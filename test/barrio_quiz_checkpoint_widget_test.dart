// Widget + pure tests for the chapter-end quick-check quiz cards
// (2026-07-23 operator-approved rec #4b).
//
// The #1479 quiz bank renders as tap-to-answer checkpoint cards at the
// end of each banked chapter inside the training reader. These tests
// prove:
//   * deck assembly: quiz cards append AFTER a chapter's content cards
//     and only in the three banked manuals; every pre-quiz content
//     coordinate still resolves to the same content card;
//   * quiz card UI: correct pick goes calm green with the whyLine,
//     wrong pick is marked and the correct option revealed, options
//     lock after reveal, and the reveal survives paging away and back;
//   * gesture composition: edge taps still turn the page on a quiz
//     card, and option taps never trigger the edge tap zones even
//     where an option row overlaps the edge band;
//   * honesty: quiz cards are never recorded as read content cards
//     and never move the saved reading position; the hero's honest
//     "SECTION N OF M" follows the quiz card's own chapter;
//   * resume, in-doc search, and the A-Z index still land on the same
//     content cards with quiz cards present;
//   * display shuffle: the bank authors every correct answer first,
//     but the card shows a deterministic per-question permutation, so
//     across the full bank the correct option is NOT pinned to the top
//     row, taps still report ORIGINAL option indices, and the order is
//     stable across rebuilds of the same question.
//
// All widget tests run at a 390x844 phone viewport with explicit pumps
// and assert takeException() is null, mirroring the other Barrio
// suites.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_training_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_quiz_checkpoint_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kDishesId = 'training_latin_dishes';

List<HandbookUnit> _flatUnitsOf(BarrioTrainingDoc doc) =>
    [for (final c in doc.chapters) ...c.units];

Finder _quizCard(BarrioQuizQuestion q) => find.byKey(ValueKey('quiz_${q.id}'));

Finder _option(BarrioQuizQuestion q, int i) =>
    find.byKey(ValueKey<String>('quiz_option_${q.id}_$i'));

Finder _whyLine(BarrioQuizQuestion q) =>
    find.byKey(ValueKey<String>('quiz_why_${q.id}'));

void main() {
  const phoneSize = Size(390, 844);

  final dishesDoc = kBarrioTrainingDocs[_kDishesId]!;
  final dishesDeck = buildTrainingDeck(dishesDoc);
  final dishesBank = kBarrioQuizBanks[_kDishesId]!;
  final chapter0Units = dishesDoc.chapters[0].units.length;
  final chapter0Questions =
      dishesBank.questionsByChapter[dishesDoc.chapters[0].id]!;
  final q0 = chapter0Questions[0];
  final q1 = chapter0Questions[1];

  Future<void> pumpDoc(
    WidgetTester tester,
    String docId, {
    int? chapter,
    int? unit,
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: TrainingDocScreen(
          doc: kBarrioTrainingDocs[docId]!,
          initialChapterIndex: chapter,
          initialUnitInChapter: unit,
        ),
      ),
    );
    // Restore setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  /// Taps INSIDE the card area's invisible edge tap band, in the
  /// badge/prompt band near the top of the card (well above the option
  /// rows) and left of the chevron gutter. This exercises the
  /// carousel's in-card tap zone itself, which must stay live on a
  /// quiz card (the quiz card adds no card-level tap recognizer that
  /// could swallow it).
  Future<void> tapCardEdgeZone(WidgetTester tester,
      {required bool right}) async {
    final rect = tester.getRect(find.byType(PageView));
    final x = right ? rect.right - 62 : rect.left + 62;
    await tester.tapAt(Offset(x, rect.top + 36));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Turns the page via the always-visible gutter chevron, the
  /// page-turn affordance that works on every card type (a content
  /// card's own tap recognizer swallows in-card zone taps on its
  /// body, so stepping OFF a content card uses the chevron, exactly
  /// like the learning-carousel gestures suite).
  Future<void> tapChevron(WidgetTester tester, {required bool right}) async {
    final rect = tester.getRect(find.byType(PageView));
    final x = right ? rect.right - 8 : rect.left + 8;
    await tester.tapAt(Offset(x, rect.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Deep-links to the last content card of the dishes chapter 0, then
  /// turns one page onto that chapter's first quiz card.
  Future<void> pumpOntoFirstQuizCard(WidgetTester tester,
      {Map<String, Object> prefs = const {}}) async {
    await pumpDoc(tester, _kDishesId,
        chapter: 0, unit: chapter0Units - 1, prefs: prefs);
    expect(find.text('$chapter0Units of ${dishesDeck.length}'), findsOneWidget,
        reason: 'sanity: the deep link lands on the last content card '
            'of section 1');
    await tapChevron(tester, right: true);
  }

  group('deck insertion (widget)', () {
    testWidgets(
        'the first quiz card sits directly after the last content card '
        'of a banked chapter; the hero still reports the quiz card as '
        'part of its own section', (tester) async {
      await pumpOntoFirstQuizCard(tester);

      expect(
        find.text('${chapter0Units + 1} of ${dishesDeck.length}'),
        findsOneWidget,
        reason: 'one page turn past the last content card lands on the '
            'chapter quiz card',
      );
      expect(find.text('QUICK CHECK'), findsWidgets);
      expect(find.text(q0.prompt), findsOneWidget,
          reason: 'the first chapter-0 bank question renders');
      expect(
        find.text('SECTION 1 OF ${dishesDoc.chapters.length}'),
        findsOneWidget,
        reason: 'a quiz card belongs to its own chapter: the hero and '
            'section count are unchanged by quiz insertion',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unbanked manual gets no quiz cards: its deck is the '
        'plain content flatten', (tester) async {
      final tequila = kBarrioTrainingDocs['training_tequila']!;
      final contentCount = _flatUnitsOf(tequila).length;
      expect(buildTrainingDeck(tequila).length, contentCount,
          reason: 'sanity: no bank, no quiz entries');

      await pumpDoc(tester, 'training_tequila');
      expect(find.text('1 of $contentCount'), findsOneWidget,
          reason: 'the footer total is the untouched content count');
      expect(find.text('QUICK CHECK'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('quiz card interaction', () {
    testWidgets('tapping the correct option shows calm green plus the '
        'whyLine', (tester) async {
      await pumpOntoFirstQuizCard(tester);

      await tester.tap(_option(q0, q0.correctIndex));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.check_circle), findsOneWidget,
          reason: 'the correct option is confirmed in green');
      expect(find.byIcon(Icons.close_rounded), findsNothing,
          reason: 'a correct first pick shows no wrong marker');
      expect(_whyLine(q0), findsOneWidget);
      expect(find.text(q0.whyLine), findsOneWidget,
          reason: 'the plain-English whyLine appears after reveal');
      expect(
        find.text('${chapter0Units + 1} of ${dishesDeck.length}'),
        findsOneWidget,
        reason: 'answering never turns the page',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a wrong option marks it and reveals the correct '
        'option', (tester) async {
      final wrongIndex = (q0.correctIndex + 1) % q0.options.length;
      await pumpOntoFirstQuizCard(tester);

      await tester.tap(_option(q0, wrongIndex));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.close_rounded), findsOneWidget,
          reason: 'the wrong pick is marked, softly');
      expect(find.byIcon(Icons.check_circle), findsOneWidget,
          reason: 'the correct option is revealed alongside');
      expect(find.text(q0.whyLine), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('options lock after reveal: later taps change nothing '
        'and never turn the page', (tester) async {
      final wrongIndex = (q0.correctIndex + 1) % q0.options.length;
      final otherIndex = (q0.correctIndex + 2) % q0.options.length;
      await pumpOntoFirstQuizCard(tester);

      await tester.tap(_option(q0, wrongIndex));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<BarrioQuizCheckpointCard>(_quizCard(q0))
            .selectedIndex,
        wrongIndex,
      );

      await tester.tap(_option(q0, otherIndex));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(_option(q0, q0.correctIndex));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester
            .widget<BarrioQuizCheckpointCard>(_quizCard(q0))
            .selectedIndex,
        wrongIndex,
        reason: 'the first pick stands: options are locked after reveal',
      );
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(
        find.text('${chapter0Units + 1} of ${dishesDeck.length}'),
        findsOneWidget,
        reason: 'locked option rows absorb taps instead of passing them '
            'to the page-turn zones',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the reveal survives paging away and back within the '
        'session', (tester) async {
      await pumpOntoFirstQuizCard(tester);
      await tester.tap(_option(q0, q0.correctIndex));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_whyLine(q0), findsOneWidget);

      await tapCardEdgeZone(tester, right: true);
      expect(find.text(q1.prompt), findsOneWidget,
          reason: 'sanity: the next quiz card of the chapter follows');
      await tapCardEdgeZone(tester, right: false);

      expect(_whyLine(q0), findsOneWidget,
          reason: 'the session pick is held by the screen, so paging '
              'away and back keeps the reveal');
      expect(tester.takeException(), isNull);
    });
  });

  group('gesture composition', () {
    testWidgets('edge taps still turn the page on a quiz card, both '
        'directions', (tester) async {
      await pumpOntoFirstQuizCard(tester);
      expect(find.text('${chapter0Units + 1} of ${dishesDeck.length}'),
          findsOneWidget);

      await tapCardEdgeZone(tester, right: true);
      expect(
        find.text('${chapter0Units + 2} of ${dishesDeck.length}'),
        findsOneWidget,
        reason: 'a right edge tap on a quiz card advances one page',
      );

      await tapCardEdgeZone(tester, right: false);
      expect(
        find.text('${chapter0Units + 1} of ${dishesDeck.length}'),
        findsOneWidget,
        reason: 'a left edge tap on a quiz card goes back one page',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap on an option row where it overlaps the edge band '
        'selects the option and never turns the page', (tester) async {
      await pumpOntoFirstQuizCard(tester);

      final cardRect = tester.getRect(_quizCard(q0));
      final optionRect = tester.getRect(_option(q0, q0.correctIndex));
      final tapPoint =
          Offset(optionRect.right - 12, optionRect.center.dy);
      expect(
        tapPoint.dx - cardRect.left,
        greaterThan(cardRect.width * 0.78),
        reason: 'sanity: the tap point sits inside the right edge-tap '
            'band of the card area',
      );

      await tester.tapAt(tapPoint);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester
            .widget<BarrioQuizCheckpointCard>(_quizCard(q0))
            .selectedIndex,
        q0.correctIndex,
        reason: 'the option row wins the tap, not the edge zone',
      );
      expect(
        find.text('${chapter0Units + 1} of ${dishesDeck.length}'),
        findsOneWidget,
        reason: 'the page did not turn',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('honesty: read marks and position', () {
    testWidgets('a quiz card never records a read mark or moves the '
        'saved position, answered or not', (tester) async {
      final lastContentUnit = dishesDoc.chapters[0].units[chapter0Units - 1];
      await pumpOntoFirstQuizCard(tester);

      var position = await BarrioReadingProgressService.getPosition(_kDishesId);
      expect(position!.chapterIndex, 0);
      expect(position.unitInChapter, chapter0Units - 1,
          reason: 'settling on a quiz card keeps the position on the '
              'last content card');
      expect(
        await BarrioReadingProgressService.getReadUnitIds(_kDishesId),
        {lastContentUnit.id},
        reason: 'only the content card is marked read; the quiz card '
            'adds nothing',
      );

      await tester.tap(_option(q0, q0.correctIndex));
      await tester.pump(const Duration(milliseconds: 300));

      position = await BarrioReadingProgressService.getPosition(_kDishesId);
      expect(position!.chapterIndex, 0);
      expect(position.unitInChapter, chapter0Units - 1);
      expect(
        await BarrioReadingProgressService.getReadUnitIds(_kDishesId),
        {lastContentUnit.id},
        reason: 'answering records no score, streak, or read mark',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('coordinate stability (widget)', () {
    testWidgets('resume lands on the same content card with quiz cards '
        'present', (tester) async {
      final target = dishesDoc.chapters[2].units[1];
      expect(dishesDeck.chapterStarts[2], greaterThan(_contentStartOf(2)),
          reason: 'sanity: two chapters of quiz cards sit before the '
              'resume target, so the conversion is real');

      await pumpDoc(tester, _kDishesId, prefs: {
        BarrioReadingProgressService.positionKeyFor(_kDishesId): '2:1',
        'barrio_reading_last_doc': _kDishesId,
      });

      expect(find.byKey(ValueKey(target.id)), findsOneWidget,
          reason: 'the stored (chapter, unitInChapter) coordinate still '
              'resolves to the same content card');
      expect(
        find.text('${dishesDeck.chapterStarts[2] + 2} of '
            '${dishesDeck.length}'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an in-doc search hit past the first banked chapter '
        'still lands on the exact matched card', (tester) async {
      final hit = BarrioTrainingSearch.search(
        'empanadas',
        isDestinationAllowed: (id) => id == _kDishesId,
      ).first;
      expect(hit.chapterIndex, greaterThan(0),
          reason: 'sanity: quiz cards of earlier chapters sit before '
              'the hit, so the jump must use deck coordinates');
      final targetUnit = dishesDoc.chapters[hit.chapterIndex]
          .units[hit.unitIndex];
      final deckPage =
          dishesDeck.chapterStarts[hit.chapterIndex] + hit.unitIndex;

      await pumpDoc(tester, _kDishesId);
      await tester.tap(find.byTooltip('Search this manual'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(find.byType(TextField), 'empanadas');
      await tester.pump(const Duration(milliseconds: 250));

      final resultsList =
          find.byKey(const ValueKey<String>('training_doc_search_results'));
      await tester.tap(
        find
            .descendant(of: resultsList, matching: find.text(hit.unitTitle))
            .first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(ValueKey(targetUnit.id)), findsOneWidget,
          reason: 'the deck lands on the same content card as before '
              'quiz insertion');
      expect(find.text('${deckPage + 1} of ${dishesDeck.length}'),
          findsOneWidget);

      final position =
          await BarrioReadingProgressService.getPosition(_kDishesId);
      expect(position!.chapterIndex, hit.chapterIndex);
      expect(position.unitInChapter, hit.unitIndex,
          reason: 'the saved coordinate stays in content space');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an A-Z index entry in a later chapter converts its '
        'content page and lands on the first card of the run',
        (tester) async {
      final flatUnits = _flatUnitsOf(dishesDoc);
      final contentPage =
          flatUnits.indexWhere((u) => u.title == 'EMPANADAS');
      expect(contentPage, greaterThanOrEqualTo(0));
      final deckPage = dishesDeck.deckPageForContentPage(contentPage);
      expect(deckPage, greaterThan(contentPage),
          reason: 'sanity: earlier chapters carry quiz cards, so the '
              'deck page differs from the content page');

      await pumpDoc(tester, _kDishesId);
      await tester.tap(find.byTooltip('Jump to a term'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final indexList =
          find.byKey(const ValueKey<String>('training_doc_index_list'));
      await tester.scrollUntilVisible(
        find.descendant(of: indexList, matching: find.text('EMPANADAS')),
        200,
        scrollable: find
            .descendant(of: indexList, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('EMPANADAS'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(ValueKey(flatUnits[contentPage].id)), findsOneWidget,
          reason: 'the entry lands on the same content card as before '
              'quiz insertion');
      expect(find.text('${deckPage + 1} of ${dishesDeck.length}'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('display shuffle', () {
    final allQuestions = [
      for (final bank in kBarrioQuizBanks.values) ...bank.questions,
    ];

    test('across the full bank the correct answer is not pinned to the '
        'top row, and every display order is a real permutation', () {
      expect(allQuestions.length, greaterThanOrEqualTo(105),
          reason: 'sanity: the full 3-manual bank is under test');

      var correctFirst = 0;
      for (final q in allQuestions) {
        final order = BarrioQuizCheckpointCard.displayOrderFor(q);
        expect(
          List<int>.of(order)..sort(),
          List<int>.generate(q.options.length, (i) => i),
          reason: '${q.id}: the display order must be a permutation of '
              'the original option indices, nothing dropped or doubled',
        );
        expect(BarrioQuizCheckpointCard.displayOrderFor(q), order,
            reason: '${q.id}: the shuffle is deterministic per question');
        if (order[0] == q.correctIndex) correctFirst++;
      }

      // The bank authors correctIndex 0 everywhere, so without the
      // shuffle this count would equal allQuestions.length. Seeded
      // shuffling is deterministic, so this bound never flakes.
      expect(correctFirst, lessThan(90),
          reason: 'the correct answer must not render first for the '
              'bulk of the bank ($correctFirst of '
              '${allQuestions.length} render correct-first)');
    });

    testWidgets('a shuffled card reports ORIGINAL indices: tapping the '
        'displayed correct option reveals green and hands the screen '
        'question.correctIndex', (tester) async {
      // Any question whose shuffle moves the correct answer off the
      // top row. Deterministic pick, so the test is stable.
      final moved = allQuestions.firstWhere((q) =>
          BarrioQuizCheckpointCard.displayOrderFor(q)[0] != q.correctIndex);
      final order = BarrioQuizCheckpointCard.displayOrderFor(moved);

      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      int? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: BarrioQuizCheckpointCard(
                  question: moved,
                  selectedIndex: picked,
                  onOptionSelected: (i) => setState(() => picked = i),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The correct option really sits below the top display row, and
      // the letters follow DISPLAY position, not bank position.
      final topRect = tester.getRect(_option(moved, order[0]));
      final correctRect = tester.getRect(_option(moved, moved.correctIndex));
      expect(correctRect.top, greaterThan(topRect.top),
          reason: 'the correct option is not the first row on screen');
      expect(
        find.descendant(
            of: _option(moved, order[0]), matching: find.text('A')),
        findsOneWidget,
        reason: 'the top display row is lettered A whichever original '
            'option it holds',
      );
      final correctLetter =
          String.fromCharCode(0x41 + order.indexOf(moved.correctIndex));
      expect(
        find.descendant(
            of: _option(moved, moved.correctIndex),
            matching: find.text(correctLetter)),
        findsOneWidget,
        reason: 'the correct row wears its display-position letter',
      );

      await tester.tap(_option(moved, moved.correctIndex));
      await tester.pump(const Duration(milliseconds: 300));

      expect(picked, moved.correctIndex,
          reason: 'onOptionSelected hands the screen the ORIGINAL bank '
              'index, so _picks[id] == correctIndex scoring still holds');
      expect(find.byIcon(Icons.check_circle), findsOneWidget,
          reason: 'the tapped correct option goes calm green');
      expect(find.byIcon(Icons.close_rounded), findsNothing);
      expect(_whyLine(moved), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the display order of one question is identical across '
        'full rebuilds', (tester) async {
      final q = allQuestions.first;

      tester.view.physicalSize = phoneSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Future<void> pumpCard() => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: BarrioQuizCheckpointCard(
                    question: q,
                    selectedIndex: null,
                    onOptionSelected: (_) {},
                  ),
                ),
              ),
            ),
          );

      List<double> rowTops() => [
            for (var i = 0; i < q.options.length; i++)
              tester.getRect(_option(q, i)).top,
          ];

      await pumpCard();
      await tester.pump();
      final firstTops = rowTops();

      // Tear the tree down completely, then build the card fresh: the
      // same question must land its rows at the same positions.
      await tester.pumpWidget(const SizedBox());
      await pumpCard();
      await tester.pump();

      expect(rowTops(), firstTops,
          reason: 'a rebuilt card shows the same shuffled order, so '
              'paging away and back never re-deals the options');
      expect(tester.takeException(), isNull);
    });
  });

  group('buildTrainingDeck (pure)', () {
    test('banked manuals: quiz cards append after each chapter\'s content '
        'cards; every content coordinate is unchanged', () {
      for (final docId in kBarrioQuizBanks.keys) {
        final doc = kBarrioTrainingDocs[docId]!;
        final bank = kBarrioQuizBanks[docId]!;
        final deck = buildTrainingDeck(doc);
        final flatUnits = _flatUnitsOf(doc);

        expect(deck.length, flatUnits.length + bank.questions.length,
            reason: '$docId: one deck slot per content card and question');
        expect(deck.contentCardCount, flatUnits.length,
            reason: '$docId: the honest content-card total (the M in '
                '"N of M cards read") never counts quiz cards');

        final byChapter = bank.questionsByChapter;
        for (var i = 0; i < doc.chapters.length; i++) {
          final chapter = doc.chapters[i];
          final start = deck.chapterStarts[i];
          for (var k = 0; k < chapter.units.length; k++) {
            expect(
              identical(deck.entries[start + k].unit, chapter.units[k]),
              isTrue,
              reason: '$docId: content card $k of chapter $i keeps its '
                  'pre-quiz coordinate chapterStarts[$i] + $k',
            );
          }
          final questions =
              byChapter[chapter.id] ?? const <BarrioQuizQuestion>[];
          for (var qi = 0; qi < questions.length; qi++) {
            final page = start + chapter.units.length + qi;
            expect(
              identical(deck.entries[page].question, questions[qi]),
              isTrue,
              reason: '$docId: chapter $i question $qi follows the '
                  'chapter\'s last content card, in bank order',
            );
            expect(deck.chapterOf(page), i,
                reason: '$docId: a quiz card belongs to its own chapter');
          }
        }
      }
    });

    test('deckPageForContentPage maps every content page to the same '
        'unit; unbanked docs build the identity deck', () {
      for (final entry in kBarrioTrainingDocs.entries) {
        final deck = buildTrainingDeck(entry.value);
        final flatUnits = _flatUnitsOf(entry.value);
        final banked = kBarrioQuizBanks.containsKey(entry.key);

        for (var page = 0; page < flatUnits.length; page++) {
          final deckPage = deck.deckPageForContentPage(page);
          expect(
            identical(deck.entries[deckPage].unit, flatUnits[page]),
            isTrue,
            reason: '${entry.key}: content page $page must convert to '
                'the deck page holding the same card',
          );
          if (!banked) {
            expect(deckPage, page,
                reason: '${entry.key}: no bank means the conversion is '
                    'the identity');
          }
        }
        if (!banked) {
          expect(deck.length, flatUnits.length,
              reason: '${entry.key}: unbanked decks are the plain '
                  'content flatten');
          expect(deck.entries.any((e) => e.isQuiz), isFalse);
        }
      }
    });
  });
}

/// Content-flatten page of the dishes doc's chapter [i] first card.
int _contentStartOf(int i) {
  final doc = kBarrioTrainingDocs[_kDishesId]!;
  var page = 0;
  for (var c = 0; c < i; c++) {
    page += doc.chapters[c].units.length;
  }
  return page;
}
