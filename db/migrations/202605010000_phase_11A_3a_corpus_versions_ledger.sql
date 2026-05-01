-- Phase 11A.3a — Corpus admin ledger.
--
-- Adds a `corpus_versions` ledger plus a many-to-many membership
-- table so the F&F admin Corpus screen can:
--
--   * list every corpus version with its actor + summary,
--   * fetch the chunks that belong to one version (membership is
--     resolved through the join table, not by overwriting per-chunk
--     pointers — the same chunk row may legitimately be a member of
--     several versions when its content is unchanged),
--   * stamp prior chunks `superseded_at` when a new version commits,
--   * roll back to a prior version by writing a new row whose
--     `rollback_of` points at the target.
--
-- Per CLAUDE.md (Postgres host = Azure DB Flexible Server PG 16) and
-- the cloud foundation migration `202604250001`, the corpus tables
-- live in `public` and use UUIDs from `pgcrypto`.

create extension if not exists pgcrypto;

create table if not exists public.corpus_versions (
  version_id   uuid primary key default gen_random_uuid(),
  created_by   uuid,
  created_at   timestamptz not null default now(),
  summary      text not null default '',
  rollback_of  uuid references public.corpus_versions(version_id)
                  on delete set null,
  superseded_at timestamptz
);

create index if not exists corpus_versions_version_id_idx
  on public.corpus_versions(version_id);

create index if not exists corpus_versions_created_at_idx
  on public.corpus_versions(created_at desc);

-- Per-chunk pointer to the version that FIRST introduced the chunk.
-- Nullable so existing rows from `tool/advisor_corpus/main.dart
-- materialize` runs (which pre-date the admin console) keep loading
-- without a backfill. After 11A.3a, membership in a corpus version is
-- determined by [corpus_version_chunks], NOT by this column — leaving
-- it set lets the admin trace where a chunk first appeared, but the
-- column is informational only.
do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'advisor_source_chunks'
      and column_name = 'version_id'
  ) then
    execute 'alter table public.advisor_source_chunks '
            'add column version_id uuid references public.corpus_versions(version_id) '
            'on delete set null';
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'advisor_source_chunks'
      and column_name = 'superseded_at'
  ) then
    execute 'alter table public.advisor_source_chunks '
            'add column superseded_at timestamptz';
  end if;
end;
$$;

create index if not exists advisor_source_chunks_version_idx
  on public.advisor_source_chunks(version_id);

create index if not exists advisor_source_chunks_superseded_at_idx
  on public.advisor_source_chunks(superseded_at);

-- Many-to-many membership: a single chunk row stays attached to every
-- version that includes it. Without this table, `commitVersion`
-- reassigning `version_id` on the chunk row would destroy historical
-- snapshots — v1 with A+B and v2 keeping A would lose A from v1, and
-- a rollback to v1 could only ever recover B. Membership through this
-- table preserves the per-version snapshot for audit + rollback.
create table if not exists public.corpus_version_chunks (
  version_id uuid not null references public.corpus_versions(version_id)
                on delete cascade,
  chunk_id   text not null references public.advisor_source_chunks(chunk_id)
                on delete cascade,
  primary key (version_id, chunk_id)
);

create index if not exists corpus_version_chunks_chunk_id_idx
  on public.corpus_version_chunks(chunk_id);

create index if not exists corpus_version_chunks_version_id_idx
  on public.corpus_version_chunks(version_id);

-- Cross-tenant F&F admin idempotency cache. The cloud-foundation
-- `proxy_requests` table is keyed on `(operator_id, location_id,
-- idempotency_key)` with NOT NULL FK columns and is scoped to
-- per-operator request flows; the corpus admin paths (and future
-- cross-tenant F&F admin POSTs) run across the fleet and do not
-- carry an operator/location context, so they need their own
-- (route, idempotency_key) cache. Keeping the cross-tenant cache
-- in a dedicated table also preserves the cloud-foundation table's
-- tenant-leading PK (`(operator_id, location_id, request_id)`)
-- which the 11a.11c.6 RLS-performance hardening relies on.
create table if not exists public.admin_idempotency_cache (
  route             text not null,
  idempotency_key   text not null,
  response_payload  jsonb not null,
  created_at        timestamptz not null default now(),
  primary key (route, idempotency_key)
);

create index if not exists admin_idempotency_cache_created_at_idx
  on public.admin_idempotency_cache(created_at desc);

alter table public.corpus_versions enable row level security;
alter table public.corpus_version_chunks enable row level security;
alter table public.admin_idempotency_cache enable row level security;

-- Admin-only writes. The proxy `/v1/admin/corpus/*` routes run through
-- `OperatorScopedRepository.withSystem`, which executes
-- `set local role forge_admin`. `forge_admin` carries `BYPASSRLS` so
-- the policies below are a backstop; non-admin roles cannot read or
-- write the ledger directly. The explicit `GRANT` block below covers
-- the table-privilege half — `BYPASSRLS` skips row policies, but it
-- does not grant table privileges, so `forge_admin` still needs the
-- usual SELECT/INSERT/UPDATE/DELETE to operate.
--
-- Postgres has no `CREATE POLICY IF NOT EXISTS`, so each policy is
-- preceded by `DROP POLICY IF EXISTS` to keep the migration safe to
-- re-run.
drop policy if exists "corpus_versions_service_role_all"
  on public.corpus_versions;
create policy "corpus_versions_service_role_all"
  on public.corpus_versions
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists "corpus_version_chunks_service_role_all"
  on public.corpus_version_chunks;
create policy "corpus_version_chunks_service_role_all"
  on public.corpus_version_chunks
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists "admin_idempotency_cache_service_role_all"
  on public.admin_idempotency_cache;
create policy "admin_idempotency_cache_service_role_all"
  on public.admin_idempotency_cache
  for all
  to service_role
  using (true)
  with check (true);

-- Table grants for the runtime roles. Mirrors the pattern in
-- `db/migrations/202604280010_*` (Phase 9.0Σ.k rollup tables): the
-- `forge_admin` role drives admin paths via `withSystem`, and the
-- `service_role` covers Supabase-style anon-key reads when the row
-- policy permits. Both roles are no-ops when the database does not
-- exist yet (e.g. local SQLite tests), so the GRANT statements are
-- guarded by an exists check.
--
-- Note: `advisor_source_chunks` predates the `forge_admin` role
-- (its original migration `202604250001` only sets up service_role
-- RLS policies). The corpus admin repository runs reads + writes on
-- that table through `withSystem`, which `set local role
-- forge_admin` — `BYPASSRLS` skips row policies but does NOT confer
-- table privileges. Issuing the grant here keeps the corpus chunk
-- access live without retroactively editing the frozen
-- cloud-foundation migration.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    execute 'grant select, insert, update, delete on public.corpus_versions to forge_admin';
    execute 'grant select, insert, update, delete on public.corpus_version_chunks to forge_admin';
    execute 'grant select, insert, update, delete on public.admin_idempotency_cache to forge_admin';
    execute 'grant select, insert, update, delete on public.advisor_source_chunks to forge_admin';
    execute 'grant select on public.advisor_source_documents to forge_admin';
    execute 'grant select on public.advisor_ingestion_runs to forge_admin';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert, update, delete on public.corpus_versions to service_role';
    execute 'grant select, insert, update, delete on public.corpus_version_chunks to service_role';
    execute 'grant select, insert, update, delete on public.admin_idempotency_cache to service_role';
  end if;
end;
$$;

comment on table public.corpus_versions is
  '11A.3a corpus admin ledger. One row per markdown corpus snapshot the F&F admin commits or rolls back to. `rollback_of` points at the version this row reverted to; NULL on plain commits.';
comment on column public.corpus_versions.summary is
  'Operator-supplied or auto-generated description of the change ("Updated methodology seed, 12 chunks").';
comment on column public.corpus_versions.superseded_at is
  'Set when a later version commits. NULL on the current active version. The admin screen sorts current-first by COALESCE(superseded_at, ''infinity'') DESC.';
comment on table public.corpus_version_chunks is
  '11A.3a corpus version membership join. A single chunk row may belong to many corpus versions when its content is unchanged across snapshots; the join table preserves per-version membership without overwriting per-chunk pointers.';
comment on table public.admin_idempotency_cache is
  '11A.3a cross-tenant F&F admin idempotency cache, keyed on (route, idempotency_key). Distinct from public.proxy_requests which is per-(operator_id, location_id) and inappropriate for admin paths that do not carry tenant scope.';
comment on column public.advisor_source_chunks.version_id is
  '11A.3a — corpus version that FIRST introduced this chunk. NULL on rows seeded before the admin ledger landed. Informational only after 11A.3a; membership is resolved through corpus_version_chunks.';
comment on column public.advisor_source_chunks.superseded_at is
  '11A.3a — set when the chunk no longer belongs to the active corpus snapshot. NULL on chunks that are part of the active version''s membership set.';
