# p2b_sink_pressure_harness — Phase 2B Postgres sink pressure

**Runner:** `test/integration/pressure/p2b_sink_pressure_harness_test.dart`

**What it pressures:** the per-vendor Phase 8 Postgres sinks
(`*_postgres_sink.dart`) driven from the Phase 1 fixture corpus.
Asserts operator-scoped writes land in the right fact table,
idempotency holds under retry, RLS denies cross-operator reads,
cross-vendor namespace isolation holds even when vendor entity ids
collide, and the demo→live flip fires via
`DemoModeFlipPolicy.evaluateFlip` on first backfill commit.

**Status at f0bf2702:** PASS. Two-mode harness: a structural mode runs
unconditionally; a runtime mode runs only when `PRESSURE_PG_URL` is
supplied.

## Inputs

- Env / dart-define: `PRESSURE_PG_URL` — local Postgres URL. SET →
  exercise the runtime cases against the live DB. UNSET → structural
  mode (existence checks + setup_skipped findings for runtime probes).
- 17 vendor entries with `factTable` mapping: POS sinks (7) write
  `cover_facts`, labor sinks (6) write `labor_punches`, reservation
  sinks (4) write `reservation_facts`.
- Fixture corpus root: `test/fixtures/vendor_payloads/<vendor>/`.

## What it asserts

- Structural group (always runs):
  - Every vendor has a sink file at the documented path with the
    expected class name.
  - Every vendor fixture corpus contains the required
    `happy_path` + `sparse` + `scenario_f` fixtures.
  - Case enumeration covers every fixture without unknown kinds.
  - Cross-vendor `scenario_f` pair set is non-empty.
- Runtime group (only with `PRESSURE_PG_URL`):
  - `demo_mode_state` inserts land under operator A and are NOT visible
    to operator B (HP #4 per-operator isolation; RLS engaged).
  - `demo_mode_state` INSERT is idempotent on
    `(operator_id, location_id, category)`.
  - Per-vendor happy-path + sparse sink writes land in the right
    canonical fact row.
  - `scenario_f` cross-vendor pairs land in disjoint rows under each
    vendor's own `vendor_id` namespace (UNIQUE on `(vendor_id,
    operator_id, vendor_entity_id, vendor_modified_at)` holds).
  - Demo→live flip evaluation fires per `(operator, location,
    category)` on first backfill commit; disconnect does NOT
    auto-revert.

## How to read the output

- Findings artifact: `test/integration/pressure/p2b_sink_findings.jsonl`
  (gitignored) plus a `p2b_sink_summary.md` table beside it (also
  gitignored — runs in-place per invocation).
- Runtime cases skipped without `PRESSURE_PG_URL` show as
  `setup_skipped` findings; that's expected on a CI-dark box and not
  a regression.
- Regression signal: a `cross_operator_isolation_breach` finding
  means RLS or the repository scope filter regressed; a sink-file
  rename without updating the catalog surfaces as
  `sink_file_missing` / `class_name_mismatch`.

## Related

- Authority:
  - `docs/contracts/integration_spine_architecture_contract.md`
    (Postgres-backed CanonicalSink shape)
  - `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
    (repository pattern + RLS backup)
  - `docs/contracts/demo_mode_contract.md` (HP #2 + demo_mode_state)
  - `docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.4,
    backlog item #10
- Companion harnesses: `p2a_adapter_pressure_harness_test.dart`,
  `p2c_spine_pressure_harness_test.dart`,
  `p2d_mobile_sync_pressure_harness_test.dart`
- Last touched: see `git log -- test/integration/pressure/p2b_sink_pressure_harness_test.dart`
