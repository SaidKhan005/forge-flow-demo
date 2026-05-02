# syntax=docker/dockerfile:1
#
# Forge & Flow advisor proxy Cloud Run container.
#
# Two-stage build: Flutter SDK image runs `dart compile exe` (the
# proxy transitively imports `package:forge_and_flow`, which is a
# Flutter package), then a slim debian runtime ships only the AOT
# binary plus ca-certificates.
#
# Base images are pinned by digest (HARD-E). Refresh them with:
#
#   docker buildx imagetools inspect ghcr.io/cirruslabs/flutter:stable
#   docker buildx imagetools inspect debian:bookworm-slim
#
# Bump the digests below and commit; CI rebuilds against the new
# digest. Do not move to a floating tag — silent base-image rotation
# is a SLSA-3 violation.

FROM ghcr.io/cirruslabs/flutter:stable@sha256:00a00f16768db672361fb5b79396b2748b75391c9d3bd9a33fc40b257ee94ef0 AS build

WORKDIR /workspace

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib ./lib
COPY tool ./tool
COPY db/migrations ./db/migrations

RUN mkdir -p /workspace/build \
    && dart compile exe tool/advisor_proxy/main.dart -o /workspace/build/advisor_proxy

FROM debian:bookworm-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Non-root runtime user. UID 10001 is well outside the host's
# subordinate-UID range so a container escape cannot collide with a
# real account on the host. /app is owned by `app` so the binary can
# read auxiliary files mounted alongside it.
RUN useradd --create-home --uid 10001 --user-group app \
    && mkdir -p /app \
    && chown -R app:app /app

WORKDIR /app

COPY --from=build --chown=app:app /workspace/build/advisor_proxy /app/advisor_proxy
COPY --from=build --chown=app:app /workspace/db/migrations /app/db/migrations

USER app

ENV PORT=8080
EXPOSE 8080

CMD ["/app/advisor_proxy"]
