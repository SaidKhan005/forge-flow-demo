# p3c_oauth_refresh_storm — Phase 3C OAuth refresh storm

**Runner:** `test/pressure/p3c_oauth_refresh_storm_runner_test.dart`
(in-process probe; CLI variant: `test/pressure/p3c_oauth_refresh_storm_cli_test.dart` /
harness binary `tool/pressure/p3c_oauth_refresh_storm.dart`)

**What it pressures:** the OAuth refresh path under N-way concurrent
storm against the same `(operator_id, location_id, vendor_id)` credential
row. Catches advisory-lock regressions (multiple closures running),
torn reads (mid-poll observes an empty bearer), half-rotated rows
(commit-vs-update ordering bug), and registry drift (an OAuth-using
vendor without a wired refresh closure).

**Status at f0bf2702:** PASS. Runs every `flutter test` invocation;
uses an in-process `SyntheticCredentialStore`, not the production
worker.

## Inputs

- No env vars. Hermetic: spins up a `SyntheticCredentialStore` and
  exercises `tool/oauth_refresh_worker/main.dart` factories
  (`buildProductionRefreshClosures`) with synthetic AAD env values.
- 8 concurrent callers per single-tuple storm test.
- Catalog mirror: `_helpers/p3c_vendor_authmode_catalog.dart`
  enumerates the 17 Phase 8 vendors + their declared auth modes.

## What it asserts

- Advisory-lock collapse: N parallel refreshes against one tuple invoke
  the refresh closure exactly once; `rotation_count` increments by 1,
  not N.
- Per-tuple lock isolation: parallel refreshes against different
  `(op, loc, vendor)` tuples run concurrently (closure invocations == N).
- Atomic rotation: a snapshot probe between vendor RTT and commit sees
  the pre-rotation ciphertext, never a torn intermediate.
- Mid-poll-during-refresh: pollers never observe an empty bearer.
- Closure registry coverage: exactly 13 OAuth vendors wired when full
  env supplied; 4 entries on `kVendorsWithoutRefreshClosure` (tock,
  push_operations, humanity, agendrix); each carries a documented
  delegation reason.
- Oracle Simphony has an OAuth closure (refutes audit's mTLS claim);
  Agendrix surfaces as the lone OAuth-flavored-but-unsupported entry.
- `P3cFindingSink.flush` emits one JSONL line per finding; the summary
  MD opens with `# P3C OAuth Refresh Storm` and reports the total.

## How to read the output

- Healthy run: every group's tests pass; no findings need surfacing
  because the assertions are direct (advisory-lock collapse, vendor
  count == 13, etc.).
- Regression: a vendor count drift means `tool/oauth_refresh_worker/main.dart`
  added/removed a wire without updating `kVendorsWithoutRefreshClosure`
  or this test (re-pin lines 264 / 305 / 354 as noted in the test
  source).
- The CLI variant writes a real findings JSONL + summary MD when
  invoked manually; no committed findings file in the runner-test path.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/oauth_refresh_worker/main.dart`
  (`buildProductionRefreshClosures`, `kVendorsWithoutRefreshClosure`)
- Companion harnesses: `p3a_webhook_flood_runner_test.dart`,
  `p3b_backfill_flood_runner_test.dart`
- Last touched: see `git log -- test/pressure/p3c_oauth_refresh_storm_runner_test.dart`
