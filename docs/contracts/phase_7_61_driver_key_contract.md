# Phase 7.61 - Driver Key Contract

Updated: 2026-05-03
Owner: Codex architecture
Status: Active authority for `7.61` sub-slice family
Companion: `docs/archive/phases/phase_7_61/phase_7_61_audit_plan.md` (archived 2026-05-03 after `.0`/`.1`/`.2`/`.3` accepted; `.4` carried to `cutover.0b`)

## Why This Exists

Every variance / shift / history / learn / baseline surface keys off the
same lever id (`'covers_down'`, `'cplh_up'`, …). The id flows from
`LaborModel.determineLever` through eight different model fields
(`ShiftRecord.primaryLever`, `WeekData.primaryLeverId`,
`WeekRecord.primaryLeverId`, `ShiftFact.primaryLeverId`,
`BaselineCandidateShift.primaryLeverId`,
`ShiftDashboardReadModel.primaryLeverId`,
`HistoryPatternRecord.leverId`,
`DaypartPatternSummary.dominant{Benchmark,Leak}LeverId`) into four
downstream summary fields (`HistoryTeachingSummary.mostCommonLeakId` /
`mostCommonBenchmarkId`, `LearnTeachingSummary.primaryLeakId`,
`LearnRepeatableWinSummary.dominantLeverId`) and two SQLite columns
(`shifts.primary_lever`, `week_records.primary_lever_id`).

`docs/contracts/phase_7_58_primary_driver_contract.md` pins the
*semantics* of that id (input axes, decision logic, presentation split,
row-status honesty). This contract pins the *key shape*: what values are
in the catalog, what string form each storage seam carries, which
producers are allowed to mint or transform a key, and what consumers
must do when they read one. The split exists because the key contract
binds Phase 8 (vendor connector writes) before any decision-logic
revisit; vendor adapters need a stable shape to write against, not a
finalized semantics layer.

## Authority Position

Sibling to `docs/contracts/phase_7_58_primary_driver_contract.md`.
Above all `7.61.*` slice docs and any code that mints, persists, or
reads a driver key. When this doc and `7.58` conflict on **key shape**
(catalog membership, storage form, producer/consumer rules, cross-table
consistency), this doc wins. When they conflict on **semantics**
(decision logic, presentation split, row-status honesty), `7.58` wins.
Layer 10 of `phase_7_55_architecture_contract.md` (Variance) sits above
both.

## The Catalog

### Engine ids (16)

The 16 lowercase snake_case ids minted by `LaborModel.determineLever`
match 1:1 with `LeverCards.all`
([app_defaults.dart:434](../../lib/data/app_defaults.dart)) and the
priority-order list at
[labor_model.dart:131](../../lib/services/labor_model.dart):

| Family | Up id | Down / Over id |
| --- | --- | --- |
| Covers (volume) | `covers_up` | `covers_down` |
| PPA (price) | `ppa_up` | `ppa_down` |
| CPLH (FOH productivity) | `cplh_up` | `cplh_down` |
| SPLH (BOH productivity) | `splh_up` | `splh_down` |
| FOH wage | `foh_wage_up` | `foh_wage_down` |
| BOH wage | `boh_wage_up` | `boh_wage_down` |
| FOH hours flex | `foh_hours_under` | `foh_hours_over` |
| BOH hours flex | `boh_hours_under` | `boh_hours_over` |

### Sentinels (1)

`'on_model'` — placeholder for `ShiftRecord` rows constructed from open
snapshots
([current_week_state.dart:61](../../lib/models/current_week_state.dart),
[mock_integration_replay_seed.dart:314](../../lib/data/mock_integration_replay_seed.dart),
[fixture_seed_data.dart:116-149, :576](../../lib/dev/fixture_seed_data.dart)).
Stored as `'ON_MODEL'` in upper-snake form. **Never** returned by
`determineLever`.

### Out-of-catalog ids

There are none. Every other token used in production code as a driver
key collapses to one of the 17 above. Any new id requires a
`LeverCards.all` entry and an explicit `7.61` revision PR before
landing in any producer or storage layer.

## Storage Forms

The same id appears in two on-the-wire forms. Crossing between them is
allowed only at named boundaries.

| Form | Example | Where it lives |
| --- | --- | --- |
| **Lowercase canonical** (`snake_case`) | `'covers_down'`, `'on_model'` | engine output (`LaborModel.determineLever`); every aggregate / summary field; `WeekData.primaryLeverId`, `WeekRecord.primaryLeverId`, `ShiftFact.primaryLeverId`, `BaselineCandidateShift.primaryLeverId`, `ShiftDashboardReadModel.primaryLeverId`, `HistoryPatternRecord.leverId`, `DaypartPatternSummary.dominant*LeverId`, `HistoryTeachingSummary.mostCommon*Id`, `LearnTeachingSummary.primaryLeakId`, `LearnRepeatableWinSummary.dominantLeverId`; SQLite `week_records.primary_lever_id` |
| **Upper-snake storage form** | `'COVERS_DOWN'`, `'ON_MODEL'` | exactly one field — `ShiftRecord.primaryLever` (in-memory and SQLite `shifts.primary_lever`) |

### Storage-form rules

- **R-STOR-1** — `LaborModel.determineLever` returns lowercase
  snake_case. No spaces, no uppercase characters, no leading or
  trailing whitespace.
- **R-STOR-2** — `ShiftRecord.primaryLever` MUST carry upper-snake form
  (`'COVERS_DOWN'`, `'ON_MODEL'`). The lowercase canonical form is
  forbidden in this field.
- **R-STOR-3** — `ShiftRecord.normalizedLeverId` is the only legal
  conversion seam from upper-snake storage to lowercase canonical for a
  shift row. Renderers MUST go through it (or through
  `LeverCards.lookup`, which is case-insensitive) and MUST NOT
  hand-roll case conversion.
- **R-STOR-4** — Every other lever-id-bearing field MUST carry
  lowercase canonical form. Upper-snake in any non-`ShiftRecord` field
  is a bug.
- **R-STOR-5** — `LeverCards.lookup` is case-insensitive: it accepts
  both forms and resolves to the same `LeverCardData`. Renderers MUST
  use it instead of `LeverCards.all.firstWhere(...)`.
- **R-STOR-6** — `LeverCards.lookup('on_model')` returns `null`
  (sentinel is intentionally outside the catalog). The same applies to
  `'ON_MODEL'`.
- **R-STOR-7** — `LeverCards.lookup` returns `null` for unknown ids and
  for null / empty input. Renderers MUST surface that null as an
  explicit degraded state — never fall through to a real card.

## Producer Rules

A "producer" is any code that mints a driver key (constructs a string
that downstream code will treat as a lever id) or transforms one
across a storage-form boundary.

- **R-PROD-1** — `LaborModel.determineLever` is the only function
  allowed to mint an engine id. No producer rederives a key from a
  different formula or rounded UI numbers (this re-states the
  `7.58` Single Source of Truth rule for the key-shape angle).
- **R-PROD-2** — The lowercase → upper-snake transform happens in
  exactly two places:
  - [`shift_service.dart:330`](../../lib/services/shift_service.dart) —
    closing a `ShiftFact` into a `ShiftRecord` (`fact.primaryLeverId.toUpperCase()`).
  - [`mock_integration_replay_seed.dart:364`](../../lib/data/mock_integration_replay_seed.dart) —
    seeding closed `ShiftRecord` rows for replay (`lever.toUpperCase()`).
  No other producer is allowed to call `.toUpperCase()` on a lever id
  for storage. The upper-snake → lowercase transform is owned solely
  by `ShiftRecord.normalizedLeverId` (R-STOR-3).
- **R-PROD-3** — The `'on_model'` sentinel is minted only at three
  sites:
  - [`current_week_state.dart:61`](../../lib/models/current_week_state.dart) —
    `shiftRecordFromSnapshot` (open / projected rows).
  - [`mock_integration_replay_seed.dart:314`](../../lib/data/mock_integration_replay_seed.dart) —
    seed open shifts for replay.
  - [`fixture_seed_data.dart:116-149, :576`](../../lib/dev/fixture_seed_data.dart) —
    dev fixture open / projected rows.
  All three write the upper-snake form `'ON_MODEL'`, since the only
  field carrying the sentinel is `ShiftRecord.primaryLever`.
- **R-PROD-4** — Aggregate / pattern producers
  ([`history_pattern_builder.dart:41-42`](../../lib/services/history_pattern_builder.dart),
  [`daypart_pattern_summary_builder.dart:162-163`](../../lib/services/daypart_pattern_summary_builder.dart))
  MUST skip rows whose `normalizedLeverId == 'on_model'` AND whose id
  is not in `LeverCards.all`. The sentinel and unknown ids do not
  contribute to leak / benchmark counts. (Closed-shift counts and
  metric averages still include them.)
- **R-PROD-5** — Producers writing to `WeekData.primaryLeverId`,
  `WeekRecord.primaryLeverId`, `ShiftFact.primaryLeverId`,
  `ShiftDashboardReadModel.primaryLeverId`, and
  `BaselineCandidateShift.primaryLeverId` write the lowercase
  canonical form direct from `determineLever` (or from
  `ShiftRecord.normalizedLeverId`). Calling `.toLowerCase()` on storage
  form is acceptable; calling `.toUpperCase()` is forbidden.

## Consumer Rules

A "consumer" is any code that reads a driver key and uses it to
choose presentation, classification, or further routing.

- **R-CONS-1** — Renderer consumers MUST resolve a lever id through
  `LeverCards.lookup(id)` and treat a null return as an explicit
  degraded state (per `7.58` Presentation Split Rules and
  `7.58.UX.5`). The pre-`7.58.UX.5` `LeverCards.all.firstWhere(...
  orElse: () => LeverCards.coversDown)` / `() => ppaUp` pattern is
  banned in renderer code paths.
- **R-CONS-2** — Service consumers that produce a downstream summary
  whose value will be rendered (e.g. `HistoryTeachingAnalyzer`,
  `LearnTeachingAnalyzer`) MUST either filter to known catalog ids
  before producing the summary OR resolve through `LeverCards.lookup`.
  A silent `firstWhere(... orElse: () => LeverCards.coversDown)` in a
  service still drives a renderer to overclaim a real driver one
  layer down — same harm, longer call chain.
- **R-CONS-3** — Read-model consumers that operate on engine output
  guaranteed to be in the catalog (per R-STOR-1 + 7.58 R6:
  `determineLever` never returns `'on_model'`) MAY assert non-null
  via `LeverCards.lookup(id)!` so a hypothetical contract violation
  surfaces as a crash rather than a silent fall-through. Used today
  by `ShiftDashboardReadModel.buildWholeDay`
  ([line 241](../../lib/models/shift_dashboard_read_model.dart)).
- **R-CONS-4** — Consumers MUST NOT use the upper-snake form
  (`'COVERS_DOWN'`, `'ON_MODEL'`) directly for comparisons or
  rendering text. Every `if (id == 'COVERS_DOWN')` is a bug —
  normalize first.

## Cross-Table Key Consistency

When the same shift / week / closed-row truth flows through multiple
fields, the lever id is identical (modulo the upper-snake / lowercase
form difference at the `ShiftRecord` boundary).

- **R-CONS-5** — For a closed `ShiftFact` with engine id `e`, the
  derived `ShiftRecord.primaryLever` is `e.toUpperCase()` and
  `ShiftRecord.normalizedLeverId` is `e`. Round-trip is identity.
- **R-CONS-6** — For a closed `ShiftRecord` with `normalizedLeverId
  == e`:
  - `BaselineCandidateShift.primaryLeverId` derived from it (via
    [`baseline_manager_service.dart:108`](../../lib/services/baseline_manager_service.dart))
    equals `e`.
  - `HistoryPatternRecord.leverId` derived from it (via
    [`history_pattern_builder.dart:49`](../../lib/services/history_pattern_builder.dart))
    equals `e` whenever `e ∈ LeverCards.all` and `e != 'on_model'`.
- **R-CONS-7** — `WeekData.primaryLeverId` and
  `WeekRecord.primaryLeverId` are produced by direct
  `LaborModel.determineLever` calls
  ([`shift_service.dart:129/197`, `:448/545`, `:805/859`](../../lib/services/shift_service.dart);
  [`shift_data_source.dart:89/111`](../../lib/services/shift_data_source.dart);
  [`mock_integration_replay_seed.dart:410/468`](../../lib/data/mock_integration_replay_seed.dart)).
  Both fields therefore carry one of the 16 catalog ids in lowercase
  form — never `'on_model'`, never upper-snake. Differences between
  the two for the same week are legitimate when their aggregation
  windows or input axis subsets differ (per `7.58` Honesty Rules); the
  shape is identical regardless.
- **R-CONS-8** — `DaypartPatternSummary.dominantBenchmarkLeverId` and
  `dominantLeakLeverId` are nullable. When non-null they MUST equal
  one of the 16 catalog ids in lowercase form — never `'on_model'`,
  never upper-snake, never an unknown id (the producer at
  [`daypart_pattern_summary_builder.dart:163`](../../lib/services/daypart_pattern_summary_builder.dart)
  enforces this via the `_validLeverIds` filter).
- **R-CONS-9** — Same for
  `HistoryTeachingSummary.mostCommonLeakId` /
  `mostCommonBenchmarkId`, `LearnTeachingSummary.primaryLeakId`,
  `LearnRepeatableWinSummary.dominantLeverId`. These summary fields
  carry the lowercase canonical form (or empty string when no
  evidence exists) and are downstream of the producer filters above.

## SQLite Schema

| Column | Table | Form | Source field |
| --- | --- | --- | --- |
| `primary_lever` | `shifts` | UPPER_SNAKE TEXT NOT NULL | `ShiftRecord.primaryLever` |
| `primary_lever_id` | `week_records` | lowercase TEXT NOT NULL | `WeekRecord.primaryLeverId` |

The schema does not enforce form via CHECK constraint; the contract is
enforced at the application boundary (R-STOR-2, R-STOR-4) and by the
producer rules above. Phase 8 vendor connectors writing into these
tables MUST honour the per-column form. A future Postgres migration
(Phase 9 / cutover.0b) MAY add a CHECK constraint pinning the
lowercase form for `week_records.primary_lever_id`; the upper-snake
form on `shifts.primary_lever` is preserved verbatim during cutover for
back-compatibility with `7.5b` rows already on disk. See `7.61`
Findings F-A and F-B.

## Sub-Slice Family

| Slice | Owns |
| --- | --- |
| `7.61.0` | this audit + contract; no production code change |
| `7.61.1` | ACCEPTED 2026-05-03 - `history_teaching_analyzer.dart` `firstWhere(orElse: ...)` removal (F-1) |
| `7.61.2` | `history_teaching_analyzer.dart` `mostCommonLeakId = 'covers_down'` empty-state default (F-2 below) |
| `7.61.3` | `demo_fixture_data.dart` `firstWhere(orElse: …)` cleanup + dev-only audit (F-3 below) |
| `7.61.4` | optional CHECK constraints on `week_records.primary_lever_id` form during Postgres cutover (F-A below) — defers to `cutover.0b` if the form column hasn't been touched by then |

`docs/archive/phases/phase_7_61/phase_7_61_audit_plan.md` (archived) owns
the per-slice scope, Frontend Exposure, hard gates, and the running
Findings list.
**All `7.61.*` sub-slices must accept before Phase 8 opens** (per
`PROJECT_TRACKER.md` Hard Gates).

## Hard Promises Crossref

This contract sits inside the 10 Hard Promises in `CLAUDE.md`. The
ones that bind:

- **HP #1** — Phase 8 is a pure transport swap. Vendor connectors
  write into the existing tables, which means they write against
  the per-column forms this contract pins. A connector that wrote
  lowercase into `shifts.primary_lever` would silently corrupt the
  renderer-side normalisation seam. `7.61.0` accepts before any
  vendor adapter is wired (Phase 8 hard gate).
- **HP #3** — `7.61.0` is docs/audit only; logic-deciding work
  starts at `7.61.1`+ follow-ups generated by this audit.
- **HP #6** — Drivers are recommendations, not commands. The
  contract does not turn the lever id into an automatic action.
- **HP #10** — `7.61.*` sub-slices ship with their UX evidence per
  the plan doc's Frontend Exposure section when an operator-visible
  change is involved.
