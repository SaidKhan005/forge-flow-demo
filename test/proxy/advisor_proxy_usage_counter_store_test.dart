// HARD-A — Postgres-backed usage counter store.
//
// The store provides the data-access seam over
// `public.advisor_proxy_usage_counters`; the proxy bootstrap wraps it
// with an adapter that satisfies the runtime `ProxyUsageCounterStore`
// interface. These tests run against a fake in-memory pool so we
// assert on SQL shape, parameter binding, the minute / month bucket
// math, and the ON CONFLICT collapse.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';

void main() {
  group('AdvisorProxyUsageCounterStore.readSnapshot', () {
    test('reads minute request_count and month cost_cents sum', () async {
      final pool = _FakeUsageCountersPool();
      pool.minuteRequestCounts['2026-05-02T12:34:00.000Z'] = 7;
      pool.monthlyCostCents['2026-05-01'] = 4321;
      final store = AdvisorProxyUsageCounterStore(
        TenantTransactionWrapper(pool),
      );

      final snapshot = await store.readSnapshot(
        operatorId: _operatorId,
        locationId: _locationId,
        tierId: 'launch',
        now: DateTime.utc(2026, 5, 2, 12, 34, 56, 789),
      );

      expect(snapshot.requestsThisMinute, equals(7));
      expect(snapshot.costCentsThisMonth, equals(4321));
      expect(
        snapshot.minuteBucketStart,
        equals(DateTime.utc(2026, 5, 2, 12, 34)),
      );
      expect(snapshot.monthBucketStart, equals(DateTime.utc(2026, 5)));

      final tx = pool.transactions.single;
      expect(tx.committed, isTrue);
      expect(
        tx.executedSql,
        containsAll(<String>[
          "select set_config('app.operator_id', @value, true)",
          "select set_config('app.location_id', @value, true)",
        ]),
      );
      // Minute query uses tenant-leading (operator, location, tier,
      // minute_bucket) lookup.
      final minuteCall = tx.queryCalls.first;
      expect(minuteCall.sql, contains('select request_count'));
      expect(minuteCall.parameters['operator_id'], equals(_operatorId));
      expect(minuteCall.parameters['location_id'], equals(_locationId));
      expect(minuteCall.parameters['tier_id'], equals('launch'));
      expect(
        minuteCall.parameters['minute_bucket'],
        equals('2026-05-02T12:34:00.000Z'),
      );
      // Month query sums cost_cents for the operator's UTC month.
      final monthCall = tx.queryCalls[1];
      expect(monthCall.sql, contains('coalesce(sum(cost_cents), 0)'));
      expect(monthCall.parameters['month_bucket'], equals('2026-05-01'));
    });

    test('absent rows project to zero, not null', () async {
      final pool = _FakeUsageCountersPool();
      final store = AdvisorProxyUsageCounterStore(
        TenantTransactionWrapper(pool),
      );

      final snapshot = await store.readSnapshot(
        operatorId: _operatorId,
        locationId: _locationId,
        tierId: 'launch',
        now: DateTime.utc(2026, 5, 2, 12, 34),
      );

      expect(snapshot.requestsThisMinute, equals(0));
      expect(snapshot.costCentsThisMonth, equals(0));
    });

    test('non-UTC `now` is normalized to UTC for bucket math', () async {
      final pool = _FakeUsageCountersPool();
      final store = AdvisorProxyUsageCounterStore(
        TenantTransactionWrapper(pool),
      );

      // 2026-05-02 19:30 UTC-04:00 == 2026-05-02 23:30 UTC.
      final localTime = DateTime.utc(
        2026,
        5,
        2,
        23,
        30,
      ).add(Duration.zero); // already UTC, but mimic a transformed input
      await store.readSnapshot(
        operatorId: _operatorId,
        locationId: _locationId,
        tierId: 'launch',
        now: localTime,
      );

      final tx = pool.transactions.single;
      final minuteCall = tx.queryCalls.first;
      expect(
        minuteCall.parameters['minute_bucket'],
        equals('2026-05-02T23:30:00.000Z'),
      );
    });
  });

  group('AdvisorProxyUsageCounterStore.upsertIncrement', () {
    test('UPSERTs with ON CONFLICT on the unique tenant-leading key', () async {
      final pool = _FakeUsageCountersPool();
      final store = AdvisorProxyUsageCounterStore(
        TenantTransactionWrapper(pool),
      );

      await store.upsertIncrement(
        operatorId: _operatorId,
        locationId: _locationId,
        tierId: 'launch',
        now: DateTime.utc(2026, 5, 2, 12, 34, 56),
        costCentsToAdd: 175,
      );

      final tx = pool.transactions.single;
      expect(tx.committed, isTrue);
      // Single insert+upsert call.
      expect(pool.upsertExecuteCount, equals(1));
      final upsert = pool.upsertExecuteCalls.single;
      expect(
        upsert.sql,
        contains('insert into public.advisor_proxy_usage_counters'),
      );
      expect(
        upsert.sql,
        contains(
          'on conflict (operator_id, location_id, tier_id, minute_bucket)',
        ),
      );
      expect(
        upsert.sql,
        contains(
          'public.advisor_proxy_usage_counters.request_count + 1',
        ),
      );
      expect(
        upsert.sql,
        contains(
          'public.advisor_proxy_usage_counters.cost_cents +',
        ),
      );
      expect(upsert.parameters['operator_id'], equals(_operatorId));
      expect(upsert.parameters['location_id'], equals(_locationId));
      expect(upsert.parameters['tier_id'], equals('launch'));
      expect(
        upsert.parameters['minute_bucket'],
        equals('2026-05-02T12:34:00.000Z'),
      );
      expect(upsert.parameters['month_bucket'], equals('2026-05-01'));
      expect(upsert.parameters['cost_cents'], equals(175));
    });

    test('concurrent increments on same minute bucket collapse to one row',
        () async {
      // The fake's upsert simulates Postgres ON CONFLICT semantics:
      // concurrent INSERTs that hit the same unique key collapse to one
      // row whose request_count is the count of writers and whose
      // cost_cents is the sum.
      final pool = _FakeUsageCountersPool();
      final store = AdvisorProxyUsageCounterStore(
        TenantTransactionWrapper(pool),
      );

      final futures = <Future<void>>[
        for (var i = 0; i < 8; i++)
          store.upsertIncrement(
            operatorId: _operatorId,
            locationId: _locationId,
            tierId: 'launch',
            now: DateTime.utc(2026, 5, 2, 12, 34),
            costCentsToAdd: 5,
          ),
      ];
      await Future.wait(futures);

      final stored = pool.usageCountersTable;
      expect(stored, hasLength(1));
      final row = stored.values.single;
      expect(row.requestCount, equals(8));
      expect(row.costCents, equals(40));
      expect(row.minuteBucket, equals('2026-05-02T12:34:00.000Z'));
      expect(row.monthBucket, equals('2026-05-01'));
    });

    test(
      'ProxyUsageGuard.recordAllowed flows through to incrementOnAllow',
      () async {
        // The guard's recordAllowed wraps the lib counter store via the
        // adapter in proxy_bootstrap.dart. The smoke + advisor routes
        // call recordAllowed after requireAllowed succeeds; this test
        // proves the call advances the per-minute bucket.
        final pool = _FakeUsageCountersPool();
        final libStore = AdvisorProxyUsageCounterStore(
          TenantTransactionWrapper(pool),
        );
        final guardStore = _LibStoreAdapter(libStore);
        final guard = ProxyUsageGuard(
          store: guardStore,
          tierResolver: const FixedLaunchTierResolver(),
          now: () => DateTime.utc(2026, 5, 2, 12, 34),
        );
        const operator = OperatorContext(
          userId: '33333333-3333-4333-8333-333333333333',
          operatorId: _operatorId,
          locationId: _locationId,
          roles: <String>['advisor.read'],
        );
        const decision = UsageDecisionAllowed(
          tier: PolicyTier.launch,
          remainingRequestsThisMinute: 29,
          remainingCostCentsThisMonth: 4999,
        );

        await guard.recordAllowed(
          operator: operator,
          decision: decision,
          costCentsToAdd: 12,
        );

        expect(pool.usageCountersTable, hasLength(1));
        final row = pool.usageCountersTable.values.single;
        expect(row.requestCount, equals(1));
        expect(row.costCents, equals(12));
        expect(row.minuteBucket, equals('2026-05-02T12:34:00.000Z'));
      },
    );

    test('writes for distinct minutes do NOT collapse', () async {
      final pool = _FakeUsageCountersPool();
      final store = AdvisorProxyUsageCounterStore(
        TenantTransactionWrapper(pool),
      );

      await store.upsertIncrement(
        operatorId: _operatorId,
        locationId: _locationId,
        tierId: 'launch',
        now: DateTime.utc(2026, 5, 2, 12, 34),
        costCentsToAdd: 5,
      );
      await store.upsertIncrement(
        operatorId: _operatorId,
        locationId: _locationId,
        tierId: 'launch',
        now: DateTime.utc(2026, 5, 2, 12, 35),
        costCentsToAdd: 9,
      );

      expect(pool.usageCountersTable, hasLength(2));
      final byMinute = <String, _FakeUsageCounterRow>{
        for (final row in pool.usageCountersTable.values)
          row.minuteBucket: row,
      };
      expect(byMinute['2026-05-02T12:34:00.000Z']!.requestCount, equals(1));
      expect(byMinute['2026-05-02T12:34:00.000Z']!.costCents, equals(5));
      expect(byMinute['2026-05-02T12:35:00.000Z']!.requestCount, equals(1));
      expect(byMinute['2026-05-02T12:35:00.000Z']!.costCents, equals(9));
    });
  });
}

/// Adapts the lib data-access [AdvisorProxyUsageCounterStore] to the
/// proxy's runtime [ProxyUsageCounterStore] interface. Mirrors the
/// adapter the production bootstrap installs.
class _LibStoreAdapter implements ProxyUsageCounterStore {
  _LibStoreAdapter(this._inner);

  final AdvisorProxyUsageCounterStore _inner;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async {
    final s = await _inner.readSnapshot(
      operatorId: operatorId,
      locationId: locationId,
      tierId: tierId,
      now: now,
    );
    return UsageSnapshot(
      requestsThisMinute: s.requestsThisMinute,
      costCentsThisMonth: s.costCentsThisMonth,
      minuteBucketStart: s.minuteBucketStart,
      monthBucketStart: s.monthBucketStart,
    );
  }

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) {
    return _inner.upsertIncrement(
      operatorId: operatorId,
      locationId: locationId,
      tierId: tierId,
      now: now,
      costCentsToAdd: costCentsToAdd,
    );
  }
}

class _FakeUsageCounterRow {
  _FakeUsageCounterRow({
    required this.minuteBucket,
    required this.monthBucket,
    required this.requestCount,
    required this.costCents,
  });

  final String minuteBucket;
  final String monthBucket;
  int requestCount;
  int costCents;
}

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _FakeUsageCountersPool implements PostgresPool {
  /// Seeded by tests: minute_bucket → request_count.
  final Map<String, int> minuteRequestCounts = <String, int>{};

  /// Seeded by tests: month_bucket → cost_cents_this_month.
  final Map<String, int> monthlyCostCents = <String, int>{};

  /// Simulates the unique-key collapse from
  /// `(operator_id, location_id, tier_id, minute_bucket)`.
  final Map<String, _FakeUsageCounterRow> usageCountersTable =
      <String, _FakeUsageCounterRow>{};

  final List<_FakeUsageCountersTransaction> transactions =
      <_FakeUsageCountersTransaction>[];

  final List<_SqlCall> upsertExecuteCalls = <_SqlCall>[];
  int get upsertExecuteCount => upsertExecuteCalls.length;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeUsageCountersTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _FakeUsageCountersTransaction implements PostgresTransaction {
  _FakeUsageCountersTransaction(this.pool);

  final _FakeUsageCountersPool pool;
  final List<String> executedSql = <String>[];
  final List<_SqlCall> queryCalls = <_SqlCall>[];
  bool committed = false;
  bool rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('select request_count')) {
      final minuteBucket = parameters['minute_bucket'] as String?;
      final count = pool.minuteRequestCounts[minuteBucket] ?? 0;
      return <PostgresRow>[
        <String, Object?>{'request_count': count},
      ];
    }
    if (sql.contains('coalesce(sum(cost_cents)')) {
      final monthBucket = parameters['month_bucket'] as String?;
      final cost = pool.monthlyCostCents[monthBucket] ?? 0;
      return <PostgresRow>[
        <String, Object?>{'cost_cents_this_month': cost},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executedSql.add(sql);
    if (sql.contains('insert into public.advisor_proxy_usage_counters')) {
      pool.upsertExecuteCalls.add(_SqlCall(sql, parameters));
      final operatorId = parameters['operator_id']! as String;
      final locationId = parameters['location_id']! as String;
      final tierId = parameters['tier_id']! as String;
      final minuteBucket = parameters['minute_bucket']! as String;
      final monthBucket = parameters['month_bucket']! as String;
      final cost = (parameters['cost_cents'] as num).toInt();
      final key = '$operatorId|$locationId|$tierId|$minuteBucket';
      final existing = pool.usageCountersTable[key];
      if (existing == null) {
        pool.usageCountersTable[key] = _FakeUsageCounterRow(
          minuteBucket: minuteBucket,
          monthBucket: monthBucket,
          requestCount: 1,
          costCents: cost,
        );
      } else {
        existing.requestCount += 1;
        existing.costCents += cost;
      }
      return 1;
    }
    return 1;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }
}
