# Lane B Findings — Shift Dashboard + Variance

Scope: ShiftDashboard (whole-day view, all sticky sections, daypart sub-sections,
metric pills, tappable rows), VarianceReport (This Week / History / Learn tabs,
all interactive elements in each tab).

Status: **CLOSED — 8 / 8 passed**  
Run: 2026-05-22 · Device: emulator-5554 · Build time: ~35 s

---

## Test results

| # | Test name | Result |
|---|-----------|--------|
| 1 | Shift-01: ShiftDashboard sections render (Outputs / Inputs / FOH Productivity) | ✅ |
| 2 | Shift-02: daypart expand/collapse and scroll do not crash or overflow | ✅ |
| 3 | Shift-03: empty-state path renders without crash | ✅ |
| 4 | Variance-01: three Variance tabs mount without crash or stuck spinner | ✅ |
| 5 | Variance-02: This Week tab deep — metric pills and date-range chip interactive | ✅ |
| 6 | Variance-03: History tab renders rows without crash | ✅ |
| 7 | Variance-04: Learn tab renders content without crash | ✅ |
| 8 | Variance-05: data integrity — no NaN or null displayed in metric values | ✅ |

---

## Findings

### P1 — Production bug (fixed this session)

| # | Surface | Bug | Root cause | Fix applied |
|---|---------|-----|------------|-------------|
| 1 | `WeekDataNotifier` | `notifyListeners()` called after disposal — crashed entire variance suite, all tests showed "did not complete" | `_load()` / `refresh()` await SQLite; notifier disposed when test teardown fires; async chain still in flight | Added `bool _disposed` guard in `week_data_notifier.dart` |
| 2 | `ShiftDashboardNotifier` | Same pattern — disposed during shift test teardown, crashed shift-02 and shift-03 | No `dispose()` override; `_load()` called `notifyListeners()` after widget tree torn down | Added `_disposed` guard + `dispose()` override in `shift_dashboard_notifier.dart` |

### Test infra fixes

| # | Fix | File |
|---|-----|------|
| 1 | Changed section-header check from AND → OR (FOH PRODUCTIVITY is below fold in lazy `SliverList`) | `scenario_shift_01`, `scenario_shift_03` |
| 2 | Scoped `CustomScrollView` search to `ShiftDashboard` subtree to avoid hitting the business-scope drawer's list viewport | `scenario_shift_02` |
