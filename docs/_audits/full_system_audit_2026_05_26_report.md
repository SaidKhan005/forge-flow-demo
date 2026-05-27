# Full System Audit Report - 2026-05-26

Scope: all active Forge & Flow surfaces and backend architecture lanes, except
the admin console Knowledge Base implementation which was explicitly excluded.

Method: persisted the audit plan, read the binding repo authority docs, ran local
guardrails/static scans, and used parallel read-only audit lanes for mobile,
Operator Web, Admin Console, backend/proxy, data/migrations, infra/tests, and
cross-surface user journeys.

Current working tree note after the fix pass: the checkout still has untracked
`outputs/`. This audit/fix pass did not delete or reset unrelated local output
artifacts.

## Fix Pass Update

The original findings below are retained as audit evidence. This section is the
authoritative status after the 2026-05-26/27 fix pass.

Fixed in this pass:

- P0-1: Operator Web release demo-auth now fails closed outside `assert`.
- P0-2: Production1 migration docs now point to one authoritative pending queue,
  with the two first-connect rows called out as the operator-decision subset.
- P1-1: First-connect demo/live flip now writes canonical
  `public.demo_mode_state.is_demo`.
- P1-2: cap events, audit logs, PII erasure business dates, and tenant adapter
  runtime config now use canonical hierarchy-aware business timing.
- P1-5: Advisor answer now requires `advisor.read`, resolves plan and advisor
  entitlement server-side, ignores client tier/query-class spoofing, and runs
  accounting preflight before provider calls.
- P1-6 and P2 audit-log route drift: Auditor/Compliance is admitted read-only,
  audit-log view/export permissions are honored, and operator-wide audit reads
  fall back to the hierarchy route when the legacy path is unavailable.
- P1-8/P1-9: CSP and full analyzer are green in the local proof run.
- P2 vendor lifecycle logs: Admin, Operator Web, and the auth location proxy
  route now load integration logs instead of throwing "not available yet".
- P2 mobile push: resume-token revalidation is registered and rereads FCM on
  app resume.
- P2 QA runners: Operator/Admin QA nav helpers now fail when route labels are
  missing instead of silently continuing.
- P1-3/P1-4: Open-shift blended wage now carries availability/provenance through
  projector, proxy payload, SQLite, domain model, and mobile sync. Live labor no
  longer synthesizes a phantom zero wage when wage truth is unavailable.
- P1-7: Operator Web "Your plan" now reads a live account-plan snapshot for the
  effective scoped contract price line and feature-entitlement matrix when the
  proxy is wired, with the old honest fallback preserved for older payloads.
- P2 account timing ownership: Location account override routes now reject
  `businessDayRolloverHour`, and the repository rejects direct timing patches
  as a defense-in-depth backstop.
- P2 provider-key rotation: Admin route/client semantics now require the
  `integration.key_rotate` permission, fresh MFA posture, and live role snapshot
  alignment with the server's super-admin gate.
- P2 guardrails: CI/pre-push now invoke the launch-relevant local lints, and
  `release_build_demo_flag_lint` scans release workflows, Dockerfiles,
  Cloud Build files, and deploy scripts.
- P3 orphan cleanup: `AuditLogHierarchyFilterPane` was deleted and the refactor
  follow-up docs were closed.

Still open because they require environment proof, vendor/product scope, or an
operator-controlled production action:

- Production1 migration apply remains pending against the authoritative 75-row
  queue; staging apply evidence and operator approval are still required before
  production apply.
- DB-backed pressure tests for RLS, idempotency, operator isolation, and audit
  hash storms remain intentionally deferred until a staging-capable Postgres
  target is available.
- Push delivery still needs real-device/Patrol proof; local unit coverage now
  proves resume-token revalidation, not delivery to a device.
- The Oracle Micros Simphony webhook verifier remains a documented skip while
  Oracle stays deferred/poll-only.
- Operator Web size headroom is still near zero (`account_screen.dart` and
  `members_screen.dart` are exactly at ceiling), though the size lint is green.

## Highest Priority Findings

### P0-1 - Operator Web release demo-auth guard is ineffective

`lib/main_operator_web.dart:134-142` checks `OPERATOR_WEB_DEMO_AUTH` only inside
`assert`, which is stripped from release/profile builds. `Dockerfile.operator_web:118-120`
builds `--release` and passes `OPERATOR_WEB_DEMO_AUTH` into the artifact.
`docs/contracts/demo_mode_contract.md:463-466` forbids release demo auth. Admin
has the real runtime guard pattern in `lib/main_admin.dart:234-260`; Operator Web
does not.

Impact: a public Cloud Run Operator Web build can be compiled with demo auth and
the runtime guard will not execute.

Recommended fix: move Operator Web to a real runtime fail-closed guard matching
Admin's `adminFixtureAuthBlockedInRelease` pattern and extend release guardrails
to scan Docker/Cloud Build scripts, not only GitHub workflow files.

### P0-2 - Production1 migration/cutover readiness is contradictory

`docs/POST_HARDENING_FOLLOWUPS.md:34-36` says 75 migrations are pending through
`202605251020_plans_and_limits_scoped_contract_windows.sql`, and line 121 says
apply all 75. `runbooks/v1_operator_launch_punchlist_runbook.md:107-110` lists
only two pending files. `PROJECT_TRACKER.md:105` says "2 remaining" while also
pointing to the full P0 queue. Separately, `PROJECT_TRACKER.md:115-121` leaves
cutover gates not started, and `runbooks/tier_m_perf_gate_runbook.md:371-386`
keeps Tier-M preflight blocked.

Impact: Production1 apply order and blast radius are not currently trustworthy
from docs alone. First-connect and operator account production readiness depend
on this being reconciled before any apply.

Recommended fix: create one authoritative Production1 pending-migration
inventory, reconcile whether the intended queue is 2 or 75, attach staging apply
evidence, then update the tracker and launch punchlist together.

### P1-1 - First-connect demo-to-live flip writes the wrong table shape

Schema creates singular `public.demo_mode_state` with `is_demo` at
`db/migrations/202605040000_phase_8_0_integration_framework.sql:395-421`.
`tool/first_connect_backfill_worker/main.dart:908-924` writes plural
`public.demo_mode_states` and a nonexistent `mode` column.

Impact: the first successful vendor backfill can fail exactly where demo should
flip live, leaving the demo/live handoff broken. `flutter test
test/tool/first_connect_backfill_worker/main_test.dart` passed in agent
verification, but the fake executor does not validate the SQL table/column
shape.

Recommended fix: update the worker to upsert `public.demo_mode_state.is_demo =
false` with the existing flip metadata, then add a SQL-shape test that fails on
plural table names or `mode`.

### P1-2 - Business-date writers still bypass canonical hierarchy timing

Slice 7b deprecates `locations.business_day_rollover_hour` because it is
integer-hour only and bypasses hierarchy inheritance
(`db/migrations/202605161500_per_daypart_v1_deprecate_locations_rollover_hour.sql:7`).
Remaining backend seams still read it:

- AI cap events: `tool/advisor_proxy/cap_event_recorder_part.dart:140-174`
- Audit logs: `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart:132-148`
- PII erasure business date: `lib/services/auth/pii_business_date_resolver.dart:30-79`
- Adapter runtime config: `lib/services/integration/per_tenant_location_config_resolver.dart:223-254`

Impact: these write paths can produce wrong business dates under sub-hour
cutoffs or org-unit/location timing overrides, and they drift from HP#11.

Recommended fix: route these through the canonical business timing profile
resolver/projector used by vendor sinks, then add regression cases with a 04:30
cutoff and inherited org-unit timing.

### P1-3 - Open-shift live labor can show phantom zero blended wage

`lib/services/integration/open_shift_snapshot_projector.dart:494` writes
`blendedWage: 0`. `lib/state/shift_service_period_notifier.dart:658-709`
synthesizes labor punches from the snapshot and uses that wage. Shift UI then
marks the blended wage live at `lib/screens/shift_dashboard.dart:1334-1335`.
Metric Honesty requires unavailable, not phantom zero, for missing live values.

Impact: a live open-shift daypart can show labor as live while presenting zero
wage as if it were measured.

Recommended fix: model missing blended wage explicitly, stop synthesizing live
wage from zero, and add `open_shift_snapshot_projector_test.dart` coverage for
blended wage availability.

### P1-4 - Open-shift provenance is stored in Postgres but lost before mobile

Postgres stores `open_shift_snapshots.provenance` at
`db/migrations/202605060000_phase_business_timing_live_schema.sql:292`, and the
Postgres repository preserves it at
`lib/infrastructure/persistence/postgres/repositories/open_shift_snapshots_repository.dart:403`.
The mobile model lacks the field at `lib/domain/models/open_shift_snapshot.dart:7-24`,
SQLite lacks a column at
`lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart:248`, and
Shift falls back to `vendor_unknown` at `lib/screens/shift_dashboard.dart:1159-1160`.

Impact: mobile erases live metric provenance that already exists upstream.

Recommended fix: add provenance to the sync payload, domain model, SQLite schema,
and UI source labeling tests.

### P1-5 - Advisor answer tier/cost controls are not authoritative enough

`tool/advisor_proxy/advisor_answer_route_group_part.dart:198-266` reads
`subscription_tier` from the request body and routes the model from that client
value. Plans & Limits closeout says model routing is by plan
(`docs/phases/plans_and_limits_v1/plans_and_limits_v1_plan.md:16`,
`PROJECT_TRACKER.md:390-394`). The same route does call `usageGuard` before the
provider at lines 244-253, but it does not use the full
`ProxyAccountingStore.startRequest` preflight/idempotency/cap path documented at
`tool/advisor_proxy/advisor_proxy.dart:2557-2663`; it only commits usage after
the provider at `advisor_answer_route_group_part.dart:455-470`.

Impact: model tier is client-spoofable, and advisor answer metering is not on
the same strongest preflight path as the main proxy accounting stack.

Recommended fix: resolve tier server-side from the authenticated operator and
use the accounting preflight reservation/cap path for advisor answer, including
idempotency and cap refusal evidence.

### P1-6 - Auditor/Compliance is mapped, then blocked before Audit Log

`lib/operator_web/auth/firebase_operator_web_auth_source.dart:707-709` maps the
role to `auditor_compliance`. Console admission at lines 737-746 admits only
owner/GM/location manager roles or a narrow permission list that omits
`team.audit_log.view/export`. `lib/operator_web/screens/audit_log_screen.dart:175-182`
would allow the screen if reached. The catalog grants auditor/compliance audit
view/export at `docs/contracts/auth_permission_key_catalog.md:261-262` and
describes the role at line 415.

Impact: a valid read-only audit role can be denied entry before it reaches its
own primary surface.

Recommended fix: include audit-log view/export permissions in console admission
or add an explicit admitted-role path for `auditor_compliance` with read-only
navigation.

### P1-7 - "Your plan" does not read live entitlement/custom-contract truth

`lib/operator_web/screens/plan_screen.dart:17-23` says it makes no proxy call.
Line 310 uses `buildDefaultFeatureEntitlements()`, and
`lib/services/auth/account_info_gateway.dart:46-53` carries only tier/trial.
Plans & Limits says feature entitlements, model routing, Operator Web "Your
plan", and scoped custom contracts shipped
(`docs/phases/plans_and_limits_v1/plans_and_limits_v1_plan.md:15-24`);
`docs/phases/plans_and_limits_v1/scoped_custom_contracts_plan.md:35` requires
Operator Web to read cleanly for Enterprise/custom contracts.

Impact: the operator-visible plan page can disagree with live entitlement and
scoped contract state.

Recommended fix: project effective entitlement and scoped custom-contract
summary through the account/session payload or a dedicated read endpoint, then
replace client defaults with live effective truth.

### P1-8 - Current checkout has a dev-relaxed CSP

`dart run tool/csp_header_lint.dart` currently fails. `web/index.html:24-35`
contains `script-src 'unsafe-inline' 'unsafe-eval'`, localhost connect sources,
and no `upgrade-insecure-requests`; `web/index.prod.html.bak` is untracked.
The dev CSP swap scripts state source files should remain prod-strict.

Impact: if the current working tree were built as-is, the web artifact would
carry dev CSP relaxation.

Recommended fix: restore the production `web/index.html` after the dev session
and make the CSP swap tool fail closed or auto-restore on interrupted runs.

### P1-9 - Analyzer gate fails while CI is dark

`dart analyze --fatal-infos` exits 1 with eight unused imports in mobile pressure
integration tests:

- `integration_test/mobile_pressure/auth/scenario_auth_01_demo_login.dart:13`
- `integration_test/mobile_pressure/auth/scenario_auth_01_demo_login.dart:17`
- `integration_test/mobile_pressure/auth/scenario_auth_02_login_form_present.dart:16`
- `integration_test/mobile_pressure/regression/scenario_reg_01_crashreporter_no_freeze.dart:27`
- `integration_test/mobile_pressure/regression/scenario_reg_01_crashreporter_no_freeze.dart:30`
- `integration_test/mobile_pressure/shell/scenario_shell_01_all_tabs_mount.dart:15`
- `integration_test/mobile_pressure/shell/scenario_shell_01_all_tabs_mount.dart:18`
- `integration_test/mobile_pressure/shell/scenario_shell_04_rapid_nav_stress.dart:25`

Impact: local canonical analyzer proof is red during the documented CI-dark
window.

Recommended fix: remove the unused imports and rerun `dart analyze --fatal-infos`.

## Additional Findings

### P1/P2 - Advisor answer has backend/client pieces but no operator-facing entry

`lib/services/advisor/advisor_answer_gateway.dart:1-16` and line 247 define the
client service/provider. `lib/operator_web/auth/firebase_operator_web_auth_source.dart:31-32`
does not expose an advisor provider mixin, and
`lib/operator_web/router/operator_web_router.dart:1498-1588` has no advisor nav
entry. The advisor activation plan still calls out D2/D3 operator-facing UI
work, excluding the admin KB implementation.

Impact: outside Admin KB work, operators still cannot talk to the advisor.

### P2 - Vendor lifecycle logs/actions are stranded across surfaces

The shared vendor widget calls `loadLogs` at
`lib/integrations/ui/vendor_connections/vendor_connections_widget.dart:391`.
The proxy has admin logs routes at
`tool/advisor_proxy/admin_integrations_routes.dart:495` and handler coverage
around line 943. Live Admin throws "not available yet" at
`lib/admin/services/admin_vendor_connections_gateway.dart:239-240`; Operator Web
throws similarly at
`lib/operator_web/services/operator_web_vendor_connections_gateway.dart:227-237`.
Operator Web also documents Notify Me and retry as unwired in
`lib/operator_web/screens/vendor_connections_screen.dart:31` and
`lib/operator_web/widgets/vendor_connections_backfill_progress_panel.dart:342`.

Impact: visible lifecycle affordances are not actually wired end-to-end.

### P2 - Operator-wide audit log still uses legacy self-scoped path

`lib/operator_web/screens/audit_log_screen.dart:289` uses the hierarchy route
only for non-operator-wide scopes, so operator-wide falls back to
`widget.gateway.listEntries` at line 421. The legacy backend route at
`tool/advisor_proxy/advisor_proxy.dart:11344-11392` clamps reads to
`actorUserId: scope.userId` and lacks the newer `team.audit_log.view` gate. The
new hierarchy route has the right permission posture in
`tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart:15`.

Impact: operator-wide audit review can become "my own auth events" instead of
the operator audit view.

### P2 - Account override APIs still edit business-day rollover outside Business Timing

`tool/advisor_proxy/operator_location_account_overrides_routes.dart:428` accepts
`businessDayRolloverHour`, and
`lib/infrastructure/persistence/postgres/repositories/location_account_overrides_repository.dart:280`
mirrors it into `public.locations`. The org-unit account route rejects that
field as Business Timing-owned at
`tool/advisor_proxy/operator_account_scope_overrides_routes.dart:94`, matching
`db/migrations/202605201000_org_unit_account_overrides.sql:9`.

Impact: location account settings still have a timing write surface that newer
scope routes intentionally removed.

### P2 - Mobile push resume-token revalidation is declared but not registered

`lib/main_forgeflow.dart:180-205` defines `FcmTokenRevalidationObserver`, but no
`WidgetsBinding.instance.addObserver(...)` registration exists. The target
method only re-syncs cached state at
`lib/services/mobile_push/mobile_push_notification_service.dart:805-810`.
`dart run tool/pressure/p5_push_delivery_proof.dart` exits 0 but emits
`push_delivery.skipped` with `deferredPatrolMissing`, even though `pubspec.yaml`
now includes Patrol.

Impact: push delivery proof and resume-token refresh remain incomplete.

### P2 - QA route coverage is stale

Operator Web registers "Your plan" at
`lib/operator_web/router/operator_web_router.dart:1588` and
`lib/operator_web/screens/plan_nav.dart:13-24`, but `web/_qa_runner.js:167-178`
and `runbooks/operator_web_qa_runbook.md:121-138` still describe the older 11
route/42 assertion set. Admin route paths are documented as future metadata in
`lib/admin/admin_route_model.dart:34`, while `lib/admin/admin_app.dart:83` and
`lib/admin/admin_shell.dart:71` use shell state rather than browser routing.
The admin QA runbook lists Polling Setup as primary nav, but
`lib/admin/admin_routes.dart:391-399` marks it hidden.

Impact: canonical QA can pass while missing shipped route/nav behavior.

### P2 - Provider key rotation has split client permission semantics

`lib/auth/permission_keys.dart:246` and line 384 define `integration.key_rotate`
as MFA-required, but Admin route UI enables rotation through `_isAdminSuperAdmin`
at `lib/admin/admin_routes.dart:1166`. The live gateway is built without a
client permission resolver at `lib/main_admin.dart:643`, while the proxy gates
strict super_admin role and fresh auth at
`tool/advisor_proxy/advisor_proxy.dart:11955-11975`.

Impact: server-side safety is good, but route/client permission semantics do not
match the catalog key end-to-end.

### P2 - Guardrail coverage has drifted out of CI/pre-push

`.github/workflows/ci.yml:97-118` and `.githooks/pre-push:119-141` cover only a
subset of local guardrails. Missing or weakly covered checks include
`release_build_demo_flag_lint`, `operator_web_size_lint`,
`skip_quarantine_lint`, `ux_em_dash_lint`, `ignore_justification_lint`,
`csp_header_lint`, and `vendor_completeness_lint`. The current
`tool/release_build_demo_flag_lint.dart:158-176` scans workflow files only, so
it missed the Docker/Cloud Build Operator Web demo-auth path.

Impact: several launch-relevant failures are only caught by manual audit runs.

### P2 - DB-backed concurrency pressure remains deferred

`docs/POST_HARDENING_FOLLOWUPS.md:1370-1392` explicitly defers DB-backed
pressure for RLS, idempotency, operator isolation, and audit hash storms. The
pressure tests remain in-memory/default-only at:

- `test/pressure/p3d_rls_multi_tenant_concurrent_reads_test.dart:23-39`
- `test/pressure/p3d_idempotency_store_concurrent_retry_test.dart:21-38`
- `test/pressure/p3d_operator_scoped_isolation_under_concurrency_test.dart:35-41`
- `test/pressure/p3d_audit_chain_hash_storm_test.dart:39-45`

Impact: launch risk remains around real-row concurrent isolation/idempotency
behavior.

### P3 - Operator Web size headroom is near zero

`dart run tool/operator_web_size_lint.dart` passes, but reported:

- `lib/operator_web/screens/account_screen.dart`: 2223/2223
- `lib/operator_web/screens/members_screen.dart`: 1702/1702
- `lib/operator_web/router/operator_web_router.dart`: 2948/2950

Impact: any small accepted change can fail local guardrails unless extraction
happens first.

### P3 - Known orphan/stale code remains

Resolved in the fix pass: `AuditLogHierarchyFilterPane` was removed and the
refactor/follow-up docs now mark the cleanup closed. Archived historical audit
notes still mention the widget, but active `lib/` code does not.

### P3 - Vendor completeness has documented deferred Oracle verifier

`dart run tool/vendor_completeness_lint.dart` exits 0, but reports the
documented skip for missing
`lib/integrations/pos/oracle_micros_simphony_webhook_signature_verifier.dart`.

Impact: deferred vendor lifecycle item, not an active V1 blocker if Oracle
remains documented/deferred.

## Verification Summary

Local checks that passed after fixes:

- `flutter test test/main_operator_web_demo_auth_guard_test.dart test/mobile_push_notification_service_test.dart test/main_forgeflow_test.dart test/operator_web/auth/firebase_operator_web_auth_source_test.dart test/operator_web/auth/firebase_operator_web_auth_source_g7d_v2_roles_test.dart test/operator_web/auth/firebase_operator_web_auth_source_permission_constants_test.dart test/operator_web/screens/audit_log_screen_test.dart test/operator_web/screens/plan_screen_test.dart test/admin/admin_vendor_connections_gateway_test.dart test/operator_web/services/operator_web_vendor_connections_gateway_test.dart test/proxy/auth_location_integrations_route_test.dart test/services/auth/pii_business_date_resolver_test.dart test/services/integration/per_tenant_location_config_resolver_test.dart test/tool/first_connect_backfill_worker/main_test.dart test/advisor_proxy_usage_and_migrations_test.dart test/proxy/advisor_answer_route_test.dart test/services/integration/open_shift_snapshot_projector_test.dart test/services/sync/http_sync_proxy_client_test.dart test/services/sync/postgres_shift_record_to_mobile_sync_test.dart test/proxy/mobile_operational_sync_shift_records_test.dart test/proxy/operator_location_account_overrides_routes_test.dart test/admin/integration_admin_gateway_test.dart test/admin/g7a_admin_super_admin_helper_test.dart test/services/auth/demo_auth_release_guard_test.dart test/domain/models/timing_provenance_models_test.dart`
- `dart analyze --fatal-infos`
- `dart run tool/csp_header_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `dart run tool/advisor_proxy_size_lint.dart`
- `dart run tool/operator_web_size_lint.dart`
- `dart run tool/release_build_demo_flag_lint.dart`
- `dart run tool/vendor_completeness_lint.dart`

Earlier audit checks that also passed:

- `dart run tool/skip_quarantine_lint.dart`
- `dart run tool/permission_key_lint.dart`
- `dart run tool/postgres_import_lint.dart`
- `dart run tool/index_leading_column_lint.dart`
- `dart run tool/rls_policy_lint.dart`
- `dart run tool/migration_cutoff_lint.dart`
- `dart run tool/migration_drift_scanner.dart --strict-docs`
- `dart run tool/actions_pinning_lint.dart`
- `dart run tool/ignore_justification_lint.dart`

Checks not reclassified as complete:

- `dart run tool/pressure/p5_push_delivery_proof.dart` still needs a real
  device/Patrol delivery proof; earlier it exited 0 with
  `push_delivery.skipped`.

## Remaining Fix Order

1. Attach staging apply evidence and operator approval for the Production1
   migration queue before any production apply.
2. Run DB-backed pressure against staging-capable Postgres before Production1.
3. Run connected-device/Patrol push delivery proof when the device lane is
   available.
4. Decide whether Oracle Micros Simphony webhook verification enters scope; if
   it does, remove the documented vendor-completeness skip.
5. Extract the zero-headroom Operator Web files before accepting more broad
   UI work in `account_screen.dart`, `members_screen.dart`, or the router.
