# Post-Hardening Follow-ups (2026-05-02)

Audit log of items surfaced by the 2026-05-02 deep audit that were **not**
in scope of HARD-A through HARD-H but warrant attention before launch. Each
open item has a single owner-suggested next action; none are launch-blocking
unless flagged.

Resolved items are archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`. The
2026-05-03 staging remediation evidence lives in
`docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`.
Open items below are the current remainder.

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

## P3 - Unused Public Classes

- `AuditLogExportResult` (`lib/services/admin/audit_log_csv_export.dart`)
- `MfaOverrideChange` (`lib/services/admin/mfa_policy_editor_controller.dart`)
- `MatrixCellChange` (`lib/services/admin/role_permission_matrix_controller.dart`)
- `CorpusCloudLoadResult` (`lib/services/advisor_corpus_admin_service.dart`)

**Action:** delete on next sweep through each file, or leave in place if
they are forward-compatible API shapes that have not been wired yet.
