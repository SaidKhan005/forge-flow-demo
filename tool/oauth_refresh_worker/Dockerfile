# syntax=docker/dockerfile:1
#
# Phase 8 — oauth_refresh_worker Cloud Run container.
#
# Mirrors `tool/first_connect_backfill_worker/Dockerfile` and
# `tool/audit_anchor/Dockerfile`: Flutter SDK build stage so
# `dart compile exe` can resolve the `package:forge_and_flow`
# dependency (the worker imports
# lib/integrations/_common/vendor_credential_broker.dart and
# lib/infrastructure/persistence/postgres/*), then a slim debian
# runtime carrying only ca-certificates for outbound HTTPS to
# Postgres-over-TLS and (if the deployed refresh closure registry
# drives vendor APIs from this worker) third-party vendor OAuth
# endpoints.
#
# Build context expectation: repo root. Build invocation lives in
# `scripts/deploy_oauth_refresh_worker.ps1`; do not run
# `docker build` from inside this directory — that strips the
# lib/ and pubspec.* the build stage needs.

FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /workspace

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib ./lib
COPY tool ./tool

RUN mkdir -p /workspace/build \
    && dart compile exe tool/oauth_refresh_worker/main.dart \
       -o /workspace/build/oauth_refresh_worker

FROM debian:bookworm-slim

# ca-certificates is the only runtime dependency: outbound TLS to
# Azure Postgres (`*.postgres.database.azure.com`) and any vendor
# OAuth endpoint the closure registry drives from this worker. The
# GCP metadata server is plain HTTP on a link-local interface and
# needs no certs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /workspace/build/oauth_refresh_worker \
     /app/oauth_refresh_worker

# Default: long-running daemon polled every N seconds (see
# WorkerRuntimeConfig). The Cloud Run Job deploy overrides this with
# `--args=runOnce` so each Cloud Scheduler firing exits after one
# tick. See README.md for service-vs-job rationale.
ENTRYPOINT ["/app/oauth_refresh_worker"]
CMD ["daemon"]
