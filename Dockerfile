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

# Runtime shared libs the Ruby interpreter links against (openssl, libyaml for psych).
RUN yum upgrade -y && \
    yum install -y openssl libyaml && \
    yum clean all -y && \
    rm -rf /var/cache/yum

COPY --from=build /usr/local/rvm/rubies/ruby-${VERSION} /usr/local/rvm/rubies/ruby-${VERSION}

ENV PATH="/usr/local/rvm/rubies/ruby-${VERSION}/bin:${PATH}"

EXPOSE 9394
ENTRYPOINT ["prometheus_exporter","--verbose","-b","ANY","-t","10"]
