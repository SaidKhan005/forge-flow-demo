# Post-Hardening Follow-ups (2026-05-02)

Audit log of items surfaced by the 2026-05-02 deep audit that were **not**
in scope of HARD-A→HARD-H but warrant attention before launch. Each item
has a single owner-suggested next-action; none are launch-blocking unless
flagged.

PRs #50–54 (`7.58.0`/`11A.3a`/`9.0Σ.l`/L4 admin idempotency/L5 MFA tests)
landed 2026-05-02 PM and resolved P1 (RLS depth), P2 (idempotency), P2
(11A.3a operator-picker), and P2 (MFA test coverage to 87.3%).

PRs #55–59 (`7.58.UX.5`/`10.5.0`/L2 postgres repo tests/L4 runbook
companion/L5 MFA adapter parcel) landed 2026-05-02 follow-up: P1 runbook
companion **RESOLVED**; P2 test coverage parcels added (5 postgres repos
+ 2 MFA adapter test files, 82 new tests across the sprint); new
walkthroughs `7.58.UX.5.md` + `10.5.0.md` shipped. Phase 7.58 has zero
DRIFT. PRs #60–66 (`10.5.1` bucketing engine, `7.61.0` driver-key audit, `10a.0` realtime scaffold, B44 graph producer family, postgres repo tests batch 2, admin MFA challenge parity, staging admin stabilization) landed 2026-05-02 evening and closed the L2 batch-2 test parcel.

Resolved items archived to `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`. Open items below are the remainder.

## P0 — Production1 migration apply gap

**22 migrations pending Production1 apply** (`202604280014` through
`202605021500`). HARD-B/HARD-H, all 11A admin column additions,
B41/B42/B43, the audit privacy role, and Phase 9.0Σ.l (RLS depth on
`proxy_requests` + `feature_flags`) are queued.

Files to apply (lex order):

```
202604280014_phase_9_0sigma_h2_audit_privacy_role.sql            (B46)
202604290000_phase_9_b41_service_principal_issue_permission.sql  (B41)
202604290100_phase_11A_1_operators_suspended_at.sql              (11A.1)
202604290101_phase_9_hierarchy_access_wiring.sql                 (9.0)
202604300000_phase_9_mfa_factor_removal_requests.sql             (9.0)
202604300001_phase_9_mfa_recovery_request_attempts.sql           (9.0)
202604300002_phase_9_mfa_hardening_launch_roles.sql              (9.0)
202605010000_phase_11A_3a_corpus_versions_ledger.sql             (11A.3a)
202605010000_phase_11A_4_provider_credentials.sql                (11A.4)
202605010001_phase_9_b4_role_audit_log_operator_id.sql           (9.0 B4)
202605010100_phase_9_0sigma_f_audit_logs_cutover_flag.sql        (9.0Σ.f)
202605020000_phase_11A_b42_proxy_migrations_applied.sql          (B42)
202605020001_phase_11A_3b_graphify_review_audit.sql              (11A.3b)
202605020001_phase_11A_4b_gemini_provider_kind.sql               (11A.4b)
202605020100_phase_11A_b43_cache_telemetry_v2.sql                (B43)
202605020200_phase_11A_4c_kms_rollout_flags.sql                  (11A.4c)
202605020300_phase_9_firebase_uid_text.sql                       (9.0)
202605020400_phase_11A_7_feature_flags_admin_columns.sql         (11A.7)
202605020452_hardening_auth_login_attempts.sql                   (HARD-B)
202605020500_hardening_auth_rls_to_wrappers.sql                  (HARD-F)
202605021000_phase_hardh_admin_idempotency.sql                   (HARD-H)
202605021500_phase_9_0sigma_l_rls_depth.sql                      (9.0Σ.l)
```

**Action:** schedule a Production1 apply event under existing runbook
(`runbooks/phase_9_production1_migration_apply_runbook.md`) — does NOT
require a new runbook; the lex-order pattern is the same.


## P2 — Test coverage gaps (open table)

| Surface | LOC | Test files | Coverage |
|---|---|---|---|
| `lib/services/mfa/` | 2,933 | 5 (`test/mfa/`) + 4 top-level | **>90%** est. (parcels closed 2026-05-02) |
| `lib/admin/services/operator_location_admin_gateway.dart` | 311 | 1 (added L4) | partial — gateway tests landed PR #53 |
| `lib/admin/services/pricing_tier_admin_gateway.dart` | 311 | 1 (added L4) | partial — gateway tests landed PR #53 |
| `lib/admin/services/integration_admin_gateway.dart` | 311 | 1 (added L4) | partial — gateway tests landed PR #53 |
| 18 of 29 postgres repositories | varies | 10 covered (L2 + L4 batch 2) | partial — chip away during routine slices |

Test parcels for MFA + postgres repo batch-1/batch-2 + Phase 11b retrieval
assumption are archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md` for the
full narrative. Live status is the table above.

## P3 — Unused public classes (4)

- `AuditLogExportResult` (`lib/services/admin/audit_log_csv_export.dart`)
- `MfaOverrideChange` (`lib/services/admin/mfa_policy_editor_controller.dart`)
- `MatrixCellChange` (`lib/services/admin/role_permission_matrix_controller.dart`)
- `CorpusCloudLoadResult` (`lib/services/advisor_corpus_admin_service.dart`)

**Action:** delete on next sweep through each file, or leave in place if
they're forward-compatible API shapes that haven't been wired yet.

## P3 — `admin_request_idempotency` vs `admin_idempotency_cache` name drift

HARD-D's contract appendix referred to a future
`admin_idempotency_cache` table; HARD-H actually shipped
`admin_request_idempotency`. Functionality matches; only the name
diverges. Update the HARD-D contract appendix to use the shipped name on
the next contract refresh (low priority — both contracts are now closed
authority).

