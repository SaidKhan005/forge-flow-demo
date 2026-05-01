// Phase 9.UX.6 — AuthEventsAuditRepository.listForUser tests.
//
// Exercises the per-user read projection through a fake Postgres
// pool. Asserts: the WHERE clause pins user_id (RLS-deepens scope
// from per-tenant to per-user), the ORDER BY is descending, the
// LIMIT/OFFSET parameters bind correctly, and event_kind patterns
// translate into LIKE clauses.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opId = '11111111-1111-4111-8111-111111111111';
const String _locId = '22222222-2222-4222-8222-222222222222';
const String _userId = '33333333-3333-4333-8333-333333333333';

void main() {
  group('AuthEventsAuditRepository.listForUser', () {
    test(
      'WHERE pins operator_id (primary defense) so a miswired admin '
      'wrapper cannot broaden same-user reads across operators',
      () async {
        final pool = _AuditPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        await repo.listForUser(
          operatorId: _opId,
          locationId: _locId,
          userId: _userId,
          limit: 50,
          offset: 0,
        );
        final tx = pool.transactions.single;
        final selectIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('from auth_events_audit'),
        );
        expect(selectIndex, isNonNegative);
        final sql = tx.executedSql[selectIndex];
        expect(sql, contains('operator_id = @operator_id::uuid'));
        final params = tx.parameters[selectIndex];
        expect(params['operator_id'], equals(_opId));
      },
    );

    test(
      'date range (from/to) bounds occurred_at and binds parameters',
      () async {
        final pool = _AuditPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
        final from = DateTime.utc(2026, 4, 1);
        final to = DateTime.utc(2026, 4, 30, 23, 59, 59);
        await repo.listForUser(
          operatorId: _opId,
          locationId: _locId,
          userId: _userId,
          limit: 50,
          offset: 0,
          from: from,
          to: to,
        );
        final tx = pool.transactions.single;
        final selectIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('from auth_events_audit'),
        );
        final sql = tx.executedSql[selectIndex];
        expect(sql, contains('occurred_at >= @from'));
        expect(sql, contains('occurred_at <= @to'));
        final params = tx.parameters[selectIndex];
        expect(params['from'], equals(from));
        expect(params['to'], equals(to));
      },
    );

    test(
      'binds user_id, runs WHERE on actor or target user and orders DESC',
      () async {
        final pool = _AuditPool(
          rows: <PostgresRow>[
            <String, Object?>{
              'event_id': 'event-1',
              'event_type': 'auth.user.signed_in',
              'event_payload': '{"reason":"normal"}',
              'occurred_at': DateTime.utc(2026, 4, 30, 14),
              'ip': '203.0.113.10',
              'user_agent': 'Forge&Flow/1.0',
              'geo_country': 'CA',
              'request_id': 'req-1',
            },
            <String, Object?>{
              'event_id': 'event-2',
              'event_type': 'auth.password_changed',
              'event_payload': <String, Object?>{},
              'occurred_at': DateTime.utc(2026, 4, 29, 9),
              'ip': null,
              'user_agent': null,
              'geo_country': null,
              'request_id': null,
            },
          ],
        );
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));

        final rows = await repo.listForUser(
          operatorId: _opId,
          locationId: _locId,
          userId: _userId,
          limit: 50,
          offset: 0,
        );

        expect(rows, hasLength(2));
        expect(rows.first.eventId, equals('event-1'));
        expect(rows.first.eventType, equals('auth.user.signed_in'));
        expect(rows.first.payload, equals(<String, Object?>{'reason': 'normal'}));
        expect(rows.first.ip, equals('203.0.113.10'));
        // Empty / null nullable fields are projected to null, not blank
        // strings, so the UI can hide them cleanly.
        expect(rows[1].ip, isNull);
        expect(rows[1].userAgent, isNull);

        final tx = pool.transactions.single;
        // Find the SELECT against auth_events_audit (skipping the
        // SET LOCAL set_config(...) preamble).
        final selectIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('from auth_events_audit'),
        );
        expect(selectIndex, isNonNegative);
        final sql = tx.executedSql[selectIndex];
        // Acceptance: WHERE pins user_id on actor OR target so the
        // operator's own ledger covers both roles.
        expect(sql, contains('actor_user_id = @user_id::uuid'));
        expect(sql, contains('target_user_id = @user_id::uuid'));
        // Acceptance: ordered newest first.
        expect(sql, contains('order by occurred_at desc'));
        // Acceptance: LIMIT + OFFSET bind to the parameters.
        expect(sql, contains('limit @limit offset @offset'));
        final params = tx.parameters[selectIndex];
        expect(params['user_id'], equals(_userId));
        expect(params['limit'], equals(50));
        expect(params['offset'], equals(0));
      },
    );

    test(
      'event_type pattern filter ANDs LIKE clauses with the user_id pin',
      () async {
        final pool = _AuditPool();
        final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));

        await repo.listForUser(
          operatorId: _opId,
          locationId: _locId,
          userId: _userId,
          limit: 25,
          offset: 50,
          eventTypePatterns: const <String>['%password%', '%mfa%'],
        );

        final tx = pool.transactions.single;
        final selectIndex = tx.executedSql.indexWhere(
          (sql) => sql.contains('from auth_events_audit'),
        );
        final sql = tx.executedSql[selectIndex];
        expect(sql, contains('event_type like @pattern_0'));
        expect(sql, contains('event_type like @pattern_1'));
        // Patterns are OR'd together — sign-ins or password events
        // both match.
        expect(sql, contains(' or '));
        final params = tx.parameters[selectIndex];
        expect(params['pattern_0'], equals('%password%'));
        expect(params['pattern_1'], equals('%mfa%'));
        expect(params['limit'], equals(25));
        expect(params['offset'], equals(50));
      },
    );

    test('SET LOCAL pins app.user_id so per-user RLS engages', () async {
      final pool = _AuditPool();
      final repo = AuthEventsAuditRepository(TenantTransactionWrapper(pool));
      await repo.listForUser(
        operatorId: _opId,
        locationId: _locId,
        userId: _userId,
        limit: 50,
        offset: 0,
      );
      final tx = pool.transactions.single;
      // Acceptance: SET LOCAL of app.user_id with the actor's id is
      // present BEFORE the SELECT, so the per-user RLS policy admits
      // only the actor's own rows even if the WHERE were missing.
      final userIdIndex = tx.executedSql.indexWhere(
        (sql) => sql.contains("'app.user_id'"),
      );
      final selectIndex = tx.executedSql.indexWhere(
        (sql) => sql.contains('from auth_events_audit'),
      );
      expect(userIdIndex, isNonNegative);
      expect(selectIndex, isNonNegative);
      expect(userIdIndex, lessThan(selectIndex));
      expect(tx.parameters[userIdIndex]['value'], equals(_userId));
    });
  });
}

class _AuditPool implements PostgresPool {
  _AuditPool({this.rows = const <PostgresRow>[]});

  final List<PostgresRow> rows;
  final List<_AuditTransaction> transactions = <_AuditTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _AuditTransaction(rows: rows);
    transactions.add(tx);
    return tx;
  }
}

class _AuditTransaction extends PostgresTransaction {
  _AuditTransaction({required this.rows});

  final List<PostgresRow> rows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from auth_events_audit')) {
      // Re-encode JSON payloads as strings to mirror the package:postgres
      // text-mode return type that production code path also handles.
      return rows
          .map((r) {
            final clone = Map<String, Object?>.from(r);
            final p = clone['event_payload'];
            if (p is Map) {
              clone['event_payload'] = jsonEncode(p);
            }
            return clone;
          })
          .toList();
    }
    return <PostgresRow>[];
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
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
