// Visual-first pass, rec #9: browse-layer list rows that point to a
// card WITH an image lead with a small rounded photo thumbnail of that
// card IN PLACE OF the wayfinding icon, so a visual learner recognizes
// the target before tapping. A row whose target card has NO image keeps
// its existing icon exactly (Metric Honesty: no placeholder or stock
// art is ever invented for an imageless row).
//
// Covers all three surfaces (each in both branches) plus the pure
// resolver and index-entry asset wiring:
//   1. In-manual search results (training_doc_search_sheet.dart)
//   2. A-Z term index rows (training_doc_index_sheet.dart)
//   3. Home Saved (bookmark) rows (barrio_home_shelf.dart)
//
// Widget tests run at 390x844 and have no bundled assets, so every
// thumbnail exercises the Image.asset errorBuilder path (same as the
// other Barrio image suites). Rows are located by widget TYPE, never by
// a loaded bitmap, so asset availability never decides a result.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_bookmarks_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_chapter_icons.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_row_thumbnail.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_index_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_search_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kDishes = 'training_latin_dishes';
const _kIngredients = 'training_latin_ingredients';
const _kWords = 'training_general_words';
const _kTequila = 'training_tequila';

/// A resolved coordinate: chapter index, unit index within the chapter,
/// and the unit itself.
typedef _Coord = ({int chapterIndex, int unitIndex, HandbookUnit unit});

_Coord? _firstUnit(BarrioTrainingDoc doc, bool Function(HandbookUnit u) test) {
  for (var c = 0; c < doc.chapters.length; c++) {
    final units = doc.chapters[c].units;
    for (var u = 0; u < units.length; u++) {
      if (test(units[u])) {
        return (chapterIndex: c, unitIndex: u, unit: units[u]);
      }
    }
  }
  return null;
}

bool _isCont(HandbookUnit u) => u.title.contains('(cont.)');

void main() {
  const phoneSize = Size(390, 844);

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // -------------------------------------------------------------------
  // Pure: coordinate -> first image resolver.
  // -------------------------------------------------------------------
  group('barrioUnitFirstImageAt (pure)', () {
    test('returns the card first image for an image-bearing coordinate, '
        'null for an imageless one', () {
      final dishes = kBarrioTrainingDocs[_kDishes]!;
      final imaged =
          _firstUnit(dishes, (u) => u.firstPhoto != null && !_isCont(u));
      // Full diagram coverage (2026-07-30) gives every reading card a visual,
      // but browse thumbnails are PHOTO-only: a diagram-only card carries no
      // photo, so it resolves null here exactly like a bare card once did.
      // Scan all docs for the first photo-less (non-cont) card.
      String? plainDoc;
      _Coord? plain;
      for (final entry in kBarrioTrainingDocs.entries) {
        final c =
            _firstUnit(entry.value, (u) => u.firstPhoto == null && !_isCont(u));
        if (c != null) {
          plainDoc = entry.key;
          plain = c;
          break;
        }
      }
      expect(imaged, isNotNull,
          reason: 'sanity: the dishes glossary has photo-bearing cards');
      expect(plain, isNotNull,
          reason: 'sanity: at least one manual has a photo-less card');

      expect(
        barrioUnitFirstImageAt(
            _kDishes, imaged!.chapterIndex, imaged.unitIndex),
        imaged.unit.images.first.assetPath,
        reason: 'an image-bearing coordinate resolves to its first photo',
      );
      expect(
        barrioUnitFirstImageAt(plainDoc!, plain!.chapterIndex, plain.unitIndex),
        isNull,
        reason: 'an imageless coordinate resolves to null (no stock art)',
      );
    });

    test('every card of the imageless Words To Know manual resolves null',
        () {
      final words = kBarrioTrainingDocs[_kWords]!;
      for (var c = 0; c < words.chapters.length; c++) {
        for (var u = 0; u < words.chapters[c].units.length; u++) {
          expect(barrioUnitFirstImageAt(_kWords, c, u), isNull);
        }
      }
    });

    test('out-of-range coordinates and unknown docs resolve null', () {
      expect(barrioUnitFirstImageAt('no_such_doc', 0, 0), isNull);
      expect(barrioUnitFirstImageAt(_kDishes, 999, 0), isNull);
      expect(barrioUnitFirstImageAt(_kDishes, 0, 999), isNull);
      expect(barrioUnitFirstImageAt(_kDishes, -1, 0), isNull);
    });
  });

  // -------------------------------------------------------------------
  // Pure: A-Z index entries carry the term's first photo when the run
  // has one, and null otherwise (invariant vs. the photo-grid entries).
  // -------------------------------------------------------------------
  group('buildTrainingIndexGroups assetPath (pure)', () {
    test('the set of image-bearing A-Z entries matches the photo entries '
        'exactly, path for path; imageless entries carry null', () {
      for (final docId in <String>[_kDishes, _kIngredients, _kWords]) {
        final doc = kBarrioTrainingDocs[docId]!;
        final azEntries = [
          for (final g in buildTrainingIndexGroups(doc)) ...g.entries,
        ];
        final photoEntries = buildTrainingIndexPhotoEntries(doc);
        final photoAssetByTitle = {
          for (final e in photoEntries) e.title: e.assetPath,
        };

        for (final entry in azEntries) {
          if (photoAssetByTitle.containsKey(entry.title)) {
            expect(entry.assetPath, photoAssetByTitle[entry.title],
                reason: '$docId: ${entry.title} carries the same photo the '
                    'grid shows');
          } else {
            expect(entry.assetPath, isNull,
                reason: '$docId: ${entry.title} has no photo, so its A-Z '
                    'row stays plain text');
          }
        }

        final azImagedTitles = {
          for (final e in azEntries)
            if (e.assetPath != null) e.title,
        };
        expect(azImagedTitles, photoAssetByTitle.keys.toSet(),
            reason: '$docId: exactly the photo-backed terms carry a '
                'thumbnail asset');
      }
    });
  });

  // -------------------------------------------------------------------
  // Surface 1: in-manual search results.
  // -------------------------------------------------------------------
  group('search result rows (rec #9)', () {
    Future<void> pumpSearch(WidgetTester tester, String docId) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrainingDocSearchSheet(
              docId: docId,
              accent: const Color(0xFFE0A030),
              onResultTap: (_, __) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder rowKey(String docId, int chapterIndex, int unitIndex) =>
        find.byKey(ValueKey<String>(
          'training_doc_search_row_${docId}_${chapterIndex}_$unitIndex',
        ));

    Future<void> scrollToRow(WidgetTester tester, Finder row) async {
      final results = find
          .byKey(const ValueKey<String>('training_doc_search_results'));
      await tester.scrollUntilVisible(
        row,
        120,
        scrollable:
            find.descendant(of: results, matching: find.byType(Scrollable))
                .first,
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('a hit whose card has a photo leads with a thumbnail, not '
        'the chapter icon', (tester) async {
      usePhone(tester);
      final dishes = kBarrioTrainingDocs[_kDishes]!;
      final imaged =
          _firstUnit(dishes, (u) => u.firstPhoto != null && !_isCont(u))!;

      await pumpSearch(tester, _kDishes);
      await tester.enterText(find.byType(TextField), imaged.unit.title);
      await tester.pump(const Duration(milliseconds: 250));

      final row = rowKey(_kDishes, imaged.chapterIndex, imaged.unitIndex);
      await scrollToRow(tester, row);

      expect(row, findsOneWidget, reason: 'the matched card renders a row');
      expect(
        find.descendant(of: row, matching: find.byType(BarrioRowThumbnail)),
        findsOneWidget,
        reason: 'the image-bearing hit leads with a photo thumbnail',
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byIcon(
              barrioChapterIconAt(_kDishes, imaged.chapterIndex)),
        ),
        findsNothing,
        reason: 'the thumbnail stands IN PLACE OF the chapter icon',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a hit whose card has no photo keeps the chapter icon and '
        'shows no thumbnail (Metric Honesty)', (tester) async {
      usePhone(tester);
      final words = kBarrioTrainingDocs[_kWords]!;
      final plain = _firstUnit(
        words,
        (u) => RegExp(r'^[A-Za-z]{4,}$').hasMatch(u.title.trim()),
      )!;

      await pumpSearch(tester, _kWords);
      await tester.enterText(find.byType(TextField), plain.unit.title.trim());
      await tester.pump(const Duration(milliseconds: 250));

      final row = rowKey(_kWords, plain.chapterIndex, plain.unitIndex);
      await scrollToRow(tester, row);

      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(BarrioRowThumbnail)),
        findsNothing,
        reason: 'an imageless hit never invents a thumbnail',
      );
      expect(
        find.descendant(
          of: row,
          matching:
              find.byIcon(barrioChapterIconAt(_kWords, plain.chapterIndex)),
        ),
        findsOneWidget,
        reason: 'the imageless hit keeps its wayfinding icon exactly',
      );
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------
  // Surface 2: A-Z term index rows.
  // -------------------------------------------------------------------
  group('A-Z index rows (rec #9)', () {
    Future<void> pumpIndex(WidgetTester tester, String docId) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrainingDocIndexSheet(
              doc: kBarrioTrainingDocs[docId]!,
              accent: const Color(0xFFE0A030),
              onEntryTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    final list = find.byKey(const ValueKey<String>('training_doc_index_list'));

    testWidgets('a term whose card has a photo leads its row with a '
        'thumbnail', (tester) async {
      usePhone(tester);
      final doc = kBarrioTrainingDocs[_kDishes]!;
      final imagedEntry = [
        for (final g in buildTrainingIndexGroups(doc)) ...g.entries,
      ].firstWhere((e) => e.assetPath != null);

      await pumpIndex(tester, _kDishes);
      final termText =
          find.descendant(of: list, matching: find.text(imagedEntry.title));
      await tester.scrollUntilVisible(
        termText,
        150,
        scrollable:
            find.descendant(of: list, matching: find.byType(Scrollable))
                .first,
      );
      await tester.pump(const Duration(milliseconds: 50));

      final row =
          find.ancestor(of: termText, matching: find.byType(GestureDetector))
              .first;
      expect(
        find.descendant(of: row, matching: find.byType(BarrioRowThumbnail)),
        findsOneWidget,
        reason: 'the photo-backed term row leads with its thumbnail',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the fully imageless Words To Know index shows plain text '
        'rows and never a thumbnail', (tester) async {
      usePhone(tester);
      final doc = kBarrioTrainingDocs[_kWords]!;
      final firstEntry = [
        for (final g in buildTrainingIndexGroups(doc)) ...g.entries,
      ].first;

      await pumpIndex(tester, _kWords);
      expect(list, findsOneWidget);
      // No A-Z row in a photo-free manual ever renders a thumbnail.
      expect(
        find.descendant(of: list, matching: find.byType(BarrioRowThumbnail)),
        findsNothing,
        reason: 'Words To Know has zero card photos, so zero thumbnails',
      );
      // The plain text row still renders and is tappable.
      expect(
        find.descendant(of: list, matching: find.text(firstEntry.title)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------
  // Surface 3: home Saved (bookmark) rows.
  // -------------------------------------------------------------------
  group('home Saved rows (rec #9)', () {
    testWidgets('a saved card with a photo leads with a thumbnail; a saved '
        'card without one keeps the manual icon', (tester) async {
      usePhone(tester);
      final dishes = kBarrioTrainingDocs[_kDishes]!;
      final imaged =
          _firstUnit(dishes, (u) => u.firstPhoto != null && !_isCont(u))!;
      final tequila = kBarrioTrainingDocs[_kTequila]!;
      // A card with no PHOTO (tequila's last bare card now carries a
      // diagram, which is never a browse thumbnail) keeps the manual icon.
      final plain = _firstUnit(tequila, (u) => u.firstPhoto == null)!;
      expect(plain.unit.firstPhoto, isNull,
          reason: 'sanity: this tequila card has no photo');

      final imagedBookmark = BarrioBookmark(
        docId: _kDishes,
        chapterIndex: imaged.chapterIndex,
        unitInChapter: imaged.unitIndex,
      );
      final plainBookmark = BarrioBookmark(
        docId: _kTequila,
        chapterIndex: plain.chapterIndex,
        unitInChapter: plain.unitIndex,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: BarrioHomeShelf(
              destinations:
                  barrioDestinations.where((d) => d.showOnHomeHub).toList(),
              onDestinationTap: (_) {},
              bookmarks: <BarrioBookmark>[imagedBookmark, plainBookmark],
              onBookmarkOpen: (_, __, ___) {},
              onBookmarkRemove: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));

      expect(find.text('Saved'), findsOneWidget);

      final imagedRow = find.byKey(ValueKey<String>(
        'barrio_saved_${_kDishes}_${imaged.chapterIndex}_${imaged.unitIndex}',
      ));
      final plainRow = find.byKey(ValueKey<String>(
        'barrio_saved_${_kTequila}_${plain.chapterIndex}_${plain.unitIndex}',
      ));
      expect(imagedRow, findsOneWidget);
      expect(plainRow, findsOneWidget);

      // Image-bearing saved card: thumbnail present, manual icon gone.
      expect(
        find.descendant(
            of: imagedRow, matching: find.byType(BarrioRowThumbnail)),
        findsOneWidget,
        reason: 'the saved card with a photo leads with its thumbnail',
      );
      expect(
        find.descendant(
          of: imagedRow,
          matching: find.byIcon(barrioManualIconOrNull(_kDishes)!),
        ),
        findsNothing,
        reason: 'the thumbnail stands IN PLACE OF the manual icon',
      );

      // Imageless saved card: manual icon present, no thumbnail.
      expect(
        find.descendant(
            of: plainRow, matching: find.byType(BarrioRowThumbnail)),
        findsNothing,
        reason: 'a saved card without a photo never invents a thumbnail',
      );
      expect(
        find.descendant(
          of: plainRow,
          matching: find.byIcon(barrioManualIconOrNull(_kTequila)!),
        ),
        findsOneWidget,
        reason: 'the imageless saved row keeps its manual wayfinding icon',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
