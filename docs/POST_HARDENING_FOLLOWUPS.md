# Post-Hardening Follow-ups (2026-05-02)

Audit log of items surfaced by the 2026-05-02 deep audit that were **not**
in scope of HARD-A→HARD-H but warrant attention before launch. Each item
has a single owner-suggested next-action; none are launch-blocking unless
flagged.

## P0 — Production1 migration apply gap

**21 migrations pending Production1 apply** (`202604280014` through
`202605021000`). PROJECT_TRACKER had said 8; the actual gap is 21 because
HARD-B/HARD-H, all 11A admin column additions, B41/B42/B43, and the audit
privacy role are queued.

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
```

**Action:** schedule a Production1 apply event under existing runbook
(`runbooks/phase_9_production1_migration_apply_runbook.md`) — does NOT
require a new runbook; the lex-order pattern is the same.

## P1 — `proxy_requests` and `feature_flags` lack RLS enable

Both tables (created in `202604250005_advisor_cloud_foundation.sql`) carry
operator scope but never call `ALTER TABLE … ENABLE ROW LEVEL SECURITY`.
Today's posture is that `service_role` reads/writes them without per-tenant
isolation — protected only by application-layer scoping in
`OperatorScopedRepository`.

**Action:** new migration (slice-shaped: ~30 LOC) that enables RLS on both
and adds wrapper-based policies. Pair with index review for
`proxy_requests` (currently has no indexes; idempotency lookup is a full
table scan). Suggest sequencing as a `9.0Σ.l` patch alongside the next
prod apply event.

## P1 — Migration cutoff lint bumped, runbook needs companion update

`scripts/postgres_staging_setup.ps1` line 49 cutoff bumped to
`202605021000_phase_hardh_admin_idempotency.sql` in this audit pass. The
companion `runbooks/phase_9_production1_migration_apply_runbook.md` may
mention the older cutoff in narrative form — verify and amend before the
next apply event.

## P2 — Phase 11A.3a corpus version ledger admin (graph commit blocker)

`11A.3a` ships corpus upload / diff / rollback. **Graph candidate commit
button is disabled** because the operator-picker screen does not exist —
the screen would otherwise silently fall back to demo IDs in live mode.
Single-screen follow-up: an "operator + location" dropdown that resolves a
real `(operator_id, location_id)` pair before commit.

**Action:** ~1-day slice (`11A.3a.fix.operator-picker`) — add dropdown
screen + wire `targetOperatorId`/`targetLocationId` into corpus gateway
calls. After this, the corpus admin is launch-grade.

## P2 — Admin idempotency-key gap on three gateways

`operator_location_admin_gateway.dart`, `pricing_tier_admin_gateway.dart`,
`integration_admin_gateway.dart` `_send` methods don't send
`Idempotency-Key` headers. `corpus_admin_gateway.dart` and
`feature_flags_admin_gateway.dart` do. Network retries on the first three
risk duplicate rows.

**Action:** add a `_newIdempotencyKey()` helper to each gateway and pass
through `_send`. Then add proxy-side dedup against
`admin_request_idempotency` (HARD-H schema already supports it; the routes
just don't consume it yet). Slice-shaped: ~half a day client + half a day
proxy.

## P2 — Test coverage gaps

| Surface | LOC | Test files |
|---|---|---|
| `lib/services/mfa/` | 2,933 | **0** |
| `lib/admin/services/operator_location_admin_gateway.dart` | 311 | 0 |
| `lib/admin/services/pricing_tier_admin_gateway.dart` | 311 | 0 |
| `lib/admin/services/integration_admin_gateway.dart` | 311 | 0 |
| 15 of 29 postgres repositories | 9,327 | 0 |

**Action:** chip away during routine slices; not a launch blocker because
the proxy-level live-binding tests (`mfa_live_binding_test.dart`,
`auth_live_binding_test.dart`) cover the integration paths. Add unit
coverage when modifying any of these surfaces.

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

## P3 — Phase 11b retrieval assumption fixed inline

The Phase 11b plan referenced direct pgvector retrieval; corrected in this
audit to point at the Modular Adaptive Agentic RAG stack from
`phase_11a_decision_register.md`. No code follow-up needed.
