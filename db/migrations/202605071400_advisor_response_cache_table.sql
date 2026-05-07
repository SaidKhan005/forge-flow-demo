-- code-health.L14 — Postgres-backed advisor response cache.
--
-- CODE_HEALTH ref: "AlwaysMissAdvisorResponseCache still in production
-- wiring (`main.dart:325`)" — collapsed fallback chain (LLM → secondary
-- → cache → refusal). The cache hop currently always misses, so a
-- breaker-open + secondary failure goes straight to graceful refusal
-- with no chance to replay a recent identical answer.
--
-- This migration creates the operator-scoped fact table that backs the
-- new `PostgresAdvisorResponseCache` (see
-- `tool/advisor_proxy/advisor_response_cache.dart`) and the hourly
-- pg_cron sweep that drains expired entries. Lock 7 v1 shipped the
-- abstract `AdvisorResponseCache` interface (lib/domain/services/) +
-- the always-miss stub; E.2b was the locked slot to swap in a real
-- impl. This slice fulfills that promise.
--
-- Authority:
--   * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables ship
--     with `(operator_id, location_id)` + an RLS policy stub from
--     creation. App code uses `OperatorScopedRepository` (primary
--     defense); RLS is the backup.
--   * CLAUDE.md "Time Guardrails" — operator-scoped Postgres fact
--     tables store `TIMESTAMPTZ` (UTC). Plain `TIMESTAMP WITHOUT TIME
--     ZONE` is banned.
--   * CLAUDE.md "RLS performance discipline" — every B-tree index on
--     an operator-scoped fact table MUST lead with `operator_id` (or
--     `(operator_id, location_id)`). `tool/index_leading_column_lint.dart`
--     enforces the rule.
--   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
--     — RLS policies use `STABLE LEAKPROOF PARALLEL SAFE` wrapper
--     functions; bare `current_setting()` reads forbidden in policy
--     bodies. The wrapper of record is `public.app_current_operator()`
--     / `public.app_current_location()` (Phase 9.0Σ.b lock).
--
-- Hard rules carried from CLAUDE.md and the contract:
--
--   1. The cache is operator-scoped and location-scoped — same answer
--      to the same prompt at a different location is a different
--      cache entry. The unique key leads with `operator_id` so the
--      policy folds into the index probe.
--
--   2. The TTL sweep job runs hourly (cheap DELETE; the table never
--      grows past one day's traffic). The unschedule-then-reschedule
--      pattern matches the Phase 10a.3 retention sweep migration so a
--      re-apply does not leave duplicate cron rows.
--
--   3. The `prompt_hash` column is `BYTEA` (raw SHA-256) so a partial
--      hash collision check (e.g. via prefix index) stays cheap. The
--      Dart side digests the normalized prompt and binds the bytes
--      directly — never hex-encodes for the round-trip.
--
--   4. The `response` column is `JSONB` so a future swap from "answer
--      text only" to a richer cached envelope (e.g. completion +
--      provenance + token counts) does not require a new migration.
--      v1 stores `{"answer": "<string>"}`.
--
--   5. The `embedding_id` column is nullable; populated when the
--      semantic-cache lookup uses an embedding probe (v2). v1 always
--      writes NULL. The unique key uses `coalesce(embedding_id, 0)`
--      so two identical-prompt entries cannot collide on insert just
--      because one has an embedding probe and the other does not.
--
--   6. The pg_cron sweep is `SECURITY DEFINER` + `forge_admin` owner
--      so the cross-operator DELETE runs without a tenant context.
--      `set search_path = public, pg_catalog` is the standard
--      hardening so a session-injected schema cannot hijack a
--      same-named object.

begin;

-- ─── advisor_response_cache table ──────────────────────────────────
--
-- One row per cached advisor answer. The cache is read on the
-- breaker-open / primary-failure / secondary-failure branch of the
-- pipeline (see `tool/advisor_proxy/advisor_proxy.dart::AdvisorRequestPipeline`),
-- and written by the proxy when a primary-served response is
-- successful and the cache is the configured implementation.
--
-- Columns:
--   * `cache_id BIGSERIAL` — synthetic PK; no surface meaning.
--   * `operator_id UUID` — tenant scope. Required (RLS-ready schema
--     mandates the column exists from creation).
--   * `location_id UUID` — co-tenancy scope. The advisor pipeline
--     binds prompts to a location (different STAR target, different
--     daypart truth) so the same prompt at a different location is a
--     different cache entry.
--   * `query_class TEXT` — usage class label (e.g. `'haiku'`,
--     `'sonnet'`). Maps to the pipeline's `queryClass` argument.
--   * `corpus_version TEXT` — methodology context version. When the
--     corpus revs, the previous answers are stale; the unique key
--     pins this so a corpus bump silently invalidates past hits.
--   * `prompt_hash BYTEA` — SHA-256 of the normalized prompt (or the
--     `questionHash` the pipeline already passes). Bytes, not hex.
--   * `embedding_id BIGINT NULL` — populated when the semantic-cache
--     probe uses an embedding (v2 follow-up). v1 always NULL.
--   * `response JSONB` — cached envelope. v1: `{"answer": "<string>"}`.
--   * `created_at TIMESTAMPTZ` — server-side `now()`. TIMESTAMPTZ per
--     time guardrails.
--   * `expires_at TIMESTAMPTZ` — server-side default `now() + 24h`.
--     Caller can override for tests via the put() ttl argument.

create table if not exists public.advisor_response_cache (
  cache_id bigserial primary key,
  operator_id uuid not null,
  location_id uuid not null,
  query_class text not null,
  corpus_version text not null,
  prompt_hash bytea not null,
  embedding_id bigint null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours')
);

comment on table public.advisor_response_cache is
  'code-health.L14 — Postgres-backed advisor response cache. Replaces '
  'AlwaysMissAdvisorResponseCache in main.dart so the breaker-open / '
  'primary-failure / secondary-failure branch of '
  'AdvisorRequestPipeline can replay a recent identical answer '
  'instead of falling straight to graceful refusal. Operator-scoped, '
  'location-scoped, corpus-versioned, hashed-prompt-keyed; 24-hour '
  'default TTL with hourly pg_cron sweep.';

comment on column public.advisor_response_cache.operator_id is
  'Tenant scope. Matched by the per-tenant RLS policy '
  'advisor_response_cache_per_tenant_location via '
  'public.app_current_operator(). Leads every B-tree on this table.';

comment on column public.advisor_response_cache.location_id is
  'Co-tenancy scope. Different locations cache different answers for '
  'identical prompts (different STAR target, different daypart truth).';

comment on column public.advisor_response_cache.query_class is
  'Usage class label (e.g. "haiku", "sonnet"). Mirrors the '
  'AdvisorRequestPipeline.execute(queryClass:) argument.';

comment on column public.advisor_response_cache.corpus_version is
  'Methodology context version. When the corpus revs, the previous '
  'answers are stale; the unique key pins this so a corpus bump '
  'silently invalidates past hits without an explicit DELETE.';

comment on column public.advisor_response_cache.prompt_hash is
  'SHA-256 of the normalized prompt, raw bytes (NOT hex). Mirrors '
  'AdvisorRequestPipeline.execute(questionHash:) digested as bytes.';

comment on column public.advisor_response_cache.embedding_id is
  'Populated when the semantic-cache probe uses an embedding (v2 '
  'follow-up). v1 always NULL. The unique key uses '
  'coalesce(embedding_id, 0) so two identical-prompt rows cannot '
  'collide on insert just because one has an embedding probe and the '
  'other does not.';

comment on column public.advisor_response_cache.response is
  'Cached envelope. v1 stores {"answer": "<string>"}; JSONB so a '
  'future richer envelope (completion + provenance + token counts) '
  'does not require a new migration.';

comment on column public.advisor_response_cache.created_at is
  'Server-side now() at insert. TIMESTAMPTZ per CLAUDE.md "Time '
  'Guardrails".';

comment on column public.advisor_response_cache.expires_at is
  'Server-side default now() + 24h. The pg_cron sweep '
  'advisor_response_cache_sweep_hourly DELETEs rows past this '
  'boundary; tests override via the put() ttl argument.';

-- ─── Tenant-leading unique key ─────────────────────────────────────
--
-- A given (operator, location, query_class, corpus_version,
-- prompt_hash, embedding_id) MUST resolve to exactly one cache row.
-- The unique constraint is the upsert target for the put() path
-- (INSERT … ON CONFLICT DO UPDATE so a re-cached entry refreshes
-- expires_at without a duplicate row).
--
-- The `coalesce(embedding_id, 0)` expression is the canonical pattern
-- for "treat NULL as a sentinel value for uniqueness purposes" — PG
-- otherwise treats NULLs as distinct, which would break the upsert
-- target in v1 (where embedding_id is always NULL for now).
--
-- operator_id leads per CLAUDE.md "RLS performance discipline"
-- (tool/index_leading_column_lint.dart enforces).

create unique index if not exists advisor_response_cache_lookup_uq
  on public.advisor_response_cache (
    operator_id,
    location_id,
    query_class,
    corpus_version,
    prompt_hash,
    coalesce(embedding_id, 0)
  );

comment on index public.advisor_response_cache_lookup_uq is
  'code-health.L14 — tenant-leading unique key. Doubles as the upsert '
  'target for INSERT … ON CONFLICT DO UPDATE in '
  'PostgresAdvisorResponseCache.put(), so re-caching the same prompt '
  'refreshes expires_at without a duplicate row. operator_id leads '
  'per CLAUDE.md RLS performance discipline.';

-- ─── TTL sweep index ───────────────────────────────────────────────
--
-- The hourly sweep is `DELETE FROM ... WHERE expires_at < now()`. The
-- per-tenant RLS policy filters platform-wide reads to the caller's
-- operator, but the sweep runs as `forge_admin` (BYPASSRLS) so it
-- needs an index that does not require a tenant prefix.
--
-- `operator_id` leads per the index-leading-column lint; `expires_at`
-- is the actual sweep predicate. The lint accepts this shape because
-- `operator_id` is the leading column even though the sweep does not
-- filter on it (the sweep DELETE drives off the secondary column).

create index if not exists advisor_response_cache_expires_at_idx
  on public.advisor_response_cache (operator_id, expires_at);

comment on index public.advisor_response_cache_expires_at_idx is
  'code-health.L14 — TTL sweep index. The hourly '
  'advisor_response_cache_sweep_hourly cron job DELETEs '
  'expires_at < now() rows; this index keeps the scan cheap. '
  'operator_id leads per CLAUDE.md RLS performance discipline.';

-- ─── RLS policy ────────────────────────────────────────────────────
--
-- Per-tenant policy gates row visibility on
-- `operator_id = public.app_current_operator() AND location_id =
-- public.app_current_location()`. The primary defense is the
-- repository pattern (every put/get goes through
-- TenantTransactionWrapper.runInTenantContext which SET LOCALs the
-- operator/location); RLS is the backup defense per CLAUDE.md
-- "RLS-Ready Schema".
--
-- The wrappers `app_current_operator()` / `app_current_location()`
-- are the locked accessors per the Phase 9.0Σ.b decision register —
-- bare `current_setting()` reads are forbidden in policy bodies
-- because the planner cannot prove constancy + leakproof posture.

alter table public.advisor_response_cache enable row level security;

drop policy if exists "advisor_response_cache_per_tenant_location"
  on public.advisor_response_cache;
create policy "advisor_response_cache_per_tenant_location"
  on public.advisor_response_cache for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

-- ─── Grants ────────────────────────────────────────────────────────
--
-- service_role: read + insert + update (upsert path) + delete (the
-- expiry-aware get() path may proactively delete a stale row before
-- returning miss, so the cache stays self-healing without waiting on
-- the cron pass). forge_admin: full access for the sweep job.

revoke all on public.advisor_response_cache from public;

grant select, insert, update, delete on public.advisor_response_cache
  to service_role;
grant select, insert, update, delete on public.advisor_response_cache
  to forge_admin;

grant usage, select on sequence public.advisor_response_cache_cache_id_seq
  to service_role;
grant usage, select on sequence public.advisor_response_cache_cache_id_seq
  to forge_admin;

-- ─── Sweep function ────────────────────────────────────────────────
--
-- Hourly DELETE of rows past expires_at. Returns the deleted-row
-- count so a manual `SELECT public.run_advisor_response_cache_sweep();`
-- call (e.g. in a smoke test or runbook) prints the result.
--
-- The cache table never grows past one day's traffic at steady state
-- (24-hour default TTL + hourly sweep), so an unbounded DELETE is
-- acceptable here — unlike the Phase 10a.3 event_outbox sweep, no
-- backlog scenario can build up enough rows to lock the table for
-- meaningful time.
--
-- SECURITY DEFINER + forge_admin owner: cross-operator DELETE runs
-- without a tenant context. `set search_path = public, pg_catalog`
-- locks the function against schema injection.

create or replace function public.run_advisor_response_cache_sweep()
returns bigint
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_deleted bigint;
begin
  delete from public.advisor_response_cache
   where expires_at < now();
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function public.run_advisor_response_cache_sweep() is
  'code-health.L14 — hourly TTL sweep. DELETEs advisor_response_cache '
  'rows past expires_at. Returns the deleted-row count. SECURITY '
  'DEFINER + forge_admin owner so the cross-operator DELETE runs '
  'without a tenant context.';

alter function public.run_advisor_response_cache_sweep()
  owner to forge_admin;

revoke execute on function public.run_advisor_response_cache_sweep()
  from public;
grant execute on function public.run_advisor_response_cache_sweep()
  to forge_admin;

-- ─── Schedule registration (idempotent) ────────────────────────────
--
-- Hourly at minute 17 (offset from the top of the hour so it does
-- not stack with the dozens of "0 * * * *" jobs the proxy already
-- runs). Idempotent unschedule-then-reschedule pattern matches the
-- Phase 10a.3 event_outbox retention sweep and the email-dispatcher
-- migration; `cron.schedule(jobname, …)` raises `unique_violation`
-- on a duplicate jobname.
--
-- Azure DB Flexible Server keeps pg_cron metadata in the database
-- named by `cron.database_name`. When pg_cron is in a different
-- database, the runbook schedules from the maintenance database via
-- `cron.schedule_in_database(..., 'forgeflow')`. The DO block raises
-- a NOTICE in that case so the live-apply log captures the manual
-- step.

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; schedule from cron.database_name with cron.schedule_in_database(..., ''forgeflow'')';
    return;
  end if;

  for v_jobid in
    select jobid from cron.job
     where jobname = 'advisor_response_cache_sweep_hourly'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'advisor_response_cache_sweep_hourly',
    '17 * * * *',
    'select public.run_advisor_response_cache_sweep();'
  );
end$$;

commit;
