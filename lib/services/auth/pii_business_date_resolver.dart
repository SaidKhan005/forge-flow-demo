// CODE_OPS_DEBT carry-over follow-up #3 (2026-05-08) — IANA-tz
// resolver for PII erasure rows.
//
// `user_pii_erasure_requests.business_date` previously stored the UTC
// truncation of the request instant. The migration column drives
// partition routing only, so the impact was small, but Phase 7.55
// time guardrails ("Restaurant-local timing wins; business date is
// the anchor") require a restaurant-local IANA-tz value.
//
// This file binds the [PiiBusinessDateResolver] typedef declared in
// `user_pii_erasure_service.dart` to the same IANA-backed converter
// every Phase 8 vendor sink uses (`IanaTimezoneConverter.toBusinessDate`).
// The proxy bootstrap calls [buildPiiBusinessDateResolver] once at
// startup with the existing tenant transaction wrapper; the resulting
// closure is passed into [UserPiiErasureService] so erasure rows for an
// `America/Los_Angeles` restaurant at 04:00 UTC land on the prior
// business day.
//
// The resolver returns null on missing-location / unknown-tz so the
// service falls back to UTC truncation rather than blocking the
// erasure write. Partition routing stays correct in the degraded case
// because UTC is a known-safe key.

import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../../infrastructure/persistence/postgres/tenant_transaction.dart';
import '../integration/iana_timezone_converter.dart';
import 'user_pii_erasure_service.dart';

/// Captured `(timezone, business_day_rollover_hour)` shape for a
/// single location. Null tz means "row missing or timezone column
/// empty" — consumers fall back to UTC.
class _LocationTiming {
  const _LocationTiming({required this.timezone, required this.rolloverHour});

  final String timezone;
  final int rolloverHour;
}

/// Concrete [OperatorScopedRepository] that exposes a single
/// `(timezone, business_day_rollover_hour)` lookup. The class is
/// private to this file — the only public surface is
/// [buildPiiBusinessDateResolver], which composes the lookup with the
/// IANA-backed converter and returns the closure the service consumes.
class _LocationTimingLookupRepository extends OperatorScopedRepository {
  _LocationTimingLookupRepository(super.tenantWrapper);

  /// Returns the timing pair for `(operatorId, locationId)`. Null when
  /// the row is missing or the stored timezone is unusable. Consumers
  /// fall back to UTC.
  Future<_LocationTiming?> readTiming({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<_LocationTiming?>(ctx, (exec) async {
      final rows = await exec.query(
        'select timezone, business_day_rollover_hour '
        'from public.locations '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final tz = row['timezone'];
      if (tz is! String || tz.isEmpty) return null;
      final rollover = row['business_day_rollover_hour'];
      final rolloverHour = rollover is int
          ? rollover
          : (rollover is num ? rollover.toInt() : 0);
      return _LocationTiming(timezone: tz, rolloverHour: rolloverHour);
    });
  }
}

/// Builds the [PiiBusinessDateResolver] the proxy injects into
/// [UserPiiErasureService]. The returned closure is safe to call
/// concurrently — both the wrapper and the converter are stateless.
///
/// [actorUserIdResolver] returns the actor user id to bind on the
/// tenant context. The proxy passes a closure that yields the request
/// `scope.userId`; tests can substitute a constant.
PiiBusinessDateResolver buildPiiBusinessDateResolver({
  required TenantTransactionWrapper tenantWrapper,
  required String Function() actorUserIdResolver,
  IanaTimezoneConverter? converter,
}) {
  final repo = _LocationTimingLookupRepository(tenantWrapper);
  final tzConverter = converter ?? IanaTimezoneConverter.shared;
  return ({
    required String operatorId,
    required String locationId,
    required DateTime requestedAt,
  }) async {
    final timing = await repo.readTiming(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserIdResolver(),
    );
    if (timing == null) return null;
    if (!tzConverter.isKnownTimezone(timing.timezone)) return null;
    final localDate = tzConverter.toBusinessDate(
      restaurantTimezone: timing.timezone,
      businessDayRolloverHour: timing.rolloverHour,
      instant: requestedAt.toUtc(),
    );
    return '${localDate.year.toString().padLeft(4, '0')}-'
        '${localDate.month.toString().padLeft(2, '0')}-'
        '${localDate.day.toString().padLeft(2, '0')}';
  };
}
