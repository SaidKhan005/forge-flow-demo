// Service tests for the offline extractive question answering
// (lib/internal/barrio/search/barrio_training_answers.dart).
//
// Pure Dart, no widgets: pins determinism (identical query, identical
// answers; ties keep corpus order), the verbatim-excerpt law over a
// battery of queries, the confidence thresholds (an in-corpus question
// answers, an out-of-corpus question returns nothing, an all-stopword
// question falls back honestly without throwing), normalization parity
// (question form vs bare terms; plain vs accented spellings), light
// plural probing, and doc scoping via the visibility filter.
//
// Corpus assertions are written invariant-style against
// kBarrioTrainingDocs (offsets, substring identity, ordering rules)
// rather than as golden excerpt strings, so content regeneration does
// not break them.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_answers.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';

/// Stable identity key for an answer's unit.
String keyOf(BarrioTrainingAnswer a) {
  return '${a.destinationId}|${a.chapterIndex}|${a.unitIndex}';
}

/// The source body the answer claims to excerpt.
String bodyOf(BarrioTrainingAnswer a) {
  return kBarrioTrainingDocs[a.destinationId]!
      .chapters[a.chapterIndex]
      .units[a.unitIndex]
      .body;
}

/// Asserts two ask() runs produced field-identical answer lists.
void expectSameAnswers(
  List<BarrioTrainingAnswer> a,
  List<BarrioTrainingAnswer> b, {
  bool compareScores = true,
}) {
  expect(b.length, a.length);
  for (var i = 0; i < a.length; i++) {
    expect(keyOf(b[i]), keyOf(a[i]), reason: 'answer $i unit identity');
    expect(b[i].excerptStart, a[i].excerptStart, reason: 'answer $i start');
    expect(b[i].excerptEnd, a[i].excerptEnd, reason: 'answer $i end');
    expect(b[i].excerpt, a[i].excerpt, reason: 'answer $i excerpt');
    expect(b[i].confidence, a[i].confidence, reason: 'answer $i confidence');
    expect(b[i].matchedTerms, a[i].matchedTerms,
        reason: 'answer $i matched terms');
    if (compareScores) {
      expect(b[i].score, a[i].score, reason: 'answer $i score');
    }
  }
}

void main() {
  group('determinism', () {
    test('identical queries return identical answers', () {
      for (final query in [
        'agave',
        'what is the origin of tequila',
        'how do i handle a guest complaint',
      ]) {
        final first = BarrioTrainingAnswers.ask(query);
        final second = BarrioTrainingAnswers.ask(query);
        expectSameAnswers(first, second);
      }
    });

    test('answers are score-sorted with corpus-order ties', () {
      // Corpus order: kBarrioTrainingDocs registry order, then chapter,
      // then unit (the map is insertion-ordered).
      final orderByKey = <String, int>{};
      var order = 0;
      kBarrioTrainingDocs.forEach((id, doc) {
        for (var c = 0; c < doc.chapters.length; c++) {
          for (var u = 0; u < doc.chapters[c].units.length; u++) {
            orderByKey['$id|$c|$u'] = order;
            order++;
          }
        }
      });

      for (final query in ['agave', 'espresso', 'food safety temperature']) {
        final answers = BarrioTrainingAnswers.ask(query);
        for (var i = 1; i < answers.length; i++) {
          final prev = answers[i - 1];
          final curr = answers[i];
          expect(curr.score, lessThanOrEqualTo(prev.score),
              reason: 'scores must be non-increasing for "$query"');
          if (curr.score == prev.score) {
            expect(
              orderByKey[keyOf(curr)]!,
              greaterThan(orderByKey[keyOf(prev)]!),
              reason: 'equal scores keep corpus order for "$query"',
            );
          }
        }
      }
    });
  });

  group('verbatim excerpt law', () {
    const battery = [
      'what is the origin of tequila',
      'tequila',
      'agave',
      'jalapeno',
      'espresso',
      'food safety temperature danger zone',
      'how do i greet a guest at the host stand',
      'suggestive selling',
      'clover order',
      'labour cost percentage',
      'what does barrio mean',
      'menu',
    ];

    test('excerpt is always an exact substring at its stated offsets', () {
      for (final query in battery) {
        final answers = BarrioTrainingAnswers.ask(query);
        for (final a in answers) {
          final body = bodyOf(a);
          expect(a.excerptStart, greaterThanOrEqualTo(0),
              reason: '"$query" start in range');
          expect(a.excerptEnd, lessThanOrEqualTo(body.length),
              reason: '"$query" end in range');
          expect(a.excerptStart, lessThan(a.excerptEnd),
              reason: '"$query" non-empty span');
          expect(
            a.excerpt,
            body.substring(a.excerptStart, a.excerptEnd),
            reason: '"$query" excerpt must be the verbatim substring',
          );
        }
      }
    });

    test('excerpts are edge-trimmed and answers address a real card', () {
      for (final query in battery) {
        for (final a in BarrioTrainingAnswers.ask(query)) {
          expect(a.excerpt.trim(), a.excerpt,
              reason: '"$query" excerpt has no edge whitespace');
          final doc = kBarrioTrainingDocs[a.destinationId]!;
          expect(a.chapterIndex, inInclusiveRange(0, doc.chapters.length - 1));
          final chapter = doc.chapters[a.chapterIndex];
          expect(a.unitIndex, inInclusiveRange(0, chapter.units.length - 1));
          expect(chapter.units[a.unitIndex].title, a.unitTitle,
              reason: '"$query" unitIndex must address the reported unit');
          expect(a.chapterTitle, chapter.title);
          expect(a.docTitle, doc.title);
        }
      }
    });

    test('multi-sentence excerpts respect the extension cap', () {
      // Extension stops at the cap; only a single uncut sentence may
      // exceed it, and a single sentence contains no internal
      // ender-plus-whitespace boundary by construction.
      final internalBoundary = RegExp(r'[.!?][\s]');
      for (final query in battery) {
        for (final a in BarrioTrainingAnswers.ask(query)) {
          final length = a.excerptEnd - a.excerptStart;
          if (length > BarrioTrainingAnswers.kExcerptCap) {
            expect(
              internalBoundary.hasMatch(
                a.excerpt.substring(0, a.excerpt.length - 1),
              ),
              isFalse,
              reason: '"$query" over-cap excerpt must be one sentence',
            );
          }
        }
      }
    });
  });

  group('thresholds and honesty', () {
    test('an in-corpus question answers from its manual', () {
      final answers = BarrioTrainingAnswers.ask('what is the origin of tequila');
      expect(answers, isNotEmpty);
      expect(answers.first.destinationId, 'training_tequila');
      expect(answers.first.confidence, BarrioAnswerConfidence.answer);
      // The seed sentence covers all content terms, and the excerpt
      // contains the seed, so both terms appear (in some folded form).
      final folded = BarrioTrainingSearch.fold(answers.first.excerpt);
      expect(folded, contains('origin'));
      expect(folded, contains('tequila'));
      expect(
        BarrioTrainingAnswers.overallConfidence(answers),
        BarrioAnswerConfidence.answer,
      );
    });

    test('an out-of-corpus question returns nothing (none tier)', () {
      final answers =
          BarrioTrainingAnswers.ask('what is the capital of france');
      expect(answers, isEmpty);
      expect(
        BarrioTrainingAnswers.overallConfidence(answers),
        BarrioAnswerConfidence.none,
      );
    });

    test('all-stopword query never throws and never claims an answer', () {
      late List<BarrioTrainingAnswer> answers;
      expect(
        () => answers = BarrioTrainingAnswers.ask('what is the'),
        returnsNormally,
      );
      for (final a in answers) {
        expect(a.confidence, isNot(BarrioAnswerConfidence.answer),
            reason: 'glue words alone must never grade as an answer');
      }
      expect(
        BarrioTrainingAnswers.overallConfidence(answers),
        isNot(BarrioAnswerConfidence.answer),
      );
    });

    test('too-short and empty queries return nothing', () {
      expect(BarrioTrainingAnswers.ask(''), isEmpty);
      expect(BarrioTrainingAnswers.ask('a'), isEmpty);
      expect(BarrioTrainingAnswers.ask(' a '), isEmpty);
      expect(BarrioTrainingAnswers.ask('   '), isEmpty);
      expect(BarrioTrainingAnswers.ask('?!'), isEmpty,
          reason: 'punctuation-only queries tokenize to nothing');
    });

    test('matched terms are content terms only, in query order', () {
      final answers = BarrioTrainingAnswers.ask('what is the origin of tequila');
      expect(answers, isNotEmpty);
      for (final a in answers) {
        expect(a.matchedTerms, isNotEmpty);
        for (final term in a.matchedTerms) {
          expect(['origin', 'tequila'], contains(term),
              reason: 'stopwords must never surface as highlight terms');
        }
        // Query order is preserved: origin before tequila when both matched.
        if (a.matchedTerms.length == 2) {
          expect(a.matchedTerms, ['origin', 'tequila']);
        }
      }
    });
  });

  group('normalization parity', () {
    test('question form equals bare content terms', () {
      final asQuestion =
          BarrioTrainingAnswers.ask('What is the origin of tequila?');
      final asTerms = BarrioTrainingAnswers.ask('origin tequila');
      expect(asQuestion, isNotEmpty);
      expectSameAnswers(asQuestion, asTerms);
    });

    test('plain and accented spellings answer identically', () {
      final plain = BarrioTrainingAnswers.ask('jalapeno');
      final accented = BarrioTrainingAnswers.ask('jalapeño');
      expect(plain, isNotEmpty,
          reason: "'jalapeno' must match the corpus's 'jalapeño'");
      expectSameAnswers(plain, accented);
    });

    test('light plural probing reaches the same manual', () {
      final singular = BarrioTrainingAnswers.ask('origin tequila');
      final plural = BarrioTrainingAnswers.ask('origins tequila');
      expect(singular, isNotEmpty);
      expect(plural, isNotEmpty);
      expect(singular.first.destinationId, 'training_tequila');
      expect(plural.first.destinationId, 'training_tequila');
    });
  });

  group('doc scoping', () {
    test('answers never leave the allowed destination set', () {
      final scoped = BarrioTrainingAnswers.ask(
        'what is the origin of tequila',
        isDestinationAllowed: (id) => id == 'training_tequila',
      );
      expect(scoped, isNotEmpty);
      expect(
        scoped.map((a) => a.destinationId).toSet(),
        {'training_tequila'},
      );
    });

    test('scoping to another manual excludes the obvious owner', () {
      // The in-manual sheet must never surface a cross-manual answer:
      // asked inside the coffee manual, a tequila question may only
      // answer from the coffee manual (or not at all).
      final scoped = BarrioTrainingAnswers.ask(
        'what is the origin of tequila',
        isDestinationAllowed: (id) => id == 'training_coffee',
      );
      for (final a in scoped) {
        expect(a.destinationId, 'training_coffee');
      }
    });

    test('a filter that allows nothing returns nothing', () {
      final scoped = BarrioTrainingAnswers.ask(
        'tequila',
        isDestinationAllowed: (_) => false,
      );
      expect(scoped, isEmpty);
    });
  });
}
