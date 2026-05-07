# syntax=docker/dockerfile:1
#
# Phase 8 Wave B `8.spine-bridge.0` — integration_sync_worker Cloud Run
# container.
#
# Mirrors `tool/first_connect_backfill_worker/Dockerfile`: Flutter SDK
# build stage so `dart compile exe` can resolve the
# `package:forge_and_flow` dependency (the worker imports
# lib/services/integration/* and lib/infrastructure/persistence/postgres/*),
# then a slim debian runtime carrying only ca-certificates for outbound
# HTTPS to Postgres-over-TLS and (per the binder-backed adapter
# factories) third-party vendor endpoints.
#
# Build context expectation: repo root. Build invocation lives in
# `scripts/deploy_integration_sync_worker.ps1`; do not run
# `docker build` from inside this directory — that strips the lib/
# and pubspec.* the build stage needs.

FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /workspace

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib ./lib
COPY tool ./tool

RUN mkdir -p /workspace/build \
    && dart compile exe tool/integration_sync_worker/main.dart \
       -o /workspace/build/integration_sync_worker

FROM debian:bookworm-slim

# ca-certificates is the only runtime dependency: outbound TLS to
# Azure Postgres (`*.postgres.database.azure.com`) and any vendor
# endpoint the binder-backed adapter factories drive. The GCP
# metadata server is plain HTTP on a link-local interface and needs
# no certs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /workspace/build/integration_sync_worker \
     /app/integration_sync_worker

# Default: long-running daemon polled every N seconds (see
# WorkerRuntimeConfig). Production deploys override CMD to `runOnce`
# via `gcloud run jobs deploy --args runOnce` — see README.md
# "Deploy shape" for the rationale.
ENTRYPOINT ["/app/integration_sync_worker"]
CMD ["daemon"]
