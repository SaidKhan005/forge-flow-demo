# Phase 7.55o - Refactor Non-Behavior-Change Contract

Updated: 2026-04-24
Status: Active `7.55o` execution guardrail
Owner: `7.55o` extraction lane

## Why This Exists

`7.55o` is an engineering-hygiene and extraction lane.

That means the success condition is:

```text
smaller files
clearer ownership
better composability
same runtime behavior
```

If a slice changes formulas, authority, fallback behavior, timing semantics,
or teaching logic, that is no longer a pure `7.55o` refactor. It becomes a
separate behavior slice and must be called out explicitly.

## Core Rule

```text
Move structure, not meaning.
```

Refactor work may change:

- file boundaries
- widget composition
- where local helper classes live
- where screen-local view models / notifiers live
- how duplicated presentation primitives are shared

Refactor work must not silently change:

- formulas
- source ownership
- fallback semantics
- visibility / degradation rules
- default screen behavior
- historical provenance

## Allowed Changes

These are in-bounds for `7.55o` by default:

- extracting private widgets into dedicated files
- extracting duplicated presentational primitives into shared widgets
- moving screen-local read-only helpers into better files
- moving a screen-local notifier / view model into a non-screen file while
  keeping the same public contract
- renaming private widget/helper classes when the runtime behavior is
  unchanged
- adding or tightening tests to prove behavior stability
- updating docs / comments / trackers to reflect the new structure

## Out Of Bounds Unless Explicitly Re-Scoped

These are **not** part of a normal `7.55o` extraction slice:

- changing benchmark, plan, shift, variance, history, or learn formulas
- changing which object owns a metric
- changing business-date / week-boundary / service-period semantics
- changing live-vs-closed-vs-projected row rules
- changing manager override authority behavior
- changing wage-authority behavior
- changing fallback / honest-degradation behavior
- changing seeded data meaning
- changing SQL schema / migrations unless the slice explicitly owns a
  persistence breakup and the schema behavior is preserved
- broad product-copy changes unless the slice explicitly owns copy cleanup

If a refactor reveals a real behavior bug, the right move is:

1. stop and name it
2. spin it into a separate scoped follow-up
3. do not smuggle it through as "just extraction"

## Behavior-Freeze List

These runtime contracts are frozen during ordinary `7.55o` work:

- one locked current-week weekly-plan authority
- one shared benchmark target seam
- whole-day Shift target alignment through `7.55q.7`
- non-closed Variance reading benchmark + locked plan 1:1
- closed Full Week rows staying locked historical truth
- History preserving locked target truth
- planned labor package remaining dead
- current time-boundary rules from `phase_7_55_time_boundary_contract.md`

## UI / UX Stability Rules

Ordinary extraction should not change:

- default tab selection
- default expansion / collapse behavior
- button meaning
- empty-state rules
- label wording
- ordering of visible sections

Exception:

- if a `7.55o` slice is explicitly approved as a UX cleanup slice, the prompt
  should say so
- otherwise assume the visible product behavior stays the same

## Local-State Stability Rules

When moving code out of a screen file:

- preserve initialization order
- preserve provider / notifier wiring
- preserve selected / expanded / tab / draft state defaults
- preserve async load timing and honest loading / unavailable states

This matters especially for:

- `variance_report.dart`
- `schedule_builder.dart`
- `settings_screen.dart`
- `baseline_manager_screen.dart`

## Proof Required For Every Refactor Slice

Every `7.55o` slice must leave behind:

1. targeted tests for the touched surface
2. no failing alignment / authority guardrails caused by the extraction
3. a short note in the final handoff that the slice was structural only

Use the companion verification doc:

- `phase_7_55o_verification_matrix.md`

## Adjacent-Phase Boundaries

Do not pull these concerns into `7.55o`:

- service-period runtime closeout -> `7.55r`
- editable timing settings -> `10a`
- live Shift daypart/time-into-service behavior -> `10.5`
- broader bridge cleanup not explicitly attached to the active extraction
  slice -> separate scoped follow-up

## One-Sentence Rule

```text
`7.55o` may reorganize how the code is packaged, but it may not change what
the product means or how the runtime truth behaves unless the slice is
explicitly re-scoped as behavior work.
```
