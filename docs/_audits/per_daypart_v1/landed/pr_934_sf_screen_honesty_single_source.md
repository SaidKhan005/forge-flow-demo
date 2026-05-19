# Audit — PR #934 (SF: route screen Benchmark honesty through the single verdict-driven source)

Branch `claude/per-daypart-v1-sf-screen-honesty-single-source` → `master`.
Verdict: **APPROVE pending operator merge sign-off** (logic/UX; consolidation, device-relevant).

## Root cause (device screenshot caught it; orchestrator SC scoping miss)
The screen renders `view.rangeGraphModel` from `BenchmarkTrackerReadService` canonical path, whose `_buildGraph` called a STALE private `_resolveHonesty` that ignored the verdict and emitted OLD copy ("Team looks busy without getting stretched…", "Let more shifts close…", "Star shifts are bunched…") and OLD states (`OPZ RANGE TOO NARROW/WIDE`, `RANGE UNCERTAIN`, `RANGE UNCONFIRMED`). SC had only updated the OTHER builder (`baseline_authority_service._resolveGraphHonesty` / bridge `BaselineData.rangeGraphModel`). My SC scope named `_resolveGraphHonesty` but not `BenchmarkTrackerReadService._buildGraph`, and my verification drove the bridge seam not the screen seam — so the miss was masked (badge label `GOOD OPZ RANGE` exists in both old and new).

## Change
- `baseline_authority_service.dart`: **additive** public forwarder `BaselineData.resolveGraphHonesty()` over the UNCHANGED private `_resolveGraphHonesty` (verified: diff is an added method only; zero logic/string change to the approved mapping).
- `benchmark_tracker_read_service.dart`: `_buildGraph` now consumes `BaselineData.resolveGraphHonesty()`; stale `_resolveHonesty` + `_GraphHonesty` + all old literals + dead `summary` plumbing DELETED. Geometry (hist min/max, active range, target, positions, override min/max/avg vs cycle floor/ceiling/target) unchanged.
- New `test/per_daypart_v1_sf_screen_honesty_test.dart`: asserts the real screen seam `BenchmarkTrackerReadService.load().rangeGraphModel` returns verbatim §9 copy + no em-dash + bit-identical to `BaselineData.rangeGraphModel` (single-source parity) for every verdict + override.

## Independent verification
- Scope: 3 files; additive forwarder confirmed; stale resolver + old strings confirmed deleted (grep: 0 remaining).
- master+SF scratch: no conflicts.
- **Three-way verbatim comparison (A mockup HTML ↔ B code ↔ C real screen seam):** all 6 states (teachable / building_early / building_flat / building_few_strong / running_hot / manager-override) **byte-identical**; per-period rollup present; zero em-dashes. C captured via `BaselineData.resolveGraphHonesty()` (the single source `_buildGraph` now calls); SF test independently proved `BenchmarkTrackerReadService.load().rangeGraphModel == BaselineData.rangeGraphModel` verbatim per state.
- Regression: prompt-named suites 122/122; new screen-seam test green; no old→new deltas (no test pinned the deleted stale strings).

## Net
Single source of truth for Benchmark honesty/copy/state across BOTH the bridge and the canonical screen path. The old "Team looks busy…" / "Let more shifts close…" copy is removed from the screen path. Numbers were already device-verified; this fixes the copy on the real screen. Post-merge: user re-screenshots on device for final confirmation.
