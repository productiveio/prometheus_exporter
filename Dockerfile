# Productive build of the complete prometheus_exporter server image.
#
# Builds the gem from THIS repo's source (the productiveio fork, which carries the
# request-duration histogram + OpenMetrics exemplars) on the productiveio/ruby base.
# This is the full image the API ECS exporter sidecar runs — it replaces
# docker-images/Dockerfile.prometheus_exporter (retired at cutover).
#
# Lives on the `productive` branch only; upstream `main` keeps its own slim Dockerfile.
ARG VERSION=4.0.3

FROM productiveio/ruby:${VERSION}

ARG VERSION
ENV PATH="/usr/local/rvm/rubies/ruby-${VERSION}/bin:${PATH}"

WORKDIR /src
COPY . /src
RUN gem build prometheus_exporter.gemspec && \
    gem install --no-doc prometheus_exporter-*.gem && \
    rm -rf /src

EXPOSE 9394
ENTRYPOINT ["prometheus_exporter","--verbose","-b","ANY","-t","10"]
