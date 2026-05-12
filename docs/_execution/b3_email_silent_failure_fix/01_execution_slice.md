# B3 — Email silent-failure hot-fix (execution slice)

Authority:
- `docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` Block B, B3.
- `docs/_audits/code_health/c_email_notification_scenario_inventory.md` (Hook-only with missing templates row).
- `CLAUDE.md` Hard Promises + UX writing standard.

Branch: `claude/b3-email-silent-failure-fix`. One PR. Auto-merge eligible (additive, no auth / billing surface).

## Scope

Three notification hooks (`notif.backfill.complete`, `notif.backfill.failed`, `notif.audit.anchor_failure`) call `NotificationEventFanout` with template ids `backfill_complete`, `backfill_failed`, `audit_anchor_failure`. None of those ids were registered in `EmailTemplateIds.all`, and no Markdown templates existed on disk. The fanout's `catch (_)` swallowed the renderer's `ArgumentError` silently. Operators never received the emails and Cloud Logging carried no trace.

This slice:
1. Registers the three missing template ids in `EmailTemplateIds`.
2. Adds locked subject lines to `_subjectByTemplate`.
3. Creates the three Markdown templates with operator-facing copy.
4. Replaces the fanout `catch (_)` with a typed-catch + structured log line so future template misses surface.
5. Adds renderer + fanout test coverage.

Out of scope (deliberately):
- Trigger-site rewiring. `notification_event_hooks.dart` already references the three ids; this slice makes them real, nothing else.
- Re-architecting the 6 other template-only entries listed in the inventory.
- Touching the dual invite path (B4, deferred).
- Touching any of the 9 locked V1 email templates' bodies.

## File list

Code:
- `lib/services/email/email_template_renderer.dart` — added 3 template id constants, 3 subject patterns, appended ids to `all`.
- `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart` — added `NotificationFanoutLogSeam` typedef + default seam binding to `log()`; constructor now accepts an optional `logSeam`; replaced the per-channel `catch (_)` with a typed `catch (e, st)` that emits `notification.fanout.email_render_failed` (email) or `notification.fanout.channel_dispatch_failed` (push/inbox); added a `notification.fanout.unknown_event_key` warning on the unknown-event-key path.

Templates (new):
- `tool/advisor_proxy/email_templates/backfill_complete.md`
- `tool/advisor_proxy/email_templates/backfill_failed.md`
- `tool/advisor_proxy/email_templates/audit_anchor_failure.md`

Tests:
- `test/services/email/email_template_renderer_test.dart` — sample data extended with B3 placeholders; `EmailTemplateIds.all` count assertion bumped 9 → 12; new id assertions added.
- `test/services/email/notification_event_fanout_test.dart` — three new B3 tests (email-side dispatch failure emits structured log; unknown event key emits structured warning; happy-path admit-all-channels regression); added `_RecordingLogSeam`, extended `_RecordingEmailSeam` with optional `failOnTemplateId`.

Slice plan:
- `docs/_execution/b3_email_silent_failure_fix/01_execution_slice.md` (this file).

No other files touched.

## Template copy decisions

UX writing standard (`memory/project_ux_writing_standard.md`): "Email templates follow the same standard: explain what happened, why, what to do, and reassure on data safety where relevant. Plain English, no engineering jargon."

### `backfill_complete.md`
Subject: `Your {{vendorName}} historical sync is complete`. Body mirrors the user-dump phrasing verbatim where possible: *"60 days of your {{vendorName}} P.o.s data has been uploaded and your initial benchmark is now live in Forge & Flow."* Closes with the `completionTimestampHumanReadable` and a CTA to the dashboard. Placeholders: `recipientName`, `vendorName`, `businessName`, `completionTimestampHumanReadable`, `dashboardUrl`.

### `backfill_failed.md`
Subject: `Your {{vendorName}} historical sync needs attention`. Body opens with reassurance ("your existing data is safe and nothing has been lost"), surfaces an `{{errorCategory}}` (operator-readable category, not stack trace), states that "The Forge & Flow support team has been alerted and is already looking into it" per the prompt. CTA back to the vendor connection panel via `{{vendorConnectionUrl}}`. Placeholders: `recipientName`, `vendorName`, `businessName`, `errorCategory`, `vendorConnectionUrl`.

### `audit_anchor_failure.md`
Subject: `A daily integrity check on your audit log did not complete`. Body deliberately avoids the words *anchor* and *hash chain* (the user explicitly flagged the current wording as too technical). Frames it as "a daily integrity check that Forge & Flow runs on your audit log did not complete." Reassures that no operating data is affected, explains why we still email (audit log is the record reached for during a compliance review), and reports `retryStatusHumanReadable`. Placeholders: `recipientName`, `checkDateHumanReadable`, `summary`, `retryStatusHumanReadable`.

## Test plan + evidence

Test commands ran from the worktree root.

`dart analyze` against touched files:
```
dart analyze lib/services/email/email_template_renderer.dart \
             tool/advisor_proxy/email_dispatch/notification_event_fanout.dart \
             tool/advisor_proxy/email_dispatch/notification_event_hooks.dart \
             test/services/email/notification_event_fanout_test.dart \
             test/services/email/email_template_renderer_test.dart \
             test/services/email/notification_event_hooks_test.dart
```
Output: `No issues found!`

`flutter test test/services/email/`:
- email_template_renderer_test.dart — 11 tests, all pass. The "every V1 template renders with sample data" loop now exercises the three new templates against `sampleData()`.
- notification_event_fanout_test.dart — 17 tests (14 pre-existing + 3 new B3 tests), all pass. The new B3 tests assert:
  - `email-side dispatch failure emits notification.fanout.email_render_failed` — drives an envelope with an unknown template id through the fanout; the email seam throws `ArgumentError`; the fanout now captures a structured log record with `event_kind`, `template_id`, `operator_id`, `user_id`, `channel`, `error.runtimeType`, `error_message`, `stack_first_frame`. Push channel still flows.
  - `unknown event_key emits notification.fanout.unknown_event_key` — drives an envelope with an unregistered event key; verifies the warning log is emitted with the same field shape.
  - `successful fanout dispatches all admitted channels for registered template ids` — drives the now-registered backfill_complete envelope (with an explicit inbox preference) and verifies push + email + inbox all dispatch and zero failure log lines fire.
- notification_event_hooks_test.dart — 4 tests, all pass (unchanged).
- vendor_lifecycle_notification_dispatcher_test.dart, email_provider_test.dart, email_outbox_dispatcher_test.dart, sendgrid_email_provider_test.dart — all pass (unchanged behavior).

Total: 83 tests, all green.

## How this closes the silent failure

Before:
- `EmailTemplateIds.all` had 9 entries. The renderer threw `ArgumentError: Unknown templateId` for `backfill_complete` / `backfill_failed` / `audit_anchor_failure`. The fanout's per-channel `catch (_)` ate the throw. `outcome.skipped` went up by 1, nothing else. No log line, no operator email, no operator visibility.

After:
- `EmailTemplateIds.all` has 12 entries. The renderer renders all three templates. The fanout dispatches the email row to `email_outbox`. Push + inbox channels continue to flow even if email throws.
- Any future template miss (or any other email-seam exception) lands as a `notification.fanout.email_render_failed` log line carrying `event_kind`, `template_id`, `operator_id`, `user_id`, `channel`, `error.runtimeType`, `error_message`, `stack_first_frame`. Recoverable failures get surfaced; the seam-side UNIQUE indexes still guarantee idempotent retries.

## Constraints honored

- Did not touch the 9 locked V1 templates (`vendor_now_available`, `operator_admin_invite`, etc.).
- Did not touch any file outside the email registry, the three new template files, the fanout swallow site, or tests for those.
- Did not skip hooks. Did not amend.
- Did not modify trigger sites or hook bodies. The hooks already reference the three template id constants; this slice makes them resolve.
- Hierarchy-scoped settings, auth/permission/billing surfaces — none touched.

## Follow-ups (not in this slice)

- Trigger-site live wiring (passing the production `NotificationEventFanout.fanOut` as the `FanoutEnvelope` to the hooks) is already in the C3 email-lane scope; see `c_email_notification_scenario_inventory.md` §5 + §6.
- The 6 other template-only entries (mfa factor changed, vendor sync error, vendor webhook signature, vendor connection auto-disabled, tos version updated, operator-admin invite SendGrid copy) stay deferred until C3 wires their emitters.
