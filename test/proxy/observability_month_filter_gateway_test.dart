// Producer-SQL coverage for the MONTHLY observability cost filter.
//
// `public.usage_logs` is a monthly rollup (each row's `period_start` is
// `date_trunc('month', ...)`), so the ONLY honest cost windows are the
// current calendar month and the immediately preceding one. The gateway
// threads an [ObservabilityMonth] selector into the five usage_logs cost
// producers (cost telemetry, top spenders, cache-hit, model-mix, batch)
// as a `@month_offset` parameter (0 = current, 1 = previous) that drives
// a parameterized `date_trunc('month', now())` bound. The NON-usage_logs
// surfaces (cap-event recent list, dormancy, graph, Cloud Run,
// projection retries) must NOT carry the month bound — "month" does not
// meaningfully apply to them.
//
// This file proves the SQL boundary is correct for current vs previous
// and that the month bound never leaks onto the non-cost producers.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

const String _operatorA = '11111111-1111-4111-8111-111111111111';

/// The five usage_logs-backed cost producers, identified by a substring
/// unique to each producer's SQL.
const Map<String, String> _costProducerMarkers = <String, String>{
  'cost_telemetry': 'counted as (',
  'top_expensive': 'by_operator as (',
  'cache_hit': 'as hit_rate',
  'model_mix': 'as sonnet_share',
  'batch_share': 'as batch_share',
};

/// Non-usage_logs producers that must stay month-agnostic.
const Map<String, String> _nonCostProducerMarkers = <String, String>{
  'cap_events': 'public.usage_cap_events',
  'dormancy': '@as_of::timestamptz',
};

void main() {
  group('RepositoryObservabilityAdminProxyGateway month filter', () {
    test('current month: every cost producer binds month_offset = 0', () async {
      final pool = _ObservabilityPool();
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 19, 12),
      );

      await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorA,
        month: ObservabilityMonth.current,
      );

      final tx = pool.transactions.single;
      for (final entry in _costProducerMarkers.entries) {
        final query = _firstWith(tx, entry.value, label: entry.key);
        // The parameterized month bound is present (both edges), and the
        // hardcoded "30 days" / bare-current predicates are gone.
        expect(
          query.sql,
          contains(
            "date_trunc('month', now()) - (@month_offset::int * interval '1 month')",
          ),
          reason: '${entry.key} lower bound must be parameterized',
        );
        expect(
          query.sql,
          contains(
            "date_trunc('month', now()) - ((@month_offset::int - 1) * interval '1 month')",
          ),
          reason: '${entry.key} upper bound must be parameterized',
        );
        expect(
          query.sql,
          isNot(contains("interval '30 days'")),
          reason: '${entry.key} must drop the legacy 30-day predicate',
        );
        // current == offset 0.
        expect(
          query.parameters['month_offset'],
          equals(0),
          reason: '${entry.key} must bind month_offset 0 for current',
        );
        // Cross-operator predicate stays intact in every cost producer.
        expect(
          query.sql,
          contains('@operator_id::uuid is null'),
          reason: '${entry.key} must keep the cross-operator predicate',
        );
        // Read-only.
        final lower = query.sql.toLowerCase();
        expect(lower, isNot(contains('insert ')));
        expect(lower, isNot(contains('update ')));
        expect(lower, isNot(contains('delete ')));
      }
    });

    test('previous month: every cost producer binds month_offset = 1',
        () async {
      final pool = _ObservabilityPool();
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 19, 12),
      );

      await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorA,
        month: ObservabilityMonth.previous,
      );

      final tx = pool.transactions.single;
      for (final entry in _costProducerMarkers.entries) {
        final query = _firstWith(tx, entry.value, label: entry.key);
        // previous == offset 1.
        expect(
          query.parameters['month_offset'],
          equals(1),
          reason: '${entry.key} must bind month_offset 1 for previous',
        );
      }
    });

    test('default month is current (offset 0) when omitted', () async {
      final pool = _ObservabilityPool();
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 19, 12),
      );

      await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorA,
        // month omitted == current.
      );

      final tx = pool.transactions.single;
      final cost = _firstWith(tx, _costProducerMarkers['cost_telemetry']!,
          label: 'cost_telemetry');
      expect(cost.parameters['month_offset'], equals(0));
    });

    test('month bound never leaks onto non-usage_logs producers', () async {
      final pool = _ObservabilityPool();
      final gateway = RepositoryObservabilityAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(pool),
        now: () => DateTime.utc(2026, 5, 19, 12),
      );

      await gateway.fetch(
        actorUserId: 'admin-user',
        adminReason: 'admin.observability.test',
        costTelemetryLimit: 10,
        operatorId: _operatorA,
        month: ObservabilityMonth.previous,
      );

      final tx = pool.transactions.single;
      // The two month-agnostic producers below must neither reference
      // @month_offset in their SQL nor be passed it as a parameter. (The
      // executor's named-SQL binding would otherwise reject the unused
      // parameter, so this is a correctness guarantee, not just hygiene.)
      for (final entry in _nonCostProducerMarkers.entries) {
        final query = _firstWith(tx, entry.value, label: entry.key);
        expect(
          query.sql,
          isNot(contains('@month_offset')),
          reason: '${entry.key} must not reference the month bound',
        );
        expect(
          query.parameters.containsKey('month_offset'),
          isFalse,
          reason: '${entry.key} must not be passed month_offset',
        );
      }

      // The graph producer takes no scope parameters at all and must
      // likewise stay month-free.
      final graphQuery = tx.queries
          .where((q) => q.sql.contains('approved_node_count'))
          .single;
      expect(graphQuery.sql, isNot(contains('@month_offset')));
      expect(graphQuery.parameters.containsKey('month_offset'), isFalse);
    });
  });
}

_RecordedQuery _firstWith(
  _ObservabilityTransaction tx,
  String marker, {
  required String label,
}) {
  final matches = tx.queries.where((q) => q.sql.contains(marker)).toList();
  expect(
    matches,
    isNotEmpty,
    reason: 'no producer query matched marker for $label',
  );
  return matches.first;
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
    // This test only inspects SQL + bound parameters, so every producer
    // returns no rows.
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
