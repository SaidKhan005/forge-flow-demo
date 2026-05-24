// D1 — AdminSetupWorkspace "All businesses" platform-scope option.
//
// The AI Metrics (Observability) surface is the one admin setup function
// that super_admin / ff_support can view platform-wide (operator_id =
// null). The shared `AdminSetupWorkspace` exposes that as an ADDITIVE,
// opt-in "All businesses" row in the left scope pane: it is default-off,
// so the ~7 other setup surfaces that share this widget keep byte-for-byte
// identical behavior. These tests pin:
//   - opt-in renders the row and selecting it opens the all-businesses
//     builder (the platform-wide view, no hierarchy scope),
//   - the option is absent by default (other surfaces unaffected),
//   - picking a concrete business clears the all-businesses selection.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/widgets/admin_setup_workspace.dart';

import '_test_helpers/widget_pump_helpers.dart';
import 'admin_operator_location_test_helpers.dart';

void main() {
  void useWideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // AdminSetupWorkspace is designed to be embedded in a screen that owns
  // the Material/Scaffold surface, so the test wraps it in a Scaffold to
  // give the TextField a Material ancestor and bound the column height.
  Widget buildWorkspace({
    required OperatorLocationAdminGateway gateway,
    required bool allowAllBusinessesScope,
    bool withAllBusinessesBuilder = true,
  }) {
    return Scaffold(
      body: AdminSetupWorkspace(
        functionTitle: 'AI Metrics',
        operatorGateway: gateway,
        functionBuilder: (context, scope, selection) =>
            const Text('scoped', key: Key('scoped_view')),
        allowAllBusinessesScope: allowAllBusinessesScope,
        allBusinessesBuilder: withAllBusinessesBuilder
            ? (context) => const Text('all biz', key: Key('all_biz_view'))
            : null,
      ),
    );
  }

  testWidgets(
    'opt-in renders the All businesses row and selecting it opens the '
    'platform-wide builder',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      await tester.pumpWidget(
        wrap(
          buildWorkspace(
            gateway: gateway,
            allowAllBusinessesScope: true,
          ),
        ),
      );
      await pumpEventually(tester);

      final allBusinessesRow = find.byKey(
        const Key('admin_setup_scope_all_businesses'),
      );
      expect(allBusinessesRow, findsOneWidget);
      expect(find.text('All businesses'), findsOneWidget);
      // Not selected yet: the platform-wide builder is not mounted.
      expect(find.byKey(const Key('all_biz_view')), findsNothing);
      expect(
        find.byKey(const Key('admin_setup_function_all_businesses')),
        findsNothing,
      );

      await tester.tap(allBusinessesRow);
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_setup_function_all_businesses')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('all_biz_view')), findsOneWidget);
      // HP#11: the workspace header names the platform-wide selection.
      expect(find.textContaining('All businesses'), findsWidgets);
    },
  );

  testWidgets(
    'All businesses row is absent by default (other setup surfaces '
    'unaffected)',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      await tester.pumpWidget(
        wrap(
          buildWorkspace(
            gateway: gateway,
            allowAllBusinessesScope: false,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_setup_scope_all_businesses')),
        findsNothing,
      );
      expect(find.text('All businesses'), findsNothing);
    },
  );

  testWidgets(
    'the option stays hidden when no all-businesses builder is provided',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      await tester.pumpWidget(
        wrap(
          buildWorkspace(
            gateway: gateway,
            allowAllBusinessesScope: true,
            withAllBusinessesBuilder: false,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_setup_scope_all_businesses')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'selecting a concrete business clears the all-businesses selection',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[seedBundle()],
      );
      await tester.pumpWidget(
        wrap(
          buildWorkspace(
            gateway: gateway,
            allowAllBusinessesScope: true,
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(
        find.byKey(const Key('admin_setup_scope_all_businesses')),
      );
      await pumpEventually(tester);
      expect(find.byKey(const Key('all_biz_view')), findsOneWidget);

      // Pick a concrete business: the all-businesses view yields to the
      // scoped function builder.
      final businessRow = find.byKey(
        const Key('admin_setup_scope_business_op-seed-1'),
      );
      await tester.ensureVisible(businessRow);
      await pumpEventually(tester);
      await tester.tap(businessRow);
      await pumpEventually(tester);

      expect(find.byKey(const Key('all_biz_view')), findsNothing);
      expect(find.byKey(const Key('scoped_view')), findsOneWidget);
    },
  );
}
