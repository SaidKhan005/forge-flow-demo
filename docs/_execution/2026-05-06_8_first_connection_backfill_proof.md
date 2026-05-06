# 8.first-connect-backfill-wire-in Proof

Date: 2026-05-06

Branch: `codex/mobile-core-first-connect-closeout`

Status: Fixture proof PASS

## Scope

This proof closes the first-connection path from
`docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md` for the
current sprint. It is intentionally lean: it proves the accepted production
seams under deterministic fixture inputs and does not include push notification
proof, live provider calls, or the huge pressure suite.

## Command

```powershell
flutter test tool\first_connection_backfill_harness\main.dart
```

Fixture summary:

```json
{
  "status": "pass",
  "connect_jobs_enqueued": 1,
  "dispatched_jobs": 3,
  "canonical_facts_written": 5,
  "demo_flips": 3,
  "closed_rows_mobile_visible": 1,
  "open_snapshots_projected": 1,
  "simulated": [
    "connect result and enqueue gateway",
    "POS/labor/reservation adapter backfill writes",
    "canonical sink, watermark, sync-log, and demo flip seams",
    "closed post-commit aggregator/writer seam",
    "open snapshot projector seam",
    "mobile-visible cache read shape"
  ],
  "not_run": [
    "live vendor/provider calls",
    "live Postgres migration apply",
    "Cloud Run worker invocation",
    "push notification proof",
    "large pressure suite"
  ]
}
```

## Proof Matrix

| Contract path | Evidence | Status |
| --- | --- | --- |
| Connect persists first-backfill intent | Harness simulates a successful connect result and enqueue gateway. | PASS |
| One active 60-day job | Harness asserts the enqueued window equals `kFirstConnectionBackfillMaxWindow`. Lane 0 repository tests cover idempotent enqueue. | PASS |
| Worker runs adapter `backfill()` | Harness dispatches POS, labor, and reservation fixture adapters through `IntegrationSyncWorkerBackfillDispatch`. | PASS |
| Backfill writes canonical facts | Harness records five canonical facts through the sink seam. | PASS |
| Watermark/sync-log path is exercised | Harness uses the accepted sink seam that records watermark and sync-log writes. | PASS |
| Zero-row first backfill does not flip demo | Harness runs a zero-row POS backfill and asserts no demo flip. | PASS |
| First committed batch with rows flips demo | Harness records three category demo flips after non-zero first-backfill commits. | PASS |
| Closed rows are projected | Harness invokes `CanonicalFactPostCommitProjector` for a completed period and records one closed row. | PASS |
| Mobile can see closed history | Harness pulls the closed row into the existing mobile-visible cache fixture. | PASS |
| Open/current rows invoke live projector | Harness invokes the post-commit projector for an open/current period and records one open snapshot projection. | PASS |
| Mobile remains cache-only | Harness uses proxy/mobile cache shapes; no mobile vendor or Postgres call is introduced. | PASS |

## Targeted Lane Coverage

The accepted implementation lanes added or exercised:

- durable `connector_backfill_jobs` migration and repository
- connect-route enqueue for OAuth callback and key-paste connect
- worker backfill dispatch over existing adapter `backfill()` APIs
- canonical fact post-commit projector for closed rows and open snapshots
- first-backfill status through proxy/mobile sync status
- fixture harness and walkthrough evidence

## Not Run

- Live vendor/provider calls.
- Live Postgres migration apply.
- Cloud Run worker invocation.
- Connected-device proof.
- Push notification proof.
- Huge pressure suite.

These remain outside this sprint by contract.
