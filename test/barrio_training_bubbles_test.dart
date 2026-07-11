// Training-drop slice (2026-07-11): 10 verbatim training bubbles.
//
// Pins: (1) registry/destination/route wiring integrity, (2) verbatim
// content shape (explainer-only, non-empty bodies), (3) the dense hub
// renders every training bubble as a tappable node, (4) TrainingDocScreen
// renders verbatim source text and chapter navigation works.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_route_map.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_bubble_hub.dart';

void main() {
  group('training registry wiring', () {
    test('every training doc has a destination, route path, and accent', () {
      final destinationIds = barrioDestinations.map((d) => d.id).toSet();
      for (final id in kBarrioTrainingDocs.keys) {
        expect(destinationIds, contains(id),
            reason: '$id needs a BarrioDestination entry');
        expect(BarrioRouteMap.destinationPaths, contains(id),
            reason: '$id needs a route path');
        expect(kBarrioTrainingAccents, contains(id),
            reason: '$id needs an accent color');
      }
    });

    test('training destinations appear on the home hub as secondary bubbles',
        () {
      for (final id in kBarrioTrainingDocs.keys) {
        final dest = barrioDestinations.firstWhere((d) => d.id == id);
        expect(dest.showOnHomeHub, isTrue, reason: '$id must be a bubble');
        expect(dest.prominence, BarrioProminence.secondary,
            reason: '$id must be an orbit bubble, not primary');
        expect(dest.comingSoon, isFalse,
            reason: '$id ships live, not coming soon');
      }
    });

    test('screenFor builds a TrainingDocScreen for every training id', () {
      for (final id in kBarrioTrainingDocs.keys) {
        expect(BarrioRouteMap.screenFor(id), isA<TrainingDocScreen>(),
            reason: '$id must route to the training surface');
      }
      // Unknown ids still fall back to home, not a training screen.
      expect(BarrioRouteMap.screenFor('nonexistent'),
          isNot(isA<TrainingDocScreen>()));
    });

    test('verbatim docs are explainer-only with non-empty titles and bodies',
        () {
      for (final doc in kBarrioTrainingDocs.values) {
        expect(doc.chapters, isNotEmpty, reason: '${doc.id} has chapters');
        for (final chapter in doc.chapters) {
          expect(chapter.units, isNotEmpty,
              reason: '${doc.id}/${chapter.id} has units');
          for (final unit in chapter.units) {
            expect(unit.type, HandbookUnitType.explainer,
                reason: 'verbatim content carries no quiz/decision units');
            expect(unit.title.trim(), isNotEmpty);
            expect(unit.body.trim(), isNotEmpty);
            expect(unit.body, isNot(contains('—')),
                reason: 'no em dash in operator-facing copy');
          }
        }
      }
    });
  });

  group('dense home hub', () {
    testWidgets('renders all training bubbles as tappable orbit nodes',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hubDestinations =
          barrioDestinations.where((d) => d.showOnHomeHub).toList();
      BarrioDestination? tapped;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 760,
                height: 1000,
                child: BarrioBubbleHub(
                  destinations: hubDestinations,
                  onDestinationTap: (d) => tapped = d,
                ),
              ),
            ),
          ),
        ),
      );

      // Let the one-shot entrance bloom finish.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      for (final id in kBarrioTrainingDocs.keys) {
        final dest = hubDestinations.firstWhere((d) => d.id == id);
        expect(find.text(dest.label), findsOneWidget,
            reason: '${dest.label} bubble must render');
      }

      await tester.tap(find.text('Tequila'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tapped?.id, 'training_tequila');

      // Dispose the hub so its idle timer cannot leak.
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('TrainingDocScreen', () {
    testWidgets('renders verbatim source text and switches chapters',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final doc = kBarrioTrainingDocs['training_tequila']!;
      await tester.pumpWidget(
        MaterialApp(
          home: TrainingDocScreen(
            doc: doc,
            accent: kBarrioTrainingAccents['training_tequila']!,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));

      // Doc title in the app bar and honest section position in the hero.
      expect(find.text('Tequila Training'), findsWidgets);
      expect(find.text('SECTION 1 OF ${doc.chapters.length}'), findsOneWidget);

      // A verbatim phrase from the source document body renders.
      expect(
        find.textContaining(
            'one of the most highly regulated alcoholic beverages'),
        findsOneWidget,
      );

      // Tap the second chapter in the rail and confirm the hero follows.
      final secondChapter = doc.chapters[1];
      await tester.tap(find.text(secondChapter.title).first);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('SECTION 2 OF ${doc.chapters.length}'), findsOneWidget);
    });
  });
}
