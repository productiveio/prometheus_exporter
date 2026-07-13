#!/usr/bin/env bash
#
# Regenerate channels.json -- a record of which image digest the latest / stable
# channels currently point at. The ECR tags are the source of truth; this file is
# a human-readable audit trail + rollback aid (roll back stable by re-pointing its
# tag at the previous digest recorded here). Run LAST in the weekly pipeline.
#
# Uploaded as a Semaphore workflow artifact (one per run), so the per-run history
# lives in the artifact store; the file is not committed back.
#
set -o pipefail

ECR_ACCOUNT=$ECR_ACCOUNT
IMAGE="prometheus_exporter"
OUT="channels.json"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "--> ECR login..."
aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin "$ECR_ACCOUNT"

digest() {
  docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

lat=$(digest "$ECR_ACCOUNT/$IMAGE:latest")
stb=$(digest "$ECR_ACCOUNT/$IMAGE:stable")

jq -n --arg now "$NOW" --arg r "$ECR_ACCOUNT" --arg l "$lat" --arg s "$stb" \
  '{updated_at: $now, images: {prometheus_exporter: {registry: $r, versions: {latest: {latest: $l, stable: $s}}}}}' \
  > "$OUT"

echo "--> Wrote $OUT:"
cat "$OUT"

if command -v artifact >/dev/null 2>&1; then
  artifact push workflow "$OUT" --force || echo "--> artifact push skipped"
fi
