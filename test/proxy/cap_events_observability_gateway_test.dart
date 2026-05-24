import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/observability_admin_models.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart';

const String _operatorA = '11111111-1111-4111-8111-111111111111';
const String _operatorB = '22222222-2222-4222-8222-222222222222';
const String _locationA = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const String _eventA = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const String _eventB = 'ffffffff-ffff-4fff-8fff-ffffffffffff';

void main() {
  group('RepositoryObservabilityAdminProxyGateway cap_events', () {
    test('populates recent cap-refusal events from usage_cap_events', () async {
      final pool = _ObservabilityPool(capEventRows: _twoCapEventRows());
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 24, 12),
      );

      final envelope = await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorA,
      );

      final capEvents = envelope['cap_events'] as List<Object?>;
      expect(capEvents, hasLength(2));

      // First row: a refusal attributed to operator A at a location.
      final first = capEvents.first as Map<String, Object?>;
      expect(first['event_id'], equals(_eventA));
      expect(first['operator_id'], equals(_operatorA));
      expect(first['business_name'], equals('Barrio Legado'));
      expect(first['usage_class'], equals('advisor'));
      expect(first['query_class'], equals('advisor_chat'));
      expect(first['cap_usd'], equals(5.0));
      expect(first['attempted_usd'], equals(6.25));
      expect(first['location_id'], equals(_locationA));
      // occurred_at round-trips to an ISO-8601 UTC instant (NOT NULL).
      expect(
        first['occurred_at'],
        equals(DateTime.utc(2026, 5, 24, 11, 30).toIso8601String()),
      );

      // Second row: a refusal for a different operator with no location
      // returned by the fake (the column is NOT NULL on the real table,
      // but the mapper emits it as a nullable field; a null fake value
      // proves the null-safe path).
      final second = capEvents[1] as Map<String, Object?>;
      expect(second['event_id'], equals(_eventB));
      expect(second['operator_id'], equals(_operatorB));
      expect(second['business_name'], equals('North Loop'));
      expect(second['cap_usd'], equals(20.0));
      expect(second['attempted_usd'], equals(33.5));
      expect(second['location_id'], isNull);

      // No staff/workflow axes: the table carries no such columns.
      expect(first.containsKey('staff_id'), isFalse);
      expect(first.containsKey('workflow_id'), isFalse);

      // The consumer model parses these rows cleanly.
      final parsed = <CapEvent>[
        for (final raw in capEvents)
          CapEvent.fromJson((raw as Map).cast<String, Object?>()),
      ];
      expect(parsed.first.eventId, equals(_eventA));
      expect(parsed.first.businessName, equals('Barrio Legado'));
      expect(parsed.first.capUsd, equals(5.0));
      expect(parsed.first.attemptedUsd, equals(6.25));
      expect(parsed.first.locationId, equals(_locationA));
      expect(
        parsed.first.occurredAt,
        equals(DateTime.utc(2026, 5, 24, 11, 30)),
      );
      expect(parsed[1].locationId, isNull);

      // cap_events is no longer advertised as a neutral-empty surface.
      final producerNotes = envelope['producer_notes'] as Map<String, Object?>;
      final neutralEmpty =
          producerNotes['neutral_empty_surfaces'] as List<Object?>;
      expect(neutralEmpty.contains('cap_events'), isFalse);

      // Producer query shape: read-only SELECT against usage_cap_events,
      // joined to operators, honoring the cross-operator predicate, the
      // occurred_at ordering, and the row-cap limit parameter.
      final tx = pool.transactions.single;
      final capQuery = tx.queries
          .where((q) => q.sql.contains('public.usage_cap_events'))
          .single;
      final lowerSql = capQuery.sql.toLowerCase();
      expect(lowerSql.trimLeft().startsWith('select'), isTrue);
      expect(lowerSql, isNot(contains('insert ')));
      expect(lowerSql, isNot(contains('update ')));
      expect(lowerSql, isNot(contains('delete ')));
      expect(capQuery.sql, contains('public.operators'));
      expect(
        capQuery.sql,
        contains(
          '@operator_id::uuid is null or e.operator_id = @operator_id::uuid',
        ),
      );
      expect(capQuery.sql, contains('order by e.occurred_at desc'));
      expect(capQuery.parameters['operator_id'], equals(_operatorA));
      expect(capQuery.parameters['limit'], equals(50));
    });

    test('empty usage_cap_events table yields an empty cap_events list',
        () async {
      final pool = _ObservabilityPool(capEventRows: const <PostgresRow>[]);
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 24, 12),
      );

      final envelope = await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorA,
      );

      // No rows in the ledger == honest "no limit hits" (empty list),
      // NOT a fabricated row.
      final capEvents = envelope['cap_events'] as List<Object?>;
      expect(capEvents, isEmpty);

      // Even with no rows, the surface is no longer advertised as
      // neutral-empty: it is a live producer that happens to have no
      // data yet (the write path lands in a later slice).
      final producerNotes = envelope['producer_notes'] as Map<String, Object?>;
      final neutralEmpty =
          producerNotes['neutral_empty_surfaces'] as List<Object?>;
      expect(neutralEmpty.contains('cap_events'), isFalse);
    });

    test('cross-operator (All businesses) path passes operator_id null',
        () async {
      final pool = _ObservabilityPool(capEventRows: _twoCapEventRows());
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 24, 12),
      );

      await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        // operatorId omitted == "All businesses".
      );

      final tx = pool.transactions.single;
      final capQuery = tx.queries
          .where((q) => q.sql.contains('public.usage_cap_events'))
          .single;
      expect(capQuery.parameters['operator_id'], isNull);
    });
  });
}

List<PostgresRow> _twoCapEventRows() => <PostgresRow>[
      <String, Object?>{
        'event_id': _eventA,
        'occurred_at': DateTime.utc(2026, 5, 24, 11, 30),
        'operator_id': _operatorA,
        'location_id': _locationA,
        'usage_class': 'advisor',
        'query_class': 'advisor_chat',
        'cap_usd': 5.0,
        'attempted_usd': 6.25,
        'business_name': 'Barrio Legado',
      },
      <String, Object?>{
        'event_id': _eventB,
        'occurred_at': DateTime.utc(2026, 5, 24, 9, 15),
        'operator_id': _operatorB,
        'location_id': null,
        'usage_class': 'embedding',
        'query_class': 'corpus_embed',
        'cap_usd': 20.0,
        'attempted_usd': 33.5,
        'business_name': 'North Loop',
      },
    ];

class _ObservabilityPool implements PostgresPool {
  _ObservabilityPool({required this.capEventRows});

  final List<PostgresRow> capEventRows;
  final List<_ObservabilityTransaction> transactions =
      <_ObservabilityTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ObservabilityTransaction(capEventRows: capEventRows);
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
  _ObservabilityTransaction({required this.capEventRows});

  final List<PostgresRow> capEventRows;
  final List<_RecordedQuery> queries = <_RecordedQuery>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    queries.add(_RecordedQuery(sql: sql, parameters: parameters));
    if (sql.contains('public.usage_cap_events')) {
      return capEventRows;
    }
    // Every other producer query (cost, cache, model mix, dormancy,
    // graph, projection retries, etc.) returns no rows: this test only
    // exercises the cap_events surface.
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
