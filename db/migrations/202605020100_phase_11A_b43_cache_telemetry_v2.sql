-- Phase 11A.B43 — cache_telemetry_v2 / corpus_invalidation_events.
--
-- One append-only row per corpus commit so the F&F operations dashboard
-- can correlate prompt-cache hit-rate drops with corpus material changes.
-- Lever 1 (Anthropic prompt caching) keys cache entries on
-- `corpus_version`; when `OperatorScopedCorpusRepository.commitVersion`
-- supersedes the prior version, every dependent prompt-cache entry is
-- invalidated. Recording the event here lets dashboards answer
-- "did cache hit-rate just drop because we shipped a corpus update?"
-- without scraping repository commits.
--
-- Hard rules:
--   * Append-only — no rows are ever updated or deleted.
--   * Fleet-scope — `corpus_versions` has no `operator_id` (the corpus is
--     shared across the fleet), so this audit table also has no
--     operator_id. RLS is intentionally NOT enabled; the table stores no
--     tenant identifiers and is admin-only by GRANT posture.
--   * Behind feature flag — repository writes only fire when the proxy's
--     `cache_telemetry_v2` flag is true. The migration is unconditional
--     so the table exists ahead of the flag flip.

begin;

create extension if not exists pgcrypto;

create table if not exists public.corpus_invalidation_events (
  event_id              uuid primary key default gen_random_uuid(),
  occurred_at           timestamptz not null default now(),
  -- ON DELETE RESTRICT (not CASCADE / SET NULL) so a corpus_versions
  -- delete cannot indirectly mutate this append-only audit table. The
  -- top-level REVOKE on UPDATE/DELETE only blocks direct DML against
  -- this table; FK referential actions bypass those grants because
  -- they fire as system-internal cascades. CASCADE here would let
  -- forge_admin (which holds DELETE on corpus_versions) erase
  -- forensic rows by deleting their parent version, and SET NULL
  -- would silently rewrite superseded_version_id from a real id to
  -- NULL. RESTRICT makes the parent delete fail loudly when any
  -- event references it, which is the correct posture for an audit
  -- log: parents stay around as long as they have history.
  new_version_id        uuid not null
    references public.corpus_versions(version_id) on delete restrict,
  superseded_version_id uuid null
    references public.corpus_versions(version_id) on delete restrict,
  dependent_count       integer not null check (dependent_count >= 0),
  summary               text not null default ''
);

create index if not exists corpus_invalidation_events_occurred_at_idx
  on public.corpus_invalidation_events(occurred_at desc);

create index if not exists corpus_invalidation_events_new_version_id_idx
  on public.corpus_invalidation_events(new_version_id);

comment on table public.corpus_invalidation_events is
  '11A.B43 fleet-scope audit of corpus-version commits. One row per '
  'commitVersion call when cache_telemetry_v2 is enabled. Append-only; '
  'UPDATE/DELETE are revoked from runtime roles.';

comment on column public.corpus_invalidation_events.new_version_id is
  'corpus_versions row id of the newly-active version after the commit.';

comment on column public.corpus_invalidation_events.superseded_version_id is
  'corpus_versions row id of the version that was active before the commit. '
  'NULL when this is the first commit (no prior version).';

comment on column public.corpus_invalidation_events.dependent_count is
  'Count of chunks attached to the superseded version at supersede time '
  '(corpus_version_chunks rows where version_id = superseded_version_id). '
  'Approximates the number of cache entries invalidated by the commit.';

-- Append-only posture. Mirrors the audit_logs pattern in
-- 202604280005: GRANT SELECT/INSERT to forge_admin and service_role,
-- explicitly REVOKE UPDATE/DELETE so a future blanket-grant cannot
-- accidentally weaken the posture without an explicit reviewer notice.
revoke all on public.corpus_invalidation_events from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    execute 'grant select, insert on public.corpus_invalidation_events to forge_admin';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert on public.corpus_invalidation_events to service_role';
  end if;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    execute 'revoke update, delete on public.corpus_invalidation_events from forge_admin';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'revoke update, delete on public.corpus_invalidation_events from service_role';
  end if;
end;
$$;

commit;
