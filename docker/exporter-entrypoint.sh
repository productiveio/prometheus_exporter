#!/usr/bin/env bash
#
# Graceful-shutdown shim for the exporter sidecar (productive fork only).
#
# The upstream `prometheus_exporter` binary parks on `sleep` with no signal trap,
# so on SIGTERM (ECS task stop / scale-down) WEBrick drains and the process exits
# NON-ZERO (1). We keep the gem source identical to upstream and fix this at the
# image layer instead: run the exporter as a child, forward the stop signal, and
# report a clean exit 0 for signal-driven shutdowns. A real fault (the child
# exiting on its own, e.g. OOM) keeps its non-zero code so ECS's container restart
# policy still fires.
set -e

status=0
got_signal=0

forward() {
  got_signal=1
  kill -TERM "$pid" 2>/dev/null || true
}
trap forward TERM INT

"$@" &
pid=$!

# The trap interrupts `wait` (returns >128) before the child has finished draining,
# so loop until the child is actually gone, capturing its real exit status.
set +e
while kill -0 "$pid" 2>/dev/null; do
  wait "$pid"
  status=$?
done
set -e

# Signal-driven stop is a clean shutdown -> 0; otherwise propagate the real code.
[ "$got_signal" -eq 1 ] && exit 0
exit "$status"
