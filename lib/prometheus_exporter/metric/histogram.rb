# frozen_string_literal: true

module PrometheusExporter::Metric
  class Histogram < Base
    DEFAULT_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5.0, 10.0].freeze

    @default_buckets = nil if !defined?(@default_buckets)

    def self.default_buckets
      @default_buckets || DEFAULT_BUCKETS
    end

    def self.default_buckets=(buckets)
      @default_buckets = buckets
    end

    attr_reader :buckets

    def initialize(name, help, opts = {})
      super(name, help)
      @buckets = (opts[:buckets] || self.class.default_buckets).sort
      reset!
    end

    def reset!
      @sums = {}
      @counts = {}
      @observations = {}
      # Most-recent exemplar per (labels, bucket); only rendered in OpenMetrics mode.
      @exemplars = {}
    end

    def to_h
      data = {}
      @observations.each do |labels, buckets|
        count = @counts[labels]
        sum = @sums[labels]
        data[labels] = { "count" => count, "sum" => sum }
      end
      data
    end

    def remove(labels)
      @observations.delete(labels)
      @counts.delete(labels)
      @sums.delete(labels)
      @exemplars.delete(labels)
    end

    def type
      "histogram"
    end

    def metric_text
      text = +""
      first = true
      @observations.each do |labels, buckets|
        text << "\n" unless first
        first = false
        count = @counts[labels]
        sum = @sums[labels]
        @buckets.each do |bucket|
          value = @observations[labels][bucket]
          text << "#{prefix(@name)}_bucket#{labels_text(with_bucket(labels, bucket.to_s))} #{value}\n"
        end
        text << "#{prefix(@name)}_bucket#{labels_text(with_bucket(labels, "+Inf"))} #{count}\n"
        text << "#{prefix(@name)}_count#{labels_text(labels)} #{count}\n"
        text << "#{prefix(@name)}_sum#{labels_text(labels)} #{sum}"
      end
      text
    end

    # exemplar is positional (not a kwarg) so braceless-hash label calls such as
    # `observe(0.1, name: "bob")` keep binding to `labels`, not to a keyword.
    def observe(value, labels = nil, exemplar = nil)
      labels ||= {}
      buckets = ensure_histogram(labels)

      value = value.to_f
      @sums[labels] += value
      @counts[labels] += 1

      fill_buckets(value, buckets)
      store_exemplar(value, labels, exemplar) if exemplar
    end

    def ensure_histogram(labels)
      @sums[labels] ||= 0.0
      @counts[labels] ||= 0
      buckets = @observations[labels]
      if buckets.nil?
        buckets = @buckets.map { |b| [b, 0] }.to_h
        @observations[labels] = buckets
      end
      buckets
    end

    def fill_buckets(value, buckets)
      @buckets.reverse_each do |b|
        break if value > b
        buckets[b] += 1
      end
    end

    def with_bucket(labels, bucket)
      labels.merge("le" => bucket)
    end

    # OpenMetrics rendering — identical to metric_text but bucket lines may carry
    # an exemplar (`# {traceID="..."} value timestamp`). Counters/gauges/summaries
    # need no special form, so only Histogram and Counter override this.
    def to_openmetrics_text
      name = prefix(@name)
      text = +"# HELP #{name} #{@help}\n# TYPE #{name} histogram\n"
      @observations.each do |labels, _buckets|
        count = @counts[labels]
        @buckets.each do |bucket|
          text << bucket_line(name, labels, bucket, @observations[labels][bucket])
        end
        text << bucket_line(name, labels, "+Inf", count)
        text << "#{name}_count#{labels_text(labels)} #{count}\n"
        text << "#{name}_sum#{labels_text(labels)} #{@sums[labels]}\n"
      end
      text
    end

    private

    def store_exemplar(value, labels, trace_id)
      key = @buckets.find { |b| value <= b } || "+Inf"
      (@exemplars[labels] ||= {})[key] = { trace_id: trace_id, value: value, ts: Time.now.to_f }
    end

    def bucket_line(name, labels, bucket, value)
      line = +"#{name}_bucket#{labels_text(with_bucket(labels, bucket.to_s))} #{value}"
      if (ex = @exemplars.dig(labels, bucket))
        line << " # {traceID=\"#{ex[:trace_id]}\"} #{ex[:value]} #{format("%.3f", ex[:ts])}"
      end
      line << "\n"
    end
  end
end
