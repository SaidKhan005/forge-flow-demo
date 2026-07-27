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
// The bubbles are now calm and static (2026-07-27 premium pass removed
// the center bubble's glow pulse + rotating arcs, along with the earlier
// removal of the falling leaves + colour-breathing scrim + busy photo
// backdrop): home runs no looping motion at rest, only the one-shot
// entrance. This suite still pumps explicit durations (never
// pumpAndSettle) so the intent survives any future looping motion.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_ambient_leaves.dart';
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

    // The center bubble renders the hub's 'Dashboard' label, so the
    // product-category destination is asserted via that text.
    expect(find.text('Dashboard'), findsOneWidget);
    expect(tester.takeException(), isNull);

    const sectionTitles = {
      BarrioCategory.companyAndCompliance: 'Company & Compliance',
      BarrioCategory.serviceHospitality: 'Service & Hospitality',
      BarrioCategory.foodAndDrink: 'Food & Drink',
      BarrioCategory.numbersAndLabor: 'A Deeper Dive',
    };

    // Sections are horizontal swipe rows now: scroll the page to the
    // section header, park it at a known height, then drag the row
    // leftward until each label in the section has rendered.
    for (final category in sectionCategories) {
      final title = sectionTitles[category]!;
      final labels = barrioDestinations
          .where((d) => d.showOnHomeHub && d.category == category)
          .map((d) => d.label)
          .toList();

      await scrollTo(tester, find.text(title));
      final headerY = tester.getCenter(find.text(title)).dy;
      await tester.drag(
          find.byType(CustomScrollView), Offset(0, 300.0 - headerY));
      await tester.pump(const Duration(milliseconds: 60));

      for (final label in labels) {
        var attempts = 0;
        while (find.text(label).evaluate().isEmpty && attempts < 12) {
          final rowPoint = Offset(
              195, tester.getCenter(find.text(title)).dy + 88);
          await tester.dragFrom(rowPoint, const Offset(-240, 0));
          await tester.pump(const Duration(milliseconds: 60));
          attempts++;
        }
        expect(find.text(label), findsOneWidget,
            reason: '$label must render exactly once in the $title row');
        expect(tester.takeException(), isNull,
            reason: 'no layout exception while revealing $label');
      }
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

  testWidgets('(h) the home TickerMode gate still toggles with route '
      'coverage, and home is calm (no looping motion) at rest',
      (tester) async {
    // 2026-07-27 premium pass: the center bubble's glow pulse + rotating
    // arcs were removed, so home no longer runs any looping motion at
    // rest. The home screen still wraps its shelf subtree in a
    // TickerMode gated on route currency (a structural battery guard);
    // this test pins that the gate keeps toggling with route coverage
    // and that home genuinely holds still (no running animations) both
    // as the current route and once covered.
    await pumpHome(tester);

    // Home's motion gate: the TickerMode wrapping the shelf subtree
    // (first TickerMode under BarrioHomeScreen). While the home route is
    // covered by an opaque pushed route it goes offstage, so the finder
    // must not skip offstage widgets.
    TickerMode homeTickerMode() => tester.widget<TickerMode>(
          find
              .descendant(
                of: find.byType(BarrioHomeScreen, skipOffstage: false),
                matching: find.byType(TickerMode, skipOffstage: false),
              )
              .first,
        );

    expect(homeTickerMode().enabled, isTrue,
        reason: 'the gate is enabled while home is the current route');
    expect(tester.hasRunningAnimations, isFalse,
        reason: 'the calm redesign runs no looping motion on the current '
            'home once the one-shot entrance has settled');

    // Push a screen on top, like opening a manual from the shelf.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: SizedBox.expand()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(homeTickerMode().enabled, isFalse,
        reason: 'the covered home disables its TickerMode-gated subtree');
    expect(tester.hasRunningAnimations, isFalse,
        reason: 'nothing animates on the covered home');

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(homeTickerMode().enabled, isTrue,
        reason: 'the gate re-enables when home becomes current again');
    expect(tester.hasRunningAnimations, isFalse,
        reason: 'home stays calm after pop: no looping motion to restart');
    expect(tester.takeException(), isNull);
  });

  group('(i) calm static backdrop (2026-07-26)', () {
    testWidgets('home no longer renders the falling-leaves overlay',
        (tester) async {
      await pumpHome(tester);
      expect(find.byType(BarrioAmbientLeaves), findsNothing,
          reason: 'the ambient leaves were dropped for the calm backdrop');
      expect(tester.takeException(), isNull);
    });

    testWidgets('home no longer renders the full-bleed home_bg photo layer',
        (tester) async {
      await pumpHome(tester);
      // Walk every Image on the fresh home: none may be the old
      // home_bg.webp full-bleed backdrop asset.
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        final provider = image.image;
        if (provider is AssetImage) {
          expect(provider.assetName, isNot(contains('home_bg')),
              reason: 'the photo backdrop was removed from home');
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('home renders the calm two-layer gradient backdrop',
        (tester) async {
      await pumpHome(tester);
      // The base backdrop layer is a LinearGradient carrying the
      // lightest-at-top cream stop colour (light theme, app-icon
      // palette); its presence proves the new static backdrop replaced
      // the animated scrim stack.
      var foundBaseGradient = false;
      for (final box in tester.widgetList<DecoratedBox>(
          find.byType(DecoratedBox))) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration &&
            decoration.gradient is LinearGradient) {
          final gradient = decoration.gradient as LinearGradient;
          if (gradient.colors.contains(const Color(0xFFFCF8EF))) {
            foundBaseGradient = true;
            break;
          }
        }
      }
      expect(foundBaseGradient, isTrue,
          reason: 'the calm cream base gradient backdrop must be present');
      expect(tester.takeException(), isNull);
    });
  });
}
