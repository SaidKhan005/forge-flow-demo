# p4_cold_boot_regression_detector — Phase 4 cold-boot regression detector

**Runner:** `test/pressure/p4_cold_boot_regression_detector_test.dart`
(runs unconditionally; no env gate — cold boot is local-only).

**What it pressures:** the app cold-boot path (mobile SQLite seed via
`lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`)
should not degrade more than 20% release-over-release. The test
measures a synthetic cold-boot proxy and compares against
`docs/PERF_BASELINES.json` when that file lands.

**Dependency note (read this):** `docs/PERF_BASELINES.json` and
`tool/perf_baseline_check.dart` are not present on this branch
(tracked separately — see POST_HARDENING_FOLLOWUPS / audit doc
§2.4). The test still runs and asserts today in **advisory mode**:
it captures a measured value, writes a findings JSONL, and PASSES.
When the baseline file lands with a `cold_boot_demo_seed_ms` field,
the test automatically flips to comparison mode (measured < baseline
× 1.2); no code change needed beyond the one-line
`TODO(perf-baseline-handshake)` swap if a hard fail is wanted even
without a baseline. This is NOT a reserved stub — every assertion
runs under default `flutter test`.

**Status:** PASS (advisory mode — no baseline file present).

## Inputs

- Optional baseline: `docs/PERF_BASELINES.json` with a numeric
  `cold_boot_demo_seed_ms` field (absent here).
- No env gate. Runs in default `flutter test`.

## What it asserts

- The synthetic cold-boot proxy is measurable (> 0 ms; defends
  against the JIT eliding the loop).
- A findings entry is appended to
  `test/pressure/p4_cold_boot_regression_detector_findings.jsonl`.
- When a baseline exists: measured < baseline × 1.2 (20% ceiling).
- When no baseline: advisory `no_baseline` finding written; test
  passes.
- The findings file is well-formed JSONL (last line parses).

## How to read the output

- Healthy run: 2 test cases pass; the findings file gains a
  `measurement` or `no_baseline` entry per run.
- The synthetic proxy is NOT the real seed path — it is a stable
  CPU/allocation-bound stand-in. A future slice swaps it for an
  instrumented `_seedDemoDataFromReplay` call once the baseline
  tooling lands.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #7
+ §2.4 (PERF_BASELINES.json gap).

## Deferred

When `docs/PERF_BASELINES.json` + `tool/perf_baseline_check.dart`
land (see POST_HARDENING_FOLLOWUPS / audit doc §2.4): record the
real cold-boot baseline, swap the synthetic proxy for an
instrumented seed call, and enable the unconditional regression
assertion.
