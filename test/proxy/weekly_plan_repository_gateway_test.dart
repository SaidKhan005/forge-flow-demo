// Phase 8 weekly-plan truth - production repository gateway wiring tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/forecast_context_repository.dart'
    as weekly_forecast;
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart'
    as weekly_snapshot;
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _restaurantId = 'demo_restaurant';
const String _snapshotId = '44444444-4444-4444-4444-444444444444';
const String _targetCycleId = '55555555-5555-5555-5555-555555555555';
const String _forecastContextId = '66666666-6666-6666-6666-666666666666';

void main() {
  test(
    'RepositoryWeeklyPlanGateway writes forecast context then snapshot',
    () async {
      final pool = _RecordingPool(
        onQuery: (sql, parameters) {
          if (sql.contains('from public.forecast_contexts f')) {
            return const <PostgresRow>[];
          }
          if (sql.contains('insert into public.forecast_contexts')) {
            expect(parameters['context_status'], equals('closed'));
            expect(parameters['target_cycle_id'], equals(_targetCycleId));
            return <PostgresRow>[_forecastContextRow()];
          }
          if (sql.contains('from public.weekly_plan_snapshots s')) {
            return const <PostgresRow>[];
          }
          if (sql.contains('insert into public.weekly_plan_snapshots')) {
            expect(
              parameters['forecast_context_id'],
              equals(_forecastContextId),
            );
            expect(parameters['target_cycle_id'], equals(_targetCycleId));
            return <PostgresRow>[_snapshotRow()];
          }
          if (sql.contains('insert into public.weekly_plan_snapshot_days')) {
            expect(parameters['snapshot_id'], equals(_snapshotId));
            return <PostgresRow>[_dayRow()];
          }
          if (sql.contains('insert into public.weekly_plan_audit_events')) {
            return <PostgresRow>[
              <String, Object?>{'audit_event_id': 'audit'},
            ];
          }
          return const <PostgresRow>[];
        },
      );
      final wrapper = TenantTransactionWrapper(pool);
      final gateway = RepositoryWeeklyPlanGateway(
        snapshotRepository: weekly_snapshot.WeeklyPlanSnapshotRepository(
          wrapper,
        ),
        forecastContextRepository: weekly_forecast.ForecastContextRepository(
          wrapper,
        ),
      );

      final row = await gateway.lockSnapshot(request: _lockRequest());

      expect(row.snapshotId, equals(_snapshotId));
      expect(row.forecastContextId, equals(_forecastContextId));
      expect(row.dayRows.single.businessDate, equals('2026-05-04'));
      expect(pool.transactions, hasLength(2));
      expect(
        pool.transactions.first.executedSql.any(
          (sql) => sql.contains('insert into public.forecast_contexts'),
        ),
        isTrue,
      );
      expect(
        pool.transactions.last.executedSql.any(
          (sql) => sql.contains('insert into public.weekly_plan_snapshots'),
        ),
        isTrue,
      );
    },
  );
}

WeeklyPlanLockRequest _lockRequest() {
  return WeeklyPlanLockRequest(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    weekStartDate: '2026-05-04',
    weekEndDate: '2026-05-10',
    targetCycleId: _targetCycleId,
    forecastContextId: null,
    embeddedForecastContext: ForecastContextPayload(
      restaurantId: _restaurantId,
      anchorBusinessDate: '2026-05-04',
      baselineTotalCovers: 7200,
      baselineWeeklyAvgCovers: 840,
      baselineWeeksRepresented: 8.571,
      recentThreeWeekTotalCovers: 2640,
      recentThreeWeekWeeklyAvgCovers: 880,
      recentTrendDeltaCovers: 40,
      resolvedWeeklyForecastCovers: 860,
      coversSource: 'appDerivedFromHistoricalAverage',
      builtAt: DateTime.utc(2026, 5, 6, 18),
    ),
    forecastCovers: 860,
    forecastSales: 36550,
    requiredFohHours: 74,
    requiredBohHours: 55,
    theoreticalFohLaborDollars: 1332,
    theoreticalBohLaborDollars: 1100,
    coversSource: 'appDerivedFromHistoricalAverage',
    salesSource: 'appDerivedFromCoversAndPpa',
    dayRows: const <WeeklyPlanDayPayload>[
      WeeklyPlanDayPayload(
        day: 'Monday',
        businessDate: '2026-05-04',
        forecastCovers: 120,
        forecastSales: 5100,
        requiredFohHours: 10,
        requiredBohHours: 8,
      ),
    ],
    reason: 'manager locked current week',
    actorUserId: _userId,
    actorKind: 'operator_user',
    idempotencyKey: 'idem-weekly-lock',
    requestHash: 'request-hash',
    metadata: const <String, Object?>{},
  );
}

PostgresRow _forecastContextRow() {
  return <String, Object?>{
    'forecast_context_id': _forecastContextId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'restaurant_id': _restaurantId,
    'anchor_business_date': '2026-05-04',
    'baseline_total_covers': 7200,
    'baseline_weekly_avg_covers': 840,
    'baseline_weeks_represented': 8.571,
    'recent_three_week_total_covers': 2640,
    'recent_three_week_weekly_avg_covers': 880,
    'recent_trend_delta_covers': 40,
    'resolved_weekly_forecast_covers': 860,
    'target_ppa': 42.5,
    'forecast_sales': 36550.0,
    'required_foh_hours': 74.0,
    'required_boh_hours': 55.0,
    'theoretical_labor_dollars': 2432.0,
    'covers_source': 'appDerivedFromHistoricalAverage',
    'sales_source': 'appDerivedFromCoversAndPpa',
    'target_cycle_id': _targetCycleId,
    'target_profile_id': null,
    'context_status': 'closed',
    'built_at': DateTime.utc(2026, 5, 6, 18),
    'closed_at': DateTime.utc(2026, 5, 6, 18, 1),
    'idempotency_key': 'idem-weekly-lock',
    'request_hash': 'request-hash',
    'metadata': <String, Object?>{},
    'created_by': _userId,
    'created_at': DateTime.utc(2026, 5, 6, 18),
    'updated_at': DateTime.utc(2026, 5, 6, 18),
  };
}

PostgresRow _snapshotRow() {
  return <String, Object?>{
    'snapshot_id': _snapshotId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'restaurant_id': _restaurantId,
    'week_start_date': '2026-05-04',
    'week_end_date': '2026-05-10',
    'week_key': '2026-05-04_2026-05-10',
    'target_cycle_id': _targetCycleId,
    'forecast_context_id': _forecastContextId,
    'forecast_covers': 860,
    'forecast_sales': 36550.0,
    'required_foh_hours': 74.0,
    'required_boh_hours': 55.0,
    'theoretical_foh_labor_dollars': 1332.0,
    'theoretical_boh_labor_dollars': 1100.0,
    'covers_source': 'appDerivedFromHistoricalAverage',
    'sales_source': 'appDerivedFromCoversAndPpa',
    'snapshot_status': 'active',
    'source': 'server_lock',
    'generated_at': DateTime.utc(2026, 5, 6, 18),
    'locked_at': DateTime.utc(2026, 5, 6, 18),
    'superseded_at': null,
    'superseded_by_snapshot_id': null,
    'supersedes_snapshot_id': null,
    'unlocked_at': null,
    'unlocked_by_user_id': null,
    'replacement_reason': 'manager locked current week',
    'idempotency_key': 'idem-weekly-lock',
    'request_hash': 'request-hash',
    'metadata': <String, Object?>{},
    'created_by': _userId,
    'created_at': DateTime.utc(2026, 5, 6, 18),
    'updated_at': DateTime.utc(2026, 5, 6, 18),
  };
}

PostgresRow _dayRow() {
  return <String, Object?>{
    'snapshot_day_id': '77777777-7777-7777-7777-777777777777',
    'operator_id': _operatorId,
    'location_id': _locationId,
    'snapshot_id': _snapshotId,
    'restaurant_id': _restaurantId,
    'day_index': 0,
    'day_label': 'Monday',
    'business_date': '2026-05-04',
    'forecast_covers': 120,
    'forecast_sales': 5100.0,
    'required_foh_hours': 10.0,
    'required_boh_hours': 8.0,
    'created_at': DateTime.utc(2026, 5, 6, 18),
    'updated_at': DateTime.utc(2026, 5, 6, 18),
  };
}

class _RecordingPool implements PostgresPool {
  _RecordingPool({required this.onQuery});

  final List<PostgresRow> Function(String sql, PostgresParameters parameters)
  onQuery;
  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction(this.pool);

  final _RecordingPool pool;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  var _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return pool.onQuery(sql, parameters);
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
