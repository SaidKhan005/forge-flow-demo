// B-r2 — "Topics the advisor knows" tests (Knowledge tab only).
//
// Covers the B-r2 presentation built on top of B3's document grouping:
//
//   * The pure [corpusTopicKindForChunk] derivation: heading/source
//     keywords map to a kind; anything unclear falls back to Document.
//     This proves the slice does NOT fabricate kinds (rich-kind
//     extraction is the later C3 slice).
//   * Each topic renders a kind pill + plain-English kind line.
//   * The kind filter dropdown narrows the visible topics.
//   * The "Showing X of Y" count tracks search + filter.
//   * Read-only mode (ff_support) still renders the topics + toolbar.
//
// Scope guard: this file drives only the Knowledge (Versions) tab and
// never touches the Connections tab or its shared widgets.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_human_labels.dart';
import 'package:forge_and_flow/admin/models/corpus_admin_models.dart';
import 'package:forge_and_flow/admin/screens/corpus_admin_screen.dart';
import 'package:forge_and_flow/admin/services/corpus_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

ChunkPreview _chunk({
  required String chunkId,
  required String sourcePath,
  required List<String> headingPath,
  String snippet = 'Snippet body for the advisor.',
}) {
  return ChunkPreview(
    chunkId: chunkId,
    docId: sourcePath,
    sourcePath: sourcePath,
    headingPath: headingPath,
    snippet: snippet,
    estimatedTokens: 40,
    riskLevel: 'standard',
    contentSha256: 'a' * 64,
    versionId: 'v-topics',
    active: true,
  );
}

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  // ── Unit: kind derivation (no fabricated kinds) ──

  group('corpusTopicKindForChunk', () {
    test('falls back to Document when nothing in the text is clear', () {
      final kind = corpusTopicKindForChunk(
        _chunk(
          chunkId: 'd#1',
          sourcePath: 'company_overview.md',
          headingPath: const <String>['Welcome'],
        ),
      );
      expect(kind, AdminCorpusTopicKind.document);
    });

    test('derives SOP from step-by-step vocabulary', () {
      expect(
        corpusTopicKindForChunk(
          _chunk(
            chunkId: 's#1',
            sourcePath: 'food_safety_manual.md',
            headingPath: const <String>['FIFO (First In, First Out)'],
          ),
        ),
        AdminCorpusTopicKind.sop,
      );
    });

    test('derives Policy from rule/compliance vocabulary', () {
      expect(
        corpusTopicKindForChunk(
          _chunk(
            chunkId: 'p#1',
            sourcePath: 'handbook.md',
            headingPath: const <String>['Workplace Harassment Policy'],
          ),
        ),
        AdminCorpusTopicKind.policy,
      );
    });

    test('derives Risk from hazard vocabulary', () {
      expect(
        corpusTopicKindForChunk(
          _chunk(
            chunkId: 'r#1',
            sourcePath: 'food_safety_manual.md',
            headingPath: const <String>['Temperature Danger Zone'],
          ),
        ),
        AdminCorpusTopicKind.risk,
      );
    });

    test('derives Metric from tracked-number vocabulary', () {
      expect(
        corpusTopicKindForChunk(
          _chunk(
            chunkId: 'm#1',
            sourcePath: 'bold_by_design.md',
            headingPath: const <String>['Cost per Labor Hour (CPLH)'],
          ),
        ),
        AdminCorpusTopicKind.metric,
      );
    });

    test('derives Formula from equation vocabulary', () {
      expect(
        corpusTopicKindForChunk(
          _chunk(
            chunkId: 'f#1',
            sourcePath: 'bold_by_design.md',
            headingPath: const <String>['The Core Labor Equation'],
          ),
        ),
        AdminCorpusTopicKind.formula,
      );
    });

    test('derives Role from job vocabulary', () {
      expect(
        corpusTopicKindForChunk(
          _chunk(
            chunkId: 'ro#1',
            sourcePath: 'handbook.md',
            headingPath: const <String>['Expo role'],
          ),
        ),
        AdminCorpusTopicKind.role,
      );
    });

    test('does not match keywords embedded inside larger words', () {
      // "policyholder" must NOT trip the Policy branch (word-boundary
      // matching), so this unclear heading stays a Document.
      expect(
        corpusTopicKindForChunk(
          _chunk(
            chunkId: 'x#1',
            sourcePath: 'notes.md',
            headingPath: const <String>['Policyholder onboarding'],
          ),
        ),
        AdminCorpusTopicKind.document,
      );
    });
  });

  // ── Widget: topic presentation + filtering on the Knowledge tab ──

  CorpusBundle topicsBundle() {
    // Two documents; six topics spanning several derived kinds.
    return CorpusBundle(
      version: CorpusVersionRef(
        versionId: 'v-topics',
        createdBy: 'seed-actor',
        createdAt: DateTime.utc(2026, 1, 1),
        summary: 'Topics check',
        rollbackOf: null,
        supersededAt: null,
        chunkCount: 6,
      ),
      chunks: <ChunkPreview>[
        _chunk(
          chunkId: 'food_safety_manual.md#001',
          sourcePath: 'food_safety_manual.md',
          headingPath: const <String>['FIFO (First In, First Out)'],
          snippet: 'Rotate stock so the oldest is used first.',
        ),
        _chunk(
          chunkId: 'food_safety_manual.md#002',
          sourcePath: 'food_safety_manual.md',
          headingPath: const <String>['Temperature Danger Zone'],
          snippet: 'Keep food out of the danger zone.',
        ),
        _chunk(
          chunkId: 'food_safety_manual.md#003',
          sourcePath: 'food_safety_manual.md',
          headingPath: const <String>['Welcome'],
          snippet: 'An introduction with no clear kind.',
        ),
        _chunk(
          chunkId: 'handbook.md#001',
          sourcePath: 'handbook.md',
          headingPath: const <String>['Workplace Harassment Policy'],
          snippet: 'The rule everyone must follow.',
        ),
        _chunk(
          chunkId: 'handbook.md#002',
          sourcePath: 'handbook.md',
          headingPath: const <String>['Cost per Labor Hour (CPLH)'],
          snippet: 'A number you track each week.',
        ),
        _chunk(
          chunkId: 'handbook.md#003',
          sourcePath: 'handbook.md',
          headingPath: const <String>['Expo role'],
          snippet: 'The person who plates and calls the pass.',
        ),
      ],
    );
  }

  testWidgets('renders the kind pill + plain-English kind line per topic', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[topicsBundle()],
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    // The FIFO topic reads as an SOP: pill + plain-English line.
    expect(find.text('SOP'), findsWidgets);
    expect(find.text('A step-by-step SOP'), findsWidgets);
    // The danger-zone topic reads as a Risk.
    expect(find.text('Risk'), findsWidgets);
    // The unclear "Welcome" topic falls back to Document.
    expect(find.text('Document'), findsWidgets);
    expect(find.text('A document'), findsWidgets);
  });

  testWidgets('shows a "Showing X of Y" count over the topic list', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[topicsBundle()],
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    final countFinder = find.byKey(const Key('admin_corpus_topics_count'));
    expect(countFinder, findsOneWidget);
    expect(
      tester.widget<Text>(countFinder).data,
      AdminKnowledgeBaseCopy.topicsShowing(6, 6),
    );
  });

  testWidgets('the kind filter narrows topics to the chosen kind', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[topicsBundle()],
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    // All six topics visible before filtering.
    expect(
      find.byKey(const Key('admin_corpus_chunk_food_safety_manual.md#001')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_corpus_chunk_handbook.md#001')),
      findsOneWidget,
    );

    // Open the kind dropdown and pick "Policies".
    final kindFilter = find.byKey(const Key('admin_corpus_kind_filter'));
    await tester.ensureVisible(kindFilter);
    await tester.pumpAndSettle();
    await tester.tap(kindFilter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Policies').last);
    await tester.pumpAndSettle();

    // Only the harassment-policy topic (handbook#001) remains; the SOP
    // and the empty food-safety doc group drop out.
    expect(
      find.byKey(const Key('admin_corpus_chunk_handbook.md#001')),
      findsOneWidget,
      reason: 'the Policy topic must survive the Policies filter',
    );
    expect(
      find.byKey(const Key('admin_corpus_chunk_food_safety_manual.md#001')),
      findsNothing,
      reason: 'the SOP topic must be hidden under the Policies filter',
    );

    // The count reflects "Showing 1 of 6".
    expect(
      tester
          .widget<Text>(find.byKey(const Key('admin_corpus_topics_count')))
          .data,
      AdminKnowledgeBaseCopy.topicsShowing(1, 6),
    );
  });

  testWidgets('an empty filter result shows the no-topics notice', (
    tester,
  ) async {
    // A single Document-only corpus: filtering to "Risks" matches none.
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        CorpusBundle(
          version: CorpusVersionRef(
            versionId: 'v-doc-only',
            createdBy: 'seed-actor',
            createdAt: DateTime.utc(2026, 1, 1),
            summary: 'Document only',
            rollbackOf: null,
            supersededAt: null,
            chunkCount: 1,
          ),
          chunks: <ChunkPreview>[
            _chunk(
              chunkId: 'overview.md#001',
              sourcePath: 'overview.md',
              headingPath: const <String>['Welcome'],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    final kindFilter = find.byKey(const Key('admin_corpus_kind_filter'));
    await tester.ensureVisible(kindFilter);
    await tester.pumpAndSettle();
    await tester.tap(kindFilter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Risks').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_corpus_topics_empty')),
      findsOneWidget,
    );
    expect(find.text(AdminKnowledgeBaseCopy.topicsEmpty), findsOneWidget);
  });

  testWidgets('search narrows topics and updates the count', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[topicsBundle()],
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_corpus_content_search')),
      'FIFO',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_corpus_chunk_food_safety_manual.md#001')),
      findsOneWidget,
      reason: 'the FIFO topic matches the query',
    );
    expect(
      find.byKey(const Key('admin_corpus_chunk_handbook.md#001')),
      findsNothing,
      reason: 'non-matching topics are hidden',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('admin_corpus_topics_count')))
          .data,
      AdminKnowledgeBaseCopy.topicsShowing(1, 6),
    );
  });

  testWidgets('read-only mode still renders topics, toolbar, and count', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[topicsBundle()],
    );
    await tester.pumpWidget(
      wrap(CorpusAdminScreen(gateway: gateway, editingEnabled: false)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_corpus_readonly_banner')),
      findsOneWidget,
    );
    // The topics card, its search box, kind filter, and count all render
    // in read-only mode (they are read affordances, not mutations).
    expect(
      find.byKey(const Key('admin_corpus_content_search')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_corpus_kind_filter')), findsOneWidget);
    expect(find.byKey(const Key('admin_corpus_topics_count')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_corpus_chunk_food_safety_manual.md#001')),
      findsOneWidget,
    );
  });
}
