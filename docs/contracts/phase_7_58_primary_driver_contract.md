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
`LeverCards.all` at `lib/data/app_defaults.dart:434`. There is also
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

A sibling catalog `lib/data/cross_axis_pair_catalog.dart` parallels
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
