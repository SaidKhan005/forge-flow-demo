# Phase 9 Execution Backlog

Updated: 2026-04-28.

Purpose: track real follow-up work discovered during the automated Phase 9
slice loop. This keeps recurring stale review findings separate from actual
remaining execution gates.

Decision source: `phase_9_decision_lock_2026-04-26.md` and the 35-item lock
in `phase_9_scalability_decisions_2026-04-27.md` (absorbed 2026-04-28; B23-B32
parcels below).

Pre-2026-04-28 checkpoint archived at
`docs/archive/phases/phase_9/phase_9_context_checkpoint.md`.

## Not Backlog: Stale Findings Already Resolved

Do not re-open these unless the repo regresses:

- `user_roles_active_grant_idx` is tenant-leading on
  `(operator_id, user_id, role_id, coalesce(location_id, ...))`.
- `auth_events_audit_actor_occurred_idx` and
  `auth_events_audit_target_occurred_idx` both lead with `operator_id`.
- `scripts/use_postgres_staging_env.ps1` uses `return`, not `exit`, on
  dot-sourced failure paths.
- `scripts/postgres_staging_setup.ps1` includes the expanded Azure extension
  and `shared_preload_libraries` requirements.
- The 11a staging apply report records the 7-day staging backup gap and B1ms
  PgBouncer limitation; Production1 records the production-ready posture.
- Phase 9 auth-table RLS on staging now has both row policies and table
  privileges: `202604260000_auth_rls_per_tenant_policies.sql` plus
  `202604260001_auth_rls_service_role_grants.sql`.
- Phase 9 auth-table RLS and grants are now also applied and verified on
  Production1.
- 9.0a live database closeout is applied and verified on staging and
  Production1, including `user_roles.scope_type`, `users.primary_location_id`,
  `operators.region`, 12 `team.*` keys, and the super_admin team-grant
  audit-fix migration.

## Scalability Foundation Progress

As of 2026-04-28, B23 / `9.0Σ.b`, B24 / `9.0Σ.c`, and B26 / `9.0Σ.e` are
complete and double-checked in the local line. B25 / `9.0Σ.d` exists
upstream/parallel and must be fast-forward verified in this live-closeout
worktree before it counts as local evidence. B27-B32 remain queued, but are
paused behind the 9 live-closeout stability freeze. Do not start `9.0Σ.f` or
later feature slices until maintenance/backlog/test status stays green and the
remaining live-closeout gates are explicitly cleared.

## Captured Before Next Feature Addition

2026-04-28 repo/backlog sweep:

- User directive for this checkpoint: no new feature additions until this
  phase is 100% stable. Use this section and
  `phase_9_maintenance_stability_sweep_result.md` as the maintenance baseline;
  keep B27-B32 paused while any regression, smoke, or live-closeout blocker is
  open.

- Retried the current non-repo `FIREBASE_AUTH_SMOKE_EMAIL` /
  `FIREBASE_AUTH_SMOKE_PASSWORD` Firebase password sign-in before proceeding.
  It initially returned Firebase `INVALID_LOGIN_CREDENTIALS` before any proxy
  mutation. Maintenance then reset/reconfirmed the dedicated staging smoke
  user's Firebase password, updated `$HOME/.forge_flow/forge_flow.secrets.ps1`,
  and verified password sign-in plus deployed proxy permission snapshot.
  Snapshot verification returned 80 permissions with `team.users.view=allow`
  and `team.users.invite=allow`.
- Older B6/B8/B14/B15/B17/B19/B20/B21 backlog text has been reconciled with
  the 2026-04-28 live auth-operation, password-change, bootstrap, and runbook
  result docs below. Remaining live-closeout gates are green on
  staging/local/GitHub, with explicit Production1 approval still required for
  any Production1 mutation. Final local analyzer/test gates are green after the
  staging repairs and tracker updates.
- Live MFA adapter gap narrowed on 2026-04-28: the proxy now has an Identity
  Toolkit REST MFA adapter, focused tests, and staging revision
  `forge-flow-staging-proxy-00017-pcz` deployed with Secret Manager-backed
  runtime config. Direct provider start/finalize/withdraw cleanup passed; proxy
  password sign-in, permission snapshot, TOTP begin/confirm, recovery-code
  consume, recovery-attempt ledger, and cleanup passed against a disposable
  staging user.
- Cloud Armor/reCAPTCHA was provisioned on staging after explicit approval:
  reserved IP `34.54.204.29`, serverless NEG/backend service, preview-only
  Cloud Armor WAF rule, HTTP(S) forwarding, and reCAPTCHA Enterprise score key
  `6LeBDc8sAAAAAO7QL0_qelJwl-f4QmCEktP-qlM4` for
  `staging-api.feflow.org`. HTTP edge `/readyz` smokes via forced resolve pass.
  DNS and managed certificate issuance remain pending.
- Security hygiene follow-up closed for staging proxy deploy config: sensitive
  runtime config now deploys as Secret Manager-backed env refs. No values were
  copied into docs.
- Backlog alignment note: local `master` is behind `origin/master`; the
  service-principal 9.0Σ.d commit exists upstream/parallel, but the current
  dirty live-closeout worktree does not contain the `service_principals`
  migration/repository yet. Keep the existing 9.0Σ.d.1 fast-forward
  verification queued after live-closeout changes are safely merged.
- Focused analyzer initially caught a stale wrapper signature in
  `lib/services/auth/invited_user_activation_ledger_writer.dart`
  (`authorizationIdToken` was still being forwarded after the
  `AuthSessionLedgerWriter` seam narrowed). The wrapper now mirrors the current
  seam; follow-up analyzer is clean.
- `docs/KNOWN_FAILING_TESTS.md` still owns the unrelated
  `test/labor_model_boh_sales_test.dart` failures. Maintenance fixed the stale
  test fixture to pass explicit demand (`historicalWeeklyAvgCovers`) under the
  current honest-demand contract. The known-failing list is now empty.
- Broad local gates after maintenance:
  `flutter analyze --fatal-infos` reported no issues, `flutter test` passed
  2323/2323, `dart run tool/rls_policy_lint.dart` reported clean, and
  `git diff --check` reported only CRLF normalization warnings.

## Backlog Items

### Covered Framework Slices

- `9.0`: no open schema backlog; repeated tenant-leading index findings are
  stale and listed above as resolved.
- `9.1-9.3`: live/production closeout work is tracked in B1-B10 below.
- `9.4-9.9`: framework slices are accepted in the checkpoint; new follow-ups
  are tracked in B11-B21 below.

### B1 - Production RS256 Firebase Signature Validator

Source: `9.1` checkpoint.

Status: completed on 2026-04-26.

Needed before: live Firebase JWT smoke and any authenticated proxy traffic.

Work:

- Choose and wire a Dart RSA/RS256 implementation, likely `pointycastle`.
- Implement production `JwtRs256SignatureValidator`.
- Parse Firebase x509/JWKS material safely.
- Replace `ScaffoldFailingRs256SignatureValidator` in
  `tool/advisor_proxy/main.dart`.
- Keep local tests deterministic with injected accept/reject validators.

Resolution:

- Added `PointyCastleRs256SignatureValidator`.
- `tool/advisor_proxy/main.dart` now wires it when `FIREBASE_PROJECT_ID` is
  present.
- Live Firebase sign-in/exchange plus local RS256 verifier smoke passed on
  staging; the one-off smoke user was deleted.

### B2 - Production Postgres Driver Binding

Source: `9.2` checkpoint.

Status: completed on 2026-04-26.

Needed before: auth session ledger writes, live RLS exercise, and production
database-backed auth operations.

Work:

- Implement `PostgresPool`, `PostgresTransaction`, and `PostgresExecutor`
  against the real Dart Postgres driver.
- Preserve the existing `TenantTransactionWrapper` `SET LOCAL` contract.
- Add focused tests that the production binding cannot bypass tenant context.

Resolution:

- Added `PackagePostgresPool` / transaction adapter under
  `lib/infrastructure/persistence/postgres/`.
- Added `postgres` dependency and fake-backed adapter tests.

### B3 - Staging RLS Flip For Phase 9 Auth Tables

Source: `9.2` checkpoint.

Status: completed for staging on 2026-04-26 and Production1 on 2026-04-27.

Needed before: Phase 9 live RLS acceptance.

Human gate: closed. Production1 apply was explicitly authorized during the
2026-04-27 closeout loop.

Work:

- Apply `db/migrations/202604260000_auth_rls_per_tenant_policies.sql` to
  staging, then Production1 after authorization.
- Verify `forge_admin`, dropped service-role-only stubs, per-tenant policies,
  negative tenant smoke, and BYPASSRLS positive smoke.
- Production1 apply must use the same verification as staging.

Resolution:

- Applied `202604260000_auth_rls_per_tenant_policies.sql` to staging only.
- Added and applied `202604260001_auth_rls_service_role_grants.sql` after live
  smoke found that policies without table grants denied `service_role` before
  RLS evaluation.
- Verified `forge_admin` BYPASSRLS, service_role membership, 12 auth tables
  with RLS, 16 expected policies, zero old auth service-role stubs,
  `permission_keys` SELECT-only, mutable auth DML grants, audit append-only
  grants, negative bogus-tenant read, and forge_admin positive read.
- Production1 closeout applied the same two RLS/grant migrations and verified
  12 auth tables with RLS, 16 policies, tenant-leading auth indexes, and
  append-only `auth_events_audit` grants for `service_role` and `forge_admin`.

### B4 - Firebase Auth Client Binding

Source: `9.3` checkpoint.

Status: completed for mobile runtime wiring on 2026-04-27.

Needed before: live login smoke and real app login.

Work:

- Implement production `AuthLoginService` using `firebase_auth` /
  `firebase_auth_web`.
- Preserve `AuthLoginSuccess`, `AuthLoginMfaRequired`, and
  `AuthLoginFailure` result contracts.
- Keep the scaffold-failing service as the fail-closed default.

Resolution (framework):

- Added `FirebaseAuthClient` adapter interface
  (`signInWithEmailPassword`, `completeTotpChallenge`,
  `requestPasswordReset`, `refreshIdToken`, `signOut`,
  `revokeAllRefreshTokens`) + `FirebaseAuthSignInOutcome` sealed
  hierarchy + `FirebaseAuthCredential`.
- Added `ScaffoldFailingFirebaseAuthClient` fail-closed default.
- Added production `FirebaseAuthLoginService implements AuthLoginService`
  that translates outcomes into `AuthLoginSuccess` /
  `AuthLoginMfaRequired` / `AuthLoginFailure`. Builds `AuthSession`
  from JWT custom claims (`operator_id`, `is_super_admin`,
  `is_ff_support`, `roles_version`, `mfa_enrolled`); missing
  `operator_id` becomes `AuthLoginFailure(code: 'invalid_claims')`
  without echoing claim values. `AuthLocationResolver` /
  `FixedAuthLocationResolver` resolves the post-login location;
  `refreshSession` preserves the live session's `locationId`.
- Tokens never appear in `toString()` or error messages from this layer.

Resolution (SDK/app wiring):

- Added `firebase_core`, `firebase_auth`, `firebase_auth_web`, and
  `flutter_secure_storage` to `pubspec.yaml`.
- Added `FirebaseAuthSdkClient`, the only runtime file that imports
  `package:firebase_auth/firebase_auth.dart`. It maps email/password,
  TOTP challenge completion, password reset, ID-token refresh, sign-out,
  and Firebase errors into the existing low-friction auth result seam.
- Added `firebase_auth_runtime_bindings.dart`, gated in all app entrypoints
  by `--dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true`.
- Android Gradle wiring was verified for Forge & Flow and Barrio debug
  builds with and without the Firebase auth define.

Evidence:

- GitHub Apple run `25078391954` passed macOS host tests plus ForgeFlow and
  Barrio iOS simulator builds after the iOS deployment target was raised to
  15.0 for Firebase Auth.
- Web/admin runtime still needs a Dart `FirebaseOptions` binding before a
  browser launch.
- Full in-app login needs the proxy session-ledger endpoint; the app must not
  write directly to Postgres.

### B5 - Secure Session Storage Binding

Source: `9.3` checkpoint.

Status: completed for mobile runtime wiring on 2026-04-27.

Needed before: real mobile/web session persistence acceptance.

Work:

- Implement production `SecureSessionStorage` using `flutter_secure_storage`
  or the chosen platform-safe storage wrapper.
- Verify Keychain on iOS and Android Keystore on Android.
- Keep token values out of logs, errors, and widget text.

Resolution (framework):

- Added `PlatformSecureStorageBackend` adapter
  (`read` / `write` / `delete`).
- Added `ScaffoldFailingPlatformSecureStorageBackend` fail-closed default
  + `InMemoryPlatformSecureStorageBackend` for tests.
- Added production `PlatformSecureSessionStorage extends SecureSessionStorage`
  that persists the AuthSession JSON under the namespaced key
  `forge_flow.auth.session_v1` (versioned for future shape migrations).
- Tokens never echoed from this layer.

Resolution (SDK/app wiring):

- Added `FlutterSecureStorageBackend`, the only runtime file that imports
  `package:flutter_secure_storage/flutter_secure_storage.dart`.
- `createFirebaseAuthRuntimeBindings()` now returns production
  `PlatformSecureSessionStorage` backed by Flutter secure storage.
- Android debug builds passed with the Firebase auth define enabled.

Pending follow-up:

- GitHub Apple run `25078391954` passed the macOS host test lane. Device-only
  keychain behavior still belongs to later physical-device QA, but the
  macOS/Xcode runner gate is closed for this live-closeout slice.

### B6 - Auth Session Ledger Writes

Source: `9.3` checkpoint and `9.0` schema comments.

Status: completed and staging-smoked by 2026-04-28. Proxy session-ledger
endpoint (client-safe HTTP route + Flutter client writer) shipped on
2026-04-27, and production proxy boot now wires
`RepositoryAuthSessionLedgerWriter` through the Phase 9 route binding bundle.

Needed before: `auth_sessions` acceptance.

Work:

- INSERT on login.
- UPDATE `last_seen_at` on refresh.
- SET `revoked_at` on single-session and all-sessions logout.
- Ensure all writes go through tenant-scoped transactions and audit paths.

Resolution (framework):

- Added `AuthSessionsRepository` (extends `OperatorScopedRepository`):
  `insertLogin` (INSERT … RETURNING `session_id` through `withTenant`
  + SET LOCAL); `markRefreshed` (UPDATE `last_seen_at = now()`,
  skipping already-revoked rows); `revokeSession` (idempotent SET
  `revoked_at` + `revoked_reason`); `revokeAllSessionsForUser`
  (user-owned path) and `revokeAllSessionsForUserAsAdmin`
  (`withSystem`, audited via
  `app.bypass_rls_audit = 'system:<reason>'`). All parameters bound,
  never concatenated.
- Added `AuthSessionLedgerWriter` interface
  (`recordLogin` returns `session_id`, `recordRefresh`,
  `revokeSession`, `revokeAllSessionsForUser`),
  `AuthSessionLedgerLogin` + `AuthSessionLedgerContext` value
  classes (IP / UA / geo / device fingerprint),
  `ScaffoldFailingAuthSessionLedgerWriter` fail-closed default,
  `InMemoryAuthSessionLedgerWriter` for tests.
- Added `RepositoryAuthSessionLedgerWriter` production binding that
  wraps the repository.
- Wired the writer through `AuthSessionNotifier`: recordLogin runs
  on signIn success with SHA-256 hex digest of the live Firebase
  **ID token** as `token_hash` (column was renamed from
  `refresh_token_hash` on 2026-04-27 — Codex audit-fix F4 — because
  `firebase_auth` does not surface the refresh token, so the writer
  cannot detect refresh-token reuse on its own today; the column
  name no longer over-promises); recordRefresh on `refreshSession`;
  revokeSession on `signOutThisSession`; revokeAllSessionsForUser
  on `signOutAllSessions`. Refresh + sign-out ledger errors logged
  but non-fatal. Sign-in fails closed on ledger error (audit-fix
  2026-04-27 Codex F2/F3 — surfaces calm `ledger_unavailable`
  AuthLoginFailure rather than entering AuthSessionAuthenticated
  without an `auth_sessions` row). Audit-fix 2026-04-27 Codex F1:
  persisted shape is now an envelope (`StoredAuthSession`) carrying
  the `auth_sessions.session_id` so cold-start rehydrate restores
  `_activeSessionId` and post-restart refresh / sign-out address the
  original ledger row.
- Bootstrap defaults `authSessionLedgerWriter` to scaffold-failing.

Resolution (proxy session-ledger endpoint, 2026-04-27):

- Added four POST routes in `tool/advisor_proxy/advisor_proxy.dart`:
  `/v1/auth/session/login`, `/v1/auth/session/refresh`,
  `/v1/auth/session/revoke`, `/v1/auth/session/revoke-all`. Every
  route flows through `ProxyRequestGuard.requireOperatorContext`
  (existing Firebase verifier path), parses a JSON body, and
  delegates to an injected `AuthSessionLedgerWriter`. The proxy
  resolves IP / UA / geo from request headers (X-Forwarded-For /
  User-Agent / X-Country) so the row carries trusted enrichment;
  clients never inject these fields. Response shape is narrow:
  `{session_id, user_id, operator_id, location_id}` for login,
  `{ok: true}` for refresh / revoke, `{ok: true, revoked_count}`
  for revoke-all. Bearer tokens, `token_hash` values, and writer
  exception text NEVER leak through the response body.
- `tool/advisor_proxy/main.dart` originally defaulted the writer to
  `ScaffoldFailingAuthSessionLedgerWriter` so a misconfigured deploy
  returned 503 from the four routes instead of silently dropping ledger rows.
  The 2026-04-28 production bootstrap reconciliation replaced that default in
  live route binding with `RepositoryAuthSessionLedgerWriter` over
  `PackagePostgresPool`.
- Added `lib/services/auth/proxy_auth_session_ledger_writer.dart`:
  `ProxyAuthSessionLedgerWriter implements AuthSessionLedgerWriter`
  drives the four routes from the Flutter app via `dart:io HttpClient`
  with a 10s timeout and an Idempotency-Key header on every write.
  `ProxyHttpJsonClient` is the testable seam (production binding
  `DartIoProxyHttpJsonClient`; scaffold-failing default). The writer's
  ID-token provider is wired to `FirebaseAuthClient.currentIdToken()`
  (new method on the existing seam) so refresh / revoke calls fetch
  the live cached token at call time. Errors map to a narrow
  `ProxyAuthSessionLedgerError` with `code` / `statusCode`; transport
  failures collapse to `transport_error` so the underlying exception
  text (which may carry connection strings) never propagates.
- `lib/services/auth/firebase_auth_runtime_bindings.dart` accepts an
  optional `proxyBaseUri`. When supplied, the bindings build the
  production `ProxyAuthSessionLedgerWriter` and expose it on
  `FirebaseAuthRuntimeBindings.authSessionLedgerWriter`. App
  entrypoints (`main_forgeflow.dart`, `main_barrio.dart`) read
  `FORGE_FLOW_PROXY_BASE_URI` from `--dart-define`; without it the
  bindings expose `null` and the bootstrap falls back to the
  scaffold-failing default — sign-in then fails closed with a calm
  `ledger_unavailable` message instead of silently writing nothing.
- Tests: 13 new server-side route cases in `test/advisor_proxy_test.dart`
  (auth-required / scope-required / body-validation / happy-path /
  writer-503 / no-stack-leak per route) + 12 new client-writer cases
  in `test/proxy_auth_session_ledger_writer_test.dart` (URL / headers /
  body shape / error mapping / ID-token-missing / transport-error /
  wire-contract sanity asserting the writer's path constants match
  the proxy's exported route constants byte-for-byte).

Pending follow-up:

- Idempotency: the proxy currently accepts the `Idempotency-Key`
  header but does not yet enforce it. A future slice will integrate
  the `proxy_requests` table so a retried POST returns the prior
  result instead of creating a duplicate `auth_sessions` row. Until
  then, a client retry can produce an orphan row that the dormancy
  sweep / admin force-logout-all reaps.
- Push the proxy's resolved IP / UA / geo back to the client via a
  response header so `AuthSessionLedgerContext._defaultLedgerContextFactory`
  can carry them on the next call (today the proxy already enriches
  from request headers server-side — this is purely about surfacing
  the resolved values on the client side for diagnostics).

### B7 - iOS Firebase/Xcode/Pod Verification

Source: `9.1` / `9.3` checkpoints.

Status: pending macOS session.

Needed before: iOS launch acceptance.

2026-04-28 Windows-side static check:

- `ios/Runner/Firebase/GoogleService-Info-ForgeFlow.plist` and
  `ios/Runner/Firebase/GoogleService-Info-Barrio.plist` are present.
- `ios/Runner.xcodeproj/project.pbxproj` includes a `Copy Firebase Config`
  shell phase that selects the plist by `PRODUCT_BUNDLE_IDENTIFIER`.
- ForgeFlow/Barrio flavor xcconfigs and target build configurations are
  present.
- No `macos/` platform directory exists in this repo.

Work:

- Wire `GoogleService-Info.plist` files into Xcode schemes/configurations.
- Run iOS build/login verification on macOS.
- Report honestly if Windows-side work cannot verify this.

### B8 - Live Staging Login Smoke

Source: `9.3` checkpoint.

Status: completed on 2026-04-28. Backend credential/session smoke,
proxy session-ledger endpoint, Flutter client writer, and full in-app
login/persistence/logout all passed. The 2026-04-27 prerequisite report
covered the session-ledger deploy env; the later Phase 9 production route
bootstrap also requires `FIREBASE_WEB_API_KEY` alongside
`FIREBASE_PROJECT_ID`, `POSTGRES_URL`, and `POSTGRES_ADMIN_URL` before the
next auth-operation deploy.

Needed before: live `9.3` acceptance.

Human gate: approve live Firebase/staging use and confirm or create
`auth-smoke@forgeflow.dev`.

Work:

- Sign in with the dedicated staging test user.
- Verify session persistence, step-up freshness, logout, and audit/session
  writes.
- Do not use Production1 or real operator users.

Completed smoke:

- Staging-only `auth-smoke@forgeflow.dev` account was created/updated in
  Firebase Identity Platform. Password lives only in the non-repo secrets
  loader.
- Matching staging Postgres operator, location, user, operator_admin, and
  role-grant rows were inserted for the smoke account.
- Firebase email/password sign-in succeeded via the Identity Toolkit API; the
  returned ID-token claims carried the expected `user_id`, `operator_id`,
  `location_id`, `roles_version`, and `mfa_enrolled` values. Token values were
  not printed.
- `auth_sessions` insert, refresh, and revoke were exercised on staging
  through the repository-compatible table path and verified as revoked with
  reason `phase_9_auth_smoke_complete`.

Post-closeout credential note:

- A 2026-04-28 retry using the previous non-repo
  `FIREBASE_AUTH_SMOKE_PASSWORD` returned Firebase
  `INVALID_LOGIN_CREDENTIALS`. The dedicated smoke user's password has since
  been reset/reconfirmed, the non-repo secrets loader updated, and password
  sign-in plus deployed proxy permission snapshot verified.
### B9 - Admin Web Security Headers / Observatory

Source: `9.3` checkpoint.

Status: deferred to admin web shell.

Needed before: admin web launch acceptance.

Work:

- Add CSP, HSTS, X-Frame-Options, and secure cookie flags in the web shell.
- Verify with Mozilla Observatory when a deployable admin web endpoint exists.

### B10 - Cloud Foundation RLS Stub Flip

Source: `9.2` checkpoint.

Status: deferred; not part of the 12 Phase 9 auth-table RLS migration.

Needed before: full cloud-foundation tenant-enforcement acceptance.

Work:

- Coordinate a separate migration for `operators`, `locations`, `users`,
  `operator_admins`, usage, proxy request, and feature flag policies.
- Keep Lock 4 tenant-leading-index discipline.
- Do not mix this with auth-table RLS unless explicitly scoped.

### B11 - Firebase Auth MFA Binding

Source: `9.4` checkpoint.

Status: local SDK/app challenge wiring and proxy Identity Toolkit REST adapter
completed by 2026-04-28. Staging proxy TOTP begin/confirm and recovery-code
consume passed with disposable-user cleanup.

Needed before: live MFA enrollment/challenge acceptance.

Work:

- Implement `MfaEnrollmentService` against Firebase Auth /
  Identity Platform TOTP MFA.
- Preserve the existing framework result types and fail-closed scaffold.
- Verify TOTP enrollment/challenge with staging only after live approval.

Resolution (framework):

- Added `FirebaseMfaClient` adapter (`beginTotpEnrollment`,
  `confirmTotpEnrollment`, `unenrollFactor`) +
  `FirebaseMfaTotpBeginPayload` + sealed
  `FirebaseMfaConfirmOutcome`.
- Added `ScaffoldFailingFirebaseMfaClient` fail-closed default.
- Added production
  `FirebaseMfaEnrollmentService implements MfaEnrollmentService`
  composing the adapter with `RecoveryCodeGenerator` +
  `RecoveryCodeHasher` + `RecoveryCodeSaltSource`. Preserves
  the existing `MfaEnrollmentConfirmSuccess` / `MfaEnrollmentConfirmFailure`
  contract.
- TOTP secrets + otpauth URLs never echoed by the adapter layer.

Resolution (runtime adapters):

- App sign-in/challenge uses `FirebaseAuthSdkClient` and Flutter
  `firebase_auth` TOTP APIs behind `FORGE_FLOW_USE_FIREBASE_AUTH=true`.
- Proxy enrollment/withdraw uses `IdentityToolkitFirebaseMfaClient`, the
  server-safe Identity Toolkit REST adapter, behind the production
  `RepositoryMfaOperationsGateway`. Live provider verification corrected this
  adapter to the API-key-plus-user-ID-token contract for the v2 MFA endpoints.
- Direct staging provider smoke passed start, finalize, lookup, and withdraw
  cleanup without printing token/secret/code values.
- Deployed proxy revision `forge-flow-staging-proxy-00017-pcz` passed TOTP
  begin/confirm plus recovery-code consume with disposable-user cleanup.

Pending follow-up:

- B7 macOS/Xcode verification remains required before iOS launch acceptance.

### B12 - MFA Persistence And Recovery-Code Consumption

Source: `9.4` checkpoint.

Status: local proxy orchestration and Identity Toolkit MFA adapter completed on
2026-04-28. Staging TOTP begin/confirm and recovery-code consume passed with
disposable-user cleanup.

Needed before: live MFA and recovery-code acceptance.

Work:

- Persist `mfa_factors` rows for TOTP and recovery codes.
- Set `used_at` on recovery-code consumption.
- Ensure recovery-code hashes stay salted, one-way, and never logged.

Resolution (framework):

- Added `MfaFactorsRepository` (extends `OperatorScopedRepository`):
  `insertTotpFactor` (returns factor_id; metadata carries
  `firebase_factor_uid` + issuer); `insertRecoveryCodeFactor`
  (one row per code, metadata carries `{salt, hash}`);
  `markRecoveryCodeUsed` (sets `last_used_at` AND `revoked_at`
  so the row never matches again — single-use enforcement);
  `revokeTotpFactor` (24h removal flow); `listActiveRecoveryCodeFactors`
  for the consumer iteration. Parameters bound; metadata
  serialized via `jsonEncode` and bound as text + `::jsonb` cast.
- Added `RecoveryCodeConsumer` orchestrating limiter + repository +
  hasher (see B13 below) — the actual consumption path.

2026-04-28 local closeout:

- Added `MfaFactorsRepository.insertTotpEnrollment` so the proxy persists the
  TOTP row and all hashed recovery-code rows inside one tenant transaction.
- Added `RepositoryMfaOperationsGateway` to chain Firebase MFA enrollment
  output, local persistence, recovery-code consumption, and append-only audit
  rows.
- Added proxy routes:
  `POST /v1/auth/mfa/totp/begin`,
  `POST /v1/auth/mfa/totp/confirm`, and
  `POST /v1/auth/mfa/recovery/consume`.
- Added app-side `ProxyMfaOperationsGateway` and runtime binding through
  `FORGE_FLOW_PROXY_BASE_URI`.
- Added `IdentityToolkitFirebaseMfaClient` for Cloud Run TOTP
  begin/finalize/withdraw and latest-factor lookup through Identity Toolkit
  REST. The proxy passes the already verified Authorization ID token into the
  adapter without logging or returning token values. The adapter uses the
  project API key path verified by live staging TOTP smoke.

Pending follow-up:

- The Firebase Admin SDK call for `revokeRefreshTokens(uid)` (paired with
  `mfa_factor_revocation_completed` audit event) belongs in the MFA removal
  slice.

### B13 - Recovery-Code Attempt Rate Limits

Source: `9.4` / `9.5` checkpoints.

Status: Postgres-backed attempt store completed locally and smoked on staging
on 2026-04-28.

Needed before: live recovery-code acceptance.

Work:

- Enforce 1/minute and max 5/24h recovery-code attempt limits.
- Store counters/audit through the proxy Postgres path.
- Fail closed if the counter store is unavailable.

Resolution (framework):

- Added `RecoveryCodeAttemptStore` interface +
  `InMemoryRecoveryCodeAttemptStore` (tests / dev) +
  `ScaffoldFailingRecoveryCodeAttemptStore` fail-closed default.
- Added `RecoveryCodeAttemptLimiter` enforcing the locked
  policy (1/min + 5/24h). Returns sealed
  `RecoveryCodeAttemptDecision` so the consumer can surface the
  right error with `retryAfter` / `resetsAt`.
- Added `RecoveryCodeConsumer` end-to-end orchestration:
  rate check → list factors → constant-time hash verify each →
  mark first match used → return outcome. Every attempt
  (valid + invalid + already-used) burns one budget slot per
  the locked policy.
- Same generic outcome surfaced for invalid-vs-already-used so
  an attacker cannot distinguish "wrong code" from
  "right code, already burned".

2026-04-28 local closeout:

- Added migration
  `db/migrations/202604280011_phase_9_recovery_code_attempts.sql` with a
  dedicated `recovery_code_attempts` table, tenant RLS via
  `public.app_current_operator()`, and grants to `service_role` /
  `forge_admin`.
- Added `PostgresRecoveryCodeAttemptStore` for durable prune/read/write
  attempt tracking behind `RecoveryCodeAttemptLimiter`.
- Proxy recovery-code consume now maps invalid/already-used to the same
  generic rejection and preserves retry metadata for rate-limit responses.

Pending follow-up:

- Recovery-code consume staging smoke recorded the durable
  `recovery_code_attempts` ledger entry and cleaned up disposable Firebase and
  Postgres state.

### B14 - HIBP Egress Policy

Source: `9.5` checkpoint.

Status: completed through the 2026-04-28 staging password-change smoke.

Needed before: live password-screening acceptance.

Work:

- Allow outbound HTTPS to the HIBP range API from the proxy runtime.
- Add per-IP HIBP cap guidance (100/minute).
- Keep k-anonymity behavior: only SHA-1 prefix leaves the system.

Evidence:

- `phase_9_password_change_orchestration_result.md` records
  `hibp_unavailable=false` during the live password-change smoke on
  `forge-flow-staging-proxy-00013-zx8`.

### B15 - Password History Persistence

Source: `9.5` checkpoint.

Status: completed and staging-smoked on 2026-04-28.

Needed before: live password-change acceptance.

Work:

- Bind `PasswordHistoryCheck` to `password_history`.
- Write new password-history rows after successful changes.
- Preserve fail-closed behavior on history-store outage where policy requires.

Evidence:

- `RepositoryPasswordChangeGateway` now checks and records password history.
- Staging password-change smoke showed `password_history_count=1`.

### B16 - Cloud Armor And reCAPTCHA Setup

Source: `9.5` checkpoint.

Status: staging edge provisioned after explicit approval; DNS/certificate
pending.

Needed before: brute-force-protection launch acceptance.

Human gate: explicit cloud dashboard / infrastructure authorization. Staging
setup was approved on 2026-04-28; Production1 remains locked.

2026-04-28 read-only inventory:

- `forge-flow-staging-proxy` latest ready revision is
  `forge-flow-staging-proxy-00013-zx8`.
- The proxy is directly exposed through Cloud Run with ingress `all` and
  unauthenticated invoker access enabled.
- `gcloud compute backend-services list --global` returned no backend
  services for `forge-flow-staging`.
- `gcloud compute security-policies list` returned no Cloud Armor policies.
- `gcloud recaptcha keys list` could not list keys because reCAPTCHA
  Enterprise API is disabled for `forge-flow-staging`.

2026-04-28 staging setup:

- Reserved global IP `ff-staging-proxy-ip`: `34.54.204.29`.
- Created serverless NEG `ff-staging-proxy-neg`, backend service
  `ff-staging-proxy-backend`, URL map, HTTP/HTTPS proxies, forwarding rules,
  and managed certificate `ff-staging-proxy-cert` for
  `staging-api.feflow.org`.
- Attached Cloud Armor policy `ff-staging-proxy-armor` with a preview-only
  `sqli-stable` / `xss-stable` preconfigured WAF deny rule.
- Enabled reCAPTCHA Enterprise and created staging score key
  `6LeBDc8sAAAAAO7QL0_qelJwl-f4QmCEktP-qlM4` for
  `staging-api.feflow.org`, WAF session-token integration.
- Forced HTTP edge smoke to `http://staging-api.feflow.org/readyz` via
  `34.54.204.29` returned 200.

Blocker:

- Porkbun DNS now resolves `staging-api.feflow.org A 34.54.204.29`, and HTTP
  `/readyz` passes on the real hostname. The managed certificate is `ACTIVE`,
  and HTTPS `/readyz` passes on the real hostname.
- Cloud Armor preview-log review passed after controlled staging-only probes:
  requests returned 200 while logs recorded preview-only DENY matches at
  priority 1000 for preconfigured WAF expressions. Keep WAF enforcement off
  until normal traffic has enough preview data for false-positive review.
- The Cloud Armor WAF rule is preview-only and should stay there until logs are
  reviewed. Backend token verification / route-level reCAPTCHA enforcement is
  still a later app decision, not part of this edge bootstrap.

Work:

- Review Cloud Armor preview logs after DNS/certificate is live, then decide
  whether to enforce.
- Wire risk telemetry to the configured controls.
- Do not perform dashboard/cloud mutation without explicit approval.

### B17 - Role/Admin HTTP Endpoints And roles_version Bump

Source: `9.6` checkpoint.

Status: partially completed and staging-smoked on 2026-04-28.

Needed before: live role-management acceptance.

Work:

- Add `/v1/admin/auth/roles/*` and
  `/v1/admin/auth/role-grants/*` proxy endpoints.
- Load grants/rules through tenant-scoped Postgres paths.
- Bump `users.roles_version` on every role/grant change.
- Write audit rows for every role/grant mutation.

Resolution so far:

- `/v1/admin/auth/role-grants` create and revoke routes are implemented,
  proxy/client contract-tested, and live-smoked on staging.
- Grant/revoke bumps `users.roles_version`, refreshes Firebase custom claims,
  and writes append-only audit rows.

Remaining:

- Custom role definition endpoints under `/v1/admin/auth/roles/*` remain for
  the fuller Settings -> Team role-management surface.

### B18 - Bulk PermissionGate Migration

Source: `9.7` checkpoint.

Status: completed on 2026-04-27 via resolver-injection pattern.

Needed before: full permission-gate acceptance across Forge & Flow / Barrio.

Work:

- Replace the remaining `BarrioPreviewRole.isIntendedFor(...)` callsites with
  `PermissionGate(permissionKey: ...)` or equivalent permission-runtime checks.
- Remove chip-driven preview-tier assumptions where no longer needed.
- Keep dev/preview ergonomics only where explicitly protected by tests.

Resolution:

- Added `BarrioDestinationVisibilityResolver` and
  `PermissionContextBarrioVisibilityResolver`.
- Wired Barrio hub/home visibility through the resolver so production can use
  `PermissionContext` while dev/preview keeps explicit fallback ergonomics.

### B19 - Proxy-Side Permission Guard

Source: `9.7` checkpoint.

Status: completed for the Phase 9 auth-operation routes on 2026-04-28.

Needed before: authenticated admin API acceptance.

Work:

- Add proxy request gating for `/v1/admin/*`.
- Load `user_roles` + `role_permissions` per request.
- Enforce default-deny, explicit-deny-wins, tenant/location scope, and MFA
  freshness for MFA-required keys.

Resolution:

- `RepositoryProxyPermissionSnapshotResolver` and
  `RepositoryProxyAdminPermissionGuard` are now wired by production proxy
  bootstrap.
- Live permission snapshot for the staging admin actor returned
  `team.users.view=allow` and `team.users.invite=allow`; auth-op routes reject
  before gateway delegation when the guard denies.

Remaining:

- Route-specific fresh-MFA enforcement for MFA-required actions continues with
  the live MFA deploy smoke lane.

### B20 - User Lifecycle Audit And Persistence Binding

Source: `9.8` checkpoint.

Status: partially completed and staging-smoked on 2026-04-28.

Needed before: live user-lifecycle acceptance.

Work:

- Persist invite acceptance, status transitions, soft-delete, force-logout,
  reset-password, and GDPR request state through tenant-scoped Postgres paths.
- Write `auth_events_audit` rows for every user lifecycle transition.
- Ensure transition audit payloads never contain raw tokens or private PII
  beyond the allowed operational fields.

Resolution so far:

- Invite create/revoke, invited-recipient acceptance, suspend/reactivate,
  soft-delete, admin password reset, and role grant/revoke are implemented
  through proxy/repository paths and live-smoked on staging.
- Auth-session revoke-all exists for signed-in user logout-all and force-logout
  repository support.

Remaining:

- Operator-facing admin force-logout action wiring and GDPR erasure request
  execution surface remain separate follow-ups. The runbook and redaction
  template are complete; production execution stays gated.

### B21 - GDPR Erasure Runbook

Source: `9.8` checkpoint.

Status: completed locally on 2026-04-27.

Needed before: operational GDPR erasure acceptance.

Work:

- Create `runbooks/gdpr_erasure_runbook.md`.
- Document paired-super-admin approval, soft-delete prerequisite, Art. 17(3)
  preserved fields, exact redaction payload, rollback limitations, and audit
  evidence.
- Keep the runbook aligned with `ErasureRedactionTemplate`.

Resolution:

- `runbooks/gdpr_erasure_runbook.md` exists and documents paired approval,
  soft-delete prerequisite, no-self-approval, irreversible execution, preserved
  Art. 17(3) fields, runtime redaction paths, and break-glass audit-log
  redaction.
- `test/user_lifecycle_live_binding_test.dart` checks runbook alignment with
  `ErasureRedactionTemplate`.

### B23 - 9.0Σ.b RLS UUID Wrapper Functions

Source: `phase_9_scalability_decisions_2026-04-27.md` item 4.

Status: completed and double-checked on 2026-04-28.

Needed before: any operator-scoped RLS policy added after 2026-04-28; gates
all future fact-table policies + the `9.0g` `usage_caps` two-slot key
rewrite.

Work:

- Add SQL functions `app_current_operator()`, `app_current_location()`,
  `app_current_actor_user()`, `app_acting_as_operator()`. All declared
  `RETURNS uuid LANGUAGE sql STABLE LEAKPROOF PARALLEL SAFE` and reading
  the corresponding `app.*` GUC via `current_setting(..., true)` with a
  NULL-safe cast.
- Migration in `db/migrations/`. Backfill existing 12 auth-table RLS
  policies + the cloud-foundation policies to call the wrappers instead
  of bare `current_setting(...)::uuid` literals.
- Add CI lint that fails if a new policy references
  `current_setting('app.current_operator_id'...)` or any other bare
  `app.*` GUC literal in operator-scoped policies; only the wrapper
  functions are allowed. The lint must run in `analysis_options.yaml`
  / pre-commit / GitHub Actions.
- Apply on staging; verify 12 auth-table policies still bypass for
  `forge_admin` and deny on bogus tenant.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_b_rls_wrappers.sql`
- `db/migrations/202604XXXXXX_phase_9_0sigma_b_rewrite_existing_policies.sql`
- `analysis_options.yaml` lint config (or a dedicated tool script).

Gate: post-apply staging smoke must show every operator-scoped policy
calling a wrapper, and the lint must reject a synthetic violator commit.

Resolution:

- Added RLS UUID wrapper functions for app GUC reads.
- Rewrote existing auth-table RLS policies to use wrappers instead of bare
  `current_setting('app.*')` reads.
- Added policy-aware lint plus allowlist for the superseded historical
  migration.
- Wired the lint into CI.
- Added wrapper/rewrite/lint coverage tests.
- Fixed the CRLF-sensitive test issue and the lint gap for unquoted policy
  names.

Verification:

- `dart run tool/rls_policy_lint.dart`.
- `dart analyze tool/rls_policy_lint.dart test/phase_9_0sigma_b_rls_wrappers_test.dart`.
- `flutter test test/phase_9_0sigma_b_rls_wrappers_test.dart` passed 14/14.
- `flutter analyze --fatal-infos`.

### B24 - 9.0Σ.c org_units ltree + data_region

Source: `phase_9_scalability_decisions_2026-04-27.md` items 1, 19.

Status: completed and double-checked on 2026-04-28.

Needed before: any code path that consumes corp/region/district/location
hierarchy — internal admin/dev access surface (Q1), franchisee billing
rollups (`9.0g`), and multi-region future-proofing (Q8).

Work:

- Migration creating `org_units(id uuid pk, operator_id uuid, parent_id
  uuid, unit_type text check (unit_type in
  ('corp','region','district','location_group')), path ltree, name text,
  created_at timestamptz, ...)`.
- GiST index on `path`; depth ≤ 6 enforced by check constraint or
  trigger.
- Add `data_region` column on `operators` (default `'CA-CENTRAL'`).
- Repository: `OrgUnitsRepository extends OperatorScopedRepository`.
- Backfill: every existing operator gets a single root `corp` row
  during the migration.
- Verify on staging + Production1 (subject to live-mutation approval
  per Phase 9 lock).

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_c_org_units.sql`
- `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart`
- Tests under `test/`.

Gate: GiST index present; depth-6 constraint rejects depth-7 inserts;
RLS reads bypass-RLS for `forge_admin`, deny cross-tenant.

Resolution:

- Added migration
  `db/migrations/202604280002_phase_9_0sigma_c_org_units.sql`.
- Migration enables `ltree`, adds `operators.data_region` default
  `'CA-CENTRAL'`, creates `org_units`, enforces unit-type and depth checks,
  backfills one root `corp` row per existing operator, adds tenant-leading
  indexes plus GiST `path`, and grants DML to `service_role` / `forge_admin`.
- Added `OrgUnitsRepository extends OperatorScopedRepository` for tenant
  list/get/create-root/create-child paths and admin root listing.
- RLS policy uses `public.app_current_operator()` from B23; no bare
  `current_setting('app.*')` tenant reads were introduced.

Verification:

- `dart analyze lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart test/phase_9_0sigma_c_org_units_test.dart`.
- `flutter test test/phase_9_0sigma_c_org_units_test.dart` passed 24/24.
- `dart run tool/rls_policy_lint.dart` scanned 19 migration files and reported
  clean.

Remaining:

- No repo/test blocker remains for `9.0Σ.c`. Any staging or Production1
  migration apply remains subject to the normal live-mutation approval gate.

### B25 - 9.0Σ.d service_principals + sp: JWT prefix + actor_kind

Source: `phase_9_scalability_decisions_2026-04-27.md` item 14.

Status: completed and double-checked on 2026-04-28.

Needed before: any Phase 12 workflow tool call. Workflows act as a
service principal, not a human user; without `actor_kind` separation
in `audit_logs` and `auth_events_audit`, machine-driven mutations
masquerade as their human owner.

Work:

- Migration creating `service_principals(id uuid pk, operator_id uuid,
  name text, scopes jsonb, created_at timestamptz, revoked_at
  timestamptz null, ...)` with tenant-leading PK index.
- JWT issuance path that prefixes the subject with `sp:` (so the
  proxy verifier can route to the SP path instead of the user path).
- Add `actor_kind text check (actor_kind in ('user','service'))` to
  `audit_logs` (created in B26) and to `auth_events_audit`.
- Repository: `ServicePrincipalsRepository extends
  OperatorScopedRepository`.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_d_service_principals.sql`
- `lib/infrastructure/persistence/postgres/repositories/service_principals_repository.dart`
- Proxy verifier extension in `tool/advisor_proxy/`.

Gate: a `sp:` JWT issued for one operator cannot read another operator's
rows (RLS); audit row carries `actor_kind='service'`.

Resolution:

- Added migration
  `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`.
- Migration creates `service_principals`, adds tenant-scoped RLS using
  `public.app_current_operator()`, grants the runtime/admin roles, and extends
  `auth_events_audit` with `actor_kind` plus
  `actor_service_principal_id`.
- Added `ServicePrincipalsRepository extends OperatorScopedRepository` with
  create/revoke/find/list helpers and strict `sp:<uuid>` subject helpers.
- Added `ServicePrincipalJwtIssuer`, `ServicePrincipalJwtVerifier`, and
  `CompositeProxyJwtVerifier` support in the advisor proxy. Verified service
  principals resolve as `actorKind='service'` with `sp_scope:*` roles while
  tampered tokens fail before scope is trusted.
- Updated `AuthEventsAuditRepository.insertEvent` so future service-principal
  events can carry non-human attribution without overloading
  `actor_user_id`.

Verification:

- `dart analyze tool/advisor_proxy/advisor_proxy.dart lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart lib/infrastructure/persistence/postgres/repositories/service_principals_repository.dart test/phase_9_0sigma_d_service_principals_test.dart`.
- `flutter test test/phase_9_0sigma_d_service_principals_test.dart` passed
  7/7.
- `dart run tool/rls_policy_lint.dart` scanned 21 migration files and reported
  clean.

Local live-closeout note:

- Current dirty local `master` is behind `origin/master`, and the
  `service_principals` migration/repository/test from upstream commit
  `49699ad` are not present in this worktree yet. Keep 9.0Σ.d.1 verification
  queued after the live-closeout branch is committed/fast-forwarded.

### B26 - 9.0Σ.e event_outbox foundation

Source: `phase_9_scalability_decisions_2026-04-27.md` item 33 (Q22).

Status: completed and double-checked on 2026-04-28.

Needed before: real-time bridge in `10a` (the Pub/Sub leg). The
foundation lands in `9.0Σ`; the Pub/Sub bridge + WebSocket leg complete
in Phase 10a.

Work:

- Migration creating `event_outbox(id bigserial pk, operator_id uuid,
  topic text, payload jsonb, created_at timestamptz, picked_up_at
  timestamptz null, ...)` with `(operator_id, picked_up_at NULLS FIRST,
  id)` index.
- `pg_notify` trigger on insert (channel `event_outbox`).
- Worker contract documented; consumer worker itself is Phase 10a.
- `SELECT ... FOR UPDATE SKIP LOCKED` claim path established.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_e_event_outbox.sql`
- `lib/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart`
- Doc in `docs/contracts/` describing topic shape + retry policy.

Gate: insert fires NOTIFY; tenant-leading index present; RLS denies
cross-tenant reads.

Resolution:

- Added migration
  `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql`.
- Migration creates durable `event_outbox` storage with `bigserial` id,
  `operator_id`, topic, JSON object payload, size cap, delivery / lease
  columns, tenant-leading claim index, insert-time `pg_notify` trigger, RLS
  policies using `public.app_current_operator()`, and table/sequence grants.
- Added `EventOutboxRepository` with tenant-scoped `enqueue` and admin/worker
  `claimBatch` using `FOR UPDATE SKIP LOCKED`, lease reclaim, stable ordering,
  and validation before opening transactions.
- Added `docs/contracts/event_outbox_contract.md` as the Phase 10a bridge
  contract: `NOTIFY` is wake-up only, `event_outbox` is source of truth,
  topics/retry/dead-letter semantics are documented, and direct non-repository
  inserts are forbidden for app code.

Verification:

- `dart analyze lib/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart test/phase_9_0sigma_e_event_outbox_test.dart`.
- `flutter test test/phase_9_0sigma_e_event_outbox_test.dart` passed 22/22.
- `dart run tool/rls_policy_lint.dart` scanned 19 migration files and reported
  clean.

Remaining:

- No repo/test blocker remains for `9.0Σ.e`. Phase 10a owns the Pub/Sub /
  WebSocket bridge consumer that drains the table. Any staging or Production1
  migration apply remains subject to the normal live-mutation approval gate.

### B27 - 9.0Σ.f Hash-chained audit_logs + Azure Blob anchor

Source: `phase_9_scalability_decisions_2026-04-27.md` item 13.

Status: queued.

Needed before: `9.8` compliance package (audit-tamper attestation
requires hash chaining); any operator-facing audit review surface in
`11A.7-10`.

Work:

- Migration creating `audit_logs` with `prev_row_hash bytea`,
  `row_hash bytea` (computed via `pgcrypto` digest of canonical
  payload). Per-operator/day partitions via `pg_partman`.
- Add `actor_kind` (paired with B25).
- Daily job (Cloud Run scheduled task) writes the day's final
  `row_hash` value to Azure Blob with immutability lock + retention.
- Verifier script that walks the chain and confirms the Blob anchor
  on demand.
- Hard rule: `audit_logs` is grant-shape append-only (no UPDATE,
  no DELETE for any role except `forge_admin` break-glass with a
  paired runbook entry).

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_f_audit_logs.sql`
- `tool/audit_anchor/` Cloud Run job source.
- `runbooks/audit_chain_verify_runbook.md`.

Gate: insert computes `row_hash` from
`prev_row_hash || canonical_payload`; partition rotation present;
Blob anchor written daily with immutability lock.

### B28 - 9.0Σ.g usage_caps two-slot key migration

Source: `phase_9_scalability_decisions_2026-04-27.md` item 6.

Status: queued.

Needed before: franchisee billing rollups, internal F&F dev/admin
class metering, any cap surface that distinguishes who pays from who
consumes.

Work:

- Migration evolving `usage_caps` PK to
  `(billing_owner_org_unit_id, scoped_org_unit_id, location_id,
  staff_id, workflow_id, usage_class)` with `usage_class text not null`.
- Same key shape on `usage_logs` (B6 in the existing PROJECT_TRACKER
  language) so cap-vs-actual reconciliation joins are 1:1.
- Online-migration friendly: ADD column → backfill → constraint flip,
  not a destructive recreate (CLAUDE.md cutover.4-and-after rule).
- Wire `9.0c` `org_units` so the FK is enforced.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_g_usage_caps_two_slot_a_add.sql`
- `db/migrations/202604XXXXXX_phase_9_0sigma_g_usage_caps_two_slot_b_backfill.sql`
- `db/migrations/202604XXXXXX_phase_9_0sigma_g_usage_caps_two_slot_c_pk_flip.sql`
- `lib/services/advisor/usage_*.dart` updates.

Gate: PK shape matches; tenant-leading index; cap-vs-actual join is
single-pass; RLS bypass for `forge_admin`.

### B29 - 9.0Σ.h advisor_conversation_log

Source: `phase_9_scalability_decisions_2026-04-27.md` item 5.

Status: queued.

Needed before: live advisor turns in `11b` (no advisor goes live
without raw-conversation persistence under audit-privacy gating).

Work:

- Migration creating `advisor_conversation_log(id uuid pk, operator_id
  uuid, location_id uuid, user_id uuid, conversation_id uuid,
  turn_index int, role text, content_encrypted bytea, content_iv bytea,
  usage_class text, created_at timestamptz, ...)` with tenant-leading
  PK index.
- Encryption-at-rest via `pgcrypto` (key reference, not raw key, in
  the row) — pairs with `cutover.0a` CMK.
- Audit-privacy gate: read access requires the matching audit-privacy
  role + a paired audit row.
- RLS policy mirrors fact tables.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_h_advisor_conversation_log.sql`
- `lib/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart`.

Gate: encrypted at rest; reads require audit-privacy role; cross-tenant
read denied; tokens never appear in `toString()`.

### B30 - 9.0Σ.i Canonical graph_nodes / graph_edges

Source: `phase_9_scalability_decisions_2026-04-27.md` item 30.

Status: queued.

Needed before: AGE projection rebuild story; `11b.2` causal traversal.
The AGE projection must be rebuildable without re-extracting from
source-of-truth corpus.

Work:

- Migration creating `graph_nodes` and `graph_edges` operator-scoped
  tables (canonical projection; AGE label graph rebuilt from these).
- Tripwire telemetry (yellow 3M nodes / red 4M) emitted to the
  health surface (Q19 — tracked separately under `11A.0-6` graph
  panel).
- Rebuild script that drops the AGE label graph and re-projects from
  `graph_nodes`/`graph_edges`.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_i_graph_canonical.sql`
- `tool/graph_projection/` rebuild source.

Gate: rebuild from canonical produces a label graph byte-equivalent
to the current AGE projection on staging; tripwire metric exposed.

### B31 - 9.0Σ.j Vector index scoping (HNSW default; DiskANN installed)

Source: `phase_9_scalability_decisions_2026-04-27.md` item 31.

Status: queued.

Needed before: `11b` advisor retrieval at scale; switch trigger
documented well before Tier-M.

Work:

- Confirm pgvector HNSW indexes are tenant-leading (already enforced
  in `202604260002_advisor_rls_index_hardening.sql`).
- Install `pg_diskann` extension on staging + Production1 (per
  CLAUDE.md Proxy & API Conventions list).
- Document switch trigger: yellow at 5M vectors per index, red at 8M.
  Include observability for index size + p50/p95 query time.
- DO NOT default DiskANN; only HNSW is on the hot path until trigger
  fires.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_j_diskann_install.sql`
  (install only, no index creation).
- `docs/phases/phase_9/phase_9_vector_index_switch_trigger.md`.

Gate: HNSW remains default; DiskANN extension present and CREATE
INDEX path verified on a throwaway table; tripwire metric exposed.

### B32 - 9.0Σ.k Rollups foundation (aggregation_state + grain set + pg_cron)

Source: `phase_9_scalability_decisions_2026-04-27.md` items 32, 34, 35.

Status: queued.

Needed before: every operator-facing dashboard surface. Without rollups,
dashboard p95 collapses on Tier-M.

Work:

- Migration creating `aggregation_state(rollup_table text, grain text,
  last_processed_seq bigint, updated_at timestamptz)` keyed
  `(rollup_table, grain)`.
- Physical rollup tables for each grain in the locked set: `daypart`,
  `business_day`, `week`, `accounting_period`, `month`, `quarter`,
  `year`. (Materialized views are internal helpers only — Q3.2 lock.)
- `pg_cron` job: 60s hot path (daypart + business_day), 300s cold
  path (week and longer).
- Idempotent worker: claim via `last_processed_seq`; advance after
  each successful batch.
- Late-data + rebuild + freshness + observability per Q3.3-Q3.10
  locks.

Files (likely):

- `db/migrations/202604XXXXXX_phase_9_0sigma_k_aggregation_state.sql`
- `db/migrations/202604XXXXXX_phase_9_0sigma_k_rollup_tables.sql`
- `db/migrations/202604XXXXXX_phase_9_0sigma_k_pg_cron_jobs.sql`
- `lib/services/rollups/` worker logic.

Gate: rollups idempotent across retried runs; freshness surfaced to
dashboards; rebuild from raw under documented runbook.

### B22 - 9.9 Admin Console Kernel Test Failure - RESOLVED

Source: Codex verification after `9.8`.

Status: resolved on 2026-04-26.

Needed before: accepting `9.9` admin role console UX.

Observed:

- `dart analyze lib/services/admin test/admin_console_test.dart` is clean.
- `flutter test test/admin_console_test.dart` fails 2 CSV export assertions:
  payload JSON is RFC-4180 escaped inside the CSV body, while the current
  tests expect the unescaped JSON substring.

Resolution:

- Tests were corrected to preserve RFC 4180 escaping and canonical JSON
  semantics.
- Codex reran the full Phase 9 framework sweep:
  `flutter test test/admin_console_test.dart test/user_lifecycle_test.dart test/permission_gate_test.dart test/permission_runtime_test.dart test/password_and_risk_test.dart test/mfa_test.dart test/auth_session_test.dart test/advisor_proxy_test.dart test/operator_scoped_repository_test.dart test/barrio_role_preview_widget_test.dart`
  -> 348/348 passed.
- After tranche 1 added RS256, Postgres-adapter, RLS-grant, and Firebase
  smoke coverage, Codex reran the focused Phase 9 sweep again:
  -> 357/357 passed.

## Current Next Step

Phase 9 tranche 2 framework (B4/B5/B6) is complete on 2026-04-27:
`FirebaseAuthClient` adapter + `FirebaseAuthLoginService`,
`PlatformSecureSessionStorage` over a pluggable backend, and the
`AuthSessionsRepository` + `RepositoryAuthSessionLedgerWriter`
integrated through `AuthSessionNotifier`.

Database closeout is also complete on staging and Production1 (see
`docs/archive/phases/phase_9/phase_9_live_database_closeout_result.md`).

Proxy session-ledger endpoint shipped on 2026-04-27 (see B6 / B8
above): four POST routes (`/v1/auth/session/login` / `refresh` /
`revoke` / `revoke-all`) on the proxy, plus `ProxyAuthSessionLedgerWriter`
in `lib/services/auth/` driving them from the Flutter app. The
`AuthSessionLedgerWriter` interface is the same one the notifier
already calls, so the only seam change is which implementation the
bootstrap injects. App entrypoints accept `FORGE_FLOW_PROXY_BASE_URI`
via `--dart-define`; without it the bootstrap falls back to the
scaffold-failing default and sign-in fails closed with a calm
`ledger_unavailable` message.

`tool/advisor_proxy/main.dart` now wires
`RepositoryAuthSessionLedgerWriter` over the live `PackagePostgresPool`
using `POSTGRES_URL`, so the four routes are ready to write real
Postgres rows when deployed. The bootstrap helper is covered by
`test/advisor_proxy_bootstrap_test.dart` and opens no database
connection until the first ledger write.

Current local code state on 2026-04-28:

- In-app `auth-smoke@forgeflow.dev` login/logout through the deployed proxy
  has passed (see `phase_9_in_app_auth_smoke_result.md`).
- Auth-operation, password-change, and MFA/recovery local route/schema
  foundations are in this dirty live-closeout worktree and covered by focused
  tests. The service-principal 9.0Σ.d foundation exists upstream/parallel, but
  this worktree still needs the queued fast-forward verification. The
  MFA/recovery route bundle now has a local Identity Toolkit REST adapter for
  live TOTP enrollment.
- `tool/advisor_proxy/main.dart` now installs the production Phase 9 route
  binding bundle into `routeRequest`: auth-session ledger,
  permission-snapshot resolver, admin permission guard, auth-operations
  gateway, password-change gateway, and MFA/recovery gateway. Construction is
  covered by `test/advisor_proxy_bootstrap_test.dart` and opens no database
  connection before the first request.
- `scripts/deploy_staging_proxy.ps1` and
  `scripts/use_forge_flow_secrets.ps1` now preserve the same
  `FIREBASE_WEB_API_KEY` contract as the proxy config: they derive it from the
  Forge Flow `google-services.json` when local env omits it, report the name
  only, and the deploy script writes it into Cloud Run env. Covered by
  `test/deploy_staging_proxy_contract_test.dart`.
- Corrected-deploy fresh invite-create smoke passed on
  `forge-flow-staging-proxy-00013-zx8`; see
  `phase_9_corrected_deploy_invite_create_retry_result.md`.
- Next live-closeout work is queued `9.0Σ.d.1` fast-forward verification and
  Production1 only if explicitly approved.
- Cloud Armor preview-log review/enforcement, route-level reCAPTCHA token
  enforcement, advisor accounting/usage/health live-store wiring, and
  Production1 apply/deploy remain gated follow-ups.
