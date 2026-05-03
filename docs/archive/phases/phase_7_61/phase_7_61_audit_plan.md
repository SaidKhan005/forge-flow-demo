# Phase 7.61 - Driver Key Audit + Sub-Slice Plan

Updated: 2026-05-03
Status: Active. `7.61.0` contract pin accepted 2026-05-02; `7.61.1`
accepted 2026-05-03 (F-1: analyzer fallthrough removal); `7.61.2`
accepted 2026-05-03 (F-2: empty-leak default flipped to `''`);
`7.61.3` accepted 2026-05-03 (F-3: dev-fixture lookup honesty).
`.4` deferred to `cutover.0b`; F-B deferred post-`cutover.5` (no
slice owner). Phase-8 hard gate now satisfied.
Owner: Variance / Vendor-connector lane
Companion contract: `docs/contracts/phase_7_61_driver_key_contract.md`

## Authority Order

When this plan and other docs conflict:

1. The active prompt.
2. `docs/contracts/phase_7_61_driver_key_contract.md` (this phase's
   own contract — key shape).
3. `docs/contracts/phase_7_58_primary_driver_contract.md` (semantics
   + presentation).
4. `docs/contracts/phase_7_55_architecture_contract.md` Layer 10 -
   Variance.
5. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`.
6. This file.
7. `CLAUDE.md`.

## Goal

Pin the driver-key catalog and storage forms before Phase 8's vendor
connectors start writing into the existing tables. Every producer that
mints or transforms a driver key, every consumer that reads one, and
every cross-table seam that carries one all collapse to the same
17-value space (16 catalog ids + `'on_model'` sentinel) in one of two
documented forms (lowercase canonical or upper-snake at the
`ShiftRecord` boundary). `7.61.0` mapped the current code to the
contract and emitted findings; `.1` has landed F-1, and `.2`/`.3`
land the remaining fixes.

## Non-Goals

- Decision logic (which axis fires, threshold tuning, priority order)
  — owned by `7.58`.
- Presentation split (which surface renders deep / medium / short
  shapes) — owned by `7.58`.
- Adding new driver families or new lever ids — out of scope for the
  whole `7.61` family; any new id requires a contract revision PR.
- Migrating `shifts.primary_lever` from upper-snake to lowercase
  on disk — sticky for back-compat with `7.5b` rows; revisit at
  `cutover.0b` (F-A below).

## Sub-Slice Family

| Slice | Type | Scope |
| --- | --- | --- |
| `7.61.0` | audit / docs | this plan + contract; enumerate findings; no production code |
| `7.61.1` | logic | ACCEPTED 2026-05-03 - replaced banned `firstWhere(orElse: coversDown / ppaUp)` patterns in `history_teaching_analyzer.dart` with `LeverCards.lookup` / catalog filtering (Finding F-1) |
| `7.61.2` | logic | ACCEPTED 2026-05-03 - flipped `mostCommonLeakId` initial value from `'covers_down'` to `''` and taught `variance_learn_tab.dart` to suppress the leak card on empty/unknown ids (Finding F-2) |
| `7.61.3` | dev-tooling | ACCEPTED 2026-05-03 - replaced banned `firstWhere(orElse: coversDown)` in `demo_fixture_data.dart` with `LeverCards.lookup` + explicit null handling via new `resolveLeverCard` helper (Finding F-3) |
| `7.61.4` | infra (deferred) | optional CHECK constraint pinning `week_records.primary_lever_id` lowercase form during Postgres cutover (Finding F-A); upper-snake `shifts.primary_lever` stays verbatim for back-compat with `7.5b` rows |

Each sub-slice ships with its own test additions per `7.58` precedent.
UX sub-slices interleave only when an operator-visible change is
involved; F-1 / F-2 close a silent overclaim that does reach the Learn
tab via `LearnTeachingSummary.primaryLeakId`. `7.61.1` shipped
`7.61.UX.1`; `7.61.2` ships `7.61.UX.2`. `7.61.3` is dev-only and
ships without UX evidence. `7.61.4` is infra-only.

## Hard Gates

- **All `7.61.*` sub-slices must accept before Phase 8 opens.** This
  matches the Hard Gates section of `PROJECT_TRACKER.md`
  (`all 7.61.* accept before Phase 8`). The driver key shape is what
  the vendor connectors write against; locking it before any
  connector ships is non-negotiable.
- **No production code changes in `7.61.0`.** Audit / docs only. Any
  divergence the audit finds becomes a `.1`/`.2`/`.3`/`.4` follow-up.
- **Contract binds before code lands.** The contract in
  `docs/contracts/phase_7_61_driver_key_contract.md` is the authority
  for what the per-slice fix has to make true. A `.1`-`.4` slice that
  diverges from the contract opens a contract revision PR first.
- **Walkthrough evidence at acceptance.** `7.61.UX.1` and
  `7.61.UX.2` demonstrate the Learn / History tab change (no more
  silent overclaim of `'covers down'` as the primary leak when there
  is none) in demo mode before the slice closes.

## Frontend Exposure

Most of `7.61` is non-rendering — it pins shape, not visuals. The two
findings that *do* surface to the operator are:

- **F-1 / `7.61.1` (accepted 2026-05-03)** - `HistoryTeachingAnalyzer.summarize`
  no longer falls through to `LeverCards.coversDown` / `LeverCards.ppaUp`
  on unknown ids. Leak summaries resolve through `LeverCards.lookup` and
  zero id/count/dayparts/side label on null. Benchmark summaries filter to
  known catalog ids before frequency and daypart aggregation, with a
  lookup guard left as defense-in-depth. Walkthrough:
  `docs/_walkthroughs/7.61.1.md`.
- **F-2 / `7.61.2`** — `HistoryTeachingAnalyzer` initialises
  `mostCommonLeakId = 'covers_down'` and only overrides it when
  `freq.isNotEmpty`. When there are zero leak records the analyzer
  still returns `'covers_down'`, which `LearnTeachingAnalyzer` stamps
  into `LearnTeachingSummary.primaryLeakId` and
  `variance_learn_tab.dart:152` renders as a real leak card. This is
  the same shape as `7.58` F-2 (engine empty-candidate fallback),
  surfacing one layer up in the analyzer. The fix flips the empty
  default to `''` and teaches the renderer to suppress the leak card
  when `primaryLeakId.isEmpty` (or via `LeverCards.lookup` returning
  null).

**Operator-facing surfaces touched by this phase:**

- `lib/screens/variance/variance_learn_tab.dart` — primary-leak card
  (`primaryLeakId` lookup at line 152) and dominant-win card
  (`dominantLeverId` lookup at line 158). Both must surface
  "no pattern yet" instead of silently materialising a fall-through
  card.

**Admin (11A) surfaces:** none. Driver keys are operator-only.

**UX sub-slice family:**

- `7.61.UX.1` - ACCEPTED 2026-05-03. Learn tab no longer receives an
  unknown-id analyzer summary that can fabricate primary-leak or benchmark
  copy (after the `firstWhere(orElse: ...)` removal). Evidence:
  `docs/_walkthroughs/7.61.1.md`.
- `7.61.UX.2` - ACCEPTED 2026-05-03. Learn tab no longer renders
  `'covers down'` as the primary leak when there are zero leak records
  (empty-state default flipped to `''`). Evidence:
  `docs/_walkthroughs/7.61.2.md`.

`7.61.3` and `7.61.4` ship without UX sub-slices (dev fixtures + infra
constraints, no operator-visible change).

**Demo-mode walkthrough (per UX sub-slice):**

- `7.61.UX.1` / `7.61.UX.2`: launch ForgeFlow demo → Variance > Learn.
  When the demo fixtures are tuned to "no leak this week", the
  PRIMARY LEAK card MUST render the "No leak pattern yet" placeholder
  instead of the `LeverCards.coversDown` card. Re-tune to a
  `cplh_down`-heavy week → PRIMARY LEAK card renders `cplh_down`
  copy. No drift between Learn and History for the same lever id.

Walkthroughs land with each UX sub-slice, not with this audit.

## Required Tests for `7.61.0`

- `flutter test test/contracts/phase_7_61_driver_key_test.dart` —
  contract assertions (catalog completeness, storage form, producer
  discipline, cross-table consistency).
- `flutter analyze` — no production code change, analyzer state must
  match pre-slice baseline (no new infos / warnings / errors).

`.1`/`.2`/`.3`/`.4` sub-slices each own their own additional test
files and update the affected sites' existing test suites.

## Acceptance Criteria for `7.61.0`

- [x] This plan doc exists with Frontend Exposure, sub-slice family,
  hard gates, authority order pointing at the contract.
- [x] `docs/contracts/phase_7_61_driver_key_contract.md` exists with
  catalog (16 + sentinel), storage forms, producer rules, consumer
  rules, cross-table consistency, SQLite schema, sub-slice family.
- [x] Findings section enumerates `F-1` through `F-B` (5 findings:
  three open follow-ups + two deferred infra items) with file:line
  citations, owner sub-slice (or "no slice owner"), and contract rule
  cite.
- [x] No production code modified.
- [x] `test/contracts/phase_7_61_driver_key_test.dart` exists and
  asserts every R-CAT, R-STOR, R-PROD, R-CONS rule that is testable
  without a renderer mount.
- [x] `CLAUDE.md` Authority Order section unchanged (the contract is
  referenced from this plan, not added to `CLAUDE.md`).
- [x] `PROJECT_TRACKER.md` Phase Board row for `7.61` updated to
  "active; 7.61.0 audit pinned; .1/.2/.3 queued; .4 deferred to
  cutover.0b" at `7.61.0` close. Hard Gates row unchanged.

## Acceptance Criteria for `7.61.1`

- [x] Banned `firstWhere(orElse: coversDown / ppaUp)` patterns removed
  from `history_teaching_analyzer.dart`.
- [x] Unknown leak ids degrade to empty/no-pattern summary fields:
  id, count, side label, and dayparts.
- [x] Unknown benchmark ids are filtered before frequency/daypart
  aggregation, including mixed known/unknown benchmark inputs.
- [x] F-2 empty-leak default remains untouched for `7.61.2`; F-3
  `demo_fixture_data.dart` cleanup remains untouched for `7.61.3`.
- [x] Walkthrough evidence captured in `docs/_walkthroughs/7.61.1.md`.
- [x] Archived resolved detail in
  `docs/archive/phases/phase_7_61/7.61.1_acceptance_closeout.md`.

## Audit Map (current code vs contract, file:line)

### Catalog (R-CAT)

- [app_defaults.dart:434-451](../../../lib/data/app_defaults.dart) —
  `LeverCards.all` is a `const List<LeverCardData>` with 16 entries.
  1:1 with the priority-order list at
  [labor_model.dart:131-141](../../../lib/services/labor_model.dart).
- [app_defaults.dart:471-479](../../../lib/data/app_defaults.dart) —
  `LeverCards.lookup` is the case-insensitive nullable resolver
  (added by `7.58.UX.5` F-1).
- [app_defaults.dart:460](../../../lib/data/app_defaults.dart) —
  `LeverCards.notYetOnModelLabel` is the canonical user-facing label
  for null lookups.

### Storage form (R-STOR)

- [shift_record.dart:22-23](../../../lib/models/shift_record.dart) —
  `primaryLever` field documented as upper-snake form, with the
  sentinel `'ON_MODEL'` listed explicitly.
- [shift_record.dart:316-318](../../../lib/models/shift_record.dart) —
  `normalizedLeverId` is the conversion seam (upper-snake →
  lowercase).
- [shift_record.dart:351, :390](../../../lib/models/shift_record.dart) —
  SQLite serialization uses `'primary_lever'` column; the upper-snake
  form is preserved verbatim through `toMap` / `fromMap`.
- [sqlite_database_schema.dart:142](../../../lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart) —
  `shifts.primary_lever TEXT NOT NULL` (no CHECK constraint).
- [sqlite_database_schema.dart:181](../../../lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart) —
  `week_records.primary_lever_id TEXT NOT NULL` (no CHECK constraint).
- [week_record.dart:196, :231](../../../lib/models/week_record.dart) —
  `WeekRecord.primaryLeverId` round-trips through SQLite as lowercase
  TEXT.
- [week_data.dart:31](../../../lib/models/week_data.dart) —
  `WeekData.primaryLeverId` is `String` (in-memory only; never
  persisted directly).

### Producers — engine boundary (R-PROD-1)

- [labor_model.dart:99-202](../../../lib/services/labor_model.dart) —
  `determineLever` returns lowercase snake_case from the candidate
  map. Empty-candidate fallback returns `'covers_down'` (line 187,
  legacy per `7.58` F-2).

### Producers — close-shift transform (R-PROD-2)

- [shift_service.dart:330](../../../lib/services/shift_service.dart) —
  `primaryLever: fact.primaryLeverId.toUpperCase()`. Single
  production-path uppercase.
- [mock_integration_replay_seed.dart:364](../../../lib/data/mock_integration_replay_seed.dart) —
  `primaryLever: lever.toUpperCase()`. Single replay-seed uppercase.
- [shift_record.dart:316-318](../../../lib/models/shift_record.dart) —
  `normalizedLeverId` is the only legal lowercase return path from
  storage form.

### Producers — sentinel (R-PROD-3)

- [current_week_state.dart:61](../../../lib/models/current_week_state.dart) —
  `shiftRecordFromSnapshot` mints `'ON_MODEL'` for open / projected
  rows.
- [mock_integration_replay_seed.dart:314](../../../lib/data/mock_integration_replay_seed.dart) —
  replay seed mints `'ON_MODEL'` for non-closed shifts.
- [fixture_seed_data.dart:116, :124, :133, :140, :149, :576](../../../lib/dev/fixture_seed_data.dart) —
  dev fixtures hard-code `'ON_MODEL'` for non-closed scenarios.

### Producers — aggregate / pattern filters (R-PROD-4)

- [history_pattern_builder.dart:25, :41-42](../../../lib/services/history_pattern_builder.dart) —
  filters `normalizedLeverId == 'on_model'` and
  `!validLeverIds.contains(leverId)` before emitting
  `HistoryPatternRecord`.
- [daypart_pattern_summary_builder.dart:56, :161-163](../../../lib/services/daypart_pattern_summary_builder.dart) —
  same filter (`_validLeverIds = LeverCards.all.map((l) => l.id).toSet()`)
  for lever counts; sentinel + unknown ids still increment
  `closedShiftCount` and metric averages.

### Producers — aggregate / WTD writers (R-PROD-5)

- [shift_service.dart:129/197, :448/545, :805/859](../../../lib/services/shift_service.dart) —
  three call sites, each `LaborModel.determineLever(...)` → lowercase
  `WeekData.primaryLeverId` / `WeekRecord.primaryLeverId`.
- [shift_data_source.dart:89/111](../../../lib/services/shift_data_source.dart) —
  replay WTD path → lowercase `WeekData.primaryLeverId`.
- [shift_dashboard_read_model.dart:222-235, :297](../../../lib/models/shift_dashboard_read_model.dart) —
  whole-day Shift → lowercase `primaryLeverId`. Read-model also
  carries the resolved `LeverCardData` via `LeverCards.lookup(...)!`
  per R-CONS-3.
- [baseline_manager_service.dart:108](../../../lib/services/baseline_manager_service.dart) —
  `primaryLeverId: shift.normalizedLeverId` → lowercase
  `BaselineCandidateShift.primaryLeverId`.
- [demo_fixture_data.dart:78-87](../../../lib/dev/demo_fixture_data.dart) —
  static `primaryLeverId` derived from `LaborModel.determineLever`
  (lowercase). See Finding F-3 for the `firstWhere` consumer at
  line 89-92.
- [mock_integration_replay_seed.dart:468](../../../lib/data/mock_integration_replay_seed.dart) —
  `primaryLeverId: lever` → lowercase `WeekData.primaryLeverId`.

### Consumers — renderer sites (R-CONS-1)

State as of `7.58.UX.5` close (2026-05-02). Every renderer site
resolves the id through `LeverCards.lookup`; null returns drive a
deliberate degraded surface. `7.61.0` re-verified each site against
the audit map in `phase_7_58_primary_driver_audit_plan.md`. No new
renderer drift.

### Consumers — service / analyzer sites (R-CONS-2)

- [history_teaching_analyzer.dart:98-118, :120-172](../../../lib/services/history_teaching_analyzer.dart) -
  F-1 RESOLVED by `7.61.1`: banned `firstWhere(orElse: coversDown / ppaUp)`
  pattern removed. Leak side uses `LeverCards.lookup` and zeros null
  lookups; benchmark side filters to known catalog ids before count/daypart
  aggregation and keeps a lookup guard.
- [history_teaching_analyzer.dart:79](../../../lib/services/history_teaching_analyzer.dart) -
  `mostCommonLeakId = 'covers_down'` initial value. See Finding F-2.
- [learn_teaching_analyzer.dart:34-100](../../../lib/services/learn_teaching_analyzer.dart) —
  consumer of `mostCommonLeakId`; emits empty string when no history
  records exist (`primaryLeakId = ''` at line 47), but propagates the
  `'covers_down'` overclaim from F-2 when a history exists with zero
  leaks.
- [demo_fixture_data.dart:89-92](../../../lib/dev/demo_fixture_data.dart) —
  banned `firstWhere(orElse: coversDown)` pattern in dev-only fixture.
  See Finding F-3.

### Consumers — read-model assertions (R-CONS-3)

- [shift_dashboard_read_model.dart:236-241](../../../lib/models/shift_dashboard_read_model.dart) —
  `LeverCards.lookup(leverId)!` asserts the `7.58` R6 contract
  (engine never returns `on_model`). Pre-`7.58.UX.5` this was a
  silent `orElse: coversDown`.

### Consumers — debug surfaces

- [data_alignment_audit_panel.dart:533, :561](../../../lib/widgets/data_alignment_audit_panel.dart) —
  raw `primaryLeverId` rendered for diagnostic purposes; lowercase
  display is acceptable here (debug panel, no operator-facing
  semantics).

### Cross-table fields (R-CONS-5 through R-CONS-9)

| Field | Form | Producer | Catalog filter? |
| --- | --- | --- | --- |
| `ShiftRecord.primaryLever` | UPPER_SNAKE | shift_service / replay seed / dev fixtures | no — accepts sentinel |
| `ShiftRecord.normalizedLeverId` (getter) | lowercase | derived | no — passes sentinel through |
| `ShiftFact.primaryLeverId` | lowercase | `ShiftFactBuilder` (engine direct) | no — never sentinel by R6 |
| `WeekData.primaryLeverId` | lowercase | shift_service WTD path / shift_data_source / replay seed | no — never sentinel by R6 |
| `WeekRecord.primaryLeverId` | lowercase | shift_service close / replay seed | no — never sentinel by R6 |
| `BaselineCandidateShift.primaryLeverId` | lowercase | `baseline_manager_service` | no — passes sentinel through |
| `ShiftDashboardReadModel.primaryLeverId` | lowercase | `buildWholeDay` (engine direct) | no — never sentinel by R6 |
| `HistoryPatternRecord.leverId` | lowercase | `HistoryPatternBuilder` | yes — sentinel + unknown skipped |
| `DaypartPatternSummary.dominant{Benchmark,Leak}LeverId` | lowercase, nullable | `DaypartPatternSummaryBuilder` | yes — sentinel + unknown skipped |
| `HistoryTeachingSummary.mostCommonLeakId` | lowercase or empty string | `HistoryTeachingAnalyzer` | partial - unknown ids reset to empty in `7.61.1`; empty leak set still defaults to `'covers_down'` (F-2) |
| `HistoryTeachingSummary.mostCommonBenchmarkId` | lowercase or empty string | `HistoryTeachingAnalyzer` | yes - filters unknown ids and emits empty string when none |
| `LearnTeachingSummary.primaryLeakId` | lowercase | `LearnTeachingAnalyzer` | inherits from above (F-2) |
| `LearnRepeatableWinSummary.dominantLeverId` | lowercase | `LearnRepeatableWinsReadService` | yes — non-null guarded by `dominantBenchmarkLeverId != null` |

## Findings

Numbered as `F-1`, `F-2`, `F-3`, `F-A`, `F-B`. `F-1` through `F-3`
each become the prompt seed for a follow-up against the named sub-slice
(`7.61.1` / `7.61.2` / `7.61.3`). `F-A` is owned by `7.61.4`
(deferred to `cutover.0b`). `F-B` has no slice owner — it parks the
deferred `shifts.primary_lever` lowercase storage migration until
post-`cutover.5`.

### F-1 / `7.61.1` — `firstWhere(orElse: coversDown / ppaUp)` in `history_teaching_analyzer.dart`

**Where:**
Pre-fix sites were `history_teaching_analyzer.dart:88-91` and
`:131-134`. Current accepted implementation lives at
[history_teaching_analyzer.dart:98-118](../../../lib/services/history_teaching_analyzer.dart)
and [history_teaching_analyzer.dart:120-172](../../../lib/services/history_teaching_analyzer.dart).

**Symptom:** the banned pre-`7.58.UX.5` pattern. Today the inputs are
pre-filtered (`HistoryPatternBuilder` already drops `'on_model'` and
unknown ids per R-PROD-4), so the `orElse` is defensive in practice.
But the contract (R-CONS-2) says service consumers that produce a
downstream summary whose value will be rendered must either filter
to known catalog ids OR resolve through `LeverCards.lookup`.
A future producer that didn't pre-filter would silently overclaim a
real leak / benchmark card via the fall-through.

**Contract reference:** R-CONS-2 (service consumers), R-STOR-7
(`lookup` returns null for unknown).

**Owns:** `7.61.1`. Accepted implementation uses
`LeverCards.lookup(mostCommonLeakId)` plus an empty/no-pattern reset on
the leak side, and a known-catalog filter plus lookup guard on the
benchmark side.

**Status:** RESOLVED in `7.61.1` (accepted 2026-05-03). Evidence:
`docs/_walkthroughs/7.61.1.md`,
`test/contracts/phase_7_61_driver_key_test.dart` (28 active + 1 F-2
holdout skipped), `test/history_teaching_analyzer_test.dart`, and
`test/learn_teaching_analyzer_test.dart`. Archived closeout:
`docs/archive/phases/phase_7_61/7.61.1_acceptance_closeout.md`.

### F-2 / `7.61.2` — `mostCommonLeakId = 'covers_down'` empty-state default

**Where:**
[history_teaching_analyzer.dart:79](../../../lib/services/history_teaching_analyzer.dart).

**Symptom:** `String mostCommonLeakId = 'covers_down';` initialises
the default to a real catalog id, then only overrides it when
`freq.isNotEmpty`. When a week has zero leak records the analyzer
returns `'covers_down'`, `LearnTeachingAnalyzer` stamps it into
`LearnTeachingSummary.primaryLeakId`, and
[variance_learn_tab.dart:152](../../../lib/screens/variance/variance_learn_tab.dart)
materialises a real leak card the operator did not earn.

This is the same shape as `7.58` Finding F-2 (engine empty-candidate
returns `'covers_down'`) one layer up in the analyzer. Both fixes
should land together — flipping the engine default without flipping
the analyzer default would still leak overclaim through this path.

**Contract reference:** R-CONS-2 (service consumers), R-CONS-9
(summary fields carry catalog id OR empty string when no evidence
exists).

**Owns:** `7.61.2`. Flip default to `''` (or null with appropriate
type change), teach `variance_learn_tab.dart:152` to suppress the
leak card on `primaryLeakId.isEmpty` (or when `LeverCards.lookup`
returns null).

**Status:** RESOLVED in `7.61.2` (accepted 2026-05-03). Evidence:
`docs/_walkthroughs/7.61.2.md`,
`test/contracts/phase_7_61_driver_key_test.dart` (32 active, 0
skipped — F-2 holdout flipped on),
`test/history_teaching_analyzer_test.dart`,
`test/learn_teaching_analyzer_test.dart`. Implementation:
`history_teaching_analyzer.dart:89` initialises
`String mostCommonLeakId = '';`; `variance_learn_tab.dart` suppresses
the leak card when `primaryLeakId.isEmpty` or `LeverCards.lookup`
returns null. Archived closeout (if present):
`docs/archive/phases/phase_7_61/7.61.2_acceptance_closeout.md`.

### F-3 / `7.61.3` — `firstWhere(orElse: coversDown)` in `demo_fixture_data.dart`

**Where:**
[demo_fixture_data.dart:89-92](../../../lib/dev/demo_fixture_data.dart).

**Symptom:** dev-only static fixture's `primaryLeverCard` getter uses
the banned pattern. Not in any production-render path
(`demo_fixture_data` is `lib/dev/`, marked frozen-ish per the
Service-Layer Split in `CLAUDE.md`). But the broken pattern is a
templating risk — anyone copying the fixture as a starting point
inherits the same overclaim.

**Contract reference:** R-CONS-1 (renderer consumers — applies to
fixtures used by tests / dev tools), R-STOR-7.

**Owns:** `7.61.3`. Replace with `LeverCards.lookup` + explicit null
handling. Audit other `lib/dev/` fixtures while in the file.

**Status:** RESOLVED in `7.61.3` (accepted 2026-05-03). Evidence:
`docs/_walkthroughs/7.61.3.md`,
`test/contracts/phase_7_61_driver_key_test.dart` (33 active + 1
intentionally skipped). Implementation: `demo_fixture_data.dart:100-101`
calls `resolveLeverCard(primaryLeverId)`; the new helper at
`demo_fixture_data.dart:110+` wraps `LeverCards.lookup(id) ?? throw
StateError(...)`. The banned `firstWhere(orElse: coversDown)` pattern
no longer appears in executable code. Archived closeout (if present):
`docs/archive/phases/phase_7_61/7.61.3_acceptance_closeout.md`.

### F-A / `7.61.4` — Storage-form CHECK constraint deferred to Postgres cutover

**Where:**
[sqlite_database_schema.dart:142, :181](../../../lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart),
future Postgres migrations under `db/migrations/`.

**Symptom:** Today's SQLite schema has `TEXT NOT NULL` columns with
no CHECK constraint on the lever-id form. The contract pins
upper-snake for `shifts.primary_lever` (R-STOR-2) and lowercase for
`week_records.primary_lever_id` (R-STOR-4) at the application layer
only. A vendor connector with a bug could slip through.

**Contract reference:** R-STOR-2, R-STOR-4, SQLite Schema section.

**Owns:** `7.61.4` (deferred to `cutover.0b`). When the Postgres
schema lands, add `CHECK (primary_lever_id ~ '^[a-z_]+$')` on
`week_records` (or equivalent enum / domain type). Preserves the
upper-snake form on `shifts.primary_lever` verbatim for back-compat
with `7.5b` rows already on disk; the lowercase migration of that
column is its own, larger follow-up — see F-B.

**Status:** DEFERRED (sequenced after `cutover.0b`).

### F-B / no slice owner — `shifts.primary_lever` lowercase migration

**Where:**
[shift_record.dart:22-23](../../../lib/models/shift_record.dart),
[shift_record.dart:316-318](../../../lib/models/shift_record.dart),
[sqlite_database_schema.dart:142](../../../lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart),
future Postgres migrations under `db/migrations/`.

**Symptom:** `shifts.primary_lever` carries the upper-snake form
(`'COVERS_DOWN'`) for back-compat with `7.5b` rows already on disk.
Every other lever-id column is lowercase canonical (R-STOR-4); the
shifts column is the single asymmetry the contract documents
(R-STOR-2). It works because `ShiftRecord.normalizedLeverId` lowercases
on read, but the storage asymmetry is a permanent maintenance tax — a
new operator looking at the schema sees one column shaped differently
from the others, with no in-schema reason for it.

**Contract reference:** R-STOR-2 (upper-snake at this one boundary),
R-STOR-3 (`normalizedLeverId` is the conversion seam), SQLite Schema
section.

**Owns:** no slice in the `7.61` family. Revisit when the Postgres
cutover has retired the SQLite path (post-`cutover.5`), at which point
a one-shot `UPDATE shifts SET primary_lever = lower(primary_lever)`
plus a CHECK constraint pinning the lowercase form lands in a single
migration. Not blocking Phase 8 — vendor connectors keep writing
upper-snake into the existing column shape until then.

**Status:** DEFERRED (no owner; revisit post-`cutover.5`).

## Notes for `7.61.1`-`7.61.4` Authors

- The contract is final at `7.61.0` close; `.1`-`.4` slices implement
  to it and only revise the contract via an explicit revision PR.
- Each slice's prompt should cite this Findings list by ID
  (`F-1` / `7.61.1` etc.) so traceability stays clean.
- `7.61.1` and `7.61.2` together close the same harm chain (Learn
  tab silently overclaims a leak). `7.61.1` accepted first by using a
  post-tie-break lookup reset on the leak side and a catalog allow-list on
  the benchmark side, while intentionally leaving the empty-leak default
  for `7.61.2`.
- `lever_logic_test.dart` and `shift_driver_trust_audit_test.dart`
  pin `7.58` engine math and may need adjustment when `7.58.0b`
  flips the empty-candidate default. `7.61.2` does not touch the
  engine; the analyzer flip is independent.
