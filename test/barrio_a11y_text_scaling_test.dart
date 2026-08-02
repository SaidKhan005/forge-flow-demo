// Accessibility pass (operator-approved rec #12, 2026-07-24): text
// scaling audit. Every major Barrio surface is pumped at a 390x844
// phone viewport with textScaler 1.3x and 2.0x and must lay out with
// no RenderFlex overflow (takeException() == null; overflow throws in
// tests). Covers: home screen scroll-through, the home shelf with the
// Continue Reading / Quick refresher / Saved / streak extras, the
// training reader (content card, chevron page turn, and a quick-check
// quiz card), the flashcard review screen (flip + advance), the
// in-manual search sheet, the A-Z index sheet, the term-definition
// sheet, and the image viewer.
//
// The home screen runs looping ambient motion: NEVER pumpAndSettle
// there; pump explicit durations only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_flashcard_review_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_quiz_refresher_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_bookmarks_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_term_links.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_training_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_flashcard_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_quiz_checkpoint_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_streak_tracker.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_term_definition_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_training_image_viewer.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_shelf.dart';
import 'package:forge_and_flow/internal/barrio/widgets/learning_carousel.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_index_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_search_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _phoneSize = Size(390, 844);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// MaterialApp wrapper forcing the given linear text scale on the
  /// whole subtree (stands in for the OS text-size setting).
  Widget scaledApp(double scale, Widget home) {
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: home,
    );
  }

  for (final scale in <double>[1.3, 2.0]) {
    group('at ${scale}x text scale (390x844)', () {
      testWidgets('home screen scrolls end to end with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        await tester.pumpWidget(scaledApp(scale, const BarrioHomeScreen()));
        await tester.pump(const Duration(milliseconds: 1000));
        expect(tester.takeException(), isNull);

        for (var i = 0; i < 16; i++) {
          await tester.drag(
              find.byType(CustomScrollView), const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 40));
          expect(tester.takeException(), isNull,
              reason: 'no overflow while scrolling home at ${scale}x');
        }
      });

      testWidgets(
          'home shelf with Continue Reading, refresher, Saved, and streak '
          'extras lays out with no overflow', (tester) async {
        usePhoneViewport(tester);
        final doc = kBarrioTrainingDocs['training_food_safety']!;
        final snapshot = BarrioReadingSnapshot(
          lastDocId: doc.id,
          lastPosition:
              const BarrioReadingPosition(chapterIndex: 0, unitInChapter: 0),
          readUnitIds: <String, Set<String>>{
            doc.id: <String>{doc.chapters.first.units.first.id},
          },
        );
        await tester.pumpWidget(
          scaledApp(
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: BarrioHomeShelf(
                destinations: barrioDestinations
                    .where((d) => d.showOnHomeHub)
                    .toList(),
                onDestinationTap: (_) {},
                readingProgress: snapshot,
                onContinueReading: (_, __, ___) {},
                bookmarks: <BarrioBookmark>[
                  BarrioBookmark(
                    docId: doc.id,
                    chapterIndex: 0,
                    unitInChapter: 0,
                  ),
                ],
                onBookmarkOpen: (_, __, ___) {},
                onBookmarkRemove: (_) {},
                refresherDueDocIds: <String>[doc.id],
                leading: const <Widget>[
                  Center(
                    child: BarrioStreakChip(
                      info: StreakInfo(
                        count: 4,
                        status: StreakStatus.active,
                        dayOffCovered: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 1000));
        expect(find.text('CONTINUE READING'), findsOneWidget);
        expect(find.text('QUICK REFRESHER'), findsOneWidget);
        expect(find.text('Saved'), findsOneWidget);
        expect(tester.takeException(), isNull);

        for (var i = 0; i < 16; i++) {
          await tester.drag(
              find.byType(CustomScrollView), const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 40));
          expect(tester.takeException(), isNull,
              reason: 'no overflow while scrolling the shelf at ${scale}x');
        }
      });

      testWidgets(
          'training reader renders and turns a page with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        final doc = kBarrioTrainingDocs['training_food_safety']!;
        await tester.pumpWidget(
          scaledApp(scale, TrainingDocScreen(doc: doc)),
        );
        await tester.pump(const Duration(milliseconds: 1000));
        expect(tester.takeException(), isNull,
            reason: 'reader first frame must not overflow at ${scale}x '
                '(hero, scaled rail, card, footer)');

        // Turn one page via the right chevron.
        await tester.tap(find.byIcon(Icons.chevron_right_rounded));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      });

      testWidgets('training reader quick-check quiz card renders with no '
          'overflow', (tester) async {
        usePhoneViewport(tester);
        final doc = kBarrioTrainingDocs['training_food_safety']!;
        final deck = buildTrainingDeck(doc);
        final quizPage = deck.entries.indexWhere((e) => e.isQuiz);
        expect(quizPage, greaterThan(0),
            reason: 'food safety must carry a quiz bank');

        await tester.pumpWidget(
          scaledApp(scale, TrainingDocScreen(doc: doc)),
        );
        await tester.pump(const Duration(milliseconds: 1000));

        tester
            .state<LearningCarouselState>(find.byType(LearningCarousel))
            .moveToPage(quizPage);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('QUICK CHECK'), findsWidgets);
        expect(tester.takeException(), isNull,
            reason: 'quiz card must not overflow at ${scale}x');
      });

      testWidgets('standalone quiz card reveal shows no overflow',
          (tester) async {
        usePhoneViewport(tester);
        final question =
            kBarrioQuizBanks['training_food_safety']!.questions.first;
        int? picked;
        await tester.pumpWidget(
          scaledApp(
            scale,
            Scaffold(
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
        expect(tester.takeException(), isNull);

        final option =
            find.byKey(ValueKey<String>('quiz_option_${question.id}_0'));
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(ValueKey<String>('quiz_why_${question.id}')),
            findsOneWidget);
        expect(tester.takeException(), isNull,
            reason: 'revealed quiz card must not overflow at ${scale}x');
      });

      testWidgets('quiz refresher screen renders with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        await tester.pumpWidget(
          scaledApp(
            scale,
            BarrioQuizRefresherScreen(
              bank: kBarrioQuizBanks['training_food_safety']!,
              title: 'Food Safety',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      });

      testWidgets('flashcard review flips and advances with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        final deck = barrioFlashcardDeckForManual(
          'training_latin_dishes',
          title: 'Latin Dishes',
        )!;
        await tester.pumpWidget(
          scaledApp(
            scale,
            BarrioFlashcardReviewScreen(deck: deck, shuffleSeed: 42),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull,
            reason: 'flashcard front must not overflow at ${scale}x');

        // Flip to the definition side.
        await tester.tap(find.byType(BarrioFlashcardCard));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull,
            reason: 'flashcard back must not overflow at ${scale}x');

        // Advance one card (buttons wrap instead of overflowing).
        await tester.tap(find.text('Got it'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      });

      testWidgets('in-manual search sheet shows results with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        await tester.pumpWidget(
          scaledApp(
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: TrainingDocSearchSheet(
                docId: 'training_food_safety',
                accent: Colors.teal,
                onResultTap: (_, __) {},
                // The sheet also answers questions and offers a web fallback (#1536);
                // these surfaces are not under test here, so the callbacks are no-ops.
                onAnswerTap: (_, __) {},
                onWebSearchRequested: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'the');
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey<String>('training_doc_search_results')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull,
            reason: 'search sheet must not overflow at ${scale}x');
      });

      testWidgets('A-Z index sheet renders with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        await tester.pumpWidget(
          scaledApp(
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: TrainingDocIndexSheet(
                doc: kBarrioTrainingDocs['training_latin_dishes']!,
                accent: Colors.teal,
                onEntryTap: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: 'index sheet header and rows must not overflow at '
                '${scale}x');
      });

      testWidgets('term definition sheet renders with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        final card = BarrioTermLinks.registry().values.first;
        await tester.pumpWidget(
          scaledApp(
            scale,
            Scaffold(
              backgroundColor: Colors.black,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: BarrioTermDefinitionSheet(
                  card: card,
                  accent: Colors.teal,
                  onOpenInManual: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: 'term sheet must not overflow at ${scale}x');
      });

      testWidgets('image viewer chrome renders with no overflow',
          (tester) async {
        usePhoneViewport(tester);
        await tester.pumpWidget(
          scaledApp(
            scale,
            const BarrioTrainingImageViewer(
              slides: [
                BarrioTrainingImageSlide(
                  assetPath: 'assets/does_not_exist.png',
                  caption: 'A literal source caption long enough to wrap when '
                      'the text scale doubles on a narrow phone.',
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: 'viewer caption and close chrome must not overflow at '
                '${scale}x');
      });
    });
  }
}
