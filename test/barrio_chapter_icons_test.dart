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
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_bookmarks_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_chapter_icons.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_quiz_checkpoint_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_row_thumbnail.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_chapter_rail.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_destination_visuals.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_search_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Photo-less fixtures are chosen at RUNTIME, never hard-coded.
//
// Picture coverage is content, and it changes every build: the real-photo
// passes keep turning previously imageless cards into photo cards, and a
// photo card leads its browse row with a thumbnail INSTEAD of the
// wayfinding icon. Any fixture that hard-codes "this manual/card has no
// picture" therefore rots the moment that card gets a photograph (it did,
// twice, in builds 30 and 32). The helpers below walk the routed corpus
// for a card that is genuinely photo-less today and fail loudly if the
// corpus no longer has one. Note that a diagram pictogram is not a photo
// (HandbookUnitPhotos.isDiagram keys on the 'Diagram: ' caption prefix),
// so a diagram-only card still counts as photo-less and still shows the
// icon.

/// A photo-less card that a home Saved row can point at: its manual is on
/// the home shelf and has an identity icon, so the row's icon branch is
/// the one under test.
class _ImagelessSavedCard {
  final String docId;
  final int chapterIndex;
  final int unitIndex;
  final IconData manualIcon;

  const _ImagelessSavedCard({
    required this.docId,
    required this.chapterIndex,
    required this.unitIndex,
    required this.manualIcon,
  });

  ValueKey<String> get rowKey =>
      ValueKey<String>('barrio_saved_${docId}_${chapterIndex}_$unitIndex');
}

/// First photo-less card, scanning the home-shelf manuals in shelf order.
_ImagelessSavedCard _findImagelessSavedCard(
  List<BarrioDestination> shelfDestinations,
) {
  for (final dest in shelfDestinations) {
    final doc = kBarrioTrainingDocs[dest.id];
    if (doc == null) continue;
    final manualIcon = barrioManualIconOrNull(dest.id);
    if (manualIcon == null) continue;
    for (var c = 0; c < doc.chapters.length; c++) {
      final units = doc.chapters[c].units;
      for (var u = 0; u < units.length; u++) {
        if (units[u].firstPhoto != null) continue;
        return _ImagelessSavedCard(
          docId: dest.id,
          chapterIndex: c,
          unitIndex: u,
          manualIcon: manualIcon,
        );
      }
    }
  }
  fail('no photo-less card exists in any home-shelf manual, so the Saved '
      'row icon branch cannot be exercised: either every card now carries '
      'a photograph (delete this test and its branch) or the corpus/shelf '
      'wiring broke');
}

/// A search query whose TOP in-manual hit is a photo-less card, plus the
/// chapter icon that hit must lead with.
class _ImagelessSearchHit {
  final String docId;
  final String query;
  final int chapterIndex;
  final int unitIndex;
  final String chapterTitle;
  final IconData chapterIcon;

  const _ImagelessSearchHit({
    required this.docId,
    required this.query,
    required this.chapterIndex,
    required this.unitIndex,
    required this.chapterTitle,
    required this.chapterIcon,
  });

  ValueKey<String> get rowKey => ValueKey<String>(
      'training_doc_search_row_${docId}_${chapterIndex}_$unitIndex');
}

/// First card whose own title, searched inside its own manual, ranks that
/// card FIRST. Insisting on the top hit keeps the row inside the sheet's
/// opening viewport, so the test never has to scroll a lazy list.
_ImagelessSearchHit _findImagelessTopSearchHit() {
  for (final entry in kBarrioTrainingDocs.entries) {
    final docId = entry.key;
    for (var c = 0; c < entry.value.chapters.length; c++) {
      final units = entry.value.chapters[c].units;
      for (var u = 0; u < units.length; u++) {
        if (units[u].firstPhoto != null) continue;
        final query = units[u].title.trim();
        if (query.length < BarrioTrainingSearch.kMinQueryLength) continue;
        final results = BarrioTrainingSearch.search(
          query,
          isDestinationAllowed: (id) => id == docId,
        );
        if (results.isEmpty) continue;
        final top = results.first;
        if (top.chapterIndex != c || top.unitIndex != u) continue;
        return _ImagelessSearchHit(
          docId: docId,
          query: query,
          chapterIndex: c,
          unitIndex: u,
          chapterTitle: top.chapterTitle,
          chapterIcon: barrioChapterIconAt(docId, c),
        );
      }
    }
  }
  fail('no photo-less card in the routed corpus ranks first for its own '
      'title, so the in-manual search icon branch cannot be exercised: '
      'either every card now carries a photograph (delete this test and '
      'its branch) or search ranking changed');
}

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
      // Runtime fixture (see the header note): a hit whose card carries a
      // photo leads with a thumbnail instead of the icon, so the branch
      // under test needs a card that is photo-less TODAY.
      final hit = _findImagelessTopSearchHit();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: TrainingDocSearchSheet(
              docId: hit.docId,
              accent: Colors.amber,
              onResultTap: (_, __) {},
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), hit.query);
      // Ride out the ~200ms debounce, then rebuild with results.
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('training_doc_search_results')),
        findsOneWidget,
      );
      final row = find.byKey(hit.rowKey);
      expect(row, findsOneWidget,
          reason: 'the photo-less card must be the top hit for its own '
              'title: "${hit.query}" in ${hit.docId}');
      expect(
        find.descendant(of: row, matching: find.byType(BarrioRowThumbnail)),
        findsNothing,
        reason: 'the fixture is photo-less by construction, so nothing may '
            'lead the row with a picture',
      );
      final icon = find.descendant(
        of: row,
        matching: find.byIcon(hit.chapterIcon),
      );
      expect(icon, findsOneWidget,
          reason: 'an imageless hit carries its curated chapter icon');
      // The icon never replaces the chapter title: both sit in one kicker
      // row, so the shape and the words carry the signal together.
      final kicker =
          find.ancestor(of: icon, matching: find.byType(Row)).first;
      expect(find.descendant(of: kicker, matching: find.text(hit.chapterTitle)),
          findsOneWidget);
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

    testWidgets('cross-manual Saved rows for an imageless card lead with '
        'the manual icon in the manual accent', (tester) async {
      // Runtime fixture (see the header note): this row exercises the
      // manual-icon fallback branch, which only renders for a card with
      // no photo. A saved card WITH a photo leads with a thumbnail
      // instead (visual-first pass, rec #9); that branch is covered in
      // barrio_visual_thumbnails_test.dart.
      final saved = _findImagelessSavedCard(
        barrioDestinations.where((d) => d.showOnHomeHub).toList(),
      );
      await pumpShelf(
        tester,
        bookmarks: [
          BarrioBookmark(
            docId: saved.docId,
            chapterIndex: saved.chapterIndex,
            unitInChapter: saved.unitIndex,
          ),
        ],
      );

      final row = find.byKey(saved.rowKey);
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(BarrioRowThumbnail)),
        findsNothing,
        reason: 'the fixture is photo-less by construction, so nothing may '
            'lead the row with a picture',
      );
      expect(
        find.descendant(of: row, matching: find.byIcon(saved.manualIcon)),
        findsOneWidget,
        reason: 'the Saved list is cross-manual, so an imageless row leads '
            'with its manual identity icon; the manual name text stays too',
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
