# Mobile Core Payload Harness

This lean harness is the Lane 5 proof wrapper for
`8.live-and-closed-truth-core`.

Run all proof suites:

```powershell
dart run tool/payload_harness/main.dart
```

List suites:

```powershell
dart run tool/payload_harness/main.dart --list
```

Run one suite:

```powershell
dart run tool/payload_harness/main.dart --suite=live-projector
```

Suites:

- `live-projector`: canonical POS/labor/reservation facts to server
  `open_shift_snapshots`, including idempotency replay, small burst in one
  service period, cross-tenant isolation, missing timing profile honesty, and
  whole-day rollup.
- `proxy-mobile-open-snapshots`: proxy fields to mobile SQLite
  `open_shift_snapshots`, plus first-sync/backfill/stale/current status
  handling.
- `closed-triplet`: closed input to builder to Postgres writer with
  `business_timing_profile_id`, `business_timing_profile_version_id`, and
  `service_period_key` preservation.
- `closed-labels`: Variance, History, and Learn labels from saved timing
  identity with legacy fallback and rename-stability coverage.

Non-goals for this harness: push notification proof, the large pressure suite,
and any duplicate `open_shift_snapshots_cache` table.
