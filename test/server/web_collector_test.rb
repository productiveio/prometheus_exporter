# frozen_string_literal: true

require_relative "../test_helper"
require "mini_racer"
require "prometheus_exporter/server"
require "prometheus_exporter/instrumentation"

class PrometheusWebCollectorTest < Minitest::Test
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
    PrometheusExporter::Metric::Base.default_aggregation = nil
  end

  def teardown
    PrometheusExporter::Metric::Base.default_aggregation = nil
    ENV.delete("HIST_ACTIONS")
    ENV.delete("HIST_CONTROLLERS")
    ENV.delete("HIST_EXEMPLAR_MIN_SECONDS")
  end

  def collector
    @collector ||= PrometheusExporter::Server::WebCollector.new
  end

  def test_collecting_metrics_without_specific_timings
    collector.collect(
      "type" => "web",
      "timings" => nil,
      "default_labels" => {
        "action" => "index",
        "controller" => "home",
        :"status" => 200,
      },
    )

    metrics = collector.metrics

    assert_equal 6, metrics.size
  end

  def test_collecting_metrics
    collector.collect(
      "type" => "web",
      "timings" => {
        "sql" => {
          duration: 0.5,
          count: 40,
        },
        "redis" => {
          duration: 0.03,
          count: 4,
        },
        "memcache" => {
          duration: 0.02,
          count: 1,
        },
        "queue" => 0.03,
        "total_duration" => 1.0,
      },
      "default_labels" => {
        "action" => "index",
        "controller" => "home",
        "status" => 200,
      },
    )

    metrics = collector.metrics
    assert_equal 6, metrics.size
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      "type" => "web",
      "timings" => nil,
      "status" => 200,
      "default_labels" => {
        "controller" => "home",
        "action" => "index",
      },
      "custom_labels" => {
        "service" => "service1",
      },
    )

    metrics = collector.metrics

    assert_equal 6, metrics.size
    assert(
      metrics.first.metric_text.include?(
        'http_requests_total{controller="home",action="index",service="service1",status="200"} 1',
      ),
    )
  end

  def test_collecting_metrics_merging_custom_labels_and_status
    collector.collect(
      "type" => "web",
      "timings" => nil,
      "status" => 200,
      "default_labels" => {
        "controller" => "home",
        "action" => "index",
      },
      "custom_labels" => {
        "service" => "service1",
        "status" => 200,
      },
    )

    metrics = collector.metrics

    assert_equal 6, metrics.size
    assert(
      metrics.first.metric_text.include?(
        'http_requests_total{controller="home",action="index",service="service1",status="200"} 1',
      ),
    )
  end

  def test_collecting_metrics_in_histogram_mode
    PrometheusExporter::Metric::Base.default_aggregation = PrometheusExporter::Metric::Histogram

    collector.collect(
      "type" => "web",
      "status" => 200,
      "timings" => {
        "sql" => {
          duration: 0.5,
          count: 40,
        },
        "redis" => {
          duration: 0.03,
          count: 4,
        },
        "memcache" => {
          duration: 0.02,
          count: 1,
        },
        "queue" => 0.03,
        "total_duration" => 1.0,
      },
      "default_labels" => {
        "controller" => "home",
        "action" => "index",
      },
      "custom_labels" => {
        "service" => "service1",
      },
    )

    metrics = collector.metrics
    metrics_lines = metrics.map(&:metric_text).flat_map(&:lines)

    assert_equal 6, metrics.size
    assert_includes(
      metrics_lines,
      "http_requests_total{controller=\"home\",action=\"index\",service=\"service1\",status=\"200\"} 1",
    )
    assert_includes(
      metrics_lines,
      "http_request_duration_seconds_bucket{controller=\"home\",action=\"index\",service=\"service1\",le=\"+Inf\"} 1\n",
    )
  end

  def web_payload(action:, controller:, total_duration:, account_tier: nil)
    custom = { "service" => "service1" }
    custom["account_tier"] = account_tier if account_tier
    {
      "type" => "web",
      "status" => 200,
      "timings" => { "total_duration" => total_duration },
      "default_labels" => { "controller" => controller, "action" => action },
      "custom_labels" => custom,
    }
  end

  def test_histogram_off_by_default
    collector.collect(web_payload(action: "index", controller: "home", total_duration: 0.1, account_tier: "xs"))

    metrics = collector.metrics
    metrics_text = metrics.map(&:metric_text).join

    assert_equal 6, metrics.size
    refute_includes metrics_text, "http_request_duration_seconds_hist"
    # account_tier is stripped before the summary path regardless of the gate.
    refute_includes metrics_text, "account_tier"
  end

  def test_histogram_emitted_and_gated_by_action
    ENV["HIST_ACTIONS"] = "index"
    collector.collect(web_payload(action: "index", controller: "home", total_duration: 0.1, account_tier: "xs"))
    collector.collect(web_payload(action: "show", controller: "home", total_duration: 0.1, account_tier: "l"))

    metrics_text = collector.metrics.map(&:metric_text).join

    # index emitted with its tier on the histogram only...
    assert_includes(
      metrics_text,
      "http_request_duration_seconds_hist_bucket{controller=\"home\",action=\"index\",service=\"service1\",account_tier=\"xs\",le=\"0.1\"} 1",
    )
    # ...show gated out of the histogram...
    refute_includes metrics_text, "action=\"show\",service=\"service1\",account_tier"
    # ...and the summary never carries account_tier.
    refute_includes metrics_text, "http_request_duration_seconds{controller=\"home\",action=\"index\",service=\"service1\",account_tier"
  end

  def test_histogram_carries_exemplar_from_trace_id
    ENV["HIST_ACTIONS"] = "index"
    ENV["HIST_EXEMPLAR_MIN_SECONDS"] = "0" # attach regardless of duration for this test
    payload = web_payload(action: "index", controller: "home", total_duration: 0.2, account_tier: "xs")
    payload["trace_id"] = "deadbeefcafe"
    collector.collect(payload)

    hist = collector.metrics.find { |m| m.name == "http_request_duration_seconds_hist" }
    refute_nil hist
    # value 0.2 lands in the le="0.2" bucket and carries the trace id as an exemplar.
    assert_match(/le="0.2"\} 1 # \{traceID="deadbeefcafe"\}/, hist.to_openmetrics_text)
  end

  def test_exemplar_gated_by_latency_threshold
    ENV["HIST_ACTIONS"] = "index"
    ENV["HIST_EXEMPLAR_MIN_SECONDS"] = "1.0"

    fast = web_payload(action: "index", controller: "home", total_duration: 0.2, account_tier: "xs")
    fast["trace_id"] = "fasttrace"
    collector.collect(fast)

    slow = web_payload(action: "index", controller: "home", total_duration: 2, account_tier: "xs")
    slow["trace_id"] = "slowtrace"
    collector.collect(slow)

    text = collector.metrics.find { |m| m.name == "http_request_duration_seconds_hist" }.to_openmetrics_text

    # the slow request (>= 1s) carries its trace as an exemplar...
    assert_match(/le="2"\} \d+ # \{traceID="slowtrace"\}/, text)
    # ...the sub-threshold request does not, so fast buckets stay clean.
    refute_match(/traceID="fasttrace"/, text)
  end
end
