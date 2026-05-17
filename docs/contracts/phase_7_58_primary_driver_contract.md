# Phase 7.58 - Primary Driver Contract

Updated: 2026-05-03
Owner: Codex architecture
Status: Active authority for `7.58` sub-slice family
Companion plan: `docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md`
Companion contract: `docs/contracts/metric_card_honesty_contract.md` — extends this doctrine from lever ids to load-bearing metric cards (CPLH / SPLH / PPA / wage). Disjoint scope; same honesty pattern.

## Why This Exists

`Primary Driver` is the single label every variance surface uses to answer
the question "what was the biggest lever on this shift / this week?" It
is rendered as a short badge in Variance and Shift, and as a deep
teaching card in Learn. Every renderer reads the same id off the
canonical record (`primaryLever` on `ShiftRecord`, `primaryLeverId` on
`WeekData` / `WeekRecord` / `BaselineCandidateShift` /
`ShiftDashboardReadModel`), so the contract for how that id is computed
and what it is allowed to mean is a hard cross-cutting seam.

This doc is the authority for `7.58.0` audit findings and the `7.58.1`-
`7.58.5` follow-up sub-slices. Layer 10 of
`docs/contracts/phase_7_55_architecture_contract.md` (Variance) governs
the row-status semantics this contract refines.

## Authority Position

Below `docs/contracts/phase_7_55_architecture_contract.md` Layer 10.
Above all `7.58.*` slice docs and any UI that renders a lever id. When
this doc and Layer 10 conflict, Layer 10 wins; when this doc and a
`7.58.*` slice doc conflict, this doc wins.

## Single Source of Truth

`LaborModel.determineLever(...)` in `lib/services/labor_model.dart:99`
is the only function allowed to compute a primary driver id. No
surface, widget, or read service may rederive a lever from a different
formula or from rounded UI numbers. Any new surface that needs a
driver calls `determineLever` (or reads the persisted
`primaryLeverId` produced by it) — never recomputes from a partial
input set.

## Input Axes

`determineLever` consumes six independent input axes. Each axis maps
to one or two candidate lever ids:

| Axis | Threshold | Lever ids | Required? |
| --- | --- | --- | --- |
| Covers (actual vs forecast) | ±2% | `covers_up` / `covers_down` | always |
| PPA (actual vs target) | ±3% | `ppa_up` / `ppa_down` | always |
| CPLH (actual vs target) | ±5% | `cplh_up` / `cplh_down` | always |
| SPLH (actual vs target) | ±5% | `splh_up` / `splh_down` | optional (BOH only — needs `avgSPLH` + `targetSPLH`) |
| FOH wage (blended actual vs target) | ±3% | `foh_wage_up` / `foh_wage_down` | optional (needs `avgFohBlendedWage` + `targetFohWage`) |
| BOH wage (blended actual vs target) | ±3% | `boh_wage_up` / `boh_wage_down` | optional |
| FOH hours flex (scheduled vs model) | ±10% | `foh_hours_over` / `foh_hours_under` | optional (needs `scheduledFohHours` + `modelFohHours`) |
| BOH hours flex (scheduled vs model) | ±10% | `boh_hours_over` / `boh_hours_under` | optional |

Each axis is read as a relative deviation against its own denominator.
A null optional input silently skips that axis — no fallback, no
synthesis, no zero-treated-as-real.

The 16 lever ids enumerated above match the 16 entries in
`LeverCards.all` at `lib/domain/constants/app_defaults.dart:434`. There is also
a 17th sentinel id, `on_model`, that is **never** returned by
`determineLever` — it is reserved for non-closed `ShiftRecord` rows
constructed from open snapshots (`CurrentWeekState.shiftRecordFromSnapshot`
at `lib/models/current_week_state.dart:59`) where no real lever has
been computed yet.

## Decision Logic

1. Compute the relative delta on every required + optional axis whose
   inputs are all present and whose denominator is positive.
2. For each axis, if `|delta|` exceeds the axis threshold, add the
   matched id (up vs down) to the candidate set with weight `|delta|`.
3. If the candidate set is empty, return the literal string
   `'covers_down'`. (This is a behaviour preserved from
   pre-7.58 code; see Finding F-2 below — `7.58.0a` will replace
   it with `'on_model'` once the on-model card exists.)

   **7.58.0a (week scope, applied):** `LaborModel.determineLever`
   keeps this legacy fallback verbatim for single-source / R10
   callers. A sibling `LaborModel.determineLeverGated` returns
   `LaborModel.onModelSentinel` (`'on_model'`) on the empty-candidate
   state and is the required entry point for WEEK-LEVEL aggregate
   producers (WeekRecord / WeekData: `ShiftService.getWeekToDate`/
   `_buildWeekRecord`/snapshot-WTD, `StaticShiftDataSource.getWeekToDate`,
   and the demo week-rollup seeds). Per-shift `ShiftFact`/`ShiftRecord`
   producers and the contract-sanctioned whole-day `LeverCards.lookup(id)!`
   site remain on `determineLever` (7.61 catalog discipline). Renderers
   already degrade the `on_model`/null lookup to `LeverCardNotYetAvailable`
   (This Week, per 7.58.UX.5) and `'—'` (`week_history_tile.dart`).
4. Otherwise, pick the candidate with the maximum `|delta|`.
5. If two or more candidates tie at the maximum, resolve by the
   `priorityOrder` list at `lib/services/labor_model.dart:131`:

   ```
   covers_down, covers_up,
   ppa_down,    ppa_up,
   cplh_down,   cplh_up,
   splh_down,   splh_up,
   foh_wage_down, foh_wage_up,
   boh_wage_down, boh_wage_up,
   foh_hours_over, foh_hours_under,
   boh_hours_over, boh_hours_under,
   ```

   Lower index wins. Volume axes outrank productivity axes outrank
   wage axes outrank hours-flex axes. Within a family, "down"
   outranks "up" by index but only fires when both directions tied
   at the same `|delta|` (which is degenerate; documented for
   completeness).

## Output Cardinality

`determineLever` returns exactly one id per call. The id is one of
the 16 cards or the legacy `'covers_down'` no-signal fallback. The
id is always lowercase snake_case. Storage layers persist the
upper-snake form (`'COVERS_DOWN'`) at `ShiftRecord.primaryLever`;
`ShiftRecord.normalizedLeverId` lowercases it for lookup. Renderers
resolve the id through `LeverCards.lookup`, which is
case-insensitive and returns `null` for the `on_model` sentinel and
unknown ids — see Presentation Split Rules.

## Presentation Split (Short vs Deep)

The same id renders three different shapes. The renderer's job is
to pick the right shape — never to invent a new one.

| Surface | Shape | Source | File |
| --- | --- | --- | --- |
| Variance > This Week > Primary Driver | full `LeverCardWidget` (cause badge + metric + WHAT HAPPENED + WHAT TO STUDY) | `LeverCardData.metric` + `whatHappened` + `teachingNote` | `lib/screens/variance/variance_this_week_tab.dart:90`, `lib/widgets/lever_card.dart` |
| Variance > Previous Weeks tile | short text badge | `LeverCardData.shortLabel` + `isFavorable` color | `lib/widgets/week_history_tile.dart:28` |
| Variance > Full Week Projection day/daypart row | underscore-stripped lever id text | `ShiftRecord.primaryLever.replaceAll('_', ' ')` (closed only) | `lib/services/variance_week_projection_read_service.dart:147` |
| Variance > Learn (Leak / Win) | three cards: WHAT HAPPENED, WHAT TO DO, WHAT TO STUDY | `LeverCardData.whatHappened` + `whatToDo` + `teachingNote` | `lib/screens/variance/variance_learn_tab.dart:148` |
| Variance > Previous Weeks > Week Detail | full `LeverCardWidget` | same as This Week | `lib/screens/week_detail_screen.dart:138` |
| Variance > History tab | leak evidence card | `LeverCardData.metric` only | `lib/screens/variance/variance_history_tab.dart:225` |
| Shift > Whole-day | full `LeverCardWidget` | `LeverCardData` (whole-day scope; can differ from Variance WTD scope) | `lib/models/shift_dashboard_read_model.dart:222` |
| Shift > Closed-shift detail (in Variance projection expand) | inline `_LeverBadge` text | `s.primaryLever.replaceAll('_', ' ')` | `lib/screens/variance/variance_this_week_tab.dart:1194` |
| Baseline Manager day detail chip | `LeverCardData.metric` long form (with fallback to title-cased id) | `leverLabel(leverId)` helper | `lib/screens/baseline_manager/baseline_manager_helpers.dart:58`, `lib/screens/baseline_manager/baseline_manager_day_detail.dart:242` |

### Rules

- The **short** badge surfaces (Previous Weeks tile, projection day
  row, Closed-shift inline `_LeverBadge`) MUST keep their text under
  one line and MUST NOT include the WHAT HAPPENED / WHAT TO DO copy.
- The **deep** surfaces (This Week Primary Driver card, Week Detail,
  Learn) MUST render the corresponding `LeverCardData` fields and
  MUST NOT condense them down to the short label.
- The **medium** surfaces (Baseline Manager chip, History leak
  evidence card) MUST use `LeverCardData.metric` only — never
  `whatHappened` or `whatToDo`. They are evidence, not teaching.
- Rendering MUST resolve a lever id through `LeverCards.lookup(id)`
  (case-insensitive, returns `LeverCardData?`). The helper returns
  `null` for the `on_model` sentinel, an unknown id, and empty / null
  input. Renderers MUST then surface the null return as an explicit
  degraded state — never fall through to a real lever card. The
  shared user-facing label is `LeverCards.notYetOnModelLabel`
  (`'Not yet on-model'`); the deep-card surfaces render
  `LeverCardNotYetAvailable`, the short-badge surfaces render `'—'`,
  and the inline `_LeverBadge` renders
  `'PRIMARY LEVER: NOT YET ON-MODEL'`. The pre-7.58.UX.5 pattern
  (`firstWhere(... orElse: () => coversDown)` / `() => ppaUp`)
  silently overclaimed a real driver and is banned. Owned by
  Finding F-1 (closed by `7.58.UX.5`).
- Read-model layers that consume guaranteed-engine output (per R6
  `determineLever` never returns `on_model`) MAY assert non-null via
  `LeverCards.lookup(id)!` so a hypothetical R6 violation surfaces
  as a crash rather than a silent fall-through. Used today by
  `ShiftDashboardReadModel.buildWholeDay`.

## Row-Status Honesty Rules

Layer 10 of `phase_7_55_architecture_contract.md` says:

> projected and open rows must not overclaim final truth.

For Primary Driver this means:

### What an open / projected row CAN say

- **Its own row-scoped driver, computed from live truth at read time.**
  When an open row has positive actual covers / hours and a defined
  blended wage, the variance projection read service is allowed to
  call `determineLever` against the live snapshot inputs and render
  the result as the row's driver — labelled clearly as a live signal,
  not as closed truth.
- **A neutral "Not yet available" placeholder** when no live signal
  exists yet (zero hours, no wage, pre-shift snapshot). This is the
  current behaviour at
  `lib/services/variance_week_projection_read_service.dart:155`.
- **The `on_model` sentinel** — the constructor-time placeholder used
  by `CurrentWeekState.shiftRecordFromSnapshot`. Renderers MUST resolve
  it through `LeverCards.lookup` (which returns `null` for this
  sentinel, per Output Cardinality + Presentation Split Rules) and
  surface a "no driver yet" treatment — same visual class as
  "Not yet available". The pre-7.58.UX.5 silent fall-through to
  `LeverCards.coversDown` is banned. Owned by Finding F-1 / F-6
  (closed by `7.58.UX.5`).

### What an open / projected row MUST NOT say

- **A previous closed row's driver, inherited via daypart carry-forward.**
  This is the `7.58.5` G.5 fold. Today
  `lib/services/variance_week_projection_read_service.dart:60-78`
  builds a `lastClosedLever[daypart]` map from earlier closed rows in
  the same week and assigns that lever to subsequent open / projected
  rows in the same daypart. This is overclaim: it asserts that the
  Tuesday Lunch open row already has the same driver as Monday Lunch
  before any Tuesday hours have been worked. The contract bans this.
  Open / projected rows derive their driver from their own row inputs
  or display "Not yet available" — they never inherit.
- **A whole-day driver as if it were a daypart driver, or vice versa.**
  Whole-day Shift (`ShiftDashboardReadModel.buildWholeDay`) and WTD
  Variance (`ShiftService.getWeekToDate`) operate on different
  aggregation windows; per `phase_7_55m_4_driver_parity_audit_cleanup`
  they may legitimately disagree. Surfaces MUST NOT cross-render one
  scope's driver in another scope's row.
- **A driver computed from rounded display values.** Inputs to
  `determineLever` come from canonical facts, never from the strings
  the UI is currently rendering.

## Sub-Slice Family

| Slice | Owns |
| --- | --- |
| `7.58.0` | this audit + contract; no production code change |
| `7.58.1` | dollar-impact attribution per driver (rendering surface TBD) |
| `7.58.2` | driver identity in History / Learn (parity with Variance) |
| `7.58.3` | history coverage (driver counts across closed weeks) |
| `7.58.4` | fixture realism (drivers in `mock_integration_replay_seed` reproduce when re-fed through `determineLever`) |
| `7.58.5` | variance row purity — remove the daypart carry-forward G.5 fold above |

`docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md`
owns the per-slice scope, Frontend Exposure, hard gates, and the
running Findings list. All five sub-slices must accept before
`11b.0`.

## Hard Promises Crossref

This contract sits inside the 10 Hard Promises in `CLAUDE.md`. The
ones that bind:

- **HP #3** — `7.58.0` is docs/audit only; logic-deciding work
  starts at `7.58.0a` follow-ups generated by this audit.
- **HP #6** — Drivers are recommendations, not commands. The
  contract does not turn the lever id into an automatic action.
- **HP #10** — `7.58.UX.*` sub-slices ship with each backend slice
  per the plan doc's Frontend Exposure section.

## Depth Surfaces (2026-05-05 addendum — Phase 7.58 depth wave)

Authority for the depth wave is `docs/phases/phase_7_58/phase_7_58_depth_wave_plan.md`
plus `docs/Knowledge_graph_docs/Bold By Design.md` chapters 2 / 5 / 8 / 9 /
10 / 11 / 12 and `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`
chapters 6 / 7 / 8 / 9. The depth wave does not change this contract's
Single Source of Truth, Decision Logic, Output Cardinality, or
Presentation Split rules. It pins three new posture rules that govern
how Bold by Design + Jim Taylor depth surfaces inside existing chrome.

### Tab ownership (no crossover)

Each operator-facing surface owns one piece of depth. No concept
renders on more than one tab in the depth wave.

| Surface | Owns |
|---|---|
| `lib/widgets/dollar_impact_card.dart` (Variance > This Week + Week Detail) | "Best Possible / Actual / Closable Gap" framing — `theoreticalLaborPct` named as the math floor it has always been. |
| `lib/widgets/lever_card.dart` `_DollarAttributionSection` (Variance > This Week + Week Detail) | OPZ-aware row adornment — when an axis crossed `opzCeilingCPLH`, the row reads `+$N axis : team was stretched`. |
| `lib/screens/shift_dashboard.dart` OPZ tile | OPZ position (live), CPLH × SPLH 3×3 matrix grid, joint diagnosis sub-label when the two axes disagree. |
| `lib/screens/variance/variance_learn_tab.dart` `_LeakSnapshotCard` + carousel | Coverage denominator caption (`Repeated 6 of last 12 Tue Lunches`). When the cross-axis analyzer surfaces a recurring pair, the carousel swaps its data source from `LeverCards` to `CrossAxisPairs` (same 4-card shape, different input). |
| `lib/screens/variance/variance_history_tab.dart` | Unchanged. History is the evidence trail; depth lives elsewhere. |

Surfaces NOT named above (`week_history_tile.dart`, `variance_week_projection_read_service.dart`, `baseline_manager_*`, `_LeverBadge`) are unchanged in this wave.

### Cross-axis pair catalog

A sibling catalog `lib/domain/constants/cross_axis_pair_catalog.dart` parallels
`LeverCards` in shape. Each entry is a `CrossAxisPairData` with the
same field set (`metric` / `whatHappened` / `whatToDo` /
`teachingNote` / `shortLabel` / `isFavorable`). The 16-card single-axis
catalog stays the source of truth for all single-axis surfaces;
cross-axis catalog activates ONLY when the analyzer detects a
recurring CPLH × SPLH pair pattern in `HistoryPatternRecord` set.

Locked catalog entries (Jim Taylor Ch. 7 + Bold by Design ch. 10):

- `cplh_below_splh_above` — "FORECAST WAS LOW. TEAM EXECUTED."
- `cplh_on_splh_below` — "KITCHEN SLOWED. DINING ROOM HELD."
- `cplh_above_splh_below` — "TEAM RAN LEAN. KITCHEN SLOWED."
- `both_below` — "DEMAND WAS SOFT."

The catalog is closed at this size for V1; new pair entries land via
contract revision PR (same gate as `LeverCards`).

### Em dash ban (operator-facing copy)

The depth wave introduces no em dashes (`—`, U+2014) in any
operator-facing string literal. Use period, colon, or middot. Lint
test pins the rule across the new catalog + the changed renderer
files.

### Walkthrough specificity

Every depth-wave walkthrough is at the click-path bar set by
`docs/_walkthroughs/7.58.UX.5.md` per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
"Walkthrough Specificity". Each walkthrough names the demo seed
shift, the rendered widgets, and the named values the test pins.

### Hard gates the depth wave inherits

- **Single Source of Truth** — `LaborModel.determineLever` and
  `LaborModel.attributeDollarImpactByAxis` are not modified. The
  cross-axis analyzer reads `HistoryPatternRecord.leverId` (which
  came from `determineLever`) and pairs them; it does not re-derive a
  driver.
- **Concern A** (`target_profile_version_id` immutability) is not
  affected. Closed-shift history stays frozen.
- **Layer 6** (forecast is F&F-computed) is not affected. The
  cross-axis catalog never emits a vendor-derived forecast.

---

# V2 Revision (2026-05-16  -  Variance Coaching V2 wave, Lane A)

Status: GATED. This section is the contract delta for the Variance
Coaching V2 wave. It does not delete or supersede any prior section.
Where this section and a prior section disagree on operator-facing
copy or sign/sentiment presentation, this V2 Revision wins for the
V2 wave surfaces (This Week Primary Driver, Learn, History inline
emphasis). The Single Source of Truth, Decision Logic, Output
Cardinality, and tab-ownership rules above are unchanged: V2 is a
presentation + copy revision, not a logic change. Any logic change
the driver-logic reconciliation surfaces is carved out as its own
operator-gated micro-slice and is NOT authorized by this section.

Authority for this section: `docs/f&f Coaching/variance_tab_v2_mockup.html`
and `docs/f&f Coaching/primary_driver_catalog_evolved.html` (agreed UX +
copy spec, behavioural acceptance reference), reconciled against
`docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` and
`docs/Knowledge_graph_docs/Bold By Design.md` (driver-logic authority).
Companion phase doc: `docs/phases/variance_coaching_v2/variance_coaching_v2.md`.
Reconciliation memo: `docs/_audits/variance_coaching_v2/driver_logic_reconciliation.md`.

## V2-1. Evolved copy catalog (verbatim, 21 states)

This is the LOCKED copy spec. Lane B applies these strings to
`lib/domain/constants/app_defaults.dart` (`LeverCards`, 16 single-axis
entries) and `lib/domain/constants/cross_axis_pair_catalog.dart`
(`CrossAxisPairs`, 4 cross-axis entries) byte-for-byte. The 21st state
(degraded "Not yet on-model") is the real widget system status, not
teaching, and is NOT evolved  -  it stays the verbatim widget text.

Field mapping from the catalog HTML to the Dart model:

| Catalog HTML key | `LeverCardData` / `CrossAxisPairData` field | UI label in card |
| --- | --- | --- |
| `metric` | `metric` | card title (serif h3) |
| `wh` | `whatHappened` | WHAT HAPPENED |
| `wd` | `whatToDo` | WHAT TO DO (Learn surface only  -  see V2-5) |
| `ws` | `teachingNote` | WHAT TO STUDY |

Transcription rule: strings are reproduced exactly as they appear in
`primary_driver_catalog_evolved.html` (the `CARDS` array). The HTML
source contains exactly three curly-apostrophe characters (U+2019),
one each inside `splh_up.ws` ("kitchen's"), `foh_wage_up.ws`
("manager's"), and `cplh_below_splh_above.wd` ("next week's"); they
are preserved here verbatim as authored. No em dash (U+2014) and no
en dash (U+2013) appears in any string. Lane B asserts a golden test
that the applied Dart copy equals these strings.

### Single-axis levers (16)  -  COVERS · VOLUME

**`covers_up`**  -  favorable  -  badge `COVERS`  -  cat `VOLUME`  -  side `BOTH SIDES`

- metric: `Volume came in above plan`
- whatHappened: `More guests showed up than you forecast, and the team carried them on the hours already scheduled. Both sides looked better because the extra covers grew the sales side. The rule before you celebrate a good number: check CPLH. If it held in the zone this was design. If it ran soft, the volume did work the schedule should have done.`
- whatToDo: `If CPLH held, write down the staffing setup that absorbed the covers, that is a benchmark. If CPLH ran below target, do not raise the forecast yet, first build the schedule from covers divided by your CPLH target.`
- teachingNote: `A hot week can rescue a bloated schedule and still post a good number. That is luck, not a system. If covers keep beating forecast in the same dayparts and CPLH holds, recalibrate the forecast upward. If CPLH does not hold, the leak is the schedule.`

**`covers_down`**  -  unfavorable  -  badge `COVERS`  -  cat `VOLUME`  -  side `BOTH SIDES`

- metric: `Covers came in light`
- whatHappened: `Fewer guests walked in than the schedule was built for, and the hours did not come down to meet the lighter volume. Both sides drift up because the sales side shrank while labor held. This is a forecast or scheduling gap, not a team problem.`
- whatToDo: `Track covers mid-week against the forecast. When the pace is running light, cut hours in real time, do not wait for close. Build next week from covers divided by your CPLH target so the schedule starts where demand actually is.`
- teachingNote: `Covers down with hours that did not flex is the most common bleed. One light week is normal variation. The same daypart light week after week means the forecast is overstating demand there.`

### PPA · GUEST EXPERIENCE

**`ppa_up`**  -  favorable  -  badge `PPA`  -  cat `GUEST EXPERIENCE`  -  side `BOTH SIDES`

- metric: `PPA above target`
- whatHappened: `Guests spent more per head. Check-backs happened, upsells landed, service was not rushed. This is the OPZ working as designed: the team had enough floor to take care of people and people responded.`
- whatToDo: `Write down what made this shift work: covers, daypart, who was on the floor, how the team was deployed. You cannot replicate what you do not understand. This is a benchmark shift.`
- teachingNote: `PPA rises when the team is inside the zone, busy but not overwhelmed. Study which dayparts produce it and protect the staffing level that left room to sell.`

**`ppa_down`**  -  unfavorable  -  badge `PPA`  -  cat `GUEST EXPERIENCE`  -  side `BOTH SIDES`

- metric: `PPA running below target`
- whatHappened: `Guests spent less per head. The first check is not the menu, it is CPLH. When the team is pushed above the OPZ ceiling, check-backs stop and upsells die. Look at productivity before you talk about training.`
- whatToDo: `Cross-reference CPLH. If it was above the ceiling, the fix is staffing level, not a coaching conversation. A team running too lean cannot sell. Give them the floor to do it.`
- teachingNote: `Upsells die above the OPZ ceiling. If PPA drops cluster in the same dayparts where CPLH runs hot, guest attention is being lost there. That is a staffing pattern, not a people problem.`

### CPLH · SCHEDULING

**`cplh_up`**  -  favorable  -  badge `CPLH`  -  cat `SCHEDULING`  -  side `FOH ONLY`

- metric: `CPLH above target`
- whatHappened: `Front-of-house covered the volume with fewer hours than model. The team moved efficiently and FOH labor landed below model. As long as CPLH stayed under the OPZ ceiling, this is what a well-scheduled shift looks like.`
- whatToDo: `Check OPZ position. Below the ceiling: document this shift, staffing level, cover count, daypart, that is your replicable setup. Above the ceiling: the team was stretched and service likely felt it even if the number looked good.`
- teachingNote: `Efficient is only a win inside the zone. Study which dayparts can sustain this CPLH without pushing past the ceiling. That range is your real FOH target.`

**`cplh_down`**  -  unfavorable  -  badge `CPLH`  -  cat `SCHEDULING`  -  side `FOH ONLY`

- metric: `CPLH below target`
- whatHappened: `More front-of-house hours were scheduled than the covers required. Servers had tables to spare and you paid for hours the volume never used. BOH is unaffected, this is a front-of-house scheduling decision.`
- whatToDo: `Build next week's FOH schedule from the math: forecast covers divided by your CPLH target. That number is your required FOH hours. Build from that, not from last week's sheet.`
- teachingNote: `Scheduling to last week or to revenue is why this repeats. If the same FOH dayparts run below target, hours are being built above actual cover demand there. Fix the schedule input, not the team.`

### SPLH · KITCHEN PRODUCTIVITY

**`splh_up`**  -  favorable  -  badge `SPLH`  -  cat `KITCHEN PRODUCTIVITY`  -  side `BOH ONLY`

- metric: `SPLH above target`
- whatHappened: `The kitchen generated more sales per labor hour than model. Ticket times were likely clean and BOH was right-sized for what came in. FOH is unaffected, this is a well-run kitchen shift.`
- whatToDo: `Note the BOH configuration: who was on which station, the lineup, how prep was staged. That is your replicable kitchen setup. Write it down before the next roster goes out.`
- teachingNote: `SPLH is the kitchen’s productivity read. Study ticket flow, prep readiness, and station setup in the dayparts where it holds, and protect that setup.`

**`splh_down`**  -  unfavorable  -  badge `SPLH`  -  cat `KITCHEN PRODUCTIVITY`  -  side `BOH ONLY`

- metric: `SPLH below target`
- whatHappened: `The kitchen produced fewer sales per labor hour than model. FOH is unaffected, the leak is back of house. It is either ticket times running slow or BOH simply overstaffed for the sales that came in.`
- whatToDo: `Check two things: kitchen ticket-time logs and BOH hours against actual sales. Clean tickets mean overstaffing. Slow tickets mean throughput. Different problems, different fixes.`
- teachingNote: `A drop in SPLH with steady covers means the kitchen took longer per ticket or carried hours the volume did not need. If it repeats in the same BOH dayparts, inspect station load and throughput there.`

### WAGE MIX

**`foh_wage_up`**  -  unfavorable  -  badge `WAGE`  -  cat `WAGE MIX`  -  side `FOH ONLY`

- metric: `FOH blended wage above model`
- whatHappened: `The hours were right, the cost on those hours was not. FOH blended wage ran above model, usually overtime or a higher-cost role covering a position it does not normally fill. BOH is unaffected.`
- whatToDo: `Pull FOH clock-outs and role assignments for the shift. Find who went over hours or covered outside their classification. This is a deployment decision for next week, not a performance conversation.`
- teachingNote: `Wage mix is largely outside the manager’s control, but deployment is not. If the same FOH dayparts keep triggering overtime or expensive coverage, that is a roster pattern to fix, not a labor problem to absorb.`

**`foh_wage_down`**  -  favorable  -  badge `WAGE`  -  cat `WAGE MIX`  -  side `FOH ONLY`

- metric: `FOH blended wage below model`
- whatHappened: `FOH blended wage came in below model. The right roles were on the right shifts, lower-cost coverage aligned with volume without sacrificing floor quality. BOH is unaffected.`
- whatToDo: `Document the FOH schedule configuration that produced this: which roles, at what hours, against what cover pace. Replicate the deployment pattern next week.`
- teachingNote: `A favorable wage mix is a deployment pattern worth banking. Study which role mix produced it and where it repeats.`

**`boh_wage_up`**  -  unfavorable  -  badge `WAGE`  -  cat `WAGE MIX`  -  side `BOH ONLY`

- metric: `BOH blended wage above model`
- whatHappened: `BOH blended wage ran above model. FOH is unaffected. The usual cause is a kitchen manager or sous chef dropping to a line position during a rush and logging hours at a higher rate. The hours may have been necessary, the deployment around them may not have been.`
- whatToDo: `Review BOH time cards and station assignments. Find who worked outside their usual role and what triggered it. The fix is smarter pre-shift BOH deployment: know which positions need coverage and at what rate before the shift starts.`
- teachingNote: `If the same BOH dayparts keep triggering overtime or manager coverage, that is a deployment pattern, not a general kitchen problem.`

**`boh_wage_down`**  -  favorable  -  badge `WAGE`  -  cat `WAGE MIX`  -  side `BOH ONLY`

- metric: `BOH blended wage below model`
- whatHappened: `BOH blended wage came in below model. Kitchen deployment matched volume without overtime or off-classification coverage. FOH is unaffected.`
- whatToDo: `Document the BOH station assignments and shift times that produced this. It is your benchmark kitchen configuration, the starting point for next week's lineup.`
- teachingNote: `Bank the kitchen setup that produced the favorable mix and study where it repeats.`

### HOURS FLEX · SCHEDULING

**`foh_hours_over`**  -  unfavorable  -  badge `HOURS`  -  cat `SCHEDULING`  -  side `FOH ONLY`

- metric: `FOH hours did not flex down`
- whatHappened: `The floor carried more hours than the covers needed. The model called for fewer FOH hours for what walked in, but the schedule never came down, so the excess shows up as labor above model. BOH is unaffected, this is a front-of-house flex issue.`
- whatToDo: `Compare the published FOH schedule to model hours by daypart. Where the gap is widest, pull hours before the shift opens. The discipline is to cut before you open, not after you find out at close.`
- teachingNote: `This is the covers-down bleed seen from the hours side. If the same FOH slots carry excess week after week, the schedule is being built above what the forecast supports.`

**`foh_hours_under`**  -  favorable  -  badge `HOURS`  -  cat `SCHEDULING`  -  side `FOH ONLY`

- metric: `FOH ran lean on hours`
- whatHappened: `FOH hours came in below model for the volume. The floor ran lean, fewer servers covered more guests. That is efficient only if PPA held and CPLH stayed under the OPZ ceiling, so check PPA before you call it a win.`
- whatToDo: `Cross-check PPA and CPLH. PPA held and CPLH below the ceiling: document this FOH setup, it is your benchmark. PPA dropped: the floor was too lean to sell, you found the staffing floor, not the efficient setup.`
- teachingNote: `Lean is favorable until it crosses the ceiling. Study whether PPA dips when FOH hours run below model. That line is where efficiency turns into understaffing.`

**`boh_hours_over`**  -  unfavorable  -  badge `HOURS`  -  cat `SCHEDULING`  -  side `BOH ONLY`

- metric: `BOH hours did not flex down`
- whatHappened: `The kitchen carried more hours than the sales volume required. The model called for fewer BOH hours for what came through, but the schedule did not flex, driving labor above theoretical. FOH is unaffected, this is a back-of-house scheduling issue.`
- whatToDo: `Review the BOH lineup against actual sales by daypart. Where prep hours or line cooks exceeded what the volume needed, tighten there. Build next week's BOH from forecast sales divided by target SPLH.`
- teachingNote: `If kitchen overstaffing repeats in the same slots, the schedule is being built above what the sales forecast supports there.`

**`boh_hours_under`**  -  favorable  -  badge `HOURS`  -  cat `SCHEDULING`  -  side `BOH ONLY`

- metric: `BOH ran lean on hours`
- whatHappened: `BOH hours came in below model for the sales volume. The kitchen ran lean, fewer hours covered more output. That is a well-run kitchen only if ticket times stayed clean and quality held, so check SPLH and tickets.`
- whatToDo: `Cross-check SPLH and ticket times. Both held: document the BOH configuration, station assignments, prep staging, lineup, that is your replicable setup. Tickets slipped: the kitchen was stretched too thin.`
- teachingNote: `Lean kitchen hours are favorable when throughput holds. Study whether ticket times slip when BOH runs below model. That is where efficiency turns into understaffing.`

### Cross-axis pairs (4)  -  CROSS-AXIS · CPLH x SPLH

**`cplh_below_splh_above`**  -  unfavorable  -  badge `CPLH ↓ SPLH ↑`  -  cat `FORECAST`  -  side `BOTH SIDES`

- metric: `Forecast was low. The team executed.`
- whatHappened: `Fewer guests walked in than the schedule was built for, but everyone who came spent well and was served right. This is not an execution miss. The floor did its job on the volume that showed up.`
- whatToDo: `Fix the forecast, not the floor. Re-anchor next week’s covers to what the restaurant is actually doing, then build FOH hours from covers divided by your CPLH target. Leave the team that executed alone.`
- teachingNote: `CPLH below with SPLH above is a volume problem, not a people problem. If it repeats in the same dayparts, the forecast is running high and the schedule is built above real demand.`

**`cplh_on_splh_below`**  -  unfavorable  -  badge `CPLH = SPLH ↓`  -  cat `KITCHEN PRODUCTIVITY`  -  side `BOH ONLY`

- metric: `Kitchen slowed. Dining room held.`
- whatHappened: `Covers came in at forecast and FOH flexed to them. The kitchen did not keep pace: sales per BOH hour fell short. The leak is on the back of the house only.`
- whatToDo: `Pull kitchen ticket times and BOH hours against actual sales for this daypart. Clean tickets mean BOH was overstaffed for the volume. Slow tickets mean throughput is the constraint. Different problems, different fixes. FOH needs nothing this round.`
- teachingNote: `When only the kitchen axis moves, the diagnosis lives in BOH deployment or throughput. Watch station load and prep readiness in the dayparts where it repeats.`

**`cplh_above_splh_below`**  -  unfavorable  -  badge `CPLH ↑ SPLH ↓`  -  cat `CROSS AXIS`  -  side `BOTH SIDES`

- metric: `Floor ran lean. Kitchen slowed.`
- whatHappened: `The dining room covered more guests with fewer hours, which is efficient. The kitchen lagged on sales per BOH hour. Two different stories on the same shift, moving opposite ways.`
- whatToDo: `Check PPA before you call the floor a win. If PPA held, document the FOH deployment: it is a benchmark. Then look at the kitchen on its own: ticket times and station assignments. Fix the kitchen without breaking the FOH pattern that worked.`
- teachingNote: `Opposite-axis movement is two stories on one shift. Bank the lean FOH side as a benchmark. Treat the slow kitchen as its own root cause. Do not average them into one take.`

**`both_below`**  -  unfavorable  -  badge `CPLH ↓ SPLH ↓`  -  cat `VOLUME`  -  side `BOTH SIDES`

- metric: `Demand was soft.`
- whatHappened: `Fewer covers came in and the guests who did spent less. Both sides carried more hours than the volume needed. The leak is upstream of execution.`
- whatToDo: `Check the outside world first: weather, a nearby event, a day-of-week anomaly. If it was external, log the soft daypart and protect the schedule for the next normal week. If demand is softening for real, re-anchor the forecast and trim FOH and BOH hours together.`
- teachingNote: `Both axes down together is the one case you look outside the building first. A one-off external cause, tag it and move on. Repeats with no explanation mean the forecast is overstating demand.`

### Degraded state (21st)  -  NOT evolved, verbatim widget system status

**`on_model` / unknown id**  -  degraded  -  badge `PENDING`

- metric (widget title): `NOT YET ON-MODEL` (the shared label is
  `LeverCards.notYetOnModelLabel` = `'Not yet on-model'`; the
  `_LeverBadge` short form is `'PRIMARY LEVER: NOT YET ON-MODEL'`,
  short-badge surfaces render `' - '`).
- body: `No driver has been detected for this row yet. The card will populate once the shift posts actuals through the engine.`

This state is a system status, not teaching. It is shown verbatim
from `lib/widgets/lever_card.dart` (`LeverCardNotYetAvailable`). It
carries no `whatHappened` / `whatToDo` / `teachingNote`, no inline
emphasis markup, and no arrow chain. Renderers MUST resolve a null /
`on_model` lookup through `LeverCards.lookup` and surface this
degraded treatment exactly as the prior Presentation Split Rules
require  -  V2 does not change the degraded path.

## V2-2. Sign + sentiment convention (global, explicit)

This is the single global rule for every signed money / variance
value on the V2 surfaces. It is binding on the hero, the dollar-impact
disclosure, the dollar-attribution bars, the arrow-chain result node,
and any inline-emphasis dollar chip.

Rule:

- A loss reads as a negative dollar value, in red, with "below" /
  "lost" language. Glyph: minus sign `−` (U+2212), e.g. `−$247`.
- A profit reads as a positive dollar value, in green, with "above"
  language. Glyph: plus sign `+`, e.g. `+$686`.
- **Color is driven by a favorable / unfavorable flag, never by the
  raw arithmetic sign of the underlying number.** The favorable flag
  is `LeverCardData.isFavorable` / `CrossAxisPairData.isFavorable` for
  lever-keyed values, and an explicit favorable predicate (loss vs
  gain to the operator) for the hero and the dollar-impact rows. A
  renderer MUST NOT infer color from `value > 0`. Two values with the
  same arithmetic sign can have opposite sentiment (an over-model
  dollar gap is unfavorable; an over-target CPLH is favorable);
  color follows sentiment.
- The sign glyph and the favorable flag are decided together from the
  same sentiment source, so the displayed sign and the color never
  disagree (a red value is always shown with `−`; a green value is
  always shown with `+`).

Per-surface application (mirrors `variance_tab_v2_mockup.html`):

| Surface | Spec (verbatim from mockup) | Sentiment source |
| --- | --- | --- |
| Hero number | `−$247` rendered in the bad/red color (`.hero .num` uses `var(--bad)`) | unfavorable: a closable gap is a loss |
| Hero verdict pill | `▼ $247 LOST · below best possible` red pill | unfavorable |
| Hero context | `actual labor 20.7% vs best possible 20.0%` muted | neutral, no color |
| Dollar-impact disclosure title | `Loss if this continues` | unfavorable framing of the closable gap |
| Dollar-impact rows | `−$247` / `−$797` / `−$2,658` / `−$16,170` each in red, labelled `this week` / `this month` / `last 60 days` / `annualized` | unfavorable |
| Dollar-impact footer | `Best possible labor %: 20.0% · Actual labor %: 20.7% · Closable labor % gap: 0.7 pts` muted | neutral |
| Attribution bar  -  favorable axis | `covers` row: green fill on the positive side, value `+$686` green | favorable (covers axis was favorable here) |
| Attribution bar  -  unfavorable axis | `cplh` `−$462`, `splh` `−$406`, `boh wage` `−$27`, `ppa` `−$21`, `foh wage` `−$17`, each red fill on the negative side, red value | unfavorable |
| Attribution read-line | covers chip green `+$686`; cplh chip red `−$462`; splh chip red `−$406`; net `−$247 below best possible` emphasised red; `luck, not design` emphasised red | mixed, per-token sentiment |
| Arrow-chain result node | `−$247 lost` rendered in the end/red color (`.cnode.end .cv` uses `var(--bad)`) | unfavorable |

The mockup's WTD-table variance column (`.vr.good` / `.vr.bad`) and
the Full Week Projection points column (`.pts.good` / `.pts.bad`) also
obey the sentiment rule (a `+82` covers variance is green/good; a
`+$0.03` blended-wage variance is red/bad  -  same arithmetic sign,
opposite sentiment). The WTD table and projection numbers themselves
are FROZEN (V2-6); only their sign/color label obeys this convention,
no math changes.

## V2-3. Arrow-chain derivation rule (derived visual, not authored copy)

The arrow chain is a rendered visual on the This Week Primary Driver
card. It is NOT a catalog string and is never authored, transcribed,
or persisted. It is derived per render from the detected lever and
the existing attribution map. No new math: it consumes
`LaborModel.attributeDollarImpactByAxis` output that the card already
computes.

Three nodes, left to right (mirrors `.chain` in the mockup):

1. **Node 1  -  detected driver axis + direction.** The short axis label
   of the detected primary lever (`LeverCardData.shortLabel`, e.g.
   `COVERS`) and a direction token derived from the lever id suffix /
   `LeverDirection` (e.g. `↑ over plan` for `covers_up`). Sentiment
   color per V2-2 from `isFavorable`. In the mockup: `COVERS` / `↑ over
   plan`, green (`.cnode.up`).
2. **Node 2  -  dominant counter-axis.** The axis with the largest
   absolute opposing-sentiment contribution in
   `attributeDollarImpactByAxis`: take every axis whose sentiment is
   opposite the net result, pick `max(|contribution|)`, render its
   short label + direction. In the mockup the net is a loss and the
   dominant opposing axis is CPLH at `−$462` → `CPLH` / `↓ soft`, red
   (`.cnode.dn`). Ties resolve by the contract `_priorityOrder` list
   (lower index wins) so the visual is deterministic.
3. **Node 3  -  net signed result.** The net dollar result of the week
   (the same value the hero shows), signed and coloured per V2-2. In
   the mockup: `RESULT` / `−$247 lost`, red (`.cnode.end`).

Below the chain, the **full `whatHappened` sentence renders fused
directly beneath the chain** (no chart-then-paragraph split  -  the
chain and its sentence are one contiguous block, `.chain` immediately
followed by `<p class="tp">`). The sentence is the catalog
`whatHappened` string with inline emphasis applied per V2-4; words are
preserved byte-for-byte.

Degraded id (`on_model` / unknown / null lookup): render NO chain at
all (the `LeverCardNotYetAvailable` path is unchanged). A degraded
row never shows nodes.

## V2-4. Inline-emphasis markup convention

Catalog strings remain plain prose (V2-1 transcription is byte-for-byte
plain text  -  the persisted Dart strings carry NO markup). Inline
emphasis is applied by a renderer at display time on the V2 deep
surfaces (This Week `whatHappened` / read-line / `teachingNote`,
History inline emphasis, Learn frame body). The markup convention is
render-agnostic and MUST degrade to clean plain text on any
non-rendering surface (Shift card, exports, short badges, plain logs).

Convention (the safe markup the renderer recognises):

- Causal-phrase emphasis: a span the renderer promotes to the
  bad/red or good/green emphasis style (mockup `.em-bad` /
  `.em-good`). Markup token: `[[bad:…]]` / `[[good:…]]`.
- Dollar-value chip: a money token the renderer renders as a
  monospace chip (mockup `.chip` red / `.chip.g` green). Markup
  token: `[[chip:−$462]]` / `[[chipg:+$686]]`.
- Plain-text fallback: a renderer or surface that does not support
  the markup strips the tokens and emits only the inner text, so the
  string reads as the exact verbatim catalog sentence (`[[bad:check
  CPLH]]` → `check CPLH`). The fallback is the default for Shift,
  exports, short-badge, and any logging surface.

Hard rules:

- The persisted catalog strings (Lane B) carry NO markup. Markup is
  added by the renderer (Lane E) from a small emphasis map keyed by
  lever id, never by mutating the catalog.
- Words are preserved byte-for-byte minus the markup tokens. A
  renderer MUST NOT add, drop, or reorder any word; it only wraps
  existing spans.
- No markup token may leak into a non-rendering surface. Lane E owns
  the fallback and a test that asserts the stripped output equals the
  verbatim catalog string.

## V2-5. 3-frame Learn structure

The Learn tab keeps its existing rail: `Recurring Leak` / `Repeatable
Wins` / `Cross-Axis` (mockup `#rail`). The rail is preserved exactly
(three buttons, same order, same labels).

- **Recurring Leak** and **Repeatable Wins** each render as a
  3-frame swipe story:
  - Frame 1  -  What happened (Leak) / What held (Wins): metric title,
    coverage caption, a `.fvis` visual hint, and the `whatHappened`
    body with inline emphasis.
  - Frame 2  -  Why it matters: a teaching-consequence frame with its
    own visual hint and body.
  - Frame 3  -  What to do (Leak) / What to protect (Wins): the action
    frame, body, plus an action card (mockup `.actioncard` "THE PLAY")
    carrying the play derived from `whatToDo`.
- **Cross-Axis** stays a 4-pair swipe (the 4 `CrossAxisPairs`
  entries), each card showing What happened / What to do / What to
  study, exactly as the mockup `#crossTrack` renders.
- The pager dots adapt to the frame count of the active section
  (mockup `setDots(t)` reads `t.children.length`): 3 dots for Leak /
  Wins, 4 dots for Cross-Axis.

Tab-ownership rule reaffirmed (no concept duplicated across tabs, per
the Depth Surfaces "Tab ownership (no crossover)" table above): the
This Week Primary Driver card owns `whatHappened` + read-line +
`teachingNote`; Learn owns the 3-frame story including the `whatToDo`
play; History owns the evidence trail + inline emphasis only.
**`WHAT TO DO` is a Learn-surface field.** It is NOT rendered on This
Week. This Week shows WHAT HAPPENED and WHAT TO STUDY (the existing
`LeverCardWidget` shape); the action / `whatToDo` lives only on the
Learn 3-frame action card. This preserves the prior Presentation
Split (This Week deep card = metric + WHAT HAPPENED + WHAT TO STUDY).

## V2-6. Guardrails (unchanged, reaffirmed)

- **FROZEN  -  WTD vs plan table.** Structure and numbers untouched.
  Only the sign / color label obeys V2-2; no math, no row, no value
  changes.
- **FROZEN  -  Dollar-impact math.** The `−$247` / `−$797` / `−$2,658`
  / `−$16,170` projection and the best-possible / actual / closable
  footer math are unchanged. V2 only re-labels sign + color and
  re-titles the disclosure to `Loss if this continues`.
- **FROZEN  -  Full Week Projection.** Day rows, percentages, points,
  and projected total math unchanged; sign/color label only.
- **Telestrator excluded.** Not selected for V2. History keeps its
  existing OPZ band + previous-weeks list; only inline emphasis
  (V2-4) + sign convention (V2-2) apply to History.
- **Catalog LOCKED.** `LeverCards` + `CrossAxisPairs` copy is locked;
  this V2 Revision IS the gated change that authorizes the V2-1
  strings. Any further copy or entry change needs a new
  contract-revision PR + operator approval (same gate as
  auth / RLS / schema / proxy).
- **HP #2** demo parity: same tables, same reads, same UI in demo and
  prod; the V2 surfaces are not `kDemoMode`-branched.
- **HP #3** no app-logic change before 7.58: V2 is presentation +
  copy. Any driver-logic divergence the reconciliation memo finds is
  a separate operator-gated micro-slice, not folded into a V2 UI lane.
- **HP #10** operator-facing UX every slice: each V2 lane ships its
  surface + a demo-mode walkthrough (see the phase doc Frontend
  Exposure section).
- **Single Source of Truth unchanged.** `LaborModel.determineLever` /
  `determineLeverGated` / `attributeDollarImpactByAxis` are not
  modified by any V2 presentation lane. The arrow chain (V2-3) reads
  the existing attribution output; it does not re-derive a driver.
