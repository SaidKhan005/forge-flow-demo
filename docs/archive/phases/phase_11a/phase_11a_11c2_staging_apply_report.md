# Phase 11a.11c.2 — Staging cloud apply report

> **SUPERSEDED 2026-04-26.** This report captured Supabase
> CLI/config/link/env/project prerequisites that were missing.
> Postgres host pivoted to Azure DB Flexible Server in
> `11a.11c.4-6`; the Supabase prerequisites are obsolete. Retained
> as Supabase-historical.

**Status:** BLOCKED. Live staging apply cannot proceed from this
environment.

This document is a read-only preflight result. No `supabase` command
was invoked. No `db push` (dry-run or live) was attempted. No live DB
was contacted, no SQL was issued against any project, and no provider
call was made. No secret values are reproduced.

**Generated:** 2026-04-25 (slice 11a.11c.2 staging-apply attempt).

---

## 1. Preflight result (read-only, name-only)

| Check | Result |
|---|---|
| `supabase` CLI on PATH | **MISSING** |
| `supabase/config.toml` | **MISSING** |
| `.supabase/` linked-project marker | **MISSING** |
| `SUPABASE_ACCESS_TOKEN` env name | **MISSING** |
| `SUPABASE_PROJECT_REF` env name | **MISSING** |
| `SUPABASE_DB_URL` env name | **MISSING** |

"Present" only means the env name is exported; "missing" means the
name is not exported. No values were inspected or reproduced. The
staging vs production check (`supabase status` against the linked
project) was not run because nothing is linked.

The state matches the `11a.11b` cloud-DB-apply readiness audit
(`docs/phases/phase_11a/phase_11a_11b_cloud_db_apply_readiness.md`)
exactly — none of the prerequisites have moved since that audit was
recorded.

## 2. Migration files staged for apply (verified locally)

The five lexicographically-ordered migrations under
`supabase/migrations/` that a future `supabase db push` would apply,
in apply order:

| # | File | Purpose |
|---|------|---------|
| 1 | `202604250001_advisor_corpus_storage_schema.sql` | 11a.3 corpus storage scaffold + extensions (vector, pgcrypto, age). |
| 2 | `202604250002_advisor_embedding_contract.sql` | 11a.6a Voyage 1024-dim embedding column lock. |
| 3 | `202604250003_advisor_vector_search.sql` | 11a.8 versioned embedding metadata, HNSW partial index, `advisor_search_chunks` function. |
| 4 | `202604250004_advisor_proxy_usage_counters.sql` | 11a.10b proxy usage counters table + RLS + service-role policy. |
| 5 | `202604250005_advisor_cloud_foundation.sql` | 11a.11c.1 cloud foundation: `operators`, `locations`, `users`, `operator_admins`, partitioned `usage_logs`, `usage_caps`, `proxy_requests`, `feature_flags`, `fx_rates`; composite `(operator_id, location_id)` ownership FKs; RLS + service-role policies on every table. |

The local file list confirms exactly these five files and no extras —
`ls supabase/migrations/` returns them in the order above.

## 3. Blocker (cannot proceed without these)

Live staging apply requires **all** of the following to be present
before `supabase db push --dry-run` can even be attempted. Until these
land, no further staging steps run.

1. **Supabase CLI on PATH.** Install per
   `https://supabase.com/docs/guides/cli`. Required for
   `supabase link`, `supabase db push`, and `supabase status`.
2. **`SUPABASE_ACCESS_TOKEN` exported.** Generate in the Supabase
   dashboard (Account → Access Tokens), then `export
   SUPABASE_ACCESS_TOKEN=...` in the operator's shell.
3. **Staging project provisioned and identified.** Record the staging
   project ref (e.g. `abcdwxyz123456789012`) — distinct from
   production.
4. **Repo linked to the staging project.** From repo root run
   `supabase link --project-ref <staging-ref>`. This produces
   `supabase/config.toml` and `.supabase/` (currently both missing).
5. **`SUPABASE_DB_URL` exported** for the staging project (used by
   the read-only verification SQL in §5 below).
6. **`SUPABASE_PROJECT_REF` exported** for the staging project (used
   by ergonomic CLI invocations).

Until items 1–6 are present, the steps in §4–§7 below cannot start
and this slice remains BLOCKED.

## 4. Steps NOT executed (because of §3)

The following steps were defined by the slice but were intentionally
skipped because the preflight failed. They are documented here so the
unblock work can pick them up verbatim once §3 is resolved.

```
# 4a. Confirm linked project is staging (refuse to proceed if ambiguous)
supabase status

# 4b. Dry-run apply (must list exactly the five migrations in §2)
supabase db push --dry-run

# 4c. Live apply against STAGING ONLY
supabase db push

# 4d. Optional explicit psql apply (only if a more controlled path is needed)
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/202604250001_advisor_corpus_storage_schema.sql
# ...repeat for 002, 003, 004, 005 in order...
```

None of these were run. No staging or production state was modified.

## 5. Read-only verification SQL (NOT executed)

These queries would be run against staging via `psql "$SUPABASE_DB_URL"`
once §4c succeeds. They prove the structural invariants every accepted
slice has so far asserted at the migration-file level.

```sql
-- 5a. Extensions
select extname from pg_extension
 where extname in ('vector','pgcrypto','age')
 order by extname;
-- expect: vector, pgcrypto. age only if intended for staging.

-- 5b. Advisor corpus / proxy / cloud-foundation tables present with RLS
select relname, relrowsecurity
  from pg_class
 where relkind in ('r','p')  -- ordinary + partitioned
   and relname in (
     -- 001
     'advisor_ingestion_runs',
     'advisor_source_documents',
     'advisor_source_chunks',
     'advisor_graph_node_seeds',
     'advisor_graph_edge_hints',
     -- 004
     'advisor_proxy_usage_counters',
     -- 005 cloud foundation
     'operators',
     'locations',
     'users',
     'operator_admins',
     'usage_logs',
     'usage_logs_default',
     'usage_caps',
     'proxy_requests',
     'feature_flags',
     'fx_rates'
   )
 order by relname;
-- expect: all sixteen present, relrowsecurity = true on every row.

-- 5c. Service-role policy stubs present on every cloud-foundation table
select schemaname, tablename, policyname, roles
  from pg_policies
 where schemaname = 'public'
   and (
     tablename in (
       'operators','locations','users','operator_admins',
       'usage_logs','usage_logs_default','usage_caps',
       'proxy_requests','feature_flags','fx_rates'
     )
   )
 order by tablename, policyname;
-- expect: every table appears with a `*_service_role_all` policy
-- whose `roles` includes `service_role`.

-- 5d. Voyage embedding column dimension and HNSW partial index
select format_type(atttypid, atttypmod) as type
  from pg_attribute
 where attrelid = 'public.advisor_source_chunks'::regclass
   and attname = 'embedding';
-- expect: vector(1024)

select indexname, indexdef
  from pg_indexes
 where tablename = 'advisor_source_chunks'
   and indexname = 'advisor_source_chunks_voyage_hnsw_idx';
-- expect: HNSW partial index with the provider/model/dim/active filter.

select pg_get_functiondef(oid)
  from pg_proc
 where proname = 'advisor_search_chunks';
-- expect: definition includes c.active = true and the
-- provider/model/dimension filter triple.

-- 5e. usage_logs is declaratively partitioned by period_start
select c.relname, p.partstrat, a.attname as partition_key
  from pg_class c
  join pg_partitioned_table p on p.partrelid = c.oid
  join pg_attribute a
    on a.attrelid = c.oid
   and a.attnum = any(p.partattrs::int[])
 where c.relname = 'usage_logs';
-- expect: relname=usage_logs, partstrat='r' (range),
--         partition_key='period_start'.

select c.relname as partition
  from pg_inherits i
  join pg_class c on c.oid = i.inhrelid
  join pg_class p on p.oid = i.inhparent
 where p.relname = 'usage_logs';
-- expect: at least usage_logs_default.

-- 5f. Composite ownership FKs on cloud-foundation tables
select conrelid::regclass as table,
       conname,
       pg_get_constraintdef(oid) as definition
  from pg_constraint
 where contype = 'f'
   and conrelid::regclass::text in (
     'public.operators',
     'public.usage_logs',
     'public.usage_caps',
     'public.proxy_requests',
     'public.feature_flags'
   )
 order by table, conname;
-- expect: each of the five tables has a FK clause matching
-- `FOREIGN KEY (operator_id, ...) REFERENCES public.locations(operator_id, location_id)` —
-- proving the cross-tenant `(operator_a, location_b)` mismatch is
-- rejected at the DB layer (P1 review-fix from 11a.11c.1).

-- 5g. feature_flags scope-shape CHECK + tightened location-scope index
select pg_get_constraintdef(oid)
  from pg_constraint
 where conrelid = 'public.feature_flags'::regclass
   and contype = 'c'
   and pg_get_constraintdef(oid) ilike '%operator_id IS NOT NULL%';
-- expect: includes `(location_id IS NULL OR operator_id IS NOT NULL)`.

select indexname, indexdef
  from pg_indexes
 where tablename = 'feature_flags'
   and indexname = 'feature_flags_location_scope_idx';
-- expect: predicate ends with `WHERE ((operator_id IS NOT NULL) AND
-- (location_id IS NOT NULL))`.

-- 5h. No `timestamp without time zone` columns in cloud-foundation tables
select c.relname as table_name, a.attname as column_name,
       format_type(a.atttypid, a.atttypmod) as type
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
 where c.relname in (
   'operators','locations','users','operator_admins',
   'usage_logs','usage_caps','proxy_requests',
   'feature_flags','fx_rates'
 )
   and a.attnum > 0
   and not a.attisdropped
   and format_type(a.atttypid, a.atttypmod) = 'timestamp without time zone';
-- expect: zero rows.
```

None of these were run. Every "expect" line is a hypothesis that the
unblock work must verify against staging.

## 6. AGE smoke check (NOT executed)

If `pg_extension` shows `age` after §4c, the smoke query below proves
graph traversal is reachable without modifying any state:

```sql
load 'age';
set search_path = ag_catalog, "$user", public;

select * from cypher('test_graph', $$
  create (n:smoke {ts: 1})
  return n
$$) as (n agtype);

-- Then drop the smoke graph so verification leaves no residue:
select * from drop_graph('test_graph', true);
```

If `age` is unavailable on the staging tier, do **not** fake success —
record the result as "AGE unavailable on staging; Q12 vector-only
fallback flag becomes the launch posture per the tracker's `11a.11c`
acceptance language" and proceed without enabling AGE-dependent slices.

This block was not run.

## 7. Acceptance for this slice

- [x] Preflight executed read-only with no live commands.
- [x] Missing prerequisites produced a BLOCKED report with no live
      mutation. (See §1 + §3.)
- [x] Report doc contains no secret values.
- [x] No production apply, provider call, runtime code change,
      migration edit, tracker change, or commit.
- [ ] If prerequisites pass, all five migrations apply to staging in
      order. — **Deferred to a future run; blocked by §3.**
- [ ] Staging verification proves pgvector, pgcrypto, schema tables,
      RLS, service-role policies, vector search objects, cloud
      foundation constraints, and partitioning. — **Deferred to a
      future run; SQL ready in §5.**
- [ ] AGE is either verified with a minimal smoke query or explicitly
      documented as unavailable with fallback required. — **Deferred
      to a future run; smoke query ready in §6.**

## 8. Out of scope

- Production apply. This slice is staging-only by hard constraint.
- Loading materialised JSONL records, vectors, or AGE projection
  artifacts. Those are downstream slices that depend on this apply
  succeeding.
- Wiring the proxy to live `usage_logs` / `proxy_requests`. That is
  `11a.11d`.
- Phase 9 RLS enforcement. Today's policies are service-role-only
  stubs; per-operator enforcement lands in Phase 9.
