// BSP.1 seam test: with `kBarrioBubbleOrbitEnabled == false` (the shipped
// default) the Barrio home-hub orbit bubbles are static tap targets. Plan:
// docs/phases/barrio_surface_polish_v1/barrio_surface_polish_v1_plan.md

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/barrio_surface_flags.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_bubble_hub.dart';

void main() {
  final hubDestinations = barrioDestinations
      .where((d) => d.showOnHomeHub)
      .toList();

  // The four non-primary hub destinations (the orbit bubbles).
  const orbitLabels = [
    'Company Handbook',
    'Interview Playbook',
    'Jim Taylor Labor Model',
    'Preston Lee Model',
  ];

  Future<void> pumpHub(
    WidgetTester tester, {
    ValueChanged<BarrioDestination>? onDestinationTap,
  }) async {
    // Give the hub room so every bubble center stays inside the Stack
    // bounds (required for hit testing).
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 700,
              height: 700,
              child: BarrioBubbleHub(
                destinations: hubDestinations,
                onDestinationTap: onDestinationTap ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The hub runs repeating controllers (shimmer, center pulse), so
  // pumpAndSettle would never complete. Advance time with fixed steps.
  Future<void> pumpFor(WidgetTester tester, Duration duration) async {
    const step = Duration(milliseconds: 250);
    var elapsed = Duration.zero;
    while (elapsed < duration) {
      await tester.pump(step);
      elapsed += step;
    }
  }

  testWidgets(
    'orbit bubbles hold their positions over time while orbit is disabled',
    (tester) async {
      expect(
        kBarrioBubbleOrbitEnabled,
        isFalse,
        reason:
            'BSP.1 ships with orbit disabled; this test pins the '
            'flag-false (static bubbles) behavior.',
      );

      await pumpHub(tester);

      // Let the one-shot entrance bloom finish (2400ms controller).
      await pumpFor(tester, const Duration(seconds: 3));

      final before = <String, Offset>{
        for (final label in orbitLabels)
          label: tester.getCenter(find.text(label)),
      };

      // At 28s per revolution the orbit would move each bubble roughly
      // 64 degrees in 5 seconds, so exact equality below proves all
      // positional motion is off.
      await pumpFor(tester, const Duration(seconds: 5));

      for (final label in orbitLabels) {
        expect(
          tester.getCenter(find.text(label)),
          before[label],
          reason:
              '$label must not move while kBarrioBubbleOrbitEnabled is false',
        );
      }

      // Dispose the hub so its idle-breathing timer cannot leak.
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('bubble tap still fires onDestinationTap', (tester) async {
    BarrioDestination? tapped;
    await pumpHub(tester, onDestinationTap: (d) => tapped = d);

    // Let the entrance bloom finish so bubbles are at full scale.
    await pumpFor(tester, const Duration(seconds: 3));

    await tester.tap(find.text('Company Handbook'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tapped, isNotNull);
    expect(tapped!.id, 'company_handbook');

    // Dispose the hub so the tap-rescheduled idle timer cannot leak.
    await tester.pumpWidget(const SizedBox());
  });
}
