# 8.live-and-closed-truth-core Proof Execution

Date: 2026-05-06

Branch: `codex/mobile-core-contract-execution`

Status: Lean proof PASS; final closeout verification PASS

## Scope

This proof is intentionally lean. It covers the live and closed truth paths
required by `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
without adding push notification proof or the large pressure suite.

## Proof Matrix

| Path | Evidence | Status |
| --- | --- | --- |
| Accepted POS sink path | `open_shift_snapshot_projector_test.dart` POS fact cases | PASS |
| Labor support path | `open_shift_snapshot_projector_test.dart` FOH/BOH labor cases and `canonical_fact_to_closed_shift_input_test.dart` labor wage-source cases | PASS |
| Reservation support path | `open_shift_snapshot_projector_test.dart` whole-day rollup and `canonical_fact_to_closed_shift_input_test.dart` reservation cases | PASS |
| Canonical facts -> live projector -> `open_shift_snapshots` | `tool/payload_harness/main.dart --suite=live-projector` | PASS |
| Proxy -> mobile SQLite open snapshot pull | `tool/payload_harness/main.dart --suite=proxy-mobile-open-snapshots` | PASS |
| Closed input -> builder -> writer -> closed row with triplet | `tool/payload_harness/main.dart --suite=closed-triplet` | PASS |
| Closed label does not drift after timing rename | `tool/payload_harness/main.dart --suite=closed-labels` | PASS |
| Idempotency replay | `open_shift_snapshot_projector_test.dart` and `postgres_shift_record_writer_test.dart` replay cases | PASS |
| Small burst in one service period | `open_shift_snapshot_projector_test.dart` many-writes-one-period case | PASS |
| Cross-tenant isolation | `open_shift_snapshot_projector_test.dart`, `canonical_fact_to_closed_shift_input_test.dart`, and `postgres_shift_record_writer_test.dart` tenant isolation cases | PASS |

## Commands

```powershell
dart run tool/payload_harness/main.dart
```

Result on 2026-05-06 from the Codex integration worktree: PASS. Harness suites
reported:

- `PASS live-projector`
- `PASS proxy-mobile-open-snapshots`
- `PASS closed-triplet`
- `PASS closed-labels`

Final coordinator closeout PASS:

- `flutter analyze`
- `dart run tool/index_leading_column_lint.dart`
- `dart run tool/migration_cutoff_lint.dart`
- `dart run tool/postgres_import_lint.dart`
- `dart run tool/rls_policy_lint.dart`
- `dart run tool/migration_drift_scanner.dart --fix --strict-docs`
- `git diff --check`
