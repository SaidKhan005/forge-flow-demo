// Phase 8 weekly plan server truth Postgres schema/repository tests.
//
// Local-only contract tests. These pin the additive migration shape and the
// repository SQL sent through TenantTransactionWrapper; no live database needed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/forecast_context_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/rls_policy_lint.dart';

const String _migrationPath =
    'db/migrations/202605080100_phase_8_weekly_plan_server_truth.sql';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _oldSnapshotId = '44444444-4444-4444-4444-444444444444';
const String _snapshotId = '55555555-5555-5555-5555-555555555555';
const String _snapshotDayId = '66666666-6666-6666-6666-666666666666';
const String _targetCycleId = '77777777-7777-7777-7777-777777777777';
const String _forecastContextId = '88888888-8888-8888-8888-888888888888';
const String _targetProfileId = '99999999-9999-9999-9999-999999999999';
const String _restaurantId = 'demo_restaurant';

void main() {
  final migration = File(
    _migrationPath,
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final normalized = migration.toLowerCase();
  final compact = migration.replaceAll(RegExp(r'\s+'), ' ');

  group('Phase 8 weekly plan server truth migration shape', () {
    test('creates additive weekly plan and forecast tables', () {
      for (final table in <String>[
        'forecast_contexts',
        'weekly_plan_snapshots',
        'weekly_plan_snapshot_days',
        'weekly_plan_audit_events',
      ]) {
        expect(
          normalized,
          contains('create table if not exists public.$table'),
          reason: 'missing table $table',
        );
      }
      expect(normalized, isNot(contains('create table mobile_')));
      expect(normalized, isNot(contains('drop table')));
    });

    test(
      'weekly snapshots preserve superseded rows and target-cycle truth',
      () {
        final block = _tableBlock(migration, 'weekly_plan_snapshots');
        for (final fragment in <String>[
          'operator_id uuid not null',
          'location_id uuid not null',
          'restaurant_id text not null',
          'week_start_date date not null',
          'week_end_date date not null',
          'week_key text not null',
          'target_cycle_id uuid not null',
          'forecast_context_id uuid',
          'forecast_covers integer not null',
          'forecast_sales numeric(14, 4) not null',
          'required_foh_hours numeric(12, 4) not null',
          'required_boh_hours numeric(12, 4) not null',
          'theoretical_foh_labor_dollars numeric(14, 4) not null',
          'theoretical_boh_labor_dollars numeric(14, 4) not null',
          "snapshot_status in ('active', 'superseded', 'unlocked')",
          'superseded_by_snapshot_id uuid',
          'supersedes_snapshot_id uuid',
          'idempotency_key text not null',
          'request_hash text not null',
        ]) {
          expect(block, contains(fragment));
        }
        expect(
          block,
          contains('references public.target_cycles(operator_id, cycle_id)'),
        );
        expect(block, contains('on delete restrict'));
      },
    );

    test('forecast context keeps explainable demand and labor fields', () {
      final block = _tableBlock(migration, 'forecast_contexts');
      for (final fragment in <String>[
        'anchor_business_date date not null',
        'baseline_total_covers integer not null',
        'baseline_weekly_avg_covers integer not null',
        'baseline_weeks_represented numeric(12, 4) not null',
        'recent_three_week_total_covers integer',
        'recent_three_week_weekly_avg_covers integer',
        'recent_trend_delta_covers integer',
        'resolved_weekly_forecast_covers integer not null',
        'target_ppa numeric(12, 4) not null',
        'forecast_sales numeric(14, 4) not null',
        'required_foh_hours numeric(12, 4) not null',
        'required_boh_hours numeric(12, 4) not null',
        'theoretical_labor_dollars numeric(14, 4) not null',
        "context_status in ('open', 'closed')",
        'closed_at timestamptz',
      ]) {
        expect(block, contains(fragment));
      }
      expect(migration, contains('forecast_contexts_prevent_closed_mutation'));
    });

    test(
      'single active weekly snapshot is enforced by partial unique index',
      () {
        expect(
          compact,
          contains(
            'create unique index if not exists '
            'weekly_plan_snapshots_active_week_uq on '
            'public.weekly_plan_snapshots ( operator_id, location_id, '
            'restaurant_id, week_start_date ) where snapshot_status = '
            "'active'",
          ),
        );
      },
    );

    test('operator-leading indexes support RLS and sync hot paths', () {
      for (final indexShape in <String>[
        'on public.forecast_contexts ( operator_id, location_id, restaurant_id, anchor_business_date desc',
        'on public.forecast_contexts ( operator_id, location_id, updated_at desc',
        'on public.weekly_plan_snapshots ( operator_id, location_id, restaurant_id, week_start_date desc',
        'on public.weekly_plan_snapshots ( operator_id, location_id, updated_at desc',
        'on public.weekly_plan_snapshot_days ( operator_id, location_id, snapshot_id, day_index',
        'on public.weekly_plan_audit_events ( operator_id, location_id, created_at desc',
      ]) {
        expect(compact, contains(indexShape));
      }
    });

    test('RLS policies use wrapper functions and scoped grants', () {
      expect(normalized, isNot(contains("current_setting('app.")));
      for (final policy in <String>[
        'forecast_contexts_per_tenant_location',
        'weekly_plan_snapshots_per_tenant_location',
        'weekly_plan_snapshot_days_per_tenant_location',
        'weekly_plan_audit_events_per_tenant_location',
      ]) {
        expect(migration, contains('create policy "$policy"'));
      }
      expect(
        migration,
        contains('operator_id = public.app_current_operator()'),
      );
      expect(
        migration,
        contains('location_id = public.app_current_location()'),
      );
      for (final table in <String>[
        'forecast_contexts',
        'weekly_plan_snapshots',
        'weekly_plan_snapshot_days',
        'weekly_plan_audit_events',
      ]) {
        expect(compact, contains('on public.$table to service_role'));
        expect(compact, contains('on public.$table to forge_admin'));
      }
    });

    test('migration passes policy-aware RLS lint', () {
      final result = RlsPolicyLintRunner(
        files: <String, String>{_migrationPath: migration},
        allowlist: const <String>{},
      ).run();
      expect(result.isClean, isTrue, reason: '${result.violations}');
    });
  });

  group('ForecastContextRepository', () {
    test(
      'upsertContext writes explainable context and audit in tenant tx',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, parameters) {
            if (sql.contains('idempotency_key = @idempotency_key')) {
              return const <PostgresRow>[];
            }
            if (sql.contains('anchor_business_date = @anchor_business_date')) {
              return const <PostgresRow>[];
            }
            if (sql.contains('insert into public.forecast_contexts')) {
              return <PostgresRow>[_forecastContextRow()];
            }
            if (sql.contains('insert into public.weekly_plan_audit_events')) {
              return <PostgresRow>[
                <String, Object?>{'audit_event_id': 'audit'},
              ];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = ForecastContextRepository(TenantTransactionWrapper(pool));

        final row = await repo.upsertContext(
          context: _forecastContextWrite(),
          reason: 'build weekly forecast context',
        );

        expect(row.forecastContextId, equals(_forecastContextId));
        expect(row.baselineTotalCovers, equals(840));
        final tx = pool.transactions.single;
        expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
        final writeSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.forecast_contexts'),
        );
        expect(
          writeSql,
          contains('on conflict on constraint forecast_contexts_anchor_uq'),
        );
        expect(writeSql, contains('where public.forecast_contexts.closed_at'));
        final writeParams = tx.parameters[tx.executedSql.indexOf(writeSql)];
        expect(writeParams['target_ppa'], equals(42.5));
        expect(writeParams['theoretical_labor_dollars'], equals(4080.0));

        final auditSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.weekly_plan_audit_events'),
        );
        final auditParams = tx.parameters[tx.executedSql.indexOf(auditSql)];
        expect(auditParams['event_type'], equals('forecast_context_written'));
        expect(tx.commitCount, equals(1));
      },
    );

    test('closed context guard rejects non-idempotent rewrite', () async {
      final pool = _RecordingPool(
        onQuery: (sql, parameters) {
          if (sql.contains('idempotency_key = @idempotency_key')) {
            return const <PostgresRow>[];
          }
          if (sql.contains('anchor_business_date = @anchor_business_date')) {
            return <PostgresRow>[
              _forecastContextRow(
                contextStatus: 'closed',
                closedAt: DateTime.utc(2026, 5, 6, 23),
              ),
            ];
          }
          return const <PostgresRow>[];
        },
      );
      final repo = ForecastContextRepository(TenantTransactionWrapper(pool));

      await expectLater(
        repo.upsertContext(
          context: _forecastContextWrite(idempotencyKey: 'forecast-new-key'),
          reason: 'blocked closed context rewrite',
        ),
        throwsA(isA<ForecastContextClosed>()),
      );
      expect(pool.transactions.single.rollbackCount, equals(1));
    });
  });

  group('WeeklyPlanSnapshotRepository', () {
    test(
      'lockOrReplaceSnapshot supersedes active row, inserts days, audits',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, parameters) {
            if (sql.contains('idempotency_key = @idempotency_key')) {
              return const <PostgresRow>[];
            }
            if (sql.contains("s.snapshot_status = 'active'")) {
              return <PostgresRow>[_snapshotRow(snapshotId: _oldSnapshotId)];
            }
            if (sql.contains('insert into public.weekly_plan_snapshots')) {
              return <PostgresRow>[
                _snapshotRow(
                  snapshotId: _snapshotId,
                  supersedesSnapshotId: _oldSnapshotId,
                  source: 'server_replace',
                ),
              ];
            }
            if (sql.contains('insert into public.weekly_plan_snapshot_days')) {
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
        final repo = WeeklyPlanSnapshotRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repo.lockOrReplaceSnapshot(
          snapshot: _snapshotWrite(source: 'server_replace'),
          days: <WeeklyPlanSnapshotDayPostgresWrite>[_dayWrite()],
          reason: 'manager locked replacement weekly plan',
        );

        expect(row.snapshotId, equals(_snapshotId));
        expect(row.supersedesSnapshotId, equals(_oldSnapshotId));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.any(
            (sql) =>
                sql.startsWith('update public.weekly_plan_snapshots') &&
                sql.contains("snapshot_status = 'superseded'"),
          ),
          isTrue,
        );
        final insertSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.weekly_plan_snapshots'),
        );
        final insertParams = tx.parameters[tx.executedSql.indexOf(insertSql)];
        expect(insertParams['target_cycle_id'], equals(_targetCycleId));
        expect(insertParams['forecast_context_id'], equals(_forecastContextId));
        expect(insertParams['supersedes_snapshot_id'], equals(_oldSnapshotId));

        expect(
          tx.executedSql.any(
            (sql) =>
                sql.contains('insert into public.weekly_plan_snapshot_days'),
          ),
          isTrue,
        );
        final auditSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.weekly_plan_audit_events'),
        );
        final auditParams = tx.parameters[tx.executedSql.indexOf(auditSql)];
        expect(auditParams['event_type'], equals('weekly_plan_replaced'));
        final afterSnapshot =
            jsonDecode(auditParams['after_snapshot']! as String)
                as Map<String, dynamic>;
        expect(afterSnapshot['target_cycle_id'], equals(_targetCycleId));
        expect(tx.commitCount, equals(1));
      },
    );

    test(
      'idempotency replay returns existing snapshot without audit',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, parameters) {
            if (sql.contains('idempotency_key = @idempotency_key')) {
              return <PostgresRow>[_snapshotRow(snapshotId: _snapshotId)];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = WeeklyPlanSnapshotRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repo.lockOrReplaceSnapshot(
          snapshot: _snapshotWrite(),
          reason: 'replay weekly plan lock',
        );

        expect(row.snapshotId, equals(_snapshotId));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.any(
            (sql) => sql.contains('insert into public.weekly_plan_snapshots'),
          ),
          isFalse,
        );
        expect(
          tx.executedSql.any(
            (sql) =>
                sql.contains('insert into public.weekly_plan_audit_events'),
          ),
          isFalse,
        );
      },
    );

    test('unlockActiveSnapshot marks active row and writes audit', () async {
      final pool = _RecordingPool(
        onQuery: (sql, parameters) {
          if (sql.contains('from public.weekly_plan_audit_events')) {
            return const <PostgresRow>[];
          }
          if (sql.contains("s.snapshot_status = 'active'")) {
            return <PostgresRow>[_snapshotRow(snapshotId: _snapshotId)];
          }
          if (sql.startsWith('update public.weekly_plan_snapshots') &&
              sql.contains("snapshot_status = 'unlocked'")) {
            return <PostgresRow>[
              _snapshotRow(
                snapshotId: _snapshotId,
                snapshotStatus: 'unlocked',
                unlockedAt: DateTime.utc(2026, 5, 6, 18),
                unlockedByUserId: _userId,
              ),
            ];
          }
          if (sql.contains('insert into public.weekly_plan_audit_events')) {
            return <PostgresRow>[
              <String, Object?>{'audit_event_id': 'audit'},
            ];
          }
          return const <PostgresRow>[];
        },
      );
      final repo = WeeklyPlanSnapshotRepository(TenantTransactionWrapper(pool));

      final row = await repo.unlockActiveSnapshot(
        operatorId: _operatorId,
        locationId: _locationId,
        restaurantId: _restaurantId,
        weekStartDate: '2026-05-04',
        actorUserId: _userId,
        reason: 'manager unlocked plan',
        idempotencyKey: 'unlock-key-1',
      );

      expect(row!.snapshotStatus, equals('unlocked'));
      final tx = pool.transactions.single;
      final auditSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('insert into public.weekly_plan_audit_events'),
      );
      final auditParams = tx.parameters[tx.executedSql.indexOf(auditSql)];
      expect(auditParams['event_type'], equals('weekly_plan_unlocked'));
    });

    test('listUpdatedSince exposes only active rows for mobile sync', () async {
      final pool = _RecordingPool(
        onQuery: (sql, parameters) {
          if (sql.contains('from public.weekly_plan_snapshots s')) {
            expect(sql, contains("s.snapshot_status = 'active'"));
            return <PostgresRow>[_snapshotRow(snapshotId: _snapshotId)];
          }
          return const <PostgresRow>[];
        },
      );
      final repo = WeeklyPlanSnapshotRepository(TenantTransactionWrapper(pool));

      final rows = await repo.listUpdatedSince(
        operatorId: _operatorId,
        locationId: _locationId,
        updatedAfter: DateTime.utc(2026, 5, 6),
        userId: _userId,
      );

      expect(rows.single.snapshotId, equals(_snapshotId));
    });
  });
}

ForecastContextPostgresWrite _forecastContextWrite({
  String idempotencyKey = 'forecast-key-1',
}) {
  return ForecastContextPostgresWrite(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    forecastContextId: _forecastContextId,
    anchorBusinessDate: '2026-05-06',
    baselineTotalCovers: 840,
    baselineWeeklyAvgCovers: 98,
    baselineWeeksRepresented: 8.5714,
    recentThreeWeekTotalCovers: 330,
    recentThreeWeekWeeklyAvgCovers: 110,
    recentTrendDeltaCovers: 12,
    resolvedWeeklyForecastCovers: 104,
    targetPpa: 42.5,
    forecastSales: 4420.0,
    requiredFohHours: 120.0,
    requiredBohHours: 80.0,
    theoreticalLaborDollars: 4080.0,
    coversSource: 'appDerivedFromHistoricalAverage',
    salesSource: 'appDerivedFromCoversAndPpa',
    targetCycleId: _targetCycleId,
    targetProfileId: _targetProfileId,
    builtAt: DateTime.utc(2026, 5, 6, 12),
    idempotencyKey: idempotencyKey,
    requestHash: 'forecast-hash-1',
    metadata: const <String, Object?>{'window': '60d'},
    createdBy: _userId,
  );
}

WeeklyPlanSnapshotPostgresWrite _snapshotWrite({
  String source = 'server_lock',
}) {
  return WeeklyPlanSnapshotPostgresWrite(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    snapshotId: _snapshotId,
    weekStartDate: '2026-05-04',
    weekEndDate: '2026-05-10',
    weekKey: '2026-05-04_2026-05-10',
    targetCycleId: _targetCycleId,
    forecastContextId: _forecastContextId,
    forecastCovers: 104,
    forecastSales: 4420.0,
    requiredFohHours: 120.0,
    requiredBohHours: 80.0,
    theoreticalFohLaborDollars: 2190.0,
    theoreticalBohLaborDollars: 1768.0,
    coversSource: 'appDerivedFromHistoricalAverage',
    salesSource: 'appDerivedFromCoversAndPpa',
    source: source,
    generatedAt: DateTime.utc(2026, 5, 6, 12, 5),
    lockedAt: DateTime.utc(2026, 5, 6, 12, 10),
    replacementReason: source == 'server_replace' ? 'replacement' : null,
    idempotencyKey: 'snapshot-key-1',
    requestHash: 'snapshot-hash-1',
    metadata: const <String, Object?>{'source': 'test'},
    createdBy: _userId,
  );
}

WeeklyPlanSnapshotDayPostgresWrite _dayWrite() {
  return const WeeklyPlanSnapshotDayPostgresWrite(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    dayIndex: 0,
    dayLabel: 'Monday',
    businessDate: '2026-05-04',
    forecastCovers: 14,
    forecastSales: 595.0,
    requiredFohHours: 16.0,
    requiredBohHours: 11.0,
  );
}

PostgresRow _forecastContextRow({
  String contextStatus = 'open',
  DateTime? closedAt,
}) {
  return <String, Object?>{
    'forecast_context_id': _forecastContextId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'restaurant_id': _restaurantId,
    'anchor_business_date': '2026-05-06',
    'baseline_total_covers': 840,
    'baseline_weekly_avg_covers': 98,
    'baseline_weeks_represented': 8.5714,
    'recent_three_week_total_covers': 330,
    'recent_three_week_weekly_avg_covers': 110,
    'recent_trend_delta_covers': 12,
    'resolved_weekly_forecast_covers': 104,
    'target_ppa': 42.5,
    'forecast_sales': 4420.0,
    'required_foh_hours': 120.0,
    'required_boh_hours': 80.0,
    'theoretical_labor_dollars': 4080.0,
    'covers_source': 'appDerivedFromHistoricalAverage',
    'sales_source': 'appDerivedFromCoversAndPpa',
    'target_cycle_id': _targetCycleId,
    'target_profile_id': _targetProfileId,
    'context_status': contextStatus,
    'built_at': DateTime.utc(2026, 5, 6, 12),
    'closed_at': closedAt,
    'idempotency_key': 'forecast-key-1',
    'request_hash': 'forecast-hash-1',
    'metadata': <String, Object?>{'window': '60d'},
    'created_by': _userId,
    'created_at': DateTime.utc(2026, 5, 6, 12),
    'updated_at': DateTime.utc(2026, 5, 6, 12),
  };
}

PostgresRow _snapshotRow({
  required String snapshotId,
  String snapshotStatus = 'active',
  String source = 'server_lock',
  String? supersedesSnapshotId,
  DateTime? supersededAt,
  String? supersededBySnapshotId,
  DateTime? unlockedAt,
  String? unlockedByUserId,
}) {
  return <String, Object?>{
    'snapshot_id': snapshotId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'restaurant_id': _restaurantId,
    'week_start_date': '2026-05-04',
    'week_end_date': '2026-05-10',
    'week_key': '2026-05-04_2026-05-10',
    'target_cycle_id': _targetCycleId,
    'forecast_context_id': _forecastContextId,
    'forecast_covers': 104,
    'forecast_sales': 4420.0,
    'required_foh_hours': 120.0,
    'required_boh_hours': 80.0,
    'theoretical_foh_labor_dollars': 2190.0,
    'theoretical_boh_labor_dollars': 1768.0,
    'covers_source': 'appDerivedFromHistoricalAverage',
    'sales_source': 'appDerivedFromCoversAndPpa',
    'snapshot_status': snapshotStatus,
    'source': source,
    'generated_at': DateTime.utc(2026, 5, 6, 12, 5),
    'locked_at': DateTime.utc(2026, 5, 6, 12, 10),
    'superseded_at': supersededAt,
    'superseded_by_snapshot_id': supersededBySnapshotId,
    'supersedes_snapshot_id': supersedesSnapshotId,
    'unlocked_at': unlockedAt,
    'unlocked_by_user_id': unlockedByUserId,
    'replacement_reason': source == 'server_replace' ? 'replacement' : null,
    'idempotency_key': 'snapshot-key-1',
    'request_hash': 'snapshot-hash-1',
    'metadata': <String, Object?>{'source': 'test'},
    'created_by': _userId,
    'created_at': DateTime.utc(2026, 5, 6, 12),
    'updated_at': DateTime.utc(2026, 5, 6, 12),
  };
}

PostgresRow _dayRow() {
  return <String, Object?>{
    'snapshot_day_id': _snapshotDayId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'snapshot_id': _snapshotId,
    'restaurant_id': _restaurantId,
    'day_index': 0,
    'day_label': 'Monday',
    'business_date': '2026-05-04',
    'forecast_covers': 14,
    'forecast_sales': 595.0,
    'required_foh_hours': 16.0,
    'required_boh_hours': 11.0,
    'created_at': DateTime.utc(2026, 5, 6, 12),
    'updated_at': DateTime.utc(2026, 5, 6, 12),
  };
}

String _tableBlock(String sql, String tableName) {
  final start = sql.indexOf('create table if not exists public.$tableName');
  if (start < 0) return '';
  final rest = sql.substring(start);
  final end = rest.indexOf('\n);');
  if (end < 0) return rest;
  return rest.substring(0, end + 3);
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
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

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
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}
