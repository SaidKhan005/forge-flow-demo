# A3 — Proxy Monolith Decomposition Plan

Planning document only. No code changes, no tests, no PRs. Maps a
clean decomposition of `tool/advisor_proxy/advisor_proxy.dart`
(18,623 lines as of 2026-05-12, worktree `nifty-clarke-d3ec25`) into
bounded sub-modules so future proxy lanes can land without serializing
on a single file. Complementary to A1 (proxy bug root-cause) and to
the Lane A lens-audit running in parallel.

All file:line citations are from this worktree. Authority order:
`CLAUDE.md` Proxy & API Conventions, the post-Codex wave decision lock
(`docs/archive/_decisions/post_codex_wave_decisions_2026-05-12.md`), the
canonical Phase 7.55 architecture
(`docs/contracts/core_app_architecture.md`), and the existing stub
plan (`docs/phases/proxy_split/proxy_split_plan.md`) that this audit
formalizes.

---

## Section 1 — Current structure inventory

`tool/advisor_proxy/` holds **38 Dart files**. Line counts (highest
first):

| File                                                       | Lines  | Role                                                       |
| ---------------------------------------------------------- | -----: | ---------------------------------------------------------- |
| `advisor_proxy.dart`                                       | 18,623 | THE monolith. Route handler, gateways, config, JWT, lockout, helpers. |
| `proxy_bootstrap.dart`                                     |  8,691 | Production wiring (repositories → gateways → router callsite). |
| `main.dart`                                                |  2,183 | Cloud Run entrypoint; serve loop; `runZonedGuarded`.       |
| `integration_oauth_routes.dart`                            |  2,145 | Vendor OAuth start/callback for Square/Clover/Humanity/etc. |
| `phase_8_vendor_integration_factories.dart`                |  1,093 | Phase 8 vendor factories (POS / labor / reservation).      |
| `admin_integrations_routes.dart`                           |  1,092 | Admin-side vendor integration mgmt routes (already extracted). |
| `realtime_bridge.dart`                                     |  1,033 | Pub/Sub → in-process publisher bridge.                     |
| `weekly_plan_routes.dart`                                  |  1,021 | Weekly-plan truth router (already extracted).              |
| `star_target_routes.dart`                                  |    999 | Selected-star / target-cycle router (already extracted).   |
| `operator_routes.dart`                                     |    954 | Operator self-service write router (already extracted).    |
| `wage_role_rows_routes.dart`                               |    695 | Wage role rows write router (already extracted).           |
| `integration_oauth_state_store.dart`                       |    613 | OAuth state-token store + Postgres-backed impl.            |
| `phase_8_production_binder.dart`                           |    587 | Phase 8 production binder (wires factories into bootstrap). |
| `notification_preferences_routes.dart`                     |    532 | Notification-preferences PUT/DELETE/GET (already extracted). |
| `mobile_push_notifications.dart`                           |    520 | Mobile-push token register/revoke/test gateway impl.       |
| `worker_startup_wiring.dart`                               |    511 | Background worker startup helpers.                         |
| `realtime_route.dart`                                      |    502 | WebSocket upgrade + subscription glue.                     |
| `admin_email_routes.dart`                                  |    417 | Admin email-template / -dispatch routes.                   |
| `admin_business_timing_routes.dart`                        |    410 | Admin-side business-timing overrides (already extracted).  |
| `pos_adapter_registry.dart`                                |    394 | POS-adapter registry.                                      |
| `labor_adapter_registry.dart`                              |    305 | Labor-adapter registry.                                    |
| `advisor_response_cache.dart`                              |    293 | Postgres-backed advisor response cache.                    |
| `pepper_routes.dart`                                       |    283 | Pepper-rotation route + audit.                             |
| `audit_chain_anchors_routes.dart`                          |    261 | Per-tenant audit-chain-anchor read (already extracted).    |
| `vendor_lifecycle_recently_available_routes.dart`          |    258 | Vendor-lifecycle "recently available" read (already extracted). |
| `reservation_adapter_registry.dart`                        |    250 | Reservation-adapter registry.                              |
| `realtime_tripwire_gateway.dart`                           |    240 | Realtime tripwire status gateway.                          |
| `anthropic_http_complete_fn.dart`                          |    220 | Anthropic HTTP completion helper.                          |
| `business_scope_routes.dart`                               |    186 | Business-scope read router (already extracted).            |
| `vendor_admin_status_catalog.dart`                         |    185 | Vendor admin status catalog (data).                        |
| `connector_backfill_jobs_routes.dart`                      |    162 | Connector backfill jobs read router (already extracted).   |
| `proxy_idempotency_cache.dart`                             |    150 | Proxy-side idempotency cache (memory + audit).             |
| `phase_8_test_connection_executor.dart`                    |    136 | Phase 8 test-connection executor.                          |
| `vendor_capability_index.dart`                             |     62 | Vendor capability constants.                               |
| `health_operation_budget.dart`                             |     41 | Health-route operation budget guard.                       |
| `log.dart`                                                 |     12 | Re-export shim for logging.                                |
| (subdirs)                                                  |        | `email_dispatch/`, `email_templates/`, `health_producers/`, `graphify_candidates/` |
| **Total**                                                  | **46,059** | (`wc -l tool/advisor_proxy/*.dart`)                    |

### Distribution

- The monolith is **40.4%** of the directory by lines.
- Adding `proxy_bootstrap.dart` (production wiring) puts a single
  two-file pair at **59.3%** of the directory.
- Eleven route files have **already** been extracted as standalone
  router classes (`weekly_plan_routes`, `star_target_routes`,
  `operator_routes`, `wage_role_rows_routes`,
  `notification_preferences_routes`, `business_scope_routes`,
  `audit_chain_anchors_routes`, `connector_backfill_jobs_routes`,
  `vendor_lifecycle_recently_available_routes`,
  `admin_business_timing_routes`, `admin_integrations_routes`). The
  pattern is established and working — the remaining sections
  in `advisor_proxy.dart` follow it.
- The monolith's **own** structure breaks roughly into three layers:
  1. Lines 1–8384 — config, secrets, JWT/auth value types, services,
     gateways, abstract classes, route-path constants. ~8,400 lines
     of class definitions + path constants.
  2. Lines 8385–14661 — the single `routeRequest(...)` function and
     its inline route handlers. ~6,300 lines, one function.
  3. Lines 14662–18623 — top-level helper functions (`_routeIntegrationsAdmin`,
     `_routePricingAdmin`, etc.), path matchers, JSON helpers, CORS
     glue. ~3,950 lines.

### What the monolith holds that belongs elsewhere

- **Auth lockout enforcement, MFA retry counters, password-reset
  throttle counters** (lines 6493–7099) — bounded context, belongs in
  `lib/services/auth/` or its own `routes/auth/` module.
- **Path constants for every route family** (lines 6934–8273, ~1,340
  lines of `const String *Path = '/v1/...'`) — belongs in a shared
  `routes/_paths.dart`.
- **Health surface dependency probe + registry** (lines 5329–5505) —
  belongs in `routes/health.dart`.
- **Service-principal JWT issuer + Postgres-backed issuance gateway**
  (lines 1204–1374, 2706–3247) — belongs in
  `routes/service_principals.dart`.
- **Auth-operations admin handler** (the giant `_isAdminAuthOperation`
  branch, lines 10652–11625, ~970 lines inline in `routeRequest`) —
  belongs in `routes/auth_team_admin.dart`.

---

## Section 2 — Bounded-context map

Each bounded context lists: line range(s) in `advisor_proxy.dart`,
the route paths it owns, shared dependencies, and an approximate
LoC count. Path constants cited live in `advisor_proxy.dart:6934-8273`
unless flagged otherwise.

### 2.1 Health + readiness + smoke probes

- **Line ranges (handler):** 8653-8794 (`/healthz`, `/readyz`,
  `/health`, `/v1/scope`, `/v1/realtime/tripwire-status`), 9131-9196
  (`/v1/usage-smoke`), 9197-9544 (`/v1/advisor-smoke`).
- **Routes:**
  - `GET /healthz` (`healthPath`)
  - `GET /readyz` (`readinessPath`)
  - `GET /health` (`deepHealthPath`)
  - `GET /v1/scope` (`scopeSmokePath`)
  - `GET /v1/usage-smoke` (`usageSmokePath`)
  - `GET /v1/advisor-smoke` (`advisorSmokePath`)
  - `GET /v1/realtime/tripwire-status` (`realtimeTripwireStatusPath`)
- **Shared deps:** `ProxyHealthCheckStore`, `ProxyUsageGuard`,
  `ProxyAccountingStore`, `ProxyLlmProvider`, `AdvisorRequestPipeline`,
  `ProxyRuntimeGauges`, `RealtimeTripwireProxyGateway`.
- **Approx LoC in handler:** ~530.

### 2.2 Auth — sessions, login, refresh, revoke

- **Line ranges (handler):** 12120-13150 (login + refresh + revoke +
  revoke-all + refresh-tokens-revoke-all + sessions list + team
  sessions list).
  - `POST /v1/auth/refresh-tokens/revoke-all` — 12120-12165.
  - `GET /v1/auth/sessions` — 12167-12216.
  - `GET /v1/auth/team/sessions` — 12224-12308.
  - `POST /v1/auth/session/login` — 12655-12948 (~290 LoC, the
    failure-report + lockout + success path described in A1 §1.1).
  - `POST /v1/auth/session/refresh` — 12949-13012.
  - `POST /v1/auth/session/revoke` — 13013-13082.
  - `POST /v1/auth/session/revoke-all` — 13083-13150.
- **Shared deps:** `AuthSessionLedgerWriter`,
  `FirebaseAdminAuthClient`, `AuthOperationsGateway`,
  `AuthLockoutEnforcer`, `AuthLockoutAuditSink`,
  `ProxyPermissionSnapshotResolver`,
  `ProxyRequestGuard.requireOperatorContext`.
- **Approx LoC in handler:** ~1,030.
- **High-risk seam.** Carries the failure-report → lockout flow,
  hash-chain audit row writes via `AuthLockoutAuditSink`. Touches
  `_resolveLedgerContextFromHeaders` (`advisor_proxy.dart:18262`),
  `hashAuthEmailHex` / `hashAuthIpHex` (used at `12723-12724`).

### 2.3 Auth — account, permissions snapshot, audit log read+export

- **Line ranges (handler):** 9545-9612 (account), 9584-9612
  (permissions snapshot), 12420-12573 (audit log CSV export),
  12575-12654 (audit log read).
- **Routes:**
  - `GET /v1/auth/account` (`authAccountInfoPath`)
  - `GET /v1/auth/permissions/snapshot` (`authPermissionsSnapshotPath`)
  - `GET /v1/auth/audit-log` (`authAuditLogPath`)
  - `GET /v1/auth/audit-log/export.csv` (`authAuditLogExportPath`)
- **Shared deps:** `AccountInfoGateway`,
  `ProxyPermissionSnapshotResolver`, `AuthOperationsGateway`,
  `PermissionEffect`, `PermissionKeys.teamAuditLogExport`.
- **Approx LoC in handler:** ~410.
- **High-risk seam.** Audit-log export streams chunked CSV (12506-12572)
  directly to `response`; cannot retroactively switch to a JSON error
  envelope once headers are committed. The bare `catch (_)` at 12566
  is a known one of the 16 cataloged in `proxy_split_plan.md`.

### 2.4 Auth — passwords + magic link + MFA recovery

- **Line ranges (handler):**
  - `POST /v1/auth/password/change` — 9783-9852.
  - `POST /v1/auth/password/reset/request` — 9853-10026.
  - `POST /v1/auth/password/reset/confirm` — 10027-10144.
  - `POST /v1/auth/magic-link/redeem` — 10145-10226.
  - `POST /v1/auth/mfa/recovery/request` — 10227-10318.
- **Shared deps:** `PasswordChangeGateway`,
  `PasswordResetConfirmGateway`, `PasswordResetRequestGateway`,
  `MagicLinkRedeemGateway`, `MfaRecoveryRequestGateway`,
  `RollingWindowAttemptCounter` (×3: throttle, IP, short-window),
  `hashAuthEmailHex`, `hashAuthIpHex`.
- **Approx LoC in handler:** ~540.

### 2.5 MFA — TOTP enroll / confirm / list / revoke / cancel

- **Line range (handler):** 10319-10588 (the `_isMfaOperation` branch
  starting after the bearer-token resolution at ~10280).
- **Routes:**
  - `POST /v1/auth/mfa/totp/begin` (`authMfaTotpBeginPath`) — 10340-10367.
  - `POST /v1/auth/mfa/totp/confirm` (`authMfaTotpConfirmPath`) — 10368-10442.
  - `POST /v1/auth/mfa/factors/list` (`authMfaFactorsListPath`) — 10443-10486.
  - `POST /v1/auth/mfa/factors/revoke` (`authMfaFactorsRevokePath`) — 10487-10522.
  - `POST /v1/auth/mfa/factors/removal/cancel` (`authMfaFactorsRemovalCancelPath`) — 10523-10547.
- **Shared deps:** `MfaOperationsGateway`,
  `IdentityToolkitFirebaseMfaError`, `RollingWindowAttemptCounter`
  (TOTP retry), `kAuthMfaTotpRetryThreshold`,
  `_requireFreshAuthenticationOrWrite`, `_freshAuthProofId`,
  `AuthLockoutAuditSink.recordMfaRetryExceeded`.
- **Approx LoC in handler:** ~270.
- **Predicate:** `_isMfaOperation(path, method)` (`advisor_proxy.dart:17711-17718`).

### 2.6 Service principals — JWT issuance

- **Line range (handler):** 10589-10650 (`POST
  /v1/admin/service-principals/{id}/jwt`).
- **Routes:** `POST /v1/admin/service-principals/{sp_id}/jwt` via
  `_servicePrincipalJwtIssueId(path, method)` at
  `advisor_proxy.dart:17700-17709`.
- **Shared deps:** `ServicePrincipalJwtIssuanceGateway`,
  `ProxyAdminPermissionGuard`, `PermissionKeys.adminServicePrincipalIssueToken`.
- **Class defs in monolith:** `ServicePrincipalJwtIssuer` (1204-1235),
  `ServicePrincipalJwtVerifier` (1236-1372),
  `ServicePrincipalJwtIssueCommand` / `…Issued` / `…Rejected` /
  abstract gateway (2706-2764),
  `PostgresServicePrincipalJwtIssuanceGateway` (2765-3171),
  `_ServicePrincipalIssueRow` (3172-3247).
- **Approx LoC across monolith:** value classes ~150, Postgres
  gateway ~410, route handler ~62.

### 2.7 Auth admin / team — invites, users, roles, role-grants, org-units, locations, sessions admin, audit log admin, erase-pii

- **Line range (handler):** 10652-12119 — the `_isAdminAuthOperation`
  branch. By far the largest single inline block (~1,470 LoC).
- **Predicate:** `_isAdminAuthOperation(path, method)`
  (`advisor_proxy.dart:17550-17637`).
- **Canonical path map:** `_canonicalAuthOperationPath(path)`
  (`advisor_proxy.dart:17639-17668`) folds the `team/*` self-service
  paths onto the `admin/auth/*` shape so the handler is single-source.
- **Routes:**
  - `GET / POST /v1/admin/auth/roles` and `PATCH / DELETE
    /v1/admin/auth/roles/{role_id}` (~10752-10985).
  - `GET / PATCH / POST /v1/admin/auth/users[…]` plus `erase-pii`
    sub-action (10752-11260).
  - `GET /v1/admin/auth/sessions`, `POST
    /v1/admin/auth/sessions/{session_id}/revoke` (11625-11710).
  - `GET /v1/admin/auth/invites`, `POST
    /v1/admin/auth/invites`, `DELETE
    /v1/admin/auth/invites/{invite_id}` (11712-11885).
  - `POST /v1/admin/auth/role-grants`, `DELETE
    /v1/admin/auth/role-grants/{grant_id}` (11888-11985).
  - `GET / POST /v1/admin/auth/org-units`, `PATCH
    /v1/admin/auth/org-units/{org_unit_id}/parent`, `PATCH
    .../suspend`, `PATCH .../reactivate`, `POST .../delete`
    (11986-12039).
  - `PATCH /v1/admin/auth/locations/{location_id}/org-unit`, plus
    `suspend`, `reactivate`, `delete` (12039-12119).
  - `GET /v1/admin/auth/audit-log` (11376-11625 — the admin audit log
    read with cross-operator listing, distinct from the operator-side
    `/v1/auth/audit-log`).
  - Mirror `team/*` versions: `/v1/auth/team/invites`,
    `/v1/auth/team/users`, `/v1/auth/team/roles`,
    `/v1/auth/team/role-grants`, `/v1/auth/team/org-units`,
    `/v1/auth/team/locations/{id}/org-unit`. Folded onto the admin
    shape via `_canonicalAuthOperationPath`.
- **Shared deps:** `AuthOperationsGateway`,
  `ProxyAdminPermissionGuard`, `ProxyAuthIdempotencyCache`,
  `UserPiiErasureService`, `FirebaseAdminAuthClient`,
  `_effectiveAdminAuthScope` (used to widen scope to cross-operator
  when `super_admin` / `ff_support` calls a `team/*` path).
- **Approx LoC in handler:** ~1,470. **Largest single contiguous
  inline block in the file.**
- **High-risk seam.** Writes `auth_events_audit` rows on every
  mutating branch; per HP #8 and CLAUDE.md the audit hash chain is
  non-negotiable.

### 2.8 Admin — operator + location lifecycle (F&F internal)

- **Line range (handler):** 14049-14171 (the `_isAdminOperatorOrLocationOperation`
  branch in `routeRequest`).
- **Delegate function:** `_routeOperatorLocationAdmin` at
  `advisor_proxy.dart:14689-15007` (~320 LoC).
- **Routes** (via `_isAdminOperatorOrLocationOperation`,
  `advisor_proxy.dart:14678-14687`):
  - `GET /v1/admin/operators` (`adminOperatorsPath`)
  - `POST /v1/admin/operators`
  - `PATCH /v1/admin/operators/{id}` (suspend / reactivate / delete /
    archive sub-actions via path suffix)
  - `POST /v1/admin/operators/{id}/...`
  - `POST /v1/admin/locations`
  - `PATCH /v1/admin/locations/{id}` (suspend / reactivate)
  - `DELETE /v1/admin/locations/{id}`
- **Shared deps:** `OperatorLocationAdminProxyGateway`,
  `AdminRequestIdempotencyStore`, `_isFfOperatorLocationAdminCaller`,
  `kFfOperatorLocationAdminRoles`.
- **Approx LoC:** inline ~120 + delegate ~320 = ~440.

### 2.9 Admin — integrations (KMS rotate, status, list)

- **Line range (handler):** 13144-13311 (the `_isAdminIntegrationsOperation`
  branch in `routeRequest`).
- **Delegate function:** `_routeIntegrationsAdmin` at
  `advisor_proxy.dart:15078-15207` (~130 LoC).
- **Routes** (via `_isAdminIntegrationsOperation`,
  `advisor_proxy.dart:15062-15159`):
  - `GET /v1/admin/integrations` (`adminIntegrationsListPath`)
  - `GET /v1/admin/integrations/status`
  - `POST /v1/admin/integrations/rotate-anthropic` / `rotate-voyage` /
    `rotate-azure-db` / `rotate-gemini` (4 paths).
- **Shared deps:** `IntegrationAdminProxyGateway`,
  `IntegrationAdminActorResolver`, `AdminRequestIdempotencyStore`,
  `_requireFreshClaimsOrWrite` (MFA-fresh check for write methods).
- **Approx LoC:** inline ~170 + delegate ~130 = ~300.
- **High-risk seam.** Rotation writes go to `provider_credentials`
  and emit an audit row; fresh-MFA gate is critical.

### 2.10 Admin — pricing tier + usage caps + polling pricing

- **Line range (handler):** 13313-13422 (the `_isAdminPricingOperation`
  branch).
- **Delegate function:** `_routePricingAdmin` at
  `advisor_proxy.dart:15602-15805` (~200 LoC).
- **Routes** (via `_isAdminPricingOperation`,
  `advisor_proxy.dart:15164-15175`):
  - `/v1/admin/pricing/operators` (+ prefix)
  - `/v1/admin/pricing/usage-caps`
  - `/v1/admin/polling-pricing/tier-definitions` (+ prefix)
  - `/v1/admin/polling-pricing/assignments` (+ prefix)
  - `/v1/admin/polling-pricing/scoped-assignments`
  - `/v1/admin/polling-pricing/margin` and `.../margin/export-csv`
  - `/v1/admin/polling-pricing/change-requests` (+ prefix)
- **Shared deps:** `PricingTierAdminProxyGateway`,
  `AdminRequestIdempotencyStore`.
- **Approx LoC:** inline ~110 + delegate ~200 = ~310.

### 2.11 Admin — data accuracy + scoped settings + audit history

- **Line range (handler):** 13424-13525 (the `_isAdminDataAccuracyOperation`
  branch).
- **Delegate function:** `_routeDataAccuracyAdmin` at
  `advisor_proxy.dart:15208-15601` (~390 LoC).
- **Routes** (via `_isAdminDataAccuracyOperation`,
  `advisor_proxy.dart:15177-15909`):
  - `/v1/admin/data-accuracy/rows`
  - `/v1/admin/data-accuracy/settings` (+ prefix)
  - `/v1/admin/data-accuracy/scoped-settings`
  - `/v1/admin/data-accuracy/audit-history`
- **Shared deps:** `DataAccuracyAdminProxyGateway`,
  `AdminRequestIdempotencyStore`.
- **Approx LoC:** inline ~100 + delegate ~390 = ~490.

### 2.12 Admin — corpus + age rebuild + graphify candidates

- **Line range (handler):** 13526-13680 (corpus admin),
  13681-13763 (graphify candidates).
- **Delegate functions:**
  - `_routeCorpusAdmin` at `advisor_proxy.dart:15806-15928` (~120 LoC).
  - `_routeGraphCandidates` at `advisor_proxy.dart:16540-16922`
    (~380 LoC).
- **Routes:**
  - Corpus: `/v1/admin/corpus/versions` (+ prefix),
    `/v1/admin/corpus/upload`, `/v1/admin/corpus/preview-diff`,
    `/v1/admin/corpus/commit`, `/v1/admin/corpus/rollback`,
    `/v1/admin/age/rebuild`.
  - Graphify: `/v1/admin/corpus/graph-candidates`,
    `/v1/admin/corpus/graph-candidates/commit-batch`.
- **Shared deps:** `CorpusAdminProxyGateway`,
  `GraphCandidatesProxyGateway`, `_enforceGraphCandidateSourceScope`
  (`advisor_proxy.dart:16639-16733`).
- **Approx LoC:** ~660 total.

### 2.13 Admin — feature flags + debug console + observability

- **Line ranges (handler):**
  - Feature flags: 13764-13919 (`_isAdminFeatureFlagsOperation`).
  - Debug console: 13921-13986 (`_isAdminDebugOperation`).
  - Observability: 13987-14047 (`_isAdminObservabilityOperation`).
- **Delegate functions:**
  - `_routeFeatureFlagsAdmin` at `advisor_proxy.dart:16203-16539` (~340).
  - `_routeDebugConsoleAdmin` at `advisor_proxy.dart:15929-16152` (~220).
  - `_routeObservabilityAdmin` at `advisor_proxy.dart:16153-16202` (~50).
- **Routes:**
  - Feature flags: `/v1/admin/feature-flags`,
    `/v1/admin/feature-flags/toggle`.
  - Debug: `/v1/admin/debug/requests`, `.../requests/by-id`,
    `.../requests/by-key`, `.../requests/tail`,
    `.../full-content-opt-ins`, `.../relationship-help`,
    `.../account-help`.
  - Observability: `/v1/admin/observability`.
- **Shared deps:** `FeatureFlagsAdminProxyGateway`,
  `DebugConsoleAdminProxyGateway`,
  `ObservabilityAdminProxyGateway`, `AdminRequestIdempotencyStore`.
- **Approx LoC:** ~770 total.

### 2.14 Realtime — WebSocket subscribe

- **Line ranges:** delegated to `realtime_route.dart` (handled in
  `routeRequest` at the `handleRealtimeUpgrade(...)` callsite — not
  inlined in the monolith).
- **Routes:** `GET /v1/realtime` (upgrade).
- **Shared deps:** `InProcessRealtimePublisher`,
  `RealtimeReplayFetcher`.

### 2.15 Mobile operational sync (read + data-accuracy settings write)

- **Line ranges (handler):** 9103-9130 (PATCH data-accuracy settings),
  9119-9130 (GET mobile-operational paths).
- **Delegate functions:**
  - `_routeMobileOperationalSync` at `advisor_proxy.dart:16923-17057`
    (~130 LoC).
  - `_routeOperatorDataAccuracySettingsWrite` at
    `advisor_proxy.dart:17058-17260` (~200 LoC).
- **Routes:** `/v1/operators/{operator_id}/...` family
  (`mobileOperatorsPrefix`). Handles the demo/mobile read seam plus
  the operator-scoped data-accuracy PATCH.
- **Shared deps:** `MobileOperationalSyncProxyGateway`,
  `BusinessScopeProxyGateway`, `_mobileOperationalPath` matcher.

### 2.16 Operator-self-service routers (already extracted as classes, mounted in handler)

These are already in their own files; the handler block in
`advisor_proxy.dart` is a mount point only. Listing for sequencing
reference because they share the same Idempotency-Key + scope guards
as the new extractions.

| Bounded context                          | Mount block in monolith | Owning file                                              |
| ---------------------------------------- | ----------------------- | -------------------------------------------------------- |
| Weekly plan                              | 8797-8889               | `weekly_plan_routes.dart`                                |
| Selected star / target                   | 8891-8989               | `star_target_routes.dart`                                |
| Business scope                           | 8991-9042               | `business_scope_routes.dart`                             |
| Audit chain anchors (operator-side)      | 9044-9101               | `audit_chain_anchors_routes.dart`                        |
| Operator write router (account + timing) | 14176-14266             | `operator_routes.dart`                                   |
| Admin business timing                    | 14272-14361             | `admin_business_timing_routes.dart`                      |
| Connector backfill jobs                  | 14367-14418             | `connector_backfill_jobs_routes.dart`                    |
| Vendor lifecycle recently available      | 14424-14479             | `vendor_lifecycle_recently_available_routes.dart`        |
| Notification preferences                 | 14484-14559             | `notification_preferences_routes.dart`                   |
| Wage role rows                           | 14567-14645             | `wage_role_rows_routes.dart`                             |
| Admin integrations (KMS rotate)          | (via `_routeIntegrationsAdmin`) | `admin_integrations_routes.dart`                  |
| Admin email                              | (via `main.dart` mount) | `admin_email_routes.dart`                                |
| Pepper rotation                          | (via `main.dart` mount) | `pepper_routes.dart`                                     |
| Integration OAuth                        | (via `main.dart` mount) | `integration_oauth_routes.dart`                          |

### 2.17 Push notifications (mobile)

- Delegated to `mobile_push_notifications.dart`. Handler block in
  `advisor_proxy.dart`:
  - `POST /v1/auth/mobile/push-token/register` — 9613-9673.
  - `POST /v1/auth/mobile/push-token/revoke` — 9674-9728.
  - `POST /v1/auth/mobile/push/test` — 9729-9782.
- **Shared deps:** `MobilePushTokenGateway`,
  `MobilePushSelfTestGateway`.

### 2.18 Auth-location integrations read (per-operator integrations list)

- **Line range (handler):** 12310-12412 (`/v1/auth/locations/{id}/integrations`).
- **Shared deps:** `OperatorLocationIntegrationsProjection`,
  `ProxyPermissionSnapshotResolver`,
  `authLocationIntegrationsPattern` regex.

---

## Section 3 — Target file layout

After decomposition, `advisor_proxy.dart` becomes bootstrap + middleware
+ route mounts only. Estimated post-split size: **~1,200-1,500 lines**
(vs 18,623 today).

### 3.1 Proposed directory structure

```
tool/advisor_proxy/
  advisor_proxy.dart                        # routeRequest dispatch, ~1.2k LoC
  main.dart                                 # unchanged
  proxy_bootstrap.dart                      # production wiring (separate audit candidate)

  routes/
    _paths.dart                             # ALL path consts (~1,340 LoC moved)
    _shared/
      cors.dart                             # respondAdminCorsPreflight + helpers
      idempotency.dart                      # _runAdminIdempotent, header parsing
      json_body.dart                        # _readJsonBody, _MalformedJsonBodyError
      strings.dart                          # _nonBlankString, _commaSeparatedQueryList
      response.dart                         # _writeJson, _writeDependencyTimeoutEnvelope, _logProxyUnhandled
      scope_guard.dart                      # _resolveOperatorContextOrWrite, requireScopeChecked
      permission_guard.dart                 # _requireAdminPermissionOrWrite, _requireFreshClaimsOrWrite
      fresh_auth.dart                       # _requireFreshAuthenticationOrWrite, _freshAuthProofId
      ledger_context.dart                   # _resolveLedgerContextFromHeaders
      auth_hashing.dart                     # hashAuthEmailHex / hashAuthIpHex (moved from current monolith)

    health.dart                             # /healthz, /readyz, /health, smoke probes
    auth_session.dart                       # /v1/auth/session/*, /v1/auth/sessions, /v1/auth/team/sessions
    auth_account.dart                       # /v1/auth/account, /v1/auth/permissions/snapshot
    auth_audit_log.dart                     # /v1/auth/audit-log (read), .../export.csv
    auth_passwords.dart                     # /v1/auth/password/*, /v1/auth/magic-link/redeem
    auth_mfa.dart                           # /v1/auth/mfa/*
    auth_mfa_recovery.dart                  # /v1/auth/mfa/recovery/request
    auth_lockout.dart                       # value types: AuthLockoutEnforcer, *Sink, RollingWindowAttemptCounter
    auth_team_admin.dart                    # /v1/admin/auth/* + /v1/auth/team/* (the 1,470-line beast — biggest single extraction)
    service_principals.dart                 # value types + Postgres gateway + /v1/admin/service-principals/{id}/jwt
    push_tokens.dart                        # /v1/auth/mobile/push-token/*
    realtime.dart                           # /v1/realtime upgrade mount; /v1/realtime/tripwire-status
    mobile_operational.dart                 # /v1/operators/{id}/... read + data-accuracy PATCH

    admin_operator_location.dart            # /v1/admin/operators/*, /v1/admin/locations/*
    admin_integrations.dart                 # already extracted; restated as canonical home
    admin_pricing.dart                      # /v1/admin/pricing/*, /v1/admin/polling-pricing/*
    admin_data_accuracy.dart                # /v1/admin/data-accuracy/*
    admin_corpus.dart                       # /v1/admin/corpus/* + /v1/admin/age/rebuild
    admin_graph_candidates.dart             # /v1/admin/corpus/graph-candidates*
    admin_feature_flags.dart                # /v1/admin/feature-flags*
    admin_debug.dart                        # /v1/admin/debug/*
    admin_observability.dart                # /v1/admin/observability

    auth_location_integrations.dart         # /v1/auth/locations/{id}/integrations

  jwt/                                      # value classes + verifiers extracted from monolith head
    proxy_jwt_claims.dart                   # ProxyJwtClaims, ProxyJwtVerificationError, OperatorContext
    proxy_jwt_verifier.dart                 # abstract + ScaffoldRejectingJwtVerifier + CompositeProxyJwtVerifier
    firebase_jwt_verifier.dart              # FirebaseProxyJwtVerifier + JWKS sources
    service_principal_jwt.dart              # ServicePrincipalJwtIssuer + Verifier
    rs256_validator.dart                    # JwtKeyMaterial + JwtRs256SignatureValidator impls
    proxy_request_guard.dart                # ProxyRequestGuard
    proxy_auth_error.dart                   # ProxyAuthError

  policy/                                   # service classes orchestrated by handlers
    policy_tier.dart                        # PolicyTier, PolicyTierResolver, FixedLaunchTierResolver
    usage_estimate.dart                     # UsageEstimate, UsageSnapshot, UsageRefusal, UsageDecisionAllowed
    usage_counter_store.dart                # ProxyUsageCounterStore + scaffold-failing impl
    usage_guard.dart                        # ProxyUsageGuard
    accounting_store.dart                   # ProxyAccountingStore + Postgres impl
    permission_snapshot.dart                # ProxyPermissionSnapshot + resolver iface
    permission_version_checker.dart         # PermissionVersionChecker iface + in-memory impl
    proxy_request_log_policy.dart           # ProxyRequestLogPolicy

  llm/                                      # provider plumbing
    proxy_llm_provider.dart                 # iface + Scaffold-Rejecting
    anthropic_llm_provider.dart             # AnthropicProxyLlmProvider (delegates to anthropic_http_complete_fn.dart)
    gemini_llm_provider.dart                # GeminiProxyLlmProvider
    secondary_breaker.dart                  # SecondaryLlmBreaker
    advisor_request_pipeline.dart           # AdvisorRequestPipeline + AdvisorPipelineResult
    advisor_prompt_cache_builder.dart       # AdvisorPromptCacheBuilder + ProxyPromptBlock

  health/                                   # already partially under `health_producers/` subdir
    proxy_health_check_store.dart           # iface + Registry/Scaffold impls
    proxy_health_dependency_probe.dart      # default + strict probes
    proxy_health_metric_catalog.dart        # constants currently 4000-4400 in monolith
    proxy_runtime_gauges.dart               # ProxyRuntimeGauges holder
```

### 3.2 What `advisor_proxy.dart` looks like after the split

```dart
// Forge & Flow advisor proxy — request dispatch.
// All bounded-context handlers live under tool/advisor_proxy/routes/.
// This file holds only:
//   - the top-level routeRequest signature (the existing 70-parameter
//     dependency surface, which is itself a future audit candidate)
//   - the request-scope try/finally for response.close
//   - the correlation-id + log-context zone setup
//   - the path-family dispatch ladder
//   - the per-bounded-context mounts (the route classes already in routes/)

Future<void> routeRequest(HttpRequest request, ProxyRequestGuard guard, {...}) async {
  final response = request.response;
  final correlationId = readOrMintCorrelationId(request, response);
  await withProxyLogContext(ProxyLogContext(correlationId: correlationId, ...), () async {
    try {
      try {
        final path = request.uri.path;
        if (await handleAdminCors(request, response, path)) return;
        if (rejectOversizedBody(request, response, path)) return;

        // Health surface
        if (await dispatchHealth(request, response, path, healthCheckStore, ...)) return;
        // Auth surface
        if (await dispatchAuthSession(request, response, path, authGuard, authSessionLedgerWriter, ...)) return;
        if (await dispatchAuthAccount(request, response, path, ...)) return;
        if (await dispatchAuthAuditLog(request, response, path, ...)) return;
        if (await dispatchAuthPasswords(request, response, path, ...)) return;
        if (await dispatchAuthMfa(request, response, path, ...)) return;
        // Service principals
        if (await dispatchServicePrincipals(request, response, path, ...)) return;
        // Admin auth / team
        if (await dispatchAuthTeamAdmin(request, response, path, ...)) return;
        // Push tokens
        if (await dispatchPushTokens(request, response, path, ...)) return;
        // Realtime
        if (await dispatchRealtime(request, response, path, ...)) return;
        // Mobile operational sync
        if (await dispatchMobileOperational(request, response, path, ...)) return;
        // Operator self-service (already extracted routers)
        if (await dispatchOperatorRouters(request, response, path, ...)) return;
        // Admin operator/location
        if (await dispatchAdminOperatorLocation(request, response, path, ...)) return;
        // Admin integrations / pricing / data-accuracy / corpus / graph / flags / debug / observability
        if (await dispatchAdminConsoles(request, response, path, ...)) return;

        write404(response, request);
      } on DependencyTimeoutException catch (error) {
        writeDependencyTimeoutEnvelope(response, error);
      }
    } finally {
      await response.close();
    }
  });
}
```

Each `dispatchXxx` returns `Future<bool>` indicating whether the
request was handled — keeps the dispatch ladder flat and explicit
and matches the early-return idiom already used inline.

---

## Section 4 — Migration sequencing

Extract in this order. Sequencing rationale at the top of each step.
The plan is governed by three principles:

- **Lowest-coupling first.** The bounded contexts with the fewest
  cross-references can be extracted in isolation, building confidence
  in the pattern before riskier extractions.
- **Audit-touching last.** Anything that writes to `auth_events_audit`
  or `audit_chain_anchors` is moved late, and only after the auth-log
  hash chain is regression-tested end-to-end (see Risk §7.1).
- **One bounded context per PR, never split a context across PRs.**
  The handler file is moved in a single commit so the cross-file
  diff is reviewable.

### Step 0 — Mechanical prereq: `routes/_paths.dart`

- **Scope:** Move all `const String *Path = '/v1/...'` declarations
  from `advisor_proxy.dart:6934-8273` (~1,340 lines) into
  `routes/_paths.dart` and re-export from the monolith for back-compat.
  Pure mechanical move, no behavior change.
- **Effort:** half day.
- **Dependencies:** none.
- **Test impact:** Imports change in tests that reference path
  constants directly (`test/advisor_proxy_test.dart` heavily). Tests
  do not need new assertions — re-export covers existing callers.
- **Risk:** Low. Compiler verifies references.
- **Order rationale:** Every subsequent step needs paths in a stable
  shared location.

### Step 1 — `routes/_shared/` helpers

- **Scope:** Move `_writeJson`, `_readJsonBody`, `_nonBlankString`,
  `_writeDependencyTimeoutEnvelope`, `_maybeWriteDependencyTimeout`,
  `_logProxyUnhandled`, `_isBodyMethod`, `resolveRequestBodyLimitBytes`,
  `respondAdminCorsPreflight`, `_applyAdminCorsHeaders`,
  `_matchAdminCorsOrigin`, `_requireAdminPermissionOrWrite`,
  `_resolveLedgerContextFromHeaders`, `_MalformedJsonBodyError`,
  `_runAdminIdempotent`, `_AdminInputError` (file lines 17720-18650 for
  the leaf helpers; 16408-16539 for `_runAdminIdempotent`).
- **Effort:** ~1 day.
- **Dependencies:** Step 0 (paths import in a few helpers).
- **Test impact:** Existing tests touch these indirectly via routes;
  no new test files needed if the helpers stay package-private to
  `tool/advisor_proxy/`.
- **Risk:** Low-medium. `_runAdminIdempotent` carries the
  `admin_request_idempotency` insert path — any rename or signature
  drift breaks every admin write. Test the seam in isolation via the
  existing `test/tool/advisor_proxy/admin_idempotency_reclaim_test.dart`.
- **Order rationale:** Helpers are the unblocker for every route
  extraction — moving them first means each subsequent extraction is
  a single file move plus a single dispatch addition.

### Step 2 — Health + readiness + smoke probes (`routes/health.dart`)

- **Scope:** Extract handler blocks at `advisor_proxy.dart:8653-8794`
  + `9131-9544`. ~530 LoC.
- **Effort:** 1 day.
- **Dependencies:** Steps 0, 1.
- **Test impact:** `test/proxy/advisor_proxy_health_envelope_test.dart`
  switches imports. `test/proxy/registry_proxy_health_check_store_test.dart`
  unaffected (already tests the store directly).
- **Risk:** Low. Health endpoints are read-only, no audit writes.
- **Order rationale:** Smallest self-contained block that exercises
  the dispatch + helper pattern end-to-end. Confirms the
  `dispatchXxx → Future<bool>` shape works against real production
  routes before harder extractions.

### Step 3 — Push tokens (`routes/push_tokens.dart`)

- **Scope:** Extract `advisor_proxy.dart:9613-9782` (3 routes,
  ~170 LoC).
- **Effort:** half day.
- **Dependencies:** Steps 0, 1.
- **Test impact:** `test/proxy/mobile_push_routes_test.dart` swaps imports.
- **Risk:** Low. Self-contained, single gateway dep.

### Step 4 — Auth account + permissions snapshot (`routes/auth_account.dart`)

- **Scope:** Extract `advisor_proxy.dart:9545-9612` (account) +
  `9584-9612` (permissions snapshot). ~70 LoC.
- **Effort:** half day.
- **Dependencies:** Steps 0, 1.
- **Test impact:** Account tests in `test/advisor_proxy_test.dart`
  (lines need located post-extraction); proxy_auth_operations_route
  test untouched.
- **Risk:** Low. Reads only.

### Step 5 — MFA TOTP routes (`routes/auth_mfa.dart`)

- **Scope:** Extract `advisor_proxy.dart:10319-10588` (5 POST routes
  for begin/confirm/list/revoke/cancel). ~270 LoC.
- **Effort:** 1 day.
- **Dependencies:** Steps 0, 1, plus `routes/_shared/fresh_auth.dart`
  (a focused sub-step that pulls `_requireFreshAuthenticationOrWrite`
  + `_freshAuthProofId` from `advisor_proxy.dart` — these are
  referenced by MFA, integrations admin, and admin auth team paths,
  so they belong in shared).
- **Test impact:** MFA-related tests in
  `test/advisor_proxy_test.dart` swap imports. No new fixtures
  needed.
- **Risk:** Medium. The TOTP confirm route at 10368-10442 carries
  the per-challenge retry counter (`mfaTotpRetryCounter`) and the
  429 lockout audit row (`AuthLockoutAuditSink.recordMfaRetryExceeded`,
  10391-10399). Audit row write must move with the route — sink type
  stays in `routes/auth_lockout.dart` (Step 6).

### Step 6 — Auth lockout types + enforcer (`routes/auth_lockout.dart`)

- **Scope:** Move value types
  `AuthLockoutEvaluation` (`advisor_proxy.dart:6493-6519`),
  `AuthLoginFailureOutcomes` (6520-6541),
  `AuthLockoutAuditSink` (6542-6587),
  `InMemoryAuthLockoutAuditSink` (6588-6674),
  `AuthLockoutEnforcer` (6675-6717),
  `InMemoryAuthLockoutEnforcer` (6718-6840),
  `InMemoryAuthAttempt` (6841-6862),
  `RollingWindowAttemptCounter` (6863-7099),
  plus `kAuthMfaTotpRetryThreshold` / `kAuthLoginLockoutRetryAfter`
  / `kAuthMfaTotpRetryAfter` constants. ~610 LoC.
- **Effort:** half day.
- **Dependencies:** Step 0.
- **Test impact:** `test/proxy/auth_lockout_routes_test.dart` swaps
  imports; `test/advisor_proxy_test.dart` lockout tests likewise.
- **Risk:** Low-medium. **Audit row writes** but the sink interface
  is stable; only the file location changes.

### Step 7 — Auth password routes (`routes/auth_passwords.dart`)

- **Scope:** Extract `advisor_proxy.dart:9783-10226` (password change
  / reset request / reset confirm / magic-link redeem) + MFA recovery
  request `10227-10318`. ~540 LoC.
- **Effort:** 1 day.
- **Dependencies:** Steps 0, 1, 6 (lockout counters).
- **Test impact:**
  `test/proxy/magic_link_redeem_routes_test.dart` and the password
  / reset blocks in `test/advisor_proxy_test.dart`.
- **Risk:** Medium. Rate-limit counters (per-email, per-IP, short-
  window) flow into these handlers — make sure all four counter
  instances continue threading through the new module's signature.

### Step 8 — Auth session ledger + login (`routes/auth_session.dart`)

- **Scope:** Extract `advisor_proxy.dart:12120-13150` (login + refresh
  + revoke + revoke-all + refresh-tokens-revoke-all + sessions list +
  team sessions list). ~1,030 LoC.
- **Effort:** 2-3 days.
- **Dependencies:** Steps 0, 1, 6, plus `routes/_shared/auth_hashing.dart`
  (`hashAuthEmailHex` / `hashAuthIpHex`).
- **Test impact:** `test/proxy_auth_operations_route_test.dart`
  (3,081 LoC) plus the login portions in `test/advisor_proxy_test.dart`.
- **Risk:** High. A1 §1 documents the support-user / scope-mismatch
  defect already living in this route. Carries the
  `failure_outcome` lockout branch + `auth_login_attempts` writes +
  `auth_events_audit` writes. Audit row insertion path must move
  with the route. Coordinate with whoever owns the A1 fix so the
  extraction doesn't collide with the bug-fix PR.

### Step 9 — Auth audit-log read + CSV export (`routes/auth_audit_log.dart`)

- **Scope:** Extract `advisor_proxy.dart:12420-12654`. ~410 LoC.
- **Effort:** 1 day.
- **Dependencies:** Steps 0, 1.
- **Test impact:**
  `test/proxy/admin_audit_extensions_test.dart` (verify scope),
  plus the audit-log read blocks in `test/advisor_proxy_test.dart`.
- **Risk:** Medium. Streaming CSV export reuses headers once
  committed — preserve the exact chunked-transfer dance at
  12506-12572. The bare `catch (_)` at 12566 (one of the 16) is the
  only mid-stream failure absorber; do not collapse it into a typed
  arm during extraction (the in-flight bare-catch sweep in
  `proxy_split_plan.md` Sequencing Option 1 covers that as a
  separate step inside the same PR).

### Step 10 — Service principals (`routes/service_principals.dart`)

- **Scope:** Move `ServicePrincipalJwtIssuer` (1204-1235),
  `ServicePrincipalJwtVerifier` (1236-1372),
  `ServicePrincipalJwtIssueCommand` / `…Issued` / `…Rejected` /
  abstract gateway (2706-2764),
  `PostgresServicePrincipalJwtIssuanceGateway` (2765-3171),
  `_ServicePrincipalIssueRow` (3172-3247), and the route handler at
  10589-10650. ~620 LoC.
- **Effort:** 1.5 days.
- **Dependencies:** Step 0; the `jwt/` subdirectory (the SP verifier
  rebinds via `CompositeProxyJwtVerifier` — that's a Step 12 chunk).
- **Test impact:** Tests that today instantiate
  `ServicePrincipalJwtIssuanceGateway` swap imports.
- **Risk:** Medium. The Postgres gateway carries the `service_principal_*`
  table writes + audit row emission. Pure file move — keep the
  signature identical so the bootstrap binding doesn't drift.

### Step 11 — Auth-location integrations read (`routes/auth_location_integrations.dart`)

- **Scope:** Extract `advisor_proxy.dart:12310-12412` (the
  `authLocationIntegrationsPattern` regex match + handler). ~100 LoC.
- **Effort:** half day.
- **Dependencies:** Steps 0, 1.
- **Test impact:** `test/proxy/auth_location_integrations_route_test.dart`.
- **Risk:** Low. Read-only.

### Step 12 — JWT infrastructure (`jwt/` subtree)

- **Scope:** Move
  `ProxyJwtClaims` (1103-1146),
  `ProxyJwtVerificationError` (1147-1155),
  `ProxyJwtVerifier` (1156-1167),
  `ScaffoldRejectingJwtVerifier` (1168-1203),
  `CompositeProxyJwtVerifier` (1375-1438),
  `_VerifierProbe` (1439-1468),
  `JwtKeyMaterial` (1469-1487),
  `JwtRs256SignatureValidator` (1488-1509),
  `ScaffoldFailingRs256SignatureValidator` (1510-1536),
  `PointyCastleRs256SignatureValidator` (1537-1705),
  `_PemBlock` (1706-1716),
  `JwksKeySource` (1717-1733),
  `FirebaseSecureTokenJwksSource` (1734-1842),
  `FirebaseProxyJwtVerifier` (1843-2074),
  `OperatorContext` (2075-2106),
  `ProxyAuthError` (2107-2118),
  `ProxyRequestGuard` (2119-2288). ~1,200 LoC.
- **Effort:** 2 days.
- **Dependencies:** Step 0.
- **Test impact:** Big — many tests instantiate verifiers directly.
  `test/advisor_proxy_test.dart` references `ProxyJwtVerifier`,
  `OperatorContext`, `ProxyRequestGuard` extensively. Keep the
  monolith re-exporting these classes from `jwt/*` for one transition
  release.
- **Risk:** Medium-high. **Touched by 100% of routes.** The
  rebinding has to be transparent — pure file move + re-export.

### Step 13 — Policy / usage / accounting (`policy/` subtree)

- **Scope:** Move `PolicyTier` through `ProxyRequestLogPolicy`
  (lines 2289-3648 + 8286-8383). ~1,500 LoC.
- **Effort:** 2 days.
- **Dependencies:** Step 0.
- **Test impact:**
  `test/proxy/advisor_proxy_usage_counter_store_test.dart`,
  plus tier/cap branches in `test/advisor_proxy_test.dart`.
- **Risk:** Medium. Postgres-backed accounting store
  (`PostgresProxyAccountingStore`, 3401-3604) writes
  `advisor_proxy_usage_counters` rows — pure file move keeps SQL
  intact.

### Step 14 — LLM provider plumbing (`llm/` subtree)

- **Scope:** Move
  `ProxyLlmModelRouting` (5575-5587),
  `SubscriptionLlmTierRouter` (5588-5618),
  `ProxyPromptBlock` (5619-5658),
  `ProxyLlmRequest` (5659-5676),
  `ProxyLlmCompletion` (5677-5692),
  `ProxyLlmProvider` (5693-5696),
  `ScaffoldRejectingProxyLlmProvider` (5697-5721),
  `ProxyLlmCompletePayload` (5722-5792),
  `AnthropicProxyLlmProvider` (5793-5813),
  `GeminiProxyLlmProvider` (5814-5940),
  `SecondaryLlmBreaker` (5941-6021),
  `AdvisorRequestPipeline` (6022-6163),
  `AdvisorPipelineResult` (6164-6188),
  `AdvisorPromptCacheBuilder` (6189-6233),
  `ProxyCacheFeatureFlags` (6234-6239),
  `ProxyRequestLogPolicy` (6240-6274),
  `ProxyUsageLogSql` (6275-6492). ~2,000 LoC.
- **Effort:** 2-3 days.
- **Dependencies:** Step 0, partial overlap with Step 13.
- **Test impact:**
  `test/proxy/pipeline_with_gemini_secondary_test.dart`,
  `test/proxy/fallback_chain_test.dart`,
  `test/proxy/cache_breakpoint_test.dart`, etc. All these touch
  the pipeline; signatures should not change.
- **Risk:** Medium. AI plumbing is reused by Phase 12; per HP #8
  the abstractions stay general-purpose, so do not narrow the
  interfaces during the move.

### Step 15 — Health surface (`health/` subtree)

- **Scope:** Move
  `ProxyHealthCheckStore` (3649-3668),
  `ProxyRuntimeGauges` (3669-3727),
  `ProxyHealthStatus` (3728-3851),
  `ProxyHealthMetric` (3852-3887),
  `ProxyHealthSurface` (3888-4964),
  `ScaffoldFailingProxyHealthCheckStore` (4965-4983),
  `ProxySchemaContractException` (4984-4998),
  `AdminProxySchemaContractVerifier` (4999-5103),
  `ProxyHealthRegistryContext` (5104-5128),
  `ProxyHealthFeatureFlags` (5129-5137),
  `ProxyHealthRegistryResult` (5138-5158),
  `RegistryProxyHealthCheckStore` (5159-5328),
  `ProxyHealthDependencyProbe` (5329-5505),
  `ProxyMigrationApplyRegistryWriter` (5506-5574). ~1,900 LoC.
- **Effort:** 2 days.
- **Dependencies:** Step 0.
- **Risk:** Medium. Audit-chain anchor metrics
  (`audit_chain_lag_seconds`, `audit_chain_anchor_age_seconds` —
  4032-4204) live in the health surface; these read but do not write
  audit rows.

### Step 16 — Admin operator + location (`routes/admin_operator_location.dart`)

- **Scope:** Extract handler block 14049-14171 + delegate function
  `_routeOperatorLocationAdmin` (14689-15007) + predicate helpers
  (`_isAdminOperatorOrLocationPath`, `_isAdminOperatorOrLocationOperation`).
  ~480 LoC.
- **Effort:** 1.5 days.
- **Dependencies:** Steps 0, 1.
- **Test impact:** Operator/location admin tests in
  `test/advisor_proxy_test.dart`.
- **Risk:** Medium. Suspend / reactivate / archive write
  `auth_events_audit`; sink interface unchanged.

### Step 17 — Admin pricing (`routes/admin_pricing.dart`)

- **Scope:** Handler 13313-13422 + `_routePricingAdmin` (15602-15805)
  + predicate. ~310 LoC.
- **Effort:** 1 day.
- **Dependencies:** Steps 0, 1.
- **Risk:** Low-medium.

### Step 18 — Admin data accuracy (`routes/admin_data_accuracy.dart`)

- **Scope:** Handler 13424-13525 + `_routeDataAccuracyAdmin`
  (15208-15601) + predicate. ~490 LoC.
- **Effort:** 1 day.
- **Dependencies:** Steps 0, 1.
- **Risk:** Low-medium.

### Step 19 — Admin corpus + graph candidates (`routes/admin_corpus.dart`, `routes/admin_graph_candidates.dart`)

- **Scope:** Handler 13526-13680 + 13681-13763 +
  `_routeCorpusAdmin` (15806-15928) + `_routeGraphCandidates`
  (16540-16922) + `_enforceGraphCandidateSourceScope` + predicates.
  ~660 LoC.
- **Effort:** 1.5 days.
- **Dependencies:** Steps 0, 1.
- **Risk:** Low-medium. Watch for the 16 MB body cap carve-out at
  `resolveRequestBodyLimitBytes` (`advisor_proxy.dart:18448`) — that
  selector stays in `_shared/`.

### Step 20 — Admin feature flags + debug + observability

- **Scope:** Handler blocks 13764-14047 + delegates
  `_routeFeatureFlagsAdmin` (16203-16539),
  `_routeDebugConsoleAdmin` (15929-16152),
  `_routeObservabilityAdmin` (16153-16202) + predicates.
  ~770 LoC across 3 files.
- **Effort:** 1.5 days.
- **Dependencies:** Steps 0, 1.
- **Risk:** Low-medium.

### Step 21 — Admin integrations (consolidate already-extracted)

- **Scope:** Handler 13144-13311 + `_routeIntegrationsAdmin`
  (15078-15207). The route file `admin_integrations_routes.dart`
  already exists; move the inline branch and delegate fully into
  it. ~300 LoC moved.
- **Effort:** 1 day.
- **Dependencies:** Steps 0, 1.
- **Risk:** High. Touches `provider_credentials` writes + audit row;
  fresh-MFA gate at `_requireFreshClaimsOrWrite` (lines 13182-13189).
  Pure file move discipline applies.

### Step 22 — Mobile operational sync (`routes/mobile_operational.dart`)

- **Scope:** Handler 9103-9130 + delegates `_routeMobileOperationalSync`
  (16923-17057) + `_routeOperatorDataAccuracySettingsWrite`
  (17058-17260) + `_operatorLocationScopeAllowed` (17261-17328) +
  `_MobileOperationalPath` matcher (17329-17549). ~620 LoC.
- **Effort:** 1.5 days.
- **Dependencies:** Steps 0, 1.
- **Risk:** Medium. PATCH writes data-accuracy settings + audit row.

### Step 23 — Auth team admin (`routes/auth_team_admin.dart`) — **LARGEST**

- **Scope:** The 1,470-line `_isAdminAuthOperation` branch at
  `advisor_proxy.dart:10652-12119` plus the predicate
  (17550-17637), the canonical path map
  (17639-17668), the path-suffix helpers
  (17670-17709, 17802-17823, 18190-18250),
  and the to-JSON converters
  (17825-18139). ~2,400 LoC total.
- **Effort:** 4-5 days.
- **Dependencies:** ALL prior steps. This step is intentionally last
  in the route-extraction sequence because:
  1. The handler block branches on `_canonicalAuthOperationPath` to
     fold `/v1/auth/team/*` onto `/v1/admin/auth/*` — splitting it
     mid-flight risks losing the canonical-path map.
  2. Every mutating branch writes an `auth_events_audit` row.
     Per HP #8 and the post-Codex decision lock #8, the hash chain
     is non-negotiable. Doing this extraction after Steps 6 and 8
     means the lockout + login extraction work has surfaced any
     audit-write bugs first.
  3. `_effectiveAdminAuthScope` (somewhere in the inline block —
     read at 10688-10692) widens the scope to cross-operator for
     `super_admin` / `ff_support` callers; the encapsulation must
     not leak.
- **Test impact:** `test/proxy_auth_operations_route_test.dart`
  (3,081 LoC, the second-largest proxy test file), plus
  `test/proxy_auth_operations_route_grants_test.dart`. Both swap
  imports; assertions unchanged.
- **Risk:** **Highest.** See Risk §7.1.

### Step 24 — Realtime mount cleanup (`routes/realtime.dart`)

- **Scope:** Wrap the existing `handleRealtimeUpgrade` mount + the
  `/v1/realtime/tripwire-status` block (8767-8794) in a single
  `dispatchRealtime` helper. The actual upgrade logic stays in
  `realtime_route.dart`. ~40 LoC of glue.
- **Effort:** half day.
- **Dependencies:** Steps 0, 1.
- **Risk:** Low.

### Step 25 — Cleanup: re-exports + dead-code sweep

- **Scope:** Replace transitional `export 'routes/...';` lines in
  `advisor_proxy.dart` with direct imports from call sites in
  `proxy_bootstrap.dart` and `main.dart`. Run `dart analyze` to
  catch the now-unused imports.
- **Effort:** 1 day.
- **Dependencies:** all prior steps.
- **Risk:** Low.

### Sequencing summary

| Order | Step                                       | LoC moved | Risk        |
| ----: | ------------------------------------------ | --------: | ----------- |
|     0 | `routes/_paths.dart`                       |    ~1,340 | Low         |
|     1 | `routes/_shared/`                          |    ~1,200 | Low-medium  |
|     2 | Health probes                              |      ~530 | Low         |
|     3 | Push tokens                                |      ~170 | Low         |
|     4 | Auth account / permissions snapshot       |       ~70 | Low         |
|     5 | MFA TOTP                                   |      ~270 | Medium      |
|     6 | Auth lockout (types)                       |      ~610 | Low-medium  |
|     7 | Auth passwords + magic link + MFA recovery |      ~540 | Medium      |
|     8 | Auth session login/refresh/revoke          |    ~1,030 | **High**    |
|     9 | Auth audit-log read + export CSV           |      ~410 | Medium      |
|    10 | Service principals                         |      ~620 | Medium      |
|    11 | Auth-location integrations read            |      ~100 | Low         |
|    12 | JWT infrastructure (`jwt/`)                |    ~1,200 | Medium-high |
|    13 | Policy / usage / accounting (`policy/`)    |    ~1,500 | Medium      |
|    14 | LLM provider plumbing (`llm/`)             |    ~2,000 | Medium      |
|    15 | Health surface classes (`health/`)         |    ~1,900 | Medium      |
|    16 | Admin operator + location                  |      ~480 | Medium      |
|    17 | Admin pricing                              |      ~310 | Low-medium  |
|    18 | Admin data accuracy                        |      ~490 | Low-medium  |
|    19 | Admin corpus + graph candidates            |      ~660 | Low-medium  |
|    20 | Admin feature flags + debug + observability|      ~770 | Low-medium  |
|    21 | Admin integrations consolidation           |      ~300 | **High**    |
|    22 | Mobile operational sync                    |      ~620 | Medium      |
|    23 | **Auth team admin** (`routes/auth_team_admin.dart`) | ~2,400 | **Highest** |
|    24 | Realtime mount cleanup                     |       ~40 | Low         |
|    25 | Cleanup / re-exports                       |         — | Low         |

Total LoC moved out of `advisor_proxy.dart`: ~19,460 (it sums above
the current 18,623 because the helper classes and value types in
Steps 12-15 are referenced across multiple routes, so they appear
once in the line count but are conceptually shared).

Post-split estimate for `advisor_proxy.dart`: **1,200-1,500 lines**.

---

## Section 5 — Shared seams

Below: helpers / services / types reused across two or more bounded
contexts. These cannot live in any single route file. Naming +
ownership is fixed at extraction time so subsequent steps know where
to import from.

### 5.1 JWT verification + scope guard (`jwt/`)

- **Owner:** `tool/advisor_proxy/jwt/` (Step 12).
- **Re-exports from `advisor_proxy.dart`:** Keep
  `ProxyJwtClaims`, `ProxyJwtVerifier`, `OperatorContext`,
  `ProxyRequestGuard`, `ProxyAuthError` re-exported from the
  monolith for at least one release so downstream `lib/` consumers do
  not need a same-PR import sweep.

### 5.2 Auth hashing primitives (`routes/_shared/auth_hashing.dart`)

- **Owner:** Step 1.
- Carries `hashAuthEmailHex` and `hashAuthIpHex`. Used by `auth_session`,
  `auth_passwords`, `auth_mfa_recovery`, and the auth lockout sink.

### 5.3 Response writers + envelope helpers (`routes/_shared/response.dart`)

- **Owner:** Step 1.
- Carries `_writeJson`, `_writeDependencyTimeoutEnvelope`,
  `_maybeWriteDependencyTimeout`, `_logProxyUnhandled`. Used everywhere.

### 5.4 JSON body parser (`routes/_shared/json_body.dart`)

- **Owner:** Step 1.
- `_readJsonBody` + `_MalformedJsonBodyError`. Used everywhere.

### 5.5 Admin CORS dispatch (`routes/_shared/cors.dart`)

- **Owner:** Step 1.
- `respondAdminCorsPreflight`, `_applyAdminCorsHeaders`,
  `_matchAdminCorsOrigin`, the `kAdmin*CorsMethods` lists. Used by
  every admin route family.

### 5.6 Idempotency helpers (`routes/_shared/idempotency.dart`)

- **Owner:** Step 1.
- `_runAdminIdempotent`, `AdminRequestIdempotencyStore` import shim,
  `AdminIdempotencyKeyConflict`, Idempotency-Key header parsing.
  Used by every admin write.

### 5.7 Permission guards (`routes/_shared/permission_guard.dart`)

- **Owner:** Step 1.
- `_requireAdminPermissionOrWrite`, `_requireFreshClaimsOrWrite`,
  `_callerHasAnyRole`, `_operatorContextHasAnyRole`,
  `_isFfOperatorLocationAdminCaller`, plus the `kFf*Roles` constants.
  Used by every admin route family + several operator routes.

### 5.8 Fresh-auth proof helpers (`routes/_shared/fresh_auth.dart`)

- **Owner:** Step 5.
- `_requireFreshAuthenticationOrWrite`, `_freshAuthProofId`. Used by
  MFA revoke, admin integrations rotate, admin auth team mutate.

### 5.9 Scope resolution (`routes/_shared/scope_guard.dart`)

- **Owner:** Step 1.
- `_resolveOperatorContextOrWrite`,
  `_resolveLocationReadContextOrWrite`, `_resolveVerifiedClaimsOrWrite`,
  `requireScopeChecked`. Used by every authed route.

### 5.10 Ledger context (`routes/_shared/ledger_context.dart`)

- **Owner:** Step 8.
- `_resolveLedgerContextFromHeaders`. Used by `auth_session_login`,
  the audit row sinks (via header pass-through), and any future
  route that needs trusted IP / country.

### 5.11 Auth event JSON converters (`routes/auth_team_admin.dart` private)

- **Owner:** Step 23. Internal to `auth_team_admin.dart`. Includes
  `_teamRoleToJson`, `_teamUserToJson`, `_teamGrantSnapshotToJson`,
  `_teamOrgUnitToJson`, `_teamOrgLocationToJson`,
  `_authSessionSummaryToJson`, `_teamInviteToJson`.

### 5.12 Admin error type (`routes/_shared/admin_input_error.dart`)

- **Owner:** Step 1.
- `_AdminInputError` (currently at `advisor_proxy.dart:16734-16744`).
  Used by every `_routeXxxAdmin` delegate.

---

## Section 6 — Test reorganization

> **Update (post-PR-#1120 / #1122, 2026-05-20):** The two mega-files
> below have already been split by the test-suite tightening audit's
> Bucket 5. `test/advisor_proxy_test.dart` (was 7,693 / pre-A3 8,328 LoC)
> is now five focused files —
> `test/advisor_proxy_{config,token_and_guard,usage_and_migrations,jwt_verifier,http_and_admin_routes}_test.dart`
> plus `test/advisor_proxy_test_helpers.dart` (PR #1120).
> `test/proxy_auth_operations_route_test.dart` is now four focused files —
> `test/proxy_auth_{account_and_permission,password_and_session,mfa,invite_and_admin}_test.dart`
> plus `test/proxy_auth_test_helpers.dart` (PR #1122). All
> per-step "Test impact" notes below predate the split; readers
> implementing a Step should re-grep the post-split files for the
> specific test groups named.

Current proxy tests are flat:

- `test/advisor_proxy_test.dart` — **7,693 LoC.** The big one.
  Mirror of the monolith; one Dart file covers every route family.
- `test/advisor_proxy_bootstrap_test.dart` — 635 LoC. Bootstrap-only.
- `test/proxy_auth_operations_route_test.dart` — 3,081 LoC. The
  auth-team admin block (Step 23 home).
- `test/proxy_auth_operations_route_grants_test.dart` — also auth team.
- `test/proxy_integration_admin_routes_test.dart` — 966 LoC.
- `test/proxy/` — 51 files, already grouped by topic.
- `test/services/proxy_*` — corpus / feature flags / graph candidates.
- `test/tool/advisor_proxy/` — 16 files (admin_integrations idempotency,
  KMS revision, Phase 8 binder, etc.).

### Proposed structure

```
test/proxy/
  routes/
    _paths_test.dart                            # smoke: every const path is non-empty + starts with /v1/
    _shared/
      cors_test.dart                            # already partly in admin_cors_*_test.dart — consolidate
      idempotency_test.dart                     # already at tool/advisor_proxy/admin_idempotency_reclaim_test.dart — move here
      json_body_test.dart
      permission_guard_test.dart
      scope_guard_test.dart
      fresh_auth_test.dart

    health_test.dart                            # from advisor_proxy_health_envelope_test.dart + smoke probe tests
    auth_session_test.dart                      # from proxy_auth_operations_route_test.dart (subset)
    auth_account_test.dart                      # from advisor_proxy_test.dart account block
    auth_audit_log_test.dart                    # from advisor_proxy_test.dart audit-log block + admin_audit_extensions_test.dart
    auth_passwords_test.dart                    # from advisor_proxy_test.dart password block
    auth_mfa_test.dart                          # from advisor_proxy_test.dart MFA block
    auth_mfa_recovery_test.dart
    auth_lockout_test.dart                      # from auth_lockout_routes_test.dart
    auth_team_admin_test.dart                   # from proxy_auth_operations_route_test.dart (main)
    auth_team_admin_grants_test.dart            # from proxy_auth_operations_route_grants_test.dart
    auth_location_integrations_test.dart        # from auth_location_integrations_route_test.dart (already in place)
    service_principals_test.dart                # extract from advisor_proxy_test.dart
    push_tokens_test.dart                       # from mobile_push_routes_test.dart
    realtime_test.dart                          # from pubsub_realtime_startup_test.dart
    mobile_operational_test.dart                # from mobile_operational_sync_routes_test.dart

    admin_operator_location_test.dart           # extract from advisor_proxy_test.dart
    admin_integrations_test.dart                # from proxy_integration_admin_routes_test.dart + tool/advisor_proxy/admin_integrations_*
    admin_pricing_test.dart                     # extract from advisor_proxy_test.dart
    admin_data_accuracy_test.dart               # from data_accuracy_admin_routes_test.dart
    admin_corpus_test.dart                      # from services/proxy_corpus_admin_routes_test.dart
    admin_graph_candidates_test.dart            # from services/proxy_graph_candidates_routes_test.dart
    admin_feature_flags_test.dart               # from services/proxy_feature_flags_routes_test.dart + feature_flags_*_test.dart
    admin_debug_test.dart                       # from admin_debug_console_routes_test.dart
    admin_observability_test.dart               # extract from advisor_proxy_test.dart

  jwt/
    proxy_request_guard_test.dart
    firebase_jwt_verifier_test.dart
    service_principal_jwt_test.dart
    rs256_validator_test.dart

  policy/
    usage_guard_test.dart                       # from advisor_proxy_usage_counter_store_test.dart
    accounting_store_test.dart
    proxy_request_log_policy_test.dart

  llm/
    fallback_chain_test.dart                    # already at proxy/fallback_chain_test.dart — move
    secondary_breaker_test.dart                 # already at tool/advisor_proxy/secondary_llm_breaker_test.dart — move
    cache_breakpoint_test.dart                  # already at proxy/cache_breakpoint_test.dart — move
    pipeline_test.dart                          # from pipeline_with_gemini_secondary_test.dart

  health/
    health_check_store_test.dart                # already at proxy/registry_proxy_health_check_store_test.dart — move
    health_dependency_probe_test.dart
    runtime_gauges_test.dart                    # already at proxy/health_producers/*

  bootstrap_test.dart                           # from advisor_proxy_bootstrap_test.dart
```

The reorganization is bottom-up: each routes/route file extraction
moves its tests into `test/proxy/routes/<context>_test.dart` in the
same PR. The big `test/advisor_proxy_test.dart` shrinks
proportionally; once all 23 route steps are done it can be deleted.

`test/tool/advisor_proxy/` survives — these tests target the
direct-dependency files (`phase_8_production_binder.dart`,
`advisor_response_cache.dart`, etc.) that are NOT inside the
monolith.

---

## Section 7 — Risk register

### 7.1 Audit hash chain integrity (HIGHEST)

- **Risk:** Steps 8 (auth session login), 9 (audit-log export), 16
  (operator/location admin), 21 (integrations admin), 22 (mobile
  operational sync data-accuracy PATCH), and especially **Step 23
  (auth team admin)** all write `auth_events_audit` rows. The
  per-operator hash chain in `auth_events_audit` is non-negotiable
  per HP #8 and the decision lock #8 ("read-side join only … hash
  chain anchoring and `pg_partman` per-operator/day partitioning
  stay untouched").
- **Failure mode:** A miscompiled extraction could change the order
  of `AuthLockoutAuditSink.record*` calls relative to the gateway
  response — fine for the response, broken for the chain if a row
  insert is skipped or duplicated. Worse: dropping the
  `prev_hash` chain by missing a side-effect in the `try/catch/finally`
  rewriting.
- **Mitigation:**
  1. Every audit-touching extraction is a **pure file move**, not a
     refactor. No rename of `record*` methods, no signature changes
     on `AuthLockoutAuditSink`, no inlining/extraction of inner
     try/catch arms.
  2. The four wrapper functions (`STABLE LEAKPROOF PARALLEL SAFE` per
     CLAUDE.md) live in Postgres, not Dart. The Dart proxy does NOT
     call `current_setting()` directly; the audit-row insert goes
     through `tenant_transaction.dart` (see `proxy_bootstrap.dart:60-61`)
     which is unchanged by this audit. Confirm during extraction
     that no audit-row code path bypasses the wrapper.
  3. Before merging Step 23, the existing
     `test/proxy_auth_operations_route_test.dart` (3,081 LoC) must
     pass without modification beyond imports. If any assertion shifts,
     the extraction has changed behavior.
  4. Add a regression test that proves chain continuity across the
     extracted route: insert two rows back-to-back and verify
     `chain_prev_hash` of row N+1 equals `row_hash` of row N (this
     test does not exist today; recommended as part of Step 8/Step 23
     PR scaffolding).

### 7.2 Per-operator RLS context propagation (HIGH)

- **Risk:** Per CLAUDE.md "Proxy & API Conventions": "Proxy uses
  `SET LOCAL` (transaction-scoped). RLS policies use four `STABLE
  LEAKPROOF PARALLEL SAFE` wrapper functions; bare `current_setting()`
  reads forbidden." Any extraction that broke the
  `TenantTransactionWrapper` callsite could leak operator context
  across requests on the same connection.
- **Failure mode:** A route extracted into a new file imports
  `tenant_transaction.dart` but accidentally bypasses the wrapper
  (e.g. by holding the connection lease in a captured closure that
  outlives the transaction).
- **Mitigation:**
  1. Audit every extracted handler: the `SET LOCAL app.operator_id`
     callsite must remain inside the same `tx` future the gateway
     uses. The proxy itself does not call `SET LOCAL`; it delegates
     to the gateway. So the rule simplifies to: **do not introduce
     new tenant_transaction usage during extraction; keep the
     existing gateway-mediated pattern.**
  2. Steps 13 (policy/accounting) and 15 (health) touch Postgres
     directly. They must continue to use the existing
     `TenantTransactionWrapper` paths.

### 7.3 Idempotency reuse across modules (MEDIUM)

- **Risk:** Every admin write currently reads `Idempotency-Key`
  inline and delegates to `_runAdminIdempotent` against the shared
  `AdminRequestIdempotencyStore`. If the extracted modules import a
  divergent helper or duplicate the key-parsing code, two retries
  carrying the same key could insert two `admin_request_idempotency`
  rows, breaking the reserve→complete contract.
- **Failure mode:** Operator double-clicks "Save"; second call lands
  in a route extracted into a new file that doesn't see the same
  cache instance.
- **Mitigation:**
  1. `_runAdminIdempotent` and the `AdminRequestIdempotencyStore`
     interface stay in `routes/_shared/idempotency.dart`. Every
     extracted module imports from there.
  2. The `ProxyAuthIdempotencyCache` (`proxy_idempotency_cache.dart`)
     is the in-memory side; do not duplicate.
  3. Add a regression test that submits the same Idempotency-Key
     across two different bounded contexts and verifies one cache
     entry per (route_family, key) — the existing
     `test/tool/advisor_proxy/admin_idempotency_reclaim_test.dart`
     covers single-family; cross-family is recommended new coverage.

### 7.4 JWT context propagation across modules (MEDIUM)

- **Risk:** `ProxyRequestGuard.requireOperatorContext` returns an
  `OperatorContext` value type. Every route uses the same instance
  produced by the per-request `_resolveOperatorContextOrWrite` helper.
  Once the helper moves to `routes/_shared/scope_guard.dart`, a
  divergent local implementation in an extracted module would skip
  the permission-version check or the freshness-window check.
- **Failure mode:** A module copies `requireOperatorContext` to
  avoid the import; the copy drops the `permissionVersionChecker`
  invocation (the `requireScopeChecked` wrapper at
  `advisor_proxy.dart:8536-8564` is what does the DB lookup).
- **Mitigation:**
  1. `requireScopeChecked` is the canonical wrapper — move it to
     `routes/_shared/scope_guard.dart` in Step 1 and do not allow
     parallel definitions.
  2. Steps 5-9 (auth routes) must all consume `requireScopeChecked`
     once a `PermissionVersionChecker` is wired — see B1.A3 in the
     monolith comments at 8524-8534.

### 7.5 Streaming response state mid-extraction (MEDIUM)

- **Risk:** The audit-log CSV export (Step 9) and any future
  streamed response are stateful: once `response.statusCode` /
  `response.headers.contentType` / `chunkedTransferEncoding` are
  set, the response cannot be replaced with a JSON envelope. If the
  extraction inadvertently introduces a buffering or retry layer,
  the chunked stream will break mid-emit.
- **Failure mode:** Operator hits Export, gets a partial CSV (or no
  CSV) when the route's new file mishandles `response.flush()`.
- **Mitigation:**
  1. Keep the streaming code at its current position in
     `routes/auth_audit_log.dart`. Do not extract sub-helpers from
     inside the loop. Move it as one block.
  2. Add an end-to-end test that asserts the CSV body downloads
     with the correct content-type, chunked transfer encoding, and
     `Content-Disposition` filename pattern.

### 7.6 Realtime WebSocket subscription leakage (MEDIUM)

- **Risk:** A1 §2.1 S4 documents a latent
  WebSocket-subscription-accumulation risk in `realtime_route.dart`.
  This audit's extraction does NOT touch `realtime_route.dart`; the
  Step 24 wrap is a thin dispatch helper only. Do not refactor the
  realtime route as part of decomposition.
- **Mitigation:** Step 24 keeps `handleRealtimeUpgrade(...)` as the
  delegating call. No subscription-lifecycle changes.

### 7.7 `runZonedGuarded` placement (LOW but watch)

- **Risk:** A1 §2.1 S1 documents that `main.dart:83-100` wraps the
  serve loop in `runZonedGuarded`. The extraction must not move the
  wrap or the completer.
- **Mitigation:** Decomposition stays inside the monolith file +
  `routes/`. `main.dart` is out of scope. Confirm during PR review.

### 7.8 Bootstrap dependency list parameter (LOW-MEDIUM, but follow-up)

- **Risk:** `routeRequest` takes ~70 optional named parameters
  (`advisor_proxy.dart:8385-8520`). The dispatch ladder in the
  refactored `advisor_proxy.dart` will need each dispatch helper to
  receive only its sub-set. Naive extraction would still pass all 70
  through every helper.
- **Mitigation:** Each `dispatchXxx(...)` helper takes ONLY its
  required parameters. The signature reduction is value-added during
  extraction. Follow-up task for the bootstrap audit (separate from
  A3): consider a single `RouteRequestDeps` carrier class so the
  signature doesn't keep growing.

### 7.9 Path-constant duplication during transitional period (LOW)

- **Risk:** Step 0 moves all path constants to `routes/_paths.dart`
  but re-exports for back-compat. Any new path constant added during
  the migration window must go to `_paths.dart` directly, not back
  into the monolith.
- **Mitigation:** Add a CI lint or doc note: "during proxy
  decomposition (2026-05-12 → 2026-Q3 ish), every new `const String *Path`
  goes to `tool/advisor_proxy/routes/_paths.dart`."

### 7.10 The 16 bare `catch (_)` debt overlap (LOW)

- **Risk:** `proxy_split_plan.md` already names 16 bare catches in
  `advisor_proxy.dart` (lines 1319, 1352, 1429, 1661, 1698, 1789,
  1944, 1974, 1980, 1997, 2306, 2540, 2618, 5143, 5221, 5274 — as of
  2026-05-08). Line numbers will have drifted by 2026-05-12. The
  decomposition lanes can clear them naturally per-step, but if a
  lane both extracts AND fixes catches the diff becomes hard to
  review.
- **Mitigation:** Per `proxy_split_plan.md` Sequencing Option 1
  ("As part of the first split slice"), fix bare catches within the
  extraction PR for that route family, not in a separate sweep. PRs
  must show the catch fix as a separate commit inside the same PR
  so audit-trail is clean.

---

## Section 8 — What was NOT audited

- **Runtime performance:** This audit does NOT measure latency, RSS,
  pool waits, or pubsub ring-buffer pressure. That's A4. A1 §2 (the
  proxy crash investigation) already covered the production-observed
  pool exhaustion and ring-buffer growth concerns.
- **Scaffold / placeholder inventory:** This audit does NOT catalog
  which gateways are scaffolds (`ScaffoldRejecting*`) vs production
  bindings, nor the demo-mode carve-outs. That's A2.
- **Postgres schema / RLS policy text:** This audit does NOT inspect
  the four `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions, the
  `audit_logs` partition shape, or `pg_partman` settings. It DOES
  assert that the proxy continues to mediate audit-row writes through
  the existing `tenant_transaction.dart` wrapper. Schema-side audit
  is A5 territory per the decision lock.
- **`proxy_bootstrap.dart` (the 8,691-line wiring file):** Equally a
  monolith, but it's a different problem shape (it wires repositories
  + gateways, not routes). Its decomposition is a separate audit
  (suggest A6: bootstrap decomposition). Sequencing-wise, decomposing
  the route layer first means the bootstrap audit then has clearer
  seams to wire against.
- **`main.dart` (2,183 lines):** Out of scope; minor compared to
  the monolith and the bootstrap. A1 §2 already covered the
  `runZonedGuarded` + listener-loop seams.
- **Inbound contract changes:** No path-shape, payload-shape, or
  error-envelope changes are proposed. Pure structural refactor.
- **Lib-side proxy clients (`lib/services/.../*_proxy_*_gateway.dart`):**
  Out of scope. Decomposition is server-side only.

---

## Citations summary

- `tool/advisor_proxy/advisor_proxy.dart:6934-8273` — path constants.
- `tool/advisor_proxy/advisor_proxy.dart:8385-14661` — single
  `routeRequest` function.
- `tool/advisor_proxy/advisor_proxy.dart:10652-12119` — auth-team
  admin block (largest single inline section, ~1,470 LoC).
- `tool/advisor_proxy/advisor_proxy.dart:12655-12948` — auth session
  login (A1 bug 1 surface; ~290 LoC).
- `tool/advisor_proxy/advisor_proxy.dart:14689-17260` — admin
  delegate helpers (`_routeXxxAdmin` family + mobile sync delegates).
- `tool/advisor_proxy/advisor_proxy.dart:17550-18650` — predicate
  helpers + JSON converters + CORS + low-level utilities.
- `tool/advisor_proxy/proxy_bootstrap.dart` — production wiring; in
  scope for the future A6 audit, not this one.
- `docs/phases/proxy_split/proxy_split_plan.md` — pre-existing stub
  this audit formalizes. The 16-bare-catches list is incorporated as
  Risk §7.10.
- `docs/_audits/code_health/a1_proxy_bug_root_cause.md` — shape
  precedent (line-number citation density, evidence-grade ranking).

---

## Bare-catch sweep progress (A3.2 / A3.3 / A3.4)

The 45 bare `catch (_)` sites in `advisor_proxy.dart` are being typed
across three sibling slices. Each slice picks a coherent cluster
range from the seam map at
`docs/_audits/code_health/a3_advisor_proxy_seam_map.md`.

| Slice | Cluster range | Lines | Sites converted | Status |
|---|---|---|---|---|
| **A3.2** | Clusters 2-3 + early cluster 4 | 1341-2735 | 12 (1 explicitly retained at line 2426 — `Platform.environment` swallow) | merged (PR #563) |
| **A3.3** | Clusters 4-8 (mid + late `routeRequest`) | 3744-5470 | 5 (1 already-documented retention at line 2426 carries forward; 1 out-of-scope site at line 7024 inside `SessionRecordIncompleteGauge`) | merged (PR #572) |
| **A3.4** | Clusters 9-12 (`routeRequest` mega-function inline handlers + admin route delegates + path matchers + CORS tail) | 8939-16286 (master pre-edit) | **26** (line 2426 retention preserved; line 7107 = `SessionRecordIncompleteGauge.observe()` carried forward A3.3 out-of-scope) | open |

A3.2 conversion idiom: every typed catch carries a 1-3 line comment
naming the exception class the protected block actually throws and
the verifier-typed error it converts to. `on Exception catch (_)`
used when the protected block has multiple disjoint concrete
throws (e.g. cryptography backends) — `on Object` was never used so
genuine `Error`s (assertion failures, OOM, type errors) keep
propagating. A3.2 line count: 18,871 → 18,899 (+28; bleed-stop
ceiling 19,071, headroom 172).

### A3.3 chunk-2 site registry

Chunk 2 (A3.3) converted **5 of the estimated 16 sites**. The actual
count came in materially lower because clusters 4-8 turned out to be
sparse on `catch (_)` patterns — most of the dense bare-catch surface
sits in clusters 9-12 (admin delegates + predicates + the
`routeRequest` mega-function's inline handler bodies), which A3.4
will sweep. Two sites in clusters 4-8 were intentionally NOT touched:

- **Line 2426** — already documented by A3.2 as the
  `Platform.environment` retention (`UnsupportedError` is an `Error`
  subclass, not `Exception`; narrowing would re-throw the very
  failure mode this fallback exists to absorb).
- **Line 7024** — inside `SessionRecordIncompleteGauge.observe()`
  (class lines 6997-7075). Block 2 of the slice brief explicitly
  scopes this class's internals OUT — A11.1 owns the gauge surface
  and the A11.1.b consumer-wiring work is in flight in another
  worktree.

| Site (file:line) | Original throw source | Narrowed type | Rationale |
|---|---|---|---|
| `tool/advisor_proxy/advisor_proxy.dart:3744` | `pgCollector()` closure (arbitrary Postgres pool internals invoked from the runtime gauge snapshot) | `on Exception catch (_)` | Pool collectors can surface `PgException` from the postgres driver, `StateError`-like wraps from a closed pool, or custom subscriber failures. Multiple disjoint concrete throws → collapse to `Exception`. Genuine `Error`s keep propagating so a real bug in the gauge class doesn't get masked behind the `error: pool_gauge_collector_failed` placeholder. |
| `tool/advisor_proxy/advisor_proxy.dart:3762` | `ringCollector()` closure (arbitrary pubsub subscriber internals invoked from the runtime gauge snapshot) | `on Exception catch (_)` | Same shape as 3744. Subscriber closures can raise any `Exception` subtype (closed-subscriber `StateError`-like wraps, ring-buffer overflow signals, etc.); collapse to `Exception` and surface the `ring_buffer_gauge_collector_failed` placeholder. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:5339` | `awaitHealthOperationWithBudget(producer(context), …)` inside `_runOne` of the producer registry runner | `on Exception catch (_)` | Producers are arbitrary `ProxyHealthRegistryProducer` closures; the budget helper raises `TimeoutException` and any producer-side `Exception` subtype propagates (`PgException`, `IOException`, parse `FormatException`, etc.). Collapse them all into the `unknown` placeholder metric. `Error`s propagate so a real defect in a producer doesn't get masked behind `registry_outer_failure`. |
| `tool/advisor_proxy/advisor_proxy.dart:5417` | `awaitHealthOperationWithBudget(runnerFn(sql), …)` inside `defaultProxyHealthDependencyProbe`'s inner `probe` | `on Exception catch (_)` | Same shape as 5339. Dependency liveness must project to `false` for `TimeoutException`, `PgException`, network `IOException`, etc. — every flake mode. `Error`s propagate so a real defect (assertion failure, type error) doesn't get masked behind a green deep-health envelope. |
| `tool/advisor_proxy/advisor_proxy.dart:5470` | `awaitHealthOperationWithBudget(runnerFn(sql), …)` inside `strictProxyHealthDependencyProbe`'s inner `probe` | `on Exception catch (_)` | Same shape as 5417 — the HARD-A probe mirrors the default probe's exception surface (the only difference is that the SQL round-trips through cypher / pgvector). Same narrowing applies for the same reason. |

A3.3 line count: 18,904 → 18,934 (+30; bleed-stop ceiling 19,071,
headroom 137). Test backfill skipped per A3.2 Option A operator
approval (pure refactor; behavior preservation verified by the
existing 25 tests in `test/proxy/advisor_proxy_health_envelope_test.dart`
which exercise the registry runner + both dependency probes, plus
the 223 tests in `test/advisor_proxy_test.dart` which exercise the
full proxy surface).

### A3.4 chunk-3 site registry

Chunk 3 (A3.4) converted **26 sites** in clusters 9-12 (master
pre-edit lines 8939-16286). The independent grep on master at
`1afb7924` produces exactly 26 `} catch (_)` matches in that line
range — all typed in this PR. A3.3's worker estimate of ~22 came in
slightly low because cluster 9 (the `routeRequest` mega-function's
inline handler bodies, lines 8512-14910) is even denser than the
seam map suggested: 25 of the 26 sites live there. One site sits in
cluster 10 (admin corpus route delegate). Clusters 11 + 12
(predicates + path matchers + CORS / response tail) contain **zero**
bare-catches — they were stripped during A1 / A2 / A11.1 work.

Two pre-existing retentions carry forward from A3.2 / A3.3 and are
**NOT** touched by this PR:

- **Line 2426** (cluster 2-3) — `Platform.environment` swallow.
  `UnsupportedError` is an `Error` subclass not `Exception`;
  narrowing would re-throw the very failure mode this fallback
  exists to absorb (web embedders that block direct
  `Platform.environment` reads).
- **Line 7107** (cluster 4-8) — inside
  `SessionRecordIncompleteGauge.observe()`. A11.1 owns the
  `SessionRecordIncompleteGauge` class surface; A3 stays scoped to
  the proxy plumbing and leaves gauge internals to the A11 lane.

Site 16286 (`Base64Decoder().convert`) is the only "tight" narrowing
in this chunk — `on FormatException` — because the standard-library
decoder genuinely throws only one Exception subtype. The other 25
sites all wrap gateway / store / probe / resolver callouts whose
inner throw surface is genuinely diverse (`PgException`,
`TimeoutException`, `IOException`, `FormatException`, plus typed
rejections that are already caught in upstream `on …` branches
above the catch-all), so `on Exception catch (_)` is the right
narrowing per the A3.2 / A3.3 idiom — `on Object` was deliberately
never used so `Error`s (StateError, type errors, OOM, assertion
failures) keep propagating to `runZonedGuarded` per addendum C4.

| Site (file:line, master pre-edit) | Original throw source | Narrowed type | Rationale |
|---|---|---|---|
| `tool/advisor_proxy/advisor_proxy.dart:8939` | `healthCheckStore.check()` — wraps the full registry-driven health producer + dependency-probe fan-out | `on Exception catch (_)` | Producer / probe throw surface is genuinely diverse (`PgException` from postgres, `TimeoutException` from the budget helper, `IOException` on a transport-level outage, `FormatException` on a parse, etc.); collapse to the `unhealthy` 503 envelope. `Error`s propagate per C4. |
| `tool/advisor_proxy/advisor_proxy.dart:9550` | `accountingStore.startRequest(...)` — proxy accounting `usage_log_entries` insert + concurrency check | `on Exception catch (_)` | Surface: `PgException` (write contention, RLS denial), `TimeoutException` (budget helper), `IOException` (network), `StateError`-like closed-pool wraps. Collapse to `accounting_store_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:9634` | `llmProvider.complete(llmRequest)` — LLM provider HTTP call (smoke pipeline) | `on Exception catch (_)` | Surface: `TimeoutException`, `IOException`, `HttpException` (HTTP transport / parse), `FormatException` (response parse), provider-specific Exception subtypes (rate-limit, quota, auth). Collapse to `llm_provider_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:9738` | `accountingStore.commitUsageLog(...)` — completion-side counter write | `on Exception catch (_)` | Same accounting-store surface as the startRequest catch above. Collapse to `accounting_store_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:9765` | `accountingStore.completeRequest(...)` — idempotency-key complete row | `on Exception catch (_)` | Same accounting-store surface. Collapse to `accounting_store_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:9827` | `accountInfoGateway.load(...)` — read-only account info projection | `on Exception catch (_)` | Typed `AccountInfoUnavailable` caught above (→ 404). Catch-all here covers gateway transport/storage Exceptions (`PgException`, `TimeoutException`, `IOException`). Collapse to `account_info_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:9856` | `permissionSnapshotResolver.load(scope)` — permission snapshot read (success path renders `snapshot.toJson()`) | `on Exception catch (_)` | Postgres-backed surface: `PgException`, `TimeoutException`, `IOException`, closed-pool wraps. Collapse to `permission_snapshot_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:10350` | `passwordResetRequestGateway.requestReset(...)` inside a `CachedProxyResponse.run` closure | `on Exception catch (_)` | Typed `PasswordResetRequestThrottled` caught above (→ 429). Catch-all here covers gateway transport/storage + SendGrid HTTP (`PgException`, `TimeoutException`, `IOException`, `HttpException`). Cache the 503 envelope so idempotent retries replay the same response. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:10451` | `passwordResetConfirmGateway.confirm(...)` inside a `CachedProxyResponse.run` closure | `on Exception catch (_)` | Typed `PasswordResetConfirmRejected` (caught above via `error.code/rejections`) and `DependencyTimeoutException` (HARD-G envelope above) already handled. Catch-all here covers remaining transport/storage + crypto-internal Exceptions (`PgException`, `IOException`, `FormatException`). Cache 503 for idempotent replay. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:10621` | `mfaRecoveryRequestGateway.submit(...)` | `on Exception catch (_)` | Typed `MfaRecoveryRequestRejected` caught above. Catch-all covers gateway transport/storage + email pipeline failures (`PgException`, `TimeoutException`, `IOException`, SendGrid `HttpException`). Collapse to `mfa_recovery_request_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:10980` | `servicePrincipalJwtIssuanceGateway.issue(...)` | `on Exception catch (_)` | Typed `ServicePrincipalJwtIssueRejected` caught above. Catch-all covers transport/signer Exceptions (`PgException`, `TimeoutException`, `IOException`, `FormatException`, crypto-backend). Collapse to `service_principal_issuance_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12501` | `firebaseAdminAuthClient.revokeRefreshTokens(...)` — Firebase Admin REST call | `on Exception catch (_)` | Typed `FirebaseAdminAuthError` caught above. Catch-all covers REST client transport/parse Exceptions (`IOException`, `TimeoutException`, `FormatException`, `HttpException`). Collapse to `refresh_token_revoke_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12555` | `authOperationsGateway.listActiveSessions(...)` | `on Exception catch (_)` | Typed `AuthOperationRejected` caught above. Catch-all covers gateway Postgres surface (`PgException`, `TimeoutException`, `IOException`, closed-pool wraps). Collapse to `auth_sessions_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12604` | `permissionSnapshotResolver.load(scope)` — force-logout permission gate (success path reads `snapshot.permissions[PermissionKeys.teamSessionForceLogout]`) | `on Exception catch (_)` | Same permission-snapshot Postgres surface. Collapse to `permission_snapshot_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12647` | `authOperationsGateway.listTeamActiveSessions(...)` | `on Exception catch (_)` | Typed `AuthOperationRejected` caught above. Catch-all covers gateway Postgres surface. Collapse to `team_sessions_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12697` | `permissionSnapshotResolver.load(scope)` — integrations-read permission gate (success path reads `snapshot.permissions.entries.any(...)`) | `on Exception catch (_)` | Same permission-snapshot Postgres surface. Collapse to `permission_snapshot_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12736` | `operatorLocationIntegrationsProjection(...)` — integrations + provider-credentials read | `on Exception catch (_)` | Postgres surface (`PgException`, `TimeoutException`, `IOException`, closed-pool wraps). Collapse to `integrations_projection_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12802` | `permissionSnapshotResolver.load(scope)` — CSV export permission gate (`ProxyPermissionSnapshot exportSnapshot`) | `on Exception catch (_)` | Same permission-snapshot Postgres surface. Collapse to `permission_snapshot_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:12912` | Streaming CSV export loop — `authOperationsGateway.listAuthEventsForActor`, `response.write`, `response.flush` inside the paged-export `while (true)` body | `on Exception catch (_)` | Mid-stream failure. Surface: gateway (`PgException`, `TimeoutException`, `IOException`) + `response.flush` (`HttpException`, `SocketException` on client disconnect) + row-render (`FormatException` on malformed event payload). Best-effort `response.close()` so the operator's browser stops waiting — CSV truncates but headers + column row already shipped. `Error`s propagate (a real defect must not silently truncate the export). |
| `tool/advisor_proxy/advisor_proxy.dart:12992` | `authOperationsGateway.listAuthEventsForActor(...)` — audit log read (paged JSON) | `on Exception catch (_)` | Typed `AuthOperationRejected` caught above. Catch-all covers gateway Postgres surface. Collapse to `auth_audit_log_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:13360` | `authSessionLedgerWriter.recordRefresh(...)` — refresh-token write | `on Exception catch (_)` | Postgres write surface (`PgException`, `TimeoutException`, `IOException`, closed-pool wraps). Collapse to `auth_session_ledger_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:13430` | `authSessionLedgerWriter.revokeSession(...)` — single-session revoke write (may also call Firebase admin) | `on Exception catch (_)` | Postgres write + optional Firebase admin call (`PgException`, `TimeoutException`, `IOException`, `FirebaseAdminAuthError`). Collapse to `auth_session_ledger_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:13488` | `authSessionLedgerWriter.revokeAllSessionsForUser(...)` — bulk-revoke transaction | `on Exception catch (_)` | Multi-row Postgres transaction (`PgException` on contention/RLS, `TimeoutException`, `IOException`, closed-pool wraps). Collapse to `auth_session_ledger_unavailable` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:13588` | `integrationAdminActorResolver.resolveActorUserId(...)` — integrations admin actor lookup | `on Exception catch (_)` | Postgres lookup surface (`PgException`, `TimeoutException`, `IOException`, closed-pool wraps). Collapse to `integration_admin_actor_resolve_failed` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:14212` | `integrationAdminActorResolver.resolveActorUserId(...)` — feature-flags admin actor lookup variant | `on Exception catch (_)` | Same resolver Postgres surface as 13588. Collapse to `feature_flags_actor_resolve_failed` 503. `Error`s propagate. |
| `tool/advisor_proxy/advisor_proxy.dart:16221` | `const Base64Decoder().convert(base64)` — admin corpus upload body decode | `on FormatException` | Standard-library decoder throws ONLY `FormatException` on malformed base64 — narrowest possible typing. Re-throw as `_AdminInputError` (400 `invalid_content_base64`). `Error`s propagate per C4 so an unexpected runtime defect in the decoder doesn't get masked as "invalid base64". |

A3.4 line count: 18,987 → 19,065 (+78; bleed-stop ceiling 19,071,
headroom 6). Comment density was deliberately compacted (1-2 line
rationales per site instead of A3.3's 3-5 line style) to stay
inside the ratchet — full provenance lives in this audit-doc
registry table above. Test backfill skipped per A3.2 Option A
operator approval (pure refactor; behavior preservation verified
by the existing 223 tests in `test/advisor_proxy_test.dart` and 25
tests in `test/proxy/advisor_proxy_health_envelope_test.dart`).

**Sweep complete.** A3.2 + A3.3 + A3.4 = 12 + 5 + 26 = **43 sites
typed**; 2 retained (line 2426 = `Platform.environment` /
`UnsupportedError`; line 7107 = `SessionRecordIncompleteGauge`
internals owned by A11.1). Original A3.2 estimate was 45 total —
actual is 43 typed + 2 retained = 45. The bare-catch debt for
`tool/advisor_proxy/advisor_proxy.dart` is now closed under the
addendum C4 ("no silent failures") invariant. Pure refactor —
`Exception`-subtype behavior preserved across the 248-test proxy
suite; `Error` propagation is the intended C4 improvement. Future
extraction work (the 25-step plan in Section 4 above) will move
these typed catches into the per-route modules under
`tool/advisor_proxy/routes/` without changing exception
semantics.

**Post-merge carry-forward (single site, not in A3.4's scope):**
B10.1 (PR #576, merged into origin/master AFTER A3.4's worker was
briefed) introduces one **new** bare `catch (_)` at master line
14109 inside the vendor-applicability admin route's
`integrationAdminActorResolver.resolveActorUserId` block — identical
shape to the four sister sites A3.4 typed at 13588 (integrations
admin), 14212 (feature flags admin), and the two earlier
admin-route variants. A3.4 deliberately leaves this site untouched
to honor slice discipline: the worker brief explicitly scopes
"clusters 9-12 of the seam map snapshot" (taken pre-B10.1) and
warns against silently expanding scope when rebases introduce new
material. The B10.1 follow-up (or a separate A3.5 micro-slice) is
the right home for this one-line fix — narrow to `on Exception
catch (_)` with the same Postgres / closed-pool rationale used at
13588 / 14212. This carry-forward does NOT change the "sweep
complete" status for the original 45-site debt the A3 lane signed
up for.
