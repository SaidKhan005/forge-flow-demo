// integration_test/admin_pressure/sysmon_health/scenario_sysmon_health_01_categories_render.dart
//
// Lane D — Sysmon/Health-01: the System health route mounts the screen
// scaffold and resolves to a recognised state — either the summary +
// tabs (normal), the loading indicator, or the load-error placeholder.
//
// Keys come from lib/admin/screens/health_admin_screen.dart:
//   - admin_health_screen      (:314)
//   - admin_health_summary     (:378)
//   - admin_health_tabs        (:413)
//   - admin_health_loading     (:341)
//   - admin_health_load_error  (:334)
//   - admin_health_title       (:970 titleKey)
//
// This scenario also asserts no RenderFlex overflow during the
// category render — System health has a tab strip with variable
// label widths that historically pressured the layout.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Sysmon/Health-01: System health mounts scaffold and resolves to '
    'summary+tabs, loading, or load-error state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminHealthRouteId);

      // Screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_health_screen')),
        findsOneWidget,
        reason: 'System health screen scaffold did not mount.',
      );

      // Body resolves to a recognised state. Reject "blank" failures.
      final hasSummary = find
          .byKey(const Key('admin_health_summary'))
          .evaluate()
          .isNotEmpty;
      final hasTabs = find
          .byKey(const Key('admin_health_tabs'))
          .evaluate()
          .isNotEmpty;
      final hasLoading = find
          .byKey(const Key('admin_health_loading'))
          .evaluate()
          .isNotEmpty;
      final hasError = find
          .byKey(const Key('admin_health_load_error'))
          .evaluate()
          .isNotEmpty;

      expect(
        (hasSummary && hasTabs) || hasLoading || hasError,
        isTrue,
        reason:
            'System health did not resolve to summary+tabs, loading, or '
            'load-error state — the surface is blank.',
      );

      // No overflows during category render.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'System health overflowed during category render: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
