// Advisor Knowledge Activation — Slice A4.6.
//
// FAKES-ONLY unit tests for `ShiftRecordsReadRepository`. No live
// Postgres: a fake `PostgresPool` / `PostgresTransaction` records every
// `query` / `execute` call and matches SQL by substring to return fixed
// rows (same shape as the `AccountingPostgresPool` recorder in
// `test/advisor_proxy_test_helpers.dart`).
//
// What these tests pin (the A4.6 read-repo contract):
//   * Reads run through `withTenant`, so the tenant SET LOCAL
//     (`select set_config('app.operator_id', ...)`) carries the CALLER's
//     operator_id / location_id (RLS-ready, HP #4).
//   * The window query is operator-leading (folds into
//     `shift_records_operator_business_date_idx`) and is SELECT-only.
//   * A genuinely-NULL measurement stays NULL on the row model — never
//     coerced to 0.0 (metric honesty) — and variance is null when either
//     side is absent.
//   * Variance is computed from actual+target on the SAME row.
//   * The repo issues NO write SQL (insert/update/delete/DDL).
//   * `loadScopedRestaurantIds` reads the operator's own restaurant ids
//     from `active_target_profiles`, operator-leading + tenant-scoped.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/shift_records_read_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _operatorId = '22222222-2222-4222-8222-222222222222';
const String _locationId = '33333333-3333-4333-8333-333333333333';
const String _userId = '11111111-1111-4111-8111-111111111111';
const String _restaurantId = 'demo_restaurant_001';

void main() {
  group('ShiftRecordsReadRepository.loadShiftVarianceForWindow', () {
    test('runs withTenant carrying the caller operator/location scope', () async {
      final pool = _FakeShiftPool(shiftRows: <PostgresRow>[_shiftRow()]);
      final repo = ShiftRecordsReadRepository(TenantTransactionWrapper(pool));

      await repo.loadShiftVarianceForWindow(
        operatorId: _operatorId,
        locationId: _locationId,
        restaurantId: _restaurantId,
        businessDateFrom: '2026-05-01',
        businessDateTo: '2026-05-07',
        userId: _userId,
      );

      final tx = pool.transactions.single;
      // SET LOCAL operator_id bound to THE CALLER's operator_id.
      final setOperator = tx.executeCalls.firstWhere(
        (c) => c.sql.contains("set_config('app.operator_id'"),
      );
      expect(setOperator.parameters['value'], _operatorId);
      final setLocation = tx.executeCalls.firstWhere(
        (c) => c.sql.contains("set_config('app.location_id'"),
      );
      expect(setLocation.parameters['value'], _locationId);
      final setUser = tx.executeCalls.firstWhere(
        (c) => c.sql.contains("set_config('app.user_id'"),
      );
      expect(setUser.parameters['value'], _userId);
    });

    test('window query is operator-leading SELECT bound to caller scope', () async {
      final pool = _FakeShiftPool(shiftRows: <PostgresRow>[_shiftRow()]);
      final repo = ShiftRecordsReadRepository(TenantTransactionWrapper(pool));

      await repo.loadShiftVarianceForWindow(
        operatorId: _operatorId,
        locationId: _locationId,
        restaurantId: _restaurantId,
        businessDateFrom: '2026-05-01',
        businessDateTo: '2026-05-07',
        userId: _userId,
      );

      final tx = pool.transactions.single;
      final select = tx.queryCalls.firstWhere(
        (c) => c.sql.contains('from public.shift_records'),
      );
      // Operator-leading predicate so it folds into the operator index.
      expect(
        select.sql.indexOf('sr.operator_id ='),
        lessThan(select.sql.indexOf('sr.location_id =')),
      );
      expect(select.sql, contains('sr.business_date >='));
      expect(select.sql, contains('sr.business_date <='));
      expect(select.parameters['operator_id'], _operatorId);
      expect(select.parameters['location_id'], _locationId);
      expect(select.parameters['restaurant_id'], _restaurantId);
    });

    test('computes variance from actual+target on the same row', () async {
      final pool = _FakeShiftPool(shiftRows: <PostgresRow>[_shiftRow()]);
      final repo = ShiftRecordsReadRepository(TenantTransactionWrapper(pool));

      final rows = await repo.loadShiftVarianceForWindow(
        operatorId: _operatorId,
        locationId: _locationId,
        restaurantId: _restaurantId,
        businessDateFrom: '2026-05-01',
        businessDateTo: '2026-05-07',
      );

      final row = rows.single;
      // actual cplh 9.0, target 8.0 → +1.0
      expect(row.actualCplh, 9.0);
      expect(row.targetCplh, 8.0);
      expect(row.cplhVariance, closeTo(1.0, 1e-9));
      // actual splh 110.0, target 120.0 → -10.0
      expect(row.splhVariance, closeTo(-10.0, 1e-9));
      // provenance carried through.
      expect(row.coversProvenance, 'toast_pos');
      expect(row.laborDollarsProvenance, 'adp_payroll');
    });

    test('a NULL measurement stays null (never 0.0) and zeroes the variance',
        () async {
      final pool = _FakeShiftPool(
        shiftRows: <PostgresRow>[_shiftRowMissingActuals()],
      );
      final repo = ShiftRecordsReadRepository(TenantTransactionWrapper(pool));

      final rows = await repo.loadShiftVarianceForWindow(
        operatorId: _operatorId,
        locationId: _locationId,
        restaurantId: _restaurantId,
        businessDateFrom: '2026-05-01',
        businessDateTo: '2026-05-07',
      );

      final row = rows.single;
      // Actuals genuinely absent → null, NOT 0.0.
      expect(row.actualCplh, isNull);
      expect(row.actualSales, isNull);
      // Target present but actual missing → variance null (no phantom 0).
      expect(row.targetCplh, 8.0);
      expect(row.cplhVariance, isNull);
    });

    test('issues NO write SQL (read-only)', () async {
      final pool = _FakeShiftPool(shiftRows: <PostgresRow>[_shiftRow()]);
      final repo = ShiftRecordsReadRepository(TenantTransactionWrapper(pool));

      await repo.loadShiftVarianceForWindow(
        operatorId: _operatorId,
        locationId: _locationId,
        restaurantId: _restaurantId,
        businessDateFrom: '2026-05-01',
        businessDateTo: '2026-05-07',
      );

      final tx = pool.transactions.single;
      // Only the SET LOCAL set_config statements are allowed through
      // execute(); none of them is a data mutation. The data read is a
      // SELECT through query(). Assert no DML/DDL slipped into either.
      final allSql = <String>[
        for (final c in tx.executeCalls) c.sql,
        for (final c in tx.queryCalls) c.sql,
      ];
      for (final sql in allSql) {
        final lower = sql.toLowerCase();
        expect(lower.contains('insert into'), isFalse, reason: sql);
        expect(lower.contains('update '), isFalse, reason: sql);
        expect(lower.contains('delete from'), isFalse, reason: sql);
        expect(lower.startsWith('create '), isFalse, reason: sql);
      }
      // Every execute() call is a set_config (SET LOCAL) — nothing else.
      for (final c in tx.executeCalls) {
        expect(c.sql, contains('set_config'));
      }
    });
  });

  group('ShiftRecordsReadRepository.loadScopedRestaurantIds', () {
    test('reads operator-own restaurant ids from active_target_profiles', () async {
      final pool = _FakeShiftPool(
        restaurantIdRows: const <PostgresRow>[
          <String, Object?>{'restaurant_id': 'demo_restaurant_001'},
          <String, Object?>{'restaurant_id': 'demo_restaurant_002'},
        ],
      );
      final repo = ShiftRecordsReadRepository(TenantTransactionWrapper(pool));

      final ids = await repo.loadScopedRestaurantIds(
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
      );

      expect(ids, <String>['demo_restaurant_001', 'demo_restaurant_002']);
      final tx = pool.transactions.single;
      final select = tx.queryCalls.firstWhere(
        (c) => c.sql.contains('from public.active_target_profiles'),
      );
      expect(select.sql, contains('distinct'));
      expect(select.parameters['operator_id'], _operatorId);
      expect(select.parameters['location_id'], _locationId);
      // SET LOCAL still carries caller scope.
      expect(
        tx.executeCalls
            .firstWhere((c) => c.sql.contains("set_config('app.operator_id'"))
            .parameters['value'],
        _operatorId,
      );
    });
  });
}

// ─── Fixed fact rows ────────────────────────────────────────────────────

PostgresRow _shiftRow() => <String, Object?>{
      'operator_id': _operatorId,
      'location_id': _locationId,
      'restaurant_id': _restaurantId,
      'business_date': '2026-05-03',
      'daypart': 'dinner',
      'status': 'closed',
      'covers': 180,
      'forecast_covers': 175,
      'actual_sales': 4200.0,
      'ppa': 23.0,
      'cplh': 9.0,
      'splh': 110.0,
      'foh_hours': 40,
      'boh_hours': 32,
      'foh_labor_dollar': 720.0,
      'boh_labor_dollar': 640.0,
      'theoretical_labor_pct': 24.0,
      'primary_lever': 'foh_overstaffed',
      'target_cplh': 8.0,
      'target_splh': 120.0,
      'target_ppa': 24.0,
      'opz_floor_cplh': 7.0,
      'opz_ceiling_cplh': 9.5,
      'covers_provenance': 'toast_pos',
      'labor_dollars_provenance': 'adp_payroll',
      'source_system': 'toast',
      'updated_at': '2026-05-03T23:30:00.000Z',
    };

/// A closed shift where the vendor never supplied actuals (covers/sales/
/// cplh/splh/ppa are NULL) but the locked target snapshot IS present.
PostgresRow _shiftRowMissingActuals() => <String, Object?>{
      'operator_id': _operatorId,
      'location_id': _locationId,
      'restaurant_id': _restaurantId,
      'business_date': '2026-05-04',
      'daypart': 'lunch',
      'status': 'closed',
      'covers': null,
      'forecast_covers': 90,
      'actual_sales': null,
      'ppa': null,
      'cplh': null,
      'splh': null,
      'foh_hours': null,
      'boh_hours': null,
      'foh_labor_dollar': null,
      'boh_labor_dollar': null,
      'theoretical_labor_pct': null,
      'primary_lever': null,
      'target_cplh': 8.0,
      'target_splh': 120.0,
      'target_ppa': 24.0,
      'opz_floor_cplh': 7.0,
      'opz_ceiling_cplh': 9.5,
      'covers_provenance': null,
      'labor_dollars_provenance': null,
      'source_system': null,
      'updated_at': '2026-05-04T16:00:00.000Z',
    };

// ─── Fake pool / transaction recorder (SQL matched by substring) ─────────

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);
  final String sql;
  final PostgresParameters parameters;
}

class _FakeShiftPool implements PostgresPool {
  _FakeShiftPool({
    this.shiftRows = const <PostgresRow>[],
    this.restaurantIdRows = const <PostgresRow>[],
  });

  final List<PostgresRow> shiftRows;
  final List<PostgresRow> restaurantIdRows;
  final List<_FakeShiftTransaction> transactions = <_FakeShiftTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeShiftTransaction(
      shiftRows: shiftRows,
      restaurantIdRows: restaurantIdRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _FakeShiftTransaction implements PostgresTransaction {
  _FakeShiftTransaction({
    required this.shiftRows,
    required this.restaurantIdRows,
  });

  final List<PostgresRow> shiftRows;
  final List<PostgresRow> restaurantIdRows;
  final List<_SqlCall> queryCalls = <_SqlCall>[];
  final List<_SqlCall> executeCalls = <_SqlCall>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('from public.shift_records')) return shiftRows;
    if (sql.contains('from public.active_target_profiles')) {
      return restaurantIdRows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executeCalls.add(_SqlCall(sql, parameters));
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
