# Productive build of the prometheus_exporter server image (multi-stage).
#
# Stage 1 (build): builds the gem from THIS repo's source (the productiveio fork,
# which carries the request-duration histogram + OpenMetrics exemplars) on the
# heavy productiveio/ruby base. Because RVM is not sourced in a plain RUN shell,
# GEM_HOME is unset and the gem + its `prometheus_exporter` executable install
# INTO the ruby's own dir under /usr/local/rvm/rubies/ruby-${VERSION}.
#
# Stage 2 (runtime): copies ONLY that ruby dir into a slim Amazon Linux 2023
# image, mirroring the api repo's pattern. Both stages are AL2023, so the
# compiled Ruby is ABI-compatible. Result: ~295 MB vs ~3.3 GB single-stage.
#
# This is the full image the api ECS exporter sidecar runs. It replaces
# docker-images/Dockerfile.prometheus_exporter (retired at cutover).
#
# productiveio/ruby:${VERSION} is a multi-arch manifest (amd64 + arm64), and the
# AL2023 runtime is multi-arch too, so the CI `docker buildx build
# --platform linux/amd64,linux/arm64` produces a correct image index with each
# arch's Ruby matched to its runtime.
#
# Lives on the `productive` branch only; upstream `main` keeps its own slim Dockerfile.
ARG VERSION=4.0.3

FROM productiveio/ruby:${VERSION} AS build

ARG VERSION
ENV PATH="/usr/local/rvm/rubies/ruby-${VERSION}/bin:${PATH}"

WORKDIR /src
COPY . /src
RUN gem build prometheus_exporter.gemspec && \
    gem install --no-doc prometheus_exporter-*.gem

FROM public.ecr.aws/amazonlinux/amazonlinux:2023

ARG VERSION

# Runtime deps:
#  - openssl, libyaml: shared libs the Ruby interpreter links against (libyaml for psych)
#  - jemalloc: LD_PRELOAD'd below to keep the exporter's RSS under the sidecar's tight
#    memory limit. The heavy productiveio/ruby base provided this; the slim AL2023
#    runtime must add it back, otherwise glibc malloc fragmentation grows the process
#    until the OOM killer reaps it (~every 20 min) and the container restart-loops.
RUN yum upgrade -y && \
    yum install -y openssl libyaml jemalloc && \
    yum clean all -y && \
    rm -rf /var/cache/yum

COPY --from=build /usr/local/rvm/rubies/ruby-${VERSION} /usr/local/rvm/rubies/ruby-${VERSION}
COPY --chmod=0755 docker/exporter-entrypoint.sh /usr/local/bin/exporter-entrypoint

ENV PATH="/usr/local/rvm/rubies/ruby-${VERSION}/bin:${PATH}" \
    LD_PRELOAD="/usr/lib64/libjemalloc.so.2"

EXPOSE 9394
# Wrap the exporter so SIGTERM/SIGINT produce a clean exit 0 (see the shim). The gem's
# own exe/prometheus_exporter is left untouched so the fork stays in sync with upstream.
ENTRYPOINT ["/usr/local/bin/exporter-entrypoint"]
CMD ["prometheus_exporter", "--verbose", "-b", "ANY", "-t", "10"]
