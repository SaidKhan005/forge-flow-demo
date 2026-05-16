# Per-Daypart V1 Slice 4 fix — closed-period state + honest empty-state parity (Lens Audit)

Branch: `claude/per-daypart-fix-shift-card-closed-state` · Base: `master` (`9adeea85`)
Authority: this fix prompt → `docs/contracts/core_app_architecture.md` →
`docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` (Slice 4) → `CLAUDE.md`.

## Scope

The Shift daypart card mirrored the whole-day card's section structure but not its
state machine or honest empty-state treatment. Two defects fixed:

- **1a — no closed/past-period state.** A past, already-closed period (demo Lunch
  11:00–15:00 viewed at 16:00) had no bucket → fell through the binary else-branch
  to "Projected / unavailable until this period opens." — wrong; that period
  already closed.
- **1b — phantom zeros.** Labor-unconnected rendered `LABOR % 0.0%` (computed off
  `$0 ÷ sales`); the card also collapsed to a one-line message instead of the
  full 3-section grammar.

Operator decision applied: **"Full card, dashes — maximum 1:1 parity."**

## Files changed

- `lib/state/shift_service_period_notifier.dart` — added `ServicePeriodPhase`
  enum (`shift_service_period_notifier.dart:707-720`), business-date-aware
  `resolveServicePeriodPhase(...)` top-level resolver
  (`shift_service_period_notifier.dart:722-806`), and the minimal notifier
  accessor `servicePeriodPhase(...)` (`shift_service_period_notifier.dart:171-188`).
- `lib/screens/shift_dashboard.dart` — always-render full 3-section card +
  tri-state status line (`shift_dashboard.dart:1170-1264`), new
  `_DaypartStatusLine` (`shift_dashboard.dart:1271-1318`), phase wiring
  (`shift_dashboard.dart:1077-1090`), Labor % phantom-zero fix
  (`shift_dashboard.dart:1369-1380`), COVERS sentinel-zero fix
  (`shift_dashboard.dart:1331-1337`).
- Tests: new `test/widget/shift_dashboard_daypart_closed_state_test.dart`;
  stale-assertion refresh in `test/widget/shift_dashboard_daypart_test.dart`
  and `test/shift_dashboard_daypart_toggle_widget_test.dart`.

## Pattern B — 14-lens self-audit

| # | Lens | Worker self-audit (file:line) | Independent audit |
|---|------|-------------------------------|-------------------|
| 1 | Product & user journey | Operator now sees the correct period state. Past → "Period closed" not "until this period opens" (`shift_dashboard.dart:1301-1303`); active → "Active now"; future → "Opens at {start}" (`shift_dashboard.dart:1304-1312`). Full 3-section card every state (`shift_dashboard.dart:1235-1262`). | [orchestrator] |
| 2 | Information architecture & navigation | No nav change. Status line sits inside the card under the header, not a replacement (`shift_dashboard.dart:1224-1232`). Whole-day toggle path untouched. | [orchestrator] |
| 3 | Data model, migration, RLS | None. No schema/migration/SQL; Slice-1 domain models untouched (verified — only enum + resolver + widget edits). | [orchestrator] |
| 4 | Repository & service layer | Notifier extended additively only: new enum/resolver/accessor; `_load`, `_resolveDaypartTargets`, correction paths byte-unchanged (`shift_service_period_notifier.dart:204-447`). | [orchestrator] |
| 5 | Proxy/route/gateway | N/A — pure UI/state read path. | [orchestrator] |
| 6 | Auth/roles/permissions/scope | N/A — no permission keys touched. | [orchestrator] |
| 7 | Lifecycle & destructive actions | None. No deletes/overwrites; demo seed files (`sqlite_database_seed.dart`, `mock_integration_replay_seed.dart`) deliberately NOT touched (parallel worker owns them). | [orchestrator] |
| 8 | Background workers/deploy/startup/health | N/A. | [orchestrator] |
| 9 | UI state, UX, accessibility | Honest "—" everywhere actuals are missing; Labor % null when no labor punches (`shift_dashboard.dart:1369-1380`); COVERS "—" when 0 (`shift_dashboard.dart:1331-1337`); locked targets always render (`_DaypartInputsSection` unchanged). Status copy is plain-English training tone (UX Writing Standard). Metric Honesty: no phantom zeros — verified via tests asserting `0.0%`/`$0.00`/`Target 0.00` findsNothing. | [orchestrator] |
| 10 | Performance & data loading | Phase resolution is O(periods) wall-clock math, no I/O; reuses existing `resolveActiveServicePeriodId` + `BusinessDateResolver`. No extra rebuilds. | [orchestrator] |
| 11 | Mobile/web/admin/API parity | Shift mobile surface only; daypart sits adjacent to whole-day (Promise 3 / Layer 9). Whole-day render path byte-untouched — proven by `shift_dashboard_daypart_parity_test.dart` "whole-day half is untouched" + new file's "byte-untouched" test. | [orchestrator] |
| 12 | Tests, builds, evidence | `dart analyze` clean on all touched files (0 issues). 24/24 green across the 4 daypart files. 4 unrelated failures (`shift_dashboard_empty_state`, `shift_visual_widget` — whole-day DRIVER/"In the books"/spinner) confirmed identical (`-4`) on pristine base `9adeea85` via detached baseline worktree → pre-existing, not regressions. CI dark (commands disclosed in PR). | [orchestrator] |
| 13 | Observability/audit/supportability | Status text is deterministic from phase; no logging surface. Resolver docstring documents the business-weekday + inclusive-end + rolls-past-midnight rules (`shift_service_period_notifier.dart:733-758`). | [orchestrator] |
| 14 | Docs/tracker/prompt hygiene | Trackers/ledgers/memory NOT touched (worker contract). Card + status-line docstrings updated to describe new behavior (`shift_dashboard.dart:1100-1138`, `1271-1283`); stale test comments refreshed. This audit doc added. | [orchestrator] |

## Time guardrail compliance

Past/active/future is derived from the **same** business-date-aware clock the
active chip uses: `resolveActiveServicePeriodId` → `BusinessDateResolver`
(`shift_service_period_notifier.dart:761-806`). No raw `DateTime.now().weekday`;
no naive-vs-tz instant comparison — wall-clock-of-day Duration math mirrors
`resolveActiveServicePeriodId` exactly so the status line cannot disagree with
the ACTIVE NOW chip.

## Residual risks / known consistent behavior

- A closed-with-no-data period whose stamp carries a locked OPZ band renders the
  shared `ZoneStatusCard` with `CURRENT CPLH 0.00` (existing
  `_DaypartFohProductivitySection` behavior, `shift_dashboard.dart` unchanged
  there). This is the same shared widget the whole-day card uses given zero
  inputs — byte-consistent by construction, not a new phantom introduced here.
  The honest empty state ("No locked productivity zone…") still applies when no
  locked band exists. Out of this fix's scope; noted for orchestrator visibility.
- `rolls-past-midnight` non-active periods resolve to `future` (documented at
  `shift_service_period_notifier.dart:751-758`); demo dayparts Lunch/Dinner do
  not roll, so this is exercised only by Late Night on its applicable days.

## Decision stops

None — operator decision ("Full card, dashes") was pre-supplied in the prompt.
No auth/RLS/schema/proxy/ceiling-raise touched.
