// Home hub GPU diet + glass token (2026-08-05 premium+performance
// Wave 2). These pin the four findings the slice landed, so a future
// pass cannot quietly reintroduce them:
//
//   A5  Every backdrop blur on the home hub is gone EXCEPT the one on
//       [BarrioHomeHeroCard]. The bubbles painted a ~95%-opaque fill
//       straight over a gaussian blur of a smooth cream gradient, so
//       ~26 saveLayer + blur passes per frame bought no picture.
//   B1  One glass-fill token. The private 0xE6FFFFFF disc fill and the
//       shellMid@0.92 literals all route through
//       [BarrioColors.glassFill]; the one deliberately lighter surface
//       (the search field) routes through [BarrioColors.glassFillSoft].
//   B2  The duplicate `_neutralLift` shadow builder is gone: bubbles
//       lift on the shared [barrioSoftShadow] token.
//   B4  The hero card is on the card radius rung, lifts on ONE navy
//       soft shadow (no coloured glow), and carries no dark-theme
//       white rim or black gradient stop.
//
// Nothing here asserts a pixel; every assertion reads the shipped
// decoration values, so the tests describe the look in the same terms
// the design tokens do.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_bubble.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_destination_visuals.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_hero_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_search.dart';

void main() {
  int rgb(Color c) => c.toARGB32() & 0x00FFFFFF;
  int argb(Color c) => c.toARGB32();

  const navy = Color(0xFF16243B); // BarrioColors.textPrimary
  const forgeAccent = kBarrioHomeForgeAccent; // 0xFF2E6EE0

  final centerDest = barrioDestinations.firstWhere(
    (d) => d.category == BarrioCategory.product,
  );
  final orbitDest = barrioDestinations.firstWhere(
    (d) =>
        d.showOnHomeHub &&
        !d.comingSoon &&
        d.category != BarrioCategory.product,
  );

  List<BoxDecoration> decorationsIn(WidgetTester tester, Finder root) {
    return [
      for (final box in tester.widgetList<DecoratedBox>(
          find.descendant(of: root, matching: find.byType(DecoratedBox))))
        if (box.decoration is BoxDecoration) box.decoration as BoxDecoration,
    ];
  }

  List<BoxShadow> shadowsIn(WidgetTester tester, Finder root) {
    return [
      for (final dec in decorationsIn(tester, root))
        ...(dec.boxShadow ?? const <BoxShadow>[]),
    ];
  }

  /// Every corner radius the subtree actually paints or clips with:
  /// decoration radii plus ClipRRect radii.
  List<double> radiiIn(WidgetTester tester, Finder root) {
    final out = <double>[];
    for (final dec in decorationsIn(tester, root)) {
      final r = dec.borderRadius;
      if (r is BorderRadius) out.add(r.topLeft.x);
    }
    for (final clip in tester.widgetList<ClipRRect>(
        find.descendant(of: root, matching: find.byType(ClipRRect)))) {
      final r = clip.borderRadius;
      if (r is BorderRadius) out.add(r.topLeft.x);
    }
    return out;
  }

  Future<void> pumpOn(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: BarrioColors.shellDeep,
          body: Center(child: child),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  // -------------------------------------------------------------------
  // A5 + B1 + B2: the bubbles
  // -------------------------------------------------------------------

  group('A5 home bubbles paint no backdrop blur', () {
    testWidgets('center bubble has no BackdropFilter', (tester) async {
      await pumpOn(
        tester,
        BarrioHomeCenterBubble(
          destination: centerDest,
          diameter: 160,
          dimmed: false,
          onTap: () {},
        ),
      );

      expect(
        find.descendant(
          of: find.byType(BarrioHomeCenterBubble),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
        reason: 'a ~95%-opaque fill was painted straight over the blur',
      );
      // The glass read that replaces it is still there: the specular
      // sheen gradient and the teal hairline ring.
      final decorations =
          decorationsIn(tester, find.byType(BarrioHomeCenterBubble));
      expect(decorations.any((d) => d.gradient != null), isTrue,
          reason: 'the top specular sheen still carries the glass');
      expect(
        decorations.any((d) =>
            d.border is Border &&
            rgb((d.border as Border).top.color) == rgb(BarrioColors.tealDeep)),
        isTrue,
        reason: 'the teal hairline ring is untouched',
      );
    });

    testWidgets('orbit bubble has no BackdropFilter, active or dimmed',
        (tester) async {
      for (final dimmed in [false, true]) {
        await pumpOn(
          tester,
          BarrioHomeOrbitBubble(
            destination: orbitDest,
            diameter: 100,
            dimmed: dimmed,
            onTap: () {},
          ),
        );
        expect(
          find.descendant(
            of: find.byType(BarrioHomeOrbitBubble),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
          reason: 'orbit bubble (dimmed: $dimmed) blurs nothing',
        );
      }
    });

    testWidgets('the whole home hub paints zero backdrop blurs',
        (tester) async {
      // 360 dp: the narrowest width the slice has to stay sound at.
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: BarrioHomeScreen()));
      await tester.pump(const Duration(milliseconds: 1000));

      expect(find.byType(BarrioHomeCenterBubble), findsOneWidget,
          reason: 'sanity: the hub really did build');
      expect(find.byType(BackdropFilter), findsNothing,
          reason: 'the ~26 per-frame gaussian passes are gone');
      expect(tester.takeException(), isNull,
          reason: 'nothing overflows at 360 dp width');
    });
  });

  group('B1 one glass-fill token on the home hub', () {
    testWidgets('center + orbit discs fill with BarrioColors.glassFill',
        (tester) async {
      await pumpOn(
        tester,
        BarrioHomeCenterBubble(
          destination: centerDest,
          diameter: 160,
          dimmed: false,
          onTap: () {},
        ),
      );
      expect(
        decorationsIn(tester, find.byType(BarrioHomeCenterBubble))
            .any((d) => d.color != null && argb(d.color!) == argb(BarrioColors.glassFill)),
        isTrue,
        reason: 'the private 0xE6FFFFFF disc fill is gone',
      );

      await pumpOn(
        tester,
        BarrioHomeOrbitBubble(
          destination: orbitDest,
          diameter: 100,
          dimmed: false,
          onTap: () {},
        ),
      );
      expect(
        decorationsIn(tester, find.byType(BarrioHomeOrbitBubble))
            .any((d) => d.color != null && argb(d.color!) == argb(BarrioColors.glassFill)),
        isTrue,
        reason: 'orbit discs read the same warmth as the reader cards',
      );
    });

    testWidgets('the search field is the one lighter glass rung',
        (tester) async {
      await pumpOn(
        tester,
        SizedBox(
          width: 360,
          child: BarrioHomeSearchField(onQueryChanged: (_) {}),
        ),
      );
      final fills = [
        for (final d in decorationsIn(tester, find.byType(BarrioHomeSearchField)))
          if (d.color != null) argb(d.color!),
      ];
      expect(fills, contains(argb(BarrioColors.glassFillSoft)),
          reason: 'the field routes through the soft token, not a literal');
    });
  });

  group('B2 bubbles lift on the shared shadow token', () {
    testWidgets('center + orbit each carry exactly one navy soft shadow',
        (tester) async {
      await pumpOn(
        tester,
        BarrioHomeCenterBubble(
          destination: centerDest,
          diameter: 160,
          dimmed: false,
          onTap: () {},
        ),
      );
      final centerShadows =
          shadowsIn(tester, find.byType(BarrioHomeCenterBubble));
      expect(centerShadows.length, 1);
      // barrioSoftShadow(y: 8, blur: 24, opacity: 0.10) — byte-identical
      // to the deleted _neutralLift() default, so the look is unchanged.
      expect(centerShadows.single.offset, const Offset(0, 8));
      expect(centerShadows.single.blurRadius, 24);
      expect(rgb(centerShadows.single.color), rgb(navy));

      await pumpOn(
        tester,
        BarrioHomeOrbitBubble(
          destination: orbitDest,
          diameter: 100,
          dimmed: false,
          onTap: () {},
        ),
      );
      final orbitShadows =
          shadowsIn(tester, find.byType(BarrioHomeOrbitBubble));
      expect(orbitShadows.length, 1);
      expect(orbitShadows.single.offset, const Offset(0, 6));
      expect(orbitShadows.single.blurRadius, 18);
      expect(rgb(orbitShadows.single.color), rgb(navy));
    });
  });

  // -------------------------------------------------------------------
  // B4: the hero card
  // -------------------------------------------------------------------

  group('B4 hero card is styled for the cream page', () {
    Future<void> pumpHero(WidgetTester tester, {bool dimmed = false}) {
      return pumpOn(
        tester,
        SizedBox(
          width: 360,
          child: BarrioHomeHeroCard(
            destination: centerDest,
            dimmed: dimmed,
            onTap: () {},
          ),
        ),
      );
    }

    testWidgets('card corners sit on the card rung, only the pill is round',
        (tester) async {
      await pumpHero(tester);
      final radii = radiiIn(tester, find.byType(BarrioHomeHeroCard));
      expect(radii.where((r) => r == BarrioRadii.card).length, 3,
          reason: 'outer decoration + ClipRRect + inner decoration');
      expect(radii.where((r) => r == 24).length, 1,
          reason: 'the only 24 left is the 48-high stadium pill');
    });

    testWidgets('lifts on one navy soft shadow, no coloured glow',
        (tester) async {
      await pumpHero(tester);
      final shadows = shadowsIn(tester, find.byType(BarrioHomeHeroCard));
      expect(shadows.length, 1,
          reason: 'the 36px + 64px double glow is gone');
      expect(rgb(shadows.single.color), rgb(navy));
      expect(shadows.single.blurRadius, 28);
      expect(shadows.single.offset, const Offset(0, 10));
      expect(shadows.any((s) => rgb(s.color) == rgb(forgeAccent)), isFalse,
          reason: 'no accent-coloured neon halo remains');
    });

    testWidgets('no white rim and no black gradient stop', (tester) async {
      await pumpHero(tester);
      final decorations = decorationsIn(tester, find.byType(BarrioHomeHeroCard));

      final cardBorders = <Color>[
        for (final d in decorations)
          if (d.border is Border && d.gradient is LinearGradient)
            (d.border as Border).top.color,
      ];
      expect(cardBorders.any((c) => argb(c) == 0x33FFFFFF), isFalse,
          reason: 'the dark-theme white rim is gone');
      expect(cardBorders.any((c) => rgb(c) == rgb(forgeAccent)), isTrue,
          reason: 'a muted accent hairline replaced it, matching the bubbles');

      final gradientColors = <Color>[
        for (final d in decorations)
          if (d.gradient != null) ...d.gradient!.colors,
      ];
      expect(gradientColors.any((c) => argb(c) == 0x46000000), isFalse,
          reason: 'the muddy black stop is gone');
      expect(gradientColors.any((c) => rgb(c) == rgb(BarrioColors.navy)), isTrue,
          reason: 'a navy tint cools the mid-stop instead');
    });

    testWidgets('keeps exactly one blur: the hero differentiator',
        (tester) async {
      await pumpHero(tester);
      expect(
        find.descendant(
          of: find.byType(BarrioHomeHeroCard),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
        reason: 'its fill tops out at 32% alpha, so the frost really reads',
      );
      expect(tester.takeException(), isNull,
          reason: 'nothing overflows at 360 dp width');
    });

    testWidgets('dimmed hero drops the lift entirely', (tester) async {
      await pumpHero(tester, dimmed: true);
      expect(shadowsIn(tester, find.byType(BarrioHomeHeroCard)), isEmpty);
    });
  });
}
