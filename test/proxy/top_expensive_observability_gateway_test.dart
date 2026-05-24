import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/observability_admin_models.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart';

const String _operatorA = '11111111-1111-4111-8111-111111111111';
const String _operatorB = '22222222-2222-4222-8222-222222222222';
const String _staffA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _workflowA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

void main() {
  group('RepositoryObservabilityAdminProxyGateway top_expensive', () {
    test('populates top spenders per axis on the 30d window', () async {
      final pool = _ObservabilityPool();
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 19, 12),
      );

      final envelope = await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorA,
      );

      final topExpensive = envelope['top_expensive'] as List<Object?>;
      // Not empty any more: 1 operator + 1 staff + 1 workflow row.
      expect(topExpensive, hasLength(3));

      // Every row maps onto the 30d window. The 1d / 7d windows are
      // intentionally never produced (usage_logs is a monthly rollup).
      for (final raw in topExpensive) {
        final row = raw as Map<String, Object?>;
        expect(row['window'], equals('30d'));
      }
      final windows = topExpensive
          .map((r) => (r as Map<String, Object?>)['window'])
          .toSet();
      expect(windows, equals(<Object?>{'30d'}));
      expect(windows.contains('1d'), isFalse);
      expect(windows.contains('7d'), isFalse);

      final byAxis = <String, Map<String, Object?>>{
        for (final raw in topExpensive)
          (raw as Map<String, Object?>)['axis'] as String: raw,
      };
      expect(
        byAxis.keys.toSet(),
        equals(<String>{'operator', 'staff', 'workflow'}),
      );

      // Operator axis: label is the business_name, id axes resolve to
      // the operator id only.
      final operatorRow = byAxis['operator']!;
      expect(operatorRow['label'], equals('Barrio Legado'));
      expect(operatorRow['operator_id'], equals(_operatorA));
      expect(operatorRow['staff_id'], isNull);
      expect(operatorRow['workflow_id'], isNull);
      expect(operatorRow['total_usd'], equals(42.5));
      expect(operatorRow['request_count'], equals(120));

      // Staff axis: no name table, so the label is the staff id text.
      final staffRow = byAxis['staff']!;
      expect(staffRow['axis'], equals('staff'));
      expect(staffRow['label'], equals(_staffA));
      expect(staffRow['staff_id'], equals(_staffA));
      expect(staffRow['workflow_id'], isNull);

      // Workflow axis: label is the workflow id text.
      final workflowRow = byAxis['workflow']!;
      expect(workflowRow['axis'], equals('workflow'));
      expect(workflowRow['label'], equals(_workflowA));
      expect(workflowRow['workflow_id'], equals(_workflowA));
      expect(workflowRow['staff_id'], isNull);

      // The consumer model parses these rows onto the 30d window.
      final parsed = <TopExpensiveEntry>[
        for (final raw in topExpensive)
          TopExpensiveEntry.fromJson((raw as Map).cast<String, Object?>()),
      ];
      expect(
        parsed.every((e) => e.window == ObservabilityWindow.thirtyDays),
        isTrue,
      );
      expect(
        parsed.any((e) => e.window == ObservabilityWindow.oneDay),
        isFalse,
      );
      expect(
        parsed.any((e) => e.window == ObservabilityWindow.sevenDays),
        isFalse,
      );

      // top_expensive is no longer advertised as a neutral-empty surface.
      final producerNotes = envelope['producer_notes'] as Map<String, Object?>;
      final neutralEmpty =
          producerNotes['neutral_empty_surfaces'] as List<Object?>;
      expect(neutralEmpty.contains('top_expensive'), isFalse);

      // Producer query shape: read-only, against usage_logs, honoring the
      // cross-operator predicate and the per-axis limit parameter.
      final tx = pool.transactions.single;
      final topQuery = tx.queries
          .where(
            (q) => q.sql.contains('union all') && q.sql.contains('by_operator'),
          )
          .single;
      expect(topQuery.sql.trimLeft().toLowerCase().startsWith('with'), isTrue);
      expect(topQuery.sql.toLowerCase(), isNot(contains('insert ')));
      expect(topQuery.sql.toLowerCase(), isNot(contains('update ')));
      expect(topQuery.sql.toLowerCase(), isNot(contains('delete ')));
      expect(topQuery.sql, contains('public.usage_logs'));
      expect(
        topQuery.sql,
        contains(
          '@operator_id::uuid is null or l.operator_id = @operator_id::uuid',
        ),
      );
      expect(topQuery.sql, contains("date_trunc('month', now())"));
      expect(topQuery.parameters['operator_id'], equals(_operatorA));
      expect(topQuery.parameters['axis_limit'], equals(10));
    });

    test(
      'cross-operator (All businesses) path passes operator_id null',
      () async {
        final pool = _ObservabilityPool();
        final gateway = RepositoryObservabilityAdminProxyGateway(
          adminWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 19, 12),
        );

        final envelope = await gateway.fetch(
          actorUserId: 'admin-user',
          adminReason: 'admin.observability.test',
          costTelemetryLimit: 10,
          // operatorId omitted == "All businesses".
        );

        // Cross-operator rows still land (the fake returns the same rows
        // regardless of scope; what matters is the null predicate flows).
        final topExpensive = envelope['top_expensive'] as List<Object?>;
        expect(topExpensive, isNotEmpty);

        final tx = pool.transactions.single;
        final topQuery = tx.queries
            .where(
              (q) =>
                  q.sql.contains('union all') && q.sql.contains('by_operator'),
            )
            .single;
        expect(topQuery.parameters['operator_id'], isNull);
      },
    );
  });
}

class _ObservabilityPool implements PostgresPool {
  final List<_ObservabilityTransaction> transactions =
      <_ObservabilityTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ObservabilityTransaction();
    transactions.add(tx);
    return tx;
  }
}

class _RecordedQuery {
  const _RecordedQuery({required this.sql, required this.parameters});

  final String sql;
  final PostgresParameters parameters;
}

class _ObservabilityTransaction extends PostgresTransaction {
  final List<_RecordedQuery> queries = <_RecordedQuery>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    queries.add(_RecordedQuery(sql: sql, parameters: parameters));
    if (sql.contains('union all') && sql.contains('by_operator')) {
      return <PostgresRow>[
        <String, Object?>{
          'axis': 'operator',
          'operator_id': _operatorA,
          'staff_id': null,
          'workflow_id': null,
          'label': 'Barrio Legado',
          'total_usd': 42.5,
          'request_count': 120,
        },
        <String, Object?>{
          'axis': 'staff',
          'operator_id': _operatorB,
          'staff_id': _staffA,
          'workflow_id': null,
          // label resolves to the staff id text in the producer SQL.
          'label': _staffA,
          'total_usd': 19.0,
          'request_count': 40,
        },
        <String, Object?>{
          'axis': 'workflow',
          'operator_id': _operatorB,
          'staff_id': null,
          'workflow_id': _workflowA,
          'label': _workflowA,
          'total_usd': 7.25,
          'request_count': 12,
        },
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
