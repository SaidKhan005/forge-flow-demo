// Phase 10a.2 — EventOutboxDeadLetterRepository.
//
// Persistence layer for the Phase 10a.2 dead-letter table that the
// bridge worker writes when a row's `attempt_count` crosses
// `EVENT_OUTBOX_DLQ_CAP`. Authority:
//
//   * `db/migrations/202605040300_phase_10a_2_dead_letter.sql` —
//     table + RLS + pg_partman registration.
//   * `docs/contracts/event_outbox_contract.md` — "Worker
//     Responsibilities": dead-letter rows whose attempt_count
//     exceeded the tunable cap by writing the row to an
//     `event_outbox_dead_letter` table and removing it from
//     `event_outbox`.
//   * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` —
//     Scope "Dead-letter" subsection.
//
// The repository owns three contract methods:
//
//   * [moveFromOutbox]    — bridge-side. Issues a single CTE that
//                           DELETEs the row from `event_outbox` and
//                           INSERTs the row into
//                           `event_outbox_dead_letter` so either both
//                           writes commit or neither does. The bridge
//                           passes `EVENT_OUTBOX_DLQ_CAP` as the cap
//                           parameter so the predicate is verified
//                           server-side (defense in depth — the
//                           worker should already have partitioned
//                           rows by attempt_count before calling).
//
//   * [listByOperator]    — admin-side. Returns up to [limit]
//                           dead-letter rows for the operator,
//                           ordered by `dead_lettered_at DESC`.
//                           Used by F&F-internal triage SQL (V1
//                           surface is admin SQL + log search; per
//                           lean cut 2, no operator-facing tile).
//
//   * [countByOperator]   — admin-side. Returns the depth (count)
//                           of dead-letter rows for the operator.
//                           Used by F&F-internal triage SQL (V1
//                           surface is admin SQL + log search; per
//                           lean cut 2, no operator-facing tile).
//
// CLAUDE.md "RLS performance discipline" bindings:
//   * Every read/write goes through `OperatorScopedRepository.withTenant`
//     so `SET LOCAL app.operator_id` is in place when the policy
//     (`event_outbox_dead_letter_per_tenant_select` /
//     `_modify`) evaluates.
//   * Indexes lead with `operator_id` so the policy folds into the
//     index probe (verified by the migration's recent-rows index).
//   * Bare `current_setting()` is forbidden in policy bodies — the
//     migration calls `public.app_current_operator()` per the 9.0Σ.b
//     wrapper lock.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// One dead-letter row, projected for F&F-internal triage. Per
/// lean cut 2 the V1 surface is admin SQL + log search; this struct
/// also fits a future operator-facing tile if depth ever justifies
/// one.
///
/// `id` is rendered as a string so the Dart side does not have to
/// commit to a 64-bit integer width on the wire (matches
/// `EventOutboxClaimedRow`).
class EventOutboxDeadLetterRow {
  const EventOutboxDeadLetterRow({
    required this.id,
    required this.operatorId,
    required this.topic,
    required this.payload,
    required this.createdAt,
    required this.attemptCount,
    required this.lastError,
    required this.deadLetteredAt,
    required this.deadLetterReason,
  });

  /// Original `event_outbox.id` carried forward from the live table
  /// at MOVE time. F&F-internal triage SQL uses this to link back to
  /// producer telemetry without joining tables.
  final String id;
  final String operatorId;
  final String topic;
  final Map<String, Object?> payload;
  final DateTime createdAt;
  final int attemptCount;

  /// Most-recent failure string copied from the live table at MOVE
  /// time. Nullable because the live table also allows NULL (a row
  /// that hit the cap with no recorded last_error is rare but
  /// allowed by the contract).
  final String? lastError;

  /// Server-set timestamp at MOVE time. Drives the recent-rows index
  /// + the partition column.
  final DateTime deadLetteredAt;

  /// Short machine-readable code: `'attempt_cap_exceeded'` (default
  /// for V1 auto-DLQ) or `'forced_dlq'` (reserved for the post-V1
  /// manual-DLQ operator action).
  final String deadLetterReason;
}

class EventOutboxDeadLetterRepository extends OperatorScopedRepository {
  EventOutboxDeadLetterRepository(super.tenantWrapper);

  /// Default `dead_letter_reason` for the auto-DLQ path. Stays in
  /// sync with the migration's CHECK constraint allowed values.
  static const String reasonAttemptCapExceeded = 'attempt_cap_exceeded';

  /// Reserved for the post-V1 manual-DLQ operator action. The bridge
  /// worker never writes this reason; declared here so the manual
  /// flow can pass the constant rather than re-declaring the literal.
  static const String reasonForcedDlq = 'forced_dlq';

  /// Move a row from `event_outbox` to `event_outbox_dead_letter` in
  /// a single transaction. Either both writes commit or neither does.
  ///
  /// The CTE pattern:
  ///
  /// ```sql
  /// WITH dead AS (
  ///   DELETE FROM event_outbox
  ///    WHERE operator_id = $1::uuid
  ///      AND id = $2::bigint
  ///      AND attempt_count > $3
  ///   RETURNING *
  /// )
  /// INSERT INTO event_outbox_dead_letter
  ///        (id, operator_id, topic, payload, created_at, picked_up_at,
  ///         delivered_at, attempt_count, last_error_at, last_error,
  ///         dead_lettered_at, dead_lettered_at_month,
  ///         dead_letter_reason)
  /// SELECT id, operator_id, topic, payload, created_at, picked_up_at,
  ///        delivered_at, attempt_count, last_error_at, last_error,
  ///        now(),
  ///        date_trunc('month', now() at time zone 'UTC')::date,
  ///        $4
  /// FROM dead
  /// RETURNING id::text AS id;
  /// ```
  ///
  /// The `attempt_count > $cap` predicate is server-side defense in
  /// depth — the bridge worker already partitions rows by
  /// `attempt_count > EVENT_OUTBOX_DLQ_CAP` before calling this
  /// method, but the predicate inside the CTE prevents an off-by-one
  /// caller from MOVEing a row that has not actually exceeded the
  /// cap.
  ///
  /// Returns the inserted row's id (the original `event_outbox.id`,
  /// rendered as a string). When the predicate filters the row out
  /// (already moved, attempt_count not actually past the cap, or
  /// RLS denied the read), the repository returns `null` instead of
  /// throwing — the bridge worker treats `null` as "row already
  /// gone, skip the publish loop entry" rather than an error.
  Future<String?> moveFromOutbox({
    required String operatorId,
    required String locationId,
    required String eventId,
    required int attemptCountThreshold,
    String? userId,
    String reason = reasonAttemptCapExceeded,
  }) {
    if (attemptCountThreshold < 0) {
      throw ArgumentError.value(
        attemptCountThreshold,
        'attemptCountThreshold',
        'must be non-negative (cap is the count, not an offset)',
      );
    }
    if (reason != reasonAttemptCapExceeded && reason != reasonForcedDlq) {
      throw ArgumentError.value(
        reason,
        'reason',
        'must be one of attempt_cap_exceeded / forced_dlq (matches '
            'the migration CHECK constraint)',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'with dead as ('
        '  delete from event_outbox '
        '   where operator_id = @operator_id::uuid '
        '     and id = @id::bigint '
        '     and attempt_count > @threshold '
        '  returning '
        '    id, operator_id, topic, payload, created_at, '
        '    picked_up_at, delivered_at, attempt_count, '
        '    last_error_at, last_error'
        ') '
        'insert into event_outbox_dead_letter ('
        '  id, operator_id, topic, payload, created_at, '
        '  picked_up_at, delivered_at, attempt_count, '
        '  last_error_at, last_error, '
        '  dead_lettered_at, dead_lettered_at_month, '
        '  dead_letter_reason'
        ') '
        'select '
        '  id, operator_id, topic, payload, created_at, '
        '  picked_up_at, delivered_at, attempt_count, '
        '  last_error_at, last_error, '
        '  now(), '
        "  date_trunc('month', now() at time zone 'UTC')::date, "
        '  @reason '
        'from dead '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'id': eventId,
          'threshold': attemptCountThreshold,
          'reason': reason,
        },
      );
      if (rows.isEmpty) return null;
      final id = rows.single['id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'event_outbox_dead_letter MOVE returned a malformed id',
        );
      }
      return id;
    });
  }

  /// List the most-recent dead-letter rows for [operatorId], ordered
  /// by `dead_lettered_at DESC` so triage sees the latest failures
  /// first. Default [limit] is 10 — matches a typical "last N rows"
  /// admin SQL query; callers that want more pass a higher value.
  Future<List<EventOutboxDeadLetterRow>> listByOperator({
    required String operatorId,
    required String locationId,
    int limit = 10,
    String? userId,
  }) {
    if (limit <= 0) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be positive (admin SQL pulls 1..N rows)',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<EventOutboxDeadLetterRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select '
        '  id::text as id, '
        '  operator_id::text as operator_id, '
        '  topic, '
        '  payload, '
        '  created_at, '
        '  attempt_count, '
        '  last_error, '
        '  dead_lettered_at, '
        '  dead_letter_reason '
        'from event_outbox_dead_letter '
        'where operator_id = @operator_id::uuid '
        'order by dead_lettered_at desc, id desc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'limit': limit,
        },
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  /// Count of dead-letter rows for [operatorId]. Used by the admin
  /// tile's depth chip.
  Future<int> countByOperator({
    required String operatorId,
    required String locationId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      final rows = await exec.query(
        'select coalesce(count(*), 0)::bigint as cnt '
        'from event_outbox_dead_letter '
        'where operator_id = @operator_id::uuid',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (rows.isEmpty) return 0;
      final raw = rows.single['cnt'];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      throw StateError(
        'event_outbox_dead_letter count returned a malformed cnt',
      );
    });
  }

  EventOutboxDeadLetterRow _projectRow(Map<String, Object?> row) {
    final id = row['id'];
    final operatorId = row['operator_id'];
    final topic = row['topic'];
    final payloadRaw = row['payload'];
    final createdAt = row['created_at'];
    final attemptCount = row['attempt_count'];
    final lastError = row['last_error'];
    final deadLetteredAt = row['dead_lettered_at'];
    final deadLetterReason = row['dead_letter_reason'];
    if (id is! String ||
        operatorId is! String ||
        topic is! String ||
        createdAt is! DateTime ||
        attemptCount is! int ||
        deadLetteredAt is! DateTime ||
        deadLetterReason is! String) {
      throw StateError(
        'event_outbox_dead_letter row returned a malformed shape',
      );
    }
    if (lastError != null && lastError is! String) {
      throw StateError(
        'event_outbox_dead_letter last_error is not a String / null',
      );
    }
    return EventOutboxDeadLetterRow(
      id: id,
      operatorId: operatorId,
      topic: topic,
      payload: _decodePayload(payloadRaw),
      createdAt: createdAt,
      attemptCount: attemptCount,
      lastError: lastError as String?,
      deadLetteredAt: deadLetteredAt,
      deadLetterReason: deadLetterReason,
    );
  }

  /// Mirrors `EventOutboxRepository._decodePayload` so the driver-shape
  /// contract (`Map<String, Object?>` | `Map<dynamic, dynamic>` |
  /// `String` | empty-string) is normalized identically on both
  /// surfaces.
  Map<String, Object?> _decodePayload(Object? raw) {
    if (raw == null) return const <String, Object?>{};
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) {
      return raw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    if (raw is String) {
      if (raw.isEmpty) return const <String, Object?>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    }
    throw StateError(
      'event_outbox_dead_letter row returned a payload of unsupported '
      'type ${raw.runtimeType}',
    );
  }
}
