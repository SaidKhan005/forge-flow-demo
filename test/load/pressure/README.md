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

## Five Load Lanes

| Lane | Name | Pressure shape | What it stresses |
|---|---|---|---|
| 3A | Webhook flood | N concurrent webhook POSTs across all 17 vendors, sustained for M minutes | Adapter parse path, signature verification, idempotency ledger contention, proxy request queue |
| 3B | Backfill flood | Multiple operators triggering first-connection backfill simultaneously | Backfill worker pool, OAuth refresh advisory lock, sink throughput, RLS context-switch cost under load |
| 3C | OAuth-refresh storm | Synthetic near-expiry tokens for the 11 OAuth vendors, all refreshing in the same window | OAuth refresh advisory lock contention, token-rotation idempotency, vendor rate-limit handling |
| 4 (session soak) | Multi-session sign-in soak (B2) | N concurrent operators repeatedly hitting `POST /v1/auth/session/login` with mixed Flutter Web + Mobile UAs; every 7th operator is `ff_support` (scope-less) | Sign-in contract integrity (Bug A regression class), pubsub ring buffer growth (S3), Postgres pool waiter pile-up (S2), root-zone uncaught traps (S1) |
| 4 (operator-day soak) | Synthetic operator daily journey (B2) | N operators looping sign-in → dashboard → notifications → settings → sign-out with realistic ±25% jittered think times | Multi-step flow integrity, sustained mixed-route traffic, Bug B class crashes under hours-long live use |

Each lane is its own file under `tool/pressure/`. Lanes 4 share the
`p4_session_record_predicate.dart` helper — the
`SessionRecordCompleteness.assertComplete` predicate is called on
every successful sign-in and short-circuits the run with exit code
3 on any incomplete record (Bug A regression must surface as a CI
red).

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

## Phase 4 — B2 hot-fix lanes (2026-05-12)

Added in the B1+B2 proxy hot-fix slice
(`docs/_execution/b1_b2_proxy_soak_fix/01_execution_slice.md`):

  * `tool/pressure/p4_session_soak.dart` — multi-session sign-in
    soak. Smoke run example:

        dart run tool/pressure/p4_session_soak.dart \
          --ops=2 --concurrency=2 --duration=30s \
          --proxy-url=http://localhost:8080

  * `tool/pressure/p4_operator_day_soak.dart` — synthetic operator
    daily journey. Smoke run example:

        dart run tool/pressure/p4_operator_day_soak.dart \
          --ops=2 --concurrency=2 --duration=30s \
          --proxy-url=http://localhost:8080

  * `tool/pressure/p4_session_record_predicate.dart` — shared
    `SessionRecordCompleteness.assertComplete` predicate used by both
    harnesses AND by the production observability surface (future
    `proxy.session_record.incomplete{route, missing_field}` gauge).

Both harnesses honour `SIGINT` for clean shutdown, refuse to run
against a non-preview / non-staging / non-localhost URL, and exit
with code 3 if any incomplete session record was observed (Bug A
regression class).

## What This Directory Is NOT

- Not a place for integration tests (Phase 2 owns
  `test/integration/pressure/`).
- Not a place for adversarial security tests (those stay in
  `test/security/` and are run in their own lane).
- Not a place for production-load benchmarks (those run from external
  load-gen infrastructure, not from `flutter test`).
