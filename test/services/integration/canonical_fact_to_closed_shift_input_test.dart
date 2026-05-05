// Phase 8 spine-bridge Lane .2 — aggregator test suite.
//
// Tests cover the Block 2 A-M acceptance items per the prompt and
// `docs/contracts/integration_spine_architecture_contract.md`
// "Sub-lane shape -> .2":
//
//   A. Trio aggregation (Oracle + QBT + Libro) — vendor provenance
//      strings.
//   B. Multi-vendor POS for same daypart -> MultiplePosAdaptersException.
//   C. Square fact lacks covers + forecast available ->
//      vendor_square_covers_unavailable_app_forecast_substituted.
//   D. Manual entry for daypart -> operator_manual_entry_per_daypart;
//      sourceSystem = operator_manual_entry.
//   E. Reservation+walk-in Pattern A: Square+Libro operator with
//      seated + operator_walk_in_count -> covers = sum;
//      provenance = vendor_libro_seated_plus_operator_walk_in_count.
//   F. Tock fixture (no seated_at) -> daypart bucketed by
//      reservation_at; SEATED party_size sums.
//   G. Wage source perPositionWithRates (Humanity) -> labor_dollars
//      = rate × hours; provenance =
//      vendor_humanity_per_position_actual_dollars.
//   H. Wage source manual_mix -> target_wage_substituted.
//   I. perEmployeeWithRates (QBT) -> labor_dollars = rate × duration;
//      provenance includes 'per_employee_rates' qualifier.
//   J. Wage source hoursOnly (ADP, Push) -> fallback
//      target_wage_substituted; provenance =
//      vendor_<id>_dollars_unavailable_target_wage_substituted.
//   L. RLS + tenancy: every aggregator transaction injects
//      app.operator_id / app.location_id via set_config. (Concern A —
//      target_profile_version_id preservation — is in the writer test
//      where the writer side can be exercised end-to-end.)
//   M. Banned-items grep across the aggregator source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _restaurantA = 'demo_restaurant_001';

final DateTime _businessDate = DateTime.utc(2026, 5, 4);

// Period definition for "dinner" in America/Toronto (17:00–22:00 local).
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

// 22:00 UTC = 18:00 EDT (America/Toronto, May 2026) → buckets to
// dinner. Used by all three canonical fact tables.
final DateTime _dinnerInstantUtc = DateTime.utc(2026, 5, 4, 22, 0, 0);

void main() {
  // ─────────────────────────── A — trio aggregation ───────────────────────
  group('aggregator — A. trio aggregation (Oracle + QBT + Libro)', () {
    test('writes ClosedShiftInput + provenance with vendor strings for '
        'covers and labor dollars', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
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
      pool.reservationFactsByOperatorLocation[
          '$_opA|$_locA|$_businessDateIso'] = [
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

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

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
      expect(result!.input.covers, 5,
          reason: 'covers from Oracle Simphony cover_facts row');
      expect(result.input.actualSales, closeTo(124.85, 0.001));
      expect(result.input.actualFohHours, 5);
      expect(result.input.actualBohHours, 6);
      // QuickBooks Time wage class is perEmployeeWithRates; compute
      // dollars via rate × hours per punch.
      expect(result.input.actualFohLaborDollars, closeTo(5 * 18.0, 0.001));
      expect(result.input.actualBohLaborDollars, closeTo(6 * 20.0, 0.001));
      expect(result.input.sourceSystem, 'oracle_micros_simphony');
      expect(result.provenance.coversProvenance,
          'vendor_oracle_micros_simphony');
      expect(
        result.provenance.laborDollarsProvenance,
        'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
      );
    });
  });

  // ─────────────────── B — multiple POS adapters at same slot ─────────────
  group('aggregator — B. MultiplePosAdaptersException', () {
    test('two POS vendors writing the same daypart -> exception', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
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
          'actual_sales': 100.00,
        },
        <String, Object?>{
          'vendor_id': 'toast',
          'vendor_entity_id': 'check_002',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 3,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc.subtract(const Duration(hours: 1)),
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 90.00,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      await expectLater(
        () => aggregator.aggregate(
          operatorId: _opA,
          locationId: _locA,
          restaurantId: _restaurantA,
          businessDate: _businessDate,
          weekId: '2026-W18',
          dayLabel: 'Mon',
          daypart: Daypart.dinner,
          periodDefinition: _dinnerPeriod,
        ),
        throwsA(isA<MultiplePosAdaptersException>()),
      );
    });
  });

  // ─────────────────── C — Square coversFieldExposed=false → forecast ─────
  group('aggregator — C. forecast substitution when POS lacks covers', () {
    test('Square (coversFieldExposed=false) row + forecast available -> '
        'vendor_square_covers_unavailable_app_forecast_substituted',
        () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      // Square fact lacks covers (covers = 0) but actual_sales is
      // populated (Square exposes sales but not covers per 2026-05-05
      // confirmation).
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

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final forecast = DemandForecastContext(
        restaurantId: _restaurantA,
        anchorBusinessDate: _businessDateIso,
        baselineTotalCovers: 1500,
        baselineWeeklyAvgCovers: 175,
        baselineWeeksRepresented: 60 / 7,
        recentThreeWeekTotalCovers: 525,
        recentThreeWeekWeeklyAvgCovers: 175,
        recentTrendDeltaCovers: 0,
        // 210 weekly / 7 days / 3 dayparts ≈ 10 per daypart.
        resolvedWeeklyForecastCovers: 210,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: _businessDateIso,
      );

      final result = await aggregator.aggregate(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        daypart: Daypart.dinner,
        periodDefinition: _dinnerPeriod,
        forecastContext: forecast,
      );

      expect(result, isNotNull);
      expect(result!.input.covers, greaterThan(0),
          reason: 'forecast share allocates a positive integer per daypart');
      expect(
        result.provenance.coversProvenance,
        'vendor_square_covers_unavailable_app_forecast_substituted',
      );
      expect(result.input.sourceSystem, 'square');
    });
  });

  // ─────────────────── D — operator manual entry ──────────────────────────
  group('aggregator — D. operator manual entry per daypart', () {
    test('manual entry overrides everything; provenance + sourceSystem '
        'reflect operator origin', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      // Seed operator preference: dinner = manual, value 187.
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
      // POS row exists but operator preference wins.
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

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

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
      expect(result.provenance.coversProvenance,
          'operator_manual_entry_per_daypart');
    });
  });

  // ─────────────────── E — reservation + walk-in Pattern A ────────────────
  group('aggregator — E. reservation+walk-in (Square + Libro)', () {
    test('seated party_size sum + operator walk-in count -> '
        'vendor_libro_seated_plus_operator_walk_in_count', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      // Square fact with no covers (POS does not expose covers).
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
          'actual_sales': 525.00,
        },
      ];
      // Libro reservations seated this daypart.
      pool.reservationFactsByOperatorLocation[
          '$_opA|$_locA|$_businessDateIso'] = [
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
          'party_size': 6,
          'status': 'SEATED',
          'seated_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final result = await aggregator.aggregate(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        daypart: Daypart.dinner,
        periodDefinition: _dinnerPeriod,
        walkInOverride:
            const ReservationWalkInOverride(operatorWalkInCount: 25),
      );

      expect(result, isNotNull);
      // 4 + 6 seated + 25 walk-in = 35.
      expect(result!.input.covers, 35);
      expect(result.input.sourceSystem, 'libro');
      expect(
        result.provenance.coversProvenance,
        'vendor_libro_seated_plus_operator_walk_in_count',
      );
    });
  });

  // ─────────────────── F — Tock (no seated_at; serviceDateTimestamp) ──────
  group('aggregator — F. Tock daypart bucketing without seated_at', () {
    test('Tock reservation_facts with no seated_at still bucket by '
        'reservation_at; SEATED party_size sums', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.reservationFactsByOperatorLocation[
          '$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'tock',
          'vendor_entity_id': 'res_001',
          // reservation_at populated from Tock's serviceDateTimestamp;
          // seated_at deliberately null per the 2026-05-05 binding
          // correction (Tock public docs do not expose seated_at).
          'reservation_at': _dinnerInstantUtc,
          'party_size': 8,
          'status': 'SEATED',
          'seated_at': null,
          'business_date': _businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final result = await aggregator.aggregate(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        daypart: Daypart.dinner,
        periodDefinition: _dinnerPeriod,
        walkInOverride:
            const ReservationWalkInOverride(operatorWalkInCount: 0),
      );

      expect(result, isNotNull);
      // Pattern A path: 8 seated + 0 walk-in = 8.
      expect(result!.input.covers, 8);
      expect(result.provenance.coversProvenance,
          'vendor_tock_seated_plus_operator_walk_in_count');
    });
  });

  // ─────────────────── G — perPositionWithRates (Humanity) ────────────────
  group('aggregator — G. wage perPositionWithRates (Humanity)', () {
    test('Humanity per-position rates compute dollars via rate × hours', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      // POS covers from Oracle so the aggregator has a sales source.
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 12,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 480.00,
        },
      ];
      pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'humanity',
          'vendor_entity_id': 'sched_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': _dinnerInstantUtc,
          'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 4,
          'pay_rate': 22.0,
          'business_date': _businessDateIso,
        },
        <String, Object?>{
          'vendor_id': 'humanity',
          'vendor_entity_id': 'sched_002',
          'employee_source_id': 'emp_2',
          'role_name': 'cook',
          'shift_start': _dinnerInstantUtc,
          'shift_end': _dinnerInstantUtc.add(const Duration(hours: 5)),
          'hours_worked': 5,
          'pay_rate': 24.0,
          'business_date': _businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

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
  });

  // ─────────────────── H — manual_mix override ────────────────────────────
  group('aggregator — H. wage manual_mix override', () {
    test('wage_source = manual_mix forces target_wage_substituted '
        'regardless of vendor capability', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
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
      // QBT rates exist but manual_mix override forces ignoring them.
      pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': _dinnerInstantUtc,
          'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 4,
          'pay_rate': 18.0,
          'business_date': _businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

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
      // manual_mix path emits null dollars so ShiftFactBuilder takes
      // the wage*hours fallback; provenance is target_wage_substituted.
      expect(result!.input.actualFohLaborDollars, isNull);
      expect(result.input.actualBohLaborDollars, isNull);
      expect(result.provenance.laborDollarsProvenance,
          'target_wage_substituted');
    });
  });

  // ─────────────────── I — perEmployeeWithRates (QBT) ─────────────────────
  group('aggregator — I. wage perEmployeeWithRates (QBT)', () {
    test('QuickBooks Time per-employee rates compute dollars via '
        'rate × duration; provenance carries the per_employee_rates '
        'qualifier', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
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
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': _dinnerInstantUtc,
          'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 4,
          'pay_rate': 18.0,
          'business_date': _businessDateIso,
        },
        <String, Object?>{
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_002',
          'employee_source_id': 'emp_2',
          'role_name': 'cook',
          'shift_start': _dinnerInstantUtc,
          'shift_end': _dinnerInstantUtc.add(const Duration(hours: 6)),
          'hours_worked': 6,
          'pay_rate': 22.0,
          'business_date': _businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

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
      expect(result!.input.actualFohLaborDollars, closeTo(4 * 18.0, 0.001));
      expect(result.input.actualBohLaborDollars, closeTo(6 * 22.0, 0.001));
      expect(
        result.provenance.laborDollarsProvenance,
        'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
        reason:
            'per_employee_rates qualifier disambiguates from perEmployeeWithDollars',
      );
    });
  });

  // ─────────────────── J — hoursOnly (ADP, Push Operations) ───────────────
  group('aggregator — J. wage hoursOnly fallback', () {
    test('ADP punches with no rates -> '
        'vendor_adp_dollars_unavailable_target_wage_substituted', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
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
          'vendor_id': 'adp',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': _dinnerInstantUtc,
          'shift_end': _dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 4,
          'pay_rate': null, // ADP wage ingestion deferred V1.
          'business_date': _businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

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
      expect(result!.input.actualFohHours, 4);
      expect(result.input.actualFohLaborDollars, isNull);
      expect(
        result.provenance.laborDollarsProvenance,
        'vendor_adp_dollars_unavailable_target_wage_substituted',
      );
    });

    test('Push Operations same hoursOnly fallback', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
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
          'vendor_id': 'push_operations',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'cook',
          'shift_start': _dinnerInstantUtc,
          'shift_end': _dinnerInstantUtc.add(const Duration(hours: 5)),
          'hours_worked': 5,
          'pay_rate': null,
          'business_date': _businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

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
        'vendor_push_operations_dollars_unavailable_target_wage_substituted',
      );
    });
  });

  // ─────────────────── L — RLS + tenancy ─────────────────────────────────
  group('aggregator — L. RLS + tenancy injection', () {
    test('every aggregator transaction injects '
        'app.operator_id / app.location_id via set_config', () async {
      final pool = _FakePool()
        ..seedLocation(_opA, _locA)
        ..seedLocation(_opB, _locB);
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
      pool.coverFactsByOperatorLocation['$_opB|$_locB|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 9,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 200.00,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final resultA = await aggregator.aggregate(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        daypart: Daypart.dinner,
        periodDefinition: _dinnerPeriod,
      );
      final resultB = await aggregator.aggregate(
        operatorId: _opB,
        locationId: _locB,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        daypart: Daypart.dinner,
        periodDefinition: _dinnerPeriod,
      );

      // Tenant isolation: operator A and operator B see different
      // covers because the fake keys rows by the tenant tuple.
      expect(resultA!.input.covers, 5);
      expect(resultB!.input.covers, 9);

      // Every transaction set both tenant keys.
      expect(pool.transactions, isNotEmpty);
      for (final tx in pool.transactions) {
        expect(tx.setConfigCalls['app.operator_id'], isNotNull,
            reason: 'tenant SET LOCAL must run on every transaction');
        expect(tx.setConfigCalls['app.location_id'], isNotNull);
      }
    });
  });

  // ─────────────────── M — banned-items grep ──────────────────────────────
  group('aggregator — M. banned-items grep', () {
    test('aggregator + sidecar source contain zero V1 lean cut 2 banned '
        'items', () async {
      const sources = <String>[
        'lib/services/integration/canonical_fact_to_closed_shift_input.dart',
        'lib/services/integration/labor_wage_source_class.dart',
        'lib/domain/models/aggregator_provenance_context.dart',
        'lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart',
      ];
      const banned = <String>[
        'KMS',
        'pgp_sym_encrypt_kms',
        'rotateSigningKey',
        'parse_warnings',
        'parse_partial',
        'kStrictReplayFiveMinute',
        'pg_try_advisory_lock',
        'pg_advisory_lock',
        'sigtermDrainHandler',
        'inboundWebhookDLQTile',
        'raw_payload_partition',
        'pg_partman_raw',
      ];
      for (final relPath in sources) {
        final source = await File(relPath).readAsString();
        for (final token in banned) {
          expect(
            source.toLowerCase().contains(token.toLowerCase()),
            isFalse,
            reason: 'banned item present in $relPath: $token',
          );
        }
      }
    });
  });
}

// ─── Helpers + fakes ──────────────────────────────────────────────────

String get _businessDateIso => '${_businessDate.year.toString().padLeft(4, '0')}'
    '-${_businessDate.month.toString().padLeft(2, '0')}'
    '-${_businessDate.day.toString().padLeft(2, '0')}';

class _FakePool implements PostgresPool {
  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> dataAccuracySettingsByTenant =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, business_date_iso)`.
  final Map<String, List<Map<String, Object?>>> coverFactsByOperatorLocation =
      <String, List<Map<String, Object?>>>{};
  final Map<String, List<Map<String, Object?>>>
      laborPunchesByOperatorLocation =
      <String, List<Map<String, Object?>>>{};
  final Map<String, List<Map<String, Object?>>>
      reservationFactsByOperatorLocation =
      <String, List<Map<String, Object?>>>{};

  /// Keyed by `(operator_id, location_id, business_date_iso, daypart)`.
  /// Pre-seed when a test wants to exercise priorTargetProfileVersionId.
  final Map<String, String> shiftRecordTpvBySlot = <String, String>{};

  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

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
    final tx = _FakeTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this.pool);

  final _FakePool pool;
  final Map<String, String> setConfigCalls = <String, String>{};
  bool committed = false;

  void _captureSetConfig(String sql, PostgresParameters parameters) {
    final regex = RegExp(r"set_config\('(?<name>[a-zA-Z0-9_.]+)'");
    final match = regex.firstMatch(sql);
    if (match == null) return;
    final name = match.namedGroup('name')!;
    final value = parameters['value'];
    if (value is String) {
      setConfigCalls[name] = value;
    }
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
        'select timezone, business_day_rollover_hour from public.locations')) {
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
      return pool.coverFactsByOperatorLocation[
              '$operatorId|$locationId|$businessDate'] ??
          const <PostgresRow>[];
    }
    if (sql.contains('from public.labor_punches')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      return pool.laborPunchesByOperatorLocation[
              '$operatorId|$locationId|$businessDate'] ??
          const <PostgresRow>[];
    }
    if (sql.contains('from public.reservation_facts')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      return pool.reservationFactsByOperatorLocation[
              '$operatorId|$locationId|$businessDate'] ??
          const <PostgresRow>[];
    }
    if (sql.contains('from public.shift_records')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      final daypart = parameters['daypart'] as String;
      final tpv = pool.shiftRecordTpvBySlot[
          '$operatorId|$locationId|$businessDate|$daypart'];
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
    return 0;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {}
}
