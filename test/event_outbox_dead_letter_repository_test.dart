// Phase 10a.2 — EventOutboxDeadLetterRepository unit tests.
//
// Pinned behaviour (matches
// `db/migrations/202605040300_phase_10a_2_dead_letter.sql` +
// `docs/contracts/event_outbox_contract.md` "Worker Responsibilities"):
//
//   * `moveFromOutbox` issues a SINGLE statement: a `WITH dead AS
//     (DELETE … RETURNING *) INSERT … SELECT … RETURNING id` CTE.
//     Either both writes commit or neither does — the contract
//     requires the MOVE be transactional.
//
//   * The CTE filters on `attempt_count > @threshold` so an
//     off-by-one caller cannot MOVE a row that has not actually
//     exceeded the cap; defense in depth.
//
//   * `dead_lettered_at` and `dead_lettered_at_month` are set
//     server-side (`now()` / `date_trunc('month', now())`) — the
//     bridge does NOT pass producer-supplied timestamps.
//
//   * `dead_letter_reason` defaults to `'attempt_cap_exceeded'`;
//     the constructor validates the value matches the migration's
//     CHECK constraint.
//
//   * `listByOperator` orders by `dead_lettered_at DESC` so admin
//     SQL triage sees the latest failures first.
//
//   * Tenant scoping holds on every operation — the SET LOCAL
//     `app.operator_id` is observable in the recorded SQL stream
//     before the repository's CTE / SELECT executes. The wrapper
//     emits the SET LOCAL inside the same transaction as the body,
//     and `withTenant` rolls back on exception so a failing INSERT
//     also rolls back the matching DELETE — the transactional move
//     contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_dead_letter_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const String _userA = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

void main() {
  group('EventOutboxDeadLetterRepository.moveFromOutbox', () {
    test(
      'issues a single CTE that DELETEs from event_outbox and INSERTs '
      'into event_outbox_dead_letter; returns the id from RETURNING',
      () async {
        final pool = _RecordingPool(returningId: '101');
        final repo = EventOutboxDeadLetterRepository(
          TenantTransactionWrapper(pool),
        );
        final movedId = await repo.moveFromOutbox(
          operatorId: _opA,
          locationId: _locA,
          eventId: '101',
          attemptCountThreshold: 5,
          userId: _userA,
        );
        expect(movedId, '101');

        final tx = pool.transactions.single;

        // SET LOCAL before the body, on the same transaction.
        expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
        expect(tx.parameters.first['value'], equals(_opA));

        // Single CTE: dead AS (delete returning) + insert select returning.
        final cteSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('with dead as'),
        );
        expect(cteSql, contains('delete from event_outbox'));
        expect(cteSql, contains('returning '));
        expect(cteSql, contains('insert into event_outbox_dead_letter'));
        expect(cteSql, contains('from dead'));
        expect(cteSql, contains('returning id::text as id'));
        // The threshold predicate makes the move idempotent on a
        // row that has not actually exceeded the cap — defense in
        // depth.
        expect(cteSql, contains('attempt_count > @threshold'));
        // Server-set timestamps.
        expect(cteSql, contains('now()'));
        expect(cteSql, contains("date_trunc('month'"));

        final cteParams = tx.parameters.firstWhere(
          (p) => p['threshold'] == 5,
        );
        expect(cteParams['operator_id'], equals(_opA));
        expect(cteParams['id'], equals('101'));
        expect(
          cteParams['reason'],
          equals(EventOutboxDeadLetterRepository.reasonAttemptCapExceeded),
        );

        expect(tx.commitCount, equals(1));
      },
    );

    test(
      'returns null when the CTE filters the row out (already moved by '
      'another shard, or attempt_count not actually past the cap)',
      () async {
        final pool = _RecordingPool(returningId: null);
        final repo = EventOutboxDeadLetterRepository(
          TenantTransactionWrapper(pool),
        );
        final movedId = await repo.moveFromOutbox(
          operatorId: _opA,
          locationId: _locA,
          eventId: '999',
          attemptCountThreshold: 5,
        );
        expect(
          movedId,
          isNull,
          reason: 'caller distinguishes "moved" (id) from "already '
              'gone" (null) so the bridge worker does not re-publish '
              'a row that another shard moved out from under it',
        );
        // Transaction still committed — empty INSERT result is not an
        // error condition.
        expect(pool.transactions.single.commitCount, equals(1));
      },
    );

    test(
      'transaction-bounded atomicity: a thrown error inside the body '
      'rolls back the SET LOCAL plus any partial CTE work',
      () async {
        final pool = _RecordingPool(throwOnQuery: _SimulatedDbFailure());
        final repo = EventOutboxDeadLetterRepository(
          TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await repo.moveFromOutbox(
            operatorId: _opA,
            locationId: _locA,
            eventId: '101',
            attemptCountThreshold: 5,
          );
        } catch (error) {
          thrown = error;
        }
        expect(
          thrown,
          isA<_SimulatedDbFailure>(),
          reason: 'wrapper re-throws so callers see the underlying '
              'failure; rollback path runs in finally',
        );
        final tx = pool.transactions.single;
        expect(tx.commitCount, equals(0));
        expect(
          tx.rollbackCount,
          equals(1),
          reason: 'the failed body must roll back so neither the '
              'DELETE nor the INSERT lands — this is the contract '
              'requirement that the MOVE is transactional',
        );
      },
    );

    test(
      'rejects negative attemptCountThreshold (cap is the count, not '
      'an offset)',
      () async {
        final pool = _RecordingPool();
        final repo = EventOutboxDeadLetterRepository(
          TenantTransactionWrapper(pool),
        );
        // ArgumentError throws synchronously before the Future is
        // returned; wrap in a closure so expectLater catches the
        // synchronous throw.
        expect(
          () => repo.moveFromOutbox(
            operatorId: _opA,
            locationId: _locA,
            eventId: '101',
            attemptCountThreshold: -1,
          ),
          throwsArgumentError,
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'rejects unknown reason values (must match the migration CHECK '
      'constraint)',
      () async {
        final pool = _RecordingPool();
        final repo = EventOutboxDeadLetterRepository(
          TenantTransactionWrapper(pool),
        );
        expect(
          () => repo.moveFromOutbox(
            operatorId: _opA,
            locationId: _locA,
            eventId: '101',
            attemptCountThreshold: 5,
            reason: 'arbitrary',
          ),
          throwsArgumentError,
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test('forced_dlq reason is accepted (post-V1 manual flow)', () async {
      final pool = _RecordingPool(returningId: '202');
      final repo = EventOutboxDeadLetterRepository(
        TenantTransactionWrapper(pool),
      );
      final movedId = await repo.moveFromOutbox(
        operatorId: _opA,
        locationId: _locA,
        eventId: '202',
        attemptCountThreshold: 0,
        reason: EventOutboxDeadLetterRepository.reasonForcedDlq,
      );
      expect(movedId, '202');
      final cteParams = pool.transactions.single.parameters.firstWhere(
        (p) => p.containsKey('reason'),
      );
      expect(
        cteParams['reason'],
        equals(EventOutboxDeadLetterRepository.reasonForcedDlq),
      );
    });
  });

  group('EventOutboxDeadLetterRepository.listByOperator', () {
    test(
      'projects rows in dead_lettered_at DESC order; payload + '
      'last_error normalize correctly',
      () async {
        final later = DateTime.utc(2026, 5, 4, 12);
        final earlier = DateTime.utc(2026, 5, 3, 11);
        final pool = _RecordingPool(
          listRows: <PostgresRow>[
            <String, Object?>{
              'id': '301',
              'operator_id': _opA,
              'topic': 'rollup.invalidate.variance_week',
              'payload': const <String, Object?>{
                'event_id': 'producer-uuid',
              },
              'created_at': later.subtract(const Duration(seconds: 30)),
              'attempt_count': 7,
              'last_error': 'pubsub publish 503',
              'dead_lettered_at': later,
              'dead_letter_reason': 'attempt_cap_exceeded',
            },
            <String, Object?>{
              'id': '302',
              'operator_id': _opA,
              'topic': 'auth.session.login',
              // Payload arrives as raw JSON String — the repo
              // normalizes it (matches event_outbox_repository
              // payload normalization).
              'payload': '{"event_id":"another-uuid"}',
              'created_at': earlier.subtract(const Duration(seconds: 30)),
              'attempt_count': 6,
              'last_error': null,
              'dead_lettered_at': earlier,
              'dead_letter_reason': 'attempt_cap_exceeded',
            },
          ],
        );
        final repo = EventOutboxDeadLetterRepository(
          TenantTransactionWrapper(pool),
        );
        final rows = await repo.listByOperator(
          operatorId: _opA,
          locationId: _locA,
          limit: 10,
        );
        expect(rows, hasLength(2));
        expect(rows.first.id, equals('301'));
        expect(rows.first.lastError, equals('pubsub publish 503'));
        expect(rows.first.payload['event_id'], equals('producer-uuid'));
        expect(rows.last.id, equals('302'));
        expect(rows.last.lastError, isNull);
        expect(rows.last.payload['event_id'], equals('another-uuid'));

        final tx = pool.transactions.single;
        // SET LOCAL on the read path too.
        expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
        // Server-side ordering for the admin SQL "latest first" view.
        final selectSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('from event_outbox_dead_letter'),
        );
        expect(selectSql, contains('order by dead_lettered_at desc'));
        expect(selectSql, contains('limit @limit'));
        // Tenant scoping in the predicate.
        expect(selectSql, contains('operator_id = @operator_id::uuid'));
      },
    );

    test('rejects non-positive limit', () async {
      final pool = _RecordingPool();
      final repo = EventOutboxDeadLetterRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.listByOperator(
          operatorId: _opA,
          locationId: _locA,
          limit: 0,
        ),
        throwsArgumentError,
      );
    });

    test(
      'malformed row shape (e.g. non-DateTime dead_lettered_at) throws '
      'StateError instead of a vague type-cast crash',
      () async {
        final pool = _RecordingPool(
          listRows: <PostgresRow>[
            <String, Object?>{
              'id': '401',
              'operator_id': _opA,
              'topic': 'auth.session.login',
              'payload': const <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 4),
              'attempt_count': 6,
              'last_error': null,
              // Wrong shape: string instead of DateTime.
              'dead_lettered_at': '2026-05-04',
              'dead_letter_reason': 'attempt_cap_exceeded',
            },
          ],
        );
        final repo = EventOutboxDeadLetterRepository(
          TenantTransactionWrapper(pool),
        );
        await expectLater(
          repo.listByOperator(
            operatorId: _opA,
            locationId: _locA,
            limit: 10,
          ),
          throwsStateError,
        );
      },
    );
  });

  group('EventOutboxDeadLetterRepository.countByOperator', () {
    test('returns the cnt as int', () async {
      final pool = _RecordingPool(
        countResult: 7,
      );
      final repo = EventOutboxDeadLetterRepository(
        TenantTransactionWrapper(pool),
      );
      final count = await repo.countByOperator(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(count, equals(7));
      final tx = pool.transactions.single;
      // SET LOCAL on the read path.
      expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
      final countSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('coalesce(count(*)'),
      );
      expect(countSql, contains('from event_outbox_dead_letter'));
      expect(countSql, contains('operator_id = @operator_id::uuid'));
    });

    test('zero rows returns 0', () async {
      final pool = _RecordingPool(countResult: 0);
      final repo = EventOutboxDeadLetterRepository(
        TenantTransactionWrapper(pool),
      );
      final count = await repo.countByOperator(
        operatorId: _opB,
        locationId: _locA,
      );
      expect(count, equals(0));
    });
  });
}

class _SimulatedDbFailure implements Exception {
  const _SimulatedDbFailure();
  @override
  String toString() => 'SimulatedDbFailure';
}

/// Recording fake `PostgresPool` shaped for the dead-letter
/// repository's three call shapes.
///
/// `returningId` controls what the MOVE CTE's `RETURNING id::text as
/// id` hands back; `null` simulates "row already filtered out" (zero
/// rows returned).
///
/// `listRows` controls what `listByOperator`'s SELECT returns.
///
/// `countResult` controls what `countByOperator`'s `count(*)` returns.
///
/// `throwOnQuery` simulates a DB failure mid-body so the test can
/// assert the rollback path runs.
class _RecordingPool implements PostgresPool {
  _RecordingPool({
    this.returningId,
    this.listRows = const <PostgresRow>[],
    this.countResult = 0,
    this.throwOnQuery,
  });

  final Object? returningId;
  final List<PostgresRow> listRows;
  final int countResult;
  final Exception? throwOnQuery;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      returningId: returningId,
      listRows: listRows,
      countResult: countResult,
      throwOnQuery: throwOnQuery,
    );
    transactions.add(tx);
    return tx;
  }
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    required this.returningId,
    required this.listRows,
    required this.countResult,
    this.throwOnQuery,
  });

  final Object? returningId;
  final List<PostgresRow> listRows;
  final int countResult;
  final Exception? throwOnQuery;
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
    if (sql.contains('with dead as') &&
        sql.contains('insert into event_outbox_dead_letter')) {
      if (throwOnQuery != null) throw throwOnQuery!;
      if (returningId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'id': returningId},
      ];
    }
    if (sql.contains('select') &&
        sql.contains('from event_outbox_dead_letter') &&
        sql.contains('order by dead_lettered_at desc')) {
      return listRows;
    }
    if (sql.contains('coalesce(count(*)') &&
        sql.contains('from event_outbox_dead_letter')) {
      return <PostgresRow>[
        <String, Object?>{'cnt': countResult},
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
    executedSql.add(sql);
    this.parameters.add(parameters);
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
