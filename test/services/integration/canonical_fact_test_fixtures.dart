// Phase 8 spine-bridge — shared aggregator test fixtures.
//
// Bucket 5a of the 2026-05-20 test-suite tightening audit: split out of
// `canonical_fact_to_closed_shift_input_test.dart` (3,981 lines) so the
// constants, `FakePool`, and `FakeTransaction` are reused by the three
// focused test files (canonical_fact_covers_and_pos_aggregation_test.dart,
// canonical_fact_wage_and_labor_sources_test.dart, and
// canonical_fact_rls_and_regression_checks_test.dart) without
// duplicating ~450 lines of fakes. Symbols were made library-public
// (leading `_` dropped) so the helpers cross the file boundary; fixture
// values and `FakePool`/`FakeTransaction` behaviour are byte-identical
// to the pre-split source.

import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

const String opA = '11111111-1111-4111-8111-111111111111';
const String opB = '22222222-2222-4222-8222-222222222222';
const String locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String restaurantA = 'demo_restaurant_001';
const String timingProfileA = '33333333-3333-4333-8333-333333333333';
const String timingProfileB = '44444444-4444-4444-8444-444444444444';

const Map<String, Object?> vendorCoversSourcePerServicePeriod =
    <String, Object?>{
      'lunch': 'vendor',
      'dinner': 'vendor',
      'late_night': 'vendor',
    };

const Map<String, Object?> manualDinnerCoversSourcePerServicePeriod =
    <String, Object?>{
      'lunch': 'vendor',
      'dinner': 'manual',
      'late_night': 'vendor',
    };

final DateTime businessDate = DateTime.utc(2026, 5, 4);

const ServicePeriodDefinition lunchPeriod = ServicePeriodDefinition(
  id: 'lunch',
  label: 'Lunch',
  shortLabel: 'L',
  sortOrder: 1,
  startLocalTime: '11:00',
  endLocalTime: '16:00',
  rollsPastMidnight: false,
  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
);

// Period definition for "dinner" in America/Toronto (17:00–22:00 local).
const ServicePeriodDefinition dinnerPeriod = ServicePeriodDefinition(
  id: 'dinner',
  label: 'Dinner',
  shortLabel: 'D',
  sortOrder: 2,
  startLocalTime: '17:00',
  endLocalTime: '22:00',
  rollsPastMidnight: false,
  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
);

const ServicePeriodDefinition lateNightPeriod = ServicePeriodDefinition(
  id: 'late_night',
  label: 'Late Night',
  shortLabel: 'LN',
  sortOrder: 3,
  startLocalTime: '22:00',
  endLocalTime: '02:00',
  rollsPastMidnight: true,
  applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
);

const List<ServicePeriodDefinition> standardPeriods = <ServicePeriodDefinition>[
  lunchPeriod,
  dinnerPeriod,
  lateNightPeriod,
];

// 22:00 UTC = 18:00 EDT (America/Toronto, May 2026) → buckets to
// dinner. Used by all three canonical fact tables.
final DateTime dinnerInstantUtc = DateTime.utc(2026, 5, 4, 22, 0, 0);

void seedReservationPlusWalkinPreference(
  FakePool pool,
  String servicePeriodId,
) {
  pool.dataAccuracySettingsByTenant['$opA|$locA'] = <String, Object?>{
    'setting_id': 'das_reservation_plus_walkin_$servicePeriodId',
    'operator_id': opA,
    'location_id': locA,
    'covers_manual_entries': <String, Map<String, int>>{},
    'wage_source': 'vendor',
    'walk_in_handling_mode': 'walk_ins_added_to_reservations',
    'walk_in_manual_entries': <String, Object?>{},
    'created_at': DateTime.utc(2026, 5, 1),
    'updated_at': DateTime.utc(2026, 5, 4),
    'updated_by': null,
  };
  pool.dataAccuracyServicePeriodSettingsByTenant['$opA|$locA|$servicePeriodId'] =
      <String, Object?>{
        'id': 'das_rspw_$servicePeriodId',
        'operator_id': opA,
        'location_id': locA,
        'service_period_key': servicePeriodId,
        'covers_source': 'reservation_plus_walkin',
        'wage_source': 'vendor_per_employee',
        'effective_at_business_date': '2026-05-01',
        'created_at': DateTime.utc(2026, 5, 1),
        'updated_at': DateTime.utc(2026, 5, 1),
        'updated_by': null,
      };
}

// ─── Helpers + fakes ──────────────────────────────────────────────────

String get businessDateIso =>
    '${businessDate.year.toString().padLeft(4, '0')}'
    '-${businessDate.month.toString().padLeft(2, '0')}'
    '-${businessDate.day.toString().padLeft(2, '0')}';

DateTime _dateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.parse(value);
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

class FakePool implements PostgresPool {
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
  final List<Map<String, Object?>> vendorApplicabilityRows =
      <Map<String, Object?>>[];

  /// Keyed by `(operator_id, location_id, business_date_iso, daypart)`.
  /// Pre-seed when a test wants to exercise priorTargetProfileVersionId.
  final Map<String, String> shiftRecordTpvBySlot = <String, String>{};

  /// Keyed by `(operator_id, location_id, business_date_iso, daypart)`.
  /// Pre-seed when a test wants prior timing provenance as well.
  final Map<String, Map<String, Object?>> shiftRecordProvenanceBySlot =
      <String, Map<String, Object?>>{};

  final List<FakeTransaction> transactions = <FakeTransaction>[];

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
    final tx = FakeTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class FakeTransaction implements PostgresTransaction {
  FakeTransaction(this.pool);

  final FakePool pool;
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
    if (sql.contains('from public.vendor_applicability')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final settingKind = parameters['setting_kind'] as String;
      final winners = <String, Map<String, Object?>>{};
      for (final row in pool.vendorApplicabilityRows) {
        if (row['setting_kind'] != settingKind) continue;
        if (row['effective_until'] != null) continue;
        final rowOperatorId = row['operator_id'];
        final rowLocationId = row['location_id'];
        final rank = rowOperatorId == null
            ? 0
            : rowOperatorId == operatorId && rowLocationId == null
            ? 1
            : rowOperatorId == operatorId && rowLocationId == locationId
            ? 2
            : -1;
        if (rank < 0) continue;
        final settingKey = row['setting_key'];
        final vendorSlug = row['vendor_slug'];
        if (settingKey is! String || vendorSlug is! String) continue;
        final key = '$settingKey|$vendorSlug';
        final existing = winners[key];
        if (existing == null ||
            rank > (existing['_rank'] as int? ?? -1) ||
            (rank == (existing['_rank'] as int? ?? -1) &&
                _dateTime(
                  row['effective_from'],
                ).isAfter(_dateTime(existing['effective_from'])))) {
          winners[key] = <String, Object?>{...row, '_rank': rank};
        }
      }
      return winners.values
          .map(
            (row) => <String, Object?>{
              'vendor_slug': row['vendor_slug'],
              'enabled': row['enabled'],
            },
          )
          .toList(growable: false);
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
            effectiveAt.compareTo(FakePool._effectiveSettingsViewAsOfDate) >
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
      // keyed sub-SELECT would. The model no longer consults the old
      // lunch/dinner/late-night scalar columns.
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
