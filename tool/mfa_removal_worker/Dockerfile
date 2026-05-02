# syntax=docker/dockerfile:1
#
# HARD-E — mfa_removal_worker Cloud Run Job container.
#
# Mirrors the audit_anchor build pattern: Flutter SDK image for
# `dart compile exe` (the worker transitively imports
# `package:forge_and_flow`, which is a Flutter package), then a
# distroless runtime that ships only what the AOT executable plus
# system root certs need.
#
# Build context expectation: repo root. Build invocation lives in
# `tool/mfa_removal_worker/cloudbuild.yaml`; do not run
# `docker build` from inside `tool/mfa_removal_worker/` — that
# strips the lib/ and pubspec.* the build stage needs.
#
# Base images are pinned by digest. `:stable`/`:nonroot` floats
# would let the build silently swap to a new image whenever
# upstream re-tags. Refresh:
#
#   docker buildx imagetools inspect ghcr.io/cirruslabs/flutter:stable
#   docker buildx imagetools inspect gcr.io/distroless/cc-debian12:nonroot
#
# Bump the digests below and commit; CI rebuilds against the new
# digest and the cloudbuild step writes the resulting image SHA into
# the artifact registry. The distroless `nonroot` tag runs as UID
# 65532 by default, so we do not need a separate `useradd` step.

FROM ghcr.io/cirruslabs/flutter:stable@sha256:00a00f16768db672361fb5b79396b2748b75391c9d3bd9a33fc40b257ee94ef0 AS build

WORKDIR /workspace

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib ./lib
COPY tool ./tool

RUN mkdir -p /workspace/build \
    && dart compile exe tool/mfa_removal_worker/main.dart \
        -o /workspace/build/mfa_removal_worker

FROM gcr.io/distroless/cc-debian12:nonroot@sha256:e2d29aec8061843706b7e484c444f78fafb05bfe47745505252b1769a05d14f1

WORKDIR /app

COPY --from=build /workspace/build/mfa_removal_worker /app/mfa_removal_worker

# distroless `nonroot` images run as UID 65532 by default. The image
# has no shell, so the entrypoint must be the AOT binary directly.
USER nonroot

# Cloud Run Jobs invoke ENTRYPOINT then exit; no port to expose.
# Operators can override the batch size per execution by passing
# `--args=--batch-size=200` to the job.
ENTRYPOINT ["/app/mfa_removal_worker"]
