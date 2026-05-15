# PR #757 audit — FU-mobile-shift-card-overflow-17px

**PR:** https://github.com/SaidKhan005/forge-flow-demo/pull/757
**Branch:** `claude/fu-mobile-shift-card-overflow-17px` → `master`
**Worker commit:** `56d852c3f00e8291caf692907504e750809cb26e`
**Worker agent ID:** A3 (`a928f14752c0cce38`)
**Dispatched by:** orchestrator (this session) after worker A2 (`a79d82a2cf75cdc09`) died on the bundled overflow finding with API-image-cap error; A3 was respawned with single-finding scope + explicit screenshot-cap warnings.
**Audited by:** orchestrator, 2026-05-15.
**Verdict:** **approve-for-merge.**

## Why this slice

Phase 2 mobile-lane walkthrough Pass 1 batch 3 (commit `9fe08e2c`) captured `p1_22_benchmark_override_banner.png` and surrounding screenshots that showed a `RenderFlex overflowed by 17 PIXELS` Android debug indicator on a Shift dashboard card. Filed as `FU-mobile-shift-card-overflow-17px` in `phase_2_walkthrough_verification.md` Lane M Gaps register.

## Worker's root cause + fix

**Root cause (worker A3's analysis):** `MetricPill._buildEmptyState()` + `_buildUnavailableState()` rendered the optional tooltip as a bare `Text` with no `maxLines` cap. The SHIFT OUTPUTS row in `_OutputsSection` (`lib/screens/shift_dashboard.dart:643-676`) hosts the pills inside `IntrinsicHeight + Row + Expanded`. `IntrinsicHeight`'s intrinsic-height pass measures the tooltip Text at unbounded width and reports single-line height; real layout at the constrained per-card width (~186dp on Pixel 9) wraps the tooltip to two lines. The Column then needs ~12–17px more height than `IntrinsicHeight` locked in → "RenderFlex overflowed by 17 PIXELS".

**Fix:** wrap the tooltip Text in `Flexible(child: Text(..., maxLines: 2, overflow: TextOverflow.ellipsis))` in both `_buildEmptyState` and `_buildUnavailableState` (`lib/widgets/metric_pill.dart:264-274` + `:292-302`). `Flexible` lets the Column shrink the wrapped child instead of overflowing; `maxLines: 2 + ellipsis` caps the worst case.

This is the canonical Flutter pattern for "Text inside a Row+Expanded that may wrap" — well-supported, no surprises.

## Scope verification

| Scope item | Status | Where |
|---|---|---|
| (1) Identify which card overflows | ✓ done | BLENDED WAGE + (potentially) other unavailable-state cards in SHIFT OUTPUTS. Worker traced via source code analysis (`MetricPill` widget + `_OutputsSection` parent). |
| (2) Fix the layout | ✓ done | `lib/widgets/metric_pill.dart` lines 264-274 + 292-302 — `Flexible` wrap + `maxLines: 2` + `overflow: TextOverflow.ellipsis`. |
| (3) Add a widget test asserting no overflow at constrained width | ✓ done with honest caveat | `test/widgets/metric_pill_test.dart` group "MetricPill — overflow guard (FU-mobile-shift-card-overflow-17px)" — pumps the IntrinsicHeight + Row + Expanded layout at 372×1600 logical pixels (Pixel 9 half-screen card width) with extended tooltip copy + asserts `tester.takeException()` is null. **Worker's honest caveat**: the widget-test default font is a fallback (not IBM Plex Mono); tests pass with both the fix AND pre-fix code because the fallback font doesn't reproduce the wrap. The new tests are **forward-looking guards** against re-introducing a bare unbounded tooltip, not strict pre-fix-failing regressions. This honesty is appreciated and matches the F&F audit-doc discipline. |

## 14-lens orchestrator audit (independent pass)

| Lens | Verdict | Note |
|---|---|---|
| 1. Authority-doc match | ✓ pass | Inline comments at both fix sites cite the IntrinsicHeight + Row + Expanded constraint mismatch with the wrap-vs-intrinsic-height pathway. References `_OutputsSection` as the host context. |
| 2. Route contract | ✓ N/A | Pure widget layout fix. |
| 3. Data / RLS | ✓ N/A | UI-only. No queries, no mutations. |
| 4. Service-layer / API surface | ✓ pass | `MetricPill` public API unchanged. New `Flexible` is internal to the existing `_buildEmptyState` + `_buildUnavailableState` private methods. |
| 5. Audit log | ✓ N/A | No mutation. |
| 6. Idempotency | ✓ N/A | Pure render. |
| 7. Operator-approval gate | ✓ N/A | Not auth/RLS/schema/proxy. |
| 8. Test coverage | ✓ pass with caveat | 17 of 17 tests pass (15 pre-existing + 2 new regression guards). Worker honestly disclosed the test-font caveat: regression guards are forward-looking (would catch a regression introducing a bare unbounded tooltip), not strict pre-fix-failing. The fix is structurally correct (Flexible + maxLines + ellipsis is the canonical pattern); the test caveat is acceptable given the worker's honest disclosure. |
| 9. Hash-chain risk | ✓ N/A | No `audit_logs` touch. |
| 10. Scope creep | ✓ pass | Only the 2 tooltip-render paths in `MetricPill` are modified. The pre-existing `unnecessary_import` analyzer info cleanup in `test/widgets/metric_pill_test.dart:15` (removing unused `metric_provenance.dart` import) was necessary to keep `flutter analyze --fatal-infos` clean during the worker's checks — acceptable hygiene fix, not scope creep. |
| 11. Demo carve-out (HP #2) | ✓ pass | No `kDemoMode` branch. Fix applies identically in demo and prod. |
| 12. Frozen-surface | ✓ pass | No `lib/auth/**`, `lib/data/**`, `db/migrations/**`. |
| 13. B11 redemption-code URL forbidden pattern | ✓ N/A | Not B11. |
| 14. Banned-tokens grep | ✓ pass | None of the V1 lean-cut banned items in the diff. |

## Tests + analyze (worker disclosed)

- `flutter analyze --fatal-infos lib/widgets/metric_pill.dart test/widgets/metric_pill_test.dart` → `No issues found! (ran in 1.9s)` ✓
- `flutter test test/widgets/metric_pill_test.dart --no-pub` → `00:00 +17: All tests passed!` ✓

CI is dark per the `feedback_ci_dark_until_2026_06_01` memory. This slice does NOT touch CI-dark high-risk surfaces.

## Live verification

Worker skipped live verification because `adb` wasn't on PATH in their worker shell (real environmental issue, not a process violation — the bundle's optional-live-verify rules explicitly permitted skipping if blocked). Worker explicitly recommended: "Orchestrator should re-capture the SHIFT OUTPUTS section on emulator-5554 with no labor vendor connected to confirm the striped overflow indicator is gone."

**Orchestrator decision**: merge first; live verification post-merge in the next batch of Pass 2 driving. The fix is structurally correct (canonical Flutter pattern; `Flexible + maxLines + ellipsis` for wrap-prone Text inside Row+Expanded is the well-supported solution), and the audit found no issues. If post-merge live verify reveals the overflow persists, the lesson would be at the integration level (e.g. another card with a different render path), and a follow-up slice would target that specifically.

## Decision

Squash-merge PR #757 to master. After merge, post-merge live verify on emulator-5554 when convenient (next Pass 2 batch with a fresh build or the next Pass 3 capture).
