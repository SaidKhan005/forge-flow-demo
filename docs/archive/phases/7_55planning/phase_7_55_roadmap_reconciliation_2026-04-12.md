# Phase 7.55 Roadmap Reconciliation - 2026-04-12

Status: planning proposal
Owner: Codex synthesis pass
Authority: proposal only until tracker update

## Why This Exists

The current tracker and the merged planning note are close, but they are not
saying the same thing anymore.

Current tracker flow:

- `7.55n`
- `7.55o`
- `7.55j.3`
- `7.55j.4`

Current merged-note reality:

- `7.55n` is still correct next
- but there is a real post-`7.55n` product/alignment lane missing before
  engineering hygiene
- `7.55o` is correctly after `7.55n`, but it should not absorb truth fixes that
  belong to runtime/product alignment

This note turns that mismatch into a concrete proposed roadmap.

## How We Got Here

We did not get here because the tracker was wrong in spirit. We got here
because it was trimmed to keep the active queue small, and that trim compressed
too many different kinds of work into:

- timing/runtime foundation
- engineering hygiene
- later integration packaging

The deeper code pass shows those are not enough buckets.

Three things made the gap visible:

1. the merged planning note surfaced real post-`7.55n` product/alignment work
2. code review showed some of that work is broader than the note first implied
3. `7.55o` extraction targets are not all "structure only"; at least one still
   carries truth debt

So the fix is not to throw away the tracker. It is to insert one concrete lane
between `7.55n` and `7.55o`, then attach the remaining edge cases to the right
owner.

## What The Codebase Says Right Now

### 1. `7.55n` is still the correct next implementation lane

This remains the right owner for:

- restaurant timing config
- business-date resolution
- service-period definitions
- week-start wiring
- service-period close vs shift finalization
- timestamp normalization

No change there.

### 2. `7.55o` should not be the next thing after `7.55n`

The tracker currently jumps from `7.55n` to `7.55o`, but the merged note and
code review show a missing middle lane:

- driver trust is not fully settled
- WTD / Full Week alignment is not fully settled
- Dollar Impact is not defined tightly enough
- refresh / notifications / replay integrity still need app-truth review
- OPZ surface honesty still needs its own pass

Those are not extraction tasks.

### 3. Learn is not fully migrated to one closed-evidence seam yet

Current code truth:

- Repeatable Wins is on the new evidence-backed path
- Benchmark Set / Recurring Leak / Coach Next Week still rely on
  `HistoryPatternRecord` compatibility paths plus benchmark context

That does not block `7.55n`, but it means we should not describe Learn as
fully closed-evidence-native yet.

### 4. The fixed `14 shifts` assumption is broader than a single runtime seam

This debt currently appears in:

- week finalization logic
- replay seed assumptions
- tests
- UI copy
- integration docs

So when `7.55n` lands restaurant-owned service periods, we will need a broader
cleanup than "change one runtime condition."

### 5. Baseline Manager still has one real truth debt

`7.55o` is still the right structural owner for Baseline Manager file bloat,
but the current preview path still uses direct `MeridianConfig` wages instead
of the wage-authority seam.

That means:

- Baseline Manager is not extraction-only
- its first future touch must include that truth fix

## Recommended Phase Sequence

This is the proposed coding order after reconciling the merged note against the
live tracker.

## 1. Finish `7.55n.*`

Keep the current lane exactly where it is, in order:

- `7.55n.1` restaurant timing config persistence seam
- `7.55n.2` BusinessDateResolver
- `7.55n.3` ServicePeriodDefinitionResolver
- `7.55n.4` week-start wiring
- `7.55n.5` service-period close vs shift finalization
- `7.55n.6` metadata timestamp normalization

This is still the next coding lane.

## 2. Insert a new `7.55p.*` lane before `7.55o`

This lane should own the product/alignment work that is too real to be treated
as polish, but is not timing foundation and not engineering hygiene.

### `7.55p.1` - Shift driver trust audit

Scope:

- Shift driver scenario matrix
- driver-card highlight behavior
- positive vs negative emphasis parity
- Chapter 10 coverage check

Why first:

- the user wants Shift logic understood first
- Variance driver discussion depends on this

### `7.55p.2` - Variance WTD / Full Week alignment

Scope:

- literal locked-plan meaning in WTD
- Full Week target ownership:
  - covers / sales / hours from Plan
  - standards / rates from Benchmark
- FOH / BOH / blended wage alignment on Variance surfaces
- interim primary-lever carry-forward rule in Full Week

Why second:

- this is the clearest live product-truth mismatch still visible today

### `7.55p.3` - Dollar Impact accumulation model

Scope:

- closed-truth only accumulation contract
- Day / Week / Month / 60 Days / Annualized definitions
- projected labeling for annualized
- Variance-first swipeable card behavior

Why third:

- the user has already made the key product decisions
- the logic should be nailed down before surface redesign

### `7.55p.4` - Refresh, replay integrity, and notifications

Scope:

- refresh trust
- stale-data confidence
- mock replay day advance vs locked-week integrity
- post-close correction carry-through
- notification event ownership and storage model

Special note:

- this lane should also absorb the non-runtime touchpoints of the fixed
  `14 shifts` migration once `7.55n.5` defines the real close rule

### `7.55p.5` - Benchmark OPZ and graph honesty audit

Scope:

- OPZ range width/readability
- historical range vs selected benchmark range explanation
- whether the current graph visually overstates acceptable range

## 3. Run `7.55o.*` after `7.55p.*`

Once timing/runtime truth and product alignment are in better shape, keep
`7.55o` as engineering hygiene:

- `7.55o.1` shared surface primitives
- `7.55o.2` Variance shell split
- `7.55o.3` Schedule planning surface separation
- `7.55o.4` Settings surface split
- `7.55o.5` Baseline Manager decomposition
- `7.55o.6` SQLite bootstrap breakup only if still justified

Attached rule:

- the first Baseline Manager touch must also fix its wage-authority alignment
  rather than treating it as extraction-only

## 4. Resume `7.55j.3` and `7.55j.4`

Only after:

- timing/runtime foundation is real
- post-`7.55n` product alignment debt is resolved enough
- extraction/hygiene no longer threatens merge velocity

Then resume:

- `7.55j.3` vendor endpoint checklist template
- `7.55j.4` final gap report

## Recommended Tracker Changes

If we update the trackers, this is the concrete change I recommend.

### `PROJECT_TRACKER.md`

Replace:

- `7.55n`
- `7.55o`
- `7.55j.3`
- `7.55j.4`

With:

- current:
  - `7.55n.1`
- next lane:
  - `7.55n.2` through `7.55n.6`
- then:
  - `7.55p.1` Shift driver trust audit
  - `7.55p.2` Variance WTD / Full Week alignment
  - `7.55p.3` Dollar Impact accumulation model
  - `7.55p.4` Refresh, replay integrity, and notifications
  - `7.55p.5` Benchmark OPZ and graph honesty audit
- then:
  - `7.55o.1` through `7.55o.6`
- then:
  - `7.55j.3`
  - `7.55j.4`

Also update the planning-doc list to include:

- `docs/phases/phase_7_55_planning_merge_2026-04-12.md`
- `docs/phases/phase_7_55_roadmap_reconciliation_2026-04-12.md`
- `docs/archive/phases/7_55o/phase_7_55o_deep_extraction_followup.md`

### `docs/DATA_ALIGNMENT_TRACKER.md`

Mirror the same sequence change:

- `7.55n` remains current foundation owner
- `7.55p` becomes the next alignment/product lane
- `7.55o` remains engineering hygiene after `7.55p`

Also add two explicit notes:

- Learn is partially migrated:
  - Repeatable Wins is evidence-backed
  - the rest of Learn still has compatibility seams
- fixed `14 shifts` debt spans runtime + replay + tests + docs, not just one
  condition in `ShiftService`

## What We Should Do Next

If the goal is to get back into coding cleanly, the next move is still:

- code `7.55n.1`

But before or immediately after that coding pass, the tracker should be updated
to reflect the real sequence above so we do not accidentally jump from
foundation work straight into extraction.

## Bottom Line

The corrected sequence is:

1. `7.55n.*`
2. `7.55p.*`
3. `7.55o.*`
4. `7.55j.3` / `7.55j.4`

That is the simplest roadmap that matches:

- the architecture contracts
- the merged planning note
- the live codebase
- the user's stated priorities

And it gives us a clean answer for "what do we code next?"

- right now: `7.55n.1`
- after `7.55n`: not extraction yet; do the `7.55p` alignment lane first
