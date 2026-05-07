// Phase 9.UX.1 - delayed MFA factor removal request repository.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class MfaFactorRemovalRequestRecord {
  const MfaFactorRemovalRequestRecord({
    required this.requestId,
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.factorId,
    required this.requestedByUserId,
    required this.stepUpProofId,
    required this.requestedAt,
    required this.executeAfter,
    this.completedAt,
    this.cancelledAt,
    this.processingStartedAt,
    this.processingOwner,
    this.lastError,
    this.attemptCount = 0,
    this.deadLetteredAt,
  });

  final String requestId;
  final String operatorId;
  final String locationId;
  final String userId;
  final String factorId;
  final String requestedByUserId;
  final String stepUpProofId;
  final DateTime requestedAt;
  final DateTime executeAfter;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final DateTime? processingStartedAt;
  final String? processingOwner;
  final String? lastError;

  /// Per-row retry counter. Schema CHECK caps at 100; the L7 worker
  /// enforces the tighter app-level cap (default 10) before calling
  /// [MfaFactorRemovalRequestsRepository.markDeadLettered].
  final int attemptCount;

  /// DLQ sentinel. Non-null once the worker has decided this row
  /// exceeded its retry budget. Dead-lettered rows are excluded from
  /// the partial indexes that drive `claimDuePending` /
  /// `listDuePendingForUser`, so they stop being retried automatically.
  final DateTime? deadLetteredAt;

  bool get isPending =>
      completedAt == null && cancelledAt == null && deadLetteredAt == null;
  bool get isCompleted => completedAt != null;
  bool get isDeadLettered => deadLetteredAt != null;
}

class MfaFactorRemovalRequestsRepository extends OperatorScopedRepository {
  MfaFactorRemovalRequestsRepository(super.tenantWrapper);

  Future<MfaFactorRemovalRequestRecord> insertPending({
    required String operatorId,
    required String locationId,
    required String userId,
    required String factorId,
    required String requestedByUserId,
    required String stepUpProofId,
    required String requestId,
    required DateTime requestedAt,
    required DateTime executeAfter,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<MfaFactorRemovalRequestRecord>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into mfa_factor_removal_requests ('
        'request_id, operator_id, location_id, user_id, factor_id, '
        'requested_by_user_id, step_up_proof_id, requested_at, execute_after'
        ') values ('
        '@request_id::uuid, @operator_id::uuid, @location_id::uuid, '
        '@user_id::uuid, @factor_id::uuid, @requested_by_user_id::uuid, '
        '@step_up_proof_id, @requested_at::timestamptz, '
        '@execute_after::timestamptz'
        ') on conflict (operator_id, user_id, factor_id) '
        'where completed_at is null and cancelled_at is null '
        'do update set updated_at = mfa_factor_removal_requests.updated_at '
        'returning request_id::text as request_id, '
        'operator_id::text as operator_id, location_id::text as location_id, '
        'user_id::text as user_id, factor_id::text as factor_id, '
        'requested_by_user_id::text as requested_by_user_id, '
        'step_up_proof_id, requested_at, execute_after, completed_at, '
        'cancelled_at, processing_started_at, processing_owner, last_error, '
        'attempt_count, dead_lettered_at',
        parameters: <String, Object?>{
          'request_id': requestId,
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'factor_id': factorId,
          'requested_by_user_id': requestedByUserId,
          'step_up_proof_id': stepUpProofId,
          'requested_at': requestedAt.toUtc().toIso8601String(),
          'execute_after': executeAfter.toUtc().toIso8601String(),
        },
      );
      return _projectSingle(rows, 'insert');
    });
  }

  Future<List<MfaFactorRemovalRequestRecord>> listRecentForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    int limit = 20,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<MfaFactorRemovalRequestRecord>>(ctx, (exec) async {
      final rows = await exec.query(
        'select request_id::text as request_id, '
        'operator_id::text as operator_id, location_id::text as location_id, '
        'user_id::text as user_id, factor_id::text as factor_id, '
        'requested_by_user_id::text as requested_by_user_id, '
        'step_up_proof_id, requested_at, execute_after, completed_at, '
        'cancelled_at, processing_started_at, processing_owner, last_error, '
        'attempt_count, dead_lettered_at '
        'from mfa_factor_removal_requests '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and user_id = @user_id::uuid '
        'order by requested_at desc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'limit': limit,
        },
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  Future<List<MfaFactorRemovalRequestRecord>> listDuePendingForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required DateTime now,
    int limit = 10,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<MfaFactorRemovalRequestRecord>>(ctx, (exec) async {
      final rows = await exec.query(
        'select request_id::text as request_id, '
        'operator_id::text as operator_id, location_id::text as location_id, '
        'user_id::text as user_id, factor_id::text as factor_id, '
        'requested_by_user_id::text as requested_by_user_id, '
        'step_up_proof_id, requested_at, execute_after, completed_at, '
        'cancelled_at, processing_started_at, processing_owner, last_error, '
        'attempt_count, dead_lettered_at '
        'from mfa_factor_removal_requests '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and user_id = @user_id::uuid '
        'and completed_at is null '
        'and cancelled_at is null '
        'and dead_lettered_at is null '
        'and execute_after <= @now::timestamptz '
        'order by execute_after, requested_at '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'now': now.toUtc().toIso8601String(),
          'limit': limit,
        },
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  Future<List<MfaFactorRemovalRequestRecord>> claimDuePending({
    required DateTime now,
    required String workerOwner,
    int limit = 50,
    Duration staleAfter = const Duration(minutes: 15),
  }) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    final trimmedOwner = workerOwner.trim();
    if (trimmedOwner.isEmpty) {
      throw ArgumentError.value(
        workerOwner,
        'workerOwner',
        'must be non-blank',
      );
    }
    return withSystem<List<MfaFactorRemovalRequestRecord>>((exec) async {
      final rows = await exec.query(
        'with due as ('
        '  select request_id '
        '  from mfa_factor_removal_requests '
        '  where completed_at is null '
        '  and cancelled_at is null '
        '  and dead_lettered_at is null '
        '  and execute_after <= @now::timestamptz '
        '  and (processing_started_at is null '
        '       or processing_started_at < '
        "          @now::timestamptz - (@stale_seconds * interval '1 second')) "
        '  order by execute_after, request_id '
        '  for update skip locked '
        '  limit @limit'
        '), claimed as ('
        '  update mfa_factor_removal_requests r '
        '  set processing_started_at = @now::timestamptz, '
        '      processing_owner = @worker_owner, '
        '      updated_at = now() '
        '  from due '
        '  where r.request_id = due.request_id '
        '  returning r.request_id::text as request_id, '
        '    r.operator_id::text as operator_id, '
        '    r.location_id::text as location_id, '
        '    r.user_id::text as user_id, '
        '    r.factor_id::text as factor_id, '
        '    r.requested_by_user_id::text as requested_by_user_id, '
        '    r.step_up_proof_id, r.requested_at, r.execute_after, '
        '    r.completed_at, r.cancelled_at, r.processing_started_at, '
        '    r.processing_owner, r.last_error, '
        '    r.attempt_count, r.dead_lettered_at'
        ') '
        'select * from claimed order by execute_after, request_id',
        parameters: <String, Object?>{
          'now': now.toUtc().toIso8601String(),
          'stale_seconds': staleAfter.inSeconds,
          'worker_owner': trimmedOwner,
          'limit': limit,
        },
      );
      return rows.map(_projectRow).toList(growable: false);
    }, reason: 'system.mfa_factor_removal_worker_claim');
  }

  Future<int> markCompleted({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime completedAt,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update mfa_factor_removal_requests '
        'set completed_at = @completed_at::timestamptz, '
        'last_error = null, processing_started_at = null, '
        'processing_owner = null, updated_at = now() '
        'where request_id = @request_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and user_id = @user_id::uuid '
        'and completed_at is null '
        'and cancelled_at is null',
        parameters: <String, Object?>{
          'request_id': requestId,
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'completed_at': completedAt.toUtc().toIso8601String(),
        },
      );
    });
  }

  Future<int> markCancelled({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime cancelledAt,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update mfa_factor_removal_requests '
        'set cancelled_at = @cancelled_at::timestamptz, '
        'last_error = null, processing_started_at = null, '
        'processing_owner = null, updated_at = now() '
        'where request_id = @request_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and user_id = @user_id::uuid '
        'and completed_at is null '
        'and cancelled_at is null',
        parameters: <String, Object?>{
          'request_id': requestId,
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'cancelled_at': cancelledAt.toUtc().toIso8601String(),
        },
      );
    });
  }

  Future<int> markFailed({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required String error,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update mfa_factor_removal_requests '
        'set last_error = @last_error, '
        'processing_started_at = null, processing_owner = null, '
        'updated_at = now() '
        'where request_id = @request_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and user_id = @user_id::uuid '
        'and completed_at is null '
        'and cancelled_at is null',
        parameters: <String, Object?>{
          'request_id': requestId,
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'last_error': error,
        },
      );
    });
  }

  /// Bumps the row's `attempt_count` by one and returns the new value.
  ///
  /// Intentionally separate from [markFailed] so the L7 worker can
  /// compose `incrementAttemptCount` with its own success/failure
  /// write atomically inside one tenant transaction. This method does
  /// not enforce the retry cap — that's app-level policy. The schema
  /// CHECK (attempt_count <= 100) is the defensive backstop.
  ///
  /// Returns the post-increment count. Throws [StateError] if the row
  /// is missing or has been dead-lettered (so the caller is forced to
  /// notice that the row left the active set).
  Future<int> incrementAttemptCount({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      final rows = await exec.query(
        'update mfa_factor_removal_requests '
        'set attempt_count = attempt_count + 1, '
        'updated_at = now() '
        'where request_id = @request_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and user_id = @user_id::uuid '
        'and completed_at is null '
        'and cancelled_at is null '
        'and dead_lettered_at is null '
        'returning attempt_count',
        parameters: <String, Object?>{
          'request_id': requestId,
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'mfa_factor_removal_requests increment_attempt_count returned no rows '
          '(row missing, dead-lettered, or already terminal)',
        );
      }
      return _int(rows.single['attempt_count']);
    });
  }

  /// Stamps `dead_lettered_at = now()`, captures the [reason] in
  /// `last_error`, and clears the worker-claim fields so a confused
  /// worker cannot keep re-claiming the row. The pending-only partial
  /// indexes also exclude `dead_lettered_at IS NOT NULL`, so once this
  /// runs the row drops out of `claimDuePending` /
  /// `listDuePendingForUser` results.
  ///
  /// Returns the number of rows updated (0 if the row is already
  /// terminal — this method is idempotent).
  Future<int> markDeadLettered({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required String reason,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update mfa_factor_removal_requests '
        'set dead_lettered_at = now(), '
        'last_error = @last_error, '
        'processing_started_at = null, '
        'processing_owner = null, '
        'updated_at = now() '
        'where request_id = @request_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and user_id = @user_id::uuid '
        'and completed_at is null '
        'and cancelled_at is null '
        'and dead_lettered_at is null',
        parameters: <String, Object?>{
          'request_id': requestId,
          'operator_id': operatorId,
          'location_id': locationId,
          'user_id': userId,
          'last_error': reason,
        },
      );
    });
  }

  static MfaFactorRemovalRequestRecord _projectSingle(
    List<Map<String, Object?>> rows,
    String operation,
  ) {
    if (rows.isEmpty) {
      throw StateError(
        'mfa_factor_removal_requests $operation returned no rows',
      );
    }
    return _projectRow(rows.single);
  }

  static MfaFactorRemovalRequestRecord _projectRow(Map<String, Object?> row) {
    return MfaFactorRemovalRequestRecord(
      requestId: row['request_id'] as String,
      operatorId: row['operator_id'] as String,
      locationId: row['location_id'] as String,
      userId: row['user_id'] as String,
      factorId: row['factor_id'] as String,
      requestedByUserId: row['requested_by_user_id'] as String,
      stepUpProofId: row['step_up_proof_id'] as String,
      requestedAt: _date(row['requested_at'], 'requested_at'),
      executeAfter: _date(row['execute_after'], 'execute_after'),
      completedAt: _nullableDate(row['completed_at']),
      cancelledAt: _nullableDate(row['cancelled_at']),
      processingStartedAt: _nullableDate(row['processing_started_at']),
      processingOwner: row['processing_owner'] as String?,
      lastError: row['last_error'] as String?,
      attemptCount: _int(row['attempt_count']),
      deadLetteredAt: _nullableDate(row['dead_lettered_at']),
    );
  }

  static DateTime _date(Object? value, String field) {
    final parsed = _nullableDate(value);
    if (parsed == null) {
      throw StateError('mfa removal request row missing $field');
    }
    return parsed;
  }

  static DateTime? _nullableDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    throw StateError('unsupported timestamp value ${value.runtimeType}');
  }

  /// Projects an integer column. The schema declares `attempt_count`
  /// `NOT NULL DEFAULT 0`, but older rows projected from a JOIN or a
  /// fixture that omits the column should default to 0 rather than
  /// throw.
  static int _int(Object? value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.parse(value);
    throw StateError('unsupported integer value ${value.runtimeType}');
  }
}
