import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';

void main() {
  group('B5.b catalog tri-mirror', () {
    test('constants are present exactly once and are not MFA-required', () {
      expect(PermissionKeys.accountConfigure, 'account.configure');
      expect(
        PermissionKeys.businessTimingConfigure,
        'business_timing.configure',
      );

      expect(
        PermissionKeys.all.where(
          (key) => key == PermissionKeys.accountConfigure,
        ),
        hasLength(1),
      );
      expect(
        PermissionKeys.all.where(
          (key) => key == PermissionKeys.businessTimingConfigure,
        ),
        hasLength(1),
      );
      expect(
        PermissionKeys.requiresMfa,
        isNot(contains(PermissionKeys.accountConfigure)),
      );
      expect(
        PermissionKeys.requiresMfa,
        isNot(contains(PermissionKeys.businessTimingConfigure)),
      );
    });

    test('contract documents grant intent and MFA posture', () {
      final catalog = File(
        'docs/contracts/auth_permission_key_catalog.md',
      ).readAsStringSync();
      final normalizedCatalog = catalog.replaceAll(RegExp(r'\s+'), ' ');

      expect(catalog, contains('### `account.*` (1)'));
      expect(catalog, contains('### `business_timing.*` (1)'));
      expect(catalog, contains('| `account.configure` |'));
      expect(catalog, contains('| `business_timing.configure` |'));
      expect(catalog, contains('No MFA is required at the catalog level'));
      expect(
        normalizedCatalog,
        contains('`operator_owner` configures the account'),
      );
      expect(
        normalizedCatalog,
        contains('no such seeded role exists; it is part of `operator_owner`'),
      );
      expect(
        normalizedCatalog,
        isNot(contains('`operator_owner` and `operator_admin`')),
      );
      expect(catalog, contains('No B2/B10 admin keys were added.'));
    });

    test('migration seeds keys and historical grants idempotently', () {
      final migration = File(
        'db/migrations/202605131500_b5_b_catalog_tri_mirror.sql',
      ).readAsStringSync();
      final normalized = migration.replaceAll(RegExp(r'\s+'), ' ');

      for (final key in const <String>[
        'account.configure',
        'business_timing.configure',
      ]) {
        expect(migration, contains("'$key'"));
        expect(
          normalized,
          contains("on conflict (key) do nothing"),
          reason: '$key must be idempotent in permission_keys',
        );
      }

      for (final tuple in const <String>[
        "('super_admin', 'account.configure')",
        "('operator_owner', 'account.configure')",
        "('operator_admin', 'account.configure')",
        "('super_admin', 'business_timing.configure')",
        "('operator_owner', 'business_timing.configure')",
        "('operator_admin', 'business_timing.configure')",
      ]) {
        expect(normalized, contains(tuple));
      }

      for (final role in const <String>[
        'ff_support',
        'operator_manager',
        'operator_supervisor',
        'operator_staff',
      ]) {
        expect(normalized, isNot(contains("('$role', 'account.configure')")));
        expect(
          normalized,
          isNot(contains("('$role', 'business_timing.configure')")),
        );
      }

      expect(
        normalized,
        contains('on conflict (role_id, permission_key) do nothing'),
      );
      expect(normalized.toLowerCase(), isNot(contains('audit_logs')));
      expect(normalized, isNot(contains('admin.roles.catalog_publish')));
      expect(normalized, isNot(contains('admin.vendor_applicability.edit')));
    });

    test('v2 catalog folds phantom admin settings grants into owner', () {
      final migration = File(
        'db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql',
      ).readAsStringSync();
      final normalized = migration.replaceAll(RegExp(r'\s+'), ' ');

      expect(
        normalized,
        contains(
          "where r.role_key = 'operator_owner' and r.operator_id is null",
        ),
      );
      expect(normalized, contains("'account.configure'"));
      expect(normalized, contains("'business_timing.configure'"));
      expect(normalized, isNot(contains("role_key = 'operator_admin'")));
    });

    test(
      'the three operator-web screens use constants instead of literals',
      () {
        const screens = <String, List<String>>{
          'lib/operator_web/screens/account_screen.dart': <String>[
            'PermissionKeys.accountConfigure',
            'account.configure',
          ],
          'lib/operator_web/screens/business_setup_screen.dart': <String>[
            'PermissionKeys.businessTimingConfigure',
            'business_timing.configure',
          ],
          'lib/operator_web/screens/business_timing_editor_screen.dart':
              <String>[
                'PermissionKeys.businessTimingConfigure',
                'business_timing.configure',
              ],
        };

        for (final entry in screens.entries) {
          final source = File(entry.key).readAsStringSync();
          final constantRef = entry.value[0];
          final rawKey = RegExp.escape(entry.value[1]);
          final rawLiteral = RegExp("['\"]$rawKey['\"]");

          expect(source, contains("import '../../auth/permission_keys.dart';"));
          expect(source, contains(constantRef));
          expect(
            rawLiteral.hasMatch(source),
            isFalse,
            reason: '${entry.key} must not hand-type ${entry.value[1]}',
          );
        }
      },
    );
  });
}
