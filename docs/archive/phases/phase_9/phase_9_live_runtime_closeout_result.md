# Phase 9 Live Runtime Closeout Result

Status: ACCEPTED for slices 1-5 on 2026-04-27.

## Scope

This report covers the requested per-slice closeout loop through step 5:

1. Apply remaining Phase 9 database migrations to staging and Production1.
2. Update tracker/report docs.
3. Add Firebase auth and secure-session app wiring.
4. Run staging credential/session smoke.
5. Build the first operator-facing Settings -> Team Material UI foundation.

## Slice Results

### 1. Database closeout

- Applied auth RLS/grant migrations to Production1.
- Applied 9.0a scope/team-key migration to staging and Production1.
- Applied `auth_sessions.token_hash` rename to staging and Production1.
- Added and applied `202604270200_phase_9_0a_super_admin_team_grants.sql`
  after live verification found `super_admin` did not inherit newly-added
  `team.*` keys from the original 9.0 seed.
- Verified staging and Production1: 93 permission keys, 12 team keys,
  super_admin/team grants fixed, RLS enabled on auth tables, 16 auth policies,
  tenant-leading auth indexes, append-only audit grants, and no unzoned
  timestamps.

Detailed database evidence is in
`docs/phases/phase_9/phase_9_live_database_closeout_result.md`.

### 2. Tracker and reports

- Updated `PROJECT_TRACKER.md`.
- Updated `phase_9_execution_backlog.md`.
- Updated `phase_9_context_checkpoint.md`.
- Updated `phase_9_auth_plan.md`.

### 3. Firebase auth and secure storage app wiring

- Added FlutterFire and secure-storage dependencies.
- Added `FirebaseAuthSdkClient`.
- Added `FlutterSecureStorageBackend`.
- Added `firebase_auth_runtime_bindings.dart`.
- Wired all app entrypoints behind
  `--dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true`.
- Verified Android debug builds for Forge & Flow and Barrio, with and without
  the Firebase auth define.
- iOS config-copy wiring is written but still requires a macOS build check.

### 4. Staging credential/session smoke

- Created/updated staging-only `auth-smoke@forgeflow.dev`.
- Wrote the password only to the non-repo secrets loader.
- Created matching staging Postgres smoke operator/location/user/admin/grant
  rows.
- Verified Firebase email/password sign-in and expected ID-token claims without
  printing tokens.
- Exercised staging `auth_sessions` insert, refresh, and revoke; verified the
  smoke row was revoked with reason `phase_9_auth_smoke_complete`.

### 5. Settings -> Team Material UI foundation

- Added `TeamSettingsSection`: summary strip, search/status/role/location
  filters, dense team rows, and controller-backed invite form.
- Wired `SettingsScreen` to add a Team tab only when an allowed
  `TeamScopeActor` is injected.
- Team stays hidden by default when no actor snapshot is installed.
- Invite submit stays disabled unless the actor has invite permission and a
  submitter is wired.

## Verification

- `dart analyze lib tool db/migrations test` -> no issues found.
- Phase 9 sweep across 19 test files -> 553/553 passed.
- Focused Team checks:
  - `flutter test test/team_ux_kernel_test.dart` -> 28/28 passed.
  - `flutter test test/settings_screen_widget_test.dart` -> 29/29 passed.

## Live Calls And Mutations

Executed:

- Staging and Production1 database migration applies listed above.
- Staging-only Firebase smoke user create/update.
- Staging-only smoke auth rows.
- Staging Firebase credential smoke.
- Staging `auth_sessions` insert/refresh/revoke smoke.

Not executed:

- No Production1 operator data load.
- No Production1 Firebase/user mutation.
- No provider calls to Anthropic or Voyage.
- No Cloud Armor or reCAPTCHA dashboard mutation.
- No iOS/macOS build verification.
- No full in-app Firebase login smoke yet.

## Remaining Gate

The next auth slice is the proxy auth endpoint tranche, starting with a
client-safe session-ledger endpoint and client writer. Without that endpoint,
the Flutter app correctly fails closed on sign-in because it cannot record an
`auth_sessions` row without direct database access.
