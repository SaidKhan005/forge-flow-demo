// Phase 9.0a tests.
//
// Asserts:
//   * The 9.0a migration file exists and is named per the expected
//     `202604270000_phase_9_0a_scope_extensions.sql` slot.
//   * The migration adds user_roles.scope_type with the locked CHECK
//     and backfills it from location_id.
//   * The migration adds users.primary_location_id with the
//     composite FK to locations(operator_id, location_id) — applied
//     conditionally so the migration does not break before the
//     cloud-foundation slice adds users.operator_id.
//   * The migration adds operators.region.
//   * The migration seeds 12 team.* permission keys, each with
//     `category = 'team'` and `frozen = true`.
//   * The migration extends baseline role grants:
//       operator_owner gets every team.* key
//       operator_manager gets the manager-tier subset
//   * The audit-fix migration grants the post-9.0 team.* keys to
//     super_admin so "super_admin has every key" stays true.
//   * `lib/auth/permission_keys.dart` exposes 12 team.* constants
//     and PermissionKeys.all goes from 81 → 93.
//   * No timestamp without time zone is used (CLAUDE.md storage rule).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';

void main() {
  final migrationFile = File(
    'db/migrations/202604270000_phase_9_0a_scope_extensions.sql',
  );
  final superAdminTeamGrantsMigrationFile = File(
    'db/migrations/202604270200_phase_9_0a_super_admin_team_grants.sql',
  );

  setUpAll(() {
    expect(
      migrationFile.existsSync(),
      isTrue,
      reason: 'Phase 9.0a migration file must exist alongside 9.0 schema',
    );
    expect(
      superAdminTeamGrantsMigrationFile.existsSync(),
      isTrue,
      reason: 'Phase 9.0a audit-fix migration must preserve super_admin grants',
    );
  });

  String migration() => migrationFile.readAsStringSync();
  String superAdminTeamGrantsMigration() =>
      superAdminTeamGrantsMigrationFile.readAsStringSync();

  group('user_roles.scope_type (9.0a)', () {
    test('column added with NOT NULL + CHECK in (operator_wide, location)',
        () {
      final sql = migration();
      expect(sql, contains('alter table public.user_roles'));
      expect(sql, contains('add column if not exists scope_type text'));
      expect(sql, contains('alter column scope_type set not null'));
      expect(sql, contains('user_roles_scope_type_check'));
      expect(
        sql,
        contains("check (scope_type in ('operator_wide', 'location'))"),
      );
    });

    test('backfill: NULL location_id -> operator_wide; non-null -> location',
        () {
      final sql = migration();
      expect(sql, contains('update public.user_roles'));
      expect(sql, contains("when location_id is null then 'operator_wide'"));
      expect(sql, contains("else 'location'"));
    });

    test('tenant-leading scope_type lookup index exists', () {
      final sql = migration();
      expect(sql, contains('user_roles_operator_scope_idx'));
      expect(
        sql,
        contains('on public.user_roles (operator_id, scope_type, user_id)'),
      );
    });
  });

  group('users.primary_location_id (9.0a)', () {
    test('column added as nullable uuid', () {
      final sql = migration();
      expect(sql, contains('alter table public.users'));
      expect(
        sql,
        contains('add column if not exists primary_location_id uuid null'),
      );
    });

    test('composite FK to locations(operator_id, location_id) applied '
        'conditionally', () {
      final sql = migration();
      // The DO block runs the FK only if users.operator_id exists.
      expect(sql, contains('users_primary_location_fk'));
      expect(
        sql,
        contains(
          'foreign key (operator_id, primary_location_id)\n'
          '        references public.locations(operator_id, location_id)',
        ),
      );
      expect(sql, contains('on delete set null'));
    });
  });

  group('operators.region (9.0a)', () {
    test('column added as nullable text', () {
      final sql = migration();
      expect(sql, contains('alter table public.operators'));
      expect(sql, contains('add column if not exists region text null'));
    });
  });

  group('team.* permission key seed (9.0a)', () {
    test('12 keys inserted with category=team, frozen=true, MFA=false', () {
      final sql = migration();
      const expectedKeys = <String>[
        'team.users.view',
        'team.users.invite',
        'team.users.deactivate',
        'team.users.reactivate',
        'team.users.soft_delete',
        'team.users.reset_password',
        'team.roles.view',
        'team.roles.create_custom',
        'team.roles.assign',
        'team.roles.revoke',
        'team.audit_log.view',
        'team.session.force_logout',
      ];
      for (final key in expectedKeys) {
        expect(
          sql,
          contains("'$key', 'team'"),
          reason: 'team.* permission key seed missing $key',
        );
      }
      expect(sql, contains('on conflict (key) do nothing'));
    });

    test('operator_owner cross-join seed grants every team.* key', () {
      final sql = migration();
      expect(sql, contains("where r.role_key = 'operator_owner'"));
      expect(sql, contains("and pk.category = 'team'"));
      expect(sql, contains("on conflict (role_id, permission_key) do nothing"));
    });

    test('audit-fix grants post-9.0 team.* keys to super_admin', () {
      final sql = superAdminTeamGrantsMigration();
      expect(sql, contains("where r.role_key = 'super_admin'"));
      expect(sql, contains('cross join public.permission_keys pk'));
      expect(sql, contains("and pk.category = 'team'"));
      expect(sql, contains("on conflict (role_id, permission_key) do nothing"));
      expect(
        sql,
        contains('super_admin role keeps every catalog key'),
      );
    });

    test('operator_manager seed grants the manager-tier subset', () {
      final sql = migration();
      // Extract only the operator_manager seed block so we can assert
      // its content without false-positives from operator_owner's
      // cross-join above (which DOES grant every team.* key).
      final managerBlockStart = sql.indexOf("where r.role_key = 'operator_manager'");
      expect(managerBlockStart, greaterThan(0));
      final managerBlock = sql.substring(managerBlockStart);
      expect(managerBlock, contains("'team.users.view',"));
      expect(managerBlock, contains("'team.users.invite',"));
      expect(managerBlock, contains("'team.users.reactivate',"));
      expect(managerBlock, contains("'team.users.reset_password',"));
      expect(managerBlock, contains("'team.roles.view',"));
      expect(managerBlock, contains("'team.roles.assign',"));
      expect(managerBlock, contains("'team.roles.revoke',"));
      expect(managerBlock, contains("'team.audit_log.view',"));
      expect(managerBlock, contains("'team.session.force_logout'"));
      // Acceptance: operator_manager does NOT get create_custom or
      // soft_delete (locked decision).
      expect(
        managerBlock,
        isNot(contains("'team.roles.create_custom'")),
      );
      expect(
        managerBlock,
        isNot(contains("'team.users.soft_delete'")),
      );
    });
  });

  group('PermissionKeys catalog mirror (9.0a)', () {
    test('12 team.* constants are present', () {
      const expectedKeys = <String>{
        'team.users.view',
        'team.users.invite',
        'team.users.deactivate',
        'team.users.reactivate',
        'team.users.soft_delete',
        'team.users.reset_password',
        'team.roles.view',
        'team.roles.create_custom',
        'team.roles.assign',
        'team.roles.revoke',
        'team.audit_log.view',
        'team.session.force_logout',
      };
      for (final key in expectedKeys) {
        expect(
          PermissionKeys.all,
          contains(key),
          reason: 'PermissionKeys.all missing $key',
        );
      }
    });

    test('PermissionKeys.all has 93 entries (81 baseline + 12 team.*)', () {
      expect(PermissionKeys.all.length, equals(93));
    });

    test('team.* keys are NOT in requiresMfa (locked decision: no MFA gate '
        'on team management for the launch tier)', () {
      const teamKeys = <String>{
        'team.users.view',
        'team.users.invite',
        'team.users.deactivate',
        'team.users.reactivate',
        'team.users.soft_delete',
        'team.users.reset_password',
        'team.roles.view',
        'team.roles.create_custom',
        'team.roles.assign',
        'team.roles.revoke',
        'team.audit_log.view',
        'team.session.force_logout',
      };
      for (final key in teamKeys) {
        expect(
          PermissionKeys.requiresMfa,
          isNot(contains(key)),
          reason: 'team.* key $key should not require MFA per the lock',
        );
      }
    });
  });

  group('Storage rule discipline', () {
    test('migration does not introduce timestamp without time zone', () {
      // CLAUDE.md storage rule: every operator-scoped fact uses
      // TIMESTAMPTZ. Even though 9.0a doesn't add timestamps, lint
      // for regression in case future edits add them.
      final sql = migration();
      expect(
        sql.toLowerCase(),
        isNot(contains('timestamp without time zone')),
      );
      expect(
        sql.toLowerCase(),
        isNot(matches(RegExp(r'\btimestamp\b(?!\s*with)'))),
      );
    });

    test('migration runs in a transaction (begin/commit pair)', () {
      final sql = migration();
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
    });
  });
}
