# Perf Baseline Capture Runbook

Version: 0.1 (2026-05-21). Owner: Orchestrator (pressure-PR audits).
Status: Skeleton — baseline values land as live cloud measurements
become available.

Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
§3 dimension 2 + §7 backlog item #5 + §8 (tooling gap "no
perf-baseline file").

## What the baselines mean

`docs/PERF_BASELINES.json` is the committed source of truth for the
small set of measured performance numbers we ratchet against. Each
key is one named surface where a regression would ship silently
without a comparison file:

- `cold_boot_demo_seed_ms` — wall-clock to seed the demo SQLite DB
  from `MockReplayDataSourceProvider` on a fresh install.
- `soak_p50_request_ms`, `soak_p95_request_ms`, `soak_p99_request_ms`
  — proxy request latency percentiles from a soak run driven by
  `tool/pressure/p4_soak_orchestrator.dart`.
- `p3a_webhook_flood_throughput_rps` — sustained webhook-intake
  throughput from `tool/pressure/p3a_webhook_flood.dart`.
- `p3b_backfill_flood_complete_ms` — wall-clock to drain a backfill
  flood from `tool/pressure/p3b_backfill_flood.dart` at full scale.

A value of `null` means "no baseline captured yet"; `--check` against
a null baseline is a SKIPPED pass, not a fail. The ratchet must not
block PRs while we are still standing the measurement up.

## How to capture a baseline

Captures are deliberate, not a one-off run:

1. Operator marks a perf-relevant change as the new baseline.
2. The pressure harness runs at its documented full-scale invocation,
   on a host close to production shape (preview proxy or staging).
3. Record: `dart run tool/perf_baseline_check.dart --capture <metric> <value>`.
   Updates the metric in place and stamps `captured_at` to today (UTC).
4. The capture PR body notes *why* this is the new baseline (slice
   that landed, prior baseline, improvement vs accepted regression).

Do not capture from a dev laptop or a smoke-scale run.

## How `--check` is used in pressure-PR audits

Orchestrator runs `--check` explicitly during any PR audit that
exercises a pressure harness:

```
dart run tool/perf_baseline_check.dart --check <metric> <measured>
```

Exit 0 (OK or SKIPPED) → audit clean. Exit 1 (REGRESSION) → audit
flags it; the slice does not merge without explicit operator
accept-or-fix.

NOT wired into the pre-push hook — per-push perf checks are too
expensive. Runs only when the audit needs it.

## What "regression" means here

`regression_factor` in the JSON (currently `1.2`) is the multiplier
on the baseline. A measurement is a REGRESSION when
`measured > baseline * regression_factor`. The factor lives in the
JSON so a future operator can tighten it (e.g. to `1.1`) once we
have multiple stable captures. Relative, not absolute.

## Update cadence

- Capture once when the first production-shape measurement is
  available.
- Recapture only when the operator marks a perf-relevant change as
  the new baseline. Not on routine merges.
- Quarterly: orchestrator runs `--list` and confirms each number
  still represents a healthy baseline.
