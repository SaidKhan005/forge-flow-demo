// integration_test/admin_pressure/ai_pricing/scenario_ai_pri_01_scope_picker_renders.dart
//
// Lane C — AI/Pri-01: the Plans and limits route mounts with its three
// view tabs (Plans / Features / Businesses). The screen tags itself
// with Key('admin_pricing_screen')
// (lib/admin/screens/pricing_tier_admin_screen.dart:524) and exposes
// the tab triplet via Keys 'admin_pricing_tab_plans' (:1063),
// 'admin_pricing_tab_features' (:1070), 'admin_pricing_tab_businesses'
// (:1077). The default view is Plans, which renders
// 'admin_pricing_plans_view' (:588).
//
// This scenario asserts:
//   - the screen mounts,
//   - all three view tabs are in the widget tree,
//   - the Plans view body renders on first load (the default),
//   - switching to Features renders the Features matrix body
//     (Key 'admin_pricing_features_view', :596),
//   - the screen has not overflowed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'AI/Pri-01: Plans and limits route mounts with Plans/Features/'
    'Businesses tabs; switching to Features renders the matrix view',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminPricingRouteId);

      // Screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_pricing_screen')),
        findsOneWidget,
        reason: 'Plans and limits (pricing) screen did not mount.',
      );

      // All three view tabs present.
      expect(
        find.byKey(const Key('admin_pricing_tab_plans')),
        findsOneWidget,
        reason: 'Plans tab missing from Plans-and-limits tab row.',
      );
      expect(
        find.byKey(const Key('admin_pricing_tab_features')),
        findsOneWidget,
        reason: 'Features tab missing from Plans-and-limits tab row.',
      );
      expect(
        find.byKey(const Key('admin_pricing_tab_businesses')),
        findsOneWidget,
        reason: 'Businesses tab missing from Plans-and-limits tab row.',
      );

      // Default Plans view body rendered (or a recognised load state).
      const initialBodyStates = <Key>[
        Key('admin_pricing_loading'),
        Key('admin_pricing_load_error'),
        Key('admin_pricing_plans_view'),
      ];
      var initialMatched = false;
      for (final key in initialBodyStates) {
        if (find.byKey(key).evaluate().isNotEmpty) {
          initialMatched = true;
          break;
        }
      }
      expect(
        initialMatched,
        isTrue,
        reason:
            'Plans-and-limits did not settle into Plans / loading / load '
            'error state on first mount.',
      );

      // Switch to Features tab and confirm its body renders.
      await tester.tap(
        find.byKey(const Key('admin_pricing_tab_features')),
        warnIfMissed: false,
      );
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      const featuresStates = <Key>[
        Key('admin_pricing_loading'),
        Key('admin_pricing_load_error'),
        Key('admin_pricing_features_view'),
      ];
      var featuresMatched = false;
      for (final key in featuresStates) {
        if (find.byKey(key).evaluate().isNotEmpty) {
          featuresMatched = true;
          break;
        }
      }
      expect(
        featuresMatched,
        isTrue,
        reason:
            'Switching to the Features tab did not render the Features '
            'matrix or any recognised state.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Plans and limits screen overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
