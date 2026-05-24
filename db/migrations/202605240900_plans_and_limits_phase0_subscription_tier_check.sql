-- Plans & Limits V1 — Phase 0: make the six plans real.
--
-- The operator-approved pricing model (decision register
-- `docs/phases/phase_11a/phase_11a_decision_register.md`, "Reconciled
-- pricing model (2026-05-24)") locks six subscription tiers:
--
--   pilot, starter, premium, elite, pro, enterprise
--
-- `public.operators.subscription_tier`
-- (`db/migrations/202604250005_advisor_cloud_foundation.sql:77`) was
-- created as a bare `text not null default 'launch'` with NO CHECK
-- constraint, so it accepts any string — including the placeholder
-- `'launch'` value, which is undefined in both the `OperatorSubscriptionTier`
-- enum (`lib/auth/mfa_policy.dart`) and the pricing templates. This
-- migration retires `'launch'` and pins the column to the six real keys.
--
-- Expand/backfill/contract ordering (matters — do not reorder):
--
--   1. BACKFILL first. Any existing operators row still on the legacy
--      `'launch'` placeholder is mapped to `'pilot'` (the free-preview
--      entry tier). This includes the feature-flag system sentinel row
--      seeded by `202605072000_feature_flags_sentinel_operator.sql:119`,
--      which inserts `subscription_tier = 'launch'`. Running the backfill
--      before the CHECK is added guarantees no pre-existing row violates
--      the new constraint at apply time.
--   2. RELAX the column default from `'launch'` to `'pilot'` so future
--      inserts that omit the tier stay valid under the new CHECK.
--   3. ADD the CHECK constraint last, once all live rows are valid.
--
-- The CHECK is dropped-if-exists first so a re-apply is a no-op (the
-- column had no prior named constraint; the guard matches the repo's
-- additive-CHECK pattern in `202605200900_brand_org_unit_type.sql`).
--
-- No live database mutation here. Live apply on staging + Production1 is
-- queued under the Phase 9 live-mutation gate.
--
-- Residual risk: the backfill only remaps `'launch'`. Any operators row
-- carrying a DIFFERENT invalid `subscription_tier` (none expected; the
-- column has only ever defaulted to / been seeded with `'launch'`) would
-- fail the CHECK at apply time and must be reconciled first. Confirm with
-- `select distinct subscription_tier from public.operators;` before apply.

begin;

-- ─── 1. Backfill the legacy 'launch' placeholder to a real key ─────
--
-- 'launch' -> 'pilot' (the $0 free-preview entry tier per the decision
-- register). Idempotent: a re-apply matches zero rows.

update public.operators
   set subscription_tier = 'pilot'
 where subscription_tier = 'launch';

-- ─── 2. Relax the column default so omitted-tier inserts stay valid ─
--
-- The original default 'launch' would violate the CHECK added below.

alter table public.operators
  alter column subscription_tier set default 'pilot';

-- ─── 3. Pin the column to the six operator-approved tier keys ──────

alter table public.operators
  drop constraint if exists operators_subscription_tier_check;

alter table public.operators
  add constraint operators_subscription_tier_check
  check (subscription_tier in (
    'pilot',
    'starter',
    'premium',
    'elite',
    'pro',
    'enterprise'
  ));

comment on column public.operators.subscription_tier is
  'Operator subscription tier. One of the six operator-approved plans: '
  'pilot (free preview), starter, premium, elite, pro, enterprise. '
  'Mirrors OperatorSubscriptionTier in lib/auth/mfa_policy.dart.';

commit;
