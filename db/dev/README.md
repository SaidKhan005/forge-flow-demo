# Local Postgres dev scaffold

Phase 11a.11c.5 retarget. Not run by that slice; a starting point for
a developer who wants to apply the advisor migrations against a local
Postgres without provisioning Azure or Supabase.

## What it gives you

- Postgres 16
- `pgvector` (from `pgvector/pgvector:pg16` base — already registered)
- `apache/age` v1.5.0-rc0 built from source against PG16 and added to
  `shared_preload_libraries` so `cypher(...)` works without a per-
  session `LOAD 'age'`

## Bring it up (NOT executed by 11a.11c.5)

```sh
docker compose -f docker-compose.dev.yml up --build
```

Then, from a second terminal:

```sh
psql "postgres://forge:dev@localhost:5432/forge" -v ON_ERROR_STOP=1 \
  -f db/migrations/202604250000_advisor_roles.sql
psql "postgres://forge:dev@localhost:5432/forge" -v ON_ERROR_STOP=1 \
  -f db/migrations/202604250001_advisor_corpus_storage_schema.sql
psql "postgres://forge:dev@localhost:5432/forge" -v ON_ERROR_STOP=1 \
  -f db/migrations/202604250002_advisor_embedding_contract.sql
psql "postgres://forge:dev@localhost:5432/forge" -v ON_ERROR_STOP=1 \
  -f db/migrations/202604250003_advisor_vector_search.sql
psql "postgres://forge:dev@localhost:5432/forge" -v ON_ERROR_STOP=1 \
  -f db/migrations/202604250004_advisor_proxy_usage_counters.sql
psql "postgres://forge:dev@localhost:5432/forge" -v ON_ERROR_STOP=1 \
  -f db/migrations/202604250005_advisor_cloud_foundation.sql
```

## Production target

This dev scaffold is a stand-in for the production Azure Database for
PostgreSQL Flexible Server provisioned in `11a.11c.6`. The role
bootstrap migration (`202604250000_advisor_roles.sql`) ensures the
same migration set applies cleanly to a generic Postgres host — no
Supabase-specific role conventions assumed.
