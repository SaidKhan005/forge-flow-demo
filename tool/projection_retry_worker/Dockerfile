# syntax=docker/dockerfile:1
#
# Canonical fact projection retry worker Cloud Run container.
#
# Mirrors the Phase 8 worker Dockerfiles: Flutter SDK build stage so
# `dart compile exe` can resolve the `package:forge_and_flow` dependency, then
# a slim Debian runtime with ca-certificates for Azure Postgres TLS.

FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /workspace

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib ./lib
COPY tool ./tool

RUN mkdir -p /workspace/build \
    && dart compile exe tool/projection_retry_worker/main.dart \
       -o /workspace/build/projection_retry_worker

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /workspace/build/projection_retry_worker \
     /app/projection_retry_worker

ENTRYPOINT ["/app/projection_retry_worker"]
CMD ["runOnce"]
