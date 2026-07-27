// Rendering coverage for the giant-manual STRUCTURE pass
// (operator-approved 2026-07-26). The DATA (part grouping, section merge,
// depth badge) is locked by barrio_training_structure_test.dart; this file
// locks that the reader actually SEES the structure:
//
//   1. Rail unit: a slim 'PART k' separator marks each new named part
//      boundary, and never before the very first part. Manuals without
//      part grouping render no separators (plain rail as before).
//   2. Screen level: the hero shows the active chapter's
//      'PART k OF n: Name' line and the doc-level 'DEEPER DIVE' badge.
//
// Per-card run-chip rendering and the in-card depth badge live in the
// fenced handbook_lesson_card.dart and are deferred (see the PR body); the
// run metadata datum they read is already emitted and tested.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_chapter_rail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Six single-card chapters grouped into three named parts of two.
const List<String> _partNames = <String>[
  'Foundations Fixture',
  'Middle Fixture',
  'Closing Fixture',
];

List<HandbookChapter> _partedChapters() => [
      for (var i = 0; i < 6; i++)
        HandbookChapter(
          id: 'ch_$i',
          title: 'Chapter ${i + 1}',
          subtitle: 'section ${i + 1}',
          iconCodePoint: 0xe533,
          partTitle: _partNames[i ~/ 2],
          partIndex: (i ~/ 2) + 1,
          partCount: 3,
          units: [
            HandbookUnit(
              id: 'ch_${i}_u0',
              type: HandbookUnitType.explainer,
              title: 'Chapter ${i + 1}',
              body: 'Body for chapter ${i + 1}.',
            ),
          ],
        ),
    ];

List<HandbookChapter> _plainChapters() => [
      for (var i = 0; i < 3; i++)
        HandbookChapter(
          id: 'plain_$i',
          title: 'Plain ${i + 1}',
          subtitle: 'section ${i + 1}',
          iconCodePoint: 0xe533,
          units: [
            HandbookUnit(
              id: 'plain_${i}_u0',
              type: HandbookUnitType.explainer,
              title: 'Plain ${i + 1}',
              body: 'Body for plain ${i + 1}.',
            ),
          ],
        ),
    ];

void main() {
  const phoneSize = Size(390, 844);

  Widget railHarness(List<HandbookChapter> chapters) => MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HandbookChapterRail(
                  chapters: chapters,
                  activeIndex: 0,
                  completedChapterIds: const <String>{},
                  activeAccent: BarrioColors.tealWarm,
                  onChapterTap: (_) {},
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      );

  testWidgets('rail marks each new part boundary and never the first part',
      (tester) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(railHarness(_partedChapters()));
    await tester.pumpAndSettle();

    // Part 2 and Part 3 each get a boundary separator; part 1 starts the
    // rail so it gets none (no leading separator).
    expect(find.text('PART 2'), findsOneWidget);
    expect(find.text('PART 3'), findsOneWidget);
    expect(find.text('PART 1'), findsNothing);
  });

  testWidgets('rail renders no part separators for an ungrouped manual',
      (tester) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(railHarness(_plainChapters()));
    await tester.pumpAndSettle();

    expect(find.textContaining('PART '), findsNothing);
  });

  testWidgets('hero shows the active part line and the DEEPER DIVE badge',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final doc = BarrioTrainingDoc(
      id: 'structure_render_fixture',
      title: 'Structure Render Fixture',
      sourcePath: 'test://structure-render',
      chapters: _partedChapters(),
      depthBadge: 'DEEPER DIVE',
    );

    await tester.pumpWidget(MaterialApp(home: TrainingDocScreen(doc: doc)));
    // setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    // Active chapter is 0 -> part 1 of 3.
    expect(find.textContaining('PART 1 OF 3: Foundations Fixture'),
        findsOneWidget);
    // Doc-level depth badge rides the hero eyebrow.
    expect(find.text('DEEPER DIVE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
