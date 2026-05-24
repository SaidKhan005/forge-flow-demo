// Phase 11A.3b — Corpus admin "Graph candidates" tab widget tests.
//
// Drives [CorpusAdminScreen] with the in-memory gateway seeded with
// the demo Graphify diff. The screen must:
//
//   * Render both tabs (Versions + Graph candidates) and switch.
//   * Load and render the three classification sections (EXTRACTED,
//     INFERRED, AMBIGUOUS) with their own keys.
//   * Surface a low-confidence warning chip on candidates whose
//     score is < 0.7.
//   * Bulk-approve the EXTRACTED bucket; per-row approve the
//     INFERRED bucket; per-row edit the AMBIGUOUS bucket via dialog.
//   * Commit the queued batch through the gateway and split the
//     decisions: approves land in `debugApprovedNodes` /
//     `debugApprovedEdges`; rejects land in `debugRejectedAudit`
//     ONLY (no canonical write).
//   * Show the AGE rebuild banner when the rebuild button is
//     pressed (the launch-slice 501 stub message).
//   * Hide every mutate affordance when `editingEnabled: false` (the
//     `ff_support` read-only path) and still render the diff.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/corpus_admin_models.dart';
import 'package:forge_and_flow/admin/screens/corpus_admin_screen.dart';
import 'package:forge_and_flow/admin/services/corpus_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  /// Demo target the widget tests pass to [CorpusAdminScreen]. The
  /// screen no longer defaults a target operator (the live route
  /// in admin_routes.dart leaves them null until the operator
  /// picker ships, and silently defaulting to demo IDs would
  /// route production commits to a non-existent tenant). Tests
  /// pass a stable demo pair so the commit button stays enabled
  /// and the routes that depend on a target can run.
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

  /// Builds a deterministic Graphify diff fixture covering all three
  /// buckets. Mirrors the demo seed shape but with stable
  /// candidate_ids the tests can target.
  GraphCandidateDiff buildDiff() {
    return GraphCandidateDiff(
      graphScope: 'methodology',
      graphVersion: '1',
      graphifyVersion: 'v5',
      graphifySourceCommit: 'fixture-commit',
      extracted: <GraphCandidate>[
        GraphCandidate(
          candidateId: 'node:fixture:doc',
          kind: GraphCandidateKind.node,
          candidateKey: 'graphify:fixture_doc',
          candidateType: 'Document',
          label: GraphCandidateLabel.extracted,
          confidenceScore: 0.95,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          payload: const <String, Object?>{'label': 'Fixture Doc'},
        ),
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
      inferred: <GraphCandidate>[
        GraphCandidate(
          candidateId: 'edge:fixture:section:concept:informs',
          kind: GraphCandidateKind.edge,
          candidateKey: 'graphify:edge:fixture_section:fixture_concept:informs',
          candidateType: 'INFORMS',
          // Score 0.62 is below the 0.7 warning threshold so the
          // chip flips to its low-confidence variant.
          confidenceScore: 0.62,
          label: GraphCandidateLabel.inferred,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:fixture_section',
          toNodeKey: 'graphify:fixture_concept',
          payload: const <String, Object?>{
            'graphify_relation': 'INFORMS',
            'label': 'section INFORMS concept',
          },
        ),
      ],
      ambiguous: <GraphCandidate>[
        GraphCandidate(
          candidateId: 'edge:fixture:concept:other:relates',
          kind: GraphCandidateKind.edge,
          candidateKey:
              'graphify:edge:fixture_concept:fixture_other:relates_to',
          candidateType: 'RELATES_TO',
          label: GraphCandidateLabel.ambiguous,
          confidenceScore: 0.41,
          sourceFile: 'methodology_seed.md',
          sourceRef: null,
          fromNodeKey: 'graphify:fixture_concept',
          toNodeKey: 'graphify:fixture_other',
          payload: const <String, Object?>{
            'graphify_relation': 'NEAR',
            'label': 'concept near other concept',
          },
        ),
      ],
    );
  }

  /// Switches to the "Connections" tab (the Graph-candidates tab,
  /// renamed from "Relationship review" in #1263). The Tab widget keys
  /// are scoped inside the TabBar and not directly findable through
  /// `find.byKey()` (Flutter's TabBar wraps each child in its own
  /// internal builder), so we tap the tab label text instead: the
  /// TabBar guarantees that text is unique within the bar.
  Future<void> openGraphCandidatesTab(WidgetTester tester) async {
    final tabFinder = find.descendant(
      of: find.byKey(const Key('admin_corpus_tab_bar')),
      matching: find.text('Connections'),
    );
    await tester.tap(tabFinder);
    await tester.pumpAndSettle();
  }

  testWidgets('tab bar renders both Versions and Graph candidates tabs', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    // The TabBar itself carries `admin_corpus_tab_bar` and is
    // findable through `find.byKey`. The two `Tab` children carry
    // their own keys but Flutter's TabBar wraps each child in an
    // internal builder so the per-tab keys do not survive into the
    // element tree `find.byKey` walks; assert the tab labels through
    // text matching scoped inside the bar instead.
    expect(find.byKey(const Key('admin_corpus_tab_bar')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('admin_corpus_tab_bar')),
        matching: find.text('Knowledge'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('admin_corpus_tab_bar')),
        matching: find.text('Connections'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('switching to Graph candidates tab loads the seed and renders '
      'all three classification sections', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    expect(
      find.byKey(const Key('admin_corpus_graph_tab_body')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_graph_extracted_section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_graph_inferred_section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_graph_ambiguous_section')),
      findsOneWidget,
    );
    expect(find.textContaining('fixture-commit'), findsNothing);
    expect(find.textContaining('methodology_seed.md'), findsNothing);

    await tester.tap(
      find.byKey(const Key('admin_corpus_graph_review_advanced')),
    );
    await tester.pumpAndSettle();
    expect(find.text('fixture-commit'), findsOneWidget);

    final candidateDetails = find.byKey(
      const Key('admin_corpus_graph_candidate_details_node:fixture:doc'),
    );
    await tester.ensureVisible(candidateDetails);
    await tester.pumpAndSettle();
    await tester.tap(candidateDetails);
    await tester.pumpAndSettle();
    expect(find.textContaining('methodology_seed.md'), findsOneWidget);
  });

  testWidgets('low-confidence candidate (< 0.7) renders the warning chip', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    // The fixture INFERRED edge carries score 0.62, below the 0.7
    // threshold the screen uses for the warning chip variant. The
    // candidate id below is the same one buildDiff() seeds.
    expect(
      find.byKey(
        const Key(
          'admin_corpus_graph_candidate_warning_'
          'edge:fixture:section:concept:informs',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('bulk-approve EXTRACTED queues every candidate in that bucket', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    final bulkApprove = find.byKey(
      const Key('admin_corpus_graph_bulk_approve_extracted'),
    );
    await tester.ensureVisible(bulkApprove);
    await tester.pumpAndSettle();
    await tester.tap(bulkApprove);
    await tester.pumpAndSettle();

    // Both EXTRACTED candidates should now show their staged-decision
    // chip (the screen marks every queued row with a chip keyed
    // `admin_corpus_graph_staged_<candidate_id>`).
    expect(
      find.byKey(const Key('admin_corpus_graph_staged_node:fixture:doc')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'admin_corpus_graph_staged_edge:fixture:doc:section:contains',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('per-row approve on the INFERRED candidate queues that one', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    final approveButton = find.byKey(
      const Key(
        'admin_corpus_graph_candidate_approve_'
        'edge:fixture:section:concept:informs',
      ),
    );
    // Default test surface (800x600) is smaller than the rendered
    // diff; scroll the button into view before tapping so the hit
    // test resolves on a visible widget.
    await tester.ensureVisible(approveButton);
    await tester.pumpAndSettle();
    await tester.tap(approveButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key(
          'admin_corpus_graph_staged_'
          'edge:fixture:section:concept:informs',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'per-row edit on the AMBIGUOUS candidate opens the type-field dialog',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        graphCandidateSeed: buildDiff(),
      );
      await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
      await tester.pumpAndSettle();
      await openGraphCandidatesTab(tester);

      final editButton = find.byKey(
        const Key(
          'admin_corpus_graph_candidate_edit_'
          'edge:fixture:concept:other:relates',
        ),
      );
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_corpus_graph_candidates_edit_dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_corpus_graph_candidates_edit_dialog_type_field'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'commit batch routes approves to canonical and rejects to audit only',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        graphCandidateSeed: buildDiff(),
      );
      await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
      await tester.pumpAndSettle();
      await openGraphCandidatesTab(tester);

      // Approve both EXTRACTED via bulk; reject the INFERRED. Each
      // affordance is scrolled into view before the tap because the
      // default test surface (800x600) cannot fit the whole diff.
      final bulkApprove = find.byKey(
        const Key('admin_corpus_graph_bulk_approve_extracted'),
      );
      await tester.ensureVisible(bulkApprove);
      await tester.pumpAndSettle();
      await tester.tap(bulkApprove);
      await tester.pumpAndSettle();

      final rejectButton = find.byKey(
        const Key(
          'admin_corpus_graph_candidate_reject_'
          'edge:fixture:section:concept:informs',
        ),
      );
      await tester.ensureVisible(rejectButton);
      await tester.pumpAndSettle();
      await tester.tap(rejectButton);
      await tester.pumpAndSettle();

      final commitButton = find.byKey(
        const Key('admin_corpus_graph_commit_button'),
      );
      await tester.ensureVisible(commitButton);
      await tester.pumpAndSettle();
      await tester.tap(commitButton);
      await tester.pumpAndSettle();

      // One node + one edge approved → canonical-bucket inserts.
      expect(
        gateway.debugApprovedNodes,
        hasLength(1),
        reason:
            'extracted bucket has one node candidate that was '
            'bulk-approved',
      );
      expect(
        gateway.debugApprovedEdges,
        hasLength(1),
        reason:
            'extracted bucket has one edge candidate that was '
            'bulk-approved',
      );

      // The rejected candidate must land in audit only — never in the
      // canonical buckets. This is the data-flow assertion the slice
      // promises operator-side: a rejected candidate is unreachable
      // through the canonical-graph tables AGE projects from.
      expect(gateway.debugRejectedAudit, hasLength(1));
      final rejected = gateway.debugRejectedAudit.single;
      expect(
        rejected['candidate_id'],
        equals('edge:fixture:section:concept:informs'),
      );
      final approvedKeys = <String>[
        ...gateway.debugApprovedNodes.map((m) => m['node_key'] as String),
        ...gateway.debugApprovedEdges.map((m) => m['edge_key'] as String),
      ];
      expect(
        approvedKeys,
        isNot(
          contains('graphify:edge:fixture_section:fixture_concept:informs'),
        ),
        reason:
            'the rejected candidate must NEVER appear in the '
            'approved-canonical buckets — this is the schema-level '
            'guarantee the operator relies on',
      );
    },
  );

  testWidgets('AGE rebuild button surfaces the 501 not-implemented banner', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    final rebuildButton = find.byKey(
      const Key('admin_corpus_age_rebuild_button'),
    );
    await tester.ensureVisible(rebuildButton);
    await tester.pumpAndSettle();
    await tester.tap(rebuildButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_corpus_age_rebuild_banner')),
      findsOneWidget,
      reason:
          'launch slice ships AGE rebuild as a 501 stub; the '
          'banner tells the operator the rebuild infra is not yet '
          'enabled, so the click did not silently fail',
    );
    expect(find.textContaining('not yet enabled'), findsOneWidget);
  });

  testWidgets(
    'editingEnabled: false (ff_support) hides every mutate affordance '
    'but still renders the diff',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        graphCandidateSeed: buildDiff(),
      );
      await tester.pumpWidget(
        wrap(buildScreen(gateway: gateway, editingEnabled: false)),
      );
      await tester.pumpAndSettle();
      await openGraphCandidatesTab(tester);

      // The diff still renders — three sections present.
      expect(
        find.byKey(const Key('admin_corpus_graph_extracted_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_corpus_graph_inferred_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_corpus_graph_ambiguous_section')),
        findsOneWidget,
      );

      // Every mutate affordance is gone.
      expect(
        find.byKey(const Key('admin_corpus_graph_bulk_approve_extracted')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_corpus_graph_commit_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_corpus_age_rebuild_button')),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key(
            'admin_corpus_graph_candidate_approve_'
            'edge:fixture:section:concept:informs',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key(
            'admin_corpus_graph_candidate_reject_'
            'edge:fixture:section:concept:informs',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key(
            'admin_corpus_graph_candidate_edit_'
            'edge:fixture:concept:other:relates',
          ),
        ),
        findsNothing,
      );
    },
  );

  // ─── Code-review follow-ups ──────────────────────────────────────────
  //
  // Each test below corresponds to a P1 / P2 finding from the
  // post-implementation review. They sit at the end of the file so a
  // future reader can scan the original walkthrough coverage first
  // and the regression guards second.

  testWidgets('AMBIGUOUS rows hide the Approve button (debug-only until edited)', (
    tester,
  ) async {
    // Spec line 249: "AMBIGUOUS relationships are debug-only until
    // edited into a clear approved relationship". Bare Approve on
    // an unedited AMBIGUOUS candidate would route it into canonical
    // storage and then AGE — the slice's whole reason for existing
    // forbids that. The screen renders Edit + Reject only on
    // AMBIGUOUS rows; Approve is intentionally absent.
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    // Sanity check: the AMBIGUOUS candidate row exists.
    expect(
      find.byKey(
        const Key('admin_corpus_graph_tile_edge:fixture:concept:other:relates'),
      ),
      findsOneWidget,
    );
    // The Edit + Reject buttons render.
    expect(
      find.byKey(
        const Key(
          'admin_corpus_graph_candidate_edit_edge:fixture:concept:other:relates',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'admin_corpus_graph_candidate_reject_edge:fixture:concept:other:relates',
        ),
      ),
      findsOneWidget,
    );
    // But the Approve button is hidden — this is the slice's
    // forbidden-by-construction guarantee for AMBIGUOUS rows.
    expect(
      find.byKey(
        const Key(
          'admin_corpus_graph_candidate_approve_edge:fixture:concept:other:relates',
        ),
      ),
      findsNothing,
    );

    // EXTRACTED + INFERRED rows still expose Approve.
    expect(
      find.byKey(
        const Key('admin_corpus_graph_candidate_approve_node:fixture:doc'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'admin_corpus_graph_candidate_approve_edge:fixture:section:concept:informs',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'edit dialog queues an ApprovalDecision that carries editedPayload',
    (tester) async {
      // P1: the proxy commit-batch route rejects an edit decision
      // arriving without `edited_payload` (`missing_edited_payload`
      // 400). The dialog must therefore forward the original
      // candidate payload verbatim alongside the edited
      // candidate_type — otherwise live mode's whole AMBIGUOUS
      // edit-and-approve path is dead.
      final gateway = InMemoryCorpusAdminGateway(
        graphCandidateSeed: buildDiff(),
      );
      await tester.pumpWidget(wrap(buildScreen(gateway: gateway)));
      await tester.pumpAndSettle();
      await openGraphCandidatesTab(tester);

      final editButton = find.byKey(
        const Key(
          'admin_corpus_graph_candidate_edit_edge:fixture:concept:other:relates',
        ),
      );
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      // Type a new edge_type into the dialog's type field, then
      // submit.
      await tester.enterText(
        find.byKey(
          const Key('admin_corpus_graph_candidates_edit_dialog_type_field'),
        ),
        'INFORMS',
      );
      await tester.tap(
        find.byKey(
          const Key('admin_corpus_graph_candidates_edit_dialog_submit'),
        ),
      );
      await tester.pumpAndSettle();

      // Commit the queued batch so the gateway captures the
      // serialized decision and we can inspect what landed.
      final commitButton = find.byKey(
        const Key('admin_corpus_graph_commit_button'),
      );
      await tester.ensureVisible(commitButton);
      await tester.pumpAndSettle();
      await tester.tap(commitButton);
      await tester.pumpAndSettle();

      // The demo gateway's edit branch records the resolved approve
      // shape under debugApprovedEdges (edit-then-approve lands in
      // canonical storage, mirroring the production gateway path).
      // We verify (a) one edge was approved, (b) its edge_type is
      // the edited one, and (c) the properties payload survived
      // the round trip end-to-end so the proxy's
      // `missing_edited_payload` check would pass on the wire.
      expect(gateway.debugApprovedEdges, hasLength(1));
      final approved = gateway.debugApprovedEdges.single;
      expect(approved['edge_type'], equals('INFORMS'));
      final properties = (approved['properties'] as Map?)
          ?.cast<String, Object?>();
      expect(properties, isNotNull);
      expect(properties!['graphify_relation'], equals('NEAR'));
      expect(properties['label'], equals('concept near other concept'));
    },
  );

  test('BatchCommitCommand.toJson() includes target_operator_id and '
      'target_location_id (proxy 400s on a body without them)', () {
    // P1 review finding: HttpCorpusAdminGateway POSTs
    // `command.toJson()` verbatim. The proxy commit-batch route
    // requires `target_operator_id` + `target_location_id` to
    // build the TenantContext for the GraphRepository write. The
    // model now carries both fields; this test pins the wire
    // contract so a regression in toJson() (e.g. dropping the
    // fields back to `{decisions: [...]}`) breaks here instead of
    // silently 400-ing every Flutter client.
    const command = BatchCommitCommand(
      idempotencyKey: 'test-key',
      targetOperatorId: '00000000-0000-4000-8000-000000000001',
      targetLocationId: '00000000-0000-4000-8000-0000000000a1',
      decisions: <ApprovalDecision>[],
    );
    final json = command.toJson();
    expect(
      json['target_operator_id'],
      equals('00000000-0000-4000-8000-000000000001'),
    );
    expect(
      json['target_location_id'],
      equals('00000000-0000-4000-8000-0000000000a1'),
    );
    expect(json['decisions'], isA<List<Map<String, Object?>>>());
  });

  testWidgets('no target operator/location: commit button is disabled and the '
      '"select operator" banner renders (P1 follow-up — live route '
      'must not silently fall back to demo IDs)', (tester) async {
    // Live mode in admin_routes.dart leaves both targets null
    // until the operator-picker slice ships. The screen must
    // refuse to commit in that case so a super_admin cannot
    // accidentally write graph decisions against the wrong tenant
    // (or the demo IDs, which do not exist in production).
    final gateway = InMemoryCorpusAdminGateway(graphCandidateSeed: buildDiff());
    await tester.pumpWidget(
      wrap(
        buildScreen(
          gateway: gateway,
          // Both targets explicitly null = live-mode-pre-picker
          // wiring.
          targetOperatorId: null,
          targetLocationId: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openGraphCandidatesTab(tester);

    // Banner is visible and points at the operator-picker
    // follow-up.
    expect(
      find.byKey(const Key('admin_corpus_graph_no_target_banner')),
      findsOneWidget,
    );

    // Even after queuing a decision, the commit button stays
    // disabled because the destination is unknown.
    final bulkApprove = find.byKey(
      const Key('admin_corpus_graph_bulk_approve_extracted'),
    );
    await tester.ensureVisible(bulkApprove);
    await tester.pumpAndSettle();
    await tester.tap(bulkApprove);
    await tester.pumpAndSettle();

    final commitButton = find.byKey(
      const Key('admin_corpus_graph_commit_button'),
    );
    await tester.ensureVisible(commitButton);
    await tester.pumpAndSettle();
    // The button widget exists but is disabled (onPressed: null).
    final FilledButton commitWidget = tester.widget<FilledButton>(commitButton);
    expect(
      commitWidget.onPressed,
      isNull,
      reason:
          'commit button must stay disabled when no target '
          'is configured, even when decisions are queued — the '
          'destination is unknown so a click would otherwise commit '
          'against the wrong tenant',
    );

    // Nothing landed in the demo gateway's canonical buckets
    // because no commit fired.
    expect(gateway.debugApprovedNodes, isEmpty);
    expect(gateway.debugApprovedEdges, isEmpty);
    expect(gateway.debugRejectedAudit, isEmpty);
  });
}
