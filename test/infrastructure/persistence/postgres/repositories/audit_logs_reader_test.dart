// Lane B B8 — AuditLogsReader.listByHierarchy unit tests.
//
// Pins the read SQL shape + parameter binding for the three scope
// branches (operator_wide / org_unit / location) plus the actor /
// action / limit / before_id filters. The reader extends
// [OperatorScopedRepository] so every call routes through a tenant
// transaction; the fake pool below captures the SET LOCAL bookkeeping
// and the SELECT shape.
//
// What this file is NOT:
//   * Not a live Postgres test. The chain-integrity / RLS-policy
//     verification lives in `phase_9_0sigma_f_audit_chain_e2e_test`
//     and the live-binding suites. This file pins the in-process
//     repository contract that the proxy route depends on (parameter
//     names, scope-branch SQL composition, NULL location safeguards
//     on the org_unit branch).
//
// Coverage:
//   * operator_wide branch: SELECT does NOT join `locations`; the
//     `audit_logs.location_id is not null` guard does NOT appear.
//   * org_unit branch: SELECT joins `locations` on `org_unit_path <@`
//     and adds the `al.location_id is not null` guard.
//   * location branch: SELECT adds `al.location_id = @location_filter`.
//   * actor_user_id, action, before_id are bound when supplied.
//   * limit clamps to the maxLimit constant.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _orgUnitA = '33333333-3333-3333-3333-333333333333';
const String _locFilter = '44444444-4444-4444-4444-444444444444';
const String _actorA = '55555555-5555-5555-5555-555555555555';

void main() {
  group('AuditLogsReader.listByHierarchy', () {
    test('operator_wide branch emits a plain audit_logs SELECT with the '
        'time-range predicate and no location join', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      final sql = tx.lastSelectSql;
      expect(sql, contains('from public.audit_logs al '));
      expect(sql, isNot(contains('join public.locations')));
      expect(sql, contains('al.occurred_at >= @from'));
      expect(sql, contains('al.occurred_at <= @to'));
      expect(sql, contains('order by al.id desc'));
      expect(tx.lastParameters.containsKey('from'), isTrue);
      expect(tx.lastParameters.containsKey('to'), isTrue);
      expect(tx.lastParameters.containsKey('org_unit_id'), isFalse);
      expect(tx.lastParameters.containsKey('location_filter'), isFalse);
    });

    test('org_unit branch joins locations on the ltree subtree '
        'predicate and binds org_unit_id', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.orgUnit,
        orgUnitId: _orgUnitA,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      final sql = tx.lastSelectSql;
      expect(sql, contains('join public.locations l'));
      expect(sql, contains('l.org_unit_path <@'));
      expect(sql, contains('from public.org_units'));
      expect(sql, contains('al.location_id is not null'));
      expect(tx.lastParameters['org_unit_id'], _orgUnitA);
    });

    test('location branch adds the location_id predicate and binds '
        'location_filter', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.location,
        locationFilter: _locFilter,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      final sql = tx.lastSelectSql;
      expect(sql, contains('al.location_id = @location_filter::uuid'));
      expect(tx.lastParameters['location_filter'], _locFilter);
    });

    test('actor_user_id filter is bound when supplied', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        actorUserId: _actorA,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      expect(tx.lastSelectSql, contains('al.actor_user_id = @actor_user_id'));
      expect(tx.lastParameters['actor_user_id'], _actorA);
    });

    test('action filter is bound when supplied', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        action: 'auth.password_changed',
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      expect(tx.lastSelectSql, contains('al.action = @action'));
      expect(tx.lastParameters['action'], 'auth.password_changed');
    });

    test('before_id cursor is bound when supplied', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        beforeId: 999,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      expect(tx.lastSelectSql, contains('al.id < @before_id'));
      expect(tx.lastParameters['before_id'], 999);
    });

    test('limit clamps to maxLimit', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        limit: 10000,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      expect(tx.lastParameters['limit'], AuditLogsReader.maxLimit);
    });

    test('default limit applies when none supplied', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      expect(tx.lastParameters['limit'], AuditLogsReader.defaultLimit);
    });

    test('tenant SET LOCAL set_config calls bind operator/location/user '
        'ids before the SELECT', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        userId: _actorA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      // Find set_config statements in order; the SELECT must come
      // AFTER the SET LOCAL bindings.
      final operatorIdx = tx.executedSql.indexWhere(
        (s) => s.contains("set_config('app.operator_id'"),
      );
      final selectIdx = tx.executedSql.indexWhere(
        (s) => s.contains('select') && s.contains('from public.audit_logs'),
      );
      expect(operatorIdx, greaterThanOrEqualTo(0));
      expect(selectIdx, greaterThan(operatorIdx));
    });

    test('the reader maps the returned rows through AuditLogRow', () async {
      final pool = _RecordingPool(seedRows: <PostgresRow>[
        <String, Object?>{
          'id': '42',
          'operator_id': _opA,
          'location_id': _locA,
          'occurred_at': DateTime.utc(2026, 5, 13, 9),
          'actor_kind': 'user',
          'actor_user_id': _actorA,
          'actor_principal_id': null,
          'target_kind': 'user',
          'target_id': _actorA,
          'action': 'auth.password_changed',
          'payload_text': '{"hint": "demo"}',
          'admin_reason': null,
          'business_date': '2026-05-13',
          'chain_date': '2026-05-13',
        },
      ]);
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      final rows = await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.operatorWide,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13, 23),
      );
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.id, '42');
      expect(row.action, 'auth.password_changed');
      expect(row.payload['hint'], 'demo');
      expect(row.businessDate, '2026-05-13');
    });

    test('soft-deleted org_unit subqueries (the scope predicate) — '
        'the SELECT requires the scope path subquery to use deleted_at '
        'is null so a removed scope returns zero rows', () async {
      final pool = _RecordingPool();
      final reader = AuditLogsReader(TenantTransactionWrapper(pool));
      await reader.listByHierarchy(
        operatorId: _opA,
        locationId: _locA,
        scopeType: AuditLogHierarchyScope.orgUnit,
        orgUnitId: _orgUnitA,
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 13),
      );
      final tx = pool.transactions.single;
      // The inline subquery selecting the org_unit path must filter
      // soft-deleted scopes; otherwise a moved-then-deleted scope
      // could still match.
      expect(tx.lastSelectSql, contains('deleted_at is null'));
    });
  });

  group('AuditLogHierarchyScope wire codec', () {
    test('round-trips operator_wide / org_unit / location', () {
      for (final scope in AuditLogHierarchyScope.values) {
        final wire = auditLogHierarchyScopeWireName(scope);
        expect(auditLogHierarchyScopeFromWire(wire), scope);
      }
    });

    test('rejects unknown tokens', () {
      expect(auditLogHierarchyScopeFromWire('invalid'), isNull);
      expect(auditLogHierarchyScopeFromWire(null), isNull);
      expect(auditLogHierarchyScopeFromWire(''), isNull);
    });
  });
}

// ───────────────────────────────────────────────────────────────────
// Test scaffolding.
// ───────────────────────────────────────────────────────────────────

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({this.seedRows = const <PostgresRow>[]});

  final List<PostgresRow> seedRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  String get lastSelectSql => executedSql.firstWhere(
        (s) =>
            s.contains('select') && s.contains('from public.audit_logs'),
        orElse: () => throw StateError('no SELECT recorded'),
      );

  PostgresParameters get lastParameters {
    final idx = executedSql.indexWhere(
      (s) =>
          s.contains('select') && s.contains('from public.audit_logs'),
    );
    if (idx < 0) throw StateError('no SELECT recorded');
    return parameters[idx];
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.audit_logs')) {
      return seedRows;
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
    return 1;
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

class _RecordingPool implements PostgresPool {
  _RecordingPool({this.seedRows = const <PostgresRow>[]});

  final List<PostgresRow> seedRows;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(seedRows: seedRows);
    transactions.add(tx);
    return tx;
  }
}
