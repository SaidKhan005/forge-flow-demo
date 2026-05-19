import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/demo_mode_state_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _op = '11111111-1111-4111-8111-111111111111';
const String _loc = '22222222-2222-4222-8222-222222222222';
const String _actor = '33333333-3333-4333-8333-333333333333';

void main() {
  group('DemoModeStateRepository master switch', () {
    test('flips demo rows, audits, and completes proxy idempotency', () async {
      final pool = _FakePool()
        ..seed(category: IntegrationCategory.pos, isDemo: true)
        ..seed(category: IntegrationCategory.labor, isDemo: true)
        ..seed(category: IntegrationCategory.reservation, isDemo: false);
      final audit = _RecordingAuditLogsRepository();
      final repo = DemoModeStateRepository(
        TenantTransactionWrapper(pool),
        auditLogsRepository: audit,
      );

      final result = await repo.flipAllDemoRowsToLive(
        operatorId: _op,
        locationId: _loc,
        actorUserId: _actor,
        flippedAt: DateTime.utc(2026, 5, 13, 12),
        idempotencyKey: 'idem-demo-live',
        requestBodyHash: 'hash-live',
      );

      expect(result.flippedCount, 2);
      expect(result.records.every((record) => !record.isDemo), isTrue);
      expect(result.idempotentReplay, isFalse);
      expect(pool.committed, isTrue);
      expect(
        pool.executedSql.join('\n'),
        contains("set_config('app.operator_id'"),
      );
      final updateSql = pool.queries.singleWhere(
        (entry) => entry.sql.startsWith('update public.demo_mode_state'),
      );
      expect(updateSql.sql, contains('and is_demo = true'));
      expect(updateSql.sql, contains('pending_inserts_count = 0'));
      expect(updateSql.parameters['operator_id'], _op);
      expect(updateSql.parameters['location_id'], _loc);
      final idempotencyInsert = pool.queries.singleWhere(
        (entry) => entry.sql.contains('insert into public.proxy_requests'),
      );
      expect(idempotencyInsert.sql, contains('demo_mode_master_switch'));
      expect(
        idempotencyInsert.parameters['request_type'],
        'demo_mode.master_switch_to_live:hash-live',
      );
      final idempotencyComplete = pool.executeCalls.singleWhere(
        (entry) => entry.sql.contains('update public.proxy_requests'),
      );
      expect(
        idempotencyComplete.parameters['idempotency_key'],
        'idem-demo-live',
      );
      expect(
        jsonDecode(
          idempotencyComplete.parameters['response_payload']! as String,
        ),
        containsPair('flipped_count', 2),
      );

      expect(audit.calls, hasLength(1));
      final auditCall = audit.calls.single;
      expect(auditCall.operatorId, _op);
      expect(auditCall.locationId, _loc);
      expect(auditCall.actorKind, 'team_member');
      expect(auditCall.actorUserId, _actor);
      expect(auditCall.targetKind, 'demo_mode_state');
      expect(auditCall.targetId, _loc);
      expect(auditCall.action, demoModeMasterSwitchAction);
      expect(auditCall.payload['flipped_count'], 2);
      expect(
        auditCall.payload['categories_flipped'],
        containsAll(<String>['labor', 'pos']),
      );
      expect(auditCall.payload['operator_gate'], 'operator_owner');
      expect(auditCall.payload['idempotency_key'], 'idem-demo-live');
    });

    test(
      'returns live snapshot without reserving when already live and fresh key',
      () async {
        final pool = _FakePool()
          ..seed(category: IntegrationCategory.pos, isDemo: false);
        final audit = _RecordingAuditLogsRepository();
        final repo = DemoModeStateRepository(
          TenantTransactionWrapper(pool),
          auditLogsRepository: audit,
        );

        final result = await repo.flipAllDemoRowsToLive(
          operatorId: _op,
          locationId: _loc,
          actorUserId: _actor,
          flippedAt: DateTime.utc(2026, 5, 13, 12),
          idempotencyKey: 'idem-already-live',
          requestBodyHash: 'hash-live',
        );

        expect(result.flippedCount, 0);
        expect(result.records.single.category, IntegrationCategory.pos);
        expect(
          pool.queries.any(
            (entry) => entry.sql.startsWith('update public.demo_mode_state'),
          ),
          isFalse,
        );
        expect(
          pool.queries.any(
            (entry) => entry.sql.contains('insert into public.proxy_requests'),
          ),
          isFalse,
        );
        expect(audit.calls, isEmpty);
      },
    );

    test(
      'replays completed proxy_requests row across repository instances',
      () async {
        final pool = _FakePool()
          ..seed(category: IntegrationCategory.pos, isDemo: true)
          ..seed(category: IntegrationCategory.labor, isDemo: true);
        final firstAudit = _RecordingAuditLogsRepository();
        final firstRepo = DemoModeStateRepository(
          TenantTransactionWrapper(pool),
          auditLogsRepository: firstAudit,
        );

        final first = await firstRepo.flipAllDemoRowsToLive(
          operatorId: _op,
          locationId: _loc,
          actorUserId: _actor,
          flippedAt: DateTime.utc(2026, 5, 13, 12),
          idempotencyKey: 'idem-durable',
          requestBodyHash: 'hash-live',
        );

        final secondAudit = _RecordingAuditLogsRepository();
        final secondRepo = DemoModeStateRepository(
          TenantTransactionWrapper(pool),
          auditLogsRepository: secondAudit,
        );
        final replay = await secondRepo.flipAllDemoRowsToLive(
          operatorId: _op,
          locationId: _loc,
          actorUserId: _actor,
          flippedAt: DateTime.utc(2026, 5, 13, 12, 5),
          idempotencyKey: 'idem-durable',
          requestBodyHash: 'hash-live',
        );

        expect(first.flippedCount, 2);
        expect(replay.flippedCount, 2);
        expect(replay.idempotentReplay, isTrue);
        expect(firstAudit.calls, hasLength(1));
        expect(secondAudit.calls, isEmpty);
        expect(
          pool.queries
              .where(
                (entry) =>
                    entry.sql.startsWith('update public.demo_mode_state'),
              )
              .length,
          1,
        );
        expect(pool.proxyRequests, contains('$_op|$_loc|idem-durable'));
      },
    );

    test(
      'rejects same durable idempotency key with a different body hash',
      () async {
        final pool = _FakePool()
          ..seed(category: IntegrationCategory.pos, isDemo: true);
        final repo = DemoModeStateRepository(
          TenantTransactionWrapper(pool),
          auditLogsRepository: _RecordingAuditLogsRepository(),
        );
        await repo.flipAllDemoRowsToLive(
          operatorId: _op,
          locationId: _loc,
          actorUserId: _actor,
          flippedAt: DateTime.utc(2026, 5, 13, 12),
          idempotencyKey: 'idem-conflict',
          requestBodyHash: 'hash-live',
        );

        expect(
          () => repo.flipAllDemoRowsToLive(
            operatorId: _op,
            locationId: _loc,
            actorUserId: _actor,
            flippedAt: DateTime.utc(2026, 5, 13, 12, 1),
            idempotencyKey: 'idem-conflict',
            requestBodyHash: 'hash-other',
          ),
          throwsA(
            isA<DemoModeStateRepositoryRejected>()
                .having(
                  (error) => error.code,
                  'code',
                  'idempotency_key_conflict',
                )
                .having((error) => error.statusCode, 'statusCode', 409),
          ),
        );
      },
    );
  });
}

class _RecordingAuditLogsRepository extends AuditLogsRepository {
  final List<_AuditCall> calls = <_AuditCall>[];

  @override
  Future<void> writeRow(
    PostgresExecutor exec, {
    required String operatorId,
    String? locationId,
    DateTime? occurredAt,
    String? businessDate,
    required String actorKind,
    String? actorUserId,
    String? actorPrincipalId,
    String? targetKind,
    String? targetId,
    required String action,
    Map<String, Object?> payload = const <String, Object?>{},
    String? adminReason,
  }) async {
    calls.add(
      _AuditCall(
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: occurredAt,
        actorKind: actorKind,
        actorUserId: actorUserId,
        targetKind: targetKind,
        targetId: targetId,
        action: action,
        payload: Map<String, Object?>.from(payload),
      ),
    );
  }
}

class _AuditCall {
  const _AuditCall({
    required this.operatorId,
    required this.locationId,
    required this.occurredAt,
    required this.actorKind,
    required this.actorUserId,
    required this.targetKind,
    required this.targetId,
    required this.action,
    required this.payload,
  });

  final String operatorId;
  final String? locationId;
  final DateTime? occurredAt;
  final String actorKind;
  final String? actorUserId;
  final String? targetKind;
  final String? targetId;
  final String action;
  final Map<String, Object?> payload;
}

class _FakePool implements PostgresPool {
  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> proxyRequests =
      <String, Map<String, Object?>>{};
  final List<_QueryLog> queries = <_QueryLog>[];
  final List<_QueryLog> executeCalls = <_QueryLog>[];
  final List<String> executedSql = <String>[];
  bool committed = false;

  void seed({required IntegrationCategory category, required bool isDemo}) {
    rows[category.name] = <String, Object?>{
      'operator_id': _op,
      'location_id': _loc,
      'category': category.name,
      'is_demo': isDemo,
      'flipped_to_live_at': isDemo ? null : DateTime.utc(2026, 5, 12),
      'flipped_by_connection_id': null,
    };
  }

  @override
  Future<PostgresTransaction> beginTransaction() async => _FakeTx(this);
}

class _FakeTx implements PostgresTransaction {
  _FakeTx(this.pool);

  final _FakePool pool;

  @override
  Future<void> commit() async {
    pool.committed = true;
  }

  @override
  Future<void> rollback() async {}

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    pool.executedSql.add(sql);
    pool.executeCalls.add(_QueryLog(sql, parameters));
    if (sql.contains('update public.proxy_requests')) {
      final key = _proxyKey(parameters);
      final row = pool.proxyRequests[key];
      if (row == null) return 0;
      row['response_payload'] = parameters['response_payload'];
      return 1;
    }
    return 0;
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    pool.queries.add(_QueryLog(sql, parameters));
    if (sql.contains('from public.proxy_requests')) {
      final row = pool.proxyRequests[_proxyKey(parameters)];
      return row == null ? const <PostgresRow>[] : <PostgresRow>[row];
    }
    if (sql.contains('insert into public.proxy_requests')) {
      final key = _proxyKey(parameters);
      if (pool.proxyRequests.containsKey(key)) return const <PostgresRow>[];
      pool.proxyRequests[key] = <String, Object?>{
        'request_id': '44444444-4444-4444-8444-444444444444',
        'request_type': parameters['request_type'],
        'response_payload': null,
      };
      return const <PostgresRow>[
        <String, Object?>{'request_id': '44444444-4444-4444-8444-444444444444'},
      ];
    }
    if (sql.startsWith('select operator_id::text')) {
      return _orderedRows();
    }
    if (sql.startsWith('update public.demo_mode_state')) {
      final flipped = <PostgresRow>[];
      for (final row in _orderedRows()) {
        if (row['is_demo'] == true) {
          final category = row['category']!.toString();
          pool.rows[category] = <String, Object?>{
            ...pool.rows[category]!,
            'is_demo': false,
            'flipped_to_live_at': DateTime.parse(
              parameters['flipped_at']!.toString(),
            ).toUtc(),
            'flipped_by_connection_id': null,
          };
          flipped.add(Map<String, Object?>.from(pool.rows[category]!));
        }
      }
      return flipped;
    }
    return const <PostgresRow>[];
  }

  List<PostgresRow> _orderedRows() {
    final rows = pool.rows.values
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    rows.sort(
      (a, b) => a['category'].toString().compareTo(b['category'].toString()),
    );
    return rows;
  }

  static String _proxyKey(PostgresParameters parameters) =>
      '${parameters['operator_id']}|${parameters['location_id']}|'
      '${parameters['idempotency_key']}';
}

class _QueryLog {
  const _QueryLog(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}
