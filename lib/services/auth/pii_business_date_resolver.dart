// CODE_OPS_DEBT carry-over follow-up #3 (2026-05-08) - canonical
// resolver for PII erasure rows.
//
// `user_pii_erasure_requests.business_date` is resolved through the
// same business-timing profile chain used by vendor sinks:
// operator -> org_unit -> location timezone, then effective
// business_day_start_local_time. The resolver returns null on
// missing-location / unknown-timezone so the service falls back to UTC
// truncation rather than blocking the erasure write.

import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../../infrastructure/persistence/postgres/tenant_transaction.dart';
import '../integration/iana_timezone_converter.dart';
import '../integration/sink_business_date_projector.dart';
import 'user_pii_erasure_service.dart';

/// Builds the [PiiBusinessDateResolver] the proxy injects into
/// [UserPiiErasureService]. The returned closure is safe to call
/// concurrently.
///
/// [actorUserIdResolver] returns the actor user id to bind on the
/// tenant context. The proxy passes a closure that yields the request
/// `scope.userId`; tests can substitute a constant.
PiiBusinessDateResolver buildPiiBusinessDateResolver({
  required TenantTransactionWrapper tenantWrapper,
  required String Function() actorUserIdResolver,
  IanaTimezoneConverter? converter,
}) {
  final tzConverter = converter ?? IanaTimezoneConverter.shared;
  return ({
    required String operatorId,
    required String locationId,
    required DateTime requestedAt,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserIdResolver(),
    );
    final businessDate = await tenantWrapper.runInTenantContext<DateTime?>(ctx, (
      exec,
    ) {
      return SinkBusinessDateProjector.projectBusinessDateForLocationInTransaction(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        instantUtc: requestedAt,
        timezoneConverter: tzConverter,
      );
    });
    if (businessDate == null) return null;
    return _formatDate(businessDate);
  };
}

String _formatDate(DateTime value) {
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}
