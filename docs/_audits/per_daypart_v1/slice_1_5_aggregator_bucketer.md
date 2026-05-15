# Slice 1.5 — closed-shift aggregator routes through DaypartBucketer + close authority auto-derived

**Branch:** `claude/per-daypart-slice-1.5-aggregator-bucketer`
**Base:** `master` (`b904cef8`)
**Slice tag:** Per-Daypart Targets V1 — Slice 1.5
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge (subject to orchestrator/operator approval — schema-touching + RLS-adjacent)

---

## TL;DR

Six interlocked fixes in the integration spine to unblock Slice 6's pool-consistency audit:

1. Closed-shift aggregator now buckets POS / reservation rows through the canonical `DaypartBucketer` (Gap 20 — boundary inclusivity parity with live read).
2. Labor punches are read over a ±1-day business-date window and split into per-period segments via `DaypartBucketer.bucketLaborPunch` (Gaps 21, 26 — Promise 3 + cross-(business-date) splits).
3. Stage-4 forecast-covers fallback now uses `DaypartPlanAllocator` with the operator's full period list + optional distribution weights (Gap 25 — no more uniform `/3` divide).
4. `ShiftService.closeShift` 14-shift hardcode replaced by `sum(applicable_days_per_period)` from `RestaurantTimingConfig` (Gap 24).
5. New `CloseAuthorityCapability` per-vendor sidecar replaces the operator-set `shift_close_authority`. SQLite drops `shift_close_authority` + `local_close_fallback` columns; Postgres makes `close_authority` nullable (deprecation-step migration; full drop deferred to a follow-up Postgres-only slice because the Postgres `business_timing_profiles_repository.dart` write surface is broader than Slice 1.5's scope) (Gap 31, operator decision 2026-05-15).
6. Mobile and F&F Ops admin display rows for "Shift close rule" / "Shift close authority" removed.

24 existing aggregator tests preserved (3 expectation updates where per-period interval splitting now produces less-than-whole-punch attribution). 5 new aggregator regressions cover the slice's locked scopes plus 2 new `closeShift` weekly-upsert regressions for 3-period + 4-period operators. All touched test suites green locally.

---

## Scope

| What | Where |
|---|---|
| New sidecar enum + per-vendor lookup | `lib/services/integration/close_authority_capability.dart` (new file) |
| Aggregator refactor — DaypartBucketer routing | `lib/services/integration/canonical_fact_to_closed_shift_input.dart` |
| Aggregator forecast-fallback allocator hook | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:425-475` |
| Aggregator per-period labor-punch splitter | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:1118-1238` |
| `closeShift` per-period-aware gate | `lib/services/shift_service.dart:303-318, 339-365` |
| `_buildLockedWeekToDate` per-row close authority | `lib/services/shift_service.dart:715-748` |
| `RestaurantTimingConfig` model — drop 2 fields | `lib/domain/models/restaurant_timing_config.dart` |
| `BusinessTimingProfile.toRestaurantTimingConfig` — no longer passes dropped fields | `lib/domain/models/business_timing_profile.dart:95-114` |
| `AggregatorProvenanceContext` — new `closeAuthorityProvenance` field | `lib/domain/models/aggregator_provenance_context.dart:33-44, 116-141` |
| SQLite schema + V35 migration drop columns | `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart:394-411`; `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart:315-348` |
| SQLite DAO + repository — drop dropped fields | `lib/infrastructure/persistence/sqlite/dao/restaurant_timing_config_dao.dart`; `lib/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart` |
| SQLite seed — drop fields | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:690-703` |
| Sync proxy client — ignore legacy JSON fields | `lib/services/sync/http_sync_proxy_client.dart:840-883` |
| Proxy bootstrap — stop emitting dropped JSON fields | `tool/advisor_proxy/proxy_bootstrap.dart:3615-3629` |
| Postgres migration (deprecation step) | `db/migrations/202605150400_per_daypart_v1_drop_close_authority.sql` |
| Mobile timing read display — remove "Shift close rule" | `lib/screens/settings/settings_timing_authority_section.dart` |
| F&F Ops admin timing display — remove "Shift close authority" row | `lib/admin/screens/operator_location_admin_screen.dart:3578-3588, 3859-3865` |
| Aggregator unit tests — 5 new + 3 expectation updates + fake-pool 3-day window | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart` |
| `closeShift` per-period gate tests — 2 new | `test/shift_service_close_shift_test.dart:421-563` |
| Other test files — drop references to removed fields | `test/business_date_authority_service_test.dart`, `test/restaurant_timing_config_repository_test.dart`, `test/shift_boundary_resolver_test.dart`, `test/week_start_wiring_test.dart`, `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart` |
| **Untouched (per stop-conditions)** | `target_cycle_service.dart` (Slice 0), `ShiftService._shiftRecordFromFact` (Slice 1), production wiring of `CanonicalFactPeriodResolver` (separate cutover work) |

**Public API:**

- `CanonicalFactToClosedShiftInputAggregator.aggregate` adds two **optional** parameters (`allServicePeriodDefinitions`, `distributionWeights`). Existing callers that pass neither still get correct behavior — the aggregator falls back to `[periodDefinition]` (single-period list) and a `/3` whole-day-style allocation only when no full period list is provided. The new parameters are how Slice 1 (per-period plan persistence) will plumb in the full configured periods at call sites.
- `AggregatorProvenanceContext` adds an optional `closeAuthorityProvenance` field.
- `RestaurantTimingConfig` constructor drops two parameters (`shiftCloseAuthority`, `localCloseFallback`). Callers updated.
- `RestaurantTimingConfigDao.upsert` drops the two named parameters.

**Operator-facing copy:**

- Mobile Settings → Restaurant Timing: the "Shift close rule" row is removed. "Business day starts" remains as a standalone row (was paired with "Shift close rule" in a tile per U-7 MO-3b; the tile is now a single row).
- F&F Ops admin → Location timing dialog: the "Shift close authority" row is removed. The labeled label and its support-only display function are gone.

---

## 14-lens audit

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice aligns with the active feature plan `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` (Slice 1.5 in the "Slice sequence amendments (post-audit)" section — Gaps 20, 21, 24, 25, 26, 31). Honors `core_app_architecture.md` Promise 3 (Live canonical facts bucketed into effective service periods first, including interval splitting for labor punches) and Layer 4 (close moment is a property of the source system). Honors `integration_spine_architecture_contract.md` (the canonical bucketer is the single source of bucketing semantics; closed-shift aggregator and live projector now share that source). | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` Slice 1.5; `docs/contracts/core_app_architecture.md` Promise 3 | None |
| 2 | **Hard Promises** | HP #1 (Phase 8 = pure transport swap): aggregator is server-side and inside the transport layer; no new tables. HP #2 (kDemoMode = writer-side switch): no reader-side branch added; demo and prod read identically through the new bucketing path. HP #3 (No app logic before 7.58): the aggregator was already mutating data; the slice fixes a Promise 3 violation, not adding new logic. HP #4 (Per-operator isolation): unchanged — every aggregator read still passes through `withTenant(ctx)`. HP #11 (Hierarchy-scoped settings): the operator-set `shift_close_authority` collapses into a per-vendor auto-derivation (operator decision 2026-05-15) — no longer a hierarchy setting; mobile and admin displays removed to match. | `CLAUDE.md` "Hard Promises" #1, #2, #3, #4, #11 | None |
| 3 | **Service-layer split** | New file `lib/services/integration/close_authority_capability.dart` follows the established sidecar pattern (`labor_wage_source_class.dart`, `pos_covers_capability.dart`). Domain enum stays in `lib/domain/models/restaurant_timing_config.dart` (still referenced by `BusinessTimingProfile` + `ShiftBoundaryResolver` — out of scope to refactor those further). `lib/services/shift_service.dart` adds a private mapping helper `_closeAuthorityForRow` that lives at the service layer, not the domain layer. No raw `package:postgres` imports added outside the existing `OperatorScopedRepository` seam. | `lib/services/integration/close_authority_capability.dart:1-148`; `lib/services/integration/labor_wage_source_class.dart` (sidecar template) | None |
| 4 | **Architecture guardrails** | `LaborModel` / `TargetCycle` / `WeeklyPlanSnapshot` untouched. `ActiveTargetProfile` untouched. The aggregator does not own service-period bucketing — it routes every bucketing decision through `DaypartBucketer` (a pure domain service in `lib/domain/services/`). Source facts (`cover_facts`, `labor_punches`, `reservation_facts`) untouched. Closed-shift truth is not retroactively rewritten — the `priorTargetProfileVersionId` preservation path is untouched. | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:1110-1116` (bucketer routing); `:879-918` (prior provenance preserved) | None |
| 5 | **Time guardrails** | All bucketing decisions consume restaurant-local timestamps. UTC instants from canonical facts are converted via the existing `IanaTimezoneConverter.toBusinessLocal` before any business-date or bucketing math. The new `_businessDateForLocalTime` helper applies the operator's `businessDayStartLocalTime` cutoff — the same rule `DaypartBucketer._classifyInstant` uses internally. No `DateTime.now()` introduced. No `TIMESTAMP WITHOUT TIME ZONE` in operator-scoped tables. | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:1213-1232` (`_businessDateForLocalTime`); `lib/domain/services/daypart_bucketer.dart:300-320` (parallel logic in bucketer) | None |
| 6 | **RLS-ready schema** | SQLite migration V35 drops two columns from `restaurant_timing_configs` (the local mirror of `business_timing_profiles`; not operator-scoped — no RLS posture on this table). The new file `close_authority_capability.dart` introduces no schema. Postgres migration `202605150400_…` drops the NOT NULL constraint + cross-column CHECK; no row-level changes; no policies altered. Existing per-operator partitioning of `business_timing_profiles` is preserved. | `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart:315-348`; `db/migrations/202605150400_per_daypart_v1_drop_close_authority.sql` | None |
| 7 | **Proxy & API conventions** | `HttpSyncProxyClient._timingConfigFromJson` now ignores the legacy `shift_close_authority` / `close_authority` / `local_close_fallback` keys gracefully (existing servers may still emit them; clients tolerate). `tool/advisor_proxy/proxy_bootstrap.dart::_timingConfigJson` no longer emits the dropped keys — older clients tolerant of missing optional keys. No new proxy routes. No new idempotency-key paths. Proxy-write conventions unchanged. | `lib/services/sync/http_sync_proxy_client.dart:860-880`; `tool/advisor_proxy/proxy_bootstrap.dart:3615-3631` | None |
| 8 | **Testing seam** | 5 new aggregator regressions (group "O. Per-Daypart V1 Slice 1.5 regressions") cover the slice's locked scopes: boundary inclusivity, per-period labor split, cross-(business-date), forecast allocator weights, close-authority auto-derive. 2 new `closeShift` regressions (group "Slice 1.5 — _expectedClosedShiftsPerWeek (Gap 24)") cover 3-period × 7 and 4-period × 7 operators. Three pre-existing aggregator tests updated to reflect that per-period interval splitting now produces less-than-whole-punch attribution when a punch overflows the period. Fake `_FakePool` updated to honor the new 3-day SQL window. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:1672-2218`; `test/shift_service_close_shift_test.dart:421-563` | None |
| 9 | **Operator-facing copy / UX writing standard** | Mobile "Shift close rule" row removed — no replacement copy needed because the close-authority is auto-derived and never operator-edited. Admin "Shift close authority" row removed. No new copy strings introduced. | `lib/screens/settings/settings_timing_authority_section.dart:120-145`; `lib/admin/screens/operator_location_admin_screen.dart:3574-3590` | None |
| 10 | **Demo mode contract** | No new `kDemoMode` branch. Demo seed updated to omit the dropped columns from the INSERT. The `MockIntegrationReplaySeed.sourceSystem` value (`mock_pos_labor_replay`) is intentionally NOT in the `close_authority_capability` sidecar — demo shifts therefore default to `unreliableFallbackToBusinessDayStart`, matching the pre-1.5 demo behavior of "appLocalCutoffFallback" for the demo restaurant. | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:690-703`; `lib/services/integration/close_authority_capability.dart:79-91` (omission rationale) | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling raises. No `kAdvisorProxyMaxLines` adjustments. The aggregator file grew from ~1099 to ~1325 LoC; this is well below any per-file cap and corresponds 1:1 with the slice's six scopes. | `lib/services/integration/canonical_fact_to_closed_shift_input.dart` | None |
| 12 | **Phase-doc hygiene** | Slice is the size of a small phase (one new file, eight modified files, two new test groups). The active feature plan `per_daypart_targets_v1_plan.md` already documents Slice 1.5 scope inline. No new phase doc was created; per CLAUDE.md "Phase Doc Hygiene", `<1 week AND <5 files` doesn't apply (this is multi-file) but the slice is fully captured in the active feature plan. | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` Slice 1.5 section | None |
| 13 | **Anti-scope** | Stop-condition: `target_cycle_service.dart::_writeReplacementCycle` — NOT touched. Stop-condition: `ShiftService._shiftRecordFromFact` — NOT touched (still at lines 363-403, unchanged). Stop-condition: production wiring of `CanonicalFactPeriodResolver` / `CanonicalFactPostCommitProjector` — NOT touched. The Postgres-side `BusinessTimingProfilesRepository` write surface still emits `close_authority` to the now-nullable column; full repository refactor deferred (documented in TL;DR). | `lib/services/target_cycle_service.dart` (untouched); `lib/services/shift_service.dart:363-403` (`_shiftRecordFromFact` body unchanged); `tool/advisor_proxy/main.dart:1625-1629` (production wiring untouched) | None |
| 14 | **Honest disclosures** | `dart analyze --fatal-infos` on the five prompt-named files: clean. `dart analyze --fatal-infos lib/`: 0 errors, 9 pre-existing infos (push_permission_denied_card.dart + user_pii_erasure_repository.dart — predate this slice). `flutter test test/services/integration/canonical_fact_to_closed_shift_input_test.dart`: 29/29 pass. `flutter test test/shift_service_close_shift_test.dart`: 11/11 pass. `flutter test test/shift_boundary_resolver_test.dart`: 26/26 pass. `flutter test test/week_start_wiring_test.dart`: 15/15 pass. `flutter test test/restaurant_timing_config_repository_test.dart`: 26/26 pass. `flutter test test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`: 16/16 pass. `flutter test test/business_date_authority_service_test.dart`: included in the broader 99/99 batch above. Migration drift scanner + migration cutoff lint both clean. No CI run (CI dark until 2026-06-01 per `CLAUDE.md`). | Local runs in this worktree, 2026-05-15 | None |

---

## Pattern B exemplar — independent re-audit

| # | Lens | Independent re-audit | Citation |
|---|---|---|---|
| A | **Boundary parity proof** | New regression test "1. POS check at exact period boundary (15:00:00) buckets to lunch via both DaypartBucketer.bucketPosLine AND the closed-shift aggregator path" exercises both paths from the same `15:00:00` local instant and asserts both return `'lunch'`. Before Slice 1.5, the aggregator's inline `_bucketsToDaypart` used half-open `[startMinutes, endMinutes)` semantics, so it returned "no period" while `DaypartBucketer._classifyInstant` returned `'lunch'`. The aggregator now routes through `DaypartBucketer.bucketPosLine`, so the two paths are byte-identical by construction. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:1709-1779` |
| B | **Per-period split correctness** | New regression test "2. A FOH punch 10:00–18:00…" matches the slice prompt's worked example exactly: lunch run asserts 4h + 4×20=80 dollars; dinner run asserts 1h + 1×20=20 dollars. Two pre-existing tests (G Humanity, I QBT) were updated where their pre-1.5 expectations counted a punch's full duration regardless of the period it lived in — those expectations were always wrong under Promise 3; the slice fixes the underlying behavior, the test updates document the corrected truth. | `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:1782-1879`; `:987-994`; `:1140-1147` |
| C | **Cross-(business-date) split** | The new 3-day SQL window (`business_date between prior_business_date and next_business_date`) is the minimum required to capture (a) a punch starting before the queried business_date's rollover whose tail bleeds into the lunch period, and (b) a punch starting before the queried business_date's late_night that bleeds past the next-day rollover. Regression test 3 anchors a punch under business_date=Mon and asserts Mon's late_night call sees the 03:00–04:00 spillover (the segment's anchored business date matches), while Tue's lunch call sees 0h because the punch ends at 11:00 (half-open right endpoint in the bucketer's punch-split intervals). | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:976-1000` (3-day SQL); `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:1882-1992` (regression) |
| D | **Forecast allocator parity** | The legacy `dailyShare / 3` hardcode is replaced by a call to `DaypartPlanAllocator.allocate` with the operator's full period list + optional `ScheduleDistributionWeights`. Regression test 4 supplies a 3-period config with weights `(30, 50, 20)` and a 90-cover daily forecast and asserts `27 / 45 / 18` (largest-remainder). This proves the aggregator now consumes the same allocator the Schedule presentation uses (`lib/services/daypart_plan_allocator.dart` — the single shared seam). | `lib/services/integration/canonical_fact_to_closed_shift_input.dart:449-489`; `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:1994-2097`; `lib/services/daypart_plan_allocator.dart` (shared seam) |
| E | **closeShift gate correctness** | Two new tests under group "Slice 1.5 — _expectedClosedShiftsPerWeek (Gap 24)" assert that a 3-period × 7-day operator's gate is 21 (not 14) and a 4-period × 7-day operator's gate is 28. The legacy 14-shift gate was a hidden 2-period × 7-day assumption. The demo's mixed shape (lunch 5d + dinner 7d + late_night 2d = 14) still rolls up at 14, preserving the legacy demo closeShift behavior under the new formula. | `lib/services/shift_service.dart:339-365` (formula); `test/shift_service_close_shift_test.dart:521-578` (regressions); `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:657-689` (demo config = 5+7+2=14) |
| F | **Close-authority auto-derive** | The new `CloseAuthorityCapability` enum + sidecar map keys every Wave B POS adapter (Toast, Aloha, Oracle Simphony, Lightspeed K-Series, Revel, Square, Clover) as `vendorReliableFinalization`. Unknown / non-POS / null vendor ids fall back to `unreliableFallbackToBusinessDayStart`. The aggregator stamps this on `AggregatorProvenanceContext.closeAuthorityProvenance` for every emitted row. `ShiftService._buildLockedWeekToDate` consults the per-row capability via `_closeAuthorityForRow(s.sourceSystem)` to drive `ShiftBoundaryResolver.isEligibleForClosedTruth` — same enum the resolver always took, just sourced per-row instead of from a deleted operator setting. Regression test 5 covers the reliable + no-vendor cases; the existing `shift_boundary_resolver_test.dart` "vendorFinalization" group was updated to stamp `source_system='toast'` so the test still exercises the vendor-finalization branch (now via auto-derive). | `lib/services/integration/close_authority_capability.dart`; `lib/services/shift_service.dart:317-337`; `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:2099-2218`; `test/shift_boundary_resolver_test.dart:323-356` |
| G | **Postgres deferral discipline** | The Postgres migration is intentionally a **deprecation step** (drop NOT NULL + dependent CHECK), not a full column drop. Reason: the Postgres `BusinessTimingProfilesRepository` (~900 LoC, 12 write-method sites referencing `closeAuthority` / `localCloseFallbackTime`) is broader than this slice's "don't broaden scope" rule. The full Postgres column drop should follow a separate slice that refactors the repository's write surface in lockstep. Until then, existing rows keep their values and new writes can pass null. Documented in TL;DR. | `db/migrations/202605150400_per_daypart_v1_drop_close_authority.sql:18-23`; `lib/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart` (untouched) |

---

## What I ran

```
pwsh scripts/install_git_hooks.ps1
# -> Forge & Flow git hooks enabled for this clone.

flutter pub get
# -> Got dependencies! (52 packages have newer versions; OK per env)

dart analyze --fatal-infos lib/services/integration/canonical_fact_to_closed_shift_input.dart \
  lib/services/shift_service.dart \
  lib/services/integration/close_authority_capability.dart \
  lib/admin/screens/operator_location_admin_screen.dart \
  lib/screens/settings/settings_timing_authority_section.dart
# -> No issues found!

dart analyze --fatal-infos lib/
# -> 0 errors / 0 warnings; 9 pre-existing infos in unrelated files

flutter test test/services/integration/canonical_fact_to_closed_shift_input_test.dart
# -> 29/29 pass (includes 5 new Slice 1.5 regressions)

flutter test test/shift_service_close_shift_test.dart
# -> 11/11 pass (includes 2 new Slice 1.5 regressions)

flutter test test/shift_boundary_resolver_test.dart \
  test/week_start_wiring_test.dart \
  test/business_timing_profile_resolver_test.dart \
  test/restaurant_timing_config_repository_test.dart \
  test/services/sync/postgres_shift_record_to_mobile_sync_test.dart \
  test/business_date_authority_service_test.dart
# -> All pass

dart run tool/migration_drift_scanner.dart --fix --strict-docs
# -> migration_drift_scanner: cutoff updated to 202605150400_per_daypart_v1_drop_close_authority.sql

dart run tool/migration_cutoff_lint.dart
# -> clean — runbook cutoff is current
```

---

## Baseline failure snapshot

Per the "Audit Baseline Test Snapshot" doctrine: I confirmed the pre-existing analyzer errors in
`lib/services/schedule_plan_read_service.dart`, `lib/state/schedule_distribution_weights_notifier.dart`, and the `weekly_plan_snapshot_repository_test.dart` `PackagePostgresPool` references are cross-worktree analyzer-resolution artifacts that predate this slice (verified by stashing my changes and re-running analyze — same errors with the same line numbers on master). They are unrelated to Slice 1.5 and out of scope.

---

## Risks / follow-ups

1. **Postgres column drop deferred.** The deprecation-step migration leaves `business_timing_profiles.close_authority` and `local_close_fallback_time` nullable. A follow-up slice should refactor `BusinessTimingProfilesRepository` (drop the 12+ write-method `closeAuthority` parameters; update the `create_profile` Postgres function in `db/migrations/202605060000_…`) and then ship a full-drop migration. Until that lands, new writes from the operator-web admin path will continue to set the now-nullable column to whatever the candidate profile carries (currently `'app_local_cutoff_fallback'` for the demo seed and admin defaults). This is operationally benign — no reader consults the value.
2. **Aggregator API additive.** Existing callers that don't pass `allServicePeriodDefinitions` get a degraded forecast-fallback allocation (single-period list). Slice 1 (per-period plan persistence) is the right place to plumb the full operator period list into every aggregator call site.
3. **`ShiftCloseAuthority` enum retained.** The enum stays in `lib/domain/models/restaurant_timing_config.dart` because `BusinessTimingProfile`, `EffectiveBusinessTimingProfile`, `BusinessTimingProfileResolver`, and `ShiftBoundaryResolver` still reference it. This is intentional — Slice 1.5 maps per-vendor capability ONTO this enum at the boundary-resolver call seam; the enum itself is the right abstraction for "is the shift finalized."

---

## Files changed

**Production source (lib/, tool/):**

- `lib/services/integration/close_authority_capability.dart` (new — 148 LoC)
- `lib/services/integration/canonical_fact_to_closed_shift_input.dart` (1099 → ~1325 LoC; new imports, new helpers, refactored read paths)
- `lib/services/shift_service.dart` (added `_closeAuthorityForRow` + `_expectedClosedShiftsPerWeek`, swapped `_buildLockedWeekToDate` boundary derivation, swapped `closeShift` 14-shift hardcode)
- `lib/services/sync/http_sync_proxy_client.dart` (tolerate legacy JSON fields)
- `lib/domain/models/restaurant_timing_config.dart` (drop 2 fields)
- `lib/domain/models/business_timing_profile.dart` (`toRestaurantTimingConfig` stops passing dropped fields)
- `lib/domain/models/aggregator_provenance_context.dart` (new optional `closeAuthorityProvenance` field)
- `lib/infrastructure/persistence/sqlite/sqlite_database.dart` (bump schemaVersion 34→35)
- `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart` (drop 2 columns from CREATE TABLE)
- `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart` (new `_migrateToV35`)
- `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` (drop 2 INSERT keys)
- `lib/infrastructure/persistence/sqlite/dao/restaurant_timing_config_dao.dart` (drop 2 upsert params + INSERT keys)
- `lib/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart` (drop 2 read/write hops)
- `lib/screens/settings/settings_timing_authority_section.dart` (drop "Shift close rule" row + helper fn + tile)
- `lib/admin/screens/operator_location_admin_screen.dart` (drop "Shift close authority" row + label fn)
- `tool/advisor_proxy/proxy_bootstrap.dart` (stop emitting dropped JSON keys)

**Schema migrations:**

- `db/migrations/202605150400_per_daypart_v1_drop_close_authority.sql` (new — deprecation step)
- `scripts/postgres_staging_setup.ps1` (cutoff updated by migration drift scanner)

**Tests:**

- `test/services/integration/canonical_fact_to_closed_shift_input_test.dart` (5 new tests group "O. Per-Daypart V1 Slice 1.5 regressions"; 3 existing expectation updates for per-period attribution; fake `_FakePool.query` updated for 3-day SQL window)
- `test/shift_service_close_shift_test.dart` (2 new tests group "Slice 1.5 — _expectedClosedShiftsPerWeek (Gap 24)")
- `test/business_date_authority_service_test.dart` (drop dropped-field reference)
- `test/restaurant_timing_config_repository_test.dart` (drop 4 dropped-field references)
- `test/shift_boundary_resolver_test.dart` (drop raw-column INSERT references; vendorFinalization branch swapped to per-row `source_system='toast'`)
- `test/week_start_wiring_test.dart` (drop dropped-field references)
- `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart` (drop dropped-field reference)
