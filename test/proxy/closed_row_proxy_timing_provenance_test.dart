// V1.A closed-row proxy timing-provenance Lane: tests the
// `RepositoryMobileOperationalSyncProxyGateway.fetchShiftRecords`
// mapper now emits the `business_timing_profile_id` /
// `business_timing_profile_version_id` / `service_period_key`
// triplet that the matching open-snapshot mapper has been emitting.
//
// Without these tests the closed-row gap silently regresses any
// future refactor of `proxy_bootstrap.dart`. The matching migration
// is `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql`.
//
// The gap was tracked in `docs/POST_HARDENING_FOLLOWUPS.md` under
// the `Closed-row proxy gap` heading and dispatched in
// `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md` row V1.A.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('closed shift_records proxy mapper emits timing triplet', () {
    test('SELECT requests the three timing provenance columns', () async {
      final pool = _StubPostgresPool(rowsForShift: const <PostgresRow>[]);
      final wrapper = TenantTransactionWrapper(pool);
      final gateway = RepositoryMobileOperationalSyncProxyGateway(
        tenantWrapper: wrapper,
      );

      await gateway.fetchShiftRecords(
        scope: const OperatorContext(
          userId: '11111111-1111-4111-8111-111111111111',
          operatorId: '22222222-2222-4222-8222-222222222222',
          locationId: '33333333-3333-4333-8333-333333333333',
          roles: <String>['operator_owner'],
        ),
        operatorId: '22222222-2222-4222-8222-222222222222',
        locationId: '33333333-3333-4333-8333-333333333333',
        modifiedSince: null,
        pageSize: 50,
      );

      // Exactly one query against shift_records (SET LOCAL calls run
      // through `execute`, not `query`).
      final shiftQueries = pool.lastTransaction!.queryCalls
          .where((call) => call.sql.contains('from public.shift_records'))
          .toList(growable: false);
      expect(shiftQueries, hasLength(1));

      final sql = shiftQueries.single.sql;
      // Triplet columns must appear in the SELECT projection.
      expect(sql, contains('business_timing_profile_id::text'));
      expect(sql, contains('business_timing_profile_version_id'));
      expect(sql, contains('service_period_key'));

      // The proxy bootstrap routes operator/location parameters
      // through the wrapper as `@operator_id::uuid` and
      // `@location_id::uuid`; verify they aren't dropped by the new
      // SELECT shape.
      expect(sql, contains('operator_id = @operator_id::uuid'));
      expect(sql, contains('location_id = @location_id::uuid'));
    });

    test(
      'a row with all three columns set round-trips to JSON with the same values',
      () async {
        final pool = _StubPostgresPool(
          rowsForShift: <PostgresRow>[
            <String, Object?>{
              'restaurant_id': 'loc-1',
              'week_id': '2026-W18',
              'day_label': 'Tue',
              'daypart': 'lunch',
              'status': 'closed',
              'business_date': '2026-05-05',
              'business_timing_profile_id':
                  '44444444-4444-4444-8444-444444444444',
              'business_timing_profile_version_id':
                  '44444444-4444-4444-8444-444444444444',
              'service_period_key': 'lunch',
              'covers': 120,
              'forecast_covers': 110,
              'ppa': 42.0,
              'cplh': 13.5,
              'splh': 160.0,
              'foh_hours': 8,
              'boh_hours': 5,
              'theoretical_labor_pct': 24.0,
              'primary_lever': 'ON_MODEL',
              'foh_labor_dollar': 480.0,
              'boh_labor_dollar': 320.0,
              'target_profile_id': null,
              'target_profile_version_id': null,
              'target_source_type': null,
              'target_cplh': null,
              'target_splh': null,
              'target_ppa': null,
              'target_foh_wage': null,
              'target_boh_wage': null,
              'opz_floor_cplh': null,
              'opz_ceiling_cplh': null,
              'theoretical_foh_labor_pct': null,
              'theoretical_boh_labor_pct': null,
              'source_system': 'toast',
              'source_shift_id': 'src-1',
              'updated_at': DateTime.utc(2026, 5, 5, 18, 30),
            },
          ],
        );
        final wrapper = TenantTransactionWrapper(pool);
        final gateway = RepositoryMobileOperationalSyncProxyGateway(
          tenantWrapper: wrapper,
        );

        final result = await gateway.fetchShiftRecords(
          scope: const OperatorContext(
            userId: '11111111-1111-4111-8111-111111111111',
            operatorId: '22222222-2222-4222-8222-222222222222',
            locationId: '33333333-3333-4333-8333-333333333333',
            roles: <String>['operator_owner'],
          ),
          operatorId: '22222222-2222-4222-8222-222222222222',
          locationId: '33333333-3333-4333-8333-333333333333',
          modifiedSince: null,
          pageSize: 50,
        );

        final rows = result['shift_records'] as List<Object?>;
        expect(rows, hasLength(1));
        final row = rows.single as Map<String, Object?>;

        expect(
          row['business_timing_profile_id'],
          '44444444-4444-4444-8444-444444444444',
        );
        expect(
          row['business_timing_profile_version_id'],
          '44444444-4444-4444-8444-444444444444',
        );
        expect(row['service_period_key'], 'lunch');

        // The legacy `daypart` column survives alongside the triplet
        // (closed timing label resolver falls back to it for old
        // rows). Confirm it is still emitted.
        expect(row['daypart'], 'lunch');
      },
    );

    test(
      'a legacy row with NULL triplet emits explicit nulls so callers know to fall back',
      () async {
        final pool = _StubPostgresPool(
          rowsForShift: <PostgresRow>[
            <String, Object?>{
              'restaurant_id': 'loc-1',
              'week_id': '2026-W17',
              'day_label': 'Mon',
              'daypart': 'dinner',
              'status': 'closed',
              'business_date': '2026-04-28',
              'business_timing_profile_id': null,
              'business_timing_profile_version_id': null,
              'service_period_key': null,
              'covers': 80,
              'forecast_covers': 90,
              'ppa': 38.0,
              'cplh': 12.0,
              'splh': 150.0,
              'foh_hours': 7,
              'boh_hours': 5,
              'theoretical_labor_pct': 25.0,
              'primary_lever': 'ON_MODEL',
              'foh_labor_dollar': null,
              'boh_labor_dollar': null,
              'target_profile_id': null,
              'target_profile_version_id': null,
              'target_source_type': null,
              'target_cplh': null,
              'target_splh': null,
              'target_ppa': null,
              'target_foh_wage': null,
              'target_boh_wage': null,
              'opz_floor_cplh': null,
              'opz_ceiling_cplh': null,
              'theoretical_foh_labor_pct': null,
              'theoretical_boh_labor_pct': null,
              'source_system': 'toast',
              'source_shift_id': 'src-legacy',
              'updated_at': DateTime.utc(2026, 4, 28, 23, 0),
            },
          ],
        );
        final wrapper = TenantTransactionWrapper(pool);
        final gateway = RepositoryMobileOperationalSyncProxyGateway(
          tenantWrapper: wrapper,
        );

        final result = await gateway.fetchShiftRecords(
          scope: const OperatorContext(
            userId: '11111111-1111-4111-8111-111111111111',
            operatorId: '22222222-2222-4222-8222-222222222222',
            locationId: '33333333-3333-4333-8333-333333333333',
            roles: <String>['operator_owner'],
          ),
          operatorId: '22222222-2222-4222-8222-222222222222',
          locationId: '33333333-3333-4333-8333-333333333333',
          modifiedSince: null,
          pageSize: 50,
        );

        final rows = result['shift_records'] as List<Object?>;
        expect(rows, hasLength(1));
        final row = rows.single as Map<String, Object?>;

        // Keys must be present (so `Map.fromMap` reads null, not
        // missing-key) but values must be null.
        expect(row.containsKey('business_timing_profile_id'), isTrue);
        expect(row.containsKey('business_timing_profile_version_id'), isTrue);
        expect(row.containsKey('service_period_key'), isTrue);
        expect(row['business_timing_profile_id'], isNull);
        expect(row['business_timing_profile_version_id'], isNull);
        expect(row['service_period_key'], isNull);

        // Legacy `daypart` survives to power
        // `ClosedTimingLabelResolver`'s fallback path.
        expect(row['daypart'], 'dinner');
      },
    );
  });
}

class _StubPostgresPool implements PostgresPool {
  _StubPostgresPool({required this.rowsForShift});

  final List<PostgresRow> rowsForShift;
  _StubPostgresTransaction? lastTransaction;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _StubPostgresTransaction(rowsForShift: rowsForShift);
    lastTransaction = tx;
    return tx;
  }
}

class _StubSqlCall {
  const _StubSqlCall(this.sql, this.parameters);
  final String sql;
  final PostgresParameters parameters;
}

class _StubPostgresTransaction implements PostgresTransaction {
  _StubPostgresTransaction({required this.rowsForShift});

  final List<PostgresRow> rowsForShift;
  final List<_StubSqlCall> queryCalls = <_StubSqlCall>[];
  final List<_StubSqlCall> executeCalls = <_StubSqlCall>[];
  bool committed = false;
  bool rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_StubSqlCall(sql, parameters));
    if (sql.contains('from public.shift_records')) {
      return rowsForShift;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executeCalls.add(_StubSqlCall(sql, parameters));
    return 0;
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
