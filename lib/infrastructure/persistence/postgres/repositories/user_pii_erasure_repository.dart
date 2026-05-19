// CODE_OPS_DEBT Theme B#1 - user_pii_erasure_requests repository.
//
// Operator-scoped repository for the durable PII erasure request
// ledger created by `db/migrations/202605082000_user_pii_erasure_requests.sql`.
//
// The repository is the single seam between three call sites:
//
//   1. The proxy POST `.../erase-pii` route — captures a snapshot of
//      the target user's PII, then calls [insertPending] inside a
//      tenant transaction so the row commits with the audit-log row.
//   2. The proxy POST `.../erase-pii/reverse` route — calls
//      [markReversed] + the read of `pii_snapshot` so the route can
//      restore the previously-captured PII before the worker applies
//      the NULL-out.
//   3. The grace-window apply worker — calls [listDuePending] +
//      [applyDueRow] under `withSystem` (cross-operator scan) and
//      runs the actual NULL-out of `public.users` PII columns inside
//      one tenant transaction per row.
//
// Hard rules carried from the migration:
//
//   * `pii_snapshot` is `JSONB NOT NULL`. The row stores a captured
//     snapshot of `(display_name, email, first_name, last_name,
//     avatar_url)` so [markReversed] can restore them. Once the
//     worker applies the NULL-out, the snapshot is overwritten with
//     `'{}'::jsonb` so PII does not linger past the grace window.
//   * Per-row uniqueness is `(operator_id, user_id)` partial on
//     pending rows (`applied_at is null and reversed_at is null`).
//     A second `insertPending` while a prior row is still in the
//     active window raises a UNIQUE violation, which the proxy
//     translates to 409 `pii_erasure_in_flight`.
//   * The `withTenant` paths bind `(operator_id, location_id,
//     user_id)` for the RLS policy
//     (`user_pii_erasure_requests_per_operator`); the worker uses
//     `withSystem` (forge_admin BYPASSRLS) so the cross-operator scan
//     is permitted but tightly attributed via the [reason] string.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';
import 'audit_logs_repository.dart';

/// One row from `public.user_pii_erasure_requests`. Mirrors the column
/// shape declared by the migration (see header for column definitions).
class UserPiiErasureRequestRecord {
  const UserPiiErasureRequestRecord({
    required this.erasureId,
    required this.operatorId,
    required this.userId,
    required this.requestedByUserId,
    required this.requestedAt,
    required this.businessDate,
    required this.gracePeriodEndsAt,
    this.appliedAt,
    this.reversedAt,
    this.reversedByUserId,
    this.reversalReason,
    this.piiSnapshot = const <String, Object?>{},
  });

  final String erasureId;
  final String operatorId;
  final String userId;
  final String requestedByUserId;
  final DateTime requestedAt;
  final String businessDate; // YYYY-MM-DD restaurant-local
  final DateTime gracePeriodEndsAt;
  final DateTime? appliedAt;
  final DateTime? reversedAt;
  final String? reversedByUserId;
  final String? reversalReason;

  /// Snapshot of the target user's PII captured at request time so
  /// [markReversed] can restore them. After the worker applies the
  /// NULL-out, this map is overwritten with `{}` server-side.
  final Map<String, Object?> piiSnapshot;

  bool get isPending => appliedAt == null && reversedAt == null;
  bool get isApplied => appliedAt != null;
  bool get isReversed => reversedAt != null;

  /// True iff the row's grace window has expired and it has not yet
  /// been applied or reversed.
  bool isGraceExpired(DateTime now) =>
      isPending && !now.isBefore(gracePeriodEndsAt);
}

/// Snapshot shape captured at erasure-request time. Keys mirror the
/// PII columns on `public.users` (see migration
/// `202604250008_auth_schema_foundation.sql`). The repository persists
/// this map verbatim to `pii_snapshot::jsonb`.
class UserPiiSnapshot {
  const UserPiiSnapshot({
    this.displayName,
    this.email,
    this.firstName,
    this.lastName,
    this.avatarUrl,
  });

  final String? displayName;
  final String? email;
  final String? firstName;
  final String? lastName;
  final String? avatarUrl;

  Map<String, Object?> toJson() => <String, Object?>{
        'display_name': displayName,
        'email': email,
        'first_name': firstName,
        'last_name': lastName,
        'avatar_url': avatarUrl,
      };

  static UserPiiSnapshot fromJson(Map<String, Object?> json) =>
      UserPiiSnapshot(
        displayName: json['display_name'] as String?,
        email: json['email'] as String?,
        firstName: json['first_name'] as String?,
        lastName: json['last_name'] as String?,
        avatarUrl: json['avatar_url'] as String?,
      );
}

class UserPiiErasureRepository extends OperatorScopedRepository {
  UserPiiErasureRepository(
    super.tenantWrapper, {
    this.auditLogsRepository = const AuditLogsRepository(),
  });

  /// Audit log writer used to append a `users.pii_erasure_*` row
  /// inside every mutation transaction. Defaults to the shared
  /// const-constructible [AuditLogsRepository]; tests inject a fake
  /// to assert the action / payload shape.
  final AuditLogsRepository auditLogsRepository;

  /// Inserts a pending erasure request and returns the durable row.
  /// The caller is responsible for capturing the [piiSnapshot] from
  /// the live `public.users` row before invoking this method (see
  /// [UserPiiErasureService.requestErasure] for the orchestration).
  ///
  /// Raises a UNIQUE violation if another pending erasure already
  /// exists for `(operatorId, userId)` — the partial index
  /// `user_pii_erasure_active_idx` enforces single in-flight erasure
  /// per target user. The proxy translates that into a 409.
  Future<UserPiiErasureRequestRecord> insertPending({
    required String erasureId,
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestedByUserId,
    required DateTime requestedAt,
    required String businessDate,
    required DateTime gracePeriodEndsAt,
    required UserPiiSnapshot piiSnapshot,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: requestedByUserId,
    );
    return withTenant<UserPiiErasureRequestRecord>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.user_pii_erasure_requests ('
        'erasure_id, operator_id, user_id, requested_by_user_id, '
        'requested_at, business_date, grace_period_ends_at, '
        'pii_snapshot'
        ') values ('
        '@erasure_id::uuid, @operator_id::uuid, @user_id::uuid, '
        '@requested_by_user_id::uuid, @requested_at::timestamptz, '
        '@business_date::date, @grace_period_ends_at::timestamptz, '
        '@pii_snapshot::jsonb'
        ') returning $_columnList',
        parameters: <String, Object?>{
          'erasure_id': erasureId,
          'operator_id': operatorId,
          'user_id': userId,
          'requested_by_user_id': requestedByUserId,
          'requested_at': requestedAt.toUtc().toIso8601String(),
          'business_date': businessDate,
          'grace_period_ends_at': gracePeriodEndsAt.toUtc().toIso8601String(),
          'pii_snapshot': jsonEncode(piiSnapshot.toJson()),
        },
      );
      return _projectSingle(rows, 'insert_pending');
    });
  }

  /// Composite path: reads the target user's PII, captures the
  /// snapshot, and inserts the pending erasure row inside ONE tenant
  /// transaction so a parallel writer cannot mutate the user between
  /// snapshot capture and request insert. Returns null when the
  /// target user row is missing (proxy maps to 404).
  Future<UserPiiErasureRequestRecord?> snapshotPiiAndInsertPending({
    required String erasureId,
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestedByUserId,
    required DateTime requestedAt,
    required String businessDate,
    required DateTime gracePeriodEndsAt,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: requestedByUserId,
    );
    return withTenant<UserPiiErasureRequestRecord?>(ctx, (exec) async {
      final userRows = await exec.query(
        'select display_name, email, first_name, last_name, avatar_url '
        'from public.users '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
      if (userRows.isEmpty) return null;
      final user = userRows.single;
      final snapshot = UserPiiSnapshot(
        displayName: user['display_name'] as String?,
        email: user['email'] as String?,
        firstName: user['first_name'] as String?,
        lastName: user['last_name'] as String?,
        avatarUrl: user['avatar_url'] as String?,
      );
      final rows = await exec.query(
        'insert into public.user_pii_erasure_requests ('
        'erasure_id, operator_id, user_id, requested_by_user_id, '
        'requested_at, business_date, grace_period_ends_at, '
        'pii_snapshot'
        ') values ('
        '@erasure_id::uuid, @operator_id::uuid, @user_id::uuid, '
        '@requested_by_user_id::uuid, @requested_at::timestamptz, '
        '@business_date::date, @grace_period_ends_at::timestamptz, '
        '@pii_snapshot::jsonb'
        ') returning $_columnList',
        parameters: <String, Object?>{
          'erasure_id': erasureId,
          'operator_id': operatorId,
          'user_id': userId,
          'requested_by_user_id': requestedByUserId,
          'requested_at': requestedAt.toUtc().toIso8601String(),
          'business_date': businessDate,
          'grace_period_ends_at': gracePeriodEndsAt.toUtc().toIso8601String(),
          'pii_snapshot': jsonEncode(snapshot.toJson()),
        },
      );
      final record = _projectSingle(rows, 'snapshot_pii_and_insert_pending');
      await auditLogsRepository.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: requestedAt,
        actorKind: 'user',
        actorUserId: requestedByUserId,
        targetKind: 'user',
        targetId: userId,
        action: 'users.pii_erasure_requested',
        payload: <String, Object?>{
          'erasure_id': record.erasureId,
          'grace_period_ends_at':
              record.gracePeriodEndsAt.toIso8601String(),
        },
      );
      return record;
    });
  }

  /// Resolves a tenant location for a target user — used by the
  /// worker which only knows `(operator_id, user_id)` from the scan
  /// and needs `(operator_id, location_id)` for the per-row apply
  /// `withTenant` SET LOCAL. Falls back to the operator's primary
  /// location if the user has no resolvable location yet (e.g. a
  /// user created before location grants land).
  Future<String?> resolveLocationForUser({
    required String operatorId,
    required String userId,
  }) {
    return withSystem<String?>(
      (exec) async {
        final rows = await exec.query(
          'select coalesce(u.primary_location_id::text, '
          '       o.primary_location_id::text) as location_id '
          'from public.users u '
          'join public.operators o on o.operator_id = u.operator_id '
          'where u.user_id = @user_id::uuid '
          'and u.operator_id = @operator_id::uuid',
          parameters: <String, Object?>{
            'user_id': userId,
            'operator_id': operatorId,
          },
        );
        if (rows.isEmpty) return null;
        final value = rows.single['location_id'];
        if (value is String && value.isNotEmpty) return value;
        return null;
      },
      reason: 'system.pii_erasure_grace_expired_apply.resolve_location',
    );
  }

  /// Reads the latest erasure row for `(operatorId, userId)` so the
  /// GET `.../erase-pii` route can render status + remaining grace
  /// window. Returns null when no erasure has ever been requested for
  /// the user (frontend renders the "Issue erasure" affordance).
  Future<UserPiiErasureRequestRecord?> findLatestForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<UserPiiErasureRequestRecord?>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_columnList '
        'from public.user_pii_erasure_requests '
        'where operator_id = @operator_id::uuid '
        'and user_id = @user_id::uuid '
        'order by requested_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'user_id': userId,
        },
      );
      if (rows.isEmpty) return null;
      return _projectRow(rows.single);
    });
  }

  /// Reads the pending row by id. Used by the reverse / apply paths
  /// to surface the captured snapshot before they mutate `users`.
  Future<UserPiiErasureRequestRecord?> findPendingById({
    required String operatorId,
    required String locationId,
    required String userId,
    required String erasureId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<UserPiiErasureRequestRecord?>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_columnList '
        'from public.user_pii_erasure_requests '
        'where erasure_id = @erasure_id::uuid '
        'and operator_id = @operator_id::uuid '
        'limit 1',
        parameters: <String, Object?>{
          'erasure_id': erasureId,
          'operator_id': operatorId,
        },
      );
      if (rows.isEmpty) return null;
      return _projectRow(rows.single);
    });
  }

  /// Stamps `reversed_at` + `reversed_by_user_id` on the named row,
  /// only while the row is still inside its grace window and not
  /// already terminal. Returns the rowcount (1 on success, 0 if the
  /// row is missing, applied, already reversed, or grace-expired).
  ///
  /// The caller is expected to read the row first via [findPendingById]
  /// and surface the captured snapshot to restore the user record.
  Future<int> markReversed({
    required String operatorId,
    required String locationId,
    required String userId,
    required String erasureId,
    required String reversedByUserId,
    required String? reversalReason,
    required DateTime reversedAt,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      final updated = await exec.execute(
        'update public.user_pii_erasure_requests '
        'set reversed_at = @reversed_at::timestamptz, '
        '    reversed_by_user_id = @reversed_by_user_id::uuid, '
        '    reversal_reason = @reversal_reason, '
        '    pii_snapshot = ' "'{}'::jsonb, "
        '    updated_at = now() '
        'where erasure_id = @erasure_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and applied_at is null '
        'and reversed_at is null '
        'and grace_period_ends_at > @reversed_at::timestamptz',
        parameters: <String, Object?>{
          'erasure_id': erasureId,
          'operator_id': operatorId,
          'reversed_at': reversedAt.toUtc().toIso8601String(),
          'reversed_by_user_id': reversedByUserId,
          'reversal_reason': reversalReason,
        },
      );
      if (updated > 0) {
        await auditLogsRepository.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          occurredAt: reversedAt,
          actorKind: 'user',
          actorUserId: reversedByUserId,
          targetKind: 'user',
          targetId: userId,
          action: 'users.pii_erasure_reversed',
          payload: <String, Object?>{
            'erasure_id': erasureId,
            if (reversalReason != null) 'reversal_reason': reversalReason,
          },
        );
      }
      return updated;
    });
  }

  /// Cross-operator scan run by the grace-window apply worker. Returns
  /// every pending row whose grace window has expired (`now >=
  /// grace_period_ends_at`) and that has not been applied or reversed.
  /// Uses `withSystem` (forge_admin BYPASSRLS) because the worker
  /// processes every operator's expired rows; per-row apply still
  /// runs inside its own [applyRowAndWipeSnapshot] tenant tx for RLS
  /// + audit attribution.
  Future<List<UserPiiErasureRequestRecord>> listDuePending({
    required DateTime now,
    int limit = 100,
  }) {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    return withSystem<List<UserPiiErasureRequestRecord>>(
      (exec) async {
        final rows = await exec.query(
          'select $_columnList '
          'from public.user_pii_erasure_requests '
          'where applied_at is null '
          'and reversed_at is null '
          'and grace_period_ends_at <= @now::timestamptz '
          'order by grace_period_ends_at, erasure_id '
          'limit @limit',
          parameters: <String, Object?>{
            'now': now.toUtc().toIso8601String(),
            'limit': limit,
          },
        );
        return rows.map(_projectRow).toList(growable: false);
      },
      reason: 'system.pii_erasure_grace_expired_apply.scan',
    );
  }

  /// Applies the actual NULL-out on `public.users` for the row's PII
  /// columns and stamps `applied_at` + wipes `pii_snapshot` to `'{}'`
  /// so PII does not linger past the grace window. Both writes happen
  /// inside one tenant transaction so the audit chain is consistent.
  ///
  /// Returns the rowcount on the request-row update (1 on success, 0
  /// if a parallel worker already finalised the row).
  Future<int> applyRowAndWipeSnapshot({
    required String operatorId,
    required String locationId,
    required String userId,
    required String erasureId,
    required DateTime appliedAt,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      // 1) NULL the PII columns on the live user row. The user_id row
      //    survives so foreign keys (audit_logs.actor_user_id, role
      //    grants) remain intact — this is PII-only redaction, not a
      //    cascade.
      await exec.execute(
        'update public.users '
        'set display_name = null, '
        '    email = null, '
        '    first_name = null, '
        '    last_name = null, '
        '    avatar_url = null, '
        '    updated_at = now() '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
        },
      );
      // 2) Stamp the request row + wipe the captured snapshot so PII
      //    does not linger.
      final updated = await exec.execute(
        'update public.user_pii_erasure_requests '
        'set applied_at = @applied_at::timestamptz, '
        '    pii_snapshot = ' "'{}'::jsonb, "
        '    updated_at = now() '
        'where erasure_id = @erasure_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and applied_at is null '
        'and reversed_at is null',
        parameters: <String, Object?>{
          'erasure_id': erasureId,
          'operator_id': operatorId,
          'applied_at': appliedAt.toUtc().toIso8601String(),
        },
      );
      if (updated > 0) {
        // Worker-driven apply — actor is the system service principal.
        // The boundary uses `actor_kind = 'service'` with a stable
        // sentinel principal id so the audit chain attributes the
        // mutation to the cron worker rather than the original
        // requester.
        await auditLogsRepository.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          occurredAt: appliedAt,
          actorKind: 'service',
          actorPrincipalId: 'sp:pii-erasure-worker',
          targetKind: 'user',
          targetId: userId,
          action: 'users.pii_erasure_applied',
          payload: <String, Object?>{
            'erasure_id': erasureId,
          },
        );
      }
      return updated;
    });
  }

  /// Restores the captured snapshot back onto `public.users`. Called
  /// by the proxy reverse route AFTER [markReversed] succeeds so the
  /// snapshot row has been wiped — the snapshot value used here comes
  /// from the pre-reverse read.
  Future<int> restoreSnapshotToUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required UserPiiSnapshot snapshot,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update public.users '
        'set display_name = @display_name, '
        '    email = coalesce(@email, email), '
        '    first_name = @first_name, '
        '    last_name = @last_name, '
        '    avatar_url = @avatar_url, '
        '    updated_at = now() '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
          'display_name': snapshot.displayName,
          'email': snapshot.email,
          'first_name': snapshot.firstName,
          'last_name': snapshot.lastName,
          'avatar_url': snapshot.avatarUrl,
        },
      );
    });
  }

  // ─── Projection helpers ───────────────────────────────────────────

  static const String _columnList =
      'erasure_id::text as erasure_id, '
      'operator_id::text as operator_id, '
      'user_id::text as user_id, '
      'requested_by_user_id::text as requested_by_user_id, '
      'requested_at, '
      'business_date::text as business_date, '
      'grace_period_ends_at, '
      'applied_at, reversed_at, '
      'reversed_by_user_id::text as reversed_by_user_id, '
      'reversal_reason, pii_snapshot';

  static UserPiiErasureRequestRecord _projectSingle(
    List<Map<String, Object?>> rows,
    String operation,
  ) {
    if (rows.isEmpty) {
      throw StateError(
        'user_pii_erasure_requests $operation returned no rows',
      );
    }
    return _projectRow(rows.single);
  }

  static UserPiiErasureRequestRecord _projectRow(Map<String, Object?> row) {
    final snapshotRaw = row['pii_snapshot'];
    Map<String, Object?> snapshot;
    if (snapshotRaw is Map) {
      snapshot = snapshotRaw.cast<String, Object?>();
    } else if (snapshotRaw is String && snapshotRaw.isNotEmpty) {
      final decoded = jsonDecode(snapshotRaw);
      snapshot = decoded is Map
          ? decoded.cast<String, Object?>()
          : const <String, Object?>{};
    } else {
      snapshot = const <String, Object?>{};
    }
    return UserPiiErasureRequestRecord(
      erasureId: row['erasure_id'] as String,
      operatorId: row['operator_id'] as String,
      userId: row['user_id'] as String,
      requestedByUserId: row['requested_by_user_id'] as String,
      requestedAt: _date(row['requested_at'], 'requested_at'),
      businessDate: row['business_date'] as String,
      gracePeriodEndsAt: _date(row['grace_period_ends_at'],
          'grace_period_ends_at'),
      appliedAt: _nullableDate(row['applied_at']),
      reversedAt: _nullableDate(row['reversed_at']),
      reversedByUserId: row['reversed_by_user_id'] as String?,
      reversalReason: row['reversal_reason'] as String?,
      piiSnapshot: snapshot,
    );
  }

  static DateTime _date(Object? value, String field) {
    final parsed = _nullableDate(value);
    if (parsed == null) {
      throw StateError('user_pii_erasure_requests row missing $field');
    }
    return parsed;
  }

  static DateTime? _nullableDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    throw StateError('unsupported timestamp value ${value.runtimeType}');
  }
}
