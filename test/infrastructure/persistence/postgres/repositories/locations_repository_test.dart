// Phase 11A.1 / post-hardening P2 — canonical-path unit tests for
// LocationsRepository.
//
// Coverage focus (Time Guardrails — `business_timezone (IANA)` +
// `business_day_rollover_hour` are restaurant-owned and feed the
// per-write `business_date` projection on operator-scoped fact tables;
// the locations row is the source-of-truth for both):
//
//   * `business_timezone` round-trip — IANA strings (`'America/New_York'`,
//     `'Pacific/Auckland'`) survive INSERT and UPDATE bind without
//     mutation. The repo trusts the IANA value the proxy validated;
//     this test pins parametric binding (no concatenation) so a future
//     refactor cannot silently lower-case or otherwise mutate the
//     value.
//
//   * `business_day_rollover_hour` boundary — 0..23 round-trip
//     unchanged on INSERT and UPDATE. The DB CHECK enforces the range;
//     the repo just round-trips the int. This test pins both endpoints
//     of the legal range so a clamp regression surfaces here.
//
//   * Cross-operator isolation — every method runs through `withSystem`
//     (the admin onboarding console walks operators that have not yet
//     opened a tenant session, so tenant SET LOCAL is unavailable).
//     Tests verify:
//       - `set local role forge_admin` runs before the read/write so
//         BYPASSRLS engages
//       - `app.bypass_rls_audit = 'system:<reason>'` audit marker carries
//         the canonical shape so audit triggers attribute the bypass
//       - `listForOperator` filters `where operator_id = @operator_id::uuid`
//         so the admin scopes the read to one operator even on the
//         BYPASSRLS path
//       - `listAllLocations` has NO operator_id predicate (the admin
//         walks every tenant) and orders by `(operator_id, created_at)`
//         so the admin grouping is stable
//       - `deleteLocation` requires BOTH `location_id = @location_id::uuid`
//         AND `operator_id = @operator_id::uuid` so a stale location_id
//         cannot accidentally land on the wrong operator's row
//
//   * `updateLocation` returns null when the row does not exist (404
//     surface for the proxy); `coalesce` guards every editable column
//     so omitted fields are not blanked out.
//
//   * `insertLocation` throws StateError on empty RETURNING (defensive —
//     the `gen_random_uuid()` default + RETURNING should always yield
//     a row, so an empty result means RLS denied the row even on the
//     BYPASSRLS path, which is a hard failure).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/locations_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _locB = '55555555-5555-5555-5555-555555555555';
const String _parentOrgUnitA = '33333333-3333-3333-3333-333333333333';

PostgresRow _locationRow({
  String locationId = _locA,
  String operatorId = _opA,
  String parentOrgUnitId = _parentOrgUnitA,
  String name = 'Downtown',
  String address = '123 Main St',
  String timezone = 'America/New_York',
  int? businessDayRolloverHour = 4,
}) {
  return <String, Object?>{
    'location_id': locationId,
    'operator_id': operatorId,
    'parent_org_unit_id': parentOrgUnitId,
    'name': name,
    'address': address,
    'timezone': timezone,
    'business_day_rollover_hour': businessDayRolloverHour,
    'created_at': DateTime.utc(2026, 4, 28, 10),
    'updated_at': DateTime.utc(2026, 4, 28, 11),
  };
}

void main() {
  group('LocationsRepository.listForOperator (admin tenant-bounded sweep)', () {
    test('uses withSystem with the canonical bypass marker; SQL filters '
        'operator_id::uuid and orders by created_at so the admin sees a '
        'stable per-operator listing even on the BYPASSRLS path', () async {
      final pool = _LocationsPool(
        listForOperatorRows: <PostgresRow>[
          _locationRow(operatorId: _opA, name: 'A'),
          _locationRow(operatorId: _opA, locationId: _locB, name: 'B'),
        ],
      );
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      final rows = await repo.listForOperator(
        operatorId: _opA,
        adminReason: 'admin.locations.list_for_op',
      );
      expect(rows, hasLength(2));
      expect(rows[0].operatorId, equals(_opA));
      expect(rows[1].operatorId, equals(_opA));

      final tx = pool.transactions.single;
      // Bypass audit marker carries the canonical "system:<reason>" shape.
      final auditCfg = tx.parameters.firstWhere(
        (p) =>
            p['value'] is String &&
            (p['value']! as String).startsWith('system:'),
      );
      expect(auditCfg['value'], equals('system:admin.locations.list_for_op'));
      // forge_admin elevation precedes the SELECT.
      expect(
        tx.executedSql.where((s) => s.contains('set local role forge_admin')),
        hasLength(1),
      );
      // Tenant GUCs MUST NOT be set in withSystem.
      expect(
        tx.executedSql.where((s) => s.contains("'app.operator_id'")),
        isEmpty,
        reason:
            'withSystem must not set tenant GUCs — that would shadow '
            'BYPASSRLS and break the cross-operator admin path',
      );
      // SQL shape — operator_id filter + created_at ordering.
      final selectSql = tx.executedSql.firstWhere(
        (s) => s.contains('from locations'),
      );
      expect(selectSql, contains('where operator_id = @operator_id::uuid'));
      expect(selectSql, contains('and deleted_at is null'));
      expect(selectSql, contains('order by created_at asc'));
      // operator_id bound parametrically.
      final selectParams = tx.parameters.firstWhere(
        (p) => p['operator_id'] == _opA,
      );
      expect(selectParams['operator_id'], equals(_opA));
    });

    test('rejects a blank adminReason at the wrapper boundary', () async {
      final pool = _LocationsPool();
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      Object? thrown;
      try {
        await repo.listForOperator(operatorId: _opA, adminReason: '   ');
      } on ArgumentError catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ArgumentError>());
      expect(
        pool.transactions,
        isEmpty,
        reason:
            'wrapper validates the audit marker before opening a tx — '
            'a blank reason cannot mint an unattributable BYPASSRLS path',
      );
    });

    test('returns an empty list when the operator has no locations', () async {
      final pool = _LocationsPool(listForOperatorRows: const <PostgresRow>[]);
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      final rows = await repo.listForOperator(
        operatorId: _opA,
        adminReason: 'admin.locations.list_for_op',
      );
      expect(rows, isEmpty);
    });
  });

  group(
    'LocationsRepository.listAllLocations (cross-operator admin sweep)',
    () {
      test(
        'SQL has NO operator_id predicate — the admin walks every tenant; '
        'order by (operator_id, created_at) so admin grouping is stable',
        () async {
          final pool = _LocationsPool(
            listAllRows: <PostgresRow>[
              _locationRow(operatorId: _opA),
              _locationRow(operatorId: _opB, locationId: _locB),
            ],
          );
          final repo = LocationsRepository(TenantTransactionWrapper(pool));
          final rows = await repo.listAllLocations(
            adminReason: 'admin.locations.list_all',
          );
          expect(rows, hasLength(2));
          expect(rows[0].operatorId, equals(_opA));
          expect(rows[1].operatorId, equals(_opB));

          final tx = pool.transactions.single;
          final selectSql = tx.executedSql.firstWhere(
            (s) => s.contains('from locations'),
          );
          expect(selectSql, contains('where deleted_at is null'));
          expect(
            selectSql,
            isNot(contains('where operator_id')),
            reason: 'cross-operator sweep — no operator_id filter',
          );
          expect(
            selectSql,
            contains('order by operator_id asc, created_at asc'),
            reason: 'admin grouping needs a stable sort across operators',
          );
        },
      );
    },
  );

  group('LocationsRepository.insertLocation', () {
    test('business_timezone IANA string round-trips parametrically (no '
        'concatenation, no normalization on the way down)', () async {
      final pool = _LocationsPool(
        insertedRows: <PostgresRow>[_locationRow(timezone: 'Pacific/Auckland')],
      );
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      final row = await repo.insertLocation(
        operatorId: _opA,
        parentOrgUnitId: _parentOrgUnitA,
        name: 'Auckland',
        address: '1 Queen St',
        timezone: 'Pacific/Auckland',
        businessDayRolloverHour: 3,
        adminReason: 'admin.locations.create',
      );
      expect(row.timezone, equals('Pacific/Auckland'));
      expect(row.parentOrgUnitId, equals(_parentOrgUnitA));

      final tx = pool.transactions.single;
      final insertParams = tx.parameters.firstWhere(
        (p) => p['timezone'] == 'Pacific/Auckland',
      );
      // Repo binds the IANA value as-is — no toLowerCase, no '_'
      // substitution, no validation. The proxy validated upstream.
      expect(insertParams['timezone'], equals('Pacific/Auckland'));
      expect(insertParams['parent_org_unit_id'], equals(_parentOrgUnitA));
      // SQL bound through @timezone, never concatenated.
      final insertSql = tx.executedSql.firstWhere(
        (s) => s.contains('insert into locations'),
      );
      expect(insertSql, contains('@timezone'));
      expect(insertSql, isNot(contains("'Pacific/Auckland'")));
    });

    test('business_day_rollover_hour boundary: 0 (midnight rollover) and '
        '23 (last legal hour) round-trip unchanged on INSERT bind', () async {
      // 0 — midnight rollover.
      final poolZero = _LocationsPool(
        insertedRows: <PostgresRow>[_locationRow(businessDayRolloverHour: 0)],
      );
      final repoZero = LocationsRepository(TenantTransactionWrapper(poolZero));
      await repoZero.insertLocation(
        operatorId: _opA,
        parentOrgUnitId: _parentOrgUnitA,
        name: 'Midnight',
        address: 'addr',
        timezone: 'UTC',
        businessDayRolloverHour: 0,
        adminReason: 'admin.locations.create',
      );
      final paramsZero = poolZero.transactions.single.parameters.firstWhere(
        (p) => p['name'] == 'Midnight',
      );
      expect(paramsZero['business_day_rollover_hour'], equals(0));

      // 23 — last legal hour before the next day rolls over.
      final pool23 = _LocationsPool(
        insertedRows: <PostgresRow>[_locationRow(businessDayRolloverHour: 23)],
      );
      final repo23 = LocationsRepository(TenantTransactionWrapper(pool23));
      await repo23.insertLocation(
        operatorId: _opA,
        parentOrgUnitId: _parentOrgUnitA,
        name: 'LateNight',
        address: 'addr',
        timezone: 'UTC',
        businessDayRolloverHour: 23,
        adminReason: 'admin.locations.create',
      );
      final params23 = pool23.transactions.single.parameters.firstWhere(
        (p) => p['name'] == 'LateNight',
      );
      expect(params23['business_day_rollover_hour'], equals(23));
    });

    test('binds operator_id::uuid + name + address + timezone + '
        'parent_org_unit_id::uuid + business_day_rollover_hour exactly '
        'once each in the INSERT', () async {
      final pool = _LocationsPool(insertedRows: <PostgresRow>[_locationRow()]);
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      await repo.insertLocation(
        operatorId: _opA,
        parentOrgUnitId: _parentOrgUnitA,
        name: 'Downtown',
        address: '123 Main St',
        timezone: 'America/New_York',
        businessDayRolloverHour: 4,
        adminReason: 'admin.locations.create',
      );
      final tx = pool.transactions.single;
      final insertSql = tx.executedSql.firstWhere(
        (s) => s.contains('insert into locations'),
      );
      // Cast operator_id to uuid (defense in depth — text-coerced
      // input would silently land on the wrong tenant on conflict).
      expect(insertSql, contains('@operator_id::uuid'));
      expect(insertSql, contains('@parent_org_unit_id::uuid'));
      expect(insertSql, contains('@name'));
      expect(insertSql, contains('@address'));
      expect(insertSql, contains('@timezone'));
      expect(insertSql, contains('@business_day_rollover_hour'));
      // RETURNING projects location_id::text (Dart-side `String`).
      expect(insertSql, contains('returning location_id::text'));
    });

    test('throws StateError when the INSERT RETURNING is empty — RLS '
        'denial on the BYPASSRLS path is a hard failure, not a silent '
        'null return', () async {
      final pool = _LocationsPool(insertedRows: const <PostgresRow>[]);
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.insertLocation(
          operatorId: _opA,
          parentOrgUnitId: _parentOrgUnitA,
          name: 'X',
          address: 'addr',
          timezone: 'UTC',
          businessDayRolloverHour: 0,
          adminReason: 'admin.locations.create',
        ),
        throwsStateError,
      );
    });
  });

  group('LocationsRepository.updateLocation', () {
    test('coalesce guards every editable column — omitted fields are '
        'preserved, not blanked', () async {
      final pool = _LocationsPool(
        updatedRows: <PostgresRow>[_locationRow(name: 'NewName')],
      );
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      final row = await repo.updateLocation(
        locationId: _locA,
        name: 'NewName',
        adminReason: 'admin.locations.update',
      );
      expect(row, isNotNull);
      expect(row!.name, equals('NewName'));

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.firstWhere(
        (s) => s.contains('update locations'),
      );
      // Every editable column wraps in coalesce(@<name>, <name>) so
      // a null bind preserves the existing value.
      expect(updateSql, contains('name = coalesce(@name, name)'));
      expect(updateSql, contains('address = coalesce(@address, address)'));
      expect(updateSql, contains('timezone = coalesce(@timezone, timezone)'));
      expect(
        updateSql,
        contains(
          'business_day_rollover_hour = coalesce(@business_day_rollover_hour, business_day_rollover_hour)',
        ),
      );
      expect(updateSql, contains('updated_at = now()'));
      expect(updateSql, contains('and deleted_at is null'));

      // Omitted fields bound as null so coalesce keeps the existing
      // column value.
      final params = tx.parameters.firstWhere((p) => p['name'] == 'NewName');
      expect(params['address'], isNull);
      expect(params['timezone'], isNull);
      expect(params['business_day_rollover_hour'], isNull);
    });

    test('business_timezone update path — passing a new IANA value binds '
        'parametrically; coalesce switches to the new value', () async {
      final pool = _LocationsPool(
        updatedRows: <PostgresRow>[_locationRow(timezone: 'Europe/Berlin')],
      );
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      await repo.updateLocation(
        locationId: _locA,
        timezone: 'Europe/Berlin',
        adminReason: 'admin.locations.update',
      );
      final params = pool.transactions.single.parameters.firstWhere(
        (p) => p['timezone'] == 'Europe/Berlin',
      );
      expect(params['timezone'], equals('Europe/Berlin'));
    });

    test('business_day_rollover_hour update path — both endpoints (0 and '
        '23) bind unchanged through the coalesce wrapper', () async {
      final pool = _LocationsPool(
        updatedRows: <PostgresRow>[_locationRow(businessDayRolloverHour: 0)],
      );
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      await repo.updateLocation(
        locationId: _locA,
        businessDayRolloverHour: 0,
        adminReason: 'admin.locations.update',
      );
      final paramsZero = pool.transactions.single.parameters.firstWhere(
        (p) => p['business_day_rollover_hour'] == 0,
      );
      expect(paramsZero['business_day_rollover_hour'], equals(0));

      final pool23 = _LocationsPool(
        updatedRows: <PostgresRow>[_locationRow(businessDayRolloverHour: 23)],
      );
      final repo23 = LocationsRepository(TenantTransactionWrapper(pool23));
      await repo23.updateLocation(
        locationId: _locA,
        businessDayRolloverHour: 23,
        adminReason: 'admin.locations.update',
      );
      final params23 = pool23.transactions.single.parameters.firstWhere(
        (p) => p['business_day_rollover_hour'] == 23,
      );
      expect(params23['business_day_rollover_hour'], equals(23));
    });

    test('returns null when UPDATE … RETURNING yields no rows (location '
        'does not exist — proxy translates to a 404)', () async {
      final pool = _LocationsPool(updatedRows: const <PostgresRow>[]);
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      final row = await repo.updateLocation(
        locationId: _locA,
        name: 'X',
        adminReason: 'admin.locations.update',
      );
      expect(row, isNull);
    });
  });

  group('LocationsRepository.deleteLocation (cross-operator isolation)', () {
    test(
      'DELETE requires BOTH location_id AND operator_id — a stale '
      'location_id cannot accidentally hit the wrong operator\'s row',
      () async {
        final pool = _LocationsPool(deleteAffectedRows: 1);
        final repo = LocationsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.deleteLocation(
          locationId: _locA,
          operatorId: _opA,
          adminReason: 'admin.locations.delete',
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final guardSql = tx.executedSql.firstWhere(
          (s) => s.contains('from user_roles') && s.contains('auth_invites'),
        );
        expect(guardSql, contains("scope_type = 'location'"));
        expect(guardSql, contains('valid_from <= now()'));
        expect(guardSql, contains('expires_at > now()'));

        final deleteSql = tx.executedSql.firstWhere(
          (s) => s.contains('update locations'),
        );
        expect(deleteSql, contains('set deleted_at = now()'));
        expect(deleteSql, contains('where location_id = @location_id::uuid'));
        expect(deleteSql, contains('and operator_id = @operator_id::uuid'));
        expect(deleteSql, contains('and deleted_at is null'));
        // Both are bound parametrically.
        final deleteParams = tx.parameters.firstWhere(
          (p) => p['location_id'] == _locA && p['operator_id'] == _opA,
        );
        expect(deleteParams['location_id'], equals(_locA));
        expect(deleteParams['operator_id'], equals(_opA));
      },
    );

    test('returns 0 when the location does not belong to the operator '
        '(proxy translates that into a 404; the cross-operator predicate '
        'is what makes this safe under BYPASSRLS)', () async {
      final pool = _LocationsPool(deleteAffectedRows: 0);
      final repo = LocationsRepository(TenantTransactionWrapper(pool));
      final affected = await repo.deleteLocation(
        locationId: _locA,
        operatorId: _opB,
        adminReason: 'admin.locations.delete',
      );
      expect(affected, equals(0));
    });

    test(
      'refuses soft delete when active role or invite targets location',
      () async {
        final pool = _LocationsPool(
          activeTargetRows: const <PostgresRow>[
            <String, Object?>{'source': 'user_roles'},
          ],
          deleteAffectedRows: 1,
        );
        final repo = LocationsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.deleteLocation(
            locationId: _locA,
            operatorId: _opA,
            adminReason: 'admin.locations.delete',
          ),
          throwsStateError,
        );
        final tx = pool.transactions.single;
        expect(
          tx.executedSql.any((s) => s.contains('update locations')),
          isFalse,
        );
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the LocationsRepository
/// seam. Mirrors the operators / usage-caps test fakes — every method
/// runs through `withSystem`, so the transaction stream begins with
/// the audit marker + `set local role forge_admin` SET LOCAL chain.
class _LocationsPool implements PostgresPool {
  _LocationsPool({
    this.listForOperatorRows = const <PostgresRow>[],
    this.listAllRows = const <PostgresRow>[],
    this.insertedRows = const <PostgresRow>[],
    this.updatedRows = const <PostgresRow>[],
    this.activeTargetRows = const <PostgresRow>[],
    this.deleteAffectedRows = 0,
  });

  final List<PostgresRow> listForOperatorRows;
  final List<PostgresRow> listAllRows;
  final List<PostgresRow> insertedRows;
  final List<PostgresRow> updatedRows;
  final List<PostgresRow> activeTargetRows;
  final int deleteAffectedRows;
  final List<_LocationsTransaction> transactions = <_LocationsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _LocationsTransaction(
      listForOperatorRows: listForOperatorRows,
      listAllRows: listAllRows,
      insertedRows: insertedRows,
      updatedRows: updatedRows,
      activeTargetRows: activeTargetRows,
      deleteAffectedRows: deleteAffectedRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _LocationsTransaction extends PostgresTransaction {
  _LocationsTransaction({
    required this.listForOperatorRows,
    required this.listAllRows,
    required this.insertedRows,
    required this.updatedRows,
    required this.activeTargetRows,
    required this.deleteAffectedRows,
  });

  final List<PostgresRow> listForOperatorRows;
  final List<PostgresRow> listAllRows;
  final List<PostgresRow> insertedRows;
  final List<PostgresRow> updatedRows;
  final List<PostgresRow> activeTargetRows;
  final int deleteAffectedRows;

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
    if (sql.contains('insert into locations')) {
      return insertedRows;
    }
    if (sql.contains('update locations')) {
      return updatedRows;
    }
    if (sql.contains('from user_roles') && sql.contains('auth_invites')) {
      return activeTargetRows;
    }
    if (sql.contains('from locations')) {
      if (sql.contains('where operator_id = @operator_id::uuid')) {
        return listForOperatorRows;
      }
      return listAllRows;
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
    if (sql.contains('update locations') &&
        sql.contains('deleted_at = now()')) {
      return deleteAffectedRows;
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
