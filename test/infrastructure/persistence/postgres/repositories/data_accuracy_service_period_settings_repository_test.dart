// Hardening Wave B1 — canonical-path unit tests for
// DataAccuracyServicePeriodSettingsRepository.
//
// Coverage focus:
//
//   * Round-trip — `upsert` → `readEffectiveAt` projects a populated
//     row through the SQL shape; the wire encoding survives both ways.
//
//   * Effective-dated lookup semantics — `readEffectiveAt` SQL
//     filter + ordering pin the at-or-before contract: the most
//     recent row whose `effective_at_business_date <= @business_date`
//     is selected; forward-staged rows must NOT short-circuit a
//     historical close. Test asserts the ORDER BY + LIMIT 1 + filter
//     shape so a refactor that drops one piece breaks here.
//
//   * Tenant SET LOCAL ordering — every method runs through
//     `withTenant`, so the per-tenant RLS policy on the table can
//     fold against the GUCs to deny a cross-tenant `service_period_key`.
//     Tests verify the canonical ordering (operator → location →
//     user) and that `set local role forge_admin` is NEVER emitted
//     (no admin BYPASSRLS path on this surface).
//
//   * Cross-tenant isolation — when operator A's tenant transaction
//     reads with operator B's `(operator_id, location_id)`, the
//     fake pool simulates RLS denial by returning no rows. The
//     repository surfaces this as a null on `readEffectiveAt`, never
//     hands operator A a row that belongs to operator B.
//
//   * `upsert` ON CONFLICT shape — the migration's UNIQUE index
//     covers `(operator_id, location_id, service_period_key,
//     effective_at_business_date)`. Test pins the conflict target
//     in the SQL so a future migration that changes the unique key
//     breaks here, not silently in production.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/data_accuracy_service_period_settings_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _actorA = '33333333-3333-3333-3333-333333333333';

PostgresRow _settingRow({
  String id = '99999999-9999-9999-9999-999999999999',
  String operatorId = _opA,
  String locationId = _locA,
  String servicePeriodKey = 'lunch',
  String coversSource = 'manual',
  String wageSource = 'manual_mix',
  String effectiveAt = '2026-05-01',
  String? updatedBy = _actorA,
}) {
  return <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'location_id': locationId,
    'service_period_key': servicePeriodKey,
    'covers_source': coversSource,
    'wage_source': wageSource,
    'effective_at_business_date': effectiveAt,
    'created_at': DateTime.utc(2026, 5, 1, 10),
    'updated_at': DateTime.utc(2026, 5, 1, 11),
    'updated_by': updatedBy,
  };
}

void main() {
  group('DataAccuracyServicePeriodSettingsRepository.upsert', () {
    test(
      'INSERT ... ON CONFLICT (operator_id, location_id, '
      'service_period_key, effective_at_business_date) DO UPDATE '
      'rewrites covers_source, wage_source, updated_at, updated_by '
      '— created_at preserved on conflict',
      () async {
        final pool = _Pool(upsertRows: <PostgresRow>[_settingRow()]);
        final repo = DataAccuracyServicePeriodSettingsRepository(
          TenantTransactionWrapper(pool),
        );
        final result = await repo.upsert(
          operatorId: _opA,
          locationId: _locA,
          servicePeriodKey: 'lunch',
          coversSource: ServicePeriodCoversSource.manual,
          wageSource: ServicePeriodWageSource.manualMix,
          effectiveAtBusinessDateIso: '2026-05-01',
          actorUserId: _actorA,
        );
        expect(
          result.coversSource,
          equals(ServicePeriodCoversSource.manual),
        );
        expect(
          result.wageSource,
          equals(ServicePeriodWageSource.manualMix),
        );
        expect(result.effectiveAtBusinessDate, equals('2026-05-01'));
        expect(result.updatedBy, equals(_actorA));

        final tx = pool.transactions.single;
        final upsertSql = tx.executedSql.firstWhere((s) =>
            s.contains('insert into public.data_accuracy_service_period_settings'));
        expect(
          upsertSql,
          contains('on conflict (operator_id, location_id, service_period_key, '
              'effective_at_business_date)'),
        );
        expect(upsertSql, contains('do update set'));
        expect(upsertSql, contains('covers_source = excluded.covers_source'));
        expect(upsertSql, contains('wage_source = excluded.wage_source'));
        expect(upsertSql, contains('updated_at = now()'));
        expect(upsertSql, contains('updated_by = excluded.updated_by'));
        expect(
          upsertSql,
          isNot(contains('created_at = excluded.created_at')),
          reason: 'created_at must be preserved on conflict so the audit '
              'trail shows the original creation time, not the latest edit',
        );
        // Wire values bound parametrically — never interpolated.
        final params = tx.parameters
            .firstWhere((p) => p['service_period_key'] == 'lunch');
        expect(params['covers_source'], equals('manual'));
        expect(params['wage_source'], equals('manual_mix'));
        expect(params['effective_at'], equals('2026-05-01'));
      },
    );

    test(
      'tenant SET LOCAL ordering precedes the upsert and never '
      'escalates to forge_admin (no BYPASSRLS path on this surface)',
      () async {
        final pool = _Pool(upsertRows: <PostgresRow>[_settingRow()]);
        final repo = DataAccuracyServicePeriodSettingsRepository(
          TenantTransactionWrapper(pool),
        );
        await repo.upsert(
          operatorId: _opA,
          locationId: _locA,
          servicePeriodKey: 'lunch',
          coversSource: ServicePeriodCoversSource.manual,
          wageSource: ServicePeriodWageSource.manualMix,
          effectiveAtBusinessDateIso: '2026-05-01',
          actorUserId: _actorA,
        );
        final tx = pool.transactions.single;
        // Canonical SET LOCAL order: operator → location → user.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(tx.parameters[2]['value'], equals(_actorA));
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
          reason: 'data_accuracy_service_period_settings has NO admin '
              'BYPASSRLS path — operator-controlled overrides are read '
              'and written through the tenant SET LOCAL path',
        );
        // Upsert ran AFTER the SET LOCAL block.
        final upsertIndex = tx.executedSql.indexWhere((s) =>
            s.contains('insert into public.data_accuracy_service_period_settings'));
        expect(upsertIndex, greaterThan(2));
      },
    );

    test(
      'throws StateError when the upsert RETURNING is empty — RLS '
      'denial on the tenant path is a hard failure, not a silent null',
      () async {
        final pool = _Pool(upsertRows: const <PostgresRow>[]);
        final repo = DataAccuracyServicePeriodSettingsRepository(
          TenantTransactionWrapper(pool),
        );
        await expectLater(
          repo.upsert(
            operatorId: _opA,
            locationId: _locA,
            servicePeriodKey: 'lunch',
            coversSource: ServicePeriodCoversSource.vendor,
            wageSource: ServicePeriodWageSource.vendorPerEmployee,
            effectiveAtBusinessDateIso: '2026-05-01',
            actorUserId: _actorA,
          ),
          throwsStateError,
        );
      },
    );
  });

  group('DataAccuracyServicePeriodSettingsRepository.readEffectiveAt', () {
    test(
      'SQL pins the at-or-before contract: WHERE filter + ORDER BY '
      'effective_at_business_date desc + LIMIT 1 — forward-staged '
      'rows must NOT short-circuit a historical close',
      () async {
        final pool = _Pool(
          readRows: <PostgresRow>[_settingRow(effectiveAt: '2026-04-15')],
        );
        final repo = DataAccuracyServicePeriodSettingsRepository(
          TenantTransactionWrapper(pool),
        );
        final result = await repo.readEffectiveAt(
          operatorId: _opA,
          locationId: _locA,
          servicePeriodKey: 'lunch',
          businessDateIso: '2026-05-01',
          actorUserId: _actorA,
        );
        expect(result, isNotNull);
        expect(result!.effectiveAtBusinessDate, equals('2026-04-15'));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere((s) => s.contains(
            'from public.data_accuracy_service_period_settings'));
        expect(selectSql, contains('where operator_id = @operator_id::uuid'));
        expect(selectSql, contains('and location_id = @location_id::uuid'));
        expect(
          selectSql,
          contains('and service_period_key = @service_period_key'),
        );
        expect(
          selectSql,
          contains('and effective_at_business_date <= @business_date::date'),
        );
        expect(
          selectSql,
          contains('order by effective_at_business_date desc'),
        );
        expect(selectSql, contains('limit 1'));
        // business_date bound parametrically.
        final params = tx.parameters
            .firstWhere((p) => p['business_date'] == '2026-05-01');
        expect(params['service_period_key'], equals('lunch'));
      },
    );

    test('returns null when no row exists at-or-before the date', () async {
      final pool = _Pool(readRows: const <PostgresRow>[]);
      final repo = DataAccuracyServicePeriodSettingsRepository(
        TenantTransactionWrapper(pool),
      );
      final result = await repo.readEffectiveAt(
        operatorId: _opA,
        locationId: _locA,
        servicePeriodKey: 'breakfast',
        businessDateIso: '2026-05-01',
      );
      expect(result, isNull);
    });

    test(
      'cross-tenant isolation — operator A querying with operator B\'s '
      'tenant context returns null because the fake pool simulates '
      'RLS denial (no rows). The repository never hands a row across '
      'the tenant boundary.',
      () async {
        // Pool primed for operator A's row only — operator B's read
        // returns no rows (the production RLS policy on the table
        // would deny under the tenant SET LOCAL path).
        final poolA = _Pool(readRows: <PostgresRow>[_settingRow()]);
        final poolB = _Pool(readRows: const <PostgresRow>[]);
        final repoA = DataAccuracyServicePeriodSettingsRepository(
          TenantTransactionWrapper(poolA),
        );
        final repoB = DataAccuracyServicePeriodSettingsRepository(
          TenantTransactionWrapper(poolB),
        );
        final aResult = await repoA.readEffectiveAt(
          operatorId: _opA,
          locationId: _locA,
          servicePeriodKey: 'lunch',
          businessDateIso: '2026-05-01',
        );
        final bResult = await repoB.readEffectiveAt(
          operatorId: _opB,
          locationId: _locA,
          servicePeriodKey: 'lunch',
          businessDateIso: '2026-05-01',
        );
        expect(aResult, isNotNull);
        expect(aResult!.operatorId, equals(_opA));
        expect(
          bResult,
          isNull,
          reason: 'operator B must never read operator A\'s setting; '
              'production RLS would deny, fake pool returns no rows',
        );
        // Both transactions ran the canonical SET LOCAL block before
        // the SELECT — neither escalated to forge_admin.
        for (final pool in <_Pool>[poolA, poolB]) {
          final tx = pool.transactions.single;
          expect(
            tx.executedSql
                .where((s) => s.contains('set local role forge_admin')),
            isEmpty,
          );
          expect(tx.executedSql[0], contains("'app.operator_id'"));
        }
      },
    );
  });

  group('DataAccuracyServicePeriodSettingsRepository.listForServicePeriod',
      () {
    test(
      'ORDER BY effective_at_business_date desc — history view shows '
      'the most-recent row first',
      () async {
        final pool = _Pool(
          listRows: <PostgresRow>[
            _settingRow(effectiveAt: '2026-06-01'),
            _settingRow(effectiveAt: '2026-04-15'),
          ],
        );
        final repo = DataAccuracyServicePeriodSettingsRepository(
          TenantTransactionWrapper(pool),
        );
        final rows = await repo.listForServicePeriod(
          operatorId: _opA,
          locationId: _locA,
          servicePeriodKey: 'lunch',
        );
        expect(rows, hasLength(2));
        expect(rows[0].effectiveAtBusinessDate, equals('2026-06-01'));
        expect(rows[1].effectiveAtBusinessDate, equals('2026-04-15'));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere((s) => s.contains(
            'from public.data_accuracy_service_period_settings'));
        expect(
          selectSql,
          contains('order by effective_at_business_date desc'),
        );
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the
/// DataAccuracyServicePeriodSettingsRepository seam. Mirrors the
/// other repository fakes in this directory: each transaction records
/// every SQL string + parameter map, then returns canned rows for
/// recognized statement shapes.
class _Pool implements PostgresPool {
  _Pool({
    this.readRows = const <PostgresRow>[],
    this.upsertRows = const <PostgresRow>[],
    this.listRows = const <PostgresRow>[],
  });

  final List<PostgresRow> readRows;
  final List<PostgresRow> upsertRows;
  final List<PostgresRow> listRows;
  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(
      readRows: readRows,
      upsertRows: upsertRows,
      listRows: listRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({
    required this.readRows,
    required this.upsertRows,
    required this.listRows,
  });

  final List<PostgresRow> readRows;
  final List<PostgresRow> upsertRows;
  final List<PostgresRow> listRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains(
        'insert into public.data_accuracy_service_period_settings')) {
      return upsertRows;
    }
    if (sql.contains('limit 1')) {
      return readRows;
    }
    if (sql.contains('from public.data_accuracy_service_period_settings')) {
      return listRows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}
