# PR #473 — B3 Email Silent-Failure Hot-fix — Retroactive Audit

Created 2026-05-12. Read-only audit; no code modified.

PR #473: `fix(email): B3 — wire 3 missing templates + stop silent fanout swallow`.
Merge commit: `859587f9` (Merges: `4f81a45d` + `d0b708de`). Merged 2026-05-12 03:29 UTC.
Bypass: `--no-verify` on pre-commit hook (process violation; hook itself fixed in PR #474).
Diff: 8 files, +496 / -11. No code outside the email/notification fanout surface.

---

## Verdict

**Clean — with one process flag (hook bypass) and two minor copy-fidelity notes.**

Material findings: none.
Regression risk: none observed.
Process: `--no-verify` was the agent-worktree refusal, not a substantive check.

The merged code does exactly the three things addendum B3 specifies, in exactly
the surface area the slice plan promised. Copy mirrors the user-dump phrasing
on backfill-complete and avoids the words "anchor" and "hash chain" inside the
audit-failure body. The fanout swallow site is now a typed `catch (e, st)` with
a structured log line carrying every contextual field the slice plan called for,
and push + inbox channels still flow on email-side failure.

---

## 1. Scope adherence — CLEAN

Addendum B3 (cited from
`docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` Block B row 3)
specifies exactly three actions:

> register the missing template IDs in `EmailTemplateIds.all`, create the three
> Markdown templates under `tool/advisor_proxy/email_templates/`, add typed-catch
> + log line at the fanout swallow site so future template misses surface.

Merged change set (`gh pr view 473 --json files`, 8 paths):

- `lib/services/email/email_template_renderer.dart` (+40, -0) — 3 template-id
  constants + 3 subject patterns + `EmailTemplateIds.all` append. **Specified.**
- `tool/advisor_proxy/email_templates/backfill_complete.md` (new, +20). **Specified.**
- `tool/advisor_proxy/email_templates/backfill_failed.md` (new, +22). **Specified.**
- `tool/advisor_proxy/email_templates/audit_anchor_failure.md` (new, +19). **Specified.**
- `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart` (+79, -7) —
  typed-catch + structured log seam. **Specified.**
- `test/services/email/email_template_renderer_test.dart` (+24, -4) — count
  assertion 9 → 12 + new id assertions. **Reasonable adjunct.**
- `test/services/email/notification_event_fanout_test.dart` (+186) — 3 new B3 tests
  + recording log seam. **Reasonable adjunct.**
- `docs/_execution/b3_email_silent_failure_fix/01_execution_slice.md` (new, +106).
  Slice plan. **Reasonable adjunct.**

No file outside the email + notification-fanout surface was touched
(`git diff 4f81a45d 859587f98 --stat`).
No schema, auth, billing, permission, RLS, or migration touched.
No trigger-site rewiring of `notification_event_hooks.dart` (deliberately out of
scope per the slice plan — hooks already referenced the three template ids;
this slice just made them resolve).

**Beyond addendum-strict scope but still proportional:** the `NotificationFanout
LogSeam` typedef + `defaultNotificationFanoutLogSeam` binding
(`notification_event_fanout.dart:229-247`) inject the log emitter so B3 tests
can capture records without touching `stdout`. Test-shape adaptation, not scope
expansion — production binding calls straight through to `log()`
(`notification_event_fanout.dart:244`).

---

## 2. Template copy fidelity — CLEAN, two micro-notes

### 2.1 `backfill_complete.md` — mirrors the user-dump phrasing

Body (`tool/advisor_proxy/email_templates/backfill_complete.md:5`):

> Good news. 60 days of your {{vendorName}} P.o.s data has been uploaded and your
> initial benchmark is now live in Forge & Flow.

User-dump phrasing (per the brief): *"60 days of your P.o.s data has been uploaded
and your initial benchmark is now live"*. **Match.** Vendor name interpolated in
the middle ("your {{vendorName}} P.o.s data") is a faithful extension that names
the source vendor without altering the cadence.

Plain-English check: no engineering jargon, no codes, no stack-trace exposure. Tone
is welcoming ("Welcome to a live benchmark," — line 17). CTA points to the dashboard
URL. Lists three concrete operator-facing next steps (lines 9-11). Closes with the
benchmark-finished timestamp (line 13). Conforms to the UX writing standard
(`memory/project_ux_writing_standard.md`).

### 2.2 `backfill_failed.md` — operator-friendly, reassuring, no stack trace

Subject (`email_template_renderer.dart:198`): `Your {{vendorName}} historical sync
needs attention` — operator-friendly, no jargon.

Body opens with reassurance (`backfill_failed.md:5`): *"Your benchmark for
{{businessName}} is not live yet, but your existing data is safe and nothing has
been lost."* Matches the "reassure on data safety" plank of the UX writing standard.

Failure surface is `{{errorCategory}}` (line 7), not a stack trace — exactly per
the slice plan ("operator-readable category, not stack trace"). Sample test data
populates this with `'network timeout during seed run'`
(`email_template_renderer_test.dart:79`) — a plain-language category, confirming
the slot is shaped for human-readable input.

CTA at line 15 points to the vendor connection panel
(`[Open the {{vendorName}} connection]({{vendorConnectionUrl}})`) — matches the
brief.

"The Forge & Flow support team has been alerted and is already looking into it."
(line 9) mirrors the original-dump phrasing.

### 2.3 `audit_anchor_failure.md` — AVOIDS "anchor" and "hash chain"

Full body text (`tool/advisor_proxy/email_templates/audit_anchor_failure.md:1-17`)
**does not contain** the strings "anchor" or "hash chain". Confirmed via direct
read of the merged file (`git show master:tool/advisor_proxy/email_templates/
audit_anchor_failure.md`).

Subject line (`email_template_renderer.dart:200`): `A daily integrity check on
your audit log did not complete` — no "anchor", no "hash chain".

Framing (line 3): *"A daily integrity check that Forge & Flow runs on your audit
log did not complete on {{checkDateHumanReadable}}."* Plain language; matches the
addendum's plain-language directive verbatim.

Compliance framing present (line 5): *"…we let admins know because the audit log
is the record you would reach for during a compliance review, and we want you to
hear about a gap from us first."* Matches the original-dump's compliance posture.

Reassurance present (line 5): *"This does not block anyone from using F&F, and
no operating data is affected."*

CTA: no hard CTA URL (none in the slice plan either). Reply-back path offered at
line 15: *"If you have questions or your compliance team would like a written
confirmation, reply to this email…"* — appropriate for a low-frequency
compliance-adjacent notice.

The renderer-doc comment on `EmailTemplateIds.auditAnchorFailure`
(`email_template_renderer.dart:155`) explicitly carries the same guardrail
in-source: *"Operator-facing copy avoids the words 'anchor' and 'hash chain'
per the addendum's plain-language directive."*

---

## 3. Registry correctness — CLEAN

Added constants (`lib/services/email/email_template_renderer.dart:130-156`):

```
static const String backfillComplete    = 'backfill_complete';
static const String backfillFailed      = 'backfill_failed';
static const String auditAnchorFailure  = 'audit_anchor_failure';
```

Casing + naming style match the existing nine constants
(`operatorInviteFirstAdmin`, `vendorNowAvailable`, etc.) at
`email_template_renderer.dart:84-128`. Wire-format strings (snake_case) match
the existing pattern (`vendor_now_available`, `mfa_factor_changed_notice`, …).

`EmailTemplateIds.all` append order matches doc-comment intent
(`email_template_renderer.dart:160-171`): vendor-now-available stays last in the
pre-B3 group, B3 trio appended at the end.

Subject patterns added to `_subjectByTemplate` at
`email_template_renderer.dart:195-200`:

```
backfill_complete:   'Your {{vendorName}} historical sync is complete'
backfill_failed:     'Your {{vendorName}} historical sync needs attention'
audit_anchor_failure:'A daily integrity check on your audit log did not complete'
```

All three appear in `_subjectByTemplate` (the renderer's `subjectFor()` check
at `email_template_renderer.dart:217` is the gate for "unknown template id").

Hook-side template id constants
(`tool/advisor_proxy/email_dispatch/notification_event_hooks.dart:62-64`) resolve
to the same wire strings:

```
const String kBackfillCompleteEmailTemplateId    = 'backfill_complete';
const String kBackfillFailedEmailTemplateId      = 'backfill_failed';
const String kAuditAnchorFailureEmailTemplateId  = 'audit_anchor_failure';
```

Wire-up closed. Renderer + dispatcher + hook agree on identifiers.

Count assertion in tests bumped 9 → 12 with explanatory comment block
(`test/services/email/email_template_renderer_test.dart:259-271`). New id
assertions added at lines 286-288. Consistent.

---

## 4. Fanout swallow site fix — CLEAN

`catch (_)` replaced with typed `catch (e, st)` at
`tool/advisor_proxy/email_dispatch/notification_event_fanout.dart:487`. Confirmed
via diff (`git diff 4f81a45d 859587f98 -- tool/advisor_proxy/email_dispatch/
notification_event_fanout.dart`).

Two structured log lines surface from the new path:

1. **Email-channel failure** (`notification_event_fanout.dart:507-521`):
   - event: `'notification.fanout.email_render_failed'`
   - severity: `LogSeverity.error`
   - fields: `event_kind`, `template_id`, `operator_id`, `user_id`, `channel`,
     `error.runtimeType`, `error_message`, `stack_first_frame`.
   - All 8 fields named in the slice plan are present. `stack_first_frame` is
     populated via the `firstStackFrame(st)` helper in
     `lib/services/observability/log.dart:309`.

2. **Push / inbox channel failure** (same `catch` block, event-key ternary at
   line 509-511): `'notification.fanout.channel_dispatch_failed'`. Same field
   set. Matches the slice plan's named log events.

3. **Unknown event_key** (`notification_event_fanout.dart:393-403`):
   - event: `'notification.fanout.unknown_event_key'`
   - severity: `LogSeverity.warning`
   - fields: `event_kind`, `template_id`, `operator_id`.
   - Previously this path returned silently. Now it surfaces in Cloud Logging
     before the empty `NotificationFanoutOutcome` returns.

**Re-throw not required, preserved silent recovery per slice plan.** The new
`catch` increments `skipped += 1` and continues to the next channel for the
same user (`notification_event_fanout.dart:506`). Push + inbox still flow when
email throws — confirmed by the B3 regression test
(`test/services/email/notification_event_fanout_test.dart:489-499`): driving an
email-side throw still yields `outcome.pushDispatched == 1`.

**Log seam binding** (`notification_event_fanout.dart:343-356`):
- Constructor accepts an optional `logSeam` defaulting to
  `defaultNotificationFanoutLogSeam`.
- Default binding (`notification_event_fanout.dart:244`) is the one-liner
  `log(severity, event, fields: fields)` — production wiring is the proxy's
  structured logger from `lib/services/observability/log.dart`.

---

## 5. Test coverage — CLEAN

### Renderer side

`test/services/email/email_template_renderer_test.dart:75-83` extends `sampleData`
with the seven new placeholders the three B3 templates need
(`completionTimestampHumanReadable`, `dashboardUrl`, `errorCategory`,
`vendorConnectionUrl`, `checkDateHumanReadable`, `summary`,
`retryStatusHumanReadable`).

The existing "every V1 template renders with sample data" loop
(`email_template_renderer_test.dart:104-117`, iterating `EmailTemplateIds.all`)
now exercises the three new templates against `sampleData()`. No new dedicated
per-template render test was added, but the slice plan called this out
explicitly — the loop is the canonical pattern.

Count assertion at line 274 (`expect(EmailTemplateIds.all, hasLength(12))`).
Three new `contains(...)` assertions at lines 286-288.

### Fanout side

`test/services/email/notification_event_fanout_test.dart:441-588` defines the
B3 group with three tests:

1. **`email-side dispatch failure emits notification.fanout.email_render_failed`**
   (lines 449-501). Drives an envelope through the fanout with `failOnTemplateId:
   'unknown_template_id'` on the recording email seam (lines 451-453). Asserts:
   - `outcome.pushDispatched == 1` (push still flows).
   - `outcome.emailDispatched == 0` and `outcome.skipped == 1`.
   - Exactly one log record with event `'notification.fanout.email_render_failed'`.
   - Severity is `LogSeverity.error`.
   - Every field the slice plan named (`event_kind`, `template_id`, `operator_id`,
     `user_id`, `channel`, `error.runtimeType`, `stack_first_frame`) is asserted
     present and non-empty (lines 491-500).

2. **`unknown event_key emits notification.fanout.unknown_event_key`**
   (lines 503-540). Drives an unregistered `notif.unknown.thing` envelope.
   Asserts the warning log fires with severity `LogSeverity.warning` and carries
   `event_kind`, `template_id`, `operator_id`. Matches the slice plan.

3. **`successful fanout dispatches all admitted channels for registered template
   ids (B3 regression)`** (lines 542-585). Drives the now-registered
   `backfill_complete` envelope with an explicit inbox preference row. Asserts:
   - `pushDispatched == 1`, `emailDispatched == 1`, `inboxDispatched == 1`.
   - `skipped == 0`.
   - Zero `notification.fanout.email_render_failed` log lines fire on the
     happy path.

The three required behaviors from the audit prompt — "each new template renders
successfully", "fanout dispatches all 3 channels for a now-registered template
id", "fanout fires the new structured log line when given an unknown template
id" — are all covered.

`_RecordingLogSeam` (lines 661-678) + `_LoggedRecord` (lines 680-690) are the
adjunct fakes used to capture log calls without `stdout`. `_RecordingEmailSeam`
extended with `failOnTemplateId` (line 644) for the throw-injection path.

83 total tests in `test/services/email/` per the slice plan's evidence block.

---

## 6. Hidden scope creep / risky additions — NONE

`git diff 4f81a45d 859587f98 --stat` lists exactly 8 paths (above). All are
either the source files named in addendum B3, the three new template Markdown
files named in addendum B3, the test files for those, or the slice plan.

No changes to:
- Schema / migrations (`db/migrations/**` untouched).
- Auth / permission / RLS / billing surfaces.
- Trigger-site code (`tool/integration_sync_worker/backfill_dispatch.dart`,
  `tool/first_connect_backfill_worker/main.dart`, `tool/audit_anchor/main.dart`
  — all untouched; the slice plan flagged trigger-site live wiring as out of
  scope for C3 follow-up).
- Hook helpers (`notification_event_hooks.dart` untouched; hook tests
  unchanged).
- The 6 other template-only entries (`mfa_factor_changed_notice`,
  `vendor_sync_error_alert`, etc. — all untouched).
- Operator-facing copy elsewhere (no string changes outside the three new
  templates + the subject map additions).

Slice plan's "Constraints honored" block
(`docs/_execution/b3_email_silent_failure_fix/01_execution_slice.md:99-104`)
matches the actual diff one-for-one.

---

## 7. Hook bypass impact — PROCESS VIOLATION, ZERO SUBSTANTIVE LOSS

Active pre-commit hook at the time of bypass: `git show 4f81a45d:.githooks/
pre-commit`. Two real checks plus the agent-worktree blanket refusal:

1. **Lines 9-15** (`case "$repo_root_posix" in */.claude/worktrees/*|...`):
   blanket refusal to commit from any agent worktree. **This is what
   `--no-verify` bypassed.** PR #474 (per the audit prompt) has since loosened
   this so substantive checks still run on agent worktrees.

2. **Lines 21-29**: PROJECT_TRACKER.md + code co-staged reminder. Informational
   echo only (`echo … "Reminder…"`), no `exit 1`. PR #473 did not stage
   `PROJECT_TRACKER.md`, so this would have been silent regardless.

3. **Lines 31-46**: `db/migrations/*.sql` guardrail (`migration_drift_scanner.dart
   --strict-docs` + `migration_cutoff_lint.dart`). **PR #473 staged no migration
   files** (`git diff 4f81a45d 859587f98 --stat | grep -i 'db/migrations'` returns
   empty), so this would have been a no-op.

**Net assessment:** the bypass skipped only the agent-worktree refusal. No
migration-drift, audit-log-write, or operator-scoped-RLS lint was on this hook at
the time. The hook bypass was a process violation (and the right call to fix in
PR #474), but it did not mask any substantive issue in the PR #473 change set.

---

## Follow-up items

None blocking. Two optional, low-priority items:

1. **Wire the typed-catch log seam into the trigger sites' own outcome logs.**
   The fanout now emits `notification.fanout.email_render_failed`, but
   `backfill_dispatch.dart`, `first_connect_backfill_worker/main.dart`, and
   `audit_anchor/main.dart` log only the aggregate `NotificationFanoutOutcome
   .toJson()`. If a trigger site cares about per-user email failure (e.g., for
   alert thresholds), it currently has to parse Cloud Logging rather than the
   in-process outcome. **Not a regression** — pre-B3 they had no signal at all.
   Defer to C3 if useful.

2. **Add a single per-template "rendered body contains expected fragment" assertion.**
   The current `email_template_renderer_test.dart` loop confirms each template
   renders without throwing on `sampleData()`, but no assertion pins the
   user-dump phrasing into the rendered output. A 3-line check (e.g.,
   `expect(text, contains('60 days of your'))` for `backfill_complete`) would
   catch a future copy edit that drifts the locked phrasing. **Not a regression**
   — every template is already exercised. Pure belt-and-suspenders.

Neither warrants a new slice on its own. If C3 lands a broader email-pipeline
sweep, fold them in there.

---

## Citations index

- Addendum B3:
  `docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` Block B row 3.
- Scenario inventory:
  `docs/_audits/code_health/c_email_notification_scenario_inventory.md` §5 (backfill),
  §6 (audit).
- Slice plan: `docs/_execution/b3_email_silent_failure_fix/01_execution_slice.md`.
- UX writing standard:
  `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/project_ux_writing_standard.md`.
- Merge commit: `859587f9` (Merges: `4f81a45d` + `d0b708de`).
- Pre-bypass hook: `git show 4f81a45d:.githooks/pre-commit`.
- Touched files (all under master):
  - `lib/services/email/email_template_renderer.dart:84-200`
  - `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart:215-247,
    343-356, 390-403, 487-521`
  - `tool/advisor_proxy/email_templates/backfill_complete.md:1-17`
  - `tool/advisor_proxy/email_templates/backfill_failed.md:1-19`
  - `tool/advisor_proxy/email_templates/audit_anchor_failure.md:1-17`
  - `test/services/email/email_template_renderer_test.dart:75-83, 259-288`
  - `test/services/email/notification_event_fanout_test.dart:441-588, 661-690`
