// Regression guards for the "search that never stalls" pass
// (premium + performance audit A3 and A7, 2026-07-31).
//
// These are cost guards, not feature tests: the features themselves are
// covered by barrio_training_search_test.dart (fold, AND semantics,
// ranking, snippet spans), barrio_home_search_widget_test.dart (the
// results sliver and its deep link), and
// barrio_training_doc_search_index_test.dart (the A-Z sheet). What is
// pinned here is that the same behaviour is now paid for at the right
// moment:
//
//   A3.1  The folded corpus is warmed in chunks off the first frame,
//         and a warmed corpus is indistinguishable from one a query
//         folded in place. That equivalence is the before/after proof:
//         the in-place path IS the original one-shot build.
//   A3.2  The home results sliver memoizes, so an unrelated rebuild
//         does not re-run the scan.
//   A3.3  A result's snippet is built on first read and cached, so
//         reading it later (or out of order) yields the same snippet
//         the eager path produced.
//   A7    The A-Z sheet's flattened row model keeps the exact header /
//         entry order the eagerly-built widget list produced.
//
// Explicit pumps only, 390x844 phone viewport, mirroring the other
// Barrio suites.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_search.dart';
import 'package:forge_and_flow/internal/barrio/widgets/training_doc_index_sheet.dart';

/// A representative query set: a 2-character query (the cheapest to
/// type and the most expensive to answer, since it scores hundreds of
/// units), a single word, a multi-word AND, a diacritic query, a query
/// that lands in the newest manual, and one that matches nothing.
const _kQueries = <String>[
  'te',
  'mezcal',
  'blue weber',
  'jalapeño',
  'wine',
  'zzqx',
];

/// Everything a result renders or routes with, as one comparable
/// string. Reading `snippet` is deliberate: it forces the deferred
/// snippet so the comparison covers its text, spans, and cut flags.
String _serialize(BarrioTrainingSearchResult r) {
  final snippet = r.snippet;
  final spans =
      snippet.matchSpans.map((s) => '${s.start}-${s.end}').join(',');
  return <String>[
    r.destinationId,
    r.docTitle,
    '${r.chapterIndex}',
    r.chapterTitle,
    '${r.unitIndex}',
    r.unitTitle,
    '${r.hitCount}',
    '${snippet.cutAtStart}',
    '${snippet.cutAtEnd}',
    spans,
    snippet.text,
  ].join('|');
}

/// Result counts plus the serialized head of each query's hit list.
/// The head is capped so a 2-character query does not turn the guard
/// into a corpus-wide snippet build, while the counts still pin the
/// full result set.
Map<String, Object> _snapshotQueries() {
  final out = <String, Object>{};
  for (final query in _kQueries) {
    final results = BarrioTrainingSearch.search(query);
    out['$query::count'] = results.length;
    out['$query::head'] = <String>[
      for (final r in results.take(25)) _serialize(r),
    ];
  }
  return out;
}

/// Hosts the results sliver next to something unrelated, so a
/// `setState` that changes only the unrelated part still rebuilds the
/// sliver. That is the exact shape of the home-screen rebuilds A3.2 is
/// about (a reading-progress future landing, an app-lifecycle change).
class _UnrelatedRebuildHarness extends StatefulWidget {
  final String query;

  const _UnrelatedRebuildHarness({required this.query});

  @override
  State<_UnrelatedRebuildHarness> createState() =>
      _UnrelatedRebuildHarnessState();
}

class _UnrelatedRebuildHarnessState extends State<_UnrelatedRebuildHarness> {
  int _unrelated = 0;

  void bumpUnrelated() => setState(() => _unrelated++);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(child: Text('unrelated $_unrelated')),
            BarrioHomeSearchResults(
              query: widget.query,
              previewRole: BarrioPreviewRole.admin,
              onResultTap: (_, __) {},
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  const phoneSize = Size(390, 844);

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  group('A3.1 corpus warm', () {
    test('warmUp folds the corpus in chunks, without running a search',
        () async {
      BarrioTrainingSearch.debugResetCorpus();
      final searchesBefore = BarrioTrainingSearch.debugSearchCallCount;

      final warming = BarrioTrainingSearch.warmUp();
      // Chunked, not one blocking pass: the first chunk runs
      // synchronously and the rest is spread over later event-loop
      // turns, so the corpus is NOT complete the moment warmUp returns.
      expect(
        BarrioTrainingSearch.isCorpusWarm,
        isFalse,
        reason: 'a single synchronous fold would stall the frame it lands on',
      );

      await warming;
      expect(BarrioTrainingSearch.isCorpusWarm, isTrue);
      expect(
        BarrioTrainingSearch.debugSearchCallCount,
        searchesBefore,
        reason: 'warming is pure fold work; it must not run a query',
      );

      // Idempotent: a second mount joins nothing and rebuilds nothing.
      await BarrioTrainingSearch.warmUp();
      expect(BarrioTrainingSearch.isCorpusWarm, isTrue);
    });

    test('a query that arrives mid-warm still sees the whole corpus',
        () async {
      // Reference answer, with no warm anywhere near it.
      BarrioTrainingSearch.debugResetCorpus();
      final reference =
          BarrioTrainingSearch.search('mezcal').map(_serialize).toList();
      expect(reference, isNotEmpty);

      BarrioTrainingSearch.debugResetCorpus();
      final warming = BarrioTrainingSearch.warmUp();
      expect(BarrioTrainingSearch.isCorpusWarm, isFalse);

      // Beats the warm to the corpus: it must finish the fold in place
      // rather than answer from the units folded so far. Comparing
      // against the reference (not just against itself) is the point:
      // a partial corpus would answer consistently and still be wrong.
      final midWarm =
          BarrioTrainingSearch.search('mezcal').map(_serialize).toList();
      expect(BarrioTrainingSearch.isCorpusWarm, isTrue);
      expect(midWarm, reference);

      await warming;
      final afterWarm =
          BarrioTrainingSearch.search('mezcal').map(_serialize).toList();
      expect(afterWarm, reference);
    });

    test('results are identical whether the corpus was warmed in chunks '
        'or folded in place by the query', () async {
      // The in-place path is the original one-shot build, so this is a
      // literal before/after comparison of the new warm machinery.
      BarrioTrainingSearch.debugResetCorpus();
      final foldedInPlace = _snapshotQueries();

      BarrioTrainingSearch.debugResetCorpus();
      await BarrioTrainingSearch.warmUp();
      expect(BarrioTrainingSearch.isCorpusWarm, isTrue);
      final warmed = _snapshotQueries();

      expect(warmed, foldedInPlace);

      // Sanity: the set really does exercise a wide 2-character query,
      // a narrow one, and a miss, so "identical" means something.
      expect(foldedInPlace['te::count'] as int, greaterThan(200),
          reason: 'a 2-char query is the unbounded-materialization case');
      expect(foldedInPlace['mezcal::count'] as int, greaterThan(0));
      expect(foldedInPlace['wine::count'] as int, greaterThan(0));
      expect(foldedInPlace['zzqx::count'], 0);
    });
  });

  group('A3.3 deferred snippet', () {
    test('a snippet is built once and does not depend on when it is read',
        () async {
      BarrioTrainingSearch.debugResetCorpus();
      await BarrioTrainingSearch.warmUp();

      final forward = BarrioTrainingSearch.search('marinade');
      expect(forward, isNotEmpty);
      final readInOrder = forward.map(_serialize).toList();

      // Same query, fresh result objects, snippets read last-to-first
      // with unrelated searches interleaved. Deferring must not let
      // anything about the read order leak into the snippet.
      final shuffled = BarrioTrainingSearch.search('marinade');
      BarrioTrainingSearch.search('te');
      for (final r in shuffled.reversed) {
        r.snippet;
      }
      BarrioTrainingSearch.search('blue weber');
      expect(shuffled.map(_serialize).toList(), readInOrder);

      // Cached, not rebuilt: the same object every read.
      final one = shuffled.first;
      expect(identical(one.snippet, one.snippet), isTrue);
    });
  });

  group('A3.2 home results memoization', () {
    testWidgets('an unrelated setState does not re-run the search',
        (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(
        const _UnrelatedRebuildHarness(query: 'mezcal'),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('unrelated 0'), findsOneWidget);

      final afterFirstBuild = BarrioTrainingSearch.debugSearchCallCount;
      expect(afterFirstBuild, greaterThan(0),
          reason: 'sanity: the first build must have searched once');

      final state = tester.state<_UnrelatedRebuildHarnessState>(
        find.byType(_UnrelatedRebuildHarness),
      );
      for (var i = 0; i < 3; i++) {
        state.bumpUnrelated();
        await tester.pump(const Duration(milliseconds: 20));
      }
      // Proof the rebuilds really reached the sliver's subtree.
      expect(find.text('unrelated 3'), findsOneWidget);
      expect(
        BarrioTrainingSearch.debugSearchCallCount,
        afterFirstBuild,
        reason: 'the scan must not re-run when only the query is unchanged',
      );

      // Positive control: a real query change still searches, so the
      // counter above is measuring something live.
      await tester.pumpWidget(
        const _UnrelatedRebuildHarness(query: 'tequila'),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(BarrioTrainingSearch.debugSearchCallCount,
          greaterThan(afterFirstBuild));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an app-lifecycle rebuild of the real home screen does not '
        're-run the search', (tester) async {
      usePhoneViewport(tester);
      await tester.pumpWidget(const MaterialApp(home: BarrioHomeScreen()));
      await tester.pump(const Duration(milliseconds: 1000));

      await tester.enterText(find.byType(TextField), 'mezcal');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 50));

      final expected = BarrioTrainingSearch.search('mezcal').first;
      expect(find.text(expected.docTitle), findsWidgets,
          reason: 'sanity: the query is live and rendering results');

      final afterQuery = BarrioTrainingSearch.debugSearchCallCount;
      // The home screen's own setState path: backgrounding flips
      // _animationsEnabled and rebuilds the whole shelf, results and
      // all, without touching the query.
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(expected.docTitle), findsWidgets,
          reason: 'the same results stay on screen across the rebuild');
      expect(
        BarrioTrainingSearch.debugSearchCallCount,
        afterQuery,
        reason: 'an unrelated home rebuild must not re-scan the corpus',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('A7 A-Z index sheet rows', () {
    testWidgets('the flattened row model keeps letter-header / entry order',
        (tester) async {
      usePhoneViewport(tester);
      // Fixture picked from the live registry, not pinned: glossaries
      // gain and lose terms, so the guard asks for whichever of the
      // three TERM manuals currently has the longest index.
      const glossaryIds = <String>[
        'training_latin_ingredients',
        'training_latin_dishes',
        'training_general_words',
      ];
      BarrioTrainingDoc? doc;
      var groups = const <TrainingIndexGroup>[];
      for (final id in glossaryIds) {
        final candidate = kBarrioTrainingDocs[id]!;
        final candidateGroups = buildTrainingIndexGroups(candidate);
        final rows = candidateGroups.fold<int>(
          0,
          (sum, g) => sum + 1 + g.entries.length,
        );
        final best = groups.fold<int>(0, (sum, g) => sum + 1 + g.entries.length);
        if (rows > best) {
          doc = candidate;
          groups = candidateGroups;
        }
      }
      // The order the eagerly-built widget list produced: each group's
      // letter header, then that group's entries.
      final expected = <String>[
        for (final group in groups) ...<String>[
          group.letter,
          for (final entry in group.entries) entry.title,
        ],
      ];
      expect(doc, isNotNull);
      expect(expected.length, greaterThan(60),
          reason: 'the longest glossary index must be many screenfuls, '
              'or "only the visible rows mounted" proves nothing');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrainingDocIndexSheet(
              doc: doc!,
              accent: BarrioColors.tealWarm,
              onEntryTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final rendered = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(
                const ValueKey<String>('training_doc_index_list'),
              ),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .whereType<String>()
          .toList();

      expect(rendered, isNotEmpty);
      expect(rendered.length, lessThan(expected.length),
          reason: 'itemBuilder must mount only the rows near the viewport');
      expect(rendered, expected.take(rendered.length).toList());
      expect(tester.takeException(), isNull);
    });
  });
}
