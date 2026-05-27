// CODE_OPS_DEBT carry-over follow-up #3 (2026-05-08) — unit tests for
// the IANA-tz business-date resolver injected into
// [UserPiiErasureService].
//
// Coverage focus:
//
//   * The resolver reads the canonical business-timing profile chain for
//     `(operatorId, locationId)` and projects the request instant
//     through the shared timing resolver. A 04:00 UTC
//     erasure for an `America/Los_Angeles` restaurant lands on the
//     prior PT business day (2026-05-07), not the UTC day
//     (2026-05-08). This is the core acceptance check from the
//     carry-over.
//
//   * Missing-row / unknown-tz returns null so the service falls
//     back to UTC truncation — the resolver intentionally does not
//     throw because partition routing is the only consumer of the
//     denormalized column.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/pii_business_date_resolver.dart';
import 'package:timezone/data/latest.dart' as tzdata;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _adminA = '44444444-4444-4444-4444-444444444444';

void main() {
  setUpAll(() {
    // Same posture as `test/integration/iana_scenarios_test.dart` —
    // the IANA converter's lazy init usually handles this, but eager
    // initialisation matches the project's convention for tz tests.
    tzdata.initializeTimeZones();
  });

  group('buildPiiBusinessDateResolver — restaurant-local IANA-tz '
      'business_date for PII erasure rows', () {
    test('America/Los_Angeles location at 2026-05-08 04:00 UTC → '
        'business_date is 2026-05-07 (prior PT day)', () async {
      final pool = _LocationsPool(
        timezone: 'America/Los_Angeles',
        rolloverHour: 0,
      );
      final resolver = buildPiiBusinessDateResolver(
        tenantWrapper: TenantTransactionWrapper(pool),
        actorUserIdResolver: () => _adminA,
      );
      final value = await resolver(
        operatorId: _opA,
        locationId: _locA,
        requestedAt: DateTime.utc(2026, 5, 8, 4),
      );
      // 04:00 UTC = 21:00 PDT on 2026-05-07. A 00:00 profile cutoff
      // leaves that wall-clock instant on 2026-05-07.
      expect(value, equals('2026-05-07'));
    });

    test('America/Los_Angeles location at 2026-05-08 12:00 UTC → '
        'business_date is 2026-05-08 (same PT day)', () async {
      final pool = _LocationsPool(
        timezone: 'America/Los_Angeles',
        rolloverHour: 0,
      );
      final resolver = buildPiiBusinessDateResolver(
        tenantWrapper: TenantTransactionWrapper(pool),
        actorUserIdResolver: () => _adminA,
      );
      final value = await resolver(
        operatorId: _opA,
        locationId: _locA,
        requestedAt: DateTime.utc(2026, 5, 8, 12),
      );
      // 12:00 UTC = 05:00 PDT on 2026-05-08. A 00:00 profile cutoff
      // leaves that wall-clock instant on 2026-05-08.
      expect(value, equals('2026-05-08'));
    });

    test('business-day start 04:30, 04:00 PT on 2026-05-08 still '
        'belongs to 2026-05-07 because it is before the cutoff', () async {
      final pool = _LocationsPool(
        timezone: 'America/Los_Angeles',
        rolloverHour: 0,
        businessDayStartLocalTime: '04:30',
      );
      final resolver = buildPiiBusinessDateResolver(
        tenantWrapper: TenantTransactionWrapper(pool),
        actorUserIdResolver: () => _adminA,
      );
      // 11:00 UTC = 04:00 PDT on 2026-05-08. The profile's 04:30
      // cutoff keeps the instant on the prior business day.
      final value = await resolver(
        operatorId: _opA,
        locationId: _locA,
        requestedAt: DateTime.utc(2026, 5, 8, 11),
      );
      expect(value, equals('2026-05-07'));
    });

    test('missing location row → returns null (service falls back)', () async {
      final pool = _LocationsPool(
        timezone: null,
        rolloverHour: 0,
        locationFound: false,
      );
      final resolver = buildPiiBusinessDateResolver(
        tenantWrapper: TenantTransactionWrapper(pool),
        actorUserIdResolver: () => _adminA,
      );
      final value = await resolver(
        operatorId: _opA,
        locationId: _locA,
        requestedAt: DateTime.utc(2026, 5, 8, 4),
      );
      expect(value, isNull);
    });

    test('unknown / non-IANA timezone string → returns null (service '
        'falls back)', () async {
      final pool = _LocationsPool(timezone: 'Mars/Olympus', rolloverHour: 0);
      final resolver = buildPiiBusinessDateResolver(
        tenantWrapper: TenantTransactionWrapper(pool),
        actorUserIdResolver: () => _adminA,
      );
      final value = await resolver(
        operatorId: _opA,
        locationId: _locA,
        requestedAt: DateTime.utc(2026, 5, 8, 4),
      );
      expect(value, isNull);
    });

    test('America/Toronto location at 2026-05-08 03:30 UTC → '
        'business_date is 2026-05-07 (prior ET day)', () async {
      final pool = _LocationsPool(timezone: 'America/Toronto', rolloverHour: 0);
      final resolver = buildPiiBusinessDateResolver(
        tenantWrapper: TenantTransactionWrapper(pool),
        actorUserIdResolver: () => _adminA,
      );
      // 03:30 UTC = 23:30 EDT on 2026-05-07.
      final value = await resolver(
        operatorId: _opA,
        locationId: _locA,
        requestedAt: DateTime.utc(2026, 5, 8, 3, 30),
      );
      expect(value, equals('2026-05-07'));
    });
  });
}

class _LocationsPool implements PostgresPool {
  _LocationsPool({
    required this.timezone,
    required this.rolloverHour,
    this.businessDayStartLocalTime,
    this.locationFound = true,
  });

  final String? timezone;
  final int rolloverHour;
  final String? businessDayStartLocalTime;
  final bool locationFound;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _LocationsTransaction(
      timezone: timezone,
      rolloverHour: rolloverHour,
      businessDayStartLocalTime: businessDayStartLocalTime,
      locationFound: locationFound,
    );
  }
}

class _LocationsTransaction extends PostgresTransaction {
  _LocationsTransaction({
    required this.timezone,
    required this.rolloverHour,
    required this.businessDayStartLocalTime,
    required this.locationFound,
  });

  final String? timezone;
  final int rolloverHour;
  final String? businessDayStartLocalTime;
  final bool locationFound;

  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    if (sql.contains('from public.business_timing_profiles p')) {
      if (!locationFound || timezone == null) return const <PostgresRow>[];
      final start =
          businessDayStartLocalTime ??
          '${rolloverHour.toString().padLeft(2, '0')}:00';
      return <PostgresRow>[
        <String, Object?>{
          'profile_id': 'profile-1',
          'operator_id': _opA,
          'scope_type': 'operator',
          'scope_id': _opA,
          'display_name': 'Default',
          'business_day_start_local_time': start,
          'week_start_day': 1,
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
          'service_periods': const <Map<String, Object?>>[
            <String, Object?>{
              'service_period_id': 'service-period-1',
              'operator_id': _opA,
              'profile_id': 'profile-1',
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
    if (sql.contains('location_timezone') &&
        sql.contains('from public.locations loc')) {
      if (!locationFound) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'location_timezone': timezone},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
