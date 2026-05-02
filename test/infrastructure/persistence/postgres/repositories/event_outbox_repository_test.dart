// Phase 9.0Σ.e / HARD-H / post-hardening P2 — canonical-path unit
// tests for EventOutboxRepository.
//
// Companion to `test/phase_9_0sigma_e_event_outbox_test.dart`, which
// covers the migration shape AND the core repository SQL contract
// (enqueue SET LOCAL + INSERT, claimBatch FOR UPDATE SKIP LOCKED,
// lease-reclaim predicate, two-tenant pooled-connection isolation).
// This file is the canonical-path entry expected by the
// post-hardening test-coverage rollup and focuses on the surfaces
// that file does NOT cover:
//
//   * `markDelivered` — added under HARD-H so the boundary-monitor
//     backlog drain (and Phase 10a's bridge) can seal a row after a
//     successful publish. The claim predicate filters on
//     `delivered_at IS NULL`, so a missed seal would re-publish
//     forever; this test pins the UPDATE shape and the
//     transaction-bounded operator scoping.
//
//   * `claimBatch(topic: ...)` — added under HARD-H so a single-topic
//     consumer (boundary-monitor backlog drain) does not lock + stamp
//     `picked_up_at` on rows belonging to other topics. Without the
//     filter, a batch full of older non-matching rows would starve the
//     consumer's own backlog.
//
//   * Payload normalization edge cases — the driver hands back
//     `payload` as `Map<String, Object?>`, generic `Map`, or raw JSON
//     `String`. The repo normalizes all three; the bulk test pins
//     `Map<String, Object?>` and `String`, this file pins generic `Map`
//     (Map<dynamic, dynamic>) and the empty-string edge.
//
//   * `enqueue` malformed RETURNING id — the repo throws StateError
//     when the INSERT returns no rows (RLS denial). It must also
//     throw when `RETURNING id::text` produces a non-string or empty
//     value (defensive — the driver should never do this, but the
//     guard is in production code so the test pins it).
//
// Acceptance:
//   * Tenant scoping holds on read AND write — every operation runs
//     through `withTenant`, and the wrapper-emitted SET LOCAL
//     `app.operator_id` is observable in the recorded SQL stream
//     before the repository's INSERT/UPDATE/SELECT executes.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

void main() {
  group('EventOutboxRepository.markDelivered (HARD-H — backlog drain seal)',
      () {
    test(
      'UPDATE shape: stamps delivered_at = now(), guards on '
      'delivered_at IS NULL (idempotent), parameters operator_id + id',
      () async {
        final pool = _RecordingPool(updateRowCount: 1);
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        final affected = await repo.markDelivered(
          operatorId: _opA,
          locationId: _locA,
          eventId: '101',
          userId: _userA,
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        // SET LOCAL block ran first (tenant scope on the seal write).
        expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
        expect(tx.parameters.first['value'], equals(_opA));

        // Find the UPDATE statement (last non-set_config write).
        final updateSql = tx.executedSql
            .firstWhere((sql) => sql.contains('update event_outbox'));
        expect(updateSql, contains('set delivered_at = now()'));
        expect(updateSql, contains('where id = @id::bigint'));
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        // Idempotency guard: re-running on an already-delivered row
        // touches zero rows. Without `delivered_at is null`, a
        // stale-message redrive would silently overwrite the prior
        // delivery timestamp.
        expect(updateSql, contains('and delivered_at is null'));

        final updateParams = tx.parameters
            .firstWhere((p) => p['id'] == '101');
        expect(updateParams['operator_id'], equals(_opA));

        expect(tx.commitCount, equals(1));
      },
    );

    test(
      'reports affected-row count from the underlying execute() so the '
      'caller knows whether the seal landed or was already sealed',
      () async {
        // Already-delivered row: UPDATE reports 0 affected.
        final pool = _RecordingPool(updateRowCount: 0);
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        final affected = await repo.markDelivered(
          operatorId: _opA,
          locationId: _locA,
          eventId: '999',
        );
        expect(
          affected,
          equals(0),
          reason: 'caller distinguishes "freshly sealed" (1) from '
              '"already sealed" (0) so the boundary-monitor backlog '
              'drain can avoid double-publish telemetry',
        );
      },
    );

    test(
      'invalid operator UUID is rejected before opening a transaction '
      '(TenantContext validation runs at the wrapper boundary)',
      () async {
        final pool = _RecordingPool(updateRowCount: 1);
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        Object? thrown;
        try {
          await repo.markDelivered(
            operatorId: 'not-a-uuid',
            locationId: _locA,
            eventId: '101',
          );
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isNotNull);
        expect(pool.transactions, isEmpty);
      },
    );
  });

  group('EventOutboxRepository.claimBatch(topic:) — HARD-H consumer filter',
      () {
    test(
      'topic filter present: SQL includes `topic = @topic` inside the '
      'inner CTE, parameter is bound, and other filters still apply',
      () async {
        final pool = _RecordingPool(claimedRows: const <PostgresRow>[]);
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        await repo.claimBatch(
          operatorId: _opA,
          locationId: _locA,
          batchSize: 5,
          topic: 'auth.session.login',
        );
        final tx = pool.transactions.single;
        final claimSql = tx.executedSql.last;
        // Filter inside the inner CTE so we don't lock + stamp
        // picked_up_at on rows belonging to other topics.
        expect(claimSql, contains('and topic = @topic'));
        // Other filters still in place — topic is additive.
        expect(claimSql, contains('delivered_at is null'));
        expect(claimSql, contains('for update skip locked'));
        expect(claimSql, contains('order by id'));
        expect(tx.parameters.last['topic'], equals('auth.session.login'));
      },
    );

    test(
      'topic filter absent: SQL omits the topic predicate AND the '
      '@topic parameter is NOT bound (back-compat with the Phase 10a '
      'bridge worker which is multi-topic)',
      () async {
        final pool = _RecordingPool(claimedRows: const <PostgresRow>[]);
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        await repo.claimBatch(
          operatorId: _opA,
          locationId: _locA,
          batchSize: 5,
        );
        final tx = pool.transactions.single;
        final claimSql = tx.executedSql.last;
        // No topic predicate — default Phase 10a multi-topic shape.
        expect(claimSql, isNot(contains('and topic = @topic')));
        // @topic must not be in the parameter map either; otherwise
        // a stale binding could leak into a future call.
        expect(tx.parameters.last.containsKey('topic'), isFalse);
      },
    );
  });

  group('EventOutboxRepository.claimBatch — payload normalization edges', () {
    test(
      'payload arrives as Map<dynamic, dynamic> (some adapters): '
      'repo normalizes to Map<String, Object?> by stringifying keys',
      () async {
        final claimedAt = DateTime.utc(2026, 4, 28, 12);
        // ignore: prefer_const_literals_to_create_immutables -- want a dynamic-typed Map
        final dynamicPayload = <dynamic, dynamic>{
          'topic': 'rollup.invalidate.daypart',
          'count': 7,
        };
        final pool = _RecordingPool(
          claimedRows: <PostgresRow>[
            <String, Object?>{
              'id': '101',
              'operator_id': _opA,
              'topic': 'rollup.invalidate.daypart',
              'payload': dynamicPayload,
              'created_at': claimedAt.subtract(const Duration(seconds: 1)),
              'picked_up_at': claimedAt,
              'attempt_count': 0,
            },
          ],
        );
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        final claimed = await repo.claimBatch(
          operatorId: _opA,
          locationId: _locA,
          batchSize: 1,
        );
        expect(claimed, hasLength(1));
        expect(claimed.single.payload['topic'], equals('rollup.invalidate.daypart'));
        expect(claimed.single.payload['count'], equals(7));
      },
    );

    test(
      'empty-string payload normalizes to an empty map (some legacy '
      'rows seeded before the JSON-object CHECK landed)',
      () async {
        final claimedAt = DateTime.utc(2026, 4, 28, 12);
        final pool = _RecordingPool(
          claimedRows: <PostgresRow>[
            <String, Object?>{
              'id': '102',
              'operator_id': _opA,
              'topic': 'auth.session.login',
              'payload': '',
              'created_at': claimedAt.subtract(const Duration(seconds: 1)),
              'picked_up_at': claimedAt,
              'attempt_count': 0,
            },
          ],
        );
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        final claimed = await repo.claimBatch(
          operatorId: _opA,
          locationId: _locA,
          batchSize: 1,
        );
        expect(claimed.single.payload, isEmpty);
      },
    );

    test(
      'malformed payload (not Map / String) throws StateError so the '
      'driver-shape contract violation surfaces loudly rather than '
      'silently coercing into a usable but wrong shape',
      () async {
        final claimedAt = DateTime.utc(2026, 4, 28, 12);
        final pool = _RecordingPool(
          claimedRows: <PostgresRow>[
            <String, Object?>{
              'id': '103',
              'operator_id': _opA,
              'topic': 'auth.session.login',
              'payload': 12345, // garbage — driver should never do this
              'created_at': claimedAt.subtract(const Duration(seconds: 1)),
              'picked_up_at': claimedAt,
              'attempt_count': 0,
            },
          ],
        );
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.claimBatch(
            operatorId: _opA,
            locationId: _locA,
            batchSize: 1,
          ),
          throwsStateError,
        );
      },
    );

    test(
      'malformed claimed row (e.g. non-DateTime created_at) throws '
      'StateError instead of a vague type-cast crash',
      () async {
        final pool = _RecordingPool(
          claimedRows: <PostgresRow>[
            <String, Object?>{
              'id': '104',
              'operator_id': _opA,
              'topic': 'auth.session.login',
              'payload': const <String, Object?>{},
              'created_at': '2026-04-28', // string instead of DateTime
              'picked_up_at': DateTime.utc(2026, 4, 28, 12),
              'attempt_count': 0,
            },
          ],
        );
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.claimBatch(
            operatorId: _opA,
            locationId: _locA,
            batchSize: 1,
          ),
          throwsStateError,
        );
      },
    );
  });

  group('EventOutboxRepository.enqueue — defensive RETURNING id guards', () {
    test(
      'RETURNING returns a non-string id (driver protocol violation) → '
      'StateError surfaces so the boundary-monitor sees a hard failure '
      'rather than a silent enqueue with a broken id',
      () async {
        final pool = _RecordingPool(returningId: 99); // int instead of String
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.enqueue(
            operatorId: _opA,
            locationId: _locA,
            topic: 'auth.session.login',
            payload: const <String, Object?>{},
          ),
          throwsStateError,
        );
      },
    );

    test(
      'RETURNING returns an empty-string id → StateError (defensive '
      'contract: bigserial cast to text is never empty in practice)',
      () async {
        final pool = _RecordingPool(returningId: '');
        final repo = EventOutboxRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.enqueue(
            operatorId: _opA,
            locationId: _locA,
            topic: 'auth.session.login',
            payload: const <String, Object?>{},
          ),
          throwsStateError,
        );
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the EventOutbox seam.
///
/// `returningId` controls what the INSERT's `RETURNING id::text as id`
/// hands back; pass `null` for an empty-rows result, a non-String for
/// a malformed-shape result, or a String for the happy path.
///
/// `claimedRows` controls what the claim CTE chain returns; defaults
/// to empty.
///
/// `updateRowCount` controls what `markDelivered`'s UPDATE reports as
/// the affected-row count.
class _RecordingPool implements PostgresPool {
  _RecordingPool({
    this.returningId,
    this.claimedRows = const <PostgresRow>[],
    this.updateRowCount = 0,
  });

  final Object? returningId;
  final List<PostgresRow> claimedRows;
  final int updateRowCount;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      returningId: returningId,
      claimedRows: claimedRows,
      updateRowCount: updateRowCount,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    required this.returningId,
    required this.claimedRows,
    required this.updateRowCount,
  });

  final Object? returningId;
  final List<PostgresRow> claimedRows;
  final int updateRowCount;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into event_outbox') &&
        sql.contains('returning id::text as id')) {
      if (returningId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'id': returningId},
      ];
    }
    if (sql.contains('with claimed as') &&
        sql.contains('update event_outbox e')) {
      return claimedRows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('update event_outbox') &&
        sql.contains('set delivered_at = now()')) {
      return updateRowCount;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}
