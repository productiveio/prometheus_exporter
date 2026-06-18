# frozen_string_literal: true

require "webrick"
require "timeout"
require "zlib"
require "stringio"

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    def initialize(opts)
      @port = opts[:port] || PrometheusExporter::DEFAULT_PORT
      @bind = opts[:bind] || PrometheusExporter::DEFAULT_BIND_ADDRESS
      @timeout = opts[:timeout] || PrometheusExporter::DEFAULT_TIMEOUT
      @verbose = opts[:verbose] || false
      @auth = opts[:auth]
      @realm = opts[:realm] || PrometheusExporter::DEFAULT_REALM

      @metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_metrics_total",
          "Total metrics processed by exporter web.",
        )

      @sessions_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_sessions_total",
          "Total send_metric sessions processed by exporter web.",
        )

      @bad_metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_bad_metrics_total",
          "Total mis-handled metrics by collector.",
        )

      @metrics_total.observe(0)
      @sessions_total.observe(0)
      @bad_metrics_total.observe(0)

      @access_log, @logger = nil
      log_target = opts[:log_target]

      if @verbose
        @access_log = [
          [$stderr, WEBrick::AccessLog::COMMON_LOG_FORMAT],
          [$stderr, WEBrick::AccessLog::REFERER_LOG_FORMAT],
        ]
        @logger = WEBrick::Log.new(log_target || $stderr)
      else
        @access_log = []
        @logger = WEBrick::Log.new(log_target || "/dev/null")
      end

      @logger.info "Using Basic Authentication via #{@auth}" if @verbose && @auth

      if %w[ALL ANY].include?(@bind)
        @logger.info "Listening on both 0.0.0.0/:: network interfaces"
        @bind = nil
      end

      @collector = opts[:collector] || Collector.new(logger: @logger)

      # Custom collectors may still define `prometheus_metrics_text` with no args
      # (the legacy CollectorBase interface); only pass `openmetrics:` when supported.
      @collector_accepts_openmetrics =
        @collector
          .method(:prometheus_metrics_text)
          .parameters
          .any? { |type, name| type == :keyrest || name == :openmetrics }

      webrick_options = { Port: @port, BindAddress: @bind, Logger: @logger, AccessLog: @access_log }

      if opts[:tls_cert_file] && opts[:tls_key_file]
        require "webrick/https"
        require "openssl"

        webrick_options[:SSLEnable] = true
        webrick_options[:SSLCertificate] = OpenSSL::X509::Certificate.new(
          File.read(opts[:tls_cert_file]),
        )
        webrick_options[:SSLPrivateKey] = OpenSSL::PKey::RSA.new(File.read(opts[:tls_key_file]))
      end

      @server = WEBrick::HTTPServer.new(webrick_options)

      @server.mount_proc "/" do |req, res|
        res["Content-Type"] = "text/plain; charset=utf-8"
        if req.path == "/metrics"
          authenticate(req, res) if @auth

          res.status = 200
          # Prometheus advertises OpenMetrics via Accept when exemplar-storage
          # scraping is on; only then do we emit exemplars + `# EOF`.
          openmetrics = req["accept"].to_s.include?("application/openmetrics-text")
          if openmetrics
            res["Content-Type"] = "application/openmetrics-text; version=1.0.0; charset=utf-8"
          end
          if req.header["accept-encoding"].to_s.include?("gzip")
            sio = StringIO.new
            collected_metrics = metrics(openmetrics: openmetrics)
            begin
              writer = Zlib::GzipWriter.new(sio)
              writer.write(collected_metrics)
            ensure
              writer.close
            end
            res.body = sio.string
            res.header["content-encoding"] = "gzip"
          else
            res.body = metrics(openmetrics: openmetrics)
          end
        elsif req.path == "/send-metrics"
          handle_metrics(req, res)
        elsif req.path == "/ping"
          res.body = "PONG"
        else
          res.status = 404
          res.body =
            "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics"
        end
      end
    end

    def handle_metrics(req, res)
      @sessions_total.observe
      req.body do |block|
        begin
          @metrics_total.observe
          @collector.process(block)
        rescue => e
          @logger.error "\n\n#{e.inspect}\n#{e.backtrace}\n\n" if @verbose
          @bad_metrics_total.observe
          res.body = "Bad Metrics #{e}"
          res.status = e.respond_to?(:status_code) ? e.status_code : 500
          break
        end
      end

      res.body = "OK"
      res.status = 200
    end

    def start
      @runner ||=
        Thread.start do
          begin
            @server.start
          rescue => e
            @logger.error "Failed to start prometheus collector web on port #{@port}: #{e}"
          end
        end
    end

    def stop
      @server.shutdown
    end

    def metrics(openmetrics: false)
      metric_text = nil
      begin
        Timeout.timeout(@timeout) do
          metric_text =
            if @collector_accepts_openmetrics
              @collector.prometheus_metrics_text(openmetrics: openmetrics)
            else
              @collector.prometheus_metrics_text
            end
        end
      rescue Timeout::Error
        # we timed out ... bummer
        @logger.error "Generating Prometheus metrics text timed out"
      end

      metrics = []

      metrics << add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0,
      )

      metrics << add_gauge("collector_rss", "total memory used by collector process", get_rss)

      metrics << @metrics_total
      metrics << @sessions_total
      metrics << @bad_metrics_total

      internal = metrics.map { |m| openmetrics ? m.to_openmetrics_text : m.to_prometheus_text }

      body = +"#{internal.join("\n\n")}\n#{metric_text}\n"

      if openmetrics
        # OpenMetrics forbids blank lines (the legacy text parser tolerates them)
        # and the document MUST terminate with a single `# EOF`.
        body = body.gsub(/\n{2,}/, "\n").sub(/\A\n+/, "")
        body << "\n" unless body.end_with?("\n")
        body << "# EOF\n"
      end

      body
    end

    def get_rss
      @pagesize ||=
        begin
          `getconf PAGESIZE`.to_i
        rescue StandardError
          4096
        end
      @pid ||= Process.pid
      begin
        File.read("/proc/#{@pid}/statm").split(" ")[1].to_i * @pagesize
      rescue StandardError
        0
      end
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      gauge
    end

    def authenticate(req, res)
      htpasswd = WEBrick::HTTPAuth::Htpasswd.new(@auth)
      basic_auth =
        WEBrick::HTTPAuth::BasicAuth.new({ Realm: @realm, UserDB: htpasswd, Logger: @logger })

      basic_auth.authenticate(req, res)
    end
  end
end
