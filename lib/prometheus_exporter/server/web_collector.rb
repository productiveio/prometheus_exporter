# frozen_string_literal: true

module PrometheusExporter::Server
  class WebCollector < TypeCollector
    # Request-duration histogram (additive to the existing summary; gives true
    # quantiles + SLOs). Buckets tuned from the production index-latency
    # distribution (2026-06-17): controller p50 58ms / p90 125ms / p99 154ms;
    # 90th-pct controller p99 922ms; worst index endpoint p99 ~46s.
    HISTOGRAM_BUCKETS = [0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 3, 5, 10, 30, 60].freeze

    def initialize
      @metrics = {}
      @http_requests_total = nil
      @http_request_duration_seconds = nil
      @http_request_duration_seconds_hist = nil
      @http_request_redis_duration_seconds = nil
      @http_request_sql_duration_seconds = nil
      @http_request_queue_duration_seconds = nil
      @http_request_memcache_duration_seconds = nil
      # Ramp gating (default OFF): the histogram is emitted only for these
      # actions/controllers, so it can be rolled out one endpoint at a time.
      @hist_actions = (ENV["HIST_ACTIONS"] || "").split(",").map(&:strip).reject(&:empty?)
      @hist_controllers = (ENV["HIST_CONTROLLERS"] || "").split(",").map(&:strip).reject(&:empty?)
      # Exemplars are attached only to requests at/above this duration, so the
      # fast, high-volume buckets don't bury the slow tail we actually want to
      # trace. Tune via env; 0 attaches an exemplar to every request.
      @hist_exemplar_min = (ENV["HIST_EXEMPLAR_MIN_SECONDS"] || "1.0").to_f
    end

    def type
      "web"
    end

    def collect(obj)
      ensure_metrics
      observe(obj)
    end

    def metrics
      @metrics.values
    end

    protected

    def ensure_metrics
      unless @http_requests_total
        @metrics["http_requests_total"] = @http_requests_total =
          PrometheusExporter::Metric::Counter.new(
            "http_requests_total",
            "Total HTTP requests from web app.",
          )

        @metrics["http_request_duration_seconds"] = @http_request_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_duration_seconds",
            "Time spent in HTTP reqs in seconds.",
          )

        @metrics["http_request_redis_duration_seconds"] = @http_request_redis_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_redis_duration_seconds",
            "Time spent in HTTP reqs in Redis, in seconds.",
          )

        @metrics["http_request_sql_duration_seconds"] = @http_request_sql_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_sql_duration_seconds",
            "Time spent in HTTP reqs in SQL in seconds.",
          )

        @metrics[
          "http_request_memcache_duration_seconds"
        ] = @http_request_memcache_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_memcache_duration_seconds",
            "Time spent in HTTP reqs in Memcache in seconds.",
          )

        @metrics["http_request_queue_duration_seconds"] = @http_request_queue_duration_seconds =
          PrometheusExporter::Metric::Base.default_aggregation.new(
            "http_request_queue_duration_seconds",
            "Time spent queueing the request in load balancer in seconds.",
          )
      end
    end

    def observe(obj)
      default_labels = obj["default_labels"]
      custom_labels = obj["custom_labels"]
      # account_tier rides on the histogram only — strip it before the summaries
      # so the existing low-cardinality summary series stay unchanged.
      account_tier = custom_labels && custom_labels.delete("account_tier")
      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      @http_requests_total.observe(1, labels.merge("status" => obj["status"]))

      if timings = obj["timings"]
        @http_request_duration_seconds.observe(timings["total_duration"], labels)
        observe_histogram(timings["total_duration"], labels, account_tier, obj["trace_id"])
        if redis = timings["redis"]
          @http_request_redis_duration_seconds.observe(redis["duration"], labels)
        end
        if sql = timings["sql"]
          @http_request_sql_duration_seconds.observe(sql["duration"], labels)
        end
        if memcache = timings["memcache"]
          @http_request_memcache_duration_seconds.observe(memcache["duration"], labels)
        end
      end
      if queue_time = obj["queue_time"]
        @http_request_queue_duration_seconds.observe(queue_time, labels)
      end
    end

    private

    def observe_histogram(duration, labels, account_tier, trace_id)
      return if duration.nil?
      return if @hist_actions.empty? # gate: off by default
      # exclude? would be cleaner but it's ActiveSupport — unavailable in the standalone server.
      return unless @hist_actions.include?(labels["action"]) # rubocop:disable Style/InvertibleUnlessCondition
      return unless @hist_controllers.empty? || @hist_controllers.include?(labels["controller"])

      # Registered lazily so the metric is absent entirely until the gate opens.
      @http_request_duration_seconds_hist ||=
        @metrics["http_request_duration_seconds_hist"] =
          PrometheusExporter::Metric::Histogram.new(
            "http_request_duration_seconds_hist",
            "HTTP request duration in seconds (histogram, additive to the summary).",
            buckets: HISTOGRAM_BUCKETS,
          )

      exemplar = trace_id if trace_id && duration >= @hist_exemplar_min
      @http_request_duration_seconds_hist.observe(
        duration,
        labels.merge("account_tier" => account_tier || "unknown"),
        exemplar,
      )
    end
  end
end
