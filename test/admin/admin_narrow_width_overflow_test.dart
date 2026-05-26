// B-r2: narrow-width text-scaling overflow guard for the whole admin console.
//
// The admin MaterialApp clamps text scaling up to a 1.12 floor (see
// `AdminConsoleApp.builder`). In a narrow window the side nav still claims
// 304px, and scoped-workspace routes fold into a ~456px compact function
// pane. Any widget whose Row cannot shrink overflows horizontally there —
// the exact bug first found on the corpus "Show technical details" toggle.
//
// This test drives the real AdminConsoleApp (so the 1.12 clamp is live) to
// every non-placeholder admin route at a 760px-wide surface, with every
// route forced visible in the side nav so the drill-in setup tiles are
// reachable too. It asserts no RenderFlex overflow. Beyond guarding the
// four B-r2 fixes —
//   * corpus toggle              (corpus_admin_screen.dart)
//   * observability month toggle (admin_observability_run_controls.dart)
//   * notification event row     (admin_notification_preferences_screen.dart)
//   * members meta chips         (admin_members_ops_table.dart)
// — it catches any future admin screen that regresses the same way.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';

/// Seeded demo business (`_defaultDemoGateway`) used to satisfy the
/// scoped-workspace routes that need a selected business before their
/// function pane loads.
const String _demoOpId = '00000000-0000-4000-8000-000000000001';

/// The full route catalog with every entry forced visible in the side nav,
/// so setup-tile (drill-in) routes can be reached by a plain nav tap.
final List<AdminRoute> _allRoutesVisible = <AdminRoute>[
  for (final r in kAdminRoutes)
    AdminRoute(
      id: r.id,
      title: r.title,
      path: r.path,
      icon: r.icon,
      section: r.section,
      builder: r.builder,
      subtitle: r.subtitle,
      badge: r.badge,
      placeholder: r.placeholder,
      visibleInNav: true,
      navAnchorRouteId: r.navAnchorRouteId,
    ),
];

void main() {
  for (final route in kAdminRoutes) {
    // Placeholder routes render a static "coming soon" panel, not a builder.
    if (route.placeholder) continue;
    final routeId = route.id;

    testWidgets('$routeId renders without overflow at a narrow admin width',
        (tester) async {
      // Wide enough to keep the 304px side nav (every route reachable) but
      // narrow enough that scoped workspaces fold into their ~456px compact
      // function pane — the layout that surfaces text-scaling overflow.
      await tester.binding.setSurfaceSize(const Size(760, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final source = DemoAdminAuthSource(
        initial: const AdminAuthAuthenticated(
          AdminAuthSession(
            uid: 'demo-super-admin',
            email: 'admin@forgeflow.test',
            displayName: 'Demo Super Admin',
            // super_admin renders the most affordances (edit buttons, action
            // menus), maximising the chance of catching a squeeze.
            roles: <String>['super_admin'],
          ),
        ),
      );
      addTearDown(source.dispose);

      await tester.pumpWidget(
        AdminConsoleServicesScope(
          adminAuthSource: source,
          child: AdminConsoleApp(authSource: source, routes: _allRoutesVisible),
        ),
      );
      await tester.pumpAndSettle();

      final nav = find.byKey(Key('admin_nav_item_$routeId'));
      expect(nav, findsOneWidget, reason: 'route $routeId should be in the nav');
      await tester.ensureVisible(nav);
      await tester.tap(nav);
      await tester.pumpAndSettle();

      // Scoped-workspace routes need a business selected before the function
      // pane loads; pick the seeded demo business if the Scope pane offers it.
      final biz = find.byKey(Key('admin_setup_scope_business_$_demoOpId'));
      if (biz.evaluate().isNotEmpty) {
        await tester.ensureVisible(biz);
        await tester.tap(biz);
        await tester.pumpAndSettle();
      }

      // At this width a scoped workspace splits into [Scope | <function>]
      // tabs; switch to the function tab (index 1) to lay out the screen.
      final wsTabs = find.byKey(const Key('admin_setup_workspace_tabs'));
      if (wsTabs.evaluate().isNotEmpty) {
        final tabs = find.descendant(
          of: find.byType(TabBar),
          matching: find.byType(Tab),
        );
        if (tabs.evaluate().length >= 2) {
          await tester.tap(tabs.at(1));
          await tester.pumpAndSettle();
        }
      }

      expect(
        tester.takeException(),
        isNull,
        reason: 'route $routeId overflows at a 760px width under 1.12 text '
            'scaling — a widget Row needs Flexible/Wrap to degrade gracefully',
      );
    });
  }
}
