// GAP A6 - F&F Admin Permission Explainer parity regression.
//
// Pins the parity contract section "Roles + Permission Explainer
// (11W.2 + 11A.13 Roles tab)":
//
//   - The admin Roles tab Explainer renders the VERBATIM catalog
//     `description` text (no humanized paraphrase). Before the
//     shared-widget lift the admin card rendered humanized labels
//     (`permissionHumanLabel(...)`), a parity violation.
//   - The admin Explainer includes the `account.*` and
//     `business_timing.*` categories. Before the lift the admin
//     `_categoryOrder` omitted both prefixes so those keys were
//     silently dropped (contract: every catalog key must appear).
//   - Every key in `PermissionKeys.all` has a verbatim
//     description-map entry (drift guard shared by web + admin).
//
// The admin card now hosts the shared `PermissionExplainerView`
// (`lib/widgets/permission_explainer_view.dart`), the same widget the
// Operator Web `/roles/explainer` screen renders, so copy / category
// order / MFA marker are identical across both consoles.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/permission_explainer_view.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  void tallViewport(WidgetTester tester) {
    // Tall so every Explainer category mounts in the offstage scroll
    // extent of the Roles tab.
    tester.view.physicalSize = const Size(1600, 8000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> pumpSharedExplainer(WidgetTester tester) async {
    tallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const SingleChildScrollView(
          child: PermissionExplainerView(
            embedded: true,
            keyPrefix: 'admin_rhs_permission_explainer',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Admin Permission Explainer parity (GAP A6)', () {
    testWidgets(
      'admin card hosts the shared explainer view, not a humanized clone',
      (tester) async {
        await pumpSharedExplainer(tester);
        // The shared widget remains the parity authority for admin and web.
        expect(
          find.byKey(const Key('admin_rhs_permission_explainer_intro')),
          findsOneWidget,
        );
        expect(find.byType(PermissionExplainerView), findsOneWidget);
      },
    );

    testWidgets(
      'renders the VERBATIM catalog description (not humanized "View users")',
      (tester) async {
        await pumpSharedExplainer(tester);
        // Anti-paraphrase guard: the catalog description for
        // admin.users.view is "View users in admin console.", NOT the
        // humanized "View users" the old _PermissionExplainerCard
        // rendered via permissionHumanLabel(...).
        const verbatim = 'View users in admin console.';
        expect(kPermissionExplainerDescriptions['admin.users.view'], verbatim);
        final descFinder = find.byKey(
          const Key('admin_rhs_permission_explainer_desc_admin.users.view'),
        );
        expect(descFinder, findsOneWidget);
        final descText = tester.widget<Text>(descFinder);
        expect(descText.data, verbatim);
      },
    );

    testWidgets(
      'account.* and business_timing.* keys now appear in the admin explainer',
      (tester) async {
        await pumpSharedExplainer(tester);
        // Regression: the old admin _categoryOrder omitted `account`
        // and `business_timing`, silently dropping these keys.
        expect(
          find.byKey(
            const Key('admin_rhs_permission_explainer_category_account'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key(
              'admin_rhs_permission_explainer_category_business_timing',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('admin_rhs_permission_explainer_row_account.configure'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key(
              'admin_rhs_permission_explainer_row_business_timing.configure',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    test(
      'every key in PermissionKeys.all has a verbatim description entry',
      () {
        for (final key in PermissionKeys.all) {
          final description = kPermissionExplainerDescriptions[key];
          expect(
            description,
            isNotNull,
            reason: 'permission_explainer_view missing description for $key',
          );
          expect(
            (description ?? '').trim().isNotEmpty,
            isTrue,
            reason: 'permission_explainer_view blank description for $key',
          );
        }
      },
    );

    test('the locked category order includes account + business_timing', () {
      expect(
        kPermissionExplainerCategories,
        containsAllInOrder(<String>[
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
        ]),
      );
    });
  });
}
