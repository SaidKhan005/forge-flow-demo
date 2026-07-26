// Accessibility pass (operator-approved rec #12, 2026-07-24):
// semantics completion tests. Pins the screen-reader contract for the
// training reader (hero header, rail tiles, chevrons, card page area,
// bookmark toggle, image thumbnails, header search tooltip), quiz
// option state labels after reveal, the flashcard flip button, review
// action buttons, the streak chip, the home shelf's Continue Reading /
// Saved rows, and the reduce-motion behavior of the reader entrance
// and the flashcard flip.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_flashcard_review_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_bookmarks_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_flashcard_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_quiz_checkpoint_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_streak_tracker.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:forge_and_flow/internal/barrio/widgets/learning_carousel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _phoneSize = Size(390, 844);

/// Small fixture manual: 2 sections of 2 cards. Card One carries a
/// captioned picture, Card Two an uncaptioned one, so both thumbnail
/// label branches (literal caption vs 'Photo: <title>') are pinned.
const BarrioTrainingDoc _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_a11y_doc',
  title: 'A11y Fixture Manual',
  sourcePath: 'test://fixture',
  chapters: [
    HandbookChapter(
      id: 'fixa_ch1',
      title: 'Getting Started',
      subtitle: 'first fixture section',
      iconCodePoint: 0xe533,
      units: [
        HandbookUnit(
          id: 'fixa_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Card One',
          body: 'First fixture card body.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/does_not_exist_one.png',
              caption: 'Team photo, 2019',
              afterParagraph: 0,
            ),
          ],
        ),
        HandbookUnit(
          id: 'fixa_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Two',
          body: 'Second fixture card body.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/does_not_exist_two.png',
              afterParagraph: 0,
            ),
          ],
        ),
      ],
    ),
    HandbookChapter(
      id: 'fixa_ch2',
      title: 'Going Deeper',
      subtitle: 'second fixture section',
      iconCodePoint: 0xe556,
      units: [
        HandbookUnit(
          id: 'fixa_c2_u1',
          type: HandbookUnitType.explainer,
          title: 'Card Three',
          body: 'Third fixture card body.',
        ),
        HandbookUnit(
          id: 'fixa_c2_u2',
          type: HandbookUnitType.explainer,
          title: 'Card Four',
          body: 'Fourth fixture card body.',
        ),
      ],
    ),
  ],
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('training reader semantics', () {
    testWidgets(
        'hero header, rail tiles, chevron, card page area, bookmark '
        'toggle, image thumbnails, and search tooltip are all labeled',
        (tester) async {
      usePhoneViewport(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
      );
      await tester.pump(const Duration(milliseconds: 1000));

      // Hero: full title in one merged header label.
      expect(find.bySemanticsLabel('Section 1 of 2: Getting Started'),
          findsOneWidget);
      // Rail tiles: position, full title, honest reading time.
      expect(
        find.bySemanticsLabel(
            'Section 1 of 2: Getting Started, about 1 minute'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Section 2 of 2: Going Deeper, about 1 minute'),
        findsOneWidget,
      );
      // Page-turn chevron (existing label, verified).
      expect(find.bySemanticsLabel('Next card'), findsOneWidget);
      // Card page area announces deck position.
      expect(find.bySemanticsLabel('Card 1 of 4'), findsOneWidget);
      // Bookmark toggle (existing label, verified).
      expect(find.bySemanticsLabel('Save this card'), findsWidgets);
      // Captioned thumbnail reads its LITERAL caption.
      expect(find.bySemanticsLabel('Team photo, 2019'), findsOneWidget);
      // Header search icon (existing tooltip, verified).
      expect(find.byTooltip('Search this manual'), findsOneWidget);

      // Turn the page: the uncaptioned thumbnail reads Photo + title.
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel('Photo: Card Two'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets(
        'reduce motion lands the reader settled with nothing animating',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child ?? const SizedBox.shrink(),
          ),
          home: const TrainingDocScreen(doc: _fixtureDoc),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      // Allow the card scrollbar's one-shot thumb fade-in (a functional
      // overflow indicator on the image card, not ambient motion) to
      // finish before asserting stillness.
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.hasRunningAnimations, isFalse,
          reason: 'hero fade and carousel entrance must not run under '
              'reduce motion');
      final entranceFade = tester.widget<FadeTransition>(
        find
            .descendant(
              of: find.byType(LearningCarousel),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(entranceFade.opacity.value, 1.0,
          reason: 'the deck lands fully visible, not faded out');
      expect(tester.takeException(), isNull);
    });
  });

  group('quiz option semantics', () {
    testWidgets('options carry letter + text, then honest state after '
        'reveal', (tester) async {
      usePhoneViewport(tester);
      final handle = tester.ensureSemantics();
      final question =
          kBarrioQuizBanks['training_food_safety']!.questions.first;
      final wrongIndex = question.correctIndex == 0 ? 1 : 0;
      int? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: BarrioQuizCheckpointCard(
                  question: question,
                  selectedIndex: picked,
                  onOptionSelected: (i) => setState(() => picked = i),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Before reveal: letter + option text, no state suffix.
      expect(
        find.bySemanticsLabel('A: ${question.options[0]}'),
        findsOneWidget,
      );

      final wrongOption = find.byKey(
          ValueKey<String>('quiz_option_${question.id}_$wrongIndex'));
      await tester.ensureVisible(wrongOption);
      await tester.tap(wrongOption);
      await tester.pump(const Duration(milliseconds: 400));

      // After reveal: the wrong pick and the correct answer both say so.
      expect(
        find.bySemanticsLabel(RegExp(r'your pick, not correct$')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r', correct answer$')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });

  group('flashcard semantics and reduce motion', () {
    testWidgets('flip button announces Show definition / Show term and '
        'review actions are buttons', (tester) async {
      usePhoneViewport(tester);
      final handle = tester.ensureSemantics();
      final deck = barrioFlashcardDeckForManual(
        'training_latin_dishes',
        title: 'Latin Dishes',
      )!;
      await tester.pumpWidget(
        MaterialApp(
          home: BarrioFlashcardReviewScreen(deck: deck, shuffleSeed: 42),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // The face content merges in after the action label, so the flip
      // button node READS 'Show definition, <term>': match the prefix.
      expect(find.bySemanticsLabel(RegExp(r'^Show definition')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Show term')), findsNothing);

      await tester.tap(find.byType(BarrioFlashcardCard));
      await tester.pump(); // start the flip ticker
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel(RegExp(r'^Show term')), findsOneWidget);

      expect(
        tester.getSemantics(find.text('Got it')),
        containsSemantics(label: 'Got it', isButton: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(find.text('See it again')),
        containsSemantics(
            label: 'See it again', isButton: true, hasTapAction: true),
      );
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('reduce motion makes the flip instant', (tester) async {
      usePhoneViewport(tester);
      final handle = tester.ensureSemantics();
      final deck = barrioFlashcardDeckForManual(
        'training_latin_dishes',
        title: 'Latin Dishes',
      )!;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child ?? const SizedBox.shrink(),
          ),
          home: BarrioFlashcardReviewScreen(deck: deck, shuffleSeed: 42),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byType(BarrioFlashcardCard));
      await tester.pump();
      // Zero-duration flip: the back face (Show term) lands on the very
      // next frame, no 320ms tween.
      expect(find.bySemanticsLabel(RegExp(r'^Show term')), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });

  group('home shelf semantics', () {
    testWidgets('streak chip label covers count, singular day, and the '
        'day-off note', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: BarrioStreakChip(
                info: StreakInfo(
                  count: 1,
                  status: StreakStatus.active,
                  dayOffCovered: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.bySemanticsLabel('Learning streak: 1 day, day off covered'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets(
        'Continue Reading and Saved rows read as single labeled buttons',
        (tester) async {
      usePhoneViewport(tester);
      final handle = tester.ensureSemantics();
      final doc = kBarrioTrainingDocs['training_food_safety']!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: BarrioHomeShelf(
              destinations:
                  barrioDestinations.where((d) => d.showOnHomeHub).toList(),
              onDestinationTap: (_) {},
              readingProgress: BarrioReadingSnapshot(
                lastDocId: doc.id,
                lastPosition: const BarrioReadingPosition(
                    chapterIndex: 0, unitInChapter: 0),
                readUnitIds: <String, Set<String>>{
                  doc.id: <String>{doc.chapters.first.units.first.id},
                },
              ),
              onContinueReading: (_, __, ___) {},
              bookmarks: <BarrioBookmark>[
                BarrioBookmark(
                    docId: doc.id, chapterIndex: 0, unitInChapter: 0),
              ],
              onBookmarkOpen: (_, __, ___) {},
              onBookmarkRemove: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));

      // Continue Reading: one merged button, tap action included.
      expect(
        tester.getSemantics(find.text('CONTINUE READING')),
        containsSemantics(isButton: true, hasTapAction: true),
      );
      // Saved row: labeled button naming the card and its manual, with
      // the remove x kept as its own separately reachable node.
      expect(find.bySemanticsLabel(RegExp(r'^Saved: ')), findsOneWidget);
      expect(find.bySemanticsLabel('Remove from saved'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });
}
