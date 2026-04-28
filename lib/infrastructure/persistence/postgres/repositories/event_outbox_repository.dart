// Phase 9.0Σ.e — EventOutboxRepository.
//
// Persistence layer for the durable transactional outbox locked in
// `phase_9_scalability_decisions_2026-04-27.md` item 33 / Q22 and
// scoped in `phase_9_execution_backlog.md` parcel B26. The schema
// lands in
// `db/migrations/202604280002_phase_9_0sigma_e_event_outbox.sql`;
// this repository owns the two contract methods producers and the
// (Phase 10a) bridge worker call:
//
//   * [enqueue]    — producer-side. Writes one row inside the caller's
//                    tenant transaction so the business mutation and
//                    the outbox row commit or roll back atomically.
//                    The trigger fires `pg_notify('event_outbox', …)`
//                    on commit; NOTIFY is treated only as a wake-up
//                    signal, never as the source of truth.
//
//   * [claimBatch] — bridge-side. Issues
//                    `SELECT … FROM event_outbox FOR UPDATE SKIP
//                    LOCKED` against the tenant-leading
//                    `(operator_id, picked_up_at NULLS FIRST, id)`
//                    index, stamps `picked_up_at = now()`, and
//                    returns the projected rows. Workers run in
//                    independent transactions so concurrent shards
//                    cannot fight over the same row.
//
// Phase 10a owns the Pub/Sub publisher, the WebSocket leg, the retry
// ledger (`attempt_count` / `last_error*` / dead-letter), the
// retention sweep, and the yellow/red lag tripwires. The schema is
// stable from this slice so the Phase 10a worker can be wired
// without a follow-up migration.
//
// CLAUDE.md "RLS performance discipline" bindings:
//   * Every read/write goes through `OperatorScopedRepository.withTenant`
//     so `SET LOCAL app.operator_id` is in place when the policy
//     (`event_outbox_per_tenant_select` / `_modify`) evaluates.
//   * Indexes lead with `operator_id` so the policy folds into the
//     index probe (verified by the migration's claim-index shape).
//   * Bare `current_setting()` is forbidden in policy bodies — the
//     migration calls `public.app_current_operator()` per the 9.0Σ.b
//     wrapper lock.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// One claimed `event_outbox` row, projected for the Phase 10a
/// bridge worker. Only the columns the worker needs at publish time
/// are surfaced; the retry-ledger columns (`attempt_count`,
/// `last_error_at`, `last_error`) are mutated through dedicated
/// methods that land alongside the worker.
class EventOutboxClaimedRow {
  const EventOutboxClaimedRow({
    required this.id,
    required this.operatorId,
    required this.topic,
    required this.payload,
    required this.createdAt,
    required this.pickedUpAt,
    required this.attemptCount,
  });

  /// `bigserial` PK rendered as a string so the Dart side does not
  /// have to commit to a 64-bit integer width on the wire.
  final String id;
  final String operatorId;
  final String topic;
  final Map<String, Object?> payload;
  final DateTime createdAt;
  final DateTime pickedUpAt;
  final int attemptCount;
}

class EventOutboxRepository extends OperatorScopedRepository {
  EventOutboxRepository(super.tenantWrapper);

  /// Enqueue one event row inside the caller's tenant transaction.
  /// Returns the freshly assigned `bigserial` id (rendered as a
  /// string — see [EventOutboxClaimedRow.id]).
  ///
  /// The repository injects its own `withTenant` boundary so the
  /// SET LOCAL payload always carries the matching `operator_id`;
  /// callers that already hold a tenant transaction can — and
  /// should — wrap their full unit of work (business write +
  /// `enqueue`) in a single outer transaction once the executor
  /// surface exposes a "join existing transaction" hook. Until then
  /// the wrapper opens an inner transaction; each `enqueue` is its
  /// own atomic commit, which is sufficient for Q22's "outbox row
  /// commits or doesn't" guarantee but does NOT yet give the full
  /// "outbox row commits with the business row" guarantee. That
  /// upgrade is a Phase 10a follow-up tracked in the contract doc.
  Future<String> enqueue({
    required String operatorId,
    required String locationId,
    required String topic,
    required Map<String, Object?> payload,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into event_outbox (operator_id, topic, payload) '
        'values (@operator_id::uuid, @topic, @payload::jsonb) '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'topic': topic,
          'payload': jsonEncode(payload),
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'event_outbox insert returned no rows — RLS may have '
          'blocked the row even though SET LOCAL ran',
        );
      }
      final id = rows.single['id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'event_outbox insert returned a malformed id',
        );
      }
      return id;
    });
  }

  /// Claim up to [batchSize] undelivered rows for the operator named
  /// in [operatorId]. Marks each row `picked_up_at = now()` in the
  /// same transaction so concurrent claimants under SKIP LOCKED never
  /// see the same row twice.
  ///
  /// The query orders by `id` so older rows publish first (matches
  /// the `(operator_id, picked_up_at NULLS FIRST, id)` index trailing
  /// column — no sort needed).
  ///
  /// `FOR UPDATE SKIP LOCKED` is the locked Q22 / B26 claim shape:
  /// rows already locked by another worker shard are skipped rather
  /// than blocking, so worker concurrency scales linearly with shard
  /// count.
  Future<List<EventOutboxClaimedRow>> claimBatch({
    required String operatorId,
    required String locationId,
    required int batchSize,
    String? userId,
  }) {
    if (batchSize <= 0) {
      throw ArgumentError.value(
        batchSize,
        'batchSize',
        'must be positive (claim batches are 1..N rows)',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<EventOutboxClaimedRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'with claimed as ('
        '  select id from event_outbox '
        '  where operator_id = @operator_id::uuid '
        '    and picked_up_at is null '
        '  order by id '
        '  for update skip locked '
        '  limit @batch_size'
        ') '
        'update event_outbox e '
        '   set picked_up_at = now() '
        '  from claimed '
        ' where e.id = claimed.id '
        'returning '
        '  e.id::text as id, '
        '  e.operator_id::text as operator_id, '
        '  e.topic as topic, '
        '  e.payload as payload, '
        '  e.created_at as created_at, '
        '  e.picked_up_at as picked_up_at, '
        '  e.attempt_count as attempt_count',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'batch_size': batchSize,
        },
      );
      return rows.map(_projectClaimedRow).toList(growable: false);
    });
  }

  EventOutboxClaimedRow _projectClaimedRow(Map<String, Object?> row) {
    final id = row['id'];
    final operatorId = row['operator_id'];
    final topic = row['topic'];
    final payloadRaw = row['payload'];
    final createdAt = row['created_at'];
    final pickedUpAt = row['picked_up_at'];
    final attemptCount = row['attempt_count'];
    if (id is! String ||
        operatorId is! String ||
        topic is! String ||
        createdAt is! DateTime ||
        pickedUpAt is! DateTime ||
        attemptCount is! int) {
      throw StateError(
        'event_outbox claim returned a malformed row shape',
      );
    }
    final payload = _decodePayload(payloadRaw);
    return EventOutboxClaimedRow(
      id: id,
      operatorId: operatorId,
      topic: topic,
      payload: payload,
      createdAt: createdAt,
      pickedUpAt: pickedUpAt,
      attemptCount: attemptCount,
    );
  }

  /// `payload` arrives from the driver as either a Dart `Map`
  /// (jsonb decoded by the underlying adapter) or a `String` (raw
  /// JSON text). The repository normalizes both into `Map<String,
  /// Object?>` so downstream code does not need to branch.
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
      'event_outbox claim returned a payload of unsupported type '
      '${raw.runtimeType}',
    );
  }
}
