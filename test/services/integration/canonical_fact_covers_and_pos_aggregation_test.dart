// Phase 8 spine-bridge — aggregator covers + POS aggregation tests.
//
// Bucket 5a of the 2026-05-20 test-suite tightening audit: extracted
// from the original 3,981-line
// `canonical_fact_to_closed_shift_input_test.dart` mega-file. Covers
// groups A (trio aggregation), timing provenance, B (multi-POS), C (forecast substitution), D (manual entry), D-FU (POS-fallback manual), E (reservation + walk-in), and F (Tock without seated_at). Shared fakes + constants live in
// `canonical_fact_test_fixtures.dart` (also part of Bucket 5a).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';

import 'canonical_fact_test_fixtures.dart';

void main() {
  // ─────────────────────────── A — trio aggregation ───────────────────────
  group('aggregator — A. trio aggregation (Oracle + QBT + Libro)', () {
    test('writes ClosedShiftInput + provenance with vendor strings for '
        'covers and labor dollars', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 5,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc.subtract(const Duration(hours: 1)),
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 124.85,
        },
      ];
      pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_001',
          'employee_source_id': 'emp_1',
          'role_name': 'server',
          'shift_start': dinnerInstantUtc.subtract(const Duration(hours: 1)),
          'shift_end': dinnerInstantUtc.add(const Duration(hours: 4)),
          'hours_worked': 5,
          'pay_rate': 18.0,
          'business_date': businessDateIso,
        },
        <String, Object?>{
          'vendor_id': 'quickbooks_time',
          'vendor_entity_id': 'ts_002',
          'employee_source_id': 'emp_2',
          'role_name': 'cook',
          'shift_start': dinnerInstantUtc.subtract(const Duration(hours: 1)),
          'shift_end': dinnerInstantUtc.add(const Duration(hours: 5)),
          'hours_worked': 6,
          'pay_rate': 20.0,
          'business_date': businessDateIso,
        },
      ];
      pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_001',
              'reservation_at': dinnerInstantUtc,
              'party_size': 4,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
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

  // ─────────────────── B — multiple POS adapters at same slot ─────────────
  group('aggregator - timing provenance', () {
    test('stamps ClosedShiftInput with the effective timing profile and '
        'service period used for bucketing', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 5,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc.subtract(const Duration(hours: 1)),
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 124.85,
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
        businessTimingProfileId: timingProfileA,
      );

      expect(result, isNotNull);
      expect(result!.input.businessTimingProfileId, timingProfileA);
      expect(
        result.input.businessTimingProfileVersionId,
        timingProfileA,
        reason: 'Lane 0 maps the V1 version id to the profile id',
      );
      expect(result.input.servicePeriodKey, 'dinner');
    });

    test(
      'carries prior closed timing provenance for replay preservation',
      () async {
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_001',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 5,
            'covers_source': 'direct',
            'opened_at': dinnerInstantUtc.subtract(const Duration(hours: 1)),
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 124.85,
          },
        ];
        pool.shiftRecordProvenanceBySlot['$opA|$locA|$businessDateIso|dinner'] =
            <String, Object?>{
              'target_profile_version_id': 'tpv_X',
              'business_timing_profile_id': timingProfileA,
              'business_timing_profile_version_id': timingProfileA,
              'service_period_key': 'dinner',
            };

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
          businessTimingProfileId: timingProfileB,
        );

        expect(result, isNotNull);
        expect(
          result!.input.businessTimingProfileId,
          timingProfileB,
          reason: 'current bucketing still records the effective profile',
        );
        expect(result.provenance.hasPriorShiftRecord, isTrue);
        expect(result.provenance.priorTargetProfileVersionId, 'tpv_X');
        expect(result.provenance.priorBusinessTimingProfileId, timingProfileA);
        expect(
          result.provenance.priorBusinessTimingProfileVersionId,
          timingProfileA,
        );
        expect(result.provenance.priorServicePeriodKey, 'dinner');
      },
    );
  });


  group('aggregator — B. MultiplePosAdaptersException', () {
    test('two POS vendors writing the same daypart -> exception', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 5,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc.subtract(const Duration(hours: 1)),
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 100.00,
        },
        <String, Object?>{
          'vendor_id': 'toast',
          'vendor_entity_id': 'check_002',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 3,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc.subtract(const Duration(hours: 1)),
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 90.00,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      await expectLater(
        () => aggregator.aggregate(
          operatorId: opA,
          locationId: locA,
          restaurantId: restaurantA,
          businessDate: businessDate,
          weekId: '2026-W18',
          dayLabel: 'Mon',
          servicePeriodId: 'dinner',
          periodDefinition: dinnerPeriod,
        ),
        throwsA(isA<MultiplePosAdaptersException>()),
      );
    });
  });

  // ─────────────────── C — Square coversFieldExposed=false → forecast ─────

  // ─────────────────── C — Square coversFieldExposed=false → forecast ─────
  group('aggregator — C. forecast substitution when POS lacks covers', () {
    test('Square (coversFieldExposed=false) row + forecast available -> '
        'vendor_square_covers_unavailable_app_forecast_substituted', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      // Square fact lacks covers (covers = 0) but actual_sales is
      // populated (Square exposes sales but not covers per 2026-05-05
      // confirmation).
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'forecast_fallback',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 250.00,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final forecast = DemandForecastContext(
        restaurantId: restaurantA,
        anchorBusinessDate: businessDateIso,
        baselineTotalCovers: 1500,
        baselineWeeklyAvgCovers: 175,
        baselineWeeksRepresented: 60 / 7,
        recentThreeWeekTotalCovers: 525,
        recentThreeWeekWeeklyAvgCovers: 175,
        recentTrendDeltaCovers: 0,
        // 210 weekly / 7 days / 3 dayparts ≈ 10 per daypart.
        resolvedWeeklyForecastCovers: 210,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: businessDateIso,
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
          'setting_id': 'das_forecast_explicit',
          'operator_id': opA,
          'location_id': locA,
          'covers_manual_entries': <String, Map<String, int>>{},
          'wage_source': 'vendor',
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 4),
          'updated_by': null,
        };
        pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
            <String, Object?>{
              'id': '99999999-9999-9999-9999-999999999993',
              'operator_id': opA,
              'location_id': locA,
              'service_period_key': 'dinner',
              'covers_source': 'forecast',
              'wage_source': 'vendor_per_employee',
              'effective_at_business_date': '2026-05-01',
              'created_at': DateTime.utc(2026, 5, 1),
              'updated_at': DateTime.utc(2026, 5, 1),
              'updated_by': null,
            };
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'toast',
            'vendor_entity_id': 'check_toast_forecast_explicit',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 92,
            'covers_source': 'direct',
            'opened_at': dinnerInstantUtc,
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 2310.50,
          },
        ];

        final forecast = DemandForecastContext(
          restaurantId: restaurantA,
          anchorBusinessDate: businessDateIso,
          baselineTotalCovers: 1500,
          baselineWeeklyAvgCovers: 175,
          baselineWeeksRepresented: 60 / 7,
          resolvedWeeklyForecastCovers: 210,
          coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
          builtAt: businessDateIso,
        );

        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
              businessDate: businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'dinner',
              periodDefinition: dinnerPeriod,
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

  // ─────────────────── D — operator manual entry ──────────────────────────
  group('aggregator — D. operator manual entry per daypart', () {
    test('manual entry overrides everything; provenance + sourceSystem '
        'reflect operator origin', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      // Seed keyed operator preference: dinner = manual, value 187.
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': opA,
        'location_id': locA,
        'covers_source_per_service_period':
            manualDinnerCoversSourcePerServicePeriod,
        'covers_manual_entries': <String, Map<String, int>>{
          businessDateIso: <String, int>{'dinner': 187},
        },
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999991',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      // POS row exists but operator preference wins.
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'forecast_fallback',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 250.00,
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
      expect(result!.input.covers, 187);
      expect(result.input.sourceSystem, 'operator_manual_entry');
      expect(
        result.provenance.coversProvenance,
        'operator_manual_entry_per_daypart',
      );
    });

    test('manual source with no value returns null even when vendor and '
        'forecast data are present', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_manual_missing',
        'operator_id': opA,
        'location_id': locA,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999992',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'toast',
          'vendor_entity_id': 'check_toast_manual_missing',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 92,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 2310.50,
        },
      ];

      final forecast = DemandForecastContext(
        restaurantId: restaurantA,
        anchorBusinessDate: businessDateIso,
        baselineTotalCovers: 1500,
        baselineWeeklyAvgCovers: 175,
        baselineWeeksRepresented: 60 / 7,
        resolvedWeeklyForecastCovers: 210,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        builtAt: businessDateIso,
      );

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: opA,
            locationId: locA,
            restaurantId: restaurantA,
            businessDate: businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: dinnerPeriod,
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
        final pool = FakePool()..seedLocation(opA, locA);
        // Toast row carries covers; capability mirror says Toast
        // exposes covers, so stage 2 must win even though the
        // operator typed a manual entry for the same slot.
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'toast',
            'vendor_entity_id': 'check_toast_001',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 92,
            'covers_source': 'direct',
            'opened_at': dinnerInstantUtc.subtract(const Duration(hours: 1)),
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 2310.50,
          },
        ];
        // Operator typed a manual entry for the same slot. Operator
        // preference is the default ('vendor'), so stage 1 does not
        // fire. The new stage 3.5 also does not fire because Toast
        // exposes covers (capability mirror).
        pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
          'setting_id': 'das_002',
          'operator_id': opA,
          'location_id': locA,
          'covers_source_per_service_period':
              vendorCoversSourcePerServicePeriod,
          'covers_manual_entries': <String, Map<String, int>>{
            businessDateIso: <String, int>{'dinner': 500},
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
          result!.input.covers,
          92,
          reason: 'Toast (coversFieldExposed=true) wins; manual ignored',
        );
        expect(result.input.sourceSystem, 'toast');
        expect(result.provenance.coversProvenance, 'vendor_toast');
      });

      test('POS exposes covers (Toast) + vendor reports zero -> zero is '
          'closed truth, not a manual or forecast fallback', () async {
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'toast',
            'vendor_entity_id': 'check_toast_zero',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 0,
            'covers_source': 'direct',
            'opened_at': dinnerInstantUtc.subtract(const Duration(hours: 1)),
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 0.0,
          },
        ];
        pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
          'setting_id': 'das_zero_truth',
          'operator_id': opA,
          'location_id': locA,
          'covers_manual_entries': <String, Map<String, int>>{
            businessDateIso: <String, int>{'dinner': 500},
          },
          'wage_source': 'vendor',
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 4),
          'updated_by': null,
        };
        final forecast = DemandForecastContext(
          restaurantId: restaurantA,
          anchorBusinessDate: businessDateIso,
          baselineTotalCovers: 1500,
          baselineWeeklyAvgCovers: 175,
          baselineWeeksRepresented: 60 / 7,
          resolvedWeeklyForecastCovers: 210,
          coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
          builtAt: businessDateIso,
        );

        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
              businessDate: businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'dinner',
              periodDefinition: dinnerPeriod,
              forecastContext: forecast,
            );

        expect(result, isNotNull);
        expect(result!.input.covers, 0);
        expect(result.input.sourceSystem, 'toast');
        expect(result.provenance.coversProvenance, 'vendor_toast');
      });

      test(
        'POS does NOT expose covers (Square) + manual entries present -> '
        'manual projected with operator_manual_entry_fallback_pos_not_exposed',
        () async {
          final pool = FakePool()..seedLocation(opA, locA);
          // Square row exists but POS does not expose covers
          // (coversFieldExposed=false); stage 2 ignores the row before
          // looking at the numeric value. Stage 3.5 fires because the
          // operator typed a manual entry for the slot.
          pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
              [
                <String, Object?>{
                  'vendor_id': 'square',
                  'vendor_entity_id': 'order_sq_001',
                  'vendor_modified_at': dinnerInstantUtc,
                  'covers': 0,
                  'covers_source': 'forecast_fallback',
                  'opened_at': dinnerInstantUtc,
                  'closed_at': dinnerInstantUtc,
                  'business_date': businessDateIso,
                  'actual_sales': 850.00,
                },
              ];
          pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
            'setting_id': 'das_003',
            'operator_id': opA,
            'location_id': locA,
            'covers_source_per_service_period':
                vendorCoversSourcePerServicePeriod,
            'covers_manual_entries': <String, Map<String, int>>{
              businessDateIso: <String, int>{'dinner': 73},
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
            restaurantId: restaurantA,
            anchorBusinessDate: businessDateIso,
            baselineTotalCovers: 1500,
            baselineWeeklyAvgCovers: 175,
            baselineWeeksRepresented: 60 / 7,
            recentThreeWeekTotalCovers: 525,
            recentThreeWeekWeeklyAvgCovers: 175,
            recentTrendDeltaCovers: 0,
            resolvedWeeklyForecastCovers: 210,
            coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
            builtAt: businessDateIso,
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'square',
            'vendor_entity_id': 'order_sq_002',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 0,
            'covers_source': 'forecast_fallback',
            'opened_at': dinnerInstantUtc,
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 612.40,
          },
        ];
        // No manual entries seeded; default DataAccuracySettings
        // (covers_manual_entries empty) is constructed by the
        // aggregator when no row exists for the tenant.
        final forecast = DemandForecastContext(
          restaurantId: restaurantA,
          anchorBusinessDate: businessDateIso,
          baselineTotalCovers: 1500,
          baselineWeeklyAvgCovers: 175,
          baselineWeeksRepresented: 60 / 7,
          recentThreeWeekTotalCovers: 525,
          recentThreeWeekWeeklyAvgCovers: 175,
          recentTrendDeltaCovers: 0,
          resolvedWeeklyForecastCovers: 210,
          coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
          builtAt: businessDateIso,
        );

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
          final pool = FakePool()..seedLocation(opA, locA);
          // No cover_facts seeded — posVendorId resolves to null;
          // capability lookup returns null which the aggregator treats
          // as "lacks coverage" (safer assumption).
          pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
            'setting_id': 'das_004',
            'operator_id': opA,
            'location_id': locA,
            'covers_source_per_service_period':
                vendorCoversSourcePerServicePeriod,
            'covers_manual_entries': <String, Map<String, int>>{
              businessDateIso: <String, int>{'dinner': 41},
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

  // ─────────────────── E — reservation + walk-in Pattern A ────────────────
  group('aggregator — E. reservation+walk-in (Square + Libro)', () {
    test('seated party_size sum + operator walk-in count -> '
        'vendor_libro_seated_plus_operator_walk_in_count', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      seedReservationPlusWalkinPreference(pool, 'dinner');
      // Square fact with no covers (POS does not expose covers).
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'forecast_fallback',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 525.00,
        },
      ];
      // Libro reservations seated this daypart.
      pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_001',
              'reservation_at': dinnerInstantUtc,
              'party_size': 4,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
              'business_date': businessDateIso,
            },
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_002',
              'reservation_at': dinnerInstantUtc,
              'party_size': 6,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
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
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_reservation_plus_walkin',
        'operator_id': opA,
        'location_id': locA,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999994',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'reservation_plus_walkin',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'toast',
          'vendor_entity_id': 'check_toast_reservation_choice',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 92,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 2310.50,
        },
      ];
      pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_001',
              'reservation_at': dinnerInstantUtc,
              'party_size': 4,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
              'business_date': businessDateIso,
            },
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_002',
              'reservation_at': dinnerInstantUtc,
              'party_size': 6,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
              'business_date': businessDateIso,
            },
          ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: opA,
            locationId: locA,
            restaurantId: restaurantA,
            businessDate: businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: dinnerPeriod,
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
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_walk_in',
        'operator_id': opA,
        'location_id': locA,
        'covers_source_per_service_period': vendorCoversSourcePerServicePeriod,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'walk_in_handling_mode': 'walk_ins_added_to_reservations',
        'walk_in_manual_entries': <String, int>{businessDateIso: 11},
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': 'operator-admin',
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': 'das_walk_in_dinner',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'reservation_plus_walkin',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': 'operator-admin',
          };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'forecast_fallback',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 525.00,
        },
      ];
      pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_001',
              'reservation_at': dinnerInstantUtc,
              'party_size': 4,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
              'business_date': businessDateIso,
            },
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_002',
              'reservation_at': dinnerInstantUtc,
              'party_size': 6,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
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
      expect(result!.input.covers, 21);
      expect(
        result.provenance.coversProvenance,
        'vendor_libro_seated_plus_operator_walk_in_count',
      );
    });

    test('per-service-period walk-in count overrides daily fallback', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_walk_in_split',
        'operator_id': opA,
        'location_id': locA,
        'covers_source_per_service_period': vendorCoversSourcePerServicePeriod,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'walk_in_handling_mode': 'walk_ins_added_to_reservations',
        'walk_in_manual_entries': <String, int>{
          businessDateIso: 30,
          '$businessDateIso|dinner': 7,
        },
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': 'operator-admin',
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': 'das_walk_in_split_dinner',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'reservation_plus_walkin',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': 'operator-admin',
          };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'forecast_fallback',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 525.00,
        },
      ];
      pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_001',
              'reservation_at': dinnerInstantUtc,
              'party_size': 10,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
              'business_date': businessDateIso,
            },
          ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: opA,
            locationId: locA,
            restaurantId: restaurantA,
            businessDate: businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: dinnerPeriod,
            allServicePeriodDefinitions: standardPeriods,
          );

      expect(result, isNotNull);
      expect(result!.input.covers, 17);
    });

    test(
      'legacy daily walk-in count is split across configured periods',
      () async {
        final pool = FakePool()..seedLocation(opA, locA);
        pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
          'setting_id': 'das_walk_in_daily_split',
          'operator_id': opA,
          'location_id': locA,
          'covers_source_per_service_period':
              vendorCoversSourcePerServicePeriod,
          'covers_manual_entries': <String, Map<String, int>>{},
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'walk_ins_added_to_reservations',
          'walk_in_manual_entries': <String, int>{businessDateIso: 11},
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 4),
          'updated_by': 'operator-admin',
        };
        pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
            <String, Object?>{
              'id': 'das_walk_in_daily_split_dinner',
              'operator_id': opA,
              'location_id': locA,
              'service_period_key': 'dinner',
              'covers_source': 'reservation_plus_walkin',
              'wage_source': 'vendor_per_employee',
              'effective_at_business_date': '2026-05-01',
              'created_at': DateTime.utc(2026, 5, 1),
              'updated_at': DateTime.utc(2026, 5, 1),
              'updated_by': 'operator-admin',
            };
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'square',
            'vendor_entity_id': 'order_001',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 0,
            'covers_source': 'forecast_fallback',
            'opened_at': dinnerInstantUtc,
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 525.00,
          },
        ];
        pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
            [
              <String, Object?>{
                'vendor_id': 'libro',
                'vendor_entity_id': 'res_001',
                'reservation_at': dinnerInstantUtc,
                'party_size': 10,
                'status': 'SEATED',
                'seated_at': dinnerInstantUtc,
                'business_date': businessDateIso,
              },
            ];

        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
              businessDate: businessDate,
              weekId: '2026-W18',
              dayLabel: 'Mon',
              servicePeriodId: 'dinner',
              periodDefinition: dinnerPeriod,
              allServicePeriodDefinitions: standardPeriods,
            );

        expect(result, isNotNull);
        // 11 daily walk-ins split by default 45/40/15 period weights:
        // lunch 5, dinner 4, late night 2.
        expect(result!.input.covers, 14);
      },
    );

    test('vendor preference does not silently use reservation facts', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_vendor_preference',
        'operator_id': opA,
        'location_id': locA,
        'covers_manual_entries': <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'walk_in_handling_mode': 'reservations_only',
        'walk_in_manual_entries': <String, Object?>{},
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999993',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'vendor',
            'wage_source': 'vendor_per_employee',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'order_no_covers',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 0,
          'covers_source': 'not_exposed',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 525.00,
        },
      ];
      pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_001',
              'reservation_at': dinnerInstantUtc,
              'party_size': 4,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
              'business_date': businessDateIso,
            },
            <String, Object?>{
              'vendor_id': 'libro',
              'vendor_entity_id': 'res_002',
              'reservation_at': dinnerInstantUtc,
              'party_size': 6,
              'status': 'SEATED',
              'seated_at': dinnerInstantUtc,
              'business_date': businessDateIso,
            },
          ];

      final result =
          await CanonicalFactToClosedShiftInputAggregator(
            TenantTransactionWrapper(pool),
          ).aggregate(
            operatorId: opA,
            locationId: locA,
            restaurantId: restaurantA,
            businessDate: businessDate,
            weekId: '2026-W18',
            dayLabel: 'Mon',
            servicePeriodId: 'dinner',
            periodDefinition: dinnerPeriod,
          );

      expect(result, isNull);
    });
  });

  // ─────────────────── F — Tock (no seated_at; serviceDateTimestamp) ──────

  // ─────────────────── F — Tock (no seated_at; serviceDateTimestamp) ──────
  group('aggregator — F. Tock daypart bucketing without seated_at', () {
    test('Tock reservation_facts with no seated_at still bucket by '
        'reservation_at; SEATED party_size sums', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      seedReservationPlusWalkinPreference(pool, 'dinner');
      pool.reservationFactsByOperatorLocation['$opA|$locA|$businessDateIso'] =
          [
            <String, Object?>{
              'vendor_id': 'tock',
              'vendor_entity_id': 'res_001',
              // reservation_at populated from Tock's serviceDateTimestamp;
              // seated_at deliberately null per the 2026-05-05 binding
              // correction (Tock public docs do not expose seated_at).
              'reservation_at': dinnerInstantUtc,
              'party_size': 8,
              'status': 'SEATED',
              'seated_at': null,
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
}
