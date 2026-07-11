// One-scroll round-bubble home screen tests (2026-07-11 operator
// decision revising the Editorial Shelf of Barrio Home Redesign V1).
//
// Pins, at a 390x844 phone viewport:
//   (a) the Forge & Flow center bubble renders with the hub's
//       'Dashboard' label;
//   (b) all four category section titles render after scrolling;
//   (c) every showOnHomeHub destination is reachable by scrolling and
//       renders exactly once, with no RenderFlex overflow anywhere
//       along the scroll (f). Bubble labels sit INSIDE the circles, and
//       the center bubble renders the hub's 'Dashboard' label rather
//       than the forge_and_flow destination label;
//   (d) tapping a training bubble routes through BarrioRouteMap
//       (Navigator push lands on TrainingDocScreen), and the shelf's
//       tap callback fires for visible bubbles while B18-dimmed bubbles
//       stay inert at exactly 0.38 opacity;
//   (e) preston_lee_model renders the hub's 0.30-opacity 'Coming Soon'
//       treatment and keeps its tap-through to the placeholder screen;
//   (g) supervisor_content (showOnHomeHub: false) never renders.
//
// The restored premium effects (falling leaves, scrim breathing, center
// arc + glow pulse) loop forever: NEVER pumpAndSettle in this suite;
// pump explicit durations only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_bubble.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';

class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount++;
  }
}

void main() {
  const phoneSize = Size(390, 844);

  /// The four category sections in their fixed order (2026-07-11
  /// operator revision: Company & Compliance leads).
  const sectionCategories = [
    BarrioCategory.companyAndCompliance,
    BarrioCategory.serviceHospitality,
    BarrioCategory.foodAndDrink,
    BarrioCategory.numbersAndLabor,
  ];

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    NavigatorObserver? observer,
  }) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: const BarrioHomeScreen(),
        navigatorObservers: [if (observer != null) observer],
      ),
    );
    // Let the one-shot entrance (900ms) and header wordmark (700ms)
    // finish. Looping ambient motion continues; explicit pumps only.
    await tester.pump(const Duration(milliseconds: 1000));
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('(a) hero renders the Forge & Flow center bubble with its '
      'Dashboard label', (tester) async {
    await pumpHome(tester);

    expect(find.byType(BarrioHomeCenterBubble), findsOneWidget);
    // The hub's center bubble labels itself 'Dashboard', not with the
    // forge_and_flow destination label.
    expect(find.text('Dashboard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('(b) all four section titles render after scrolling',
      (tester) async {
    await pumpHome(tester);

    const titles = [
      'Company & Compliance',
      'Service & Hospitality',
      'Food & Drink',
      'A Deeper Dive',
    ];
    for (final title in titles) {
      await scrollTo(tester, find.text(title));
      expect(find.text(title), findsOneWidget,
          reason: 'section "$title" must render');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('(c)(f) every home destination is reachable by scrolling '
      'with no overflow errors', (tester) async {
    await pumpHome(tester);

    final orderedLabels = <String>[
      // The center bubble renders the hub's 'Dashboard' label, so the
      // product-category destination is asserted via that text.
      for (final _ in barrioDestinations.where(
          (d) => d.showOnHomeHub && d.category == BarrioCategory.product))
        'Dashboard',
      for (final category in sectionCategories)
        ...barrioDestinations
            .where((d) => d.showOnHomeHub && d.category == category)
            .map((d) => d.label),
    ];

    for (final label in orderedLabels) {
      await scrollTo(tester, find.text(label));
      expect(find.text(label), findsOneWidget,
          reason: '$label must render exactly once');
      expect(tester.takeException(), isNull,
          reason: 'no layout exception while scrolling to $label');
    }

    // Scroll past the last row into the footer to cover the whole extent.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('(d) tapping a training bubble pushes its training screen via '
      'BarrioRouteMap', (tester) async {
    final observer = _RecordingNavigatorObserver();
    await pumpHome(tester, observer: observer);
    final pushesBefore = observer.pushCount;

    await scrollTo(tester, find.text('Strong Foundation'));
    await tester.tap(find.text('Strong Foundation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(observer.pushCount, pushesBefore + 1,
        reason: 'the bubble tap must push exactly one route');
    expect(find.byType(TrainingDocScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Dispose the pushed screen's animations cleanly.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('(d) shelf tap callback: visible bubbles fire, B18-dimmed '
      'bubbles are inert', (tester) async {
    usePhoneViewport(tester);
    final tapped = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BarrioHomeShelf(
            destinations:
                barrioDestinations.where((d) => d.showOnHomeHub).toList(),
            // Staff preview tier: not intended for forge_and_flow, so the
            // center bubble must render dimmed (0.38) and non-interactive;
            // the all-staff training bubbles stay tappable.
            previewRole: BarrioPreviewRole.staff,
            onDestinationTap: (d) => tapped.add(d.id),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));

    final heroOpacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('Dashboard'), matching: find.byType(Opacity))
          .first,
    );
    expect(heroOpacity.opacity, 0.38,
        reason: 'not-visible destinations render at exactly 0.38 opacity');

    await tester.tap(find.text('Dashboard'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, isEmpty, reason: 'dimmed destinations are non-interactive');

    await scrollTo(tester, find.text('Strong Foundation'));
    await tester.tap(find.text('Strong Foundation'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, ['training_strong_foundation']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('(e) preston_lee_model renders the hub Coming Soon treatment '
      'and keeps its tap-through', (tester) async {
    await pumpHome(tester);

    await scrollTo(tester, find.text('Preston Lee Model'));
    expect(find.text('Preston Lee Model'), findsOneWidget);
    expect(find.text('Coming Soon'), findsOneWidget);

    final prestonOpacity = tester.widget<Opacity>(
      find
          .ancestor(
              of: find.text('Preston Lee Model'),
              matching: find.byType(Opacity))
          .first,
    );
    expect(prestonOpacity.opacity, 0.30,
        reason: 'coming-soon bubbles use the hub 0.30-opacity treatment');

    await tester.tap(find.text('Preston Lee Model'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PrestonLeeModelComingSoonScreen), findsOneWidget,
        reason: 'coming-soon bubble keeps navigating to its placeholder');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('(g) supervisor_content never renders on the home screen',
      (tester) async {
    await pumpHome(tester);

    expect(find.text('Supervisor Content'), findsNothing);
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('Supervisor Content'), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}
