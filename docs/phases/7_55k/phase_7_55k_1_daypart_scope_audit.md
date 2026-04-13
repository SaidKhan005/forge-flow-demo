# Phase 7.55k.1 — Daypart Scope Audit

Updated: 2026-04-12
Owner: Claude implementation
Status: Implemented

## What This Slice Delivers

An explicit classification of every daypart-aware field and surface in
Variance, History, and Learn — what scope each surface actually
operates at, what authority it reads from, and where labels or read
models currently overstate precision.

This audit is the foundation for `7.55k.2+` model and semantics work.

## Surface Classification

### Variance — This Week Tab

| Surface | Scope | Authority | Notes |
|---------|-------|-----------|-------|
| WTD summary header | WTD aggregate | `WeekData` from `WeekDataNotifier` | Aggregate of closed shifts only. `lastClosedDay` and `closedDayNumber` track progress. |
| WTD Variance table | WTD aggregate | `WeekData` getters vs locked targets | Targets from `ActiveTargetProfile` injected into `WeekData`. Model hours computed via `LaborModel`. Compares closed WTD actuals against locked plan targets. |
| Dollar Impact card | WTD aggregate | `WeekData.dollarGap` / `dollarGapAnnualized` | Dollar gap is a WTD run-rate extrapolation, not a full-week closed truth. |
| Primary Driver | WTD aggregate | `WeekData.primaryLeverId` resolved via `LeverCards` | Single lever id from the WTD aggregate driver detection. Whole-day scope — not daypart-aware. |
| Full Week Projection label | Section label | Static text | Says "FULL WEEK PROJECTION" — implies a forecast, which is structurally correct. |

### Variance — Full Week Projection

| Surface | Scope | Authority | Notes |
|---------|-------|-----------|-------|
| Day rows (collapsed) | Day aggregate | `ShiftRecord` list from `ShiftDataSource.getFullWeekShifts` | Each day row aggregates its daypart child records. Mix of closed + open + projected. |
| Daypart rows (expanded) | Daypart detail | Individual `ShiftRecord` per daypart | **This is the only surface that operates at daypart granularity in Variance.** |
| Closed daypart rows | Daypart detail — closed truth | `ShiftRecord` with `status == 'closed'` | Actual covers, sales, hours, lever. Target fields from the locked weekly plan snapshot via the shift's `targetProfileId`. |
| Open daypart rows | Daypart detail — live partial | `OpenShiftSnapshot` converted via `CurrentWeekState.shiftRecordFromSnapshot` | May carry live partial actuals. `primaryLever` is hardcoded `'ON_MODEL'` — a placeholder, not a driver claim. See `7.55m.4` audit. |
| Projected daypart rows | Daypart detail — plan placeholder | `OpenShiftSnapshot` with `status == 'projected'` converted the same way | No actuals. Forecast covers and scheduled hours from the plan. `primaryLever` is `'ON_MODEL'` — inert placeholder. |
| Day-row totals | Day aggregate | Sum of child daypart rows | Mixes closed truth + open partial + projected placeholder in one total. No scope label distinguishes which children contributed. |

**Overstatement gaps:**
- Day-row totals blend closed truth with open/projected data without
  labeling the mix. A manager cannot tell how much of a day total is
  final vs in-progress vs planned.
- `ON_MODEL` on open rows masks real deviation. Row-scope driver
  detection is not yet modeled (`7.55k.4` work).
- No per-row status badge distinguishes closed/open/projected in the
  UI. The only visual signal is the lever card color, which is
  `ON_MODEL` for all non-closed rows.

### Variance — History Tab

| Surface | Scope | Authority | Notes |
|---------|-------|-----------|-------|
| Week list | Historical week summaries | `WeekRecord` list from `ShiftDataSource.getWeekHistory()` | Each tile shows: week label, shifts completed, dollar gap, variance pts, primary lever. All from closed completed weeks. |
| `WeekHistoryTile` | Historical week summary | `WeekRecord` fields | Displays provenance label (`provenanceLabel`) showing which cycle/era the week belonged to. Added in `7.55l.7d`. |
| Week Detail screen | Historical week detail | `WeekRecord` grouped summary table | Closed-week truth with actual vs locked-target comparison. Provenance label visible. |
| Teaching summary | Historical pattern coaching | `HistoryTeachingAnalyzer.summarize(patternRecords)` | Frequency-based leak/benchmark analysis from closed shifts only. |
| Teaching summary — leak | Historical pattern | Most common unfavorable lever + top 2 daypart labels | Daypart labels come from `HistoryPatternRecord.fullLabel` (e.g. "Saturday Dinner"). |
| Teaching summary — benchmark | Historical pattern | Most common favorable lever + top 2 daypart labels | Same source. |

**Overstatement gaps:**
- "Benchmark dayparts" are frequency labels, not evidence-backed
  summaries. Saying "Saturday Dinner is a benchmark daypart" means
  it appeared favorably the most times — it does not carry average
  CPLH, sample count, or metric proof (`7.55k.5` work).
- The teaching summary has no minimum sample threshold. A single
  favorable closed shift can appear as a "benchmark daypart"
  (`7.55k.7` work).
- `HistoryPatternRecord` is a lightweight signal (lever id +
  benchmark boolean). It does not carry covers, sales, PPA, CPLH,
  SPLH, hours, or labor %. The downstream coaching can say "this
  lever repeated" but cannot say "this lever held at X CPLH"
  (`7.55k.3` work).

### Variance — History Data Pipeline

| Component | Scope | Input | Output | Notes |
|-----------|-------|-------|--------|-------|
| `HistoryPatternBuilder.fromClosedShifts` | Closed-only daypart signals | `List<ShiftRecord>` (closed only) + week labels | `List<HistoryPatternRecord>` | Correctly filters to `status == 'closed'`, skips `on_model`, validates lever id against `LeverCards.all`. |
| `HistoryTeachingAnalyzer.summarize` | Frequency summary | `List<HistoryPatternRecord>` | `HistoryTeachingSummary` | Deterministic tie-breaking. Returns most common leak, top daypart labels, most common benchmark. No metric averages. |

**What is correct:**
- Closed-only filter is explicit and tested.
- `on_model` shifts are excluded.
- Lever validation against `LeverCards.all` prevents unknown levers.

**What is missing:**
- No metric context in `HistoryPatternRecord` — only lever + benchmark flag.
- No sample-size gating in `HistoryTeachingAnalyzer`.
- `benchmarkDayparts` is a frequency label list, not a summary with
  proof.

### Learn Tab

| Surface | Scope | Authority | Notes |
|---------|-------|-----------|-------|
| Header | Week count | `weekCount` from `WeekRecord` list length | Correct — just a count. |
| Benchmark Set card | Canonical benchmark truth | `LearnBenchmarkContext` from `LearnBenchmarkContextService.resolve()` | Canonical path: active profile → active/recovered cycle → persisted `BenchmarkSelectionSummary`. Bridge values only for explicit bridge-only mode or genuine no-profile bootstrap — not a normal resolution tier. Source label, targets, range quality all from persisted authority. This is the strongest-sourced surface in the Learn tab. (See `phase_7_55l_8_learn_bridge_closeout.md`.) |
| Recurring Leak card | Historical pattern coaching | `LearnTeachingSummary.primaryLeakId/Count/SideLabel` | From `HistoryTeachingAnalyzer` frequency analysis. Same overstatement gap as History: no metric proof, no sample-size gating. |
| Repeatable Wins card | Historical pattern coaching | `LearnTeachingSummary.benchmarkDayparts` + `primaryBenchmarkId/Count/SideLabel` | Frequency-based. Says "these dayparts showed favorable patterns N times." Does not say why (no avg CPLH, PPA, covers proof). |
| Coach Next Week card | Coaching guidance | `LearnTeachingSummary.primaryFixLine/studyLine/coachToLine` | Generic teaching copy built from lever metadata + benchmark daypart labels. `coachToLine` uses real target values. `primaryFixLine` and `studyLine` use daypart labels but no metric context. |

### Learn Data Pipeline

| Component | Scope | Input | Output | Notes |
|-----------|-------|-------|--------|-------|
| `LearnBenchmarkContextService.resolve()` | Canonical benchmark | Active profile → active/recovered cycle → persisted summary | `LearnBenchmarkContext` | Canonical path is profile → cycle → summary. Bridge is not a normal third tier — it fires only for explicit bridge-only mode or genuine no-profile bootstrap. Recovery paths (8c1, 8d) repair missing cycle/summary state. |
| `LearnTeachingAnalyzer.summarize` | Combined coaching | Pattern records + week count + benchmark context | `LearnTeachingSummary` | Merges frequency-based history analysis with canonical benchmark truth. The benchmark context is strong; the pattern analysis is thin. |

**Overstatement gaps:**
- "Repeatable Wins" implies proven repeatability. The current evidence
  is lever-frequency counts from `HistoryPatternRecord` — it shows
  *how often* a favorable lever appeared at a daypart, not *what
  operational conditions made it work* (`7.55k.6` work).
- `primaryFixLine` and `studyLine` use daypart labels from frequency
  analysis. A reader might assume these are evidence-backed coaching
  recommendations, but they are pattern-frequency labels combined
  with generic lever card copy.
- No sample-size check. "Repeatable Win" can appear from a single
  favorable shift (`7.55k.7` work).

## Shift Scope (Reference Only)

Shift is documented here for boundary clarity, not for `7.55k` work.

| Surface | Scope | Notes |
|---------|-------|-------|
| Shift dashboard | Whole-day current state | Aggregates all snapshots for the current business date. Not daypart-aware. |
| Zone status card | Whole-day CPLH position | Current CPLH vs OPZ bounds. Whole-day. |
| Primary Driver section | Hidden | Hidden until Phase 10.5. Requires daypart-live truth to be meaningful. |

Shift remains whole-day until Phase 10.5. `7.55k` does not change this.

## Summary of Overstatement Gaps

| Gap | Current State | What It Implies | What Is Actually There | Owner |
|-----|--------------|-----------------|----------------------|-------|
| Full Week day-row scope | No per-row status label | All rows are equivalent truth | Mix of closed/open/projected | `7.55k.4` |
| Open-row driver | `ON_MODEL` placeholder | Row is on target | No driver detection for partial rows | `7.55k.4` |
| Benchmark dayparts | Frequency label ("Saturday Dinner") | Evidence-backed benchmark | Lever appeared favorably N times | `7.55k.5` |
| Repeatable Wins evidence | Lever frequency count | Proven operational repeatability | Count of favorable lever appearances | `7.55k.6` |
| Teaching copy proof | Generic lever card text + daypart labels | Evidence-based coaching guidance | Pattern-frequency labels + static copy | `7.55k.6` |
| Sample-size gating | No minimum threshold | All signals are reliable | Single shift can appear as benchmark/win | `7.55k.7` |
| Pattern record depth | Lever id + benchmark boolean | Rich daypart summary | No covers, sales, PPA, CPLH, hours | `7.55k.3` |

## Handoff Map

### 7.55k.2 — Service-Period Decoupling Plan

Identify all `weekId|dayLabel|daypart` keys that should become
`restaurantId|businessDate|daypart`. This audit shows the current
keys are:

- `HistoryPatternRecord`: `weekId + dayLabel + daypart`
- `ShiftRecord`: `weekId + dayLabel + daypart + businessDate`
  (plus `restaurantId`; `businessDate` persisted since 7.55f)
- `OpenShiftSnapshot`: `weekId + dayLabel + daypart + businessDate`
- `WeekRecord`: `weekId` only (week-level, no daypart)

`ShiftRecord` and `OpenShiftSnapshot` both carry persisted `businessDate`.
The remaining identity gap is in derived/history layers:
`HistoryPatternRecord` still lacks `businessDate`, and some read-model
joins still key on `weekId|dayLabel|daypart` rather than
`restaurantId|businessDate|daypart`.

### 7.55k.3 — Daypart Pattern Summary Model

Replace `HistoryPatternRecord` (lever + boolean) with a richer
`DaypartPatternSummary` carrying:
- closed shift count, benchmark count, leak count
- average covers, sales, PPA, CPLH, SPLH, hours, labor %
- exemplar source shift ids

The audit confirms this is the root model gap — every downstream
overstatement traces back to pattern records not carrying metric
context.

### 7.55k.4 — Variance Full Week Projection Semantics

From this audit:
- add per-row scope labels (closed / open / projected)
- define honest day-row totals that distinguish closed truth from
  non-final context
- replace `ON_MODEL` placeholder on open rows with honest row-scope
  driver detection or an explicit "driver not yet available" label
- consider a `VarianceWeekProjectionReadService` to move the mixed
  scope logic out of widget helpers

### 7.55k.5 — History Benchmark Dayparts Upgrade

From this audit:
- upgrade "benchmark dayparts" from frequency labels to
  `DaypartPatternSummary`-backed evidence
- show sample count and at least one metric proof (e.g., avg CPLH)
  alongside the daypart label

### 7.55k.6 — Learn Repeatable Wins Upgrade

From this audit:
- upgrade Repeatable Wins from lever-frequency counts to
  evidence-backed summaries using `DaypartPatternSummary`
- replace generic lever card copy with metric-grounded coaching
  guidance that says *why* the win repeats

### 7.55k.7 — Interim Visibility Rules

From this audit:
- add minimum sample threshold before displaying benchmark dayparts
  or repeatable wins
- show "Early signal" instead of presenting thin evidence as proven
  patterns
- hide Repeatable Wins when there are no repeated favorable patterns

### Reserved for 10.5

- Live daypart-aware Shift
- Service-period lifecycle tracking
- Real time-into-service display
- Shift primary-driver teaching (requires daypart-live truth)
- `ShiftServicePeriodReadService` or equivalent

`7.55k` does not touch Shift scope.

## Files

- `docs/phases/7_55k/phase_7_55k_1_daypart_scope_audit.md` (this doc)
