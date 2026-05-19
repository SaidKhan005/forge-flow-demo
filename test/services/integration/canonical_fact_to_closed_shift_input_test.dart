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
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/daypart_bucketer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _restaurantA = 'demo_restaurant_001';
const String _timingProfileA = '33333333-3333-4333-8333-333333333333';
const String _timingProfileB = '44444444-4444-4444-8444-444444444444';

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

void _seedReservationPlusWalkinPreference(
  _FakePool pool,
  String servicePeriodId,
) {
  pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
    'setting_id': 'das_reservation_plus_walkin_$servicePeriodId',
    'operator_id': _opA,
    'location_id': _locA,
    'covers_manual_entries': <String, Map<String, int>>{},
    'wage_source': 'vendor',
    'walk_in_handling_mode': 'walk_ins_added_to_reservations',
    'walk_in_manual_entries': <String, Object?>{},
    'created_at': DateTime.utc(2026, 5, 1),
    'updated_at': DateTime.utc(2026, 5, 4),
    'updated_by': null,
  };
  pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|$servicePeriodId'] =
      <String, Object?>{
        'id': 'das_rspw_$servicePeriodId',
        'operator_id': _opA,
        'location_id': _locA,
        'service_period_key': servicePeriodId,
        'covers_source': 'reservation_plus_walkin',
        'wage_source': 'vendor_per_employee',
        'effective_at_business_date': '2026-05-01',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 1),
        'updated_by': null,
      };
}

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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );

      expect(result, isNotNull);
      expect(
        result!.input.covers,
        5,
        reason: 'covers from Oracle Simphony cover_facts row',
      );
      expect(result.input.actualSales, closeTo(124.85, 0.001));
      // Per-Daypart V1 Slice 1.5: hours are per-period overlap. Server
      // 17:00–22:00 fits entirely inside dinner (5h). Cook 17:00–23:00
      // overflows dinner end at 22:00; only 5h count.
      expect(result.input.actualFohHours, 5);
      expect(result.input.actualBohHours, 5);
      // QuickBooks Time wage class is perEmployeeWithRates; compute
      // dollars via rate × period-overlap-hours per punch.
      expect(result.input.actualFohLaborDollars, closeTo(5 * 18.0, 0.001));
      expect(result.input.actualBohLaborDollars, closeTo(5 * 20.0, 0.001));
      expect(result.input.sourceSystem, 'oracle_micros_simphony');
      expect(
        result.provenance.coversProvenance,
        'vendor_oracle_micros_simphony',
      );
      expect(
        result.provenance.laborDollarsProvenance,
        'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
      );
    });
  });

  // ─────────────────── B — multiple POS adapters at same slot ─────────────
  group('aggregator - timing provenance', () {
    test('stamps ClosedShiftInput with the effective timing profile and '
        'service period used for bucketing', () async {
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
        businessTimingProfileId: _timingProfileA,
      );

      expect(result, isNotNull);
      expect(result!.input.businessTimingProfileId, _timingProfileA);
      expect(
        result.input.businessTimingProfileVersionId,
        _timingProfileA,
        reason: 'Lane 0 maps the V1 version id to the profile id',
      );
      expect(result.input.servicePeriodKey, 'dinner');
    });

    test(
      'carries prior closed timing provenance for replay preservation',
      () async {
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
        pool.shiftRecordProvenanceBySlot['$_opA|$_locA|$_businessDateIso|dinner'] =
            <String, Object?>{
              'target_profile_version_id': 'tpv_X',
              'business_timing_profile_id': _timingProfileA,
              'business_timing_profile_version_id': _timingProfileA,
              'service_period_key': 'dinner',
            };

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
          servicePeriodId: 'dinner',
          periodDefinition: _dinnerPeriod,
          businessTimingProfileId: _timingProfileB,
        );

        expect(result, isNotNull);
        expect(
          result!.input.businessTimingProfileId,
          _timingProfileB,
          reason: 'current bucketing still records the effective profile',
        );
        expect(result.provenance.hasPriorShiftRecord, isTrue);
        expect(result.provenance.priorTargetProfileVersionId, 'tpv_X');
        expect(result.provenance.priorBusinessTimingProfileId, _timingProfileA);
        expect(
          result.provenance.priorBusinessTimingProfileVersionId,
          _timingProfileA,
        );
        expect(result.provenance.priorServicePeriodKey, 'dinner');
      },
    );
  });

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
          servicePeriodId: 'dinner',
          periodDefinition: _dinnerPeriod,
        ),
        throwsA(isA<MultiplePosAdaptersException>()),
      );
    });
  });

  // ─────────────────── C — Square coversFieldExposed=false → forecast ─────
  group('aggregator — C. forecast substitution when POS lacks covers', () {
    test('Square (coversFieldExposed=false) row + forecast available -> '
        'vendor_square_covers_unavailable_app_forecast_substituted', () async {
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
        forecastContext: forecast,
      );

      expect(result, isNotNull);
      expect(
        result!.input.covers,
        greaterThan(0),
        reason: 'forecast share allocates a positive integer per daypart',
      );
      expect(
        result.provenance.coversProvenance,
        'vendor_square_covers_unavailable_app_forecast_substituted',
      );
      expect(result.input.sourceSystem, 'square');
    });

    test(
      'explicit forecast source wins before vendor covers are aggregated',
      () async {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
          'setting_id': 'das_forecast_explicit',
          'operator_id': _opA,
          'location_id': _locA,
          'covers_manual_entries': <String, Map<String, int>>{},
          'wage_source': 'vendor',
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 4),
          'updated_by': null,
        };
        pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
            <String, Object?>{
              'id': '99999999-9999-9999-9999-999999999993',
              'operator_id': _opA,
              'location_id': _locA,
              'service_period_key': 'dinner',
              'covers_source': 'forecast',
              'wage_source': 'vendor_per_employee',
              'effective_at_business_date': '2026-05-01',
              'created_at': DateTime.utc(2026, 5, 1),
              'updated_at': DateTime.utc(2026, 5, 1),
              'updated_by': null,
            };
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'toast',
            'vendor_entity_id': 'check_toast_forecast_explicit',
            'vendor_modified_at': _dinnerInstantUtc,
            'covers': 92,
            'covers_source': 'direct',
            'opened_at': _dinnerInstantUtc,
            'closed_at': _dinnerInstantUtc,
            'business_date': _businessDateIso,
            'actual_sales': 2310.50,
          },
        ];

        final forecast = DemandForecastContext(
          restaurantId: _restaurantA,
          anchorBusinessDate: _businessDateIso,
          baselineTotalCovers: 1500,
          baselineWeeklyAvgCovers: 175,
          baselineWeeksRepresented: 60 / 7,
          resolvedWeeklyForecastCovers: 210,
          coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
          builtAt: _businessDateIso,
        );

        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: _businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'dinner',
              periodDefinition: _dinnerPeriod,
              forecastContext: forecast,
            );

        expect(result, isNotNull);
        expect(result!.input.covers, 30);
        expect(result.input.sourceSystem, 'app_forecast');
        expect(result.provenance.coversProvenance, 'app_forecast_60_day_avg');
      },
    );
  });

  // ─────────────────── D — operator manual entry ──────────────────────────
  group('aggregator — D. operator manual entry per daypart', () {
    test('manual entry overrides everything; provenance + sourceSystem '
        'reflect operator origin', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      // Seed keyed operator preference: dinner = manual, value 187.
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
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999991',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
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
        servicePeriodId: 'dinner',
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

    test('manual source with no value returns null even when vendor and '
        'forecast data are present', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_manual_missing',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999992',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'toast',
          'vendor_entity_id': 'check_toast_manual_missing',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 92,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 2310.50,
        },
      ];

      final forecast = DemandForecastContext(
        restaurantId: _restaurantA,
        anchorBusinessDate: _businessDateIso,
        baselineTotalCovers: 1500,
        baselineWeeklyAvgCovers: 175,
        baselineWeeksRepresented: 60 / 7,
        resolvedWeeklyForecastCovers: 210,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: _businessDateIso,
      );

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: _businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: _dinnerPeriod,
            forecastContext: forecast,
          );

      expect(
        result,
        isNull,
        reason:
            'Manual is an explicit operator choice; missing manual covers '
            'means no closed shift for the period.',
      );
    });
  });

  // ───────── D-FU — Wave 2 MO-2-FU (Option A, fallback-only) ──────────────
  //
  // Manual entries in `covers_manual_entries` project into
  // `ShiftRecord.covers` ONLY when the active POS does NOT expose
  // covers (Square, Clover, or unknown vendor). When POS DOES expose
  // covers (Toast, Aloha, Lightspeed K-Series, Oracle MICROS Simphony,
  // Revel), the POS feed is the source of truth and manual entries are
  // ignored.
  group(
    'aggregator — D-FU. POS-fallback manual entries (Option A, MO-2-FU)',
    () {
      test('POS exposes covers (Toast) + manual entries present -> manual '
          'IGNORED; vendor wins', () async {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        // Toast row carries covers; capability mirror says Toast
        // exposes covers, so stage 2 must win even though the
        // operator typed a manual entry for the same slot.
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'toast',
            'vendor_entity_id': 'check_toast_001',
            'vendor_modified_at': _dinnerInstantUtc,
            'covers': 92,
            'covers_source': 'direct',
            'opened_at': _dinnerInstantUtc.subtract(const Duration(hours: 1)),
            'closed_at': _dinnerInstantUtc,
            'business_date': _businessDateIso,
            'actual_sales': 2310.50,
          },
        ];
        // Operator typed a manual entry for the same slot. Operator
        // preference is the default ('vendor'), so stage 1 does not
        // fire. The new stage 3.5 also does not fire because Toast
        // exposes covers (capability mirror).
        pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
          'setting_id': 'das_002',
          'operator_id': _opA,
          'location_id': _locA,
          'covers_source_lunch': 'vendor',
          'covers_source_dinner': 'vendor',
          'covers_source_late_night': 'vendor',
          'covers_manual_entries': <String, Map<String, int>>{
            _businessDateIso: <String, int>{'dinner': 500},
          },
          'wage_source': 'vendor',
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 4),
          'updated_by': null,
        };

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
          servicePeriodId: 'dinner',
          periodDefinition: _dinnerPeriod,
        );

        expect(result, isNotNull);
        expect(
          result!.input.covers,
          92,
          reason: 'Toast (coversFieldExposed=true) wins; manual ignored',
        );
        expect(result.input.sourceSystem, 'toast');
        expect(result.provenance.coversProvenance, 'vendor_toast');
      });

      test(
        'POS does NOT expose covers (Square) + manual entries present -> '
        'manual projected with operator_manual_entry_fallback_pos_not_exposed',
        () async {
          final pool = _FakePool()..seedLocation(_opA, _locA);
          // Square row exists but POS does not expose covers
          // (coversFieldExposed=false); stage 2 short-circuits because
          // summed covers == 0. Stage 3.5 (new) fires because the
          // operator typed a manual entry for the slot.
          pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
              [
                <String, Object?>{
                  'vendor_id': 'square',
                  'vendor_entity_id': 'order_sq_001',
                  'vendor_modified_at': _dinnerInstantUtc,
                  'covers': 0,
                  'covers_source': 'forecast_fallback',
                  'opened_at': _dinnerInstantUtc,
                  'closed_at': _dinnerInstantUtc,
                  'business_date': _businessDateIso,
                  'actual_sales': 850.00,
                },
              ];
          pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
            'setting_id': 'das_003',
            'operator_id': _opA,
            'location_id': _locA,
            'covers_source_lunch': 'vendor',
            'covers_source_dinner': 'vendor',
            'covers_source_late_night': 'vendor',
            'covers_manual_entries': <String, Map<String, int>>{
              _businessDateIso: <String, int>{'dinner': 73},
            },
            'wage_source': 'vendor',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 4),
            'updated_by': null,
          };

          final aggregator = CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          );

          // Seed a forecast context too; the new stage 3.5 must beat
          // stage 4 (forecast substitution) when manual entries are
          // present.
          final forecast = DemandForecastContext(
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
          );

          final result = await aggregator.aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: _businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: _dinnerPeriod,
            forecastContext: forecast,
          );

          expect(result, isNotNull);
          expect(
            result!.input.covers,
            73,
            reason:
                'Square (coversFieldExposed=false) + manual entry -> manual',
          );
          expect(result.input.sourceSystem, 'operator_manual_entry');
          expect(
            result.provenance.coversProvenance,
            'operator_manual_entry_fallback_pos_not_exposed',
          );
        },
      );

      test('POS does NOT expose covers (Square) + NO manual entries -> '
          'existing forecast substitution still wins', () async {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'square',
            'vendor_entity_id': 'order_sq_002',
            'vendor_modified_at': _dinnerInstantUtc,
            'covers': 0,
            'covers_source': 'forecast_fallback',
            'opened_at': _dinnerInstantUtc,
            'closed_at': _dinnerInstantUtc,
            'business_date': _businessDateIso,
            'actual_sales': 612.40,
          },
        ];
        // No manual entries seeded; default DataAccuracySettings
        // (covers_manual_entries empty) is constructed by the
        // aggregator when no row exists for the tenant.
        final forecast = DemandForecastContext(
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
        );

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
          servicePeriodId: 'dinner',
          periodDefinition: _dinnerPeriod,
          forecastContext: forecast,
        );

        expect(result, isNotNull);
        // Forecast substitution still wins when no manual entries
        // are present.
        expect(
          result!.provenance.coversProvenance,
          'vendor_square_covers_unavailable_app_forecast_substituted',
        );
        expect(result.input.sourceSystem, 'square');
      });

      test(
        'Unknown POS vendor (no cover_facts rows) + manual entries -> '
        'manual projected; POS-fallback also covers the "no POS" case',
        () async {
          final pool = _FakePool()..seedLocation(_opA, _locA);
          // No cover_facts seeded — posVendorId resolves to null;
          // capability lookup returns null which the aggregator treats
          // as "lacks coverage" (safer assumption).
          pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
            'setting_id': 'das_004',
            'operator_id': _opA,
            'location_id': _locA,
            'covers_source_lunch': 'vendor',
            'covers_source_dinner': 'vendor',
            'covers_source_late_night': 'vendor',
            'covers_manual_entries': <String, Map<String, int>>{
              _businessDateIso: <String, int>{'dinner': 41},
            },
            'wage_source': 'vendor',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 4),
            'updated_by': null,
          };

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
            servicePeriodId: 'dinner',
            periodDefinition: _dinnerPeriod,
          );

          expect(result, isNotNull);
          expect(result!.input.covers, 41);
          expect(result.input.sourceSystem, 'operator_manual_entry');
          expect(
            result.provenance.coversProvenance,
            'operator_manual_entry_fallback_pos_not_exposed',
          );
        },
      );
    },
  );

  // ─────────────────── E — reservation + walk-in Pattern A ────────────────
  group('aggregator — E. reservation+walk-in (Square + Libro)', () {
    test('seated party_size sum + operator walk-in count -> '
        'vendor_libro_seated_plus_operator_walk_in_count', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      _seedReservationPlusWalkinPreference(pool, 'dinner');
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
        walkInOverride: const ReservationWalkInOverride(
          operatorWalkInCount: 25,
        ),
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

    test('keyed reservation_plus_walkin source is preserved instead of '
        'collapsing to vendor', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_reservation_plus_walkin',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999994',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'reservation_plus_walkin',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'toast',
          'vendor_entity_id': 'check_toast_reservation_choice',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 92,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 2310.50,
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
              'party_size': 6,
              'status': 'SEATED',
              'seated_at': _dinnerInstantUtc,
              'business_date': _businessDateIso,
            },
          ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: _businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: _dinnerPeriod,
            walkInOverride: const ReservationWalkInOverride(
              operatorWalkInCount: 25,
            ),
          );

      expect(result, isNotNull);
      expect(result!.input.covers, 35);
      expect(result.input.sourceSystem, 'libro');
      expect(
        result.provenance.coversProvenance,
        'vendor_libro_seated_plus_operator_walk_in_count',
      );
    });

    test('durable data_accuracy_settings walk-in count feeds Pattern A '
        'when no explicit override is supplied', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_walk_in',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'vendor',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'walk_in_handling_mode': 'walk_ins_added_to_reservations',
        'walk_in_manual_entries': <String, int>{_businessDateIso: 11},
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': 'operator-admin',
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': 'das_walk_in_dinner',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'reservation_plus_walkin',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': 'operator-admin',
          };
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );

      expect(result, isNotNull);
      expect(result!.input.covers, 21);
      expect(
        result.provenance.coversProvenance,
        'vendor_libro_seated_plus_operator_walk_in_count',
      );
    });

    test('vendor preference does not silently use reservation facts', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_vendor_preference',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'walk_in_handling_mode': 'reservations_only',
        'walk_in_manual_entries': <String, Object?>{},
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999993',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'vendor',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_no_covers',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'not_exposed',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 525.00,
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
              'party_size': 6,
              'status': 'SEATED',
              'seated_at': _dinnerInstantUtc,
              'business_date': _businessDateIso,
            },
          ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: _businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: _dinnerPeriod,
          );

      expect(result, isNull);
    });
  });

  // ─────────────────── F — Tock (no seated_at; serviceDateTimestamp) ──────
  group('aggregator — F. Tock daypart bucketing without seated_at', () {
    test('Tock reservation_facts with no seated_at still bucket by '
        'reservation_at; SEATED party_size sums', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      _seedReservationPlusWalkinPreference(pool, 'dinner');
      pool.reservationFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
          [
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
        walkInOverride: const ReservationWalkInOverride(operatorWalkInCount: 0),
      );

      expect(result, isNotNull);
      // Pattern A path: 8 seated + 0 walk-in = 8.
      expect(result!.input.covers, 8);
      expect(
        result.provenance.coversProvenance,
        'vendor_tock_seated_plus_operator_walk_in_count',
      );
    });
  });

  // ─────────────────── G — perPositionWithRates (Humanity) ────────────────
  group('aggregator — G. wage perPositionWithRates (Humanity)', () {
    test(
      'Humanity per-position rates compute dollars via rate × hours',
      () async {
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
        pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
            [
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
          servicePeriodId: 'dinner',
          periodDefinition: _dinnerPeriod,
        );

        expect(result, isNotNull);
        // Per-Daypart V1 Slice 1.5: labor dollars now consume the
        // per-period overlap minutes via DaypartBucketer, not the full
        // punch duration. Both punches start at 18:00 local (within
        // dinner 17:00–22:00); the 4h server punch fits entirely inside
        // dinner (4h × 22 = 88) while the 5h cook punch tail at 22:00–
        // 23:00 falls outside dinner, so only 4h count for dinner (4h
        // × 24 = 96).
        expect(result!.input.actualFohLaborDollars, closeTo(4 * 22.0, 0.001));
        expect(result.input.actualBohLaborDollars, closeTo(4 * 24.0, 0.001));
        expect(
          result.provenance.laborDollarsProvenance,
          'vendor_humanity_per_position_actual_dollars',
        );
      },
    );
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );

      expect(result, isNotNull);
      // manual_mix path emits null dollars so ShiftFactBuilder takes
      // the wage*hours fallback; provenance is target_wage_substituted.
      expect(result!.input.actualFohLaborDollars, isNull);
      expect(result.input.actualBohLaborDollars, isNull);
      expect(
        result.provenance.laborDollarsProvenance,
        'target_wage_substituted',
      );
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );

      expect(result, isNotNull);
      // Per-Daypart V1 Slice 1.5: dollars use per-period overlap
      // minutes. Server 4h fits entirely inside dinner; cook 6h
      // overflows the period at 22:00 local, so only 4h count for
      // dinner (4 × 22 = 88).
      expect(result!.input.actualFohLaborDollars, closeTo(4 * 18.0, 0.001));
      expect(result.input.actualBohLaborDollars, closeTo(4 * 22.0, 0.001));
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
        servicePeriodId: 'dinner',
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
        servicePeriodId: 'dinner',
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );
      final resultB = await aggregator.aggregate(
        operatorId: _opB,
        locationId: _locB,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );

      // Tenant isolation: operator A and operator B see different
      // covers because the fake keys rows by the tenant tuple.
      expect(resultA!.input.covers, 5);
      expect(resultB!.input.covers, 9);

      // Every transaction set both tenant keys.
      expect(pool.transactions, isNotEmpty);
      for (final tx in pool.transactions) {
        expect(
          tx.setConfigCalls['app.operator_id'],
          isNotNull,
          reason: 'tenant SET LOCAL must run on every transaction',
        );
        expect(tx.setConfigCalls['app.location_id'], isNotNull);
      }
    });
  });

  // ─────────────────── N — keyed Data Accuracy service-period settings ────
  //
  // R7f: covers-source resolution must use the effective hierarchy
  // answer. Raw keyed rows are only consulted when source metadata says
  // the keyed base row is the effective winner, and then only at the
  // closed shift's business date.
  group('aggregator — N. R7f effective Covers source resolution', () {
    test('effective keyed base source (covers_source=manual) still uses '
        'the business-date keyed row; manual entry jsonb resolves; '
        'provenance + sourceSystem reflect operator manual entry', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'vendor',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': <String, Map<String, int>>{
          _businessDateIso: <String, int>{'dinner': 142},
        },
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      // Keyed setting wins: covers_source=manual for service period
      // 'dinner' effective from 2026-05-01 (≤ business_date 2026-05-04).
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999999',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      // POS row exists but operator manual preference must win.
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );
      expect(result, isNotNull);
      expect(
        result!.input.covers,
        142,
        reason:
            'effective keyed covers_source=manual must use the manual '
            'jsonb value for the closed shift date',
      );
      expect(result.input.sourceSystem, 'operator_manual_entry');
      expect(
        result.provenance.coversProvenance,
        'operator_manual_entry_per_daypart',
      );
    });

    test('org-unit scoped override from the effective view beats a raw '
        'keyed base row for the same service period', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.effectiveDataAccuracySettingsByTenant['$_opA|$_locA'] =
          <String, Object?>{
            'setting_id': 'org_override_effective',
            'operator_id': _opA,
            'location_id': _locA,
            'covers_source_per_service_period': <String, Object?>{
              'dinner': 'manual',
            },
            'covers_source_per_service_period_source': <String, Object?>{
              'dinner': <String, Object?>{
                'scope_type': 'org_unit',
                'scope_id': 'org-unit-1',
                'source_kind': 'scoped_override',
                'override_id': 'org_override_1',
              },
            },
            'covers_manual_entries': <String, Map<String, int>>{
              _businessDateIso: <String, int>{'dinner': 142},
            },
            'wage_source': 'vendor',
            'walk_in_handling_mode': 'reservations_only',
            'walk_in_manual_entries': const <String, Object?>{},
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 4),
            'updated_by': null,
          };
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999990',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'vendor',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 73,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 1184.50,
        },
      ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: _businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: _dinnerPeriod,
          );

      expect(result, isNotNull);
      expect(
        result!.input.covers,
        142,
        reason: 'effective org override must win over the raw keyed base row',
      );
      expect(result.input.sourceSystem, 'operator_manual_entry');
      expect(
        result.provenance.coversProvenance,
        'operator_manual_entry_per_daypart',
      );
    });

    test('date-aware keyed base lookup does not apply a row that became '
        'effective after the closed shift business date', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_manual_entries': <String, Map<String, int>>{
          _businessDateIso: <String, int>{'dinner': 187},
        },
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999989',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-05-10',
            'created_at': DateTime.utc(2026, 5, 10),
            'updated_at': DateTime.utc(2026, 5, 10),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 61,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 912.25,
        },
      ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: _businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: _dinnerPeriod,
          );

      expect(result, isNotNull);
      expect(
        result!.input.covers,
        61,
        reason:
            'a keyed base row effective on 2026-05-10 must not rewrite '
            'a 2026-05-04 closed shift',
      );
      expect(
        result.provenance.coversProvenance,
        'vendor_oracle_micros_simphony',
      );
    });

    test('no keyed row present — aggregator falls back to the vendor '
        'default and emits the vendor '
        'provenance with the POS-supplied covers', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      // Keyed table is empty for this
      // (operator, location, service_period_key), so vendor is the
      // effective default.
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'vendor',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': const <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      // POS supplies covers; vendor preference flows through stage 2.
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 73,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 1184.50,
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
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );
      expect(result, isNotNull);
      expect(result!.input.covers, 73);
      expect(result.input.sourceSystem, 'oracle_micros_simphony');
      expect(
        result.provenance.coversProvenance,
        'vendor_oracle_micros_simphony',
      );
    });

    test('forward-staged keyed row (effective_at AFTER the business_date) '
        'must NOT short-circuit the vendor default — the at-or-before '
        'lookup keeps a 2026-06-01 manual switch from gating a '
        '2026-05-04 close', () async {
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.dataAccuracySettingsByTenant['$_opA|$_locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': _opA,
        'location_id': _locA,
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'vendor',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': const <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      // Forward-staged keyed setting: effective from 2026-06-01.
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999999',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-06-01',
            'created_at': DateTime.utc(2026, 5, 31),
            'updated_at': DateTime.utc(2026, 5, 31),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 51,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 812.00,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );
      final result = await aggregator.aggregate(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: _restaurantA,
        businessDate: _businessDate, // 2026-05-04
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );
      expect(result, isNotNull);
      expect(
        result!.input.covers,
        51,
        reason:
            'forward-staged keyed row must not short-circuit '
            'the vendor default for a historical close',
      );
      expect(
        result.provenance.coversProvenance,
        'vendor_oracle_micros_simphony',
      );
    });

    test('cross-tenant isolation — operator A\'s keyed row must NOT be '
        'reachable from operator B\'s tenant context (the fake pool '
        'partitions by operator_id, mirroring production RLS)', () async {
      final pool = _FakePool()
        ..seedLocation(_opA, _locA)
        ..seedLocation(_opB, _locA);
      // Keyed setting only seeded for operator A.
      pool.dataAccuracyServicePeriodSettingsByTenant['$_opA|$_locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999999',
            'operator_id': _opA,
            'location_id': _locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      // Operator B has only the effective default + a vendor POS row.
      pool.dataAccuracySettingsByTenant['$_opB|$_locA'] = <String, Object?>{
        'setting_id': 'das_002',
        'operator_id': _opB,
        'location_id': _locA,
        'covers_source_lunch': 'vendor',
        'covers_source_dinner': 'vendor',
        'covers_source_late_night': 'vendor',
        'covers_manual_entries': const <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.coverFactsByOperatorLocation['$_opB|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': _dinnerInstantUtc,
          'covers': 28,
          'covers_source': 'direct',
          'opened_at': _dinnerInstantUtc,
          'closed_at': _dinnerInstantUtc,
          'business_date': _businessDateIso,
          'actual_sales': 412.50,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );
      final result = await aggregator.aggregate(
        operatorId: _opB,
        locationId: _locA,
        restaurantId: _restaurantA,
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: _dinnerPeriod,
      );
      expect(result, isNotNull);
      // Operator B sees vendor covers, NOT operator A's manual mode.
      expect(result!.input.covers, 28);
      expect(result.input.sourceSystem, 'oracle_micros_simphony');
      expect(
        result.provenance.coversProvenance,
        'vendor_oracle_micros_simphony',
      );
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

  // ─────────── O — Per-Daypart V1 Slice 1.5 regression suite ───────────
  //
  // Six focused tests covering the six locked scopes from the slice
  // prompt:
  //
  //   1. POS check closing exactly at the period boundary buckets to
  //      the period in both the canonical bucketer AND the closed-shift
  //      aggregator path (Gap 20 — half-open vs inclusive).
  //   2. A FOH punch crossing lunch -> dinner is split into per-period
  //      minutes (Gap 21 — Promise 3).
  //   3. Cross-(business-date) punch emits per-business-date rows
  //      anchored to the segment's resolved business date (Gap 26).
  //   4. Stage-4 forecast fallback uses DaypartPlanAllocator with
  //      distribution weights, not the legacy `/3` divide (Gap 25).
  //   5. Close-authority auto-derive — reliable vendor returns
  //      `vendor_<id>_reliable_finalization`; unknown / unreliable
  //      vendor returns the business-day-start fallback shape (Gap 31).
  group('aggregator — O. Per-Daypart V1 Slice 1.5 regressions', () {
    const ServicePeriodDefinition lunchPeriod = ServicePeriodDefinition(
      id: 'lunch',
      label: 'Lunch',
      shortLabel: 'L',
      sortOrder: 1,
      startLocalTime: '11:00',
      endLocalTime: '15:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    );
    const ServicePeriodDefinition dinnerPeriodFull = ServicePeriodDefinition(
      id: 'dinner',
      label: 'Dinner',
      shortLabel: 'D',
      sortOrder: 2,
      startLocalTime: '17:00',
      endLocalTime: '22:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    );

    test('1. POS check at exact period boundary (15:00:00) buckets to '
        'lunch via both DaypartBucketer.bucketPosLine AND the closed-'
        'shift aggregator path', () async {
      // 19:00 UTC = 15:00 EDT (May 2026, America/Toronto). The
      // canonical bucketer treats period end inclusive at full
      // sub-minute precision: 15:00:00.000 belongs to Lunch
      // (Lunch 11:00–15:00). The pre-1.5 aggregator's inline
      // `_bucketsToDaypart` used `[start, end)` half-open which
      // would have classified this as "no period". Both paths
      // must now agree.
      final boundaryUtc = DateTime.utc(2026, 5, 4, 19, 0, 0);

      // Path 1 — canonical bucketer with the operator's full
      // period list.
      const location = BucketingLocationContext(
        iana: 'America/Toronto',
        businessDayStartLocalTime: '04:00',
      );
      final localBoundary = DateTime(2026, 5, 4, 15, 0, 0);
      final bucketedByDaypartBucketer = DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: 'check_boundary',
          eventLocalTimestamp: localBoundary,
        ),
        location,
        const <ServicePeriodDefinition>[lunchPeriod, dinnerPeriodFull],
      );
      expect(
        bucketedByDaypartBucketer,
        'lunch',
        reason:
            'DaypartBucketer.bucketPosLine treats period end '
            'inclusive — 15:00:00 belongs to lunch.',
      );

      // Path 2 — closed-shift aggregator. The cover_facts row at
      // closed_at=15:00:00 local must surface to the lunch
      // aggregator call (covers > 0) and produce non-null result.
      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_boundary',
          'vendor_modified_at': boundaryUtc,
          'covers': 12,
          'covers_source': 'direct',
          'opened_at': boundaryUtc.subtract(const Duration(hours: 1)),
          'closed_at': boundaryUtc,
          'business_date': _businessDateIso,
          'actual_sales': 240.00,
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
        servicePeriodId: 'lunch',
        periodDefinition: lunchPeriod,
        allServicePeriodDefinitions: const <ServicePeriodDefinition>[
          lunchPeriod,
          dinnerPeriodFull,
        ],
      );
      expect(
        result,
        isNotNull,
        reason:
            'closed-shift aggregator must keep the 15:00:00 '
            'check inside lunch — byte-identical to live read.',
      );
      expect(result!.input.covers, 12);
      expect(result.input.daypart, 'lunch');
    });

    test('2. A FOH punch 10:00–18:00 with lunch 11:00–15:00 / dinner '
        '17:00–22:00 contributes 4h to lunch and 1h to dinner '
        '(per-period interval splitting)', () async {
      // 14:00 UTC = 10:00 EDT; 22:00 UTC = 18:00 EDT.
      final startUtc = DateTime.utc(2026, 5, 4, 14, 0, 0);
      final endUtc = DateTime.utc(2026, 5, 4, 22, 0, 0);
      final punchRow = <String, Object?>{
        'vendor_id': 'quickbooks_time',
        'vendor_entity_id': 'ts_split',
        'employee_source_id': 'emp_split',
        'role_name': 'server',
        'shift_start': startUtc,
        'shift_end': endUtc,
        'hours_worked': 8,
        'pay_rate': 20.0,
        'business_date': _businessDateIso,
      };

      // Lunch run — expect 4 hours and 4×20 = 80 dollars.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_lunch',
            'vendor_modified_at': DateTime.utc(2026, 5, 4, 17, 0, 0),
            'covers': 10,
            'covers_source': 'direct',
            'opened_at': DateTime.utc(2026, 5, 4, 16, 0, 0),
            'closed_at': DateTime.utc(2026, 5, 4, 17, 0, 0),
            'business_date': _businessDateIso,
            'actual_sales': 200.0,
          },
        ];
        pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
            [punchRow];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: _businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'lunch',
              periodDefinition: lunchPeriod,
              allServicePeriodDefinitions: const <ServicePeriodDefinition>[
                lunchPeriod,
                dinnerPeriodFull,
              ],
            );
        expect(result, isNotNull);
        expect(result!.input.actualFohHours, 4);
        expect(result.input.actualFohLaborDollars, closeTo(4 * 20.0, 0.001));
      }

      // Dinner run — expect 1 hour and 1×20 = 20 dollars.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_dinner',
            'vendor_modified_at': DateTime.utc(2026, 5, 4, 22, 0, 0),
            'covers': 8,
            'covers_source': 'direct',
            'opened_at': DateTime.utc(2026, 5, 4, 21, 0, 0),
            'closed_at': DateTime.utc(2026, 5, 4, 22, 0, 0),
            'business_date': _businessDateIso,
            'actual_sales': 160.0,
          },
        ];
        pool.laborPunchesByOperatorLocation['$_opA|$_locA|$_businessDateIso'] =
            [punchRow];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: _businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'dinner',
              periodDefinition: dinnerPeriodFull,
              allServicePeriodDefinitions: const <ServicePeriodDefinition>[
                lunchPeriod,
                dinnerPeriodFull,
              ],
            );
        expect(result, isNotNull);
        expect(result!.input.actualFohHours, 1);
        expect(result.input.actualFohLaborDollars, closeTo(1 * 20.0, 0.001));
      }
    });

    test('3. Cross-(business-date) punch — 03:00 -> 11:00 with cutoff '
        '04:00 splits across Mon (1h before rollover) and Tue (7h '
        'after); each business_date aggregator call sees only its '
        'own slice', () async {
      // Local 03:00 Tue → 11:00 Tue, cutoff 04:00 → punch spans
      // Mon business date (03:00–04:00 = 1h) and Tue business
      // date (04:00–11:00 = 7h).
      // 03:00 EDT = 07:00 UTC; 11:00 EDT = 15:00 UTC (May 2026).
      final startUtc = DateTime.utc(2026, 5, 5, 7, 0, 0);
      final endUtc = DateTime.utc(2026, 5, 5, 15, 0, 0);

      // Both the calendar Tue row and the Mon row hold the same
      // punch in the fake DB (the SQL window is ±1 day around the
      // queried business_date; the production write path stamps
      // the punch's `business_date` from its `shift_start`).
      final monPunchRow = <String, Object?>{
        'vendor_id': 'quickbooks_time',
        'vendor_entity_id': 'ts_cross',
        'employee_source_id': 'emp_cross',
        'role_name': 'cook',
        'shift_start': startUtc,
        'shift_end': endUtc,
        'hours_worked': 8,
        'pay_rate': 18.0,
        'business_date': '2026-05-04',
      };

      // Mon (lunch is 11:00–15:00 by definition; the spillover
      // 03:00–04:00 is non-service, so the lunch aggregator call
      // for Mon receives 0 hours for this punch). We assert the
      // late_night period for Mon picks up the 1h.
      const lateNightMon = ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late night',
        shortLabel: 'LN',
        sortOrder: 3,
        startLocalTime: '22:00',
        endLocalTime: '04:00',
        rollsPastMidnight: true,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      );
      final allPeriods = const <ServicePeriodDefinition>[
        lunchPeriod,
        dinnerPeriodFull,
        lateNightMon,
      ];

      // Mon late_night aggregator call (business_date = 2026-05-04).
      // Late-night Mon = [2026-05-04 22:00, 2026-05-05 04:00).
      // Punch 03:00–11:00 Tue calendar overlaps that interval at
      // 03:00–04:00 → 1 hour.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|2026-05-04'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_late_night',
            'vendor_modified_at': DateTime.utc(2026, 5, 5, 7, 30, 0),
            'covers': 2,
            'covers_source': 'direct',
            'opened_at': DateTime.utc(2026, 5, 5, 7, 0, 0),
            'closed_at': DateTime.utc(2026, 5, 5, 7, 30, 0),
            'business_date': '2026-05-04',
            'actual_sales': 40.0,
          },
        ];
        // Punch stamped business_date=Mon; the new 3-day window
        // SQL captures it for the Mon aggregator call.
        pool.laborPunchesByOperatorLocation['$_opA|$_locA|2026-05-04'] = [
          monPunchRow,
        ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: DateTime.utc(2026, 5, 4),
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'late_night',
              periodDefinition: lateNightMon,
              allServicePeriodDefinitions: allPeriods,
            );
        expect(result, isNotNull);
        expect(
          result!.input.actualBohHours,
          1,
          reason:
              'Mon late_night picks up the 03:00–04:00 spillover '
              'of the Tue-calendar punch.',
        );
      }

      // Tue lunch aggregator call (business_date = 2026-05-05).
      // Lunch Tue = [2026-05-05 11:00, 2026-05-05 15:00].
      // Punch 03:00–11:00 Tue covers 11:00 endpoint → 0 dinner /
      // 0 lunch minutes via the half-open Lunch interval seen by
      // the bucketer's punch splitter
      // (`[ivStart, ivEnd)`). The slice's worked example is the
      // 03:00–04:00 split, which Mon late_night captured above.
      // What this test asserts is the inverse: the Tue lunch
      // aggregator call must NOT double-count the Mon-stamped row.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|2026-05-05'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_tue_lunch',
            'vendor_modified_at': DateTime.utc(2026, 5, 5, 17, 0, 0),
            'covers': 4,
            'covers_source': 'direct',
            'opened_at': DateTime.utc(2026, 5, 5, 16, 0, 0),
            'closed_at': DateTime.utc(2026, 5, 5, 17, 0, 0),
            'business_date': '2026-05-05',
            'actual_sales': 80.0,
          },
        ];
        // The punch row's stored business_date = Mon. The 3-day
        // SQL window for Tue (prior=Mon, next=Wed) captures it.
        pool.laborPunchesByOperatorLocation['$_opA|$_locA|2026-05-04'] = [
          monPunchRow,
        ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: DateTime.utc(2026, 5, 5),
              weekId: '2026-W19',
              dayLabel: 'Tue',
              servicePeriodId: 'lunch',
              periodDefinition: lunchPeriod,
              allServicePeriodDefinitions: allPeriods,
            );
        expect(result, isNotNull);
        // The punch's overlap with Tue lunch period [11:00, 15:00)
        // is empty because the punch ends exactly at 11:00 local
        // (bucketer uses half-open punch intervals — the minute
        // starting at 11:00 is the first minute of lunch, but
        // the punch end at 11:00 is exclusive).
        expect(
          result!.input.actualBohHours,
          0,
          reason:
              'Tue lunch must NOT double-count the punch that '
              'already contributed to Mon late_night.',
        );
      }
    });

    test('4. Stage-4 forecast fallback uses DaypartPlanAllocator with '
        'distribution weights — 3-period config with weights '
        '(0.3, 0.5, 0.2) splits 90-cover daily forecast into 27/45/18, '
        'NOT the legacy 30/30/30 uniform `/3` divide', () async {
      // Operator's 3 periods (sum cover_proportions = 1.0).
      const lunch = lunchPeriod;
      const dinner = dinnerPeriodFull;
      const lateNight = ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late night',
        shortLabel: 'LN',
        sortOrder: 3,
        startLocalTime: '22:00',
        endLocalTime: '01:00',
        rollsPastMidnight: true,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      );
      // Weekly forecast = 90 covers/day × 7 days = 630.
      const weeklyForecast = 90 * 7;
      final forecastContext = DemandForecastContext(
        restaurantId: _restaurantA,
        anchorBusinessDate: _businessDateIso,
        baselineTotalCovers: 5400,
        baselineWeeklyAvgCovers: weeklyForecast,
        baselineWeeksRepresented: 60 / 7,
        resolvedWeeklyForecastCovers: weeklyForecast,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: DateTime.utc(2026, 5, 4).toIso8601String(),
      );
      // Distribution weights — per-day map keyed by daypart id.
      final weights = ScheduleDistributionWeights.available(
        dayWeights: const <String, int>{'Mon': 100},
        daypartWeightsByDay: const <String, Map<String, int>>{
          'Mon': <String, int>{'lunch': 30, 'dinner': 50, 'late_night': 20},
        },
        closedShiftCount: 21,
        closedBusinessDayCount: 7,
        totalCovers: 100,
      );

      Future<int?> coversFor(
        ServicePeriodDefinition target,
        String targetServicePeriodId,
      ) async {
        // Pool has NO POS rows -> stage 4 fallback kicks in.
        final pool = _FakePool()..seedLocation(_opA, _locA);
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: _businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: targetServicePeriodId,
              periodDefinition: target,
              allServicePeriodDefinitions: const <ServicePeriodDefinition>[
                lunch,
                dinner,
                lateNight,
              ],
              distributionWeights: weights,
              forecastContext: forecastContext,
            );
        return result?.input.covers;
      }

      // 90 × 0.3 = 27, 90 × 0.5 = 45, 90 × 0.2 = 18.
      expect(await coversFor(lunch, 'lunch'), 27);
      expect(await coversFor(dinner, 'dinner'), 45);
      expect(await coversFor(lateNight, 'late_night'), 18);
    });

    test('5. Close-authority auto-derive — reliable POS vendor emits '
        '`vendor_<id>_reliable_finalization`; unknown vendor emits '
        '`no_pos_vendor_business_day_start_fallback`', () async {
      // Reliable case — Oracle Simphony classifies as
      // vendorReliableFinalization in the sidecar.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$_businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_reliable',
            'vendor_modified_at': _dinnerInstantUtc,
            'covers': 8,
            'covers_source': 'direct',
            'opened_at': _dinnerInstantUtc,
            'closed_at': _dinnerInstantUtc,
            'business_date': _businessDateIso,
            'actual_sales': 200.0,
          },
        ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: _businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'dinner',
              periodDefinition: dinnerPeriodFull,
            );
        expect(
          result?.provenance.closeAuthorityProvenance,
          'vendor_oracle_micros_simphony_reliable_finalization',
        );
      }
      // Unknown / no POS vendor case — close-authority falls back
      // to the operator's business-day-start.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        // No cover_facts rows -> stage 4 / 5 fallback path. With
        // a forecast context absent, stage 5 returns null. Use a
        // forecast context so we hit stage 4 and the result is
        // non-null with sourceSystem='app_forecast'.
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: _businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'dinner',
              periodDefinition: dinnerPeriodFull,
              forecastContext: DemandForecastContext(
                restaurantId: _restaurantA,
                anchorBusinessDate: _businessDateIso,
                baselineTotalCovers: 600,
                baselineWeeklyAvgCovers: 70,
                baselineWeeksRepresented: 60 / 7,
                resolvedWeeklyForecastCovers: 70,
                coversSource:
                    ForecastDemandSource.appDerivedFromHistoricalAverage,
                builtAt: DateTime.utc(2026, 5, 4).toIso8601String(),
              ),
            );
        expect(
          result?.provenance.closeAuthorityProvenance,
          'no_pos_vendor_business_day_start_fallback',
        );
      }
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  // P. Operator business-hours scenario — 23:00 Tue → 03:30 Wed
  // (intent lock).
  //
  // Locks the operator's stated scenario from
  // docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md
  // §"End-to-end verification 2026-05-15 (post-Slice-1.5 merge)" into
  // the regression test suite so a future change cannot silently
  // regress it. Slice 1.5 (PR #763) routed the closed-shift aggregator
  // through `DaypartBucketer`; this group ratchets that behavior.
  //
  // Restaurant config:
  //   business_day_start_local_time = '04:00'   (cutoff anchor)
  //   IANA timezone                  = America/Toronto
  //   Late Night daypart             = 22:00–02:00
  //                                    rollsPastMidnight = true
  //
  // Anchor business date: Tuesday 2026-05-12 (May falls within EDT
  // 2026 — UTC-4 — so DST does not trip the test). Weekday(2026-05-12)
  // = 2 (Tue).
  //
  // Local→UTC mapping used throughout:
  //   23:00 Tue local = 03:00 Wed UTC = DateTime.utc(2026, 5, 13, 3, 0)
  //   01:30 Wed local = 05:30 Wed UTC = DateTime.utc(2026, 5, 13, 5, 30)
  //   02:00 Wed local = 06:00 Wed UTC = DateTime.utc(2026, 5, 13, 6, 0)
  //   03:30 Wed local = 07:30 Wed UTC = DateTime.utc(2026, 5, 13, 7, 30)
  // ──────────────────────────────────────────────────────────────────────
  group('P. Operator business-hours scenario — '
      '23:00 Tue → 03:30 Wed (intent lock)', () {
    // Tuesday business date anchor.
    final tuesdayBusinessDate = DateTime.utc(2026, 5, 12);
    const tuesdayBusinessDateIso = '2026-05-12';

    // The operator's stated Late Night period: 22:00–02:00 with
    // rollsPastMidnight=true. With cutoff 04:00, Late Night on
    // business date Tue resolves to the calendar interval
    // [Tue 22:00 local, Wed 02:00 local) per
    // `DaypartBucketer._periodIntervalsOnBusinessDate`.
    const lateNightPeriod = ServicePeriodDefinition(
      id: 'late_night',
      label: 'Late Night',
      shortLabel: 'LN',
      sortOrder: 3,
      startLocalTime: '22:00',
      endLocalTime: '02:00',
      rollsPastMidnight: true,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    );
    // Carry lunch + dinner so the bucketer iterates the full
    // operator period list — matches production where
    // `allServicePeriodDefinitions` is plumbed in by the call site.
    const lunchPeriod = ServicePeriodDefinition(
      id: 'lunch',
      label: 'Lunch',
      shortLabel: 'L',
      sortOrder: 1,
      startLocalTime: '11:00',
      endLocalTime: '15:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    );
    const dinnerPeriod = ServicePeriodDefinition(
      id: 'dinner',
      label: 'Dinner',
      shortLabel: 'D',
      sortOrder: 2,
      startLocalTime: '17:00',
      endLocalTime: '22:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    );
    const allPeriods = <ServicePeriodDefinition>[
      lunchPeriod,
      dinnerPeriod,
      lateNightPeriod,
    ];

    // Operator's restaurant timing context — must match what
    // `_FakePool.seedLocation` writes (timezone='America/Toronto',
    // business_day_rollover_hour=4 → businessDayStartLocalTime='04:00').
    const bucketingContext = BucketingLocationContext(
      iana: 'America/Toronto',
      businessDayStartLocalTime: '04:00',
    );

    // ─── P.1 — POS check buckets to Tuesday Late Night ─────────
    test('P.1 POS check at 23:00 Tue local AND at 01:30 Wed local both '
        'bucket to Tuesday business date / late_night daypart', () async {
      // 23:00 Tue local = 03:00 Wed UTC.
      final twentyThreeTueUtc = DateTime.utc(2026, 5, 13, 3, 0, 0);
      // 01:30 Wed local = 05:30 Wed UTC.
      final oneThirtyWedUtc = DateTime.utc(2026, 5, 13, 5, 30, 0);

      // Sub-case A — closed_at = 23:00 Tue local.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
            [
              <String, Object?>{
                'vendor_id': 'oracle_micros_simphony',
                'vendor_entity_id': 'check_2300_tue',
                'vendor_modified_at': twentyThreeTueUtc,
                'covers': 6,
                'covers_source': 'direct',
                'opened_at': twentyThreeTueUtc.subtract(
                  const Duration(hours: 1),
                ),
                'closed_at': twentyThreeTueUtc,
                'business_date': tuesdayBusinessDateIso,
                'actual_sales': 180.0,
              },
            ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: tuesdayBusinessDate,
              weekId: '2026-W20',
              dayLabel: 'Tue',
              servicePeriodId: 'late_night',
              periodDefinition: lateNightPeriod,
              allServicePeriodDefinitions: allPeriods,
            );
        expect(
          result,
          isNotNull,
          reason:
              '23:00 Tue local check must be picked up by the '
              'Tuesday late_night aggregator call.',
        );
        expect(result!.input.covers, 6);
        expect(result.input.daypart, 'late_night');
        // ClosedShiftInput.businessDate is the same DateTime the
        // call passed in — the aggregator does not re-resolve it.
        // The truth this assertion locks: the row's `business_date`
        // anchor is Tuesday because the closed_at 23:00 Tue local
        // resolved to Tuesday under the cutoff — the aggregator
        // call would not have surfaced it otherwise.
        expect(result.input.businessDate, tuesdayBusinessDate);
        expect(
          result.input.servicePeriodKey,
          isNull,
          reason:
              'businessTimingProfileId not supplied → '
              'servicePeriodKey is null per aggregator contract; '
              'the daypart field already carries the period.',
        );
      }

      // Sub-case B — closed_at = 01:30 Wed local (post-midnight,
      // pre-cutoff). Must still attribute to Tuesday late_night.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
            [
              <String, Object?>{
                'vendor_id': 'oracle_micros_simphony',
                'vendor_entity_id': 'check_0130_wed',
                'vendor_modified_at': oneThirtyWedUtc,
                'covers': 4,
                'covers_source': 'direct',
                'opened_at': oneThirtyWedUtc.subtract(const Duration(hours: 1)),
                'closed_at': oneThirtyWedUtc,
                'business_date': tuesdayBusinessDateIso,
                'actual_sales': 120.0,
              },
            ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: tuesdayBusinessDate,
              weekId: '2026-W20',
              dayLabel: 'Tue',
              servicePeriodId: 'late_night',
              periodDefinition: lateNightPeriod,
              allServicePeriodDefinitions: allPeriods,
            );
        expect(
          result,
          isNotNull,
          reason:
              '01:30 Wed local check must attribute to Tuesday '
              'late_night because 01:30 < 04:00 cutoff AND falls in '
              'the Late Night [Tue 22:00, Wed 02:00) interval.',
        );
        expect(result!.input.covers, 4);
        expect(result.input.daypart, 'late_night');
        expect(result.input.businessDate, tuesdayBusinessDate);
      }

      // Sub-case C — `DaypartBucketer.bucketPosLine` direct check.
      // Locks the canonical bucketer's behavior at both endpoints
      // independent of the aggregator wiring. If a future change
      // breaks the bucketer's classification of either instant,
      // this assertion fails before the aggregator path does.
      final localTwentyThreeTue = DateTime(2026, 5, 12, 23, 0, 0);
      final localOneThirtyWed = DateTime(2026, 5, 13, 1, 30, 0);
      expect(
        DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'check_2300_tue',
            eventLocalTimestamp: localTwentyThreeTue,
          ),
          bucketingContext,
          allPeriods,
        ),
        'late_night',
      );
      expect(
        DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'check_0130_wed',
            eventLocalTimestamp: localOneThirtyWed,
          ),
          bucketingContext,
          allPeriods,
        ),
        'late_night',
      );
    });

    test('P.1b closed-shift bucketing reads business_timing_profiles '
        'cutoff, not locations.business_day_rollover_hour', () async {
      // 04:15 Wed local = 08:15 Wed UTC in America/Toronto.
      // With canonical cutoff 04:30 this belongs to Tuesday's
      // business date. With legacy rolloverHour=0 it would be
      // Wednesday and fail the Tuesday-only applicableDays gate.
      final fourFifteenWedUtc = DateTime.utc(2026, 5, 13, 8, 15);
      const earlyBreakfastPeriod = ServicePeriodDefinition(
        id: 'early_breakfast',
        label: 'Early Breakfast',
        shortLabel: 'EB',
        sortOrder: 1,
        startLocalTime: '03:00',
        endLocalTime: '05:00',
        rollsPastMidnight: false,
        applicableDays: <int>[DateTime.tuesday],
      );
      final pool = _FakePool()
        ..seedLocation(
          _opA,
          _locA,
          businessDayStartLocalTime: '04:30:00',
          businessDayRolloverHour: 0,
        );
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'oracle_micros_simphony',
              'vendor_entity_id': 'check_0415_wed',
              'vendor_modified_at': fourFifteenWedUtc,
              'covers': 7,
              'covers_source': 'direct',
              'opened_at': fourFifteenWedUtc.subtract(
                const Duration(minutes: 45),
              ),
              'closed_at': fourFifteenWedUtc,
              'business_date': tuesdayBusinessDateIso,
              'actual_sales': 210.0,
            },
          ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: tuesdayBusinessDate,
            weekId: '2026-W20',
            dayLabel: 'Tue',
            servicePeriodId: 'early_breakfast',
            periodDefinition: earlyBreakfastPeriod,
            allServicePeriodDefinitions: const <ServicePeriodDefinition>[
              earlyBreakfastPeriod,
            ],
          );

      expect(result, isNotNull);
      expect(result!.input.covers, 7);
      expect(result.input.actualSales, closeTo(210.0, 0.001));
    });

    // ─── P.2 — Labor punch split with non-service tail ─────────
    test('P.2 FOH labor punch 23:00 Tue → 03:30 Wed contributes 3h '
        '(180 min) to Tuesday late_night and the 02:00→03:30 sliver '
        '(90 min non_service) is excluded from the late_night rollup', () async {
      // shift_start = 23:00 Tue local = 03:00 Wed UTC.
      // shift_end   = 03:30 Wed local = 07:30 Wed UTC.
      final shiftStartUtc = DateTime.utc(2026, 5, 13, 3, 0, 0);
      final shiftEndUtc = DateTime.utc(2026, 5, 13, 7, 30, 0);
      final laborRow = <String, Object?>{
        'vendor_id': 'quickbooks_time',
        'vendor_entity_id': 'ts_late_night_cross',
        'employee_source_id': 'emp_late',
        'role_name': 'server', // FOH
        'shift_start': shiftStartUtc,
        'shift_end': shiftEndUtc,
        // hours_worked stamped by upstream sink at full duration;
        // the aggregator MUST NOT use this — it must derive
        // per-period minutes via DaypartBucketer.bucketLaborPunch.
        'hours_worked': 4.5,
        'pay_rate': 22.0,
        'business_date': tuesdayBusinessDateIso,
      };

      // ── Sub-assertion (a) — proxy for `_businessDatesSpanning`.
      // The private helper `DaypartBucketer._businessDatesSpanning`
      // is not exposed for direct call. We assert it returns
      // `[Tuesday-ISO]` only by proxy: with the punch as the only
      // labor row anchored to business_date=Tuesday, the
      // Wednesday business_date aggregator call must see ZERO
      // labor minutes for late_night (the punch's segments do not
      // anchor onto Wednesday because every 30-min probe from
      // [Tue 23:00, Wed 03:30] resolves to Tuesday under the
      // 04:00 cutoff).
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        // Anchor the punch under business_date=Tuesday only.
        pool.laborPunchesByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
            [laborRow];
        // Wednesday cover_fact required so the aggregator returns
        // a non-null result for the Wed call.
        pool.coverFactsByOperatorLocation['$_opA|$_locA|2026-05-13'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_wed_late_night_anchor',
            'vendor_modified_at': DateTime.utc(2026, 5, 14, 3, 0, 0),
            'covers': 1,
            'covers_source': 'direct',
            'opened_at': DateTime.utc(2026, 5, 14, 2, 0, 0),
            'closed_at': DateTime.utc(2026, 5, 14, 3, 0, 0),
            'business_date': '2026-05-13',
            'actual_sales': 30.0,
          },
        ];
        final wedResult =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: DateTime.utc(2026, 5, 13),
              weekId: '2026-W20',
              dayLabel: 'Wed',
              servicePeriodId: 'late_night',
              periodDefinition: lateNightPeriod,
              allServicePeriodDefinitions: allPeriods,
            );
        expect(wedResult, isNotNull);
        expect(
          wedResult!.input.actualFohHours,
          0,
          reason:
              '_businessDatesSpanning for the Tue 23:00 → Wed 03:30 '
              'punch must return only [Tuesday-ISO] under cutoff '
              '04:00; the punch must not bleed onto Wednesday\'s '
              'late_night row.',
        );
      }

      // ── Sub-assertion (b) — late_night minutes on Tuesday = 180.
      // ── Sub-assertion (c) — the 02:00 → 03:30 Wed sliver (90 min
      // non_service) is excluded from the late_night rollup. The
      // aggregator does not expose a separate "non_service minutes"
      // field on ClosedShiftInput; the assertion shape is therefore
      // "late_night labor hours = 3 (== 180 min / 60), NOT 4
      // (would be the rounded result of 270 min / 60 if the gap
      // were included)". This proves the gap was excluded from the
      // period rollup per the Jim Taylor non_service rule.
      {
        final pool = _FakePool()..seedLocation(_opA, _locA);
        pool.laborPunchesByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
            [laborRow];
        // Need at least one cover_fact in late_night so the
        // aggregator returns non-null (POS-supplied covers stage 2
        // is the simplest path).
        pool.coverFactsByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
            [
              <String, Object?>{
                'vendor_id': 'oracle_micros_simphony',
                'vendor_entity_id': 'check_anchor',
                'vendor_modified_at': DateTime.utc(2026, 5, 13, 3, 0, 0),
                'covers': 1,
                'covers_source': 'direct',
                'opened_at': DateTime.utc(2026, 5, 13, 2, 0, 0),
                'closed_at': DateTime.utc(2026, 5, 13, 3, 0, 0),
                'business_date': tuesdayBusinessDateIso,
                'actual_sales': 30.0,
              },
            ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: _opA,
              locationId: _locA,
              restaurantId: _restaurantA,
              businessDate: tuesdayBusinessDate,
              weekId: '2026-W20',
              dayLabel: 'Tue',
              servicePeriodId: 'late_night',
              periodDefinition: lateNightPeriod,
              allServicePeriodDefinitions: allPeriods,
            );
        expect(result, isNotNull);
        expect(
          result!.input.actualFohHours,
          3,
          reason:
              'Late Night [Tue 22:00, Wed 02:00) overlapped with '
              'punch [Tue 23:00, Wed 03:30) = [Tue 23:00, Wed 02:00) '
              '= 180 min = 3h. The 02:00→03:30 Wed sliver (90 min) '
              'is non_service per the Jim Taylor rule and must NOT '
              'inflate this number to 4h (which would be the '
              'rounded result of including the gap).',
        );
        // Per-period rate × hours sanity: QuickBooks Time wage
        // class is perEmployeeWithRates; dollars must reflect 3h
        // (not 4.5h). 3 × 22.00 = 66.00.
        expect(
          result.input.actualFohLaborDollars,
          closeTo(3 * 22.0, 0.001),
          reason:
              'Labor dollars must scale to the per-period overlap '
              'minutes (3h x \$22), not the punch\'s full 4.5h '
              'duration. Confirms the gap minutes are excluded '
              'from CPLH/SPLH denominators end-to-end.',
        );
      }

      // ── Sub-assertion (d) — direct call to
      // `DaypartBucketer.bucketLaborPunch` confirms the segment
      // shape that drives (b) and (c). The non_service segment
      // exists, carries 90 minutes, and has servicePeriodId=null
      // (the canonical sentinel per `LaborPunchSegment`).
      final localStart = DateTime(2026, 5, 12, 23, 0, 0);
      final localEnd = DateTime(2026, 5, 13, 3, 30, 0);
      final segments = DaypartBucketer.bucketLaborPunch(
        BucketingLaborPunch(
          sourceId: 'ts_late_night_cross',
          clockedInLocal: localStart,
          clockedOutLocal: localEnd,
        ),
        bucketingContext,
        allPeriods,
      );
      // Two segments: [Tue 23:00, Wed 02:00) late_night (180 min)
      // + [Wed 02:00, Wed 03:30) non_service (90 min).
      expect(
        segments.length,
        2,
        reason:
            'Punch yields one period segment + one trailing '
            'non_service segment.',
      );
      final lateNightSeg = segments.firstWhere(
        (s) => s.servicePeriodId == 'late_night',
      );
      expect(lateNightSeg.minutes, 180);
      expect(lateNightSeg.startLocal, localStart);
      expect(lateNightSeg.endLocal, DateTime(2026, 5, 13, 2, 0, 0));
      final nonServiceSeg = segments.firstWhere(
        (s) => s.servicePeriodId == null,
      );
      expect(
        nonServiceSeg.minutes,
        90,
        reason:
            'The 02:00 Wed → 03:30 Wed sliver is the Jim Taylor '
            'non_service gap segment, excluded from per-period CPLH/'
            'SPLH denominators by the aggregator.',
      );
      expect(nonServiceSeg.startLocal, DateTime(2026, 5, 13, 2, 0, 0));
      expect(nonServiceSeg.endLocal, localEnd);
    });

    // ─── P.3 — Reservation buckets to Tuesday Late Night ───────
    test('P.3 reservation_facts row at 01:30 Wed local buckets to '
        'Tuesday business date / late_night daypart', () async {
      // reservation_at = 01:30 Wed local = 05:30 Wed UTC.
      final reservationAtUtc = DateTime.utc(2026, 5, 13, 5, 30, 0);
      final pool = _FakePool()..seedLocation(_opA, _locA);
      // Reservation anchored to Tuesday business_date — matches
      // the canonical write path's `business_date` derivation
      // (an upstream sink resolves the reservation's business
      // date from `reservation_at` under the operator's cutoff).
      _seedReservationPlusWalkinPreference(pool, 'late_night');
      pool.reservationFactsByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_late_night_001',
              'reservation_at': reservationAtUtc,
              'party_size': 4,
              'status': 'SEATED',
              // seated_at intentionally null to also exercise the Tock
              // bucketing path (bucketing keys off reservation_at).
              'seated_at': null,
              'business_date': tuesdayBusinessDateIso,
            },
          ];
      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: tuesdayBusinessDate,
            weekId: '2026-W20',
            dayLabel: 'Tue',
            servicePeriodId: 'late_night',
            periodDefinition: lateNightPeriod,
            allServicePeriodDefinitions: allPeriods,
            // Pattern A path — operator walk-in count = 0 + seated
            // sum 4 = 4 covers via stage 3 (no POS rows present).
            walkInOverride: const ReservationWalkInOverride(
              operatorWalkInCount: 0,
            ),
          );
      expect(
        result,
        isNotNull,
        reason:
            'Reservation at 01:30 Wed local must surface to the '
            'Tuesday late_night aggregator call.',
      );
      // Stage 3 covers = seated party_size + walk-in. Proves the
      // reservation passed `_readReservationFactsForDaypart`'s
      // post-filter via `bucketReservation` → 'late_night'.
      expect(result!.input.covers, 4);
      expect(result.input.daypart, 'late_night');
      expect(result.input.businessDate, tuesdayBusinessDate);
      expect(
        result.provenance.coversProvenance,
        'vendor_libro_seated_plus_operator_walk_in_count',
        reason:
            'Stage 3 (Pattern A) provenance confirms the '
            'reservation row was kept by the period filter — a '
            'classification miss would have produced a stage 5 '
            '(unavailable) null result instead.',
      );

      // Direct bucketer assertion — locks the canonical
      // classification of the reservation instant independent of
      // the aggregator wiring.
      final localOneThirtyWed = DateTime(2026, 5, 13, 1, 30, 0);
      expect(
        DaypartBucketer.bucketReservation(
          BucketingReservation(
            sourceId: 'res_late_night_001',
            reservationLocalTimestamp: localOneThirtyWed,
          ),
          bucketingContext,
          allPeriods,
        ),
        'late_night',
      );
    });

    // ─── P.4 — Composite (all three facts on one Tuesday row) ──
    test('P.4 composite: POS check + labor punch + reservation all on '
        'Tuesday late_night → aggregator emits one ClosedShiftInput '
        'row keyed (Tuesday, late_night) with rolled-up actuals', () async {
      final closedAtUtc = DateTime.utc(2026, 5, 13, 3, 0, 0);
      final laterCloseUtc = DateTime.utc(2026, 5, 13, 5, 30, 0);
      final shiftStartUtc = DateTime.utc(2026, 5, 13, 3, 0, 0);
      final shiftEndUtc = DateTime.utc(2026, 5, 13, 7, 30, 0);
      final reservationAtUtc = DateTime.utc(2026, 5, 13, 5, 30, 0);

      final pool = _FakePool()..seedLocation(_opA, _locA);
      pool.coverFactsByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'oracle_micros_simphony',
              'vendor_entity_id': 'check_2300_tue',
              'vendor_modified_at': closedAtUtc,
              'covers': 6,
              'covers_source': 'direct',
              'opened_at': closedAtUtc.subtract(const Duration(hours: 1)),
              'closed_at': closedAtUtc,
              'business_date': tuesdayBusinessDateIso,
              'actual_sales': 180.0,
            },
            <String, Object?>{
              'vendor_id': 'oracle_micros_simphony',
              'vendor_entity_id': 'check_0130_wed',
              'vendor_modified_at': laterCloseUtc,
              'covers': 4,
              'covers_source': 'direct',
              'opened_at': laterCloseUtc.subtract(const Duration(hours: 1)),
              'closed_at': laterCloseUtc,
              'business_date': tuesdayBusinessDateIso,
              'actual_sales': 120.0,
            },
          ];
      pool.laborPunchesByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'quickbooks_time',
              'vendor_entity_id': 'ts_composite',
              'employee_source_id': 'emp_late_composite',
              'role_name': 'server',
              'shift_start': shiftStartUtc,
              'shift_end': shiftEndUtc,
              'hours_worked': 4.5,
              'pay_rate': 22.0,
              'business_date': tuesdayBusinessDateIso,
            },
          ];
      // Reservation present so the bucketer must classify it; in
      // composite POS wins covers (stage 2 > stage 3) but the
      // reservation MUST still pass the period filter to be a
      // candidate. The covers assertion below stays POS-driven; a
      // bucketer regression on reservations would not change
      // covers but a separate assertion in P.3 covers that path.
      pool.reservationFactsByOperatorLocation['$_opA|$_locA|$tuesdayBusinessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_composite',
              'reservation_at': reservationAtUtc,
              'party_size': 4,
              'status': 'SEATED',
              'seated_at': null,
              'business_date': tuesdayBusinessDateIso,
            },
          ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: _restaurantA,
            businessDate: tuesdayBusinessDate,
            weekId: '2026-W20',
            dayLabel: 'Tue',
            servicePeriodId: 'late_night',
            periodDefinition: lateNightPeriod,
            allServicePeriodDefinitions: allPeriods,
          );

      expect(result, isNotNull);
      expect(result!.input.businessDate, tuesdayBusinessDate);
      expect(result.input.daypart, 'late_night');
      // Covers from POS sum (stage 2): 6 + 4 = 10.
      expect(result.input.covers, 10);
      // Sales from POS sum: 180 + 120 = 300.
      expect(result.input.actualSales, closeTo(300.0, 0.001));
      // Labor hours from per-period split (180 min late_night,
      // 90 min non_service excluded): 3h FOH.
      expect(result.input.actualFohHours, 3);
      // Per-period rate × hours: 3 × 22 = 66.
      expect(result.input.actualFohLaborDollars, closeTo(3 * 22.0, 0.001));
      expect(result.input.sourceSystem, 'oracle_micros_simphony');
      expect(
        result.provenance.coversProvenance,
        'vendor_oracle_micros_simphony',
      );
      expect(
        result.provenance.laborDollarsProvenance,
        'vendor_quickbooks_time_per_employee_actual_dollars_'
        'per_employee_rates',
      );
      // Close-authority provenance on a reliable POS vendor:
      // proves the auto-derive path stamps the per-vendor sidecar
      // (Slice 1.5 close-authority work) on this row.
      expect(
        result.provenance.closeAuthorityProvenance,
        'vendor_oracle_micros_simphony_reliable_finalization',
      );
    });
  });
}

// ─── Helpers + fakes ──────────────────────────────────────────────────

String get _businessDateIso =>
    '${_businessDate.year.toString().padLeft(4, '0')}'
    '-${_businessDate.month.toString().padLeft(2, '0')}'
    '-${_businessDate.day.toString().padLeft(2, '0')}';

class _FakePool implements PostgresPool {
  static const String _effectiveSettingsViewAsOfDate = '2026-05-19';

  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> dataAccuracySettingsByTenant =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id)`.
  ///
  /// When seeded, this row is returned as the already-resolved
  /// `effective_data_accuracy_settings_v` answer. Tests use it for
  /// scoped override precedence cases where the raw keyed base row is
  /// intentionally not the effective winner.
  final Map<String, Map<String, Object?>>
  effectiveDataAccuracySettingsByTenant = <String, Map<String, Object?>>{};

  /// Hardening Wave B1 — keyed by `(operator_id, location_id,
  /// service_period_key)`. The fake returns the row when
  /// `effective_at_business_date <= @business_date`; tests pre-seed
  /// rows whose effective date should win the at-or-before lookup.
  final Map<String, Map<String, Object?>>
  dataAccuracyServicePeriodSettingsByTenant = <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, business_date_iso)`.
  final Map<String, List<Map<String, Object?>>> coverFactsByOperatorLocation =
      <String, List<Map<String, Object?>>>{};
  final Map<String, List<Map<String, Object?>>> laborPunchesByOperatorLocation =
      <String, List<Map<String, Object?>>>{};
  final Map<String, List<Map<String, Object?>>>
  reservationFactsByOperatorLocation = <String, List<Map<String, Object?>>>{};

  /// Keyed by `(operator_id, location_id, business_date_iso, daypart)`.
  /// Pre-seed when a test wants to exercise priorTargetProfileVersionId.
  final Map<String, String> shiftRecordTpvBySlot = <String, String>{};

  /// Keyed by `(operator_id, location_id, business_date_iso, daypart)`.
  /// Pre-seed when a test wants prior timing provenance as well.
  final Map<String, Map<String, Object?>> shiftRecordProvenanceBySlot =
      <String, Map<String, Object?>>{};

  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  void seedLocation(
    String operatorId,
    String locationId, {
    String timezone = 'America/Toronto',
    String businessDayStartLocalTime = '04:00:00',
    int? businessDayRolloverHour = 4,
  }) {
    _locations['$operatorId|$locationId'] = <String, Object?>{
      'timezone': timezone,
      'business_day_start_local_time': businessDayStartLocalTime,
      if (businessDayRolloverHour != null)
        'business_day_rollover_hour': businessDayRolloverHour,
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
    if (sql.contains('from public.effective_data_accuracy_settings_v')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final tenantKey = '$operatorId|$locationId';
      final directRow = pool.effectiveDataAccuracySettingsByTenant[tenantKey];
      if (directRow != null) return <PostgresRow>[directRow];
      final row = pool.dataAccuracySettingsByTenant[tenantKey];
      if (row == null) return const <PostgresRow>[];

      final perPeriod = <String, Object?>{};
      final rawPerPeriod = row['covers_source_per_service_period'];
      if (rawPerPeriod is Map) {
        rawPerPeriod.forEach((key, value) {
          if (key is String && value is String) perPeriod[key] = value;
        });
      }
      final perPeriodSources = <String, Object?>{};
      final rawPerPeriodSources =
          row['covers_source_per_service_period_source'];
      if (rawPerPeriodSources is Map) {
        rawPerPeriodSources.forEach((key, value) {
          if (key is String && value is Map) perPeriodSources[key] = value;
        });
      }

      final prefix = '$operatorId|$locationId|';
      pool.dataAccuracyServicePeriodSettingsByTenant.forEach((key, kr) {
        if (!key.startsWith(prefix)) return;
        final effectiveAt = kr['effective_at_business_date'];
        if (effectiveAt is String &&
            effectiveAt.compareTo(_FakePool._effectiveSettingsViewAsOfDate) >
                0) {
          return;
        }
        final spk = kr['service_period_key'];
        final cs = kr['covers_source'];
        final id = kr['id'];
        if (spk is! String || cs is! String) return;
        perPeriod[spk] = cs;
        perPeriodSources[spk] = <String, Object?>{
          'scope_type': 'location',
          'scope_id': locationId,
          'source_kind': 'service_period_setting',
          if (id is String) 'setting_id': id,
        };
      });

      final projected = Map<String, Object?>.from(row);
      projected['covers_source_per_service_period'] = perPeriod;
      projected['covers_source_per_service_period_source'] = perPeriodSources;
      return <PostgresRow>[projected];
    }

    // The raw keyed read is now only the date-aware base lookup. The
    // effective settings read above is routed through
    // `effective_data_accuracy_settings_v`, so this branch must only
    // handle queries carrying the standalone service-period parameter.
    final hasServicePeriodKeyParam = parameters['service_period_key'] is String;
    if (sql.contains('from public.data_accuracy_service_period_settings') &&
        hasServicePeriodKeyParam) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final servicePeriodKey = parameters['service_period_key'] as String;
      final businessDate = parameters['business_date'] as String;
      final row = pool
          .dataAccuracyServicePeriodSettingsByTenant['$operatorId|$locationId|$servicePeriodKey'];
      if (row == null) return const <PostgresRow>[];
      // Honour the at-or-before contract — if the seeded effective
      // date is AFTER the queried business_date, return no row.
      final effectiveAt = row['effective_at_business_date'];
      if (effectiveAt is String && effectiveAt.compareTo(businessDate) > 0) {
        return const <PostgresRow>[];
      }
      return <PostgresRow>[row];
    }
    if (sql.contains('from data_accuracy_settings')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final row = pool.dataAccuracySettingsByTenant['$operatorId|$locationId'];
      if (row == null) return const <PostgresRow>[];
      // The R5 DAS read projects a `covers_source_per_service_period`
      // jsonb (from the keyed table) instead of the legacy columns.
      // Synthesize it from any seeded keyed rows for this tenant so
      // the model's `coversSourceFor` resolves the same way the real
      // keyed sub-SELECT would; the seeded legacy columns on the row
      // remain as the backward-compat fallback fromRow honours.
      final perPeriod = <String, Object?>{};
      final prefix = '$operatorId|$locationId|';
      final businessDate = parameters['business_date'] as String?;
      pool.dataAccuracyServicePeriodSettingsByTenant.forEach((key, kr) {
        if (!key.startsWith(prefix)) return;
        final effectiveAt = kr['effective_at_business_date'];
        if (businessDate != null &&
            effectiveAt is String &&
            effectiveAt.compareTo(businessDate) > 0) {
          return;
        }
        final spk = kr['service_period_key'];
        final cs = kr['covers_source'];
        if (spk is String && cs is String) perPeriod[spk] = cs;
      });
      final projected = Map<String, Object?>.from(row);
      projected['covers_source_per_service_period'] = perPeriod;
      return <PostgresRow>[projected];
    }
    if (sql.contains('from public.business_timing_profiles p')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final row = pool.readLocation(operatorId, locationId);
      if (row == null) return const <PostgresRow>[];
      final cutoff =
          row['business_day_start_local_time'] as String? ?? '04:00:00';
      final timezone = row['timezone'] as String? ?? 'America/Toronto';
      return <PostgresRow>[
        <String, Object?>{
          'profile_id': '99999999-9999-4999-8999-999999999999',
          'operator_id': operatorId,
          'scope_type': 'location',
          'scope_id': locationId,
          'display_name': null,
          'business_day_start_local_time': cutoff,
          'week_start_day': DateTime.monday,
          'close_authority': 'app_local_cutoff_fallback',
          'local_close_fallback_time': null,
          'effective_from_business_date': '2026-01-01',
          'effective_until_business_date': null,
          'supersedes_profile_id': null,
          'created_by': null,
          'updated_by': null,
          'created_at': DateTime.utc(2026, 1, 1),
          'updated_at': DateTime.utc(2026, 1, 1),
          'location_timezone': timezone,
          'service_periods': <Map<String, Object?>>[
            <String, Object?>{
              'service_period_id': '88888888-8888-4888-8888-888888888888',
              'operator_id': operatorId,
              'profile_id': '99999999-9999-4999-8999-999999999999',
              'service_period_key': 'lunch',
              'label': 'Lunch',
              'short_label': 'L',
              'sort_order': 1,
              'start_local_time': '11:00',
              'end_local_time': '15:00',
              'rolls_past_midnight': false,
              'applicable_weekdays': <int>[1, 2, 3, 4, 5, 6, 7],
            },
          ],
        },
      ];
    }
    if (sql.contains('select timezone from public.locations') ||
        sql.contains(
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
      // Per-Daypart V1 Slice 1.5: aggregator now reads punches over a
      // 3-day business-date window (prior_business_date,
      // next_business_date). The fake returns the union of any rows
      // seeded under prior, middle, and next dates so cross-(business-
      // date) splits work.
      final prior = parameters['prior_business_date'] as String;
      final next = parameters['next_business_date'] as String;
      // Compute the middle date as the day after `prior` (== the day
      // before `next`).
      final priorDt = DateTime.parse(prior);
      final mid = priorDt.add(const Duration(days: 1));
      final midIso =
          '${mid.year.toString().padLeft(4, '0')}-'
          '${mid.month.toString().padLeft(2, '0')}-'
          '${mid.day.toString().padLeft(2, '0')}';
      final keys = <String>[
        '$operatorId|$locationId|$prior',
        '$operatorId|$locationId|$midIso',
        '$operatorId|$locationId|$next',
      ];
      final rows = <Map<String, Object?>>[];
      for (final key in keys) {
        rows.addAll(
          pool.laborPunchesByOperatorLocation[key] ??
              const <Map<String, Object?>>[],
        );
      }
      return rows;
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
      final provenance = pool
          .shiftRecordProvenanceBySlot['$operatorId|$locationId|$businessDate|$daypart'];
      if (provenance != null) return <PostgresRow>[provenance];
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
    return 0;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {}
}
