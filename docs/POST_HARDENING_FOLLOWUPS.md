# Post-Hardening Follow-ups

Updated: 2026-05-07 (Phase 8 plug-and-play V1 closeout — resolved
operator-self-service / backfill-factory / OAuth-refresh-closures /
location-integrations-list / test-connection / api-key paste / route
alignment / binder split / analyzer sweep gaps archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md`).
Earlier closeouts: `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`
and the 2026-05-07 closeout addendum at the bottom of this file.
Origin: 2026-05-02 deep audit.

## P0 — Production1 Migration Apply Gap

**20 migrations pending Production1 apply** (chronological). 18 are
already staging-verified; the last 2 need an explicit operator decision
before staging-apply + Production1-apply runs.

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
| `202605080600_phase_8_idempotency_location_id_rekey.sql` | A1 idempotency rekey: add location_id, switch to vendor_modified_at >= guard | code-ready |

**Action:** apply all 22 in next Production1 event per
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
| 18 of 29 postgres repositories | varies | 10 covered (L2 + L4 batch 2) | partial; chip away during routine slices |

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
