// Widget + pure tests for the index sheet's photo-grid browse view
// (visual-first pass, rec #4): the two food glossaries get an
// "A to Z" / "Photos" toggle; Photos is a two-column grid of the
// cards' own bundled pictures with the term on a solid strip; tapping
// a tile jumps to the card exactly like the A-Z row does. Manuals
// without card photos (Words To Know) show no toggle at all.
//
// All widget tests run at a 390x844 phone viewport and assert
// takeException() is null (overflow guard). Widget tests have no
// bundled assets, so every tile exercises the Image.asset errorBuilder
// path, same as the other Barrio image suites.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_training_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_index_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kIndexLabel = 'Jump to a term';

const _kPhotoGlossaryIds = <String>[
  'training_latin_dishes',
  'training_latin_ingredients',
];

final _kAzToggle = find.byKey(const ValueKey<String>(
  'training_doc_index_view_az',
));
final _kPhotosToggle = find.byKey(const ValueKey<String>(
  'training_doc_index_view_photos',
));
final _kAzList = find.byKey(const ValueKey<String>(
  'training_doc_index_list',
));
final _kPhotoGrid = find.byKey(const ValueKey<String>(
  'training_doc_index_photo_grid',
));

List<HandbookUnit> _flatUnitsOf(BarrioTrainingDoc doc) =>
    [for (final c in doc.chapters) ...c.units];

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpDoc(WidgetTester tester, String docId) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: kBarrioTrainingDocs[docId]!)),
    );
    // Restore setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  Future<void> openIndexSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip(_kIndexLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  group('photo-grid toggle visibility', () {
    testWidgets('the two food glossaries carry the A to Z / Photos toggle '
        'and open on the complete A to Z list', (tester) async {
      for (final docId in _kPhotoGlossaryIds) {
        await pumpDoc(tester, docId);
        await openIndexSheet(tester);

        expect(_kAzToggle, findsOneWidget,
            reason: '$docId carries the A to Z toggle pill');
        expect(_kPhotosToggle, findsOneWidget,
            reason: '$docId carries the Photos toggle pill');
        expect(_kAzList, findsOneWidget,
            reason: '$docId opens on the default A to Z list');
        expect(_kPhotoGrid, findsNothing,
            reason: '$docId shows no grid until Photos is chosen');
        expect(tester.takeException(), isNull);

        // Dismiss the sheet before the next iteration: pumpWidget only
        // swaps the home, so an open sheet route would linger on the
        // navigator stack and obscure the next manual's header.
        await tester.tapAt(const Offset(195, 40)); // barrier above sheet
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(_kAzList, findsNothing, reason: 'the sheet is gone');
      }
    });

    testWidgets('Words To Know (photos on too few cards) shows no toggle '
        'and keeps the plain A to Z sheet', (tester) async {
      // Precondition keeps the test self-validating. Build 32 gave this
      // manual real photographs on some cards, but a photo browse is only
      // honest once at least half the terms carry one, so the toggle must
      // still stay away: a grid of mostly blanks would teach nothing.
      final doc = kBarrioTrainingDocs['training_general_words']!;
      final termCount = buildTrainingIndexGroups(doc)
          .fold<int>(0, (sum, g) => sum + g.entries.length);
      final photoCount = buildTrainingIndexPhotoEntries(doc).length;
      expect(photoCount, greaterThan(0),
          reason: 'sanity: the manual does carry some card photos');
      expect(photoCount * 2, lessThan(termCount),
          reason: 'sanity: coverage is under the half-the-terms bar '
              '($photoCount of $termCount)');
      expect(trainingDocHasPhotoBrowse(doc), isFalse);

      await pumpDoc(tester, 'training_general_words');
      await openIndexSheet(tester);

      expect(_kAzToggle, findsNothing);
      expect(_kPhotosToggle, findsNothing);
      expect(_kAzList, findsOneWidget,
          reason: 'the complete A to Z list still renders');
      expect(tester.takeException(), isNull);
    });
  });

  group('Photos grid', () {
    testWidgets('choosing Photos swaps in the two-column grid of '
        'image tiles with their term labels; A to Z swaps back',
        (tester) async {
      final doc = kBarrioTrainingDocs['training_latin_dishes']!;
      final entries = buildTrainingIndexPhotoEntries(doc);
      expect(entries, isNotEmpty,
          reason: 'sanity: the dishes glossary has photo entries');

      await pumpDoc(tester, 'training_latin_dishes');
      await openIndexSheet(tester);

      await tester.tap(_kPhotosToggle);
      await tester.pump();

      expect(_kPhotoGrid, findsOneWidget);
      expect(_kAzList, findsNothing,
          reason: 'the grid replaces the list, one view at a time');
      // The first two entries share the grid's top row (2 columns):
      // each tile renders its image widget and its label text.
      for (final entry in entries.take(2)) {
        expect(
          find.descendant(of: _kPhotoGrid, matching: find.text(entry.title)),
          findsOneWidget,
          reason: 'tile for ${entry.title} shows its label strip',
        );
      }
      expect(
        find.descendant(of: _kPhotoGrid, matching: find.byType(Image)),
        findsWidgets,
        reason: 'tiles carry the bundled card image widget',
      );
      expect(
        find.text('${entries.length} photos'),
        findsOneWidget,
        reason: 'the header count states the visible view honestly',
      );

      await tester.tap(_kAzToggle);
      await tester.pump();
      expect(_kAzList, findsOneWidget);
      expect(_kPhotoGrid, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a photo tile closes the sheet and jumps the '
        'deck to that term\'s card, exactly like the A-Z row',
        (tester) async {
      final doc = kBarrioTrainingDocs['training_latin_dishes']!;
      final deck = buildTrainingDeck(doc);
      final entries = buildTrainingIndexPhotoEntries(doc);
      // Pick a top-row tile that is NOT the landing card, so the
      // footer proves a real jump happened.
      final entry = entries
          .take(2)
          .firstWhere((e) => deck.deckPageForContentPage(e.page) != 0);
      final targetDeckPage = deck.deckPageForContentPage(entry.page);

      await pumpDoc(tester, 'training_latin_dishes');
      await openIndexSheet(tester);
      await tester.tap(_kPhotosToggle);
      await tester.pump();

      await tester.tap(
        find.descendant(of: _kPhotoGrid, matching: find.text(entry.title)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(_kPhotoGrid, findsNothing, reason: 'the sheet is gone');
      expect(
        find.text('${targetDeckPage + 1} of ${deck.length}'),
        findsOneWidget,
        reason: 'the deck lands on the tapped term\'s own card',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('buildTrainingIndexPhotoEntries (pure)', () {
    test('entries carry only photo-backed terms, sorted like the A-Z '
        'index, jumping to the same pages as their A-Z entries', () {
      for (final docId in _kPhotoGlossaryIds) {
        final doc = kBarrioTrainingDocs[docId]!;
        final flatUnits = _flatUnitsOf(doc);
        final entries = buildTrainingIndexPhotoEntries(doc);
        final azEntries = [
          for (final g in buildTrainingIndexGroups(doc)) ...g.entries,
        ];
        final azPageByTitle = {for (final e in azEntries) e.title: e.page};

        expect(entries, isNotEmpty, reason: '$docId has photo entries');
        expect(entries.length, lessThanOrEqualTo(azEntries.length),
            reason: '$docId: the A-Z list stays the complete index');
        for (final entry in entries) {
          expect(entry.title.endsWith('(cont.)'), isFalse,
              reason: '$docId: runs fold once under the base title');
          expect(azPageByTitle[entry.title], entry.page,
              reason: '$docId: ${entry.title} jumps exactly where its '
                  'A-Z entry jumps');
          expect(entry.assetPath, isNotEmpty);
          // The photo really belongs to this term's own cards (any
          // card whose folded base title matches the entry).
          final foldedTitle = BarrioTrainingSearch.fold(entry.title);
          final runPaths = <String>{
            for (final u in flatUnits)
              if (BarrioTrainingSearch.fold(u.title
                      .replaceFirst(RegExp(r'\s*\(cont\.\)\s*$'), '')
                      .trim()) ==
                  foldedTitle)
                for (final i in u.images) i.assetPath,
          };
          expect(runPaths, contains(entry.assetPath),
              reason: '$docId: ${entry.title} shows its own card photo');
        }

        final folded = [
          for (final e in entries) BarrioTrainingSearch.fold(e.title),
        ];
        expect(folded, orderedEquals([...folded]..sort()),
            reason: '$docId: photo entries are alphabetical after folding');
      }
    });

    test('a term without any picture is absent from the photo entries '
        'but present in the A-Z index', () {
      for (final docId in _kPhotoGlossaryIds) {
        final doc = kBarrioTrainingDocs[docId]!;
        final entries = buildTrainingIndexPhotoEntries(doc);
        final photoTitles = {for (final e in entries) e.title};
        final azTitles = {
          for (final g in buildTrainingIndexGroups(doc))
            for (final e in g.entries) e.title,
        };
        expect(photoTitles.difference(azTitles), isEmpty,
            reason: '$docId: every photo entry is also an A-Z entry');
        // Every A-Z-only title genuinely has no image on any card of
        // its run (no placeholder art was invented, none dropped).
        final flatUnits = _flatUnitsOf(doc);
        final imagedFoldedBases = <String>{
          for (final u in flatUnits)
            if (u.images.isNotEmpty)
              BarrioTrainingSearch.fold(u.title
                  .replaceFirst(RegExp(r'\s*\(cont\.\)\s*$'), '')
                  .trim()),
        };
        for (final title in azTitles.difference(photoTitles)) {
          expect(
            imagedFoldedBases,
            isNot(contains(BarrioTrainingSearch.fold(title))),
            reason: '$docId: $title has no card photo, so it is '
                'absent from the grid by design',
          );
        }
      }
    });

    test('a manual whose cards carry only diagrams yields zero photo '
        'entries', () {
      // Located at runtime: which manuals hold photographs is content that
      // changes, so the diagram-only path is exercised by whichever manual
      // currently qualifies rather than by a hard-coded name.
      final diagramOnly = kBarrioTrainingDocs.values.where((doc) => [
            for (final c in doc.chapters)
              for (final u in c.units) ...u.images,
          ].isNotEmpty && [
            for (final c in doc.chapters)
              for (final u in c.units)
                if (u.firstPhoto != null) u,
          ].isEmpty);
      expect(diagramOnly, isNotEmpty,
          reason: 'sanity: at least one manual is still diagram-only');
      for (final doc in diagramOnly) {
        expect(buildTrainingIndexPhotoEntries(doc), isEmpty);
      }
    });

    test('Words To Know yields only its photo-backed terms', () {
      final doc = kBarrioTrainingDocs['training_general_words']!;
      final entries = buildTrainingIndexPhotoEntries(doc);
      expect(entries, isNotEmpty,
          reason: 'build 32 gave some of its cards real photographs');
      for (final entry in entries) {
        expect(entry.assetPath, contains('_photos/'),
            reason: '${entry.title}: the grid shows photographs, never '
                'diagram art');
      }
    });
  });
}
