# Projection Error Path Drain Plan

## Plain English Summary

- The latest projection audit found success paths are wired.
- Two smaller gaps are safe to fix now:
  - first-connect backfill needs to await production adapter factories
  - poll/backfill error logs should also drain any facts already written before the adapter failed
- One larger gap is not safe to fake in memory:
  - if projection itself fails, there is still no durable retry ledger

## Fix Now

1. Make first-connect backfill adapter factories allow `Future` results.
2. Await the adapter before type-checking it in backfill dispatch.
3. Treat `poll_error` and `backfill_error` as drain events.
4. Add tests proving:
   - async backfill factories work
   - poll error drains buffered facts after the durable `poll_error` log
   - backfill error drains buffered facts after the durable `backfill_error` log

## Document For Later

- A real durable projection retry needs its own ledger or replay job.
- Keeping an in-memory buffer after projection failure would not survive process restart.
- Do not pretend that is solved in this patch.

## Guardrails

- No schema change.
- No adapter business logic change.
- No projection formula change.
- No tracker update.
- Main checkout stays on `master`; edits stay in this worktree.

## Execution Result

- First-connect backfill now awaits async production adapter factories before the category type-check.
- Poll and backfill error logs now drain projection taps after the durable error log is recorded.
- Projection retry after the projection layer itself fails remains a separate follow-up. This patch does not fake durable retry with process-local memory.

## Verification

- `dart analyze --fatal-infos lib\services\integration\projecting_canonical_sink.dart tool\integration_sync_worker\backfill_dispatch.dart tool\integration_sync_worker\dispatch.dart tool\first_connect_backfill_worker\main.dart test\tool\integration_sync_worker\dispatch_test.dart test\tool\integration_sync_worker\backfill_dispatch_test.dart test\tool\first_connect_backfill_worker\main_test.dart test\tool\integration_sync_worker\main_test.dart`
- `flutter test test\tool\integration_sync_worker\dispatch_test.dart test\tool\integration_sync_worker\backfill_dispatch_test.dart test\tool\first_connect_backfill_worker\main_test.dart test\tool\integration_sync_worker\main_test.dart`
- `dart run tool\ux_em_dash_lint.dart`
- `dart run tool\postgres_import_lint.dart`
- `git diff --check`
