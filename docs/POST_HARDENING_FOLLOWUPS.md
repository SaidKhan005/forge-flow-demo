# Post-Hardening Follow-ups

Updated: 2026-05-06 (B1 data-accuracy migration renumbered to `…1701_…`; Phase 8 first-connection backfill job seam added at `…1800_…`; Phase 11W.7 operator account write-fields added at `…07000000_…`; Phase 8 timing-provenance FK posture flipped to `ON DELETE SET NULL` at `…08000000_…`).
Origin: 2026-05-02 deep audit. Resolved items in `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`. Staging remediation evidence in `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`.

## P0 - Production1 Migration Apply Gap

**13 migrations pending Production1/staging apply** (chronological):

| Migration | Origin | Staging status |
|---|---|---|
| `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` | 11A.5 Debug Console SELECT grant | applied + Browser Use verified 2026-05-03 |
| `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` | 11A operator/location admin DML | applied + Browser Use verified 2026-05-04 |
| `202605060000_mobile_push_notifications.sql` | Mobile FCM/APNs + delivery sidecar | code-ready; needs staging apply + connected-device proof |
| `202605060000_phase_business_timing_live_schema.sql` | `business_timing_profiles` + `open_shift_snapshots` | code-ready; needs staging/review apply |
| `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql` | 11A.14 audited support actions | code-ready (additive seed + grants) |
| `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql` | 5-index `operator_id` rekey (2026-05-06 audit follow-up) | code-ready; uses `CONCURRENTLY` |
| `202605061600_phase_11W_5_team_audit_log_export_key.sql` | 11W.5 `team.audit_log.export` key + grants | code-ready |
| `202605061700_hardening_audit_anchor_daily_schedule.sql` | Hardening Wave B3 daily pg_cron tick `forge_audit_anchor_daily` at 02:00 UTC (NOTIFY-only kickoff; punchlist §5) | code-ready |
| `202605061700_phase_8_timing_provenance_shift_records.sql` | Phase 8 timing provenance keys for closed/live shift rows | code-ready |
| `202605061701_phase_8_data_accuracy_service_period_settings.sql` | Hardening Wave B1 keyed Data Accuracy child table per `(operator_id, location_id, service_period_key, effective_at_business_date)` (replaces hardcoded `covers_source_lunch`/`_dinner`/`_late_night` columns; legacy columns kept as read-only fallback). Renumbered 2026-05-06 from `202605061700_…` to break same-second prefix collision. | code-ready |
| `202605061800_phase_8_first_connection_backfill_jobs.sql` | Phase 8 mobile core first-connection durable backfill jobs: server-side enqueue/claim/status seam for the 60-day backfill path. | code-ready |
| `202605070000_phase_11W_7_operator_account_fields.sql` | Phase 11W.7 / Wave A2 operator-web Account editor write-fields on `public.operators` (`logo_url`, `locale_tag`, `week_start_day`, `rollover_hour`) plus format CHECK constraints + `business_name` length CHECK. Additive + default-backed; existing rows preserved. | code-ready |
| `202605080000_phase_8_timing_provenance_fk_posture.sql` | V1.B Phase 8 timing-provenance FK posture flip: drops + re-adds `shift_records_business_timing_profile_fk`, `shift_records_business_timing_profile_version_fk`, and `open_shift_snapshots_profile_version_fk` with `ON DELETE SET NULL NOT VALID` so closed historical truth survives `business_timing_profiles` deletion (Operator Web timing editor lifecycle). Validation deferred to a future maintenance window. | code-ready |

**Action:** apply all 13 in next Production1 event per `runbooks/phase_9_production1_migration_apply_runbook.md`. Until applied + verified, the corresponding feature is **staging-ready only**.

## P1 - Live Admin Operational Gates

The staging admin smoke surfaced live actions that code cannot complete
without operator-held secrets and action-time approval. Resolved graph
candidate packaging and staging audit-anchor remediation are archived in the
2026-05-03 execution note.

- Provider credentials / KMS rollout: use
  `runbooks/admin_provider_credentials_kms_rollout_runbook.md`.
- Admin browser QA: use the static-build path in
  `runbooks/admin_console_browser_qa_runbook.md`; treat debug web-server
  bootstrap failures as dev-workflow noise unless the static build also fails.

## P1 - Business Timing / Live Shift Architecture Follow-ups

The 2026-05-06 audit found the product direction sound but identified contract
work that must land before live in-progress Shift is claimed:

- Keep `8.spine-bridge-sink-fanout` closed-truth only. Live
  `OpenShiftSnapshot` production belongs in explicit `8.spine-bridge-live`.
- Add keyed per-service-period Data Accuracy settings before enabling a fourth
  or non-canonical service period key for an operator.
- Persist/use stable timing profile and service-period keys for bucketed live
  and closed facts so label changes do not rewrite history.
- Treat Operator Web as the normal timing editor and F&F Operations Console as
  audited support override only.

### Phase 8 Lane 0 timing-provenance carry-forward (2026-05-06)

Lane 0 (`db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql`)
landed the additive timing triplet on closed `shift_records` plus
`business_timing_profile_version_id` on `open_shift_snapshots`. Lanes 1
(writer/builder + aggregator), 2 (`ClosedTimingLabelResolver` wired into
Variance/History/Learn read services), 3 (`OpenShiftSnapshotProjector`),
and the live half of Lane 4 (`_openShiftSnapshotJson` mapper +
SELECT now emit the triplet) all landed in commits
`da1484a0`, `976e8d7e`, `c9a3de6b`, `e3c196bf`. Four follow-ups
remain:

- **[~] Closed-row proxy gap — IN FLIGHT (V1.A).** `_shiftRecordJson`
  and the paired `fetchShiftRecords` SELECT in
  `tool/advisor_proxy/proxy_bootstrap.dart:1224-1259` and
  `:1483-1521` do NOT include
  `business_timing_profile_id`,
  `business_timing_profile_version_id`, or
  `service_period_key`. Until that lands, every closed row pulled by the
  mobile sync arrives with a null triplet, and Lane 2's
  `ClosedTimingLabelResolver` falls back to mutable `daypart` for
  display — i.e. Lane 2 is wired but inert on mobile. Mirror the
  open-snapshot SELECT/mapper change that already landed for
  `_openShiftSnapshotJson`. **In flight via V1.A
  `8.closed-row-proxy-timing-provenance` per
  `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`.**
- **[x] FK posture on closed `shift_records` — CLOSED via V1.B
  (`db/migrations/202605080000_phase_8_timing_provenance_fk_posture.sql`).**
  Lane 0 added `shift_records_business_timing_profile_fk` and
  `shift_records_business_timing_profile_version_fk` (both `NOT VALID`) with
  the default `ON DELETE NO ACTION`. The `core_app_architecture.md` "What
  never rewrites" non-negotiable says closed historical truth must outlive
  profile mutation; default `NO ACTION` blocked any
  `business_timing_profiles` delete the moment a closed row referenced the
  profile, conflicting with the Operator Web timing editor's expected
  lifecycle. The follow-up migration drops + re-adds the two `shift_records`
  FKs and the matching `open_shift_snapshots_profile_version_fk` with
  `ON DELETE SET NULL NOT VALID`, so profile deletion degrades the row to a
  null timing triplet (legacy `daypart` still drives display) and survives.
  Validation is deferred to a future maintenance window. Refs:
  `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql:39-77,
  101-108`,
  `db/migrations/202605080000_phase_8_timing_provenance_fk_posture.sql`.
- **Drop the version-equals-profile CHECKs before any future Phase 8R
  divergence.** Lane 0 added
  `shift_records_timing_version_profile_match_check` and
  `open_shift_snapshots_timing_version_profile_match_check`
  (`version_id IS NOT DISTINCT FROM profile_id`, both `NOT VALID`) as the
  V1 enforcement of decision A. When Phase 8R introduces a real
  `business_timing_profile_versions` table and code starts writing a
  divergent `version_id`, both CHECKs must be dropped first; otherwise the
  first divergent INSERT fails. Refs:
  `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql:51-66,
  113-129`.
- **Same-second prefix collision resolved 2026-05-06.** Three migrations
  briefly shared the `202605061700_` timestamp slot
  (`..._hardening_audit_anchor_daily_schedule.sql`,
  `..._phase_8_data_accuracy_service_period_settings.sql`, and
  `..._phase_8_timing_provenance_shift_records.sql`). The data-accuracy
  entry (most recent — added by `4655b484`, none of the three applied to
  staging or production yet) was renumbered to
  `202605061701_phase_8_data_accuracy_service_period_settings.sql` to
  restore deterministic deploy ordering across environments. The
  audit-anchor + timing-provenance basenames stay at `…1700_…` because
  the timing-provenance basename is referenced from
  `scripts/postgres_staging_setup.ps1` and
  `docs/_walkthroughs/8.timing-provenance-closed.md`, and the
  audit-anchor basename is referenced from
  `test/infrastructure/persistence/postgres/audit_anchor_cron_schedule_test.dart`.

## P2 - Test Coverage Gaps Remaining

| Surface | LOC | Test files | Coverage |
|---|---|---|---|
| `lib/admin/services/operator_location_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| `lib/admin/services/pricing_tier_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| `lib/admin/services/integration_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| 18 of 29 postgres repositories | varies | 10 covered (L2 + L4 batch 2) | partial; chip away during routine slices |

Test parcels for MFA, postgres repo batch 1/batch 2, and the Phase 11b
retrieval assumption are archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`. Live status
is the remaining table above.

## P3 — Verified-keep API surfaces (verified 2026-05-06, Wave B4)

The 2026-05-02 audit flagged these as "unused public classes." The
2026-05-06 verification sweep (Wave B4) found each one is the return
type of a unit-tested method on a sibling class in the same file —
none are deletable in isolation:

- `AuditLogExportResult` — return type of `AuditLogCsvExport.export(...)`;
  tests in `test/admin_console_test.dart` consume `.csvBody`,
  `.rowCount`, `.exportEvent`.
- `MfaOverrideChange` — value type of `MfaPolicyEditorState.diff()`'s
  `Map<String, MfaOverrideChange>` return; consumed by
  `test/admin_console_test.dart`.
- `MatrixCellChange` — element type of
  `RolePermissionMatrixController.diff()`'s `List<MatrixCellChange>`
  return; tests access `.roleId`, `.permissionKey`, `.from`, `.to`.
- `CorpusCloudLoadResult` — return type of
  `AdvisorCorpusAdminService.attemptCloudLoad(...)`; reachable from
  the ADVISOR CORPUS Settings section
  (`lib/screens/settings/settings_advisor_corpus_section.dart`,
  wired in `lib/forge_flow_app.dart`) and tested in
  `test/advisor_corpus_admin_service_test.dart`.

**Status:** keep all four. They are tested public-API shapes awaiting
proxy / production wiring, not dead code. Re-evaluate only if the
sibling method (`export`, `diff`, `attemptCloudLoad`) is itself
removed in a wider lane.
