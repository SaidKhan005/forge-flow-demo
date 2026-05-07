# syntax=docker/dockerfile:1
#
# Phase 8 gap-2 — first_connect_backfill_worker Cloud Run container.
#
# Mirrors `tool/audit_anchor/Dockerfile`: Flutter SDK build stage so
# `dart compile exe` can resolve the `package:forge_and_flow`
# dependency (the worker imports lib/services/integration/* and
# lib/infrastructure/persistence/postgres/*), then a slim debian
# runtime carrying only ca-certificates for outbound HTTPS to
# Postgres-over-TLS and (if the deployed adapter factory drives
# vendor APIs from the worker) third-party vendor endpoints.
#
# Build context expectation: repo root. Build invocation lives in
# `scripts/deploy_first_connect_backfill_worker.ps1`; do not run
# `docker build` from inside this directory — that strips the lib/
# and pubspec.* the build stage needs.

FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /workspace

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib ./lib
COPY tool ./tool

RUN mkdir -p /workspace/build \
    && dart compile exe tool/first_connect_backfill_worker/main.dart \
       -o /workspace/build/first_connect_backfill_worker

FROM debian:bookworm-slim

# ca-certificates is the only runtime dependency: outbound TLS to
# Azure Postgres (`*.postgres.database.azure.com`) and any vendor
# endpoint the adapter factory drives from the worker. The GCP
# metadata server is plain HTTP on a link-local interface and needs
# no certs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /workspace/build/first_connect_backfill_worker \
     /app/first_connect_backfill_worker

# Default: long-running daemon polled every N seconds (see
# WorkerRuntimeConfig). Cloud Run service deploy starts at one
# instance with always-on CPU; a Cloud Scheduler "ping" keeps the
# instance warm. See README.md for service-vs-job rationale.
ENTRYPOINT ["/app/first_connect_backfill_worker"]
CMD ["daemon"]
