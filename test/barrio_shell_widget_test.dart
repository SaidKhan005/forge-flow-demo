import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_route_map.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/forge_and_flow_destination_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/supervisor_content_screen_placeholder.dart';

void main() {
  // A. Destination manifest (metadata-driven)

  group('Barrio destination manifest', () {
    test('contains all six required destinations', () {
      final ids = barrioDestinations.map((d) => d.id).toSet();
      expect(ids, containsAll([
        'forge_and_flow',
        'company_handbook',
        'interview_playbook',
        'jim_taylor_labor_model',
        'preston_lee_model',
        'supervisor_content',
      ]));
    });

    test('Forge & Flow is the only primary-prominence destination', () {
      final primaries = barrioDestinations
          .where((d) => d.prominence == BarrioProminence.primary)
          .toList();
      expect(primaries.length, 1);
      expect(primaries.first.id, 'forge_and_flow');
    });

    test('Preston Lee Model is marked coming soon', () {
      final preston =
          barrioDestinations.firstWhere((d) => d.id == 'preston_lee_model');
      expect(preston.comingSoon, isTrue);
    });

    test('home hub destinations are tagged correctly', () {
      final hubDests =
          barrioDestinations.where((d) => d.showOnHomeHub).toList();
      // supervisor_content has showOnHomeHub: false — not on the hub
      expect(hubDests.length, greaterThanOrEqualTo(5));
    });

    test('all destinations are metadata-driven with audience labels', () {
      for (final d in barrioDestinations) {
        expect(d.audienceLabels, isNotEmpty,
            reason: '${d.id} should have audience labels');
        expect(d.label, isNotEmpty,
            reason: '${d.id} should have a label');
        expect(d.description, isNotEmpty,
            reason: '${d.id} should have a description');
      }
    });
  });

  // Route map

  group('Barrio route map', () {
    test('has a path for every destination', () {
      for (final d in barrioDestinations) {
        final path = BarrioRouteMap.pathFor(d);
        expect(path, isNot(BarrioRouteMap.home),
            reason: '${d.id} should have its own route path');
      }
    });

    test('screenFor returns the correct widget type for each destination', () {
      expect(BarrioRouteMap.screenFor('forge_and_flow'),
          isA<ForgeAndFlowDestinationScreen>());
      // 2026-07-11 word-for-word directive: the three original learning
      // destinations now render the verbatim training surface.
      expect(BarrioRouteMap.screenFor('company_handbook'),
          isA<TrainingDocScreen>());
      expect(BarrioRouteMap.screenFor('interview_playbook'),
          isA<TrainingDocScreen>());
      expect(BarrioRouteMap.screenFor('jim_taylor_labor_model'),
          isA<TrainingDocScreen>());
      expect(BarrioRouteMap.screenFor('preston_lee_model'),
          isA<PrestonLeeModelComingSoonScreen>());
      expect(BarrioRouteMap.screenFor('supervisor_content'),
          isA<SupervisorContentScreenPlaceholder>());
    });

    test('unknown destination falls back to home screen', () {
      expect(BarrioRouteMap.screenFor('nonexistent'),
          isA<BarrioHomeScreen>());
    });
  });

  // Widget tests
  //
  // The round-bubble home screen is calm now (the center bubble's glow
  // pulse + arcs were removed 2026-07-27, along with the earlier falling
  // leaves + colour-breathing scrim), so only the one-shot entrance
  // animates. This suite still uses explicit pumps, never pumpAndSettle.

  group('Barrio home screen widget', () {
    testWidgets('builds and shows the Barrio Legado wordmark', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: BarrioHomeScreen()),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // The wordmark is a RichText with "Barrio " + "Legado" spans
      expect(find.byType(RichText), findsWidgets);
      // BSP.2: the El Podio pill is hidden while
      // kBarrioShowElPodioEntry is false (hide-only; flag flip restores it).
      expect(find.text('EL PODIO'), findsNothing);
    });

    testWidgets('shows Coming Soon for Preston Lee Model', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: BarrioHomeScreen()),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // Preston Lee is marked comingSoon in the destination manifest
      final preston =
          barrioDestinations.firstWhere((d) => d.id == 'preston_lee_model');
      expect(preston.comingSoon, isTrue);
    });

    testWidgets('role preview switcher is hidden (BSP.2)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: BarrioHomeScreen()),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // BSP.2: the PREVIEW row is hidden while
      // kBarrioShowRolePreviewChips is false (hide-only; flag flip
      // restores it).
      expect(find.text('PREVIEW'), findsNothing);
    });
  });
}
