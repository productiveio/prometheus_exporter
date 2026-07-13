#!/usr/bin/env bash
#
# Promote the current prometheus_exporter "latest" to the "stable" channel.
#
# Runs FIRST in the weekly pipeline, BEFORE the rebuild overwrites latest, so
# stable always trails latest by one week (same model as productiveio/docker-images):
#
#   - latest -> the image built this Sunday (fresh; api staging / `latest` sidecar)
#   - stable -> what latest was last Sunday, soaked in staging a week
#               (edge / prod / sandbox sidecar)
#
# Promotion is a registry-side manifest copy by digest -- no pull, no rebuild --
# preserving the multi-arch (amd64 + arm64) manifest list.
#
# Break-glass: set PROMOTION_HOLD=true on the Semaphore task to skip promotion.
#
set -o errexit
set -o pipefail

ECR_ACCOUNT=$ECR_ACCOUNT
IMAGE="prometheus_exporter"

if [ "${PROMOTION_HOLD}" = "true" ]; then
  echo "--> PROMOTION_HOLD=true -> skipping latest->stable promotion this run"
  exit 0
fi

echo "--> ECR login..."
aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin "$ECR_ACCOUNT"

src="$ECR_ACCOUNT/$IMAGE:latest"
dst="$ECR_ACCOUNT/$IMAGE:stable"

if docker buildx imagetools inspect "$src" >/dev/null 2>&1; then
  echo "--> Promoting $src -> $dst"
  docker buildx imagetools create -t "$dst" "$src"
else
  echo "--> Skipping $dst ($src does not exist yet)"
fi

echo "--> Promotion complete"
