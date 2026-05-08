// CODE_OPS_DEBT carry-over follow-up #3 (2026-05-08) — unit tests for
// the IANA-tz business-date resolver injected into
// [UserPiiErasureService].
//
// Coverage focus:
//
//   * The resolver reads `(timezone, business_day_rollover_hour)` for
//     `(operatorId, locationId)` and projects the request instant
//     through the shared [IanaTimezoneConverter]. A 04:00 UTC
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

  group(
    'buildPiiBusinessDateResolver — restaurant-local IANA-tz '
    'business_date for PII erasure rows',
    () {
      test(
        'America/Los_Angeles location at 2026-05-08 04:00 UTC → '
        'business_date is 2026-05-07 (prior PT day)',
        () async {
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
          // 04:00 UTC = 21:00 PDT on 2026-05-07. Rollover 0 → that
          // wall-clock instant belongs to 2026-05-07.
          expect(value, equals('2026-05-07'));
        },
      );

      test(
        'America/Los_Angeles location at 2026-05-08 12:00 UTC → '
        'business_date is 2026-05-08 (same PT day)',
        () async {
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
          // 12:00 UTC = 05:00 PDT on 2026-05-08. Rollover 0 → that
          // wall-clock belongs to 2026-05-08.
          expect(value, equals('2026-05-08'));
        },
      );

      test(
        'rollover hour 4 — 02:00 PT (09:00 UTC) on 2026-05-08 still '
        'belongs to 2026-05-07 because it is before the cutoff',
        () async {
          final pool = _LocationsPool(
            timezone: 'America/Los_Angeles',
            rolloverHour: 4,
          );
          final resolver = buildPiiBusinessDateResolver(
            tenantWrapper: TenantTransactionWrapper(pool),
            actorUserIdResolver: () => _adminA,
          );
          // 09:00 UTC = 02:00 PDT on 2026-05-08. Rollover 4 → before
          // the cutoff → belongs to the prior day 2026-05-07.
          final value = await resolver(
            operatorId: _opA,
            locationId: _locA,
            requestedAt: DateTime.utc(2026, 5, 8, 9),
          );
          expect(value, equals('2026-05-07'));
        },
      );

      test('missing location row → returns null (service falls back)',
          () async {
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

      test(
        'unknown / non-IANA timezone string → returns null (service '
        'falls back)',
        () async {
          final pool = _LocationsPool(
            timezone: 'Mars/Olympus',
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
          expect(value, isNull);
        },
      );

      test(
        'America/Toronto location at 2026-05-08 03:30 UTC → '
        'business_date is 2026-05-07 (prior ET day)',
        () async {
          final pool = _LocationsPool(
            timezone: 'America/Toronto',
            rolloverHour: 0,
          );
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
        },
      );
    },
  );
}

class _LocationsPool implements PostgresPool {
  _LocationsPool({
    required this.timezone,
    required this.rolloverHour,
    this.locationFound = true,
  });

  final String? timezone;
  final int rolloverHour;
  final bool locationFound;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _LocationsTransaction(
      timezone: timezone,
      rolloverHour: rolloverHour,
      locationFound: locationFound,
    );
  }
}

class _LocationsTransaction extends PostgresTransaction {
  _LocationsTransaction({
    required this.timezone,
    required this.rolloverHour,
    required this.locationFound,
  });

  final String? timezone;
  final int rolloverHour;
  final bool locationFound;

  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    if (sql.contains('select timezone, business_day_rollover_hour') &&
        sql.contains('from public.locations')) {
      if (!locationFound) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'timezone': timezone,
          'business_day_rollover_hour': rolloverHour,
        },
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
