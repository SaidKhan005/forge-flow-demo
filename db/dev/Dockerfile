# Phase 11a.11c.5 — Local Postgres 16 image with Apache AGE + pgvector.
#
# Starting point for a developer who wants to apply the advisor
# migrations against a local Postgres without going through Azure /
# Supabase. Not built or run by the 11a.11c.5 retarget slice.
#
# Strategy: extend the official pgvector image (which already has
# pgvector compiled and registered) and build Apache AGE from source.
# AGE upstream provides PG-version-tagged images, but pgvector is
# easier to package, so we layer AGE on top of pgvector rather than
# the reverse.

FROM pgvector/pgvector:pg16

ARG AGE_VERSION=PG16/v1.5.0-rc0

# Build dependencies for Apache AGE. Cleaned up after `make install`
# so the final image stays close to the pgvector base.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      ca-certificates \
      flex \
      bison \
      postgresql-server-dev-16 \
 && rm -rf /var/lib/apt/lists/*

# Clone Apache AGE at the pinned version, build, install, then drop
# the source tree.
RUN git clone https://github.com/apache/age.git /tmp/age \
 && cd /tmp/age \
 && git checkout ${AGE_VERSION} \
 && make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config \
 && make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config install \
 && cd / \
 && rm -rf /tmp/age \
 && apt-get purge -y build-essential git flex bison postgresql-server-dev-16 \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# Pre-load AGE for every connection so `cypher(...)` works without a
# manual `LOAD 'age'` per session. pgvector's CREATE EXTENSION runs at
# DB init time inside the container's existing entrypoint scripts.
RUN echo "shared_preload_libraries = 'age'" \
      >> /usr/share/postgresql/postgresql.conf.sample
