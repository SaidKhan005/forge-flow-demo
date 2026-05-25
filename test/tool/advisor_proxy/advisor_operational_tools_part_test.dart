// Advisor Knowledge Activation — Slice A4.6.
//
// FAKES-ONLY unit tests for the operational read tools
// (`advisor_operational_tools_part.dart`): the factory
// `buildAdvisorOperationalTools`, its three handlers, and the HP #4
// restaurant-scope resolver.
//
// The handlers are exercised end to end against the REAL repositories
// backed by a fake `PostgresPool` (the same recorder shape as
// `test/advisor_proxy_test_helpers.dart`). Driving the real repos lets
// the tests assert that the tenant SET LOCAL carries the CALLER's
// operator_id — the load-bearing HP #4 guarantee — rather than trusting a
// stubbed repo.
//
// Pins:
//   (a) each handler runs withTenant carrying the CALLER's operator_id
//       (SET LOCAL app.operator_id bound to the OperatorContext);
//   (b) a tool input with a DIFFERENT operator_id is ignored — scope
//       stays the caller's (HP #4);
//   (c) get_shift_variance computes variance from actual+target and
//       surfaces provenance;
//   (d) an unavailable metric is marked unavailable, NOT 0.0;
//   (e) handlers emit NO write SQL (read-only, HP #6);
//   plus restaurant-scope resolution (single / selector / ambiguous /
//   foreign-id-rejected) and the tool catalog shape.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/shift_records_read_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';

const String _callerOperatorId = '22222222-2222-4222-8222-222222222222';
const String _callerLocationId = '33333333-3333-4333-8333-333333333333';
const String _callerUserId = '11111111-1111-4111-8111-111111111111';

// A foreign / hallucinated operator id the model might try to smuggle in
// via tool input. It must NEVER reach SET LOCAL.
const String _foreignOperatorId = '99999999-9999-4999-8999-999999999999';

const String _restaurantId = 'demo_restaurant_001';

OperatorContext _caller() => const OperatorContext(
      userId: _callerUserId,
      operatorId: _callerOperatorId,
      locationId: _callerLocationId,
      roles: <String>['advisor.read'],
    );

void main() {
  group('buildAdvisorOperationalTools — catalog', () {
    test('exposes exactly the three read tools, no write/mutation tool', () {
      final pool = _FakePool();
      final tools = _build(pool);

      final names = tools.definitions.map((d) => d.name).toList()..sort();
      expect(names, <String>[
        'get_active_targets',
        'get_shift_variance',
        'get_week_plan',
      ]);
      expect(tools.handlers.keys.toSet(), names.toSet());

      // HP #6: no tool name hints at a write/mutation capability.
      for (final name in names) {
        for (final verb in const <String>[
          'set',
          'update',
          'create',
          'delete',
          'write',
          'apply',
          'change',
        ]) {
          expect(name.contains(verb), isFalse, reason: '$name contains $verb');
        }
      }
    });
  });

  group('get_active_targets', () {
    test('(a) runs withTenant carrying the caller operator_id', () async {
      final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
      final tools = _build(pool);

      final result = await tools.handlers['get_active_targets']!(
        const <String, Object?>{},
      );

      expect(result['found'], true);
      _expectTenantBoundTo(pool, _callerOperatorId, _callerLocationId);
    });

    test('(b) a DIFFERENT operator_id in tool input is ignored (HP #4)', () async {
      final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
      final tools = _build(pool);

      // Smuggle a foreign operator_id (and a foreign restaurant) into the
      // tool input. Scope MUST stay the caller's; the foreign restaurant
      // is not one of the caller's own, so it is rejected, not honored.
      await tools.handlers['get_active_targets']!(<String, Object?>{
        'operator_id': _foreignOperatorId,
        'location_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      });

      // Every SET LOCAL operator_id across every tenant transaction is the
      // CALLER's id — the foreign id never reached the DB session.
      for (final tx in pool.transactions) {
        for (final c in tx.executeCalls) {
          if (c.sql.contains("set_config('app.operator_id'")) {
            expect(c.parameters['value'], _callerOperatorId);
            expect(c.parameters['value'], isNot(_foreignOperatorId));
          }
        }
      }
    });

    test('emits a citable source for the operator own target cycle', () async {
      final pool = _FakePool(targetCycleRows: <PostgresRow>[_cycleRow()]);
      final tools = _build(pool);

      final result = await tools.handlers['get_active_targets']!(
        const <String, Object?>{},
      );

      final sources = result['sources']! as List;
      expect(sources, isNotEmpty);
      final first = sources.first as Map;
      expect((first['source_id']! as String), startsWith('target_cycle:'));
      // Targets envelope is a measured value, not a bare number.
      final targets = result['targets']! as Map;
      expect((targets['cplh']! as Map)['state'], 'measured');
      expect((targets['cplh']! as Map)['value'], 8.0);
    });
  });

  group('get_week_plan', () {
    test('(a) runs withTenant carrying the caller scope', () async {
      final pool = _FakePool(weekPlanRows: <PostgresRow>[_weekPlanRow()]);
      final tools = _build(pool);

      final result = await tools.handlers['get_week_plan']!(
        const <String, Object?>{'week_start_date': '2026-05-04'},
      );

      expect(result['found'], true);
      expect(result['is_locked'], true);
      _expectTenantBoundTo(pool, _callerOperatorId, _callerLocationId);
    });

    test('rejects a missing/invalid week_start_date as invalid_input', () async {
      final pool = _FakePool(weekPlanRows: <PostgresRow>[_weekPlanRow()]);
      final tools = _build(pool);

      final missing =
          await tools.handlers['get_week_plan']!(const <String, Object?>{});
      expect(missing['error'], 'invalid_input');

      final bad = await tools.handlers['get_week_plan']!(
        const <String, Object?>{'week_start_date': 'not-a-date'},
      );
      expect(bad['error'], 'invalid_input');
    });
  });

  group('get_shift_variance', () {
    test('(c) computes variance from actual+target and surfaces provenance',
        () async {
      final pool = _FakePool(shiftRows: <PostgresRow>[_shiftRow()]);
      final tools = _build(pool);

      final result = await tools.handlers['get_shift_variance']!(
        const <String, Object?>{
          'business_date_from': '2026-05-01',
          'business_date_to': '2026-05-07',
        },
      );

      expect(result['shift_count'], 1);
      final shift = (result['shifts']! as List).single as Map;
      final cplh = shift['cplh']! as Map;
      expect((cplh['actual']! as Map)['value'], 9.0);
      expect((cplh['target']! as Map)['value'], 8.0);
      expect((cplh['variance']! as Map)['value'], closeTo(1.0, 1e-9));
      expect((cplh['variance']! as Map)['state'], 'measured');
      // Provenance carried so an estimate is never shown as a measurement.
      expect(shift['covers_provenance'], 'toast_pos');
      expect(shift['labor_dollars_provenance'], 'adp_payroll');
      _expectTenantBoundTo(pool, _callerOperatorId, _callerLocationId);
    });

    test('(d) an unavailable metric is marked unavailable, NOT 0.0', () async {
      final pool = _FakePool(shiftRows: <PostgresRow>[_shiftRowMissingActuals()]);
      final tools = _build(pool);

      final result = await tools.handlers['get_shift_variance']!(
        const <String, Object?>{
          'business_date_from': '2026-05-01',
          'business_date_to': '2026-05-07',
        },
      );

      final shift = (result['shifts']! as List).single as Map;
      final cplh = shift['cplh']! as Map;
      final actual = cplh['actual']! as Map;
      expect(actual['state'], 'unavailable');
      expect(actual['value'], isNull);
      // The variance is also unavailable (no phantom 0.0).
      final variance = cplh['variance']! as Map;
      expect(variance['state'], 'unavailable');
      expect(variance['value'], isNull);
      // actual_sales likewise unavailable, not 0.0.
      final actualSales = shift['actual_sales']! as Map;
      expect(actualSales['state'], 'unavailable');
      expect(actualSales['value'], isNull);
    });

    test('rejects an inverted date range as invalid_input', () async {
      final pool = _FakePool(shiftRows: const <PostgresRow>[]);
      final tools = _build(pool);

      final result = await tools.handlers['get_shift_variance']!(
        const <String, Object?>{
          'business_date_from': '2026-05-07',
          'business_date_to': '2026-05-01',
        },
      );
      expect(result['error'], 'invalid_input');
    });
  });

  group('(e) read-only — handlers emit no write SQL (HP #6)', () {
    test('no insert/update/delete/DDL across all three handlers', () async {
      final pool = _FakePool(
        targetCycleRows: <PostgresRow>[_cycleRow()],
        weekPlanRows: <PostgresRow>[_weekPlanRow()],
        shiftRows: <PostgresRow>[_shiftRow()],
      );
      final tools = _build(pool);

      await tools.handlers['get_active_targets']!(const <String, Object?>{});
      await tools.handlers['get_week_plan']!(
        const <String, Object?>{'week_start_date': '2026-05-04'},
      );
      await tools.handlers['get_shift_variance']!(
        const <String, Object?>{
          'business_date_from': '2026-05-01',
          'business_date_to': '2026-05-07',
        },
      );

      for (final tx in pool.transactions) {
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
        // execute() is only ever the SET LOCAL set_config statements.
        for (final c in tx.executeCalls) {
          expect(c.sql, contains('set_config'));
        }
      }
    });
  });

  group('HP #4 restaurant-scope resolution', () {
    test('single own restaurant resolves without any tool input', () async {
      final pool = _FakePool(
        restaurantIdRows: const <PostgresRow>[
          <String, Object?>{'restaurant_id': _restaurantId},
        ],
        targetCycleRows: <PostgresRow>[_cycleRow()],
      );
      final tools = _build(pool);

      final result = await tools.handlers['get_active_targets']!(
        const <String, Object?>{},
      );
      expect(result['found'], true);
      expect(result['restaurant_id'], _restaurantId);
    });

    test('a foreign restaurant_id selector is rejected, not honored', () async {
      final pool = _FakePool(
        restaurantIdRows: const <PostgresRow>[
          <String, Object?>{'restaurant_id': _restaurantId},
          <String, Object?>{'restaurant_id': 'demo_restaurant_002'},
        ],
        targetCycleRows: <PostgresRow>[_cycleRow()],
      );
      final tools = _build(pool);

      final result = await tools.handlers['get_active_targets']!(
        const <String, Object?>{'restaurant_id': 'someone_elses_restaurant'},
      );
      // Not honored: needs_restaurant_selection, listing only OWN ids.
      expect(result['needs_restaurant_selection'], true);
      expect(
        result['your_restaurant_ids'],
        <String>[_restaurantId, 'demo_restaurant_002'],
      );
      // The active-cycle query never ran with the foreign restaurant.
      for (final tx in pool.transactions) {
        for (final c in tx.queryCalls) {
          if (c.sql.contains('from public.target_cycles')) {
            expect(c.parameters['restaurant_id'], isNot('someone_elses_restaurant'));
          }
        }
      }
    });

    test('a valid own selector among many is honored', () async {
      final pool = _FakePool(
        restaurantIdRows: const <PostgresRow>[
          <String, Object?>{'restaurant_id': _restaurantId},
          <String, Object?>{'restaurant_id': 'demo_restaurant_002'},
        ],
        targetCycleRows: <PostgresRow>[_cycleRow(restaurantId: 'demo_restaurant_002')],
      );
      final tools = _build(pool);

      final result = await tools.handlers['get_active_targets']!(
        const <String, Object?>{'restaurant_id': 'demo_restaurant_002'},
      );
      expect(result['found'], true);
      expect(result['restaurant_id'], 'demo_restaurant_002');
    });

    test('multiple own restaurants with no selector asks for selection', () async {
      final pool = _FakePool(
        restaurantIdRows: const <PostgresRow>[
          <String, Object?>{'restaurant_id': _restaurantId},
          <String, Object?>{'restaurant_id': 'demo_restaurant_002'},
        ],
      );
      final tools = _build(pool);

      final result = await tools.handlers['get_active_targets']!(
        const <String, Object?>{},
      );
      expect(result['needs_restaurant_selection'], true);
      expect((result['your_restaurant_ids']! as List).length, 2);
      // No target-cycle read happened (we could not pick a restaurant).
      for (final tx in pool.transactions) {
        for (final c in tx.queryCalls) {
          expect(c.sql.contains('from public.target_cycles'), isFalse);
        }
      }
    });

    test('zero own restaurants reports no data (graceful, not an error)', () async {
      final pool = _FakePool(restaurantIdRows: const <PostgresRow>[]);
      final tools = _build(pool);

      final result = await tools.handlers['get_shift_variance']!(
        const <String, Object?>{
          'business_date_from': '2026-05-01',
          'business_date_to': '2026-05-07',
        },
      );
      expect(result['needs_restaurant_selection'], true);
      expect(result['your_restaurant_ids'], <String>[]);
    });
  });
}

// ─── Helpers ────────────────────────────────────────────────────────────

AdvisorOperationalTools _build(_FakePool pool) {
  final wrapper = TenantTransactionWrapper(pool);
  return buildAdvisorOperationalTools(
    operator: _caller(),
    targetCycleRepository: TargetCycleRepository(wrapper),
    weeklyPlanSnapshotRepository: WeeklyPlanSnapshotRepository(wrapper),
    shiftRecordsReadRepository: ShiftRecordsReadRepository(wrapper),
  );
}

void _expectTenantBoundTo(_FakePool pool, String operatorId, String locationId) {
  expect(pool.transactions, isNotEmpty);
  var sawOperator = false;
  var sawLocation = false;
  for (final tx in pool.transactions) {
    for (final c in tx.executeCalls) {
      if (c.sql.contains("set_config('app.operator_id'")) {
        expect(c.parameters['value'], operatorId);
        sawOperator = true;
      }
      if (c.sql.contains("set_config('app.location_id'")) {
        expect(c.parameters['value'], locationId);
        sawLocation = true;
      }
    }
  }
  expect(sawOperator, isTrue, reason: 'no SET LOCAL app.operator_id issued');
  expect(sawLocation, isTrue, reason: 'no SET LOCAL app.location_id issued');
}

// ─── Fixed fact rows ────────────────────────────────────────────────────

PostgresRow _cycleRow({String restaurantId = _restaurantId}) => <String, Object?>{
      'cycle_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'operator_id': _callerOperatorId,
      'location_id': _callerLocationId,
      'restaurant_id': restaurantId,
      'source': 'recommended',
      'effective_start': '2026-05-01',
      'effective_end': '2026-06-30',
      'calibration_window_start': '2026-04-01',
      'calibration_window_end': '2026-04-30',
      'target_cplh': 8.0,
      'target_splh': 120.0,
      'target_ppa': 24.0,
      'foh_wage': 18.0,
      'boh_wage': 20.0,
      'opz_floor_cplh': 7.0,
      'opz_ceiling_cplh': 9.5,
      'manager_override_used': false,
      'manager_override_at': null,
      'manager_override_by_user_id': null,
      'admin_replaced_at': null,
      'admin_replaced_by_user_id': null,
      'supersedes_cycle_id': null,
      'selected_shift_count': 12,
      'selected_record_keys': '[]',
      'selection_decision_ids': '[]',
      'replacement_reason': null,
      'idempotency_key': 'idem-cycle-1',
      'request_hash': 'hash-1',
      'created_by': _callerUserId,
      'created_at': '2026-05-01T00:00:00.000Z',
      'updated_at': '2026-05-01T00:00:00.000Z',
      'deactivated_at': null,
    };

PostgresRow _weekPlanRow() => <String, Object?>{
      'snapshot_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'operator_id': _callerOperatorId,
      'location_id': _callerLocationId,
      'restaurant_id': _restaurantId,
      'week_start_date': '2026-05-04',
      'week_end_date': '2026-05-10',
      'week_key': 'week_2026_05_04',
      'target_cycle_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'forecast_context_id': null,
      'forecast_covers': 1200,
      'forecast_sales': 28000.0,
      'required_foh_hours': 210.0,
      'required_boh_hours': 168.0,
      'theoretical_foh_labor_dollars': 3780.0,
      'theoretical_boh_labor_dollars': 3360.0,
      'covers_source': 'reservation_forecast',
      'sales_source': 'pos_forecast',
      'snapshot_status': 'active',
      'source': 'server_lock',
      'generated_at': '2026-05-03T12:00:00.000Z',
      'locked_at': '2026-05-03T12:00:00.000Z',
      'superseded_at': null,
      'superseded_by_snapshot_id': null,
      'supersedes_snapshot_id': null,
      'unlocked_at': null,
      'unlocked_by_user_id': null,
      'replacement_reason': null,
      'idempotency_key': 'idem-week-1',
      'request_hash': 'hash-week-1',
      'wage_at_lock_time_json': null,
      'metadata': '{}',
      'created_by': _callerUserId,
      'created_at': '2026-05-03T12:00:00.000Z',
      'updated_at': '2026-05-03T12:00:00.000Z',
    };

PostgresRow _shiftRow() => <String, Object?>{
      'operator_id': _callerOperatorId,
      'location_id': _callerLocationId,
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

PostgresRow _shiftRowMissingActuals() => <String, Object?>{
      'operator_id': _callerOperatorId,
      'location_id': _callerLocationId,
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

class _FakePool implements PostgresPool {
  _FakePool({
    this.targetCycleRows = const <PostgresRow>[],
    this.weekPlanRows = const <PostgresRow>[],
    this.shiftRows = const <PostgresRow>[],
    this.restaurantIdRows = const <PostgresRow>[
      <String, Object?>{'restaurant_id': _restaurantId},
    ],
  });

  final List<PostgresRow> targetCycleRows;
  final List<PostgresRow> weekPlanRows;
  final List<PostgresRow> shiftRows;
  final List<PostgresRow> restaurantIdRows;
  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(
      targetCycleRows: targetCycleRows,
      weekPlanRows: weekPlanRows,
      shiftRows: shiftRows,
      restaurantIdRows: restaurantIdRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction({
    required this.targetCycleRows,
    required this.weekPlanRows,
    required this.shiftRows,
    required this.restaurantIdRows,
  });

  final List<PostgresRow> targetCycleRows;
  final List<PostgresRow> weekPlanRows;
  final List<PostgresRow> shiftRows;
  final List<PostgresRow> restaurantIdRows;
  final List<_SqlCall> queryCalls = <_SqlCall>[];
  final List<_SqlCall> executeCalls = <_SqlCall>[];

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('from public.active_target_profiles')) {
      return restaurantIdRows;
    }
    if (sql.contains('from public.target_cycles')) return targetCycleRows;
    if (sql.contains('from public.target_cycle_dayparts')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.weekly_plan_snapshots')) return weekPlanRows;
    if (sql.contains('from public.shift_records')) return shiftRows;
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
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
