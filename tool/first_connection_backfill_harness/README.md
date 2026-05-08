# First Connection Backfill Harness

Regression / validation harness for the first-connect backfill seam.
Originally landed as the Lane 5 fixture proof for
`8.first-connect-backfill-wire-in` (sprint shipped); now used to pin
the bounded 60-day enqueue, demo-flip, post-commit aggregator, and
open snapshot projector contracts against any future change.

Run it from the repo root:

```powershell
flutter test tool\first_connection_backfill_harness\main.dart
```

The harness is intentionally a Flutter test because the accepted integration
seams import Flutter test-only dependencies indirectly. It does not make live
vendor calls and it does not connect to live Postgres.

## What It Proves

- A simulated successful vendor connect enqueues exactly one bounded 60-day
  first-backfill job.
- A zero-row first backfill completes without flipping demo mode.
- POS, labor, and reservation backfill dispatch paths call the accepted
  adapter `backfill()` seams.
- Canonical facts write through the sink, watermark, sync-log, and demo-flip
  seams.
- Demo mode flips only after a first committed backfill batch with at least
  one row.
- Completed periods run through the closed post-commit aggregator/writer seam.
- The closed row is visible through the existing mobile cache read shape.
- Current/open periods invoke the open snapshot projector seam.

## Not Run

- Live vendor/provider calls.
- Live Postgres migration apply.
- Cloud Run worker invocation.
- Push notification proof.
- Large pressure suite.
