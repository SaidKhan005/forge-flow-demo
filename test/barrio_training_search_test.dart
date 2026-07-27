// Service tests for the Wave B training search
// (lib/internal/barrio/search/barrio_training_search.dart).
//
// Pure Dart, no widgets: pins folding (case + Latin diacritics, both
// directions), single-word and multi-word AND matching, ranking (hit
// count desc, corpus-order ties), the minimum query length, snippet
// span correctness, the visibility filter hook, supervisor_content
// absence, and 20-doc coverage for a universal word.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';

/// Stable identity key for a result's unit (chapter-scoped).
String keyOf(BarrioTrainingSearchResult r) {
  return '${r.destinationId}|${r.chapterIndex}|${r.unitTitle}';
}

void main() {
  group('fold', () {
    test('lowercases ASCII and strips Latin diacritics', () {
      expect(BarrioTrainingSearch.fold('Jalapeño'), 'jalapeno');
      expect(
        BarrioTrainingSearch.fold('ÁéÎõÜÇ'),
        'aeiouc',
      );
    });

    test('is length-preserving so fold-space offsets map one-to-one', () {
      const mixed = 'Café con jalapeños ÑANDU 42!';
      expect(BarrioTrainingSearch.fold(mixed).length, mixed.length);
    });
  });

  group('search', () {
    test('single word matches the Tequila doc', () {
      final results = BarrioTrainingSearch.search('tequila');
      expect(results, isNotEmpty);
      expect(
        results.any((r) => r.destinationId == 'training_tequila'),
        isTrue,
      );
    });

    test('multi-word query ANDs all words within the same unit', () {
      final both = BarrioTrainingSearch.search('blue weber');
      expect(both, isNotEmpty);
      final blueKeys =
          BarrioTrainingSearch.search('blue').map(keyOf).toSet();
      final weberKeys =
          BarrioTrainingSearch.search('weber').map(keyOf).toSet();
      for (final r in both) {
        expect(blueKeys, contains(keyOf(r)),
            reason: 'every AND result must also match "blue" alone');
        expect(weberKeys, contains(keyOf(r)),
            reason: 'every AND result must also match "weber" alone');
      }
      // AND is stricter than either single word.
      expect(both.length, lessThanOrEqualTo(blueKeys.length));
      expect(both.length, lessThanOrEqualTo(weberKeys.length));
    });

    test('diacritic folding matches in both directions', () {
      final plain = BarrioTrainingSearch.search('jalapeno');
      final accented = BarrioTrainingSearch.search('jalapeño');
      expect(plain, isNotEmpty,
          reason: "'jalapeno' must match the corpus's 'jalapeño'");
      expect(accented.map(keyOf).toList(), plain.map(keyOf).toList(),
          reason: 'accented and plain queries return identical results');
    });

    test('ranks by hit count descending with corpus-order ties', () {
      // Corpus order: kBarrioTrainingDocs registry order, then chapter,
      // then unit (the map literal is insertion-ordered).
      final orderByKey = <String, int>{};
      var order = 0;
      kBarrioTrainingDocs.forEach((id, doc) {
        for (var c = 0; c < doc.chapters.length; c++) {
          for (final unit in doc.chapters[c].units) {
            orderByKey.putIfAbsent('$id|$c|${unit.title}', () => order);
            order++;
          }
        }
      });

      final results = BarrioTrainingSearch.search('agave');
      expect(results, isNotEmpty);
      for (var i = 1; i < results.length; i++) {
        final prev = results[i - 1];
        final curr = results[i];
        expect(curr.hitCount, lessThanOrEqualTo(prev.hitCount),
            reason: 'hit counts must be non-increasing');
        if (curr.hitCount == prev.hitCount) {
          expect(
            orderByKey[keyOf(curr)]!,
            greaterThanOrEqualTo(orderByKey[keyOf(prev)]!),
            reason: 'equal hit counts keep corpus order',
          );
        }
      }
    });

    test('queries shorter than 2 chars after trimming return nothing', () {
      expect(BarrioTrainingSearch.search(''), isEmpty);
      expect(BarrioTrainingSearch.search('a'), isEmpty);
      expect(BarrioTrainingSearch.search(' a '), isEmpty);
      expect(BarrioTrainingSearch.search('   '), isEmpty);
      // Exactly 2 chars is allowed.
      expect(BarrioTrainingSearch.search('te'), isNotEmpty);
    });

    test('snippet spans cover exactly the matched words', () {
      final results = BarrioTrainingSearch.search('jalapeno');
      expect(results, isNotEmpty);
      final snippet = results.first.snippet;
      expect(snippet.text.length,
          lessThanOrEqualTo(BarrioTrainingSearch.kSnippetWindow));
      expect(snippet.matchSpans, isNotEmpty,
          reason: 'a body match must produce bold spans');
      for (final span in snippet.matchSpans) {
        expect(span.start, greaterThanOrEqualTo(0));
        expect(span.end, lessThanOrEqualTo(snippet.text.length));
        expect(span.start, lessThan(span.end));
        // Offsets are fold-space == original-space (length-preserving
        // fold), so the folded slice must be exactly the query word.
        expect(
          BarrioTrainingSearch.fold(
            snippet.text.substring(span.start, span.end),
          ),
          'jalapeno',
        );
      }
    });

    test('supervisor_content never appears (it has no training doc)', () {
      for (final query in ['supervisor', 'content', 'the']) {
        final results = BarrioTrainingSearch.search(query);
        expect(
          results.any((r) => r.destinationId == 'supervisor_content'),
          isFalse,
          reason: "supervisor_content must never surface for '$query'",
        );
      }
    });

    test('a universal word reaches all 20 docs', () {
      final ids = BarrioTrainingSearch.search('the')
          .map((r) => r.destinationId)
          .toSet();
      expect(kBarrioTrainingDocs.length, 20);
      expect(ids, kBarrioTrainingDocs.keys.toSet(),
          reason: 'every registered doc must be searchable');
    });

    test('isDestinationAllowed excludes disallowed docs entirely', () {
      final filtered = BarrioTrainingSearch.search(
        'the',
        isDestinationAllowed: (id) => id == 'training_coffee',
      );
      expect(filtered, isNotEmpty);
      expect(
        filtered.map((r) => r.destinationId).toSet(),
        {'training_coffee'},
      );
    });

    test('every result carries the exact card position within its section',
        () {
      // 2026-07-11 operator request: opening a result lands on the
      // matched card, so unitIndex must address the unit whose title
      // the result reports.
      final results = BarrioTrainingSearch.search('marinade');
      expect(results, isNotEmpty);
      for (final r in results) {
        final chapter =
            kBarrioTrainingDocs[r.destinationId]!.chapters[r.chapterIndex];
        expect(r.unitIndex, inInclusiveRange(0, chapter.units.length - 1),
            reason: '${r.destinationId} unitIndex in range');
        expect(chapter.units[r.unitIndex].title, r.unitTitle,
            reason: 'unitIndex must address the reported unit');
      }
    });
  });
}
