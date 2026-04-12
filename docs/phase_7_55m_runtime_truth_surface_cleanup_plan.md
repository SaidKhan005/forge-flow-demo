# Phase 7.55m - Runtime Truth + Surface Cleanup

Updated: 2026-04-12
Owner: Codex planning / tracker truth
Status: Planned, not implemented

## Purpose

Phase `7.55m` is the stabilization lane between the completed `7.55l`
cycle/week architecture work and the deeper downstream semantics work in
`7.55k`.

This lane exists to fix current-product truth mismatches and misleading UI
surfaces without leaking future `7.55k` or `10.5` behavior forward.

## Why This Phase Exists

The current app has a few concerns mixed together:

- runtime authority seams that are not explicit enough yet
- mock replay drift questions that need a written contract
- Shift and Variance driver behavior that needs parity review
- a fake/static Shift time surface that should not pretend to be live
- OPZ range questions that need truth-vs-presentation verification
- Plan / Benchmark / Settings cleanup that should happen after the truth seams
  are clarified

These are real current-product issues, but they are not all the same kind of
issue:

- some are correctness / architecture cleanup now
- some are downstream semantics owned by `7.55k`
- some are future live daypart Shift behavior owned by `10.5`

## Scope Split

### `7.55m` owns

- shared date / business-date authority
- mock replay drift boundaries
- truthful Shift clock / time behavior
- driver parity checks across Shift and Variance
- Benchmark OPZ truth audit
- current-product Plan / Benchmark / Settings cleanup

### `7.55k` still owns

- Full Week row-scope semantics
- History / Learn daypart evidence honesty
- longer-term `restaurantId + businessDate + daypart` hardening
- downstream daypart coaching semantics

### `10.5` still owns

- live daypart-aware Shift
- real time-into-service as a service-period feature
- live daypart primary-driver teaching

## Current Concerns To Cover

### Logic

- Shift driver indicator feels stale and does not appear to change cleanly
- Shift top clock is static instead of live
- Variance top date/day counter needs explicit authority
- Variance primary-driver behavior needs a deeper parity check
- Full Week projection needs clearer rules for open/projected/closed daypart
  updating as the week closes
- History rollover should be explicit: what moves from WTD into History and
  when
- Benchmark OPZ range needs verification for narrow / good / wide behavior
- advancing mock replay day appears to affect next-week forecast and downstream
  planning surfaces in ways that need a formal allowed-vs-locked contract

### Visuals

- remove fake "time into service" from current Shift
- add section labels to Plan before the top cards, graph, and table
- regroup Benchmark target output into clearer sections
- shorten OPZ range helper wording so it is easier to scan
- organize Settings / replay controls more clearly

## Guardrails

- do not fake live daypart/service-period behavior early
- do not turn `7.55m` into `7.55k`
- do not turn `7.55m` into `10.5`
- no new manager workflow
- prefer truthful labels and cleanup over speculative new features

## Proposed Slice Breakdown

### `7.55m.0` - Planning / handoff

- capture this lane in trackers and docs
- classify each concern into `7.55m`, `7.55k`, or `10.5`

### `7.55m.1` - Date / business-date authority seam

- define shared authority for:
  - planning anchor date
  - current business date
  - current week id
  - canonical day ordering
- reduce duplicated date-resolution seams where appropriate

### `7.55m.2` - Mock replay drift contract

- define what mock replay advance may change
- define what must stay locked
- capture current-week vs next-week vs History expectations

### `7.55m.3` - Shift time truthfulness cleanup

- remove fake time-into-service
- add or prepare real top-of-screen clock/date behavior without implying
  daypart-live Shift

### `7.55m.4` - Driver parity audit / cleanup

- compare Shift and Variance primary-driver behavior
- separate stale refresh behavior from legitimate scope differences

### `7.55m.5` - Benchmark OPZ truth audit / cleanup

- verify narrow / good / wide range truth
- separate data truth issues from presentation issues

### `7.55m.6` - Plan / Benchmark / Settings surface cleanup

- add Plan section labels
- regroup Benchmark targets
- tighten OPZ helper copy
- improve Settings / replay control organization

### `7.55m.7` - Closeout / handoff

- summarize what `7.55m` fixed
- move remaining semantic work into `7.55k`
- leave live daypart Shift behavior in `10.5`

## Execution Order

Recommended order:

1. `7.55m.0`
2. `7.55m.1`
3. `7.55m.2`
4. `7.55m.3`
5. `7.55m.4`
6. `7.55m.5`
7. `7.55m.6`
8. `7.55m.7`
9. `7.55k`
10. resume `7.55j.3`
11. `7.55j.4`

## Success Criteria

`7.55m` is complete when:

- date / business-date authority is explicit enough for current runtime use
- mock replay drift expectations are documented and tested where needed
- Shift no longer shows fake time behavior
- driver and OPZ questions have clear truth answers
- current Plan / Benchmark / Settings cleanup is landed
- remaining downstream daypart semantics are cleanly handed to `7.55k`
