// Business Timing Live Postgres schema/repository tests.
//
// Local-only contract tests. These do not need a live database; they pin the
// migration shape and the repository SQL sent through TenantTransactionWrapper.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/open_shift_snapshots_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';
import 'package:forge_and_flow/services/business_timing/repository_operator_write_gateways.dart';

import '../tool/rls_policy_lint.dart';

const String _migrationPath =
    'db/migrations/202605060000_phase_business_timing_live_schema.sql';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _userId = '33333333-3333-3333-3333-333333333333';
const String _profileId = '44444444-4444-4444-4444-444444444444';
const String _orgUnitId = '55555555-5555-5555-5555-555555555555';
const String _snapshotId = '66666666-6666-6666-6666-666666666666';

void main() {
  final migration = _readSqlNormalized(_migrationPath);
  final normalized = migration.toLowerCase();
  final compactMigration = migration.replaceAll(RegExp(r'\s+'), ' ');

  group('Business Timing Live migration shape', () {
    test('declares the canonical timing tables and live snapshot table', () {
      for (final table in <String>[
        'business_timing_profiles',
        'business_timing_service_periods',
        'business_timing_audit_events',
        'open_shift_snapshots',
      ]) {
        expect(
          migration,
          contains('create table if not exists public.$table'),
          reason: 'missing table $table',
        );
      }
    });

    test('profiles carry scoped effective timing but no timezone column', () {
      final profileBlock = _tableBlock(migration, 'business_timing_profiles');
      expect(profileBlock, contains('scope_type text not null'));
      expect(profileBlock, contains('scope_id uuid not null'));
      for (final scope in <String>['operator', 'org_unit', 'location']) {
        expect(profileBlock, contains("'$scope'"));
      }
      expect(
        profileBlock,
        contains('business_day_start_local_time time not null'),
      );
      expect(profileBlock, contains('week_start_day integer not null'));
      expect(profileBlock, contains('close_authority text not null'));
      expect(
        profileBlock,
        contains('effective_from_business_date date not null'),
      );
      expect(profileBlock, contains('effective_until_business_date date'));
      expect(
        profileBlock.toLowerCase(),
        isNot(contains('timezone')),
        reason: 'locations.timezone is the authoritative IANA timezone',
      );
    });

    test(
      'service periods enforce quarter-hour, max-four, no-overlap shape',
      () {
        final periodBlock = _tableBlock(
          migration,
          'business_timing_service_periods',
        );
        expect(periodBlock, contains('service_period_key text not null'));
        expect(periodBlock, contains('sort_order integer not null'));
        expect(periodBlock, contains('start_local_time time not null'));
        expect(periodBlock, contains('end_local_time time not null'));
        expect(periodBlock, contains('applicable_weekdays integer[] not null'));
        expect(migration, contains('period_count > 4'));
        expect(migration, contains('rolling_count > 1'));
        expect(migration, contains('business-day start falls inside'));
        expect(migration, contains('service periods % and % overlap'));
      },
    );

    test('audit table records scoped actor/reason snapshots', () {
      final auditBlock = _tableBlock(migration, 'business_timing_audit_events');
      for (final eventType in <String>[
        'profile_created',
        'profile_updated',
        'profile_closed',
        'service_periods_replaced',
      ]) {
        expect(auditBlock, contains("'$eventType'"));
      }
      for (final actorKind in <String>[
        'operator_user',
        'forge_admin',
        'system',
      ]) {
        expect(auditBlock, contains("'$actorKind'"));
      }
      expect(auditBlock, contains('before_snapshot jsonb'));
      expect(auditBlock, contains('after_snapshot jsonb'));
      expect(auditBlock, contains('reason text not null'));
    });

    test('open_shift_snapshots locks profile id and stays location-scoped', () {
      final snapshotBlock = _tableBlock(migration, 'open_shift_snapshots');
      expect(snapshotBlock, contains('operator_id uuid not null'));
      expect(snapshotBlock, contains('location_id uuid not null'));
      expect(
        snapshotBlock,
        contains('business_timing_profile_id uuid not null'),
      );
      expect(snapshotBlock, contains('business_date date not null'));
      expect(snapshotBlock, contains('week_start_date date not null'));
      expect(snapshotBlock, contains('snapshot_scope text not null'));
      expect(snapshotBlock, contains('service_period_key text not null'));
      expect(
        snapshotBlock,
        contains('open_shift_snapshots_location_business_day_scope_uq'),
      );
      expect(snapshotBlock.toLowerCase(), isNot(contains('timezone')));
    });

    test('uses operator-leading indexes for RLS hot paths', () {
      for (final indexShape in <String>[
        '''
on public.business_timing_profiles (
    operator_id,
    scope_type,
    scope_id,
    effective_from_business_date''',
        '''
on public.business_timing_service_periods (
    operator_id,
    profile_id,
    sort_order''',
        '''
on public.business_timing_audit_events (
    operator_id,
    created_at desc''',
        '''
on public.open_shift_snapshots (
    operator_id,
    location_id,
    business_date desc''',
        '''
on public.open_shift_snapshots (
    operator_id,
    location_id,
    status,
    updated_at desc''',
      ]) {
        expect(migration, contains(indexShape));
      }
    });

    test(
      'RLS policies use wrapper functions and grant runtime/admin roles',
      () {
        expect(normalized, isNot(contains("current_setting('app.")));
        for (final policy in <String>[
          'business_timing_profiles_per_tenant',
          'business_timing_service_periods_per_tenant',
          'business_timing_audit_events_per_tenant',
          'open_shift_snapshots_per_tenant_location',
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
          'business_timing_profiles',
          'business_timing_service_periods',
          'business_timing_audit_events',
          'open_shift_snapshots',
        ]) {
          expect(
            compactMigration,
            contains('on public.$table to service_role'),
          );
          expect(compactMigration, contains('on public.$table to forge_admin'));
        }
      },
    );

    test('migration passes the policy-aware RLS lint', () {
      final result = RlsPolicyLintRunner(
        files: <String, String>{_migrationPath: migration},
        allowlist: const <String>{},
      ).run();
      expect(result.isClean, isTrue, reason: '${result.violations}');
    });

    test('does not introduce timestamp without time zone', () {
      expect(normalized, isNot(contains('timestamp without time zone')));
    });
  });

  group('BusinessTimingProfilesRepository', () {
    test(
      'createProfile writes profile, periods, and audit in one tenant tx',
      () async {
        final pool = _RecordingPool(onQuery: _businessTimingCreateQuery);
        final repo = BusinessTimingProfilesRepository(
          TenantTransactionWrapper(pool),
        );

        final row = await repo.createProfile(
          operatorId: _operatorId,
          locationId: _locationId,
          scopeType: 'org_unit',
          scopeId: _orgUnitId,
          businessDayStartLocalTime: '04:00',
          weekStartDay: DateTime.monday,
          closeAuthority: 'app_local_cutoff_fallback',
          localCloseFallbackTime: '04:00',
          effectiveFromBusinessDate: '2026-05-06',
          actorUserId: _userId,
          reason: 'operator timing setup',
          servicePeriods: const <BusinessTimingServicePeriodWrite>[
            BusinessTimingServicePeriodWrite(
              servicePeriodKey: 'lunch',
              label: 'Lunch',
              shortLabel: 'L',
              sortOrder: 1,
              startLocalTime: '11:00',
              endLocalTime: '15:00',
              rollsPastMidnight: false,
              applicableWeekdays: <int>[1, 2, 3, 4, 5],
            ),
            BusinessTimingServicePeriodWrite(
              servicePeriodKey: 'dinner',
              label: 'Dinner',
              shortLabel: 'D',
              sortOrder: 2,
              startLocalTime: '17:00',
              endLocalTime: '22:00',
              rollsPastMidnight: false,
              applicableWeekdays: <int>[1, 2, 3, 4, 5, 6, 7],
            ),
          ],
        );

        expect(row.profileId, equals(_profileId));
        expect(row.servicePeriods, hasLength(2));
        final tx = pool.transactions.single;
        expect(tx.executedSql.first, contains("set_config('app.operator_id'"));
        expect(tx.parameters.first['value'], equals(_operatorId));

        final profileInsert = tx.executedSql.firstWhere(
          (sql) => sql.contains('insert into public.business_timing_profiles'),
        );
        expect(profileInsert, isNot(contains('timezone')));
        final profileParams =
            tx.parameters[tx.executedSql.indexOf(profileInsert)];
        expect(profileParams['scope_type'], equals('org_unit'));
        expect(profileParams['scope_id'], equals(_orgUnitId));
        expect(profileParams['business_day_start_local_time'], equals('04:00'));

        final periodInserts = tx.executedSql
            .where(
              (sql) => sql.contains(
                'insert into public.business_timing_service_periods',
              ),
            )
            .toList();
        expect(periodInserts, hasLength(2));
        expect(
          periodInserts.first,
          contains('@applicable_weekdays::integer[]'),
        );

        final auditInsert = tx.executedSql.firstWhere(
          (sql) =>
              sql.contains('insert into public.business_timing_audit_events'),
        );
        final auditParams = tx.parameters[tx.executedSql.indexOf(auditInsert)];
        expect(auditParams['event_type'], equals('profile_created'));
        expect(auditParams['reason'], equals('operator timing setup'));
        final afterSnapshot =
            jsonDecode(auditParams['after_snapshot']! as String)
                as Map<String, dynamic>;
        expect(afterSnapshot['service_periods'], hasLength(2));
        expect(tx.commitCount, equals(1));
      },
    );

    test(
      'operator write gateway preserves validated service period metadata',
      () async {
        final pool = _RecordingPool(onQuery: _businessTimingCreateQuery);
        final repo = BusinessTimingProfilesRepository(
          TenantTransactionWrapper(pool),
        );
        final gateway = RepositoryOperatorBusinessTimingWriteGateway(
          repository: repo,
        );
        final validated = validateNewBusinessTimingProfile(<String, Object?>{
          'scopeKind': 'org_unit',
          'scopeId': _orgUnitId,
          'effectiveAtBusinessDate': '2026-05-06',
          'ianaTimezone': 'America/St_Johns',
          'weekStartDay': 'monday',
          'businessDayStartLocal': '04:00',
          'servicePeriods': <Map<String, Object?>>[
            <String, Object?>{
              'key': 'brunch',
              'label': 'Weekend Brunch',
              'startLocal': '09:00',
              'endLocal': '13:00',
              'applicableDays': <int>[6, 7],
              'shortLabel': 'WB',
              'sortOrder': 2,
            },
          ],
        });

        await gateway.createProfile(
          operatorId: _operatorId,
          actorUserId: _userId,
          idempotencyKey: 'idem-metadata',
          validated: validated,
          adminReason: 'operator timing setup',
        );

        final tx = pool.transactions.single;
        final periodInsert = tx.executedSql.firstWhere(
          (sql) => sql.contains(
            'insert into public.business_timing_service_periods',
          ),
        );
        final periodParams =
            tx.parameters[tx.executedSql.indexOf(periodInsert)];
        expect(periodParams['service_period_key'], equals('brunch'));
        expect(periodParams['label'], equals('Weekend Brunch'));
        expect(periodParams['applicable_weekdays'], equals(<int>[6, 7]));
        expect(periodParams['short_label'], equals('WB'));
        expect(periodParams['sort_order'], equals(2));
      },
    );

    test(
      'listCandidateProfilesForLocation reads effective account timezone',
      () async {
        final pool = _RecordingPool(
          onQuery: (sql, _) {
            if (sql.contains('from public.business_timing_profiles p')) {
              return <PostgresRow>[
                _profileRow(
                  scopeType: 'operator',
                  scopeId: _operatorId,
                  locationTimezone: 'America/St_Johns',
                ),
              ];
            }
            return const <PostgresRow>[];
          },
        );
        final repo = BusinessTimingProfilesRepository(
          TenantTransactionWrapper(pool),
        );

        final rows = await repo.listCandidateProfilesForLocation(
          operatorId: _operatorId,
          locationId: _locationId,
          businessDate: '2026-05-06',
          userId: _userId,
        );

        expect(rows.single.locationTimezone, equals('America/St_Johns'));
        final sql = pool.transactions.single.executedSql.last;
        expect(sql, contains('location_override.iana_timezone'));
        expect(sql, contains('org_unit_override.iana_timezone'));
        expect(sql, contains('loc.timezone'));
        expect(sql, contains('public.org_unit_account_overrides'));
        expect(sql, contains('public.location_account_overrides'));
        expect(sql, contains('ou.path @> loc.org_unit_path'));
        expect(sql, contains('order by scope.scope_depth asc'));
        expect(sql, isNot(contains('p.timezone')));
      },
    );

    test('rejects more than four service periods before opening tx', () async {
      final pool = _RecordingPool(onQuery: _businessTimingCreateQuery);
      final repo = BusinessTimingProfilesRepository(
        TenantTransactionWrapper(pool),
      );
      expect(
        () => repo.createProfile(
          operatorId: _operatorId,
          locationId: _locationId,
          scopeType: 'operator',
          scopeId: _operatorId,
          businessDayStartLocalTime: '04:00',
          weekStartDay: DateTime.monday,
          closeAuthority: 'vendor_finalization',
          effectiveFromBusinessDate: '2026-05-06',
          actorUserId: _userId,
          reason: 'too many',
          servicePeriods: List<BusinessTimingServicePeriodWrite>.filled(
            5,
            const BusinessTimingServicePeriodWrite(
              servicePeriodKey: 'x',
              label: 'X',
              shortLabel: 'X',
              sortOrder: 1,
              startLocalTime: '10:00',
              endLocalTime: '11:00',
              rollsPastMidnight: false,
              applicableWeekdays: <int>[1],
            ),
          ),
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });
  });

  group('OpenShiftSnapshotsRepository', () {
    test('upsertSnapshot uses locked conflict key and returns row', () async {
      final pool = _RecordingPool(
        onQuery: (sql, _) {
          if (sql.contains('insert into public.open_shift_snapshots')) {
            return <PostgresRow>[_snapshotRow()];
          }
          return const <PostgresRow>[];
        },
      );
      final repo = OpenShiftSnapshotsRepository(TenantTransactionWrapper(pool));

      final row = await repo.upsertSnapshot(
        snapshot: _snapshotWrite(),
        userId: _userId,
      );

      expect(row.snapshotId, equals(_snapshotId));
      expect(row.provenance['pos'], equals('canonical_facts'));
      final tx = pool.transactions.single;
      final sql = tx.executedSql.last;
      expect(sql, contains('insert into public.open_shift_snapshots'));
      expect(
        sql,
        contains(
          'on conflict on constraint '
          'open_shift_snapshots_location_business_day_scope_uq',
        ),
      );
      expect(sql, contains('updated_at = now()'));
      final params = tx.parameters.last;
      expect(params['business_timing_profile_id'], equals(_profileId));
      expect(params['business_timing_profile_version_id'], equals(_profileId));
      expect(params['business_date'], equals('2026-05-06'));
      expect(params['service_period_key'], equals('whole_day'));
      final provenance =
          jsonDecode(params['provenance']! as String) as Map<String, dynamic>;
      expect(provenance['pos'], equals('canonical_facts'));
    });

    test('listUpdatedSince rejects non-positive limits before tx', () async {
      final pool = _RecordingPool(onQuery: (_, __) => const <PostgresRow>[]);
      final repo = OpenShiftSnapshotsRepository(TenantTransactionWrapper(pool));
      expect(
        () => repo.listUpdatedSince(
          operatorId: _operatorId,
          locationId: _locationId,
          updatedAfter: DateTime.utc(2026, 5, 6),
          limit: 0,
          userId: _userId,
        ),
        throwsArgumentError,
      );
      expect(pool.transactions, isEmpty);
    });
  });
}

List<PostgresRow> _businessTimingCreateQuery(
  String sql,
  PostgresParameters parameters,
) {
  if (sql.contains('insert into public.business_timing_profiles')) {
    return <PostgresRow>[
      <String, Object?>{'profile_id': _profileId},
    ];
  }
  if (sql.contains('insert into public.business_timing_service_periods')) {
    return <PostgresRow>[
      <String, Object?>{'service_period_id': parameters['service_period_key']},
    ];
  }
  if (sql.contains('from public.business_timing_profiles p')) {
    return <PostgresRow>[
      _profileRow(scopeType: 'org_unit', scopeId: _orgUnitId),
    ];
  }
  if (sql.contains('insert into public.business_timing_audit_events')) {
    return <PostgresRow>[
      <String, Object?>{'audit_event_id': 'audit-1'},
    ];
  }
  return const <PostgresRow>[];
}

PostgresRow _profileRow({
  required String scopeType,
  required String scopeId,
  String? locationTimezone,
}) {
  return <String, Object?>{
    'profile_id': _profileId,
    'operator_id': _operatorId,
    'scope_type': scopeType,
    'scope_id': scopeId,
    'display_name': 'Default timing',
    'business_day_start_local_time': '04:00:00',
    'week_start_day': DateTime.monday,
    'close_authority': 'app_local_cutoff_fallback',
    'local_close_fallback_time': '04:00:00',
    'effective_from_business_date': '2026-05-06',
    'effective_until_business_date': null,
    'supersedes_profile_id': null,
    'created_by': _userId,
    'updated_by': _userId,
    'created_at': DateTime.utc(2026, 5, 6, 12),
    'updated_at': DateTime.utc(2026, 5, 6, 12),
    'location_timezone': locationTimezone,
    'service_periods': <Map<String, Object?>>[
      <String, Object?>{
        'service_period_id': '77777777-7777-7777-7777-777777777777',
        'operator_id': _operatorId,
        'profile_id': _profileId,
        'service_period_key': 'lunch',
        'label': 'Lunch',
        'short_label': 'L',
        'sort_order': 1,
        'start_local_time': '11:00:00',
        'end_local_time': '15:00:00',
        'rolls_past_midnight': false,
        'applicable_weekdays': <int>[1, 2, 3, 4, 5],
      },
      <String, Object?>{
        'service_period_id': '88888888-8888-8888-8888-888888888888',
        'operator_id': _operatorId,
        'profile_id': _profileId,
        'service_period_key': 'dinner',
        'label': 'Dinner',
        'short_label': 'D',
        'sort_order': 2,
        'start_local_time': '17:00:00',
        'end_local_time': '22:00:00',
        'rolls_past_midnight': false,
        'applicable_weekdays': <int>[1, 2, 3, 4, 5, 6, 7],
      },
    ],
  };
}

OpenShiftSnapshotPostgresWrite _snapshotWrite() {
  return OpenShiftSnapshotPostgresWrite(
    operatorId: _operatorId,
    locationId: _locationId,
    businessTimingProfileId: _profileId,
    businessDate: '2026-05-06',
    weekStartDate: '2026-05-04',
    weekId: '2026-W19',
    dayLabel: 'Wednesday',
    snapshotScope: 'whole_day',
    servicePeriodKey: 'whole_day',
    servicePeriodLabel: 'Whole Day',
    status: 'open',
    forecastCovers: 120,
    currentCovers: 72,
    scheduledFohHours: 42,
    scheduledBohHours: 31,
    currentPpa: 42.50,
    currentCplh: 11.2,
    currentSplh: 152.0,
    blendedWage: 18.25,
    provenance: const <String, Object?>{'pos': 'canonical_facts'},
    lastEventAt: DateTime.utc(2026, 5, 6, 18, 30),
  );
}

PostgresRow _snapshotRow() {
  return <String, Object?>{
    'snapshot_id': _snapshotId,
    'operator_id': _operatorId,
    'location_id': _locationId,
    'business_timing_profile_id': _profileId,
    'business_timing_profile_version_id': _profileId,
    'business_date': '2026-05-06',
    'week_start_date': '2026-05-04',
    'week_id': '2026-W19',
    'day_label': 'Wednesday',
    'snapshot_scope': 'whole_day',
    'service_period_key': 'whole_day',
    'service_period_label': 'Whole Day',
    'status': 'open',
    'forecast_covers': 120,
    'current_covers': 72,
    'scheduled_foh_hours': 42,
    'scheduled_boh_hours': 31,
    'current_ppa': 42.5,
    'current_cplh': 11.2,
    'current_splh': 152.0,
    'blended_wage': 18.25,
    'time_label': '',
    'service_elapsed_label': '',
    'source_system': 'pos',
    'source_shift_id': 'shift-1',
    'provenance': <String, Object?>{'pos': 'canonical_facts'},
    'last_event_at': DateTime.utc(2026, 5, 6, 18, 30),
    'created_at': DateTime.utc(2026, 5, 6, 18, 31),
    'updated_at': DateTime.utc(2026, 5, 6, 18, 31),
  };
}

String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
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
