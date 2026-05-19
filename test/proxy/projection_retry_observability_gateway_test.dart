import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationA = '22222222-2222-4222-8222-222222222222';
const String _locationB = '33333333-3333-4333-8333-333333333333';

void main() {
  group('RepositoryObservabilityAdminProxyGateway projection retries', () {
    test('returns counts and bounded recent plus dead-letter rows', () async {
      final pool = _ObservabilityPool();
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
      );

      final envelope = await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorId,
        locationIds: <String>[_locationA, _locationB],
      );

      final projectionRetries =
          envelope['projection_retries'] as Map<String, Object?>;
      expect(
        projectionRetries['status_counts'],
        equals(<String, Object?>{
          'pending': 12,
          'running': 4,
          'succeeded': 0,
          'dead_lettered': 3,
        }),
      );

      final recent = projectionRetries['recent_active'] as List<Object?>;
      final deadLettered = projectionRetries['dead_lettered'] as List<Object?>;
      expect(recent, hasLength(25));
      expect(deadLettered, hasLength(25));

      final recentFirst = recent.first as Map<String, Object?>;
      expect(recentFirst['status'], equals('pending'));
      expect(recentFirst['job_id'], equals('active-0'));
      expect(
        recentFirst['next_attempt_at'],
        equals('2026-05-19T12:00:00.000Z'),
      );
      expect(recentFirst.containsKey('changed_periods'), isFalse);
      expect(recentFirst.containsKey('open_current_fact_maps'), isFalse);

      final deadFirst = deadLettered.first as Map<String, Object?>;
      expect(deadFirst['status'], equals('dead_lettered'));
      expect(deadFirst['dead_lettered_at'], equals('2026-05-19T12:00:00.000Z'));

      final limits = projectionRetries['limits'] as Map<String, Object?>;
      expect(limits['recent_active'], equals(25));
      expect(limits['dead_lettered'], equals(25));

      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      expect(
        tx.executedSql.where((sql) => sql == 'set local role forge_admin'),
        hasLength(1),
      );
      expect(
        tx.executedParameters.any(
          (params) => params['value'] == 'system:admin.observability.test',
        ),
        isTrue,
      );

      final projectionQueries = tx.queries
          .where(
            (query) =>
                query.sql.contains('canonical_fact_projection_retry_jobs'),
          )
          .toList();
      expect(projectionQueries, hasLength(3));
      for (final query in projectionQueries) {
        expect(query.sql.trimLeft().startsWith('select'), isTrue);
        expect(query.sql.toLowerCase(), isNot(contains('insert ')));
        expect(query.sql.toLowerCase(), isNot(contains('update ')));
        expect(query.sql.toLowerCase(), isNot(contains('delete ')));
        expect(query.parameters['operator_id'], equals(_operatorId));
        expect(
          query.parameters['location_ids'],
          equals(<String>[_locationA, _locationB]),
        );
      }
      expect(
        projectionQueries
            .where((query) => query.sql.contains('limit @limit::int'))
            .map((query) => query.parameters['limit'])
            .toList(),
        equals(<Object?>[25, 25]),
      );
    });
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
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> executedParameters = <PostgresParameters>[];
  final List<_RecordedQuery> queries = <_RecordedQuery>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    queries.add(_RecordedQuery(sql: sql, parameters: parameters));
    if (sql.contains('canonical_fact_projection_retry_jobs') &&
        sql.contains('group by status')) {
      return const <PostgresRow>[
        <String, Object?>{'status': 'pending', 'count': 12},
        <String, Object?>{'status': 'running', 'count': 4},
        <String, Object?>{'status': 'dead_lettered', 'count': 3},
      ];
    }
    if (sql.contains('canonical_fact_projection_retry_jobs') &&
        sql.contains("status in ('pending', 'running')")) {
      return _projectionRows(
        status: 'pending',
        prefix: 'active',
      ).take(parameters['limit'] as int).toList();
    }
    if (sql.contains('canonical_fact_projection_retry_jobs') &&
        sql.contains("status = 'dead_lettered'")) {
      return _projectionRows(
        status: 'dead_lettered',
        prefix: 'dead',
        deadLettered: true,
      ).take(parameters['limit'] as int).toList();
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
    executedParameters.add(parameters);
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

List<PostgresRow> _projectionRows({
  required String status,
  required String prefix,
  bool deadLettered = false,
}) {
  final base = DateTime.utc(2026, 5, 19, 12);
  return <PostgresRow>[
    for (var i = 0; i < 30; i++)
      <String, Object?>{
        'job_id': '$prefix-$i',
        'operator_id': _operatorId,
        'location_id': i.isEven ? _locationA : _locationB,
        'restaurant_id': 'restaurant-$i',
        'connection_id': 'connection-$i',
        'vendor_id': 'toast',
        'category': 'pos',
        'status': status,
        'fact_count': i + 1,
        'attempt_count': deadLettered ? 5 : 1,
        'worker_id': deadLettered ? null : 'worker-1',
        'claimed_at': deadLettered ? null : base.subtract(Duration(minutes: i)),
        'next_attempt_at': base.add(Duration(minutes: i)),
        'created_at': base.subtract(Duration(hours: i + 1)),
        'updated_at': base.subtract(Duration(minutes: i)),
        'completed_at': null,
        'dead_lettered_at': deadLettered
            ? base.subtract(Duration(minutes: i))
            : null,
        'input_hash': 'a' * 64,
        'last_error_class': 'ProjectionFailure',
        'last_error_message': 'failed projector replay $i',
        'stack_first_frame': 'package:forge_and_flow/projector.dart:$i',
      },
  ];
}
