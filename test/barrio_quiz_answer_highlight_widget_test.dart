// Widget tests for the chapter-end quiz answer highlight inside reading
// cards (operator request 2026-07-26, restyled 2026-07-27): a
// HandbookLessonCard renders, in its body, the verbatim phrase that answers
// each chapter-end quiz question in teal-colored, slightly bolder wording
// (NOT a background highlighter wash), so a learner can scan the key fact
// before the quiz.
//
// The card is self-sufficient: it looks up its own answer phrases by unit
// id, so these tests just render a real training unit and assert:
//   * a unit WITH quiz answer evidence renders the phrase as teal-COLORED
//     text with NO background, while the concatenated visible text stays
//     byte-identical to the source body (verbatim law: styling only);
//   * a unit with NO evidence renders unchanged (no teal answer span at all);
//   * overlap precedence: an answer phrase overlapping a search highlight
//     is not double-styled: the search highlight wins and the teal answer
//     span is dropped whole.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/quiz/barrio_quiz_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

// Style targets mirrored from _composeSpans in handbook_lesson_card.dart.
// The answer phrase is now teal-COLORED wording with NO background wash.
final Color _answerTeal = BarrioColors.tealDeep;
final Color _searchBg = BarrioColors.tealWarm.withValues(alpha: 0.28);

const _evidenceUnitId = 'training_food_safety_c0_u0';
const _evidencePhrase = 'each team member plays a vital role';
const _noEvidenceUnitId = 'training_food_safety_c17_u0';

HandbookUnit _unit(String id) => kBarrioTrainingDocs.values
    .expand((d) => d.chapters)
    .expand((c) => c.units)
    .firstWhere((u) => u.id == id);

/// Every leaf [TextSpan] under [span], in reading order.
List<TextSpan> _flatten(InlineSpan span) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      out.add(s);
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(span);
  return out;
}

/// A teal answer span: teal-colored wording with NO background wash. This
/// distinguishes it from the search highlight (which carries a tealWarm
/// background) and from the numeric fact pop (which uses the manual's
/// accent color, not tealDeep).
bool _isAnswerSpan(TextSpan s) =>
    s.style?.color == _answerTeal && s.style?.backgroundColor == null;

/// The body RichText of the card: the one whose plain text carries the
/// body prose (found by a distinctive fragment so it is never the title
/// or badge RichText).
RichText _bodyRich(WidgetTester tester, String needle) {
  return tester
      .widgetList<RichText>(find.byType(RichText))
      .firstWhere((rt) => rt.text.toPlainText().contains(needle));
}

Future<void> _pumpCard(
  WidgetTester tester,
  HandbookUnit unit, {
  List<String> highlightTerms = const [],
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HandbookLessonCard(
            unit: unit,
            highlightTerms: highlightTerms,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
      'a unit with quiz evidence renders the answer phrase in teal-colored '
      'text with no background while the visible text stays byte-identical',
      (tester) async {
    final unit = _unit(_evidenceUnitId);
    // Sanity: the reader looks this up itself; the phrase is present.
    expect(barrioAnswerEvidenceForUnit(unit.id), contains(_evidencePhrase));
    expect(unit.body.contains(_evidencePhrase), isTrue);

    await _pumpCard(tester, unit);

    final rich = _bodyRich(tester, _evidencePhrase);
    // Verbatim law: the concatenated visible text equals the source body.
    expect(rich.text.toPlainText(), unit.body);

    final spans = _flatten(rich.text);
    final teal = spans.where(_isAnswerSpan);
    expect(teal, hasLength(1),
        reason: 'exactly one teal answer span for the answer phrase');
    expect(teal.first.text, _evidencePhrase,
        reason: 'the teal span is exactly the verbatim answer phrase');
    expect(teal.first.style!.color, _answerTeal,
        reason: 'the answer phrase is teal-colored wording');
    expect(teal.first.style!.backgroundColor, isNull,
        reason: 'no highlighter background wash: teal wording only');
    expect(teal.first.style!.fontWeight, FontWeight.w600,
        reason: 'a semibold weight keeps the teal wording emphasized');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a unit with no quiz evidence renders unchanged: no teal span',
      (tester) async {
    final unit = _unit(_noEvidenceUnitId);
    // Sanity: this unit backs no non-null answer evidence.
    expect(barrioAnswerEvidenceForUnit(unit.id), isEmpty);

    await _pumpCard(tester, unit);

    final rich = _bodyRich(tester, 'Sanitizing refers to the reduction');
    expect(rich.text.toPlainText(), unit.body,
        reason: 'the body text is unchanged');
    final teal = _flatten(rich.text).where(_isAnswerSpan);
    expect(teal, isEmpty, reason: 'no answer highlight where none is defined');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'overlap precedence: an answer phrase overlapping a search highlight '
      'is not double-styled: the search highlight wins', (tester) async {
    final unit = _unit(_evidenceUnitId);
    // A search deep link folds query words; "member" sits inside the
    // answer phrase "each team member plays a vital role".
    final term = BarrioTrainingSearch.fold('member');

    await _pumpCard(tester, unit, highlightTerms: [term]);

    final rich = _bodyRich(tester, _evidencePhrase);
    expect(rich.text.toPlainText(), unit.body,
        reason: 'styling only: the body text is still byte-identical');

    final spans = _flatten(rich.text);
    final searchSpans =
        spans.where((s) => s.style?.backgroundColor == _searchBg);
    final tealSpans = spans.where(_isAnswerSpan);

    expect(searchSpans, isNotEmpty,
        reason: 'the search highlight renders on "member"');
    expect(searchSpans.map((s) => s.text).join(), contains('member'));
    expect(tealSpans, isEmpty,
        reason: 'the overlapping answer span is dropped whole, so the '
            'phrase is never double-styled (search wins)');
    expect(tester.takeException(), isNull);
  });
}
