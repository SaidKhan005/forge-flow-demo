# Operating Inputs Strip Alignment — Lens Audit (Pattern B)

Slice: Benchmark UX — align Operating Inputs strip halves
Branch: `claude/ux-operating-inputs-strip-align`
Scope: `lib/screens/baseline_tracker.dart` (`_OperatingStrip` / `_StripHalf`) — pure layout. Plus one new widget test.

## Pass 0 — Branch, Authority, Scope

- Branch verified `claude/ux-operating-inputs-strip-align`; base `master` at `88ac0f0f`.
- Authority: prompt → CLAUDE.md (UX Writing Standard, Metric Honesty Doctrine). No contract conflict.
- Symptom verified on fresh master before changes: at 360px the right title `Theoretical Labor %: The Floor` wrapped to two lines and pushed the right half's rule + rows down (root cause). A **separate, pre-existing** ~37px horizontal `RenderFlex` overflow (`mainAxisSize: min` Row elsewhere on the screen, **not** in the strip) reproduces on **unmodified** master at 360px — confirmed by `git stash` of the lib change + diagnostic test producing the identical overflow. That overflow is unrelated to the strip and out of scope for this layout-only slice.
- Scope honored: only `lib/screens/baseline_tracker.dart` touched in `lib/`; no `shift_dashboard.dart`, no demo seed, no Settings, no `ActiveTargetProfile`, no read logic.

## Fix summary

1. `_StripHalf` header: title moved into a fixed two-line band — `SizedBox(height: _kHeaderFontSize * _kHeaderLineHeight * _kHeaderLines)` with `Align(centerLeft)` + `mono7.copyWith(height:1.3)`, `maxLines:2`, ellipsis. Both halves' bands now share an identical top/height regardless of title length (`baseline_tracker.dart:639-682`).
2. `_StripHalf` data rows: label + value `Text` set to `maxLines:1, softWrap:false, overflow:ellipsis` so every row is exactly one line tall in both halves (the flex 5:4 split was starving the longer left labels at 360px, re-introducing raggedness below the now-aligned header) (`baseline_tracker.dart:697-728`).

## Lenses Checked

| Lens | Code/doc checked | Worker self-audit finding | Independent audit (orchestrator) |
|---|---|---|---|
| 0 Branch/Authority/Scope | branch, `CLAUDE.md`, `git stash` repro | PASS — correct branch/base; symptom verified pre-change; pre-existing unrelated overflow proven on master; scope = 1 lib file + 1 test | |
| 1 Product & user journey | `baseline_tracker.dart:639-728` | PASS — Benchmark Operating Inputs strip now reads as deliberate aligned siblings; no copy/number/journey change | |
| 2 Information architecture & nav | `baseline_tracker.dart:590-624` | PASS — card grammar unchanged: gradient surface, `AppColors.rule` border, 3px radius, center divider, 18/14 padding rhythm all preserved | |
| 3 Data model, migration, RLS | n/a | PASS — no schema/migration/RLS surface; pure widget layout | |
| 4 Repository & service layer | `baseline_tracker.dart:521-584` | PASS — profile/bridge read path (`context.watch<ActiveTargetProfileNotifier?>()`, `targetBlendedWage` seam) byte-unchanged | |
| 5 Proxy/route/gateway | n/a | PASS — no network/proxy surface | |
| 6 Auth/roles/permissions/scope | n/a | PASS — no auth/permission surface | |
| 7 Lifecycle & destructive actions | n/a | PASS — no destructive action; no state mutation | |
| 8 Background/deploy/startup/health | n/a | PASS — none | |
| 9 UI state, UX, accessibility | `baseline_tracker.dart:531-545`, `639-728` | PASS — honest-empty "Benchmark target profile unavailable" path untouched (Design Rule 2). Header band fixed-height + vertical-center; rows single-line uniform. Full text visible at operator phone width (1080px); ellipsis only the 360px safety valve (full `Theoretical Labor %: The Floor` still shows two-line at 360 per geometry dump) | |
| 10 Performance & data loading | `baseline_tracker.dart:659-682` | PASS — `SizedBox`/`Align` are O(1) layout; no extra rebuilds, no new listeners | |
| 11 Mobile/web/admin/API parity | `baseline_tracker.dart` | PASS — single shared widget; demo/prod identical (no `kDemoMode` branch); parity intact | |
| 12 Tests/builds/evidence | `test/widget/baseline_operating_strip_align_test.dart` | PASS — 4 new tests (header-band + row-align at 1080 & 360) green; `flutter analyze` clean; existing baseline/benchmark suites green (see Evidence). Diagnostic scratch tests removed | |
| 13 Observability/audit/support | n/a | PASS — none | |
| 14 Docs/tracker/prompt hygiene | this doc | PASS — self-audit doc added; no tracker edits (per contract); no copy changes so no UX-writing drift | |

## Tests & Evidence (CI dark — all run locally on Windows)

- `pwsh scripts/install_git_hooks.ps1` → hooks installed (pre-commit, pre-push).
- `flutter pub get` → `Got dependencies!`
- `flutter analyze lib/screens/baseline_tracker.dart test/widget/baseline_operating_strip_align_test.dart` → `No issues found!`
- `flutter test test/widget/baseline_operating_strip_align_test.dart` → 4/4 passed (header bands + row pixel-align at 1080 and 360).
- `flutter test test/widget/baseline_operating_strip_align_test.dart test/baseline_override_propagation_test.dart test/target_consistency_opz_test.dart` → **+32 All tests passed** (4 new + 28 existing baseline/benchmark, incl. `G. Slice 2 strip + daypart table prefer ActiveTargetProfile` and the honest-fallback case).
- Geometry proof (diagnostic, at 360px, post-fix): both header bands `top=1119.3 h=28.0`; rows `FOH Wage`/`FOH %` `top=1176.6`, `BOH Wage`/`BOH %` `top=1222.6`, `Blended Wage`/`Total %` `top=1268.6` — left/right pixel-aligned, all rows uniform `h=17.0`.

## Residual Risks

- At 360px the longest data label (`Blended Wage`, ~62px column) may ellipsize. This is the extreme-narrow stress floor; at the operator's stated phone width (1080px) all labels render in full. Alignment at 360px is the operator's binding requirement, and ellipsis is also what clears the in-strip row overflow. Accepted tradeoff, documented inline at `baseline_tracker.dart:703-712`.
- Pre-existing screen-level horizontal overflow (~37px, `mainAxisSize:min` Row, **not** the strip) remains on master at 360px — unrelated, out of scope, not regressed by this change. Flagged for a future BaselineTracker layout pass; the new test tolerates only a horizontal overflow and still fails on a vertical one (a band-regression shape).

## Decision Stops

None. Layout-only, no auth/RLS/schema/proxy surface; no ceiling raise.
