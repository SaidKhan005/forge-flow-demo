# PR cut-variance-daypart-toggle — Self-Audit (Pattern B, worker side)

Auditor: claude-worker on `claude/cut-variance-daypart-toggle` (worktree `agent-ac7c19ac419d0a660`).
Base: `origin/master` at `ba345300a0aae4beae814c4d72be4ed382311c26`.
Diff: 3 files, +60 / -377 vs origin/master.
Operator decision: 2026-05-15 — cut the Variance > Daypart toggle V1.

## Verdict (worker self-audit)

`approve-for-merge` (pending orchestrator re-audit).

Every chunk signs off independently against the prompt's anti-scope list,
CLAUDE.md authority order, and the three contract anchors named in
Block 2.

## Scope of cut (one paragraph)

The Variance "This Week" tab previously rendered a
`Whole Week | Daypart` toggle. The Whole Week branch is the real
variance table (TARGET / ACTUAL / VAR columns + Dollar Impact +
Primary Driver + Full Week Projection). The Daypart branch only ever
rendered raw per-service-period actuals (Covers, Sales, PPA, CPLH,
SPLH, FOH/BOH Hrs, Blended Wage) with no target column and no
variance math — the plan model holds no per-daypart targets, so the
surface could not deliver what its "Variance > Daypart" name implied.
Per the operator decision dated 2026-05-15 this PR cuts the toggle
entirely. The "This Week" tab now renders the Whole Week table
directly. The Shift dashboard's daypart cards (the per-service-period
surface) are untouched. `ShiftServicePeriodNotifier`,
`ShiftServicePeriodReadService`, `ServicePeriodAccumulator`, and
`DaypartBucketer` remain intact — Shift still uses them.

## Per-chunk findings

| Finding | file:line | Authority anchor | Fix | Verification |
|---|---|---|---|---|

### Chunk 1 — Schema migrations

CLEAN. No migrations touched. Cut is a UI-only delete.

### Chunk 2 — Repository / service layer

CLEAN. The shared `ShiftServicePeriodNotifier` /
`ShiftServicePeriodReadService` / `ServicePeriodAccumulator` /
`DaypartBucketer` are kept verbatim — Shift dashboard continues to
read them (verified: `lib/screens/shift_dashboard.dart` still imports
and consumes `ShiftServicePeriodNotifier`; `lib/forge_flow_app.dart:422`
still mounts `ChangeNotifierProvider<ShiftServicePeriodNotifier>`;
`lib/state/app_refresh_coordinator.dart` still threads
`shiftServicePeriod` for whole-app refreshes). No service-layer code
was edited.

### Chunk 3 — Proxy + auth gateways

CLEAN. Untouched.

### Chunk 4 — UI lib (the actual cut)

CLEAN against anti-scope. Cut occurred in exactly one file:
`lib/screens/variance/variance_this_week_tab.dart` (1755 → 1406 lines,
−349 net).

Concretely removed:
- `enum VarianceScope { wholeWeek, daypart }` (was at `variance_this_week_tab.dart:68` pre-cut).
- `_ThisWeekContentState` (the `StatefulWidget` state holding `_scope` + `_setScope`; pre-cut at lines 78-84).
- `_VarianceScopeToggle` widget (the segmented control; pre-cut at lines 299-333).
- `_VariancePill` widget (the toggle pill render; pre-cut at lines 335-378).
- `_DaypartVarianceLens` widget (the daypart sliver content; pre-cut at lines 386-437).
- `_DaypartVarianceCard` widget (per-period card; pre-cut at lines 439-519).
- `_DaypartVarianceDriverChip` widget (10.5.3 chip; pre-cut at lines 523-558).
- `_DaypartVarianceMetrics` widget (raw-actual metric block; pre-cut at lines 560-590).
- `_VarianceMetricRow` widget (the metric-row primitive used only by `_DaypartVarianceMetrics`; pre-cut at lines 592-620).
- The scope-toggle sliver and `if (_scope == VarianceScope.daypart) ... else ...` branch in the `_ThisWeekContent.build` slivers list (pre-cut at lines 181-200 + 286).

Concretely kept (whole-week render path):
- `ThisWeekTab` shell (`variance_this_week_tab.dart:34-59`).
- `_ThisWeekContent` (now `StatelessWidget`; `:68-258`).
- `_WtdTable` (`:281-432` post-cut) — the actual variance table with
  CONDITIONS / EXECUTION / OUTCOMES group bands and TARGET / ACTUAL /
  VAR columns — unchanged byte-for-byte except for trailing comment-
  banner glyphs (Dart parses the file identically).
- `_FullWeekLoader` / `_FullWeekSection` / `_DayRow` / `_DaypartChips`
  / `_ClosedShiftDetail` / `_ProjectedShiftDetail` /
  `_ProjectedTotalRow` / `_LeverBadge` and the dollar-impact
  + primary-lever sliver groups (`_ThisWeekContent.build` slivers list
  at `variance_this_week_tab.dart:130-256` post-cut).

Imports trimmed (verified by `grep` over the post-cut file):
- Removed: `services/shift_service_period_read_service.dart`,
  `state/shift_service_period_notifier.dart`,
  `domain/services/service_period_definition_resolver.dart`.
- Kept: `domain/models/service_period_definition.dart` (still used by
  `_FullWeekSection._servicePeriodDefinitions` at
  `variance_this_week_tab.dart:495` post-cut for the persisted-timing-
  config hand-off into `VarianceWeekProjectionReadService`).

CLAUDE.md "Architecture Guardrails" §2 (shift whole-day vs daypart):
the Hard Promise that motivated the original 10.5.2 Variance daypart
lens — *"Shift's whole-day view is authoritative; 10.5 adds daypart
alongside, never replacing"* — is preserved end-to-end. Cutting the
Variance daypart lens removes a duplicate daypart surface from
Variance; the Shift daypart cards remain the single daypart-aware
read in master.

### Chunk 5 — Tests

CLEAN.

- No test file in `test/**` references `VarianceScope`,
  `_VarianceScopeToggle`, `_VariancePill`, `_DaypartVarianceLens`,
  `_DaypartVarianceCard`, `_DaypartVarianceDriverChip`,
  `_DaypartVarianceMetrics`, `_VarianceMetricRow`, the
  `SERVICE PERIODS · TODAY` sticky-header string, or the
  `Whole Week` / `Daypart` pill labels (verified by
  `grep` over `test/`).
- `test/variance_visual_widget_test.dart` (the canonical Variance
  visual suite, 21+ tests) **does not** assert on the toggle. The
  daypart references in that file at lines 1169 + 1177 are
  `copyWithDaypart` helpers on `ShiftRecord`, unrelated to the
  Variance daypart toggle.
- No test file was deleted or modified by this PR. All Whole-Week
  variance tests stay in place.

Test runs (local; CI dark until 2026-06-01 per CLAUDE.md):
- `flutter analyze --fatal-infos lib/screens/variance/ test/screens/variance/` → `No issues found! (ran in 4.0s)`.
- `flutter analyze --fatal-infos lib/screens/ lib/state/shift_service_period_notifier.dart` → `No issues found! (ran in 14.1s)`. (Sanity-check on the kept notifier file + the broader screens tree to confirm no orphaned imports anywhere.)
- `flutter test test/screens/variance/` → **7/7 pass** (`variance_learn_tab_depth_test.dart`).
- `flutter test test/variance_visual_widget_test.dart test/variance_history_widget_test.dart test/variance_learn_history_coverage_test.dart test/variance_learn_history_parity_test.dart test/variance_week_projection_read_service_test.dart test/wtd_variance_logic_test.dart` → **178/178 pass**.

### Chunk 6 — Docs + runbooks

CLEAN. Two walkthrough docs updated with a `[CUT V1 — 2026-05-15]`
banner at the top, leaving the historic body intact so the slice's
implementation history stays readable:

- `docs/_walkthroughs/10.5.2.md:1-25` — banner names the cut, the
  rationale, the Shift carve-out, the kept infrastructure, and points
  the reader at the PR. Specifies that Step 4 ("Open Variance →
  daypart toggle"), the Variance-side authority-files row, and the
  `variance_visual_widget_test` mention later in the doc describe
  state that no longer exists in master.
- `docs/_walkthroughs/10.5.3.md:1-19` — banner specifically calls out
  that the Variance-side `_DaypartVarianceDriverChip` was cut while
  the Shift-side `_DaypartDriverChip` is unaffected; Step 5
  ("Open Variance → daypart lens") describes state no longer in
  master.

No `docs/contracts/**`, `PROJECT_TRACKER.md`,
`DATA_ALIGNMENT_TRACKER.md`, `POST_HARDENING_FOLLOWUPS.md`, or
`CLAUDE.md` edits in this PR — per worker-contract "do not update
trackers".

### Chunk 7 — Integration test harness + scripts

CLEAN. Untouched.

## 14-lens self-audit

| # | Lens | Result | Evidence |
|---|---|---|---|
| 1 | **Anti-scope respected** | PASS | No edits under `lib/screens/shift_dashboard.dart`, `lib/state/shift_service_period_notifier.dart`, `lib/services/shift_service_period_read_service.dart`, `lib/domain/services/daypart_bucketer.dart`, `lib/auth/**`, `lib/data/**`, `db/migrations/**`. Verified via `git diff --name-only origin/master` (3 files, all in `lib/screens/variance/` or `docs/_walkthroughs/`). |
| 2 | **Hard Promise #3 (no app-logic changes before 7.58)** | N/A | This is a Phase 10.5 UI surface cut, not Phase 7-8 transport. The cut removes UI plumbing only; the underlying accumulator math is untouched. |
| 3 | **Hard Promise #10 (Frontend Exposure)** | PASS | The cut is *narrowing* the frontend, not adding a non-exposed surface. Operator-facing impact documented in the two walkthrough banners. |
| 4 | **Hard Promise #11 (hierarchy-scoped settings)** | N/A | No settings, no roles, no timing, no pricing surface touched. |
| 5 | **RLS-ready schema** | N/A | No schema or repository edits. |
| 6 | **Time guardrails** | N/A | No fact-table / `TIMESTAMPTZ` edits. |
| 7 | **Proxy / API conventions** | N/A | No proxy edits. |
| 8 | **Demo Mode HP #2** | PASS | No `kDemoMode` branching introduced or removed. The cut surface was not gated on `kDemoMode`; the kept Whole Week table reads the same `WeekData` in demo and prod. |
| 9 | **Service-Layer Split** | PASS | Cut stays inside `lib/screens/`. No `lib/data/`, `lib/services/`, `lib/domain/services/`, `lib/infrastructure/**` edits. |
| 10 | **`dart analyze --fatal-infos`** | PASS | Variance scope clean (see Chunk 5). |
| 11 | **Tests** | PASS | 178/178 pass across the Variance suites named in Chunk 5. No test deletions; no test modifications. |
| 12 | **No bypass of hooks / no `--no-verify`** | PASS | Pre-commit + pre-push hooks installed via `scripts/install_git_hooks.ps1` (worker step 0). Will not pass `--no-verify` on push. |
| 13 | **No tracker / ledger / audit-doc edits outside this PR's own self-audit** | PASS | Only the worker self-audit doc (`docs/_audits/wave_2/pr_cut_variance_daypart_toggle.md`) is created. No edits to `PROJECT_TRACKER.md`, `WAVE_EXECUTION_LEDGER.md`, `NEXT_WAVE_PLAN.md`, `POST_HARDENING_FOLLOWUPS.md`, `KNOWN_FAILING_TESTS.md`, `CLAUDE.md`. |
| 14 | **Authority-doc anchor for every change** | PASS | Cut anchored to (a) the operator decision dated 2026-05-15 (Authority order #1 — active prompt), (b) the Hard Promise #6 "Advisor speaks in recommendations, not commands" / "F&F never acts on the operator's behalf at launch" guardrail (the cut Variance daypart lens added no recommendation, only raw actuals that duplicated Shift), (c) CLAUDE.md "Architecture Guardrails" §3 "Shift's whole-day view is authoritative; 10.5 adds daypart alongside, never replacing" (Shift remains the daypart surface; Variance speaks week-level variance only). |

## Citations

- `lib/screens/variance/variance_this_week_tab.dart` (post-cut, 1406 LoC) — primary surface.
- `lib/screens/variance/variance_this_week_tab.dart` (pre-cut, 1755 LoC at `origin/master@ba34530`) — for the line citations above.
- `lib/screens/shift_dashboard.dart` — Shift daypart consumer (untouched, verified).
- `lib/state/shift_service_period_notifier.dart` — kept (untouched, verified).
- `lib/services/shift_service_period_read_service.dart` — kept (untouched, verified).
- `lib/forge_flow_app.dart:422` — `ChangeNotifierProvider<ShiftServicePeriodNotifier>` mount (untouched).
- `lib/state/app_refresh_coordinator.dart` — `shiftServicePeriod` thread (untouched).
- `docs/_walkthroughs/10.5.2.md` — banner added.
- `docs/_walkthroughs/10.5.3.md` — banner added.
- `CLAUDE.md` "Hard Promises" §3, §6, §10 — authority anchors.
- `docs/_audits/audit_chunking_playbook.md` — Pattern B audit shape.

## Follow-up items

None. Operator merge approval required per the prompt's "operator
decision" status; the cut is operator-initiated and the self-audit
finds no material gaps.
