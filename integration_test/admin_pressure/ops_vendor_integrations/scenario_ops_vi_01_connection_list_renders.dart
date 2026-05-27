// integration_test/admin_pressure/ops_vendor_integrations/scenario_ops_vi_01_connection_list_renders.dart
//
// Lane B — Ops/VI-01: the Vendor Integrations route (per-location
// cluster) mounts the screen scaffold and resolves to one of three
// recognised states: the wired widget host (vendor connections card),
// the "location-required" placeholder when no location is in scope,
// or the "not-wired" placeholder when the gateway is absent.
//
// Keys come from lib/admin/screens/vendor_connections/vendor_connections_admin_mount.dart:
//   - admin_vendor_connections_screen           (:126, :133)
//   - admin_vendor_connections_screen_body      (:178 scrollKey)
//   - admin_vendor_connections_widget_host      (:211)
//   - admin_vendor_connections_location_required (:238, :423)
//   - admin_vendor_connections_not_wired         (:279, :510)
//
// The route is per-business-cluster — it requires a location scope.
// This scenario uses selectDemoDinerTorontoLocationScope() to set up
// the scope, then taps the cluster route. After that the body must
// resolve to widget-host, location-required, or not-wired (never
// blank).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/VI-01: Vendor Integrations route mounts scaffold + body, and '
    'resolves to widget-host, location-required, or not-wired state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await selectDemoDinerTorontoLocationScope(tester);
      await tapAdminClusterRoute(tester, kAdminVendorIntegrationsRouteId);

      // Screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_vendor_connections_screen')),
        findsOneWidget,
        reason:
            'Vendor Integrations screen scaffold did not mount under the '
            'Toronto Yorkville location scope.',
      );

      // Body must resolve to a recognised state. Reject blank surface.
      final hasWidgetHost = find
          .byKey(const Key('admin_vendor_connections_widget_host'))
          .evaluate()
          .isNotEmpty;
      final hasLocationRequired = find
          .byKey(const Key('admin_vendor_connections_location_required'))
          .evaluate()
          .isNotEmpty;
      final hasNotWired = find
          .byKey(const Key('admin_vendor_connections_not_wired'))
          .evaluate()
          .isNotEmpty;

      expect(
        hasWidgetHost || hasLocationRequired || hasNotWired,
        isTrue,
        reason:
            'Vendor Integrations body did not resolve to a recognised '
            'state (widget-host, location-required, not-wired). The '
            'surface is blank — most likely the gateway wiring or scope '
            'resolution regressed.',
      );

      // Either the embedded body scroll key OR a route-not-wired
      // placeholder must be in the tree. The embedded body is the
      // normal path; the not-wired placeholder is the fallback.
      final hasBody = find
          .byKey(const Key('admin_vendor_connections_screen_body'))
          .evaluate()
          .isNotEmpty;
      expect(
        hasBody || hasNotWired,
        isTrue,
        reason:
            'Neither the embedded body scroll surface nor the not-wired '
            'placeholder is mounted — the route shell is broken.',
      );

      // No overflows on the Vendor Integrations layout.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Vendor Integrations overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
