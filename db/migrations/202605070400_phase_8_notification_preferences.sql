-- Phase 8 W2.B - operator-web notification preferences.
--
-- Authority:
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--     (RLS-Ready Schema, wrapper-only RLS posture, tenant-leading
--      B-tree indexes).
--   * docs/POST_HARDENING_FOLLOWUPS.md "P0 - Production1 Migration
--     Apply Gap" (this migration appended to the gap table).
--   * Master plan: W2.B "operator-web.settings-notifications-config"
--     (notification event catalog + per-channel + per-scope toggles).
--
-- Adds public.notification_preferences: operator-scoped + per-user
-- per-event-key per-channel per-scope row. Absence of a row means the
-- catalog default applies; presence with enabled=true is an explicit
-- opt-in, enabled=false is an explicit opt-out.
--
-- Schema follows the durable contract:
--   * synthetic UUID primary key (no client-side UUIDs; PG generates)
--   * UNIQUE NULLS NOT DISTINCT on the 6-tuple (operator_id, user_id,
--     event_key, channel, scope_kind, scope_id) so a (operator) scope
--     row with scope_id=NULL still uniques cleanly.
--   * channel enum (push / email / inbox).
--   * scope enum (operator / location); scope_id NULL when scope_kind
--     is 'operator', UUID when scope_kind is 'location'.
--   * created_at / updated_at TIMESTAMPTZ per the time guardrails.
--
-- Hard rules carried verbatim from CLAUDE.md / phase docs:
--
--   * **HP #4 RLS-Ready Schema.** Table carries operator_id from
--     creation; tenant-leading B-tree indexes; per-tenant +
--     per-user RLS policy enabled at table-creation time.
--   * **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Policy body
--     calls public.app_current_operator() / public.app_current_actor_user().
--     No bare current_setting(...) reads.
--   * **Time guardrails.** All temporal columns are TIMESTAMPTZ.
--   * **Idempotent migration.** if not exists on every CREATE,
--     drop policy if exists before create policy. Re-applying the
--     migration is a no-op.
--   * **No client-side UUIDs.** id default is gen_random_uuid()
--     server-side; clients PUT by event/channel/scope, not by id.

begin;

-- ─── notification_preferences ──────────────────────────────────────
create table if not exists public.notification_preferences (
  id          uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  user_id     uuid not null,
  event_key   text not null,
  channel     text not null check (channel in ('push', 'email', 'inbox')),
  scope_kind  text not null check (scope_kind in ('operator', 'location')),
  scope_id    uuid null,
  enabled     boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.notification_preferences is
  'Phase 8 W2.B - operator-scoped per-user per-event-key per-channel '
  'per-scope notification preference rows. Absence of a row means the '
  'catalog default applies. Synthetic UUID id with UNIQUE NULLS NOT '
  'DISTINCT on the 6-tuple so (operator) scope rows with scope_id=NULL '
  'still uniques cleanly. RLS: tenant + per-user (operator_id = '
  'app_current_operator() AND user_id = app_current_actor_user()).';

-- One row per (operator_id, user_id, event_key, channel, scope_kind,
-- scope_id). NULLS NOT DISTINCT lets us treat (scope_kind=operator,
-- scope_id=NULL) as a single unique key rather than allowing
-- duplicates via NULL inequality.
create unique index if not exists
  notification_preferences_unique_event_channel_scope_idx
  on public.notification_preferences (
    operator_id, user_id, event_key, channel, scope_kind, scope_id
  )
  nulls not distinct;

-- Operator-leading B-tree indexes per CI lint (CLAUDE.md hard rule).
create index if not exists notification_preferences_operator_user_idx
  on public.notification_preferences (operator_id, user_id);
create index if not exists notification_preferences_operator_event_idx
  on public.notification_preferences (operator_id, event_key);

-- RLS - wrapper-only per Phase 9.0Σ.b item 4.
alter table public.notification_preferences enable row level security;

drop policy if exists "notification_preferences_per_operator_per_user"
  on public.notification_preferences;
create policy "notification_preferences_per_operator_per_user"
  on public.notification_preferences for all to service_role
  using (
    operator_id = public.app_current_operator()
    and user_id = public.app_current_actor_user()
  )
  with check (
    operator_id = public.app_current_operator()
    and user_id = public.app_current_actor_user()
  );

revoke all on public.notification_preferences from public;
grant select, insert, update, delete
  on public.notification_preferences to service_role;
grant select, insert, update, delete
  on public.notification_preferences to forge_admin;

commit;
