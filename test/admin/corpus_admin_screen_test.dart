// Phase 11A.3a — Corpus admin screen widget tests.
//
// Drives the screen against an `InMemoryCorpusAdminGateway` so the
// click path runs end-to-end without a backend. Coverage:
//
//   * Initial render lists every seeded version with current chip.
//   * Empty state renders when no versions are seeded.
//   * Upload + preview + commit flow drops a new current version.
//   * Rollback flow re-points current to the rolled-back chunk set.
//   * Read-only mode (`editingEnabled: false`) hides every mutate
//     affordance — exercised by the `ff_support` walkthrough.
//   * Binary upload surfaces the typed action banner instead of
//     advancing the staged-diff card.
//
// B1 additions (Advisor Knowledge Activation):
//   * Injected picker returning .md bytes reaches the preview-diff card.
//   * Injected picker returning .txt bytes reaches the preview-diff card.
//   * Injected picker returning null (cancel) leaves the screen unchanged.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/admin_shell.dart';
import 'package:forge_and_flow/admin/models/corpus_admin_models.dart';
import 'package:forge_and_flow/admin/screens/corpus_admin_screen.dart';
import 'package:forge_and_flow/admin/services/corpus_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '../_test_helpers/widget_pump_helpers.dart';

/// B-r1: flips the screen-level "Show technical details" toggle ON.
/// The toggle is OFF by default, hiding machine-flavored details (raw
/// IDs, content hashes, version IDs) and the per-card disclosures.
/// Tests that need those visible call this first.
Future<void> _enableTechDetails(WidgetTester tester) async {
  final toggle = find.byKey(const Key('admin_corpus_tech_details_toggle'));
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  CorpusBundle seedBundle({
    required String versionId,
    String summary = 'Seed',
    DateTime? createdAt,
    DateTime? supersededAt,
    int chunkCount = 1,
    String contentHash = 'a',
  }) {
    final created = createdAt ?? DateTime.utc(2026, 1, 1);
    return CorpusBundle(
      version: CorpusVersionRef(
        versionId: versionId,
        createdBy: 'seed-actor',
        createdAt: created,
        summary: summary,
        rollbackOf: null,
        supersededAt: supersededAt,
        chunkCount: chunkCount,
      ),
      chunks: <ChunkPreview>[
        ChunkPreview(
          chunkId: 'methodology_seed.md#000',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: const <String>['Forge & Flow'],
          snippet: 'Methodology preamble',
          estimatedTokens: 64,
          riskLevel: 'standard',
          contentSha256: contentHash * 64,
          versionId: versionId,
          active: supersededAt == null,
        ),
      ],
    );
  }

  Future<UploadCommand?> demoPicker(String body, String idempotencyKey) {
    return Future<UploadCommand?>.value(
      UploadCommand(
        fileName: 'methodology_seed.md',
        contentType: 'text/markdown',
        bytes: Uint8List.fromList(body.codeUnits),
        idempotencyKey: idempotencyKey,
      ),
    );
  }

  testWidgets('renders one row per seeded version with current chip', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        seedBundle(
          versionId: 'v1',
          summary: 'v1 prior',
          createdAt: DateTime.utc(2026, 1, 1),
          supersededAt: DateTime.utc(2026, 1, 2),
        ),
        seedBundle(
          versionId: 'v2',
          summary: 'v2 current',
          createdAt: DateTime.utc(2026, 1, 2),
        ),
      ],
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_corpus_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_corpus_row_v1')), findsOneWidget);
    expect(find.byKey(const Key('admin_corpus_row_v2')), findsOneWidget);
    expect(find.byKey(const Key('admin_corpus_current_v2')), findsOneWidget);
    expect(find.byKey(const Key('admin_corpus_current_v1')), findsNothing);
    expect(find.textContaining('sha256'), findsNothing);
    expect(find.textContaining('aaaaaaaaaaaa'), findsNothing);

    // B-r1: machine-flavored details (and the per-card "Technical
    // details" disclosure) only render when the screen-level "Show
    // technical details" toggle is ON. Flip it on before reaching for
    // the chunk disclosure.
    await _enableTechDetails(tester);

    final chunkDetails = find.byKey(
      const Key('admin_corpus_chunk_details_methodology_seed.md#000'),
    );
    await tester.ensureVisible(chunkDetails);
    await tester.pumpAndSettle();
    await tester.tap(chunkDetails);
    await tester.pumpAndSettle();
    expect(find.text('Source hash'), findsOneWidget);
    expect(find.text('aaaaaaaaaaaa'), findsOneWidget);
  });

  testWidgets('defers Graph candidates fetch until the tab is opened', (
    tester,
  ) async {
    final gateway = _CountingCorpusAdminGateway(
      InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(versionId: 'v1', summary: 'seed', chunkCount: 1),
        ],
        graphCandidateSeed: const GraphCandidateDiff(
          graphScope: 'methodology',
          graphVersion: '1',
          graphifyVersion: 'v5',
          graphifySourceCommit: 'perf-test',
          extracted: <GraphCandidate>[],
          inferred: <GraphCandidate>[],
          ambiguous: <GraphCandidate>[],
        ),
      ),
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(gateway.listVersionsCount, equals(1));
    expect(gateway.fetchVersionCount, equals(1));
    expect(
      gateway.graphCandidateFetchCount,
      equals(0),
      reason: 'default Versions tab should not prefetch the hidden graph tab',
    );

    final tabFinder = find.descendant(
      of: find.byKey(const Key('admin_corpus_tab_bar')),
      matching: find.text('Connections'),
    );
    await tester.tap(tabFinder);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_corpus_graph_tab_body')),
      findsOneWidget,
    );
    expect(gateway.graphCandidateFetchCount, equals(1));
  });

  testWidgets('stacks version list/detail panes on compact widths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        seedBundle(
          versionId: 'v-compact',
          summary: 'Compact width smoke with a longer summary',
        ),
      ],
    );
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_corpus_version_list')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_corpus_detail_v-compact')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the empty state with an upload prompt', (tester) async {
    final gateway = InMemoryCorpusAdminGateway();
    await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_corpus_empty')), findsOneWidget);
    expect(find.text('No advisor content yet'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_corpus_first_upload_button')),
      findsOneWidget,
    );
  });

  testWidgets('upload + preview produces a staged diff card', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        seedBundle(versionId: 'v1', summary: 'seed', chunkCount: 1),
      ],
    );
    await tester.pumpWidget(
      wrap(
        CorpusAdminScreen(
          gateway: gateway,
          uploadPicker: (_) => demoPicker(
            '# Forge\n\n## Cycles\n\nSixty-day cycles.\n\n## Daypart\n\nDaypart guidance.\n',
            'k1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_corpus_upload_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_corpus_staged_diff')), findsOneWidget);
    expect(find.byKey(const Key('admin_corpus_commit_button')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_corpus_discard_button')),
      findsOneWidget,
    );
  });

  testWidgets('commit promotes staged upload to the current version', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        seedBundle(versionId: 'v1', summary: 'seed', chunkCount: 1),
      ],
    );
    await tester.pumpWidget(
      wrap(
        CorpusAdminScreen(
          gateway: gateway,
          uploadPicker: (_) =>
              demoPicker('# Forge\n\n## Cycles\n\nSixty-day cycles.\n', 'k1'),
          idempotencyKeyGenerator: () => 'commit-key-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_corpus_upload_button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_corpus_staged_diff')),
      findsOneWidget,
      reason: 'staged diff card should render after preview',
    );
    expect(
      find.byKey(const Key('admin_corpus_commit_button')),
      findsOneWidget,
      reason: 'commit button should render before tap',
    );
    expect(
      find.byKey(const Key('admin_corpus_action_error')),
      findsNothing,
      reason: 'no action error should have surfaced',
    );

    await tester.ensureVisible(
      find.byKey(const Key('admin_corpus_commit_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_corpus_commit_button')));
    await tester.pumpAndSettle();

    final errorBanner = find.byKey(const Key('admin_corpus_action_error'));
    if (errorBanner.evaluate().isNotEmpty) {
      // Surface the actual error so the failure message names the
      // missing field instead of an opaque "no action error".
      final errorText =
          (errorBanner.evaluate().first.widget as dynamic).message as String;
      fail('action error after commit: $errorText');
    }

    final versions = await gateway.listVersions();
    // Seed (v1) plus the freshly-committed version.
    expect(versions, hasLength(2));
    expect(versions.first.isCurrent, isTrue);
    expect(versions.first.versionId, isNot(equals('v1')));
  });

  testWidgets('rollback writes a new current version pointing at target', (
    tester,
  ) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        seedBundle(
          versionId: 'v1',
          summary: 'v1 prior',
          createdAt: DateTime.utc(2026, 1, 1),
          supersededAt: DateTime.utc(2026, 1, 2),
        ),
        seedBundle(
          versionId: 'v2',
          summary: 'v2 current',
          createdAt: DateTime.utc(2026, 1, 2),
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        CorpusAdminScreen(
          gateway: gateway,
          idempotencyKeyGenerator: () => 'rollback-key-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // D7e shared-console adoption: the screen header now uses
    // OperatorWebScreenHeader, whose multi-line subtitle reflows the
    // version list a few pixels lower on the default 800x600 surface,
    // leaving the prior-version Restore button at the viewport edge.
    // Scroll it into view before tapping (same pattern the sibling
    // graph-candidates tests already use). Intent is unchanged: the tap
    // still opens the confirm dialog and the rollback assertions below
    // still run.
    final rollbackButton = find.byKey(const Key('admin_corpus_rollback_v1'));
    await tester.ensureVisible(rollbackButton);
    await tester.pumpAndSettle();
    await tester.tap(rollbackButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_corpus_confirm_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('admin_corpus_confirm_ok')));
    await tester.pumpAndSettle();

    final versions = await gateway.listVersions();
    final current = versions.firstWhere((v) => v.isCurrent);
    expect(current.rollbackOf, equals('v1'));
    expect(current.versionId, isNot(equals('v1')));
    expect(current.versionId, isNot(equals('v2')));
  });

  testWidgets(
    'editingEnabled: false hides upload, commit, and rollback affordances',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(
            versionId: 'v1',
            summary: 'v1 prior',
            createdAt: DateTime.utc(2026, 1, 1),
            supersededAt: DateTime.utc(2026, 1, 2),
          ),
          seedBundle(
            versionId: 'v2',
            summary: 'v2 current',
            createdAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(CorpusAdminScreen(gateway: gateway, editingEnabled: false)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_corpus_readonly_banner')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_corpus_upload_button')), findsNothing);
      expect(find.byKey(const Key('admin_corpus_rollback_v1')), findsNothing);
    },
  );

  testWidgets(
    'admin shell with ff_support source renders corpus in read-only mode',
    (tester) async {
      // Side nav grew with members/roles-hierarchy-sessions/audited-support-actions
      // routes; expand the surface so the corpus nav item is on-screen and tappable.
      await tester.binding.setSurfaceSize(const Size(1400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(
            versionId: 'v1',
            summary: 'support read view',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );
      const ffSupportSession = AdminAuthSession(
        uid: 'demo-ff-support',
        email: 'support@forgeflow.test',
        displayName: 'Demo F&F Support',
        roles: <String>['ff_support'],
      );
      final source = DemoAdminAuthSource(
        initial: const AdminAuthAuthenticated(ffSupportSession),
      );
      addTearDown(source.dispose);
      // Drive AdminShell directly — the pattern admin_shell_widget_test.dart
      // uses for every scoped-workspace screen — rather than the full
      // AdminConsoleApp. AdminConsoleApp's root MediaQuery clamps text
      // scaling up to a 1.12 floor, which tips the Knowledge Base "Show
      // technical details" toggle ~3px past OperatorWebScreenFrame's capped
      // content width and trips a render overflow unrelated to this test's
      // ff_support read-only contract. Scale-1.0 shell rendering keeps the
      // test on its subject (the toggle-vs-OS-text-scaling quirk is tracked
      // separately).
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          corpusAdminGateway: gateway,
          adminAuthSource: source,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.themeData,
            home: AdminShell(session: ffSupportSession, authSource: source),
          ),
        ),
      );
      // Bounded settling (pumpEventually) instead of pumpAndSettle: the
      // shared scope-tree pane runs a finite attention-pulse animation, so an
      // unbounded settle can hang. Mirrors admin_shell_widget_test.dart.
      await pumpEventually(tester);

      final corpusNavItem = find.byKey(const Key('admin_nav_item_corpus'));
      await tester.ensureVisible(corpusNavItem);
      await pumpEventually(tester);
      await tester.tap(corpusNavItem);
      await pumpEventually(tester);

      // 44e225a9 ("Complete admin hierarchy UX consolidation", #481) moved
      // the Knowledge base behind the shared scoped-admin workspace: the
      // corpus screen only builds once a business scope is picked. Until
      // then the function pane shows the "Pick a business first" card. Pick
      // the seeded demo business ("Demo Diner Co.") so the ff_support
      // read-only corpus screen loads — the same scope-first nav flow the
      // AI-workspace tests in admin_shell_widget_test.dart exercise.
      final demoBusinessScope = find.byKey(
        const Key(
          'admin_setup_scope_business_00000000-0000-4000-8000-000000000001',
        ),
      );
      await tester.ensureVisible(demoBusinessScope);
      await pumpEventually(tester);
      await tester.tap(demoBusinessScope);
      await pumpEventually(tester);
      // On compact widths the function pane is tabbed behind the scope pane;
      // tap the 'Knowledge Base' tab when present so the corpus screen is the
      // visible pane before asserting.
      if (find
          .byKey(const Key('admin_setup_workspace_tabs'))
          .evaluate()
          .isNotEmpty) {
        await tester.tap(find.widgetWithText(Tab, 'Knowledge Base'));
        await pumpEventually(tester);
      }

      expect(find.byKey(const Key('admin_corpus_screen')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_corpus_readonly_banner')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_corpus_upload_button')), findsNothing);
    },
  );

  testWidgets('binary upload surfaces the action-error banner', (tester) async {
    final gateway = InMemoryCorpusAdminGateway(
      seed: <CorpusBundle>[
        seedBundle(versionId: 'v1', summary: 'seed', chunkCount: 1),
      ],
    );
    await tester.pumpWidget(
      wrap(
        CorpusAdminScreen(
          gateway: gateway,
          uploadPicker: (_) => Future<UploadCommand?>.value(
            UploadCommand(
              fileName: 'methodology.md',
              contentType: 'text/markdown',
              bytes: Uint8List.fromList(<int>[0, 1, 2, 3]),
              idempotencyKey: 'k-bin',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_corpus_upload_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_corpus_action_error')), findsOneWidget);
    expect(find.byKey(const Key('admin_corpus_staged_diff')), findsNothing);
  });

  // ── B1 tests: injected-picker seam exercises the real preview-diff flow ──

  testWidgets(
    'B1: injected .md picker returns UploadCommand and reaches staged-diff card',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(versionId: 'v1', summary: 'seed', chunkCount: 1),
        ],
      );
      const mdBody =
          '# Knowledge Base\n\n## Section\n\nContent for the advisor.\n';
      await tester.pumpWidget(
        wrap(
          CorpusAdminScreen(
            gateway: gateway,
            uploadPicker: (_) => Future<UploadCommand?>.value(
              UploadCommand(
                fileName: 'knowledge.md',
                contentType: 'text/markdown',
                bytes: Uint8List.fromList(mdBody.codeUnits),
                idempotencyKey: 'b1-md-key',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_corpus_upload_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_corpus_staged_diff')),
        findsOneWidget,
        reason: '.md upload should produce a staged-diff preview card',
      );
      expect(
        find.byKey(const Key('admin_corpus_action_error')),
        findsNothing,
        reason: 'no error banner should appear for a valid .md upload',
      );
      expect(
        find.byKey(const Key('admin_corpus_commit_button')),
        findsOneWidget,
        reason: 'commit button should be visible after preview',
      );
    },
  );

  testWidgets(
    'B1: injected .txt picker returns UploadCommand and reaches staged-diff card',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(versionId: 'v1', summary: 'seed', chunkCount: 1),
        ],
      );
      const txtBody = 'Plain text advisor content.\n\nSome more content.\n';
      await tester.pumpWidget(
        wrap(
          CorpusAdminScreen(
            gateway: gateway,
            uploadPicker: (_) => Future<UploadCommand?>.value(
              UploadCommand(
                fileName: 'notes.txt',
                contentType: 'text/plain',
                bytes: Uint8List.fromList(txtBody.codeUnits),
                idempotencyKey: 'b1-txt-key',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_corpus_upload_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_corpus_staged_diff')),
        findsOneWidget,
        reason: '.txt upload should produce a staged-diff preview card',
      );
      expect(
        find.byKey(const Key('admin_corpus_action_error')),
        findsNothing,
        reason: 'no error banner should appear for a valid .txt upload',
      );
    },
  );

  // ── B2 tests: plain-English copy + icons + machine-ID disclosure ──

  testWidgets(
    'B2: technical-details disclosure exists and raw chunk ID not in primary label',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(
            versionId: 'v-b2',
            summary: 'B2 plain-English check',
            contentHash: 'deadbeef',
          ),
        ],
      );
      await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      // B-r1: with the screen-level "Show technical details" toggle OFF
      // (the default), the per-card disclosures are hidden entirely and
      // no raw IDs/hashes appear anywhere.
      expect(
        find.byKey(
          const Key('admin_corpus_chunk_details_methodology_seed.md#000'),
        ),
        findsNothing,
        reason: 'tech disclosure must be hidden while the toggle is OFF',
      );
      expect(
        find.byKey(const Key('admin_corpus_version_details_v-b2')),
        findsNothing,
        reason: 'version tech disclosure must be hidden while the toggle is OFF',
      );
      expect(
        find.textContaining('methodology_seed.md#000'),
        findsNothing,
        reason: 'raw chunk ID must not appear in primary label',
      );
      expect(
        find.textContaining('sha256'),
        findsNothing,
        reason: 'sha256 label must not appear in primary label',
      );

      // Flip the toggle ON: the disclosures now render (machine IDs are
      // reachable behind them).
      await _enableTechDetails(tester);
      expect(
        find.byKey(
          const Key('admin_corpus_chunk_details_methodology_seed.md#000'),
        ),
        findsOneWidget,
        reason: 'technical-details ExpansionTile must exist for chunk when ON',
      );
      expect(
        find.byKey(const Key('admin_corpus_version_details_v-b2')),
        findsOneWidget,
        reason: 'technical-details ExpansionTile must exist for version when ON',
      );

      // The raw version ID still stays inside the disclosure, not the
      // primary label, even with the toggle ON.
      expect(
        find.text('v-b2'),
        findsNothing,
        reason: 'raw version ID must not appear outside the disclosure',
      );
    },
  );

  testWidgets(
    'B1: picker returning null (cancel) leaves the screen unchanged',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(versionId: 'v1', summary: 'seed', chunkCount: 1),
        ],
      );
      await tester.pumpWidget(
        wrap(
          CorpusAdminScreen(
            gateway: gateway,
            uploadPicker: (_) => Future<UploadCommand?>.value(null),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_corpus_upload_button')));
      await tester.pumpAndSettle();

      // Cancelling the picker should not show any diff or error.
      expect(find.byKey(const Key('admin_corpus_staged_diff')), findsNothing);
      expect(find.byKey(const Key('admin_corpus_action_error')), findsNothing);
    },
  );

  // ── B3 tests: grouped sections view + client-side search ──

  CorpusBundle b3Bundle() {
    // Two source documents, three sections total:
    //   doc_a.md  -> Section Alpha, Section Beta
    //   doc_b.md  -> Section Gamma
    return CorpusBundle(
      version: CorpusVersionRef(
        versionId: 'v-b3',
        createdBy: 'seed-actor',
        createdAt: DateTime.utc(2026, 1, 1),
        summary: 'B3 grouped-view check',
        rollbackOf: null,
        supersededAt: null,
        chunkCount: 3,
      ),
      chunks: const <ChunkPreview>[
        ChunkPreview(
          chunkId: 'doc_a.md#001',
          docId: 'doc_a',
          sourcePath: 'doc_a.md',
          headingPath: <String>['Section Alpha'],
          snippet: 'Alpha snippet content about workflows.',
          estimatedTokens: 40,
          riskLevel: 'standard',
          contentSha256: 'aaaa',
          versionId: 'v-b3',
          active: true,
        ),
        ChunkPreview(
          chunkId: 'doc_a.md#002',
          docId: 'doc_a',
          sourcePath: 'doc_a.md',
          headingPath: <String>['Section Beta'],
          snippet: 'Beta snippet about scheduling.',
          estimatedTokens: 42,
          riskLevel: 'standard',
          contentSha256: 'bbbb',
          versionId: 'v-b3',
          active: true,
        ),
        ChunkPreview(
          chunkId: 'doc_b.md#001',
          docId: 'doc_b',
          sourcePath: 'doc_b.md',
          headingPath: <String>['Section Gamma'],
          snippet: 'Gamma snippet about targets.',
          estimatedTokens: 35,
          riskLevel: 'standard',
          contentSha256: 'cccc',
          versionId: 'v-b3',
          active: true,
        ),
      ],
    );
  }

  testWidgets(
    'B3: grouped view renders one collapsible group per source document',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(seed: <CorpusBundle>[b3Bundle()]);
      await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      // Two document groups should appear.
      expect(
        find.byKey(Key('admin_corpus_doc_group_${'doc_a.md'.hashCode}')),
        findsOneWidget,
        reason: 'doc_a.md group must render',
      );
      expect(
        find.byKey(Key('admin_corpus_doc_group_${'doc_b.md'.hashCode}')),
        findsOneWidget,
        reason: 'doc_b.md group must render',
      );

      // All three sections are visible (groups start expanded).
      expect(
        find.byKey(const Key('admin_corpus_chunk_doc_a.md#001')),
        findsOneWidget,
        reason: 'Section Alpha tile must be visible (group expanded by default)',
      );
      expect(
        find.byKey(const Key('admin_corpus_chunk_doc_a.md#002')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_corpus_chunk_doc_b.md#001')),
        findsOneWidget,
      );

      // B-r1: the per-card technical-details disclosure is hidden while
      // the screen-level toggle is OFF (the default); flip it on, then
      // the disclosure renders (B2 carryover, now gated by the toggle).
      expect(
        find.byKey(const Key('admin_corpus_chunk_details_doc_a.md#001')),
        findsNothing,
        reason: 'tech disclosure stays hidden while the toggle is OFF',
      );
      await _enableTechDetails(tester);
      expect(
        find.byKey(const Key('admin_corpus_chunk_details_doc_a.md#001')),
        findsOneWidget,
        reason: 'Technical details ExpansionTile must be present per B2',
      );

      // Search box is rendered.
      expect(
        find.byKey(const Key('admin_corpus_content_search')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'B3: search box filters sections — matching section stays, non-matching is hidden',
    (tester) async {
      final gateway = InMemoryCorpusAdminGateway(seed: <CorpusBundle>[b3Bundle()]);
      await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      // Initially all three tiles are visible.
      expect(find.byKey(const Key('admin_corpus_chunk_doc_a.md#001')), findsOneWidget);
      expect(find.byKey(const Key('admin_corpus_chunk_doc_b.md#001')), findsOneWidget);

      // Type a query that only matches "Gamma" (doc_b).
      await tester.enterText(
        find.byKey(const Key('admin_corpus_content_search')),
        'Gamma',
      );
      await tester.pumpAndSettle();

      // doc_b section must still be visible.
      expect(
        find.byKey(const Key('admin_corpus_chunk_doc_b.md#001')),
        findsOneWidget,
        reason: 'Section Gamma matches the search query and must be visible',
      );

      // doc_a sections must be hidden (neither name nor snippet contains "gamma").
      expect(
        find.byKey(const Key('admin_corpus_chunk_doc_a.md#001')),
        findsNothing,
        reason: 'Section Alpha does not match "Gamma" and must be hidden',
      );
      expect(
        find.byKey(const Key('admin_corpus_chunk_doc_a.md#002')),
        findsNothing,
        reason: 'Section Beta does not match "Gamma" and must be hidden',
      );
    },
  );
}

class _CountingCorpusAdminGateway implements CorpusAdminGateway {
  _CountingCorpusAdminGateway(this._inner);

  final CorpusAdminGateway _inner;

  int listVersionsCount = 0;
  int fetchVersionCount = 0;
  int graphCandidateFetchCount = 0;

  @override
  Future<List<CorpusVersionRef>> listVersions() {
    listVersionsCount += 1;
    return _inner.listVersions();
  }

  @override
  Future<CorpusBundle> fetchVersion({required String versionId}) {
    fetchVersionCount += 1;
    return _inner.fetchVersion(versionId: versionId);
  }

  @override
  Future<CorpusDiff> previewDiff(UploadCommand command) =>
      _inner.previewDiff(command);

  @override
  Future<CorpusVersionRef> commitVersion(CommitCommand command) =>
      _inner.commitVersion(command);

  @override
  Future<CorpusVersionRef> rollbackToVersion(RollbackCommand command) =>
      _inner.rollbackToVersion(command);

  @override
  Future<GraphCandidateDiff> listGraphCandidates() {
    graphCandidateFetchCount += 1;
    return _inner.listGraphCandidates();
  }

  @override
  Future<BatchCommitResult> commitGraphCandidatesBatch(
    BatchCommitCommand command,
  ) => _inner.commitGraphCandidatesBatch(command);

  @override
  Future<AgeRebuildResult> requestAgeRebuild({
    required String idempotencyKey,
  }) => _inner.requestAgeRebuild(idempotencyKey: idempotencyKey);
}
