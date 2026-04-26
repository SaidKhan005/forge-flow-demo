# Phase 11a.11c.3 - Staging cloud apply retry report

> **SUPERSEDED 2026-04-26.** This report verified Supabase staging
> schema. The Postgres host then pivoted to Azure DB Flexible Server
> (`Canada Central`, PG 16) because Apache AGE is GA on Azure but
> unavailable on Supabase. The SQL portability conclusions in this
> report are still valid (the same migrations apply cleanly on Azure
> in `11a.11c.6`); the Supabase staging project is retired after
> `11a.11c.6` accepts. Retained as Supabase-historical for traceability.

**Status:** STAGING SCHEMA VERIFIED.

The repo can reach Supabase through the local `supabase` npm dev dependency /
`npx supabase`. The repo is linked to the project ref from `.env.local`, and
the remote migration list shows all five local migrations applied. Read-only
verification queries confirm the expected schema surfaces and pgvector behavior.
The user confirmed on 2026-04-25 that the linked project named `Forge & Flow`
is the staging project for this lane; production will be created or named
separately later.

No secret values are reproduced in this report. Env values were loaded only
from `.env.local` into the current PowerShell process.

**Generated:** 2026-04-25 (slice 11a.11c.3 retry).

---

## 1. Preflight result

| Check | Result |
|---|---|
| `supabase` on PATH | **MISSING** |
| `npx supabase --version` | **PRESENT** (`2.95.3`) |
| Local `package.json` Supabase CLI dependency | **PRESENT** |
| `.env.local` | **PRESENT**, gitignored, untracked |
| `SUPABASE_ACCESS_TOKEN` env name | **PRESENT after local dotenv load** |
| `SUPABASE_PROJECT_REF` env name | **PRESENT after local dotenv load** |
| `SUPABASE_DB_URL` env name | **PRESENT after local dotenv load** |
| `supabase/config.toml` | **PRESENT** |
| legacy `.supabase/` marker | **MISSING** |
| `supabase/.temp/project-ref` marker | **PRESENT** and matches `SUPABASE_PROJECT_REF` |

Notes:

- Global npm install is unsupported by the Supabase CLI package, so the CLI is
  available through `npm run supabase` / `npx supabase`.
- This Supabase CLI version records the link under `supabase/.temp/` rather
  than a repo-root `.supabase/` directory.

## 2. Project identity

The linked project display name is not obviously staging-shaped, but the user
confirmed it is the staging project for this lane. Production is not linked here
and should be named separately later.

## 3. Remote migration status

`npx supabase migration list` showed all five local migrations matched remotely:

1. `202604250001`
2. `202604250002`
3. `202604250003`
4. `202604250004`
5. `202604250005`

No `db push` command was run during this Codex retry; the remote already had
the five migration versions recorded by the time the read-only migration list
was checked.

## 4. Read-only verification results

Read-only queries against the linked remote database verified:

- Installed extensions: `pgcrypto 1.3`, `vector 0.8.0`.
- AGE availability: `age` is not available and not installed on this project.
- Expected advisor/corpus/proxy/cloud-foundation tables with RLS: count
  returned `17` rows, covering the expected tables plus partitioned table
  surfaces.
- `usage_logs` is declaratively range-partitioned: count `1`.
- Composite `(operator_id, location_id)` foreign keys: count `5`.
- `feature_flags` malformed-scope CHECK: count `1`.
- `feature_flags_location_scope_idx` requires both scope columns: count `1`.
- `advisor_source_chunks.embedding` type: `vector(1024)`.
- Voyage HNSW partial index with `active = true`: count `1`.
- `advisor_search_chunks` definition includes `c.active = true`: count `1`.
- pgvector smoke query returned a finite cosine distance.
- `timestamp without time zone` columns in cloud-foundation tables: count `0`.

## 5. AGE result

AGE is neither available nor installed on the linked Supabase project. Per the
11a.11c gate, AGE traversal remains blocked/fallback-only until an AGE-capable
target is provisioned. Do not fake AGE success.

## 6. Acceptance for this retry

- [x] `.env.local` was loaded without printing values.
- [x] Supabase CLI is available through local npm / `npx`.
- [x] Repo link exists and matches the project ref from `.env.local`.
- [x] Remote migration list shows all five migrations applied.
- [x] Read-only verification proves pgvector, pgcrypto, schema tables, RLS,
      vector-search objects, cloud-foundation constraints, and partitioning.
- [x] AGE is explicitly documented as unavailable with fallback required.
- [x] No secret values are reproduced.
- [x] No production confirmation, provider call, runtime code change, migration
      edit, tracker change, or commit.
- [x] Human confirmation that the linked project is staging.
