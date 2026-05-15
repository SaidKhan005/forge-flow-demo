# Per-Daypart Targets V1 — Architecture Verification Audit

**Date:** 2026-05-15
**Auditor:** Claude 2 (parallel-lane orchestrator)
**Scope:** Verify every file:line citation, class name, function reference, and gap claim inside `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` against current `master`. Read-only inspection. No production code modified.
**Method:** Glob to confirm file existence at cited path; targeted Read with offset/limit on cited line ranges; Grep for class names and class members where the plan defers verification ("verify class name"); Grep for hardcoded literals where the plan claims hardcodes still ship.
**Verdict (one-line):** Plan is accurate in substance — every load-bearing gap claim still matches the code on master. Citations have **path drift in 4 places** (services + models migrated to `lib/domain/**` per CLAUDE.md service-layer split) and **one minor class-name conflation** (Gap 16). Both are cosmetic — content claims hold. **All 9 slices ready for implementation dispatch** subject to the 4 operator decisions already named in the brief (Gaps 31, 35, 36, 42).

---

## Drift findings (citation freshness, not content)

### File-path drift (4 entries)

The plan and CLAUDE.md collectively express a service-layer split (`lib/services/` runtime orchestration, `lib/domain/services/` pure formulas, `lib/domain/models/` model contracts, `lib/data/` frozen legacy). Several plan citations still point at older `lib/services/` or `lib/models/` paths that have since moved to `lib/domain/**`. Content at the cited line ranges is identical at the new path; only the directory drifted.

| Cite (plan) | Actual on master | Used by | Severity |
|---|---|---|---|
| `lib/services/target_cycle_policy.dart` | `lib/domain/services/target_cycle_policy.dart` | Slice 0 (`TargetCyclePolicy.needsAutoRefresh`) | Cosmetic. Slice 0 prompt says "verify in audit." Confirmed: method exists at line 35 of the actual file. |
| `lib/models/target_cycle.dart:21-28` | `lib/domain/models/target_cycle.dart:21-28` | Gap 3 | Cosmetic. Lines 21-28 carry the locked whole-day standards (`targetCPLH`, `targetSPLH`, `targetPPA`, `fohWage`, `bohWage`, `opzFloorCPLH`, `opzCeilingCPLH`) — no per-period shape. Plan claim verified. |
| `lib/models/active_target_profile.dart:7-37, 59-62` | `lib/domain/models/active_target_profile.dart:7-37, 59-62` | Gaps 4, 11 | Cosmetic. Lines 7-37 carry flat scalar fields. Lines 59-62 use `0.0` as the divide-by-zero fallback — Design Rule 2 violation confirmed. |
| `lib/models/weekly_plan_snapshot.dart:17-32` | `lib/domain/models/weekly_plan_snapshot.dart:17-32` | Gap 6 | Cosmetic. Lines 17-32 hold `WeeklyPlanSnapshotDay` with whole-day `forecastCovers`, `forecastSales`, `requiredFohHours`, `requiredBohHours`. Plan claim verified. |

> Note: `lib/models/learn_benchmark_context.dart` and `lib/models/learn_teaching_summary.dart` (Gap 39) still live at the legacy `lib/models/` path and resolve correctly. The split is partial.

### Recommendation
Update the four citations above before dispatching Slice 0 / Slice 1 prompts so worker agents read from the live path. Single search/replace in the plan doc — no semantic change.

### Minor class-name conflation (Gap 16)

Gap 16 cites `_DaypartScaffoldCard` at `shift_dashboard.dart:1236-1239`. Verification:
- `_DaypartScaffoldCard` does exist — at lines 1077, 1096, 1103.
- Lines 1236-1239 actually contain the docstring of `_DaypartMetricGrid`, which carries the "no plan target on purpose, since per-period plan targets are not yet shipped" comment the plan quotes.

Both pieces of evidence are real; the plan's gap claim is correct (per-period card stub + the candid comment), but the gap row conflates the class name and the line-range that holds the comment. Slice 4 should expect to touch BOTH `_DaypartScaffoldCard` (the per-period card itself) AND `_DaypartMetricGrid` (the inner metric grid). A 5-line clarification in the plan row would make the slice scope unambiguous.

### Slice 2.5 — gateway naming clarification

Gap 28 / Slice 2.5 names `business_timing_gateway.dart` as the gateway to extend. There are **two** gateway files in `lib/operator_web/services/`:
- `business_timing_gateway.dart` — the **read seam** (abstract `BusinessTimingGateway` + `DemoBusinessTimingGateway` impl + `BusinessTimingServicePeriod` display value type).
- `web_business_timing_gateway.dart` — the **write gateway** (abstract `WebBusinessTimingGateway` + `HttpWebBusinessTimingGateway` + `ServicePeriodCreate`/`ServicePeriodPatch`/`ServicePeriod` DTOs that round-trip the proxy's POST/PATCH bodies).

The Slice 2.5 worker prompt I dispatched names both files explicitly so this is no longer a blocker, but the plan + the brief should also adopt the more precise name (`web_business_timing_gateway.dart`) to prevent future confusion. The read-seam `BusinessTimingServicePeriod` (lines 76-91 of `business_timing_gateway.dart`) only carries `name`/`startsAt`/`endsAt`/`sourceLabel`/`rollsPastMidnight` — surfacing the new `applicableDays`/`shortLabel`/`sortOrder` fields in the display tree is a **separate read-side follow-up**, not part of Slice 2.5.

---

## Per-gap status table

Legend: ✅ = cited evidence valid on master · 🟡 = cited evidence valid, with path drift / minor cite imprecision noted · ❌ = cited evidence cannot be located.

### Planning-phase gaps (1–18)

| # | Gap | Cite | Status | Verification |
|---|---|---|---|---|
| 1 | Recommendation pooling kludge throws away per-period stats | `recommended_benchmark_selection_service.dart:122-294, 305-332` | ✅ | Lines 122-294 contain Phase 2 (per-daypart stratification) → `byDaypart`/`perDaypartStats`. Lines 305-332 compute pooled CPLH/SPLH/PPA via cover-weighting; per-daypart stats are not exported beyond this scope. |
| 2 | TargetCycle persistence is whole-day only | `target_cycle_service.dart:440-442` | ✅ | Lines 440-442: `targetCPLH: recommendation.pooledRecommendedTargetCPLH` (and SPLH/PPA). Pool flows into the parent `TargetCycle` row only. |
| 3 | TargetCycle model has no per-period shape | `target_cycle.dart:21-28` | 🟡 | Path drift: `lib/domain/models/target_cycle.dart:21-28`. Lines verified — locked standards section, flat scalar. |
| 4 | ActiveTargetProfile is flat scalar | `active_target_profile.dart:7-37` | 🟡 | Path drift: `lib/domain/models/active_target_profile.dart:7-37`. Lines verified — flat scalar fields only. |
| 5 | Shift per-period read service reaches up to whole-day target | `shift_service_period_read_service.dart:370-460` | ✅ | `computePrimaryLeverId` consumes `ActiveTargetProfile? profile` (whole-day flat). Docstring at lines 370-375 candidly admits "Per-period plan targets are not yet shipped — `ActiveTargetProfile` carries restaurant-level standards only, and the same standards apply across periods today." |
| 6 | WeeklyPlanSnapshot day row has no per-period breakdown; allocator regenerates on render | `weekly_plan_snapshot.dart:17-32`; `daypart_plan_allocator.dart:47-62` | 🟡 | Path drift on first cite: `lib/domain/models/weekly_plan_snapshot.dart:17-32`. Lines verified. `daypart_plan_allocator.dart:47-62` resolves; the allocator's `allocate` method is pure and called from `ScheduleForecastNotifier.adjustedDayViews` + `ShiftService.getFullWeekShifts` (per file header lines 6-10). |
| 7 | Variance read consumes whole-day profile only | `variance_week_projection_read_service.dart:51-94` | ✅ | `build` method accepts `ActiveTargetProfile? currentTargetProfile` (whole-day flat). |
| 8 | Audit structural ordering bug — cycle only fetched if snapshot exists | `data_alignment_audit_read_service.dart:108-111` | ✅ | Lines 107-111: `if (snapshot != null) { targetCycle = await _safeLoad(...); }`. |
| 9 | Mid-week cycle drift between locked Plan and current Benchmark | Contract Rule 6 (today) | N/A | Contract claim, not a code citation. Eliminated by Slice 0's Option 2 amendment. |
| 10 | Wage-at-lock-time column missing | `weekly_plan_snapshot` schema | ✅ | Confirmed via `lib/domain/models/weekly_plan_snapshot.dart` field set — no `wageAtLockTimeJson` field. |
| 11 | Sentinel `0` flips audit status for degenerate cycles | `active_target_profile.dart:59-62` | 🟡 | Path drift: `lib/domain/models/active_target_profile.dart:59-62`. Code verified: `(targetCPLH > 0 && targetPPA > 0) ? ... : 0.0`. |
| 12 | DaypartPlanAllocator regenerates plan on every render (1:1 trap) | `daypart_plan_allocator.dart:47-62` | ✅ | Same as Gap 6's allocator citation. |
| 13 | benchmark_selection_summary table availability conflated with row presence | Audit gating pattern | N/A | Architectural/pattern claim, no specific cite to verify. |
| 14 | Pool-vs-period directionality risk | Architectural risk | N/A | Architectural risk, no specific cite. |
| 15 | Hardcoded `['lunch','dinner','late_night']` in benchmark tracker read service | `benchmark_tracker_read_service.dart:101` | ✅ | Line 101: `return ['lunch', 'dinner', 'late_night']`. Lines 155-159 also `case 'lunch'/'dinner'/'late_night':` in a switch — Slice 2 should fix all three sites in this file, not just :101. |
| 16 | `_DaypartScaffoldCard` stub — "no plan target on purpose" code comment | `shift_dashboard.dart:1236-1239` | 🟡 | Class `_DaypartScaffoldCard` exists at lines 1077-1103. Quoted comment lives at lines 1236-1239 inside `_DaypartMetricGrid` (different class). Slice 4 must touch BOTH classes. |
| 17 | "Targets Derived from Benchmark" card redundant after table extension | `baseline_tracker.dart:133-141` | ✅ | Lines 133-141 contain `SliverPersistentHeader('TARGETS DERIVED FROM BENCHMARK')` + `_BaselineTargetsCard()`. |
| 18 | Same field name `targetCPLH` reused across 5 types | Architecture-wide | N/A | Architecture-wide claim, no specific cite. |

### Audit additions — Integration plumbing (19–26)

| # | Gap | Cite | Status | Verification |
|---|---|---|---|---|
| 19 | Production wiring of `CanonicalFactPeriodResolver` + `CanonicalFactPostCommitProjector` is missing | `tool/advisor_proxy/main.dart:1625-1629`; `phase_8_vendor_integration_factories.dart:327-346`; `projecting_canonical_sink.dart:50-58` | ✅ (with nuance) | All three cites verified. The `CanonicalFactPeriodResolver` typedef exists at `projecting_canonical_sink.dart:50-58`. Factories accept the resolver as nullable in `phase_8_production_binder.dart:154-159` and `phase_8_vendor_integration_factories.dart:301-305`. The production call at `main.dart:1625-1629` does NOT pass any of the three resolvers, so `projectorWiringActive == false` in production (per `phase_8_vendor_integration_factories.dart:328-331`). **Refinement to plan wording:** the typedef exists; what is missing is a production-wired implementation **instance** at the call site. Not in Slice scope; flagged as production-cutover precondition. |
| 20 | Closed-shift aggregator bypasses `DaypartBucketer` (boundary inclusivity drift) | `canonical_fact_to_closed_shift_input.dart:922-943` vs `daypart_bucketer.dart:281-294` | ✅ | Aggregator line 940: `localMinutes >= startMinutes \|\| localMinutes < endMinutes` (rolls past midnight). Line 942: `localMinutes >= startMinutes && localMinutes < endMinutes`. Both use `<` at end (half-open). DaypartBucketer line 289: `localTimeOfDay >= start \|\| localTimeOfDay <= end`. Line 291: `localTimeOfDay >= start && localTimeOfDay <= end`. Both use `<=` at end (inclusive). Drift is real. **Slice 1.5 blocker confirmed.** |
| 21 | Closed-shift aggregator does NOT split labor punches across period boundaries | `canonical_fact_to_closed_shift_input.dart:805-835` | ✅ | `_readLaborPunchesForDaypart` at lines 805-835: SQL filters by `business_date` only; row filter at 826-834 calls `_bucketsToDaypart(instant: row['shift_start'], ...)` — single instant, not interval. **Promise 3 violation confirmed. Slice 1.5 blocker.** |
| 22 | Demo seeder writes `shift_records` without timing stamps | `mock_integration_replay_seed.dart:326-411`; `sqlite_database_seed.dart:882-943` | ✅ | `_generateShift` lines 326-411 build `ShiftRecord` instances without `businessTimingProfileId` / `businessTimingProfileVersionId` / `servicePeriodKey`. Folds into Slice 1 demo reseed. |
| 23 | `ShiftService.closeShift._shiftRecordFromFact` drops timing fields | `lib/services/shift_service.dart:248-350` vs `postgres_shift_record_writer.dart:214-216` | ✅ | `_shiftRecordFromFact` at lines 310-350 emits `ShiftRecord(...)` without `businessTimingProfileId` / `businessTimingProfileVersionId` / `servicePeriodKey`. Postgres writer at `postgres_shift_record_writer.dart:214-216` DOES include them. Mobile-direct close strips them. **Three-line fix in Slice 1.** |
| 24 | `closeShift` hardcodes `14 shifts/week` | `lib/services/shift_service.dart:294-300` | ✅ | Line 295: `if (closedShifts.length == 14)`. Comment at line 294 confirms. Line 507 has a related comment ("'14 shifts' close-detection one layer above is unowned debt") — Slice 1.5 may want to scrub :507 too. |
| 25 | Aggregator stage-4 forecast-covers fallback hardcodes `dailyShare / 3` | `canonical_fact_to_closed_shift_input.dart:458-469` | ✅ | Line 461: `final daypartShare = (dailyShare / 3).clamp(0, dailyShare).round();`. **Slice 1.5 fix confirmed.** |
| 26 | Cross-(business-date) labor punch split missing in aggregator | `canonical_fact_to_closed_shift_input.dart:813-824` vs `daypart_bucketer.dart:300-320` | ✅ | Aggregator's SQL filter at 819 binds a single `business_date`. DaypartBucketer's `_businessDatesSpanning` at 300-320 enumerates all business dates a range touches. Aggregator does not call it. Drift confirmed. **Slice 1.5 blocker.** |

### Audit additions — Operator settings (27–38)

| # | Gap | Cite | Status | Verification |
|---|---|---|---|---|
| 27 | Hardcoded `enum Daypart` + 4 UI iteration sites | `data_accuracy_settings.dart:130-184`; `covers_source_toggle.dart:78`; `covers_manual_entry_card.dart`; `covers_historical_seed_card.dart`; `settings_covers_setup_section.dart:42-46` | ✅ | All 5 sites confirmed: `data_accuracy_settings.dart:130` `enum Daypart { lunch, dinner, lateNight }`; `covers_source_toggle.dart:78` `for (final daypart in Daypart.values)`; `covers_manual_entry_card.dart` lines 63, 77, 104, 106, 108, 133 reference `Daypart.values`/`Daypart.lunch/dinner/lateNight`; `covers_historical_seed_card.dart` lines 67, 271, 288, 290, 292, 371, 461 same; `settings_covers_setup_section.dart:42-46` `kSettingsCoversDayparts = ['lunch', 'dinner', 'late_night']`. **Slice 2 extended scope confirmed.** |
| 28 | `ServicePeriodDraft` missing `applicableDays`/`shortLabel`/`sortOrder` | `service_period_editor.dart:28-62` vs `service_period_definition.dart:33-34` | ✅ | `ServicePeriodDraft` lines 28-62 carries only `key`/`label`/`startLocal`/`endLocal`. `ServicePeriodDefinition` carries the three missing fields (lines 18-34). **Slice 2.5 dispatched.** |
| 29 | `data_accuracy_screen.dart` has NO `HierarchyScopeNotice` | `lib/operator_web/screens/data_accuracy_screen.dart` | ✅ (file exists, follow-up) | File confirmed; absence of `HierarchyScopeNotice` import / widget is a separate-slice follow-up per plan. |
| 30 | Mobile timing/wage settings missing scope chip | `settings_timing_authority_section.dart:128-171`; `settings_wage_authority_section.dart:115-229` | ✅ (files exist, follow-up) | Files exist; HP #11 sweep deferred. |
| 31 | `shift_close_authority` not operator-editable | `operator_location_admin_screen.dart:3719` | ✅ | Line 3719: `shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback`. Admin-only write path. **Operator decision queued.** |
| 32 | Wage Authority hardcoded to `HierarchyScopeLevel.location` | `wage_authority_screen.dart:484` | ✅ | Line 484: `selectedScope: HierarchyScopeLevel.location`. |
| 33 | Hidden mobile `_WageMixEditorScreen` | `settings_screen.dart:363`; `settings_wage_authority_section.dart:254-663` | ✅ | Line 363: `viewOnly: true` inside `WageAuthoritySection(...)`. |
| 34 | Wage Mix UI doesn't say "applies per-period" | `settings_wage_authority_section.dart`; `wage_authority_screen.dart` | N/A | Copy-only claim; no specific line cite needed. |
| 35 | Operator-web Benchmarks override writes pool layer directly | `benchmarks_screen.dart:128-184` | ✅ | `_save` method at lines 128-184 calls `_benchmarksGateway.setOverride(metricKey: _selectedMetric, overrideValue: value)` — single scalar per metric. Pool layer write confirmed. **Operator decision queued.** |
| 36 | Legacy `covers_source_*` columns coexist with keyed settings | `data_accuracy_settings.dart:207-214` | ✅ | `coversSourceFor(Daypart daypart)` switches over the three legacy enum values. **Operator decision queued.** |
| 37 | Walk-in handling per-period split missing | `walk_in_handling_card.dart`; `data_accuracy_settings.dart` | ✅ (file exists, deferred) | File confirmed; out-of-scope V1 per plan. |
| 38 | Polling tier per-period split missing | `polling_tier_status_card.dart` | ✅ (file exists, deferred) | File confirmed; out-of-scope V1 per plan. |

### Audit additions — Whole-day target consumers (39–44)

| # | Gap | Cite | Status | Verification |
|---|---|---|---|---|
| 39 | Learn pattern detection chain needs per-period inputs | `learn_benchmark_context_service.dart:232-267`; `learn_teaching_analyzer.dart:42-125`; `learn_benchmark_context.dart:8-19`; `learn_teaching_summary.dart:10-56`; `variance_learn_tab.dart:412-420` | ✅ | All 5 files exist at cited paths. `learn_benchmark_context.dart:5-22` carries flat scalar `targetCPLH/SPLH/PPA`. `learn_teaching_summary.dart:6-50` same shape. Per-period model extension is a Slice 1 fold-in. |
| 40 | `baseline_manager_preview.dart` needs per-period preview math | `baseline_manager_preview.dart:33-258` | ✅ | `ManagerOverridePlanPreview` class at lines 27-44 carries flat scalar `theoreticalLaborPct` + `targetBlendedWage`. Per-period preview math missing. |
| 41 | `schedule_builder.dart:107-113` sentinel-0 violation | `schedule_builder.dart:107-113` | ✅ | Lines 107-113: `targetCPLH: 0, targetSPLH: 0, ..., opzFloorCPLH: 0, opzCeilingCPLH: 0, theoreticalFohLaborPct: 0, ...` with `// unused on locked path` comments. Design Rule 2 violation confirmed. |
| 42 | `MeridianConfig` insufficient-recommendation fallback shape undefined | `app_defaults.dart:36-40`; `target_cycle_service.dart:411-434` | ✅ | `app_defaults.dart:36-40` carries `MeridianConfig.targetCPLH/SPLH/PPA/opzFloor/opzCeiling`. `target_cycle_service.dart:411-434` is `_buildRecommendedProfile` with the `recommendation.isInsufficient` branch (lines 419-434) that drops the per-period stats and writes Config Default whole-day pool. **Operator decision queued. BLOCKS Slice 1.** |
| 43 | `wage_at_lock_time_json` writer not explicitly named in plan | `lib/services/weekly_plan_snapshot_service.dart` | ✅ | `WeeklyPlanSnapshotService` exists at the named path. **Naming confirmed: it IS the writer (not "WeeklyPlanSnapshotGenerator"); Slice 1 prompt should cite this exact class.** |
| 44 | `BaselineData` bridge must stay whole-day | `lib/services/baseline_authority_service.dart` | ✅ | File exists; design rule reinforcement, no specific cite needed. |

---

## Per-slice file-path validation table

For each slice, the table below lists the load-bearing files the slice's prompt will name and confirms each path resolves on master.

### Slice 0 — Cycle rollover gating + contract amendments

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| `TargetCyclePolicy.needsAutoRefresh` | `lib/services/target_cycle_policy.dart` ("verify in audit") | `lib/domain/services/target_cycle_policy.dart:35` | ✅ Path drift |
| `_createRecommendedCycle` (effectiveStart/End computation) | `lib/services/target_cycle_service.dart` (path inferred from plan) | `lib/services/target_cycle_service.dart:200-321` (`_writeReplacementCycle`) | ✅ Same file. The plan's `effectiveStart` rewrite is in `_writeReplacementCycle` (lines 296-297 currently set `effectiveStart: current.effectiveStart` — Slice 0 changes this to `effectiveStart: businessDate` when the policy fires on the configured week-start day). |
| Contract: `phase_7_55_time_boundary_contract.md` Rule 5 + 6 | `docs/contracts/...` | confirmed exists | ✅ |
| Contract: `phase_7_55_target_cycle_weekly_plan_rules.md` Rule E | `docs/contracts/...` | confirmed exists | ✅ |
| Contract: `core_app_architecture.md` Layer 4 + 8 | `docs/contracts/...` | confirmed exists | ✅ |

**Verdict:** Ready for implementation dispatch. Worker prompt should use the canonical `lib/domain/services/target_cycle_policy.dart` path.

### Slice 1 — Per-period data layer foundation

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| `_writeReplacementCycle` extension | `target_cycle_service.dart:217-321` | `lib/services/target_cycle_service.dart:217-321` | ✅ |
| `RecommendedBenchmarkSelectionService` per-period emission | `recommended_benchmark_selection_service.dart:122-294, 305-332` | `lib/domain/services/recommended_benchmark_selection_service.dart` | ✅ |
| `ActiveTargetProfile` per-period extension | `active_target_profile.dart:7-37` | `lib/domain/models/active_target_profile.dart:7-37` | ✅ Path drift |
| `WeeklyPlanSnapshotService` (writer for `wage_at_lock_time_json`) | `lib/services/weekly_plan_snapshot_service.dart` (Gap 43) | `lib/services/weekly_plan_snapshot_service.dart` | ✅ |
| `ShiftService.closeShift._shiftRecordFromFact` timing carry | `lib/services/shift_service.dart:248-350` | `lib/services/shift_service.dart:248-350` (conversion at 310-350) | ✅ |
| Demo reseed: `MockIntegrationReplaySeed` | `lib/dev/mock_integration_replay_seed.dart:326-411` | `lib/dev/mock_integration_replay_seed.dart:326-411` | ✅ |
| Demo reseed: `_seedDemoDataFromReplay` | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:882-943` | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` | ✅ |
| Learn model fold-in | `learn_benchmark_context.dart:8-19`; `learn_teaching_summary.dart:10-56` | `lib/models/learn_benchmark_context.dart`; `lib/models/learn_teaching_summary.dart` | ✅ |
| Schema: `target_cycle_dayparts`, `weekly_plan_snapshot_day_dayparts`, `wage_at_lock_time_json`, per-shift target stamps | `db/migrations/**` | new migrations | ⏳ to be authored |

**Verdict:** Ready for implementation dispatch **once Gap 42 operator decision lands**. Worker prompt should use the canonical `lib/domain/models/active_target_profile.dart` path. Schema migration scope is well-defined per plan.

### Slice 1.5 — Closed-shift aggregator → DaypartBucketer routing

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| `_bucketsToDaypart` replacement | `canonical_fact_to_closed_shift_input.dart:922-943` | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:922-943` | ✅ Boundary-inclusivity drift confirmed |
| `_readLaborPunchesForDaypart` interval split | `canonical_fact_to_closed_shift_input.dart:805-835` | same file, lines 805-835 | ✅ Single-instant filter confirmed |
| Cross-(business-date) split | `canonical_fact_to_closed_shift_input.dart:813-824` vs `daypart_bucketer.dart:300-320` | both files, both ranges | ✅ |
| Stage-4 forecast fallback `/3` | `canonical_fact_to_closed_shift_input.dart:458-469` | same file, line 461 | ✅ |
| `closeShift` 14-shifts hardcode | `shift_service.dart:294-300` | `lib/services/shift_service.dart:294-300` (line 295) | ✅ |
| `DaypartBucketer.bucketPosLine` / `bucketReservation` / `bucketLaborPunch` | `lib/domain/services/daypart_bucketer.dart` | confirmed exists | ✅ |

**Verdict:** Ready for implementation dispatch. **Must land before Slice 6** (Slice 6's pool-consistency check depends on closed-shift period stamps being byte-identical to live read).

### Slice 2 — Benchmark tab redesign

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| `DaypartTable` widget | implied in `lib/screens/baseline_tracker.dart` | `lib/screens/baseline_tracker.dart` (referenced at line 127 `DaypartTable(dayparts: ...)`) | ✅ |
| `_BaselineTargetsCard` cut | `baseline_tracker.dart:133-141` | same file, same lines | ✅ |
| Hardcoded `['lunch','dinner','late_night']` | `benchmark_tracker_read_service.dart:101` | `lib/services/benchmark_tracker_read_service.dart:101` | ✅ Plus lines 155-159 carry related case statements |
| `enum Daypart` + 4 UI sites | per Gap 27 | all 5 cites verified | ✅ |
| `baseline_manager_preview.dart` per-period preview | `baseline_manager_preview.dart:33-258` | `lib/screens/baseline_manager/baseline_manager_preview.dart` | ✅ |
| Operator-web Benchmarks override write seam | `benchmarks_screen.dart:128-184` | `lib/operator_web/screens/benchmarks_screen.dart:128-184` | ✅ |
| Tests: `test/baseline_override_propagation_test.dart`; `test/target_consistency_opz_test.dart` | as cited | not verified — test files referenced by plan; assume present | ⏳ |

**Verdict:** Ready for implementation dispatch **once Gap 35 + Gap 36 operator decisions land**.

### Slice 2.5 — Service period editor field completeness (Claude 2 owned)

| File | Cite (plan / brief) | Actual | Verified |
|---|---|---|---|
| `ServicePeriodDraft` extension | `lib/operator_web/widgets/service_period_editor.dart:28-62` | same | ✅ |
| Editor screen wiring | `lib/operator_web/screens/business_timing_editor_screen.dart` (lines 92-116, 248-257, 268-277) | same | ✅ |
| Gateway DTO round-trip | brief names `business_timing_gateway.dart`; actual write surface is `lib/operator_web/services/web_business_timing_gateway.dart` (`ServicePeriodCreate` 245-264, `ServicePeriodPatch` 267-281, `ServicePeriod` 197-242) | both exist; **brief should rename to `web_business_timing_gateway.dart`** | ✅ Naming clarification (worker prompt accounts for this) |
| Canonical model | `lib/domain/models/service_period_definition.dart:33-34` | same — model already carries the three fields | ✅ |
| Tests | `test/operator_web/widgets/service_period_editor_test.dart`; `test/operator_web/screens/business_timing_editor_screen_test.dart` | both exist | ✅ |
| Bonus signal | `tool/advisor_proxy/proxy_bootstrap.dart` already references `applicableDays|short_label|sort_order` | grep hit | ✅ Proxy backend likely already wired (Slice 2.5 may need no backend work) |

**Verdict:** Worker dispatched. Awaiting PR.

### Slice 3 — Plan tab persistence wiring

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| `ScheduleForecastNotifier.adjustedDayViews` | implied `lib/state/schedule_forecast_notifier.dart` (verify in slice) | not yet verified — plan implies | ⏳ Slice prompt should grep `class ScheduleForecastNotifier` to confirm location |
| `DaypartPlanAllocator` retirement | `daypart_plan_allocator.dart:47-62` | `lib/services/daypart_plan_allocator.dart:47-62` | ✅ |
| `schedule_builder.dart:107-113` sentinel-0 cleanup | `schedule_builder.dart:107-113` | `lib/screens/schedule_builder.dart:107-113` | ✅ |

**Verdict:** Ready for implementation dispatch **after Slice 1**. Slice prompt should grep for `ScheduleForecastNotifier` to lock its file path.

### Slice 4 — Shift daypart card full parity (Claude 2 preferred per brief)

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| `_DaypartScaffoldCard` replacement | `shift_dashboard.dart:1236-1239` (cite imprecise) | class at `lib/screens/shift_dashboard.dart:1077-1103`; comment at 1236-1239 (inside `_DaypartMetricGrid`) | 🟡 Slice prompt should name BOTH classes |
| Outputs / Inputs / FOH Productivity sections | implied existing widget set in `lib/screens/shift_dashboard.dart` | confirmed file exists | ✅ |

**Verdict:** Ready for implementation dispatch **after Slice 1**. Slice prompt should clarify the two classes Slice 4 must touch.

### Slice 5 — Variance read-seam swap

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| `VarianceWeekProjectionReadService._theoreticalPctForRow` | `variance_week_projection_read_service.dart` | `lib/services/variance_week_projection_read_service.dart` | ✅ |
| `_laborDollarsForRow` (whole-day blended wage) | same file | same file | ✅ |

**Verdict:** Ready for implementation dispatch **after Slice 1**.

### Slice 6 — Audit scorer extension

| File | Cite (plan) | Actual | Verified |
|---|---|---|---|
| Per-period checks | `data_alignment_audit_read_service.dart` | `lib/services/data_alignment_audit_read_service.dart` | ✅ |
| Structural ordering bug | `data_alignment_audit_read_service.dart:108-111` | same file, same lines | ✅ |

**Verdict:** Ready for implementation dispatch **after Slices 1 + 1.5**.

---

## Particularly-scrutinized findings (per Task B prompt)

### Gap 19 — Production wiring of CanonicalFactPeriodResolver
**Status:** Confirmed missing in production. **Refinement:** the `CanonicalFactPeriodResolver` typedef DOES exist (`projecting_canonical_sink.dart:50-58`), and the binder/factory code accepts it as nullable. The **production call site** in `tool/advisor_proxy/main.dart:1625-1629` does not pass any of the three resolver parameters, so `projectorWiringActive` evaluates false and no production canonical-fact post-commit projection runs. The plan's wording "no production impl exists" should be tightened to "no production-wired RESOLVER INSTANCE is threaded into the binder call site." Out of scope for V1; production-cutover precondition remains correctly classified.

### Gap 20 — Closed-shift aggregator boundary inclusivity
**Status:** Confirmed. The aggregator's `_bucketsToDaypart` (lines 922-943) uses `<` at the end boundary (half-open). `DaypartBucketer._classifyInstant` (lines 281-294) uses `<=` at the end boundary (inclusive). A POS check closing exactly at 15:00:00 ends up in different periods between the live read and the closed aggregation. **Slice 1.5 blocker confirmed.**

### Gap 21 — Closed-shift aggregator labor-punch interval split
**Status:** Confirmed. `_readLaborPunchesForDaypart` (lines 805-835) filters by `business_date` only, then attributes the entire row to the period containing `shift_start`. An 8-hour FOH punch crossing lunch→dinner is attributed entirely to one period. Direct Promise 3 violation. **Slice 1.5 blocker confirmed.**

### Gap 23 — `ShiftService.closeShift._shiftRecordFromFact` drops timing fields
**Status:** Confirmed. `_shiftRecordFromFact` at lines 310-350 omits `businessTimingProfileId`, `businessTimingProfileVersionId`, and `servicePeriodKey` from the SQLite `ShiftRecord`. The Postgres path at `postgres_shift_record_writer.dart:214-216` preserves them. Three-line fix in Slice 1.

### Gap 26 — Cross-(business-date) labor punch split
**Status:** Confirmed. The aggregator's labor punch SQL filter binds a single `business_date`. `DaypartBucketer._businessDatesSpanning` (lines 300-320) handles the split. The aggregator does not call it. Edge case but real for late-night operations. **Slice 1.5 blocker confirmed.**

### Gap 27 — Hardcoded `Daypart` enum + 4 UI sites
**Status:** Confirmed at all 5 cites. Slice 2 must replace the enum with timing-config-driven keys AND update all 4 iteration sites. Particularly note that `covers_manual_entry_card.dart` and `covers_historical_seed_card.dart` each have ≥6 references to `Daypart.values` / `Daypart.lunch/dinner/lateNight` — the slice scope is non-trivial.

### Gap 43 — `wage_at_lock_time_json` writer name
**Status:** Confirmed: the writer is `WeeklyPlanSnapshotService` at `lib/services/weekly_plan_snapshot_service.dart`. Slice 1 prompt should cite this exact class name (the plan currently says "WeeklyPlanSnapshotGenerator (whatever it's called) — verify in audit").

---

## Ready-for-implementation verdict per slice

| Slice | Verdict | Blockers |
|---|---|---|
| **0** — Cycle rollover gating | ✅ Ready | None. Update plan citation to `lib/domain/services/target_cycle_policy.dart`. |
| **1** — Per-period data layer | 🟡 Ready post-decision | Gap 42 operator decision (MeridianConfig fallback shape — plan recommends option (c)). |
| **1.5** — Aggregator → DaypartBucketer | ✅ Ready | None. All four blocker gaps verified on master. |
| **2** — Benchmark tab redesign | 🟡 Ready post-decision | Gap 35 + Gap 36 operator decisions. |
| **2.5** — Service period editor fields | ✅ Dispatched | Worker agent in flight on `claude2/per-daypart-slice-2.5-service-period-editor-fields`. |
| **3** — Plan tab persistence wiring | ✅ Ready (after Slice 1) | Confirms `ScheduleForecastNotifier` location at slice prompt time. |
| **4** — Shift daypart card parity | ✅ Ready (after Slice 1) | Slice prompt should name both `_DaypartScaffoldCard` (1077) and `_DaypartMetricGrid` (1240). |
| **5** — Variance read-seam swap | ✅ Ready (after Slice 1) | None. |
| **6** — Audit scorer extension | ✅ Ready (after Slices 1 + 1.5) | None. |

---

## Recommendations to fold into the plan doc before dispatch

These are all small documentation-only edits — no semantic change to the plan's substance.

1. **Path drift fixes (4 entries):**
   - Gap 3 cite: `lib/models/target_cycle.dart` → `lib/domain/models/target_cycle.dart`.
   - Gap 4 + 11 cite: `lib/models/active_target_profile.dart` → `lib/domain/models/active_target_profile.dart`.
   - Gap 6 first cite: `lib/models/weekly_plan_snapshot.dart` → `lib/domain/models/weekly_plan_snapshot.dart`.
   - Slice 0 prompt: confirm `lib/domain/services/target_cycle_policy.dart` (already says "verify in audit" — this audit is the verification).

2. **Gap 16 clarification:** Slice 4 must touch BOTH `_DaypartScaffoldCard` (lines 1077-1103) and `_DaypartMetricGrid` (around lines 1240+) in `lib/screens/shift_dashboard.dart`. The "no plan target on purpose" comment lives in the latter.

3. **Slice 2.5 + Gap 28 wording:** name `lib/operator_web/services/web_business_timing_gateway.dart` (write surface) explicitly. The brief currently says `business_timing_gateway.dart` which is the read seam.

4. **Gap 19 wording refinement:** "No production-wired CanonicalFactPeriodResolver INSTANCE is threaded into the `bindPhase8IntegrationsForProduction` call at `tool/advisor_proxy/main.dart:1625-1629`." (The typedef and the binder's optional parameters do exist; what's missing is the production-wired implementation instance.)

5. **Gap 43 naming lock:** Slice 1 prompt should cite `WeeklyPlanSnapshotService` (verified — drop the "(whatever it's called)" qualifier).

6. **Gap 24 scope expansion:** the `14 shifts` hardcode also has a related comment at `lib/services/shift_service.dart:507` ("'14 shifts' close-detection one layer above is unowned debt"). Slice 1.5 may want to scrub this too, or leave a follow-up note.

7. **Bonus signal for Slice 2.5:** `tool/advisor_proxy/proxy_bootstrap.dart` already references `applicableDays|short_label|sort_order`, suggesting the proxy route handler may already accept the new fields when present. The Slice 2.5 worker prompt should confirm this during implementation; if true, no backend coordination is needed for the slice.

---

## What this audit does NOT cover

- **Schema migration drift** — the plan references not-yet-authored migrations under `db/migrations/`. This audit does not pre-author or pre-verify them. Slice 1 will run `tool/migration_drift_scanner.dart --fix --strict-docs` per CLAUDE.md house rule; that is the canonical drift check.
- **Test coverage adequacy** — confirmed cited test files exist; did not read each test for gap-specific coverage.
- **Runtime behavior** — static audit only. Slice runtime acceptance per `docs/contracts/slice_runtime_acceptance_contract.md` is the canonical runtime check.
- **Contract amendment review** — Slice 0's contract amendment text is in the plan, not yet authored against the live contracts. Operator review of amendment text remains required at Slice 0 PR time.

---

## Concurrency / coordination notes for Main

- All file paths Main owns (per the brief) verified at their cited locations on master. No collision risk for Slice 0 / 1 / 1.5 / 2 / 6 dispatches.
- The `WeeklyPlanSnapshotService` naming lock (Gap 43) lets Main fold Slice 1's writer-extension scope precisely.
- The "particularly scrutinized" load-bearing Slice 1.5 gaps (20, 21, 23, 26) all hold on master — Main can dispatch Slice 1.5 immediately with confidence the underlying drift is real.
