# Projection Retry RunOnce Default Plan

## Plain-English Finding

- The retry worker README says production should use `runOnce`.
- The Dockerfile still defaulted to `daemon`.
- That could turn a scheduled Cloud Run Job into a long-running loop.
- The proxy already returns retry counts and dead-letter rows, but the admin
  screen did not parse or render them.
- There was no projection retry deploy script matching the other Cloud Run Job
  workers.

## Fix Plan

- Make the Dockerfile default command `runOnce`.
- Keep `daemon` available for explicit local or platform loop setups.
- Add a test that reads the Dockerfile and fails if the default drifts back to `daemon`.
- Add a Cloud Run Job + Cloud Scheduler deploy script that pins `--args runOnce`.
- Parse `projection_retries` into the admin observability model and add a
  projection retry tab with status counts, active rows, and dead-letter rows.
- Keep replay and write actions out of the admin UI; this slice is visibility
  and deployment wiring only.

## Verification

- Run the focused projection retry worker test.
- Run proxy projection retry observability tests.
- Run the admin observability widget test.
- Run changed-file Dart analysis if available.

## Follow-Up Not In This Slice

- Pre-input failures are currently dead-lettered without a durable
  `failure_stage` column. The admin tab labels the dead-letter list
  conservatively, but a future schema slice should expose explicit
  replayability metadata.
