# Phase 7.58 - Primary Driver Audit + Sub-Slice Plan

Updated: 2026-05-02
Status: Active. `7.58.0` contract pin + `7.58.5` row purity + `7.58.UX.5` renderer honesty (F-1/F-6/F-7) accepted 2026-05-02; zero DRIFT. `7.58.1`/`.2`/`.3`/`.4` queued.
Owner: Variance / Learn lane
Companion contract: `docs/contracts/phase_7_58_primary_driver_contract.md`

## Authority Order

When this plan and other docs conflict:

1. The active prompt.
2. `docs/contracts/phase_7_58_primary_driver_contract.md` (this phase's
   own contract).
3. `docs/contracts/phase_7_55_architecture_contract.md` Layer 10 -
   Variance.
4. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`.
5. This file.
6. `CLAUDE.md`.

## Goal

Make Primary Driver — the single label every variance / shift /
history surface uses to answer "what was the biggest lever?" — honest,
parity-tested, and free of the silent inheritance fold that lets open
and projected rows inherit a closed row's driver.

`7.58.0` (this audit) maps the current code to the contract and
emits findings. The `.1`-`.5` sub-slices land the fixes.

## Non-Goals

- Daypart-aware Shift live driver (Phase `10.5`, owned separately).
- Adding new driver axes beyond the existing six.
- Changing the priority-order tie-break ranking (preserved as-is per
  `phase_7_55p_1_shift_driver_trust_audit`).
- Anything past the variance / shift / history / learn / baseline
  surfaces enumerated in the contract.

## Sub-Slice Family

| Slice | Type | Scope |
| --- | --- | --- |
| `7.58.0` | audit / docs | this plan + contract; enumerate findings; no production code |
| `7.58.1` | logic | per-driver dollar-impact attribution (which axis owns how many cents of the total gap) |
| `7.58.2` | logic | driver identity in History / Learn — parity audit between History pattern records and Variance Learn |
| `7.58.3` | logic | history coverage — number of historical dayparts a driver shows up in (denominator for repeat-detection) |
| `7.58.4` | fixture | demo / replay fixtures must round-trip through `determineLever` and produce the stored `primaryLeverId` |
| `7.58.5` | logic | variance row purity — remove the daypart carry-forward G.5 fold (open / projected rows stop inheriting closed lever ids) |

Each sub-slice ships with its own UX evidence per HP #10. UX
sub-slices interleave: backend slice `7.58.X` is followed by
`7.58.UX.X` when an operator-visible change is involved (`.1`,
`.2`, `.5`). Slices `.3` and `.4` are non-rendering and ship without
UX sub-slices.

## Hard Gates

- **All five sub-slices must accept before `11b.0` opens.** This
  matches the Hard Gates section of `PROJECT_TRACKER.md` line 242
  ("All `7.58` sub-slices accept before `11b.0`").
- **No production code changes in `7.58.0`.** Audit / docs only. Any
  divergence the audit finds becomes a `.0a`/`.0b`/`.0c` follow-up
  prompt against the relevant `.1`-`.5` sub-slice.
- **Contract binds before code lands.** The contract in
  `docs/contracts/phase_7_58_primary_driver_contract.md` is the
  authority for what the per-slice fix has to make true. A `.1`-`.5`
  slice that diverges from the contract opens a contract revision PR
  first, then ships the code.
- **Walkthrough evidence at acceptance.** Backend slices that change
  what the operator sees must demonstrate the change in demo mode
  before the slice closes (`docs/CODEX_PROMPT_GENERATION_STANDARD.md`
  walkthrough rule).

## Frontend Exposure

This phase touches multiple operator-facing surfaces. The contract's
"Presentation Split" table is the source of truth for which surface
renders which shape. Per HP #10:

**Operator-facing surfaces touched by this phase:**

- `lib/screens/variance/variance_this_week_tab.dart` — Primary Driver
  full card and the inline `_LeverBadge` inside the closed-shift
  detail. `7.58.5` removes daypart carry-forward inheritance for the
  Full Week Projection day-row driver text.
- `lib/widgets/week_history_tile.dart` — Previous Weeks short badge.
- `lib/screens/week_detail_screen.dart` — Week Detail full card.
- `lib/screens/variance/variance_history_tab.dart` — leak evidence
  card (`LeverCardData.metric` only).
- `lib/screens/variance/variance_learn_tab.dart` — three-card leak /
  win teaching shape (`whatHappened` + `whatToDo` + `teachingNote`).
  `7.58.2` lands parity adjustments here.
- `lib/screens/baseline_manager/baseline_manager_day_detail.dart` —
  per-candidate `LEVER` chip via `leverLabel(...)`.
- `lib/screens/shift_dashboard.dart` (whole-day) — full lever card
  surfaced via `ShiftDashboardReadModel.primaryLeverCard`. Whole-day
  scope; daypart scope is owned by `10.5`.

**Admin (11A) surfaces:** none. Primary Driver is entirely an
operator-facing concept — no admin / pricing-tier / integration
panel reads it.

**UX sub-slice family:**

- `7.58.UX.1` — dollar-impact attribution rendering (Variance This
  Week + Week Detail).
- `7.58.UX.2` — Learn / History parity for driver identity.
- `7.58.UX.5` — Full Week Projection day-row driver text honesty
  ("Not yet available" instead of inherited closed lever).

`7.58.3` and `7.58.4` ship without UX sub-slices (coverage math and
fixture seed parity, no operator-visible change).

**Demo-mode walkthrough (per UX sub-slice):**

- `7.58.UX.1`: launch ForgeFlow demo → Variance > This Week →
  PRIMARY DRIVER section now shows the dollar-impact attribution
  for the dominant lever; the per-axis breakdown stays in line with
  the existing DOLLAR IMPACT card.
- `7.58.UX.2`: Variance > History → leak / win evidence cards
  match Variance > Learn for the same lever id and metric copy
  (no drift between the two tabs).
- `7.58.UX.5`: Variance > This Week > FULL WEEK PROJECTION → Tue
  Lunch open row no longer inherits "covers down" from Mon Lunch's
  closed driver; reads "Not yet available" until Tue Lunch posts
  its own positive-hours snapshot.

Walkthroughs land with each UX sub-slice, not with this audit.

## Required Tests for `7.58.0`

- `dart analyze` — no production code change, analyzer state must
  match pre-slice baseline (no new infos / warnings / errors).

No new test files in `7.58.0`; the `.1`-`.5` sub-slices each own
their own test additions.

## Acceptance Criteria for `7.58.0`

- [ ] This plan doc exists with Frontend Exposure, sub-slice family,
  hard gates, authority order pointing at the contract.
- [ ] `docs/contracts/phase_7_58_primary_driver_contract.md` exists
  with input axes, decision logic, tie-breaks, presentation split,
  open / projected row honesty rules.
- [ ] Findings section enumerates `7.58.0a`, `7.58.0b`, `7.58.0c`, …
  follow-ups with file:line citations.
- [ ] No production code modified.
- [ ] `CLAUDE.md` Authority Order section unchanged (the contract is
  referenced from this plan, not added to `CLAUDE.md`).

## Audit Map (current code vs contract, file:line)

### Engine

- [labor_model.dart:99-202](../../../lib/services/labor_model.dart) —
  `determineLever` matches contract input axes, threshold table, and
  tie-break order. The empty-candidate fallback returns
  `'covers_down'` (line 187) — see Finding F-2.

### Producers (call `determineLever` and persist / return the id)

- [shift_fact_builder.dart:53](../../../lib/domain/services/shift_fact_builder.dart) —
  per-shift, persists into `ShiftRecord.primaryLever` (upper-snake).
  Drives the closed-shift driver everywhere downstream.
- [shift_service.dart:129](../../../lib/services/shift_service.dart) —
  WTD, returned as `WeekData.primaryLeverId`.
- [shift_service.dart:448](../../../lib/services/shift_service.dart) —
  closed-week persist, returned as `WeekRecord.primaryLeverId`.
- [shift_service.dart:805](../../../lib/services/shift_service.dart) —
  alternate WTD path, same shape as line 129.
- [shift_data_source.dart:89](../../../lib/services/shift_data_source.dart) —
  replay-seed WTD; SPLH only, no wage/hours-flex axes (see
  Finding F-3).
- [shift_dashboard_read_model.dart:222](../../../lib/models/shift_dashboard_read_model.dart) —
  whole-day Shift; SPLH + hours-flex axes only, no wage axes (see
  Finding F-3).
- [demo_fixture_data.dart:78](../../../lib/dev/demo_fixture_data.dart) —
  demo seed.
- [mock_integration_replay_seed.dart:339, :410](../../../lib/data/mock_integration_replay_seed.dart) —
  replay seed; per-shift and aggregate.

### Consumers (read the persisted id and render)

State as of 7.58.UX.5 close (2026-05-02). All renderer sites resolve
the id through `LeverCards.lookup` (returns `LeverCardData?`); null
returns drive a deliberate degraded surface, never silent
fall-through. Pre-UX.5 history of each site is preserved in the
Findings section below.

- [variance_this_week_tab.dart:90](../../../lib/screens/variance/variance_this_week_tab.dart) —
  full `LeverCardWidget` for `weekData.primaryLeverId`; null →
  `LeverCardNotYetAvailable`.
- [variance_this_week_tab.dart:938, :1194](../../../lib/screens/variance/variance_this_week_tab.dart) —
  inline `_LeverBadge`; renders `LeverCardData.metric` for known
  ids, `'PRIMARY LEVER: NOT YET ON-MODEL'` (muted) for null lookup.
- [week_history_tile.dart:28](../../../lib/widgets/week_history_tile.dart) —
  short badge rendering `LeverCardData.shortLabel`; null → `'—'`.
- [week_detail_screen.dart:138](../../../lib/screens/week_detail_screen.dart) —
  full `LeverCardWidget` for `WeekRecord.primaryLeverId`; null →
  `LeverCardNotYetAvailable`.
- [variance_history_tab.dart:225, :447](../../../lib/screens/variance/variance_history_tab.dart) —
  `_LeakEvidenceCard` rendering `LeverCardData.metric` only; null
  lookup suppresses the leak card rather than fabricating one.
- [variance_learn_tab.dart:148, :479](../../../lib/screens/variance/variance_learn_tab.dart) —
  three-card teaching shape; null lookup falls back to the existing
  "no patterns yet" placeholder. `_leverShortLabel` returns `'—'`
  for null lookup.
- [baseline_manager_helpers.dart:44, :58](../../../lib/screens/baseline_manager/baseline_manager_helpers.dart) —
  `isSuggestedStar` + `leverLabel`. (Out of `7.58.UX.5` scope; uses
  its own helper. Audit deferred.)
- [baseline_manager_day_detail.dart:242](../../../lib/screens/baseline_manager/baseline_manager_day_detail.dart) —
  candidate `LEVER` chip. (Same scope note as above.)
- [variance_week_projection_read_service.dart:138](../../../lib/services/variance_week_projection_read_service.dart) —
  `_driverLabel` returns `s.normalizedLeverId.replaceAll('_', ' ')`
  (lowercase) for closed rows; `'Not yet available'` for non-closed
  rows (`7.58.5` G.5 fold lift; `7.58.UX.5` F-7 case fix).

## Findings

Numbered as `7.58.0a`, `7.58.0b`, … Each one becomes the prompt seed
for a follow-up against the named sub-slice.

### F-1 / `7.58.0a` — Unknown lever ids degrade to `covers_down` (or `ppa_up`) silently

**Where:**
[variance_this_week_tab.dart:90-93](../../../lib/screens/variance/variance_this_week_tab.dart),
[week_history_tile.dart:28-31](../../../lib/widgets/week_history_tile.dart),
[week_detail_screen.dart:138-141](../../../lib/screens/week_detail_screen.dart),
[shift_dashboard_read_model.dart:236-239](../../../lib/models/shift_dashboard_read_model.dart),
[variance_learn_tab.dart:149-162, :479-482](../../../lib/screens/variance/variance_learn_tab.dart),
[variance_history_tab.dart:447-450](../../../lib/screens/variance/variance_history_tab.dart).

**Symptom:** every `LeverCards.all.firstWhere(...)` site uses
`orElse: () => LeverCards.coversDown` (or `ppaUp` in Learn). When a
row carries the `'on_model'` sentinel from
[current_week_state.dart:59](../../../lib/models/current_week_state.dart),
or a future-introduced id the renderer doesn't yet know about, the UI
silently shows "COVERS CAME IN LIGHT" — i.e. claims a real driver
that was not detected. This is overclaim by fallback.

**Contract reference:** Presentation Split rules — "Rendering MUST
use … so an unknown id degrades to a sensible default rather than
crashing"; row-status honesty rule — "Renderers MAY treat
[`on_model`] as 'no driver yet' but MUST NOT fall through to
`LeverCards.coversDown`."

**Owns:** `7.58.UX.5` (variance row purity touches the same renderer
sites; cleaner to fix the `orElse` once when the projection-row fix
lands).

**Status:** RESOLVED by `7.58.UX.5` (2026-05-02). Pre-fix
`firstWhere(... orElse: coversDown)` replaced at all 8 renderer sites
by `LeverCards.lookup` returning `LeverCardData?`; null returns drive
explicit degraded surfaces — `LeverCardNotYetAvailable` (deep cards),
`'—'` (short badges), `'PRIMARY LEVER: NOT YET ON-MODEL'` (inline
`_LeverBadge`). Contract Presentation Split rule revised in lockstep.
See `docs/_walkthroughs/7.58.UX.5.md`.

### F-2 / `7.58.0b` — Empty-candidate path returns `'covers_down'`

**Where:**
[labor_model.dart:187](../../../lib/services/labor_model.dart).

**Symptom:** when no axis exceeds its threshold, `determineLever`
returns `'covers_down'`. This path fires on a genuinely on-model
shift and produces a misleading driver. The
[lever_logic_test.dart](../../../test/lever_logic_test.dart) suite
relies on the current behaviour, so the fix is a coordinated
engine + test + UI change.

**Contract reference:** Decision Logic step 3 — explicitly notes the
`covers_down` fallback as legacy behaviour to be replaced with
`'on_model'` once the on-model lever card exists.

**Owns:** `7.58.0b` is engine + test; `7.58.UX.5` is the renderer
side, since today the "no signal" path silently re-uses the
`covers_down` card. The two land together.

### F-3 / `7.58.0c` — Producer call sites pass different optional-axis subsets

**Where:**
- [shift_dashboard_read_model.dart:222-235](../../../lib/models/shift_dashboard_read_model.dart) —
  passes SPLH and hours-flex; **omits** FOH/BOH wage axes.
- [shift_data_source.dart:89-98](../../../lib/services/shift_data_source.dart) —
  passes SPLH only; omits wage and hours-flex.
- [shift_service.dart:129-146](../../../lib/services/shift_service.dart),
  [shift_service.dart:448-465](../../../lib/services/shift_service.dart),
  [shift_service.dart:805-822](../../../lib/services/shift_service.dart),
  [shift_fact_builder.dart:53-70](../../../lib/domain/services/shift_fact_builder.dart) —
  pass all axes.

**Symptom:** Two surfaces looking at the same shift can return
different drivers because they consider different axis subsets. The
WTD vs whole-day divergence is documented as legitimate
(`phase_7_55m_4`); the WTD-replay vs WTD-live divergence is **not**
— `shift_data_source` and `shift_service` should agree.

**Contract reference:** Single Source of Truth — "the only function
allowed to compute a primary driver id." Axis subsets aren't part of
the function signature, so divergence is a producer-side bug, not an
engine bug.

**Owns:** `7.58.4` (fixture realism — the `shift_data_source`
omission is most visible in demo mode where the replay seed becomes
the user's reality).

### F-4 / `7.58.0d` — Whole-day Shift driver and WTD Variance driver can disagree by design

**Where:**
[shift_dashboard_read_model.dart:217-221](../../../lib/models/shift_dashboard_read_model.dart)
inline comment: "This can legitimately differ from the Variance WTD
lever (different aggregation window). See phase_7_55m_4 audit doc."

**Symptom:** not a bug — the comment notes the divergence is
intentional. But the contract did not previously say so; an
operator hopping between Shift and Variance would see two different
drivers for "today" and assume one is wrong.

**Contract reference:** Row-Status Honesty Rules — "Surfaces MUST
NOT cross-render one scope's driver in another scope's row." The
contract now formalises this.

**Owns:** `7.58.UX.2` — Learn copy can clarify the scope split when
both surfaces show different drivers.

### F-5 / `7.58.0e` — Daypart carry-forward inheritance (the G.5 fold)

**Where:**
[variance_week_projection_read_service.dart:60-78, :147-156](../../../lib/services/variance_week_projection_read_service.dart).

**Symptom:** the `_buildDaypartRow` path builds a
`lastClosedLever[daypart]` map from each day's closed shifts and
hands the most recent same-daypart closed lever to subsequent open /
projected rows in the **same week**. So if Mon Lunch closes
`covers_down`, Tue Lunch's open row renders "covers down" as its
own driver — before any Tuesday hours have been worked. This
violates Layer 10 ("projected and open rows must not overclaim final
truth") and HP #6 (driver is a recommendation, but here it's
fabricated for a row that has no real signal yet).

**Contract reference:** Row-Status Honesty Rules — open / projected
rows MUST NOT inherit a previous closed row's driver.

**Owns:** `7.58.5` is the dedicated fix slice for this fold (named
"variance row purity" in the sub-slice family table). `7.58.UX.5`
ships the renderer-visible change.

### F-6 / `7.58.0f` — `'on_model'` constructor placeholder is unowned

**Where:**
[current_week_state.dart:59](../../../lib/models/current_week_state.dart),
[shift_record.dart:22](../../../lib/models/shift_record.dart) (comment
notes `'ON_MODEL'` is a valid `primaryLever` value).

**Symptom:** open snapshots are constructed with
`primaryLever: 'ON_MODEL'`, but no consumer is wired to render the
"on-model" case as anything other than the silent
`coversDown` fallback (Finding F-1). There is no
`LeverCards.onModel` entry, and `determineLever` never returns
`'on_model'`.

**Contract reference:** Output Cardinality — `on_model` is reserved
as a sentinel for non-closed rows constructed pre-signal; it is not
returned by `determineLever`. The renderer obligation is in
Presentation Split.

**Owns:** `7.58.0b` (engine side, when the empty-candidate fallback
flips to `on_model`) + `7.58.UX.5` (renderer side, when "Not yet
available" / "On-model" gets a deliberate visual treatment).

**Status:** Renderer side RESOLVED by `7.58.UX.5` (2026-05-02). The
`'ON_MODEL'` sentinel now resolves to `null` via `LeverCards.lookup`
and renders the "Not yet on-model" treatment. Sentinel ownership
documented in `current_week_state.dart` and `shift_record.dart`
docstrings, both pointing at the contract's Output Cardinality
clause. Engine-side flip (when `7.58.0b` lands) remains queued.

### F-7 / `7.58.0g` — Persistence form / lookup form mismatch

**Where:**
[shift_record.dart:22, :316](../../../lib/models/shift_record.dart),
[variance_week_projection_read_service.dart:77, :150](../../../lib/services/variance_week_projection_read_service.dart).

**Symptom:** `ShiftRecord.primaryLever` is upper-snake
(`'COVERS_DOWN'`); every renderer except `_LeverBadge` /
`_driverLabel` lowercases via `normalizedLeverId` before
`firstWhere`. Two surfaces (the inline `_LeverBadge` at
`variance_this_week_tab.dart:1194` and the projection
`_driverLabel`) use `s.primaryLever.replaceAll('_', ' ')`, which
yields "COVERS DOWN" — uppercased text — while every other surface
shows title-cased or sentence-cased copy from `LeverCardData.metric`.
Visual inconsistency, not a correctness bug.

**Contract reference:** Output Cardinality — id is lowercase
snake_case; storage uppercase; renderers must normalise. The
inline-badge surfaces should call `LeverCardData.shortLabel` (or
`metric`) for consistency.

**Owns:** `7.58.UX.5` — fix the renderer when row purity work
already touches the projection display.

**Status:** RESOLVED by `7.58.UX.5` (2026-05-02). Closed-row
projection `_driverLabel` now uses `s.normalizedLeverId` (lowercase,
matches engine output). Inline `_LeverBadge` switched to
`LeverCardData.metric` per the contract's recommendation. Closed-row
contract test (R1 + R18 + R32) round-trips the lowercase form back
to engine ids.

## Notes for `7.58.1`-`7.58.5` Authors

- The contract is final at `7.58.0` close; `.1`-`.5` slices implement
  to it and only revise the contract via an explicit revision PR.
- Each slice's prompt should cite this Findings list by ID
  (`F-1` / `7.58.0a` etc.) so traceability stays clean.
- Tests added in `.1`-`.5` should pin the exact contract behaviour
  (e.g. `7.58.5` test: "Tue Lunch open row driver is 'Not yet
  available' when Mon Lunch closed `covers_down`").
- The `lever_logic_test.dart` and `shift_driver_trust_audit_test.dart`
  suites already pin the engine math; they may need adjustment when
  Finding F-2 lands (engine returns `'on_model'` instead of
  `'covers_down'`).
