-- Plans & Limits V1 Phase 3 — pricing_plan_catalog table.
--
-- Authority:
--   * docs/phases/plans_and_limits_v1/plans_and_limits_v1_plan.md
--     ("Phase 3 — Make plan pricing editable")
--   * docs/phases/phase_11a/phase_11a_decision_register.md
--     ("Reconciled pricing model (2026-05-24, operator decision)") — the
--     canonical plan lineup + per-plan prices this table seeds from.
--   * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables include
--     (operator_id, location_id) + an RLS policy stub from creation. THIS
--     TABLE IS NOT OPERATOR-SCOPED — see "Why no RLS" below.
--   * CLAUDE.md "Time Guardrails" — all temporal columns are TIMESTAMPTZ.
--   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
--     (admin-pool BYPASSRLS posture for non-tenant tables; SET LOCAL
--      ROLE forge_admin via TenantTransactionWrapper.runAsSystem.)
--   * Precedent: 202605131600_b2_1_default_role_catalog_versions.sql
--     (the other GLOBAL F&F-wide catalog table; this migration mirrors
--      its no-RLS justification + admin-pool grant shape exactly).
--
-- Why this exists
-- ---------------
-- The six F&F plan prices (Pilot / Starter / Premium / Elite / Pro /
-- Enterprise — monthly fee, per-seat ramp, onboarding range) live today
-- as hard-coded Dart constants (`kPricingTierTemplates` +
-- `kPricingPlanPresentations` in
-- lib/admin/models/pricing_tier_admin_models.dart). F&F admins cannot
-- adjust a price without a client deploy, and any future billing path
-- would have to read client constants instead of a server source of
-- truth. Phase 3 introduces this catalog so an admin can edit plan
-- pricing through the existing admin "Plans & limits" screen, and so
-- downstream billing reads one row per plan from the database.
--
-- This migration is the persistence shape + seed only. The proxy routes
-- (GET /v1/admin/pricing/plans, PATCH /v1/admin/pricing/plans/{tier_key})
-- and the admin-screen editor wiring ship in the same Phase 3 slice but
-- are not part of the DDL.
--
-- Schema notes
-- ------------
--   * tier_key text PRIMARY KEY — the stable plan key the proxy + the
--     operators.subscription_tier CHECK both recognise. The CHECK below
--     pins exactly the six locked keys so a malformed row can never land
--     (mirrors the Phase 0 CHECK on operators.subscription_tier in
--     202605240900_plans_and_limits_phase0_subscription_tier_check.sql).
--   * monthly_usd numeric — headline monthly fee in USD. NULL for a
--     custom-contract plan (Enterprise) so the UI renders "Custom"
--     instead of a number.
--   * first_n_seats int — size of the first per-seat pricing band
--     (e.g. 20 for "first 20 seats at $X"). NULL when the plan has no
--     per-seat fee (Pilot / Starter / Enterprise).
--   * first_seat_usd / additional_seat_usd numeric — per-seat price
--     inside / past the first band. NULL when the plan has no per-seat
--     fee.
--   * onboarding_min_usd / onboarding_max_usd numeric — onboarding fee
--     range. NULL for the self-serve ($0) and custom plans.
--   * updated_at timestamptz NOT NULL DEFAULT now() — UTC instant of the
--     last edit. TIMESTAMPTZ per CLAUDE.md "Time Guardrails".
--   * updated_by text — actor user id of the F&F admin who last edited
--     the row. NULL for the seed rows inserted by this migration.
--
-- Why no RLS on pricing_plan_catalog
-- ----------------------------------
-- This is a GLOBAL platform-wide catalog table — NOT an operator-scoped
-- fact table. Plan pricing is the same for every operator; there is no
-- operator_id to scope on. CLAUDE.md "RLS-Ready Schema" mandates RLS
-- policy stubs only for operator-scoped fact tables. The defense-in-depth
-- posture mirrors default_role_catalog_versions exactly:
--
--   * The admin-pool runtime (service_role + forge_admin) is the only
--     identity that reads/writes this table. The repository
--     (pricing_plan_catalog_repository.dart) routes every call through
--     TenantTransactionWrapper.runAsSystem so the connection carries
--     `SET LOCAL ROLE forge_admin` for the lifetime of the transaction.
--   * Grants below REVOKE all from public, GRANT SELECT to service_role
--     (so a future tenant-side resolver can read plan pricing from a
--     tenant transaction without elevating), and GRANT full DML to
--     forge_admin (so the admin edit path can mutate).
--   * Operator-scoped readers never filter by operator_id on this table
--     because there is no operator_id column — the catalog is the same
--     for everyone.
--
-- Idempotency
-- -----------
-- All DDL is idempotent (`if not exists` on the CREATE; the seed uses
-- `on conflict (tier_key) do nothing` so re-applying the migration never
-- clobbers an admin's later price edit). Re-running the migration is a
-- no-op.
--
-- Lock + timeout guardrails
-- -------------------------
-- The CREATE TABLE takes a brief lock on a brand-new relation; the seed
-- INSERT touches only the six rows it adds. We still bound the waits so a
-- hot pool does not stall behind us.

begin;

set local statement_timeout = '30s';
set local lock_timeout = '5s';

-- ─── pricing_plan_catalog ──────────────────────────────────────────
create table if not exists public.pricing_plan_catalog (
  tier_key             text primary key,
  monthly_usd          numeric,
  first_n_seats        integer,
  first_seat_usd       numeric,
  additional_seat_usd  numeric,
  onboarding_min_usd   numeric,
  onboarding_max_usd   numeric,
  updated_at           timestamptz not null default now(),
  updated_by           text,
  constraint pricing_plan_catalog_tier_key_chk
    check (tier_key in ('pilot','starter','premium','elite','pro','enterprise'))
);

comment on table public.pricing_plan_catalog is
  'Plans & Limits V1 Phase 3 — F&F-wide editable plan pricing catalog. '
  'One row per plan (Pilot / Starter / Premium / Elite / Pro / '
  'Enterprise). Global (no operator_id): plan pricing is the same for '
  'every operator, so there is nothing to scope on and no RLS policy '
  '(admin-pool BYPASSRLS posture, exactly like '
  'default_role_catalog_versions). Edited by F&F admins through '
  'PATCH /v1/admin/pricing/plans/{tier_key}; seeded here from the '
  'reconciled pricing model in the phase_11a decision register.';

comment on column public.pricing_plan_catalog.tier_key is
  'Stable plan key the proxy + operators.subscription_tier CHECK both '
  'recognise. CHECK-pinned to the six locked keys.';

comment on column public.pricing_plan_catalog.monthly_usd is
  'Headline monthly fee in USD. NULL for a custom-contract plan '
  '(Enterprise) so the UI renders "Custom".';

comment on column public.pricing_plan_catalog.first_n_seats is
  'Size of the first per-seat pricing band (e.g. 20). NULL when the '
  'plan has no per-seat fee.';

comment on column public.pricing_plan_catalog.first_seat_usd is
  'Per-seat USD price inside the first band. NULL when the plan has no '
  'per-seat fee.';

comment on column public.pricing_plan_catalog.additional_seat_usd is
  'Per-seat USD price past the first band. NULL when the plan has no '
  'per-seat fee.';

comment on column public.pricing_plan_catalog.onboarding_min_usd is
  'Low end of the onboarding fee range in USD. NULL for the self-serve '
  'and custom plans.';

comment on column public.pricing_plan_catalog.onboarding_max_usd is
  'High end of the onboarding fee range in USD. NULL for the '
  'self-serve and custom plans.';

comment on column public.pricing_plan_catalog.updated_at is
  'UTC instant of the last edit. TIMESTAMPTZ per CLAUDE.md "Time '
  'Guardrails".';

comment on column public.pricing_plan_catalog.updated_by is
  'Actor user id of the F&F admin who last edited the row. NULL for the '
  'seed rows inserted by this migration.';

-- ─── Seed the six plans ────────────────────────────────────────────
-- Values mirror lib/admin/models/pricing_tier_admin_models.dart
-- (kPricingTierTemplates + kPricingPlanPresentations) and the reconciled
-- pricing model in the phase_11a decision register: Elite seat $10/$5,
-- Premium $5/$3, Pro $15/$8, per-plan onboarding ranges. `on conflict do
-- nothing` keeps a re-applied migration from clobbering a later admin
-- price edit.
insert into public.pricing_plan_catalog (
  tier_key, monthly_usd, first_n_seats, first_seat_usd,
  additional_seat_usd, onboarding_min_usd, onboarding_max_usd
) values
  ('pilot',      0,    null, null, null, 0,    0),
  ('starter',    250,  null, null, null, 500,  1000),
  ('premium',    250,  20,   5,    3,    750,  2000),
  ('elite',      250,  20,   10,   5,    1500, 3500),
  ('pro',        500,  20,   15,   8,    2500, 5000),
  ('enterprise', null, null, null, null, null, null)
on conflict (tier_key) do nothing;

-- ─── Grants ────────────────────────────────────────────────────────
-- Admin-pool BYPASSRLS posture for the catalog table, identical to
-- default_role_catalog_versions. Runtime reads only need SELECT; the
-- edit path runs under forge_admin via
-- TenantTransactionWrapper.runAsSystem.
revoke all on public.pricing_plan_catalog from public;
grant select
  on public.pricing_plan_catalog to service_role;
grant select, insert, update, delete
  on public.pricing_plan_catalog to forge_admin;

commit;
