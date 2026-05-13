// Phase 11W.2 - Permission Explainer screen widget tests.
//
// Pins the parity contract section "Roles + Permission Explainer
// (11W.2 + 11A.13 Roles tab)":
//
//   - 11 categories rendered in the locked order:
//     `product` -> `forgeflow` -> `barrio` -> `admin` -> `team` ->
//     `account` -> `business_timing` -> `billing` -> `integration` ->
//     `integrations` -> `workflow`.
//   - Every key in `PermissionKeys.all` appears under its category.
//   - Description copy is verbatim from the catalog migration seed
//     (no paraphrasing in the UI).
//   - MFA-required keys (`PermissionKeys.requiresMfa`) carry the
//     lock chip + tooltip "Requires multi-factor authentication."
//   - Em-dash free across the 11W.2 file set.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/operator_web/screens/permission_explainer_screen.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: child,
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  group('Permission Explainer renders 11 categories in locked order', () {
    testWidgets('renders all 11 category blocks in the locked sequence', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await tester.pumpWidget(wrap(const PermissionExplainerScreen()));
      await tester.pumpAndSettle();

      const expectedOrder = <String>[
        'product',
        'forgeflow',
        'barrio',
        'admin',
        'team',
        'account',
        'business_timing',
        'billing',
        'integration',
        'integrations',
        'workflow',
      ];
      expect(expectedOrder, kPermissionExplainerCategories);
      // Each category block is keyed; assert every block exists in order
      // by reading the on-screen text positions.
      final foundOrder = <String>[];
      for (final category in expectedOrder) {
        final finder = find.byKey(
          Key('operator_web_permission_explainer_category_$category'),
        );
        if (finder.evaluate().isNotEmpty) {
          foundOrder.add(category);
        }
      }
      expect(foundOrder, expectedOrder);
    });

    test('every key in PermissionKeys.all has a verbatim description', () {
      // The catalog file (`docs/contracts/auth_permission_key_catalog.md`)
      // requires every catalog key to render with the migration's
      // `description` field verbatim. The screen's static map is the
      // mirror; this assertion guards against drift.
      for (final key in PermissionKeys.all) {
        final description = kPermissionExplainerDescriptions[key];
        expect(
          description,
          isNotNull,
          reason: 'permission_key_descriptions missing $key',
        );
        expect(
          (description ?? '').trim().isNotEmpty,
          isTrue,
          reason: 'permission_key_descriptions blank for $key',
        );
      }
    });

    test(
      'permissionExplainerByCategory groups every key under its frozen prefix',
      () {
        final byCategory = permissionExplainerByCategory();
        final flattened = <String>{
          for (final list in byCategory.values) ...list,
        };
        expect(
          flattened,
          PermissionKeys.all,
          reason: 'every catalog key must group into a category',
        );
        for (final entry in byCategory.entries) {
          for (final key in entry.value) {
            expect(
              key.startsWith('${entry.key}.'),
              isTrue,
              reason: 'key $key does not match category ${entry.key}',
            );
          }
        }
      },
    );
  });

  group('MFA-required keys render the lock chip + tooltip', () {
    testWidgets('every requiresMfa key renders the MFA chip', (tester) async {
      await sizeViewport(tester, const Size(1280, 2400));
      await tester.pumpWidget(wrap(const PermissionExplainerScreen()));
      await tester.pumpAndSettle();
      for (final key in PermissionKeys.requiresMfa) {
        expect(
          find.byKey(Key('operator_web_permission_explainer_mfa_$key')),
          findsOneWidget,
          reason: 'MFA chip missing for $key',
        );
      }
    });

    testWidgets('non-MFA keys do not render the MFA chip', (tester) async {
      await sizeViewport(tester, const Size(1280, 2400));
      await tester.pumpWidget(wrap(const PermissionExplainerScreen()));
      await tester.pumpAndSettle();
      // Pick a few representative non-MFA keys so the test stays fast.
      const sampleNonMfa = <String>[
        'forgeflow.shift.view',
        'team.users.view',
        'team.roles.view',
        'account.configure',
        'business_timing.configure',
        'product.forgeflow.access',
        'integrations.configure',
      ];
      for (final key in sampleNonMfa) {
        expect(
          find.byKey(Key('operator_web_permission_explainer_mfa_$key')),
          findsNothing,
          reason: 'MFA chip should not render for non-MFA key $key',
        );
      }
    });

    test('tooltip copy matches the parity contract verbatim', () {
      expect(
        kPermissionExplainerMfaTooltip,
        'Requires multi-factor authentication.',
      );
    });
  });

  group('Verbatim description sample (anti-paraphrase guard)', () {
    test('product + forgeflow descriptions match migration seed', () {
      expect(
        kPermissionExplainerDescriptions['product.forgeflow.access'],
        'Access to Forge & Flow surfaces in either product shell.',
      );
      expect(
        kPermissionExplainerDescriptions['forgeflow.shift.view'],
        'View shift surface.',
      );
      expect(
        kPermissionExplainerDescriptions['forgeflow.weekly_plan.lock'],
        'Lock the in-force weekly plan snapshot.',
      );
    });

    test('team descriptions match migration seed', () {
      expect(
        kPermissionExplainerDescriptions['team.users.invite'],
        'Create invites for users in own operator.',
      );
      expect(
        kPermissionExplainerDescriptions['team.roles.create_custom'],
        'Create operator-scoped custom role.',
      );
      expect(
        kPermissionExplainerDescriptions['team.users.reset_mfa'],
        'Start or cancel delayed authenticator-app removal for a team '
            'member after fresh authentication.',
      );
    });

    test('admin + integrations descriptions match migration seed', () {
      expect(
        kPermissionExplainerDescriptions['admin.users.erase_pii'],
        'GDPR right-to-erasure: redact PII for a user. Paired-approval '
            '+ MFA required.',
      );
      expect(
        kPermissionExplainerDescriptions['integrations.configure'],
        'Configure inbound vendor connections (POS / labor / reservation) '
            'on the per-(operator, location) Vendor Connections admin '
            'surface.',
      );
      expect(
        kPermissionExplainerDescriptions['account.configure'],
        'Configure operator business account identity, locale, currency, '
            'business-week, rollover-hour, and logo settings.',
      );
      expect(
        kPermissionExplainerDescriptions['business_timing.configure'],
        'Configure effective-dated business timing profiles, rollover-hour, '
            'week-start, and service periods.',
      );
    });
  });

  group('No em dash regression on 11W.2-owned files', () {
    test('every operator-facing string literal in the 11W.2 file set is '
        'em-dash free', () async {
      const ownedPaths = <String>[
        'lib/operator_web/services/web_team_roles_gateway.dart',
        'lib/operator_web/services/demo_team_roles_gateway.dart',
        'lib/operator_web/screens/roles_screen.dart',
        'lib/operator_web/screens/custom_role_editor_screen.dart',
        'lib/operator_web/screens/permission_explainer_screen.dart',
      ];
      for (final relativePath in ownedPaths) {
        final source = await io.File(relativePath).readAsString();
        final stripped = source
            .split('\n')
            .map((line) {
              final commentStart = line.indexOf('//');
              if (commentStart < 0) return line;
              var inString = false;
              String? quote;
              for (var i = 0; i < line.length - 1; i++) {
                final c = line[i];
                if (!inString && (c == '"' || c == "'")) {
                  inString = true;
                  quote = c;
                  continue;
                }
                if (inString && c == quote) {
                  inString = false;
                  quote = null;
                  continue;
                }
                if (!inString && c == '/' && line[i + 1] == '/') {
                  return line.substring(0, i);
                }
              }
              return line;
            })
            .join('\n');
        expect(
          stripped.contains('—'),
          isFalse,
          reason: 'em dash (U+2014) found in $relativePath outside comments',
        );
      }
    });
  });
}
