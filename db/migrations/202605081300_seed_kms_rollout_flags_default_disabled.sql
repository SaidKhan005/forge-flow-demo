-- Staging proxy startup unblock — idempotently seed the four KMS
-- rollout feature-flag rows that the admin schema contract requires.
--
-- Background
-- ----------
-- The original `202605020200_phase_11A_4c_kms_rollout_flags.sql`
-- migration seeded the four `kms_real_provider_<lane>_enabled`
-- rows with `INSERT ... ON CONFLICT DO NOTHING`. At that time
-- `feature_flags.operator_id` was nullable and global-scope rows
-- carried `operator_id IS NULL`; uniqueness was enforced by the
-- partial unique index `feature_flags_global_scope_idx (flag_name)
-- WHERE operator_id IS NULL AND location_id IS NULL`.
--
-- Then `202605072000_feature_flags_sentinel_operator.sql` introduced
-- the system-wide sentinel UUID (`00000000-…-000000000000`),
-- backfilled every NULL `operator_id` row to the sentinel, made the
-- column NOT NULL, and dropped the global-scope partial unique
-- index in favor of `feature_flags_operator_scope_idx (flag_name,
-- operator_id) WHERE operator_id IS NOT NULL AND location_id IS
-- NULL`. The startup contract in
-- `tool/advisor_proxy/advisor_proxy.dart::AdminProxySchemaContractVerifier`
-- now scopes its existence check to
-- `operator_id = public.feature_flag_system_wide_operator_id() AND
-- location_id IS NULL`.
--
-- On staging (`forge-flow-staging-proxy` rev 00069) the four rows
-- were absent from `public.feature_flags` at startup, the contract
-- verifier surfaced
--   row:public.feature_flags.kms_real_provider_anthropic_enabled
--   row:public.feature_flags.kms_real_provider_azure_db_enabled
--   row:public.feature_flags.kms_real_provider_gemini_enabled
--   row:public.feature_flags.kms_real_provider_voyage_enabled
-- and the proxy exited 78. Cloud Run auto-rolled back to rev 68
-- (which started before the contract tightened around the sentinel
-- shape).
--
-- Fix shape
-- ---------
-- This migration idempotently seeds the four rows at the system-wide
-- sentinel scope with `enabled = false` (the production-shaped
-- default — every lane stays on `KmsStubProvider` until an operator
-- flips the row to ON via the 11A.7 admin Feature Flags screen). It
-- mirrors the original 11A.4c semantics, just rebased onto the
-- post-sentinel schema.
--
-- The `kind = 'destructive'` classification on these rows is owned
-- by `202605020400_phase_11A_7_feature_flags_admin_columns.sql`
-- (the post-launch reclassification UPDATE there is `kind <>
-- 'destructive'`-guarded so an operator override survives). This
-- seed only writes the row identity columns (`flag_name`,
-- `operator_id`, `location_id`, `enabled`) and lets the kind /
-- description / updated_by fields fall back to their column
-- defaults — the 11A.7 reclassification migration will idempotently
-- promote these rows on its next apply if they were not present
-- when it last ran.
--
-- Authority order
--   1. CLAUDE.md "Proxy & API Conventions" — every proxy write is
--      idempotent.
--   2. `202605072000_feature_flags_sentinel_operator.sql` — the
--      sentinel UUID + reader function this seed uses.
--   3. `202605020200_phase_11A_4c_kms_rollout_flags.sql` — original
--      seed, now superseded by this one.
--   4. `tool/advisor_proxy/advisor_proxy.dart::AdminProxySchemaContractVerifier`
--      — the startup contract this seed satisfies.
--
-- Idempotency
--   * `WHERE NOT EXISTS` guards each row against duplicate inserts.
--     Plain `ON CONFLICT (operator_id, location_id, flag_name)` is
--     not available because the post-sentinel uniqueness target is
--     a partial unique index (`feature_flags_operator_scope_idx`),
--     not a named constraint, and `NULL` `location_id` does not
--     compare equal under `ON CONFLICT` semantics in any case.
--   * The seed never touches rows that already exist — an operator
--     override (`enabled = true` after a lane flip via the 11A.7
--     admin screen) survives migration replays unchanged.

begin;

insert into public.feature_flags (
  flag_name,
  operator_id,
  location_id,
  enabled
)
select
  flag_name,
  public.feature_flag_system_wide_operator_id(),
  null::uuid,
  false
from (
  values
    ('kms_real_provider_azure_db_enabled'),
    ('kms_real_provider_voyage_enabled'),
    ('kms_real_provider_gemini_enabled'),
    ('kms_real_provider_anthropic_enabled')
) as required(flag_name)
where not exists (
  select 1
    from public.feature_flags f
   where f.flag_name = required.flag_name
     and f.operator_id = public.feature_flag_system_wide_operator_id()
     and f.location_id is null
);

commit;
