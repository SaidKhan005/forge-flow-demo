// Operator Web W4.B - Audit log chain integrity badge widget tests.
//
// Pins the four badge states (healthy / delayed / failed / unknown)
// the master plan named for the operator-web Audit Log screen, plus
// the loading + transient-error variants the screen renders while
// the gateway resolves.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/audit_log_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_audit_log_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_audit_chain_anchors_gateway_provider.dart';
import 'package:forge_and_flow/operator_web/services/web_team_audit_log_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  // Pin the screen clock to a moment where the latest demo audit log
  // fixture stays inside the default time-window filter so the screen
  // pumps the same way it does in the existing audit_log_screen_test.
  final pinnedClock = DateTime.utc(2026, 5, 5, 18);

  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession ownerSession() => OperatorWebSession(
        uid: 'demo-user-owner',
        email: 'sam.owner@demobistro.test',
        displayName: 'Sam Patel',
        operatorId: kDemoOperatorIdFixture,
        businessName: kDemoOperatorBusinessNameFixture,
        primaryLocationId: 'demo-loc-downtown',
        primaryLocationName: 'Downtown',
        roles: const <String>['operator_owner'],
      );

  WebTeamAuditLogGateway logGateway() =>
      DemoWebTeamAuditLogGateway(clock: pinnedClock);

  Future<void> pumpScreen(
    WidgetTester tester, {
    required OperatorWebAuditChainAnchorsGateway? chainGateway,
  }) async {
    await sizeViewport(tester);
    await tester.pumpWidget(
      wrap(
        AuditLogScreen(
          session: ownerSession(),
          gateway: logGateway(),
          chainAnchorGateway: chainGateway,
          chainAnchorClock: () => pinnedClock,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('healthy snapshot renders the green anchored copy',
      (tester) async {
    final gateway = OperatorWebAuditChainAnchorsGatewayDemo(
      snapshot: OperatorWebAuditChainAnchorSnapshot(
        status: OperatorWebAuditChainAnchorStatus.healthy,
        anchoredAt: pinnedClock.subtract(const Duration(hours: 4)),
        lastAnchorBlobAt: pinnedClock.subtract(const Duration(hours: 4)),
        chainDate: DateTime.utc(2026, 5, 4),
      ),
    );
    await pumpScreen(tester, chainGateway: gateway);

    expect(
      find.byKey(const Key('operator_web_audit_log_integrity_badge')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('operator_web_audit_log_integrity_badge_healthy_title'),
      ),
      findsOneWidget,
    );
    expect(find.text('Audit chain healthy'), findsOneWidget);
    expect(
      find.text('Anchored at 02:00 UTC. Last anchor 4 hours ago.'),
      findsOneWidget,
    );
  });

  testWidgets('delayed snapshot renders the yellow delayed copy',
      (tester) async {
    final gateway = OperatorWebAuditChainAnchorsGatewayDemo(
      snapshot: OperatorWebAuditChainAnchorSnapshot(
        status: OperatorWebAuditChainAnchorStatus.delayed,
        anchoredAt: pinnedClock.subtract(const Duration(hours: 30)),
        lastAnchorBlobAt: pinnedClock.subtract(const Duration(hours: 30)),
        chainDate: DateTime.utc(2026, 5, 3),
      ),
    );
    await pumpScreen(tester, chainGateway: gateway);

    expect(
      find.byKey(
        const Key('operator_web_audit_log_integrity_badge_delayed_title'),
      ),
      findsOneWidget,
    );
    expect(find.text('Audit chain delayed'), findsOneWidget);
    expect(
      find.textContaining('Last anchor was 30 hours ago.'),
      findsOneWidget,
    );
  });

  testWidgets('failed snapshot renders the red anchor-failed copy',
      (tester) async {
    final gateway = OperatorWebAuditChainAnchorsGatewayDemo(
      snapshot: OperatorWebAuditChainAnchorSnapshot(
        status: OperatorWebAuditChainAnchorStatus.failed,
        anchoredAt: pinnedClock.subtract(const Duration(days: 4)),
        // last_anchor_blob_at intentionally null - the M3 breadcrumb
        // is what flips status -> failed in the route classifier.
        chainDate: DateTime.utc(2026, 5, 1),
      ),
    );
    await pumpScreen(tester, chainGateway: gateway);

    expect(
      find.byKey(
        const Key('operator_web_audit_log_integrity_badge_failed_title'),
      ),
      findsOneWidget,
    );
    expect(find.text('Audit chain anchor failed'), findsOneWidget);
    expect(
      find.textContaining('F and F support is investigating'),
      findsOneWidget,
    );
  });

  testWidgets('unknown snapshot renders the no-anchor-yet copy',
      (tester) async {
    final gateway = OperatorWebAuditChainAnchorsGatewayDemo(
      snapshot: const OperatorWebAuditChainAnchorSnapshot(
        status: OperatorWebAuditChainAnchorStatus.unknown,
      ),
    );
    await pumpScreen(tester, chainGateway: gateway);

    expect(
      find.byKey(
        const Key('operator_web_audit_log_integrity_badge_unknown_title'),
      ),
      findsOneWidget,
    );
    expect(find.text('Audit chain status unknown'), findsOneWidget);
    expect(
      find.textContaining('No anchor recorded yet.'),
      findsOneWidget,
    );
  });

  testWidgets('no chain gateway falls back to the unknown badge state',
      (tester) async {
    await pumpScreen(tester, chainGateway: null);

    expect(
      find.byKey(const Key('operator_web_audit_log_integrity_badge')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('operator_web_audit_log_integrity_badge_unknown_title'),
      ),
      findsOneWidget,
    );
    expect(find.text('Audit chain status unknown'), findsOneWidget);
  });

  testWidgets('gateway error surfaces the unavailable copy', (tester) async {
    await pumpScreen(tester, chainGateway: _ThrowingGateway());

    expect(
      find.byKey(
        const Key('operator_web_audit_log_integrity_badge_unknown_title'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Audit chain status unavailable'),
      findsOneWidget,
    );
  });
}

class _ThrowingGateway implements OperatorWebAuditChainAnchorsGateway {
  @override
  Future<OperatorWebAuditChainAnchorSnapshot> latest() async {
    throw const OperatorWebAuditChainAnchorsError(
      code: 'transport_error',
      message: 'simulated failure',
    );
  }
}
