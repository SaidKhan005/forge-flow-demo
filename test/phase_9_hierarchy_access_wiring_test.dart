// Phase 9 hierarchy access wiring tests.
//
// Two layers:
//
//   1. STRUCTURAL (offline, runs in every flutter test invocation):
//      Text-greps the migration file for required DDL strings — a
//      cheap sanity check that catches accidental migration deletions
//      or column renames during refactor. Cannot detect runtime
//      regressions.
//
//   2. INTEGRATION (passive-by-default, gated on
//      `FORGE_FLOW_RUN_STAGING_HIERARCHY_TEST=true` + POSTGRES_URL +
//      POSTGRES_ADMIN_URL): runs the migration's trigger semantics,
//      ltree path denormalization, subtree predicate, and RLS
//      isolation against a live staging database. Live target is
//      staging only — never Production1.
//
// The integration layer owns RLS isolation coverage for
// `user_effective_locations` (referenced from
// `phase_9_0sigma_rls_isolation_sweep_test.dart` by comment) since
// the table is trigger-maintained from `user_roles` and needs the
// fuller users + roles + user_roles fixture.
//
// CLAUDE.md bindings:
//   * `package:postgres` is not imported here; all SQL flows through
//     `PackagePostgresPool` + `TenantTransactionWrapper`, so SET
//     LOCAL discipline holds and the rule against direct
//     `package:postgres` imports outside
//     `lib/infrastructure/persistence/postgres/` is preserved.
//   * Admin DSN is used only for fixture seed/cleanup; tenant checks
//     run through `runInTenantContext`, and forge_admin emergency
//     reads run through `runAsSystem`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

// ─── Fixture identifiers ─────────────────────────────────────────────
//
// `hier0000…` namespace marks every fixture row so a manual cleanup on
// staging can be recognized at a glance and the seed/cleanup helper
// has a deterministic predicate. Two operators each with a small
// org_unit subtree (root → region → district), two locations per
// operator (one attached at region level, one at district level), one
// user, and one operator-scoped test role.

const String _opA = 'hier0000-0000-0000-0000-0000000000a1';
const String _opB = 'hier0000-0000-0000-0000-0000000000b1';

// org_unit hierarchy per operator: root (corp) → region → district.
// The integration test inserts `user_roles` scoped to each level and
// asserts the trigger populates `user_effective_locations` with the
// correct subtree.
const String _ouRootA = 'hier0000-0000-0000-0000-0000000000a2';
const String _ouRegionA = 'hier0000-0000-0000-0000-0000000000a3';
const String _ouDistrictA = 'hier0000-0000-0000-0000-0000000000a4';

const String _ouRootB = 'hier0000-0000-0000-0000-0000000000b2';
const String _ouRegionB = 'hier0000-0000-0000-0000-0000000000b3';
const String _ouDistrictB = 'hier0000-0000-0000-0000-0000000000b4';

// Two locations per operator. `_locRegion*` is attached directly at
// the region level (so an org_unit grant at the district level should
// NOT cover it). `_locDistrict*` hangs off the district.
const String _locRegionA = 'hier0000-0000-0000-0000-0000000000a5';
const String _locDistrictA = 'hier0000-0000-0000-0000-0000000000a6';
const String _locRegionB = 'hier0000-0000-0000-0000-0000000000b5';
const String _locDistrictB = 'hier0000-0000-0000-0000-0000000000b6';

const String _userA = 'hier0000-0000-0000-0000-0000000000a7';
const String _userB = 'hier0000-0000-0000-0000-0000000000b7';

const String _roleA = 'hier0000-0000-0000-0000-0000000000a8';
const String _roleB = 'hier0000-0000-0000-0000-0000000000b8';

const String _fixtureMarker = 'hier-rls-test';
const String _envFlag = 'FORGE_FLOW_RUN_STAGING_HIERARCHY_TEST';
const String _envPostgresUrl = 'POSTGRES_URL';
const String _envPostgresAdminUrl = 'POSTGRES_ADMIN_URL';

void main() {
  // ─── STRUCTURAL layer (offline, every run) ───────────────────────
  //
  // Cheap migration-file shape check. Catches accidental migration
  // deletion or column renames during refactor. Does not detect
  // runtime regressions — those are the integration layer below.

  group('Phase 9 hierarchy access wiring migration shape', () {
    final migration = File(
      'db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    test('attaches locations to org_units with denormalized paths', () {
      expect(
        migration,
        contains('add column if not exists parent_org_unit_id'),
      );
      expect(migration, contains('add column if not exists org_unit_path'));
      expect(migration, contains('locations_parent_org_unit_fk'));
      expect(migration, contains('locations_org_unit_path_gist_idx'));
      expect(migration, contains('set_location_org_unit_path'));
    });

    test('allows org-unit scoped user roles and invites', () {
      expect(
        migration,
        contains(
          "check (scope_type in ('operator_wide', 'org_unit', 'location'))",
        ),
      );
      expect(migration, contains('add column if not exists org_unit_id'));
      expect(migration, contains('user_roles_scope_payload_check'));
      expect(migration, contains('auth_invites_scope_payload_check'));
      expect(migration, contains('auth_invites_operator_org_unit_idx'));
    });

    test('materializes effective locations for permission resolution', () {
      expect(
        migration,
        contains('create table if not exists public.user_effective_locations'),
      );
      expect(migration, contains('source_scope_type text not null'));
      expect(migration, contains("ur.scope_type = 'operator_wide'"));
      expect(migration, contains("ur.scope_type = 'location'"));
      expect(migration, contains("ur.scope_type = 'org_unit'"));
      expect(migration, contains('loc.org_unit_path <@ ou.path'));
      expect(migration, contains('refresh_user_effective_locations'));
      expect(migration, contains('user_roles_refresh_effective_locations'));
    });

    test('keeps tenant RLS wrapper discipline on effective-location cache',
        () {
      expect(migration, contains('enable row level security'));
      expect(
        migration,
        contains('using (operator_id = public.app_current_operator())'),
      );
      expect(
        migration,
        contains('with check (operator_id = public.app_current_operator())'),
      );
    });
  });

  // ─── INTEGRATION layer (passive-by-default, staging only) ────────
  //
  // PASSIVE BY DEFAULT. The whole integration suite runs only when
  // `FORGE_FLOW_RUN_STAGING_HIERARCHY_TEST=true` is set; without the
  // flag the suite skips with a clear name-only reason. With the flag
  // set but `POSTGRES_URL` or `POSTGRES_ADMIN_URL` missing, the suite
  // fails fast with a BLOCKED-style preflight error that names ONLY
  // the missing env names — values are never echoed. Live target is
  // staging only — never Production1.

  final flagRaw = Platform.environment[_envFlag] ?? '';
  final liveEnabled = flagRaw.toLowerCase() == 'true' || flagRaw == '1';

  if (!liveEnabled) {
    test(
      'Phase 9 hierarchy access wiring integration (passive default)',
      () {
        // The skip below is the contract — body intentionally empty.
      },
      skip:
          'Hierarchy integration suite is passive by default. To run '
          'against staging Postgres, set $_envFlag=true and provide '
          '$_envPostgresUrl + $_envPostgresAdminUrl. Live target is '
          'staging only — never Production1.',
    );
    return;
  }

  final pgUrl = Platform.environment[_envPostgresUrl];
  final pgAdminUrl = Platform.environment[_envPostgresAdminUrl];
  final missingEnv = <String>[
    if (pgUrl == null || pgUrl.isEmpty) _envPostgresUrl,
    if (pgAdminUrl == null || pgAdminUrl.isEmpty) _envPostgresAdminUrl,
  ];
  if (missingEnv.isNotEmpty) {
    test('Phase 9 hierarchy integration — env preflight', () {
      fail(
        'BLOCKED: $_envFlag is true but required env names are '
        'missing: ${missingEnv.join(', ')}. Source the staging env '
        'loader (scripts/use_postgres_staging_env.ps1) and re-run. '
        'No env values are echoed by this test.',
      );
    });
    return;
  }

  late PackagePostgresPool tenantPool;
  late PackagePostgresPool adminPool;
  late TenantTransactionWrapper tenantWrapper;

  setUpAll(() async {
    tenantPool = PackagePostgresPool.fromUrl(pgUrl!);
    adminPool = PackagePostgresPool.fromUrl(pgAdminUrl!);
    tenantWrapper = TenantTransactionWrapper(tenantPool);

    await _runAdmin(adminPool, _cleanupFixtures);
    await _runAdmin(adminPool, _seedBaseFixtures);
  });

  tearDownAll(() async {
    await _runAdmin(adminPool, _cleanupFixtures);
  });

  // ─── Trigger semantics ───────────────────────────────────────────

  group('hierarchy trigger semantics', () {
    test('inserting an operator_wide user_role populates u_e_l for every '
        'location under the operator (including both region and district '
        'attached locations)', () async {
      // Clean any prior grants for this user so the assertion sees only
      // the row this test inserts.
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id = @uid::uuid',
          parameters: <String, Object?>{'uid': _userA},
        );
      });

      await _runAdmin(adminPool, (exec) async {
        await _insertUserRole(
          exec: exec,
          operatorId: _opA,
          userId: _userA,
          roleId: _roleA,
          scopeType: 'operator_wide',
          locationId: null,
          orgUnitId: null,
        );
      });

      final cached = await _readEffectiveLocations(adminPool, _opA, _userA);
      expect(
        cached.toSet(),
        equals(<String>{_locRegionA, _locDistrictA}.toSet()),
        reason: 'operator_wide grant should map to every operator '
            'location regardless of org-unit attachment depth',
      );
    });

    test('inserting an org_unit-scoped user_role at the region level '
        'populates u_e_l for every location whose org_unit_path is below '
        'the region path (loc.org_unit_path <@ ou.path)', () async {
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id = @uid::uuid',
          parameters: <String, Object?>{'uid': _userA},
        );
      });

      await _runAdmin(adminPool, (exec) async {
        await _insertUserRole(
          exec: exec,
          operatorId: _opA,
          userId: _userA,
          roleId: _roleA,
          scopeType: 'org_unit',
          locationId: null,
          orgUnitId: _ouRegionA,
        );
      });

      final cached = await _readEffectiveLocations(adminPool, _opA, _userA);
      // _locRegionA is attached at the region level; _locDistrictA is
      // attached at the district level (a descendant of region). Both
      // are below the region path — both must appear.
      expect(
        cached.toSet(),
        equals(<String>{_locRegionA, _locDistrictA}.toSet()),
        reason: 'region-scoped grant should cover region + descendant '
            'locations via the ltree subtree predicate',
      );
    });

    test('inserting an org_unit-scoped user_role at the district level '
        'populates u_e_l only for the location attached at or below the '
        'district', () async {
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id = @uid::uuid',
          parameters: <String, Object?>{'uid': _userA},
        );
      });

      await _runAdmin(adminPool, (exec) async {
        await _insertUserRole(
          exec: exec,
          operatorId: _opA,
          userId: _userA,
          roleId: _roleA,
          scopeType: 'org_unit',
          locationId: null,
          orgUnitId: _ouDistrictA,
        );
      });

      final cached = await _readEffectiveLocations(adminPool, _opA, _userA);
      expect(
        cached,
        equals(<String>[_locDistrictA]),
        reason: 'district-scoped grant should only cover the location '
            'attached at the district (region-level location is OUTSIDE '
            'the district subtree)',
      );
    });

    test('inserting a location-scoped user_role populates u_e_l for only '
        'that single location', () async {
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id = @uid::uuid',
          parameters: <String, Object?>{'uid': _userA},
        );
      });

      await _runAdmin(adminPool, (exec) async {
        await _insertUserRole(
          exec: exec,
          operatorId: _opA,
          userId: _userA,
          roleId: _roleA,
          scopeType: 'location',
          locationId: _locRegionA,
          orgUnitId: null,
        );
      });

      final cached = await _readEffectiveLocations(adminPool, _opA, _userA);
      expect(cached, equals(<String>[_locRegionA]));
    });

    test('deleting a user_role removes the cache rows it sourced (per-user '
        'refresh path)', () async {
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id = @uid::uuid',
          parameters: <String, Object?>{'uid': _userA},
        );
        await _insertUserRole(
          exec: exec,
          operatorId: _opA,
          userId: _userA,
          roleId: _roleA,
          scopeType: 'operator_wide',
          locationId: null,
          orgUnitId: null,
        );
      });

      final before = await _readEffectiveLocations(adminPool, _opA, _userA);
      expect(before, isNotEmpty);

      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id = @uid::uuid',
          parameters: <String, Object?>{'uid': _userA},
        );
      });

      final after = await _readEffectiveLocations(adminPool, _opA, _userA);
      expect(after, isEmpty,
          reason: 'AFTER DELETE on user_roles, the trigger refresh '
              'should have wiped the user\'s cache rows');
    });

    test('updating a user_role.location_id refreshes u_e_l to the new '
        'location', () async {
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id = @uid::uuid',
          parameters: <String, Object?>{'uid': _userA},
        );
      });

      String userRoleId = '';
      await _runAdmin(adminPool, (exec) async {
        userRoleId = await _insertUserRole(
          exec: exec,
          operatorId: _opA,
          userId: _userA,
          roleId: _roleA,
          scopeType: 'location',
          locationId: _locRegionA,
          orgUnitId: null,
        );
      });

      final before = await _readEffectiveLocations(adminPool, _opA, _userA);
      expect(before, equals(<String>[_locRegionA]));

      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'update public.user_roles '
          'set location_id = @newLocId::uuid '
          'where user_role_id = @urId::uuid',
          parameters: <String, Object?>{
            'newLocId': _locDistrictA,
            'urId': userRoleId,
          },
        );
      });

      final after = await _readEffectiveLocations(adminPool, _opA, _userA);
      expect(after, equals(<String>[_locDistrictA]),
          reason: 'AFTER UPDATE on user_roles.location_id, the trigger '
              'should have replaced the cache row');
    });

    test('inserting a location with parent_org_unit_id correctly '
        'denormalizes org_unit_path from the parent org_unit', () async {
      // Insert a brand-new location attached to the district org_unit.
      // Verify the BEFORE INSERT trigger set its `org_unit_path` to
      // match `org_units(_opA, _ouDistrictA).path`.
      const String tempLoc = 'hier0000-0000-0000-0000-000000000fff';

      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.locations where location_id = @id::uuid',
          parameters: <String, Object?>{'id': tempLoc},
        );
        await exec.execute(
          'insert into public.locations '
          '(location_id, operator_id, parent_org_unit_id, name, '
          'timezone, business_day_rollover_hour) '
          "values (@id::uuid, @op::uuid, @parent::uuid, "
          "'hier-test-derived-loc', 'America/Toronto', 4)",
          parameters: <String, Object?>{
            'id': tempLoc,
            'op': _opA,
            'parent': _ouDistrictA,
          },
        );

        final rows = await exec.query(
          'select org_unit_path::text as path from public.locations '
          'where location_id = @id::uuid',
          parameters: <String, Object?>{'id': tempLoc},
        );
        expect(rows, hasLength(1));
        // Path corresponds to the district org_unit (`hier_a.region.district`).
        expect(rows.single['path'], equals('hier_a.region.district'));

        // Cleanup the derived row so subsequent runs are deterministic.
        await exec.execute(
          'delete from public.locations where location_id = @id::uuid',
          parameters: <String, Object?>{'id': tempLoc},
        );
      });
    });
  });

  // ─── RLS isolation on user_effective_locations ───────────────────

  group('user_effective_locations RLS isolation', () {
    setUp(() async {
      // Pin the per-tenant fixture state for these assertions: each
      // operator has exactly one operator_wide grant for its user, so
      // each operator owns exactly two u_e_l rows (one per location).
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'delete from public.user_roles where user_id::text in '
          "('$_userA', '$_userB')",
        );
        await _insertUserRole(
          exec: exec,
          operatorId: _opA,
          userId: _userA,
          roleId: _roleA,
          scopeType: 'operator_wide',
          locationId: null,
          orgUnitId: null,
        );
        await _insertUserRole(
          exec: exec,
          operatorId: _opB,
          userId: _userB,
          roleId: _roleB,
          scopeType: 'operator_wide',
          locationId: null,
          orgUnitId: null,
        );
      });
    });

    test('tenant A SELECT cannot see tenant B u_e_l rows (RLS USING)',
        () async {
      final ctx = TenantContext(
        operatorId: _opA,
        locationId: _locRegionA,
        userId: _userA,
      );
      final rows =
          await tenantWrapper.runInTenantContext<List<PostgresRow>>(
        ctx,
        (exec) => exec.query(
          'select count(*)::bigint as cnt '
          'from public.user_effective_locations '
          'where operator_id = @other::uuid',
          parameters: <String, Object?>{'other': _opB},
        ),
      );
      final cnt = (rows.single['cnt'] as int?) ??
          int.tryParse('${rows.single['cnt']}') ??
          0;
      expect(cnt, equals(0));
    });

    test('tenant B SELECT cannot see tenant A u_e_l rows (RLS USING)',
        () async {
      final ctx = TenantContext(
        operatorId: _opB,
        locationId: _locRegionB,
        userId: _userB,
      );
      final rows =
          await tenantWrapper.runInTenantContext<List<PostgresRow>>(
        ctx,
        (exec) => exec.query(
          'select count(*)::bigint as cnt '
          'from public.user_effective_locations '
          'where operator_id = @other::uuid',
          parameters: <String, Object?>{'other': _opA},
        ),
      );
      final cnt = (rows.single['cnt'] as int?) ??
          int.tryParse('${rows.single['cnt']}') ??
          0;
      expect(cnt, equals(0));
    });

    test(
        'cross-tenant direct INSERT is rejected by RLS WITH CHECK or affects '
        '0 rows', () async {
      final ctx = TenantContext(
        operatorId: _opA,
        locationId: _locRegionA,
        userId: _userA,
      );
      // The cross row clones B's FK chain (operator_id, user_id,
      // location_id, source_user_role_id all reference B's rows). A
      // broken WITH CHECK is the only way this row would land.
      final rows = await _runAdminQuery(
        adminPool,
        'select user_role_id::text as urid from public.user_roles '
        'where user_id = @uid::uuid limit 1',
        <String, Object?>{'uid': _userB},
      );
      expect(rows, hasLength(1),
          reason: 'fixture should have a B user_role to clone the FK from');
      final bUserRoleId = rows.single['urid'] as String;

      Object? caught;
      var affected = -1;
      try {
        affected =
            await tenantWrapper.runInTenantContext<int>(ctx, (exec) async {
          // A row attributed to opB but inserted under opA's tenant
          // context. WITH CHECK should reject because
          // `operator_id (= opB) != app_current_operator() (= opA)`.
          // Use an explicit user_effective_location_id so we can
          // detect a forged row by its known UUID afterwards.
          return exec.execute(
            'insert into public.user_effective_locations ('
            'user_effective_location_id, operator_id, user_id, '
            'location_id, source_user_role_id, source_scope_type) '
            'values (@id::uuid, @op::uuid, @uid::uuid, @loc::uuid, '
            "@urid::uuid, 'operator_wide')",
            parameters: <String, Object?>{
              'id': 'hier0000-0000-0000-0000-0000000fffff',
              'op': _opB,
              'uid': _userB,
              'loc': _locRegionB,
              'urid': bUserRoleId,
            },
          );
        });
      } catch (e) {
        caught = e;
      }

      expect(caught != null || affected == 0, isTrue,
          reason:
              'cross-tenant INSERT under $_opA attributing to $_opB must be '
              'rejected (WITH CHECK / privilege) or affect 0 rows. Got '
              'rejected=${caught != null}, affected=$affected, '
              'error=$caught');

      // Admin-side: confirm no forged row landed.
      final forgedRows = await _runAdminQuery(
        adminPool,
        'select count(*)::bigint as cnt from '
        'public.user_effective_locations where '
        'user_effective_location_id = @id::uuid',
        <String, Object?>{'id': 'hier0000-0000-0000-0000-0000000fffff'},
      );
      final forged = (forgedRows.single['cnt'] as int?) ??
          int.tryParse('${forgedRows.single['cnt']}') ??
          0;
      expect(forged, equals(0));
    });

    test('cross-tenant UPDATE under tenant A cannot touch tenant B u_e_l '
        'rows (RLS USING filters them out — 0 rows affected)', () async {
      final ctx = TenantContext(
        operatorId: _opA,
        locationId: _locRegionA,
        userId: _userA,
      );
      final affected = await tenantWrapper.runInTenantContext<int>(
        ctx,
        (exec) => exec.execute(
          // Try to flip every B row's source_scope_type to a different
          // (still valid) value. RLS USING filters them out, so the
          // UPDATE matches 0 rows.
          'update public.user_effective_locations '
          "set source_scope_type = 'location' "
          'where operator_id = @other::uuid',
          parameters: <String, Object?>{'other': _opB},
        ),
      );
      expect(affected, equals(0));

      // Admin-side: B's rows still carry their original
      // source_scope_type ('operator_wide' from the seed).
      final rows = await _runAdminQuery(
        adminPool,
        'select source_scope_type from '
        'public.user_effective_locations '
        'where operator_id = @op::uuid '
        'order by source_scope_type',
        <String, Object?>{'op': _opB},
      );
      for (final row in rows) {
        expect(row['source_scope_type'], equals('operator_wide'));
      }
    });

    test('cross-tenant DELETE under tenant A cannot remove tenant B u_e_l '
        'rows (RLS USING filters them out — 0 rows affected)', () async {
      final ctx = TenantContext(
        operatorId: _opA,
        locationId: _locRegionA,
        userId: _userA,
      );
      final affected = await tenantWrapper.runInTenantContext<int>(
        ctx,
        (exec) => exec.execute(
          'delete from public.user_effective_locations '
          'where operator_id = @other::uuid',
          parameters: <String, Object?>{'other': _opB},
        ),
      );
      expect(affected, equals(0));

      // Admin-side: B's rows are still there (the operator_wide grant
      // produced one row per B location).
      final rows = await _runAdminQuery(
        adminPool,
        'select count(*)::bigint as cnt from '
        'public.user_effective_locations '
        'where operator_id = @op::uuid',
        <String, Object?>{'op': _opB},
      );
      final cnt = (rows.single['cnt'] as int?) ??
          int.tryParse('${rows.single['cnt']}') ??
          0;
      expect(cnt, greaterThanOrEqualTo(2));
    });

    test('forge_admin emergency read via runAsSystem sees both tenants',
        () async {
      final rows = await tenantWrapper.runAsSystem<List<PostgresRow>>(
        (exec) => exec.query(
          'select operator_id::text as operator_id, '
          'count(*)::bigint as cnt from '
          'public.user_effective_locations '
          "where operator_id::text in ('$_opA', '$_opB') "
          'group by operator_id::text',
        ),
        reason: 'hierarchy_emergency_read:user_effective_locations',
      );
      final perOp = <String, int>{
        for (final row in rows)
          (row['operator_id'] as String): (row['cnt'] as int?) ??
              int.parse('${row['cnt']}'),
      };
      expect(perOp[_opA] ?? 0, greaterThanOrEqualTo(1));
      expect(perOp[_opB] ?? 0, greaterThanOrEqualTo(1));
    });

    test('tenant SET LOCAL EXPLAIN plan uses operator_id-leading index '
        'on user_effective_locations (RLS performance discipline)',
        () async {
      final ctx = TenantContext(
        operatorId: _opA,
        locationId: _locRegionA,
        userId: _userA,
      );
      final planJson =
          await tenantWrapper.runInTenantContext<Object?>(ctx, (exec) async {
        await exec.execute('set local enable_seqscan = off');
        await exec.execute('set local enable_bitmapscan = off');
        final rows = await exec.query(
          'explain (format json) select 1 from '
          'public.user_effective_locations limit 1',
        );
        return rows.single['QUERY PLAN'];
      });

      final parsed = _parseExplainJson(planJson);
      expect(_planUsesTenantLeadingIndex(parsed), isTrue,
          reason: 'user_effective_locations EXPLAIN must use an Index/'
              'Bitmap path whose Index Cond / Index Name names operator_id');
    });
  });
}

// ─── Fixture helpers ────────────────────────────────────────────────

Future<void> _runAdmin(
  PackagePostgresPool pool,
  Future<void> Function(PostgresExecutor exec) body,
) async {
  final tx = await pool.beginTransaction();
  var finalized = false;
  try {
    await body(tx);
    await tx.commit();
    finalized = true;
  } finally {
    if (!finalized) {
      try {
        await tx.rollback();
      } catch (_) {/* swallow */}
    }
  }
}

Future<List<PostgresRow>> _runAdminQuery(
  PackagePostgresPool pool,
  String sql,
  Map<String, Object?> parameters,
) async {
  late List<PostgresRow> rows;
  await _runAdmin(pool, (exec) async {
    rows = await exec.query(sql, parameters: parameters);
  });
  return rows;
}

Future<List<String>> _readEffectiveLocations(
  PackagePostgresPool adminPool,
  String operatorId,
  String userId,
) async {
  final rows = await _runAdminQuery(
    adminPool,
    'select location_id::text as loc from '
    'public.user_effective_locations '
    'where operator_id = @op::uuid and user_id = @uid::uuid '
    'order by location_id',
    <String, Object?>{'op': operatorId, 'uid': userId},
  );
  return <String>[for (final r in rows) r['loc'] as String];
}

Future<String> _insertUserRole({
  required PostgresExecutor exec,
  required String operatorId,
  required String userId,
  required String roleId,
  required String scopeType,
  required String? locationId,
  required String? orgUnitId,
}) async {
  // Generate the user_role_id client-side so the test can address the
  // row directly afterwards.
  final userRoleId = _newUuidFor(operatorId, scopeType);
  await exec.execute(
    'insert into public.user_roles ('
    'user_role_id, user_id, role_id, operator_id, location_id, '
    'org_unit_id, scope_type, granted_by) '
    'values (@urid::uuid, @uid::uuid, @rid::uuid, @op::uuid, '
    '@loc::uuid, @ou::uuid, @scope, @uid::uuid)',
    parameters: <String, Object?>{
      'urid': userRoleId,
      'uid': userId,
      'rid': roleId,
      'op': operatorId,
      'loc': locationId,
      'ou': orgUnitId,
      'scope': scopeType,
    },
  );
  return userRoleId;
}

String _newUuidFor(String operatorId, String scopeType) {
  // Deterministic-ish UUID per (operator, scope) so a developer
  // running the test can tell at a glance what role belongs where in
  // the staging fixture residue, but every run uses a fresh tail
  // segment so a re-run after a partial cleanup does not collide on
  // the unique active-grant index.
  final tail = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final padded = tail.padLeft(12, '0').substring(0, 12);
  final shardA = operatorId.endsWith('a1') ? 'a' : 'b';
  final shardB = scopeType == 'operator_wide'
      ? '1'
      : scopeType == 'org_unit'
          ? '2'
          : '3';
  return 'hier0000-0000-0000-0000-${shardA}c$shardB$padded';
}

Future<void> _cleanupFixtures(PostgresExecutor exec) async {
  // Order matters because of FK chains: user_effective_locations is
  // trigger-cascaded but we still scrub it explicitly in case a prior
  // run left rows. user_roles cascades to u_e_l via the trigger.
  Future<void> deleteWhere(String table, String predicate) async {
    await exec.execute('delete from public.$table where $predicate');
  }

  await deleteWhere(
    'user_effective_locations',
    "operator_id::text in ('$_opA', '$_opB')",
  );
  await deleteWhere(
    'user_roles',
    "operator_id::text in ('$_opA', '$_opB')",
  );
  await deleteWhere(
    'roles',
    "role_id::text in ('$_roleA', '$_roleB')",
  );
  await deleteWhere(
    'locations',
    "operator_id::text in ('$_opA', '$_opB')",
  );
  await deleteWhere(
    'org_units',
    "operator_id::text in ('$_opA', '$_opB')",
  );
  await deleteWhere(
    'users',
    "user_id::text in ('$_userA', '$_userB')",
  );
  await deleteWhere(
    'operators',
    "operator_id::text in ('$_opA', '$_opB')",
  );
}

Future<void> _seedBaseFixtures(PostgresExecutor exec) async {
  // Operators.
  for (final op in <List<String>>[
    <String>[_opA, '$_fixtureMarker tenant A'],
    <String>[_opB, '$_fixtureMarker tenant B'],
  ]) {
    await exec.execute(
      'insert into public.operators '
      '(operator_id, business_name, owner_email) '
      'values (@id::uuid, @name, @email) '
      'on conflict (operator_id) do nothing',
      parameters: <String, Object?>{
        'id': op[0],
        'name': op[1],
        'email': '${op[0]}@$_fixtureMarker.invalid',
      },
    );
  }

  // org_units. Subtree per operator: root → region → district. Path
  // labels are operator-prefixed so they cannot collide across
  // tenants on a shared staging instance.
  for (final ou in <List<String>>[
    <String>[_opA, _ouRootA, 'corp', 'hier_a', 'null', 'null'],
    <String>[
      _opA,
      _ouRegionA,
      'region',
      'hier_a.region',
      _ouRootA,
      _ouRootA,
    ],
    <String>[
      _opA,
      _ouDistrictA,
      'district',
      'hier_a.region.district',
      _ouRegionA,
      _ouRegionA,
    ],
    <String>[_opB, _ouRootB, 'corp', 'hier_b', 'null', 'null'],
    <String>[
      _opB,
      _ouRegionB,
      'region',
      'hier_b.region',
      _ouRootB,
      _ouRootB,
    ],
    <String>[
      _opB,
      _ouDistrictB,
      'district',
      'hier_b.region.district',
      _ouRegionB,
      _ouRegionB,
    ],
  ]) {
    final parent = ou[4] == 'null' ? null : ou[4];
    await exec.execute(
      'insert into public.org_units '
      '(id, operator_id, parent_id, unit_type, path, name) '
      'values (@id::uuid, @op::uuid, @parent::uuid, @type, '
      '@path::ltree, @name) '
      'on conflict (id) do nothing',
      parameters: <String, Object?>{
        'id': ou[1],
        'op': ou[0],
        'parent': parent,
        'type': ou[2],
        'path': ou[3],
        'name': '$_fixtureMarker ${ou[3]}',
      },
    );
  }

  // Locations. _locRegion* attaches at the region level; _locDistrict*
  // attaches at the district level. The BEFORE INSERT trigger
  // `set_location_org_unit_path` denormalizes `org_unit_path` from
  // the parent's `org_units.path` so the test can later assert
  // ltree-subtree containment.
  for (final loc in <List<String>>[
    <String>[_opA, _locRegionA, _ouRegionA, '$_fixtureMarker locA-region'],
    <String>[_opA, _locDistrictA, _ouDistrictA, '$_fixtureMarker locA-district'],
    <String>[_opB, _locRegionB, _ouRegionB, '$_fixtureMarker locB-region'],
    <String>[_opB, _locDistrictB, _ouDistrictB, '$_fixtureMarker locB-district'],
  ]) {
    await exec.execute(
      'insert into public.locations '
      '(location_id, operator_id, parent_org_unit_id, name, '
      'timezone, business_day_rollover_hour) '
      'values (@id::uuid, @op::uuid, @parent::uuid, @name, '
      '@tz, @rollover) '
      'on conflict (location_id) do nothing',
      parameters: <String, Object?>{
        'id': loc[1],
        'op': loc[0],
        'parent': loc[2],
        'name': loc[3],
        'tz': 'America/Toronto',
        'rollover': 4,
      },
    );
  }

  // Users (one per operator). The auth schema extension may add NOT
  // NULL columns beyond the cloud_foundation base; we provide only
  // the foundation-required fields and rely on column defaults for
  // anything the auth migration added.
  for (final user in <List<String>>[
    <String>[_opA, _userA, 'usera@$_fixtureMarker.invalid'],
    <String>[_opB, _userB, 'userb@$_fixtureMarker.invalid'],
  ]) {
    await exec.execute(
      'insert into public.users '
      '(user_id, operator_id, email) '
      'values (@id::uuid, @op::uuid, @email) '
      'on conflict (user_id) do nothing',
      parameters: <String, Object?>{
        'id': user[1],
        'op': user[0],
        'email': user[2],
      },
    );
  }

  // Operator-scoped roles (one per tenant). Using a fixture-specific
  // role_key namespace so the test does not depend on the seeded
  // global roles existing on the live database (some staging snapshots
  // may diverge).
  for (final role in <List<String>>[
    <String>[_opA, _roleA, '$_fixtureMarker-role-a'],
    <String>[_opB, _roleB, '$_fixtureMarker-role-b'],
  ]) {
    await exec.execute(
      'insert into public.roles '
      '(role_id, operator_id, role_key, display_name, description) '
      "values (@id::uuid, @op::uuid, @key, @display, '') "
      'on conflict (role_id) do nothing',
      parameters: <String, Object?>{
        'id': role[1],
        'op': role[0],
        'key': role[2],
        'display': '$_fixtureMarker role',
      },
    );
  }
}

// ─── EXPLAIN walking (mirrors the B36 sweep helpers) ────────────────

List<dynamic> _parseExplainJson(Object? raw) {
  if (raw == null) {
    throw StateError('EXPLAIN returned a null QUERY PLAN');
  }
  if (raw is List) return raw;
  if (raw is String) {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded;
    throw StateError(
      'EXPLAIN JSON did not decode as a list: ${decoded.runtimeType}',
    );
  }
  throw StateError('Unexpected EXPLAIN result shape: ${raw.runtimeType}');
}

bool _planUsesTenantLeadingIndex(List<dynamic> plans) {
  for (final entry in plans) {
    if (entry is Map) {
      final root = entry['Plan'];
      if (root is Map && _walkPlanNode(Map<String, dynamic>.from(root))) {
        return true;
      }
    }
  }
  return false;
}

bool _walkPlanNode(Map<String, dynamic> plan) {
  if (_isTenantLeadingIndexNode(plan)) return true;
  final children = plan['Plans'];
  if (children is List) {
    for (final child in children) {
      if (child is Map && _walkPlanNode(Map<String, dynamic>.from(child))) {
        return true;
      }
    }
  }
  return false;
}

bool _isTenantLeadingIndexNode(Map<String, dynamic> plan) {
  final nodeType = (plan['Node Type'] ?? '').toString();
  if (!nodeType.contains('Index') && !nodeType.contains('Bitmap')) {
    return false;
  }
  final cond = (plan['Index Cond'] ?? '').toString();
  final indexName = (plan['Index Name'] ?? '').toString();
  return cond.contains('operator_id') || indexName.contains('operator');
}
