// Phase 11A.3a follow-up — Graph candidates commit unblock.
//
// The 11A.3a launch slice landed the Corpus admin "Graph candidates"
// tab with the commit button gated behind a target (operator,
// location) pair. Live mode left the targets null, so a banner
// directed the admin to wait for the operator-picker slice and the
// commit button stayed disabled.
//
// This test asserts the picker unblocks that path: with the
// operator-picker opener wired and a queued decision in flight,
// resolving a pair flips the commit button from disabled to enabled.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/corpus_admin_models.dart';
import 'package:forge_and_flow/admin/screens/corpus_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/services/corpus_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  GraphCandidateDiff buildDiff() {
    return GraphCandidateDiff(
      graphScope: 'methodology',
      graphVersion: '1',
      graphifyVersion: 'v5',
      graphifySourceCommit: 'fixture-commit',
      extracted: <GraphCandidate>[
        GraphCandidate(
          candidateId: 'edge:fixture:doc:section:contains',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:fixture_doc:section:contains',
          candidateType: 'CONTAINS',
          label: GraphCandidateLabel.extracted,
          confidenceScore: 0.92,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:fixture_doc',
          toNodeKey: 'graphify:fixture_section',
          payload: const <String, Object?>{
            'graphify_relation': 'CONTAINS',
            'label': 'doc CONTAINS section',
          },
        ),
      ],
      inferred: const <GraphCandidate>[],
      ambiguous: const <GraphCandidate>[],
    );
  }

  Future<void> openGraphCandidatesTab(WidgetTester tester) async {
    final tabFinder = find.descendant(
      of: find.byKey(const Key('admin_corpus_tab_bar')),
      matching: find.text('Relationship review'),
    );
    await tester.tap(tabFinder);
    await tester.pumpAndSettle();
  }

  testWidgets('commit button enables once the picker resolves a (operator, '
      'location) pair (live-mode unblock for 11A.3a graph commits)', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    const resolved = OperatorPickerResult(
      operatorId: '00000000-0000-4000-8000-0000000000aa',
      locationId: '00000000-0000-4000-8000-0000000000bb',
      operatorBusinessName: 'Picked Operator',
      locationName: 'Picked Location',
    );
    var openerCalls = 0;
    Future<OperatorPickerResult?> stubOpener(BuildContext _) async {
      openerCalls++;
      return resolved;
    }

    await tester.pumpWidget(
      wrap(
        CorpusAdminScreen(
          gateway: gateway,
          // Live-mode-pre-pick wiring: targets explicitly null so
          // the screen renders the no-target banner with the new
          // "Pick operator" button.
          targetOperatorId: null,
          targetLocationId: null,
          operatorPickerOpener: stubOpener,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    // Banner is visible with the "Pick operator" button.
    expect(
      find.byKey(const Key('admin_corpus_graph_no_target_banner')),
      findsOneWidget,
    );
    final pickButton = find.byKey(
      const Key('admin_corpus_graph_pick_operator_button'),
    );
    expect(pickButton, findsOneWidget);
    // The picked-target indicator is absent before resolution.
    expect(
      find.byKey(const Key('admin_corpus_graph_picked_target_indicator')),
      findsNothing,
    );

    // Queue a decision while target is unresolved — the commit
    // button must stay disabled because the destination is unknown.
    final bulkApprove = find.byKey(
      const Key('admin_corpus_graph_bulk_approve_extracted'),
    );
    await tester.ensureVisible(bulkApprove);
    await tester.pumpAndSettle();
    await tester.tap(bulkApprove);
    await tester.pumpAndSettle();

    var commitWidget = tester.widget<FilledButton>(
      find.byKey(const Key('admin_corpus_graph_commit_button')),
    );
    expect(
      commitWidget.onPressed,
      isNull,
      reason: 'commit must stay disabled while target is unresolved',
    );

    // Tap "Pick operator" — stub returns the resolved pair.
    await tester.ensureVisible(pickButton);
    await tester.pumpAndSettle();
    await tester.tap(pickButton);
    await tester.pumpAndSettle();
    expect(openerCalls, equals(1));

    // Banner is gone; the picked-target indicator renders the
    // confirmed (operator, location) label for the rest of the
    // session.
    expect(
      find.byKey(const Key('admin_corpus_graph_no_target_banner')),
      findsNothing,
    );
    final indicator = find.byKey(
      const Key('admin_corpus_graph_picked_target_indicator'),
    );
    expect(indicator, findsOneWidget);
    expect(
      find.descendant(
        of: indicator,
        matching: find.textContaining('Picked Operator'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: indicator,
        matching: find.textContaining('Picked Location'),
      ),
      findsOneWidget,
    );

    // Commit button now enables — the queued decision survives the
    // resolution because the screen state holds the queue.
    commitWidget = tester.widget<FilledButton>(
      find.byKey(const Key('admin_corpus_graph_commit_button')),
    );
    expect(
      commitWidget.onPressed,
      isNotNull,
      reason:
          'commit must enable once the picker resolves a pair '
          'and a decision is queued',
    );
  });
}
