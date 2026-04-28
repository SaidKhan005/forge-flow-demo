// Phase 9.2 - Tenant context value object.
//
// Every operator-scoped Postgres operation flows through
// [TenantTransactionWrapper.runInTenantContext], which requires a
// [TenantContext] and immediately injects its values via `SET LOCAL`
// (transaction-scoped) so RLS policies can read them through
// `current_setting('app.operator_id', true)::uuid`.
//
// This file is intentionally I/O free and has no `package:postgres`
// import: it only describes what tenant context looks like. The
// concrete SQL execution lives in `tenant_transaction.dart` via the
// `PostgresExecutor` seam.

/// Per-request tenant context resolved from the verified JWT (Phase 9.1)
/// + Postgres user lookup (Phase 9.2 forward).
///
/// Required fields are non-optional because the repository pattern
/// refuses to run any tenant-scoped SQL without them. The optional
/// [userId] is for actor attribution on writes; some background jobs
/// (e.g., scheduled dormancy sweeps) operate without a human actor
/// and pass null.
class TenantContext {
  TenantContext({
    required this.operatorId,
    required this.locationId,
    this.userId,
  }) {
    if (!_uuidPattern.hasMatch(operatorId)) {
      throw TenantContextValidationError(
        'operator_id is not a valid UUID',
        field: 'operator_id',
      );
    }
    if (!_uuidPattern.hasMatch(locationId)) {
      throw TenantContextValidationError(
        'location_id is not a valid UUID',
        field: 'location_id',
      );
    }
    final uid = userId;
    if (uid != null && !_uuidPattern.hasMatch(uid)) {
      throw TenantContextValidationError(
        'user_id is not a valid UUID',
        field: 'user_id',
      );
    }
  }

  final String operatorId;
  final String locationId;
  final String? userId;

  // Strict 8-4-4-4-12 lowercase UUID format. Validated at construction
  // time so a malformed value cannot slip into the SET LOCAL payload
  // even if the SQL executor uses parameter binding (defense in depth:
  // any `current_setting('app.operator_id', true)::uuid` call would
  // also throw in Postgres on a bad value, but failing earlier in
  // Dart prevents the whole transaction round-trip).
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

/// Thrown by [TenantContext] construction when one of the UUID fields
/// fails strict validation. The exception names which field failed
/// without echoing the offending value (the value may carry secrets in
/// pathological misuse — e.g. a header-injection attempt).
class TenantContextValidationError implements Exception {
  TenantContextValidationError(this.message, {required this.field});

  final String message;
  final String field;

  @override
  String toString() => 'TenantContextValidationError($field): $message';
}
