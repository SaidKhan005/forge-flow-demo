// B-r3 — Add-knowledge + Update-history tests (Knowledge tab only).
//
// Drives the two backend-backed B-r3 features against the in-memory
// CorpusAdminGateway fake:
//
//   * Add document -> previewDiff: the "What this update changes" panel
//     renders an added row and a modified row, each with B-r2's kind
//     icon + plain-English line. (No fabricated kinds.)
//   * "Save this update" -> commitVersion: the staged upload becomes the
//     new current version.
//   * "Cancel" discards the staged upload.
//   * Update history renders the current version with an "In use now"
//     badge plus prior rows, and the honest "No earlier versions yet"
//     empty state when only the current version exists.
//   * "Go back to this version" -> rollbackToVersion, behind a confirm
//     dialog; the confirm copy states it writes a NEW version and
//     deletes nothing.
//   * Read-only (ff_support) hides the dropzone, the "Choose a file"
//     button, and every "Go back to this version" button, while the
//     history timeline itself stays visible.
//
// Scope guard: this file drives only the Knowledge tab and never touches
// the Connections tab or its shared widgets.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_human_labels.dart';
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

  ChunkPreview chunk({
    required String chunkId,
    required String sourcePath,
    required List<String> headingPath,
    String hash = 'z',
    String snippet = 'Existing body.',
  }) {
    return ChunkPreview(
      chunkId: chunkId,
      docId: sourcePath,
      sourcePath: sourcePath,
      headingPath: headingPath,
      snippet: snippet,
      estimatedTokens: 40,
      riskLevel: 'standard',
      contentSha256: hash * 64,
      versionId: 'seed',
      active: true,
    );
  }

  CorpusBundle currentBundle({
    required String versionId,
    String summary = 'Current',
    DateTime? createdAt,
    List<ChunkPreview>? chunks,
  }) {
    return CorpusBundle(
      version: CorpusVersionRef(
        versionId: versionId,
        createdBy: 'seed-actor',
        createdAt: createdAt ?? DateTime.utc(2026, 2, 1),
        summary: summary,
        rollbackOf: null,
        supersededAt: null,
        chunkCount: (chunks ?? const <ChunkPreview>[]).length,
      ),
      chunks:
          chunks ??
          <ChunkPreview>[
            chunk(
              chunkId: 'doc.md#000',
              sourcePath: 'doc.md',
              headingPath: const <String>['One'],
            ),
          ],
    );
  }

  // A markdown body that the in-memory chunker splits into:
  //   doc.md#000  (heading: Doc > One)   -> matches the seed chunk key,
  //                                          different hash => MODIFIED
  //   doc.md#001  (heading: Doc > Two)   -> new key            => ADDED
  const docUpload =
      '# Doc\n\n'
      '## One\n\nFirst section body about the SOP procedure.\n\n'
      '## Two\n\nSecond section body about the CPLH metric.\n';

  UploadCommand uploadCommand(String key) => UploadCommand(
    fileName: 'doc.md',
    contentType: 'text/markdown',
    bytes: Uint8List.fromList(docUpload.codeUnits),
    idempotencyKey: key,
  );

  group('Add knowledge + What this update changes', () {
    testWidgets('previewDiff renders an added row and a modified row', (
      tester,
    ) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[currentBundle(versionId: 'v-cur')],
      );
      await tester.pumpWidget(
        wrap(
          CorpusAdminScreen(
            gateway: gateway,
            uploadPicker: (_) =>
                Future<UploadCommand?>.value(uploadCommand('k-preview')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_corpus_add_choose_file')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_corpus_change_preview')),
        findsOneWidget,
      );
      expect(find.text('What this update changes'), findsOneWidget);

      // doc.md#001 is brand new -> an added row.
      expect(
        find.byKey(const Key('admin_corpus_change_added_doc.md#001')),
        findsOneWidget,
        reason: 'the new second section should render as an added row',
      );
      // doc.md#000 matches the seed key with a different hash -> modified.
      expect(
        find.byKey(const Key('admin_corpus_change_modified_doc.md#000')),
        findsOneWidget,
        reason: 'the reworded first section should render as a modified row',
      );

      // Plain-English lines from the approved preview (no em dash).
      expect(
        find.text('Reworded, a bit clearer than before'),
        findsOneWidget,
      );
      expect(find.textContaining('the advisor will learn'), findsWidgets);

      // Honest: the "nothing changed" notice is absent when there are
      // real changes.
      expect(find.byKey(const Key('admin_corpus_change_none')), findsNothing);
    });

    testWidgets('Save this update calls commitVersion', (tester) async {
      final gateway = _SpyGateway(
        InMemoryCorpusAdminGateway(
          seed: <CorpusBundle>[currentBundle(versionId: 'v-cur')],
        ),
      );
      await tester.pumpWidget(
        wrap(
          CorpusAdminScreen(
            gateway: gateway,
            uploadPicker: (_) =>
                Future<UploadCommand?>.value(uploadCommand('k-save')),
            idempotencyKeyGenerator: () => 'commit-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_corpus_add_choose_file')));
      await tester.pumpAndSettle();

      final saveButton = find.byKey(
        const Key('admin_corpus_save_update_button'),
      );
      await tester.ensureVisible(saveButton);
      await tester.pumpAndSettle();
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(
        gateway.commitCount,
        equals(1),
        reason: 'Save this update should call commitVersion exactly once',
      );
      // A new current version landed on top of the seed.
      final versions = await gateway.listVersions();
      expect(versions.first.isCurrent, isTrue);
      expect(versions.first.versionId, isNot(equals('v-cur')));
      // The change preview clears after a successful save.
      expect(
        find.byKey(const Key('admin_corpus_change_preview')),
        findsNothing,
      );
    });

    testWidgets('Cancel discards the staged upload without committing', (
      tester,
    ) async {
      final gateway = _SpyGateway(
        InMemoryCorpusAdminGateway(
          seed: <CorpusBundle>[currentBundle(versionId: 'v-cur')],
        ),
      );
      await tester.pumpWidget(
        wrap(
          CorpusAdminScreen(
            gateway: gateway,
            uploadPicker: (_) =>
                Future<UploadCommand?>.value(uploadCommand('k-cancel')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_corpus_add_choose_file')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('admin_corpus_change_preview')),
        findsOneWidget,
      );

      final cancel = find.byKey(const Key('admin_corpus_cancel_update_button'));
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      await tester.tap(cancel);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_corpus_change_preview')),
        findsNothing,
      );
      expect(gateway.commitCount, equals(0));
    });
  });

  group('Update history + rollback', () {
    testWidgets('renders the current version with an In-use-now badge', (
      tester,
    ) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          currentBundle(
            versionId: 'v-only',
            summary: 'Added Responsible Alcohol Service training',
          ),
        ],
      );
      await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('admin_corpus_history_card')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_corpus_history_row_v-only')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_corpus_history_in_use_v-only')),
        findsOneWidget,
      );
      expect(find.text('In use now'), findsOneWidget);
      expect(
        find.textContaining(AdminKnowledgeBaseCopy.historyByStaff),
        findsWidgets,
      );

      // Honest empty state: only the current version exists, so there is
      // no "Go back" affordance and the no-prior notice shows.
      expect(
        find.byKey(const Key('admin_corpus_history_empty')),
        findsOneWidget,
      );
      expect(find.text('No earlier versions yet.'), findsOneWidget);
      expect(find.byKey(const Key('admin_corpus_go_back_v-only')), findsNothing);
    });

    testWidgets('renders prior rows with a Go-back button', (tester) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          currentBundle(
            versionId: 'v-old',
            summary: 'Added the Food Safety Manual',
            createdAt: DateTime.utc(2026, 1, 1),
          ).supersede(DateTime.utc(2026, 2, 1)),
          currentBundle(
            versionId: 'v-new',
            summary: 'Added Responsible Alcohol Service training',
            createdAt: DateTime.utc(2026, 2, 1),
          ),
        ],
      );
      await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_corpus_history_in_use_v-new')),
        findsOneWidget,
      );
      // The prior version has a "Go back to this version" button; the
      // current one does not (and the empty notice is gone).
      expect(
        find.byKey(const Key('admin_corpus_go_back_v-old')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_corpus_go_back_v-new')), findsNothing);
      expect(
        find.byKey(const Key('admin_corpus_history_empty')),
        findsNothing,
      );
      expect(find.text('Go back to this version'), findsOneWidget);
    });

    testWidgets('Go back to this version calls rollbackToVersion after confirm', (
      tester,
    ) async {
      final gateway = _SpyGateway(
        InMemoryCorpusAdminGateway(
          seed: <CorpusBundle>[
            currentBundle(
              versionId: 'v-old',
              summary: 'Added the Food Safety Manual',
              createdAt: DateTime.utc(2026, 1, 1),
            ).supersede(DateTime.utc(2026, 2, 1)),
            currentBundle(
              versionId: 'v-new',
              summary: 'Latest',
              createdAt: DateTime.utc(2026, 2, 1),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        wrap(
          CorpusAdminScreen(
            gateway: gateway,
            idempotencyKeyGenerator: () => 'rb-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final goBack = find.byKey(const Key('admin_corpus_go_back_v-old'));
      await tester.ensureVisible(goBack);
      await tester.pumpAndSettle();
      await tester.tap(goBack);
      await tester.pumpAndSettle();

      // Confirm dialog states honestly that nothing is deleted.
      expect(
        find.byKey(const Key('admin_corpus_confirm_dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('Nothing is deleted'), findsOneWidget);
      expect(gateway.rollbackCount, equals(0), reason: 'not yet confirmed');

      await tester.tap(find.byKey(const Key('admin_corpus_confirm_ok')));
      await tester.pumpAndSettle();

      expect(
        gateway.rollbackCount,
        equals(1),
        reason: 'confirming should call rollbackToVersion once',
      );
      expect(gateway.lastRollbackTarget, equals('v-old'));

      // The rollback wrote a NEW version (append-only ledger); nothing
      // was deleted, so the original three-version lineage is intact.
      final versions = await gateway.listVersions();
      final current = versions.firstWhere((v) => v.isCurrent);
      expect(current.rollbackOf, equals('v-old'));
      expect(current.versionId, isNot(equals('v-old')));
      expect(current.versionId, isNot(equals('v-new')));
    });

    testWidgets('cancelling the confirm dialog does not roll back', (
      tester,
    ) async {
      final gateway = _SpyGateway(
        InMemoryCorpusAdminGateway(
          seed: <CorpusBundle>[
            currentBundle(
              versionId: 'v-old',
              createdAt: DateTime.utc(2026, 1, 1),
            ).supersede(DateTime.utc(2026, 2, 1)),
            currentBundle(
              versionId: 'v-new',
              createdAt: DateTime.utc(2026, 2, 1),
            ),
          ],
        ),
      );
      await tester.pumpWidget(wrap(CorpusAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      final goBack = find.byKey(const Key('admin_corpus_go_back_v-old'));
      await tester.ensureVisible(goBack);
      await tester.pumpAndSettle();
      await tester.tap(goBack);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_corpus_confirm_cancel')));
      await tester.pumpAndSettle();

      expect(gateway.rollbackCount, equals(0));
    });
  });

  group('Read-only (ff_support)', () {
    testWidgets('hides the dropzone, Choose-a-file, and Go-back buttons', (
      tester,
    ) async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          currentBundle(
            versionId: 'v-old',
            createdAt: DateTime.utc(2026, 1, 1),
          ).supersede(DateTime.utc(2026, 2, 1)),
          currentBundle(
            versionId: 'v-new',
            createdAt: DateTime.utc(2026, 2, 1),
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(CorpusAdminScreen(gateway: gateway, editingEnabled: false)),
      );
      await tester.pumpAndSettle();

      // The Add-knowledge card title still reads (orientation copy), but
      // the dropzone + pick button are gone.
      expect(
        find.byKey(const Key('admin_corpus_add_knowledge_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_corpus_add_choose_file')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_corpus_add_drop_zone')),
        findsNothing,
      );

      // History is always visible (read-only audit view), but rollback is
      // hidden on every prior row.
      expect(find.byKey(const Key('admin_corpus_history_card')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_corpus_history_in_use_v-new')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_corpus_go_back_v-old')), findsNothing);
    });
  });
}

/// Append-only supersede helper for building a prior version in tests.
extension on CorpusBundle {
  CorpusBundle supersede(DateTime when) => CorpusBundle(
    version: CorpusVersionRef(
      versionId: version.versionId,
      createdBy: version.createdBy,
      createdAt: version.createdAt,
      summary: version.summary,
      rollbackOf: version.rollbackOf,
      supersededAt: when,
      chunkCount: version.chunkCount,
    ),
    chunks: chunks,
  );
}

/// Counts commit / rollback calls so the tests can assert the button
/// reached the gateway, then delegates to the real in-memory fake so the
/// ledger state stays consistent.
class _SpyGateway implements CorpusAdminGateway {
  _SpyGateway(this._inner);

  final CorpusAdminGateway _inner;

  int commitCount = 0;
  int rollbackCount = 0;
  String? lastRollbackTarget;

  @override
  Future<List<CorpusVersionRef>> listVersions() => _inner.listVersions();

  @override
  Future<CorpusBundle> fetchVersion({required String versionId}) =>
      _inner.fetchVersion(versionId: versionId);

  @override
  Future<CorpusDiff> previewDiff(UploadCommand command) =>
      _inner.previewDiff(command);

  @override
  Future<CorpusVersionRef> commitVersion(CommitCommand command) {
    commitCount += 1;
    return _inner.commitVersion(command);
  }

  @override
  Future<CorpusVersionRef> rollbackToVersion(RollbackCommand command) {
    rollbackCount += 1;
    lastRollbackTarget = command.targetVersionId;
    return _inner.rollbackToVersion(command);
  }

  @override
  Future<GraphCandidateDiff> listGraphCandidates() =>
      _inner.listGraphCandidates();

  @override
  Future<BatchCommitResult> commitGraphCandidatesBatch(
    BatchCommitCommand command,
  ) => _inner.commitGraphCandidatesBatch(command);

  @override
  Future<AgeRebuildResult> requestAgeRebuild({
    required String idempotencyKey,
  }) => _inner.requestAgeRebuild(idempotencyKey: idempotencyKey);
}
