// Slice L_A1 — OrgUnitsRepository hierarchy-read tests.
//
// Pins the three new L_A1 methods (getOrgUnitTreeForOperator,
// getDescendantLocations, getNodeForLocation) against a fake Postgres
// pool that records every executed SQL string + parameter map. Mirrors
// the recording-transaction pattern used in
// `test/infrastructure/persistence/postgres/repositories/handoff_codes_repository_test.dart`.
//
// What we assert:
//   * All three methods route through the tenant transaction wrapper
//     (SET LOCAL app.operator_id / location_id / user_id) BEFORE any
//     hierarchy read — RLS isolation is the primary defense per the
//     OperatorScopedRepository contract.
//   * getOrgUnitTreeForOperator stitches the Business → Org Unit →
//     Location chain in pure Dart from two ordered reads; children
//     are sorted alphabetically; returns null when no root row exists.
//   * getDescendantLocations uses `path <@ ancestor` ltree predicate
//     against the GIST index when scope is supplied; falls back to
//     "every leaf in the tenant" when scope is null.
//   * getNodeForLocation returns null on RLS miss; returns a
//     location-kind node with parent + depth populated when found.
//   * The pure tree assembler (`_assembleTree`-equivalent via
//     getOrgUnitTreeForOperator) preserves a stable deterministic
//     order across runs.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/inheritance_tree_node.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_units_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

void main() {
  group('OrgUnitsRepository.getOrgUnitTreeForOperator', () {
    test('runs SET LOCAL via wrapper before any hierarchy read', () async {
      final pool = _RecordingPool(
        orgUnitsReturning: const <PostgresRow>[
          <String, Object?>{
            'id': 'ou-root',
            'parent_id': null,
            'unit_type': 'corp',
            'path': 'demo',
            'name': 'Demo Bistro',
          },
        ],
        locationsReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final tree = await repo.getOrgUnitTreeForOperator(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
      );

      expect(tree, isNotNull);
      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      // SET LOCAL block lands first (4 set_config calls when a userId
      // is supplied: operator / location / user / bypass_rls_audit)
      // before any hierarchy read.
      expect(tx.executedSql.length, greaterThanOrEqualTo(6));
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      expect(tx.executedSql[1], contains("set_config('app.location_id'"));
      expect(tx.executedSql[2], contains("set_config('app.user_id'"));
      expect(tx.executedSql[3], contains("set_config('app.bypass_rls_audit'"));
      // Then the org_units read, then the locations read.
      final orgUnitsReadIdx = tx.executedSql
          .indexWhere((sql) => sql.contains('from org_units'));
      final locationsReadIdx = tx.executedSql
          .indexWhere((sql) => sql.contains('from locations'));
      // Both reads happened AFTER the SET LOCAL block.
      expect(orgUnitsReadIdx, greaterThanOrEqualTo(4));
      expect(locationsReadIdx, greaterThan(orgUnitsReadIdx));
      expect(tx.commitCount, equals(1));
    });

    test('stitches Business → Org Unit → Location with alphabetical sort',
        () async {
      final pool = _RecordingPool(
        orgUnitsReturning: const <PostgresRow>[
          <String, Object?>{
            'id': 'ou-root',
            'parent_id': null,
            'unit_type': 'corp',
            'path': 'demo',
            'name': 'Demo Bistro',
          },
          <String, Object?>{
            'id': 'ou-south',
            'parent_id': 'ou-root',
            'unit_type': 'region',
            'path': 'demo.south',
            'name': 'South Region',
          },
          <String, Object?>{
            'id': 'ou-north',
            'parent_id': 'ou-root',
            'unit_type': 'region',
            'path': 'demo.north',
            'name': 'North Region',
          },
        ],
        locationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-zeta',
            'parent_org_unit_id': 'ou-north',
            'org_unit_path': 'demo.north',
            'name': 'Zeta Cafe',
          },
          <String, Object?>{
            'location_id': 'loc-alpha',
            'parent_org_unit_id': 'ou-north',
            'org_unit_path': 'demo.north',
            'name': 'Alpha Cafe',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final tree = await repo.getOrgUnitTreeForOperator(
        operatorId: _opA,
        locationId: _locA,
      );

      expect(tree, isNotNull);
      expect(tree!.scopeKind, equals(InheritanceTreeScopeKind.business));
      expect(tree.displayName, equals('Demo Bistro'));
      expect(tree.parentScopeId, isNull);
      expect(tree.depth, equals(0));
      expect(tree.children, hasLength(2));

      // Children sorted alphabetically: North before South.
      final firstChild = tree.children[0];
      expect(firstChild.displayName, equals('North Region'));
      expect(firstChild.scopeKind, equals(InheritanceTreeScopeKind.orgUnit));
      expect(firstChild.parentScopeId, equals('ou-root'));
      expect(firstChild.depth, equals(1));
      expect(firstChild.metadata['unit_type'], equals('region'));

      // North's locations sorted alphabetically: Alpha before Zeta.
      expect(firstChild.children, hasLength(2));
      expect(firstChild.children[0].displayName, equals('Alpha Cafe'));
      expect(
        firstChild.children[0].scopeKind,
        equals(InheritanceTreeScopeKind.location),
      );
      expect(firstChild.children[0].depth, equals(2));
      expect(firstChild.children[1].displayName, equals('Zeta Cafe'));

      // South has no children.
      final secondChild = tree.children[1];
      expect(secondChild.displayName, equals('South Region'));
      expect(secondChild.children, isEmpty);
    });

    test('returns null when the operator has no root row', () async {
      final pool = _RecordingPool(
        orgUnitsReturning: const <PostgresRow>[],
        locationsReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final tree = await repo.getOrgUnitTreeForOperator(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(tree, isNull);
    });

    test('single-location edge case: one root with one direct leaf',
        () async {
      final pool = _RecordingPool(
        orgUnitsReturning: const <PostgresRow>[
          <String, Object?>{
            'id': 'ou-root',
            'parent_id': null,
            'unit_type': 'corp',
            'path': 'demo',
            'name': 'Demo Bistro',
          },
        ],
        locationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-main',
            'parent_org_unit_id': 'ou-root',
            'org_unit_path': 'demo',
            'name': 'Main Street',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final tree = await repo.getOrgUnitTreeForOperator(
        operatorId: _opA,
        locationId: _locA,
      );

      expect(tree, isNotNull);
      expect(tree!.children, hasLength(1));
      expect(tree.children[0].scopeKind, equals(InheritanceTreeScopeKind.location));
      expect(tree.children[0].displayName, equals('Main Street'));
      expect(tree.children[0].depth, equals(1));
    });

    test('locations without a parent are excluded (defensive filter)',
        () async {
      // Should never happen in production (set_location_org_unit_path
      // trigger keeps parent populated), but the assembler must not
      // crash on a malformed dataset.
      final pool = _RecordingPool(
        orgUnitsReturning: const <PostgresRow>[
          <String, Object?>{
            'id': 'ou-root',
            'parent_id': null,
            'unit_type': 'corp',
            'path': 'demo',
            'name': 'Demo Bistro',
          },
        ],
        locationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-orphan',
            'parent_org_unit_id': null,
            'org_unit_path': '',
            'name': 'Orphan Cafe',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final tree = await repo.getOrgUnitTreeForOperator(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(tree, isNotNull);
      expect(tree!.children, isEmpty);
    });

    test('deep nesting honors depth markers across multiple levels',
        () async {
      final pool = _RecordingPool(
        orgUnitsReturning: const <PostgresRow>[
          <String, Object?>{
            'id': 'ou-root',
            'parent_id': null,
            'unit_type': 'corp',
            'path': 'demo',
            'name': 'Demo Bistro',
          },
          <String, Object?>{
            'id': 'ou-east',
            'parent_id': 'ou-root',
            'unit_type': 'region',
            'path': 'demo.east',
            'name': 'East Region',
          },
          <String, Object?>{
            'id': 'ou-dt',
            'parent_id': 'ou-east',
            'unit_type': 'district',
            'path': 'demo.east.downtown',
            'name': 'Downtown District',
          },
        ],
        locationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-flagship',
            'parent_org_unit_id': 'ou-dt',
            'org_unit_path': 'demo.east.downtown',
            'name': 'Flagship Store',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final tree = await repo.getOrgUnitTreeForOperator(
        operatorId: _opA,
        locationId: _locA,
      );
      expect(tree!.depth, equals(0));
      final region = tree.children.single;
      expect(region.depth, equals(1));
      final district = region.children.single;
      expect(district.depth, equals(2));
      expect(district.metadata['unit_type'], equals('district'));
      final loc = district.children.single;
      expect(loc.depth, equals(3));
      expect(loc.scopeKind, equals(InheritanceTreeScopeKind.location));
    });
  });

  group('OrgUnitsRepository.getDescendantLocations', () {
    test(
        'with scope: emits ltree path <@ subtree predicate against GIST index',
        () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-1',
            'parent_org_unit_id': 'ou-region',
            'org_unit_path': 'demo.east',
            'name': 'Store One',
          },
          <String, Object?>{
            'location_id': 'loc-2',
            'parent_org_unit_id': 'ou-district',
            'org_unit_path': 'demo.east.downtown',
            'name': 'Store Two',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final descendants = await repo.getDescendantLocations(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-region',
      );

      expect(descendants, hasLength(2));
      expect(descendants.first.locationId, equals('loc-1'));
      expect(descendants.first.displayName, equals('Store One'));
      expect(descendants.first.orgUnitPath, equals('demo.east'));
      expect(descendants.first.parentOrgUnitId, equals('ou-region'));

      final tx = pool.transactions.single;
      final readSql = tx.executedSql.last;
      // ltree subtree predicate: confirms the GIST-index path is used.
      expect(readSql, contains('l.org_unit_path <@ scope.path'));
      // Bind the scope id as a UUID.
      expect(readSql, contains('@scope_id::uuid'));
      final params = tx.parameters.last;
      expect(params['scope_id'], equals('ou-region'));
    });

    test('without scope: returns every leaf in the tenant', () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-1',
            'parent_org_unit_id': 'ou-root',
            'org_unit_path': 'demo',
            'name': 'Only Store',
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final descendants = await repo.getDescendantLocations(
        operatorId: _opA,
        locationId: _locA,
      );

      expect(descendants, hasLength(1));
      final tx = pool.transactions.single;
      final readSql = tx.executedSql.last;
      // No SCOPE-bounded ltree subtree predicate when scope is
      // omitted — RLS scopes the read to the operator's locations.
      // (The defensive ancestor-chain filter does use `<@`, so we
      // assert specifically on the scope-bounding subtree predicate
      // shape `l.org_unit_path <@ scope.path` not being present.)
      expect(readSql.contains('l.org_unit_path <@ scope.path'), isFalse);
      expect(readSql.contains('@scope_id'), isFalse);
      expect(readSql, contains('from locations'));
    });

    test('returns empty list when scope has no leaves', () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final descendants = await repo.getDescendantLocations(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-empty',
      );
      expect(descendants, isEmpty);
    });

    test('runs through withTenant so RLS isolates the read', () async {
      final pool = _RecordingPool(
        descendantLocationsReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      await repo.getDescendantLocations(
        operatorId: _opA,
        locationId: _locA,
        scopeOrgUnitId: 'ou-x',
      );

      final tx = pool.transactions.single;
      // SET LOCAL block runs first (3 set_config calls when userId is
      // null; 4 when supplied).
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      // The read is INSIDE the tenant tx (after SET LOCAL).
      expect(tx.executedSql.length, greaterThanOrEqualTo(4));
      expect(tx.executedSql.last, contains('from locations'));
    });
  });

  group('OrgUnitsRepository.getNodeForLocation', () {
    test('returns a location node with parent + depth populated', () async {
      final pool = _RecordingPool(
        nodeForLocationReturning: const <PostgresRow>[
          <String, Object?>{
            'location_id': 'loc-target',
            'parent_org_unit_id': 'ou-region',
            'org_unit_path': 'demo.east',
            'name': 'Target Store',
            'depth': 2,
          },
        ],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final node = await repo.getNodeForLocation(
        operatorId: _opA,
        locationId: _locA,
        targetLocationId: 'loc-target',
      );

      expect(node, isNotNull);
      expect(node!.scopeKind, equals(InheritanceTreeScopeKind.location));
      expect(node.scopeId, equals('loc-target'));
      expect(node.displayName, equals('Target Store'));
      expect(node.parentScopeId, equals('ou-region'));
      expect(node.depth, equals(2));
      expect(node.metadata['org_unit_path'], equals('demo.east'));

      final tx = pool.transactions.single;
      final params = tx.parameters.last;
      expect(params['location_id'], equals('loc-target'));
    });

    test('returns null when RLS hides the location', () async {
      final pool = _RecordingPool(
        nodeForLocationReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      final node = await repo.getNodeForLocation(
        operatorId: _opA,
        locationId: _locA,
        targetLocationId: 'loc-missing',
      );
      expect(node, isNull);
    });

    test('runs through withTenant (no withSystem leak)', () async {
      final pool = _RecordingPool(
        nodeForLocationReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      await repo.getNodeForLocation(
        operatorId: _opA,
        locationId: _locA,
        targetLocationId: 'loc-x',
      );

      final tx = pool.transactions.single;
      // SET LOCAL for tenant runs first; bypass_rls_audit must NOT
      // carry the 'system:' marker (that marker only fires under
      // withSystem — `runAsSystem` in tenant_transaction.dart sets
      // bypass_rls_audit to `system:<reason>`). The tenant path
      // stamps the literal `'tenant'` instead.
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      final bypassCall = tx.executedSql.firstWhere(
        (sql) => sql.contains("set_config('app.bypass_rls_audit'"),
        orElse: () => '',
      );
      expect(bypassCall, isNot(equals('')));
      expect(bypassCall, contains("'tenant'"));
      expect(bypassCall.contains('system:'), isFalse);
    });
  });

  group('OperatorScopedRepository inheritance', () {
    test('OrgUnitsRepository extends OperatorScopedRepository', () {
      final repo = OrgUnitsRepository(
        TenantTransactionWrapper(_RecordingPool()),
      );
      expect(repo, isA<OperatorScopedRepository>());
    });
  });

  group('OrgUnitsRepository.getOrgUnitTreeForOperator — cross-tenant '
      'isolation posture', () {
    test('RLS-scope: read SQL relies on tenant context, not literal '
        'operator_id binding', () async {
      // The hierarchy reads do NOT bind `operator_id` as a SQL parameter
      // — they rely on the `org_units_per_tenant` RLS policy + the
      // `app_current_operator()` wrapper. This is by design: a literal
      // WHERE predicate would be a defense-in-depth layer, but the
      // primary defense is the per-tenant tx SET LOCAL.
      final pool = _RecordingPool(
        orgUnitsReturning: const <PostgresRow>[
          <String, Object?>{
            'id': 'ou-root',
            'parent_id': null,
            'unit_type': 'corp',
            'path': 'demo',
            'name': 'Demo',
          },
        ],
        locationsReturning: const <PostgresRow>[],
      );
      final repo = OrgUnitsRepository(TenantTransactionWrapper(pool));

      await repo.getOrgUnitTreeForOperator(
        operatorId: _opA,
        locationId: _locA,
      );

      final tx = pool.transactions.single;
      // Locate the two hierarchy reads (SET LOCAL count varies with
      // whether userId is supplied; we did NOT supply one here).
      final orgUnitsReadSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('from org_units') &&
            sql.contains('order by path'),
      );
      final locationsReadSql = tx.executedSql.firstWhere(
        (sql) =>
            sql.contains('from locations') && sql.contains('order by name'),
      );
      // Reads do NOT bind a parameter-bound operator_id literally —
      // RLS (via SET LOCAL app.operator_id) is the gate. The locations
      // read does reference operator_id in a JOIN predicate against
      // org_units for the soft-deleted-ancestor defensive filter, but
      // it never binds `@operator_id` as a parameter — the only
      // operator_id-shaped binding sites in this repo are the writes,
      // not the reads.
      expect(orgUnitsReadSql.contains('@operator_id'), isFalse);
      expect(locationsReadSql.contains('@operator_id'), isFalse);
      // Defensive filter for soft-deleted ancestor chain is present
      // so visualization stays consistent with listLocationsForTenant.
      expect(
        locationsReadSql,
        contains('deleted_ancestor.deleted_at is not null'),
      );
    });
  });
}

/// Recording transaction. Captures every executed SQL + parameter map
/// and routes the various read shapes (org_units list, locations list,
/// descendant location list, single-location lookup) to per-test
/// override hooks. Models the same recording posture as the handoff
/// codes repository tests.
class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    this.orgUnitsReturning,
    this.locationsReturning,
    this.descendantLocationsReturning,
    this.nodeForLocationReturning,
  });

  final List<PostgresRow>? orgUnitsReturning;
  final List<PostgresRow>? locationsReturning;
  final List<PostgresRow>? descendantLocationsReturning;
  final List<PostgresRow>? nodeForLocationReturning;

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
    // Routing distinguishes the 4 read shapes used by L_A1's three
    // methods. Order matters: check the more specific markers first so
    // a generic `from org_units` substring (which appears in EVERY
    // hierarchy read's `deleted_ancestor` defensive subquery) does not
    // misroute the locations reads.
    final lowered = sql.toLowerCase();
    if (lowered.contains('from locations') ||
        lowered.contains('from public.locations')) {
      // Single-location lookup (`getNodeForLocation`) uses
      // `nlevel(org_unit_path)`.
      if (lowered.contains('nlevel(org_unit_path)')) {
        return nodeForLocationReturning ?? const <PostgresRow>[];
      }
      // Descendant-set lookup with scope uses an ltree subtree
      // predicate. No-scope descendant uses the
      // `order by org_unit_path, lower(name), location_id` clause.
      if (lowered.contains('l.org_unit_path <@ scope.path') ||
          lowered.contains('order by org_unit_path, lower(name), location_id')) {
        return descendantLocationsReturning ?? const <PostgresRow>[];
      }
      return locationsReturning ?? const <PostgresRow>[];
    }
    if (lowered.contains('from org_units')) {
      return orgUnitsReturning ?? const <PostgresRow>[];
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

class _RecordingPool implements PostgresPool {
  _RecordingPool({
    this.orgUnitsReturning,
    this.locationsReturning,
    this.descendantLocationsReturning,
    this.nodeForLocationReturning,
  });

  final List<PostgresRow>? orgUnitsReturning;
  final List<PostgresRow>? locationsReturning;
  final List<PostgresRow>? descendantLocationsReturning;
  final List<PostgresRow>? nodeForLocationReturning;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      orgUnitsReturning: orgUnitsReturning,
      locationsReturning: locationsReturning,
      descendantLocationsReturning: descendantLocationsReturning,
      nodeForLocationReturning: nodeForLocationReturning,
    );
    transactions.add(tx);
    return tx;
  }
}
