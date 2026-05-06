// Phase 8 star/target truth Postgres schema/repository tests.
//
// Local-only contract tests. These do not need a live database; they pin the
// migration shape and the repository SQL sent through TenantTransactionWrapper.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/selected_star_shift_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/rls_policy_lint.dart';

const String _migrationPath =
    'db/migrations/202605061900_phase_8_star_target_truth.sql';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _decisionId = '44444444-4444-4444-4444-444444444444';
const String _oldCycleId = '55555555-5555-5555-5555-555555555555';
const String _cycleId = '66666666-6666-6666-6666-666666666666';
const String _profileId = '77777777-7777-7777-7777-777777777777';
const String _profileVersionId = '88888888-8888-8888-8888-888888888888';
const String _restaurantId = 'demo_restaurant';

void main() {
  final migration = File(
    _migrationPath,
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final normalized = migration.toLowerCase();
  final compact = migration.replaceAll(RegExp(r'\s+'), ' ');

  group('Phase 8 star/target truth migration shape', () {
    test('creates additive server truth tables only', () {
      for (final table in <String>[
        'selected_star_shift_decisions',
        'target_cycles',
        'active_target_profiles',
        'target_profile_versions',
        'star_target_audit_events',
      ]) {
        expect(
          normalized,
          contains('create table if not exists public.$table'),
          reason: 'missing table $table',
        );
      }
      expect(normalized, isNot(contains('create table baseline_selected')));
      expect(normalized, isNot(contains('create table mobile_')));
      expect(normalized, isNot(contains('weekly_plan_snapshots')));
    });

    test('selected-star decisions preserve manager/admin provenance', () {
      final block = _tableBlock(migration, 'selected_star_shift_decisions');
      for (final fragment in <String>[
        'operator_id uuid not null',
        'location_id uuid not null',
        'restaurant_id text not null',
        'record_key text not null',
        'week_id text not null',
        'day_label text not null',
        'daypart text not null',
        'business_date date not null',
        "'manager_cleared'",
        "'admin_selected'",
        "'admin_cleared'",
        "'manager_selected'",
        "decision_source in ('manager', 'admin')",
        'recommendation_reference_id text',
        'candidate_snapshot jsonb not null',
        'idempotency_key text not null',
        'request_hash text not null',
        'updated_at timestamptz not null default now()',
      ]) {
        expect(block, contains(fragment));
      }
      expect(block, contains('selected_star_shift_decisions_source_matches'));
    });

    test('target cycles mirror mobile cycle fields plus server guard data', () {
      final block = _tableBlock(migration, 'target_cycles');
      for (final fragment in <String>[
        'restaurant_id text not null',
        "'manager_override'",
        "'admin_replacement'",
        "'recommended'",
        'effective_start date not null',
        'effective_end date not null',
        'calibration_window_start date not null',
        'calibration_window_end date not null',
        'target_cplh numeric(12, 4) not null',
        'target_splh numeric(12, 4) not null',
        'target_ppa numeric(12, 4) not null',
        'foh_wage numeric(12, 4) not null',
        'boh_wage numeric(12, 4) not null',
        'opz_floor_cplh numeric(12, 4) not null',
        'opz_ceiling_cplh numeric(12, 4) not null',
        'manager_override_used boolean not null default false',
        'manager_override_at timestamptz',
        'admin_replaced_at timestamptz',
        'selected_record_keys jsonb not null',
        'selection_decision_ids jsonb not null',
        'deactivated_at timestamptz',
      ]) {
        expect(block, contains(fragment));
      }
    });

    test('active profile and version tables mirror cache shapes', () {
      final activeBlock = _tableBlock(migration, 'active_target_profiles');
      final versionBlock = _tableBlock(migration, 'target_profile_versions');
      for (final block in <String>[activeBlock, versionBlock]) {
        for (final fragment in <String>[
          'restaurant_id text not null',
          'target_cycle_id uuid not null',
          "'cycle_manager_override'",
          "'cycle_admin_replacement'",
          "'cycle_recommended'",
          'target_cplh numeric(12, 4) not null',
          'target_splh numeric(12, 4) not null',
          'target_ppa numeric(12, 4) not null',
          'theoretical_foh_labor_pct numeric(12, 4) not null',
          'theoretical_boh_labor_pct numeric(12, 4) not null',
          'theoretical_labor_pct numeric(12, 4) not null',
          'updated_at timestamptz not null default now()',
        ]) {
          expect(block, contains(fragment));
        }
      }
      expect(activeBlock, contains('target_profile_version_id uuid not null'));
      expect(
        activeBlock,
        contains(
          "projection_source text not null default 'server_target_cycle'",
        ),
      );
    });

    test('operator-leading indexes support RLS and sync hot paths', () {
      for (final indexShape in <String>[
        'on public.target_cycles ( operator_id, location_id, restaurant_id )',
        'on public.target_cycles ( operator_id, location_id, updated_at desc',
        'on public.selected_star_shift_decisions ( operator_id, location_id, restaurant_id, record_key',
        'on public.selected_star_shift_decisions ( operator_id, location_id, updated_at desc',
        'on public.active_target_profiles ( operator_id, location_id, updated_at desc',
        'on public.target_profile_versions ( operator_id, location_id, updated_at desc',
        'on public.star_target_audit_events ( operator_id, location_id, created_at desc',
      ]) {
        expect(compact, contains(indexShape));
      }
    });

    test('RLS policies use wrapper functions and scoped grants', () {
      expect(normalized, isNot(contains("current_setting('app.")));
      for (final policy in <String>[
        'target_cycles_per_tenant_location',
        'selected_star_shift_decisions_per_tenant_location',
        'active_target_profiles_per_tenant_location',
        'target_profile_versions_per_tenant_location',
        'star_target_audit_events_per_tenant_location',
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
        'target_cycles',
        'selected_star_shift_decisions',
        'active_target_profiles',
        'target_profile_versions',
        'star_target_audit_events',
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

    test('does not introduce timezone-naive timestamps', () {
      expect(normalized, isNot(contains('timestamp without time zone')));
    });
  });

  group('SelectedStarShiftRepository', () {
    test(
      'records idempotent manager selection and audit in tenant tx',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, parameters) {
            if (sql.contains(
              'insert into public.selected_star_shift_decisions',
            )) {
              return <PostgresRow>[_decisionRow(inserted: true)];
            }
            if (sql.contains('insert into public.star_target_audit_events')) {
              return <PostgresRow>[
                <String, Object?>{'audit_event_id': 'audit-1'},
              ];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = SelectedStarShiftRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repo.recordDecision(decision: _decisionWrite());

        expect(row.decisionId, equals(_decisionId));
        expect(row.decisionType, equals('manager_selected'));
        final tx = pool.transactions.single;
        expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
        final writeSql = tx.executedSql.firstWhere(
          (sql) =>
              sql.contains('insert into public.selected_star_shift_decisions'),
        );
        expect(
          writeSql.replaceAll(RegExp(r'\s+'), ' '),
          contains(
            'on conflict (operator_id, location_id, idempotency_key) do nothing',
          ),
        );
        final params = tx.parameters[tx.executedSql.indexOf(writeSql)];
        expect(params['recommendation_reference_id'], equals('rec-123'));
        expect(params['decision_source'], equals('manager'));
        expect(params['candidate_snapshot'], contains('actual_labor_pct'));

        final auditSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.star_target_audit_events'),
        );
        final auditParams = tx.parameters[tx.executedSql.indexOf(auditSql)];
        expect(auditParams['event_type'], equals('selected_star_selected'));
        final snapshot =
            jsonDecode(auditParams['after_snapshot']! as String)
                as Map<String, dynamic>;
        expect(snapshot['recommendation_reference_id'], equals('rec-123'));
        expect(tx.commitCount, equals(1));
      },
    );

    test('invalid tenant UUID opens no transaction', () {
      final pool = _RecordingPool(onQuery: (_, __) => const <PostgresRow>[]);
      final repo = SelectedStarShiftRepository(TenantTransactionWrapper(pool));

      expect(
        () => repo.recordDecision(
          decision: _decisionWrite(operatorId: 'not-a-uuid'),
        ),
        throwsA(isA<TenantContextValidationError>()),
      );
      expect(pool.transactions, isEmpty);
    });
  });

  group('TargetCycleRepository', () {
    test(
      'replaceActiveCycle deactivates prior active cycle and audits',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, parameters) {
            if (sql.contains('idempotency_key = @idempotency_key')) {
              return const <PostgresRow>[];
            }
            if (sql.contains('deactivated_at is null') &&
                sql.contains('from public.target_cycles c')) {
              return <PostgresRow>[_cycleRow(cycleId: _oldCycleId)];
            }
            if (sql.contains('insert into public.target_cycles')) {
              return <PostgresRow>[
                _cycleRow(
                  cycleId: _cycleId,
                  source: 'manager_override',
                  managerOverrideUsed: true,
                  supersedesCycleId: _oldCycleId,
                ),
              ];
            }
            if (sql.contains('insert into public.star_target_audit_events')) {
              return <PostgresRow>[
                <String, Object?>{'audit_event_id': 'audit-2'},
              ];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = TargetCycleRepository(TenantTransactionWrapper(pool));

        final row = await repo.replaceActiveCycle(
          replacement: _cycleWrite(),
          reason: 'manager selected new star targets',
        );

        expect(row.cycleId, equals(_cycleId));
        expect(row.supersedesCycleId, equals(_oldCycleId));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql,
          contains(
            predicate<String>(
              (sql) => sql.startsWith('update public.target_cycles'),
            ),
          ),
        );
        final insertSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.target_cycles'),
        );
        final insertParams = tx.parameters[tx.executedSql.indexOf(insertSql)];
        expect(insertParams['supersedes_cycle_id'], equals(_oldCycleId));
        expect(insertParams['manager_override_used'], isTrue);
        expect(insertParams['selected_record_keys'], contains('2026-W19'));
      },
    );

    test(
      'server-side once-per-cycle guard rejects second manager override',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, parameters) {
            if (sql.contains('idempotency_key = @idempotency_key')) {
              return const <PostgresRow>[];
            }
            if (sql.contains('deactivated_at is null') &&
                sql.contains('from public.target_cycles c')) {
              return <PostgresRow>[
                _cycleRow(
                  cycleId: _oldCycleId,
                  source: 'manager_override',
                  managerOverrideUsed: true,
                ),
              ];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = TargetCycleRepository(TenantTransactionWrapper(pool));

        await expectLater(
          repo.replaceActiveCycle(
            replacement: _cycleWrite(),
            reason: 'blocked second override',
          ),
          throwsA(isA<TargetCycleManagerOverrideAlreadyUsed>()),
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.any(
            (sql) => sql.contains('insert into public.target_cycles'),
          ),
          isFalse,
        );
        expect(tx.rollbackCount, equals(1));
      },
    );
  });

  group('ActiveTargetProfileRepository', () {
    test(
      'upsertProjection writes active profile, version, and audit',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, parameters) {
            if (sql.contains('from public.active_target_profiles p')) {
              return const <PostgresRow>[];
            }
            if (sql.contains('insert into public.active_target_profiles')) {
              return <PostgresRow>[_activeProfileRow()];
            }
            if (sql.contains('insert into public.target_profile_versions')) {
              return <PostgresRow>[_profileVersionRow()];
            }
            if (sql.contains('insert into public.star_target_audit_events')) {
              return <PostgresRow>[
                <String, Object?>{'audit_event_id': 'audit-3'},
              ];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = ActiveTargetProfileRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repo.upsertProjection(
          profile: _profileWrite(),
          reason: 'project target cycle',
        );

        expect(row.targetProfileId, equals(_profileId));
        expect(row.targetProfileVersionId, equals(_profileVersionId));
        final tx = pool.transactions.single;
        final profileSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.active_target_profiles'),
        );
        expect(
          profileSql,
          contains(
            'on conflict on constraint active_target_profiles_restaurant_uq',
          ),
        );
        expect(
          tx.executedSql.any(
            (sql) => sql.contains('insert into public.target_profile_versions'),
          ),
          isTrue,
        );
        final auditSql = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.star_target_audit_events'),
        );
        final auditParams = tx.parameters[tx.executedSql.indexOf(auditSql)];
        expect(
          auditParams['event_type'],
          equals('active_target_profile_projected'),
        );
        expect(tx.commitCount, equals(1));
      },
    );
  });
}

SelectedStarShiftDecisionWrite _decisionWrite({
  String operatorId = _operatorId,
}) {
  return SelectedStarShiftDecisionWrite(
    operatorId: operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    recordKey: '2026-W19|Wednesday|dinner',
    weekId: '2026-W19',
    dayLabel: 'Wednesday',
    daypart: 'dinner',
    businessDate: '2026-05-06',
    servicePeriodKey: 'dinner',
    decisionType: 'manager_selected',
    decisionSource: 'manager',
    actorUserId: _userId,
    sourceSystem: 'pos',
    sourceShiftId: 'shift-1',
    sourceShiftRecordId: 'record-1',
    covers: 120,
    cplh: 12.4,
    splh: 152.0,
    ppa: 42.5,
    primaryLeverId: 'labor',
    actualLaborPct: 21.4,
    hasActualLaborPctTruth: true,
    recommendationReferenceId: 'rec-123',
    candidateSnapshot: const <String, Object?>{
      'actual_labor_pct': 21.4,
      'source': 'closed_shift_history',
    },
    reason: 'manager selected star',
    idempotencyKey: 'idem-select-1',
    requestHash: 'hash-select-1',
  );
}

TargetCyclePostgresWrite _cycleWrite() {
  return TargetCyclePostgresWrite(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    source: 'manager_override',
    effectiveStart: '2026-05-06',
    effectiveEnd: '2026-07-05',
    calibrationWindowStart: '2026-03-07',
    calibrationWindowEnd: '2026-05-05',
    targetCplh: 12.4,
    targetSplh: 152.0,
    targetPpa: 42.5,
    fohWage: 18.25,
    bohWage: 22.10,
    opzFloorCplh: 10.0,
    opzCeilingCplh: 14.0,
    managerOverrideUsed: true,
    managerOverrideAt: DateTime.utc(2026, 5, 6, 18),
    managerOverrideByUserId: _userId,
    selectedShiftCount: 1,
    selectedRecordKeys: const <String>['2026-W19|Wednesday|dinner'],
    selectionDecisionIds: const <String>[_decisionId],
    replacementReason: 'manager selected new star targets',
    idempotencyKey: 'idem-cycle-1',
    requestHash: 'hash-cycle-1',
    createdBy: _userId,
  );
}

ActiveTargetProfileProjectionWrite _profileWrite() {
  return ActiveTargetProfileProjectionWrite(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    targetProfileId: _profileId,
    targetCycleId: _cycleId,
    targetProfileVersionId: _profileVersionId,
    sourceType: 'cycle_manager_override',
    targetCplh: 12.4,
    targetSplh: 152.0,
    targetPpa: 42.5,
    fohWage: 18.25,
    bohWage: 22.10,
    opzFloorCplh: 10.0,
    opzCeilingCplh: 14.0,
    theoreticalFohLaborPct: 3.46,
    theoreticalBohLaborPct: 14.54,
    theoreticalLaborPct: 18.0,
    builtAt: DateTime.utc(2026, 5, 6, 18, 5),
    actorUserId: _userId,
  );
}

PostgresRow _decisionRow({bool inserted = false}) {
  return <String, Object?>{
    'inserted': inserted,
    'decision_id': _decisionId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'restaurant_id': _restaurantId,
    'record_key': '2026-W19|Wednesday|dinner',
    'week_id': '2026-W19',
    'day_label': 'Wednesday',
    'daypart': 'dinner',
    'business_date': '2026-05-06',
    'service_period_key': 'dinner',
    'target_cycle_id': null,
    'decision_type': 'manager_selected',
    'decision_source': 'manager',
    'actor_user_id': _userId,
    'decided_at': DateTime.utc(2026, 5, 6, 18),
    'source_system': 'pos',
    'source_shift_id': 'shift-1',
    'source_shift_record_id': 'record-1',
    'covers': 120,
    'cplh': 12.4,
    'splh': 152.0,
    'ppa': 42.5,
    'primary_lever_id': 'labor',
    'actual_labor_pct': 21.4,
    'has_actual_labor_pct_truth': true,
    'recommendation_reference_id': 'rec-123',
    'candidate_snapshot': <String, Object?>{'actual_labor_pct': 21.4},
    'reason': 'manager selected star',
    'idempotency_key': 'idem-select-1',
    'request_hash': 'hash-select-1',
    'metadata': <String, Object?>{},
    'created_at': DateTime.utc(2026, 5, 6, 18),
    'updated_at': DateTime.utc(2026, 5, 6, 18),
  };
}

PostgresRow _cycleRow({
  required String cycleId,
  String source = 'recommended',
  bool managerOverrideUsed = false,
  String? supersedesCycleId,
}) {
  return <String, Object?>{
    'cycle_id': cycleId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'restaurant_id': _restaurantId,
    'source': source,
    'effective_start': '2026-05-06',
    'effective_end': '2026-07-05',
    'calibration_window_start': '2026-03-07',
    'calibration_window_end': '2026-05-05',
    'target_cplh': 12.4,
    'target_splh': 152.0,
    'target_ppa': 42.5,
    'foh_wage': 18.25,
    'boh_wage': 22.10,
    'opz_floor_cplh': 10.0,
    'opz_ceiling_cplh': 14.0,
    'manager_override_used': managerOverrideUsed,
    'manager_override_at': managerOverrideUsed
        ? DateTime.utc(2026, 5, 6, 18)
        : null,
    'manager_override_by_user_id': managerOverrideUsed ? _userId : null,
    'admin_replaced_at': null,
    'admin_replaced_by_user_id': null,
    'supersedes_cycle_id': supersedesCycleId,
    'selected_shift_count': managerOverrideUsed ? 1 : 0,
    'selected_record_keys': managerOverrideUsed
        ? <String>['2026-W19|Wednesday|dinner']
        : <String>[],
    'selection_decision_ids': managerOverrideUsed
        ? <String>[_decisionId]
        : <String>[],
    'replacement_reason': managerOverrideUsed
        ? 'manager selected new star targets'
        : null,
    'idempotency_key': managerOverrideUsed
        ? 'idem-cycle-1'
        : 'idem-cycle-existing',
    'request_hash': managerOverrideUsed
        ? 'hash-cycle-1'
        : 'hash-cycle-existing',
    'created_by': _userId,
    'created_at': DateTime.utc(2026, 5, 6, 18),
    'updated_at': DateTime.utc(2026, 5, 6, 18),
    'deactivated_at': null,
  };
}

PostgresRow _activeProfileRow() {
  return <String, Object?>{
    'target_profile_id': _profileId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'restaurant_id': _restaurantId,
    'target_cycle_id': _cycleId,
    'target_profile_version_id': _profileVersionId,
    'source_type': 'cycle_manager_override',
    'target_cplh': 12.4,
    'target_splh': 152.0,
    'target_ppa': 42.5,
    'foh_wage': 18.25,
    'boh_wage': 22.10,
    'opz_floor_cplh': 10.0,
    'opz_ceiling_cplh': 14.0,
    'theoretical_foh_labor_pct': 3.46,
    'theoretical_boh_labor_pct': 14.54,
    'theoretical_labor_pct': 18.0,
    'built_at': DateTime.utc(2026, 5, 6, 18, 5),
    'projection_source': 'server_target_cycle',
    'created_at': DateTime.utc(2026, 5, 6, 18, 5),
    'updated_at': DateTime.utc(2026, 5, 6, 18, 5),
  };
}

PostgresRow _profileVersionRow() {
  return <String, Object?>{
    'target_profile_version_id': _profileVersionId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'target_profile_id': _profileId,
    'restaurant_id': _restaurantId,
    'target_cycle_id': _cycleId,
    'source_type': 'cycle_manager_override',
    'target_cplh': 12.4,
    'target_splh': 152.0,
    'target_ppa': 42.5,
    'foh_wage': 18.25,
    'boh_wage': 22.10,
    'opz_floor_cplh': 10.0,
    'opz_ceiling_cplh': 14.0,
    'theoretical_foh_labor_pct': 3.46,
    'theoretical_boh_labor_pct': 14.54,
    'theoretical_labor_pct': 18.0,
    'created_at': DateTime.utc(2026, 5, 6, 18, 5),
    'updated_at': DateTime.utc(2026, 5, 6, 18, 5),
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
