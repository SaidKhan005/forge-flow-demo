// Vendor integrations nav-item attention chip — widget tests.
//
// Pins the contract for `OperatorWebNavItem.alertCount`: when > 0 the
// side-nav tile renders an attention chip with the count; when 0 the
// chip is absent. These are pure widget tests over the nav-item
// surface — no router state, no gateway, no plumbing — so they stay
// stable as the router-side fetch logic evolves.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/widgets/web_app_shell.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  group('OperatorWebNavItem alertCount chip', () {
    testWidgets(
      'renders attention chip with the count when alertCount > 0',
      (tester) async {
        await _pumpShell(
          tester,
          navItems: const <OperatorWebNavItem>[
            OperatorWebNavItem(
              id: 'vendor_connections',
              title: 'Vendor integrations',
              icon: Icons.cable_outlined,
              group: 'Data & integrations',
              alertCount: 2,
              alertTooltip: '2 vendor connections need attention',
            ),
          ],
          selectedNavId: 'vendor_connections',
        );

        expect(
          find.byKey(const Key('operator_web_nav_alert_chip_vendor_connections')),
          findsOneWidget,
        );
        expect(find.text('2'), findsOneWidget);
      },
    );

    testWidgets(
      'omits chip when alertCount is 0',
      (tester) async {
        await _pumpShell(
          tester,
          navItems: const <OperatorWebNavItem>[
            OperatorWebNavItem(
              id: 'vendor_connections',
              title: 'Vendor integrations',
              icon: Icons.cable_outlined,
              group: 'Data & integrations',
            ),
          ],
          selectedNavId: 'vendor_connections',
        );

        expect(
          find.byKey(const Key('operator_web_nav_alert_chip_vendor_connections')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'chip is suppressed when placeholder is true (placeholder wins)',
      (tester) async {
        // Defensive contract: the "Soon" pill and the alert chip live
        // in the same slot. A placeholder tile with a non-zero count
        // should show "Soon" — the chip is meaningless when the screen
        // is not yet shipped.
        await _pumpShell(
          tester,
          navItems: const <OperatorWebNavItem>[
            OperatorWebNavItem(
              id: 'placeholder_screen',
              title: 'Coming soon',
              icon: Icons.cable_outlined,
              group: 'Data & integrations',
              placeholder: true,
              alertCount: 9,
            ),
          ],
          selectedNavId: 'placeholder_screen',
        );

        expect(find.text('Soon'), findsOneWidget);
        expect(
          find.byKey(const Key('operator_web_nav_alert_chip_placeholder_screen')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'singular tooltip copy when alertCount == 1 (default)',
      (tester) async {
        await _pumpShell(
          tester,
          navItems: const <OperatorWebNavItem>[
            OperatorWebNavItem(
              id: 'vendor_connections',
              title: 'Vendor integrations',
              icon: Icons.cable_outlined,
              group: 'Data & integrations',
              alertCount: 1,
            ),
          ],
          selectedNavId: 'vendor_connections',
        );

        final tooltipFinder = find.byKey(
          const Key('operator_web_nav_alert_tooltip_vendor_connections'),
        );
        expect(tooltipFinder, findsOneWidget);
        final tooltip = tester.widget<Tooltip>(tooltipFinder);
        expect(tooltip.message, contains('1 item needs'));
      },
    );
  });
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required List<OperatorWebNavItem> navItems,
  required String selectedNavId,
}) async {
  const session = OperatorWebSession(
    uid: 'user-1',
    email: 'fixture@example.com',
    displayName: 'Fixture User',
    operatorId: 'op-1',
    businessName: 'Fixture Restaurant',
    primaryLocationName: 'Fixture Location',
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        textTheme: const TextTheme(),
      ),
      home: ColoredBox(
        color: AppColors.backgroundDeep,
        child: WebAppShell(
          session: session,
          navItems: navItems,
          selectedNavId: selectedNavId,
          onSelectNav: (_) {},
          body: const SizedBox.shrink(),
          onSignOut: () {},
        ),
      ),
    ),
  );
  await tester.pump();
}
