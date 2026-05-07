// Phase 8 W5.A.1 — canonical-path unit tests for WageRoleRowsRepository.
//
// Coverage focus:
//
//   * Round-trip — `upsert` projects a populated row through the SQL
//     shape; the wire encoding survives the boundary (source enum,
//     metadata jsonb, optional vendor mapping fields).
//
//   * `upsert` ON CONFLICT shape — the migration's UNIQUE index covers
//     `(operator_id, location_id, restaurant_id, role_name)`. Test
//     pins the conflict target in the SQL so a future migration that
//     changes the unique key breaks here, not silently in production.
//
//   * Tenant SET LOCAL ordering — every method runs through
//     `withTenant`, so the per-tenant RLS policy on the table can
//     fold against the GUCs to deny a cross-tenant write. Tests
//     verify the canonical ordering (operator → location → user)
//     and that `set local role forge_admin` is NEVER emitted (no
//     admin BYPASSRLS path on this surface).
//
//   * Cross-tenant isolation — when operator A's tenant transaction
//     reads with operator B's `(operator_id, location_id)`, the
//     fake pool simulates RLS denial by returning no rows. The
//     repository's `softDelete` reports zero affected rows;
//     `upsert` raises StateError on empty RETURNING.
//
//   * Soft-delete — `softDelete` issues an UPDATE that sets
//     `is_active = false` and bumps `updated_at`. Returns true when
//     a row was updated.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/wage_role_rows_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _actorA = '33333333-3333-3333-3333-333333333333';
const String _wageRowId = '99999999-9999-9999-9999-999999999999';

PostgresRow _wageRow({
  String wageRoleRowId = _wageRowId,
  String operatorId = _opA,
  String locationId = _locA,
  String restaurantId = 'rest-1',
  String roleName = 'Server',
  String laborBucket = 'foh',
  double hourlyRate = 18.5,
  double weightedHours = 30.0,
  String? jobCode,
  String? vendorId,
  String? vendorRoleId,
  String source = 'operator_manual',
  bool isActive = true,
  String? updatedBy = _actorA,
}) {
  return <String, Object?>{
    'wage_role_row_id': wageRoleRowId,
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'role_name': roleName,
    'labor_bucket': laborBucket,
    'hourly_rate': hourlyRate,
    'weighted_hours': weightedHours,
    'job_code': jobCode,
    'vendor_id': vendorId,
    'vendor_role_id': vendorRoleId,
    'source': source,
    'is_active': isActive,
    'effective_at': DateTime.utc(2026, 5, 7, 9),
    'metadata': <String, Object?>{},
    'created_at': DateTime.utc(2026, 5, 7, 9),
    'updated_at': DateTime.utc(2026, 5, 7, 10),
    'updated_by': updatedBy,
  };
}

void main() {
  group('WageRoleRowsRepository.upsert', () {
    test(
      'INSERT … ON CONFLICT (operator_id, location_id, restaurant_id, '
      'role_name) DO UPDATE rewrites editable fields and bumps '
      'updated_at; created_at preserved on conflict',
      () async {
        final pool = _Pool(upsertRows: <PostgresRow>[_wageRow()]);
        final repo = WageRoleRowsRepository(TenantTransactionWrapper(pool));
        final result = await repo.upsert(
          operatorId: _opA,
          locationId: _locA,
          restaurantId: 'rest-1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 18.5,
          weightedHours: 30.0,
          actorUserId: _actorA,
        );
        expect(result.wageRoleRowId, equals(_wageRowId));
        expect(result.restaurantId, equals('rest-1'));
        expect(result.roleName, equals('Server'));
        expect(result.laborBucket, equals('foh'));
        expect(result.hourlyRate, equals(18.5));
        expect(result.weightedHours, equals(30.0));
        expect(result.source, equals(WageRoleRowSource.operatorManual));
        expect(result.isActive, isTrue);
        expect(result.updatedBy, equals(_actorA));

        final tx = pool.transactions.single;
        final upsertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.wage_role_rows'),
        );
        expect(
          upsertSql,
          contains('on conflict (operator_id, location_id, restaurant_id, '
              'role_name)'),
        );
        expect(upsertSql, contains('do update set'));
        expect(upsertSql, contains('labor_bucket = excluded.labor_bucket'));
        expect(upsertSql, contains('hourly_rate = excluded.hourly_rate'));
        expect(upsertSql, contains('weighted_hours = excluded.weighted_hours'));
        expect(upsertSql, contains('source = excluded.source'));
        expect(upsertSql, contains('is_active = excluded.is_active'));
        expect(upsertSql, contains('metadata = excluded.metadata'));
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
            .firstWhere((p) => p['restaurant_id'] == 'rest-1');
        expect(params['operator_id'], equals(_opA));
        expect(params['location_id'], equals(_locA));
        expect(params['role_name'], equals('Server'));
        expect(params['labor_bucket'], equals('foh'));
        expect(params['hourly_rate'], equals(18.5));
        expect(params['weighted_hours'], equals(30.0));
        expect(params['source'], equals('operator_manual'));
        expect(params['is_active'], isTrue);
        expect(params['updated_by'], equals(_actorA));
      },
    );

    test(
      'tenant SET LOCAL ordering precedes the upsert and never '
      'escalates to forge_admin (no BYPASSRLS path on this surface)',
      () async {
        final pool = _Pool(upsertRows: <PostgresRow>[_wageRow()]);
        final repo = WageRoleRowsRepository(TenantTransactionWrapper(pool));
        await repo.upsert(
          operatorId: _opA,
          locationId: _locA,
          restaurantId: 'rest-1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 18.5,
          weightedHours: 30.0,
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
          reason: 'wage_role_rows has NO admin BYPASSRLS path — '
              'operator-controlled wage rows are read and written through '
              'the tenant SET LOCAL path',
        );
        // Upsert ran AFTER the SET LOCAL block.
        final upsertIndex = tx.executedSql.indexWhere(
          (s) => s.contains('insert into public.wage_role_rows'),
        );
        expect(upsertIndex, greaterThan(2));
      },
    );

    test(
      'throws StateError when the upsert RETURNING is empty — RLS '
      'denial on the tenant path is a hard failure, not a silent null',
      () async {
        final pool = _Pool(upsertRows: const <PostgresRow>[]);
        final repo = WageRoleRowsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.upsert(
            operatorId: _opA,
            locationId: _locA,
            restaurantId: 'rest-1',
            roleName: 'Server',
            laborBucket: 'foh',
            hourlyRate: 18.5,
            weightedHours: 30.0,
            actorUserId: _actorA,
          ),
          throwsStateError,
        );
      },
    );

    test('forwards optional vendor mapping fields and source enum', () async {
      final pool = _Pool(upsertRows: <PostgresRow>[
        _wageRow(
          jobCode: 'COOK-1',
          vendorId: 'quickbooks_time',
          vendorRoleId: 'pos-42',
          source: 'vendor_per_position',
        ),
      ]);
      final repo = WageRoleRowsRepository(TenantTransactionWrapper(pool));
      final result = await repo.upsert(
        operatorId: _opA,
        locationId: _locA,
        restaurantId: 'rest-1',
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: 16.0,
        weightedHours: 32.0,
        jobCode: 'COOK-1',
        vendorId: 'quickbooks_time',
        vendorRoleId: 'pos-42',
        source: WageRoleRowSource.vendorPerPosition,
        actorUserId: _actorA,
      );
      expect(result.jobCode, equals('COOK-1'));
      expect(result.vendorId, equals('quickbooks_time'));
      expect(result.vendorRoleId, equals('pos-42'));
      expect(result.source, equals(WageRoleRowSource.vendorPerPosition));
      final tx = pool.transactions.single;
      final params = tx.parameters
          .firstWhere((p) => p['source'] == 'vendor_per_position');
      expect(params['job_code'], equals('COOK-1'));
      expect(params['vendor_id'], equals('quickbooks_time'));
      expect(params['vendor_role_id'], equals('pos-42'));
    });
  });

  group('WageRoleRowsRepository.softDelete', () {
    test(
      'UPDATE sets is_active=false and bumps updated_at; returns true '
      'when a row was updated',
      () async {
        final pool = _Pool(softDeleteAffected: 1);
        final repo = WageRoleRowsRepository(TenantTransactionWrapper(pool));
        final removed = await repo.softDelete(
          operatorId: _opA,
          locationId: _locA,
          wageRoleRowId: _wageRowId,
          actorUserId: _actorA,
        );
        expect(removed, isTrue);
        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) => s.contains('update public.wage_role_rows'),
        );
        expect(updateSql, contains('set is_active = false'));
        expect(updateSql, contains('updated_at = now()'));
        expect(updateSql, contains('updated_by = @updated_by'));
        expect(
          updateSql,
          contains('where wage_role_row_id = @wage_role_row_id::uuid'),
        );
        expect(updateSql, contains('and operator_id = @operator_id::uuid'));
        expect(updateSql, contains('and location_id = @location_id::uuid'));
        expect(
          updateSql,
          contains('and is_active is true'),
          reason: 'idempotent soft-delete must skip rows already inactive',
        );
        // Tenant SET LOCAL precedes the UPDATE.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        // No admin BYPASSRLS escalation.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
        );
      },
    );

    test(
      'returns false when no row was updated (cross-tenant or already '
      'soft-deleted — production RLS would deny the write entirely)',
      () async {
        final pool = _Pool(softDeleteAffected: 0);
        final repo = WageRoleRowsRepository(TenantTransactionWrapper(pool));
        final removed = await repo.softDelete(
          operatorId: _opB,
          locationId: _locA,
          wageRoleRowId: _wageRowId,
          actorUserId: _actorA,
        );
        expect(removed, isFalse);
      },
    );
  });

  group('WageRoleRowsRepository tenant isolation', () {
    test(
      'cross-tenant write is impossible: operator A repository SETs '
      'operator A; operator B repository SETs operator B — there is no '
      'shared seam where the tenant id could leak across',
      () async {
        final poolA = _Pool(upsertRows: <PostgresRow>[_wageRow()]);
        final poolB = _Pool(upsertRows: <PostgresRow>[_wageRow(operatorId: _opB)]);
        final repoA = WageRoleRowsRepository(TenantTransactionWrapper(poolA));
        final repoB = WageRoleRowsRepository(TenantTransactionWrapper(poolB));
        await repoA.upsert(
          operatorId: _opA,
          locationId: _locA,
          restaurantId: 'rest-1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 18.5,
          weightedHours: 30.0,
          actorUserId: _actorA,
        );
        await repoB.upsert(
          operatorId: _opB,
          locationId: _locA,
          restaurantId: 'rest-1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 18.5,
          weightedHours: 30.0,
          actorUserId: _actorA,
        );
        expect(poolA.transactions.single.parameters[0]['value'], equals(_opA));
        expect(poolB.transactions.single.parameters[0]['value'], equals(_opB));
        // Neither side ever escalated to forge_admin.
        for (final pool in <_Pool>[poolA, poolB]) {
          expect(
            pool.transactions.single.executedSql
                .where((s) => s.contains('set local role forge_admin')),
            isEmpty,
          );
        }
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the
/// WageRoleRowsRepository seam. Mirrors the other repository fakes
/// in this directory: each transaction records every SQL string +
/// parameter map, then returns canned rows for recognized statement
/// shapes.
class _Pool implements PostgresPool {
  _Pool({
    this.upsertRows = const <PostgresRow>[],
    this.softDeleteAffected = 0,
  });

  final List<PostgresRow> upsertRows;
  final int softDeleteAffected;
  final List<_Tx> transactions = <_Tx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _Tx(
      upsertRows: upsertRows,
      softDeleteAffected: softDeleteAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _Tx extends PostgresTransaction {
  _Tx({
    required this.upsertRows,
    required this.softDeleteAffected,
  });

  final List<PostgresRow> upsertRows;
  final int softDeleteAffected;
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
    if (sql.contains('insert into public.wage_role_rows')) {
      return upsertRows;
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
    if (sql.contains('update public.wage_role_rows')) {
      return softDeleteAffected;
    }
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
