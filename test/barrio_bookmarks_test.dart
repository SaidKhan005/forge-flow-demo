// Widget + service tests for bookmarks + the Saved shelf (rec #8,
// 2026-07-23):
//   * the card's quiet bookmark toggle saves/unsaves and persists via
//     BarrioBookmarksService (content-card coordinates);
//   * the home Saved section renders only with >= 1 resolvable
//     bookmark (no phantom empty section), newest first, deep-links
//     to the exact card, and the small x removes;
//   * a resolver-hidden manual's bookmark does not render but stays
//     in storage (B18);
//   * the visible-row cap is honest: 5 rows + 'and N more saved',
//     tapping reveals all.
//
// All at a 390x844 phone viewport. The home screen runs looping
// ambient motion: NEVER pumpAndSettle there; explicit pumps only.
// Every test asserts takeException() is null.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destination_visibility_resolver.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_bookmarks_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// B18 resolver that denies everything.
class _DenyAllResolver implements BarrioDestinationVisibilityResolver {
  const _DenyAllResolver();

  @override
  bool isVisible(BarrioDestination destination) => false;
}

const _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_bookmark_doc',
  title: 'Bookmark Fixture Manual',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'bm_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'bm_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card One',
          body: 'First fixture card body.',
        ),
        HandbookUnit(
          id: 'bm_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Second fixture card body.',
        ),
      ],
    ),
  ],
);

void main() {
  const phoneSize = Size(390, 844);

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpDoc(WidgetTester tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  Future<void> pumpHome(WidgetTester tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: BarrioHomeScreen()));
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> pumpShelf(
    WidgetTester tester, {
    List<BarrioBookmark> bookmarks = const [],
    BarrioDestinationVisibilityResolver? resolver,
    void Function(BarrioDestination, int, int)? onOpen,
    void Function(BarrioBookmark)? onRemove,
  }) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BarrioHomeShelf(
            destinations:
                barrioDestinations.where((d) => d.showOnHomeHub).toList(),
            visibilityResolver: resolver,
            bookmarks: bookmarks,
            onBookmarkOpen: onOpen ?? (_, __, ___) {},
            onBookmarkRemove: onRemove ?? (_) {},
            onDestinationTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
  }

  group('card bookmark toggle', () {
    testWidgets('saving and unsaving a card persists through the service '
        'and flips the Semantics label', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpDoc(tester);

      // The pager pre-builds the neighbor card, so both content cards
      // carry a toggle; the first is the visible card 0.
      expect(find.bySemanticsLabel('Save this card'), findsWidgets,
          reason: 'content cards offer the quiet save toggle');
      expect(find.bySemanticsLabel('Remove from saved'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Save this card').first);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.bySemanticsLabel('Remove from saved'), findsOneWidget);
      var all = await BarrioBookmarksService.getAll();
      expect(all, hasLength(1));
      expect(all.single.docId, 'fixture_bookmark_doc');
      expect(all.single.chapterIndex, 0);
      expect(all.single.unitInChapter, 0,
          reason: 'the toggle stores content-card coordinates');

      await tester.tap(find.bySemanticsLabel('Remove from saved'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.bySemanticsLabel('Remove from saved'), findsNothing);
      all = await BarrioBookmarksService.getAll();
      expect(all, isEmpty, reason: 'unsaving removes the stored tuple');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a saved card shows as saved after a screen remount '
        '(persisted, not session state)', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioBookmarksService.kBookmarksKey: <String>[
          'fixture_bookmark_doc:0:0',
        ],
      });
      await pumpDoc(tester);

      expect(find.bySemanticsLabel('Remove from saved'), findsOneWidget,
          reason: 'the persisted bookmark must survive a remount');
      expect(tester.takeException(), isNull);
    });
  });

  group('Saved shelf section', () {
    testWidgets('absent with no bookmarks (no phantom empty section)',
        (tester) async {
      await pumpShelf(tester);
      expect(find.text('Saved'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders manual + card titles and deep-links to the '
        'exact card (end to end through home)', (tester) async {
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      final savedUnit = tequila.chapters[1].units[0];
      SharedPreferences.setMockInitialValues({
        BarrioBookmarksService.kBookmarksKey: <String>[
          'training_tequila:1:0',
        ],
      });
      await pumpHome(tester);

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text(savedUnit.title), findsOneWidget,
          reason: 'the row shows the saved card title');
      expect(find.text('Tequila'), findsWidgets,
          reason: 'the row shows the manual title');

      await tester.tap(find.text(savedUnit.title));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.byType(TrainingDocScreen), findsOneWidget);
      expect(
        find.text('SECTION 2 OF ${tequila.chapters.length}'),
        findsOneWidget,
        reason: 'the Saved row must deep-link to the exact saved card',
      );
      expect(find.byKey(ValueKey(savedUnit.id)), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the small x removes the bookmark from storage and the '
        'row disappears', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioBookmarksService.kBookmarksKey: <String>[
          'training_tequila:1:0',
        ],
      });
      await pumpHome(tester);
      expect(find.text('Saved'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>(
            'barrio_saved_remove_training_tequila_1_0')),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Saved'), findsNothing,
          reason: 'the last row removed takes the whole section with it');
      expect(await BarrioBookmarksService.getAll(), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a resolver-hidden manual bookmark does not render but '
        'stays in storage (B18)', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioBookmarksService.kBookmarksKey: <String>[
          'training_tequila:0:0',
        ],
      });
      const bookmark = BarrioBookmark(
        docId: 'training_tequila',
        chapterIndex: 0,
        unitInChapter: 0,
      );

      // Sanity: without a resolver the admin tier shows the section.
      await pumpShelf(tester, bookmarks: const [bookmark]);
      expect(find.text('Saved'), findsOneWidget);

      await pumpShelf(
        tester,
        bookmarks: const [bookmark],
        resolver: const _DenyAllResolver(),
      );
      expect(find.text('Saved'), findsNothing,
          reason: 'a hidden manual never renders its bookmarks');
      expect(await BarrioBookmarksService.getAll(), hasLength(1),
          reason: 'the bookmark is kept in storage and reappears if '
              'visibility returns');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a bookmark whose coordinates no longer exist is '
        'skipped, not deleted', (tester) async {
      const gone = BarrioBookmark(
        docId: 'training_tequila',
        chapterIndex: 99,
        unitInChapter: 0,
      );
      await pumpShelf(tester, bookmarks: const [gone]);
      expect(find.text('Saved'), findsNothing,
          reason: 'a stale coordinate renders nothing (content moved)');
      expect(tester.takeException(), isNull);
    });

    testWidgets('caps visible rows at 5 with an honest "and N more '
        'saved" expander that reveals all', (tester) async {
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      final flat = [
        for (var c = 0; c < tequila.chapters.length; c++)
          for (var u = 0; u < tequila.chapters[c].units.length; u++)
            BarrioBookmark(
                docId: 'training_tequila', chapterIndex: c, unitInChapter: u),
      ];
      expect(flat.length, greaterThanOrEqualTo(7),
          reason: 'sanity: enough cards to exercise the cap');
      final seven = flat.sublist(0, 7);

      await pumpShelf(tester, bookmarks: seven);
      expect(find.text('Saved'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('barrio_saved_t')),
        findsNWidgets(5),
        reason: 'only 5 rows render before the expander',
      );
      expect(find.text('and 2 more saved'), findsOneWidget);

      await tester
          .tap(find.byKey(const ValueKey<String>('barrio_saved_expander')));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('barrio_saved_t')),
        findsNWidgets(7),
        reason: 'the expander reveals every saved row',
      );
      expect(find.text('and 2 more saved'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rows list newest saved first', (tester) async {
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      // Stored order: 0:0 saved first, 0:1 saved second (newest).
      await pumpShelf(tester, bookmarks: const [
        BarrioBookmark(
            docId: 'training_tequila', chapterIndex: 0, unitInChapter: 0),
        BarrioBookmark(
            docId: 'training_tequila', chapterIndex: 0, unitInChapter: 1),
      ]);

      final first = tester.getTopLeft(
          find.text(tequila.chapters[0].units[1].title));
      final second = tester.getTopLeft(
          find.text(tequila.chapters[0].units[0].title));
      expect(first.dy, lessThan(second.dy),
          reason: 'the most recently saved card renders on top');
      expect(tester.takeException(), isNull);
    });
  });

  group('BarrioBookmark decode (pure)', () {
    test('round-trips and rejects malformed entries', () {
      final decoded = BarrioBookmark.decode('training_tequila:1:0');
      expect(decoded, isNotNull);
      expect(decoded!.docId, 'training_tequila');
      expect(decoded.chapterIndex, 1);
      expect(decoded.unitInChapter, 0);
      expect(decoded.storageKey, 'training_tequila:1:0');

      expect(BarrioBookmark.decode('garbage'), isNull);
      expect(BarrioBookmark.decode('doc:1'), isNull);
      expect(BarrioBookmark.decode('doc:x:y'), isNull);
      expect(BarrioBookmark.decode('doc:-1:0'), isNull);
    });
  });
}
