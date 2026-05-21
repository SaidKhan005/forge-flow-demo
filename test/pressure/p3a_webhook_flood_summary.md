# p3a_webhook_flood — Phase 3A vendor webhook flood

**Runner:** `test/pressure/p3a_webhook_flood_runner_test.dart`
(thin invocation of the harness binary at `tool/pressure/p3a_webhook_flood.dart`)

**What it pressures:** the preview-proxy webhook intake under sustained
per-vendor event flood — bounded-rate replays of representative vendor
payloads against the operator-approved preview proxy. Catches webhook-
intake regressions (queue depth, dedupe key drift, signature-verify
misroute, intake retry storms) before they reach staging.

**Status at f0bf2702:** PASS. The structural CLI check runs every
`flutter test` invocation; the network smoke is opt-in (see env gate).

## Inputs

- Env gate: `FF_RUN_PRESSURE_PREVIEW_P3A=1` — without it the smoke test
  no-op skips (proxy hits cost staging-Postgres connection budget).
- Runner test smoke scale: `--ops=1 --duration=30s --rate=1
  --vendors=toast,seven_shifts --retry-each=1 --output-dir=test/pressure`.
- Placeholder secret token (`PLACEHOLDER-PRESSURE-PREVIEW-V1`) — the
  harness must NOT reference real keys.

## What it asserts

- The harness binary `tool/pressure/p3a_webhook_flood.dart` exists and
  declares an async `main` entrypoint (structural; unconditional).
- The binary references the preview-URL prefix `forge-flow-preview-`
  for its allowed-host guard.
- The binary uses the documented placeholder secret (no real keys
  committed).
- When env-gated smoke runs: harness exits 0 and writes both
  `p3a_webhook_flood_findings.jsonl` + `p3a_webhook_flood_summary.md`.
- Hard rule: `--retry-each=1` default; the runner does NOT auto-rerun.

## How to read the output

- Healthy run: exit 0; findings JSONL + summary MD written to
  `test/pressure/`; CLI stdout reports queue depth + per-vendor 2xx.
- Regression: non-zero exit, or missing output artifacts, or harness
  binary fails the structural grep (rename / preview URL drift / real
  secret accidentally committed).
- Operator-driven full-scale smoke: see the harness header for the
  documented command; runner test only exercises the 30-second scale.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4 (pressure harness coverage), backlog item #10
- Companion harnesses: `p3b_backfill_flood_runner_test.dart`,
  `p3c_oauth_refresh_storm_runner_test.dart`
- Last touched: see `git log -- test/pressure/p3a_webhook_flood_runner_test.dart`
