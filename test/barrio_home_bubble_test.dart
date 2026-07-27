// Premium bubble redesign tests (2026-07-27 operator request: "I like
// the aesthetics, I just don't like the neon lighting on all the
// bubbles: it makes it feel cheap and AI. I want them to feel premium
// and elegant").
//
// These pin that the old neon recipe is GONE and the restrained,
// brand-aligned recipe is in place, for both the center and orbit
// bubbles:
//   * no BoxShadow uses the Forge & Flow logo blue/orange (the old dual
//     glow halo + accent glow halo are removed);
//   * exactly ONE soft, neutral navy drop shadow lifts each active
//     bubble (no double/triple stacked or colored shadows);
//   * the disc no longer carries the orange F&F border or the
//     blue-to-orange gradient wash: the center disc is ringed in the
//     brand teal instead, and no gradient anywhere uses a logo color;
//   * home holds still: with the 6s glow pulse and rotating arcs gone,
//     an isolated bubble runs no looping animation at rest.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_bubble.dart';

void main() {
  // The Forge & Flow logo-palette colors the old neon recipe leaned on.
  const logoBlue = Color(0xFF2E6EE0);
  const logoOrange = Color(0xFFFF6B35);
  const oldOrangeBorder = Color(0xAAFF6B35);
  // The restrained replacements.
  const navy = Color(0xFF16243B); // BarrioColors.textPrimary
  const tealDeep = Color(0xFF2E9B8F); // BarrioColors.tealDeep

  int rgb(Color c) => c.toARGB32() & 0x00FFFFFF;
  bool isLogoColor(Color c) =>
      rgb(c) == rgb(logoBlue) || rgb(c) == rgb(logoOrange);

  final centerDest = barrioDestinations.firstWhere(
    (d) => d.category == BarrioCategory.product,
  );
  final orbitDest = barrioDestinations.firstWhere(
    (d) => d.showOnHomeHub && !d.comingSoon && d.category != BarrioCategory.product,
  );

  /// All BoxDecorations rendered inside [root].
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

  Future<void> pumpBubble(WidgetTester tester, Widget bubble) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: BarrioColors.shellDeep,
          body: Center(child: bubble),
        ),
      ),
    );
    // Let any (implicit) animation settle; there should be none looping.
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('BarrioHomeCenterBubble premium redesign', () {
    testWidgets('lifts on a single neutral navy shadow, no neon glow',
        (tester) async {
      await pumpBubble(
        tester,
        BarrioHomeCenterBubble(
          destination: centerDest,
          diameter: 160,
          dimmed: false,
          onTap: () {},
        ),
      );

      final shadows =
          shadowsIn(tester, find.byType(BarrioHomeCenterBubble));
      expect(shadows.length, 1,
          reason: 'exactly one soft neutral drop shadow (no stacked glow)');
      expect(rgb(shadows.single.color), rgb(navy),
          reason: 'the single shadow is the neutral navy lift');
      expect(shadows.any((s) => isLogoColor(s.color)), isFalse,
          reason: 'no colored blue/orange neon glow halo remains');
    });

    testWidgets('disc is ringed in brand teal, no orange border or wash',
        (tester) async {
      await pumpBubble(
        tester,
        BarrioHomeCenterBubble(
          destination: centerDest,
          diameter: 160,
          dimmed: false,
          onTap: () {},
        ),
      );

      final decorations =
          decorationsIn(tester, find.byType(BarrioHomeCenterBubble));

      // Borders: the disc is teal, nothing is the old orange F&F border.
      final borderColors = <Color>[
        for (final d in decorations)
          if (d.border is Border) (d.border as Border).top.color,
      ];
      expect(borderColors.any((c) => rgb(c) == rgb(tealDeep)), isTrue,
          reason: 'the center disc carries the brand teal hairline ring');
      expect(
          borderColors.any((c) =>
              rgb(c) == rgb(oldOrangeBorder) || isLogoColor(c)),
          isFalse,
          reason: 'the orange F&F-logo border is gone');

      // Gradients: none uses a logo blue/orange (the wash is removed).
      for (final d in decorations) {
        final gradient = d.gradient;
        if (gradient != null) {
          expect(gradient.colors.any(isLogoColor), isFalse,
              reason: 'no blue-to-orange logo wash remains on the disc');
        }
      }
    });

    testWidgets('renders the Dashboard label and runs no looping motion',
        (tester) async {
      await pumpBubble(
        tester,
        BarrioHomeCenterBubble(
          destination: centerDest,
          diameter: 160,
          dimmed: false,
          onTap: () {},
        ),
      );

      expect(find.text('Dashboard'), findsOneWidget);
      // The 6s glow pulse and rotating arcs are gone: the bubble is
      // calm and static, so nothing loops at rest.
      expect(tester.hasRunningAnimations, isFalse,
          reason: 'no glow pulse / arc ticker keeps animating');
    });
  });

  group('BarrioHomeOrbitBubble premium redesign', () {
    testWidgets('lifts on a single neutral navy shadow, no accent glow',
        (tester) async {
      await pumpBubble(
        tester,
        BarrioHomeOrbitBubble(
          destination: orbitDest,
          diameter: 100,
          dimmed: false,
          onTap: () {},
        ),
      );

      final shadows = shadowsIn(tester, find.byType(BarrioHomeOrbitBubble));
      expect(shadows.length, 1,
          reason: 'exactly one soft neutral drop shadow (no accent glow)');
      expect(rgb(shadows.single.color), rgb(navy),
          reason: 'the single shadow is the neutral navy lift');
      expect(shadows.any((s) => isLogoColor(s.color)), isFalse,
          reason: 'no colored accent glow halo remains');
    });

    testWidgets('dimmed orbit bubble drops the lift entirely',
        (tester) async {
      await pumpBubble(
        tester,
        BarrioHomeOrbitBubble(
          destination: orbitDest,
          diameter: 100,
          dimmed: true,
          onTap: () {},
        ),
      );

      final shadows = shadowsIn(tester, find.byType(BarrioHomeOrbitBubble));
      expect(shadows, isEmpty,
          reason: 'dimmed bubbles recede: no drop shadow at all');
    });
  });
}
