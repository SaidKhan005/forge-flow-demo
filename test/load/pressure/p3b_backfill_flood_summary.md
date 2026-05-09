# Pressure Preview v1 — Phase 3B Backfill Flood

Harness version: `p3b.v1`
Generated: 2026-05-09T05:18:57.909385Z

## Run Parameters

| Flag | Value |
|---|---|
| `--ops` | 3 |
| `--vendors-per-op` | 2 |
| `--records-per-vendor` | 50 |
| `--worker-pods` | 2 |
| `--simulate-restart` | 1 |
| Total jobs enqueued | 9 (6 regular + 3 demo-flip race) |
| Synthetic records | 300 |
| Elapsed | 275 ms |
| Terminal / enqueued | 9 / 9 |
| Demo-flip race resolved | true |
| Demo-flip spread | 15 ms |

## Findings Tally

Total findings: 1

| Kind | Count |
|---|---|
| `setup_skipped` | 1 |

## Finding Categories

- `backfill_stuck` — job stayed in `running` (or `pending`) past the per-job budget.
- `backfill_didnt_resume` — pod restart caused re-processing from scratch instead of resuming from cursor.
- `demo_flip_race_lost` — only some categories flipped after concurrent backfills for one (operator, location).
- `worker_collision` — two worker pods claimed the same job (would indicate a SKIP LOCKED regression).
- `audit_row_missing` — no terminal-hook audit log entry for a succeeded backfill.
- `cursor_lost_at_restart` — worker resumed from null cursor instead of partial cursor after pod restart.
- `connection_pool_exhaustion` — emitted when the in-memory serializer queue depth crosses a threshold proxy for a real pool exhaustion (not currently observed in the in-memory path).
- `setup_skipped` — preconditions for the real-DB path were absent (e.g. `POSTGRES_URL` not set); harness ran the in-memory simulation instead.

## Full-Scale Invocation

```
dart run tool/pressure/p3b_backfill_flood.dart --ops=10 --vendors-per-op=3 --records-per-vendor=1000 --worker-pods=3 --simulate-restart=3
```

≈ 30,000 records ingested across 30 backfill jobs (plus the 3-job demo-flip-race triple).

## Preview Proxy Reference

Operator-approved preview proxy URL (referenced by sprint authority; not exercised by this harness):

  https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app
