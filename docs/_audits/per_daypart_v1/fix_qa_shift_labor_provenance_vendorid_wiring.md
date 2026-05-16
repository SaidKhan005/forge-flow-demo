# PR self-audit — per-location vendor honest-degrade across Shift + Variance + pre-service messaging (3 linked defects)

Branch: `claude/fix-qa-shift-labor-provenance-vendorid-wiring`
Base: `master` (branched off `origin/master` @ `ef71f547`; current `origin/master` @ `19eed29d` — both include #827/#828/#829).
Authority: this prompt → `INVESTIGATION_labor_reservation_not_connected.md` → CLAUDE.md Demo Mode/HP#2/HP#4 + Metric Honesty → `DEMO_DATASET_FULL_SPEC.md` vendor matrix.

## Operator decision applied

**Per-location realism (decision (ii))**, driven by the existing fixture
`lib/dev/demo_vendor_integration_state_fixture.dart:145-234` — Downtown POS+Labor,
North Loop POS-only, Riverside all-live, Harbour none. ONE signal
(`ShiftVendorSourceResolver` over that fixture, the same source
`DemoModeStateNotifier`/`DemoModeBanner` derive from) drives every surface.

## What changed (file:line)

| Defect | Resolution | Cite |
|---|---|---|
| Shared signal | New `ShiftVendorSourceResolver.forLocation()` resolves `pos`/`labor` vendor ids from the canonical demo fixture; unknown (production) → `ShiftVendorSource.none` (no kDemoMode fork, no parallel signal) | `lib/services/integration/shift_vendor_source_resolver.dart:1-83` |
| D1 | Whole-day notifier call site now passes `posSourceVendorId`/`laborSourceVendorId` from the resolver | `lib/state/shift_dashboard_notifier.dart:10,153-172` |
| D1 | Whole-day `ShiftService` call site same wiring | `lib/services/shift_service.dart:67,1023-1041` |
| D1 | Read-model gate bodies UNCHANGED (caller-only) — verified by seed test "gate is caller-only" | `lib/models/shift_dashboard_read_model.dart:171,188,206` (untouched; not in diff) |
| D2 | Per-period labor gate `hasLabor` now ANDs `laborConnected`; `actualPct` ANDs `laborConnected`; OPZ pending copy distinguishes not-connected vs awaiting punches | `lib/screens/shift_dashboard.dart:889-895,907,921,939-958` |
| D3 | `_ShiftSectionViewData.unavailableTooltip()` returns the honest pre-service line when the vendor IS connected but the period has not started yet; verbatim "Connect a … vendor" otherwise | `lib/screens/shift_dashboard.dart:808-833` |
| D2/D3 wiring | `_servicePeriodSlivers` resolves active scope + period phase and feeds `fromPeriod`; 5 hardcoded tooltips swapped to `data.unavailableTooltip(...)` | `lib/screens/shift_dashboard.dart:300-339,1085-1190` |
| Tests | D1 seed test (provided) + new D2/D3 probe suite via `@visibleForTesting` `debugShiftPeriodProvenance` | `test/shift_vendor_source_provenance_test.dart`, `test/shift_period_vendor_honest_degrade_test.dart`, probe at `lib/screens/shift_dashboard.dart:1044-1100` |

## FOLLOW-UP NEEDED

None. All three defects resolved fully in the auto-fix envelope
(demo-wiring + UI rendering + lifecycle). No read-model gate body, no
`LaborModel`/`TargetCycle`/snapshot formula, no Metric-Honesty contract,
no RLS/proxy/auth, no `demo_*` table, no `kDemoMode` reader fork touched.

## Pattern B — 14-lens self-audit

| # | Lens | Worker finding (file:line) | Orchestrator |
|---|---|---|---|
| 1 | Slice intent met | All 3 device-reproduced defects fixed: D1 whole-day labor live for Downtown/Riverside, unavailable for North Loop/Harbour (`shift_vendor_source_provenance_test.dart` 11/11); D2 per-period labor honest-degrades per location (`shift_period_vendor_honest_degrade_test.dart` D2 4/4); D3 3-state messaging (D3 4/4) | |
| 2 | Authority order honored | Operator decision (ii) per-location realism applied verbatim; investigation §6.2 Option A (caller-only wiring) taken; Option B (gate collapse) explicitly NOT taken | |
| 3 | HP #2 (demo writer-side) | Single signal = existing fixture via resolver; no `demo_*` table; no `kDemoMode` reader branch; production location → `ShiftVendorSource.none` preserves current behavior `shift_vendor_source_resolver.dart:60-66` | |
| 4 | HP #4 per-(op,loc) scope | Resolver keyed on `restaurantId`; notifier/service capture active `restaurantId` before resolve `shift_dashboard_notifier.dart:96,162`; `shift_service.dart:1027` | |
| 5 | Metric Honesty | Gate bodies untouched (caller-only) — proven by seed test L166-185; degrade still fires on genuine zero; no phantom values introduced | |
| 6 | Scope discipline | Only the 4 owned files + 2 tests + 1 audit doc touched; no seed/fixture/#827-829 edits; `git diff --stat` = 3 lib + 1 new lib + 2 tests | |
| 7 | No formula change | No edit to `LaborModel`/`TargetCycle`/`WeeklyPlanSnapshot`/read-model math; D2 only ANDs a boolean onto existing value gates `shift_dashboard.dart:921` | |
| 8 | UX writing standard | Pre-service copy "This service period hasn't started yet today — numbers appear here once service begins." — plain English, training tone, no jargon `shift_dashboard.dart:828-829`; OPZ not-connected sub-line mirrors existing voice | |
| 9 | No reader fork / parallel signal | Resolver is the only new path; reuses `DemoVendorIntegrationStateFixture` (banner's source); no `kDemoMode` conditional anywhere | |
| 10 | Tests prove the seam | 19/19 new pass: per-location D1 provenance, caller-only gate proof, D2 4-location honest-degrade w/ covers/sales untouched, D3 3-state copy incl. "never mislabel not-connected as not-started" | |
| 11 | Analyze clean | `flutter analyze` on all 4 touched lib files + 2 tests: no new issues. 1 pre-existing `info` (DaypartPlanAllocator deprecation `shift_service.dart:1194`, outside diff) | |
| 12 | Baseline regression check | 3 latent failures (`shift_dashboard_empty_state_widget_test` no-data-state; `shift_dashboard_notifier_test` inTheBooksCovers 72/144; `variance_visual_widget_test` Previous-Weeks-header) reproduce identically on a fresh `origin/master` worktree → pre-existing, NOT PR-introduced | |
| 13 | Whole-day unchanged where intended | `fromWholeDay` path byte-identical: new view-data fields default (`posConnected=true,laborConnected=true,periodNotStartedYet=false`) so `unavailableTooltip` returns the verbatim prior strings; only per-period pre-service overrides `shift_dashboard.dart:801-806,817-833` | |
| 14 | Concurrency / no merge | Only owned files; branch → push → PR → STOP; no merge, no tracker edit, no `--no-verify`; hooks installed (step 0) | |

## Local verification (CI dark — disclosed honestly)

- `flutter pub get` → Got dependencies.
- `flutter analyze lib/services/integration/shift_vendor_source_resolver.dart lib/state/shift_dashboard_notifier.dart lib/services/shift_service.dart lib/screens/shift_dashboard.dart test/shift_vendor_source_provenance_test.dart test/shift_period_vendor_honest_degrade_test.dart` → no new issues (1 pre-existing deprecation info at `shift_service.dart:1194`, unrelated).
- `flutter test test/shift_vendor_source_provenance_test.dart test/shift_period_vendor_honest_degrade_test.dart` → **+19 All tests passed**.
- Adjacent suites `flutter test shift_dashboard_daypart_toggle/empty_state/notifier_cold_boot/notifier/shift_service_close_shift/service_period_definition_resolver` → +72 with 2 failures; both reproduce on `origin/master` baseline (pre-existing).
- Variance suites `flutter test variance_history/variance_visual/wtd_variance_logic/variance_week_projection/shift_whole_day_alignment/demo_slice_b_driver_variance` → +187 with 1 failure (`variance_visual_widget_test` Previous-Weeks header); reproduces on `origin/master` baseline (pre-existing).

### Per-location before → after

| Location | Whole-day labor (D1) before → after | Per-period labor (D2) before → after | Pre-service POS msg (D3) |
|---|---|---|---|
| Downtown (POS+Labor) | "Connect a labor vendor" → **live** | rendered (value-only) → **live** | connected+pre-service → **"hasn't started yet today"** |
| Riverside (all live) | "Connect a labor vendor" → **live** | rendered → **live** | as above |
| North Loop (POS only) | "Connect a labor vendor" → **unavailable (honest)** | rendered for ALL → **honest-degraded (no labor actuals, OPZ "LABOR NOT CONNECTED")**; covers/sales unchanged | POS connected → "hasn't started yet"; labor → "Connect a labor vendor" |
| Harbour (none) | "Connect a labor vendor" → **unavailable (honest)** | rendered for ALL → **honest-degraded**; covers value-gate unchanged | not connected → **still "Connect a POS vendor"** (never mislabeled as not-started) |
