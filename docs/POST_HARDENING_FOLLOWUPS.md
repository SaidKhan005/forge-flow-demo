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

**27 migrations pending Production1 apply** (`202604280014` through
`202605021900`). HARD-B/HARD-H, all 11A admin column additions,
B41/B42/B43, the audit privacy role, Phase 9.0 Sigma.l (RLS depth on
`proxy_requests` + `feature_flags`), the `forge_admin` feature-flag grants,
the 11A health AGE graph bootstrap/runtime grants, the HARD-B
auth-login-attempts index rekey, and the 11A.3a corpus-ledger seed are
queued.

Files to apply, lex order:

```text
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
202605010100_phase_9_0sigma_f_audit_logs_cutover_flag.sql        (9.0 Sigma.f)
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
202605021500_phase_9_0sigma_l_rls_depth.sql                      (9.0 Sigma.l)
202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql    (11A.7)
202605021700_phase_11A_health_age_graph_bootstrap.sql            (11A health)
202605021710_phase_11A_health_age_runtime_grants.sql             (11A health)
202605021800_hardening_auth_login_attempts_index_rekey.sql       (HARD-B)
202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql (11A.3a)
```

**Action:** schedule a Production1 apply event under
`runbooks/phase_9_production1_migration_apply_runbook.md`. No new runbook is
needed; the lex-order pattern is the same.

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
