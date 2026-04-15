# Temporary Alignment Findings â€” 2026-04-12

Status: temporary working note  
Owner: Codex synthesis pass  
Authority: not tracker authority; use for the next planning merge only

## Purpose

This note captures the current state of the user's latest logic and surface
questions before the next brain dump. The goal is to combine:

- this note
- the next user brain dump
- the active roadmap
- the older refactor/decoupling context

into one cleaner planning decision.

This note is intentionally broader than the active slice prompts. It is a
planning/sanity-check artifact, not an implementation spec.

## Snapshot Summary

| Topic | Current state | Planned owner | Notes |
|---|---|---|---|
| History benchmark tie ordering | Addressed | Landed in `7.55k.5a` | Explicit canonical tie-break now exists. |
| Shift header clock | Addressed | Landed in `7.55m.3` | Header now uses a live ticking wall clock. |
| Shift `time into service` | Addressed | Reserved for `10.5` | Removed from active Shift UI; live service tracking remains future work. |
| Variance closed/open/projected row honesty | Addressed at current scope | Landed in `7.55k.4` / `7.55k.4a` | Read-service seam now exists; timing foundation beneath it is still incomplete. |
| History benchmark evidence | Addressed at current scope | Landed in `7.55k.5` / `7.55k.5a` | Compact evidence rows now exist. |
| Learn repeatable wins evidence | Addressed at current scope | Landed in `7.55k.6` / `7.55k.6a` | Evidence path now exists; visibility policy added in `7.55k.7`. |
| Thin-sample visibility policy | Addressed at interim scope | Landed in `7.55k.7` / `7.55k.7a` | Strong vs early-signal behavior now exists. |
| Business date / week start / reset logic | Partially addressed | `7.55n.1` through `7.55n.4` | Core contracts exist; runtime seam still incomplete. |
| Variable service periods / variable count of dayparts | Not yet addressed in runtime | `7.55n` lane | Current runtime still has hardcoded fixture-era daypart assumptions. |
| Shift driver freshness / trustworthiness | Partially addressed | needs explicit follow-up lane | Logic exists, but the surface can still feel stale or confusing. |
| Variance primary-driver logic relationship to Shift | Partially addressed | needs explicit follow-up lane | Both have logic, but they operate on different scopes and that is not obvious enough. |
| History rollover semantics | Partially addressed | `7.55n.5` plus follow-up audit | Closed-truth path exists, but week finalization still assumes fixture-era structure. |
| Benchmark OPZ width / graph honesty | Partially addressed | needs explicit follow-up lane | Logic exists for narrow/good/wide, but the graph can still read misleadingly. |
| Mock-day advance affecting downstream plan | Needs audit | needs explicit follow-up lane | Some movement is expected; locked-week rewrites would be a bug. |
| Plan labels / section naming | Mostly addressed | optional polish lane | Labels already exist; wording may still want product cleanup. |
| Notifications for week/cycle/timing changes | Planned in contracts, not yet runtime-complete | needs explicit follow-up lane | Contracts call for passive notifications; no persisted notification seam is visible yet. |
| Settings organization / visual quality | Not structurally broken, but heavy | `7.55o` + later UX polish lane | Screen is long and flat; this looks more like surface cleanup than core truth debt. |
| Sticky section titles while scrolling | Mostly not implemented | later UX polish lane | Sticky infrastructure exists for the variance banner, not for most section titles. |
| Shift target labor % vs Benchmark target mismatch | Partially explained, needs product decision | follow-up audit lane | Shift currently shows day-level planned labor %, which can differ from benchmark total theoretical %. |
| WTD FOH/BOH targets vs locked plan | Needs audit | follow-up audit lane | WTD table currently shows model-hours-for-actual-volume, not literal locked-plan-to-date hours. |
| Variance dollar-impact semantics | Not aligned with user's desired accumulation model | needs explicit product-logic spec | Current card is weekly + annualized only, with thin context copy. |
| Dollar Impact swipeable accumulation card | Not implemented | needs explicit future product/UI phase | User wants the card to move from smallest accumulation window to annualized, which is a real feature layered on top of new accumulation math. |
| Full Week daypart target alignment vs Plan | Needs audit | follow-up audit lane | Open/projected rows currently read from snapshot-shaped rows, not an explicit locked daypart-plan join. |
| Positive/green driver highlight behavior | Partially present | follow-up audit lane | Status dots and deltas already turn green, but hero-driver emphasis is still neutral sunset styling. |
| Live refresh / cache freshness strategy | Partially addressed | follow-up audit lane | Staleness detection exists; continuous operational refresh does not. |
| Benchmark theoretical output FOH/BOH breakdown | Not yet surfaced | later Benchmark polish lane | Data exists in target/profile models, but the Benchmark UI still emphasizes total labor % instead. |
| History and Learn "trickle" pipeline | Directionally correct, not literal 1:1 UI trickle | architecture-aligned today | History materializes closed truth; Learn studies closed truth plus benchmark context, not the Variance UI itself. |
| "No demo data" / fully real SQL simulation | Partially true, not fully true | current gate says still not simple-swap ready | Runtime reads are SQL-backed, but transport is still mock replay / demo-backed and fixture-era helpers still exist. |
| Simple-swap integration readiness | Not yet passed | `7.55j.gate`, then re-evaluate after `7.55n` / `7.55o` | Active gate verdict remains **NO** today. |
| `7.55i` integration-daypart checkpoint | Still valid as seam guidance | still active reference | App-owned service periods, timestamp bucketing, whole-day Shift until `10.5`, and integration-first wage authority still hold. |
| Naming consistency across screens | Needs audit | later copy/surface lane | Screen titles, section labels, and concept names are not yet simple or fully consistent. |
| Language shedding / text reduction | Needs audit | later copy/surface lane | Some surfaces still carry build-era explanatory text that is not product-necessary anymore. |

## Detailed Findings

## 1. Shift

### 1.1 Driver indicator on Shift can still feel stale

Current logic:

- Shift computes a whole-day current-state driver in
  `lib/models/shift_dashboard_read_model.dart`
- the driver is derived from:
  - closed + open actual covers/sales/hours
  - full-day scheduled hours
  - current active target profile
- the visible teaching block is intentionally hidden until `10.5`

Important implication:

- the Shift driver is **not** a live service-period driver
- it is a **whole-business-day** aggregate driver
- that is by design right now

Why it may still feel stale to the user:

1. the card is snapshot-driven, not continuously recomputed from a live feed
2. the clock is now live, but the operational metrics are still only as fresh
   as the stored open-shift snapshots
3. the explanatory teaching block is hidden, so the badge can change without
   enough explanation, or feel frozen without enough context
4. because Shift remains whole-day until `10.5`, the visible driver may not
   match what a manager feels is happening in the current service period

Assessment:

- this is **not fully solved**
- it is **not primarily a `7.55n` timing-config problem**
- it needs a dedicated driver freshness / surface-trust audit after `7.55n`

Recommended owner:

- new follow-up lane after `7.55n`, before `7.55o`
- suggested slice: `7.55p.1` â€” Shift + Variance driver freshness audit

### 1.2 Header clock is already fixed

Current state:

- Shift header now renders a live wall clock in
  `lib/screens/shift_dashboard.dart`
- this is display-only and no longer pretends to be service elapsed time

Assessment:

- addressed
- do not reopen unless there is a visual bug

### 1.3 `time into service` is already removed from active Shift UI

Current state:

- the active Shift header removed the stale service-elapsed display
- service-period-aware live timing is still explicitly reserved for `10.5`

Assessment:

- addressed
- keep this out of near-term cleanup unless the UI still contains leftover text

## 2. Variance

### 2.1 How the app currently knows what day it is

Current logic:

- Shift/operational current date comes from persisted open-shift snapshots
- current week resolution prefers the open shift's `weekId`
- WTD day count is derived from the last closed day label through canonical
  day ordering
- `WeeklyPlanSnapshotPolicy` already supports configurable week start, but the
  runtime still defaults to Monday in practice

What is missing:

- persisted `businessDayStartLocalTime`
- persisted `weekStartDay`
- app-owned business-date resolver from restaurant timing config
- app-owned runtime seam for restaurant timing rules

Assessment:

- partially addressed
- exactly what `7.55n.1` through `7.55n.4` are meant to fix

### 2.2 Variance top-line date/day counter is not fully future-safe yet

Current surface:

- Variance shows text like `Mar 24 Â· Friday Â· Day 5 of 7`

Current backing truth:

- current state already uses closed-shift day ordering and current week ids
- but the full restaurant-owned timing foundation is still missing

Risk:

- until `7.55n` lands, this logic still depends on a mixture of:
  - persisted week ids
  - snapshot business dates
  - Monday-default week logic
  - fixture-era service-period assumptions elsewhere in the app

Assessment:

- not broken enough to block work
- not complete enough to call final
- correctly planned under `7.55n`

### 2.3 Variance primary-driver logic vs Shift primary-driver logic

Current truth:

- Shift primary driver is a whole-day current-state driver
- Variance WTD primary driver is a week-to-date closed-truth driver

This means they are allowed to differ.

Current problem:

- that distinction is architecturally valid
- but likely not clear enough in the product surface
- so the user can read the difference as staleness or inconsistency

Assessment:

- this is not simply a bug report
- it is a **surface-trust + explanatory-scope** problem
- it needs an explicit audit

Recommended owner:

- `7.55p.1` alongside the Shift driver freshness audit

### 2.4 Full Week projection and dayparts closing

Current state:

- `7.55k.4` / `7.55k.4a` introduced a proper read service and row-provenance
  model
- closed rows, open rows, projected rows, and mixed day rows are now treated
  more honestly
- snapshot rows replace projected rows for the same slot
- `CurrentWeekState.shiftRecordFromSnapshot(...)` now carries `businessDate`

What remains incomplete:

- the time boundary beneath this still depends on unfinished `7.55n` runtime
  foundations
- service-period definitions are still hardcoded in several places
- variable service-period counts are not yet first-class runtime truth

Assessment:

- the `k` lane addressed semantics honestly
- `7.55n` still has to make the timing/service-period foundation beneath it real

## 3. History

### 3.1 History is not just â€œVariance after seven daysâ€

Current truth:

- History reads persisted `WeekRecord`s
- `WeekRecord` creation currently happens only when the week is considered fully
  closed in `ShiftService.closeShift(...)`

Important implication:

- History is not simply a timer rollover from the current Variance surface
- it depends on **closed truth being materialized**

That is the right architecture direction.

### 3.2 But the current week-close assumption is still fixture-era

Current code still assumes:

- a fully closed week means `14` closed shifts

That is a major hidden assumption.

Why it matters:

- the user explicitly wants service periods/dayparts to be variable
- a variable service-period model breaks the fixed `14 shifts` assumption
- so the History lock path is directionally correct, but structurally not yet
  generalized enough

Assessment:

- this is **not fully addressed**
- it is only partially covered by current planning
- it should be explicitly folded into `7.55n`, especially:
  - `7.55n.3` service-period definition runtime seam
  - `7.55n.5` service-period close vs shift finalization contract

This is worth carrying forward as a specific roadmap check:

- remove hidden fixed-count week-close assumptions once restaurant-owned
  service-period definitions become real runtime data

Important clarification:

- this issue is **covered in contract intent**
- but **not yet solved in runtime**

So if someone asks "is the 14-shift problem covered?", the honest answer is:

- yes in the time/service-period contract
- no in the current implementation

## 4. Benchmark / OPZ

### 4.1 OPZ narrow/good/wide logic does exist

Current logic in `BaselineData.baselineRangeValidation` already supports:

- `OPZ RANGE TOO NARROW`
- `GOOD OPZ RANGE`
- `OPZ RANGE TOO WIDE`

So the logic is not missing.

### 4.2 Why the surface can still feel wrong

The likely issue is not the raw validation rule. It is the presentation:

- the graph intentionally shows the full historical outer range
- the selected benchmark/star-shift range is shown inside it
- if the selected range spans nearly all available history, the UI can look
  like the benchmark range â€œcovers the whole scaleâ€

So there are two separate questions:

1. is the OPZ/range-quality logic correct?
2. is the graph explaining the distinction between:
   - full historical range
   - selected benchmark range
   - recommended target
   clearly enough?

Assessment:

- logic exists
- visual/readability audit is still needed

Recommended owner:

- `7.55p.3` â€” Benchmark OPZ range + graph honesty audit

### 4.2 Quick external benchmark note

This is not a full research pass yet, but a quick spot check shows the broader
restaurant industry usually talks about:

- total labor cost roughly in the `20%` to `35%` range depending on concept
- fine dining often running higher than quick service
- labor analysis needing FOH / BOH / management breakdowns rather than one
  headline percentage alone

That does **not** directly validate our current internal OPZ width thresholds.
It does support the user's instinct that:

- total labor % by itself is not enough
- FOH / BOH breakdown matters
- a benchmark band that visually reads "everything is acceptable" is not
  helpful enough

So the next OPZ/range pass should answer **our own app rule** more clearly,
not just chase one outside percentage benchmark.

## 5. Mock Replay Day Advance

### 5.1 Some downstream movement is expected

When mock day advances, the app currently reseeds replay state for a different
business date. That can legitimately change:

- current week membership
- planning anchor date
- which week is considered active
- next week's forecast context

That part is not automatically an architecture bug.

### 5.2 What would be a real bug

If advancing mock day rewrites a **locked same-week** comparison surface that
should have remained frozen, that would conflict with the architecture.

Examples of real bugs:

- a locked weekly snapshot mutates when still in the same locked week
- WTD/Full Week comparison truth silently changes without week rollover
- historical week records effectively get regraded

Assessment:

- this needs a dedicated audit, not a guess
- likely classification: replay/data-alignment contract issue
- not enough evidence yet to call it either expected or wrong in all cases

Recommended owner:

- `7.55p.2` â€” mock replay day advance / locked-week integrity audit

## 6. Plan Surface / Labels

### 6.1 Requested labels are mostly already present

Current Plan screen already has:

- `WEEKLY PLAN SUMMARY`
- `COVER FORECAST BY DAY`
- `DAY-BY-DAY PLAN`

So the user's requested structure is mostly there already.

### 6.2 What may still remain

Likely remaining work is not structural but copy polish:

- whether the card labels are the exact product language wanted
- whether the chart/table labeling feels strong enough visually
- whether there should be a clearer heading immediately above the first four
  cards in a more product-facing tone

Assessment:

- mostly addressed
- leave as polish, not architecture

Recommended owner:

- later surface polish slice, not a foundation blocker

## 7. Notifications / Refresh / Surface Trust

### 7.1 Notification contracts exist, but not a persisted runtime seam

Current docs already say the app should notify for:

- 60-day cycle rollover
- weekly plan snapshot rollover
- timing setting changes that affect future operational days

What is missing in runtime:

- no visible persisted notification model
- no visible notification repository / queue / inbox
- no visible rule engine that records "new week activated" or
  "new target cycle active"

Assessment:

- this is planned conceptually
- it is **not yet runtime-addressed**
- it should be treated as a real future implementation lane, not as if it
  already exists because the contracts mention it

### 7.2 Data freshness is only partially handled

Current truth:

- the Shift header clock is live
- `AppDataStatusService` marks current-state data stale after 24 hours
- manual refresh hooks exist through notifiers and Settings

What is missing:

- no broad live refresh strategy for operational surfaces
- no obvious polling / push seam for open-shift metrics
- no explicit cache invalidation policy beyond refresh calls and stale checks

Assessment:

- enough exists for demo-safe operation
- not enough exists to call live data freshness solved
- deserves explicit audit before real integration pressure

## 8. Integration Readiness / Demo Transport Truth

### 8.1 Are we "no demo data" and fully aligned through real SQL simulation?

Short answer:

- **partially, but not fully**

What is true today:

- the runtime read path is genuinely SQL-backed
- Shift / Variance / History / Learn all read persisted/query-backed state
- the app is not using old screen-level hardcoded demo constants as the active
  truth path
- tests like `test/runtime_fixture_retirement_test.dart` prove that the
  production runtime path is SQLite/mock-replay-backed, not `DemoData`-backed

What is also true today:

- the upstream transport feeding SQLite is still mock replay / demo-backed
- `MockIntegrationReplaySeed` still drives operational seed truth
- `docs/DATA_ALIGNMENT_TRACKER.md` still explicitly says:
  - `transport is still fixture/replay/demo-backed`
- there are still fixture-era helpers and compatibility bridges in runtime code
  and adjacent surfaces

So the honest wording is:

- **the app is SQL-backed internally**
- **the app is not live-transport-backed yet**
- **the app is more "real SQL simulation" than "no demo data"**

That distinction matters because "real SQL simulation" is not the same thing
as "ready to swap in a connector with no remaining architecture work."

### 8.2 Are we truly ready for integration with simple swaps?

Short answer:

- **no, not yet**

The active gate doc is explicit:

- `docs/archive/phases/7_55j/phase_7_55j_gate_integration_readiness_pressure_test.md`
- current verdict: **simple-swap readiness = NO**

Why the answer is still no:

1. transport is still mock replay rather than official vendor adapters
2. restaurant timing / service-period runtime foundation is still not landed
   (`7.55n`)
3. some fixture-era helpers still influence service-period and fallback behavior
4. there are still bridge-era reads and surface-cleanup items to isolate
   (`7.55o` and likely later audit/polish work)

So we are in a stronger place than earlier phases:

- internal seams are much cleaner
- SQL/repository/UI boundaries are real
- connector config persistence exists
- cycle/week architecture landed
- downstream daypart evidence contracts landed

But we are **not** yet at:

- "pick a vendor and just wire the adapter with no further app-side timing or
  surface-truth work"

### 8.3 How this compares to the old `7.55i` checkpoint

The old checkpoint still holds up well as **seam guidance**.

Still correct:

- app-owned service-period definitions
- timestamp bucketing instead of vendor-native dayparts
- integration-first wage authority with app fallback
- whole-day Shift until `10.5`

What changed since that checkpoint:

- `7.55l` made cycle/week runtime architecture real
- `7.55k` made daypart evidence downstream consequences real
- `7.55n` is now the missing timing/runtime foundation beneath those rules

So the checkpoint is still good, but it is no longer the whole story by itself.

The cleaner hierarchy now is:

1. contracts (`docs/contracts/**`)
2. landed cycle/week architecture (`7.55l`)
3. landed downstream daypart evidence implications (`7.55k`)
4. timing/service-period runtime foundation still ahead (`7.55n`)
5. the older `7.55i` checkpoint as seam guidance

Assessment:

- **yes**, the old checkpoint is still directionally right
- **no**, it is not enough by itself to say we are integration-ready

## 9. Naming / Simplicity / Language Audit

### 9.1 The app has structure, but naming is not fully unified yet

Current screen titles:

- Shift: restaurant-name hero, but no explicit `Shift` title at the top
- Plan: `Weekly Operating Plan`
- Benchmark: `60 Day Benchmark`
- Variance: `Variance`
- History tab content: `Previous Weeks`
- Learn: `Learn`
- Settings: `Settings`

That is not broken, but it is not one tight naming system either.

The current feel is:

- some screens are product nouns (`Variance`, `Learn`, `Settings`)
- some are workflow phrases (`Weekly Operating Plan`)
- some are time-window phrases (`60 Day Benchmark`)
- some are content descriptions (`Previous Weeks`)

So the product has structure, but not yet one clean naming grammar.

### 9.2 Concept names drift a little across surfaces

Examples:

- `PRIMARY DRIVER` vs `DRIVER` badge vs lever language
- `WEEK-TO-DATE vs LOCKED PLAN` vs week detail `WEEKLY SUMMARY vs LOCKED TARGETS`
- `BENCHMARK DAYPARTS`, `EARLY SIGNALS`, `REPEATABLE WINS`, `WIN REPEATS`
- `this week`, `annualized`, `run rate`, `Targets`, `Locked Plan`, `Locked Targets`

These are all understandable individually, but together they make the product
feel more "assembled over phases" than "one language system."

### 9.3 There is already text we can likely shed later

Candidates to revisit:

- Variance dollar-impact context line:
  - `Through Friday Â· 798 covers WTD Â· run rate.`
- Week detail footer:
  - `At $3M annual sales. One location.`
- some Full Week row text that still says more than the icons/status need
- some Learn and History teaching headers that may be more verbose than the
  final product needs
- some Settings labels that are accurate for build/debug but not ideal as the
  long-term manager-facing language

This is not a call to delete meaning blindly.

The better rule is:

- keep what clarifies source truth or action
- cut what only narrates implementation context or repeats what the layout
  already shows

### 9.4 Recommended audit shape for naming/copy

This should be a dedicated practical pass, not random one-off word swaps.

Suggested audit buckets:

1. **Screen names**
   - top-level tab / route titles
2. **Section names**
   - all-caps headers and whether they are still the right nouns
3. **Metric language**
   - target / plan / actual / model / projected / theoretical
4. **Teaching language**
   - driver / lever / what happened / what to do / what to study
5. **Removable helper text**
   - lines that can be deleted because the UI already implies them

Assessment:

- this is real product work
- it is not a blocker for `7.55n`
- it should probably land in the later copy/surface lane, not get mixed into
  timing foundation work

## 10. Settings / Surface Structure

### 10.1 Settings can be organized better, but this is more UX than architecture

Current truth:

- `lib/screens/settings_screen.dart` is about 700 lines long
- it mixes:
  - data status
  - mock replay controls
  - destructive data management
  - wage authority editing
  - audit panel access

What this means:

- the screen is not tiny anymore
- but the bigger problem is **flat surface structure**, not a broken truth seam
- this feels like:
  - future extraction work in `7.55o`
  - plus later visual / information architecture polish

Assessment:

- yes, it can be made visually and structurally better
- no, I would not treat it as urgent architecture debt compared with
  timing, WTD math, or driver-trust issues

### 10.2 Sticky titles are not broadly implemented

Current truth:

- sticky infrastructure exists for the variance banner
- most section titles across Shift / Variance / Plan are ordinary widgets

Assessment:

- this is mostly a UI polish item
- not currently planned as its own phase
- if it matters broadly, it should go into a surface-polish lane rather than
  get mixed into timing/runtime slices

## 11. Shift / Variance Mismatch Findings From Latest Audit

### 11.1 Shift target labor % may differ from Benchmark target by design today

Current truth:

- Benchmark stores the profile-level theoretical labor %
- Shift computes `targetLaborPct` from:
  - the **current day's** planned FOH hours
  - the **current day's** planned BOH hours
  - the **current day's** forecast sales

Because SchedulePlan allocates hours by day with integer rounding, a day-level
planned labor % can differ slightly from the rolled benchmark total.

So when the user sees something like:

- Benchmark: `20.5%`
- Shift: `20.3%`

that is probably not random drift. It is more likely:

- plan-day rounding
- day-specific FOH / BOH hour mix
- daily plan math vs profile headline math

Assessment:

- likely **explained by current design**
- still may be a **product consistency problem**
- needs a decision:
  - should Shift show day-plan labor target?
  - or should it show the benchmark headline target?

### 11.2 WTD FOH / BOH targets do not currently mean "locked plan to date"

Current truth:

- WTD table header says `WEEK-TO-DATE vs LOCKED PLAN`
- but FOH / BOH target rows use:
  - `modelFohHoursWtd`
  - `modelBohHoursWtd`
- those are computed from **actual WTD covers / sales** against locked target
  rates

That means the current target rows are:

- "what model hours should have been for actual volume"

not:

- "what the locked week plan said through today"

Assessment:

- this is a real meaning mismatch
- the user's example is plausible and directionally correct
- this needs explicit audit, because the label and math are not the same thing

### 11.3 Full Week daypart targets are not yet explicitly joined back to plan dayparts

Current truth:

- closed rows read from locked `ShiftRecord`s
- open / projected rows are converted from `OpenShiftSnapshot`
- those snapshot-shaped rows carry:
  - `forecastCovers`
  - `scheduledFohHours`
  - `scheduledBohHours`

But the current Full Week read seam does **not** explicitly join each row back
to a locked weekly-plan **daypart** target row. So when the user says:

- cover targets do not align with plan
- blended wage does not correspond
- FOH / BOH targets do not align

that is believable.

Assessment:

- this is not fully solved by `7.55k.4`
- `7.55k.4` fixed row honesty and provenance wording
- a later pass still needs to decide whether Full Week target columns should be:
  - locked shift-close truth
  - locked weekly-plan daypart truth
  - or a clearly labeled hybrid

### 11.4 Variance dollar-impact logic is much thinner than the user's intended model

Current truth:

- the current card shows:
  - weekly dollar impact
  - annualized dollar impact
  - one short context line

It does **not** currently express the richer accumulation ladder the user
described:

- day impact
- running week impact
- month impact
- 60-day impact
- annualized roll-forward

Assessment:

- this is not just copy cleanup
- it is a product-logic redesign question
- the user is really describing a different aggregation story, not a different
  label on the same math

Additional user direction now captured:

- the card should likely support a swipeable / paged progression across
  accumulation windows
- preferred order appears to be:
  - day
  - week
  - month
  - 60 days
  - annualized

That means the eventual work is probably two-layered:

1. define the accumulation contract and source-truth rules
2. then build the swipeable card UI on top of that contract

This should get its own logic/design note before implementation.

### 11.5 `CVR` and collapsed row copy are still product polish gaps

Current truth:

- collapsed day rows still render `cvr`
- expanded labels still include verbose text like covers + status

Assessment:

- these are not architecture blockers
- they are good candidates for a focused copy/polish slice once the target
  semantics above are settled

### 11.6 Primary lever carry-forward for Full Week could work as an interim rule

User suggestion:

- let Full Week primary levers carry forward from closed daypart shift close

Assessment:

- that is directionally compatible with current architecture
- it is safer than pretending open/projected rows have true row-scope driver
  detection
- but it still needs an explicit rule, not an accidental fallback

This belongs with the broader driver-trust audit rather than being slipped in
quietly.

## 12. Driver Highlight / Scenario Audit

### 12.1 The app already has positive/negative metric coloring, but not a full scenario matrix

Current truth:

- metric cards already use:
  - green for favorable deltas/status
  - red for unfavorable deltas/status
- the hero/driver emphasis itself still uses sunset styling rather than
  changing meaningfully for favorable vs unfavorable driver states

What is missing:

- a canonical scenario table for every driver family
- proof that each scenario highlights the expected hero card
- proof of how positive vs negative drivers should present

Assessment:

- this is a good audit request
- it is not fully covered yet
- it should become a dedicated test/audit slice using Chapter 10 variance-card
  intent as the reference frame

## 13. Benchmark / Plan / History / Learn Flow

### 13.1 History is downstream of closed truth, not a timer rollover

Current truth:

- This Week / Full Week are live read surfaces
- History reads materialized week history

So the answer to:

- "Does week to date simply go from variance to history after 7 day counter?"

is:

- no, not literally
- it becomes History when closed truth is materialized into historical form

### 13.2 Learn is downstream of closed truth, not a 1:1 copy of History UI

Current truth:

- Learn now reads closed-shift evidence-backed summaries
- it does not simply mirror the History tab UI
- it studies repeated closed outcomes plus current benchmark context

So the answer to:

- "History: is this a 1:1 trickle from this week then learn a 1:1 trickle from
  history?"

is:

- directionally yes in the data pipeline
- but not literally in the screen pipeline

The cleaner mental model is:

- Variance = live + closed current-week read surface
- History = closed weeks preserved
- Learn = repeated teaching derived from closed evidence

## Cross-Cutting Risks To Carry Into The Next Planning Merge

1. **Variable service periods are still not real runtime truth yet**
   - many screens/helpers still assume lunch/dinner/late_night
   - History week finalization still carries a fixed-count assumption

2. **Driver trust is still weaker than driver math**
   - logic exists
   - scope differences are real
   - product explanation is still not strong enough

3. **Mock replay is still doing two jobs at once**
   - demo transport
   - time/anchor simulation
   which makes some downstream behavior look suspicious even when parts are
   expected

4. **Benchmark OPZ communication may be weaker than the underlying rule**
   - likely a visual explanation problem more than a raw formula problem

5. **Some top-line labels now overpromise stricter truth than the math beneath them**
   - especially WTD "vs LOCKED PLAN"
   - and some Full Week target-column expectations

6. **Notification / freshness behavior exists more in contracts than in runtime**
   - users will expect week/cycle rollover visibility
   - current code mostly relies on refresh calls and stale-state checks

7. **"SQL-backed" can be overstated if we skip the transport qualifier**
   - runtime reads are SQL-backed
   - upstream operational truth is still mock replay / demo transport
   - saying "no demo data" today would be too strong

8. **Naming/copy debt is more noticeable now that architecture is cleaner**
   - the product language still carries some build-era and debug-era phrasing
   - this will matter more as the app gets closer to connector work

## Recommended Phase Impact

## Already correctly queued

- `7.55n.*`
  - this is the correct owner for restaurant timing config, business date,
    week start, service-period definitions, and close semantics

- `7.55o.*`
  - keep this for engineering hygiene / file extraction only

## Recommended new lane after `7.55n`, before `7.55o`

Suggested family: `7.55p`

### `7.55p.1` â€” Shift + Variance driver freshness audit

Scope:

- Shift driver badge truth
- Variance WTD driver truth
- scope distinction between them
- stale-feeling vs genuinely stale behavior

### `7.55p.2` â€” Mock replay day advance / locked-week integrity audit

Scope:

- what should legitimately change when mock day advances
- what must stay locked
- same-week snapshot integrity
- downstream forecast movement vs rewrite bugs

### `7.55p.3` â€” Benchmark OPZ range + graph honesty audit

Scope:

- narrow/good/wide rule validation
- graph explanation of historical range vs selected range
- whether current benchmark surface visually overstates the range

### `7.55p.4` â€” small surface copy polish

Scope:

- Plan labels/copy
- any remaining Variance/Shift wording cleanup discovered by the audits
- sticky-title / surface hierarchy polish
- settings organization / visual refinement
- notification-surface design notes if they do not need runtime work
- naming consistency across screens
- language shedding / text reduction where the UI already carries the meaning

## Inputs To Compare During The Next Brain Dump Merge

Use this note together with:

- current roadmap / trackers
- `docs/archive/phases/7_55n/phase_7_55n_restaurant_timing_service_period_runtime_foundation.md`
- `docs/phases/7_55o/phase_7_55o_file_extraction_analysis.md`
- `docs/archive/reference/REFACTOR_AND_DECOUPLING.MD`

The merge question should be:

1. what is already solved
2. what is already planned with a real owner
3. what is real but unplanned
4. what is only copy polish

That should let the next planning pass separate architecture work from audits,
from UX wording, from cleanup.
