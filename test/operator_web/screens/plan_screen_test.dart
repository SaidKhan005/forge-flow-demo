// Plans & limits Phase 5b — "Your plan" surface widget tests.
//
// Pins the slice intent:
//
//   - a paid plan (Premium) renders the plan name, the headline price
//     line, the included-features list (AI advisor + the features the
//     plan layers on), and the upgrade CTA, with no trial countdown;
//   - a Pilot free-preview session shows "X days left in your free
//     preview" from the pinned clock + trial expiry;
//   - the top plan (Enterprise) shows the top-plan banner and NO
//     upgrade CTA;
//   - a session with no recognized tier renders the honest unknown
//     panel (the bare "—" sentinel), never a phantom plan;
//   - tapping the upgrade CTA opens the contact-guidance dialog;
//   - the slice's operator-facing literals carry zero em dashes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/plan_screen.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
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

  OperatorWebSession sessionFor({
    String? tier,
    bool trialMode = false,
    DateTime? trialExpiresAt,
    AccountPlanSnapshot? planSnapshot,
  }) => OperatorWebSession(
    uid: 'demo-owner',
    email: 'owner@demo.forgeflow.test',
    displayName: 'Demo Owner',
    operatorId: 'demo-operator',
    businessName: 'Demo Restaurant Group',
    primaryLocationId: 'demo-location',
    primaryLocationName: 'Demo Main Street',
    roles: const <String>['operator_owner'],
    subscriptionTier: tier,
    trialMode: trialMode,
    trialExpiresAt: trialExpiresAt,
    planSnapshot: planSnapshot,
  );

  Future<void> pump(
    WidgetTester tester,
    OperatorWebSession session, {
    DateTime Function()? nowUtc,
  }) async {
    await sizeViewport(tester);
    await tester.pumpWidget(wrap(PlanScreen(session: session, nowUtc: nowUtc)));
    await tester.pumpAndSettle();
  }

  testWidgets('paid plan renders name, price, features and upgrade CTA', (
    tester,
  ) async {
    await pump(tester, sessionFor(tier: 'premium'));

    // Header + current plan name.
    expect(find.text('Your plan'), findsWidgets);
    expect(find.byKey(const Key('operator_web_plan_name')), findsOneWidget);
    expect(find.text('Premium'), findsOneWidget);

    // Headline price line from the client pricing constants.
    expect(
      find.byKey(const Key('operator_web_plan_price_line')),
      findsOneWidget,
    );
    expect(find.textContaining(r'$250/mo'), findsOneWidget);

    // Included features: AI advisor (every paid plan) + Premium's adds.
    expect(find.byKey(const Key('operator_web_plan_included')), findsOneWidget);
    expect(find.text('AI advisor'), findsOneWidget);
    expect(find.text('Learning (LMS)'), findsOneWidget);
    expect(find.text('Scoreboard'), findsOneWidget);

    // A paid, non-top plan shows the upgrade CTA and no trial banner.
    expect(
      find.byKey(const Key('operator_web_plan_upgrade_cta')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_plan_trial_banner')),
      findsNothing,
    );
  });

  testWidgets('Pilot free preview shows days left from the pinned clock', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 5, 25, 12);
    // Expiry 10 full days out from the pinned clock.
    final expires = DateTime.utc(2026, 6, 4, 12);
    await pump(
      tester,
      sessionFor(tier: 'pilot', trialMode: true, trialExpiresAt: expires),
      nowUtc: () => now,
    );

    expect(find.text('Pilot'), findsOneWidget);
    expect(
      find.byKey(const Key('operator_web_plan_trial_banner')),
      findsOneWidget,
    );
    expect(
      find.textContaining('10 days left in your free preview'),
      findsOneWidget,
    );
    // Pilot includes the AI advisor.
    expect(find.text('AI advisor'), findsOneWidget);
  });

  testWidgets('Pilot with no expiry shows an honest free-preview state', (
    tester,
  ) async {
    await pump(tester, sessionFor(tier: 'pilot', trialMode: true));

    expect(
      find.byKey(const Key('operator_web_plan_trial_banner')),
      findsOneWidget,
    );
    // No phantom day count; the banner falls back to the honest line.
    expect(find.textContaining('days left'), findsNothing);
    expect(
      find.textContaining('could not work out how many days'),
      findsOneWidget,
    );
  });

  testWidgets('live plan snapshot overrides fallback price and features', (
    tester,
  ) async {
    await pump(
      tester,
      sessionFor(
        tier: 'starter',
        planSnapshot: const AccountPlanSnapshot(
          tierKey: 'premium',
          priceLine: r'$375/mo plus $4/seat',
          enabledFeatureSlugs: <String>['advisor', 'workflows'],
          contractLabel: 'Franchise 2026',
          overrideStatus: 'set_here',
        ),
      ),
    );

    expect(find.text('Premium'), findsOneWidget);
    expect(find.text(r'$375/mo plus $4/seat'), findsOneWidget);
    expect(find.text('Franchise 2026'), findsOneWidget);
    expect(find.text('AI advisor'), findsOneWidget);
    expect(find.text('Workflow catalog'), findsOneWidget);
    expect(find.text('Learning (LMS)'), findsNothing);
  });

  testWidgets('top plan hides the upgrade CTA and shows the top-plan note', (
    tester,
  ) async {
    await pump(tester, sessionFor(tier: 'enterprise'));

    expect(find.text('Enterprise'), findsOneWidget);
    expect(
      find.byKey(const Key('operator_web_plan_upgrade_cta')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('operator_web_plan_upgrade_top')),
      findsOneWidget,
    );
  });

  testWidgets('unknown tier renders the honest unknown panel', (tester) async {
    await pump(tester, sessionFor(tier: null));

    expect(find.byKey(const Key('operator_web_plan_unknown')), findsOneWidget);
    // The bare "—" sentinel, not a phantom plan name.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Premium'), findsNothing);
    expect(
      find.byKey(const Key('operator_web_plan_upgrade_cta')),
      findsNothing,
    );
  });

  testWidgets('upgrade CTA opens the contact-guidance dialog', (tester) async {
    await pump(tester, sessionFor(tier: 'starter'));

    await tester.tap(find.byKey(const Key('operator_web_plan_upgrade_cta')));
    await tester.pumpAndSettle();

    expect(find.text('Talk to us about upgrading'), findsWidgets);
    expect(find.textContaining('hello@forgeandflow.com'), findsOneWidget);
    expect(
      find.byKey(const Key('operator_web_plan_upgrade_dialog_close')),
      findsOneWidget,
    );
  });

  testWidgets('no operator-facing literal uses an em dash', (tester) async {
    // The bare "—" sentinel is the sanctioned empty-value glyph and is
    // allowed; this guards against an em dash used as punctuation in a
    // sentence. We assert no rendered Text combines an em dash with
    // surrounding words.
    await pump(tester, sessionFor(tier: 'pro'));
    final texts = tester.widgetList<Text>(find.byType(Text));
    for (final text in texts) {
      final data = text.data;
      if (data == null) continue;
      // Allow the standalone sentinel; flag an em dash with adjacent
      // non-space characters (punctuation/separator use).
      final emDashAsPunctuation = RegExp(r'\S—|—\S');
      expect(
        emDashAsPunctuation.hasMatch(data),
        isFalse,
        reason: 'Em dash used as punctuation in: "$data"',
      );
    }
  });
}
