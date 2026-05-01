# syntax=docker/dockerfile:1
#
# Phase 9.0Σ.f — audit_anchor Cloud Run Job container.
#
# Mirrors the root /Dockerfile (advisor_proxy) so both Cloud Run
# workloads share a consistent build pattern: Flutter SDK image for
# `dart compile exe` (the tool transitively imports `package:forge_and_flow`,
# which is a Flutter package), then a slim debian runtime with only
# ca-certificates for outbound HTTPS to Azure AD + Storage + the GCP
# metadata server.
#
# Build context expectation: repo root. Build invocation lives in
# `tool/audit_anchor/cloudbuild.yaml`; do not run `docker build` from
# inside `tool/audit_anchor/` — that strips the lib/ and pubspec.* the
# build stage needs.

FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /workspace

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib ./lib
COPY tool ./tool

RUN mkdir -p /workspace/build \
    && dart compile exe tool/audit_anchor/main.dart -o /workspace/build/audit_anchor

FROM debian:bookworm-slim

# ca-certificates is the only runtime dependency: the WIF token
# exchange (login.microsoftonline.com) and Storage Blob calls
# (*.blob.core.windows.net) are HTTPS, so the system trust store must
# include the public roots. The GCP metadata server is plain HTTP on
# the link-local interface and needs no certs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /workspace/build/audit_anchor /app/audit_anchor

# Cloud Run Jobs invoke ENTRYPOINT then exit; no port to expose. The
# default mode is `sweep` so the daily Cloud Scheduler trigger works
# without args. Operators running ad-hoc `anchor` / `verify` modes
# pass `--args=anchor,--operator-id=...` to the Cloud Run Job
# execution (see runbook).
ENTRYPOINT ["/app/audit_anchor"]
CMD ["sweep"]
