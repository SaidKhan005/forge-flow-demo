# Phase 11a.11b — Cloud DB apply readiness

> **SUPERSEDED 2026-04-26.** This audit catalogued Supabase
> prerequisites for cloud apply. Postgres host pivoted to Azure DB
> Flexible Server (`Canada Central`, PG 16) in `11a.11c.4-6`. The
> migration inventory in this audit is still accurate (5 migrations,
> all SQL portable); the apply mechanism (Supabase CLI / `db push`)
> is replaced by `psql` against Azure DB. Retained as
> Supabase-historical.

**Status:** BLOCKED. Live apply cannot proceed from this environment.
This document is a read-only preflight audit; no migrations were
applied, no cloud DB was contacted, no provider call was made.

**Generated:** 2026-04-25 (slice 11a.11b audit).

---

## 1. Migration inventory (apply order)

The four advisor migrations currently in `supabase/migrations/` are
ordered by their `YYYYMMDDNNNN_*` prefix. Apply them in this exact
order on a fresh project:

| # | File | Phase | Purpose |
|---|------|-------|---------|
| 1 | `supabase/migrations/202604250001_advisor_corpus_storage_schema.sql` | 11a.3 | Corpus storage scaffold: `advisor_ingestion_runs`, `advisor_source_documents`, `advisor_source_chunks`, `advisor_graph_node_seeds`, `advisor_graph_edge_hints`. Enables `vector`, `pgcrypto`, and (conditionally) `age`. RLS enabled with service-role + global-read placeholder policies. |
| 2 | `supabase/migrations/202604250002_advisor_embedding_contract.sql` | 11a.6a | Locks `advisor_source_chunks.embedding` to `vector(1024)` for Voyage `voyage-4-large`. Documents the Claude-aligned retrieval contract. |
| 3 | `supabase/migrations/202604250003_advisor_vector_search.sql` | 11a.8 | Adds versioned embedding metadata (`embedding_provider_id`, `embedding_model_id`, `embedding_dimension`), HNSW cosine partial index restricted to ready Voyage 1024-dim active rows, and the stable `advisor_search_chunks` SQL function. |
| 4 | `supabase/migrations/202604250004_advisor_proxy_usage_counters.sql` | 11a.10b | Proxy usage counters table for per-minute rate + monthly cost-cap enforcement, with `(operator_id, location_id, tier_id, minute_bucket)` uniqueness, denormalized `month_bucket`, RLS + service-role policy, and `updated_at` trigger. |

Applying in any order other than the above will fail — migration 002
alters a column created in 001; migration 003 adds metadata columns to
the same table and references it in a partial-index predicate;
migration 004 is independent of the corpus tables but depends on
`pgcrypto` (which 001 also creates).

There are no other `*.sql` files under `supabase/migrations/` at the
time of this audit.

## 2. Local environment preflight (read-only)

| Check | Result |
|---|---|
| `supabase` CLI on PATH | **MISSING** |
| `supabase/config.toml` | **MISSING** (no Supabase project config in repo) |
| `.supabase/` linked-project marker | **MISSING** |
| `SUPABASE_URL` env var | **MISSING** |
| `SUPABASE_SERVICE_ROLE_KEY` env var | **MISSING** |
| `SUPABASE_DB_URL` env var | **MISSING** |
| `SUPABASE_PROJECT_REF` env var | **MISSING** |
| `SUPABASE_ACCESS_TOKEN` env var | **MISSING** |
| `ANTHROPIC_API_KEY` env var | present (name only — value not inspected; not required for migration apply) |
| `VOYAGE_API_KEY` env var | present (name only — value not inspected; not required for migration apply) |
| `pgvector` availability on target | **CANNOT VERIFY** from this environment — needs a DB connection |
| `age` availability on target | **CANNOT VERIFY** from this environment — needs a DB connection. Migration 001 already degrades gracefully via `pg_available_extensions` if AGE is missing |

No secret values are reproduced in this document by design. "Present"
only means the env name is exported; "missing" means the name is not
exported.

## 3. Blocker

Cloud DB apply cannot run from this environment until **all** of the
following are satisfied:

1. Install the Supabase CLI on the operator's workstation
   (`https://supabase.com/docs/guides/cli`). The CLI is required for
   `supabase link`, `supabase db push`, and the verification queries.
2. Create or identify the target Supabase project; record its project
   ref (e.g. `abcdwxyz123456789012`).
3. Generate a Supabase access token in the dashboard and export it
   locally: `export SUPABASE_ACCESS_TOKEN=...`.
4. Link the repo to the project so the migrations directory is
   recognised: `supabase link --project-ref <ref>` (run from repo
   root). This produces the `.supabase/` linked-project marker that is
   currently absent.
5. Confirm the target Postgres has `pgvector` available
   (`select * from pg_available_extensions where name = 'vector';`).
   Supabase Postgres includes pgvector on all current tiers, but this
   should still be verified against the actual project.
6. Confirm `age` availability on the target if AGE traversal is
   intended in this environment
   (`select * from pg_available_extensions where name = 'age';`).
   Migration 001 will not fail when AGE is missing — it raises a
   `notice` and skips the extension — but AGE-dependent slices
   (7.57.4 projection apply, 11b graph traversal) need it to be
   present and enabled before they can run live.

Until items 1–4 are present, the runbook below cannot start.

## 4. Safe runbook for live apply (do **not** run unattended)

This section is a script for a human operator to follow once the
blocker prerequisites above are satisfied. Do not paste it into a CI
job; cloud DB apply is a deliberate human action.

### 4a. Pre-apply guardrails

1. **Confirm target project ref.** `supabase status` must show the
   linked project. Visually re-confirm the ref matches the intended
   environment (staging vs production). Refuse to proceed if there is
   any ambiguity.
2. **Backup / PITR check.** In the Supabase dashboard: Project →
   Database → Backups. Verify a recent automated backup exists and
   that point-in-time recovery is enabled (paid tier feature). Note
   the timestamp of the most recent backup so a rollback target is
   known before any DDL runs.
3. **Confirm required extensions.** Connect to the project (e.g.
   `supabase db push --dry-run` for migration preview, then
   `psql "$SUPABASE_DB_URL"` for the read-only SQL checks) and run:
   ```sql
   select extname from pg_extension where extname in ('vector','age','pgcrypto');
   select name from pg_available_extensions where name in ('vector','age');
   ```
   `vector` and `pgcrypto` must be available. `age` is optional for
   the corpus apply but required for AGE traversal slices; if
   intended for this environment, verify it before applying.

### 4b. Apply migrations in order

Use Supabase's migration push to apply the four files in their
filename order. The CLI applies them in the same order as `ls` so
nothing extra is required:

```bash
supabase db push
```

If a more explicit ordered apply is preferred, use `psql` directly
against `SUPABASE_DB_URL`:

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/202604250001_advisor_corpus_storage_schema.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/202604250002_advisor_embedding_contract.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/202604250003_advisor_vector_search.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/202604250004_advisor_proxy_usage_counters.sql
```

`-v ON_ERROR_STOP=1` aborts on the first failure so partial state is
visible immediately.

### 4c. Post-apply verification queries

Each query is read-only. They prove the structure each migration
intended is present and reachable. Run after `supabase db push`:

```sql
-- 001: corpus tables exist with RLS enabled
select relname, relrowsecurity
  from pg_class
 where relname in (
   'advisor_ingestion_runs',
   'advisor_source_documents',
   'advisor_source_chunks',
   'advisor_graph_node_seeds',
   'advisor_graph_edge_hints'
 )
 order by relname;
-- expect: all five present, relrowsecurity = true

-- 001: extensions present
select extname from pg_extension
 where extname in ('vector','pgcrypto','age')
 order by extname;
-- expect: vector, pgcrypto. age only if intended for this env.

-- 002: embedding column dimension is locked to 1024
select format_type(atttypid, atttypmod) as type
  from pg_attribute
 where attrelid = 'public.advisor_source_chunks'::regclass
   and attname = 'embedding';
-- expect: vector(1024)

-- 003: versioned embedding metadata columns + HNSW partial index
select column_name
  from information_schema.columns
 where table_name = 'advisor_source_chunks'
   and column_name in (
     'embedding_provider_id','embedding_model_id','embedding_dimension'
   )
 order by column_name;
-- expect: all three present

select indexname, indexdef
  from pg_indexes
 where tablename = 'advisor_source_chunks'
   and indexname = 'advisor_source_chunks_voyage_hnsw_idx';
-- expect: HNSW index whose definition includes the partial predicate
-- on embedding_provider_id = 'voyage', embedding_model_id =
-- 'voyage-4-large', embedding_dimension = 1024, active = true.

-- 003: search function present, stable, and filters on active = true
select pg_get_functiondef(oid)
  from pg_proc
 where proname = 'advisor_search_chunks';
-- expect: definition includes `c.active = true` and the
-- provider/model/dimension filter triple.

-- 004: usage counters table + uniqueness
select relname from pg_class
 where relname = 'advisor_proxy_usage_counters';
-- expect: present, relrowsecurity = true

select indexdef
  from pg_indexes
 where tablename = 'advisor_proxy_usage_counters';
-- expect: a unique index over (operator_id, location_id, tier_id,
-- minute_bucket).
```

### 4d. Rollback option

No advisor DML lands until a separate slice loads JSONL records via
`tool/advisor_corpus prepare-load` artifacts. Until then, the four
migrations are pure DDL and can be reverted by:

1. Dropping the four advisor tables (`advisor_proxy_usage_counters`,
   `advisor_graph_edge_hints`, `advisor_graph_node_seeds`,
   `advisor_source_chunks`, `advisor_source_documents`,
   `advisor_ingestion_runs`) in dependency-respecting order, or
2. Rolling the project back to the pre-apply backup recorded in 4a.

Prefer the backup-based rollback if any operator data has been written
to these tables.

## 5. Out of scope for this readiness doc

- Loading materialized JSONL records into the corpus tables. That is
  the job of a future apply slice (planned post-11a.11b) which will
  run `tool/advisor_corpus prepare-load` against the live DB.
- Loading vectors. That is `tool/advisor_corpus execute-embeddings`
  and depends on `VOYAGE_API_KEY` plus a populated chunk table.
- Applying the AGE projection. That is the 7.57.4 artifact apply step
  and is gated on AGE being available on the target.
- Wiring the proxy to the live `advisor_proxy_usage_counters` table —
  the proxy currently uses `ScaffoldFailingUsageCounterStore` and
  fails closed; a real store implementation will land in a follow-up
  proxy slice.
- Phase 9 RLS enforcement. Today's policies are service-role plus
  global-read placeholders; per-operator enforcement is locked behind
  the Phase 9 auth landing.
