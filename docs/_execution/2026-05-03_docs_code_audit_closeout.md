# 2026-05-03 Docs/Code Audit Closeout

Status: Complete
Last updated: 2026-05-03

Purpose: keep the next execution prompt from inheriting stale tracker or phase
truth. This audit compared live docs against current code surfaces and moved
resolved items out of open trackers.

## Code Evidence Checked

- Migration inventory: `db/migrations/*.sql` now has 59 files; latest is
  `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`.
- Migration tooling: `tool/migration_drift_scanner.dart` and
  `tool/migration_cutoff_lint.dart`.
- Admin runtime/perf tooling:
  `tool/perf_gate/staging_console_probe.dart`.
- Health producers:
  `tool/advisor_proxy/health_producers/graph_producers.dart`,
  `tool/advisor_proxy/health_producers/rollup_producers.dart`,
  `tool/advisor_proxy/health_producers/vector_producers.dart`, and
  `tool/advisor_proxy/health_producers/producer_registry.dart`.
- Admin idempotency:
  `db/migrations/202605021000_phase_hardh_admin_idempotency.sql`,
  `tool/advisor_proxy/proxy_bootstrap.dart`, and
  `tool/advisor_proxy/advisor_proxy.dart`.
- Known failing tests: `docs/KNOWN_FAILING_TESTS.md` no longer has an open
  resolved row.

## Completed And Archived

- Staging graph-candidate 503 and staging `audit_chain_lag_seconds` red are
  archived in
  `docs/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`
  and referenced from
  `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`.
- The MFA coverage row was removed from the open follow-up table because the
  MFA test parcels were already archived as resolved.
- HARD-D/HARD-H admin idempotency naming mismatch is resolved by rewriting
  `docs/contracts/hardening_feature_flag_idempotency_contract.md` around the
  shipped `admin_request_idempotency` durable backstop.
- B44/B45/B47 health producer status now reflects code reality:
  producers are delivered; 11A.5/11A.6 still own UX/live evidence.
- `docs/contracts/migrations_summary.md` was regenerated from the migration
  directory and now reports 59 migrations.
- `docs/ARCHITECTURE.md` no longer lists B33/B34, RLS sweep,
  service-principal issuance, event outbox scaffold, or health producers as
  wholly queued/missing.

## Remaining Open Work

- Production1 apply event for the 27 queued migrations
  (`202604280014` through `202605021900`).
- B43 Production1 audit-anchor deployment once the production GCP project is
  provisioned.
- 11A.5/11A.6 UX/observability surfaces and live evidence over the delivered
  health producers.
- Admin provider credential/KMS rollout and browser QA require operator-held
  secrets/action-time approval.
- Remaining P2/P3 follow-ups in `docs/POST_HARDENING_FOLLOWUPS.md`.

## Verification

Run as part of this audit:

```powershell
python scripts\generate_migrations_summary.py
dart run tool\migration_drift_scanner.dart --strict-docs
dart run tool\migration_cutoff_lint.dart
dart analyze tool\migration_drift_scanner.dart test\tool\migration_drift_scanner_test.dart
flutter test test\tool\migration_drift_scanner_test.dart test\tool\migration_cutoff_lint_test.dart
flutter test test\proxy\health_producers\graph_producers_test.dart
flutter test test\proxy\health_producers\rollup_producers_test.dart
flutter test test\proxy\health_producers\vector_producers_test.dart
flutter test test\proxy\registry_proxy_health_check_store_test.dart
flutter test test\admin\operator_location_admin_gateway_test.dart test\admin\pricing_tier_admin_gateway_test.dart test\admin\integration_admin_gateway_test.dart
git diff --check
```

`git diff --check` may report CRLF normalization warnings on edited Markdown
files; those are not whitespace errors.
