// Wave 2 R-2L — Default Role Catalog v2 migration shape tests.
//
// Pins the shape of
// `db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`
// so the implementation cannot silently drift away from the slice
// contract recorded in
// `docs/_indices/WAVE_2_R2L_DEFAULT_ROLE_CATALOG_V2_PROPOSAL.md`.
//
// Coverage:
//   1. The migration file exists and lex-orders after R-1L.
//   2. `permission_keys.human_label` is added (NULLABLE, expand-only;
//      NOT NULL flip parked alongside R-1L-FU).
//   3. Backfill `CASE` includes every category prefix that the Dart
//      mirror exposes (spot-checks one per category).
//   4. Fail-loud DO block guards the backfill coverage.
//   5. Every v2 role row is inserted with the agreed Title Case
//      display_name and reads-as-training description.
//   6. v1 retired roles are soft-deleted (no hard DELETE).
//   7. user_roles auto-migration mappings are present
//      (operator_manager -> operator_general_manager;
//       operator_supervisor/operator_staff -> supervisor).
//   8. `auth_events_audit` rows emit
//      `auth.role.seeded_catalog_v2_published`.
//   9. The standard local statement / lock timeouts are present.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';

void main() {
  group('Wave 2 R-2L default role catalog v2 migration shape', () {
    late String migration;

    setUpAll(() {
      migration = File(
        'db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('migration file exists with the slice-named timestamp slot', () {
      final names = Directory('db/migrations')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.sql'))
          .toList()
        ..sort();
      expect(
        names,
        contains('202605150000_phase_r2l_default_role_catalog_v2.sql'),
      );
      final idx = names.indexOf(
        '202605150000_phase_r2l_default_role_catalog_v2.sql',
      );
      final r1lIdx = names.indexOf(
        '202605142100_phase_R_1L_roles_schema_rewrite.sql',
      );
      expect(idx, greaterThan(r1lIdx));
    });

    test('adds permission_keys.human_label nullable expand-only', () {
      expect(
        migration,
        contains('add column if not exists human_label text'),
      );
      // Defense-in-depth: no SET NOT NULL on human_label — the flip is
      // parked alongside R-1L-FU per the expand-contract precedent.
      expect(
        migration,
        isNot(contains('alter column human_label set not null')),
      );
    });

    test('backfill CASE covers every category prefix in the catalog', () {
      // Spot-check one key per category. If the case statement omits
      // any of these, the fail-loud DO block below would trip at apply
      // time; this test catches accidental deletions in PR review.
      const samples = <String>[
        "when 'product.forgeflow.access'",
        "when 'forgeflow.shift.edit'",
        "when 'barrio.handbook.view'",
        "when 'admin.users.view'",
        "when 'team.users.invite'",
        "when 'account.configure'",
        "when 'business_timing.configure'",
        "when 'billing.usage_caps.edit'",
        "when 'integration.toast.connect'",
        "when 'integrations.configure'",
        "when 'workflow.run'",
      ];
      for (final sample in samples) {
        expect(
          migration,
          contains(sample),
          reason: 'backfill CASE missing `$sample`',
        );
      }
    });

    test('backfill is fail-loud on coverage gaps', () {
      expect(
        migration,
        contains(
          "raise exception\n      'R-2L backfill left % "
          'permission_keys rows without human_label; ',
        ),
      );
    });

    test('seeds the seven v2 role rows with Title Case display_name', () {
      const expectedRoles = <String, String>{
        'operator_general_manager': 'General Manager',
        'location_manager': 'Location Manager',
        'supervisor': 'Supervisor',
        'finance_analyst': 'Finance Analyst',
        'auditor_compliance': 'Auditor / Compliance',
        'training_lead': 'Training Lead',
        'team_admin': 'Team Admin',
      };
      for (final entry in expectedRoles.entries) {
        expect(
          migration,
          contains("'${entry.key}',"),
          reason: 'v2 role_key ${entry.key} missing from INSERT',
        );
        expect(
          migration,
          contains("'${entry.value}',"),
          reason: 'v2 display_name "${entry.value}" missing from INSERT',
        );
      }
    });

    test(
      'refreshes operator_owner display_name to v2 wording (Owner)',
      () {
        expect(
          migration,
          contains("set display_name = 'Owner',"),
        );
        expect(
          migration,
          contains("where role_key   = 'operator_owner'"),
        );
      },
    );

    test('soft-deletes v1 retired roles (no hard DELETE)', () {
      // The migration MUST set deleted_at = now() on the three v1
      // retired roles — operator_manager / operator_supervisor /
      // operator_staff. A hard DELETE would break role_audit_log /
      // role_permissions FK references.
      expect(migration, contains('set deleted_at   = now(),'));
      expect(migration, contains("'operator_manager',\n"
          "         'operator_supervisor',\n"
          "         'operator_staff'"));
      expect(
        migration,
        isNot(contains('delete from public.roles')),
        reason: 'hard DELETE forbidden — keep the audit trail intact.',
      );
    });

    test(
      'user_roles auto-migration covers manager + supervisor + staff -> v2',
      () {
        // operator_manager (slot 4) -> operator_general_manager (slot 7).
        expect(
          migration,
          contains(
            "set role_id    = '00000000-0000-0000-0000-000000000007'::uuid",
          ),
        );
        expect(
          migration,
          contains(
            "where ur.role_id = '00000000-0000-0000-0000-000000000004'::uuid",
          ),
        );
        // operator_supervisor (5) / operator_staff (6) -> supervisor (9).
        expect(
          migration,
          contains(
            "set role_id    = '00000000-0000-0000-0000-000000000009'::uuid",
          ),
        );
        expect(
          migration,
          contains(
            "where ur.role_id = '00000000-0000-0000-0000-000000000005'::uuid",
          ),
        );
        expect(
          migration,
          contains(
            "where ur.role_id = '00000000-0000-0000-0000-000000000006'::uuid",
          ),
        );
        // Fan-out from NULL location_id to per-location grants.
        expect(
          migration,
          contains('and ur.location_id is null'),
          reason: 'expected NULL-location fan-out path',
        );
        // 2c step revokes the original NULL-location v1 grants.
        expect(
          migration,
          contains('set revoked_at    = now(),'),
        );
      },
    );

    test(
      'emits auth.role.seeded_catalog_v2_published audit rows',
      () {
        expect(
          migration,
          contains("'auth.role.seeded_catalog_v2_published'"),
        );
        // One INSERT per migrated user_role; one per retired seeded role.
        expect(
          migration,
          contains('insert into public.auth_events_audit'),
        );
      },
    );

    test('carries the standard local statement / lock timeouts', () {
      expect(migration, contains("set local statement_timeout = '30s'"));
      expect(migration, contains("set local lock_timeout = '5s'"));
    });

    test('role inserts are idempotent (ON CONFLICT DO NOTHING)', () {
      expect(migration, contains('on conflict do nothing'));
      // At least one role_permissions INSERT must use the idiom.
      final occurrences =
          'on conflict do nothing'.allMatches(migration).length;
      expect(
        occurrences,
        greaterThanOrEqualTo(8),
        reason:
            'expected at least 8 `on conflict do nothing` clauses '
            '(roles INSERT + 7 role_permissions INSERTs).',
      );
    });
  });

  // G7-pre — `PermissionKeys` role-constant block refreshed to the v2
  // catalog. These assertions pin the catalog constants to the SAME
  // migration this test already loads, so a future drift on either
  // side trips here.
  group('G7-pre — PermissionKeys role constants ⟂ v2 migration', () {
    late String migration;

    setUpAll(() {
      migration = File(
        'db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('each new v2 role constant is byte-equal to a migration '
        'role_key literal', () {
      // The seven v2 roles inserted by step 2 of the migration. The
      // value on the right MUST match the constant value AND appear as
      // a `'<key>',` INSERT literal in the migration source.
      const v2Constants = <String, String>{
        'roleOperatorGeneralManager':
            PermissionKeys.roleOperatorGeneralManager,
        'roleLocationManager': PermissionKeys.roleLocationManager,
        'roleSupervisor': PermissionKeys.roleSupervisor,
        'roleFinanceAnalyst': PermissionKeys.roleFinanceAnalyst,
        'roleAuditorCompliance': PermissionKeys.roleAuditorCompliance,
        'roleTrainingLead': PermissionKeys.roleTrainingLead,
        'roleTeamAdmin': PermissionKeys.roleTeamAdmin,
      };
      const expectedValues = <String, String>{
        'roleOperatorGeneralManager': 'operator_general_manager',
        'roleLocationManager': 'location_manager',
        'roleSupervisor': 'supervisor',
        'roleFinanceAnalyst': 'finance_analyst',
        'roleAuditorCompliance': 'auditor_compliance',
        'roleTrainingLead': 'training_lead',
        'roleTeamAdmin': 'team_admin',
      };
      for (final entry in v2Constants.entries) {
        expect(
          entry.value,
          expectedValues[entry.key],
          reason: '${entry.key} value drifted from the v2 catalog key',
        );
        expect(
          migration,
          contains("'${entry.value}',"),
          reason:
              '${entry.key} (= "${entry.value}") not found as a '
              'role_key INSERT literal in the v2 migration',
        );
      }
    });

    test('carry-over role constants keep their v1 keys and appear in '
        'the v2 migration', () {
      expect(PermissionKeys.roleSuperAdmin, 'super_admin');
      expect(PermissionKeys.roleFfSupport, 'ff_support');
      expect(PermissionKeys.roleOperatorOwner, 'operator_owner');
      // The v2 migration explicitly refreshes operator_owner.
      expect(
        migration,
        contains("where role_key   = 'operator_owner'"),
      );
    });

    test('soft-deleted v1 role constants are retained as '
        'migration-history aliases', () {
      // Operator decision 2026-05-16: KEEP (do not hard-remove). They
      // are excluded from `baselineRoleKeys` but the constants still
      // resolve so migration-window tests/fixtures/policy compile.
      // ignore: deprecated_member_use_from_same_package
      const managerKey = PermissionKeys.roleOperatorManager;
      // ignore: deprecated_member_use_from_same_package
      const supervisorKey = PermissionKeys.roleOperatorSupervisor;
      // ignore: deprecated_member_use_from_same_package
      const staffKey = PermissionKeys.roleOperatorStaff;
      expect(managerKey, 'operator_manager');
      expect(supervisorKey, 'operator_supervisor');
      expect(staffKey, 'operator_staff');
      // The migration soft-deletes (never hard-deletes) these v1 keys.
      expect(
        migration,
        contains("'operator_manager',\n"
            "         'operator_supervisor',\n"
            "         'operator_staff'"),
      );
    });

    test('baselineRoleKeys is exactly the 10 active v2 catalog keys', () {
      const expected = <String>{
        'super_admin',
        'ff_support',
        'operator_owner',
        'operator_general_manager',
        'location_manager',
        'supervisor',
        'finance_analyst',
        'auditor_compliance',
        'training_lead',
        'team_admin',
      };
      expect(PermissionKeys.baselineRoleKeys, equals(expected));
      expect(PermissionKeys.baselineRoleKeys, hasLength(10));
      // The three soft-deleted v1 keys are excluded.
      expect(
        PermissionKeys.baselineRoleKeys,
        isNot(contains('operator_manager')),
      );
      expect(
        PermissionKeys.baselineRoleKeys,
        isNot(contains('operator_supervisor')),
      );
      expect(
        PermissionKeys.baselineRoleKeys,
        isNot(contains('operator_staff')),
      );
    });

    test('every baselineRoleKeys entry resolves to a seeded role_key '
        'in the v2 (or carry-over) catalog', () {
      // operator_owner is refreshed (not re-inserted) by the v2
      // migration; super_admin/ff_support are foundation carry-overs
      // not re-stated in this file. The seven v2 roles MUST appear as
      // INSERT literals here.
      const v2Inserted = <String>{
        'operator_general_manager',
        'location_manager',
        'supervisor',
        'finance_analyst',
        'auditor_compliance',
        'training_lead',
        'team_admin',
      };
      for (final key in v2Inserted) {
        expect(
          PermissionKeys.baselineRoleKeys,
          contains(key),
          reason: 'v2 seeded role $key missing from baselineRoleKeys',
        );
        expect(
          migration,
          contains("'$key',"),
          reason: '$key not an INSERT literal in the v2 migration',
        );
      }
    });
  });
}
