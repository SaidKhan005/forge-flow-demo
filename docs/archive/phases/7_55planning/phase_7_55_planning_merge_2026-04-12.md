# Phase 7.55 Planning Merge - 2026-04-12

Status: temporary synthesis note
Owner: Codex planning merge
Authority: not tracker authority; use for roadmap consolidation only

## Inputs merged

- `docs/phases/temporary_alignment_findings_2026-04-12.md`
- `docs/phases/7_55o/phase_7_55o_file_extraction_analysis.md`
- `docs/phases/7_55o/phase_7_55o_deep_extraction_followup.md`

## Purpose

This note merges the current alignment findings and the deeper `7.55o`
extraction thinking into one working planning source before the next tracker
update. It is meant to reduce drift between:

- architecture truth
- follow-up audit work
- engineering hygiene work
- later integration packaging work

Keep the source notes for reference. Use this merged note for the next roadmap
discussion.

## Architecture truths to preserve

These are the rules the next phase planning should treat as fixed unless the
contracts are intentionally changed.

### 1. Benchmark, Demand, and Plan do different jobs

- Benchmark / target-cycle context owns standards:
  - target labor %
  - CPLH
  - SPLH
  - PPA
  - FOH wage
  - BOH wage
- Demand forecast context owns rolling demand inputs.
- Plan combines locked standards plus rolling demand and owns:
  - covers
  - sales
  - FOH hours
  - BOH hours

This means Plan is not a second standards system. It is the operational
distribution layer built from Benchmark standards plus demand.

### 2. Downstream surfaces each have their own truth type

- Shift:
  - truth = live facts
  - compared against benchmark-backed standards and current plan context
- Variance:
  - truth = closed facts for WTD, plus open/projected context for Full Week
  - compared against locked weekly plan and benchmark-backed standards in the
    proper roles
- History:
  - truth = closed facts only
  - interpreted in the locked week/cycle context active when those facts closed
- Learn:
  - truth = mixed today:
    - Repeatable Wins is evidence-backed closed-shift truth
    - Benchmark Set / Recurring Leak / Coach Next Week still use the
      compatibility path from `HistoryPatternRecord` plus benchmark context
  - interpreted against benchmark context

### 3. Visible cross-surface contradictions should be treated as defects

We should not explain away visible Benchmark vs Plan contradictions when the
surface is presenting the same concept unclearly.

The clean rule is:

- standards should align across surfaces
- plan outputs can vary by day/daypart because demand distribution varies

### 4. Blended wage is operational input, not fake display math

- source authority:
  - integration first
  - restaurant settings fallback
- display location:
  - Benchmark surface
- downstream behavior:
  - inherited from the resolved target/benchmark package

## What is already landed enough

These do not need to be reopened as if they are still first-pass unknowns.

- `7.55k.4` / `7.55k.4a`
  - Full Week provenance honesty
  - closed/open/projected distinction
- `7.55k.5` / `7.55k.5a`
  - History benchmark evidence rows
- `7.55k.6` / `7.55k.6a`
  - Learn repeatable wins evidence and teaching-scope honesty
- `7.55k.7` / `7.55k.7a`
  - early-signal vs strong evidence rules
- `7.55k.8` / `7.55k.8a`
  - integration implications and doc truth cleanup
- Shift live wall clock
- active removal of `time into service` from current Shift UI

## What is already planned with the right owner

### `7.55n` still owns timing/runtime foundation work

Keep `7.55n` as the next real implementation lane for:

- restaurant timing config persistence seam
- business date resolver
- service-period definition resolver
- week-start wiring
- service-period close vs shift finalization
- timestamp normalization follow-up

This lane is the right owner for the still-open time-boundary truths beneath
Variance, History, and later notifications.

### `7.55o` should stay engineering hygiene only

Do not mix truth changes into `7.55o`.

Its job is:

- shared widget primitive extraction
- screen shell decomposition
- screen-vs-notifier/view-model separation
- reducing merge friction on high-churn surfaces

## What is real but still needs a clearer owner after `7.55n`

These are not tracker-ready implementation slices yet, but they are real work.

### 1. Driver trust and scenario coverage

- Shift driver can still feel stale or under-explained
- Variance driver scope differs from Shift in a way users can misread
- positive-driver emphasis should be as strong as negative-driver emphasis
- Chapter 10 should be the primary scenario reference
- if Chapter 10 does not cover a case, pause and ask the user before defining
  that case

### 2. WTD / Full Week alignment cleanup

- WTD `vs LOCKED PLAN` semantics need to match literal locked-plan meaning
- Full Week target columns need to align with architecture:
  - covers / sales / hours from Plan
  - standards / rates from Benchmark
- current mismatches in FOH/BOH, target columns, and plan alignment should be
  treated as defects
- interim Full Week lever rule should be:
  - carry forward the lever from the last closed version of that daypart
  - otherwise show no lever yet

### 3. Dollar Impact redesign

This is not a copy tweak. It is a real product-logic feature.

Locked decisions:

- closed truth only
- Variance first only
- swipe order:
  - Day
  - Week
  - Month
  - 60 Days
  - Annualized
- Day means the most recently closed business day
- Month means rolling closed window, not calendar month
- Annualized is derived from rolling 60-day closed truth
- Annualized must be labeled projected

### 4. Notification and refresh trust

Notifications are not runtime-complete yet.

Locked direction:

- inbox-style notifications
- brief pop-up, then stored in notifications
- must-have notification events:
  - 60-day reset
  - new week lock
  - post-close corrections
- rollout priority:
  1. 60-day reset
  2. new week lock
  3. post-close corrections

Related freshness concerns still need follow-up:

- app refresh strategy
- stale data confidence on phone surfaces
- correction carry-through after close

### 5. Week-close finalization after variable service periods land

Current runtime still hides a fixed-count assumption, and the debt is broader
than one runtime seam.

Locked direction:

- History week closes when everything the restaurant considers part of that
  week is closed
- not when a fixed `14 shifts` close
- contract intent already covers this
- runtime still needs to implement it
- migration scope will also touch:
  - week finalization logic
  - UI copy and partial-week explanations
  - mock replay seeding assumptions
  - tests that encode `14 shifts`
  - active integration docs that still describe the fixed-count model

## Proposed sequencing after `7.55n`

This is the current best-fit order from the merged notes and user decisions.
It is still planning context, not tracker authority.

### Suggested `7.55p` family

#### `7.55p.1` - Shift then Variance driver audit

Focus:

- Shift driver freshness and scenario matrix
- driver/card highlight behavior
- positive vs negative emphasis
- Variance driver relationship traced after Shift is understood

#### `7.55p.2` - WTD and Full Week alignment fixes

Focus:

- locked-plan semantics in WTD
- target-column ownership by Plan vs Benchmark
- Full Week plan alignment
- FOH/BOH and standard-display alignment

#### `7.55p.3` - Dollar Impact accumulation model

Focus:

- closed-truth accumulation contract
- Day/Week/Month/60-day/Annualized definitions
- projected labeling rules
- swipeable/paged card behavior

#### `7.55p.4` - Refresh, notification, and replay-integrity audit

Focus:

- refresh trust
- notification event plumbing/design notes
- mock replay day advance vs locked-week integrity
- correction-after-close carry-through

#### `7.55p.5` - Benchmark OPZ and graph honesty audit

Focus:

- OPZ range width/readability
- graph explanation of outer historical range vs selected benchmark range
- whether the current benchmark visual reads too permissively

After that:

- `7.55o.*` engineering hygiene / extraction
- then resume `7.55j.3` / `7.55j.4`

## Merged `7.55o` scope

The original `7.55o` note was right about direction but too narrow. The deeper
follow-up is the better sequencing basis.

### Priority targets

#### First-tier

- `lib/screens/variance_report.dart`
- shared comparison-surface primitives used by Variance and Week Detail

#### Second-tier

- `lib/screens/schedule_builder.dart`
- `lib/screens/settings_screen.dart`
- `lib/screens/baseline_manager_screen.dart`

#### Third-tier / only if still justified

- `lib/infrastructure/persistence/sqlite/sqlite_database.dart`

### Recommended `7.55o` order

#### `7.55o.1` - Shared surface primitives extraction

Extract shared pieces first:

- section labels
- comparison headers
- group bands
- comparison metric rows
- dollar impact card

This should reduce duplication across:

- Variance
- Week Detail
- Benchmark (partial)

#### `7.55o.2` - Variance shell split

Keep `variance_report.dart` as shell + tab dispatch, then move:

- This Week tab sections
- History tab sections
- Learn tab sections

Do not push truth logic back into the widgets during extraction.

#### `7.55o.3` - Schedule planning surface separation

After `7.55n`:

- move notifier out of the screen file
- move day/daypart view models out
- leave timing/service-period rewiring to `7.55n`

#### `7.55o.4` - Settings surface split

Split by responsibility while keeping one screen shell:

- status
- mock replay
- data management
- wage authority
- audit/admin surfaces

#### `7.55o.5` - Baseline Manager decomposition

Split shell vs calendar vs detail vs preview surfaces.

Important note:

- Baseline Manager is not only a decomposition target
- its preview path still uses `MeridianConfig` wages directly instead of the
  wage-authority seam
- that architecture-alignment fix should not be buried behind extraction-only
  framing

#### `7.55o.6` - SQLite bootstrap breakup only if still worth it

If churn justifies it later:

- migrations directory
- grouped schema files
- seeders directory

### Explicit `7.55o` guardrails

- do not start `7.55o` before `7.55n` lands
- do not mix timing/service-period behavior changes into extraction slices
- do not use `7.55o` as accidental bridge-retirement work
- do not make naming/copy cleanup part of engineering hygiene by default
- do not treat `legacy_fixture_data.dart` as a normal file-bloat target without
  a separate bridge-ownership decision

## Deferred but acknowledged

These are real concerns, but they should not drive the next implementation lane
unless the user explicitly reprioritizes them.

- naming consistency across screens
- shedding unnecessary language/helper text
- sticky section titles
- general card/surface polish
- settings visual refinement beyond structural cleanup

The user wants to handle naming/copy direction personally later, so keep this
document focused on truth, sequencing, and engineering ownership.

## Questions this merge answers for the next roadmap pass

1. what is already solved enough not to reopen
2. what already has the right owner
3. what needs a new post-`7.55n` owner
4. what belongs in engineering hygiene only
5. what belongs in later copy/polish instead of core architecture work

## Recommended use

Use this note as the working merge source when comparing:

- the current trackers
- the next user brain dump
- `7.55n` foundation planning
- `7.55o` engineering-hygiene sequencing
- later `7.55j.3` / `7.55j.4` integration packaging work

Do not treat this file as final truth by itself. When tracker updates happen,
they should pull from this merged note rather than from the three source docs
independently.
