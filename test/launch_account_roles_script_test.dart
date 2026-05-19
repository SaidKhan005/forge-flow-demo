import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('launch account role enforcement script', () {
    final script = File('scripts/set_launch_account_roles.ps1');
    final runbook = File('runbooks/launch_account_roles_runbook.md');

    test(
      'pins Said as highest admin and Newfoundland as regular supervisor',
      () {
        final body = script.readAsStringSync();

        expect(body, contains('saidumarkhan005@gmail.com'));
        expect(body, contains('newoundlandlimited@gmail.com'));
        expect(body, contains("r.role_key = 'super_admin'"));
        expect(body, contains("r.role_key = 'supervisor'"));
        expect(
          body,
          isNot(contains("into staff_role_id")),
          reason: 'The launch repair must grant the v2 supervisor role.',
        );
        expect(
          body,
          contains("'operator_staff'"),
          reason: 'Stale v1 staff grants should still be revoked.',
        );
        expect(body, contains("scope_type = 'super_admin'"));
        expect(body, contains('operator_admins'));
        expect(body, contains("set_config('forge_flow.launch_admin_email'"));
        expect(
          body,
          contains("current_setting('forge_flow.launch_admin_email')"),
        );
        expect(body, contains('New-SystemRootCertBundle'));
        expect(body, contains('sslrootcert'));
      },
    );

    test('keeps secrets out of the repo script', () {
      final body = script.readAsStringSync();

      expect(body, contains(r'$env:POSTGRES_ADMIN_URL'));
      expect(body, isNot(contains('postgres://')));
      expect(body, isNot(contains('postgresql://')));
      expect(body, isNot(contains('password=')));
    });

    test(
      'can refresh Firebase claims without granting admin to regular user',
      () {
        final body = script.readAsStringSync();

        expect(body, contains('RefreshFirebaseClaims'));
        expect(
          body,
          contains(
            'Apply db/migrations/202605020300_phase_9_firebase_uid_text.sql',
          ),
        );
        expect(body, contains('accounts:lookup'));
        expect(body, contains('auth application-default print-access-token'));
        expect(body, contains(r'$customClaims.is_super_admin = $true'));
        expect(body, contains(r'$customClaims.is_ff_support = $true'));
        expect(body, contains('launch Firebase UID links reconciled'));
        expect(body, contains(r'$Account.is_super_admin'));
        expect(
          body,
          contains('regular account projection still contains an admin claim'),
        );
      },
    );

    test('runbook documents dry-run, apply, and fresh sign-in', () {
      final body = runbook.readAsStringSync();

      expect(body, contains('scripts/set_launch_account_roles.ps1 -DryRun'));
      expect(
        body,
        contains('scripts/set_launch_account_roles.ps1 -RefreshFirebaseClaims'),
      );
      expect(body, contains('sign both accounts out and back in'));
    });
  });
}
