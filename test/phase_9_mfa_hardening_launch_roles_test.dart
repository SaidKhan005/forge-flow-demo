import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';

void main() {
  final migrationFile = File(
    'db/migrations/202604300002_phase_9_mfa_hardening_launch_roles.sql',
  );

  setUpAll(() {
    expect(
      migrationFile.existsSync(),
      isTrue,
      reason: 'MFA hardening migration must exist in the next Phase 9 slot.',
    );
  });

  String migration() => migrationFile.readAsStringSync();

  group('team.users.reset_mfa permission', () {
    test('is exposed by PermissionKeys and seeded by the migration', () {
      expect(PermissionKeys.teamUsersResetMfa, equals('team.users.reset_mfa'));
      expect(PermissionKeys.all, contains('team.users.reset_mfa'));

      final sql = migration();
      expect(sql, contains("'team.users.reset_mfa'"));
      expect(
        sql,
        contains("'Start or cancel delayed authenticator-app removal"),
      );
      expect(sql, contains("'team'"));
      expect(sql, contains('false'));
      expect(sql, contains('true'));
    });

    test('is granted only to super_admin and operator_owner by default', () {
      final sql = migration();
      expect(sql, contains("r.role_key in ('super_admin', 'operator_owner')"));
      expect(
        sql,
        isNot(contains("'operator_manager', 'team.users.reset_mfa'")),
      );
      expect(sql, isNot(contains("'operator_staff', 'team.users.reset_mfa'")));
    });
  });

  group('launch account role enforcement', () {
    test('pins Said as admin and Newfoundland as regular staff', () {
      final sql = migration();
      expect(sql, contains('saidumarkhan005@gmail.com'));
      expect(sql, contains('newoundlandlimited@gmail.com'));
      expect(sql, contains("r.role_key = 'super_admin'"));
      expect(sql, contains("r.role_key = 'operator_staff'"));
      expect(
        sql,
        contains(
          'launch account role enforcement: regular account is not admin',
        ),
      );
      expect(
        sql,
        contains('launch account role enforcement: highest admin account'),
      );
    });

    test(
      'removes elevated grants and operator-admin rows from Newfoundland',
      () {
        final sql = migration();
        expect(sql, contains("'operator_owner'"));
        expect(sql, contains("'operator_manager'"));
        expect(sql, contains("'operator_supervisor'"));
        expect(sql, contains('delete from public.operator_admins'));
        expect(sql, contains('where user_id = regular_user_id'));
      },
    );

    test('runs in a transaction and skips absent smoke accounts safely', () {
      final sql = migration();
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
      expect(sql, contains('role enforcement skipped'));
      expect(sql.toLowerCase(), isNot(contains('timestamp without time zone')));
    });
  });
}
