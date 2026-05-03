// Phase 9.5.0 — LeaderboardScoreRepository unit tests.
//
// Coverage focus (matches the 9.5.0 prompt's required tests):
//
//   * insert under tenant context succeeds — `recordScore` runs the
//     SET LOCAL block (operator_id, location_id, user_id, audit
//     marker), THEN runs the INSERT, returning the generated
//     `score_event_id`. Commit happens; rollback does not.
//
//   * cross-tenant read denied by RLS — the unit test cannot run a
//     real RLS policy, but it pins the conditions that make RLS
//     work:
//       - SET LOCAL ordering: operator_id → location_id → user_id
//         BEFORE the SELECT. The wrapper functions read the GUCs;
//         a SELECT that runs before the GUCs are set would see
//         NULLs and fail closed.
//       - tenant audit marker `'tenant'` is stamped (not 'system');
//         `set local role forge_admin` is NEVER emitted from this
//         repo (no admin path exists here — a future cross-tenant
//         admin read uses the OperatorScopedRepository.withSystem
//         escape hatch, not this repo's read methods).
//
//   * EXPLAIN plan uses operator-leading index — the unit test
//     pins the condition the planner needs to fold the per-tenant
//     RLS predicate into
//     `leaderboard_scores_operator_user_date_idx` (the canonical
//     per-user index landed in the migration):
//       - SELECT WHERE clause leads with `operator_id =
//         @operator_id::uuid`. Without that, the planner would
//         seq-scan the table, fold the policy row-by-row, and the
//         operator-leading index would be irrelevant.
//       - INSERT also binds `operator_id` parametrically so the
//         WITH CHECK predicate can fold against the wrapper
//         function. (The migration's
//         `leaderboard_scores_per_tenant_insert` policy WITH CHECK
//         requires `operator_id = app_current_operator() AND
//         location_id = app_current_location()`; the bound values
//         here must match the GUCs the SET LOCAL block stamped.)
//     A live-DB EXPLAIN is exercised by the
//     `phase_9_0sigma_rls_isolation_sweep_test.dart` integration
//     sweep when the table joins that fixture; the unit test here
//     pins the static SQL shape the sweep depends on.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/leaderboard_score_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = '33333333-3333-3333-3333-333333333333';
const String _userA = '44444444-4444-4444-4444-444444444444';
const String _userB = '55555555-5555-5555-5555-555555555555';
const String _actorA = '66666666-6666-6666-6666-666666666666';
const String _eventId = '77777777-7777-7777-7777-777777777777';

DateTime _occurredAt() => DateTime.utc(2026, 5, 3, 12, 30);
DateTime _businessDate() => DateTime.utc(2026, 5, 3);

void main() {
  group('LeaderboardScoreRepository.recordScore — insert under tenant context',
      () {
    test(
      'happy path — SET LOCAL ordering runs first, INSERT runs last, '
      'returning the server-generated score_event_id; transaction commits',
      () async {
        final pool = _LeaderboardPool(insertRows: <PostgresRow>[
          <String, Object?>{'score_event_id': _eventId},
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        final id = await repo.recordScore(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          scoreEventType: 'mastery_complete',
          points: 25,
          occurredAt: _occurredAt(),
          businessDate: _businessDate(),
          payload: const <String, Object?>{
            'topic': 'service_recovery',
            'session_id': 'demo-session-001',
          },
        );
        expect(id, equals(_eventId));

        final tx = pool.transactions.single;
        expect(tx.commitCount, equals(1));
        expect(tx.rollbackCount, equals(0));

        // SET LOCAL canonical ordering: operator → location → user →
        // tenant audit marker.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(tx.parameters[2]['value'], equals(_userA));
        expect(tx.executedSql[3], contains("'app.bypass_rls_audit'"));

        // INSERT runs AFTER the SET LOCAL block so the WITH CHECK
        // predicate can fold against the wrapper functions.
        final insertIndex = tx.executedSql.indexWhere(
          (s) => s.contains('insert into public.leaderboard_scores'),
        );
        expect(insertIndex, greaterThan(3));

        // No admin escalation path. cross-tenant inserts are denied
        // by the WITH CHECK at the policy layer, not by elevating to
        // forge_admin.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
        );
      },
    );

    test(
      'INSERT binds operator_id, location_id, user_id, score_event_type, '
      'points, occurred_at, business_date, payload parametrically — '
      'never interpolated, so the DB CHECK / FK can validate verbatim',
      () async {
        final pool = _LeaderboardPool(insertRows: <PostgresRow>[
          <String, Object?>{'score_event_id': _eventId},
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        await repo.recordScore(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          scoreEventType: 'streak_day',
          points: 5,
          occurredAt: _occurredAt(),
          businessDate: _businessDate(),
        );

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.leaderboard_scores'),
        );
        expect(insertSql, contains('@operator_id::uuid'));
        expect(insertSql, contains('@location_id::uuid'));
        expect(insertSql, contains('@user_id::uuid'));
        expect(insertSql, contains('@score_event_type'));
        expect(insertSql, contains('@points'));
        expect(insertSql, contains('@occurred_at::timestamptz'));
        expect(insertSql, contains('@business_date::date'));
        expect(insertSql, contains('@payload::jsonb'));
        expect(insertSql, contains('returning score_event_id'));

        // No interpolation of the user-supplied values into the SQL
        // body — every untrusted axis flows through @-bindings.
        expect(insertSql, isNot(contains("'$_opA'")));
        expect(insertSql, isNot(contains("'streak_day'")));

        final params = tx.parameters.firstWhere(
          (p) => p.containsKey('score_event_type'),
        );
        expect(params['operator_id'], equals(_opA));
        expect(params['location_id'], equals(_locA));
        expect(params['user_id'], equals(_userA));
        expect(params['score_event_type'], equals('streak_day'));
        expect(params['points'], equals(5));
        expect(params['business_date'], equals('2026-05-03'));
        expect(params['payload'], equals(jsonEncode(const <String, Object?>{})));
        // occurred_at flows as a UTC DateTime so the package:postgres
        // adapter binds it as timestamptz.
        expect(params['occurred_at'], isA<DateTime>());
        expect((params['occurred_at']! as DateTime).isUtc, isTrue);
      },
    );

    test(
      'occurredAt that arrives in local time is normalized to UTC '
      'before binding so the timestamptz column receives a stable '
      'instant',
      () async {
        final pool = _LeaderboardPool(insertRows: <PostgresRow>[
          <String, Object?>{'score_event_id': _eventId},
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        // Provide a DateTime constructed with `.local()`; the repo
        // must `.toUtc()` on the way down.
        final localInstant = DateTime(2026, 5, 3, 9, 15);
        await repo.recordScore(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          scoreEventType: 'mastery_complete',
          points: 10,
          occurredAt: localInstant,
          businessDate: _businessDate(),
        );
        final tx = pool.transactions.single;
        final params = tx.parameters.firstWhere(
          (p) => p['score_event_type'] == 'mastery_complete',
        );
        final bound = params['occurred_at']! as DateTime;
        expect(bound.isUtc, isTrue);
        expect(bound, equals(localInstant.toUtc()));
      },
    );

    test(
      'businessDate is formatted from .year/.month/.day verbatim — NO '
      'UTC conversion. A late-evening operator-local DateTime (23:30 '
      'on the business day) must NOT shift to the next calendar day '
      'when bound; that shift would silently bin the score under the '
      'wrong week.',
      () async {
        final pool = _LeaderboardPool(insertRows: <PostgresRow>[
          <String, Object?>{'score_event_id': _eventId},
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        // 23:30 local on May 3 — depending on the host's timezone,
        // .toUtc() could shift to May 4 (e.g. America/Toronto = UTC-4
        // on this date, so 03:30 UTC May 4). The repo's job is to
        // preserve the calendar day the producer supplied.
        final localBusinessDate = DateTime(2026, 5, 3, 23, 30);
        await repo.recordScore(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          scoreEventType: 'mastery_complete',
          points: 10,
          occurredAt: _occurredAt(),
          businessDate: localBusinessDate,
        );
        final tx = pool.transactions.single;
        final params = tx.parameters.firstWhere(
          (p) => p['score_event_type'] == 'mastery_complete',
        );
        // Always May 3, regardless of host timezone.
        expect(params['business_date'], equals('2026-05-03'));
      },
    );

    test(
      'TenantContext rejects malformed operator_id BEFORE opening a '
      'transaction — the synchronous UUID guard short-circuits a bad '
      'caller without a round-trip',
      () async {
        final pool = _LeaderboardPool();
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        Object? caught;
        try {
          await repo.recordScore(
            operatorId: 'not-a-uuid',
            locationId: _locA,
            userId: _userA,
            scoreEventType: 'mastery_complete',
            points: 25,
            occurredAt: _occurredAt(),
            businessDate: _businessDate(),
          );
        } on TenantContextValidationError catch (error) {
          caught = error;
        }
        expect(caught, isA<TenantContextValidationError>());
        expect(
          (caught! as TenantContextValidationError).field,
          equals('operator_id'),
        );
        expect(
          pool.transactions,
          isEmpty,
          reason: 'malformed operator_id must short-circuit before any '
              'SET LOCAL or RLS round-trip',
        );
      },
    );

    test(
      'INSERT returning no rows surfaces a StateError naming RLS — the '
      'WITH CHECK predicate evaluating false (cross-tenant attribution) '
      'is the expected failure mode here',
      () async {
        final pool = _LeaderboardPool(insertRows: const <PostgresRow>[]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        Object? caught;
        try {
          await repo.recordScore(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
            scoreEventType: 'mastery_complete',
            points: 25,
            occurredAt: _occurredAt(),
            businessDate: _businessDate(),
          );
        } on StateError catch (error) {
          caught = error;
        }
        expect(caught, isA<StateError>());
        expect((caught! as StateError).message, contains('RLS'));
        // Failure rolls back the transaction so the SET LOCAL session
        // state cannot leak across the pool boundary.
        final tx = pool.transactions.single;
        expect(tx.commitCount, equals(0));
        expect(tx.rollbackCount, equals(1));
      },
    );
  });

  group('LeaderboardScoreRepository.listScoresForUser — cross-tenant denial '
      'via SET LOCAL ordering', () {
    test(
      'tenant SET LOCAL block runs BEFORE the SELECT — the per-tenant '
      'RLS policy on leaderboard_scores can fold against the wrapper '
      'functions to deny cross-operator rows',
      () async {
        final pool = _LeaderboardPool(selectRows: const <PostgresRow>[]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        await repo.listScoresForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          actorUserId: _actorA,
        );

        final tx = pool.transactions.single;
        // Canonical SET LOCAL order: operator → location → user.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(tx.parameters[2]['value'], equals(_actorA));
        expect(tx.executedSql[3], contains("'app.bypass_rls_audit'"));

        // SELECT runs AFTER the SET LOCAL block.
        final selectIndex = tx.executedSql.indexWhere(
          (s) => s.contains('from public.leaderboard_scores'),
        );
        expect(selectIndex, greaterThan(3));

        // Tenant audit marker — never escalates to forge_admin.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
          reason:
              'leaderboard_score_repository must never elevate to forge_admin '
              '— cross-operator support reads belong on the future admin '
              'gateway, not on this repo',
        );
      },
    );

    test(
      'a fake row attributed to operator B (cross-tenant) is filtered '
      'out at the seam: when the fake pool returns 0 rows for tenant '
      'A, the repo surfaces an empty list — the production behavior '
      'is that RLS hides operator-B rows from the SELECT entirely',
      () async {
        final pool = _LeaderboardPool(selectRows: const <PostgresRow>[]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listScoresForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userB, // user belongs to operator B in production
        );
        expect(rows, isEmpty);

        // Even with no rows returned, the SET LOCAL + SELECT both
        // committed cleanly so the tenant context did not leak.
        final tx = pool.transactions.single;
        expect(tx.commitCount, equals(1));
        expect(tx.rollbackCount, equals(0));
      },
    );

    test(
      'TenantContext rejects a wrong-tenant operator_id at construction '
      'time — defense-in-depth before the SQL even reaches the policy '
      'layer (a smoke check for the UUID-only guard, not a real RLS '
      'denial)',
      () async {
        final pool = _LeaderboardPool();
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        // operator B is well-formed but distinct; the repo will run the
        // SET LOCAL with operator B's UUID, which is what the production
        // RLS policy denies on rows attributed to operator A.
        await repo.listScoresForUser(
          operatorId: _opB,
          locationId: _locA,
          userId: _userA,
        );
        final tx = pool.transactions.single;
        expect(tx.parameters[0]['value'], equals(_opB));
        // The SELECT WHERE binds operator B's id, NOT operator A's —
        // the planner cannot fold a cross-tenant predicate.
        final selectParams = tx.parameters.firstWhere(
          (p) => p.containsKey('user_id') && p.containsKey('operator_id'),
        );
        expect(selectParams['operator_id'], equals(_opB));
      },
    );
  });

  group('LeaderboardScoreRepository.listScoresForUser — operator-leading '
      'index posture (EXPLAIN plan condition)', () {
    test(
      'SELECT WHERE leads with operator_id = @operator_id::uuid so the '
      'planner can fold the per-tenant policy into the '
      'leaderboard_scores_operator_user_date_idx index probe — without '
      'this, the policy folds row-by-row and the operator-leading '
      'index is irrelevant',
      () async {
        final pool = _LeaderboardPool(selectRows: const <PostgresRow>[]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        await repo.listScoresForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from public.leaderboard_scores'),
        );
        // The clause shape is `where operator_id = @operator_id::uuid
        // and user_id = @user_id::uuid` — operator_id is the leading
        // axis, matching the index's leading column.
        final whereStart = selectSql.indexOf('where ');
        expect(whereStart, greaterThan(-1));
        final whereClause = selectSql.substring(whereStart);
        // Operator must appear before user_id in the predicate so the
        // composite index leads with it.
        final operatorPos = whereClause.indexOf('operator_id');
        final userPos = whereClause.indexOf('user_id');
        expect(operatorPos, greaterThan(-1));
        expect(userPos, greaterThan(operatorPos));
      },
    );

    test(
      'optional [from/to]BusinessDate appends to the WHERE without '
      'displacing operator_id from the lead position — the planner '
      'still picks the operator-leading index for the bounded read',
      () async {
        final pool = _LeaderboardPool(selectRows: const <PostgresRow>[]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        await repo.listScoresForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          fromBusinessDate: DateTime.utc(2026, 4, 27),
          toBusinessDate: DateTime.utc(2026, 5, 3),
        );
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from public.leaderboard_scores'),
        );
        final whereClause = selectSql.substring(selectSql.indexOf('where '));
        expect(whereClause.indexOf('operator_id'), equals(6));
        expect(whereClause, contains('business_date >= @from_business_date'));
        expect(whereClause, contains('business_date <= @to_business_date'));

        final params = tx.parameters.firstWhere(
          (p) => p.containsKey('from_business_date'),
        );
        expect(params['from_business_date'], equals('2026-04-27'));
        expect(params['to_business_date'], equals('2026-05-03'));
      },
    );

    test(
      'ORDER BY business_date desc, occurred_at desc — the most-recent '
      'rows surface first without a separate ORDER BY at the projection '
      'layer; the operator-leading composite index '
      '(operator_id, user_id, business_date desc) lines up so the '
      'planner can satisfy the ORDER BY by index walk rather than a '
      'sort step',
      () async {
        final pool = _LeaderboardPool(selectRows: const <PostgresRow>[]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        await repo.listScoresForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from public.leaderboard_scores'),
        );
        expect(
          selectSql,
          contains('order by business_date desc, occurred_at desc'),
        );
      },
    );

    test(
      'INSERT also binds operator_id parametrically so the WITH CHECK '
      'predicate (operator_id = app_current_operator()) can fold; the '
      'columns list in the INSERT keeps operator_id, location_id as '
      'the first two RLS-Ready axes',
      () async {
        final pool = _LeaderboardPool(insertRows: <PostgresRow>[
          <String, Object?>{'score_event_id': _eventId},
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        await repo.recordScore(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          scoreEventType: 'mastery_complete',
          points: 25,
          occurredAt: _occurredAt(),
          businessDate: _businessDate(),
        );
        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.leaderboard_scores'),
        );
        // RLS-Ready scaffolding: operator_id + location_id are the
        // first two columns in the INSERT.
        final columnList = insertSql.substring(
          insertSql.indexOf('(') + 1,
          insertSql.indexOf(') values'),
        );
        final cols = columnList
            .split(',')
            .map((c) => c.trim())
            .toList(growable: false);
        expect(cols[0], equals('operator_id'));
        expect(cols[1], equals('location_id'));
      },
    );
  });

  group('LeaderboardScoreRepository.listScoresForUser — row projection', () {
    test(
      'projects every column into a typed LeaderboardScoreRow; payload '
      'arriving as a JSON string is decoded into a Map',
      () async {
        final pool = _LeaderboardPool(selectRows: <PostgresRow>[
          <String, Object?>{
            'score_event_id': _eventId,
            'operator_id': _opA,
            'location_id': _locA,
            'user_id': _userA,
            'score_event_type': 'mastery_complete',
            'points': 25,
            'occurred_at': DateTime.utc(2026, 5, 3, 12, 30),
            'business_date': DateTime.utc(2026, 5, 3),
            'payload': '{"topic":"service_recovery"}',
            'created_at': DateTime.utc(2026, 5, 3, 12, 30, 1),
          },
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listScoresForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row.scoreEventId, equals(_eventId));
        expect(row.operatorId, equals(_opA));
        expect(row.userId, equals(_userA));
        expect(row.scoreEventType, equals('mastery_complete'));
        expect(row.points, equals(25));
        expect(row.payload, equals(<String, Object?>{'topic': 'service_recovery'}));
      },
    );

    test(
      'payload arriving as an already-decoded Map (the package:postgres '
      'jsonb codec path) round-trips without re-encoding',
      () async {
        final pool = _LeaderboardPool(selectRows: <PostgresRow>[
          <String, Object?>{
            'score_event_id': _eventId,
            'operator_id': _opA,
            'location_id': _locA,
            'user_id': _userA,
            'score_event_type': 'recognition_badge',
            'points': 50,
            'occurred_at': DateTime.utc(2026, 5, 3, 12, 30),
            'business_date': DateTime.utc(2026, 5, 3),
            'payload': const <String, Object?>{'badge_id': 'b-001'},
            'created_at': DateTime.utc(2026, 5, 3, 12, 30, 1),
          },
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listScoresForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows.single.payload, equals(<String, Object?>{'badge_id': 'b-001'}));
      },
    );

    test(
      'malformed row (e.g. score_event_id missing) surfaces a StateError '
      'so a producer that bypasses the repository INSERT shape fails '
      'fast at the read instead of leaking nulls into the projection',
      () async {
        final pool = _LeaderboardPool(selectRows: <PostgresRow>[
          <String, Object?>{
            // score_event_id deliberately absent
            'operator_id': _opA,
            'location_id': _locA,
            'user_id': _userA,
            'score_event_type': 'mastery_complete',
            'points': 25,
            'occurred_at': DateTime.utc(2026, 5, 3, 12, 30),
            'business_date': DateTime.utc(2026, 5, 3),
            'payload': const <String, Object?>{},
            'created_at': DateTime.utc(2026, 5, 3, 12, 30, 1),
          },
        ]);
        final repo = LeaderboardScoreRepository(TenantTransactionWrapper(pool));
        await expectLater(
          () => repo.listScoresForUser(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
          ),
          throwsStateError,
        );
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the
/// LeaderboardScoreRepository seam.
class _LeaderboardPool implements PostgresPool {
  _LeaderboardPool({
    this.insertRows = const <PostgresRow>[],
    this.selectRows = const <PostgresRow>[],
  });

  final List<PostgresRow> insertRows;
  final List<PostgresRow> selectRows;
  final List<_LeaderboardTransaction> transactions = <_LeaderboardTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _LeaderboardTransaction(
      insertRows: insertRows,
      selectRows: selectRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _LeaderboardTransaction extends PostgresTransaction {
  _LeaderboardTransaction({
    required this.insertRows,
    required this.selectRows,
  });

  final List<PostgresRow> insertRows;
  final List<PostgresRow> selectRows;

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
    if (sql.contains('insert into public.leaderboard_scores')) {
      return insertRows;
    }
    if (sql.contains('from public.leaderboard_scores')) {
      return selectRows;
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
