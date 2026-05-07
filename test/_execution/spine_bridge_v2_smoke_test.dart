// 8.integration-mobile-proof.v2 — E2E fixture harness.
//
// Walks the spine end-to-end for the trio (Oracle MICROS Simphony POS +
// QuickBooks Time labor + Libro reservation) plus exercise vendors
// (Square forecast-substitution, Humanity per-position dollars,
// 7shifts perEmployeeWithDollars after `.7S.upgrade`, Tock daypart
// bucketing without seated_at). Companion to:
//
//   - `docs/contracts/integration_spine_architecture_contract.md`
//   - `docs/contracts/data_accuracy_settings_contract.md`
//   - `docs/contracts/core_app_architecture.md` (Layers 1-12)
//   - `docs/_execution/<date>_8_integration_mobile_proof_v2_execution.md`
//
// Proof-only: this file is a test harness. It composes production code
// through a shared fake Postgres pool + in-memory SyncProxyClient + the
// real SQLite `shift_records` table. No app/business/mobile/adapter/
// schema/migration/runtime changes.
//
// What this harness proves (composition):
//
//   fixture canonical-fact dicts (what the .1.* sinks would write)
//     -> Aggregator (.2) reads via shared FakePool
//        + DataAccuracySettings (.A) seeded in same pool
//        + ForgeFlowPollingTierAssignment (.A) seeded in same pool
//     -> ClosedShiftInput + AggregatorProvenanceContext
//     -> ShiftFactBuilder.fromClosedShiftInput (pure)
//     -> PostgresShiftRecordWriter (.2) writes shift_records row
//        with target_profile_version_id preservation (Concern A)
//     -> Constructed ShiftRecord matching the captured row
//     -> ServerToMobileSync (.3) via FakeSyncProxyClient
//     -> SqliteShiftRecordRepository.replaceShiftForSlot
//     -> read back via getShiftsForWeek
//     -> covers / labor / sourceSystem / provenance flow through
//
// Out of scope per `integration_spine_architecture_contract.md`:
//   open_shift_snapshots (live in-progress dashboard) is NOT touched
//   by spine-bridge; this harness asserts that grep-level absence and
//   confirms the closed-shift truth path lands cleanly.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart'
    show Daypart;
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/domain/services/shift_fact_builder.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_shift_record_writer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';
import 'package:forge_and_flow/services/integration/labor_wage_source_class.dart';
import 'package:forge_and_flow/services/sync/postgres_shift_record_to_mobile_sync.dart';
import 'package:forge_and_flow/services/sync/sync_proxy_client.dart';
import 'package:forge_and_flow/state/app_runtime_invalidation_bus.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _restaurantA = 'demo_restaurant_001';
const String _businessDateIso = '2026-05-04';
final DateTime _businessDate = DateTime.utc(2026, 5, 4);

// 22:00 UTC = 18:00 EDT (America/Toronto, May 2026) → buckets to dinner.
final DateTime _dinnerInstantUtc = DateTime.utc(2026, 5, 4, 22, 0, 0);

const ServicePeriodDefinition _dinnerPeriod = ServicePeriodDefinition(
  id: 'dinner',
  label: 'Dinner',
  shortLabel: 'D',
  sortOrder: 2,
  startLocalTime: '17:00',
  endLocalTime: '22:00',
  rollsPastMidnight: false,
  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
);

const TargetSnapshot _targetSnapshotV1 = TargetSnapshot(
  restaurantId: _restaurantA,
  targetProfileId: 'tp_demo_2026_q2',
  targetProfileVersionId: 'tpv_X',
  sourceType: 'cycle_recommended',
  targetCPLH: 12.0,
  targetSPLH: 50.0,
  targetPPA: 40.0,
  fohWage: 18.0,
  bohWage: 20.0,
  opzFloorCPLH: 10.0,
  opzCeilingCPLH: 14.0,
  theoreticalFohLaborPct: 12.5,
  theoreticalBohLaborPct: 12.5,
  theoreticalLaborPct: 25.0,
);

const TargetSnapshot _targetSnapshotV2 = TargetSnapshot(
  restaurantId: _restaurantA,
  targetProfileId: 'tp_demo_2026_q2',
  targetProfileVersionId: 'tpv_Y',
  sourceType: 'cycle_recommended',
  targetCPLH: 13.0,
  targetSPLH: 52.0,
  targetPPA: 42.0,
  fohWage: 19.0,
  bohWage: 21.0,
  opzFloorCPLH: 11.0,
  opzCeilingCPLH: 15.0,
  theoreticalFohLaborPct: 12.0,
  theoreticalBohLaborPct: 12.0,
  theoreticalLaborPct: 24.0,
);

void main() {
  late AppRuntimeInvalidationBus bus;
  late ImportTrackingDao watermarkDao;

  setUpAll(() async {
    final db = await SqliteDatabase.instance.database;
    watermarkDao = ImportTrackingDao(db);
    bus = AppRuntimeInvalidationBus.instance;
  });

  // ──────────────────── Trio end-to-end (acceptance #1, #2, #3, #4) ────

  test('trio chain: Oracle Simphony + QuickBooks Time + Libro fixture -> '
      'aggregator + writer + sync -> SQLite shift_records row carries '
      'vendor provenance', () async {
    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);

    // Stage 1: canonical-fact dicts (what the per-vendor Postgres sinks
    // would write). Acceptance items 1 (POS), 2 (labor), 3 (reservation).
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'oracle_micros_simphony',
        'vendor_entity_id': 'check_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 5,
        'covers_source': 'direct',
        'opened_at': _dinnerInstantUtc.subtract(const Duration(hours: 1)),
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 124.85,
      },
    ];
    pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'quickbooks_time',
        'vendor_entity_id': 'ts_001',
        'employee_source_id': 'emp_1',
        'role_name': 'server',
        'shift_start': _dinnerInstantUtc.subtract(const Duration(hours: 1)),
        'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
        'hours_worked': 5,
        'pay_rate': 18.0,
        'business_date': _businessDateIso,
      },
      <String, Object?>{
        'vendor_id': 'quickbooks_time',
        'vendor_entity_id': 'ts_002',
        'employee_source_id': 'emp_2',
        'role_name': 'cook',
        'shift_start': _dinnerInstantUtc.subtract(const Duration(hours: 1)),
        'shift_end': _dinnerInstantUtc.add(const Duration(hours: 5)),
        'hours_worked': 6,
        'pay_rate': 20.0,
        'business_date': _businessDateIso,
      },
    ];
    pool.reservationFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
        [
          <String, Object?>{
            'vendor_id': 'libro',
            'vendor_entity_id': 'res_001',
            'reservation_at': _dinnerInstantUtc,
            'party_size': 4,
            'status': 'SEATED',
            'seated_at': _dinnerInstantUtc,
            'business_date': _businessDateIso,
          },
        ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final writer = PostgresShiftRecordWriter(wrapper);

    // Stage 2: aggregator
    final agg = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
    );
    expect(agg, isNotNull);
    expect(
      agg!.input.covers,
      5,
      reason: 'covers from Oracle Simphony cover_facts',
    );
    expect(agg.input.actualSales, closeTo(124.85, 0.001));
    expect(agg.input.actualFohHours, 5);
    expect(agg.input.actualBohHours, 6);
    expect(
      agg.input.actualFohLaborDollars,
      closeTo(5 * 18.0, 0.001),
      reason: 'QBT perEmployeeWithRates: rate × duration',
    );
    expect(agg.input.actualBohLaborDollars, closeTo(6 * 20.0, 0.001));
    expect(agg.input.sourceSystem, 'oracle_micros_simphony');
    expect(agg.provenance.coversProvenance, 'vendor_oracle_micros_simphony');
    expect(
      agg.provenance.laborDollarsProvenance,
      'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
    );

    // Stage 3: ShiftFactBuilder (pure)
    final fact = ShiftFactBuilder.fromClosedShiftInput(
      agg.input,
      _targetSnapshotV1,
    );
    expect(fact.targetSnapshot.targetProfileVersionId, 'tpv_X');

    // Stage 4: writer
    await writer.writeShiftRecord(
      operatorId: _opA,
      locationId: _locA,
      shiftFact: fact,
      provenance: agg.provenance,
    );
    expect(pool.shiftRecords, hasLength(1));
    final captured = pool.shiftRecords.values.single;
    expect(captured['covers'], 5);
    expect(
      (captured['actual_sales'] as num).toDouble(),
      closeTo(124.85, 0.001),
    );
    expect(
      captured['source_system'],
      'oracle_micros_simphony',
      reason: 'sourceSystem != "demo" — flipped to vendor truth',
    );
    expect(captured['target_profile_version_id'], 'tpv_X');
    expect(captured['covers_provenance'], 'vendor_oracle_micros_simphony');
    expect(
      captured['labor_dollars_provenance'],
      'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
    );

    // Tenant SET LOCAL fired on every txn (RLS Hard Promise #4).
    expect(pool.transactions, isNotEmpty);
    for (final tx in pool.transactions) {
      expect(tx.setConfigCalls['app.operator_id'], _opA);
      expect(tx.setConfigCalls['app.location_id'], _locA);
    }

    // Stage 5: server -> mobile sync via fake proxy with the captured row.
    final shiftRecordPayload = ShiftRecord(
      restaurantId: _restaurantA,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: 'dinner',
      status: 'closed',
      covers: captured['covers'] as int,
      forecastCovers: (captured['forecast_covers'] as int?) ?? 0,
      ppa: (captured['ppa'] as num).toDouble(),
      cplh: (captured['cplh'] as num).toDouble(),
      splh: (captured['splh'] as num).toDouble(),
      fohHours: captured['foh_hours'] as int,
      bohHours: captured['boh_hours'] as int,
      primaryLever: captured['primary_lever'] as String,
      sourceSystem: captured['source_system'] as String,
      businessDate: captured['business_date'] as String,
    );

    final client = _SmokeSyncProxyClient()
      ..scriptShiftPages([
        _Page(records: [shiftRecordPayload], nextCursor: null),
      ])
      ..scriptDataAccuracySettings(
        DataAccuracySettingsSnapshot(
          operatorId: _opA,
          locationId: _locA,
          coversSourceLunch: 'vendor',
          coversSourceDinner: 'vendor',
          coversSourceLateNight: 'vendor',
          coversManualEntries: const <String, Map<String, int>>{},
          wageSource: 'vendor',
          updatedAt: DateTime.utc(2026, 5, 4, 12, 0),
        ),
      )
      ..scriptPollingTierAssignment(
        ForgeFlowPollingTierAssignmentSnapshot(
          operatorId: _opA,
          locationId: _locA,
          tierKey: 'standard',
          pollingCadencePerVendorSeconds: const <String, int>{
            'oracle_micros_simphony': 300,
            'quickbooks_time': 300,
            'libro': 300,
          },
          monthlyPriceCents: 2900,
          effectiveAt: DateTime.utc(2026, 5, 1),
        ),
      );

    final invalidations = _BusListener(bus);
    addTearDown(invalidations.detach);

    final sync = PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: watermarkDao,
      invalidationBus: bus,
    );
    final result = await sync.sync(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
    );
    invalidations.detach();

    // Stage 6: SQLite read-back.
    expect(result.recordsWritten, 1);
    expect(
      invalidations.count,
      1,
      reason:
          'AppRuntimeInvalidationBus fires per write -> dashboard '
          '/ variance / history / learn refresh',
    );

    // Aux pulls (data_accuracy + polling tier) flowed through the proxy.
    expect(result.dataAccuracySettings, isNotNull);
    expect(result.dataAccuracySettings!.wageSource, 'vendor');
    expect(result.pollingTierAssignment, isNotNull);
    expect(result.pollingTierAssignment!.tierKey, 'standard');
    expect(
      result
          .pollingTierAssignment!
          .pollingCadencePerVendorSeconds['oracle_micros_simphony'],
      300,
      reason: 'F&F-controlled cadence — 300s per Oracle Simphony minimum',
    );

    // Stored mobile row matches vendor truth.
    final stored = await SqliteShiftRecordRepository.instance.getShiftsForWeek(
      _restaurantA,
      '2026-W18',
    );
    expect(stored, hasLength(1));
    expect(stored.single.covers, 5);
    expect(stored.single.daypart, 'dinner');
    expect(
      stored.single.sourceSystem,
      'oracle_micros_simphony',
      reason:
          'sourceSystem flowed Postgres -> SQLite; never reverted to '
          '"demo" — closes acceptance items 4, 10, 11, 12 for the trio',
    );

    // Cleanup: remove the row so the next test sees a clean slate (the
    // sync test pattern keys per-test on a unique restaurant_id; this
    // smoke test reuses _restaurantA for the trio + corrections, so it
    // resets between tests).
    pool.shiftRecords.clear();
  });

  // ──────────────────── Concern A — TPV preservation ───────────────────

  test('Concern A: re-aggregation after cycle roll preserves '
      'target_profile_version_id verbatim', () async {
    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'oracle_micros_simphony',
        'vendor_entity_id': 'check_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 5,
        'covers_source': 'direct',
        'opened_at': _dinnerInstantUtc,
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 100.00,
      },
    ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final writer = PostgresShiftRecordWriter(wrapper);

    // Step 1 — first-time aggregation locks tpv_X.
    final aggV1 = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
    );
    expect(aggV1, isNotNull);
    expect(
      aggV1!.provenance.priorTargetProfileVersionId,
      isNull,
      reason: 'no prior shift_records row -> first-time aggregation',
    );

    final factV1 = ShiftFactBuilder.fromClosedShiftInput(
      aggV1.input,
      _targetSnapshotV1,
    );
    await writer.writeShiftRecord(
      operatorId: _opA,
      locationId: _locA,
      shiftFact: factV1,
      provenance: aggV1.provenance,
    );
    expect(
      pool.shiftRecords.values.single['target_profile_version_id'],
      'tpv_X',
    );

    // Seed the prior TPV in the fake so the aggregator's prior-TPV read
    // returns tpv_X for the second pass (production path: writer wrote
    // it; the smoke fake captures writer rows but doesn't auto-cross-
    // populate the aggregator's prior-TPV map).
    pool.shiftRecordTpvBySlot['$_opA|$_locA|$_businessDateIso|dinner'] =
        'tpv_X';

    // Step 2 — TargetCycle rolls; vendor correction arrives.
    pool
            .coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso']!
            .first['covers'] =
        6;
    pool
            .coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso']!
            .first['actual_sales'] =
        142.50;

    final aggV2 = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
    );
    expect(aggV2, isNotNull);
    expect(
      aggV2!.provenance.priorTargetProfileVersionId,
      'tpv_X',
      reason: 'aggregator surfaces the prior TPV verbatim',
    );

    final factV2 = ShiftFactBuilder.fromClosedShiftInput(
      aggV2.input,
      _targetSnapshotV2, // cycle rolled — current snapshot is tpv_Y.
    );
    await writer.writeShiftRecord(
      operatorId: _opA,
      locationId: _locA,
      shiftFact: factV2,
      provenance: aggV2.provenance,
    );
    expect(
      pool.shiftRecords,
      hasLength(1),
      reason: 'replace-for-slot, not append',
    );
    final reread = pool.shiftRecords.values.single;
    expect(
      reread['target_profile_version_id'],
      'tpv_X',
      reason:
          'Concern A: corrected fact does NOT re-grade closed history under '
          'a newer cycle; prior tpv_X preserved verbatim',
    );
    expect(reread['covers'], 6, reason: 'numeric correction lands on the row');
  });

  // ──────────────────── Square forecast substitution + manual + walk-in ─

  test('Square (coversFieldExposed=false) trio: vendor row covers=0 + '
      'forecast available -> aggregator emits '
      'vendor_square_covers_unavailable_app_forecast_substituted', () async {
    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'square',
        'vendor_entity_id': 'order_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 0,
        'covers_source': 'forecast_fallback',
        'opened_at': _dinnerInstantUtc,
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 250.00,
      },
    ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final result = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
      forecastContext: DemandForecastContext(
        restaurantId: _restaurantA,
        anchorBusinessDate: _businessDateIso,
        baselineTotalCovers: 1500,
        baselineWeeklyAvgCovers: 175,
        baselineWeeksRepresented: 60 / 7,
        recentThreeWeekTotalCovers: 525,
        recentThreeWeekWeeklyAvgCovers: 175,
        recentTrendDeltaCovers: 0,
        resolvedWeeklyForecastCovers: 210,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: _businessDateIso,
      ),
    );
    expect(result, isNotNull);
    expect(result!.input.covers, greaterThan(0));
    expect(
      result.provenance.coversProvenance,
      'vendor_square_covers_unavailable_app_forecast_substituted',
    );
  });

  test(
    'Pattern A: Square + Libro operator with operator_walk_in_count -> '
    'covers source = vendor_libro_seated_plus_operator_walk_in_count',
    () async {
      final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'forecast_fallback',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 250.00,
        },
      ];
      pool.reservationFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_001',
              'reservation_at': _dinnerInstantUtc,
              'party_size': 4,
              'status': 'SEATED',
              'seated_at': _dinnerInstantUtc,
              'business_date': _businessDateIso,
            },
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_002',
              'reservation_at': _dinnerInstantUtc,
              'party_size': 2,
              'status': 'SEATED',
              'seated_at': _dinnerInstantUtc,
              'business_date': _businessDateIso,
            },
          ];

      final wrapper = TenantTransactionWrapper(pool);
      final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
      final result = await aggregator.aggregate(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        daypart: Daypart.dinner,
        periodDefinition: _dinnerPeriod,
        walkInOverride: const ReservationWalkInOverride(operatorWalkInCount: 8),
      );
      expect(result, isNotNull);
      expect(
        result!.input.covers,
        4 + 2 + 8,
        reason: 'seated party_size sum + operator walk-in count',
      );
      expect(
        result.provenance.coversProvenance,
        'vendor_libro_seated_plus_operator_walk_in_count',
      );
    },
  );

  // ──────────────────── Tock daypart bucketing without seated_at ───────

  test('Tock fixture without seated_at: aggregator buckets by '
      'reservation_at; SEATED party_size sums; NO_SHOW excluded', () async {
    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
    pool.reservationFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
        [
          <String, Object?>{
            'vendor_id': 'tock',
            'vendor_entity_id': 'tock_001',
            'reservation_at': _dinnerInstantUtc,
            'party_size': 4,
            'status': 'SEATED',
            // seated_at deliberately absent — Tock has no seated_at field.
            'business_date': _businessDateIso,
          },
          <String, Object?>{
            'vendor_id': 'tock',
            'vendor_entity_id': 'tock_002',
            'reservation_at': _dinnerInstantUtc,
            'party_size': 6,
            'status': 'SEATED',
            'business_date': _businessDateIso,
          },
          <String, Object?>{
            'vendor_id': 'tock',
            'vendor_entity_id': 'tock_003',
            'reservation_at': _dinnerInstantUtc,
            'party_size': 2,
            'status': 'NO_SHOW',
            'business_date': _businessDateIso,
          },
        ];
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'square',
        'vendor_entity_id': 'order_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 0,
        'covers_source': 'forecast_fallback',
        'opened_at': _dinnerInstantUtc,
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 250.00,
      },
    ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final result = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
      walkInOverride: const ReservationWalkInOverride(operatorWalkInCount: 0),
    );
    expect(result, isNotNull);
    expect(
      result!.input.covers,
      4 + 6,
      reason: 'SEATED party_size sums (10); NO_SHOW excluded',
    );
  });

  // ──────────────────── Per-position vendor wage class ─────────────────

  test('Humanity per-position fixture: rate × hours -> '
      'vendor_humanity_per_position_actual_dollars', () async {
    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'oracle_micros_simphony',
        'vendor_entity_id': 'check_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 10,
        'covers_source': 'direct',
        'opened_at': _dinnerInstantUtc,
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 400.00,
      },
    ];
    pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'humanity',
        'vendor_entity_id': 'shift_server_001',
        'employee_source_id': 'role:server',
        'role_name': 'server',
        'shift_start': _dinnerInstantUtc,
        'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
        'hours_worked': 4,
        'pay_rate': 22.0,
        'business_date': _businessDateIso,
      },
      <String, Object?>{
        'vendor_id': 'humanity',
        'vendor_entity_id': 'shift_cook_001',
        'employee_source_id': 'role:cook',
        'role_name': 'cook',
        'shift_start': _dinnerInstantUtc,
        'shift_end': _dinnerInstantUtc.add(const Duration(hours: 5)),
        'hours_worked': 5,
        'pay_rate': 24.0,
        'business_date': _businessDateIso,
      },
    ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final result = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
    );
    expect(result, isNotNull);
    expect(result!.input.actualFohLaborDollars, closeTo(4 * 22.0, 0.001));
    expect(result.input.actualBohLaborDollars, closeTo(5 * 24.0, 0.001));
    expect(
      result.provenance.laborDollarsProvenance,
      'vendor_humanity_per_position_actual_dollars',
    );
  });

  // ──────────────────── 7shifts perEmployeeWithDollars after upgrade ───

  test('7shifts post-.7S.upgrade is in perEmployeeWithDollars; aggregator '
      'consumes vendor-supplied total_pay -> '
      'vendor_seven_shifts_per_employee_actual_dollars', () async {
    // Direct sidecar assertion (.7S.upgrade landed; the sidecar lookup
    // is the contract — production aggregator dispatches on it).
    expect(
      laborWageSourceClassFor('seven_shifts'),
      LaborWageSourceClass.perEmployeeWithDollars,
      reason:
          '8.spine-bridge.7S.upgrade flipped 7shifts via '
          '/reports/hours_and_wages',
    );

    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'oracle_micros_simphony',
        'vendor_entity_id': 'check_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 10,
        'covers_source': 'direct',
        'opened_at': _dinnerInstantUtc,
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 400.00,
      },
    ];
    pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'seven_shifts',
        'vendor_entity_id': 'punch_001',
        'employee_source_id': 'emp_1',
        'role_name': 'server',
        'shift_start': _dinnerInstantUtc,
        'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
        'hours_worked': 4,
        // Vendor-supplied per-shift total_pay (the /reports/hours_and_wages
        // upgrade path — what the .7S.upgrade lane wired in).
        'actual_dollars': 95.50,
        'business_date': _businessDateIso,
      },
      <String, Object?>{
        'vendor_id': 'seven_shifts',
        'vendor_entity_id': 'punch_002',
        'employee_source_id': 'emp_2',
        'role_name': 'cook',
        'shift_start': _dinnerInstantUtc,
        'shift_end': _dinnerInstantUtc.add(const Duration(hours: 5)),
        'hours_worked': 5,
        'actual_dollars': 120.00,
        'business_date': _businessDateIso,
      },
    ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final result = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
    );
    expect(result, isNotNull);
    expect(result!.input.actualFohLaborDollars, closeTo(95.50, 0.001));
    expect(result.input.actualBohLaborDollars, closeTo(120.00, 0.001));
    expect(
      result.provenance.laborDollarsProvenance,
      'vendor_seven_shifts_per_employee_actual_dollars',
    );
  });

  // ──────────────────── Manual entry per daypart (acceptance #14) ──────

  test('operator manual entry per daypart -> sourceSystem = '
      'operator_manual_entry; provenance = '
      'operator_manual_entry_per_daypart', () async {
    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
    pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
      'setting_id': 'das_001',
      'operator_id': _opA,
      'location_id': _locA,
      'covers_source_lunch': 'vendor',
      'covers_source_dinner': 'manual',
      'covers_source_late_night': 'vendor',
      'covers_manual_entries': <String, Map<String, int>>{
        _businessDateIso: <String, int>{'dinner': 187},
      },
      'wage_source': 'vendor',
      'created_at': DateTime.utc(2026, 5, 1),
      'updated_at': DateTime.utc(2026, 5, 4),
      'updated_by': null,
    };
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'square',
        'vendor_entity_id': 'order_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 50,
        'covers_source': 'direct',
        'opened_at': _dinnerInstantUtc,
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 1000.00,
      },
    ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final result = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
    );
    expect(result, isNotNull);
    expect(result!.input.covers, 187);
    expect(result.input.sourceSystem, 'operator_manual_entry');
    expect(
      result.provenance.coversProvenance,
      'operator_manual_entry_per_daypart',
    );
  });

  test('wage source = manual_mix -> labor_dollars provenance = '
      'target_wage_substituted (acceptance #15)', () async {
    final pool = _SmokeFakePool()..seedLocation(_opA, _locA);
    pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
      'setting_id': 'das_001',
      'operator_id': _opA,
      'location_id': _locA,
      'covers_source_lunch': 'vendor',
      'covers_source_dinner': 'vendor',
      'covers_source_late_night': 'vendor',
      'covers_manual_entries': <String, Map<String, int>>{},
      'wage_source': 'manual_mix',
      'created_at': DateTime.utc(2026, 5, 1),
      'updated_at': DateTime.utc(2026, 5, 4),
      'updated_by': null,
    };
    pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'oracle_micros_simphony',
        'vendor_entity_id': 'check_001',
        'vendor_modified_at': _dinnerInstantUtc,
        'covers': 10,
        'covers_source': 'direct',
        'opened_at': _dinnerInstantUtc,
        'closed_at': _dinnerInstantUtc,
        'business_date': _businessDateIso,
        'actual_sales': 400.00,
      },
    ];
    pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
      <String, Object?>{
        'vendor_id': 'seven_shifts',
        'vendor_entity_id': 'punch_001',
        'employee_source_id': 'emp_1',
        'role_name': 'server',
        'shift_start': _dinnerInstantUtc,
        'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
        'hours_worked': 4,
        'actual_dollars':
            95.50, // vendor exposes dollars but operator overrides.
        'business_date': _businessDateIso,
      },
    ];

    final wrapper = TenantTransactionWrapper(pool);
    final aggregator = CanonicalFactToClosedShiftInputAggregator(wrapper);
    final result = await aggregator.aggregate(
      operatorId: _opA,
      locationId: _locA,
      restaurantId: _restaurantA,
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: Daypart.dinner,
      periodDefinition: _dinnerPeriod,
    );
    expect(result, isNotNull);
    expect(
      result!.provenance.laborDollarsProvenance,
      'target_wage_substituted',
      reason:
          'manual_mix forces operator-mix override regardless of vendor '
          'capability',
    );
  });

  // ──────────────────── Architectural compliance grep audit ────────────

  group('Architectural compliance audit', () {
    test(
      'no `vendorProvidedForecast` enum or field anywhere under lib/',
      () async {
        // Forecast is F&F-computed (Layer 6 in core_app_architecture.md).
        // No vendor ever produces a forecast — this rules out any sneaky
        // re-introduction of vendor-supplied forecasts.
        final dirs = <String>[
          'lib/services/integration',
          'lib/infrastructure/persistence/postgres',
          'lib/services/sync',
          'lib/services/data_accuracy',
          'lib/admin',
          'lib/operator_web',
          'lib/domain',
        ];
        for (final dir in dirs) {
          final root = Directory(dir);
          if (!root.existsSync()) continue;
          for (final entry in root.listSync(recursive: true)) {
            if (entry is! File) continue;
            if (!entry.path.endsWith('.dart')) continue;
            final source = entry.readAsStringSync();
            expect(
              source.contains('vendorProvidedForecast'),
              isFalse,
              reason:
                  'Layer 6 violation in ${entry.path} — forecast is '
                  'F&F-computed, never vendor-supplied',
            );
          }
        }
      },
    );

    test('spine-bridge code does not write to open_shift_snapshots', () {
      // Out-of-scope per integration_spine_architecture_contract.md
      // "Out of scope (binding)" — the spine bridge wires the closed-
      // shift truth path only. Live in-progress goes to a follow-up
      // sprint (`8.spine-bridge-live`).
      const spineBridgeFiles = <String>[
        'lib/services/integration/canonical_fact_to_closed_shift_input.dart',
        'lib/services/integration/labor_wage_source_class.dart',
        'lib/services/integration/polling_cadence_resolver.dart',
        'lib/services/integration/polling_tier_presets.dart',
        'lib/services/integration/canonical_sink.dart',
        'lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart',
        'lib/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart',
        'lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart',
        'lib/infrastructure/persistence/postgres/libro_postgres_sink.dart',
        'lib/services/data_accuracy/data_accuracy_settings_repository.dart',
      ];
      for (final relPath in spineBridgeFiles) {
        final file = File(relPath);
        if (!file.existsSync()) continue;
        final source = file.readAsStringSync();
        expect(
          source.contains('open_shift_snapshots'),
          isFalse,
          reason:
              'open_shift_snapshots write found in $relPath; out of '
              'scope per integration_spine_architecture_contract.md',
        );
      }
    });

    test('Oracle Simphony adapter uses Gen2 field path '
        'items[].header.guestCount; numOfGst / numberOfGuests absent', () {
      final source = File(
        'lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart',
      ).readAsStringSync();
      expect(
        source.contains("header['guestCount']"),
        isTrue,
        reason: '2026-05-05 falsehood correction #5: Gen2 path required',
      );
      expect(
        source.contains('numOfGst'),
        isFalse,
        reason: 'Gen1 path forbidden after 2026-05-05 correction',
      );
      expect(
        source.contains('numberOfGuests'),
        isFalse,
        reason: 'adapter constant guess forbidden after 2026-05-05 correction',
      );
    });

    test('ADP webhookSupport = autoRegister (not pollOnly) — '
        'cadence picker excludes ADP', () {
      final source = File(
        'lib/integrations/labor/adp_labor_adapter.dart',
      ).readAsStringSync();
      expect(
        source.contains('webhookSupport: VendorWebhookSupport.autoRegister'),
        isTrue,
        reason: '2026-05-05 falsehood correction #1: ADP is webhook-driven',
      );
    });

    test('aggregator provenance string template binds vendor_<id>_*', () async {
      final source = await File(
        'lib/services/integration/canonical_fact_to_closed_shift_input.dart',
      ).readAsString();
      // Sanity: provenance literals follow the contract naming rule.
      expect(source.contains("'vendor_\$posVendorId'"), isTrue);
      expect(
        source.contains(
          "'vendor_\${reservationVendorId}_seated_plus_operator_walk_in_count'",
        ),
        isTrue,
      );
      expect(
        source.contains(
          "'vendor_\${vendorBase}_covers_unavailable_app_forecast_substituted'",
        ),
        isTrue,
      );
      expect(
        source.contains(
          "'vendor_\${laborVendorId}_per_employee_actual_dollars'",
        ),
        isTrue,
      );
      expect(
        source.contains(
          "'vendor_\${laborVendorId}_per_position_actual_dollars'",
        ),
        isTrue,
      );
      expect(source.contains("'operator_manual_entry_per_daypart'"), isTrue);
      expect(source.contains("'target_wage_substituted'"), isTrue);
    });
  });
}

// ─── Test fakes ──────────────────────────────────────────────────────

/// Unified fake pool for the smoke harness — composes the aggregator-side
/// SELECT surface and the writer-side INSERT surface in one collaborator.
class _SmokeFakePool implements PostgresPool {
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> dataAccuracySettingsByTenant =
      <String, Map<String, Object?>>{};
  final Map<String, List<Map<String, Object?>>> coverFactsByOperatorLocation =
      <String, List<Map<String, Object?>>>{};
  final Map<String, List<Map<String, Object?>>> laborPunchesByOperatorLocation =
      <String, List<Map<String, Object?>>>{};
  final Map<String, List<Map<String, Object?>>>
  reservationFactsByOperatorLocation = <String, List<Map<String, Object?>>>{};
  final Map<String, String> shiftRecordTpvBySlot = <String, String>{};
  final Map<String, Map<String, Object?>> shiftRecords =
      <String, Map<String, Object?>>{};
  final List<_SmokeFakeTransaction> transactions = <_SmokeFakeTransaction>[];

  void seedLocation(String operatorId, String locationId) {
    _locations['$operatorId|$locationId'] = <String, Object?>{
      'timezone': 'America/Toronto',
      'business_day_rollover_hour': 4,
    };
  }

  Map<String, Object?>? readLocation(String operatorId, String locationId) =>
      _locations['$operatorId|$locationId'];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _SmokeFakeTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _SmokeFakeTransaction implements PostgresTransaction {
  _SmokeFakeTransaction(this.pool);
  final _SmokeFakePool pool;
  final Map<String, String> setConfigCalls = <String, String>{};
  bool committed = false;

  void _captureSetConfig(String sql, PostgresParameters parameters) {
    final regex = RegExp(r"set_config\('(?<name>[a-zA-Z0-9_.]+)'");
    final match = regex.firstMatch(sql);
    if (match == null) return;
    final name = match.namedGroup('name')!;
    final value = parameters['value'];
    if (value is String) setConfigCalls[name] = value;
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return const <PostgresRow>[];
    }
    if (sql.contains('from data_accuracy_settings')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final row = pool.dataAccuracySettingsByTenant['$operatorId|$locationId'];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains(
      'select timezone, business_day_rollover_hour from public.locations',
    )) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final row = pool.readLocation(operatorId, locationId);
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains('from public.cover_facts')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      return pool
              .coverFactsByOperatorLocation['$operatorId|$locationId|$businessDate'] ??
          const <PostgresRow>[];
    }
    if (sql.contains('from public.labor_punches')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      return pool
              .laborPunchesByOperatorLocation['$operatorId|$locationId|$businessDate'] ??
          const <PostgresRow>[];
    }
    if (sql.contains('from public.reservation_facts')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      return pool
              .reservationFactsByOperatorLocation['$operatorId|$locationId|$businessDate'] ??
          const <PostgresRow>[];
    }
    if (sql.contains('from public.shift_records')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      final daypart = parameters['daypart'] as String;
      final tpv = pool
          .shiftRecordTpvBySlot['$operatorId|$locationId|$businessDate|$daypart'];
      if (tpv == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'target_profile_version_id': tpv},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return 0;
    }
    if (sql.contains('insert into public.shift_records')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      final daypart = parameters['daypart'] as String;
      final key = '$operatorId|$locationId|$businessDate|$daypart';
      pool.shiftRecords[key] = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'restaurant_id': parameters['restaurant_id'],
        'week_id': parameters['week_id'],
        'day_label': parameters['day_label'],
        'daypart': daypart,
        'status': parameters['status'],
        'business_date': businessDate,
        'covers': parameters['covers'],
        'forecast_covers': parameters['forecast_covers'],
        'actual_sales': parameters['actual_sales'],
        'ppa': parameters['ppa'],
        'cplh': parameters['cplh'],
        'splh': parameters['splh'],
        'foh_hours': parameters['foh_hours'],
        'boh_hours': parameters['boh_hours'],
        'foh_labor_dollar': parameters['foh_labor_dollar'],
        'boh_labor_dollar': parameters['boh_labor_dollar'],
        'theoretical_labor_pct': parameters['theoretical_labor_pct'],
        'primary_lever': parameters['primary_lever'],
        'target_profile_id': parameters['target_profile_id'],
        'target_profile_version_id': parameters['target_profile_version_id'],
        'target_source_type': parameters['target_source_type'],
        'target_cplh': parameters['target_cplh'],
        'target_splh': parameters['target_splh'],
        'target_ppa': parameters['target_ppa'],
        'target_foh_wage': parameters['target_foh_wage'],
        'target_boh_wage': parameters['target_boh_wage'],
        'opz_floor_cplh': parameters['opz_floor_cplh'],
        'opz_ceiling_cplh': parameters['opz_ceiling_cplh'],
        'theoretical_foh_labor_pct': parameters['theoretical_foh_labor_pct'],
        'theoretical_boh_labor_pct': parameters['theoretical_boh_labor_pct'],
        'source_system': parameters['source_system'],
        'source_shift_id': parameters['source_shift_id'],
        'covers_provenance': parameters['covers_provenance'],
        'labor_dollars_provenance': parameters['labor_dollars_provenance'],
      };
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {}
}

// Sync proxy fake matching the spine-bridge.3 test pattern.
class _Page {
  const _Page({required this.records, required this.nextCursor});
  final List<ShiftRecord> records;
  final String? nextCursor;
}

class _SmokeSyncProxyClient implements SyncProxyClient {
  final List<_Page> _shiftPages = <_Page>[];
  List<DemoModeRecord> _demoModeStates = const <DemoModeRecord>[];
  DataAccuracySettingsSnapshot? _dataAccuracySettings;
  ForgeFlowPollingTierAssignmentSnapshot? _pollingTierAssignment;

  void scriptShiftPages(List<_Page> pages) {
    _shiftPages
      ..clear()
      ..addAll(pages);
  }

  // ignore: unused_element
  void scriptDemoModeStates(List<DemoModeRecord> states) {
    _demoModeStates = states;
  }

  void scriptDataAccuracySettings(DataAccuracySettingsSnapshot? snap) {
    _dataAccuracySettings = snap;
  }

  void scriptPollingTierAssignment(
    ForgeFlowPollingTierAssignmentSnapshot? snap,
  ) {
    _pollingTierAssignment = snap;
  }

  @override
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async {
    if (_shiftPages.isEmpty) {
      return const ShiftRecordPage(records: <ShiftRecord>[], nextCursor: null);
    }
    final page = _shiftPages.removeAt(0);
    return ShiftRecordPage(records: page.records, nextCursor: page.nextCursor);
  }

  @override
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  }) async => const OpenShiftSnapshotPage(
    snapshots: <OpenShiftSnapshot>[],
    nextCursor: null,
  );

  @override
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  }) async => null;

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async => _demoModeStates;

  @override
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  }) async => _dataAccuracySettings;

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) async => const <DataAccuracyServicePeriodSetting>[];

  @override
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async => _pollingTierAssignment;

  @override
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  }) async => null;
}

class _BusListener {
  _BusListener(this.bus) {
    _listener = _onFire;
    bus.addListener(_listener);
  }
  final AppRuntimeInvalidationBus bus;
  late final void Function() _listener;
  int count = 0;
  void _onFire() => count++;
  void detach() => bus.removeListener(_listener);
}
