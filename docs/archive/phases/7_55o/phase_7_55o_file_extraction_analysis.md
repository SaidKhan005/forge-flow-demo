# Phase 7.55o - File Extraction Analysis

Assessed: 2026-04-12
Status: Queued after `7.55n`

This doc captures the queued file-bloat extraction plan for the `7.55o`
engineering-hygiene lane. It is planning context only until `7.55n` closes.

---

## Background

Engineering health audit identified two files that exceed healthy single-file
thresholds. Both are functional and well-tested, but their size creates merge
friction, cognitive overhead, and makes targeted testing harder.

| File | Lines | Classes/Methods | Issue |
|------|-------|-----------------|-------|
| `lib/screens/variance_report.dart` | 2,428 | 40 classes | Mixed concerns: UI, business logic, data loading, 3 duplicated widgets |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | 1,561 | ~48 methods | Monolithic bootstrap: schema DDL + 11 migrations + demo seeding + utilities |

---

## File 1: variance_report.dart

### Current structure

Three-tab screen (This Week, History, Learn) with all 40 widgets in one file.

**Class breakdown by role:**

| Role | Count | Total lines | Examples |
|------|-------|-------------|---------|
| Main screen / tab shells | 4 | ~106 | VarianceReport, _ThisWeekTab, _HistoryTab, _LearnTab |
| Tab state managers | 3 | ~207 | _HistoryTabState, _LearnTabState, _FullWeekLoaderState |
| Major section widgets | 5 | ~277 | _WtdTable (135), _FullWeekSection, _ThisWeekContent |
| Detail / expansion widgets | 5 | ~532 | _ClosedShiftDetail (167), _ProjectedShiftDetail (131), _DayRow (114) |
| Card widgets (coaching) | 6 | ~593 | _RecurringLeakCard (153), _RepeatableWinsCard (188), _BenchmarkSetCard |
| Small helpers / chips | 11 | ~392 | _SectionLabel, _TableRow, _LearnChip, _LeverBadge |
| Data containers | 3 | ~43 | _DayGroup (business logic), _HistoryData, _LearnData |

### Problems

1. **Business logic in view layer.** `_ClosedShiftDetail` (167 lines) calculates
   variance deltas, locked targets, blended wage models, and labor % inline.
   `_DayGroup` contains calculated properties (laborPct, variancePts) that belong
   in domain services.

2. **Widget duplication across files.**
   - `_SectionLabel` is duplicated in `baseline_tracker.dart` and
     `week_detail_screen.dart` (~140 LOC wasted across 3 copies).
   - `_DollarImpactCard` is duplicated in `week_detail_screen.dart` with a
     different constructor signature.

3. **Scattered data loading.** `_HistoryTabState`, `_LearnTabState`, and
   `_FullWeekLoaderState` each implement their own async loading pattern with
   no shared abstraction.

4. **Heavy service coupling.** `_LearnTabState` calls
   `LearnBenchmarkContextService.instance.resolve()` +
   `LearnTeachingAnalyzer.summarize()` directly in `initState()`.
   `_RecurringLeakCard` and `_RepeatableWinsCard` resolve lever cards from
   legacy fixture data directly.

### Recommended extraction

**Phase 1 — Shared primitives** (lowest risk, highest reuse)

Extract to `lib/widgets/`:
- `section_label.dart` — single source, replace 3 copies
- `dollar_impact_card.dart` — unify signatures, replace 2 copies
- `table_row.dart`, `metric_row.dart`, `learn_chip.dart` — small reusable primitives

**Phase 2 — Tab-specific widget groups**

Extract to `lib/screens/variance/`:
- `this_week_tab/` — _ThisWeekContent, _WtdTable, _FullWeekSection, _DayRow,
  _DayExpanded, _ClosedShiftDetail, _ProjectedShiftDetail
- `history_tab/` — _HistoryTabState, _TeachingSummaryCard
- `learn_tab/` — _LearnTabState, _LearnContent, _BenchmarkSetCard,
  _RecurringLeakCard, _RepeatableWinsCard, _CoachNextWeekCard
- `variance_report.dart` remains as the shell: tab bar + tab dispatch only

**Phase 3 — Business logic extraction** (highest value, highest risk)

- Extract `_DayGroup` calculations to a domain service
- Extract `_ClosedShiftDetail` variance math to a service method
- Move `_LearnTabState` data resolution to a dedicated provider/notifier

### Estimated scope

- Phase 1: ~5 files created, 3 files de-duplicated. Low risk.
- Phase 2: ~8-10 files created, variance_report.dart drops to ~100 lines. Medium risk — requires updating imports and ensuring private widget state is preserved.
- Phase 3: 2-3 service methods extracted. Higher risk — touches domain layer.

---

## File 2: sqlite_database.dart

### Current structure

Singleton database manager handling schema, migrations, seeding, and utilities.

**Section breakdown:**

| Section | Lines | Content |
|---------|-------|---------|
| Initialization & lifecycle | ~57 | Singleton, platform-aware setup, close/test hooks |
| Schema DDL (`_createAllTables`) | ~323 | 16 tables in one method |
| Demo data seeding | ~358 | 7 seeding methods (shifts, snapshots, profiles, replay) |
| Utilities | ~30 | Hash, date calc, introspection helpers |
| Migrations (V7–V17) | ~486 | 11 version handlers, 3 test exposures |
| Public API / mock replay | ~115 | Scenario management, reseed, clearAll |

### Mitigating factor

**DAO/repository pattern is already mature.** 13 separate DAO + repository
pairs exist for all domain entities. `sqlite_database.dart` does NOT handle
CRUD — it only owns bootstrap (schema + seed + migrate). This makes it less
urgent than variance_report.dart.

### Problems

1. **`_createAllTables()` is 323 lines.** Single method defining 16 tables.
   Hard to review changes to one table without reading all others.

2. **Migrations are inline.** V7 (68 lines) and V8 (175 lines) are large
   multi-step migrations mixed with smaller ones. No separation between
   schema-change logic and data-backfill logic.

3. **Seeding methods contain domain logic.** `_seedOpenShiftSnapshotsFromReplay()`
   (128 lines) constructs shift snapshots with business rules (daypart
   classification, cover scaling). This logic should live closer to domain.

4. **42 files import this file** — 8 data services, 13 repositories, 21 tests.
   Changes here have wide blast radius.

### Recommended extraction

**Priority: Lower than variance_report.dart.** The file is monolithic but
coherent — it's a bootstrap layer, not a mixed-concern screen.

**If/when addressed:**

1. **Migrations → `migrations/` directory.** One file per version or version
   range. Router method stays in sqlite_database.dart.
2. **Schema DDL → table group files.** Group by domain layer (restaurant,
   import, target, operational, planning). Referenced by `_createAllTables()`.
3. **Seeding → `seeders/` directory.** One seeder per domain. Called by
   `reseedMockReplayForBusinessDate()`.
4. **Utilities → `schema_helpers.dart`.** Hash, date, introspection.

### Estimated scope

- Migrations extraction: ~5 files. Low risk if each migration keeps its test exposure.
- Schema split: ~4-5 files. Low risk — pure DDL.
- Seeder extraction: ~3-4 files. Medium risk — seeding order matters.

---

## Recommendation

**Do variance_report.dart first.** It has duplicated widgets, business logic in
the view layer, and direct impact on developer velocity when touching the
variance screen. sqlite_database.dart is lower priority — its monolithic nature
is stable and the DAO pattern already isolates it from most callers.

Suggested phase sequencing:
1. Shared widget extraction (Phase 1 above) — quick win, immediate reuse
2. Variance tab extraction (Phase 2) — main payoff
3. Business logic extraction (Phase 3) — optional, highest value per line
4. sqlite_database.dart extraction — only if migration churn increases
