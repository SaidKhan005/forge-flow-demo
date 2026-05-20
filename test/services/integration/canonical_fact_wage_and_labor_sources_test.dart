// Phase 8 spine-bridge — aggregator wage + labor source tests.
//
// Bucket 5a of the 2026-05-20 test-suite tightening audit: extracted
// from the original 3,981-line
// `canonical_fact_to_closed_shift_input_test.dart` mega-file. Covers
// groups G (perPositionWithRates / Humanity), H (manual_mix), I (perEmployeeWithRates / QBT), and J (hoursOnly fallback). Shared fakes + constants live in
// `canonical_fact_test_fixtures.dart` (also part of Bucket 5a).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';

import 'canonical_fact_test_fixtures.dart';

void main() {
  // ─────────────────── G — perPositionWithRates (Humanity) ────────────────
  group('aggregator — G. wage perPositionWithRates (Humanity)', () {
    test(
      'Humanity per-position rates compute dollars via rate × hours',
      () async {
        final pool = FakePool()..seedLocation(opA, locA);
        // POS covers from Oracle so the aggregator has a sales source.
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_001',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 12,
            'covers_source': 'direct',
            'opened_at': dinnerInstantUtc,
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 480.00,
          },
        ];
        pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] =
            [
              <String, Object?>{
                'vendor_id': 'humanity',
                'vendor_entity_id': 'sched_001',
                'employee_source_id': 'emp_1',
                'role_name': 'server',
                'shift_start': dinnerInstantUtc,
                'shift_end': dinnerInstantUtc.add(const Duration(hours: 4)),
                'hours_worked': 4,
                'pay_rate': 22.0,
                'business_date': businessDateIso,
              },
              <String, Object?>{
                'vendor_id': 'humanity',
                'vendor_entity_id': 'sched_002',
                'employee_source_id': 'emp_2',
                'role_name': 'cook',
                'shift_start': dinnerInstantUtc,
                'shift_end': dinnerInstantUtc.add(const Duration(hours: 5)),
                'hours_worked': 5,
                'pay_rate': 24.0,
                'business_date': businessDateIso,
              },
            ];

        final aggregator = CanonicalFactToClosedShiftInputAggregator(
          TenantTransactionWrapper(pool),
        );

        final result = await aggregator.aggregate(
          operatorId: opA,
          locationId: locA,
          restaurantId: restaurantA,
          businessDate: businessDate,
          weekId: '2026-W18',
          dayLabel: 'Mon',
          servicePeriodId: 'dinner',
          periodDefinition: dinnerPeriod,
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

  // ─────────────────── H — manual_mix override ────────────────────────────
  group('aggregator — H. wage manual_mix override', () {
    test('wage_source = manual_mix forces target_wage_substituted '
        'regardless of vendor capability', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': opA,
        'location_id': locA,
        'covers_source_per_service_period': vendorCoversSourcePerServicePeriod,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'manual_mix',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 10,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 400.00,
        },
      ];
      // QBT rates exist but manual_mix override forces ignoring them.
      pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': dinnerInstantUtc,
          'shift_end': dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 4,
          'pay_rate': 18.0,
          'business_date': businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final result = await aggregator.aggregate(
        operatorId: opA,
        locationId: locA,
        restaurantId: restaurantA,
        businessDate: businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
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

  // ─────────────────── I — perEmployeeWithRates (QBT) ─────────────────────
  group('aggregator — I. wage perEmployeeWithRates (QBT)', () {
    test('QuickBooks Time per-employee rates compute dollars via '
        'rate × duration; provenance carries the per_employee_rates '
        'qualifier', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 10,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 400.00,
        },
      ];
      pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': dinnerInstantUtc,
          'shift_end': dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 4,
          'pay_rate': 18.0,
          'business_date': businessDateIso,
        },
        <String, Object?>{
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_002',
          'employee_source_id': 'emp_2',
          'role_name': 'cook',
          'shift_start': dinnerInstantUtc,
          'shift_end': dinnerInstantUtc.add(const Duration(hours: 6)),
          'hours_worked': 6,
          'pay_rate': 22.0,
          'business_date': businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final result = await aggregator.aggregate(
        operatorId: opA,
        locationId: locA,
        restaurantId: restaurantA,
        businessDate: businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
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

  // ─────────────────── J — hoursOnly (ADP, Push Operations) ───────────────
  group('aggregator — J. wage hoursOnly fallback', () {
    test('ADP punches with no rates -> '
        'vendor_adp_dollars_unavailable_target_wage_substituted', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 10,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 400.00,
        },
      ];
      pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'adp',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': dinnerInstantUtc,
          'shift_end': dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 4,
          'pay_rate': null, // ADP wage ingestion deferred V1.
          'business_date': businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final result = await aggregator.aggregate(
        operatorId: opA,
        locationId: locA,
        restaurantId: restaurantA,
        businessDate: businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
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
      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 10,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 400.00,
        },
      ];
      pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'push_operations',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'cook',
          'shift_start': dinnerInstantUtc,
          'shift_end': dinnerInstantUtc.add(const Duration(hours: 5)),
          'hours_worked': 5,
          'pay_rate': null,
          'business_date': businessDateIso,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final result = await aggregator.aggregate(
        operatorId: opA,
        locationId: locA,
        restaurantId: restaurantA,
        businessDate: businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
      );

      expect(result, isNotNull);
      expect(
        result!.provenance.laborDollarsProvenance,
        'vendor_push_operations_dollars_unavailable_target_wage_substituted',
      );
    });
  });

  // ─────────────────── L — RLS + tenancy ─────────────────────────────────
}
