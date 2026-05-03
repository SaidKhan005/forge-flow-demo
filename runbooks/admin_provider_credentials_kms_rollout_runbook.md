# Admin Provider Credentials + KMS Rollout Runbook

Purpose: make 11A.4 credential rotation and 11A.7 KMS feature flags
operational without exposing secrets in the Flutter admin client.

This runbook is operator-driven. Do not paste plaintext keys, database
URLs, service-account secrets, or flag confirmation text into issues,
PRs, chat logs, or screenshots.

## When To Run

- Staging/production provider rows show `No active credential`.
- A provider key must be rotated after vendor-side replacement.
- A KMS lane is ready to move from stub provider to real Secret Manager.
- A live smoke needs Anthropic, Voyage, Gemini, or Azure DB credentials
  present before advisor/integration testing.

## Preconditions

- Signed in to the admin console as `super_admin`.
- Fresh vendor credential is available from the vendor console or
  approved secrets store.
- Target environment's proxy has Secret Manager/KMS access.
- Latest migrations through the 11A.4/4b/4c/7 grant files are applied.
- For any `kms_real_provider_<kind>_enabled` flag change, get explicit
  action-time approval naming the exact flag and environment.

## Rotate A Provider Credential

1. Open Admin Console -> Integrations.
2. Choose the provider row and open Rotate.
3. Paste the new value into the dialog locally.
4. Submit once. The admin gateway sends an idempotency key; retry only
   through the same dialog state if the browser reports a network timeout.
5. Confirm the row shows an active masked value and recent rotation time.
6. Run the matching non-destructive smoke:
   - Anthropic/Voyage: advisor smoke or provider-health check.
   - Gemini: secondary-provider startup/status check.
   - Azure DB: `/readyz` and `/health`.

## Enable A KMS Real-Provider Flag

1. Verify the matching credential row is active.
2. Verify the target proxy revision reads Secret Manager successfully.
3. Open Admin Console -> Feature Flags.
4. Open the destructive confirmation for the exact
   `kms_real_provider_<kind>_enabled` flag.
5. Type the exact flag name only after action-time approval.
6. Submit once.
7. Refresh Health and Integrations. The affected provider path must be
   green or explicitly degraded with a known vendor-side reason.

## Rollback

- Disable the same `kms_real_provider_<kind>_enabled` flag to fall back
  to the stub lane.
- If the credential itself is bad, rotate to the previous approved key
  version through Integrations.
- If the proxy revision pinned stale Secret Manager versions, redeploy
  with the proxy redeploy/reset runbook.

## Evidence To Record

- Environment, provider kind, actor, timestamp.
- Masked credential suffix only, never plaintext.
- Feature flag name and final enabled/disabled state.
- Smoke result and any health envelope red/yellow signals.
