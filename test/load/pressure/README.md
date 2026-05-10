# Pressure Load Harnesses — Pressure Preview v1

Sprint: `pressure.preview.v1` Phase 3.

This directory holds the three load-test lanes that pressure-test the
preview proxy and its dependencies under realistic concurrent vendor
traffic. The preview environment is runtime-isolated (separate Cloud
Run revision) but shares the staging Postgres cluster — operator-
approved with the load lane bounded.

The plan doc lives at
`docs/_execution/2026-05-08_pressure_preview_v1_plan.md`. Fixtures live
at `test/fixtures/vendor_payloads/<vendor>/`.

## Three Load Lanes

| Lane | Name | Pressure shape | What it stresses |
|---|---|---|---|
| 3A | Webhook flood | N concurrent webhook POSTs across all 17 vendors, sustained for M minutes | Adapter parse path, signature verification, idempotency ledger contention, proxy request queue |
| 3B | Backfill flood | Multiple operators triggering first-connection backfill simultaneously | Backfill worker pool, OAuth refresh advisory lock, sink throughput, RLS context-switch cost under load |
| 3C | OAuth-refresh storm | Synthetic near-expiry tokens for the 11 OAuth vendors, all refreshing in the same window | OAuth refresh advisory lock contention, token-rotation idempotency, vendor rate-limit handling |

Each lane is its own subdirectory (created lazily by Phase 3 agents).

## Bounded-Run Discipline

Because Phase 3 hits staging Postgres:

- Every run has an explicit cap (max requests, max duration, max
  concurrent operators). The cap lives in the lane's harness file as a
  named constant; operator override required to raise.
- Every run cleans up after itself — synthetic operators / locations
  written during the run get removed in `tearDown`.
- Every run names the lane in the proxy `User-Agent` so the staging
  log filter can isolate pressure-test traffic.
- Runs against Production1 are forbidden. The preview proxy URL guard
  is a hard fail — if the test framework cannot resolve it, fail fast
  rather than fall back.

## Conventions

- Reuse Phase 1 fixtures from `test/fixtures/vendor_payloads/`. The
  load lanes do not author new payloads; they replay existing ones at
  scale.
- Phase 3 results land in
  `docs/_execution/2026-05-08_pressure_preview_findings.md` Phase 5
  section, not in lane-local logs.
- Each lane has a "smoke" mode (1 operator × 1 vendor × 10 events) and
  a "full" mode (the cap above) so it can be exercised in development
  without burning staging quota.

## Phase 0 (this commit)

Empty placeholder — lane subdirectories will land in Phase 3. Only
this README + a `.gitkeep` exist now.

## What This Directory Is NOT

- Not a place for integration tests (Phase 2 owns
  `test/integration/pressure/`).
- Not a place for adversarial security tests (those stay in
  `test/security/` and are run in their own lane).
- Not a place for production-load benchmarks (those run from external
  load-gen infrastructure, not from `flutter test`).
