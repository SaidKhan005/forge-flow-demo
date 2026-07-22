// Widget tests for the "the app remembers you" slice (2026-07-22):
// resume-where-you-left-off, the home Continue Reading card, persisted
// read marks (rail checks + honest footer dots), honest home progress
// rows, and reading-time labels.
//
// All at a 390x844 phone viewport. The home screen and shelf run
// looping ambient motion (leaves, scrim breathing, center-bubble arc):
// NEVER pumpAndSettle in those tests; pump explicit durations only.
// Every test asserts takeException() is null (overflow guard: these
// screens are dense and must not get denser).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destination_visibility_resolver.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_time.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// B18 resolver that denies everything: proves the resolver wins over
/// the preview-role fallback for the Continue Reading card, exactly
/// like the shelf bubbles and search results.
class _DenyAllResolver implements BarrioDestinationVisibilityResolver {
  const _DenyAllResolver();

  @override
  bool isVisible(BarrioDestination destination) => false;
}

/// Small fixture manual: 2 sections of 2 cards (4 flat cards), so one
/// swipe finishes section 1 and positions are easy to reason about.
const _kFixtureDocId = 'fixture_memory_doc';
const _fixtureDoc = BarrioTrainingDoc(
  id: _kFixtureDocId,
  title: 'Memory Fixture Manual',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'fix_ch1',
      title: 'Getting Started',
      subtitle: 'first fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'fix_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card One',
          body: 'First fixture card body.',
        ),
        HandbookUnit(
          id: 'fix_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Second fixture card body.',
        ),
      ],
    ),
    HandbookChapter(
      id: 'fix_ch2',
      title: 'Going Deeper',
      subtitle: 'second fixture section',
      iconCodePoint: 0xe556,
      units: [
        HandbookUnit(
          id: 'fix_c2_u1',
          type: HandbookUnitType.explainer,
          title: 'Card Three',
          body: 'Third fixture card body.',
        ),
        HandbookUnit(
          id: 'fix_c2_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Four',
          body: 'Fourth fixture card body.',
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

  Future<void> pumpDoc(
    WidgetTester tester, {
    int? chapter,
    int? unit,
  }) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: TrainingDocScreen(
          doc: _fixtureDoc,
          initialChapterIndex: chapter,
          initialUnitInChapter: unit,
        ),
      ),
    );
    // Restore setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  Future<void> swipeLeft(WidgetTester tester) async {
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpHome(WidgetTester tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: BarrioHomeScreen()));
    // One-shot entrance (900ms) + wordmark (700ms); the reading
    // snapshot load resolves inside these pumps too.
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> pumpShelf(
    WidgetTester tester, {
    BarrioReadingSnapshot? progress,
    BarrioDestinationVisibilityResolver? resolver,
    BarrioPreviewRole role = BarrioPreviewRole.admin,
    void Function(BarrioDestination, int, int)? onContinue,
  }) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BarrioHomeShelf(
            destinations:
                barrioDestinations.where((d) => d.showOnHomeHub).toList(),
            previewRole: role,
            visibilityResolver: resolver,
            readingProgress: progress,
            onContinueReading: onContinue ?? (_, __, ___) {},
            onDestinationTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('resume where you left off', () {
    testWidgets('reading persists position and read marks, and reopening '
        'with no deep link resumes at the saved card', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpDoc(tester);

      // First-ever open: section 0, card 0, exactly as before.
      expect(find.text('SECTION 1 OF 2'), findsOneWidget);
      expect(find.text('1 of 4'), findsOneWidget);

      await swipeLeft(tester);
      expect(find.text('2 of 4'), findsOneWidget);

      // The settled cards were persisted as facts.
      final position =
          await BarrioReadingProgressService.getPosition(_kFixtureDocId);
      expect(position!.chapterIndex, 0);
      expect(position.unitInChapter, 1);
      expect(
        await BarrioReadingProgressService.getReadUnitIds(_kFixtureDocId),
        {'fix_c1_u1', 'fix_c1_u2'},
      );

      // Remount with NO deep link: the manual resumes at the saved card.
      await tester.pumpWidget(const SizedBox());
      await pumpDoc(tester);
      expect(find.text('2 of 4'), findsOneWidget,
          reason: 'resume must land on the saved card, not card 0');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a saved position in a later section restores section and '
        'card', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.positionKeyFor(_kFixtureDocId): '1:1',
        BarrioReadingProgressService.readCardsKeyFor(_kFixtureDocId):
            <String>['fix_c1_u1'],
      });
      await pumpDoc(tester);

      expect(find.text('SECTION 2 OF 2'), findsOneWidget,
          reason: 'the hero follows the restored section');
      expect(find.text('4 of 4'), findsOneWidget,
          reason: 'the carousel opens on the restored card');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an explicit deep link (including section 0) beats the '
        'saved position', (tester) async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.positionKeyFor(_kFixtureDocId): '1:1',
      });
      await pumpDoc(tester, chapter: 0, unit: 0);

      expect(find.text('SECTION 1 OF 2'), findsOneWidget,
          reason: 'a deep link to section 0 must win over resume');
      expect(find.text('1 of 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a home search deep link beats the saved position '
        '(end to end)', (tester) async {
      final expected = BarrioTrainingSearch.search('mezcal').first;
      expect(expected.destinationId, 'training_tequila',
          reason: 'sanity: mezcal is a Tequila Training query');
      // Save a DIFFERENT section as the resume position.
      final savedChapter = expected.chapterIndex == 0 ? 1 : 0;
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      SharedPreferences.setMockInitialValues({
        'barrio_reading_last_doc': 'training_tequila',
        BarrioReadingProgressService.positionKeyFor('training_tequila'):
            '$savedChapter:0',
        BarrioReadingProgressService.readCardsKeyFor('training_tequila'):
            <String>[tequila.chapters.first.units.first.id],
      });

      await pumpHome(tester);
      await tester.enterText(find.byType(TextField), 'mezcal');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text(expected.docTitle).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.byType(TrainingDocScreen), findsOneWidget);
      expect(
        find.text(
            'SECTION ${expected.chapterIndex + 1} OF ${tequila.chapters.length}'),
        findsOneWidget,
        reason: 'the search deep link must open the matched section, '
            'not the resumed one',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Continue Reading card', () {
    testWidgets('appears after reading and deep-links to the saved card',
        (tester) async {
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      SharedPreferences.setMockInitialValues({
        'barrio_reading_last_doc': 'training_tequila',
        BarrioReadingProgressService.positionKeyFor('training_tequila'):
            '1:0',
        BarrioReadingProgressService.readCardsKeyFor('training_tequila'):
            <String>[tequila.chapters.first.units.first.id],
      });
      await pumpHome(tester);

      expect(find.text('CONTINUE READING'), findsOneWidget);
      expect(
        find.text('Pick up at Section 2: ${tequila.chapters[1].title}'),
        findsOneWidget,
        reason: 'the card shows the honest saved position',
      );

      await tester.tap(find.text('CONTINUE READING'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.byType(TrainingDocScreen), findsOneWidget);
      expect(
        find.text('SECTION 2 OF ${tequila.chapters.length}'),
        findsOneWidget,
        reason: 'the card must deep-link to the remembered section',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('absent on fresh state (nothing read yet)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpHome(tester);

      expect(find.text('CONTINUE READING'), findsNothing,
          reason: 'no phantom card when nothing has been read');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a deny-all resolver hides the card even though the admin '
        'preview role would allow it (resolver-first, B18)', (tester) async {
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      final snapshot = BarrioReadingSnapshot(
        lastDocId: 'training_tequila',
        lastPosition:
            const BarrioReadingPosition(chapterIndex: 1, unitInChapter: 0),
        readUnitIds: {
          'training_tequila': {tequila.chapters.first.units.first.id},
        },
      );

      // Sanity: without a resolver, the admin preview tier shows the card.
      await pumpShelf(tester, progress: snapshot);
      expect(find.text('CONTINUE READING'), findsOneWidget);

      await pumpShelf(
        tester,
        progress: snapshot,
        resolver: const _DenyAllResolver(),
      );
      expect(find.text('CONTINUE READING'), findsNothing,
          reason: 'a hidden manual never appears as Continue Reading');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the preview-role fallback also hides a manual outside the '
        'tier (staff vs manager-only doc)', (tester) async {
      final labour = kBarrioTrainingDocs['training_labour_cost']!;
      final snapshot = BarrioReadingSnapshot(
        lastDocId: 'training_labour_cost',
        lastPosition:
            const BarrioReadingPosition(chapterIndex: 0, unitInChapter: 0),
        readUnitIds: {
          'training_labour_cost': {labour.chapters.first.units.first.id},
        },
      );

      await pumpShelf(
        tester,
        progress: snapshot,
        role: BarrioPreviewRole.staff,
      );
      expect(find.text('CONTINUE READING'), findsNothing,
          reason: 'training_labour_cost is manager/admin-only, so the '
              'staff tier must never see its card');
      expect(tester.takeException(), isNull);
    });
  });

  group('persisted read marks', () {
    testWidgets('the rail check appears only when a section is fully read '
        'and survives a screen remount', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpDoc(tester);

      // Landing card read; section 1 is NOT fully read yet: no check.
      expect(find.byIcon(Icons.check_circle), findsNothing,
          reason: 'a partially read section shows no check');

      // Reading the second card completes section 1.
      await swipeLeft(tester);
      expect(find.byIcon(Icons.check_circle), findsOneWidget,
          reason: 'the check appears once ALL section cards are read');

      // Remount the screen: the check must survive (persisted, not
      // session state).
      await tester.pumpWidget(const SizedBox());
      await pumpDoc(tester);
      expect(find.byIcon(Icons.check_circle), findsOneWidget,
          reason: 'the persisted read marks must survive a remount');
      expect(tester.takeException(), isNull);
    });

    testWidgets('reading-time labels render on the chapter rail',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpDoc(tester);

      // Both fixture sections are tiny: each floors to about 1 min.
      expect(find.text('about 1 min'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('home shelf progress rows and time labels', () {
    testWidgets('no progress row at zero reads; time labels render '
        '(no phantom zeroes)', (tester) async {
      await pumpShelf(tester);

      await scrollTo(tester, find.text('Food & Drink'));
      expect(find.textContaining('cards read'), findsNothing,
          reason: 'untouched manuals show no progress row at all');

      final tequila = kBarrioTrainingDocs['training_tequila']!;
      final expectedLabel =
          BarrioReadingTime.label(BarrioReadingTime.docMinutes(tequila));
      expect(find.text(expectedLabel), findsWidgets,
          reason: 'manuals carry the quiet reading-time estimate');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a manual with two read cards shows the honest count and '
        'a thin progress bar', (tester) async {
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      final allUnits =
          tequila.chapters.expand((c) => c.units).toList(growable: false);
      final snapshot = BarrioReadingSnapshot(
        readUnitIds: {
          'training_tequila': {allUnits[0].id, allUnits[1].id},
        },
      );
      await pumpShelf(tester, progress: snapshot);

      await scrollTo(tester, find.text('Food & Drink'));
      expect(
        find.text('2 of ${allUnits.length} cards read'),
        findsOneWidget,
        reason: 'the read count is a fact: N of M cards read',
      );
      expect(find.textContaining('cards read'), findsOneWidget,
          reason: 'only the read manual carries a progress row');
      expect(find.byType(LinearProgressIndicator), findsOneWidget,
          reason: 'the thin progress bar renders with the row');
      expect(tester.takeException(), isNull);
    });
  });
}
