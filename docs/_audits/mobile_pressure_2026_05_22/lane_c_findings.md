# Lane C Findings — Plan (ScheduleBuilder) + Benchmark (BaselineTracker)

Scope: ScheduleBuilder (Plan tab, bottom-nav index 2, all interactive elements),
BaselineTracker (Benchmark tab, bottom-nav index 3, tap-to-drill to BaselineManagerScreen),
BaselineManagerScreen sub-screens: calendar, day_sheet, preview, lens, band, actions.

Status: **CLOSED — 7 / 7 passed**  
Run: 2026-05-22 · Device: emulator-5554 · Build time: ~43 s

---

## Test results

| # | Test name | Result | Time |
|---|-----------|--------|------|
| 1 | Plan tab: ScheduleBuilder mounts with section headers, no stuck spinner, no overflow | ✅ | 8 s |
| 2 | Plan tab: day-row expand/collapse and scroll do not crash or overflow | ✅ | 11 s |
| 3 | Benchmark tab: BaselineTracker mounts with content, no stuck spinner, no overflow | ✅ | 13 s |
| 4 | Benchmark tab: tapping manager CTA pushes BaselineManagerScreen, no crash, no overflow | ✅ | 15 s |
| 5 | BaselineManagerScreen: all sub-components mount with content, no overflow | ✅ | 18 s |
| 6 | BaselineManagerScreen: interactive elements respond without crash or overflow | ✅ | 23 s |
| 7 | BaselineManagerScreen: CANCEL pops back to BaselineTracker, no dispose crash | ✅ | 26 s |

---

## Findings

### P2 — Production layout issue (not blocking)

| # | Surface | Issue | Detail | Recommended fix |
|---|---------|-------|--------|-----------------|
| 1 | `BaselineManagerScreen` — "CLEAR ALL" button | Button rendered at y = −15.1 dp (15 dp above the top of the 826.9 dp screen) | Flutter warning: `Offset(333.5, -15.1) … outside the bounds … Size(392.7, 826.9)`. Button is unreachable by a real user without scrolling the sheet header upward. Test taps are gracefully suppressed (warning only, not a failure). | Add a `SingleChildScrollView` or adjust the bottom sheet's `initialChildSize` / `maxChildSize` so the header buttons stay on-screen. |

### Test infra fixes

| # | Fix | File |
|---|-----|------|
| 1 | Added `tester.ensureVisible()` before expand-icon taps — first icon was rendered ~22 dp below the 826.9 dp screen bottom | `scenario_plan_02_interactions.dart` |
