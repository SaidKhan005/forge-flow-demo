-- Lane C C-1a — email_event.provider_event_id + partial UNIQUE INDEX.
--
-- Authority:
--   * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-1a (line 82) —
--     prep migration for SendGrid Event Webhook idempotency; operator
--     Path A pick 2026-05-13.
--   * docs/archive/_execution/lane_c_parity/03_execution_slices.md "Slice C-1
--     — SendGrid Event Webhook receiver" (line 9-29) — the receiver
--     relies on Postgres-enforced uniqueness for duplicate-event
--     rejection via ON CONFLICT DO NOTHING.
--   * CLAUDE.md "RLS-Ready Schema" — email_event is operator-scoped
--     via FK join through email_outbox.operator_id. This migration
--     does NOT change that RLS posture: no new policy, no new
--     operator_id column, no GRANT changes.
--   * CLAUDE.md "Time Guardrails" — temporal columns elsewhere stay
--     TIMESTAMPTZ; the new column is text (provider-issued opaque
--     identifier), so no time policy applies.
--   * Precedent: 202605131600_b2_1_default_role_catalog_versions.sql
--     for header/comment shape, lock+timeout guardrails, idempotent
--     DDL idiom, and operator approval gate phrasing.
--   * Precedent: 202605131030_b11_1_auth_handoff_codes.sql for the
--     idempotent CREATE TABLE / CREATE INDEX IF NOT EXISTS idiom.
--   * Existing email_event creation:
--     202605040200_phase_9_8_email_provider.sql lines 301-344. Read
--     in full before this migration; the table already carries
--     event_id (UUID PK, F&F-side surrogate) and provider_message_id
--     (SendGrid X-Message-Id, per-email NOT per-event). Neither
--     stores SendGrid's per-event sg_event_id.
--
-- Why this exists
-- ---------------
-- Slice C-1 (SendGrid Event Webhook receiver) needs Postgres-enforced
-- dedupe on SendGrid's per-event sg_event_id so a re-delivered batch
-- is a no-op rather than a duplicate row. The current email_event
-- table has no column to hold sg_event_id:
--
--   * event_id is gen_random_uuid() — an F&F-side surrogate, NOT a
--     place to store a vendor-supplied event identifier.
--   * provider_message_id holds SendGrid's X-Message-Id (one value
--     per outbound email, NOT per event). Multiple webhook events
--     for the same email share the same provider_message_id.
--
-- Operator picked Path A 2026-05-13: "ship now while there's zero
-- SendGrid traffic to worry about, so the first live operator's
-- first email lands against an already-indexed table." This is a
-- pure additive expand. C-1 will follow as a separate slice and
-- write the receiver against this column.
--
-- Schema notes
-- ------------
--   * provider_event_id text NULL — opaque SendGrid sg_event_id (or
--     any future provider's per-event identifier). NULLABLE for
--     back-compat with rows that pre-date this migration and for
--     non-SendGrid-sourced events that never carry a per-event id.
--     New SendGrid-sourced rows are expected to populate this column
--     non-null; the receiver enforces that application-side.
--
--   * Partial UNIQUE INDEX
--     email_event_provider_event_id_unique
--       ON public.email_event (provider_event_id)
--       WHERE provider_event_id IS NOT NULL
--
--     The WHERE clause is load-bearing. A full UNIQUE INDEX (or
--     UNIQUE constraint) would forbid multiple NULL rows because
--     Postgres treats NULLs as distinct in non-partial unique
--     indexes only on b-tree default semantics — historically
--     ambiguous and dependent on `NULLS NOT DISTINCT`. Pinning the
--     predicate WHERE provider_event_id IS NOT NULL makes the
--     intent explicit: dedupe enforced on populated rows only,
--     historic + non-SendGrid rows freely coexist.
--
--     C-1's receiver writes:
--       INSERT INTO public.email_event (..., provider_event_id, ...)
--       VALUES (..., $sg_event_id, ...)
--       ON CONFLICT (provider_event_id) DO NOTHING;
--     The partial UNIQUE INDEX backs that ON CONFLICT clause.
--
-- Why no RLS change
-- -----------------
-- email_event already has RLS enabled with policy
-- "email_event_per_tenant_select" (202605040200 line 326). The policy
-- filters via EXISTS join through email_outbox.operator_id, so
-- email_event itself carries no operator_id column. Adding
-- provider_event_id does not affect that posture: the column is a
-- vendor identifier scoped to the same row, not a cross-tenant
-- discriminator. No new policy is required. No grants change
-- (existing GRANT SELECT, INSERT on email_event to service_role /
-- forge_admin already covers the new column under PostgreSQL's
-- table-level grant semantics).
--
-- Idempotency
-- -----------
-- ADD COLUMN IF NOT EXISTS + CREATE UNIQUE INDEX IF NOT EXISTS make
-- this migration safe to re-apply. The COMMENT ON COLUMN replays
-- harmlessly. No DROP, no DELETE, no ALTER COLUMN TYPE.
--
-- Lock + timeout guardrails
-- -------------------------
-- ALTER TABLE … ADD COLUMN briefly takes ACCESS EXCLUSIVE on
-- email_event. We bound the wait so a hot dispatcher cannot stall
-- behind us. Adding a NULLABLE column with no default in Postgres
-- 11+ is a metadata-only operation, so the actual lock window is
-- microseconds; the timeouts are belt-and-suspenders. The partial
-- UNIQUE INDEX is built inline (transactional). On a freshly-
-- migrated database the table has zero rows, so the index build is
-- effectively instant; even on a populated table the predicate
-- IS NOT NULL touches only the populated subset.
--
-- Operator approval gate
-- ----------------------
-- Per CLAUDE.md "agent-led slices" — schema-touching slices require
-- explicit operator approval before merge regardless of audit
-- verdict. Operator approved Path A 2026-05-13.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── email_event.provider_event_id ────────────────────────────────
alter table public.email_event
  add column if not exists provider_event_id text;

comment on column public.email_event.provider_event_id is
  'Lane C C-1a — opaque per-event identifier from the upstream email '
  'provider (SendGrid sg_event_id today; future providers reuse the '
  'same column). NULL for rows that pre-date this migration and for '
  'non-provider-sourced events. The partial UNIQUE INDEX '
  'email_event_provider_event_id_unique enforces dedupe on populated '
  'rows so the C-1 webhook receiver can rely on ON CONFLICT DO NOTHING '
  'against a re-delivered SendGrid batch.';

-- ─── partial UNIQUE INDEX ─────────────────────────────────────────
-- WHERE provider_event_id IS NOT NULL is critical: without it,
-- multiple historic / non-SendGrid rows with NULL provider_event_id
-- would collide. The predicate keeps dedupe scoped to populated rows.
create unique index if not exists email_event_provider_event_id_unique
  on public.email_event (provider_event_id)
  where provider_event_id is not null;

commit;
