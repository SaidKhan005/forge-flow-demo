// Widget tests for the ask flow inside the in-manual search sheet
// (T9 slice 2, 2026-08-02): submitting a QUESTION pins the manual's own
// answer above the word hits, and an unanswerable question gets the
// honest web fallback instead.
//
// The sheet is pumped DIRECTLY (not through the reader screen) on
// purpose: the fallback hands its query back through a callback, so the
// whole flow proves out with no url_launcher anywhere in this file.
// The screen-level jump contract is already covered end to end by
// barrio_training_doc_search_index_test.dart.
//
// All at a 390x844 phone viewport; every test asserts takeException()
// is null (overflow guard: the sheet must not get denser). Explicit
// pumps only, mirroring the other Barrio suites.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_answers.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_search_sheet.dart';

const _kDocId = 'training_tequila';
const _kAccent = Color(0xFF1E7268);

/// A question this manual answers, and one it plainly does not.
const _kAnswerable = 'what is the origin of tequila';
const _kUnanswerable = 'What is the capital of France?';

/// Question words that must never travel as highlight terms.
const _kStopwordsInQuery = <String>['what', 'is', 'the', 'of'];

/// The answer-tier results the sheet is expected to pin, computed from
/// the same service the sheet calls (self-validating, and it warms the
/// service's one-time index before the widget pump).
List<BarrioTrainingAnswer> _expectedAnswers(String query) {
  return <BarrioTrainingAnswer>[
    for (final answer in BarrioTrainingAnswers.ask(
      query,
      isDestinationAllowed: (id) => id == _kDocId,
    ))
      if (answer.confidence == BarrioAnswerConfidence.answer) answer,
  ];
}

/// The body text of the unit an answer was cut from, straight out of
/// the corpus (the verbatim law's right-hand side).
String _bodyOf(BarrioTrainingAnswer answer) {
  final doc = kBarrioTrainingDocs[answer.destinationId]!;
  return doc.chapters[answer.chapterIndex].units[answer.unitIndex].body;
}

void main() {
  const phoneSize = Size(390, 844);

  // Callback captures, reset per pump.
  late List<BarrioTrainingAnswer> tappedAnswers;
  late List<String> tappedHighlightQueries;
  late List<BarrioTrainingSearchResult> tappedResults;
  late List<String> webQueries;

  Future<void> pumpSheet(WidgetTester tester) async {
    tappedAnswers = <BarrioTrainingAnswer>[];
    tappedHighlightQueries = <String>[];
    tappedResults = <BarrioTrainingSearchResult>[];
    webQueries = <String>[];
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrainingDocSearchSheet(
            docId: _kDocId,
            accent: _kAccent,
            onResultTap: (result, query) => tappedResults.add(result),
            onAnswerTap: (answer, highlightQuery) {
              tappedAnswers.add(answer);
              tappedHighlightQueries.add(highlightQuery);
            },
            onWebSearchRequested: webQueries.add,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// Types [query] and fires the keyboard search action, exactly as a
  /// reader submitting a question does.
  Future<void> ask(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  group('asking a question the manual answers', () {
    testWidgets('pins a verbatim excerpt with its source, above the word '
        'matches', (tester) async {
      final expected = _expectedAnswers(_kAnswerable);
      expect(expected, isNotEmpty,
          reason: 'sanity: the tequila manual must answer its own origin');
      final first = expected.first;

      await pumpSheet(tester);
      expect(find.text('Search or ask this manual'), findsOneWidget,
          reason: 'the hint invites a question, not just a word');

      await ask(tester, _kAnswerable);

      expect(find.text('FROM THIS MANUAL'), findsOneWidget,
          reason: 'the answer block is labelled as the manual, not an AI');
      expect(find.text('WORD MATCHES'), findsOneWidget,
          reason: 'the word hits keep their place below the answer');

      // Verbatim law, proved against the corpus body itself.
      final body = _bodyOf(first);
      expect(body.contains(first.excerpt), isTrue,
          reason: 'the excerpt must be a substring of its own unit body');
      expect(body.substring(first.excerptStart, first.excerptEnd),
          first.excerpt);
      expect(find.text('“${first.excerpt}”'), findsOneWidget,
          reason: 'the excerpt renders as-is, quoted, never reworded');
      expect(find.text('${first.chapterTitle}: ${first.unitTitle}'),
          findsOneWidget,
          reason: 'the source line joins chapter and card with a colon');

      expect(find.text('This manual does not answer that.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping an answer hands back its chapter, its card, and '
        'the content terms only', (tester) async {
      final expected = _expectedAnswers(_kAnswerable);
      expect(expected, isNotEmpty);
      final first = expected.first;

      await pumpSheet(tester);
      await ask(tester, _kAnswerable);

      await tester.tap(find.text('“${first.excerpt}”'));
      await tester.pump();

      expect(tappedAnswers, hasLength(1));
      expect(tappedAnswers.single.destinationId, _kDocId);
      expect(tappedAnswers.single.chapterIndex, first.chapterIndex);
      expect(tappedAnswers.single.unitIndex, first.unitIndex);
      expect(tappedResults, isEmpty,
          reason: 'an answer tap is not a word hit tap');

      final threaded = tappedHighlightQueries.single.split(' ');
      expect(threaded, first.matchedTerms,
          reason: 'the matched content terms travel, in query order');
      for (final stopword in _kStopwordsInQuery) {
        expect(threaded, isNot(contains(stopword)),
            reason: 'glue words must never reach the card highlighting');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing the question retires the pinned answer',
        (tester) async {
      expect(_expectedAnswers(_kAnswerable), isNotEmpty);

      await pumpSheet(tester);
      await ask(tester, _kAnswerable);
      expect(find.text('FROM THIS MANUAL'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'mezcal');
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('FROM THIS MANUAL'), findsNothing,
          reason: 'an answer must never describe a question the field no '
              'longer holds');
      expect(find.byKey(const ValueKey<String>('training_doc_search_results')),
          findsOneWidget,
          reason: 'the sheet falls back to the plain word search');
      expect(tester.takeException(), isNull);
    });
  });

  group('asking a question the manual does not answer', () {
    testWidgets('says so plainly and offers the web instead', (tester) async {
      expect(_expectedAnswers(_kUnanswerable), isEmpty,
          reason: 'sanity: the tequila manual knows nothing about France');

      await pumpSheet(tester);
      await ask(tester, '  $_kUnanswerable  ');

      expect(find.text('This manual does not answer that.'), findsOneWidget);
      expect(find.text('You can search the web instead.'), findsOneWidget);
      expect(find.text('Search the web'), findsOneWidget);
      expect(find.text('FROM THIS MANUAL'), findsNothing,
          reason: 'no weak excerpt is ever dressed as an answer');
      expect(
        find.text("No matches for '$_kUnanswerable' in this manual."),
        findsOneWidget,
        reason: 'the word matches below stay honest too',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the button hands the raw question to the screen',
        (tester) async {
      await pumpSheet(tester);
      await ask(tester, '  $_kUnanswerable  ');

      await tester.tap(find.text('Search the web'));
      await tester.pump();

      expect(webQueries, <String>[_kUnanswerable],
          reason: 'the reader\'s own words travel, trimmed but unchanged');
      expect(tappedAnswers, isEmpty);
      expect(tappedResults, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a question too short to run claims nothing', (tester) async {
      await pumpSheet(tester);
      await ask(tester, 'a');

      expect(find.text('This manual does not answer that.'), findsNothing,
          reason: 'the corpus was never searched, so the sheet says nothing '
              'about it');
      expect(find.text('FROM THIS MANUAL'), findsNothing);
      expect(find.text('WORD MATCHES'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('word search (no regression)', () {
    testWidgets('typing still lists in-manual hits and the honest empty '
        'state, with no answer block', (tester) async {
      await pumpSheet(tester);

      await tester.enterText(find.byType(TextField), 'mezcal');
      await tester.pump(const Duration(milliseconds: 250));
      final resultsList =
          find.byKey(const ValueKey<String>('training_doc_search_results'));
      expect(resultsList, findsOneWidget);
      expect(find.text('FROM THIS MANUAL'), findsNothing,
          reason: 'typing never asks; only submitting does');
      expect(find.text('WORD MATCHES'), findsNothing,
          reason: 'the divider only appears once something was asked');

      final hit = BarrioTrainingSearch.search(
        'mezcal',
        isDestinationAllowed: (id) => id == _kDocId,
      ).first;
      await tester.tap(
        find
            .descendant(of: resultsList, matching: find.text(hit.unitTitle))
            .first,
      );
      await tester.pump();
      expect(tappedResults, hasLength(1),
          reason: 'the word hit tap contract is untouched');
      expect(tappedResults.single.unitTitle, hit.unitTitle);

      await tester.enterText(find.byType(TextField), 'empanadas');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text("No matches for 'empanadas' in this manual."),
          findsOneWidget,
          reason: 'cross-manual terms keep the honest in-manual empty state');
      expect(tester.takeException(), isNull);
    });
  });

  group('accessibility', () {
    testWidgets('the answer card and the web button are labelled',
        (tester) async {
      final expected = _expectedAnswers(_kAnswerable);
      expect(expected, isNotEmpty);
      final handle = tester.ensureSemantics();

      await pumpSheet(tester);
      await ask(tester, _kAnswerable);
      expect(find.bySemanticsLabel(RegExp('^Answer from this manual')),
          findsNWidgets(expected.length),
          reason: 'every card announces what it is before reading it out');

      await ask(tester, _kUnanswerable);
      expect(find.text('Search the web'), findsOneWidget);
      expect(find.bySemanticsLabel('Search the web'), findsOneWidget,
          reason: 'the fallback button is one labelled button of its own, '
              'not the whole card announced as tappable');
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });
}
