// Phase 9.0Σ.e — EventOutboxRepository.
//
// Persistence layer for the durable transactional outbox locked in
// `phase_9_scalability_decisions_2026-04-27.md` item 33 / Q22 and
// scoped in `phase_9_execution_backlog.md` parcel B26. The schema
// lands in
// `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql`;
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

  /// Default reclaim window for stale claims. Phase 10a tunes this
  /// based on observed publish latency; the default is conservative
  /// (5 minutes ≈ Q22's RED bridge-lag threshold) so legitimate slow
  /// publishes do not get re-claimed and double-published. Pub/Sub is
  /// at-least-once anyway and the contract requires consumers to
  /// dedupe via the payload `event_id`, so the cost of a rare
  /// double-publish is bounded.
  static const Duration defaultClaimReclaimAfter = Duration(minutes: 5);

  /// Claim up to [batchSize] outbox rows for the operator named in
  /// [operatorId]. Marks each row `picked_up_at = now()` in the same
  /// transaction so concurrent claimants under SKIP LOCKED never see
  /// the same row twice.
  ///
  /// **Claim predicate.** Three filters apply:
  ///
  /// ```text
  /// delivered_at IS NULL                     -- never re-publish a delivered row
  ///   AND (picked_up_at IS NULL              -- never claimed
  ///        OR picked_up_at < now() - <claimReclaimAfter>)  -- stale claim
  /// ```
  ///
  /// `delivered_at IS NULL` keeps rows the bridge has already
  /// successfully published out of the claim set. Without it, every
  /// delivered row whose `picked_up_at` crosses the reclaim window
  /// would be re-claimed and republished — combined with Phase 10a's
  /// 7-day retention, every delivered row would re-fan-out every
  /// `claimReclaimAfter` for a week.
  ///
  /// `picked_up_at IS NULL OR picked_up_at < now() - …` treats
  /// `picked_up_at` as a stale-reclaim lease so a row whose previous
  /// claimant crashed between commit and Pub/Sub ack becomes claimable
  /// again once the reclaim window passes. Q22 explicitly rules out
  /// any one-way claim marker for the "real durable queue"
  /// guardrail. Phase 10a's graceful failure path (re-NULL
  /// `picked_up_at` after a Pub/Sub failure) still works in
  /// addition; the lease is only the safety net for
  /// crash-during-publish.
  ///
  /// **Returned-row order.** PostgreSQL's `UPDATE … RETURNING` does
  /// not guarantee row order, so the inner CTE that locks the rows
  /// by `ORDER BY id` is wrapped in an outer
  /// `SELECT … ORDER BY updated.id` over the UPDATE's RETURNING set.
  /// The outer `ORDER BY` is qualified with the CTE name because the
  /// SELECT list aliases `id::text AS id`; bare `ORDER BY id` would
  /// resolve to the text alias and lex-sort `'10' < '2'` once ids
  /// cross digit lengths. The qualified form keeps the documented
  /// oldest-id-first contract intact for the bridge worker so its
  /// publish order matches the producer order.
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
    Duration claimReclaimAfter = defaultClaimReclaimAfter,
    String? topic,
  }) {
    if (batchSize <= 0) {
      throw ArgumentError.value(
        batchSize,
        'batchSize',
        'must be positive (claim batches are 1..N rows)',
      );
    }
    if (claimReclaimAfter <= Duration.zero) {
      throw ArgumentError.value(
        claimReclaimAfter,
        'claimReclaimAfter',
        'must be positive (a non-positive lease would re-claim '
            'every row on every poll)',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    final reclaimSeconds = claimReclaimAfter.inSeconds;
    // HARD-H — when a single-topic consumer (e.g. the boundary
    // backlog drain) calls claimBatch, push the topic filter inside
    // the inner CTE. Without it, the consumer would lock + stamp
    // `picked_up_at` on rows belonging to other topics (delaying
    // their real consumers until the reclaim window) and a batch
    // full of older non-matching rows could starve the consumer's
    // own backlog. The filter is optional so existing
    // multi-topic callers (Phase 10a bridge worker) keep their
    // behavior.
    final topicFilter = topic == null ? '' : '    and topic = @topic ';
    return withTenant<List<EventOutboxClaimedRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'with claimed as ('
        '  select id from event_outbox '
        '  where operator_id = @operator_id::uuid '
        // P1 fix: `delivered_at IS NULL` keeps already-delivered rows
        // out of the claim set. Without this, every delivered row
        // becomes claimable again once its picked_up_at crosses the
        // reclaim window — combined with Phase 10a's 7-day retention
        // that means each delivered row would be republished every
        // <reclaim_window> for a week.
        '    and delivered_at is null '
        '$topicFilter'
        "    and (picked_up_at is null or picked_up_at < now() - (@reclaim_seconds * interval '1 second')) "
        '  order by id '
        '  for update skip locked '
        '  limit @batch_size'
        '), updated as ('
        '  update event_outbox e '
        '     set picked_up_at = now() '
        '    from claimed '
        '   where e.id = claimed.id '
        '  returning '
        '    e.id, e.operator_id, e.topic, e.payload, '
        '    e.created_at, e.picked_up_at, e.attempt_count'
        ') '
        'select '
        '  updated.id::text as id, '
        '  updated.operator_id::text as operator_id, '
        '  updated.topic as topic, '
        '  updated.payload as payload, '
        '  updated.created_at as created_at, '
        '  updated.picked_up_at as picked_up_at, '
        '  updated.attempt_count as attempt_count '
        'from updated '
        // P2 fix: order by the BIGINT `updated.id` from the CTE, NOT
        // the `id::text` output alias. Bare `order by id` would
        // resolve to the text alias and lex-sort '10' before '2'
        // once ids cross digit lengths, breaking the
        // oldest-id-first contract.
        'order by updated.id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'batch_size': batchSize,
          'reclaim_seconds': reclaimSeconds,
          if (topic != null) 'topic': topic,
        },
      );
      return rows.map(_projectClaimedRow).toList(growable: false);
    });
  }

  /// Mark the row identified by [eventId] as delivered. Stamps
  /// `delivered_at = now()` so subsequent [claimBatch] calls pass it
  /// over (the claim predicate filters on `delivered_at IS NULL`).
  ///
  /// Used by the HARD-H boundary-monitor backlog drain in
  /// [BoundaryMonitorSupervisor]. Phase 10a's Pub/Sub bridge will use
  /// the same method to seal a row after a successful publish.
  Future<int> markDelivered({
    required String operatorId,
    required String locationId,
    required String eventId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update event_outbox '
        'set delivered_at = now() '
        'where id = @id::bigint '
        'and operator_id = @operator_id::uuid '
        'and delivered_at is null',
        parameters: <String, Object?>{
          'id': eventId,
          'operator_id': operatorId,
        },
      );
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
