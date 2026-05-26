// Phase 8 spine-bridge — aggregator RLS + regression checks.
//
// Bucket 5a of the 2026-05-20 test-suite tightening audit: extracted
// from the original 3,981-line
// `canonical_fact_to_closed_shift_input_test.dart` mega-file. Covers
// groups L (RLS + tenancy), N (R7f covers resolution), M (banned-items grep), O (Per-Daypart V1 regressions), and P (operator business-hours scenarios). Shared fakes + constants live in
// `canonical_fact_test_fixtures.dart` (also part of Bucket 5a).

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/demand_forecast_context.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/daypart_bucketer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';

import 'canonical_fact_test_fixtures.dart';

void main() {
  // ─────────────────── L — RLS + tenancy ─────────────────────────────────
  group('aggregator — L. RLS + tenancy injection', () {
    test('every aggregator transaction injects '
        'app.operator_id / app.location_id via set_config', () async {
      final pool = FakePool()
        ..seedLocation(opA, locA)
        ..seedLocation(opB, locB);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 5,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 100.00,
        },
      ];
      pool.coverFactsByOperatorLocation['$opB|$locB|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 9,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 200.00,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );

      final resultA = await aggregator.aggregate(
        operatorId: opA,
        locationId: locA,
        restaurantId: restaurantA,
        businessDate: businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
      );
      final resultB = await aggregator.aggregate(
        operatorId: opB,
        locationId: locB,
        restaurantId: restaurantA,
        businessDate: businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
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
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': opA,
        'location_id': locA,
        'covers_source_per_service_period': vendorCoversSourcePerServicePeriod,
        'covers_manual_entries': <String, Map<String, int>>{
          businessDateIso: <String, int>{'dinner': 142},
        },
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      // Keyed setting wins: covers_source=manual for service period
      // 'dinner' effective from 2026-05-01 (≤ business_date 2026-05-04).
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999999',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      // POS row exists but operator manual preference must win.
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
      final pool = FakePool()..seedLocation(opA, locA);
      pool.effectiveDataAccuracySettingsByTenant['$opA|$locA'] =
          <String, Object?>{
            'setting_id': 'org_override_effective',
            'operator_id': opA,
            'location_id': locA,
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
              businessDateIso: <String, int>{'dinner': 142},
            },
            'wage_source': 'vendor',
            'walk_in_handling_mode': 'reservations_only',
            'walk_in_manual_entries': const <String, Object?>{},
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 4),
            'updated_by': null,
          };
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999990',
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
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 73,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 1184.50,
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
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': opA,
        'location_id': locA,
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
            'id': '99999999-9999-9999-9999-999999999989',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-05-10',
            'created_at': DateTime.utc(2026, 5, 10),
            'updated_at': DateTime.utc(2026, 5, 10),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 61,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 912.25,
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
      final pool = FakePool()..seedLocation(opA, locA);
      // Keyed table is empty for this
      // (operator, location, service_period_key), so vendor is the
      // effective default.
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': opA,
        'location_id': locA,
        'covers_source_per_service_period': vendorCoversSourcePerServicePeriod,
        'covers_manual_entries': const <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      // POS supplies covers; vendor preference flows through stage 2.
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 73,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 1184.50,
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
      expect(result!.input.covers, 73);
      expect(result.input.sourceSystem, 'oracle_micros_simphony');
      expect(
        result.provenance.coversProvenance,
        'vendor_oracle_micros_simphony',
      );
    });

    test(
      'explicit covers applicability block stops POS covers at aggregation',
      () async {
        final pool = FakePool()..seedLocation(opA, locA);
        pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
          'setting_id': 'das_001',
          'operator_id': opA,
          'location_id': locA,
          'covers_source_per_service_period':
              vendorCoversSourcePerServicePeriod,
          'covers_manual_entries': const <String, Map<String, int>>{},
          'wage_source': 'vendor',
          'created_at': DateTime.utc(2026, 5, 1),
          'updated_at': DateTime.utc(2026, 5, 4),
          'updated_by': null,
        };
        pool.vendorApplicabilityRows.add(<String, Object?>{
          'operator_id': null,
          'location_id': null,
          'setting_kind': 'covers',
          'setting_key': 'default',
          'vendor_slug': 'toast',
          'enabled': false,
          'effective_from': DateTime.utc(2026, 5, 1),
          'effective_until': null,
        });
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'toast',
            'vendor_entity_id': 'check_001',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 73,
            'covers_source': 'direct',
            'opened_at': dinnerInstantUtc,
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 1184.50,
          },
        ];
        final forecastContext = DemandForecastContext(
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
              forecastContext: forecastContext,
            );

        expect(result, isNotNull);
        expect(
          result!.input.covers,
          isNot(73),
          reason: 'blocked Toast covers must not flow into closed shifts',
        );
        expect(
          result.provenance.coversProvenance,
          'vendor_toast_covers_unavailable_app_forecast_substituted',
        );
      },
    );

    test('forward-staged keyed row (effective_at AFTER the business_date) '
        'must NOT short-circuit the vendor default — the at-or-before '
        'lookup keeps a 2026-06-01 manual switch from gating a '
        '2026-05-04 close', () async {
      final pool = FakePool()..seedLocation(opA, locA);
      pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
        'setting_id': 'das_001',
        'operator_id': opA,
        'location_id': locA,
        'covers_source_per_service_period': vendorCoversSourcePerServicePeriod,
        'covers_manual_entries': const <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      // Forward-staged keyed setting: effective from 2026-06-01.
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999999',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-06-01',
            'created_at': DateTime.utc(2026, 5, 31),
            'updated_at': DateTime.utc(2026, 5, 31),
            'updated_by': null,
          };
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 51,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 812.00,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );
      final result = await aggregator.aggregate(
        operatorId: opA,
        locationId: locA,
        restaurantId: restaurantA,
        businessDate: businessDate, // 2026-05-04
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
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
      final pool = FakePool()
        ..seedLocation(opA, locA)
        ..seedLocation(opB, locA);
      // Keyed setting only seeded for operator A.
      pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|dinner'] =
          <String, Object?>{
            'id': '99999999-9999-9999-9999-999999999999',
            'operator_id': opA,
            'location_id': locA,
            'service_period_key': 'dinner',
            'covers_source': 'manual',
            'wage_source': 'manual_mix',
            'effective_at_business_date': '2026-05-01',
            'created_at': DateTime.utc(2026, 5, 1),
            'updated_at': DateTime.utc(2026, 5, 1),
            'updated_by': null,
          };
      // Operator B has only the effective default + a vendor POS row.
      pool.dataAccuracySettingsByTenant['$opB|$locA'] = <String, Object?>{
        'setting_id': 'das_002',
        'operator_id': opB,
        'location_id': locA,
        'covers_source_per_service_period': vendorCoversSourcePerServicePeriod,
        'covers_manual_entries': const <String, Map<String, int>>{},
        'wage_source': 'vendor',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 4),
        'updated_by': null,
      };
      pool.coverFactsByOperatorLocation['$opB|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_001',
          'vendor_modified_at': dinnerInstantUtc,
          'covers': 28,
          'covers_source': 'direct',
          'opened_at': dinnerInstantUtc,
          'closed_at': dinnerInstantUtc,
          'business_date': businessDateIso,
          'actual_sales': 412.50,
        },
      ];

      final aggregator = CanonicalFactToClosedShiftInputAggregator(
        TenantTransactionWrapper(pool),
      );
      final result = await aggregator.aggregate(
        operatorId: opB,
        locationId: locA,
        restaurantId: restaurantA,
        businessDate: businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        servicePeriodId: 'dinner',
        periodDefinition: dinnerPeriod,
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
      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
        <String, Object?>{
          'vendor_id': 'oracle_micros_simphony',
          'vendor_entity_id': 'check_boundary',
          'vendor_modified_at': boundaryUtc,
          'covers': 12,
          'covers_source': 'direct',
          'opened_at': boundaryUtc.subtract(const Duration(hours: 1)),
          'closed_at': boundaryUtc,
          'business_date': businessDateIso,
          'actual_sales': 240.00,
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
        'business_date': businessDateIso,
      };

      // Lunch run — expect 4 hours and 4×20 = 80 dollars.
      {
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_lunch',
            'vendor_modified_at': DateTime.utc(2026, 5, 4, 17, 0, 0),
            'covers': 10,
            'covers_source': 'direct',
            'opened_at': DateTime.utc(2026, 5, 4, 16, 0, 0),
            'closed_at': DateTime.utc(2026, 5, 4, 17, 0, 0),
            'business_date': businessDateIso,
            'actual_sales': 200.0,
          },
        ];
        pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          punchRow,
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_dinner',
            'vendor_modified_at': DateTime.utc(2026, 5, 4, 22, 0, 0),
            'covers': 8,
            'covers_source': 'direct',
            'opened_at': DateTime.utc(2026, 5, 4, 21, 0, 0),
            'closed_at': DateTime.utc(2026, 5, 4, 22, 0, 0),
            'business_date': businessDateIso,
            'actual_sales': 160.0,
          },
        ];
        pool.laborPunchesByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          punchRow,
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|2026-05-04'] = [
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
        pool.laborPunchesByOperatorLocation['$opA|$locA|2026-05-04'] = [
          monPunchRow,
        ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|2026-05-05'] = [
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
        pool.laborPunchesByOperatorLocation['$opA|$locA|2026-05-04'] = [
          monPunchRow,
        ];
        final result =
            await CanonicalFactToClosedShiftInputAggregator(
              TenantTransactionWrapper(pool),
            ).aggregate(
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
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
        restaurantId: restaurantA,
        anchorBusinessDate: businessDateIso,
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
        final pool = FakePool()..seedLocation(opA, locA);
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$businessDateIso'] = [
          <String, Object?>{
            'vendor_id': 'oracle_micros_simphony',
            'vendor_entity_id': 'check_reliable',
            'vendor_modified_at': dinnerInstantUtc,
            'covers': 8,
            'covers_source': 'direct',
            'opened_at': dinnerInstantUtc,
            'closed_at': dinnerInstantUtc,
            'business_date': businessDateIso,
            'actual_sales': 200.0,
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
        final pool = FakePool()..seedLocation(opA, locA);
        // No cover_facts rows -> stage 4 / 5 fallback path. With
        // a forecast context absent, stage 5 returns null. Use a
        // forecast context so we hit stage 4 and the result is
        // non-null with sourceSystem='app_forecast'.
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
              periodDefinition: dinnerPeriodFull,
              forecastContext: DemandForecastContext(
                restaurantId: restaurantA,
                anchorBusinessDate: businessDateIso,
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
    // `FakePool.seedLocation` writes (timezone='America/Toronto',
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.coverFactsByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
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
      final pool = FakePool()
        ..seedLocation(
          opA,
          locA,
          businessDayStartLocalTime: '04:30:00',
          businessDayRolloverHour: 0,
        );
      pool.coverFactsByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
            operatorId: opA,
            locationId: locA,
            restaurantId: restaurantA,
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
        final pool = FakePool()..seedLocation(opA, locA);
        // Anchor the punch under business_date=Tuesday only.
        pool.laborPunchesByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
            [laborRow];
        // Wednesday cover_fact required so the aggregator returns
        // a non-null result for the Wed call.
        pool.coverFactsByOperatorLocation['$opA|$locA|2026-05-13'] = [
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
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
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
        final pool = FakePool()..seedLocation(opA, locA);
        pool.laborPunchesByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
            [laborRow];
        // Need at least one cover_fact in late_night so the
        // aggregator returns non-null (POS-supplied covers stage 2
        // is the simplest path).
        pool.coverFactsByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
              operatorId: opA,
              locationId: locA,
              restaurantId: restaurantA,
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
      final pool = FakePool()..seedLocation(opA, locA);
      // Reservation anchored to Tuesday business_date — matches
      // the canonical write path's `business_date` derivation
      // (an upstream sink resolves the reservation's business
      // date from `reservation_at` under the operator's cutoff).
      seedReservationPlusWalkinPreference(pool, 'late_night');
      pool.reservationFactsByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
            operatorId: opA,
            locationId: locA,
            restaurantId: restaurantA,
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

      final pool = FakePool()..seedLocation(opA, locA);
      pool.coverFactsByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
      pool.laborPunchesByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
      pool.reservationFactsByOperatorLocation['$opA|$locA|$tuesdayBusinessDateIso'] =
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
            operatorId: opA,
            locationId: locA,
            restaurantId: restaurantA,
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
