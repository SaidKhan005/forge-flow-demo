# PR #858 Audit — Shift tiles actual-vs-target + remove 3 demo banners

**Auditor:** Orchestrator. **Date:** 2026-05-16. **PR:** #858, branch
`claude/shift-tiles-actual-vs-target-no-demo-banners`, base `master`, +217/−962,
9 files (5 lib + 4 test). **Verdict: APPROVED — operator-requested UX, audit
clean, merging.**

## Operator request implemented
1. Remove the 3 demo banners ("Demo POS/labor/reservation data — connect … to
   go live") that rendered above the tab body.
2. Every Shift metric tile must show actual-vs-target (like SALES / LABOR %),
   not the vendor source label ("Toast"). Target = what the logic already
   defines — verified against `ShiftDashboardReadModel._buildMetricCards`.

## Scope check
5 lib files: `forge_flow_app.dart` (banner unmount + import), `demo_mode_banner.dart`
(deleted), `metric_pill.dart` (+optional `targetLabel`), `shift_dashboard.dart`
(thread target labels), `shift_dashboard_read_model.dart` (+`targetBlendedWage`
passthrough). 4 test files. No trackers, no formula/connector/auth/RLS/schema/
proxy, no migrations, no docs. In-scope; display-only on the authoritative Shift
view.

## Pattern B — orchestrator independent audit

| Change | Worker self-audit | Orchestrator audit (file:line) |
|---|---|---|
| Banner removal is purely visual | mount + widget + import + own tests removed; demo-state machinery intact | CONFIRMED `forge_flow_app.dart` −25: `const DemoModeBanner()` + wrapping `Column` removed (now bare `IndexedStack`), import dropped; the `8.demo-mode-banner` notifier comment/plumbing (`DemoModeStateNotifier`, `_bindDemoModeNotifier`) is retained, only the visual widget reference reworded. `demo_mode_banner.dart` fully deleted (−134). HP #2 untouched: no `kDemoMode` branch added/removed, `demo_mode_state`/flip-policy/sync seam unchanged. |
| 5 pills show authoritative target, format parity | byte-identical to `_buildMetricCards` | CONFIRMED `shift_dashboard.dart` `_ShiftSectionViewData.fromWholeDay` +: `'Forecast ${rm.forecastCovers}'`, `'Target \$${rm.targetPPA.toStringAsFixed(2)}'`, `'Target ${rm.targetCPLH.toStringAsFixed(2)}'`, `'Target \$${rm.targetSPLH.toStringAsFixed(0)}'`, `'Target \$${rm.targetBlendedWage.toStringAsFixed(2)}'` — character-for-character equal to `_buildMetricCards` (read model L712-770). Threaded via `_toPillProvenance(targetLabel:)` to COVERS/PPA/CPLH/SPLH/BLENDED WAGE in `_OutputsSection`/`_InputsSection`. |
| Per-period honest nulls (no fabricated Target 0) | each null when locked target absent; COVERS per-period null | CONFIRMED `fromPeriod` +: `tc.targetPPA/targetCPLH/targetSPLH` each null-guarded → `null` label (pill keeps prior honest behavior, never `Target 0`). COVERS per-period `null` (no per-period forecast-covers source on `DaypartTargetContext` — no fabrication). Blended-wage target period-invariant, passed from caller via `ActiveTargetProfileNotifier?` (nullable watch, same established pattern as `RestaurantScopeNotifier?` L322) → `null` when no profile bound. |
| Honesty branches unchanged | empty/unavailable/Demo/Stale untouched | CONFIRMED `metric_pill.dart`: `targetLabel` only consulted in `_buildProvenanceLabel` (live/stale/demo/partial/fallback) as `provenance.targetLabel ?? provenance.label` — same key `metric_pill_provenance_$label`, same style/position. Empty/unavailable branches + Demo/Stale badges byte-unchanged. New test `targetLabel does NOT leak into the unavailable honesty branch` explicitly guards this. |
| `required targetBlendedWage` safe | only one constructor site | CONFIRMED `git grep "ShiftDashboardReadModel("` on branch → only L229 (ctor decl) + L477 (sole factory call, sets `targetBlendedWage: profile.targetBlendedWage`). No other call site; `dart analyze` clean is consistent. Value = existing `profile.targetBlendedWage`, no new math. |

## Hard constraints
- HP #2: no `demo_*` table, no `kDemoMode` reader branch; demo-state runtime
  machinery (notifier/flip/sync) intact — only a visual banner removed per
  operator decision. ✓
- HP #4: per-`restaurant_id`; no migrations; RLS-ready schema untouched. ✓
- Metric Honesty: per-period targets null-guarded → pill honest-empty, never a
  phantom `Target 0`; unavailable branch test-guarded. ✓
- Architecture Guardrail (Shift whole-day authoritative): display-only; targets
  are passthroughs of existing read-model values; production math
  byte-unchanged. ✓
- No core-formula/recommendation/connector/proxy/auth/RLS change. ✓

## Tests (CI dark — disclosed local run)
`dart analyze` clean on all 7 touched files (worker-disclosed; orchestrator did
not re-run — display-only, no high-risk surface). metric_pill 20/20 (incl. 3
new `targetLabel` tests), scope-defer 1/1 (re-pointed to `AppShell`, still
asserts screen-not-torn-down on scope flip), shift daypart 39/39, p2d pressure
harness 6/6 (Task 1/2 sync-seam + Task 5 SQL-queryability HP#2/#4 retained;
removed Task 3/4 + Task 5 render probes that pumped the deleted widget — those
cannot exist without it; the HP#2 mechanism is still tested at the SQL layer),
per_daypart_v1 10 files 49/49. Pre-existing failure
`shift_dashboard_notifier_test.dart` → `inTheBooksCovers after reseed`
(`Expected <72> Actual <144>`) proven identical on branch base `fb824b27` —
NOT a regression (unrelated demo-seed count).

## Decision
Clean against all hard constraints; operator-requested UX; display-only on the
authoritative Shift view with byte-identical target formatting to the read-model
authority. Merging squash to `master`; rebuilding on the emulator for operator
visual sign-off.
