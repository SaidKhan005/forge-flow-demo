# Per-Daypart Targets V1 — Slice 2 audit (Benchmark tab redesign)

> PR: (filled on PR open)
> Branch: `claude/per-daypart-slice-2-benchmark-tab`

## Slice intent (from `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`)

Slice 2 — Benchmark tab redesign (plan §"Slice 2", Decisions 8/9/10/11,
Gaps 15/17/35):

- Daypart Breakdown table: swap Avg CPLH/SPLH/PPA columns for the
  **Target** equivalents; keep Avg Covers; fold OPZ Floor + Ceiling
  into one "OPZ Range" column; add a Whole Day rollup row (cover-
  weighted pool).
- Cut the "Targets Derived from Benchmark" card; rehome its Wage +
  Theoretical % groups as a slim strip ("Operating Wage Mix" +
  "Theoretical Labor %: The Floor", Option B labels, no em dash).
- De-hardcode the period-label sites — read from resolved timing-config
  service-period definitions instead of `['lunch','dinner','late_night']`.
- Reader swap: per-period values come from
  `ActiveTargetProfile.daypartFor(periodId)`; fall back to the whole-day
  pool when `dayparts` is empty (Gap 42). No sentinel `0`
  (Design Rule 2).
- Cut the operator-web Benchmarks override surface entirely (Gap 35
  locked resolution): delete the override screen + gateway + nav +
  auth-source wiring; leave a one-line code comment citing Gap 35.

## Scope (files modified / deleted)

Modified:
- `lib/services/benchmark_tracker_read_service.dart` — de-hardcoded the
  `['lunch','dinner','late_night']` iteration list + `_labelFor` switch;
  resolves operator timing-config service-period definitions (falls
  back to canonical fixture defs); threads `servicePeriodDefinitions`
  into `BenchmarkTrackerView`; period-agnostic honesty copy.
- `lib/widgets/daypart_table.dart` — rewritten: new column set
  (DAYPART · AVG COVERS · TARGET CPLH · TARGET SPLH · TARGET PPA ·
  OPZ RANGE), per-period read-back via `profile.daypartFor`, Gap 42
  pool fallback, honest `—` when no profile, Whole Day rollup row,
  resolver-driven labels.
- `lib/screens/baseline_tracker.dart` — cut `_BaselineTargetsCard` +
  the "TARGETS DERIVED FROM BENCHMARK" sliver header; added
  `_OperatingStrip` (Option B, no em dash); passes profile + defs to
  `DaypartTable`.
- `lib/operator_web/router/operator_web_router.dart` — removed the
  Benchmarks nav item, route case, `_benchmarksGateway` getter,
  `_routerOwnedDemoBenchmarksGateway` field, import, nav constant,
  route mapping.
- `lib/operator_web/auth/operator_web_auth_source.dart` — removed
  `OperatorWebBenchmarksGatewayProvider` from `implements`, the
  `benchmarksGateway` field, the gateway import.
- `lib/operator_web/auth/firebase_operator_web_auth_source.dart` —
  removed the provider from `implements`, the field, the constructor
  init.
- `lib/operator_web/services/operator_web_team_gateway_providers.dart`
  — removed the benchmarks gateway export block.
- `lib/operator_web/services/web_audit_log_hierarchy_gateway.dart` —
  updated a stale doc comment that named the now-deleted provider type.
- `lib/services/baseline/benchmark_override_resolver.dart` — added the
  one-line Gap 35 code comment (server-side resolver + Postgres
  repository stay; the operator-web *surface* is what is cut).

Deleted:
- `lib/operator_web/screens/benchmarks_screen.dart`
- `lib/operator_web/services/operator_web_benchmarks_gateway.dart`
- `test/operator_web/screens/benchmarks_screen_test.dart`
- `test/operator_web/services/operator_web_benchmarks_gateway_test.dart`

Tests:
- `test/daypart_table_slice_2_test.dart` — NEW. 5 tests: per-period
  read-back, OPZ single-column fold, empty-`dayparts` Gap 42 fallback,
  no-profile honest-dash, resolver-driven labels.
- `test/target_consistency_opz_test.dart` — re-pointed groups E + G at
  the new strip + daypart table surfaces.
- `test/baseline_override_propagation_test.dart` — re-pointed group B
  at the CPLH range bar (the cut card's old assertion target).

## Pattern B audit table

Worker self-audit + executor independent audit; both with file:line
citations. Lenses per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

| # | Lens | Status | Evidence (file:line) |
|---|------|--------|----------------------|
| 1 | Scope match | PASS | `git diff --name-only origin/master...HEAD` = only Benchmark-tab files + operator-web-Benchmarks-delete files + the 3 named tests + this audit doc. No touch to `target_cycle_service.dart`, `weekly_plan_snapshot_service.dart`, `data_alignment_audit_read_service.dart`, `lib/screens/shifts/*`, variance card, `schedule_builder*`, vendor sinks (concurrency exclusions honored). |
| 2 | Authority order | PASS | Prompt SCOPE block is authoritative; plan §Slice 2 + Decisions 8-11 + Gaps 15/17/35 implemented exactly. Plan's *extended* items (Gap 27 enum, Gap 34 wage copy, Gap 36 covers columns, Gap 40 preview math) are NOT in the prompt SCOPE block and were deliberately NOT pulled in (prompt > plan extended list). No conflict with `docs/contracts/core_app_architecture.md` (UI + operator-web client only). |
| 3 | Hard Promises | PASS | HP #2 (demo mode): no `kDemoMode` branch added; same reads demo/prod. HP #6 (advisor recommends, not commands): unaffected. HP #11 (hierarchy-scoped settings): the operator-web Benchmarks override was the *only* hierarchy-scoped benchmark write surface; Gap 35's locked resolution removes it (mobile Baseline Manager star-shift selection is the only override path) — this is the contract-sanctioned cut, not a hierarchy regression. No new settings surface introduced. |
| 4 | Service-layer split | PASS | Read logic stays in `lib/services/benchmark_tracker_read_service.dart`; widgets in `lib/widgets/` + `lib/screens/`; resolver in `lib/domain/services/`. No raw `package:postgres` import added. `benchmark_override_resolver.dart` (`lib/services/baseline/`) left in place; only a comment added. |
| 5 | Design Rule 1 (per-period field naming) | PASS | `DaypartTable._targetCellsFor` reads `period.daypartTargetCPLH` / `daypartTargetSPLH` / `daypartTargetPPA` / `daypartOpzFloorCPLH` / `daypartOpzCeilingCPLH` (`lib/widgets/daypart_table.dart:64-67`) — the `daypart*`-prefixed accessors only. Whole-day fields (`p.targetCPLH`, `p.opzFloorCPLH`) are read ONLY on the explicit Gap-42 fallback branch (`daypart_table.dart:71-76`) and the Whole Day rollup row (`daypart_table.dart:137-145`), never substituted for a period row that has a child row. |
| 6 | Design Rule 2 (null vs zero) | PASS | `daypartFor` null → fallback to the whole-day pool, never `0` (`daypart_table.dart:69-76`). No profile at all → honest em dash `_missing = '—'` (`daypart_table.dart:57-61,134-145`). New test `daypart_table_slice_2_test.dart` "no profile at all → honest dash" asserts `find.text('0.00')`/`find.text('\$0')` `findsNothing`. Read service no longer emits sentinel-`0` `DaypartRange`s for absent periods because the period set is now the resolver's defined set (`benchmark_tracker_read_service.dart:_buildDaypartRanges`). |
| 7 | Demo-mode contract | PASS | No `kDemoMode` carve-out added/removed. Bridge-only mode (`isBridgeOnly`) is a pre-existing test seam, not a demo branch; `_OperatingStrip` uses it only for the test-only BaselineData fallback exactly as the old `_BaselineTargetsCard` did (`baseline_tracker.dart` `_OperatingStrip.build`). Same UI/reads in demo + prod. |
| 8 | RLS-ready schema | N/A | No schema/migration change. The Postgres `benchmark_overrides` table is intentionally NOT dropped; it is historical read-only compatibility while active adjustments use selected-star target cycles. |
| 9 | Time guardrails | N/A | No timestamp handling touched. |
| 10 | Test coverage | PASS | 5 NEW tests in `test/daypart_table_slice_2_test.dart`: (a) per-period read-back asserts each row shows its own `daypartTarget*` and the candidate-average sentinels `9.99`/`$99.99` do NOT leak; (b) OPZ single-column fold asserts `'OPZ RANGE'` `findsOneWidget`, `'OPZ FLOOR'`/`'OPZ CEILING'` `findsNothing`, combined `'2.90 – 3.40'` cells; (c) Gap-42 empty-`dayparts` fallback asserts pool `4.50` `findsNWidgets(4)` (3 rows + rollup); (d) no-profile honest-dash; (e) resolver-driven labels (relabeled defs → `'Midday'` shows, `'Lunch'` `findsNothing`). Re-pointed `target_consistency_opz_test.dart` groups E/G (23 pass) + `baseline_override_propagation_test.dart` group B (5 pass). Nearest existing `benchmark_tracker_read_service_test.dart` (3 pass). |
| 11 | Reader-swap correctness | PASS | Per-period values flow `ActiveTargetProfileNotifier.profile` → `DaypartTable.profile` → `daypartFor(range.id)` (`baseline_tracker.dart` daypart sliver; `daypart_table.dart:64`). Whole Day rollup reads the same pool fields the CPLH Range & Target widget at the top reads (`p.targetCPLH` etc., `daypart_table.dart:137-145`) → 1:1 by construction per plan Decision 8 / line 241. De-hardcode verified: read service iterates `ServicePeriodDefinitionResolver.ordered(defs)` (`benchmark_tracker_read_service.dart:_buildDaypartRanges`), labels via `labelForId` (×2 sites), honesty copy period-agnostic. |
| 12 | Operator-web override fully severed | PASS | `grep -rln` for `BenchmarksScreen\|operator_web_benchmarks_gateway\|OperatorWebBenchmarksGateway\|kOperatorWebNavBenchmarks` over `lib/` + `test/` returns only the 3 files carrying explanatory *comments* (router, firebase auth source, providers index) — zero code references. `dart analyze lib/operator_web/` → `No issues found!`. Router test passes (22). Gap 35 one-line comment present at `lib/services/baseline/benchmark_override_resolver.dart:1-7`. |
| 13 | No tracker edits | PASS | `git status` shows no change to `PROJECT_TRACKER.md`, `docs/_indices/NEXT_WAVE_PLAN.md`, `docs/_indices/*_LEDGER.md`, `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`. Only impl/test files + this audit doc. |
| 14 | No merge / no `--no-verify` | PENDING | Canonical hooks installed (`scripts/install_git_hooks.ps1`, step 0). Commit + push (no `--no-verify`), PR via `gh pr create`, then STOP. No merge. |

## Follow-ups (out of scope, not fixed in this slice)

1. **Benchmark override backend posture now supersedes this follow-up.**
   The table stays for historical read-only compatibility. Active repository
   write helpers are removed and legacy HTTP write routes remain HTTP 410.
   A future cleanup may remove the route mount after old clients are proven
   gone, but no table drop is planned in this pass.
2. **Plan extended-list items (Gaps 27/34/36/40).** The plan's
   §"Slice 2 — Extended to include" list names `Daypart` enum
   replacement (Gap 27), Wage Mix "applies per-period" copy (Gap 34),
   `covers_source_*` precedence (Gap 36), `baseline_manager_preview`
   per-period math (Gap 40). None are in the prompt's authoritative
   SCOPE block; left for follow-up slices per authority order
   (prompt > plan).

## Verification (local; CI is dark — `ci.yml` gated to `workflow_dispatch`)

- `dart analyze` on every touched lib+test file → `No issues found!`
  except 6 PRE-EXISTING `info`-level `deprecated_member_use`
  lints in the untouched `test/benchmark_tracker_read_service_test.dart`
  (Slice-1 `@Deprecated` members; not introduced here).
- `dart analyze lib/` → 14 PRE-EXISTING `info` lints in untouched files
  (string-concat, deprecated_member, prefer_const). 0 errors, 0
  warnings, 0 dangling refs to the deleted surface.
- `dart analyze lib/operator_web/` → `No issues found!` (deletion clean).
- `flutter test test/daypart_table_slice_2_test.dart` → 5/5 pass.
- `flutter test test/target_consistency_opz_test.dart` → 23/23 pass.
- `flutter test test/baseline_override_propagation_test.dart` → 5/5 pass.
- `flutter test test/benchmark_tracker_read_service_test.dart` → 3/3 pass.
- `flutter test test/operator_web/operator_web_router_test.dart` → 22/22
  pass (nav/route deletion does not break operator-web routing).
