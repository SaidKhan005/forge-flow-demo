// Phase 4 Scenario 4 — SUBSTITUTED.
//
// Original prompt's Scenario 4: hierarchy-scoped settings (HP #11)
// "Selected scope" + "Inherited source" + "Effective value" trio.
//
// SCENARIO GAP: a `git grep` for the trio strings in lib/screens/
// (mobile shell) returns zero matches. The hierarchy-scoped UX trio
// is exclusively rendered in `lib/operator_web/screens/` and
// `lib/admin/screens/` (Operator Web console + admin web — both
// out of scope for the Phase 4 mobile-emulator click-path). HP #11
// states that EVERY hierarchy-aware settings/roles/timing/pricing/
// security/support surface must show the trio "or document why the
// capability is backend-only/gated/incomplete." The mobile collapse
// (W3.A) explicitly documents that mobile is the view-only mirror —
// the hierarchy-aware editors live in Operator Web. So the mobile
// shell carries no hierarchy-scoped trio to assert.
//
// Substitution: assert the Variance tab (bottom-nav index 1) renders
// against the demo seed. VarianceReport is the most "fact-heavy"
// dashboard surface that consumes the same locked weekly-plan +
// shift_records seam Phase 1 fixtures shape. Failures here surface
// when realistic vendor data violates the variance read-model
// contract — directly aligned with the Phase 4 "render under realistic
// vendor data" intent.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/variance_report.dart';

import '_harness.dart';

void main() {
  bootstrapPhase4Binding();

  testWidgets('scenario 04 — variance tab renders demo facts', (
    WidgetTester tester,
  ) async {
    final tap = FlutterErrorTap.install();
    addTearDown(tap.restore);

    await launchDemoApp(tester);
    await expectAppShellMounted(tester);

    await tapBottomNavTab(tester, 1);
    expect(
      find.byType(VarianceReport),
      findsOneWidget,
      reason:
          'Variance tab (VarianceReport) did not mount when the bottom-nav '
          'index 1 was selected. Verify the tab widget catalog in '
          '`forge_flow_app.dart` `_buildTab`.',
    );

    expect(
      tap.overflowErrors,
      isEmpty,
      reason:
          'RenderFlex overflow detected on the Variance tab:\n'
          '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
    );
  });
}
