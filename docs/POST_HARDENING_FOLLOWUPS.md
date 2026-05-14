# Post-Hardening Follow-ups

Updated: 2026-05-08 (post-audit remediation wave landed: 9 lanes
merged across PRs [#417](https://github.com/SaidKhan005/forge-flow-demo/pull/417)–
[#426](https://github.com/SaidKhan005/forge-flow-demo/pull/426). 4 of
5 P1 audit-addition items closed; the AI-frozen `advisor_proxy.dart`
placeholder strings remain on the freeze-thaw checklist. P2
broader-bare-catch pattern partially closed for 3 files (`tool/advisor_proxy/advisor_proxy.dart`'s
16 sites still open). 2026-05-08 multi-agent deep-dive sweep added 7
new findings in the "Audit additions — 2026-05-08" section;
postgres-repo coverage line corrected from "18 of 29 / 10 covered"
to actual "27 of 47 / 20 covered"; admin hierarchy lane excluded —
separate team). Prior update 2026-05-07 (Phase 8 plug-and-play V1 closeout —
resolved operator-self-service / backfill-factory / OAuth-refresh-closures /
location-integrations-list / test-connection / api-key paste / route
alignment / binder split / analyzer sweep gaps archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md`).
Earlier closeouts: `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`
and the 2026-05-07 closeout addendum at the bottom of this file.
Origin: 2026-05-02 deep audit.

## P0 — Webhook signature ordering (2026-05-09 security triage)

Forged-signature webhook POSTs to `/v1/webhooks/{vendor}/{operator}/{location}`
trigger a Postgres SELECT (`vendor_credentials` lookup for the signing secret)
BEFORE any HMAC verification, then leak the raw `Exception.toString()` +
first stack frame in the response body via the
`tool/advisor_proxy/admin_integrations_routes.dart:248` catch-all. Confirmed
schema-info disclosure + DOS amplification on connection pool. Fix slice
proposal + 9-leak-site inventory: `docs/archive/_execution/2026-05-09_security_finding_webhook_signature_ordering.md`.

## P0 — Production1 Migration Apply Gap

**49 migrations pending Production1 apply** (chronological). The queue now
runs through `202605150000_phase_r2l_default_role_catalog_v2.sql`; staging/preview
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
| `202605081100_partman_maintenance_hourly_cron.sql` | Register hourly pg_partman audit-log maintenance cron | code-ready |
| `202605081300_seed_kms_rollout_flags_default_disabled.sql` | Seed default-disabled KMS rollout feature flags after sentinel-operator change | code-ready |
| `202605082000_user_pii_erasure_requests.sql` | Durable admin PII-erasure request ledger with 24h reversal window | code-ready |
| `202605082100_phase_10a_3_retention_sweep_in_db_followup.sql` | Register bounded event-outbox retention sweep in Azure split-DB cron topology | code-ready |
| `202605082200_admin_hierarchy_lifecycle.sql` | Admin hierarchy suspend/delete lifecycle columns and permission gates | code-ready |
| `202605121200_admin_hierarchy_scoped_data_polling.sql` | Admin hierarchy scoped Data Accuracy and Polling Setup overrides/effective views | code-ready |
| `202605131000_admin_audit_log_actor_reason_contract.sql` | Admin audit-log actor-kind aliases plus required forge_admin admin_reason | code-ready |
| `202605131010_admin_audit_logs_business_date.sql` | Admin audit-log restaurant-local business_date projection | code-ready |
| `202605131020_admin_hierarchy_lifecycle_access_hardening.sql` | Admin hierarchy lifecycle access refresh, active uniqueness, and direct target guards | code-ready |
| `202605131030_b11_1_auth_handoff_codes.sql` | Lane B B11.1 mobile→web handoff code mint/redeem (operator-scoped, RLS, 60s TTL, addendum A1 — replaces JWT-in-URL) | code-ready |
| `202605131400_b11_2_auth_step_up_challenges.sql` | Lane B B11.2 RFC 9470 step-up challenge ledger (operator-scoped, RLS, 5-minute TTL, route+user binding for replay protection) | code-ready |
| `202605131500_b10_1_vendor_applicability.sql` | Lane B B10.1 vendor applicability temporal table (global defaults + operator overrides, RLS via app_current_operator, JSONB schema guarded in app code) | code-ready |
| `202605131500_b5_b_catalog_tri_mirror.sql` | Lane B B5.b account/timing permission catalog tri-mirror (`account.configure`, `business_timing.configure`) plus owner/admin grants | code-ready |
| `202605131600_b2_1_default_role_catalog_versions.sql` | Lane B B2.1 Default Role catalog versions table + `operators.default_role_catalog_version_id` pointer (global F&F-wide catalog, no RLS) | code-ready |
| `202605131700_c_1a_email_event_provider_id.sql` | Lane C C-1a `email_event.provider_event_id` column + partial UNIQUE INDEX `WHERE provider_event_id IS NOT NULL` (additive expand; backs C-1 receiver's `ON CONFLICT DO NOTHING` for SendGrid event dedupe; no RLS change) | code-ready |
| `202605131800_c_7a_recovery_codes_viewed_at.sql` | Lane C C-7a `mfa_factors.recovery_codes_viewed_at timestamptz NULL` (additive expand; unblocks Codex's C-7 Adaptive 2FA button compute over `(session.mfaEnrolled, factor_count, recovery_codes_viewed_at)`; no new index, no RLS change) | code-ready |
| `202605131900_c_2_d_vendor_sync_outage_state.sql` | Lane C C-2-D `vendor_sync_outage_state` per-(operator_id, location_id, connection_id) state surface for the first-failure-of-outage detector that gates the `vendor_sync_error_alert` email (one row per outage window; cleared on next `poll_success`; per-tenant RLS mirroring `connector_sync_log`) | code-ready |
| `202605140000_w_3_self_profile_perm_key.sql` | Wave 2 W-3 `team.users.self_update` permission key + baseline grants to every seeded operator role and super_admin. Backs the new `PATCH /v1/auth/self/profile` self-service profile editor on operator-web and admin My Account surfaces. | code-ready |
| `202605142100_phase_R_1L_roles_schema_rewrite.sql` | Wave 2 R-1L Roles schema rewrite: `permission_keys.product_label` + `category_label` + `scope_kind` (CHECK `org_wide`/`location_scoped`/`either`) + `implies text[]` columns added NULLABLE with inline backfill; defers NOT-NULL flip to R-1L-FU follow-up per expand-contract discipline. Backfill mirrors `lib/services/auth/custom_role_validator.dart`'s `kOrgWidePermissionKeys` + `kViewRequiredForWrite` + `kTeamUsersWriteKeys`. Runtime mirror at `lib/auth/permission_key_metadata.dart` is NOT-NULL-at-source via `tool/permission_key_lint.dart` METADATA pass. Resolver imply walk in `lib/auth/permission_resolution.dart`. | code-ready |

**Action:** apply all 48 in next Production1 event per
`runbooks/phase_9_production1_migration_apply_runbook.md`. Until applied
+ verified, the corresponding feature is **staging-ready only**.

## P1 — B11.1 Idempotency-Store Convention (deep-audit follow-up)

**Origin:** Wave completion deep audit 2026-05-13
(`docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md` finding #4).
B11.1 (PR #512, merged 2026-05-12) introduced `handoff_codes` — operator-scoped
mint/redeem ledger with 60s TTL. The deep audit flagged that the
**idempotency-store convention is not yet codified**: subsequent slices
(B11.2's `auth_step_up_challenges`, future `handoff_code`-shaped tables) have
mirrored the idiom by hand, with no shared abstraction, no lint enforcing
the shape (PK+operator_id+TTL+consumed_at+RLS+operator-leading indexes),
and no convention doc.

**Why this is a followup, not a slice yet:** no current slice in the ledger
touches the surface. The convention is best codified the next time a slice
adds a third idempotency-store table (or sooner if drift becomes apparent).
A new lint enforcing the shape can ship alongside that slice.

**Scope when a slice picks this up:**
1. Doc the convention in `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
   (or a new contract doc) — shape: `(opaque_id text PK, operator_id uuid, ...)`
   + RLS via `app_current_operator()` wrapper + operator-leading B-tree
   indexes + TTL CHECK + base64-url id shape CHECK + idempotent DDL.
2. Add a lint at `tool/idempotency_store_convention_lint.dart` that scans
   `db/migrations/*.sql` for tables matching the shape and fails CI when
   any of the 6 invariants are missing.
3. Optionally extract a shared Dart abstraction (`IdempotencyStoreGateway<T>`)
   that future stores bind to (mirror `OperatorScopedRepository<T>` pattern).

**Lock until then:** new idempotency-store tables landing before this slice
must mirror the B11.1 / B11.2 idiom by hand; orchestrator audit must spot-check
the 6 invariants against the migration on every such slice.

## P1 — Doc-Drift + Nits Batch (deep-audit P2/P3 holding line)

**Origin:** Wave completion deep audit 2026-05-13. The audit's P2 doc-drift
items (4) and P3 nits (2) do not warrant their own ledger rows; they get
fixed opportunistically when someone is next in the relevant file.

**Reference:** `docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md`
sections P2 + P3 (full enumeration with file:line + suggested action per
item). Pick up alongside any unrelated slice that touches those files.

## P1 — Soak Heap-Snapshot Uploader: swap GCS → Azure Blob (A11.2 follow-up)

**Origin:** A11.2 (PR #537, merged 2026-05-13 at `8463d56b`) added a
storage-agnostic `HeapSnapshotUploadTarget` interface plus a concrete
`GcsHeapSnapshotUploadTarget` implementation (raw GCS REST PUT via
`dart:io HttpClient` + bearer-token auth). The slice doc specified GCS;
F&F's only other cloud-storage client is Azure Blob
(`tool/audit_anchor/azure_blob_client.dart`).

**Operator decision (2026-05-13):** F&F will not run two cloud-storage
backends. The GCS implementation must be **replaced** with an Azure Blob
implementation before any soak run actually uses uploads.

**Binding constraint:** the GCS env vars (`GCS_BUCKET_HEAP_SNAPSHOTS`,
`GCS_BEARER_TOKEN`) MUST stay unset on every host until this swap lands.
The uploader is inert when unconfigured (one "skipped" log line at start);
that inert state is the safety guarantee until the Azure swap ships.

**Follow-up slice scope:**
- Add `AzureBlobHeapSnapshotUploadTarget implements HeapSnapshotUploadTarget`
  modeled on `tool/audit_anchor/azure_blob_client.dart` (workload-identity-
  federation flow analogous to the audit-anchor pattern).
- Switch the default binding in `tool/pressure/p4_heap_snapshot_uploader.dart`
  from `GcsHeapSnapshotUploadTarget` to `AzureBlobHeapSnapshotUploadTarget`.
- **Delete** `GcsHeapSnapshotUploadTarget` and the GCS env-var references —
  no two-backend codebase. The storage-agnostic interface stays as the
  load-bearing artifact.
- Update tests (the existing `_StubUploadTarget` in
  `test/pressure/p4_heap_snapshot_uploader_test.dart` already implements
  the interface — should keep passing without change).
- Add the new env vars (`AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER`, etc.) to
  `runbooks/cloud_run_env_vars.md` once the workload-identity flow is wired.

**Authority anchors:**
- `tool/audit_anchor/azure_blob_client.dart` (the canonical F&F Azure
  Blob pattern to mirror)
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_537_a11_2_soak_harness_extensions_audit.md`
  (audit doc that flagged the decision)
- This entry.

**Not blocking:** A11.2's other deliverables (fd watcher, p3c CLI flags)
are independent of this swap and stay live on master.

## P1 — Live Admin Operational Gates

The staging admin smoke surfaced live actions that code cannot complete
without operator-held secrets and action-time approval. Resolved graph
candidate packaging and staging audit-anchor remediation are archived in
`docs/archive/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`.

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
- `lib/screens/settings/settings_wage_authority_section.dart:52,57,73,76`
  — widget calls `SqliteRestaurantScopeRepository.instance` and
  `SqliteWageRoleRowRepository.instance` directly (`getActiveRestaurantId`
  at `:52`, `getRows` at `:57`, `upsertRow` at `:73`, `deleteRow` at
  `:76`). Action: route through a service that owns the SQLite calls.

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
- `tool/advisor_proxy/advisor_proxy.dart` — 18,871 lines (per A3.1 measurement 2026-05-13; audit cited 14,500; +4,371 net since 2026-05-06; bleed-stop ceiling 19,071 with 200-line headroom now in force via `tool/advisor_proxy_size_lint.dart`). Debt is reaccumulating faster than CODE_HEALTH lanes can clear it, but the A3.1 ratchet now prevents further routine growth.

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

### P1 — `audit_logs_repository.dart` bypasses `OperatorScopedRepository` ✅ FIXED 2026-05-08 ([#424](https://github.com/SaidKhan005/forge-flow-demo/pull/424))

`lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart`
was a stateless writer that took `operatorId` as a caller-supplied
parameter — primary-defense bypass for the operator-scoped
`audit_logs` table.

Resolution: chose **Option B (defense-in-depth)** rather than
extending `OperatorScopedRepository`, because the writer's
atomic-with-business-write contract requires it to run inside the
caller's transaction (extending the base would have forced its own
`withTenant` wrapper and broken the same-commit-boundary semantics).
`writeRow` now reads `current_setting('app.operator_id', true)` from
the executor BEFORE binding any insert SQL and throws
`AuditLogsTenantMismatchError` when the parameter disagrees with the
GUC. When the GUC is unset (the `runAsSystem` admin path, where
`forge_admin BYPASSRLS` is the gate), the parameter is accepted —
preserving `auth_events_audit_repository.insertSystemEvent` and
`invited_user_activation_repository` paths that already use
`withSystem`. Verified all 10 caller sites already pass the matching
operator id; signature unchanged. Coverage:
`test/infrastructure/persistence/postgres/repositories/audit_logs_repository_test.dart`
(happy path, mismatch throws before insert, GUC-unset accepts param).

### P1 — 4 admin integration routes missing idempotency guard ✅ FIXED 2026-05-08

`tool/advisor_proxy/admin_integrations_routes.dart` writes did not
extract `Idempotency-Key` or consult the cross-tenant
`admin_request_idempotency` ledger despite the file header claiming
they did. Affected (now fixed):

- `POST /v1/admin/integrations/oauth/{vendor}/start`
- `POST /v1/admin/integrations/{vendor}/connect-key`
- `POST /v1/admin/integrations/{vendor}/test-connection`
- `POST /v1/admin/integrations/{vendor}/disconnect`

Resolution: `Phase80IntegrationRoutes` now accepts an optional
`AdminRequestIdempotencyStore` (wired in production via
`phase_8_production_binder.dart` from `productionBindings
.adminRequestIdempotencyStore`). Each of the 4 write routes now:
missing key → 400 `missing_idempotency_key`; duplicate key →
cached replay; new key → reserve → run → cache. Body-hash mismatch
on the same key → 409 `idempotency_key_conflict`. Coverage:
`test/tool/advisor_proxy/admin_integrations_idempotency_test.dart`.

### P1 — `advisor_proxy.dart:9105-9106` hardcoded prompt placeholders ⏸️ DEFERRED (AI freeze)

Moved to phase_11b plan freeze-thaw checklist (2026-05-08). See
`docs/archive/phases/phase_11b/phase_11b_advisor_ux_plan.md` "Freeze-thaw
pre-conditions (must close before unfreezing 11b)".

### P1 — Demo-mode banner promised by architecture but never wired ✅ FIXED 2026-05-08 ([#426](https://github.com/SaidKhan005/forge-flow-demo/pull/426) — slice `8.demo-mode-banner`)

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
change needed.

Resolution: shipped via PR #426 with `lib/widgets/demo_mode_banner.dart`,
`lib/state/demo_mode_state_notifier.dart`, AppShell mount in
`lib/forge_flow_app.dart` (banner stack above the IndexedStack tab
body), `Provider<SyncProxyClient?>` exposure in
`lib/forge_flow_bootstrap.dart`, walkthrough at
`docs/_walkthroughs/8.demo-mode-banner.md`, and 5 widget tests at
`test/widgets/demo_mode_banner_test.dart`. Two follow-ups punted:
(1) mobile-side vendor-connections route doesn't exist yet, so the
banner is informational-only; (2) the realtime invalidation path
uses a permissive `integrations.*` / `first_backfill.*` topic-prefix
match — tightening to a dedicated `demo_mode_state.flipped` topic
when the proxy starts publishing it would remove the redundant proxy
round-trip on unrelated integrations events.

### P1 — Two new widget→repo direct-call violations ✅ FIXED 2026-05-08 ([#419](https://github.com/SaidKhan005/forge-flow-demo/pull/419))

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

Resolution: created `lib/services/restaurant_scope_service.dart` (thin
singleton wrapper with `overrideRepositoryForTest` / `resetForTest`
seams matching the `AppNotificationService` pattern). Updated both
widget files to use `RestaurantScopeService.instance.getActiveRestaurantId()`
and dropped the direct `SqliteRestaurantScopeRepository` imports.
Coverage: `test/services/restaurant_scope_service_test.dart`. The
P2 `settings_wage_authority_section.dart` follow-up uses the same
shape — defer to a separate slice.

### P2 — Undocumented `kDemoMode` reader-side carve-out ✅ FIXED 2026-05-08 ([#417](https://github.com/SaidKhan005/forge-flow-demo/pull/417) — option 1, blessed as Carve-out #3)

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

**Resolution:** Option 1 chosen. `lib/screens/settings_screen.dart:31,374,383` carve-out is now documented as Carve-out #3 in `docs/contracts/demo_mode_contract.md` and in CLAUDE.md "Demo Mode" section (operator sign-off 2026-05-08). The two demo-only management sections (Data reset + Demo date) stay gated on `_kDemoMode` because they have no production analogue — rendering disabled UI in prod was assessed as higher risk than the documented carve-out.

### P2 — `audit_logs_repository.dart:368` style bare catches in advisor proxy ✅ PARTIAL ([#420](https://github.com/SaidKhan005/forge-flow-demo/pull/420) — 3 of 4 files closed; advisor_proxy 16 sites still open)

11 bare catches converted via PR #420 across `auth_session_notifier.dart`,
`tenant_transaction.dart`, and `package_postgres_executor.dart`.

**Still open:** the 16 bare catches in `tool/advisor_proxy/advisor_proxy.dart`.
Moved to `docs/phases/proxy_split/proxy_split_plan.md` "Pre-Split
Cleanup" (2026-05-08) — the monolith is too risky for a one-shot
agent and the split phase is the natural home.

### P3 — `docs/_execution/` retirement window opened 2026-05-12 ✅ FIRST SWEEP COMPLETE

**`docs/_execution/` retirement window opens 2026-05-12.** The bulk of
the 2026-05-03/-04/-05/-06 closeouts cross the 7-day-since-phase-close
threshold (per CLAUDE.md "Phase Doc Hygiene") on 2026-05-12. Sweep
candidates: ~25-30 files including the Phase 8 / 8R / 8.S / 10a / 11A
foundation / 11W proofs. Action: review each file, confirm the
underlying phase is closed, retire to `docs/archive/_execution/` or
`docs/archive/phases/` as appropriate.

**Resolution (2026-05-13):** First-pass sweep landed via PR #539 → `d1c2e167` (41 archive files deleted: 3 in `archive/internal/`, 38 in `archive/_execution/`, all closed-PR proofs / one-off snapshots / "CLOSED" dispatch plans, zero-reference verified per orchestrator sub-agent's per-file grep). Git history preserves all deleted content. Remaining `docs/_execution/` candidates (any still-active sprint plans that have since closed) get swept opportunistically as their phase docs retire.

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

## Wave bugs surfaced 2026-05-13 by local apply (P1 — would block Production1)

Surfaced while applying the wave's 125 migrations against a fresh local
Postgres for happy-state demo validation (see
[`runbooks/local_full_stack_setup_runbook.md`](../runbooks/local_full_stack_setup_runbook.md)).
Both are CI-dark-era misses — CI was gated to `workflow_dispatch` only since
2026-05-12, so neither was caught at PR time. Each would fail on staging or
Production1 with the same error.

### W-1 — Legacy fact tables referenced but never created

**Migrations affected** (5):

- `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql`
  (`shift_records`)
- `db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql`
  (`shift_records`)
- `db/migrations/202605080000_phase_8_timing_provenance_fk_posture.sql`
  (`shift_records`)
- `db/migrations/202605080600_phase_8_idempotency_location_id_rekey.sql`
  (`shift_records`, `cover_facts`, `labor_punches`, `reservation_facts`)

**Failure mode:** `ERROR: relation "public.shift_records" does not exist`
(and the same shape for the other three tables) when the migration runs
`ALTER TABLE` or `CREATE INDEX`.

**Root cause:** Phase 8 framework writes vendor data into the existing SQLite
fact tables per HP #1 (`Phase 8 = pure transport swap — vendor connectors
write existing SQLite tables only; cleanup is 7.57/7.58/7.61`). The Phase 8
Postgres migrations were authored assuming Postgres-side counterparts exist,
but no migration ever runs `CREATE TABLE public.shift_records` (or the
three sibling tables). They're SQLite-only today.

**Fix path:**

1. A new Phase 8 base-schema migration must `CREATE TABLE public.shift_records (...)`,
   `public.cover_facts (...)`, `public.labor_punches (...)`,
   `public.reservation_facts (...)` BEFORE any subsequent migration alters
   them. Schema should match the columns SQLite uses today (at minimum:
   `operator_id uuid not null`, `location_id uuid not null`, `vendor_id text`,
   `vendor_entity_id text`, `business_date date`, plus the fact-specific
   columns).
2. Lex-order: the new migration must sort before
   `202605061700_phase_8_timing_provenance_shift_records.sql`. Suggested name:
   `db/migrations/202605061650_phase_8_legacy_fact_tables_postgres_create.sql`.
3. Operator-gate: schema-touching, so the slice prompt MUST be
   `[operator-approval-required]`.

**Local workaround in place:** minimal stubs (no fact-shape columns; just
the columns the migrations reference) — see step 6 of the local setup
runbook. The stubs let migrations succeed; they stay empty because demo
writes go to SQLite per HP #1.

### W-2 — `partman_maintenance_hourly_cron.sql` dollar-quote nesting

**Migration:** `db/migrations/202605081100_partman_maintenance_hourly_cron.sql`

**Failure mode:** `psql: ERROR: syntax error at or near "select" ...
LINE 16: '$$select public.run_maintenance(p_analyze := true)$$, ...`

**Root cause:** the migration wraps a `raise notice` block inside `do $$ ...
$$;`. The notice text contains `$$select public.run_maintenance(p_analyze := true)$$`
inside a single-quoted string. PostgreSQL's dollar-quote lexer does NOT
respect single-quote string boundaries — it sees the inner `$$` and
terminates the outer `do $$` block early. The rest of the body becomes
top-level statements that fail to parse.

**Fix path:** change the outer block delimiter to a unique tag, e.g.:

```sql
do $partman$
declare ...
begin
  ...
end
$partman$;
```

Single-character edit (line 50 + line 106 of the migration). No
behavioral change.

**Local workaround in place:** `sed` patch into a temp file at apply
time — see step 8 of the local setup runbook.

**Impact:** the unpatched migration will fail the very first time it
runs on staging or Production1 (already in the pending apply queue per
`runbooks/phase_9_production1_migration_apply_runbook.md`). Must be
fixed in-tree before the Production1 apply.

## Advisory-lock posture — reconciled 2026-05-13

Captured 2026-05-13 closing the C-12 wave closeout audit's finding O-5
(`docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`) and the
Migrations + Schema dimension's finding 5
(`docs/_audits/post_codex_wave/wave_audit_migrations_schema.md`).

**The finding:** V1 lean-cut #2 (project memory, locked 2026-05-03) listed
"OAuth refresh advisory lock" under *"What got pulled back"* with the trim
verdict *"Drop. One cron instance + low frequency = zero contention at V1
scale."* But two wave-scope migrations restored advisory-lock infrastructure:

- `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
- `db/migrations/202605080900_oauth_refresh_advisory_lock.sql`

And `lib/services/integration/oauth_refresh_cron.dart` carries the comment
*"pg_advisory_lock is now RESTORED per J4 race fix"*. The audit asked: memory
needs updating OR migrations need reverting.

**Reconciliation chosen — migrations stay, memory updated.** The J4
race-condition investigation (referenced in `oauth_refresh_cron.dart`) found
that some vendor token endpoints (Squarespace, certain Clover environments)
auto-revoke the earlier token when a second refresh fires before the first
commits. Two Cloud Run pods hitting the same near-expiry window can race; the
advisory lock serialises concurrent refresh per `(operator_id, vendor_id)`.
Transaction-scoped — releases on commit / rollback. The lean-cut's "one cron
instance" assumption did not survive contact with multi-pod Cloud Run deploys.
The audit-anchor advisory-lock infra is the same root cause shape (multi-pod
serialisation) for the daily anchor publisher.

**Memory doc updated** at `~/.claude/projects/.../memory/project_v1_lean_cut_2_2026_05_03.md`
(user-private, outside the repo). The lean-cut #2 entry now carries an
inline *"RESTORED 2026-05-13"* annotation pointing at a new
*"What got restored (after closer review)"* table that names both
restorations + their authority anchors (the migration files + the code
comment in `oauth_refresh_cron.dart`).

**No further code action.** Both migrations stay in the apply queue for
Production1; the runtime comment in `oauth_refresh_cron.dart` is the
authoritative rationale; the lean-cut principle ("don't reach for advisory
locks speculatively") still holds for new code — these two restorations
have concrete contention evidence + migration-resident rationale.

## Refactor phase scope (queued from 2026-05-13 post-Codex wave closeout)

Captured 2026-05-13 from the C-12 wave closeout audit
(`docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`). Both
items are governance-level decisions plus extraction work that the
post-Codex wave touched but did not resolve. The operator scoped them
into an upcoming refactor phase rather than a standalone slice; this
section is the holding pen until that phase opens.

### R-1 — Operator-web ceiling lint + `my_account_screen.dart` decomposition

**Source:** `wave_audit_operator_web_admin_ux.md` finding F-OW-1; closeout
M-2.

`lib/operator_web/screens/my_account_screen.dart` reached 2,051 LoC during
the wave (PR #624 set a soft ceiling of 1,665; C-7 PR #636 then added to it
without enforcement). The ceiling exists only in a per-PR audit doc, not in
any lint or governance doc, and the screen is becoming the operator-web
equivalent of `advisor_proxy.dart` — a god-screen accumulating MFA,
sessions, profile, and security panes that are conceptually separate.

Refactor phase work:

1. Codify the operator-web ceiling in `tool/operator_web_size_lint.dart`,
   mirroring `tool/advisor_proxy_size_lint.dart` shape (single max-lines
   constant per target file, fails build above ceiling).
2. Decompose `my_account_screen.dart` into sibling files
   (`my_account_security_pane.dart`, `my_account_mfa_pane.dart`,
   `my_account_sessions_pane.dart`, `my_account_profile_pane.dart`).
3. Keep the parent screen as a thin tab-host that mounts the panes.

Out of scope: any behavior change. Pure structural extraction + lint
codification.

### R-2 — `advisor_proxy.dart` bleed-stop discipline + helper extraction

**Source:** `wave_audit_proxy_bleed_stop.md` finding W-1; closeout M-3.

The post-Codex wave raised `kAdvisorProxyMaxLines` three times
(19,071 → 19,600 → 19,700 → 19,900) in five hours of wall time, a
cumulative +941 LoC growth on the monolith. The lint's authoritative
docstring at `tool/advisor_proxy_size_lint.dart:64-80` says explicitly
*"the monolith MUST shrink, not grow"* — the wave ratcheted the wrong
way three times. CI was dark, so each raise landed unchallenged.

The proximate cause of three of those raises (B10.1, B2.1, C-4) is the
**hybrid sibling pattern** where the router class lives in a sibling
file but the dispatcher block at `routeRequest` still carries 60-120
lines of local-state setup (`_resolveOperatorContextOrWrite`,
`_readJsonBody`, `_writeJson`, `_maybeWriteDependencyTimeout`,
`_logProxyUnhandled`, `authGuard`, `businessScopeGateway`). The
helpers are file-local to `advisor_proxy.dart`, so dispatcher blocks
cannot move out without first promoting those helpers to sibling
status.

Refactor phase work:

1. Promote the request-envelope helpers to a new
   `tool/advisor_proxy/route_helpers.dart` sibling — exported, file-
   private elements lifted as module-private with explicit `@visibleForTesting`
   where tests already depend on them.
2. Migrate the wave's three hybrid dispatchers (B2.1, B11.2, C-4) to
   the Pattern A pre-check shape (`router.tryHandle(HttpRequest)`
   returning `Future<bool>`), moving their dispatcher blocks fully
   out of `routeRequest`.
3. Lower `kAdvisorProxyMaxLines` to match the new monolith size with
   ~200 lines of forward headroom (re-instate ratchet discipline).
4. Codify in CLAUDE.md or a doctrine doc: **ceiling raises require
   explicit operator approval like auth-critical / RLS-touching /
   schema-touching / proxy-touching slices.** Without operator gate,
   the doctrine's "must shrink" intent has no enforcement.

Out of scope: route-logic changes; per-route auth posture changes; any
new routes. Pure structural extraction + discipline restoration.

### R-3 — Bundle: refactor phase opens after both above are scoped

Sequencing note: R-1 and R-2 are independent (operator-web vs proxy)
but both compete for "structural extraction without behavior change"
attention. The refactor phase doc (TBD location) will sequence them
when it opens. Operator gate on the phase opening.

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

## Pressure-preview-v1 sprint findings (2026-05-09)

The `pressure.preview.v1` sprint (Phases 1-3, PRs #428-#452) drove
verbatim vendor payload corpora through every infrastructure layer
against the preview proxy and recorded findings to feed the Phase 6
Postgres test backfill that closes the P2 coverage gap above.

Top-line severity counts: **1 P0** (schema-info leak via webhook
signature-verifier ordering bug — separate triage branch
`claude/8.gap-1.missing-webhook-signature-verifiers`), **5 P1**
(Square/LSK silent timestamp coercion; Humanity time-off-as-shift;
ADP/OpenTable/SevenRooms missing OAuth refresh closures; Humanity
inverse closure mismatch; preview-env Postgres pool exhaustion),
**6 P2** (auth-mode doc mismatches × 4; preview-env vendor-capability
registry gap × 6 vendors; preview-env schema gaps), **~25 P3** (vendor
partner-portal sourcing-gap escalation list).

Phase 6 first-wave order: `connector_backfill_job_repository.dart` (extend
existing test with Phase 3B contracts), `provider_credentials_repository.dart`
(extend with Phase 3C contracts), `weekly_plan_snapshot_repository.dart`
(new test grounded in Phase 1 fixtures), `business_timing_profiles_repository.dart`
(new test pinning rollover-hour + IANA contract every adapter depends on).

Full findings: `docs/archive/_execution/2026-05-08_pressure_preview_findings.md`.

