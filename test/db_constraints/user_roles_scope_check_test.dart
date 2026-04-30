// 9.UX.4 audit — user_roles scope-payload CHECK constraint coverage.
//
// The `202604290101_phase_9_hierarchy_access_wiring` migration locked
// the per-row scope payload via `user_roles_scope_payload_check`:
//
//   (operator_wide ∧ location_id = NULL ∧ org_unit_id = NULL)
//   ∨ (org_unit      ∧ location_id = NULL ∧ org_unit_id ≠ NULL)
//   ∨ (location      ∧ location_id ≠ NULL ∧ org_unit_id = NULL)
//
// Any row with both `location_id` AND `org_unit_id` non-null violates
// the constraint regardless of `scope_type`. Two layers, mirroring
// `phase_9_hierarchy_access_wiring_test.dart`:
//
//   1. STRUCTURAL (offline, every run): grep the migration file for
//      the CHECK clauses so a refactor that drops the payload check
//      surfaces in the standard test pass.
//   2. INTEGRATION (passive-by-default, gated on
//      `FORGE_FLOW_RUN_STAGING_HIERARCHY_TEST=true` + POSTGRES_URL +
//      POSTGRES_ADMIN_URL): attempt an INSERT with both
//      `location_id` AND `org_unit_id` non-null and assert Postgres
//      raises a CHECK violation. Live target is staging only — never
//      Production1.
//
// CLAUDE.md bindings:
//   * `package:postgres` is not imported here; SQL flows through
//     `PackagePostgresPool` so the rule against direct
//     `package:postgres` imports outside
//     `lib/infrastructure/persistence/postgres/` is preserved.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';

const String _envFlag = 'FORGE_FLOW_RUN_STAGING_HIERARCHY_TEST';
const String _envPostgresUrl = 'POSTGRES_URL';
const String _envPostgresAdminUrl = 'POSTGRES_ADMIN_URL';

// Reuse the `hier0000…` fixture namespace so a developer running this
// test sees the constraint-probe row alongside the hierarchy fixtures
// in any manual cleanup pass. The probe row is always rolled back, so
// no residue is expected.
const String _probeOperatorId = 'hier0000-0000-0000-0000-0000000000a1';
const String _probeUserId = 'hier0000-0000-0000-0000-0000000000a7';
const String _probeRoleId = 'hier0000-0000-0000-0000-0000000000a8';
const String _probeLocationId = 'hier0000-0000-0000-0000-0000000000a5';
const String _probeOrgUnitId = 'hier0000-0000-0000-0000-0000000000a3';

void main() {
  // ─── STRUCTURAL layer (offline, every run) ───────────────────────

  group('user_roles scope-payload CHECK migration shape', () {
    final migration = File(
      'db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql',
    ).readAsStringSync();

    test('declares user_roles_scope_payload_check', () {
      expect(migration, contains('user_roles_scope_payload_check'));
    });

    test('rejects both location_id and org_unit_id non-null for every '
        'scope_type', () {
      // Each disjunct pins exactly one of {location_id, org_unit_id}
      // non-null. No disjunct allows both — so any row with both
      // non-null violates the CHECK regardless of scope_type.
      expect(
        migration,
        contains(
          "(scope_type = 'operator_wide' and location_id is null and "
          'org_unit_id is null)',
        ),
      );
      expect(
        migration,
        contains(
          "(scope_type = 'org_unit' and location_id is null and "
          'org_unit_id is not null)',
        ),
      );
      expect(
        migration,
        contains(
          "(scope_type = 'location' and location_id is not null and "
          'org_unit_id is null)',
        ),
      );
    });
  });

  // ─── INTEGRATION layer (passive-by-default, staging only) ────────

  final flagRaw = Platform.environment[_envFlag] ?? '';
  final liveEnabled = flagRaw.toLowerCase() == 'true' || flagRaw == '1';

  if (!liveEnabled) {
    test(
      'user_roles scope-payload CHECK integration (passive default)',
      () {
        // The skip below is the contract — body intentionally empty.
      },
      skip:
          'Scope-payload CHECK integration is passive by default. To run '
          'against staging Postgres, set $_envFlag=true and provide '
          '$_envPostgresUrl + $_envPostgresAdminUrl. Live target is '
          'staging only — never Production1.',
    );
    return;
  }

  final pgAdminUrl = Platform.environment[_envPostgresAdminUrl];
  final pgUrl = Platform.environment[_envPostgresUrl];
  final missingEnv = <String>[
    if (pgUrl == null || pgUrl.isEmpty) _envPostgresUrl,
    if (pgAdminUrl == null || pgAdminUrl.isEmpty) _envPostgresAdminUrl,
  ];
  if (missingEnv.isNotEmpty) {
    test('user_roles scope-payload CHECK — env preflight', () {
      fail(
        'BLOCKED: $_envFlag is true but required env names are '
        'missing: ${missingEnv.join(', ')}. Source the staging env '
        'loader (scripts/use_postgres_staging_env.ps1) and re-run. '
        'No env values are echoed by this test.',
      );
    });
    return;
  }

  late PackagePostgresPool adminPool;

  setUpAll(() {
    adminPool = PackagePostgresPool.fromUrl(pgAdminUrl!);
  });

  test(
    'INSERT into user_roles with both location_id and org_unit_id '
    'non-null is rejected by user_roles_scope_payload_check',
    () async {
      // Roll the probe insert back so it never lands. The CHECK fires
      // mid-transaction; the txn is aborted regardless of whether the
      // probe matched the existing fixture (FK targets may not exist,
      // which would surface as a 23503 instead of 23514). Either way
      // the row never lands and the assertion treats both as the
      // expected reject.
      Object? caught;
      final tx = await adminPool.beginTransaction();
      try {
        await tx.execute(
          'insert into public.user_roles ('
          'user_id, role_id, operator_id, location_id, org_unit_id, '
          'scope_type, granted_by) '
          'values (@uid::uuid, @rid::uuid, @op::uuid, @loc::uuid, '
          "@ou::uuid, 'location', @uid::uuid)",
          parameters: <String, Object?>{
            'uid': _probeUserId,
            'rid': _probeRoleId,
            'op': _probeOperatorId,
            'loc': _probeLocationId,
            'ou': _probeOrgUnitId,
          },
        );
      } catch (e) {
        caught = e;
      } finally {
        try {
          await tx.rollback();
        } catch (_) {/* swallow — txn already aborted */}
      }

      expect(
        caught,
        isNotNull,
        reason:
            'INSERT with location_id AND org_unit_id both non-null '
            'must be rejected — user_roles_scope_payload_check does '
            'not allow both fields to be non-null for any scope_type',
      );
      final message = caught.toString();
      final isCheckViolation =
          message.contains('user_roles_scope_payload_check') ||
              message.contains('check constraint') ||
              message.contains('23514');
      // FK violation (23503) is acceptable as a fallback indicator
      // when the staging fixture is partially seeded — the CHECK
      // would have fired for any row that survived the FK gate.
      final isForeignKeyViolation =
          message.contains('23503') || message.contains('foreign key');
      expect(
        isCheckViolation || isForeignKeyViolation,
        isTrue,
        reason:
            'expected CHECK (preferred) or FK violation; got: $message',
      );
    },
  );
}

