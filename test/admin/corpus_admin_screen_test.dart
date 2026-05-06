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

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
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
      matching: find.text('Relationship review'),
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

    await tester.tap(find.byKey(const Key('admin_corpus_rollback_v1')));
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
      final source = DemoAdminAuthSource(
        initial: const AdminAuthAuthenticated(
          AdminAuthSession(
            uid: 'demo-ff-support',
            email: 'support@forgeflow.test',
            displayName: 'Demo F&F Support',
            roles: <String>['ff_support'],
          ),
        ),
      );
      addTearDown(source.dispose);
      await tester.pumpWidget(
        AdminConsoleServicesScope(
          corpusAdminGateway: gateway,
          adminAuthSource: source,
          child: AdminConsoleApp(authSource: source),
        ),
      );
      await tester.pumpAndSettle();

      final corpusNavItem = find.byKey(const Key('admin_nav_item_corpus'));
      await tester.ensureVisible(corpusNavItem);
      await tester.tap(corpusNavItem);
      await tester.pumpAndSettle();

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
