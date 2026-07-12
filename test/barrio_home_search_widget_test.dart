// Widget tests for the Wave B home training search
// (lib/internal/barrio/widgets/home/barrio_home_search.dart plus the
// shelf bodyOverride slot, route-map threading, and the
// TrainingDocScreen deep link).
//
// All at a 390x844 phone viewport. The home screen runs looping
// ambient motion (falling leaves, scrim breathing, center-bubble arc):
// NEVER pumpAndSettle in this suite; pump explicit durations only.
// Debounce is ~200ms, so every enterText is followed by a >=250ms pump
// (no pending timers leak past a test).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destination_visibility_resolver.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/search/barrio_training_search.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_bubble.dart';
import 'package:forge_and_flow/internal/barrio/widgets/home/barrio_home_search.dart';

/// B18 resolver that denies everything: proves the resolver wins over
/// the preview-role fallback (resolver-first, like the shelf bubbles).
class _DenyAllResolver implements BarrioDestinationVisibilityResolver {
  const _DenyAllResolver();

  @override
  bool isVisible(BarrioDestination destination) => false;
}

void main() {
  const phoneSize = Size(390, 844);

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpHome(WidgetTester tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: BarrioHomeScreen()));
    // Let the one-shot entrance (900ms) and header wordmark (700ms)
    // finish. Looping ambient motion continues; explicit pumps only.
    await tester.pump(const Duration(milliseconds: 1000));
  }

  Future<void> typeQuery(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    // Cross the ~200ms debounce, then settle one frame.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets(
      'typing a Tequila Training query shows results and tapping opens '
      'the matched section', (tester) async {
    await pumpHome(tester);
    await typeQuery(tester, 'mezcal');

    // The UI must show exactly what the service ranks first.
    final expected = BarrioTrainingSearch.search('mezcal').first;
    expect(expected.destinationId, 'training_tequila',
        reason: 'sanity: mezcal is a Tequila Training query');
    expect(find.text(expected.docTitle), findsWidgets,
        reason: 'result rows carry the doc title');
    expect(find.text(expected.chapterTitle), findsWidgets,
        reason: 'result rows carry the section title');

    // Legibility pin (operator report 2026-07-11): result rows sit over
    // the home photo, so their card must be near-opaque, not a wash.
    final rowBox = tester.widget<Container>(
      find
          .ancestor(
            of: find.text(expected.docTitle).first,
            matching: find.byType(Container),
          )
          .first,
    );
    final rowColor = (rowBox.decoration as BoxDecoration?)?.color;
    expect(rowColor, isNotNull, reason: 'result row has a card fill');
    expect(rowColor!.a, greaterThan(0.85),
        reason: 'result card must be near-opaque for legibility');

    // The center bubble and category sections are replaced while active.
    expect(find.byType(BarrioHomeCenterBubble), findsNothing);
    expect(find.text('Company & Compliance'), findsNothing);

    await tester.tap(find.text(expected.docTitle).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byType(TrainingDocScreen), findsOneWidget);
    final total =
        kBarrioTrainingDocs[expected.destinationId]!.chapters.length;
    expect(
      find.text('SECTION ${expected.chapterIndex + 1} OF $total'),
      findsOneWidget,
      reason: 'the deep link must open the matched section',
    );

    // 2026-07-11 operator request: the searched word is highlighted on
    // the opened card. The landed card body must carry at least one
    // span whose text matches the query and whose style paints the
    // highlight background.
    bool spanIsHighlightedMatch(InlineSpan span) {
      var found = false;
      span.visitChildren((child) {
        if (child is TextSpan &&
            (child.text ?? '').toLowerCase().contains('mezcal') &&
            child.style?.backgroundColor != null) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    final highlighted = tester
        .widgetList<RichText>(find.byType(RichText))
        .any((rt) => spanIsHighlightedMatch(rt.text));
    expect(highlighted, isTrue,
        reason: "the query word must render highlighted on the card");
    expect(tester.takeException(), isNull);

    // Dispose the pushed screen's animations cleanly.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clearing the query restores the shelf without replaying '
      'the entrance', (tester) async {
    await pumpHome(tester);
    await typeQuery(tester, 'tequila');
    expect(find.byType(BarrioHomeCenterBubble), findsNothing);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(BarrioHomeCenterBubble), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Company & Compliance'), findsOneWidget);

    // Entrance does not replay: the restored section renders fully
    // settled (opacity 1.0) immediately after the swap-back.
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('Company & Compliance'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, 1.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nonsense query renders the honest empty state',
      (tester) async {
    await pumpHome(tester);
    await typeQuery(tester, 'zzqx');

    expect(find.text("No matches for 'zzqx'"), findsOneWidget);
    expect(find.byType(BarrioHomeCenterBubble), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('staff preview tier excludes manager-only docs from the '
      'results (B18)', (tester) async {
    usePhoneViewport(tester);

    // Real tier case: training_labour_cost is manager/admin-only, so
    // the staff tier must exclude it entirely. Sanity-check that the
    // unfiltered service DOES rank it, so the exclusion is meaningful.
    final labourTitle = kBarrioTrainingDocs['training_labour_cost']!.title;
    expect(
      BarrioTrainingSearch.search('the')
          .any((r) => r.destinationId == 'training_labour_cost'),
      isTrue,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: CustomScrollView(
            slivers: [
              BarrioHomeSearchResults(
                query: 'the',
                previewRole: BarrioPreviewRole.staff,
                onResultTap: (_, __) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // A staff-visible result renders.
    final staffFirst = BarrioTrainingSearch.search(
      'the',
      isDestinationAllowed: (id) {
        final dest = barrioDestinations.firstWhere((d) => d.id == id);
        return BarrioPreviewRole.staff.isIntendedFor(dest);
      },
    ).first;
    expect(find.text(staffFirst.docTitle), findsWidgets);

    // The excluded doc never renders, along the whole scrolled extent
    // we sample. The product surface has no training doc and can never
    // appear either.
    for (var i = 0; i < 10; i++) {
      expect(find.text(labourTitle), findsNothing);
      expect(find.text('Forge & Flow'), findsNothing);
      await tester.drag(
          find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deny-all resolver wins over the admin preview role '
      '(resolver-first, B18)', (tester) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: CustomScrollView(
            slivers: [
              BarrioHomeSearchResults(
                query: 'the',
                previewRole: BarrioPreviewRole.admin,
                visibilityResolver: const _DenyAllResolver(),
                onResultTap: (_, __) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text("No matches for 'the'"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TrainingDocScreen clamps initialChapterIndex to the valid '
      'range', (tester) async {
    usePhoneViewport(tester);
    final doc = kBarrioTrainingDocs['training_tequila']!;
    final total = doc.chapters.length;

    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: doc, initialChapterIndex: 999)),
    );
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.text('SECTION $total OF $total'), findsOneWidget,
        reason: 'an out-of-range deep link clamps to the last section');

    // Reset the tree so the second screen runs its own initState
    // (same widget type in the same slot would otherwise reuse state).
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: doc, initialChapterIndex: -5)),
    );
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.text('SECTION 1 OF $total'), findsOneWidget,
        reason: 'a negative deep link clamps to the first section');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
