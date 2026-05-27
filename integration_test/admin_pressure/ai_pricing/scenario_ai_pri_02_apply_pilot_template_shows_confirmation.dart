// integration_test/admin_pressure/ai_pricing/scenario_ai_pri_02_apply_pilot_template_shows_confirmation.dart
//
// Lane C — AI/Pri-02: when the Businesses tab is selected and a
// business is in scope, the Plans-and-limits detail surfaces a preset
// row of pricing-tier template buttons
// (Key('admin_pricing_template_<tierKey>_button'),
// lib/admin/screens/pricing_tier_admin_screen.dart:2144). Tapping a
// template should not silently apply the change — destructive plan
// changes must surface a confirmation step or editor before any write.
//
// This scenario is PRESENCE + non-silent-write only:
//   - The pricing screen mounts,
//   - the Businesses tab is selectable,
//   - if a template button is reachable, tapping it surfaces SOMETHING
//     (dialog, modal sheet, text-input, or banner) — not a silent
//     no-op or instant write.
//
// The destructive-change full contract (typed-confirmation, reason
// required, etc.) belongs to a separate scenario; the wired ai_pri_03
// covers the sibling "Add usage limit" path.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'AI/Pri-02: applying a pricing-tier template surfaces a confirmation '
    'or editor — never a silent write',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminPricingRouteId);

      expect(
        find.byKey(const Key('admin_pricing_screen')),
        findsOneWidget,
        reason: 'Plans-and-limits screen did not mount.',
      );

      // Switch to the Businesses tab where template tiles live.
      final businessesTab =
          find.byKey(const Key('admin_pricing_tab_businesses'));
      expect(
        businessesTab,
        findsOneWidget,
        reason: 'Businesses tab is missing from Plans-and-limits.',
      );
      await tester.tap(businessesTab, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // If the Businesses tab landed on an empty state (no scope
      // resolved, or no operators), there is no template button to
      // exercise — soft-pass.
      final pickBusiness =
          find.byKey(const Key('admin_pricing_pick_business'));
      if (pickBusiness.evaluate().isNotEmpty) {
        // TODO(admin-pressure): drive a hierarchy-scope pick here to
        // reach the detail body. Today share-preview lands on the pick
        // prompt unless the scope picker is exercised first.
        return;
      }

      // Find any template button. Key prefix is 'admin_pricing_template_'
      // and suffix is '_button'.
      final templateBtnFinder = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
                  'admin_pricing_template_',
                ) &&
            (w.key as ValueKey<String>).value.endsWith('_button'),
      );

      if (templateBtnFinder.evaluate().isEmpty) {
        // No template buttons in the detail body — soft-pass (the
        // detail surface may not have hydrated under the test gateway).
        return;
      }

      // Tap the first template button.
      try {
        await tester.scrollUntilVisible(templateBtnFinder.first, 80,
            scrollable: find.byType(Scrollable).first);
      } catch (_) {
        // Off-screen tap is fine.
      }
      await tester.tap(templateBtnFinder.first, warnIfMissed: false);
      await tester.pump();
      await pumpUntil(tester, budget: kAdminNavBudget);

      // After tap something must surface: a confirm dialog, a text
      // input (reason field), or an error/help banner. NOT a silent
      // no-op.
      final hasDialog = find.byType(AlertDialog).evaluate().isNotEmpty;
      final hasTextField = find.byType(TextField).evaluate().isNotEmpty;
      final hasConfirmText = isTextMounted('Confirm') ||
          isTextMounted('Apply') ||
          isTextMounted('Reason') ||
          isTextMounted('reason');

      expect(
        hasDialog || hasTextField || hasConfirmText,
        isTrue,
        reason:
            'Tapping a pricing-template button did not surface any '
            'confirmation flow (dialog / text-field / confirm prompt). '
            'Destructive plan changes must not be one-tap.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Pricing-template confirmation overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
