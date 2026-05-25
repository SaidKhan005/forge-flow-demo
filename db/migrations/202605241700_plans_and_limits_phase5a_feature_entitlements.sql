-- Plans & Limits V1 Phase 5a — feature_entitlements table.
--
-- Authority:
--   * docs/phases/plans_and_limits_v1/plans_and_limits_v1_plan.md
--     ("Phase 5 — Plan entitlements + 'Your plan' screen + model
--      routing", slice 5a "Entitlements foundation").
--   * docs/phases/phase_11a/phase_11a_decision_register.md
--     ("Reconciled pricing model (2026-05-24, operator decision)") +
--     lib/admin/models/pricing_tier_admin_models.dart
--     (`kPricingTierTemplates` summaries) — the per-plan "what's
--     included" matrix this table seeds from.
--   * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables include
--     (operator_id, location_id) + an RLS policy stub from creation. THIS
--     TABLE IS NOT OPERATOR-SCOPED — see "Why no RLS" below.
--   * CLAUDE.md "Time Guardrails" — all temporal columns are TIMESTAMPTZ.
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--     (admin-pool BYPASSRLS posture for non-tenant tables; SET LOCAL
--      ROLE forge_admin via TenantTransactionWrapper.runAsSystem.)
--   * Precedent: 202605241100_plans_and_limits_phase3_pricing_plan_catalog.sql
--     (the Phase 3 GLOBAL plan-pricing catalog; this migration mirrors
--      its no-RLS justification + admin-pool grant shape + idempotent
--      seed posture exactly).
--
-- Why this exists
-- ---------------
-- A plan's tier is stored per operator (`operators.subscription_tier`,
-- Phase 0) but nothing yet records WHICH FEATURES each plan includes.
-- The "what's included per plan" matrix lives today only as prose in the
-- hard-coded `kPricingTierTemplates` summaries (Starter = manager
-- surfaces + advisor; Premium adds LMS + scoreboard; Elite adds staff
-- coach + SOPs; Pro adds the workflow catalog; Enterprise is custom /
-- everything). This catalog turns that prose into editable rows so the
-- admin "Plans and limits" screen can show the matrix, and so a future
-- gating slice (Phase 5d) can read "is feature X enabled for tier Y?"
-- from one server source of truth instead of re-deriving it client-side.
--
-- FOUNDATION SLICE ONLY: this migration + its routes + the admin editor
-- record the matrix. They do NOT gate anything in the app yet (that is
-- the deferred Phase 5d, which needs a per-feature surface reality-check
-- first). The seed below is therefore a sensible operator-editable
-- DEFAULT, not the final word.
--
-- Schema notes
-- ------------
--   * (tier_key, feature_slug) PRIMARY KEY — one row per plan/feature
--     pair. tier_key is CHECK-pinned to exactly the six locked plan keys
--     (mirrors the Phase 0 CHECK on operators.subscription_tier in
--     202605240900_plans_and_limits_phase0_subscription_tier_check.sql and
--     the Phase 3 catalog CHECK). feature_slug is free text by column type
--     but the proxy validates it against the known catalog before writing,
--     so a malformed slug never lands through the app.
--   * enabled boolean NOT NULL DEFAULT false — whether the plan includes
--     the feature. Defaults to false so a newly-added (tier, feature) row
--     is "off until turned on".
--   * updated_at timestamptz NOT NULL DEFAULT now() — UTC instant of the
--     last edit. TIMESTAMPTZ per CLAUDE.md "Time Guardrails".
--   * updated_by text — actor user id of the F&F admin who last toggled
--     the row. NULL for the seed rows inserted by this migration.
--
-- Feature slug set (derived from the authoritative sources above)
-- ---------------------------------------------------------------
--   advisor      — the AI advisor / manager chatbot. (Starter's "manager
--                  chatbot" IS the advisor surface — there is no separate
--                  "chatbots" product concept, so no `chatbots` slug.)
--   lms          — the Learning (LMS) surface. Premium adds it.
--   scoreboard   — the team scoreboard. Premium adds it.
--   staff_coach  — staff coaching. Elite adds it.
--   sops         — standard operating procedures. Elite adds it.
--   workflows    — the workflow catalog with run allowances. Pro adds it.
--
-- Why no RLS on feature_entitlements
-- ----------------------------------
-- This is a GLOBAL platform-wide catalog table — NOT an operator-scoped
-- fact table. Plan entitlements are the same for every operator on a
-- given tier; there is no operator_id to scope on. CLAUDE.md "RLS-Ready
-- Schema" mandates RLS policy stubs only for operator-scoped fact tables.
-- The defense-in-depth posture mirrors pricing_plan_catalog exactly:
--
--   * The admin-pool runtime (service_role + forge_admin) is the only
--     identity that reads/writes this table. The repository
--     (feature_entitlements_repository.dart) routes every call through
--     TenantTransactionWrapper.runAsSystem so the connection carries
--     `SET LOCAL ROLE forge_admin` for the lifetime of the transaction.
--   * Grants below REVOKE all from public, GRANT SELECT to service_role
--     (so a future tenant-side resolver can read "what does my tier
--     include?" from a tenant transaction without elevating), and GRANT
--     full DML to forge_admin (so the admin edit path can mutate).
--   * Operator-scoped readers never filter by operator_id on this table
--     because there is no operator_id column — the entitlements are the
--     same for everyone on a tier.
--
-- Idempotency
-- -----------
-- All DDL is idempotent (`if not exists` on the CREATE; the seed uses
-- `on conflict (tier_key, feature_slug) do nothing` so re-applying the
-- migration never clobbers an admin's later toggle). Re-running the
-- migration is a no-op.
--
-- Lock + timeout guardrails
-- -------------------------
-- The CREATE TABLE takes a brief lock on a brand-new relation; the seed
-- INSERT touches only the rows it adds. We still bound the waits so a
-- hot pool does not stall behind us. (Same bounds as the Phase 3
-- catalog migration.)

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── feature_entitlements ──────────────────────────────────────────
create table if not exists public.feature_entitlements (
  tier_key      text not null,
  feature_slug  text not null,
  enabled       boolean not null default false,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  constraint feature_entitlements_pkey primary key (tier_key, feature_slug),
  constraint feature_entitlements_tier_key_chk
    check (tier_key in ('pilot','starter','premium','elite','pro','enterprise'))
);

comment on table public.feature_entitlements is
  'Plans & Limits V1 Phase 5a — F&F-wide editable plan/feature matrix. '
  'One row per (plan, feature) pair recording whether the plan includes '
  'the feature. Global (no operator_id): entitlements are the same for '
  'every operator on a tier, so there is nothing to scope on and no RLS '
  'policy (admin-pool BYPASSRLS posture, exactly like '
  'pricing_plan_catalog). Edited by F&F admins through '
  'PATCH /v1/admin/pricing/entitlements/{tier_key}/{feature_slug}; '
  'seeded here with the cumulative ladder from the reconciled pricing '
  'model. FOUNDATION ONLY: this records the matrix, it does not gate the '
  'app (deferred Phase 5d). The seed is an operator-editable default.';

comment on column public.feature_entitlements.tier_key is
  'Stable plan key the proxy + operators.subscription_tier CHECK both '
  'recognise. CHECK-pinned to the six locked keys.';

comment on column public.feature_entitlements.feature_slug is
  'Stable feature key (advisor / lms / scoreboard / staff_coach / sops / '
  'workflows). Free text by type; the proxy validates it against the '
  'known catalog before any write.';

comment on column public.feature_entitlements.enabled is
  'Whether the plan includes this feature. Defaults to false (off until '
  'turned on).';

comment on column public.feature_entitlements.updated_at is
  'UTC instant of the last toggle. TIMESTAMPTZ per CLAUDE.md "Time '
  'Guardrails".';

comment on column public.feature_entitlements.updated_by is
  'Actor user id of the F&F admin who last toggled the row. NULL for the '
  'seed rows inserted by this migration.';

-- ─── Seed the cumulative ladder (operator-editable DEFAULT) ─────────
-- Each plan includes everything below it. Mirrors the plan summaries in
-- lib/admin/models/pricing_tier_admin_models.dart (kPricingTierTemplates):
--   advisor      — all paid tiers (and Pilot, which is the free preview
--                  of the full dashboard + advisor).
--   lms          — premium and up.
--   scoreboard   — premium and up.
--   staff_coach  — elite and up.
--   sops         — elite and up.
--   workflows    — pro and up.
-- Enterprise ("custom / everything") gets every feature on. `on conflict
-- do nothing` keeps a re-applied migration from clobbering a later admin
-- toggle.
insert into public.feature_entitlements (tier_key, feature_slug, enabled)
values
  -- advisor: the free Pilot preview + every paid tier.
  ('pilot',      'advisor',     true),
  ('starter',    'advisor',     true),
  ('premium',    'advisor',     true),
  ('elite',      'advisor',     true),
  ('pro',        'advisor',     true),
  ('enterprise', 'advisor',     true),
  -- lms: premium and up.
  ('premium',    'lms',         true),
  ('elite',      'lms',         true),
  ('pro',        'lms',         true),
  ('enterprise', 'lms',         true),
  -- scoreboard: premium and up.
  ('premium',    'scoreboard',  true),
  ('elite',      'scoreboard',  true),
  ('pro',        'scoreboard',  true),
  ('enterprise', 'scoreboard',  true),
  -- staff_coach: elite and up.
  ('elite',      'staff_coach', true),
  ('pro',        'staff_coach', true),
  ('enterprise', 'staff_coach', true),
  -- sops: elite and up.
  ('elite',      'sops',        true),
  ('pro',        'sops',        true),
  ('enterprise', 'sops',        true),
  -- workflows: pro and up.
  ('pro',        'workflows',   true),
  ('enterprise', 'workflows',   true)
on conflict (tier_key, feature_slug) do nothing;

-- ─── Grants ────────────────────────────────────────────────────────
-- Admin-pool BYPASSRLS posture for the catalog table, identical to
-- pricing_plan_catalog. Runtime reads only need SELECT; the edit path
-- runs under forge_admin via TenantTransactionWrapper.runAsSystem.
revoke all on public.feature_entitlements from public;
grant select
  on public.feature_entitlements to service_role;
grant select, insert, update, delete
  on public.feature_entitlements to forge_admin;

commit;
