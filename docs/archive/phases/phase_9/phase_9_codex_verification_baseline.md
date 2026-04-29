# Phase 9 Codex Verification Baseline

Updated: 2026-04-26.

Purpose: preserve the pre-automation repo truth before Claude runs the
remaining Phase 9 slice loop. This is a verification handoff, not a product or
architecture decision source.

Decision source: `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`.

Architecture source: `docs/phases/phase_9/phase_9_auth_plan.md`.

Compact handoff source (archived 2026-04-28):
`docs/archive/phases/phase_9/phase_9_context_checkpoint.md`.

## Current Auth State

- Phase 9 is active.
- `9.0` auth schema foundation is accepted locally, on staging, and on
  Production1.
- `9.1` Firebase Identity Platform setup closeout + JWT verifier wiring is
  next.
- Staging Firebase project `forge-flow-staging` exists and is upgraded to
  Identity Platform.
- Email/password and TOTP MFA are enabled; SMS/phone auth is disabled.
- Launch auth decision: email/password + TOTP first.
- Passkeys are a future follow-up, not a Phase 9 launch gate unless official
  Firebase / Identity Platform support appears before cutover.
- Auth email decision: Firebase action links with Forge & Flow branded pages.
- Local secrets are consolidated outside the repo under `$HOME/.forge_flow/`.
- Canonical loader: `$HOME/.forge_flow/forge_flow.secrets.ps1`.
- Firebase Admin SDK JSON stays outside the repo:
  `$HOME/.forge_flow/firebase-staging-adminsdk.json`.
- Production1 remains schema-only; no operator data is loaded.

## Stale Review Findings Rechecked

These findings should not be re-raised unless the repo regresses:

- `docs/archive/phases/phase_11a/phase_11a_11c6_azure_staging_apply_result.md`
  records the staging 7-day backup gap, B1ms PgBouncer limitation,
  Production1 35-day backup posture, and Production1 PgBouncer smoke.
- `scripts/use_postgres_staging_env.ps1` failure paths use `return`, not
  `exit`, for dot-source safety.
- `scripts/postgres_staging_setup.ps1` lists `pg_diskann`, `pg_cron`,
  `pg_partman`, `pg_stat_statements`, and `shared_preload_libraries`.
- `db/migrations/202604250008_auth_schema_foundation.sql` has
  `user_roles_active_grant_idx` leading with `operator_id`.
- `db/migrations/202604250008_auth_schema_foundation.sql` has
  `auth_events_audit` actor and target lookup indexes leading with
  `operator_id`.

## Baseline Tests

Run by Codex before the automated Claude Phase 9 loop:

```powershell
dart analyze tool/advisor_proxy test/advisor_proxy_test.dart db/migrations lib/auth
```

Result: no issues found.

```powershell
flutter test test/advisor_proxy_test.dart
```

Result: 94/94 tests passed.

## Current Worktree Shape

The worktree is intentionally dirty because Phase 11a, Firebase setup, and
Phase 9 docs/code have been staged as local changes but not committed.

Notable untracked Phase 9/Firebase files:

- `db/migrations/202604250008_auth_schema_foundation.sql`
- `docs/contracts/auth_permission_key_catalog.md`
- `docs/archive/phases/phase_9/phase_9_0_auth_schema_live_apply_result.md`
- `docs/archive/phases/phase_9/phase_9_1_firebase_setup_preflight.md`
- `docs/archive/phases/phase_9/phase_9_1_identity_provider_decision_gate.md`
- `docs/archive/phases/phase_9/phase_9_context_checkpoint.md`
- `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`
- `lib/auth/`
- `.firebaserc`
- `firebase.json`
- `android/app/src/forgeflow/google-services.json`
- `android/app/src/barrio/google-services.json`
- `ios/Runner/Firebase/`
- `web/`
- `scripts/use_forge_flow_secrets.ps1`

Do not infer these are new Claude changes unless they differ after the next
slice. Codex should compare diffs directly after Claude reports.

## Post-Claude Verification Checklist

When Claude returns a final Phase 9 automation report:

1. Read `docs/archive/phases/phase_9/phase_9_context_checkpoint.md` (archived).
2. Inspect changed files directly with `git diff -- <file>` and `rg`.
3. Confirm each slice acceptance criterion against repo content.
4. Confirm tests match the report; rerun only the smallest needed set if
   evidence is incomplete or risky.
5. Recheck the stale findings listed above before treating repeated review
   comments as real.
6. Verify Claude did not update trackers or commit.
7. Update trackers only after Codex accepts the repo truth.

Minimum final checks unless the diff requires more:

```powershell
dart analyze tool/advisor_proxy test/advisor_proxy_test.dart db/migrations lib/auth
flutter test test/advisor_proxy_test.dart
```

Add service/widget tests for any Flutter auth UI or permission-gate files
Claude touches.
