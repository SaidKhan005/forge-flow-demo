# Gap Fix Wave 2 Execution Plan - 2026-05-19

## Plain English Goal

- Remove app controls or server writes that look successful but do not really do the full job.
- Add reset and clear paths where a manager or support user needs to fall back to inherited settings.
- Keep mobile Covers Setup intentionally simple. Full covers-source setup stays in Operator Web.
- Keep each risky area in its own PR so one fix does not blur into another.

## Starting Point

- Wave 1 landed PR #1062.
- Shared checkout stayed on `master`.
- This wave starts from updated `origin/master` at `701f717c` after
  audit follow-up PR #1063 landed.
- Worktree: `.codex_worktrees/gap-fix-wave2`.

## Batch 1 - Data Accuracy Reset And Clear

- Fix the service-period override reset gap.
  - App example: if Lunch was changed to manual covers, the manager needs a way to clear Lunch back to the inherited rule.
  - Expected shape: server reset route, Operator Web reset button, readback shows inherited/effective value.
  - Execution: Operator Web now sends an explicit reset request, the proxy deletes matching keyed rows, and the card reloads the remaining rows plus effective settings.
- Fix scoped Data Accuracy clear semantics only if it is a clean same-surface change.
  - App example: support sets an org-unit wage rule, then needs to remove it so locations inherit the business rule again.
  - Expected shape: explicit clear command or scoped delete path, audit event, inherited readback test.
  - Execution: admin scoped writes now accept explicit clear fields for per-period covers source, wage source, and walk-in handling mode; the gateway audits the clear and returns affected effective rows.
- Do not add per-period wage projection in this batch.
  - That remains a future full wiring slice.

## Batch 2 - Business Timing Route Truth

- Fix timezone ownership.
  - App example: Toronto location timing should read Toronto from the location authority, not a profile fallback.
  - Expected shape: timing profile writes omit or reject timezone, reads hydrate timezone from location authority.
- Fix PATCH truth.
  - App example: if a client sends a scope move that the server will not apply, the server should reject it instead of silently accepting it.
  - Expected shape: immutable field validation and tests.
- Fix service-period clear semantics if the route already claims to support it.
  - App example: clearing custom service periods should intentionally fall back to inherited/default periods, not fail validation by accident.
- Keep Business Timing reset UI hidden until the live reset route lands.

## Batch 3 - Sync And Retry Read Honesty

- Fix manual-cover sync hydration if it is local and bounded.
  - App example: a Dinner cover count entered on Operator Web or another phone should appear in mobile recent entries after sync.
- Fix projection retry claimability labels.
  - App example: Admin should not show an unclaimable retry row as if a worker can pick it up.
- Leave operator-facing retry warnings as a product decision unless the operator chooses to expose them.
  - App example: a manager could see "updates delayed" without stack details, but that needs a product choice.

## Product Decisions To Leave Alone For Now

- Mobile Covers Setup remains simple usage, not full setup.
- Operator Web broader-scope Data Accuracy editing remains undecided.
- Admin Business Timing editor remains undecided until support-editing direction is confirmed.
- Operator-facing projection retry warning remains undecided.

## Safety Rules

- One PR per risky area: Data Accuracy, Business Timing, sync/retry.
- Run focused tests for every touched route/widget/repository.
- Run `flutter analyze`.
- For any PR touching `lib/**`, `tool/advisor_proxy/**`, schema, or proxy routes, run `tool/pre_merge_gate.sh <PR>` before merge.
- After merge, run `tool/verify_pr_landed.sh <PR>`.
