-- Phase 11A.4c — Per-lane feature flags for the GCP Secret Manager
-- rollout. Every flag starts OFF; production rollout flips one lane
-- at a time in this order: azure_db -> voyage -> gemini -> anthropic
-- (lowest-risk first, primary lane last).
--
-- When the flag for a given key_kind is OFF, [KmsLaneRouter] dispatches
-- rotation writes to [KmsStubProvider] (the existing 11A.4 behavior —
-- audit-only, kms://stub/<uuid> pointer). When ON, rotation writes
-- land in [GcpSecretManagerKmsProvider] which:
--   1. Adds a new version under projects/<P>/secrets/forge-flow-<kind>-api-key
--   2. (For runtime-read lanes only) deploys a new Cloud Run revision so
--      every instance picks up the new Secret Manager version.
--
-- Rollback: flip the flag back to false. The `kms_stub_provider` is
-- still wired and ready to serve. Already-rotated rows in
-- provider_credentials with `kms://gcp-secret-manager/...` pointers
-- stay valid — they're audit history, not active runtime references.

begin;

insert into public.feature_flags (flag_name, enabled)
values
  ('kms_real_provider_azure_db_enabled',   false),
  ('kms_real_provider_voyage_enabled',     false),
  ('kms_real_provider_gemini_enabled',     false),
  ('kms_real_provider_anthropic_enabled',  false)
on conflict do nothing;

commit;
