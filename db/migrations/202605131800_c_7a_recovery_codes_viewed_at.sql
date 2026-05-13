-- Lane C C-7a — mfa_factors.recovery_codes_viewed_at column for C-7
-- ("Adaptive 2FA button"). Pure additive expand.
--
-- Authority:
--   * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-7a (line 94) — prep
--     migration unblocking Codex's C-7 ("Adaptive 2FA button"). Operator
--     approved 2026-05-13 ("yes to all" on the open-decisions slate).
--   * docs/_execution/lane_c_parity/03_execution_slices.md "Slice C-7
--     — Adaptive 2FA button" (line 145) — the My Account button state
--     adapts from `(session.mfaEnrolled, factor_count,
--     recovery_codes_viewed_at)`. That last column did not exist on
--     master before this migration, so C-7 was data-contract-blocked.
--   * CLAUDE.md "RLS-Ready Schema" — `mfa_factors` already has RLS
--     posture from the auth schema foundation. This migration does
--     NOT change that posture: no new policy, no new operator_id
--     column, no GRANT changes.
--   * CLAUDE.md "Time Guardrails" — restaurant-local timing wins for
--     business-date facts; this column is a per-user audit timestamp
--     (UTC) for the last time the user *viewed* their MFA recovery
--     codes, not a business-date fact. `timestamptz` per the operator-
--     scoped fact-table convention even though `mfa_factors` is keyed
--     by `user_id` rather than `operator_id` (auth-scope identity table).
--   * Precedent: 202605131700_c_1a_email_event_provider_id.sql for
--     header/comment shape, lock+timeout guardrails, idempotent DDL
--     idiom, and operator approval gate phrasing. C-7a mirrors C-1a's
--     pattern verbatim: additive ADD COLUMN IF NOT EXISTS, NULLABLE,
--     comment, zero RLS / GRANT changes.
--   * Existing mfa_factors creation:
--     202604250008_auth_schema_foundation.sql lines 243-255. Read in
--     full before this migration; the table already carries
--     enrolled_at, last_used_at, revoked_at, created_at, updated_at
--     timestamps. None of those holds the "when did the user last view
--     their recovery codes" semantic that the Adaptive 2FA button needs
--     to distinguish "View recovery codes" (never viewed) from "Manage
--     two-factor sign-in" (already viewed at least once).
--
-- Why this exists
-- ---------------
-- Slice C-7 (Adaptive 2FA button) computes the My Account button label
-- from three inputs:
--
--   1. session.mfaEnrolled — already on master via session.
--   2. factor_count        — already on master via `select count(*)
--                            from mfa_factors where user_id = $1 and
--                            revoked_at is null;`
--   3. recovery_codes_viewed_at — MISSING from schema, model, gateway.
--
-- C-7's slice spec names the column explicitly (line 145). Without it,
-- the gateway has no source of truth for the "View recovery codes" vs
-- "Manage two-factor sign-in" branch and the button collapses to a
-- single label. Operator approved 2026-05-13 ("yes to all" on open
-- decisions slate): ship the prep migration now while there's no live
-- business + zero existing mfa_factors rows, so the first live operator's
-- first MFA enrollment lands against an already-shaped table. Mirrors
-- the C-1a → C-1 cadence (PR #599 → PR #611) verbatim.
--
-- Schema notes
-- ------------
--   * recovery_codes_viewed_at timestamptz NULL — UTC timestamp of the
--     most recent time the user viewed their MFA recovery codes. NULL
--     means "never viewed" (the only state pre-launch; also the default
--     for any historic row that lands during demo/dev seeding). New
--     rows do not need to populate this column at enrollment time; the
--     C-7 gateway writes `UPDATE mfa_factors SET recovery_codes_viewed_at
--     = now() WHERE factor_id = $1` on the View Recovery Codes click.
--
--   * No new index. The Adaptive 2FA button reads the column on a
--     per-user point lookup that's already covered by the existing
--     `mfa_factors_user_active_idx (user_id, factor_type) WHERE
--     revoked_at is null` index. Adding a column that's not part of
--     any query predicate or sort order does not require a new index.
--
-- Why no RLS change
-- -----------------
-- mfa_factors already has its existing per-user RLS regime from
-- 202604250008_auth_schema_foundation.sql (and any later hardening
-- migration that touches it). Adding recovery_codes_viewed_at does
-- not affect that posture: the column is a per-row audit timestamp
-- on the same row the existing policies already gate. No new policy
-- is required. No grants change — Postgres table-level grants cover
-- the new column under default privilege semantics.
--
-- Idempotency
-- -----------
-- ADD COLUMN IF NOT EXISTS makes this migration safe to re-apply.
-- The COMMENT ON COLUMN replays harmlessly. No DROP, no DELETE, no
-- ALTER COLUMN TYPE.
--
-- Lock + timeout guardrails
-- -------------------------
-- ALTER TABLE … ADD COLUMN briefly takes ACCESS EXCLUSIVE on
-- mfa_factors. We bound the wait so a hot session-validate path does
-- not stall behind us. Adding a NULLABLE column with no default in
-- Postgres 11+ is a metadata-only operation, so the actual lock
-- window is microseconds; the timeouts are belt-and-suspenders. On a
-- freshly-migrated database the table has zero rows (no business
-- live yet), so the apply is effectively instant.
--
-- Operator approval gate
-- ----------------------
-- Per CLAUDE.md "Agent-led slices" — schema-touching slices require
-- explicit operator approval before merge regardless of audit verdict.
-- Operator approved 2026-05-13 ("yes to all" on open-decisions slate).

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── mfa_factors.recovery_codes_viewed_at ─────────────────────────
alter table public.mfa_factors
  add column if not exists recovery_codes_viewed_at timestamptz;

comment on column public.mfa_factors.recovery_codes_viewed_at is
  'Lane C C-7a — UTC timestamp of the most recent time the user '
  'viewed their MFA recovery codes. NULL = never viewed (the only '
  'state pre-launch). Written by the C-7 ("Adaptive 2FA button") '
  'gateway on the "View recovery codes" click. Read by the My '
  'Account adaptive-label compute (R1 pattern) to distinguish '
  '"View recovery codes" (NULL) from "Manage two-factor sign-in" '
  '(NOT NULL). No index needed — point-lookup is covered by the '
  'existing mfa_factors_user_active_idx.';

commit;
