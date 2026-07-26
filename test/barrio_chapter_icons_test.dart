// Visual wayfinding icon maps + chips (visual-first pass, recs 2+5).
//
// Covers, in order:
//   1. Map hygiene: every routed doc id has a manual identity icon;
//      manual icons mirror the home shelf visuals one for one; every
//      curated chapter key exists in the routed corpus; corpus chapter
//      ids are globally unique (the id-keyed map depends on it); every
//      routed chapter resolves to a real (non-circle) icon.
//   2. Chapter rail: a generated manual's tiles render real icons (the
//      pre-slice behavior was Icons.circle_outlined on every generated
//      chapter), and the curated Company Handbook screen's code-point
//      icons still win unchanged.
//   3. Wayfinding chips: in-manual search rows show the hit's CHAPTER
//      icon; the cross-manual Quick refresher card and Saved rows show
//      the MANUAL icon; quiz checkpoint cards show their chapter icon
//      and render no bogus glyph for fixture docs.
//
// The home shelf runs looping ambient motion: NEVER pumpAndSettle in
// shelf tests; pump explicit durations only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_bookmarks_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_chapter_icons.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_quiz_checkpoint_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_chapter_rail.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_destination_visuals.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_search_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const phoneSize = Size(390, 844);

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('icon map hygiene', () {
    test('every routed doc id has a manual identity icon', () {
      for (final docId in kBarrioTrainingDocs.keys) {
        expect(kBarrioManualIcons.containsKey(docId), isTrue,
            reason: 'routed manual "$docId" is missing from '
                'kBarrioManualIcons: its chapters would fall back to '
                'circle_outlined');
      }
    });

    test('manual icons mirror the home shelf visuals one for one', () {
      for (final docId in kBarrioTrainingDocs.keys) {
        expect(kBarrioManualIcons[docId], barrioHomeIconFor(docId),
            reason: 'home and reader must agree on "$docId" '
                '(kBarrioManualIcons mirrors '
                'barrio_home_destination_visuals.dart)');
      }
    });

    test('corpus chapter ids are globally unique', () {
      final seen = <String>{};
      kBarrioTrainingDocs.forEach((docId, doc) {
        for (final chapter in doc.chapters) {
          expect(seen.add(chapter.id), isTrue,
              reason: 'chapter id "${chapter.id}" appears more than once '
                  'in the routed corpus; the id-keyed icon map would be '
                  'ambiguous');
        }
      });
    });

    test('every curated chapter key exists in the routed corpus', () {
      final corpusIds = <String>{
        for (final doc in kBarrioTrainingDocs.values)
          for (final chapter in doc.chapters) chapter.id,
      };
      for (final key in kBarrioChapterIcons.keys) {
        expect(corpusIds.contains(key), isTrue,
            reason: 'curated key "$key" matches no routed chapter '
                '(stale key or typo)');
      }
    });

    test('every chapter id derives its owning doc id', () {
      kBarrioTrainingDocs.forEach((docId, doc) {
        for (final chapter in doc.chapters) {
          expect(barrioDocIdOfChapter(chapter.id), docId,
              reason: 'chapter "${chapter.id}" must embed its doc id so '
                  'the manual-icon fallback can resolve');
        }
      });
    });

    test('every routed chapter resolves to a real icon (never the '
        'anonymous circle)', () {
      kBarrioTrainingDocs.forEach((docId, doc) {
        for (final chapter in doc.chapters) {
          expect(barrioChapterIconFor(chapter.id),
              isNot(equals(Icons.circle_outlined)),
              reason: 'chapter "${chapter.id}" of "$docId" fell through '
                  'both the curated map and the manual map');
        }
      });
    });
  });

  group('chapter rail icons', () {
    Future<void> pumpRail(
      WidgetTester tester,
      List<HandbookChapter> chapters,
    ) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: HandbookChapterRail(
              chapters: chapters,
              activeIndex: 0,
              completedChapterIds: const <String>{},
              activeAccent: Colors.amber,
              onChapterTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('generated-manual tiles render real icons, not the '
        'anonymous circle', (tester) async {
      final chapters = kBarrioTrainingDocs['training_coffee']!.chapters;
      await pumpRail(tester, chapters);

      // Uncurated title chapter falls back to the manual identity icon.
      expect(find.byIcon(Icons.local_cafe_rounded), findsOneWidget,
          reason: 'the uncurated "What Is Coffee" tile shows the Coffee '
              'manual icon');
      // Curated chapter shows its meaning-matched icon.
      expect(find.byIcon(Icons.local_fire_department), findsOneWidget,
          reason: 'the "Roasting" tile shows its curated icon');
      expect(find.byIcon(Icons.circle_outlined), findsNothing,
          reason: 'no generated chapter may render the generic circle');
      expect(tester.takeException(), isNull);
    });

    testWidgets('curated Company Handbook screen code-point icons still '
        'win', (tester) async {
      await pumpRail(tester, handbookChapters);

      expect(find.byIcon(Icons.restaurant_menu), findsOneWidget,
          reason: 'the original code-point lookup stays first in the '
              'fallback chain');
      expect(find.byIcon(Icons.circle_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('wayfinding chips', () {
    testWidgets('in-manual search rows show the hit chapter icon beside '
        'the chapter title', (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: TrainingDocSearchSheet(
              docId: 'training_coffee',
              accent: Colors.amber,
              onResultTap: (_, __) {},
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'roasting');
      // Ride out the ~200ms debounce, then rebuild with results.
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('training_doc_search_results')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.local_fire_department), findsWidgets,
          reason: 'hits in the "Roasting" chapter carry its curated '
              'chapter icon; the text label stays beside it');
      expect(find.byIcon(Icons.circle_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    });

    Future<void> pumpShelf(
      WidgetTester tester, {
      List<String> due = const <String>[],
      List<BarrioBookmark> bookmarks = const <BarrioBookmark>[],
    }) async {
      usePhoneViewport(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: BarrioHomeShelf(
              destinations:
                  barrioDestinations.where((d) => d.showOnHomeHub).toList(),
              refresherDueDocIds: due,
              bookmarks: bookmarks,
              onBookmarkOpen: bookmarks.isEmpty ? null : (_, __, ___) {},
              onDestinationTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));
    }

    testWidgets('the cross-manual Quick refresher card chip shows the due '
        'manual icon, not a generic refresh glyph', (tester) async {
      await pumpShelf(tester, due: const ['training_food_safety']);

      final card = find.byKey(const Key('barrio_refresher_card'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.health_and_safety_rounded),
        ),
        findsOneWidget,
        reason: 'the chip identifies WHICH manual is due; the QUICK '
            'REFRESHER kicker carries the refresh semantics in text',
      );
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.refresh_rounded)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('cross-manual Saved rows lead with the manual icon in the '
        'manual accent', (tester) async {
      await pumpShelf(
        tester,
        bookmarks: const [
          BarrioBookmark(
            docId: 'training_coffee',
            chapterIndex: 0,
            unitInChapter: 0,
          ),
        ],
      );

      final row = find.byKey(
        const ValueKey<String>('barrio_saved_training_coffee_0_0'),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.byIcon(Icons.local_cafe_rounded),
        ),
        findsOneWidget,
        reason: 'the Saved list is cross-manual, so each row leads with '
            'its manual identity icon; the manual name text stays too',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('quiz checkpoint cards show their chapter icon in the '
        'header', (tester) async {
      usePhoneViewport(tester);
      final question = kBarrioQuizBanks['training_food_safety']!.questions
          .firstWhere((q) => kBarrioChapterIcons.containsKey(q.chapterId));
      final expectedIcon = kBarrioChapterIcons[question.chapterId]!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SingleChildScrollView(
              child: BarrioQuizCheckpointCard(
                question: question,
                selectedIndex: null,
                onOptionSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(expectedIcon), findsOneWidget,
          reason: 'the header ties the checkpoint to the chapter it '
              'quizzes');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a fixture-doc quiz card renders no bogus wayfinding '
        'glyph', (tester) async {
      usePhoneViewport(tester);
      const fixtureQuestion = BarrioQuizQuestion(
        id: 'fixture_q1',
        docId: 'fixture_doc',
        chapterId: 'fixture_doc_c0',
        prompt: 'Fixture prompt?',
        options: ['One', 'Two', 'Three'],
        correctIndex: 0,
        whyLine: 'Fixture why line.',
        sourceUnitId: 'fixture_u1',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SingleChildScrollView(
              child: BarrioQuizCheckpointCard(
                question: fixtureQuestion,
                selectedIndex: null,
                onOptionSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Unanswered checkpoint cards render no Icon widgets at all, so
      // an unresolvable doc/chapter must add none either.
      expect(find.byType(Icon), findsNothing,
          reason: 'unknown fixture ids must render nothing rather than '
              'a wrong icon');
      expect(tester.takeException(), isNull);
    });
  });
}
