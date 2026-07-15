# Productive fork — request-duration histogram & exemplars

This is the `productive` branch of `prometheus_exporter`. On top of upstream it adds,
**built into the server's `WebCollector`**:

1. An **additive request-duration histogram** (`http_request_duration_seconds_hist`)
   with a bounded `account_tier` label, **env-gated** so it can be rolled out one
   endpoint at a time.
2. **OpenMetrics exemplars** — histogram buckets carry the request's trace id, so a
   bucket links straight to its Tempo trace.

Nothing existing is replaced: the legacy `http_request_duration_seconds` **summary**
is still emitted exactly as before. The histogram is purely additive.

> The image the API exporter sidecar runs is built from this branch
> (`Dockerfile`, `FROM productiveio/ruby`) and published as `prometheus_exporter:latest`.

---

## Release channels

The exporter image is `FROM productiveio/ruby`, so it inherits the same unattended
base-image drift as everything else. It follows the **same latest/stable model** as
`productiveio/docker-images`:

| Channel | Points at | Consumed by |
| --- | --- | --- |
| **latest** | freshly built | api staging / `latest` exporter sidecar |
| **stable** | last week's `latest` (soaked a week) | edge / prod / sandbox exporter sidecar |

Two things build this image:

- **This repo, per push to `productive`** (`.semaphore/deploy/image.yml`): run the
  tests, then build + push `prometheus_exporter:latest` (+ git sha). That's how code
  changes ship an image immediately.
- **`productiveio/docker-images`, weekly** (Sundays 02:00): after rebuilding the ruby
  base, its pipeline clones this repo and rebuilds the exporter on the *fresh* ruby,
  promotes the previous `latest` → `stable`, and records the digests in that repo's
  `channels.json`.

The weekly rebuild **and** the latest→stable promotion live in docker-images (one
pipeline for every base image, no cross-repo schedule race), so there is **no
scheduled task and no promotion/channels logic in this repo**.

### Break-glass (managed in docker-images)

- **Hold a promotion:** set `PROMOTION_HOLD=true` on the docker-images weekly task.
- **Rollback stable:** re-point the tag at the previous digest from docker-images'
  `channels.json`:
  `docker buildx imagetools create -t <ECR>/prometheus_exporter:stable <ECR>/prometheus_exporter@sha256:<prev>`
- Prod/edge/sandbox ECS task defs should pin `prometheus_exporter:stable` (follow-up in
  the api repo); staging stays on `:latest`.

---

## The histogram

- **Metric:** `http_request_duration_seconds_hist` (alongside the `…_seconds` summary).
- **Buckets (seconds):** `0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 3, 5, 10, 30, 60`
  — tuned from the production index-latency distribution.
- **`account_tier` label:** `xs`/`s`/`m`/`l`/`xl` (coarse, bounded — never a raw account id).
  It rides on the **histogram only**; it is stripped from `custom_labels` before the
  summary path, so the existing summary series keep their cardinality.
- Registered **lazily** — the metric is absent from `/metrics` entirely until the gate
  below opens for a matching request.

## Running it — env gating (default OFF)

| Env var            | Meaning                                                                 |
|--------------------|-------------------------------------------------------------------------|
| `HIST_ACTIONS`     | comma-list of actions to emit for, e.g. `index`. **Empty = OFF** (no histogram). |
| `HIST_CONTROLLERS` | comma-list of controllers to restrict to. Empty = all controllers for the allowed actions. |
| `HIST_EXEMPLAR_MIN_SECONDS` | attach an exemplar only to requests at/above this duration. Default `1.0`; `0` = every request. Keeps the fast, high-volume buckets from burying the slow tail. |

Both gates are **AND**ed: a request is recorded only if its `action` is in
`HIST_ACTIONS` **and** (`HIST_CONTROLLERS` is empty **or** its `controller` is listed).

```bash
# OFF (default) — only the existing summaries are emitted
prometheus_exporter

# All `index` actions, every controller
HIST_ACTIONS=index prometheus_exporter

# Ramp to a single controller
HIST_ACTIONS=index HIST_CONTROLLERS=api/v2/tenanted/tasks prometheus_exporter

# Widen to a few controllers
HIST_ACTIONS=index HIST_CONTROLLERS=api/v2/tenanted/tasks,api/v2/tenanted/projects prometheus_exporter
```

**Docker** (the published image):

```bash
docker run -e HIST_ACTIONS=index -p 9394:9394 productiveio/prometheus_exporter:latest
```

**From this repo** (local dev):

```bash
bundle install
HIST_ACTIONS=index bundle exec prometheus_exporter --verbose -b 127.0.0.1
```

To ramp in production you edit `HIST_ACTIONS` / `HIST_CONTROLLERS` on the exporter
container and redeploy — no app deploy needed.

## What `/metrics` returns

The exporter content-negotiates on the `Accept` header:

```bash
# Legacy Prometheus text (default scrape): histogram buckets + summary, NO exemplars
curl localhost:9394/metrics

# OpenMetrics: same, plus exemplars on histogram buckets and a trailing `# EOF`
curl -H 'Accept: application/openmetrics-text; version=1.0.0' localhost:9394/metrics
```

Example histogram series (gate `HIST_ACTIONS=index`):

```
http_request_duration_seconds_hist_bucket{controller="api/v2/tenanted/tasks",action="index",account_tier="l",le="0.5"} 30 # {traceID="aa11bb22…"} 0.42 1781773807.860
http_request_duration_seconds_hist_count{controller="api/v2/tenanted/tasks",action="index",account_tier="l"} 30
```

The `# {traceID="…"} <value> <ts>` suffix is the exemplar.

## Exemplars

- Rendered **only** in OpenMetrics mode. Prometheus/Mimir send the OpenMetrics `Accept`
  header automatically when scraped with `--enable-feature=exemplar-storage`; the plain
  text format never carries exemplars.
- The trace id comes from the **top-level `trace_id`** key of the web payload (it is NOT
  a label). One most-recent exemplar is kept per (series, bucket), and only for requests
  at/above `HIST_EXEMPLAR_MIN_SECONDS` (default 1s) — so fast buckets stay exemplar-free.
- The exemplar label is named `traceID` to match the Mimir → Tempo
  `exemplarTraceIdDestinations` wiring.

## How the labels & trace id get into the payload (app side)

The exporter only renders what the client sends. The API (the `prometheus_exporter`
*client*) sets, per request:

- `request.env['prometheus.account_tier']` → forwarded as the `account_tier` custom label.
- `request.env['prometheus.trace_id']`     → forwarded by this fork's `Middleware#call`
  as the top-level `trace_id` payload key (off when absent).

`account_tier` is only populated on **tenanted** requests (where the account is resolved);
non-tenanted requests bucket as `account_tier="unknown"`.

## Tests

```bash
bundle exec rake test
# histogram/exemplar coverage:
bundle exec ruby -Itest -Ilib test/metric/histogram_test.rb test/server/web_collector_test.rb test/middleware_test.rb
```
