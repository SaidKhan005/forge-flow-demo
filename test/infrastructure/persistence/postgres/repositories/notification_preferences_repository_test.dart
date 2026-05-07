// Phase 8 W2.B - canonical-path unit tests for
// NotificationPreferencesRepository.
//
// Coverage focus:
//   * upsert ON CONFLICT shape - 6-tuple with NULLS NOT DISTINCT.
//   * round-trip - upsert + listForUser shapes survive both ways.
//   * operator-scoped read excludes other operators' rows
//     (cross-tenant isolation simulated via fake pool).
//   * delete - hard delete; absence = catalog default.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/notification_preference.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/notification_preferences_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

PostgresRow _prefRow({
  String id = '99999999-9999-9999-9999-999999999999',
  String operatorId = _opA,
  String userId = _userA,
  String eventKey = 'notif.backfill.complete',
  String channel = 'push',
  String scopeKind = 'operator',
  String? scopeId,
  bool enabled = true,
}) {
  return <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'user_id': userId,
    'event_key': eventKey,
    'channel': channel,
    'scope_kind': scopeKind,
    'scope_id': scopeId,
    'enabled': enabled,
    'created_at': DateTime.utc(2026, 5, 7, 10),
    'updated_at': DateTime.utc(2026, 5, 7, 11),
  };
}

void main() {
  group('NotificationPreferencesRepository.upsert', () {
    test(
      'INSERT ... ON CONFLICT 6-tuple DO UPDATE rewrites enabled + '
      'updated_at; created_at preserved on conflict',
      () async {
        final pool = _Pool(upsertRows: <PostgresRow>[_prefRow()]);
        final repo = NotificationPreferencesRepository(
          TenantTransactionWrapper(pool),
        );
        final result = await repo.upsert(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          eventKey: 'notif.backfill.complete',
          channel: NotificationChannel.push,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
          enabled: true,
        );
        expect(result.eventKey, equals('notif.backfill.complete'));
        expect(result.channel, equals(NotificationChannel.push));
        expect(result.scopeKind, equals(NotificationScopeKind.operator));
        expect(result.scopeId, isNull);
        expect(result.enabled, isTrue);

        final tx = pool.transactions.single;
        final upsertSql = tx.executedSql.firstWhere(
            (s) => s.contains('insert into public.notification_preferences'));
        expect(
          upsertSql,
          contains('on conflict (operator_id, user_id, event_key, channel, '
              'scope_kind, scope_id)'),
        );
        expect(upsertSql, contains('do update set'));
        expect(upsertSql, contains('enabled = excluded.enabled'));
        expect(upsertSql, contains('updated_at = now()'));
        expect(
          upsertSql,
          isNot(contains('created_at = excluded.created_at')),
          reason:
              'created_at must be preserved on conflict so the audit trail '
              'shows the original creation time',
        );
        // Wire values bound parametrically.
        final params = tx.parameters
            .firstWhere((p) => p['event_key'] == 'notif.backfill.complete');
        expect(params['channel'], equals('push'));
        expect(params['scope_kind'], equals('operator'));
        expect(params['scope_id'], isNull);
        expect(params['enabled'], isTrue);
      },
    );

    test(
      'tenant SET LOCAL ordering precedes the upsert and never escalates '
      'to forge_admin (no BYPASSRLS path on this surface)',
      () async {
        final pool = _Pool(upsertRows: <PostgresRow>[_prefRow()]);
        final repo = NotificationPreferencesRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.upsert(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          eventKey: 'notif.backfill.complete',
          channel: NotificationChannel.push,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
          enabled: true,
        );
        final tx = pool.transactions.single;
        // Canonical SET LOCAL order: operator -> location -> user.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(tx.parameters[2]['value'], equals(_userA));
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
          reason:
              'notification_preferences has NO admin BYPASSRLS path - '
              'every read and write rides the per-user tenant SET LOCAL path',
        );
      },
    );

    test('throws StateError when the upsert RETURNING is empty (RLS denial)',
        () async {
      final pool = _Pool(upsertRows: const <PostgresRow>[]);
      final repo = NotificationPreferencesRepository(
        TenantTransactionWrapper(pool),
      );
      await expectLater(
        repo.upsert(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          eventKey: 'notif.audit.anchor_failure',
          channel: NotificationChannel.email,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
          enabled: false,
        ),
        throwsStateError,
      );
    });
  });

  group('NotificationPreferencesRepository.listForUser', () {
    test(
      'SELECT filters by operator_id + user_id and orders by '
      '(event_key, channel, scope_kind, scope_id)',
      () async {
        final pool = _Pool(
          listRows: <PostgresRow>[
            _prefRow(eventKey: 'notif.backfill.complete', channel: 'push'),
            _prefRow(eventKey: 'notif.backfill.complete', channel: 'email'),
          ],
        );
        final repo = NotificationPreferencesRepository(
          TenantTransactionWrapper(pool),
        );
        final rows = await repo.listForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows, hasLength(2));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
            (s) => s.contains('from public.notification_preferences'));
        expect(selectSql, contains('where operator_id = @operator_id::uuid'));
        expect(selectSql, contains('and user_id = @user_id::uuid'));
        expect(
          selectSql,
          contains(
              'order by event_key, channel, scope_kind, scope_id nulls first'),
        );
      },
    );

    test(
      'cross-tenant isolation: operator B querying with operator A\'s '
      'context returns no rows because the fake pool simulates RLS denial',
      () async {
        // Pool primed for operator A's row; operator B's read returns
        // no rows (production RLS would deny under the per-user tenant
        // SET LOCAL path).
        final poolA = _Pool(listRows: <PostgresRow>[_prefRow()]);
        final poolB = _Pool(listRows: const <PostgresRow>[]);
        final repoA = NotificationPreferencesRepository(
          TenantTransactionWrapper(poolA),
        );
        final repoB = NotificationPreferencesRepository(
          TenantTransactionWrapper(poolB),
        );
        final aRows = await repoA.listForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        final bRows = await repoB.listForUser(
          operatorId: _opB,
          locationId: _locA,
          userId: _userA,
        );
        expect(aRows, hasLength(1));
        expect(aRows.single.operatorId, equals(_opA));
        expect(
          bRows,
          isEmpty,
          reason:
              'operator B must never read operator A\'s rows; production '
              'RLS would deny, fake pool returns empty',
        );
        for (final pool in <_Pool>[poolA, poolB]) {
          final tx = pool.transactions.single;
          expect(
            tx.executedSql.where((s) => s.contains('set local role forge_admin')),
            isEmpty,
          );
          expect(tx.executedSql[0], contains("'app.operator_id'"));
        }
      },
    );
  });

  group('NotificationPreferencesRepository.delete', () {
    test(
      'DELETE uses IS NOT DISTINCT FROM on scope_id so operator-scope '
      'rows (scope_id=NULL) match cleanly',
      () async {
        final pool = _Pool(deleteAffected: 1);
        final repo = NotificationPreferencesRepository(
          TenantTransactionWrapper(pool),
        );
        final removed = await repo.delete(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          eventKey: 'notif.backfill.complete',
          channel: NotificationChannel.email,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
        );
        expect(removed, isTrue);

        final tx = pool.transactions.single;
        final deleteSql = tx.executedSql.firstWhere(
            (s) => s.contains('delete from public.notification_preferences'));
        expect(deleteSql, contains('where operator_id = @operator_id::uuid'));
        expect(deleteSql, contains('and user_id = @user_id::uuid'));
        expect(
          deleteSql,
          contains('and scope_id is not distinct from @scope_id::uuid'),
        );
      },
    );

    test('returns false when no row matched', () async {
      final pool = _Pool(deleteAffected: 0);
      final repo = NotificationPreferencesRepository(
        TenantTransactionWrapper(pool),
      );
      final removed = await repo.delete(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        eventKey: 'notif.backfill.complete',
        channel: NotificationChannel.email,
        scopeKind: NotificationScopeKind.operator,
        scopeId: null,
      );
      expect(removed, isFalse);
    });
  });
}

class _Pool implements PostgresPool {
  _Pool({
    this.upsertRows = const <PostgresRow>[],
    this.listRows = const <PostgresRow>[],
    this.deleteAffected = 0,
  });

  final List<PostgresRow> upsertRows;
  final List<PostgresRow> listRows;
  final int deleteAffected;
  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(
      upsertRows: upsertRows,
      listRows: listRows,
      deleteAffected: deleteAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({
    required this.upsertRows,
    required this.listRows,
    required this.deleteAffected,
  });

  final List<PostgresRow> upsertRows;
  final List<PostgresRow> listRows;
  final int deleteAffected;
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
    if (sql.contains('insert into public.notification_preferences')) {
      return upsertRows;
    }
    if (sql.contains('from public.notification_preferences')) {
      return listRows;
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
    if (sql.contains('delete from public.notification_preferences')) {
      return deleteAffected;
    }
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
