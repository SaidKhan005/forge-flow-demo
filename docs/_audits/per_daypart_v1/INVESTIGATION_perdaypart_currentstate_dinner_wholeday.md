# INVESTIGATION — Per-Daypart Shift card: Dinner shows the whole-day total on Saturday

> ## ✅ RESOLVED in source — 2026-05-16, master `b7d53df5`
> Baselined at `e8601d5b`. The root cause (demo weekly-slot calendar had NO
> Lunch slot on Saturday/Sunday, open shift pinned to dinner → Whole Day ≡
> Dinner on weekends) was fixed by PR #843 (`66699ac8`, weekend Lunch +
> clock-derived open shift). PR #854 then guaranteed a connected location's
> Shift home is never blank between services. Device-verified 2026-05-16
> (Saturday): Downtown Shift at 4:47 PM shows a full live whole-day card with a
> Whole Day / Lunch / Dinner / Late Night selector. **Closed.**

**Status:** READ-ONLY audit. No code changed. Master baseline = `e8601d5b`.
**Surface:** Shift dashboard per-daypart selector (Whole Day / Lunch / Dinner / Late Night).
**Device ground truth:** Harbour (`demo_restaurant_harbour`), Saturday 2026-05-16, wall clock 09:25.
Whole Day = SALES $5,353 / COVERS 123 / PPA $43.52. Dinner = the **identical**
$5,353 / 123 / $43.52 (Forecast $8,530, CPLH 10.25, blended wage $0.00,
"PRIMARY DRIVER SPLH up", provenance "Unknown"). Lunch + Late Night honest-empty.

---

## 1. Definitive root cause

**Primary mechanism = (i) a demo-seed data-modeling artifact, specifically the
weekly-slot calendar, NOT a per-period read/rollup/fallback bug and NOT a
time-anchor bug.** The per-period read path and the time/lifecycle logic are
behaving exactly as designed. The defect is that on **Saturday the demo
calendar defines only two service periods — `dinner` and `late_night`, with NO
`lunch` slot** — and the scenario unconditionally pins the single `status='open'`
shift to **`dinner`**. The consequence is:

- On Saturday the *only* actuals-eligible (`status IN ('closed','open')`)
  snapshot for the business date is the **Dinner `open`** snapshot.
- Whole-Day aggregates `closed + open` snapshots → that is *just the Dinner
  open snapshot* (no Saturday lunch shift exists; Late Night is `projected`,
  excluded).
- The Dinner per-period bucket is synthesized from that *same single Dinner
  open snapshot*.
- Therefore Whole Day ≡ Dinner is **arithmetically inevitable**: on Saturday
  the whole day *is* Dinner. They are equal because they are computed from the
  exact same one row, not because a per-period read mis-joined or fell back to
  a whole-day row.

This is the (b)/(d) family from the mandate's option list, refined: **(b)** "the
seeded `open` current-week snapshot is anchored to Dinner while Lunch/LateNight
are projected/absent" is correct, with the crucial Saturday-specific addition
that **Lunch is *absent from the calendar entirely* (not merely projected)**, so
there is no second period to dilute the whole-day rollup. It is *not* (a) (no
mis-join / no whole-day-row fallback in the per-period path), *not* (c) (the
bucketer is not dumping all-day covers into Dinner — there is only Dinner data
to begin with), and only incidentally (d) (the seed does not "write the day's
running totals onto Dinner"; it writes Dinner's *own* mid-service running total,
which simply *is* the whole day because Dinner is the whole Saturday actuals
set).

### Why this is a defect anyway

The numbers are internally consistent but **dishonest for the wall clock**. At
09:25 the Dinner service (opens 17:00) has not occurred. The Dinner `open`
snapshot is a *fabricated mid-service* state (`openProgressFraction = 0.63`,
`timeLabel = '7:45 PM'`, `serviceElapsedLabel = '3h 15m into service'`) seeded
with no relationship to the device's wall clock. The demo's "now" is pinned to
mid-Dinner-service regardless of device time (see §3). So Dinner renders running
actuals for a period that, by the device clock, has not started — violating
Metric Honesty / Design Rule 2. Lunch and Late Night look honest only by
accident: Lunch because there is no Saturday lunch row at all, Late Night
because it is `projected` (filtered out). Dinner is the one period the scenario
forces "open", so it is the one that surfaces fabricated numbers.

---

## 2. Exact file:line trace

### 2.1 The Saturday calendar has no lunch; current-day dinner/late_night are projected
`lib/dev/mock_integration_replay_seed.dart:202-210` — `weekSlots`:
```
('Sat', 'dinner'), ('Sat', 'late_night'),   // line 208 — NO ('Sat','lunch')
```
`lib/dev/mock_integration_replay_seed.dart:220-228` — `_daypartRatios['Sat'] =
{'dinner': 0.775, 'late_night': 0.225}` (no lunch key) confirms Saturday is a
two-period day by design.

`lib/dev/mock_integration_replay_seed.dart:857-890` — `_generateCurrentWeekForDate`:
for the current day (`slotDayIndex == dayIndex`), line 876-877 sets
`status = slot.$2 == 'lunch' ? 'closed' : 'projected'`. On Saturday there is no
lunch slot, so both Saturday slots (`dinner`, `late_night`) are generated with
`status='projected'`. **No Saturday `closed` shift is generated.**

### 2.2 The scenario unconditionally pins the open shift to Dinner
`lib/dev/mock_integration_replay_seed.dart:418-424` —
`scenario = MockReplayScenario(... openShiftDayLabel: dayLabel,
openShiftDaypart: 'dinner')`. Comment line 418: "Open shift is always dinner".
`openShiftDaypart` is the literal `'dinner'` for every business date, every
weekday, every location.

### 2.3 The snapshot builder makes Dinner the sole actuals-eligible row on Saturday
`lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:162-282` —
`_buildCurrentWeekOpenShiftSnapshots`:
- Lines 168-204: `projectedShifts` (Sat = dinner + late_night) emitted as
  `status='projected'`, *except* the `(openShiftDayLabel, openShiftDaypart)`
  slot is skipped (lines 175-178).
- Lines 206-247: the skipped slot `(Sat, dinner)` is re-emitted as the single
  `status='open'` snapshot. `openCovers = (openShiftPlan.forecastCovers ×
  MockIntegrationReplaySeed.openProgressFraction).round()`
  (`openProgressFraction = 0.63`, defined at
  `mock_integration_replay_seed.dart:342`). Its covers/sales are Dinner's own
  ~63%-through figures — **this is where 123 covers / $5,353 originates**, and
  Forecast $8,530 ≈ Dinner full-forecast × locked PPA.
- Lines 249-279: `currentDayClosed = currentWeekShifts.where(dayLabel ==
  scenario.openShiftDayLabel && status == 'closed')`. On Saturday this set is
  **empty** (no Saturday lunch slot exists, and dinner/late_night are
  `projected`, not `closed`). So **zero `closed` Saturday snapshots are
  written.**

Net Saturday snapshot set for the business date: **Dinner(`open`) +
LateNight(`projected`)** only.

### 2.4 Whole-day rollup = closed+open = just the Dinner open snapshot
`lib/state/shift_dashboard_notifier.dart:104-161` —
`getCurrentBusinessDate` (returns the `status='open'` row's `business_date`,
i.e. Dinner's) → `getSnapshotsForDay` → `ShiftDashboardReadModel.buildWholeDay`.
`lib/models/shift_dashboard_read_model.dart:344-358` — `buildWholeDay`
aggregates `actualSnapshots = snapshots.where(status == 'closed' || status ==
'open')`. On Saturday that filter yields **only the Dinner open snapshot**, so
`totalCovers`/`totalSales` (lines 349-357) = Dinner's 123 / $5,353. Late Night
`projected` is correctly excluded (Metric Honesty).

### 2.5 Dinner per-period bucket = the same single Dinner open snapshot
`lib/state/shift_service_period_notifier.dart:313-335` — `_load`:
- Line 313-314: `getSnapshotsForDay` → Dinner(open) + LateNight(projected).
- Line 315-316: `relevant = snapshots.where(s.status == 'closed' || s.status
  == 'open')` → **only Dinner(open)**.
- Lines 318-322: `synthesizeCanonicalFactsFromSnapshots(snapshots: relevant,
  …)` → for the Dinner snapshot only, emits one POS line at the Dinner period
  midpoint (`covers = s.currentCovers`, `sales = s.currentCovers ×
  s.currentPPA`) and FOH/BOH punches (`shift_service_period_notifier.dart:
  632-674`).
- Line 330-335: `_readService.build(...)` buckets that single Dinner POS line
  into the Dinner `ServicePeriodAccumulator`. The Lunch + Late Night buckets
  receive nothing → honest-empty.

`lib/screens/shift_dashboard.dart:299-312` — the selected-period sliver pulls
`bucket = periodNotifier.buckets[Dinner]` and renders it via
`_ShiftSectionViewData.fromPeriod` (`shift_dashboard.dart:814-959`).
`fromPeriod` uses `bucket.sales` / `bucket.covers` / `bucket.ppa` directly
(lines 943, 950, 952). Because the Dinner bucket was built from the *same single
Dinner open snapshot* that whole-day aggregated, `fromPeriod`'s Dinner output is
byte-equal to `buildWholeDay`'s output. **No fallback, no mis-join, no
whole-day-row borrow occurs** — the equality is a data-set identity, not a
read-path bug. The Dinner blended-wage $0.00 / provenance "Unknown" is a
separate cosmetic seam (the per-period synthesizer's wage/provenance string —
see §5 + in-flight-branch note), not the cause of the value equality.

### 2.6 Per-period target context is not the cause
`shift_service_period_notifier.dart:389-515` `_resolveDaypartTargets` only
supplies the *locked target / plan-side footer* fields
(`forecastSales`, `requiredFohHours`, OPZ band). The displayed actuals
($5,353 / 123 / $43.52) come from `bucket`, not `tc`. `tc.forecastSales`
(Dinner's locked per-daypart `forecast_sales` from the in-force
`WeeklyPlanSnapshot`) explains the **Forecast $8,530** footer (a legitimate
pre-service plan number). It does not drive the actuals.

---

## 3. Current-state TIME logic — demo "now" is pinned, not wall-clock-driven

- **Business date** is today-anchored: `sqlite_database.dart:271-278`
  `_coldBootAnchorIsoDate()` = `DateTime.now().toUtc()` date →
  `MockIntegrationReplaySeed.generateForDate(today)`
  (`sqlite_database.dart:345-347`). So the business date correctly tracks the
  device day (Saturday 2026-05-16) and the weekday-correct calendar (Sat =
  dinner+late_night) is selected. **This part is correct.**
- **Which period is "open" is NOT wall-clock-driven.** It is the scenario's
  hardcoded `openShiftDaypart='dinner'`
  (`mock_integration_replay_seed.dart:423`). The open snapshot is a *fixed
  mid-Dinner-service fabrication*: `openProgressFraction = 0.63`,
  `openShiftTimeLabel = '7:45 PM'`, `openShiftServiceElapsedLabel = '3h 15m
  into service'` (`mock_integration_replay_seed.dart:342-344`). None of these
  consult the device clock. So at device 09:25 the demo still presents Dinner
  as "open, 3h 15m into service" with 63%-of-forecast covers.
- **The reader's tri-state phase logic is correct and consistent.**
  `shift_service_period_notifier.dart:733-890`
  (`resolveActiveServicePeriodId` / `resolveServicePeriodPhase`) use the
  restaurant-local wall clock + business-date weekday — so the *header chip*
  ("Opens at 17:00" / "Active now" / "Period closed") will say Dinner is
  *future* at 09:25. The contradiction the operator sees — a "future" Dinner
  header above live Dinner numbers — is the visible symptom of the seed/clock
  mismatch, not a bug in the phase resolver. The phase resolver is telling the
  truth; the seeded snapshot is not.

**Conclusion for §3:** the business-date anchor is correct; the *intra-day
"which period is live and how far into it"* is a fixed seed fabrication
divorced from the wall clock. Lunch (earlier) shows empty only because the
Saturday calendar has no lunch row; Late Night shows empty only because it is
`projected`. Dinner shows data solely because the scenario nails the open shift
to Dinner. This is **seed design, surfacing as a bug** when the per-daypart
selector lets the operator inspect a not-yet-occurred period against the real
clock.

---

## 4. Per-location / per-daypart matrix (from SEED code, not device)

`_seedHistoricalOpenShiftSnapshotsFromReplay`
(`sqlite_database_seed.dart:2350-2431`) calls the **same**
`_buildCurrentWeekOpenShiftSnapshots` with the **same** `replay.scenario`
(line 2418-2423) for every non-Downtown location, feeding each its own
`_envelopeShiftsForLocation`-scaled shifts (line 2363-2364). Downtown is owned
by `_seedOpenShiftSnapshotsFromReplay` (`sqlite_database_seed.dart:294-309`),
same builder, same scenario.

Therefore, for the **Saturday** business date, **all 4 DemoScope locations**
(`demo_restaurant_001` Downtown, North Loop, Riverside, Harbour) get the
identical current-day shape:

| Period (Sat) | Calendar slot exists? | Seeded current-week status | In actuals set (`closed`/`open`)? | Figures scope |
|---|---|---|---|---|
| Lunch | **No** (`weekSlots` has no `('Sat','lunch')`) | — (no row) | No | n/a → honest-empty |
| Dinner | Yes | **`open`** (scenario pins it) | **Yes** | Dinner's own ~63% mid-service running total |
| Late Night | Yes | `projected` | No (projected excluded) | n/a → honest-empty |

The "open" daypart's figures are **period-scoped to Dinner** (Dinner's own
forecast × 0.63), *not* a whole-day-scoped write. They merely *equal* whole-day
because Dinner is the only member of the Saturday closed+open set. **The
Dinner=whole-day fingerprint is uniform across all 4 locations on any Saturday
business date — it is NOT Harbour-specific.** Harbour was simply the location
in view. (Contrast: on a Mon–Fri business date, Lunch *is* in `weekSlots` and
*is* seeded `closed` on the current day, so whole-day = Lunch(closed) +
Dinner(open) ≠ Dinner alone — the fingerprint does not appear. The defect is
specific to **Saturday and Sunday** business dates, the two days whose calendars
have no lunch slot. Sunday is even more extreme: `weekSlots` line 209 = only
`('Sun','dinner')`, so Sunday whole-day ≡ Dinner with Late Night absent too.)

---

## 5. Honest-state classification of the Dinner behavior

| Honest state | Should render | Is this Dinner@09:25-Sat? |
|---|---|---|
| Genuinely in-progress open shift (mid-service) | running numbers | **No** — Dinner has not started by the device clock (opens 17:00; it is 09:25). The "in-progress" is a fixed seed fabrication, not real elapsed service. |
| Projected upcoming period | MAY show a forecast (no actuals) | This is what Dinner *should* be at 09:25 (forecast $8,530 only). |
| Not-yet-started period, no actuals | honest-empty, never whole-day total | **This is the correct target state for Dinner@09:25.** Instead it shows running actuals. |

**Verdict:** Dinner is presenting the *mid-service running-numbers* state for a
period that is honestly in the *projected/not-yet-started* state per the real
clock. The phase resolver (§3) already classifies it `future`; the seed feeds
it `open` actuals. Mismatch ⇒ Metric Honesty / Design Rule 2 violation.

---

## 6. Single definitive root cause (one sentence)

The demo scenario unconditionally seeds the day's single `status='open'`
snapshot onto **Dinner** with a fixed mid-service (`0.63`) fabrication divorced
from the device wall clock (`mock_integration_replay_seed.dart:342,423`), and on
**Saturday/Sunday** the `weekSlots` calendar has **no lunch slot**
(`mock_integration_replay_seed.dart:202-210`) so no Saturday `closed` snapshot
is ever generated (`sqlite_database_seed.dart:249-279`) — making the Dinner open
snapshot the *sole* member of the closed+open actuals set, so Whole Day and
Dinner are computed from the identical one row and are therefore equal, while
the period that (by the real clock) has not yet occurred is shown with live
running numbers.

**Classification: (i) demo-seed data-modeling + (iii) seed "now" vs wall-clock
mismatch. NOT (ii) a per-period read/rollup/fallback bug** — the read path,
bucketer, whole-day aggregator, target-context resolver, and phase resolver are
all behaving correctly given the data they were handed.

---

## 7. PLAN-ONLY remediation (no code changed here)

### Scope verdict
The correct fix is **seed-only + lifecycle (IN SCOPE / auto-fixable)**. The
core per-period read path, `LaborModel`, the snapshot-bucketing contract, the
whole-day aggregator, and the phase resolver are all correct and **must not be
touched**. No `demo_*` table and no `kDemoMode` reader fork are involved or
needed. This stays inside the demo-data/seed + lifecycle guardrail.

### Option A (recommended, smallest honest fix) — clock-aware open-shift selection in the seed
Make `_buildCurrentWeekOpenShiftSnapshots` / the scenario derive which daypart
(if any) is `status='open'` from the **restaurant-local wall clock at seed
time** instead of the hardcoded `openShiftDaypart='dinner'`:
- If the wall clock is inside a service period's window → that period is
  `open` with covers scaled by *real* fraction-into-service (replace the fixed
  `0.63` with `elapsed / periodLength`).
- If the wall clock is *before* the first period → **no `open` snapshot**;
  earlier-today periods that already closed are `closed`, all upcoming periods
  `projected`. At 09:25 Saturday: Dinner + Late Night both `projected` → Whole
  Day + every period honest-empty/forecast-only. Correct.
- If between periods → prior `closed`, next `projected`, none `open`.
This makes the demo "now" track the device clock end-to-end and Dinner stops
showing actuals before 17:00. Touches: `mock_integration_replay_seed.dart`
(scenario open-slot derivation + progress fraction),
`sqlite_database_seed.dart` (`_buildCurrentWeekOpenShiftSnapshots` consuming a
clock-derived open slot). Pure writer-side; readers unchanged.

### Option B (narrower, partial) — keep fixed scenario but gate by phase at render
Not recommended: would require the reader to suppress a seeded `open`
snapshot's actuals when `resolveServicePeriodPhase == future`, i.e. a
reader-side behavior change on a non-demo path → **closer to (ii)/contract
territory; ESCALATE.** Rejected in favor of Option A which keeps the change
writer-side.

### ESCALATE (do NOT auto-fix)
- Any change to `ShiftDashboardReadModel.buildWholeDay`'s closed+open
  aggregation rule, `_ShiftSectionViewData.fromPeriod`, the
  `DaypartBucketer`/`ShiftServicePeriodReadService` contract, or
  `LaborModel` — these are correct; altering them to paper over the seed
  artifact would corrupt the production path.
- Adding a Saturday/Sunday lunch slot to `weekSlots` purely to dilute the
  rollup — that is a demo *content* decision (changes every Saturday/Sunday
  demo narrative, recommendation cohort, Variance, History) and should be an
  explicit operator-approved demo-dataset decision, not a silent fix. Flag for
  decision; do not bundle into the clock fix.

### Recommended sequencing
1. Land Option A (clock-aware open-slot + real progress fraction) — seed-only,
   in scope, fixes the honesty violation directly.
2. Separately raise the "Saturday/Sunday have no lunch slot — is that the
   intended demo narrative?" question to the operator as a demo-dataset
   content decision (independent of the bug fix).

---

## 8. Interaction with in-flight branch `claude/fix-qa-shift-labor-provenance-vendorid-wiring`

That branch (Defects 1–3, same Shift surface) targets **labor/provenance/
vendorId wiring** — i.e. the Dinner card's `BLENDED WAGE $0.00` and provenance
`"Unknown"` cosmetic seams, which originate in the per-period synthesizer's
wage/provenance strings (`shift_service_period_notifier.dart:654-672` punch
`hourlyWage = s.blendedWage`; `shift_dashboard.dart:846-848` `liveOr(...)
provenance: 'vendor_unknown'`). That is a **different code path** from this
investigation's root cause (the seed open-slot/calendar selection in
`mock_integration_replay_seed.dart` + `sqlite_database_seed.dart`
`_buildCurrentWeekOpenShiftSnapshots`). Option A here does **not** touch
`shift_dashboard.dart`, `shift_service_period_notifier.dart` rendering, the
read model, or provenance strings — so there is **no file-level collision** with
the provenance/vendorId branch. One caution: that branch may change blended-wage
behavior such that the *currently-$0.00* Dinner figure becomes non-zero; if
Option A also changes which/whether a snapshot is `open` on Saturday, validate
the two together on a Saturday business date so the combined demo state stays
honest (no `open` Dinner before 17:00 AND correct wage/provenance when a period
legitimately is open). Recommend landing/auditing them sequentially, not
merging both blind.
