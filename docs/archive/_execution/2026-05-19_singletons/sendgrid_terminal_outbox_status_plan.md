# SendGrid Terminal Outbox Status Plan

## Plain English Summary

- The updated graph pass found one real email gap still open.
- SendGrid webhook events are saved in `email_event`.
- Bounce and complaint events do not update the matching `email_outbox` row.
- That leaves the main delivery status stuck at `sent`.
- Fix this in the repository layer so both HTTP dispatch and test dispatch use the same behavior.

## Fix Plan

1. Keep the existing SendGrid signature and event-insert flow unchanged.
2. After each event insert or duplicate replay, check whether the event is terminal:
   - `bounced`
   - `complaint`
3. If the event has a SendGrid provider message id, update matching `email_outbox` rows from `sent` to the terminal status.
4. Leave non-terminal events unchanged.
5. Leave unmatched terminal events as a safe no-op because the outbox row may not be joinable yet.
6. Add repository tests proving:
   - a bounced event flips `sent` to `bounced`
   - a complaint replay still attempts the repair
   - non-terminal events do not touch `email_outbox`

## Guardrails

- No schema change: `email_outbox.status` already allows `bounced` and `complaint`.
- No route shape change.
- No auth change.
- No provider calls.
- Main checkout stays on `master`; all edits stay in this worktree.

## Execution Result

- Terminal SendGrid events now repair the matching `email_outbox.status` when the matching provider message id is present.
- Duplicate terminal events still attempt the same safe repair.
- Non-terminal SendGrid events still only write `email_event`.

## Verification Run

- `dart analyze --fatal-infos lib\infrastructure\persistence\postgres\repositories\email_event_repository.dart test\infrastructure\persistence\postgres\repositories\email_event_repository_test.dart test\proxy\sendgrid_events_webhook_test.dart`
- `flutter test test\infrastructure\persistence\postgres\repositories\email_event_repository_test.dart test\proxy\sendgrid_events_webhook_test.dart test\services\email\email_outbox_dispatcher_test.dart`
- `dart run tool\ux_em_dash_lint.dart`
- `dart run tool\postgres_import_lint.dart`
- `git diff --check`
