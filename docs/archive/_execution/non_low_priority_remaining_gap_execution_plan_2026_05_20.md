# Non-Low-Priority Remaining Gap Execution Plan - 2026-05-20

Status: in progress
Branch: `codex/deeper-parity-audit-wave`
Worktree: `.codex_worktrees/deeper-parity-audit-wave`

## Operator Decision

- Continue the remaining app-facing gaps.
- Skip low-priority cleanup for now.
- Do not remove legacy compatibility paths yet.
- Keep mobile Covers Setup simple; full setup remains in Operator Web.
- Keep star-target fallback behavior. A warning/reminder is enough when a
  configured service period has no selected star shifts.

## Scope For This Pass

- Correct stale docs that still describe closed gaps as open.
- Pin Learn period-specific narration with focused tests.
- Fix timing source-label mismatches found during the parallel audit:
  - Admin timezone source should show the location timezone source,
  - Admin week start should show its source,
  - Operator Web service periods should show their source,
  - demo timing should not show Shift close authority.
- Fix Wage Authority live-read/display mismatches found during the parallel
  audit:
  - proxy read responses should include scope/source fields,
  - Operator Web should show the effective wage row only when a lower scope
    overrides a higher scope.
- Keep server compatibility for old data-accuracy aliases documented as staged
  retirement, not immediate rejection.
- Confirm benchmark override writes stay fail-closed and mobile selected-star
  selection remains the active baseline-change path.
- Fold in parallel-agent findings before commit.

## Explicitly Skipped For Now

- Hidden/dead mobile wage editor cleanup.
- Polling tier per-period extensions unless a real operator workflow needs it.
- Heap snapshot UI, which remains support/pressure tooling.
- Removing old wire aliases.
- Rewriting whole-day fallback behavior.

## File Boundaries

- Docs:
  - `docs/_execution/timing_period_metadata_scope_plan.md`
  - `docs/archive/_execution/legacy_wire_alias_and_deeper_parity_plan_2026_05_20.md`
  - this execution plan
- Learn:
  - `lib/services/learn_teaching_analyzer.dart`
  - `lib/models/learn_teaching_summary.dart`
  - `lib/models/learn_benchmark_context.dart`
  - `test/learn_teaching_analyzer_test.dart`

## Safety Checks

- Keep the shared checkout on `master`.
- Work only in `codex/deeper-parity-audit-wave`.
- Do not touch unrelated Knowledge Graph docs.
- Run focused tests for any code changed.
- Run `dart run tool/ux_em_dash_lint.dart` because Learn copy changed.
- If proxy code is changed later, run the proxy pre-merge gate.

## Plain English App Examples

- If Learn finds the repeating leak in Friday Dinner, it should say Friday
  Dinner and coach to Friday Dinner's target numbers.
- If Friday Lunch is the same-day benchmark, Learn can say Friday Lunch is
  holding on plan.
- If Admin reviews Timing, timezone should read as location-owned while
  business-day and week-start values show their inherited timing source.
- If Operator Web shows Lunch or Dinner service periods, the row should also
  show where that period came from, such as Operator default.
- Shift close should not appear as a setup choice because it is automatic.
- If the business default says Server is $16.50 but a location override says
  Server is $19.25, Operator Web should show the $19.25 row only, with the
  correct "set at this location" label.
- If Admin or an old client still sends an old `covers_source_lunch` field,
  the server now rejects it with HTTP 410 and asks for the flexible keyed map.
- New Admin and Operator Web writes should keep using the flexible keyed map,
  so custom periods like `breakfast` and `happy_hour` work.

## Execution Results

- Learn period-specific narration now avoids the banned em dash and is pinned
  by a test that proves Friday Dinner uses Friday Dinner target numbers.
- Admin Timing Setup and the per-location Admin Timing dialog now label
  timezone as `Location timezone`.
- Admin timing surfaces now show `Week-start source`.
- Operator Web Business Setup service-period rows now show their source label.
- Demo Operator Web timing no longer shows `Shift close authority`.
- Wage Authority live reads now carry scope/source fields through the proxy.
- Wage Authority now hides shadowed higher-scope rows when a lower-scope row is
  the effective wage for that role.
- Legacy alias retirement remains staged and documented. No compatibility route
  was removed in this pass.
