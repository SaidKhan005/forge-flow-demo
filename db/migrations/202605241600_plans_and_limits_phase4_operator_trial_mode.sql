-- Plans & Limits V1 — Phase 4a: Pilot free-trial flag on operators.
--
-- Authority:
--   * docs/phases/plans_and_limits_v1/plans_and_limits_v1_plan.md
--     ("Phase 4 — Pilot as a real free trial").
--   * docs/phases/phase_11a/phase_11a_decision_register.md
--     ("Reconciled pricing model (2026-05-24, operator decision)") — Pilot
--     is a $0 FREE PREVIEW (full dashboard on sample data + advisor) that
--     converts to Starter when real POS / labor data connects.
--   * CLAUDE.md "Hard Promises" #2 (Demo Mode), #4 (per-operator isolation),
--     "Time Guardrails", "RLS-Ready Schema".
--   * docs/contracts/demo_mode_contract.md (authoritative on HP #2).
--   * ALTER style mirrors the Phase 0 + Phase 3 operators ALTERs:
--     202605240900_plans_and_limits_phase0_subscription_tier_check.sql and
--     202605201100_operator_account_contact_fields.sql.
--
-- What this is (and is NOT)
-- -------------------------
-- This migration adds a per-operator TRIAL FLAG to the tenant-root
-- `public.operators` table. Pilot is NOT a second demo mode and NOT a
-- parallel seeding system. Per HP #2 (Demo Mode is a writer-side switch:
-- same tables, same reads, same UI either way) the Pilot preview is a
-- real operator carrying `subscription_tier = 'pilot'` plus the two
-- columns below. When the operator connects real POS / labor data, the
-- conversion path flips the trial off and moves the tier to 'starter'.
--
-- There is intentionally NO `demo_*` table here, and these columns do
-- NOT branch any reader. They are honest attributes of a real operator
-- row that the proxy reads/writes through the existing admin-pool
-- (forge_admin / service_role) path, exactly like `subscription_tier`,
-- `suspended_at`, and `contact_email` already do.
--
--   * trial_mode boolean not null default false
--       TRUE while the operator is on the Pilot free preview; FALSE for
--       every paid / converted / non-trial operator. Defaults FALSE so
--       every existing row (and every future insert that omits it) is
--       a non-trial operator until an explicit start-pilot call sets it.
--   * trial_expires_at timestamptz
--       UTC instant the Pilot trial lapses. NULL when the operator is
--       not on a trial (the default). TIMESTAMPTZ per CLAUDE.md "Time
--       Guardrails" (operator-scoped temporal columns store UTC).
--
-- Why no new RLS policy
-- ---------------------
-- `public.operators` is the tenant ROOT table. It already has RLS
-- enabled with the `operators_service_role_all` policy from the cloud
-- foundation migration
-- (202604250005_advisor_cloud_foundation.sql:324,335) and is written
-- only through the admin-pool (forge_admin BYPASSRLS / service_role)
-- path the pricing + onboarding routes already use. These two columns
-- are additive per-operator attributes on that existing row, so they
-- inherit the table's existing RLS posture and need NO new policy
-- (identical reasoning to the Phase 3 contact-fields ALTER).
--
-- Idempotency
-- -----------
-- `add column if not exists` makes a re-apply a no-op. The constraint is
-- dropped-if-exists before re-adding so a re-apply never errors.
--
-- No live database mutation here. Live apply on staging + Production1 is
-- queued under the Phase 9 live-mutation gate.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── Pilot free-trial flag columns ─────────────────────────────────
alter table public.operators
  add column if not exists trial_mode boolean not null default false;

alter table public.operators
  add column if not exists trial_expires_at timestamptz;

comment on column public.operators.trial_mode is
  'Plans & Limits V1 Phase 4 — Pilot free-trial flag. TRUE while the '
  'operator is on the $0 Pilot free preview (full dashboard on sample '
  'data + advisor); FALSE for every paid / converted / non-trial '
  'operator. This is the trial FLAG on a real operator, NOT a second '
  'demo mode and NOT a demo_* table (HP #2: demo is a writer-side '
  'switch, same tables / reads / UI). Set TRUE by the start-pilot path; '
  'cleared by the conversion path when real POS / labor data connects.';

comment on column public.operators.trial_expires_at is
  'Plans & Limits V1 Phase 4 — UTC instant the Pilot free trial lapses. '
  'NULL when the operator is not on a trial (the default). TIMESTAMPTZ '
  'per CLAUDE.md "Time Guardrails" (operator-scoped temporal columns '
  'store UTC). Set by the start-pilot path to now() + the trial window; '
  'cleared to NULL by the conversion path.';

-- ─── Integrity guard: an expiry only makes sense while on trial ────
-- A non-trial operator must not carry a dangling expiry, and a trial
-- operator must carry one. Dropped-if-exists first so a re-apply is a
-- no-op (mirrors the additive-CHECK pattern in
-- 202605201100_operator_account_contact_fields.sql).
alter table public.operators
  drop constraint if exists operators_trial_expiry_consistency_check;

alter table public.operators
  add constraint operators_trial_expiry_consistency_check
  check (
    (trial_mode = true and trial_expires_at is not null)
    or (trial_mode = false and trial_expires_at is null)
  );

commit;
