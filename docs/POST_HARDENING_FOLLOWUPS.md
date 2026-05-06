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

## P0 - Production1 Migration Apply Gap

**3 migrations pending Production1/staging apply**:
`202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` and
`202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql`, plus
`202605060000_phase_business_timing_live_schema.sql`.
It restores read-only Debug Console request-log inspection by granting
`forge_admin` explicit `SELECT` on `public.proxy_requests`. The migration
was applied to staging and Browser Use verified on 2026-05-03; it was not
part of the 27-file Production1 apply completed earlier the same day.
The operator/location admin grant restores `forge_admin` DML on
`public.operators`, `public.locations`, and `public.operator_admins`; it was
applied and Browser Use verified on staging on 2026-05-04 after operator and
location edit routes returned live 200s.
The business timing migration adds the canonical scoped timing profile tables
and server-side `open_shift_snapshots` table; it is queued by the Business
Timing Live slice and requires staging apply before review/runtime deploys can
claim live schema parity.

**Action:** include these files in the next staged/Production1 apply event under
`runbooks/phase_9_production1_migration_apply_runbook.md`. Until that apply
and direct grant verification complete, Debug Console request-log inspection
and operator/location admin writes are staging-ready only, and business timing
live schema must not be described as review/staging-ready.

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

## P3 - Unused Public Classes

- `AuditLogExportResult` (`lib/services/admin/audit_log_csv_export.dart`)
- `MfaOverrideChange` (`lib/services/admin/mfa_policy_editor_controller.dart`)
- `MatrixCellChange` (`lib/services/admin/role_permission_matrix_controller.dart`)
- `CorpusCloudLoadResult` (`lib/services/advisor_corpus_admin_service.dart`)

**Action:** delete on next sweep through each file, or leave in place if
they are forward-compatible API shapes that have not been wired yet.
