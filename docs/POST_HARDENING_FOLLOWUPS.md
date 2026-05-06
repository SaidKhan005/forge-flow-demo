# Post-Hardening Follow-ups

Updated: 2026-05-06.
Origin: 2026-05-02 deep audit. Resolved items in `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`. Staging remediation evidence in `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`.

## P0 - Production1 Migration Apply Gap

**9 migrations pending Production1/staging apply** (chronological):

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

**Action:** apply all 9 in next Production1 event per `runbooks/phase_9_production1_migration_apply_runbook.md`. Until applied + verified, the corresponding feature is **staging-ready only**.

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
