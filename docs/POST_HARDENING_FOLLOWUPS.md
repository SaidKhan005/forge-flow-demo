# Post-Hardening Follow-ups

Updated: 2026-05-08 (multi-agent deep-dive sweep added 7 new findings
in the new "Audit additions — 2026-05-08" section; postgres-repo
coverage line corrected from "18 of 29 / 10 covered" to actual
"27 of 47 / 20 covered"; admin hierarchy lane excluded — separate
team). Prior update 2026-05-07 (Phase 8 plug-and-play V1 closeout —
resolved operator-self-service / backfill-factory / OAuth-refresh-closures /
location-integrations-list / test-connection / api-key paste / route
alignment / binder split / analyzer sweep gaps archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md`).
Earlier closeouts: `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`
and the 2026-05-07 closeout addendum at the bottom of this file.
Origin: 2026-05-02 deep audit.

## P0 — Production1 Migration Apply Gap

**28 migrations pending Production1 apply** (chronological). The queue now
runs through `202605081000_outbox_notify_channel_split.sql`; staging/preview
apply evidence must stay attached to the runbook before any Production1 apply.

| Migration | Origin | Staging |
|---|---|---|
| `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` | 11A.5 Debug Console SELECT grant | applied + Browser Use verified 2026-05-03 |
| `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` | 11A operator/location admin DML | applied + Browser Use verified 2026-05-04 |
| `202605060000_mobile_push_notifications.sql` | Mobile FCM/APNs + delivery sidecar | code-ready; needs staging apply + connected-device proof |
| `202605060000_phase_business_timing_live_schema.sql` | `business_timing_profiles` + `open_shift_snapshots` | code-ready |
| `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql` | 11A.14 audited support actions | code-ready (additive seed + grants) |
| `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql` | 5-index `operator_id` rekey | code-ready (`CONCURRENTLY`) |
| `202605061600_phase_11W_5_team_audit_log_export_key.sql` | 11W.5 `team.audit_log.export` key + grants | code-ready |
| `202605061700_hardening_audit_anchor_daily_schedule.sql` | Wave B3 daily pg_cron tick `forge_audit_anchor_daily` 02:00 UTC (NOTIFY-only kickoff) | code-ready |
| `202605061700_phase_8_timing_provenance_shift_records.sql` | Phase 8 timing provenance keys for closed/live shift rows | code-ready |
| `202605061701_phase_8_data_accuracy_service_period_settings.sql` | Wave B1 keyed Data Accuracy child table | code-ready |
| `202605061800_phase_8_first_connection_backfill_jobs.sql` | Phase 8 first-connection durable backfill jobs | code-ready — **operator decision pending** |
| `202605070000_phase_11W_7_operator_account_fields.sql` | 11W.7 / Wave A2 operator-web Account editor write-fields | code-ready — **operator decision pending** |
| `202605070100_password_history_salt_pepper.sql` | Code Health M2 password-history salt/pepper | code-ready |
| `202605070200_audit_anchor_advisory_lock_infra.sql` | Code Health M3 audit-anchor advisory lock + Azure breadcrumbs | code-ready |
| `202605070400_phase_8_notification_preferences.sql` | Phase 8 W2.B per-actor notification preferences (synthetic UUID PK + `UNIQUE NULLS NOT DISTINCT` on 6-tuple, per-user RLS, operator-leading indexes) | code-ready |
| `202605080000_phase_8_timing_provenance_fk_posture.sql` | V1.B Phase 8 timing-provenance FK flip to `ON DELETE SET NULL` | code-ready |
| `202605080100_admin_idempotency_expires_at.sql` | Code Health M1 admin idempotency TTL | code-ready |
| `202605080100_phase_8_weekly_plan_server_truth.sql` | Phase 8 weekly-plan server truth (forecast contexts + snapshots) | code-ready |
| `202605080200_phase_8_wage_role_rows_server_truth.sql` | Phase 8 wage-role row server truth | code-ready |
| `202605080300_phase_8_data_accuracy_walk_in_settings.sql` | Phase 8 walk-in handling additive fields | code-ready |
| `202605080400_phase_8_connector_oauth_state.sql` | Phase 8 connector OAuth CSRF/PKCE state table | code-ready |
| `202605080500_permission_cache_invalidation_channel.sql` | Auth permission cache invalidation NOTIFY channel | code-ready |
| `202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql` | Webhook signing secret column separate from OAuth bearer ciphertext | code-ready |
| `202605080600_phase_8_demo_pending_counter_persisted.sql` | Persist demo-mode pending insert counters across pods | code-ready |
| `202605080600_phase_8_idempotency_location_id_rekey.sql` | A1 idempotency rekey: add location_id, switch to vendor_modified_at >= guard | code-ready |
| `202605080700_audit_anchor_cron_unpause.sql` | Audit-anchor cron unpause / scheduling follow-up | code-ready |
| `202605080800_auth_permission_version.sql` | Auth permission-version invalidation column/index | code-ready |
| `202605080900_oauth_refresh_advisory_lock.sql` | OAuth refresh advisory-lock registry row | code-ready |
| `202605081000_outbox_notify_channel_split.sql` | Split outbox NOTIFY channels for bounded consumers | code-ready |

**Action:** apply all 28 in next Production1 event per
`runbooks/phase_9_production1_migration_apply_runbook.md`. Until applied
+ verified, the corresponding feature is **staging-ready only**.

## P1 — Live Admin Operational Gates

The staging admin smoke surfaced live actions that code cannot complete
without operator-held secrets and action-time approval. Resolved graph
candidate packaging and staging audit-anchor remediation are archived in
`docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`.

- Provider credentials / KMS rollout: use
  `runbooks/admin_provider_credentials_kms_rollout_runbook.md`.
- Admin browser QA: use the static-build path in
  `runbooks/admin_console_browser_qa_runbook.md`; treat debug web-server
  bootstrap failures as dev-workflow noise unless the static build also
  fails.

## P1 — Business Timing / Live Shift Architecture Follow-ups

Open items from the 2026-05-06 audit:

- Add keyed per-service-period Data Accuracy settings before enabling a
  fourth or non-canonical service period key for an operator. (Schema
  ships in `202605061701_…`; consumer code lane open.)
- Persist/use stable timing profile and service-period keys for
  bucketed live and closed facts so label changes do not rewrite
  history.
- Treat Operator Web as the normal timing editor and F&F Operations
  Console as audited support override only.

### Phase 8 timing-provenance — only one open thread

Lane 0 + 1 + 2 + 3 + 4 + 5 + the closed-row proxy gap (V1.A) + FK
posture flip (V1.B) all merged 2026-05-06/-07. The single remaining
follow-up:

- **Drop the version-equals-profile CHECKs before any future Phase 8R
  divergence.** Lane 0 added
  `shift_records_timing_version_profile_match_check` and
  `open_shift_snapshots_timing_version_profile_match_check`
  (`version_id IS NOT DISTINCT FROM profile_id`, both `NOT VALID`) as
  the V1 enforcement of decision A. When Phase 8R introduces a real
  `business_timing_profile_versions` table and code starts writing a
  divergent `version_id`, both CHECKs must be dropped first; otherwise
  the first divergent INSERT fails. Refs:
  `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql:51-66,
  113-129`.

## P2 — Test Coverage Gaps Remaining

| Surface | LOC | Test files | Coverage |
|---|---|---|---|
| `lib/admin/services/operator_location_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| `lib/admin/services/pricing_tier_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| `lib/admin/services/integration_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| 27 of 47 postgres repositories | varies | 20 covered (43%) | partial; chip away during routine slices. Audit recount 2026-05-08 — prior tracker line said "18 of 29 / 10 covered"; current census is 47 repos / 20 with `*_test.dart`. Highest-LOC uncovered: `weekly_plan_snapshot_repository.dart` (1038), `business_timing_profiles_repository.dart` (947), `target_cycle_repository.dart` (775), `corpus_repository.dart` (738), `forecast_context_repository.dart` (690), `graph_repository.dart` (684), `active_target_profile_repository.dart` (675), `auth_events_audit_repository.dart` (633), `selected_star_shift_repository.dart` (616), `user_pii_erasure_repository.dart` (656). |

## P3 — Verified-keep API surfaces (verified 2026-05-06, Wave B4)

The 2026-05-02 audit flagged these as "unused public classes." The
2026-05-06 verification sweep (Wave B4) found each is the return type
of a unit-tested method on a sibling class in the same file — none
deletable in isolation:

- `AuditLogExportResult` — return type of `AuditLogCsvExport.export(...)`.
- `MfaOverrideChange` — value type of `MfaPolicyEditorState.diff()`.
- `MatrixCellChange` — element type of
  `RolePermissionMatrixController.diff()`.
- `CorpusCloudLoadResult` — return type of
  `AdvisorCorpusAdminService.attemptCloudLoad(...)`.

**Status:** keep all four. Re-evaluate only if the sibling method
(`export`, `diff`, `attemptCloudLoad`) is itself removed in a wider
lane.

## Code Health Residuals (post-Wave 5, 2026-05-08)

Consolidated from the 2026-05-06 audit's open residuals after five
remediation waves closed 52 of 64 findings. Historical context:
`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`.

### P1 — Audit anchor cron unpause

Operational change in Cloud Scheduler; not code. Worker code shipped
Wave 1 ([#254](https://github.com/SaidKhan005/forge-flow-demo/pull/254))
and the schema landed Wave 0
([#210](https://github.com/SaidKhan005/forge-flow-demo/pull/210)).
Action: flip the `audit-anchor-daily` cron from paused to active.
Compliance posture; the tamper-evidence story has an unbounded window
without it. The companion migration
`202605080700_audit_anchor_cron_unpause.sql` is already queued in the
P0 Production1 list above.

### P2 — `backfill_dispatch.dart:368` bare `catch (_)`

Same shape as the LB3 fix that closed Wave 5
([#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364)) but
outside that lane's audit-cite scope. Apply the same pattern: typed
`on TimeoutException` / `on Exception` / `on Object` arms with a
structured-log reporter. Evidence:
`tool/integration_sync_worker/backfill_dispatch.dart:368`. Silent
failures in the backfill-dispatch loop until fixed.

### P2 — Two widget contract violations

Both are architecture-contract violations per CLAUDE.md "Architecture
Guardrails" (`Widgets do not own source-truth or service-period
bucketing`). No runtime failure today; contract decay if left.

- `lib/screens/shift_dashboard.dart:35-41` — widget owns timezone
  bootstrap (`_ensureTzInitialized`) plus service-period bucketing
  (`_servicePeriodSlivers`). Action: move timezone init into a
  service-layer initializer.
- `lib/screens/settings/settings_wage_authority_section.dart:48,64,67`
  — widget calls `SqliteWageRoleRowRepository.instance` directly.
  Action: route through a service that owns the SQLite call.

### P2 — No common worker base

Every worker re-implements the claim loop, error catch, log, alert,
and metric emission. Action: extract a `WorkerBase` abstract class or
`WorkerLoopMixin` so new workers inherit the discipline rather than
copy/paste it. Reduces drift across `tool/integration_sync_worker/`,
`tool/audit_anchor/`, and the OAuth refresh worker.

### P2 — Two-slot key vs counter-store granularity mismatch

`usage_logs` keys are broader than the runtime counter-store
`(operator_id, location_id, tier_id, minute_bucket)` UNIQUE shape.
Two restaurants on the same operator can fight over the same
rate-limit bucket. Evidence:
`tool/advisor_proxy/advisor_proxy.dart:2418` (interface) and
`lib/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart:57`
(concrete store). Rate-limit fairness; not breaking anything today.

### P3 — `admin_routes.dart` and `advisor_proxy.dart` monolith debt

Structural; needs route-by-route migration plans for each. Reviewer-
time multiplier rather than a runtime bug.

- `lib/admin/admin_routes.dart` — 2,204 lines (audit cited ~1,906;
  +298 net since 2026-05-06).
- `tool/advisor_proxy/advisor_proxy.dart` — 16,949 lines (audit cited
  14,500; +2,449 net since 2026-05-06). Debt is reaccumulating faster
  than CODE_HEALTH lanes can clear it.

Each warrants its own phase doc when the proxy split is sequenced.

### P3 — Duplicated abstractions

- Three adapter interfaces with identical method shapes.
- ~12 proxy gateways re-implementing `_postJson + idempotency-key`.
- Four trigger functions with the same body.

Architectural; needs collapsing as the proxy monolith is split rather
than as standalone lanes.

### P3 — SQLite repos as process-global singletons

Operator-switch leak partially closed by LB1's
`DatabaseHelper.forScope` factory; full repo-level scope-keying
remains a follow-up if a future incident exposes the gap. Latent; no
active incident.

### P3 — `vector_index_health` CLI placeholder

`tool/vector_index_health/main.dart:62` passes `activeVectors: 0`
(documented as `'CLI placeholder snapshot — no live DB query was
issued'`). The production reader at
`tool/advisor_proxy/health_producers/vector_producers.dart`
(`vectorActiveCountPerCorpusProducer`) queries Postgres correctly.
Action: replace the CLI placeholder with a Postgres-backed query, or
document the CLI as a non-production tool more loudly.

## Closeout — items closed since 2026-05-02 (kept for cross-reference)

Most items from the 2026-05-02 audit closed via the CODE_HEALTH
remediation wave (16 PRs) and the V1 closure dispatch (V1.A / V1.B).
Highlights:

- FK posture on closed `shift_records` → `ON DELETE SET NULL` (V1.B,
  migration `202605080000_…`). Closed historical truth survives
  profile mutation.
- Closed-row proxy timing-provenance gap (V1.A) — closed shift_records
  proxy SELECT/mapper now emits the timing triplet so mobile sync
  consumes Lane 2's resolver.
- Same-second prefix collision on three `202605061700_` migrations —
  resolved 2026-05-06 by renumbering data-accuracy entry to `…1701_…`.
- Phase 8 spine-bridge live wire-in dormancy (aggregator + projector
  unwired) — resolved by `8.first-connect-backfill-wire-in`
  (`canonical_fact_post_commit_projector.dart`).

Test parcels for MFA, postgres repo batch 1/batch 2, and the Phase 11b
retrieval assumption are archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`.

## Audit additions — 2026-05-08 deep-dive sweep

A multi-agent audit on 2026-05-08 covered: time/RLS/Postgres-import
guardrails, demo-mode purity, widget-architecture guardrails,
placeholder/silent-error patterns, Phase 8 vendor closeout reality,
postgres-repo test coverage, worker abstraction, idempotency-pattern
coverage, and `OperatorScopedRepository<T>` primary-defense coverage.
Admin hierarchy lane was excluded (separate team).

Findings below are NEW or refine prior items. Confirmed-clean lanes
(time guardrails, raw `package:postgres` import lint, RLS wrapper
function presence, all 17 Phase 8 vendor adapters at literal
`lifecycle: VendorLifecycle.documented`) are not re-listed.

### P1 — `audit_logs_repository.dart` bypasses `OperatorScopedRepository<T>`

`lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart`
is a stateless writer that takes `operatorId` as a **caller-supplied
parameter** (`writeRow(exec, operatorId: ..., ...)`) instead of
extending `OperatorScopedRepository<T>` and reading the operator from
the tenant `SET LOCAL` context. The underlying `audit_logs` table is
operator-scoped (`operator_id uuid not null`).

Why it exists: thin stateless writer designed to run inside the same
transaction as the business change so audit commits atomically.

Risk: a careless caller or logic bug could pass an attacker-controlled
operator id and forge audit rows on a different operator's chain. The
repository pattern's primary defense is bypassed; only RLS on
`audit_logs` (the backup) prevents the leak.

Action: refactor to extend `OperatorScopedRepository<T>` so
`operator_id` is injected from `withTenant(...)` rather than passed in.
Single-repository scope; the other 46 repos correctly extend the base
or are non-scoped global tables (`kms_rollout_flag`,
`service_principals`).

### P1 — 4 admin integration routes missing idempotency guard

`tool/advisor_proxy/admin_integrations_routes.dart` writes do not
extract `Idempotency-Key` or consult `proxy_requests` despite the file
header (line 15) claiming "All admin writes are idempotent via the
existing `proxy_requests` table". Affected:

- `POST /v1/admin/integrations/oauth/{vendor}/start` — `:284`
- `POST /v1/admin/integrations/{vendor}/connect-key` — `:326`
- `POST /v1/admin/integrations/{vendor}/test-connection` — `:368`
- `POST /v1/admin/integrations/{vendor}/disconnect` — `:393`

Action: thread `Idempotency-Key` into `Phase80IntegrationRoutes._handleAdmin`
and reuse the existing `OperatorWriteIdempotencyCache` pattern (or
delegate to `AdminRequestIdempotencyStore` referenced at
`tool/advisor_proxy/advisor_proxy.dart:7706`).

### P1 — `advisor_proxy.dart:9105-9106` hardcoded prompt placeholders

Production launch-tier prompt build path passes literal strings
`'launch methodology context placeholder'` and
`'advisor tool definitions placeholder'` for the `methodologyContext`
and `toolDefinitions` prompt blocks. These are not stub fallbacks —
they ship in the cached prompt for every launch-tier advisor request
when `corpusVersion` is resolved.

Action: replace with the real methodology context + tool definitions
strings before any AI-paused work resumes (Phase `11b` /
`12.0`–`12.5`). Tracked here so the freeze-thaw checklist sees it.

### P1 — Demo-mode banner promised by architecture but never wired

`lib/services/integration/demo_mode_state.dart:12-15` (the file header)
explicitly promises: *"Operator-app UX: the demo-mode banner reads
runtime state from this surface, not from a config flag. Once the
operator's first vendor connection backfills successfully, the banner
clears without a redeploy."*

Reality: zero widgets in `lib/screens/` or `lib/widgets/` read `isDemo`
or `is_demo` at runtime. The Postgres `demo_mode_state` row + the
`DemoModeFlipPolicy` flip path are fully wired on the **write** side
(every Phase 8 vendor sink calls `flipToLive(...)` after first
backfill commit), but the **read** side ends at the gateway interface.
No UI consumes it.

Operator impact: an onboarded operator who hasn't connected a POS yet
has no on-screen indication they're looking at demo data. The
build-time `kDemoMode` badge (Carve-out #2) is irrelevant in a
production build, so the runtime "you're in demo" signal is invisible
to a real operator.

Action — slice `8.demo-mode-banner`:
- New `DemoModeBanner` widget (`lib/widgets/` or
  `lib/integrations/ui/`). Subscribes to active (operator, location,
  category) and reads `DemoModeStateGateway.readOrCreateDefault(...)`
  for each of the three categories (POS, Labor, Reservation).
- Renders one banner per category that's still `is_demo = true`
  (e.g. "Demo POS data — connect a POS to go live") with a CTA that
  deep-links to the vendor-connections screen.
- Auto-clears via the realtime spine when `DemoModeFlipPolicy` flips
  the row (Phase 10a infrastructure already broadcasts the change).
- AppShell mount point so it appears across the operator app, not just
  one screen.
- Walkthrough doc per HP #10.

This is a runtime-state read, not a `kDemoMode` carve-out; no contract
change needed. Test approach: integration test asserting the banner
shows when `demo_mode_state.is_demo = true` for the active scope and
clears when the row flips.

### P1 — Two new widget→repo direct-call violations

Both violate the CLAUDE.md "Architecture Guardrails" rule that widgets
do not own source-truth or service-period bucketing.

- `lib/screens/notifications_screen.dart:12,36-37` — widget imports
  `SqliteRestaurantScopeRepository` and calls
  `SqliteRestaurantScopeRepository.instance.getActiveRestaurantId()`
  inline.
- `lib/screens/schedule/schedule_forecast_notifier.dart:19,210-211` —
  notifier (widget-tree `ChangeNotifier`) does the same.

Action: route both through a service that owns the SQLite call. Same
shape as the known `settings_wage_authority_section.dart` violation in
the P2 list above.

### P2 — Undocumented `kDemoMode` reader-side carve-out

`lib/screens/settings_screen.dart:31,374,383` adds a third reader-side
`kDemoMode` branch (Data reset + Demo date sections gated on
`_kDemoMode`). The file has a local comment at lines 27-30 explaining
the design, but CLAUDE.md and `docs/contracts/demo_mode_contract.md`
list only two carve-outs (login button + data-status badge) — this one
is undocumented.

Action: pick one of:
1. Add this as Carve-out #3 in CLAUDE.md "Demo Mode" section and the
   contract doc, with the same `// kDemoMode carve-out: <reason>`
   marker the contract requires.
2. Refactor the two demo sections to render unconditionally and
   no-op when `DemoScope.restaurantId` is not the active scope.

HP #2 strict reading: option 2 is preferred; option 1 acknowledges the
existing UX intent.

### P2 — `audit_logs_repository.dart:368` style bare catches in advisor proxy

The known `tool/integration_sync_worker/backfill_dispatch.dart:368`
bare-catch (justified by terminal-state comment) is one site; the
broader pattern is wider:

- `tool/advisor_proxy/advisor_proxy.dart` — 16 bare `catch (_)` arms
  in the request-handling path
  (lines `1319,1352,1429,1661,1698,1789,1944,1974,1980,1997,2306,2540,
  2618,5143,5221,5274`).
- `lib/state/auth_session_notifier.dart` — 5 bare catches in auth
  lifecycle (lines `156,167,280,451,492`).
- `lib/infrastructure/persistence/postgres/tenant_transaction.dart` —
  3 (lines `81,127,172`).
- `lib/infrastructure/persistence/postgres/package_postgres_executor.dart`
  — 3 (lines `119,269,405`).

Same fix pattern as the LB3 work that closed Wave 5
([#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364)):
typed `on TimeoutException` / `on Exception` / `on Object` arms with
structured-log reporter. Concentrate on the auth-lifecycle and
tenant-transaction sites first — those swallow errors that should
surface as security/data-integrity signals.

### P3 — `lib/admin/admin_routes.dart` placeholder route flags

Lines `7, 90, 118, 147, 151, 166` track `.placeholder` boolean and
skip route-surface rendering when true. These mark Phase 11A
not-yet-shipped routes. No bug today; they correctly degrade. Flag
for clearing as Phase 11A.8/.9/.10 land.

### Confirmed-clean (re-verified 2026-05-08)

- All 17 Phase 8 vendor adapters carry literal
  `lifecycle: VendorLifecycle.documented` in their
  `@IntegrationAdapter()` annotation. OAuth refresh closures wired
  for the 11 OAuth vendors; the 6 non-OAuth (ADP/mTLS, Tock/static
  key, Push/bearer, OpenTable/internal, SevenRooms/transport,
  Agendrix/static key) intentionally have no closure. Test coverage:
  4-6 unit tests per vendor.
- No operator-scoped Postgres fact table uses
  `TIMESTAMP WITHOUT TIME ZONE`.
- No `package:postgres` imports outside
  `lib/infrastructure/persistence/postgres/` or `tool/advisor_proxy/`.
- All RLS policies (post-`202604280001`) route through the four
  wrapper functions `app_current_operator()`,
  `app_current_location()`, `app_current_actor_user()`,
  `app_acting_as_operator()` (all `STABLE LEAKPROOF PARALLEL SAFE`).
- `tool/rls_policy_lint.dart` exists (251 LOC) with allowlist; the
  prior contract note implying it was missing is stale.
- `proxy_requests.idempotency_key` UNIQUE constraint present at
  `db/migrations/202604250005_advisor_cloud_foundation.sql:198`.
- No new `demo_*` SQLite or Postgres tables (only the documented
  `demo_mode_state` Postgres table).
- Operator-web `UnsupportedError` calls in
  `firebase_operator_web_auth_source.dart` /
  `operator_web_auth_source.dart` are intentional (password reset
  flows are handled by Firebase action links by design), NOT gaps.

## Closeout — Phase 8 plug-and-play V1 onboarding (2026-05-07)

End-to-end V1 plug-and-play onboarding for all 17 vendors landed via
9 PRs this session. Detail + per-PR resolution notes archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md`.

PRs (chronological): #280 MFA test signature drift; #281 OAuth refresh
worker closure registry wire-in; #282 backfill worker adapter factory
wire-in (binder split); #283 per-vendor OAuth descriptors + api-key
validators; #286 operator-web route alignment + test-connection +
disconnect endpoints; #288 master analyzer sweep; #297 test-connection
executor wire-in; #298 api-key paste UX; #301 location integrations
list real projection.

Operations work remaining (P0 above, plus Cloud Run env + partner
portal redirect URI registration) gates each vendor's `*.live.sandbox`
slice firing; engineering closure is unblocked.
