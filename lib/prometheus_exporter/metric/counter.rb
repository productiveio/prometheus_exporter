# frozen_string_literal: true

module PrometheusExporter::Metric
  class Counter < Base
    attr_reader :data

    def initialize(name, help)
      super
      reset!
    end

    def type
      "counter"
    end

    def reset!
      @data = {}
    end

    def metric_text
      @data.map { |labels, value| "#{prefix(@name)}#{labels_text(labels)} #{value}" }.join("\n")
    end

    # OpenMetrics counters: the TYPE/HELP family name must NOT carry the `_total`
    # suffix, while every sample must. (Legacy text keeps `_total` on the family.)
    def to_openmetrics_text
      family = @name.end_with?("_total") ? @name[0...-"_total".length] : @name
      family = prefix(family)
      body = @data.map { |labels, value| "#{family}_total#{labels_text(labels)} #{value}" }.join("\n")
      <<~TEXT
        # HELP #{family} #{help}
        # TYPE #{family} counter
        #{body}
      TEXT
    end

    def to_h
      @data.dup
    end

    def remove(labels)
      @data.delete(labels)
    end

    def observe(increment = 1, labels = {})
      @data[labels] ||= 0
      @data[labels] += increment
    end

    def increment(labels = {}, value = 1)
      @data[labels] ||= 0
      @data[labels] += value
    end

    def decrement(labels = {}, value = 1)
      @data[labels] ||= 0
      @data[labels] -= value
    end

    def reset(labels = {}, value = 0)
      @data[labels] = value
    end
  end
end
