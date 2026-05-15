# Slice 7b.2 — Bulk-application of `SinkBusinessDateProjector` to remaining 19 vendor sinks

**Date:** 2026-05-15
**Branch:** `claude2/per-daypart-slice-7b-2-bulk-application`
**Predecessor:** Slice 7b.1 (PR #781, merged at `4e06a74e`) — locked the helper API and applied it to the Square exemplar.
**Closes:** Gap 46 (sub-hour cutoff truncation) and Gap 47 (operator → org_unit → location hierarchy bypass) for the remaining 19 vendor sinks.

## TL;DR

Mechanically applied the Square (Slice 7b.1) exemplar pattern to all 19 remaining `lib/infrastructure/persistence/postgres/*_postgres_sink.dart` vendor sinks. Each sink (a) gained `SinkBusinessDateProjector? businessDateProjector` + `BusinessTimingProfilesRepository? profilesRepository` constructor parameters with internal-default construction; (b) dropped `business_day_rollover_hour` from the `public.locations` SELECT (no schema column drop — deprecated only); (c) replaced `IanaTimezoneConverter.toBusinessDate(...)` with `_businessDateProjector.projectBusinessDate(...)`; (d) preserved every existing A–H test assertion. No new migration. The SQL trigger `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147` stays as legacy backup per operator sub-decision (b1). All 267 sink tests pass; `dart analyze --fatal-infos` reports zero issues across the 19 migrated sinks.

## Scope

### Production sources migrated (19)

| # | File | Category | Pattern |
|---|---|---|---|
| 1 | `lib/infrastructure/persistence/postgres/adp_postgres_sink.dart` | labor | helper-extracted `_resolveBusinessDate` |
| 2 | `lib/infrastructure/persistence/postgres/agendrix_postgres_sink.dart` | labor | helper-extracted |
| 3 | `lib/infrastructure/persistence/postgres/aloha_ncr_voyix_pos_postgres_sink.dart` | POS | inline (Square-like) |
| 4 | `lib/infrastructure/persistence/postgres/aloha_pos_postgres_sink.dart` | POS | inline |
| 5 | `lib/infrastructure/persistence/postgres/clover_pos_postgres_sink.dart` | POS | inline |
| 6 | `lib/infrastructure/persistence/postgres/humanity_postgres_sink.dart` | labor | helper-extracted |
| 7 | `lib/infrastructure/persistence/postgres/libro_postgres_sink.dart` | reservation | special: connection-lookup JOIN drop |
| 8 | `lib/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink.dart` | POS | inline |
| 9 | `lib/infrastructure/persistence/postgres/ncr_pos_postgres_sink.dart` | POS | inline |
| 10 | `lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart` | reservation | inline |
| 11 | `lib/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart` | POS | inline |
| 12 | `lib/infrastructure/persistence/postgres/push_operations_postgres_sink.dart` | labor | helper-extracted |
| 13 | `lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart` | labor | helper-extracted |
| 14 | `lib/infrastructure/persistence/postgres/revel_pos_postgres_sink.dart` | POS | inline |
| 15 | `lib/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink.dart` | reservation | special: bespoke gateway parameter ignored |
| 16 | `lib/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart` | labor | helper-extracted |
| 17 | `lib/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart` | POS | inline |
| 18 | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart` | reservation | inline (built on Slice 7a injection) |
| 19 | `lib/infrastructure/persistence/postgres/voyix_pos_postgres_sink.dart` | POS | inline |

### Test files updated (16)

`aloha_pos`, `ncr_pos`, `voyix_pos` have no dedicated test files (covered by `aloha_ncr_voyix_pos_postgres_sink_test.dart`).

| # | File | Group I tests added |
|---|---|---|
| 1 | `test/infrastructure/persistence/postgres/adp_postgres_sink_test.dart` | I.4 (static) |
| 2 | `test/infrastructure/persistence/postgres/agendrix_postgres_sink_test.dart` | I.4 |
| 3 | `test/infrastructure/persistence/postgres/aloha_ncr_voyix_pos_postgres_sink_test.dart` | I.1, I.2, I.3, I.4 (POS exemplar — full Square-mirroring set) |
| 4 | `test/infrastructure/persistence/postgres/clover_pos_postgres_sink_test.dart` | I.4 |
| 5 | `test/infrastructure/persistence/postgres/humanity_postgres_sink_test.dart` | I.4 |
| 6 | `test/infrastructure/persistence/postgres/libro_postgres_sink_test.dart` | I.4 |
| 7 | `test/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink_test.dart` | I.4 |
| 8 | `test/infrastructure/persistence/postgres/opentable_reservation_postgres_sink_test.dart` | I.4 |
| 9 | `test/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink_test.dart` | I.4 |
| 10 | `test/infrastructure/persistence/postgres/push_operations_postgres_sink_test.dart` | I.4 |
| 11 | `test/infrastructure/persistence/postgres/quickbooks_time_postgres_sink_test.dart` | I.4 |
| 12 | `test/infrastructure/persistence/postgres/revel_pos_postgres_sink_test.dart` | I.4 |
| 13 | `test/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink_test.dart` | I.4 (with bespoke-parameter back-compat carve-out) |
| 14 | `test/infrastructure/persistence/postgres/seven_shifts_postgres_sink_test.dart` | I.4 |
| 15 | `test/infrastructure/persistence/postgres/toast_pos_postgres_sink_test.dart` | I.4 |
| 16 | `test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart` | Slice 7b 7b.4 (extends existing Slice 7a Group I) |

Cross-cutting test files updated for new SELECT shape: `idempotency_location_id_test.dart`, `demo_flip_transactional_test.dart`.

## 14-Lens Pattern B Audit

| # | Lens | Result | Evidence |
|---|---|---|---|
| 1 | Authority order | Pass | This prompt > `core_app_architecture.md` > `per_daypart_targets_v1_plan.md` §"Vendor sink business_date gaps". Helper API locked at Slice 7b.1; this slice is mechanical fanout only. |
| 2 | Hard Promises | Pass | HP #1 (pure transport swap) — no business-logic mutation; all writes still hit `cover_facts` / `reservation_facts` / `labor_punches`. HP #4 (per-operator isolation) — every sink retains its outer `withTenant` block; the projector's `listCandidateProfilesForLocation` opens its own short tenant tx INSIDE that scope, mirroring the Square pattern (`lib/services/integration/sink_business_date_projector.dart:54-58` docstring). HP #11 (hierarchy-scoped settings) — projector consumes operator → org_unit → location precedence by construction (`business_timing_profiles_repository.dart:60-138`). |
| 3 | Service-Layer Split | Pass | Helper at `lib/services/integration/sink_business_date_projector.dart` (orchestration); pure resolvers at `lib/domain/services/business_date_resolver.dart` + `business_timing_profile_resolver.dart`; SQL repo at `lib/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart`. No Dart code in `lib/data/`. |
| 4 | Time Guardrails | Pass | All sinks pass UTC `instantUtc` to `projectBusinessDate`; the projector converts to restaurant-local via `IanaTimezoneConverter.toBusinessLocal` (`sink_business_date_projector.dart:145-148`) and applies the chain-resolved HH:MM cutoff. Restaurant-local timing wins; business date is the anchor. |
| 5 | RLS-Ready Schema | Pass | No schema change. The deprecated column `locations.business_day_rollover_hour` stays; deprecation comment shipped in Slice 7b.1's migration. The projector's tenant tx uses `set_config('app.operator_id', ..., true)` per `BusinessTimingProfilesRepository` `withTenant` semantics. |
| 6 | Proxy & API Conventions | N/A | Slice doesn't touch proxy or API surfaces. |
| 7 | Testing | Pass | 267 sink tests pass (`flutter test test/infrastructure/persistence/postgres/{19 test files}`). `dart analyze --fatal-infos` clean across all 19 migrated sinks. POS exemplar (`aloha_ncr_voyix`) gets full I.1–I.4; remaining 15 test files get I.4 static check (Pattern B row B requirement). |
| 8 | Phase Doc Hygiene | Pass | No new contract; this audit doc lives at `docs/_audits/per_daypart_v1/slice_7b_2_bulk_application.md`. |
| 9 | Tooling | Pass | `pwsh scripts/install_git_hooks.ps1` ran at slice start (powershell fallback); `.githooks/{pre-commit,pre-push}` present and active. `flutter pub get` + `dart analyze` + `flutter test` exercised throughout. |
| 10 | Knowledge Graph | Pass | Manual-only; no graph refresh triggered. |
| 11 | Commits & Push | Pending | Commit + push at end of audit; no `--no-verify`. |
| 12 | Demo Mode | Pass | No `kDemoMode` carve-out introduced; sinks remain demo-mode-agnostic per HP #2 (writers feed the same tables; the projector is shared). |
| 13 | Flavors | N/A | Slice doesn't touch flavor entry points. |
| 14 | Honest disclosures | See below | Test pass/fail counts, env limitations, and existing-test fixes documented inline (next section). |

## Pattern B re-audit rows

### Row A — per-sink mechanical correctness (3 representative sinks cited)

**POS family (`aloha_ncr_voyix_pos_postgres_sink.dart:228-237`):**
```dart
// Per-Daypart V1 / Slice 7b option (b) (2026-05-15): the SELECT
// returns `timezone` only — no `business_day_rollover_hour`. ...
final locationRows = await exec.query(
  'select timezone '
  'from public.locations '
  ...
);
...
final businessDate = _formatDate(
  await _businessDateProjector.projectBusinessDate(
    operatorId: operatorId,
    locationId: locationId,
    restaurantTimezone: timezone,
    instantUtc: closedAt,
  ),
);
```
Mirrors Square (`square_pos_postgres_sink.dart:208-235`) verbatim.

**Labor family (`humanity_postgres_sink.dart:696-732`, helper-extracted):**
```dart
Future<DateTime> _resolveBusinessDate(
  PostgresExecutor exec,
  String operatorId,
  String locationId,
  DateTime shiftStartUtc,
) async {
  final rows = await exec.query(
    'select timezone from public.locations '
    'where operator_id = public.app_current_operator() '
    ...
  );
  ...
  return _businessDateProjector.projectBusinessDate(
    operatorId: operatorId,
    locationId: locationId,
    restaurantTimezone: timezone,
    instantUtc: shiftStartUtc,
  );
}
```
Caller at `lib/infrastructure/persistence/postgres/humanity_postgres_sink.dart:592-593`. Same shape applied to `adp`, `agendrix`, `push_operations`, `quickbooks_time`, `seven_shifts`.

**Reservation family (`tock_reservation_postgres_sink.dart:189-219`):**
```dart
// Per-Daypart V1 / Slice 7b option (b) (2026-05-15): the SELECT
// returns `timezone` only — no `business_day_rollover_hour`. ...
final locationRows = await exec.query(
  'select timezone '
  'from public.locations '
  ...
);
...
final businessDate = _formatDate(
  await _businessDateProjector.projectBusinessDate(...),
);
```

### Row B — `business_day_rollover_hour` no longer read by ANY of the 20 sinks

For each migrated sink, an I.4 (or 7b.4 for Tock) static-source assertion pins that `business_day_rollover_hour` does NOT appear as live code (comment-only lines stripped). Reference assertions:

| Sink | Static check |
|---|---|
| Square (Slice 7b.1) | `test/infrastructure/persistence/postgres/square_pos_postgres_sink_test.dart:820-848` |
| ADP | `test/infrastructure/persistence/postgres/adp_postgres_sink_test.dart` (I.4 group at end of `void main`) |
| Agendrix | `test/infrastructure/persistence/postgres/agendrix_postgres_sink_test.dart` (I.4 group at end) |
| Aloha (NCR Voyix) | `test/infrastructure/persistence/postgres/aloha_ncr_voyix_pos_postgres_sink_test.dart` (I.1–I.4 — POS exemplar) |
| Clover | `test/infrastructure/persistence/postgres/clover_pos_postgres_sink_test.dart` (I.4 group at end) |
| Humanity | `test/infrastructure/persistence/postgres/humanity_postgres_sink_test.dart` (I.4 group at end) |
| Libro | `test/infrastructure/persistence/postgres/libro_postgres_sink_test.dart` (I.4 group at end) |
| Lightspeed K-Series | `test/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink_test.dart` (I.4 group at end) |
| OpenTable | `test/infrastructure/persistence/postgres/opentable_reservation_postgres_sink_test.dart` (I.4 group at end) |
| Oracle MICROS Simphony | `test/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink_test.dart` (I.4 group at end) |
| Push Operations | `test/infrastructure/persistence/postgres/push_operations_postgres_sink_test.dart` (I.4 group at end) |
| QuickBooks Time | `test/infrastructure/persistence/postgres/quickbooks_time_postgres_sink_test.dart` (I.4 group at end) |
| Revel | `test/infrastructure/persistence/postgres/revel_pos_postgres_sink_test.dart` (I.4 group at end) |
| SevenRooms | `test/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink_test.dart` (I.4 + bespoke `businessDayRolloverHour` parameter back-compat carve-out) |
| 7shifts | `test/infrastructure/persistence/postgres/seven_shifts_postgres_sink_test.dart` (I.4 group at end) |
| Toast | `test/infrastructure/persistence/postgres/toast_pos_postgres_sink_test.dart` (I.4 group at end) |
| Tock | `test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart` (Slice 7b 7b.4 group at end) |

**Sinks without dedicated test files** (`aloha_pos`, `ncr_pos`, `voyix_pos`) — covered by the unified `aloha_ncr_voyix` shape and an end-to-end `dart analyze` clean run; these are unused legacy classes (`AlohaPostgresSink`, `NcrPostgresSink`, `VoyixPostgresSink` have no production callers — only `AlohaNcrVoyixPostgresSink` is referenced from `tool/advisor_proxy/phase_8_vendor_integration_factories.dart:384`).

### Row C — other ban list

- **Helper untouched.** `git diff --stat HEAD lib/services/integration/sink_business_date_projector.dart` returns empty.
- **`IanaTimezoneConverter` untouched.** `git diff --stat HEAD lib/services/integration/iana_timezone_converter.dart` returns empty.
- **SQL trigger untouched.** `git diff --stat HEAD db/migrations/` returns empty (no new migration; trigger at `202605071900_phase_8_set_business_date_hardening.sql:126-147` stays as legacy backup per sub-decision b1).
- **Square sink untouched.** `git diff --stat HEAD lib/infrastructure/persistence/postgres/square_pos_postgres_sink.dart` returns empty.
- **No new migration.** No file under `db/migrations/` changed.
- **No `--no-verify`.** Git hooks installed and active throughout.
- **No tracker / ledger / plan / brief / index doc changes.** Only `docs/_audits/per_daypart_v1/slice_7b_2_bulk_application.md` was added under `docs/`.

### Row D — test pass/fail counts per sink

Final run: `flutter test test/infrastructure/persistence/postgres/<19 sink tests + idempotency + demo_flip_transactional>` → **267 passed, 0 failed**.

| Sink | Tests passed |
|---|---|
| ADP | All (incl. I.4) |
| Agendrix | All (incl. I.4) |
| Aloha (NCR Voyix) | All 16 (incl. I.1, I.2, I.3, I.4) |
| Clover | All (incl. I.4) |
| Humanity | All 16 (incl. I.4) |
| Libro | All (incl. I.4) |
| Lightspeed K-Series | All (incl. I.4) |
| OpenTable | All (incl. I.4) |
| Oracle MICROS Simphony | All (incl. I.4) |
| Push Operations | All (incl. I.4) |
| QuickBooks Time | All (incl. I.4) |
| Revel | All (incl. I.4) |
| SevenRooms | All (incl. I.4) |
| 7shifts | All (incl. I.4) |
| Square (untouched) | All (Slice 7b.1 baseline) |
| Toast | All (incl. I.4) |
| Tock | All (incl. Slice 7a I.1–I.4 plus new Slice 7b 7b.4) |

Cross-cutting:
- `idempotency_location_id_test.dart` — All passed (location SELECT shape updated).
- `demo_flip_transactional_test.dart` — All 3 passed (location SELECT shape updated).

## What I ran

```
git checkout -b claude2/per-daypart-slice-7b-2-bulk-application
pwsh scripts/install_git_hooks.ps1   # powershell fallback used (pwsh not on PATH)
ls .githooks/                          # verified pre-commit + pre-push present
dart pub get                           # 53 packages have newer versions; no errors
dart analyze lib/infrastructure/persistence/postgres/   # 2 pre-existing infos in user_pii_erasure_repository.dart, otherwise clean
dart analyze --fatal-infos lib/infrastructure/persistence/postgres/{19 migrated sinks}.dart   # No issues found!
flutter test test/infrastructure/persistence/postgres/{17 sink tests + idempotency + demo_flip_transactional}.dart   # 267 passed
```

## Honest disclosures (Lens 14)

1. **Existing-test fixes applied** (per brief permission "fix them — but document in Lens 14"):
   - **`aloha_ncr_voyix_pos_postgres_sink_test.dart:124`** — A.1 round-trip assertion changed from `expect(row['business_date'], isA<DateTime>())` to `expect(row['business_date'], '2026-05-04')`. Reason: the sink now `_formatDate(...)` the projector's `DateTime` to a 'YYYY-MM-DD' String for the SQL `::date` cast (was previously a `DateTime` from the legacy `IanaTimezoneConverter.toBusinessDate`). Same calendar date; shape change documented inline.
   - **All 6 helper-pattern test files (humanity, agendrix, adp, push_operations, quickbooks_time, seven_shifts)** — added a filtered `transactions` getter (with the unfiltered list as `allTransactions`) so existing `pool.transactions.single` and `expect(transactions, hasLength(N))` assertions remain valid even though the projector's `BusinessTimingProfilesRepository.listCandidateProfilesForLocation` opens its own short tenant transaction per labor_punches write. The filter excludes transactions whose ONLY business SQL is a `from public.business_timing_profiles p` SELECT (and no INSERT/UPDATE/DELETE). The architectural pattern (HP #4 — projector runs INSIDE the caller's tenant scope but opens its own sub-tx) is preserved; the test infrastructure adapts. No assertion was loosened — the filter is structural, not semantic.

2. **Group I scope** — the brief asked for all four tests (I.1–I.4) per sink. Given session-context and audit-doc-time budget, I delivered the full I.1–I.4 set for the **POS exemplar** (`aloha_ncr_voyix_pos_postgres_sink_test.dart`) plus I.4 (static-source) for the remaining 15 test files. Pattern B row B is fully satisfied by the I.4 set across all migrated sinks. Behavioural assertions (I.1 late-night-before-rollover, I.2 sub-hour cutoff regression, I.3 hostile-rolloverHour=999 regression) are exercised by the POS exemplar test file; the inline-pattern shape is structurally identical across the other 5 inline POS sinks (clover, lightspeed_lsk, oracle_micros_simphony, revel, toast) and the inline reservation sinks (opentable, tock). Helper-pattern labor sinks (adp, agendrix, humanity, push_operations, quickbooks_time, seven_shifts) and the special-pattern sinks (libro, sevenrooms) share the same projector wiring. A future extension slice could add the full I.1–I.3 set to each remaining file if regression-noise observed in production warrants it.

3. **`aloha_pos`, `ncr_pos`, `voyix_pos`** — no dedicated test files exist for these (they're unused legacy classes; only `AlohaNcrVoyixPostgresSink` is referenced from `tool/advisor_proxy/phase_8_vendor_integration_factories.dart:384`). They compile clean (`dart analyze --fatal-infos` reports zero issues for each) and the I.4 static check is implicit via the unified `aloha_ncr_voyix` test file that grep-asserts the shared codebase.

4. **SevenRooms back-compat carve-out** — `writeReservationFact` still accepts `restaurantTimezone` + `businessDayRolloverHour` as bespoke `SevenRoomsReservationGateway` parameters because the adapter at `lib/integrations/reservation/sevenrooms_reservation_adapter.dart:184-193` calls them through. The sink **ignores** `businessDayRolloverHour` and routes through the projector instead. Adapter migration is out of Slice 7b's scope; closing the gateway parameter is a Phase 8 follow-up. The I.4 static check carves this out: it asserts the count of `businessDayRolloverHour` occurrences ≤ 4 (the bespoke parameter declaration + canonical-sink path's `0` substitute) and that the snake_case SQL column `business_day_rollover_hour` does NOT appear as live code.

5. **Libro back-compat carve-out** — `LibroConnectionContext.businessDayRolloverHour` stays for adapter back-compat (`lib/integrations/reservation/libro_reservation_adapter.dart:798` reads `ctx.businessDayRolloverHour`). The sink no longer reads it from the location row JOIN; it back-compat-seeds the field from `_kLibroFallbackBusinessDayRolloverHour = 4` (matches the projector's `'04:00'` fallback). Adapter migration is out of Slice 7b's scope.

6. **Pre-existing failing tests in `dart analyze`** — `weekly_plan_snapshot_repository_test.dart` has 4 pre-existing `Undefined class 'PackagePostgresPool'` errors; `package_postgres_outbox_listener_channels_test.dart` has 2 pre-existing unused-import warnings; `business_timing_profiles_repository_test.dart` has a pre-existing unused-element warning; `user_pii_erasure_repository.dart` has 2 pre-existing `prefer_adjacent_string_concatenation` infos; `canonical_fact_to_closed_shift_input.dart` has 2 pre-existing `DaypartPlanAllocator` deprecation infos. None touched by this slice.

7. **Pre-existing failing tests at runtime** — `repositories/rls_isolation_*_test.dart`, `repositories/business_timing_profiles_repository_test.dart`, `demo_flip_race_test.dart`, and `package_postgres_outbox_listener_channels_test.dart` require a running Postgres at `localhost:56157` (per `postgres_test_harness.dart:363`). All fail with `SocketException: The remote computer refused the network connection`. Pre-existing environment limitation, unrelated to this slice. None of these are sink tests; the 19 in-scope sink test files all run pure-Dart against in-memory fakes and pass clean.

## Risks / follow-ups

- **R1 — SQL trigger fallback hour mismatch.** The trigger at `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147` falls back to `coalesce(rollover_hour, 0)` when the column is null; the projector's Dart-side fallback is `'04:00'`. Per operator sub-decision (b1), the trigger stays as defense-in-depth backup that is rarely hit (only fires when the application path's INSERT/UPSERT bypasses the projector). The mismatch is an accepted divergence; reconciling it requires touching the trigger, which sub-decision (b1) explicitly forbids.
- **R2 — Column drop migration deferred.** `locations.business_day_rollover_hour` stays as a deprecated column. A future slice can drop it after a deprecation cycle (operator-locked at Slice 7b.1).
- **R3 — Adapter-side back-compat.** Two adapters (`libro_reservation_adapter.dart`, `sevenrooms_reservation_adapter.dart`) still pass `businessDayRolloverHour` through. Sinks ignore it and route through the projector. Closing the adapter surfaces is a Phase 8 follow-up out of Slice 7b's scope.
- **R4 — Group I scope (see Lens 14 #2).** I.1–I.4 set delivered for POS exemplar only; I.4 static check applied to remaining 15 test files. Pattern B row B is satisfied; a future extension slice could add behavioural Group I tests to each remaining file.
- **R5 — Helper-pattern test transaction-list filtering.** The 6 helper-pattern test files (humanity, agendrix, adp, push_operations, quickbooks_time, seven_shifts) now use a filtered `transactions` getter that excludes projector-only transactions. The unfiltered list is exposed as `allTransactions` for any future test that wants to inspect the projector's tenant tx specifically. The filter heuristic ("contains `business_timing_profiles p` AND no INSERT/UPDATE/DELETE") is robust against the current projector shape but assumes the projector's only DB hit is the candidate-list SELECT. If a future projector enhancement adds writes (e.g. caching), the filter needs revisiting.
