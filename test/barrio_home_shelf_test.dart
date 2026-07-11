// Editorial Shelf home screen tests (2026-07-11 Barrio Home Redesign V1).
// Plan: docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md
//
// Pins, at a 390x844 phone viewport:
//   (a) the Forge & Flow hero card renders with its Open dashboard pill;
//   (b) all four category section titles render after scrolling;
//   (c) every showOnHomeHub destination label is reachable by scrolling
//       and renders exactly once, with no RenderFlex overflow anywhere
//       along the scroll (f);
//   (d) tapping a training card routes through BarrioRouteMap (Navigator
//       push lands on TrainingDocScreen), and the shelf's tap callback
//       fires for visible cards while B18-dimmed cards stay inert;
//   (e) preston_lee_model renders its COMING SOON tag and keeps its
//       existing tap-through to the placeholder screen;
//   (g) supervisor_content (showOnHomeHub: false) never renders.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
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

  /// The four category sections in their fixed shelf order.
  const sectionCategories = [
    BarrioCategory.serviceHospitality,
    BarrioCategory.foodAndDrink,
    BarrioCategory.numbersAndLabor,
    BarrioCategory.companyAndCompliance,
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
    // settle. No looping animation remains on the home screen.
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

  testWidgets('(a) hero card renders Forge & Flow with the Open dashboard '
      'pill', (tester) async {
    await pumpHome(tester);

    expect(find.text('OPERATIONS'), findsOneWidget);
    expect(find.text('Forge & Flow'), findsOneWidget);
    expect(find.text('Open dashboard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('(b) all four section titles render after scrolling',
      (tester) async {
    await pumpHome(tester);

    const titles = [
      'Service & Hospitality',
      'Food & Drink',
      'Running the Numbers',
      'Company & Compliance',
    ];
    for (final title in titles) {
      await scrollTo(tester, find.text(title));
      expect(find.text(title), findsOneWidget,
          reason: 'section "$title" must render');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('(c)(f) every home destination label is reachable by scrolling '
      'with no overflow errors', (tester) async {
    await pumpHome(tester);

    final orderedLabels = <String>[
      ...barrioDestinations
          .where((d) =>
              d.showOnHomeHub && d.category == BarrioCategory.product)
          .map((d) => d.label),
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

  testWidgets('(d) tapping a training card pushes its training screen via '
      'BarrioRouteMap', (tester) async {
    final observer = _RecordingNavigatorObserver();
    await pumpHome(tester, observer: observer);
    final pushesBefore = observer.pushCount;

    await scrollTo(tester, find.text('Strong Foundation'));
    await tester.tap(find.text('Strong Foundation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(observer.pushCount, pushesBefore + 1,
        reason: 'the card tap must push exactly one route');
    expect(find.byType(TrainingDocScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Dispose the pushed screen's animations cleanly.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('(d) shelf tap callback: visible cards fire, B18-dimmed cards '
      'are inert', (tester) async {
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
            // hero must render dimmed (0.38) and non-interactive; the
            // all-staff training cards stay tappable.
            previewRole: BarrioPreviewRole.staff,
            onDestinationTap: (d) => tapped.add(d.id),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));

    final heroOpacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('Forge & Flow'), matching: find.byType(Opacity))
          .first,
    );
    expect(heroOpacity.opacity, 0.38,
        reason: 'not-visible destinations render at exactly 0.38 opacity');

    await tester.tap(find.text('Forge & Flow'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, isEmpty, reason: 'dimmed destinations are non-interactive');

    await scrollTo(tester, find.text('Strong Foundation'));
    await tester.tap(find.text('Strong Foundation'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, ['training_strong_foundation']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('(e) preston_lee_model renders COMING SOON and keeps its '
      'tap-through', (tester) async {
    await pumpHome(tester);

    await scrollTo(tester, find.text('Preston Lee Model'));
    expect(find.text('Preston Lee Model'), findsOneWidget);
    expect(find.text('COMING SOON'), findsOneWidget);

    await tester.tap(find.text('Preston Lee Model'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PrestonLeeModelComingSoonScreen), findsOneWidget,
        reason: 'coming-soon card keeps navigating to its placeholder');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('(g) supervisor_content never renders on the shelf',
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
