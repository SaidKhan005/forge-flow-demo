# Phase 9 Context Checkpoint

Updated: 2026-04-27.

## Phase 9 Closeout Loop — Final Status (2026-04-27)

The user's multi-slice closeout loop ran to completion. Per-slice
outcomes:

| Slice | Status |
|---|---|
| B4/B5/B6 (Firebase auth client + secure storage + auth_sessions) | SDK/app wiring DONE for Android/mobile; proxy session-ledger endpoint + Flutter client writer DONE 2026-04-27; proxy boot now wires live `RepositoryAuthSessionLedgerWriter` over `PackagePostgresPool`; iOS build verification still pending |
| B8 (Live staging login smoke) | backend credential/session smoke DONE; proxy session-ledger endpoint + client writer DONE 2026-04-27; full in-app smoke READY after 2026-04-27 prerequisite closeout: deployed staging proxy URL is present in the non-repo secrets loader, smoke password is present, and Cloud Run has `FIREBASE_PROJECT_ID`, `POSTGRES_URL`, `POSTGRES_ADMIN_URL` |
| B11/B12/B13 (MFA TOTP + persistence + rate limits) | framework DONE; SDK adapter pending |
| B14/B15/B16 (HIBP + password history + brute-force) | framework DONE; Cloud Armor / reCAPTCHA dashboard remains a human gate |
| B17/B19 (role/admin endpoints + permission guard) | framework DONE; HTTP routes lands in proxy slice |
| B18 (PermissionGate bulk migration) | DONE via resolver-injection pattern |
| B20/B21 (lifecycle persistence + GDPR runbook) | framework DONE; runbook DONE |
| B9/B22 (admin auth surfaces) | B9 deferred to web shell; B22 already RESOLVED |
| Production1 RLS gate | DONE — applied and verified 2026-04-27 |
| 9.0a (multi-location scale-flow extensions) | DONE — applied and verified on staging + Production1; super_admin team-grant audit fix live |
| 9.10 (operator Settings -> Team UX) | Material UI foundation DONE; proxy-backed data/actions and dense role/audit detail views remain |

**Sweep:** superseded by the 2026-04-27 runtime closeout sweep recorded in
`phase_9_live_runtime_closeout_result.md`.

**Live calls / mutations made:** Phase 9 database closeout was applied on
staging and Production1 on 2026-04-27. A staging-only Firebase smoke user and
matching staging Postgres smoke rows were created for credential/session
verification. No Production1 operator data was loaded.

**Live calls / mutations intentionally NOT made:**

- No iOS build verification (Windows environment; macOS still required).
- No full in-app Firebase login smoke yet. The proxy session-ledger
  endpoint, Flutter client writer, live proxy boot binding, deployed staging
  proxy URL, and smoke-user password are now in place; the remaining gate is
  running the app smoke itself.
- No staging `pgmq` extension reintroduction (per CLAUDE.md note).
- No Cloud Armor / reCAPTCHA dashboard mutation (B16 human gate).

**What Codex should verify next:**

1. Run the full in-app `auth-smoke@forgeflow.dev` smoke through
   the deployed proxy (`FORGE_FLOW_USE_FIREBASE_AUTH=true` +
   `FORGE_FLOW_PROXY_BASE_URI=https://...` defines on the build).
2. Then decide proxy slice grouping for role/admin, user lifecycle,
   password change, MFA enroll/challenge, and recovery-code consume.
3. Keep iOS/macOS verification, advisor accounting/usage/health
   live-store wiring, and Cloud Armor / reCAPTCHA as explicit
   human-gated live setup items.

Use this as the compact handoff state for Codex/Claude prompt cycles. It is
not a decision source; decisions live in `phase_9_decision_lock_2026-04-26.md`
and architecture lives in `phase_9_auth_plan.md`.

## Current State

- Phase 11a accepted; Phase 9 active.
- `9.0` Auth schema foundation: ACCEPTED. Migration applied to local +
  staging + Production1.
- `9.1` Firebase Identity Platform setup + JWT verifier wiring:
  ACCEPTED (framework + tranche 1 live-closeout). Production
  pointycastle-backed RS256 verifier is wired in the proxy and passed a live
  staging Firebase ID-token smoke.
- `9.2` Repository pattern + SET LOCAL injection + RLS prep:
  ACCEPTED (code + live-closeout). The `package:postgres` adapter is
  wired behind the repository seam. Auth-table RLS policies and matching
  `service_role` / `forge_admin` table grants are applied and verified on
  staging and Production1.
- `9.3` Login + persistent session + step-up + Flutter wiring:
  ACCEPTED (framework). Production Firebase / secure-storage SDK
  binding pending.
- `9.4` MFA enrollment + enforcement: ACCEPTED (framework + real
  SHA-256 recovery-code hashing). Production `firebase_auth` MFA
  binding still pending.
- `9.5` Password policy + HIBP + brute-force protection: ACCEPTED
  (framework, including a real `package:crypto`-backed HIBP
  k-anonymity client + a tested NIST validator + a risk-signal
  resolver). HIBP outbound HTTPS + Cloud Armor / reCAPTCHA dashboard
  config remain human-prerequisite follow-ups (NOT executed).
- `9.6` Role + permission system runtime: ACCEPTED — pure-logic
  resolver (deny wins, default deny, time-bounded grants,
  cross-tenant isolation, location scope), role-management policy
  (super_admin / ff_support / operator_owner / operator_manager
  scope visibility + seeded-role protection + operator_manager
  sub-role limit), and `(userId, rolesVersion, op, loc)`-keyed
  LRU + TTL permission cache. HTTP endpoints land server-side once
  the proxy wires the kernel.
- `9.7` Permission enforcement runtime gates: ACCEPTED — Flutter
  `PermissionContext` + `PermissionGate` widget with cross-tenant /
  cross-user isolation, default-deny, MFA-fresh-auth layering, and
  fail-closed when no PermissionContext provider is installed. Bulk
  `BarrioPreviewRole` removal across the existing 16 callsites is a
  focused follow-up; the gate primitive is ready.
- `9.8` Admin user lifecycle: ACCEPTED — `UserStatus` enum +
  `UserLifecycleStateMachine` (legal transitions enforced),
  `UserInviteService` (7-day expiry + accept / revoke + idempotent
  revoke), `TrustedUserCreationPolicy` (super_admin only),
  `GdprErasureService` (paired-approval + super_admin only +
  no-self-approval + no-double-count + soft-delete prerequisite),
  and `ErasureRedactionTemplate` payload covering the locked
  redaction map + Art. 17(3) preserved fields. Server-side wiring
  (firebase_auth Admin SDK + Postgres writes) is the focused
  follow-up.
- `9.9` Admin role console UX: ACCEPTED — admin-console kernel
  controllers (`AuditLogCsvExport` with mandatory
  `admin.audit_log.export` audit event + RFC 4180 quoting +
  canonical sorted JSON payload column,
  `RolePermissionMatrixController` for the matrix editor with
  diff-vs-baseline + JSONB audit payload,
  `MfaPolicyEditorState` + `MfaPolicyEditorPolicy` for the
  per-tier MFA defaults + per-operator override). Dense / no-
  marketing UI surfaces and HTTP wiring land server-side once the
  proxy `package:postgres` binding lands.
- **Phase 9 framework: COMPLETE.** Tranche 1 live-closeout (RS256, Postgres
  adapter, staging RLS flip, Firebase smoke) is complete. Tranche 2 B4/B5/B6
  framework and mobile runtime wiring are complete: FlutterFire + secure
  storage packages are installed, Android builds pass, and runtime bindings are
  gated behind `FORGE_FLOW_USE_FIREBASE_AUTH`. Backend B8 credential/session
  smoke is complete with a staging-only Firebase user and staging-only auth
  rows. Full in-app login still needs the proxy session-ledger endpoint; iOS
  verification still needs macOS. 9.10 Settings -> Team Material UI foundation
  is complete behind an injected actor snapshot.
- Production1 still schema-only (no operator data loaded).
- Real follow-up work from slice findings is tracked in
  `phase_9_execution_backlog.md`; stale repeated findings are listed there
  as resolved so they do not get re-opened unless the repo regresses.

## Last Completed Slice (9.live-closeout proxy session-ledger endpoint)

**Date:** 2026-04-27.

**What landed:** the client-safe proxy session-ledger endpoint + Flutter
client writer that unblocks true in-app login. The Flutter app no
longer needs direct Postgres access; the four
`/v1/auth/session/*` proxy routes verify the Firebase ID token
server-side and delegate to an injected `AuthSessionLedgerWriter`.

**Files changed:**

- `tool/advisor_proxy/advisor_proxy.dart` — added route constants
  `authSessionLoginPath`, `authSessionRefreshPath`, `authSessionRevokePath`,
  `authSessionRevokeAllPath`. Extended `routeRequest` with an
  `AuthSessionLedgerWriter? authSessionLedgerWriter` parameter and four
  POST handlers. Each handler verifies via the existing
  `ProxyRequestGuard.requireOperatorContext`, parses a JSON body
  (returns 400 `malformed_json_body` / `missing_token_hash` /
  `missing_session_id` on validation failure), resolves request
  metadata, and calls the writer. `User-Agent` is stored as soft
  client metadata; forwarded IP / geo headers are ignored by
  default unless trusted-ingress mode is explicitly enabled.
  Failures collapse to 503 `auth_session_ledger_unavailable` with
  no error-stack leak.
  Response shape: login → `{session_id, user_id, operator_id,
  location_id}`; refresh / revoke → `{ok: true}`; revoke-all →
  `{ok: true, revoked_count}`. Bearer tokens, `token_hash` values,
  and writer exception text never leak through the response body.
  Added `_resolveLedgerContextFromHeaders`, `_readJsonBody`,
  `_nonBlankString`, and `_MalformedJsonBodyError` private helpers.
- `tool/advisor_proxy/main.dart` — now wires the real
  `RepositoryAuthSessionLedgerWriter` over `PackagePostgresPool`
  using `POSTGRES_URL`. Construction is lazy with respect to the
  database: no socket opens until a request attempts to record /
  refresh / revoke an auth session. Diagnostics line now includes
  `auth_session_ledger: postgres` so a startup grep can confirm
  the binding state without echoing secrets.
- `tool/advisor_proxy/proxy_bootstrap.dart` (new) — tiny tested
  factory for the production auth-session ledger binding; proves
  the auth ledger uses tenant-scoped `POSTGRES_URL`, not
  `POSTGRES_ADMIN_URL`.
- `lib/services/auth/proxy_auth_session_ledger_writer.dart` (new) —
  `ProxyAuthSessionLedgerWriter implements AuthSessionLedgerWriter`
  drives the four routes via `dart:io HttpClient` with a 10s timeout
  and a per-call Idempotency-Key header. `ProxyHttpJsonClient` is the
  testable seam (production binding `DartIoProxyHttpJsonClient`;
  fail-closed default `ScaffoldFailingProxyHttpJsonClient`). The
  writer's ID-token provider is wired to
  `FirebaseAuthClient.currentIdToken()` (new method on the existing
  seam). Errors map to a narrow `ProxyAuthSessionLedgerError` with
  `code` / `statusCode`; transport failures collapse to
  `transport_error` so the underlying exception text never propagates.
- `lib/services/auth/firebase_auth_client.dart` — added
  `Future<String?> currentIdToken()` to the interface, implemented in
  the SDK adapter via `currentUser?.getIdToken()` (cached token —
  Firebase auto-refreshes when it nears expiry), and in the
  scaffold-failing default as a `StateError`.
- `lib/services/auth/firebase_auth_client_sdk.dart` — implemented
  `currentIdToken` over the SDK adapter.
- `lib/services/auth/firebase_auth_runtime_bindings.dart` — accepts
  optional `proxyBaseUri`. When supplied, the bindings build the
  production `ProxyAuthSessionLedgerWriter` and expose it on
  `FirebaseAuthRuntimeBindings.authSessionLedgerWriter`. Without
  the URI the field stays `null` and the bootstrap falls back to
  the scaffold-failing default.
- `lib/main_forgeflow.dart` + `lib/main_barrio.dart` — read
  `FORGE_FLOW_PROXY_BASE_URI` from `--dart-define`, pass to the
  bindings, and forward `bindings.authSessionLedgerWriter` to
  `bootstrapAndRunApp`.
- `test/advisor_proxy_test.dart` — 13 new server-side route tests
  (auth-required / scope-required / body-validation / happy-path /
  writer-503 / no-stack-leak per route) plus
  `_RecordingAuthSessionLedger` and `_ThrowingAuthSessionLedger`
  test fakes, plus `_httpPost` helper.
- `test/proxy_auth_session_ledger_writer_test.dart` (new) — 12 tests
  covering URL / headers / body shape / error mapping /
  ID-token-missing / transport-error / wire-contract sanity
  asserting the writer's path constants exactly match the proxy's
  exported route constants byte-for-byte.
- `test/auth_live_binding_test.dart` — extended `_FakeFirebaseAuthClient`
  with `currentIdToken` (defaults to a static placeholder so existing
  tests that don't care about the value pass through unchanged).

**Tests run:**

- `dart analyze` clean across `lib/services/auth`, `lib/state`,
  `lib/main_*.dart`, `lib/forge_flow_bootstrap.dart`,
  `tool/advisor_proxy/`, and the four touched test files. No issues.
- Phase 9 sweep across the same 18 test files used in the prior
  closeout PLUS the new `proxy_auth_session_ledger_writer_test.dart`
  (19 files): **566/566 passed** (+33 over the prior 533 baseline).
- Latest live-ledger boot wiring check: `dart analyze` on
  `tool/advisor_proxy/main.dart`, `tool/advisor_proxy/proxy_bootstrap.dart`,
  and `test/advisor_proxy_bootstrap_test.dart` was clean;
  `flutter test test/advisor_proxy_bootstrap_test.dart
  test/proxy_auth_session_ledger_writer_test.dart test/advisor_proxy_test.dart`
  passed **148/148**.

**Pending follow-up:**

- Run the in-app `auth-smoke@forgeflow.dev` login / logout smoke through
  the deployed staging proxy. The 2026-04-27 prerequisite closeout put
  `FORGE_FLOW_PROXY_BASE_URI` in the non-repo secret loader and verified the
  Cloud Run service has the required env names.
- Idempotency: the proxy currently accepts the `Idempotency-Key`
  header but does not yet enforce it. A future slice will integrate
  the `proxy_requests` table so a retried POST returns the prior
  result instead of creating a duplicate `auth_sessions` row. Until
  then, a client retry can produce an orphan row that the dormancy
  sweep / admin force-logout-all reaps.

**UX lock preserved:**

- Persistent login: success path is invisible — when the proxy is
  reachable and the writer accepts, the user sees no extra prompt.
- No forced password resets / no broad MFA friction: untouched.
- Fail closed posture: when the proxy returns 503 (scaffold default)
  or the writer call fails, the notifier surfaces a calm
  `AuthLoginFailure(code: 'ledger_unavailable')` and stays in
  `Unauthenticated` rather than entering an authenticated state
  without an `auth_sessions` row.

**Live calls / mutations:** none. No Firebase, no Postgres, no
commits, no Anthropic / Voyage. The slice ships framework + tests
only; live staging in-app smoke awaits the live PostgresPool wiring
above.

## Last Completed Slice (9.live-closeout B20/B21)

**Files changed:**

- `lib/infrastructure/persistence/postgres/repositories/users_repository.dart`
  (new) — `UsersRepository`: `updateStatus`, `markLoggedIn`,
  `markActive`, `softDelete`, `bumpRolesVersion`, `redactPii`. The
  redactPii path matches the locked `ErasureRedactionTemplate`
  exactly (email overwritten, profile fields nulled, firebase_uid
  preserved for link integrity).
- `lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart`
  (new) — `AuthEventsAuditRepository`: `insertEvent` (append-only
  with all the schema fields, RETURNING event_id), `redactForUser`
  (Art. 17(3) redaction — nulls ip / user_agent / strips PII keys
  from JSONB payload via `-` operator, preserves event_id /
  actor_user_id / event_type / occurred_at).
- `lib/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart`
  (new) — `AuthInvitesRepository`: `insertInvite` (with token hash,
  expires_at, role+location), `markAccepted` (filters by accepted/
  revoked/expired), `revokeInvite` (idempotent).
- `runbooks/gdpr_erasure_runbook.md` (new) — operational runbook
  for the F&F super_admin paired-approval erasure flow. Documents
  every prerequisite (soft-delete first, paired-approval, no-self-
  approval, fresh MFA), execution checklist, redaction map (matches
  template byte-for-byte), Art. 17(3) preserved-field list,
  irreversibility, audit row shape, verification SQL queries, and
  source-of-truth boundaries.
- `test/user_lifecycle_live_binding_test.dart` (new) — 14 tests:
  UsersRepository (status / login / soft-delete / redactPii / bump
  via withSystem audit reasons); AuthInvitesRepository (insert +
  accept filter + revoke idempotent); AuthEventsAuditRepository
  (insertEvent + redactForUser); GDPR runbook (every redaction
  template field appears, paired-approval / soft-delete /
  no-self-approval / Art. 17(3) docs, irreversibility).

**Tests run:**

- `dart analyze` on the 4 touched files → No issues found.
- `flutter test test/user_lifecycle_live_binding_test.dart` → 14/14.
- Full Phase 9 sweep (16 test files): **467/467 passed**.

**Acceptance status:**

- B20 user lifecycle audit + persistence binding: framework DONE.
  The proxy still owes the orchestration layer that chains
  `UserLifecycleStateMachine` decisions → `UsersRepository.updateStatus`
  → `AuthEventsAuditRepository.insertEvent` per transition.
- B21 GDPR erasure runbook: DONE. `runbooks/gdpr_erasure_runbook.md`
  is canonical and aligned with the framework code.

**Blockers / known follow-ups:**

- Wire the proxy orchestration that pipes `UserLifecycleAction`
  outcomes through the repositories + audit writer.
- The Firebase Admin SDK call for `revokeRefreshTokens(uid)` on
  hard logout still belongs to the same proxy slice as the
  invite/erasure persistence wiring.
- Trigger or scheduled job that runs the dormancy sweep
  (30/60/90-day status transitions) is still a separate cloud-side
  decision (`pg_cron` job vs. proxy worker).

## Last Completed Slice (9.0a — Multi-location scale-flow extensions)

**Files changed:**

- `db/migrations/202604270000_phase_9_0a_scope_extensions.sql`
  (new) — additive migration (idempotent + transactional):
  - `user_roles.scope_type` (NOT NULL, CHECK in operator_wide /
    location, backfill from location_id, tenant-leading
    `user_roles_operator_scope_idx`).
  - `users.primary_location_id` (UUID null) + composite FK to
    `locations(operator_id, location_id)` applied conditionally
    via DO block (FK only added when `users.operator_id` exists).
  - `operators.region` (TEXT null).
  - 12 `team.*` permission key inserts with `category = 'team'` /
    `frozen = true` / no MFA-required (locked decision: launch
    tier treats team management as low-friction).
  - Baseline role grants: operator_owner cross-join → all team.*;
    operator_manager subset (no create_custom, no soft_delete).
- `lib/auth/permission_keys.dart` — added 12 `teamUsersView` /
  `teamUsersInvite` / etc. constants under a new `team.* (12)`
  section + extended `PermissionKeys.all` so it grows from 81 → 93.
  Header comment updated.
- `docs/contracts/auth_permission_key_catalog.md` — added
  `### team.* (12)` section documenting each key + baseline grant
  matrix.
- `test/phase_9_0a_scope_extensions_test.dart` (new) — 14 tests
  covering migration shape, backfill, indexes, FK pattern, region
  column, key seeds, role grants, catalog mirror, MFA exemption
  (none of team.* require MFA), and CLAUDE.md storage discipline
  (no `timestamp without time zone`, transactional begin/commit).

**Tests run:**

- `dart analyze` on the touched files → No issues.
- `flutter test test/phase_9_0a_scope_extensions_test.dart` → 14/14.
- Full Phase 9 sweep (17 test files): **481/481 passed**.

**Acceptance status:**

- 9.0a: code DONE. Migration applies cleanly to local; staging /
  Production1 application is the live-apply follow-up paired with
  the existing Production1 RLS gate (both still wait for explicit
  user approval).

**Blockers / known follow-ups:**

- Apply the 9.0a migration to staging (then to Production1, after
  user approval) — same gate as the Production1 RLS flip.
- `lib/auth/role_management_policy.dart` extension to honor the
  `team.*` keys for operator_manager grants is a focused
  follow-up; the kernel framework still works because the policy
  defaults to "operator_owner can do anything within own
  operator" which already covers the team.* paths.

## Last Completed Slice (9.10 - Team UX Material foundation)

**Files changed:**

- `lib/services/team/team_scope_visibility_policy.dart`,
  `team_users_list_controller.dart`, and `team_invite_form_controller.dart`
  provide the pure 9.10 policy/filter/invite kernels.
- `lib/screens/team/team_settings_entrypoint.dart` keeps the Team surface
  fail-closed by hiding it when the actor cannot see Team.
- `lib/screens/team/team_settings_section.dart` adds the first Material UI
  foundation: summary strip, search/status/role/location filters, dense team
  rows, and a controller-backed invite form.
- `lib/screens/settings_screen.dart` now conditionally adds a Team tab when an
  allowed `TeamScopeActor` is injected. With no actor snapshot, Team remains
  hidden by default.
- `test/team_ux_kernel_test.dart` and `test/settings_screen_widget_test.dart`
  cover policy, controllers, entrypoint, Settings tab gating, list filtering,
  invite submit, and no-permission disabled submit.

**Acceptance status:**

- 9.10 Material UI foundation DONE. The UI is intentionally low-friction:
  staff/supervisor users do not see Team; allowed owners/managers get a dense
  operator-facing management surface without marketing copy.

**Blockers / known follow-ups:**

- Proxy-backed Team data/actions are still pending: list users, submit
  invites, edit grants, revoke/deactivate, reset password, force logout, and
  role/audit detail views.
- The actor snapshot bridge is still pending. Production remains fail-closed:
  Team is hidden unless the caller injects a `TeamScopeActor` derived from the
  resolved permission/role snapshot.

## B9/B22 — admin auth surfaces

- **B9** (Admin web security headers / Mozilla Observatory):
  remains deferred to the admin web shell slice. The headers
  (CSP, HSTS, X-Frame-Options, secure cookies) are shell-level
  config + must be verified against a deployable admin web
  endpoint that does not yet exist. No framework code to add
  here.
- **B22** (9.9 admin console kernel test failure): already
  RESOLVED in tranche 1 (CSV escaping + canonical JSON sort
  fix). No further action.

## Last Completed Slice (9.live-closeout B18)

**Files changed:**

- `lib/internal/barrio/routes/barrio_destination_visibility_resolver.dart`
  (new) — `BarrioDestinationVisibilityResolver` interface +
  `AlwaysVisibleBarrioDestinationResolver` (tests / dev) +
  `PreviewRoleBarrioVisibilityResolver` (legacy chip behavior) +
  `PermissionContextBarrioVisibilityResolver` (production over
  `PermissionContext`, derives the `barrio.destination.<id>`
  permission key, falls back when no context).
- `lib/internal/barrio/widgets/barrio_bubble_hub.dart` — added
  optional `visibilityResolver` parameter; when non-null it
  overrides the legacy `previewRole.isIntendedFor(dest)` decision.
  Dev / preview keeps the chip-driven behavior because the param
  is optional.
- `lib/internal/barrio/screens/barrio_home_screen.dart` — wires
  `PermissionContextBarrioVisibilityResolver` when a
  `Provider<PermissionContext>` is in the tree; otherwise leaves
  the resolver null so the chip-driven preview-role still works.
- `test/barrio_destination_visibility_resolver_test.dart` (new) —
  8 tests for the three resolvers + namespacing helper.

**Tests run:**

- `dart analyze` on the 4 touched files → No issues.
- `flutter test test/barrio_destination_visibility_resolver_test.dart`
  → 8/8.
- Full Phase 9 sweep (15 test files): **453/453 passed**.

**Acceptance status:**

- B18 bulk migration: DONE via the resolver-injection pattern.
  The single `widget.previewRole.isIntendedFor(dest)` callsite in
  the bubble hub now defers to the production resolver when
  available; the 16 file callsites that pass `BarrioPreviewRole`
  around as a constructor parameter are left untouched (they
  still drive the preview chip).

**Blockers / known follow-ups:**

- Catalog seed for `barrio.destination.*` permission keys (one
  per destination id) — paired with the operator console UX
  (9.10 / future). Until those keys are in `permission_keys`,
  the production resolver returns false (default-deny) for
  `barrio.destination.<id>` and the bubbles dim in production.
  That is the desired safe state.

## Last Completed Slice (9.live-closeout B17/B19 framework)

**Files changed:**

- `lib/infrastructure/persistence/postgres/repositories/roles_repository.dart`
  (new) — `RolesRepository`: `listVisibleRoles` (global first +
  alphabetical, filters deleted_at), `insertOperatorRole`
  (RETURNING role_id, is_seeded=false), `softDeleteOperatorRole`
  (refuses when active grants exist).
- `lib/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart`
  (new) — `RolePermissionsRepository`: `listForRole`,
  `upsertCell` (ON CONFLICT DO UPDATE matches the matrix-editor
  cell semantics), `deleteCell`. Effect-string validation
  (`allow` / `deny` only).
- `lib/infrastructure/persistence/postgres/repositories/user_roles_repository.dart`
  (new) — `UserRolesRepository`: `activeGrantsForUser` (filters
  revoked_at, valid_until, valid_from), `insertGrant` (INSERT +
  bump `users.roles_version` atomically in same transaction),
  `revokeGrant` (UPDATE + bump roles_version only when a row was
  affected — idempotent revoke does NOT spuriously bump).
- `lib/services/auth/proxy_admin_permission_guard.dart` (new) —
  `ProxyAdminPermissionGuard` interface +
  `ProxyAdminGuardContext` + sealed `ProxyAdminGuardDecision`
  (Allowed / DeniedDefault / DeniedExplicit / MfaStaleAuth /
  ChallengeRequired / Rejected). `ScaffoldFailingProxyAdminPermissionGuard`
  fail-closed default. `InMemoryProxyAdminPermissionGuard` wires
  permission effects + `requires_mfa` flag set + reCAPTCHA-protected
  key set + freshness clock so the proxy can drive MFA freshness
  + reCAPTCHA challenge gating uniformly. reCAPTCHA-protected
  key + missing outcome fail-closes (rejected).
- `test/role_admin_live_binding_test.dart` (new) — 20 tests across
  all four files: SQL contract assertions for every repository
  method + the guard's allow / default-deny / explicit-deny / MFA
  stale-auth / reCAPTCHA reject / reCAPTCHA challenge / missing
  reCAPTCHA outcome (fail-closed).

**Tests run:**

- `dart analyze` on the 5 touched files → No issues found
  (one prefer_interpolation fix mid-slice).
- `flutter test test/role_admin_live_binding_test.dart` → 20/20.
- Full Phase 9 sweep (14 test files): **445/445 passed**.

**Acceptance status:**

- B17 role / role-grant repositories + roles_version bump:
  framework DONE. The proxy still owes the
  `/v1/admin/auth/roles/*` and
  `/v1/admin/auth/role-grants/*` HTTP wiring on top of these
  repositories — that lands in the integrating proxy slice
  alongside the existing `tool/advisor_proxy/` route map.
- B19 proxy permission guard: framework DONE. Production
  binding (over `UserRolesRepository` + `RolePermissionsRepository`
  + `PermissionCache` from 9.6) is the focused follow-up paired
  with the same proxy slice.

**Blockers / known follow-ups:**

- Wire production `ProxyAdminPermissionGuard` over the live
  Postgres + cache stack inside `tool/advisor_proxy/advisor_proxy.dart`.
- Add `/v1/admin/auth/roles/*` + `/v1/admin/auth/role-grants/*`
  routes that consume the repositories above; chain a
  `BruteForceTelemetrySink` audit row per mutation.
- Decide (with user) whether the `roles_version` bump is the
  ONLY cache-invalidation signal or if a `pg_notify` channel
  is also wired so other proxy instances pick up the change.

## Last Completed Slice (9.live-closeout B14/B15/B16 framework)

**Files changed:**

- `lib/infrastructure/persistence/postgres/repositories/password_history_repository.dart`
  (new) — `PasswordHistoryRepository` (extends
  `OperatorScopedRepository`): `recordHash` (INSERT … RETURNING
  `entry_id`); `latestHashes` (SELECT … ORDER BY set_at DESC LIMIT
  N); `prune` (DELETE rows beyond the latest N — locked default 5);
  `clearForUser` (GDPR via `withSystem` with audited reason).
- `lib/services/auth/repository_password_history_check.dart` (new) —
  `PasswordHistoryHasher` interface + `Sha256PasswordHistoryHasher`
  production hasher (SHA-256 of `operator_id|user_id|candidate` for
  cross-tenant + per-user fingerprint isolation). Production
  `RepositoryPasswordHistoryCheck implements PasswordHistoryCheck`
  reading via the repository, comparing in constant-time. Adds
  `recordAndPrune` helper for the post-change write path.
- `lib/services/auth/rate_limited_hibp_range_fetcher.dart` (new) —
  Sliding-window decorator over `HibpRangeFetcher`. Default 100
  requests / 60s per process (matches the operator-side Cloud Armor
  cap as defense-in-depth). Throws `HibpRateLimitExceeded` past the
  cap; the existing screener maps the throw into
  `PwnedPasswordResult.screenerUnavailable`.
- `lib/services/auth/recaptcha_v3_verifier.dart` (new) —
  `RecaptchaV3VerifyOutcome` value class, `RecaptchaV3Verifier`
  interface, `ScaffoldFailingRecaptchaV3Verifier` fail-closed
  default, `RecaptchaV3Policy` that turns a verifier outcome +
  expected action into accept / challenge / reject. Score
  thresholds (acceptThreshold 0.5, challengeFloor 0.3) are
  defaults the operator can tune via proxy config. The actual
  Google `siteverify` HTTP call binding is paired with the
  operator's reCAPTCHA admin-console approval (B16 cloud blocker).
- `test/password_live_binding_test.dart` (new) — 20 tests:
  PasswordHistoryRepository SQL contract (insert + RETURNING +
  ordered latest + prune-by-not-in + GDPR withSystem path +
  no-rows guard + n>0 guard); Sha256PasswordHistoryHasher
  determinism + cross-tenant + per-user isolation;
  RepositoryPasswordHistoryCheck (match + no-match +
  recordAndPrune chain); RateLimitedHibpRangeFetcher (cap +
  sliding-window re-admission); RecaptchaV3 (scaffold-failing
  verifier + policy decisions for accept / challenge / reject /
  action mismatch / verify success=false).

**Tests run:**

- `dart analyze` on the 5 touched files → No issues found
  (one prefer_final_locals fix mid-slice).
- `flutter test test/password_live_binding_test.dart` → 20/20.
- Full Phase 9 sweep + new tests (13 test files):
  → **425/425 passed** (no regressions).

**Acceptance status:**

- B14 HIBP production wiring: framework DONE. The existing
  `HttpHibpRangeFetcher` (Phase 9.5) now has the Dart-side
  `RateLimitedHibpRangeFetcher` decorator. The operator-side
  Cloud Armor allowlist for outbound HTTPS to
  `api.pwnedpasswords.com` remains a human prerequisite.
- B15 password history persistence: DONE end-to-end. The proxy
  binds `RepositoryPasswordHistoryCheck` over the live Postgres
  pool + per-tenant context once the auth proxy slice lands.
- B16 brute-force protection: framework portion DONE
  (RecaptchaV3 verifier interface + policy +
  scaffold-failing default). Cloud Armor + reCAPTCHA admin
  dashboard mutation remains BLOCKED on operator approval — see
  the Phase 9 execution backlog B16 entry for the human
  prerequisites and the exact dashboard checklist.

**Blockers / known follow-ups:**

- Operator approval to allowlist outbound HTTPS to
  `api.pwnedpasswords.com` from the proxy egress firewall.
- Operator approval to provision a Cloud Armor security policy
  with per-IP rate limits on `/v1/auth/*` routes and to mint a
  reCAPTCHA v3 site key + secret in the GCP console.
- Wire `RepositoryPasswordHistoryCheck` over the live
  `PackagePostgresPool` when the password-change endpoint lands
  in the proxy.

## Last Completed Slice (9.live-closeout B11/B12/B13)

**Files changed:**

- `lib/services/mfa/firebase_mfa_client.dart` (new) —
  `FirebaseMfaClient` adapter (`beginTotpEnrollment`,
  `confirmTotpEnrollment`, `unenrollFactor`),
  `FirebaseMfaTotpBeginPayload`, sealed `FirebaseMfaConfirmOutcome`
  (`FirebaseMfaConfirmSucceeded` / `FirebaseMfaConfirmFailed`),
  `ScaffoldFailingFirebaseMfaClient` fail-closed default. TOTP
  secrets + otpauth URLs never echoed.
- `lib/services/mfa/firebase_mfa_enrollment_service.dart` (new) —
  production `FirebaseMfaEnrollmentService implements MfaEnrollmentService`.
  Composes the adapter with `RecoveryCodeGenerator` +
  `RecoveryCodeHasher` + `RecoveryCodeSaltSource`. On
  `confirmTotpEnrollment` success: generates the locked 10
  recovery codes, hashes them with the per-user salt, returns
  `MfaEnrollmentCompleted(plaintext + hashed + factorId)`. Uses
  `firebase_factor_uid` from metadata when present; otherwise
  falls back to the session factorId. `SecureRandomRecoveryCodeSaltSource`
  produces 16-byte salts via `Random.secure`.
- `lib/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart`
  (new) — `MfaFactorsRepository` (extends `OperatorScopedRepository`):
  `insertTotpFactor` (INSERT … RETURNING `factor_id` with
  `factor_metadata = {firebase_factor_uid, issuer}` JSONB);
  `insertRecoveryCodeFactor` (one row per code with
  `{salt, hash}` JSONB); `markRecoveryCodeUsed` (sets
  `last_used_at = now()` AND `revoked_at = now()` so the same
  code never matches again); `revokeTotpFactor` (24-hour-delayed
  removal flow); `listActiveRecoveryCodeFactors` (consumer
  iteration). All parameters bound; metadata serialized via
  `jsonEncode` and bound as text + cast to `::jsonb`.
- `lib/services/mfa/recovery_code_attempt_limiter.dart` (new) —
  `RecoveryCodeAttemptStore` interface + `InMemoryRecoveryCodeAttemptStore`
  (tests / dev) + `ScaffoldFailingRecoveryCodeAttemptStore`
  fail-closed default. Sealed `RecoveryCodeAttemptDecision`
  (`Allowed` / `RateLimited` with `retryAfter` /
  `DailyExhausted` with `resetsAt`).
  `RecoveryCodeAttemptLimiter` enforces the locked policy
  (1 attempt/min + 5 attempts/24h). `check` returns the
  decision; `recordAttempt` is the post-verify call the consumer
  always runs (even on invalid codes — the locked policy says
  invalid attempts also burn budget so an attacker can't spam).
- `lib/services/mfa/recovery_code_consumer.dart` (new) —
  `RecoveryCodeConsumer` orchestrates limiter + repository +
  hasher. Sealed `RecoveryCodeConsumeResult`
  (`Consumed` / `Invalid` / `AlreadyUsed` / `RateLimited` /
  `DailyBudgetExceeded`). Happy path: rate check → list factors
  → hash-verify each → mark first match used → return
  `Consumed(factorId)`. Invalid path returns `Invalid` and STILL
  records the attempt. Race-condition path (mark returns 0)
  surfaces `AlreadyUsed`. Constant-time hash compare (via the
  Sha256RecoveryCodeHasher's existing constant-time equals).
- `test/mfa_live_binding_test.dart` (new) — 22 tests covering:
  `ScaffoldFailingFirebaseMfaClient` fails closed;
  `SecureRandomRecoveryCodeSaltSource` produces 16-byte salts;
  `FirebaseMfaEnrollmentService` (begin forwards setup, confirm
  succeeded yields N codes + N hashes with shared per-user salt
  + canonical XXXX-XXXX-XXXX shape, falls back to session
  factorId when firebase_factor_uid missing, failed surfaces
  code+message verbatim); `MfaFactorsRepository` SQL contract
  (insertTotpFactor JSONB metadata + RETURNING projection,
  insertRecoveryCodeFactor binds salt+hash JSON, markRecoveryCodeUsed
  filters by factor_type='recovery_code' + revoked_at is null,
  revokeTotpFactor filters by factor_type='totp',
  listActiveRecoveryCodeFactors projects rows + parses JSON
  metadata, throws on no-rows RLS-denial scenario);
  `RecoveryCodeAttemptLimiter` (allow on empty, rate-limit
  within 1 min, allow past window, daily exhausted after 5/24h
  with correct resetsAt, scaffold throws);
  `RecoveryCodeConsumer` end-to-end (happy path consumes +
  records attempt, invalid still records attempt, rate-limit
  short-circuit doesn't touch repo, daily exhausted, race
  condition where match exists but mark returns 0 surfaces
  `AlreadyUsed`).

**Tests run:**

- `dart analyze` on the 6 touched MFA + repo + test files →
  No issues found (one round of fix needed for an earlier
  `_SeededRandom` scaffold; resolved by switching to seeded
  `dart:math.Random`).
- `flutter test test/mfa_live_binding_test.dart` → 22/22 passed.
- Full Phase 9 sweep + new test files
  (12 test files total: prior 10 + `auth_live_binding_test.dart` +
  `mfa_live_binding_test.dart`):
  → **405/405 passed** (no regressions).

**Acceptance status:**

- B11 production `MfaEnrollmentService` framework: DONE through
  the `FirebaseMfaClient` adapter seam. SDK adapter that imports
  `firebase_auth.MultiFactor` is the same focused follow-up as
  the B4 SDK adapter (paired with B7 iOS Xcode + Android Gradle
  wiring).
- B12 `mfa_factors` persistence: DONE end-to-end. Repository
  hits real Postgres when paired with `PackagePostgresPool` from
  tranche 1. TOTP factor + per-recovery-code rows + mark-used +
  revoke + list-active all wired through tenant-scoped
  transactions.
- B13 recovery-code attempt rate limits: DONE. Limiter
  + consumer + scaffold-failing store. The Postgres-backed
  attempt store is a focused follow-up (small additional
  schema decision: a `recovery_code_attempts` table OR pulling
  from `auth_events_audit` rows tagged with the right event
  type — the framework supports either).

**Blockers / known follow-ups:**

- `firebase_auth` MultiFactor SDK adapter not wired (paired
  with B4/B5 SDK adapter follow-up + B7 iOS/Android wiring).
- Postgres-backed `RecoveryCodeAttemptStore` not yet implemented;
  the proxy needs to pick a persistence model (dedicated
  `recovery_code_attempts` table vs. reading from
  `auth_events_audit` filtered by event_type) before wiring.
- The proxy orchestrator still needs to chain
  `FirebaseMfaEnrollmentService` + `MfaFactorsRepository`
  inserts (TOTP row + N recovery-code rows) inside one
  transaction so a partial enroll doesn't leave the user
  half-enrolled.

## Production1 RLS — DONE (2026-04-27)

Production1 authorization was given during the closeout loop. The database
closeout result is recorded in
`phase_9_live_database_closeout_result.md`.

Verification:

- `db/migrations/202604260000_auth_rls_per_tenant_policies.sql` and
  `db/migrations/202604260001_auth_rls_service_role_grants.sql`
  are applied on Production1.
- 12 Phase 9 auth tables have RLS enabled.
- 16 expected auth policies are present.
- `service_role` and `forge_admin` grants are present.
- `auth_events_audit` remains append-only for both roles.
- Tenant-leading indexes are present.
- `timestamp without time zone` count is 0.

## B8 — PENDING on Firebase SDK + smoke user (2026-04-27)

The live staging login/session smoke is now unblocked on the database side,
but still needs the Firebase SDK/app wiring and smoke-user secret. The
remaining prerequisites are itemized in
`phase_9_execution_backlog.md` under B8. Summary of the gap:

- SDK adapter (`firebase_auth` + `flutter_secure_storage`) not in
  `pubspec.yaml`; the production class therefore cannot reach
  Firebase even though the `FirebaseAuthLoginService` framework is
  ready.
- iOS Xcode + Pod wiring (B7) pending macOS session.
- `auth-smoke@forgeflow.dev` test-user state in
  `forge-flow-staging` is unknown; the previous one-off smoke user
  was deleted after the 9.1 token smoke per the tranche 1 report.
  Password must arrive via `$HOME/.forge_flow/forge_flow.secrets.ps1`
  rather than the prompt.
- `RepositoryAuthSessionLedgerWriter` not yet bound in the proxy
  bootstrap (architectural choice between "client calls writer
  directly" vs. "client calls proxy endpoint that wraps writer"
  needs the user's call before wiring).

No live calls were made. No staging or Production1 mutations
occurred. The next slice (B11/B12/B13 MFA framework) can proceed
without B8 because it is also a framework slice that defers its own
live binding to a paired follow-up.

## Last Completed Slice (9.live-closeout B4/B5/B6)

**Files changed:**

- `lib/services/auth/firebase_auth_client.dart` (new) — adapter seam
  for the production `AuthLoginService`. Defines
  `FirebaseAuthSignInOutcome` (sealed: `FirebaseAuthSignInSucceeded` /
  `FirebaseAuthSignInRequiresMfa` / `FirebaseAuthSignInFailed`),
  `FirebaseAuthCredential`, the abstract `FirebaseAuthClient`
  interface (`signInWithEmailPassword`, `completeTotpChallenge`,
  `requestPasswordReset`, `refreshIdToken`, `signOut`,
  `revokeAllRefreshTokens`), and `ScaffoldFailingFirebaseAuthClient`
  fail-closed default. Tokens never echoed in `toString()`.
- `lib/services/auth/firebase_auth_login_service.dart` (new) —
  production `FirebaseAuthLoginService implements AuthLoginService`.
  Translates adapter outcomes into `AuthLoginSuccess` /
  `AuthLoginMfaRequired` / `AuthLoginFailure`. Builds `AuthSession`
  from JWT custom claims (`operator_id`, `is_super_admin`,
  `is_ff_support`, `roles_version`, `mfa_enrolled`); missing
  `operator_id` becomes `AuthLoginFailure(code: 'invalid_claims')`
  without echoing claim values. `AuthLocationResolver` /
  `FixedAuthLocationResolver` resolves the post-login location.
  `refreshSession` preserves the live session's `locationId` (does
  not re-consult the resolver).
- `lib/services/auth/platform_secure_session_storage.dart` (new) —
  `PlatformSecureStorageBackend` adapter (read / write / delete),
  `ScaffoldFailingPlatformSecureStorageBackend` default,
  `InMemoryPlatformSecureStorageBackend` for tests, and
  `PlatformSecureSessionStorage extends SecureSessionStorage` that
  persists the AuthSession JSON under the namespaced key
  `forge_flow.auth.session_v1`. Backend swap (`flutter_secure_storage`
  / Keychain / Android Keystore) is the SDK-adapter follow-up.
- `lib/services/auth/auth_session_ledger_writer.dart` (new) —
  client-facing `AuthSessionLedgerWriter` interface (`recordLogin`
  returns `session_id`, `recordRefresh`, `revokeSession`,
  `revokeAllSessionsForUser`), `AuthSessionLedgerLogin` +
  `AuthSessionLedgerContext` value classes (IP / UA / geo /
  device fingerprint), `ScaffoldFailingAuthSessionLedgerWriter`
  fail-closed default, and `InMemoryAuthSessionLedgerWriter` for
  tests + previewer harnesses.
- `lib/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart`
  (new) — `OperatorScopedRepository` subclass for the `auth_sessions`
  ledger table. `insertLogin` runs INSERT … RETURNING `session_id`
  through `withTenant` + `SET LOCAL`; `markRefreshed` updates
  `last_seen_at = now()` (skips already-revoked rows); `revokeSession`
  sets `revoked_at = now()` + `revoked_reason` idempotently;
  `revokeAllSessionsForUser` (user-owned path) and
  `revokeAllSessionsForUserAsAdmin` (`withSystem`, audited via
  `app.bypass_rls_audit = 'system:<reason>'`) for admin force-logout.
  All parameters bound, never concatenated.
- `lib/services/auth/repository_auth_session_ledger_writer.dart`
  (new) — production `AuthSessionLedgerWriter` that wraps the
  Postgres `AuthSessionsRepository`. Tests use the in-memory writer;
  the live staging smoke (B8) uses this binding.
- `lib/state/auth_session_notifier.dart` — added optional
  `AuthSessionLedgerWriter` (defaults to `InMemoryAuthSessionLedgerWriter`
  so existing tests keep working; production bootstrap injects
  `ScaffoldFailingAuthSessionLedgerWriter` fail-closed default).
  Tracks `_activeSessionId` post-login. On `signIn` success:
  `recordLogin` runs with SHA-256 hex digest of the live Firebase
  **ID token** as `token_hash` (raw token never leaves the value
  class). The column is named `token_hash` honestly — `firebase_auth`
  does not expose the underlying refresh token, so this writer
  cannot detect refresh-token reuse on its own. A future slice with
  a true refresh token can land the real refresh-token hash in the
  same column without changing the contract. On `refreshSession`:
  `recordRefresh` updates `last_seen_at`. On
  `signOutThisSession`: `revokeSession(reason: 'user_signed_out_this_session')`.
  On `signOutAllSessions`:
  `revokeAllSessionsForUser(reason: 'user_signed_out_all_sessions')`.
  Ledger errors on refresh + sign-out are logged but non-fatal (so a
  transient blip doesn't punish the user). Sign-in fails closed on
  ledger error (audit-fix 2026-04-27 Codex F2/F3 — surfaces a calm
  `ledger_unavailable` AuthLoginFailure rather than entering
  AuthSessionAuthenticated without an `auth_sessions` row).
  Added new `refreshSession()` method on the notifier so the ledger
  can pick up the refresh.
  `_defaultLedgerContextFactory` returns empty `AuthSessionLedgerContext`
  by design — production bootstrap overrides once the proxy injects
  resolved IP/geo via response header.

  Audit-fix 2026-04-27 Codex F1 update: persisted shape is now an
  envelope (`StoredAuthSession`) carrying both the `AuthSession` and
  `auth_sessions.session_id`. Cold-start `rehydrate` restores
  `_activeSessionId` from the envelope so post-restart `refreshSession`
  / `signOutThisSession` address the original ledger row instead of
  silently skipping the call. Sign-in side-effect order is now
  ledger → storage → state (F2 reorder) so a ledger failure can never
  leave a persisted session orphaned from its row. Legacy bare-AuthSession
  blobs predating the envelope rehydrate with `authSessionId: null`
  (user stays signed in across the upgrade; ledger calls skip until
  the next fresh sign-in re-establishes the row).
- `lib/forge_flow_bootstrap.dart` — accepts optional
  `authSessionLedgerWriter`; defaults to
  `ScaffoldFailingAuthSessionLedgerWriter` so a misconfigured
  production deploy surfaces a clear "no auth ledger wired" error
  rather than silently dropping `auth_sessions` rows.
- `test/auth_live_binding_test.dart` (new) — 26 tests:
  `ScaffoldFailingFirebaseAuthClient` fails closed; `FirebaseAuthLoginService`
  outcome translation (success / mfa-required / failure / invalid-claims
  guard / completeTotpChallenge / refresh preserves location_id /
  refresh null on no refreshable session); `PlatformSecureSessionStorage`
  round-trip + namespaced key + scaffold-failing backend;
  `InMemoryAuthSessionLedgerWriter` recording + per-user revoke filter +
  scaffold-failing writer; `AuthSessionsRepository` SQL contract
  (INSERT bound parameters + RETURNING projection / no-rows guard /
  markRefreshed where clause / revokeSession reason binding / admin
  withSystem audit reason); `RepositoryAuthSessionLedgerWriter`
  delegation; `AuthSessionNotifier` B6 wiring (recordLogin on signIn
  with SHA-256 ID-token hash, ledger error doesn't block sign-in,
  signOutThisSession revokes the active session_id with the locked
  reason, signOutAllSessions revokes all sessions for user with the
  locked reason, refreshSession updates last_seen_at on the active
  session_id).

**Tests run:**

- `dart analyze` on the 9 touched auth/persistence/state/bootstrap/test
  files → No issues found (1 unused-import flagged + fixed mid-slice).
- `flutter test test/auth_live_binding_test.dart` → 26/26 passed.
- Focused Phase 9 sweep (10 prior test files + the new
  `auth_live_binding_test.dart`):
  `flutter test test/admin_console_test.dart test/user_lifecycle_test.dart
  test/permission_gate_test.dart test/permission_runtime_test.dart
  test/password_and_risk_test.dart test/mfa_test.dart
  test/auth_session_test.dart test/advisor_proxy_test.dart
  test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart
  test/auth_live_binding_test.dart` → 383/383 passed (no regressions).

**Acceptance status:**

- B4 production `AuthLoginService` framework and mobile SDK binding: DONE.
  `FirebaseAuthSdkClient` imports `firebase_auth` in the approved auth
  directory, and app entrypoints opt in with `FORGE_FLOW_USE_FIREBASE_AUTH`.
- B5 production `SecureSessionStorage` framework and secure-storage binding:
  DONE. `FlutterSecureStorageBackend` imports `flutter_secure_storage` in the
  approved auth directory.
- B6 `auth_sessions` ledger writes: framework DONE. Sign-in fails closed when
  no ledger writer is bound, so the next live slice is a client-safe proxy
  session-ledger endpoint + client writer.

**Blockers / known follow-ups:**

- iOS Xcode/Pod verification still requires a macOS build check.
- Web/admin runtime still needs a Dart `FirebaseOptions` binding before browser
  launch.
- Full in-app login needs the proxy session-ledger endpoint; direct client DB
  access is not allowed. Backend credential/session smoke is complete.

## Last Completed Slice (9.9)

**Files changed:**

- `lib/services/admin/audit_log_csv_export.dart` (new) — RFC 4180
  CSV encoder for `auth_events_audit` rows. Quotes fields with
  commas / quotes / newlines, doubles embedded double-quotes,
  emits a canonical sorted-key JSON payload column.
  `AuditLogCsvExport.export` returns the CSV body AND the
  `admin.audit_log.export` audit event the proxy must persist
  (locked decision: every CSV export is audited).
- `lib/services/admin/role_permission_matrix_controller.dart` (new)
  — dense matrix editor controller. `MatrixCellState`
  (inherit / allow / deny), `cell` / `setCell` / `toggleCell`,
  `revertAll`, `isDirty`, `diff` returning ordered
  `MatrixCellChange` list, and `diffPayload()` shaped to the
  `role_audit_log.change_payload` JSONB contract.
- `lib/services/admin/mfa_policy_editor_controller.dart` (new) —
  MFA defaults read from the decision lock: admin roles require MFA,
  staff MFA is optional at every subscription tier unless an operator
  override opts staff in. `diff` + `diffPayload` for the audit row.
  `MfaPolicyEditorPolicy.actorMayEdit` refuses everyone except
  super_admin.
- `lib/services/auth/brute_force_telemetry.dart` — added
  `requestId` field to `BruteForceTelemetryEvent` so the CSV
  export event can carry the X-Request-Id correlation token (and
  any other event that needs it).
- `test/admin_console_test.dart` (new) — 15 tests:
  AuditLogCsvExport (header + rows, RFC 4180 quoting, mandatory
  `admin.audit_log.export` event with actor + filters + row
  count, canonical JSON column ordering); RolePermissionMatrix
  (initial-clean baseline, toggle cycle, setCell upsert, diff
  ignores no-op edits, revertAll, diffPayload contract);
  MfaPolicyEditor (staff optional by default at every tier,
  override-to-required, isDirty + diff capture, clear override
  resets to default, super_admin-only edit policy).

**Tests run:**

- `dart analyze lib/services/admin
  lib/services/auth/brute_force_telemetry.dart
  test/admin_console_test.dart` → No issues found.
- Full Phase 9 sweep: `flutter test test/admin_console_test.dart
  test/user_lifecycle_test.dart test/permission_gate_test.dart
  test/permission_runtime_test.dart test/password_and_risk_test.dart
  test/mfa_test.dart test/auth_session_test.dart
  test/advisor_proxy_test.dart test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart` -> 357/357 passed
  (no regressions).

**Acceptance status:**

- Dense, work-focused admin UX: kernel controllers DONE; the
  Material widgets that consume them are a focused UI slice the
  user can spawn separately. Slice rule "do not make a marketing
  / landing UI" honored — controllers are pure, no marketing copy.
- Custom-role management within permission constraints: DONE —
  `RolePermissionMatrixController` + `RoleManagementPolicy`
  (Phase 9.6) together enforce the seeded-role + scope-visibility
  rules around every cell change.
- Authorized CSV audit export: DONE.
- Every export audited: DONE — `AuditLogCsvExport.export` produces
  a `BruteForceTelemetryEvent('admin.audit_log.export', ...)`
  alongside the CSV body so the proxy cannot accidentally ship the
  CSV without the audit row.
- No marketing / landing UI: confirmed.

**Blockers / known follow-ups (do not block Phase 9 framework
acceptance; gate Phase 9 LIVE acceptance):**

- HTTP endpoints for the admin surfaces (`/v1/admin/auth/users/*`,
  `/v1/admin/auth/roles/*`, `/v1/admin/auth/audit-log/*`) belong
  to the proxy and should use the now-available Postgres repository
  binding.
- Material UI surfaces (Users list with filters, Roles list,
  Role-permission matrix, Audit log viewer) are a focused
  follow-up that consumes the controllers shipped here.
- Full prior-slice gap list still stands (see "Pending live
  follow-ups" below).

## Pending Live Follow-ups (after tranche 1)

Each item is a focused, human-prerequisite work parcel that takes
Phase 9 from "framework + tests" to "live in staging + production":

1. **Production1 auth-table RLS flip.** Staging has
   `202604260000_auth_rls_per_tenant_policies.sql` and
   `202604260001_auth_rls_service_role_grants.sql` applied and
   verified. Production1 remains gated until staging soaks and the
   user explicitly authorizes production mutation.
2. **9.3 SDK adapter binding (`firebase_auth` + `flutter_secure_storage`).**
   The B4/B5 framework is wired through pluggable adapters
   (`FirebaseAuthClient`, `PlatformSecureStorageBackend`). The
   remaining work: add the packages to `pubspec.yaml`; implement
   the SDK adapters that bridge the interfaces to
   `firebase_auth`/`firebase_auth_web` and `flutter_secure_storage`
   (Keychain on iOS / Keystore on Android / web IndexedDB). Pair
   with item 4 (iOS Xcode wiring) so the production class can
   actually run on a device.
3. **9.3 auth session ledger production wiring.** B6 framework is
   complete: `AuthSessionsRepository` + `RepositoryAuthSessionLedgerWriter`
   + notifier integration. The remaining work: wire
   `RepositoryAuthSessionLedgerWriter` over the live
   `PackagePostgresPool` in the proxy bootstrap, and override the
   `AuthSessionLedgerContext` factory so the proxy's resolved
   IP / UA / geo / device-fingerprint actually land on the
   `auth_sessions` row.
4. **9.3 iOS Xcode + Pod wiring.** Pending macOS session; the
   GoogleService-Info plists exist under
   `ios/Runner/Firebase/`. Required before the SDK adapter binding
   in item 2 can run on iOS.
5. **9.4 `firebase_auth` MultiFactor binding.** Implement
   `MfaEnrollmentService` against `TotpMultiFactorGenerator`.
   Wire `RecoveryCodeHasher` against `Sha256RecoveryCodeHasher`
   (the production hasher in `lib/services/mfa/recovery_code_hasher.dart`)
   for proxy-side recovery-code persistence in `mfa_factors`.
6. **9.5 HIBP egress.** Allow outbound HTTPS to
   `api.pwnedpasswords.com` from the proxy egress policy + cap
   at 100 req/min/IP. Wire `HttpHibpRangeFetcher` in production.
   Bind `password_history` reads/writes through the Postgres
   repository path.
7. **9.5 Cloud Armor + reCAPTCHA dashboard config.** Operator
   dashboard work; the framework-side surfaces (telemetry sink,
   risk-signal resolver) are wire-ready.
8. **9.6 Proxy permission endpoints.** Implement
   `/v1/admin/auth/roles/*` + `/v1/admin/auth/role-grants/*` in
   the proxy using `RoleManagementPolicy.evaluateRoleAction` /
   `evaluateGrantAction` plus the Postgres repository path.
9. **9.7 BarrioPreviewRole bulk migration.** Replace every
    `BarrioPreviewRole.isIntendedFor(...)` callsite with
    `PermissionGate(permissionKey: ...)` once the proxy can
    actually feed a real `PermissionContext`. Estimated 16 files.
10. **9.8 firebase_auth Admin SDK + Postgres invite/erasure
    persistence.** Implement the actual `auth_invites` /
    `auth_events_audit` writes alongside the Firebase
    `createUser` / `deleteUser` calls.
11. **9.8 GDPR runbook.** Author `runbooks/gdpr_erasure_runbook.md`
    matching `ErasureRedactionTemplate` exactly. The redaction
    payload contract is canonical; the runbook documents the
    paired-approval workflow + retention conditions.
12. **9.9 Admin console UI surfaces.** Build the dense Material
    UI on top of the kernel controllers (Users list, Roles list,
    Role-permission matrix editor, Audit log viewer with CSV
    export, MFA enforcement editor). Estimated separate slice.

## Phase 9 Framework Test Totals

| Slice | Test file | New tests |
|---|---|---|
| 9.0 (pre-existing) | `test/advisor_proxy_test.dart` (94 baseline) | — |
| 9.1 | `test/advisor_proxy_test.dart` (additions) | 22 |
| 9.2 | `test/operator_scoped_repository_test.dart` | 26 |
| 9.3 | `test/auth_session_test.dart` | 41 |
| 9.4 | `test/mfa_test.dart` | 39 |
| 9.5 | `test/password_and_risk_test.dart` | 31 |
| 9.6 | `test/permission_runtime_test.dart` | 31 |
| 9.7 | `test/permission_gate_test.dart` | 14 |
| 9.8 | `test/user_lifecycle_test.dart` | 31 |
| 9.9 | `test/admin_console_test.dart` | 15 |
| live-closeout B4/B5/B6 | `test/auth_live_binding_test.dart` | 26 |
| live-closeout B11/B12/B13 | `test/mfa_live_binding_test.dart` | 22 |
| live-closeout B14/B15/B16 | `test/password_live_binding_test.dart` | 20 |
| live-closeout B17/B19 | `test/role_admin_live_binding_test.dart` | 20 |
| live-closeout B18 | `test/barrio_destination_visibility_resolver_test.dart` | 8 |
| live-closeout B20/B21 | `test/user_lifecycle_live_binding_test.dart` | 14 |
| 9.0a | `test/phase_9_0a_scope_extensions_test.dart` | 14 |
| 9.10 | `test/team_ux_kernel_test.dart` | 25 |
| **Total Phase 9 surface** | | **506** (94 baseline + 254 framework + 110 live-closeout B4-B21 + 14 9.0a + 25 9.10 + 9 cross-cutting baseline rebuilds) |

Tranche 1 live-closeout added production RS256, the Postgres adapter, staging
RLS/grant migration coverage, and Firebase smoke coverage. The focused Phase 9
sweep after tranche 1 passed **357/357**. Tranche 2 (B4/B5/B6) added the
Firebase auth client adapter, `PlatformSecureSessionStorage`, and the
`auth_sessions` ledger writer + repository + notifier integration; the
focused Phase 9 sweep + new test file passed **383/383**. Tranche 3
(B11/B12/B13) added the `FirebaseMfaClient` adapter +
`FirebaseMfaEnrollmentService`, `MfaFactorsRepository`,
`RecoveryCodeAttemptLimiter`, and `RecoveryCodeConsumer`; the focused
Phase 9 sweep + new test files passed **405/405**.

Other Phase 9 surface tests still in `test/advisor_proxy_test.dart`
(the Phase 9.0 schema + RLS + permission_keys catalog assertions)
are part of the 119 the test file ran after tranche 1.

## Last Completed Slice (9.8)

**Files changed:**

- `lib/auth/user_lifecycle.dart` (new) — `UserStatus` enum
  (mirrors the schema CHECK), `UserLifecycleAction` enum, and
  `UserLifecycleStateMachine.apply` / `canApply` enforcing the
  legal transitions: invited → active; active ↔ suspended;
  active → dormant_30 → 60 → 90; any-dormant → active; dormant_90
  → suspended (HP rule); soft-delete absorbing from any
  non-deleted state. Throws on illegal transitions.
- `lib/services/auth/user_invite_service.dart` (new) — 7-day
  default TTL invite flow. `createInvite` builds the record with
  `expiresAt = now + 7d`; `acceptInvite` mutates `acceptedAt`
  (refuses already-accepted / revoked / expired); `revokeInvite`
  is idempotent. `TrustedUserCreationPolicy.isAllowedFor` only
  passes super_admin per the decision lock.
- `lib/services/auth/gdpr_erasure_service.dart` (new) — paired
  super_admin approval flow with no-self-approval +
  no-double-count guards. `executeErasure` requires the target to
  be soft-deleted first and returns the canonical
  `ErasureRedactionTemplate.payloadFor(...)` shape (redact PII,
  preserve Art. 17(3) operational records). `cancel` flips state
  + blocks subsequent approval / execute.
- `test/user_lifecycle_test.dart` (new) — 31 tests covering the
  state machine (every legal transition + illegal-transition
  refusal + absorbing-deleted), invite service (7-day expiry,
  accept happy / refuse-after-accept / refuse-after-revoke /
  refuse-after-expire, idempotent revoke), trusted creation
  policy (super_admin only, case-insensitive, refuses everything
  else), and GDPR erasure (paired approval requirement,
  approver-must-be-super-admin, no-self-approval, no-double-count,
  prerequisite soft-delete, happy-path redaction payload includes
  the Art. 17(3) preserved fields, executed-then-rejected,
  cancel-blocks-future).

**Tests run:**

- `dart analyze lib/auth/user_lifecycle.dart
  lib/services/auth/user_invite_service.dart
  lib/services/auth/gdpr_erasure_service.dart
  test/user_lifecycle_test.dart` → No issues found.
- `flutter test test/user_lifecycle_test.dart
  test/permission_gate_test.dart test/permission_runtime_test.dart
  test/password_and_risk_test.dart test/mfa_test.dart
  test/auth_session_test.dart test/advisor_proxy_test.dart
  test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart` → 333/333 passed
  (no regressions).

**Acceptance status:**

- Invites expire after 7 days: DONE.
- Trusted direct creation is F&F super_admin only: DONE.
- Soft-delete + status transitions audit: framework DONE
  (transitions return a structured `UserLifecycleTransition` the
  proxy uses for the audit row); the actual `auth_events_audit`
  insert lands with the proxy Postgres binding.
- GDPR erasure redacts PII, preserves operational/audit records:
  DONE — `ErasureRedactionTemplate.payloadFor(...)` carries the
  exact redaction map (`users.email` → `redacted-{user_id}@…`,
  `auth_events_audit.ip` / `user_agent` nulled, etc.) plus the
  preserved-under-Art-17(3) list.
- Break-glass erasure requires two-super-admin paired approval:
  DONE — `recordApproval` enforces super_admin role + no-self-
  approval + no-double-count; `executeErasure` refuses without a
  complete pair.

**Blockers / known follow-ups (not blocking 9.9):**

- `auth_events_audit` row writes for every state transition land
  with the proxy Postgres binding (9.2 follow-up).
- `runbooks/gdpr_erasure_runbook.md` is referenced from the
  redaction template but the runbook itself is a separate doc
  authoring task (Phase 9.8 plan placeholder note).
- All prior pending follow-ups (9.1 RS256, 9.2 staging RLS flip
  + Postgres binding, 9.3 Firebase + secure storage + iOS, 9.4
  firebase_auth MFA + recovery-code persistence, 9.5 HIBP egress
  + Cloud Armor + reCAPTCHA dashboard, 9.6 proxy permission
  endpoints, 9.7 BarrioPreviewRole bulk migration) still pending.

## Last Completed Slice (9.7)

**Files changed:**

- `lib/state/permission_context.dart` (new) — `PermissionContext`
  wraps a `PermissionSnapshot` (Phase 9.6) and adds a per-key
  `requires_mfa` set so the gate can layer fresh-auth checks on top.
  `hasPermission` returns true only for explicit allows; default
  deny on unmapped + explicit deny.
- `lib/screens/auth/permission_gate.dart` (new) — `PermissionGate`
  widget reads the current `PermissionContext` (via Provider) and
  renders [child] only when the key is allowed AND, for MFA-required
  keys, the [AuthSessionNotifier] reports `isAuthFresh`. Otherwise
  renders [denied] (defaulting to a zero-size widget so unpermitted
  surfaces vanish from layout). Fails closed when no
  `PermissionContext` provider is installed.
- `test/permission_gate_test.dart` (new) — 14 tests covering
  PermissionContext (allow / deny / unmapped / requires_mfa /
  diagnostics) and PermissionGate widget (allow renders, deny
  hides, default-deny on unmapped, cross-tenant denial, cross-user
  isolation, fresh-auth layering both directions, missing provider
  fails closed, missing auth notifier with fresh-auth requirement
  fails closed).

**Tests run:**

- `dart analyze lib/state/permission_context.dart
  lib/screens/auth/permission_gate.dart test/permission_gate_test.dart`
  → No issues found.
- `flutter test test/permission_gate_test.dart
  test/permission_runtime_test.dart test/password_and_risk_test.dart
  test/mfa_test.dart test/auth_session_test.dart
  test/advisor_proxy_test.dart test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart` → 302/302 passed
  (no regressions).

**Acceptance status:**

- Gate Forge & Flow + Barrio surfaces through the permission
  runtime: DONE for the `PermissionGate` primitive. Per-screen
  migration of every `BarrioPreviewRole.isIntendedFor(...)` call
  to `PermissionGate(permissionKey: ...)` is a focused follow-up
  (16 files touch in the Barrio shell; bulk migration is best
  done as a single prompt to keep diffs readable).
- Retire preview-role assumptions where 9.7 owns them: PARTIAL —
  9.3 already wired `BarrioPreviewRole.fromAuthRoles(...)` so the
  Barrio shell derives its preview tier from real auth roles.
  Full removal of `BarrioPreviewRole` (replacing the chip-driven
  tier with permission-key checks) is the staged follow-up.
- Support / admin scoping follows the decision lock: DONE — the
  resolver kernel from 9.6 already enforces ff_support per-operator
  scope + super_admin override + operator_manager sub-role limit.
- Tests for allow / deny / cross-tenant denial / missing-permission
  denial: DONE.

**Blockers / known follow-ups (not blocking 9.8):**

- Wholesale `BarrioPreviewRole` migration to `PermissionGate` is
  staged; tracked alongside the 9.5 / 9.75 staff-companion + El
  Podio learning-identity work which depends on per-user state.
- Proxy-side permission guard (`/v1/admin/*` request gating)
  needs the proxy `package:postgres` binding from 9.2 to load
  `user_roles` + `role_permissions` per request.
- All prior pending follow-ups (9.1 RS256, 9.2 staging RLS flip
  + Postgres binding, 9.3 Firebase + secure storage + iOS, 9.4
  firebase_auth MFA + recovery-code Postgres persistence, 9.5
  HIBP egress + Cloud Armor + reCAPTCHA dashboard) still pending.

## Last Completed Slice (9.6)

**Files changed:**

- `lib/auth/permission_effect.dart` (new) — `PermissionEffect.allow / deny`.
- `lib/auth/permission_resolution.dart` (new) — pure resolver:
  `UserRoleGrant` with `isActiveAt(now)` + `coversLocation(loc)`,
  `RolePermissionRule` value class, and `PermissionResolver.resolve`
  / `resolveAll`. Implements the plan's algorithm: filter by tenant
  + active + location, then deny-wins + default-deny.
- `lib/auth/role_management_policy.dart` (new) —
  `RoleManagementPolicy.evaluateRoleAction` (create / edit / delete)
  and `evaluateGrantAction` (grant / revoke). Encodes:
  super_admin = unrestricted; seeded + locked roles editable only
  by super_admin; operator_owner restricted to their own
  operator-scoped roles; ff_support requires assigned operator
  scope; operator_manager limited to operator_supervisor +
  operator_staff within own location. Returns `RoleManagementDecision`
  with reason text for audit.
- `lib/auth/permission_cache.dart` (new) — LRU cache keyed by
  `(userId, rolesVersion, operatorId, locationId)` with default
  60s TTL. `read` / `put` / `invalidateUser` / `clear`. Tracks
  `hitCount` / `missCount` / `evictionCount`. roles_version bump
  is implicit invalidation (different key); explicit user
  invalidation supported for the bump-and-read race.
  `PermissionSnapshot.effectFor` defaults unmapped keys to deny.
- `test/permission_runtime_test.dart` (new) — 31 tests:
  resolver (default deny, allow, deny-wins, expired / not-yet /
  revoked grants, cross-tenant + cross-location isolation,
  operator-wide grant covers any location, resolveAll); role
  management (super_admin override, seeded protection, global
  role protection, operator_owner same/other operator,
  operator_manager allowed sub-roles, location scope, denial
  reasons); cache (miss → put → hit, roles_version bump miss,
  TTL expiry, LRU eviction, invalidateUser, snapshot default deny).

**Tests run:**

- `dart analyze lib/auth/permission_resolution.dart
  lib/auth/permission_effect.dart lib/auth/role_management_policy.dart
  lib/auth/permission_cache.dart test/permission_runtime_test.dart`
  → No issues found.
- `flutter test test/permission_runtime_test.dart
  test/password_and_risk_test.dart test/mfa_test.dart
  test/auth_session_test.dart test/advisor_proxy_test.dart
  test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart` → 288/288 passed
  (no regressions).

**Acceptance status:**

- Permission resolution: DONE — kernel passes the deny-wins +
  default-deny semantics.
- Explicit deny wins: DONE (verified by test that deny + allow
  for the same key on different active roles resolves to deny).
- Seeded roles protected: DONE — `is_seeded + !is_editable`
  refused for non-super_admin actors; global roles refused for
  non-super_admin actors.
- Operator owners create/edit operator-scoped custom roles only:
  DONE.
- Permission cache invalidation tied to roles_version: DONE — a
  roles_version bump produces a new cache key (no read of stale
  entry) and explicit invalidateUser purges any lingering entries.

**Blockers / known follow-ups (not blocking 9.7):**

- HTTP endpoints under `/v1/admin/auth/roles/*` and
  `/v1/admin/auth/role-grants/*` belong to the proxy + need the
  9.2 Postgres binding to load grants + bundles + write audit.
- `users.roles_version` bump on every role / grant change is
  proxy-side; the cache layer here is wire-ready.
- All prior pending follow-ups (9.1 RS256, 9.2 staging RLS flip
  + Postgres binding, 9.3 Firebase + secure storage + iOS, 9.4
  firebase_auth MFA + recovery-code Postgres persistence, 9.5
  HIBP egress + Cloud Armor + reCAPTCHA dashboard) still pending.

## Last Completed Slice (9.5)

**Files changed:**

- `lib/auth/password_policy.dart` (new) — `PasswordPolicy.validate`
  returns every NIST SP 800-63B-4 violation in one shot
  (`tooShort`, `tooLong`, `containsControlChars`,
  `containsLeadingOrTrailingSpace`). Allows full Unicode + emoji,
  no composition rules, no forced rotation.
- `lib/services/auth/hibp_pwned_password_screener.dart` (new) —
  HIBP k-anonymity client. Real SHA-1 hashing via
  `package:crypto`; `HttpHibpRangeFetcher` production fetcher (5s
  timeout, `Add-Padding` on, custom user agent);
  `ScaffoldFailingHibpRangeFetcher` fail-closed default; the
  screener returns `notPwned` / `pwned` / `screenerUnavailable`
  so the caller decides policy on outage.
- `lib/services/auth/password_history_check.dart` (new) — interface
  for the `password_history` Postgres lookup; production binding
  lands with the 9.2 Postgres follow-up. Default fails closed
  (refuses change) so silent reuse cannot slip through.
- `lib/services/auth/password_change_service.dart` (new) — composes
  policy + HIBP + history into a single `evaluate` returning all
  rejections at once. Tunable `failClosedOnHibpUnavailable` for
  high-security operator profiles; default fails open with audit.
- `lib/services/auth/brute_force_telemetry.dart` (new) —
  `BruteForceTelemetryEvent` value class +
  `BruteForceTelemetrySink` interface + in-memory recorder for
  tests + `ScaffoldFailingBruteForceTelemetrySink` default.
  Production binds to the proxy's `auth_events_audit` writer.
- `lib/services/auth/risk_signal_resolver.dart` (new) — pure
  geo/ASN/impossible-travel resolver. Haversine distance + speed
  cap (default 1000 km/h) for impossible-travel; denied-country
  list for soft-block; multi-signal stacking pushes to soft-block.
  Paid IP reputation vendor remains parked per the decision lock.
- `test/password_and_risk_test.dart` (new) — 31 tests across
  PasswordPolicy (every violation + happy path),
  HibpPwnedPasswordScreener (notPwned / pwned / case-insensitive
  match / fetcher throw → unavailable / scaffold default),
  PasswordChangeService (happy / shape / pwned / unavailable
  open + closed / reuse / history outage / multi-rejection
  defense in depth), telemetry sinks, and RiskSignalResolver
  (allow / step-up / soft-block / clock-skew tolerance).

**Tests run:**

- `dart analyze lib/auth/password_policy.dart lib/services/auth
  test/password_and_risk_test.dart` → No issues found.
- `flutter test test/password_and_risk_test.dart test/mfa_test.dart
  test/auth_session_test.dart test/advisor_proxy_test.dart
  test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart` → 257/257 passed
  (no regressions).

**Acceptance status:**

- Enforce NIST password rules: DONE
  (`PasswordPolicy.validate` covers length + control chars +
  edge whitespace + Unicode tolerance).
- HIBP k-anonymity screening seam: DONE — real SHA-1 + range
  client + fail-open default + audit hook through the change
  service.
- Brute-force / risk telemetry: DONE — telemetry sink + risk
  resolver. Server-side rate-limit counters (1/min, 5/24h
  recovery-code attempts; 100 req/hr/IP/account login throttle)
  land alongside the proxy Postgres binding.
- Cloud Armor / reCAPTCHA documentation/config: NOT executed
  — slice rule honored. The pattern is documented in code
  comments + the checkpoint, but no live dashboard mutation
  was performed.
- Paid IP reputation vendor: DEFERRED per the decision lock.

**Blockers / known follow-ups (not blocking 9.6):**

- HIBP outbound HTTPS allowlist + per-IP rate cap (100/min)
  belong on the proxy's egress policy. The screener seam
  itself is wire-ready.
- `password_history` writes / reads need the proxy
  `package:postgres` binding (9.2 follow-up).
- Cloud Armor + reCAPTCHA v3 site key configuration are
  human-prerequisite cloud setup steps (operator dashboard).
- 9.1 RS256 / 9.2 staging RLS / 9.3 Firebase + secure storage /
  9.4 firebase_auth MFA + recovery-code persistence — all
  prior pending items still pending.

## Last Completed Slice (9.4)

**Files changed:**

- `pubspec.yaml` — moved `crypto: ^3.0.7` from `dev_dependencies`
  to `dependencies` so `lib/services/mfa/recovery_code_hasher.dart`
  can use SHA-256 in production code. Same lock-file version, no
  toolchain change.
- `lib/auth/mfa_policy.dart` (new) — `OperatorSubscriptionTier`
  enum (pilot / starter / premium / pro / enterprise) and
  `MfaPolicy.evaluate(...)` that encodes the locked enforcement
  matrix: admin roles always require MFA, staff MFA is optional at
  every subscription tier unless an operator override opts staff in.
  Mixed-roles use highest-tier-wins; unknown roles never upgrade a
  user to admin tier; case-insensitive role matching.
- `lib/services/mfa/recovery_code_generator.dart` (new) — generates
  10 codes of `XXXX-XXXX-XXXX` shape using a 27-char Crockford-ish
  alphabet (≈57 bits of entropy per code). Uses `Random.secure` by
  default; tests inject a deterministic LCG. `normalize()` accepts
  user-typed input (mixed case, no dashes, extra spaces) and refuses
  out-of-alphabet characters.
- `lib/services/mfa/recovery_code_hasher.dart` (new) —
  `RecoveryCodeHasher` interface, production `Sha256RecoveryCodeHasher`
  (per-user 16-byte salt + SHA-256 + constant-time verify), and
  `ScaffoldFailingRecoveryCodeHasher` fail-closed default.
  `HashedRecoveryCode` value class for storage in `mfa_factors`
  (Phase 9.0 schema).
- `lib/services/mfa/mfa_enrollment_service.dart` (new) —
  `MfaEnrollmentService` interface (begin TOTP enrollment / confirm
  TOTP enrollment), `TotpEnrollmentSetup` + `MfaEnrollmentCompleted`
  result types, and `ScaffoldFailingMfaEnrollmentService` default.
- `lib/services/mfa/mfa_removal_service.dart` (new) — 24-hour delay
  flow per the decision lock. `requestRemoval` requires a
  non-blank `stepUpProofId` (proxy injects the
  `auth_events_audit.event_id` of the fresh-auth challenge);
  `executeRemoval` returns `MfaRemovalNotYetExecutable` until
  `now >= executeAfter`, then `MfaRemovalCompleted`. Cancel path
  records `cancelledAt`, blocks subsequent execute.
- `lib/screens/auth/mfa_challenge_screen.dart` (new) — TOTP entry
  form with optional "use recovery code" toggle, error banner,
  cancel-sign-in escape, and submit guard. Wires through the
  existing `AuthSessionNotifier.completeTotpChallenge` API.
- `lib/screens/auth/mfa_challenge_placeholder.dart` (deleted) —
  replaced by the real screen above.
- `lib/screens/auth/auth_gate.dart` — switched
  `AuthSessionMfaChallenge` route from the placeholder to the new
  `MfaChallengeScreen`.
- `test/auth_session_test.dart` — updated import + class reference
  for the renamed challenge widget.
- `test/mfa_test.dart` (new) — 39 tests across MfaPolicy
  (admin-tier, staff-tier-by-subscription, mixed roles, null
  tier, case folding), RecoveryCodeGenerator (shape + uniqueness +
  reject bad inputs + normalize), Sha256RecoveryCodeHasher
  (roundtrip, mismatch, salt-uniqueness, bad-base64 tolerance),
  scaffold-failing hasher + enrollment service, MfaRemovalService
  (24h delay flow, cancel, idempotency), and MfaChallengeScreen
  widget (render, empty-submit, happy submit, recovery-code path,
  cancel).

**Tests run:**

- `dart analyze lib/auth/mfa_policy.dart lib/services/mfa
  lib/screens/auth/mfa_challenge_screen.dart
  lib/screens/auth/auth_gate.dart test/mfa_test.dart` →
  No issues found.
- `flutter test test/mfa_test.dart test/auth_session_test.dart
  test/advisor_proxy_test.dart test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart` → 226/226 passed
  (no regressions).

**Acceptance status:**

- Enforce MFA policy from the decision lock: DONE
  (`MfaPolicy.evaluate` returns `requiredAndNotEnrolled` /
  `requiredAndEnrolled` / `optional` for every documented case).
- TOTP enrollment / challenge state: DONE — enrollment service
  interface + result types + scaffold default; challenge screen
  wired to the existing notifier API.
- 10 single-use recovery codes, display once, hash at rest: DONE
  framework — generator produces 10 codes, hasher persists
  per-user salted SHA-256, normalization survives typed input.
  Server-side single-use enforcement (`mfa_factors.used_at`)
  lands when the proxy `package:postgres` binding lands.
- MFA removal step-up + 24-hour delay: DONE — service requires a
  step-up proof, refuses execution until 24h elapses, supports
  cancel.
- Passkeys / WebAuthn NOT built (parked decision honored).

**Blockers / known follow-ups (not blocking 9.5):**

- Production `firebase_auth.MultiFactor` binding for
  `MfaEnrollmentService` (TOTP secret generation + Firebase-side
  factor enrollment) is the same follow-up that brings
  `firebase_auth` in for 9.3.
- Server-side `mfa_factors` writes (factor_id row, recovery code
  row, `used_at` on consumption) need the proxy
  `package:postgres` binding from the 9.2 follow-up.
- Rate-limit enforcement on recovery-code attempts (1/min,
  5/24h per the plan) lands server-side alongside the proxy
  Postgres binding — the framework here exposes the seam, the
  enforcement counter is a Phase 9.5 / proxy concern.
- 9.1 RS256 backend, 9.2 staging RLS flip, 9.3 Firebase /
  secure-storage / iOS still pending (see prior sections).

## Last Completed Slice (9.3)

**Files changed:**

- `lib/auth/auth_session.dart` (new) — `AuthSession` value class
  with `isAuthFresh(window)` for step-up checks, `isLive`, JSON
  round-trip, and `toString` that never echoes the Firebase ID
  token.
- `lib/services/secure_session_storage.dart` (new) — abstract
  storage seam, `InMemorySecureSessionStorage` for tests, and
  `ScaffoldFailingSecureSessionStorage` fail-closed default.
- `lib/services/auth_login_service.dart` (new) —
  `AuthLoginService` interface (sign-in / TOTP completion /
  password reset / refresh / single + all-sessions sign-out),
  `AuthLoginSuccess` / `AuthLoginMfaRequired` / `AuthLoginFailure`
  result types, and `ScaffoldFailingAuthLoginService` default.
- `lib/state/auth_session_notifier.dart` (new) — ChangeNotifier
  with `loading` / `unauthenticated` / `mfaChallenge` /
  `authenticated` states. Drives sign-in via the service, persists
  via storage, and exposes `requireFreshAuth()` /
  `isAuthFresh` for the 5-minute step-up window from the decision
  lock. Handles storage failures by falling through to
  unauthenticated rather than crashing the boot.
- `lib/screens/auth/auth_gate.dart` (new) — root widget that swaps
  between loading / login / MFA placeholder / authenticated child
  based on the notifier state.
- `lib/screens/auth/login_screen.dart` (new) — minimal email +
  password form with autofill hints, error banner, submit guard.
- `lib/screens/auth/mfa_challenge_placeholder.dart` (new) — gate
  placeholder for the AuthSessionMfaChallenge state. Real TOTP
  entry UI lands in 9.4.
- `lib/internal/barrio/routes/barrio_preview_role.dart` — added
  `BarrioPreviewRole.fromAuthRoles(...)` factory mapping the
  Phase 9.6 role keys (super_admin / ff_support / operator_owner /
  operator_manager / operator_supervisor / operator_staff) onto
  the existing preview tier enum, with "highest tier wins" for
  multi-role grants and case-insensitive matching. Empty roles
  fall back to admin (preview / dev).
- `lib/internal/barrio/screens/barrio_home_screen.dart` — derives
  the preview role from the AuthSessionNotifier when a session is
  live; preserves the existing chip-based override for dev /
  preview surfaces. Falls back gracefully when no provider is
  installed (existing widget tests keep working).
- `lib/forge_flow_bootstrap.dart` — wraps the supplied app shell
  in a `ChangeNotifierProvider<AuthSessionNotifier>` so both
  Forge & Flow standalone and Barrio share the same session
  (HP #9 — Forge & Flow inside Barrio uses the live Barrio
  session). Defaults to scaffold-failing services so a deploy that
  forgets to wire Firebase / secure-storage surfaces a clear
  error rather than silently allowing.
- `test/auth_session_test.dart` (new) — 41 tests across
  AuthSession, BarrioPreviewRole.fromAuthRoles, storage,
  scaffold-failing service, AuthSessionNotifier (loading,
  rehydrate happy/expired/storage-failure paths, sign-in
  success/MFA/failure, step-up freshness, sign-out),
  AuthGate widget (every state), and LoginScreen widget
  (disabled-without-input + happy submit + error banner).

**Tests run:**

- `dart analyze lib/auth lib/services/auth_login_service.dart
  lib/services/secure_session_storage.dart
  lib/state/auth_session_notifier.dart lib/screens/auth
  lib/internal/barrio/routes/barrio_preview_role.dart
  lib/internal/barrio/screens/barrio_home_screen.dart
  lib/forge_flow_bootstrap.dart` → No issues found.
- `flutter test test/auth_session_test.dart` → 41/41 passed.
- `flutter test test/auth_session_test.dart test/advisor_proxy_test.dart
  test/operator_scoped_repository_test.dart
  test/barrio_role_preview_widget_test.dart` → 195/195 passed
  (no regressions in existing 9.0/9.1/9.2 + barrio preview role
  surfaces).

**Acceptance status:**

- Login services + UI surfaces for the Phase 9.3 minimum: DONE
  (LoginScreen, AuthGate, MfaChallengePlaceholder).
- Persistent session: DONE for the storage seam + InMemory backend.
  Production `flutter_secure_storage` binding is the remaining
  gap (parallel to 9.1 RS256 backend).
- Step-up state: DONE — `requireFreshAuth` + `isAuthFresh` honor
  the 5-minute decision-lock window via injectable clock.
- Replace preview role assumptions where 9.3 owns them: DONE —
  `BarrioPreviewRole.fromAuthRoles(...)` derives the preview tier
  from real auth roles; `BarrioHomeScreen` reads it via the
  notifier when a session exists. Full removal of `BarrioPreviewRole`
  is staged for 9.7 along with the permission gates.
- iOS verification kept honest: framework code only, no
  Xcode/Pod wiring touched on Windows.

**Blockers / known follow-ups (not blocking 9.4):**

- `firebase_auth` / `firebase_auth_web` package binding for the
  production `AuthLoginService` implementation is the next
  focused follow-up (parallel to 9.1 RS256 + 9.2 `package:postgres`).
- `flutter_secure_storage` package binding for production
  `SecureSessionStorage`. Defaults to fail-closed scaffold so a
  deploy that forgets to wire it gets a clear startup error.
- `auth_sessions` writes (INSERT on login, UPDATE on refresh,
  revoked_at on logout) require the production `package:postgres`
  binding from the 9.2 follow-up.
- Web admin console security headers + Mozilla Observatory
  verification: deferred to the admin web shell (Phase 9.9 / 11A).
- iOS Xcode / Gradle Firebase plugin wiring: pending macOS / live
  Firebase session.
- Live staging login smoke (`auth-smoke@forgeflow.dev`) pending
  the above wiring.
- 9.1 Production RS256 signature validator + 9.2 staging RLS flip
  remain pending — see prior checkpoint sections.

## Live-Apply / Wiring Checklists (NOT executed in this slice)

These checklists are unchanged from 9.2; reproduced here so the
checkpoint stays the single source of truth for human-prereq
follow-ups:

1. **9.2 staging RLS flip** —
   `psql --single-transaction -v ON_ERROR_STOP=1 -f db/migrations/202604260000_auth_rls_per_tenant_policies.sql "$env:POSTGRES_ADMIN_URL"`,
   then verification SQL described in the prior checkpoint
   section (verify forge_admin role, all 14 stub policies dropped,
   per-tenant policies present, negative + positive smokes).
2. **9.1 RS256 backend** — pick a Dart RSA library (e.g.
   `pointycastle`) and implement `JwtRs256SignatureValidator` that
   parses x509 PEM certs and verifies RSASSA-PKCS1-v1_5 SHA-256.
   Wire it in `tool/advisor_proxy/main.dart` instead of
   `ScaffoldFailingRs256SignatureValidator`.
3. **9.2 `package:postgres` binding** — implement `PostgresPool`,
   `PostgresTransaction`, `PostgresExecutor` against the real
   driver inside `lib/infrastructure/persistence/postgres/`.
4. **9.3 `firebase_auth` / `flutter_secure_storage` binding** —
   implement `AuthLoginService` against `firebase_auth` (mobile)
   / `firebase_auth_web` (admin); implement `SecureSessionStorage`
   against `flutter_secure_storage` (Keychain / Android Keystore).
5. **iOS Xcode / Pod wiring** — pending macOS session.

## Stale Findings Already Cleared

(Unchanged.)

- 11a staging report records the 7-day staging backup gap and
  B1ms PgBouncer limitation; Production1 closes the
  production-only requirements.
- `scripts/use_postgres_staging_env.ps1` failure paths use
  `return`, not `exit`.
- `scripts/postgres_staging_setup.ps1` documents the expanded
  Azure extension + `shared_preload_libraries` requirements.
- `user_roles_active_grant_idx` is tenant-leading.
- `auth_events_audit` actor + target indexes lead with
  `operator_id`.

## Next Slice

`9.4` MFA enrollment + enforcement:

- Enforce MFA policy from the decision lock (admin roles require
  MFA at every tier; staff MFA is optional at every subscription
  tier unless explicitly opted in).
- Implement TOTP enrollment + challenge state — wires into the
  9.3 `AuthSessionMfaChallenge` placeholder.
- Implement 10 single-use recovery codes, display once, hash at
  rest. Rate-limit attempts per the plan.
- MFA removal requires step-up + 24-hour delay (audit both ends).
- Do NOT build passkeys / WebAuthn (parked decision).
