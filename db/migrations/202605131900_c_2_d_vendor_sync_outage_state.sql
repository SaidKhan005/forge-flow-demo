-- Lane C C-2-D — vendor_sync_outage_state (first-failure-of-outage detector).
--
-- Authority:
--   * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-2-D (line 86) —
--     wire `vendor_sync_error_alert` with a first-failure-of-outage
--     detector; per-row email would spam on transients. Operator
--     picked WIRE option (D) in the C-2 matrix.
--   * docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md
--     — draft D rationale + outage-detector design. Operator picks
--     section 2026-05-13.
--   * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables
--     include (operator_id, location_id) + RLS policy stub from
--     creation. Operator-leading B-tree index.
--   * CLAUDE.md "Time Guardrails" — operator-scoped Postgres fact
--     tables store TIMESTAMPTZ (UTC). TIMESTAMP WITHOUT TIME ZONE
--     banned in operator-scoped tables.
--   * Precedent: 202605131700_c_1a_email_event_provider_id.sql for
--     header/comment shape, lock+timeout guardrails, idempotent
--     DDL idiom, and operator approval gate phrasing.
--   * Precedent: 202605040000_phase_8_0_integration_framework.sql
--     for the `(operator_id, location_id)` FK shape + per-tenant
--     RLS policy posture used by sibling fact tables
--     (`connector_sync_log`, `connector_sync_watermark`).
--
-- Why this exists
-- ---------------
-- The `vendor_sync_error_alert` email template (Markdown source at
-- `tool/advisor_proxy/email_templates/vendor_sync_error_alert.md`)
-- promises in its body copy: "This alert fires once per outage." The
-- polling tier (`tool/integration_sync_worker`) writes per-tick
-- `connector_sync_log` rows with `event_kind = 'poll_error'` whenever
-- a vendor adapter fails, but the log on its own has no notion of
-- "outage windows" — a naive per-row email would spam the operator
-- on every transient hiccup.
--
-- This table is the state surface the outage detector uses to
-- enforce "one email per outage". Per `(operator_id, location_id,
-- connection_id)`:
--
--   * `outage_started_at` — when the consecutive-failure streak
--     that justified the email began (the timestamp of the FIRST
--     `poll_error` in the streak, not the Nth that triggered the
--     email).
--   * `consecutive_failure_count` — how many consecutive
--     `poll_error` rows have been observed since the last
--     `poll_success`. Reset to 0 (row deleted) when a `poll_success`
--     arrives.
--   * `notified_at` — when the outage email was enqueued. NULL
--     while the streak is being observed but has not yet crossed
--     the N-failure threshold. Non-null after the email lands in
--     `email_outbox`.
--   * `last_error_message` — the most recent error message
--     surfaced to the email body (`{{errorSummary}}` variable).
--
-- The detector reads the latest `connector_sync_log` rows for the
-- connection, walks them newest-first, and either:
--
--   * Sees a `poll_success` before the N-th `poll_error` → no
--     outage; clear any stale state row.
--   * Sees N consecutive `poll_error` rows → there IS an outage.
--     If no state row exists OR `notified_at IS NULL`, enqueue the
--     email and stamp `notified_at`. If `notified_at IS NOT NULL`,
--     the email has already been emitted for THIS outage window —
--     no-op.
--
-- Schema notes
-- ------------
--   * Primary key is `(connection_id)` because a vendor connection
--     uniquely identifies the (operator, location, vendor, account)
--     tuple; one outage window per connection at a time. operator_id
--     + location_id are denormalised so the table is RLS-ready and
--     the operator-leading B-tree index matches CLAUDE.md "every
--     fact-table B-tree index leads with operator_id" rule.
--
--   * `consecutive_failure_count` is `smallint` because the
--     detector only cares whether the count crosses the threshold
--     (N = 3 in the V1 detector). Values >> threshold are
--     equivalent for decision-making and we never need to count
--     above 32767.
--
--   * No deletion-of-others FK to `connector_connection`: when a
--     connection is deleted we want the cascade behaviour to clean
--     this row up. Mirror the `connector_sync_log` ON DELETE
--     CASCADE pattern.
--
-- RLS posture
-- -----------
-- The detector runs from the integration_sync_worker, which already
-- holds a `TenantTransactionWrapper` and writes
-- `connector_sync_log` / `connector_sync_watermark` per tenant via
-- `runInTenantContext`. The new table mirrors those siblings'
-- per-tenant RLS policy verbatim. Email enqueue itself runs through
-- `email_outbox` whose dispatcher uses `runAsSystem` (the operator
-- column on `email_outbox` is nullable and indexed separately for
-- the system fan-out path); the new state row updates always run
-- under the tenant context the polling tick already established.
--
-- Idempotency
-- -----------
-- CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS + DROP
-- POLICY IF EXISTS / CREATE POLICY pattern make this migration
-- safe to re-apply. The COMMENT ON COLUMN/TABLE replays harmlessly.
-- No DROP, no DELETE, no ALTER COLUMN TYPE on existing tables.
--
-- Lock + timeout guardrails
-- -------------------------
-- CREATE TABLE acquires ACCESS EXCLUSIVE briefly on the new
-- relation only. We bound the wait so a concurrent migration
-- cannot stall behind us. No existing table is touched.
--
-- Operator approval gate
-- ----------------------
-- Per CLAUDE.md "agent-led slices" — schema-touching slices require
-- explicit operator approval before merge regardless of audit
-- verdict. Operator picked WIRE in C-2 matrix 2026-05-13 (recorded
-- on master via PR #619 / decision doc operator picks section).

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── vendor_sync_outage_state ─────────────────────────────────────
--
-- One row per `(operator_id, location_id, connection_id)` while a
-- consecutive-poll-error streak is being observed. Cleared (row
-- deleted) on the next `poll_success` for the same connection.

create table if not exists public.vendor_sync_outage_state (
  operator_id uuid not null,
  location_id uuid not null,
  connection_id uuid not null
    references public.connector_connection(connection_id)
    on delete cascade,
  outage_started_at timestamptz not null,
  consecutive_failure_count smallint not null default 0
    check (consecutive_failure_count >= 0),
  notified_at timestamptz null,
  last_error_message text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (connection_id),
  constraint vendor_sync_outage_state_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.vendor_sync_outage_state is
  'Lane C C-2-D — per-(operator_id, location_id, connection_id) state '
  'surface for the first-failure-of-outage detector that gates the '
  'vendor_sync_error_alert email. One row exists while a consecutive '
  'poll_error streak is being observed; cleared on the next '
  'poll_success.';

comment on column public.vendor_sync_outage_state.outage_started_at is
  'Timestamp of the FIRST poll_error row in the consecutive-failure '
  'streak that justified the alert. Used as {{firstFailureHumanReadable}} '
  'in the rendered email body.';

comment on column public.vendor_sync_outage_state.consecutive_failure_count is
  'Count of consecutive poll_error rows observed since the last '
  'poll_success for this connection. Reset to 0 (row deleted) when a '
  'poll_success arrives. Cap is 32767 (smallint); values >> threshold '
  'are equivalent for the detector decision.';

comment on column public.vendor_sync_outage_state.notified_at is
  'Timestamp the vendor_sync_error_alert email was enqueued for the '
  'current outage window. NULL while the streak has not yet crossed '
  'the threshold. Stamped non-null after the email_outbox INSERT lands. '
  'A retry of the detector for the same outage window finds notified_at '
  'IS NOT NULL and is a natural no-op.';

comment on column public.vendor_sync_outage_state.last_error_message is
  'Most recent error_message from connector_sync_log surfaced to the '
  'email body via the {{errorSummary}} variable. NULL when no error '
  'has been observed yet (transient setup window only).';

-- ─── Operator-leading B-tree index ────────────────────────────────
--
-- CLAUDE.md "every fact-table B-tree index leads with operator_id".
-- The detector reads by `(operator_id, connection_id)` (production
-- query: "any outage state row for this connection on this
-- operator?"), so the index leads with operator_id and includes
-- connection_id second. The primary key already covers the
-- connection-only lookup; this index covers the tenant-scoped scan
-- the per-tenant RLS predicate forces.

create index if not exists vendor_sync_outage_state_operator_idx
  on public.vendor_sync_outage_state (operator_id, connection_id);

-- ─── RLS posture ──────────────────────────────────────────────────
--
-- Mirror the sibling `connector_sync_log_per_tenant_*` policy:
-- service_role gets SELECT / INSERT / UPDATE / DELETE bounded by
-- the operator-context GUCs the tenant transaction establishes.

alter table public.vendor_sync_outage_state enable row level security;

drop policy if exists "vendor_sync_outage_state_per_tenant"
  on public.vendor_sync_outage_state;
create policy "vendor_sync_outage_state_per_tenant"
  on public.vendor_sync_outage_state for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

-- ─── Grants ───────────────────────────────────────────────────────

revoke all on public.vendor_sync_outage_state from public;
grant select, insert, update, delete
  on public.vendor_sync_outage_state to service_role;
grant select, insert, update, delete
  on public.vendor_sync_outage_state to forge_admin;

commit;
