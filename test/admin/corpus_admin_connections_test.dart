// C2 — Connections tab (redesigned) widget tests.
//
// Drives [CorpusAdminScreen] with the in-memory gateway seeded with a
// deterministic Graphify diff and exercises the redesigned Connections
// tab ([CorpusConnectionsView]):
//
//   * Summary card counts + honest clarity bucketing (clear / worth
//     checking / not sure), derived from each candidate's confidence
//     score (the same 0.7 low-confidence line the prior confidence chip
//     used, plus a 0.85 clear/mid split).
//   * A connection row renders the plain-English sentence + clarity chip.
//   * "Looks right" / "Not right" stage a decision and enable
//     "Save my choices (N)".
//   * "Save my choices" commits the staged batch through the gateway.
//   * Bulk "Mark all N correct" approves the clear set.
//   * The Change modal stages an edit (carrying edited_payload).
//   * Read-only (ff_support) hides every decide/save/bulk affordance but
//     still renders the connections.
//
// Reuses the existing graph-candidate test patterns (in-memory gateway,
// demo target, tab-label tap) from the now-replaced
// corpus_admin_graph_candidates_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_human_labels.dart';
import 'package:forge_and_flow/admin/models/corpus_admin_models.dart';
import 'package:forge_and_flow/admin/screens/corpus_admin_connections_map.dart';
import 'package:forge_and_flow/admin/screens/corpus_admin_connections_view.dart';
import 'package:forge_and_flow/admin/screens/corpus_admin_screen.dart';
import 'package:forge_and_flow/admin/services/corpus_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  // Demo target so the commit ("Save my choices") button stays enabled.
  const String demoTargetOperatorId = '00000000-0000-4000-8000-000000000001';
  const String demoTargetLocationId = '00000000-0000-4000-8000-0000000000a1';

  CorpusAdminScreen buildScreen({
    required CorpusAdminGateway gateway,
    bool editingEnabled = true,
    String? targetOperatorId = demoTargetOperatorId,
    String? targetLocationId = demoTargetLocationId,
  }) {
    return CorpusAdminScreen(
      gateway: gateway,
      editingEnabled: editingEnabled,
      targetOperatorId: targetOperatorId,
      targetLocationId: targetLocationId,
    );
  }

  /// Deterministic fixture spanning all three clarity buckets:
  ///   * two CLEAR edges (scores 0.94 + 0.90, >= 0.85).
  ///   * one WORTH-CHECKING edge (score 0.78, in [0.7, 0.85)).
  ///   * one NOT-SURE edge by low score (0.62, < 0.7).
  ///   * one NOT-SURE edge by AMBIGUOUS label (score 0.41).
  ///
  /// Clear/worth-checking IDs deliberately use stable, test-targetable
  /// candidate_ids. Producer buckets (extracted/inferred/ambiguous) are
  /// set to plausible values; the view re-buckets by clarity.
  GraphCandidateDiff buildDiff() {
    return GraphCandidateDiff(
      graphScope: 'methodology',
      graphVersion: '1',
      graphifyVersion: 'v5',
      graphifySourceCommit: 'fixture-commit',
      extracted: <GraphCandidate>[
        GraphCandidate(
          candidateId: 'edge:clear:manual:fifo:contains',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:manual:fifo:contains',
          candidateType: 'CONTAINS',
          label: GraphCandidateLabel.extracted,
          confidenceScore: 0.94,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:food_safety_manual',
          toNodeKey: 'graphify:fifo',
          payload: const <String, Object?>{
            'graphify_relation': 'CONTAINS',
            'label': 'manual CONTAINS fifo',
            'from_node_type': 'MANUAL',
            'to_node_type': 'SOP',
          },
        ),
        GraphCandidate(
          candidateId: 'edge:clear:manual:haccp:contains',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:manual:haccp:contains',
          candidateType: 'CONTAINS',
          label: GraphCandidateLabel.extracted,
          confidenceScore: 0.90,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:food_safety_manual',
          toNodeKey: 'graphify:haccp',
          payload: const <String, Object?>{
            'graphify_relation': 'CONTAINS',
            'label': 'manual CONTAINS haccp',
            'from_node_type': 'MANUAL',
            'to_node_type': 'SOP',
          },
        ),
      ],
      inferred: <GraphCandidate>[
        GraphCandidate(
          candidateId: 'edge:check:fourcs:contamination:reduces',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:fourcs:contamination:reduces',
          candidateType: 'REDUCES_RISK_OF',
          label: GraphCandidateLabel.inferred,
          confidenceScore: 0.78,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:the_four_cs',
          toNodeKey: 'graphify:cross_contamination',
          payload: const <String, Object?>{
            'graphify_relation': 'REDUCES_RISK_OF',
            'label': 'four cs reduce risk of contamination',
            'from_node_type': 'CONCEPT',
            'to_node_type': 'RISK',
          },
        ),
        GraphCandidate(
          candidateId: 'edge:lowscore:fifo:fourcs:informs',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:fifo:fourcs:informs',
          candidateType: 'INFORMS',
          label: GraphCandidateLabel.inferred,
          confidenceScore: 0.62,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:fifo',
          toNodeKey: 'graphify:the_four_cs',
          payload: const <String, Object?>{
            'graphify_relation': 'INFORMS',
            'label': 'fifo informs four cs',
            'from_node_type': 'SOP',
            'to_node_type': 'CONCEPT',
          },
        ),
      ],
      ambiguous: <GraphCandidate>[
        GraphCandidate(
          candidateId: 'edge:ambiguous:daypart:cycles:relates',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:daypart:cycles:relates',
          candidateType: 'RELATES_TO',
          label: GraphCandidateLabel.ambiguous,
          confidenceScore: 0.41,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:daypart',
          toNodeKey: 'graphify:cycles',
          payload: const <String, Object?>{
            'graphify_relation': 'NEAR',
            'label': 'daypart near cycles',
            'from_node_type': 'CONCEPT',
            'to_node_type': 'CONCEPT',
          },
        ),
      ],
    );
  }

  Future<void> openConnectionsTab(WidgetTester tester) async {
    final tabFinder = find.descendant(
      of: find.byKey(const Key('admin_corpus_tab_bar')),
      matching: find.text('Connections'),
    );
    await tester.tap(tabFinder);
    await tester.pumpAndSettle();
  }

  // ─── Pure bucketing + sentence helpers ───────────────────────────────

  group('clarity bucketing (honest, from confidence)', () {
    GraphCandidate edge(double? score, {GraphCandidateLabel? label}) =>
        GraphCandidate(
          candidateId: 'x',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:x',
          candidateType: 'CONTAINS',
          label: label ?? GraphCandidateLabel.extracted,
          confidenceScore: score,
          sourceFile: null,
          sourceRef: null,
          fromNodeKey: 'graphify:a',
          toNodeKey: 'graphify:b',
          payload: const <String, Object?>{},
        );

    test('score >= 0.85 is clear', () {
      expect(
        corpusConnectionClarity(edge(0.85)),
        CorpusConnectionClarity.clear,
      );
      expect(
        corpusConnectionClarity(edge(0.99)),
        CorpusConnectionClarity.clear,
      );
    });

    test('0.7 <= score < 0.85 is worth checking', () {
      expect(
        corpusConnectionClarity(edge(0.70)),
        CorpusConnectionClarity.check,
      );
      expect(
        corpusConnectionClarity(edge(0.84)),
        CorpusConnectionClarity.check,
      );
    });

    test('score < 0.7 is not sure', () {
      expect(
        corpusConnectionClarity(edge(0.69)),
        CorpusConnectionClarity.unsure,
      );
    });

    test('null score is not sure (honest: unknown)', () {
      expect(
        corpusConnectionClarity(edge(null)),
        CorpusConnectionClarity.unsure,
      );
    });

    test('AMBIGUOUS is always not sure, even with a high score', () {
      expect(
        corpusConnectionClarity(
          edge(0.99, label: GraphCandidateLabel.ambiguous),
        ),
        CorpusConnectionClarity.unsure,
      );
    });

    test('relationship verb maps known types and falls back honestly', () {
      expect(corpusRelationshipVerb('CONTAINS'), 'includes');
      expect(corpusRelationshipVerb('REDUCES_RISK_OF'), 'reduces the risk of');
      // Unknown type never invents a specific verb.
      expect(corpusRelationshipVerb('ZORP'), 'is related to');
      expect(corpusRelationshipVerb('RELATES_TO'), 'is related to');
    });

    test('sentence reads plainly for a clear edge', () {
      final s = corpusConnectionSentence(edge(0.94));
      expect(s, contains('includes'));
      expect(s.endsWith('.'), isTrue);
    });

    test('sentence is honest about uncertainty for a not-sure edge', () {
      final s = corpusConnectionSentence(
        edge(0.4, label: GraphCandidateLabel.ambiguous),
      );
      expect(s, contains('not clear how'));
    });

    test('node name strips the graphify prefix and spaces snake_case', () {
      expect(corpusConnectionNodeName('graphify:food_safety_manual'),
          'food safety manual');
      expect(corpusConnectionNodeName(null), 'this topic');
    });
  });

  // ─── Summary card + bucketing in the rendered tab ────────────────────

  testWidgets('summary card shows total + the three clarity counts', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    expect(
      find.byKey(const Key('admin_corpus_connections_summary')),
      findsOneWidget,
    );
    // 5 total connections in the fixture.
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsFound(5)),
      findsOneWidget,
    );
    // 2 clear, 1 worth checking, 2 not sure (one low-score + one
    // ambiguous).
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsClearChip(2)),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsCheckChip(1)),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsUnsureChip(2)),
      findsOneWidget,
    );
  });

  testWidgets('three clarity-grouped lists render (default "needs my '
      'attention" reveals check + not sure)', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // Default "Show" = needs my attention => check + not-sure groups show,
    // clear is hidden.
    expect(
      find.byKey(const Key('admin_corpus_connections_group_check')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_group_unsure')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_group_clear')),
      findsNothing,
    );

    // Switching "Show" to everything reveals the clear group too. The
    // Connections-only scope banner adds height above the summary, so make
    // the Show control visible before tapping it.
    final showDropdown = find.byKey(const Key('admin_corpus_connections_show'));
    await tester.ensureVisible(showDropdown);
    await tester.pumpAndSettle();
    await tester.tap(showDropdown);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(AdminKnowledgeBaseCopy.connectionsShowEverything(5)).last,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_corpus_connections_group_clear')),
      findsOneWidget,
    );
  });

  testWidgets('a connection row renders the plain-English sentence + clarity '
      'chip', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // The worth-checking row (visible by default) reads its sentence.
    final row = find.byKey(
      const Key(
        'admin_corpus_connection_tile_edge:check:fourcs:contamination:reduces',
      ),
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    // The full plain-English sentence renders (the verb also appears in
    // the from -> verb -> to flow above, which is expected).
    expect(
      find.descendant(
        of: row,
        matching: find.text(
          'the four cs reduces the risk of cross contamination.',
        ),
      ),
      findsOneWidget,
    );
    // Its clarity chip reads "Worth checking".
    expect(
      find.descendant(
        of: row,
        matching: find.text(AdminKnowledgeBaseCopy.connectionsClarityCheck),
      ),
      findsOneWidget,
    );
  });

  // ─── Staging + save ──────────────────────────────────────────────────

  testWidgets('"Looks right" stages an approve and enables "Save my '
      'choices (N)"', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // Save starts disabled (no decisions yet).
    final saveBtn = find.byKey(const Key('admin_corpus_connections_save'));
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(saveBtn).onPressed,
      isNull,
      reason: 'no decisions queued yet',
    );

    // Approve the worth-checking row via "Looks right".
    final approve = find.byKey(
      const Key(
        'admin_corpus_connection_approve_'
        'edge:check:fourcs:contamination:reduces',
      ),
    );
    await tester.ensureVisible(approve);
    await tester.pumpAndSettle();
    await tester.tap(approve);
    await tester.pumpAndSettle();

    // The row now carries a staged chip.
    expect(
      find.byKey(
        const Key(
          'admin_corpus_connection_staged_'
          'edge:check:fourcs:contamination:reduces',
        ),
      ),
      findsOneWidget,
    );
    // Save enables and reads "(1)".
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(saveBtn).onPressed, isNotNull);
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsSaveChoices(1)),
      findsOneWidget,
    );
  });

  testWidgets('"Not right" stages a reject and enables save', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    final reject = find.byKey(
      const Key(
        'admin_corpus_connection_reject_'
        'edge:check:fourcs:contamination:reduces',
      ),
    );
    await tester.ensureVisible(reject);
    await tester.pumpAndSettle();
    await tester.tap(reject);
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key(
          'admin_corpus_connection_staged_'
          'edge:check:fourcs:contamination:reduces',
        ),
      ),
      findsOneWidget,
    );
    final saveBtn = find.byKey(const Key('admin_corpus_connections_save'));
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(saveBtn).onPressed, isNotNull);
  });

  testWidgets('"Save my choices" commits the batch through the gateway', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // Reject the worth-checking edge, then save.
    final reject = find.byKey(
      const Key(
        'admin_corpus_connection_reject_'
        'edge:check:fourcs:contamination:reduces',
      ),
    );
    await tester.ensureVisible(reject);
    await tester.pumpAndSettle();
    await tester.tap(reject);
    await tester.pumpAndSettle();

    final saveBtn = find.byKey(const Key('admin_corpus_connections_save'));
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    // The reject landed in the audit log only (never canonical), proving
    // commitGraphCandidatesBatch ran with the staged decision.
    expect(gateway.debugRejectedAudit, hasLength(1));
    expect(
      gateway.debugRejectedAudit.single['candidate_id'],
      'edge:check:fourcs:contamination:reduces',
    );
    expect(gateway.debugApprovedNodes, isEmpty);
    expect(gateway.debugApprovedEdges, isEmpty);
  });

  // ─── Bulk "Mark all N correct" ───────────────────────────────────────

  testWidgets('bulk "Mark all N correct" approves the clear set', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // Reveal the clear group (switch Show to everything). Ensure the Show
    // control is visible first (the scope banner adds height above it).
    final showDropdown = find.byKey(const Key('admin_corpus_connections_show'));
    await tester.ensureVisible(showDropdown);
    await tester.pumpAndSettle();
    await tester.tap(showDropdown);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(AdminKnowledgeBaseCopy.connectionsShowEverything(5)).last,
    );
    await tester.pumpAndSettle();

    final markAll = find.byKey(
      const Key('admin_corpus_connections_mark_all_clear'),
    );
    await tester.ensureVisible(markAll);
    await tester.pumpAndSettle();
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsMarkAllCorrect(2)),
      findsOneWidget,
    );
    await tester.tap(markAll);
    await tester.pumpAndSettle();

    // Both clear edges are now staged (save reads "(2)").
    final saveBtn = find.byKey(const Key('admin_corpus_connections_save'));
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsSaveChoices(2)),
      findsOneWidget,
    );

    // Commit and assert the two clear edges landed in canonical storage.
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();
    expect(gateway.debugApprovedEdges, hasLength(2));
    expect(gateway.debugRejectedAudit, isEmpty);
  });

  // ─── Change modal stages an edit ─────────────────────────────────────

  testWidgets('the Change modal stages an edit carrying edited_payload', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // The not-sure (ambiguous) row leads with "Set how they connect".
    final setHow = find.byKey(
      const Key(
        'admin_corpus_connection_set_how_'
        'edge:ambiguous:daypart:cycles:relates',
      ),
    );
    await tester.ensureVisible(setHow);
    await tester.pumpAndSettle();
    await tester.tap(setHow);
    await tester.pumpAndSettle();

    // Modal opens.
    expect(
      find.byKey(const Key('admin_corpus_connection_change_dialog')),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsChangeTitle),
      findsOneWidget,
    );

    // Pick the "includes" (CONTAINS) sentence, then save the connection.
    final option = find.byKey(
      const Key('admin_corpus_connection_change_option_CONTAINS'),
    );
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_corpus_connection_change_dialog_save')),
    );
    await tester.pumpAndSettle();

    // The row is now staged as a change.
    expect(
      find.byKey(
        const Key(
          'admin_corpus_connection_staged_'
          'edge:ambiguous:daypart:cycles:relates',
        ),
      ),
      findsOneWidget,
    );

    // Commit; the edit resolves to an approved edge whose edge_type is the
    // chosen one and whose properties survived the round trip (so the
    // proxy's missing_edited_payload check would pass).
    final saveBtn = find.byKey(const Key('admin_corpus_connections_save'));
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    expect(gateway.debugApprovedEdges, hasLength(1));
    final approved = gateway.debugApprovedEdges.single;
    expect(approved['edge_type'], 'CONTAINS');
    final props = (approved['properties'] as Map?)?.cast<String, Object?>();
    expect(props, isNotNull);
    expect(props!['graphify_relation'], 'NEAR');
  });

  // ─── "Start over" clears pending ─────────────────────────────────────

  testWidgets('"Start over" clears every pending decision', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    final reject = find.byKey(
      const Key(
        'admin_corpus_connection_reject_'
        'edge:check:fourcs:contamination:reduces',
      ),
    );
    await tester.ensureVisible(reject);
    await tester.pumpAndSettle();
    await tester.tap(reject);
    await tester.pumpAndSettle();

    final startOver = find.byKey(
      const Key('admin_corpus_connections_start_over'),
    );
    await tester.ensureVisible(startOver);
    await tester.pumpAndSettle();
    await tester.tap(startOver);
    await tester.pumpAndSettle();

    // The staged chip is gone and save is disabled again.
    expect(
      find.byKey(
        const Key(
          'admin_corpus_connection_staged_'
          'edge:check:fourcs:contamination:reduces',
        ),
      ),
      findsNothing,
    );
    final saveBtn = find.byKey(const Key('admin_corpus_connections_save'));
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(saveBtn).onPressed, isNull);
  });

  // ─── Technical details disclosure ────────────────────────────────────

  testWidgets('machine IDs stay hidden until "Show technical details" is on', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // The worth-checking row (its "from" node is graphify:the_four_cs) is
    // visible by default. With tech details OFF, its machine IDs never
    // render.
    expect(find.textContaining('graphify:the_four_cs'), findsNothing);

    // Flip the screen-level toggle ON.
    final toggle = find.byKey(const Key('admin_corpus_tech_details_toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Now the from/to machine IDs surface in the row's technical block.
    expect(find.textContaining('graphify:the_four_cs'), findsWidgets);
  });

  // ─── Read-only (ff_support) ──────────────────────────────────────────

  testWidgets('read-only (ff_support) hides every decide/save/bulk '
      'affordance but still shows the connections', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(
      wrap(buildScreen(gateway: gateway, editingEnabled: false)),
    );
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // The read-only banner shows; the connections still render.
    expect(
      find.byKey(const Key('admin_corpus_connections_readonly_banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_summary')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_group_check')),
      findsOneWidget,
    );

    // Every mutate affordance is gone.
    expect(
      find.byKey(const Key('admin_corpus_connections_save')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_start_over')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_mark_all_clear')),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key(
          'admin_corpus_connection_approve_'
          'edge:check:fourcs:contamination:reduces',
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key(
          'admin_corpus_connection_reject_'
          'edge:check:fourcs:contamination:reduces',
        ),
      ),
      findsNothing,
    );
  });

  // ─── Empty state ─────────────────────────────────────────────────────

  testWidgets('honest empty state when there are no connections', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      graphCandidateSeed: const GraphCandidateDiff(
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: null,
        extracted: <GraphCandidate>[],
        inferred: <GraphCandidate>[],
        ambiguous: <GraphCandidate>[],
      ),
    );
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    expect(
      find.byKey(const Key('admin_corpus_connections_empty')),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsEmpty),
      findsOneWidget,
    );
  });

  // ─── C2-map: focusable connection Map ────────────────────────────────

  group('focus map model (pure, from the diff)', () {
    test('topics list the distinct edge endpoints, sorted', () {
      final model = CorpusMapModel.fromDiff(buildDiff());
      expect(model.hasGraph, isTrue);
      // Endpoint names are the human-readable (de-prefixed) topic names.
      expect(
        model.topics,
        containsAll(<String>[
          'cross contamination',
          'cycles',
          'daypart',
          'fifo',
          'food safety manual',
          'haccp',
          'the four cs',
        ]),
      );
      // Sorted for a stable dropdown order.
      final sorted = [...model.topics]..sort();
      expect(model.topics, sorted);
      // Honest total = every edge candidate in the diff (5 in the fixture).
      expect(model.totalEdges, 5);
    });

    test('focusing on a topic returns only its directly-connected edges '
        'with the plain-English verb + clarity', () {
      final model = CorpusMapModel.fromDiff(
        buildDiff(),
        focusTopic: 'food safety manual',
      );
      expect(model.focus, 'food safety manual');
      // The manual connects to FIFO + HACCP, both "includes", both clear.
      expect(model.edges, hasLength(2));
      expect(
        model.edges.map((e) => e.otherName),
        containsAll(<String>['fifo', 'haccp']),
      );
      for (final edge in model.edges) {
        expect(edge.verb, 'includes');
        expect(edge.clarity, CorpusConnectionClarity.clear);
        expect(edge.outbound, isTrue);
      }
    });

    test('a worth-checking edge keeps its warning clarity in the model', () {
      final model = CorpusMapModel.fromDiff(
        buildDiff(),
        focusTopic: 'the four cs',
      );
      expect(model.focus, 'the four cs');
      final edge = model.edges.singleWhere(
        (e) => e.otherName == 'cross contamination',
      );
      expect(edge.verb, 'reduces the risk of');
      expect(edge.clarity, CorpusConnectionClarity.check);
    });

    test('an invalid focus falls back to the first topic (never null when '
        'there is a graph)', () {
      final model = CorpusMapModel.fromDiff(
        buildDiff(),
        focusTopic: 'not a real topic',
      );
      expect(model.focus, isNotNull);
      expect(model.topics, contains(model.focus));
    });

    test('no edge candidates => no graph (honest, never fabricated)', () {
      const empty = GraphCandidateDiff(
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: null,
        extracted: <GraphCandidate>[],
        inferred: <GraphCandidate>[],
        ambiguous: <GraphCandidate>[],
      );
      final model = CorpusMapModel.fromDiff(empty);
      expect(model.hasGraph, isFalse);
      expect(model.focus, isNull);
      expect(model.edges, isEmpty);
      expect(model.totalEdges, 0);
    });

    test('clarity colours reuse the C2 theme tokens', () {
      expect(
        corpusMapClarityColor(CorpusConnectionClarity.clear),
        AppColors.positive,
      );
      expect(
        corpusMapClarityColor(CorpusConnectionClarity.check),
        AppColors.warning,
      );
      expect(
        corpusMapClarityColor(CorpusConnectionClarity.unsure),
        AppColors.textMuted,
      );
    });
  });

  testWidgets('the Map renders, centred on the first topic, with a caption + '
      'legend', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    final map = find.byKey(const Key('admin_corpus_connections_map'));
    await tester.ensureVisible(map);
    await tester.pumpAndSettle();
    expect(map, findsOneWidget);
    // The diagram (CustomPaint host) renders, not the old placeholder.
    expect(
      find.byKey(const Key('admin_corpus_connections_map_diagram')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_map_placeholder')),
      findsNothing,
    );
    // The caption + legend render.
    expect(
      find.byKey(const Key('admin_corpus_connections_map_caption')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_map_legend')),
      findsOneWidget,
    );
    // The first topic alphabetically is "cross contamination"; the caption
    // is centred on it and reads the honest total (5).
    expect(
      find.text(
        AdminKnowledgeBaseCopy.connectionsMapCaption(
          // cross contamination only appears as the TO of one edge, so it
          // has a single inbound link.
          1,
          5,
          'cross contamination',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the focus dropdown re-centres the diagram on the chosen topic '
      '(edge with its verb + clarity colour)', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    final focus = find.byKey(const Key('admin_corpus_connections_map_focus'));
    await tester.ensureVisible(focus);
    await tester.pumpAndSettle();
    await tester.tap(focus);
    await tester.pumpAndSettle();
    // Pick the Food Safety Manual.
    await tester.tap(find.text('food safety manual').last);
    await tester.pumpAndSettle();

    // The caption now reads "Showing 2 of 5 ... centred on food safety
    // manual" (the manual's two CLEAR "includes" edges).
    expect(
      find.text(
        AdminKnowledgeBaseCopy.connectionsMapCaption(2, 5, 'food safety manual'),
      ),
      findsOneWidget,
    );

    // The painter draws the real edges: prove the model the diagram is
    // built from carries the plain-English verb + clear-clarity colour.
    final model = CorpusMapModel.fromDiff(
      buildDiff(),
      focusTopic: 'food safety manual',
    );
    expect(model.edges, hasLength(2));
    expect(model.edges.first.verb, 'includes');
    expect(
      corpusMapClarityColor(model.edges.first.clarity),
      AppColors.positive,
    );
  });

  testWidgets('honest empty-map state when there is no graph data', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      // One single-NODE candidate only: there are nodes but NO edges, so
      // there is nothing to map. The map must show its honest empty state,
      // never a fabricated diagram. (The lists still render the node.)
      graphCandidateSeed: GraphCandidateDiff(
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: null,
        extracted: <GraphCandidate>[
          GraphCandidate(
            candidateId: 'node:lonely',
            kind: GraphCandidateKind.node,
            candidateKey: 'graphify:lonely_topic',
            candidateType: 'CONCEPT',
            label: GraphCandidateLabel.extracted,
            confidenceScore: 0.95,
            sourceFile: 'methodology_seed.md',
            sourceRef: null,
            payload: const <String, Object?>{'label': 'lonely topic'},
          ),
        ],
        inferred: const <GraphCandidate>[],
        ambiguous: const <GraphCandidate>[],
      ),
    );
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    final map = find.byKey(const Key('admin_corpus_connections_map'));
    await tester.ensureVisible(map);
    await tester.pumpAndSettle();
    expect(map, findsOneWidget);
    // Honest empty state, no fabricated diagram.
    expect(
      find.byKey(const Key('admin_corpus_connections_map_empty')),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsMapEmpty),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_map_diagram')),
      findsNothing,
    );
  });

  // ─── No commit target: save disabled (safety) ────────────────────────

  testWidgets('no target operator/location: save stays disabled even with a '
      'queued decision (cannot write to wrong tenant)', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(
      wrap(
        buildScreen(
          gateway: gateway,
          targetOperatorId: null,
          targetLocationId: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    final reject = find.byKey(
      const Key(
        'admin_corpus_connection_reject_'
        'edge:check:fourcs:contamination:reduces',
      ),
    );
    await tester.ensureVisible(reject);
    await tester.pumpAndSettle();
    await tester.tap(reject);
    await tester.pumpAndSettle();

    final saveBtn = find.byKey(const Key('admin_corpus_connections_save'));
    await tester.ensureVisible(saveBtn);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(saveBtn).onPressed,
      isNull,
      reason: 'no commit target configured: save must stay disabled',
    );
    expect(gateway.debugApprovedEdges, isEmpty);
    expect(gateway.debugRejectedAudit, isEmpty);

    // C2-map gap close: an honest hint near the disabled Save button tells
    // the operator how to enable it (pick a scope), without re-adding the
    // old in-tab operator picker.
    final hint = find.byKey(
      const Key('admin_corpus_connections_no_target_hint'),
    );
    await tester.ensureVisible(hint);
    await tester.pumpAndSettle();
    expect(hint, findsOneWidget);
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsNoTargetHint),
      findsOneWidget,
    );
  });

  testWidgets('with a commit target the no-target hint stays hidden', (
    tester,
  ) async {
    // The demo/test path always supplies a target (canSave true), so the
    // hint must not show.
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    expect(
      find.byKey(const Key('admin_corpus_connections_no_target_hint')),
      findsNothing,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsNoTargetHint),
      findsNothing,
    );
  });

  // ─── Connections-only scope banner; no bespoke in-tab scope control ──

  testWidgets('the Connections-only scope banner renders on the Connections '
      'tab, NOT on the Knowledge tab, and the old bespoke scope control is '
      'gone', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        CorpusBundle(
          version: CorpusVersionRef(
            versionId: 'v-scope',
            createdBy: 'seed',
            createdAt: DateTime.utc(2026, 1, 1),
            summary: 'scope check',
            rollbackOf: null,
            supersededAt: null,
            chunkCount: 1,
          ),
          chunks: const <ChunkPreview>[
            ChunkPreview(
              chunkId: 'food_safety_manual.md#001',
              docId: 'food_safety_manual.md',
              sourcePath: 'food_safety_manual.md',
              headingPath: <String>['FIFO (First In, First Out)'],
              snippet: 'Rotate stock so the oldest is used first.',
              estimatedTokens: 40,
              riskLevel: 'standard',
              contentSha256: 'aa',
              versionId: 'v-scope',
              active: true,
            ),
          ],
        ),
      ],
      graphCandidateSeed: buildDiff(),
    );
    await tester.pumpWidget(
      wrap(
        CorpusAdminScreen(
          gateway: gateway,
          targetOperatorId: demoTargetOperatorId,
          targetLocationId: demoTargetLocationId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The bespoke in-Connections scope strip (#1400) is removed: neither
    // it nor its change button exist anywhere on the screen.
    expect(
      find.byKey(const Key('admin_corpus_connections_scope_control')),
      findsNothing,
      reason: 'the bespoke in-tab scope control is removed (operator-LOCKED)',
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_scope_change')),
      findsNothing,
    );

    // Knowledge tab is the default: it carries no scope banner and no scope
    // picker (knowledge documents are global Forge & Flow content).
    expect(
      find.byKey(const Key('admin_corpus_connections_scope_banner')),
      findsNothing,
      reason: 'the scope banner belongs only to the Connections tab',
    );

    await openConnectionsTab(tester);

    // Connections tab: the short plain-English scope banner renders.
    final banner = find.byKey(
      const Key('admin_corpus_connections_scope_banner'),
    );
    await tester.ensureVisible(banner);
    await tester.pumpAndSettle();
    expect(banner, findsOneWidget);
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsScopeBanner),
      findsOneWidget,
    );
  });

  testWidgets('read-only (ff_support) shows no scope banner (it never '
      'approves) but still renders the connections', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(
      wrap(buildScreen(gateway: gateway, editingEnabled: false)),
    );
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // The scope banner is edit-only: read-only support never picks a scope.
    expect(
      find.byKey(const Key('admin_corpus_connections_scope_banner')),
      findsNothing,
    );
    // The connections still render (the read-only banner is asserted by the
    // dedicated read-only test above).
    expect(
      find.byKey(const Key('admin_corpus_connections_summary')),
      findsOneWidget,
    );
  });

  // ─── Count reconciliation: summary == sum of bucket lists ────────────

  testWidgets('the summary counts equal the sum of the bucket lists', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    // The fixture is 2 clear + 1 worth-checking + 2 not-sure = 5 total.
    // The headline names the total; each clarity chip names its bucket;
    // and the three add up to the total. Reveal every group so each
    // bucket's count pill is on screen. Ensure the Show control is visible
    // first (the scope banner adds height above it).
    final showDropdown = find.byKey(const Key('admin_corpus_connections_show'));
    await tester.ensureVisible(showDropdown);
    await tester.pumpAndSettle();
    await tester.tap(showDropdown);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(AdminKnowledgeBaseCopy.connectionsShowEverything(5)).last,
    );
    await tester.pumpAndSettle();

    const clear = 2, check = 1, unsure = 2, total = 5;
    expect(clear + check + unsure, total);
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsFound(total)),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsClearChip(clear)),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsCheckChip(check)),
      findsOneWidget,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsUnsureChip(unsure)),
      findsOneWidget,
    );
    // Each clarity-grouped list renders, so the buckets that sum to the
    // total are all present (their count pills mirror the chip counts).
    expect(
      find.byKey(const Key('admin_corpus_connections_group_clear')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_group_check')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_connections_group_unsure')),
      findsOneWidget,
    );
  });

  testWidgets('an empty clarity bucket drops its summary chip (no '
      '"0 worth checking" noise)', (tester) async {
    // All-clear fixture: no worth-checking, no not-sure. The empty chips
    // must not render (de-clutter: a "0" chip is noise, not signal).
    final gateway = InMemoryCorpusAdminGateway(
      graphCandidateSeed: GraphCandidateDiff(
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: null,
        extracted: <GraphCandidate>[
          GraphCandidate(
            candidateId: 'edge:clear:only',
            kind: GraphCandidateKind.edge,
            candidateKey: 'graphify:edge:clear:only',
            candidateType: 'CONTAINS',
            label: GraphCandidateLabel.extracted,
            confidenceScore: 0.95,
            sourceFile: 'methodology_seed.md',
            sourceRef: null,
            fromNodeKey: 'graphify:a',
            toNodeKey: 'graphify:b',
            payload: const <String, Object?>{
              'from_node_type': 'MANUAL',
              'to_node_type': 'SOP',
            },
          ),
        ],
        inferred: const <GraphCandidate>[],
        ambiguous: const <GraphCandidate>[],
      ),
    );
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openConnectionsTab(tester);

    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsClearChip(1)),
      findsOneWidget,
    );
    // The empty buckets' chips are gone (not rendered as "0 ...").
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsCheckChip(0)),
      findsNothing,
    );
    expect(
      find.text(AdminKnowledgeBaseCopy.connectionsUnsureChip(0)),
      findsNothing,
    );
  });
}
