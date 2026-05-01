// Phase 11A.3a — Corpus admin gateway tests.
//
// Two coverage groups:
//
//   * `InMemoryCorpusAdminGateway` — exercises the demo gateway's
//     CRUD shapes + diff computation + idempotency replay. The screen
//     widget tests run against this same gateway, so anything it
//     accepts must mirror the production validators in the proxy.
//
//   * Diff classification — pins the (added / modified / inactivated)
//     bucket logic so a regression in the chunker can't silently drop
//     a category from the preview.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/corpus_admin_models.dart';
import 'package:forge_and_flow/admin/services/corpus_admin_gateway.dart';

void main() {
  CorpusBundle seedBundle({
    String versionId = '00000000-0000-4000-9000-000000000001',
    String summary = 'Initial seed',
    DateTime? createdAt,
    DateTime? supersededAt,
    String? rollbackOf,
    int chunkCount = 2,
    String contentHashA = 'a',
    String contentHashB = 'b',
  }) {
    final created = createdAt ?? DateTime.utc(2026, 1, 1);
    return CorpusBundle(
      version: CorpusVersionRef(
        versionId: versionId,
        createdBy: 'seed-actor',
        createdAt: created,
        summary: summary,
        rollbackOf: rollbackOf,
        supersededAt: supersededAt,
        chunkCount: chunkCount,
      ),
      chunks: <ChunkPreview>[
        ChunkPreview(
          chunkId: 'methodology_seed.md#000',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: const <String>['Forge & Flow Methodology'],
          snippet: 'Methodology preamble',
          estimatedTokens: 64,
          riskLevel: 'standard',
          contentSha256: contentHashA * 64,
          versionId: versionId,
          active: supersededAt == null,
        ),
        ChunkPreview(
          chunkId: 'methodology_seed.md#001',
          docId: 'methodology_seed.md',
          sourcePath: 'methodology_seed.md',
          headingPath: const <String>['Forge & Flow Methodology', 'Cycles'],
          snippet: 'Cycles paragraph',
          estimatedTokens: 80,
          riskLevel: 'standard',
          contentSha256: contentHashB * 64,
          versionId: versionId,
          active: supersededAt == null,
        ),
      ],
    );
  }

  UploadCommand demoUpload(String body, {String idempotencyKey = 'k1'}) {
    return UploadCommand(
      fileName: 'methodology_seed.md',
      contentType: 'text/markdown',
      bytes: corpusUploadBytesFromString(body),
      idempotencyKey: idempotencyKey,
    );
  }

  group('InMemoryCorpusAdminGateway — listVersions', () {
    test('returns current-first then prior, alphabetical-stable',
        () async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[
          seedBundle(
            versionId: 'v1',
            createdAt: DateTime.utc(2026, 1, 1),
            supersededAt: DateTime.utc(2026, 1, 2),
            summary: 'v1 prior',
          ),
          seedBundle(
            versionId: 'v2',
            createdAt: DateTime.utc(2026, 1, 2),
            summary: 'v2 current',
          ),
        ],
      );
      final versions = await gateway.listVersions();
      expect(versions.first.versionId, equals('v2'));
      expect(versions.first.isCurrent, isTrue);
      expect(versions.last.versionId, equals('v1'));
      expect(versions.last.isCurrent, isFalse);
    });
  });

  group('InMemoryCorpusAdminGateway — fetchVersion', () {
    test('returns the bundle for a known version', () async {
      final gateway = InMemoryCorpusAdminGateway(
        seed: <CorpusBundle>[seedBundle(versionId: 'v1')],
      );
      final bundle = await gateway.fetchVersion(versionId: 'v1');
      expect(bundle.version.versionId, equals('v1'));
      expect(bundle.chunks, hasLength(2));
    });

    test('throws 404-style error for an unknown version', () async {
      final gateway = InMemoryCorpusAdminGateway();
      Object? thrown;
      try {
        await gateway.fetchVersion(versionId: 'missing');
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CorpusAdminGatewayError>());
      expect(
        (thrown! as CorpusAdminGatewayError).statusCode,
        equals(404),
      );
    });
  });

  group('InMemoryCorpusAdminGateway — previewDiff classification', () {
    test('first upload classifies every chunk as added', () async {
      final gateway = InMemoryCorpusAdminGateway();
      final diff = await gateway.previewDiff(
        demoUpload(
          '# Forge & Flow\n\n## Cycles\n\nSixty-day cycles.\n',
        ),
      );
      expect(diff.added, isNotEmpty);
      expect(diff.modified, isEmpty);
      expect(diff.inactivated, isEmpty);
      expect(diff.previewToken, isNotEmpty);
    });

    test('re-uploading the same body yields no added/modified/inactivated',
        () async {
      final gateway = InMemoryCorpusAdminGateway();
      const body = '# Forge & Flow\n\n## Cycles\n\nSixty-day cycles.\n';
      final firstDiff = await gateway.previewDiff(
        demoUpload(body, idempotencyKey: 'first'),
      );
      await gateway.commitVersion(
        CommitCommand(
          previewToken: firstDiff.previewToken,
          summary: 'first commit',
          idempotencyKey: 'commit-first',
        ),
      );
      final replayDiff = await gateway.previewDiff(
        demoUpload(body, idempotencyKey: 'second'),
      );
      expect(replayDiff.added, isEmpty);
      expect(replayDiff.modified, isEmpty);
      expect(replayDiff.inactivated, isEmpty);
    });

    test(
      'editing a chunk and removing one classifies modified + inactivated',
      () async {
        final gateway = InMemoryCorpusAdminGateway();
        const v1 =
            '# Forge & Flow\n\n## Cycles\n\nSixty-day cycles.\n\n'
            '## Daypart\n\nDaypart guidance.\n';
        final firstDiff = await gateway.previewDiff(
          demoUpload(v1, idempotencyKey: 'k1'),
        );
        await gateway.commitVersion(
          CommitCommand(
            previewToken: firstDiff.previewToken,
            summary: 'v1',
            idempotencyKey: 'commit-v1',
          ),
        );

        const v2 =
            '# Forge & Flow\n\n## Cycles\n\nSixty-day cycles, locked '
            'standards.\n';
        final secondDiff = await gateway.previewDiff(
          demoUpload(v2, idempotencyKey: 'k2'),
        );
        // The Cycles chunk text changed -> modified.
        expect(secondDiff.modified, isNotEmpty);
        // The Daypart chunk dropped out -> inactivated.
        expect(
          secondDiff.inactivated.where(
            (c) => c.chunkId.contains('#'),
          ),
          isNotEmpty,
        );
      },
    );
  });

  group('InMemoryCorpusAdminGateway — upload validation', () {
    test('rejects an oversized upload', () async {
      final gateway = InMemoryCorpusAdminGateway();
      final big = Uint8List(kCorpusUploadMaxBytes + 1)
        ..fillRange(0, kCorpusUploadMaxBytes + 1, 0x23);
      Object? thrown;
      try {
        await gateway.previewDiff(
          UploadCommand(
            fileName: 'methodology.md',
            contentType: 'text/markdown',
            bytes: big,
            idempotencyKey: 'k-big',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CorpusAdminGatewayError>());
      expect(
        (thrown! as CorpusAdminGatewayError).errorCode,
        equals('upload_too_large'),
      );
    });

    test('rejects an unsupported content type', () async {
      final gateway = InMemoryCorpusAdminGateway();
      Object? thrown;
      try {
        await gateway.previewDiff(
          UploadCommand(
            fileName: 'methodology.pdf',
            contentType: 'application/pdf',
            bytes: corpusUploadBytesFromString('# Hello'),
            idempotencyKey: 'k-pdf',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CorpusAdminGatewayError>());
      expect(
        (thrown! as CorpusAdminGatewayError).errorCode,
        equals('unsupported_content_type'),
      );
    });

    test('rejects a binary payload (null byte)', () async {
      final gateway = InMemoryCorpusAdminGateway();
      Object? thrown;
      try {
        await gateway.previewDiff(
          UploadCommand(
            fileName: 'methodology.md',
            contentType: 'text/markdown',
            bytes: Uint8List.fromList(<int>[0, 1, 2, 3, 4]),
            idempotencyKey: 'k-bin',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CorpusAdminGatewayError>());
      expect(
        (thrown! as CorpusAdminGatewayError).errorCode,
        equals('binary_or_unsupported_file'),
      );
    });
  });

  group('InMemoryCorpusAdminGateway — commit + rollback', () {
    test('commit promotes the staged upload to the current version',
        () async {
      final gateway = InMemoryCorpusAdminGateway();
      final diff = await gateway.previewDiff(
        demoUpload('# Forge\n\n## Cycles\n\nSixty days.\n'),
      );
      final committed = await gateway.commitVersion(
        CommitCommand(
          previewToken: diff.previewToken,
          summary: 'first commit',
          idempotencyKey: 'commit-1',
        ),
      );
      expect(committed.isCurrent, isTrue);
      final versions = await gateway.listVersions();
      expect(versions.first.versionId, equals(committed.versionId));
    });

    test('commit replays cached version on idempotency key reuse',
        () async {
      final gateway = InMemoryCorpusAdminGateway();
      final diff = await gateway.previewDiff(
        demoUpload('# Forge\n\n## Cycles\n\nSixty days.\n'),
      );
      final firstCommit = await gateway.commitVersion(
        CommitCommand(
          previewToken: diff.previewToken,
          summary: 'first commit',
          idempotencyKey: 'commit-1',
        ),
      );
      // Replaying the same key returns the same version, no second
      // ledger row gets written.
      final replayed = await gateway.commitVersion(
        CommitCommand(
          previewToken: diff.previewToken,
          summary: 'first commit',
          idempotencyKey: 'commit-1',
        ),
      );
      expect(replayed.versionId, equals(firstCommit.versionId));
      final versions = await gateway.listVersions();
      expect(versions, hasLength(1));
    });

    test('commit rejects an unknown preview_token', () async {
      final gateway = InMemoryCorpusAdminGateway();
      Object? thrown;
      try {
        await gateway.commitVersion(
          const CommitCommand(
            previewToken: 'unknown',
            summary: '',
            idempotencyKey: 'commit-unknown',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CorpusAdminGatewayError>());
      expect(
        (thrown! as CorpusAdminGatewayError).errorCode,
        equals('unknown_preview_token'),
      );
    });

    test('rollback writes a fresh row whose rollback_of points at target',
        () async {
      final gateway = InMemoryCorpusAdminGateway();
      // Seed v1.
      final firstDiff = await gateway.previewDiff(
        demoUpload(
          '# Forge\n\n## Cycles\n\nSixty days.\n',
          idempotencyKey: 'k1',
        ),
      );
      final v1 = await gateway.commitVersion(
        CommitCommand(
          previewToken: firstDiff.previewToken,
          summary: 'v1',
          idempotencyKey: 'commit-v1',
        ),
      );
      // Commit v2.
      final secondDiff = await gateway.previewDiff(
        demoUpload(
          '# Forge\n\n## Cycles\n\nSixty days, locked.\n',
          idempotencyKey: 'k2',
        ),
      );
      await gateway.commitVersion(
        CommitCommand(
          previewToken: secondDiff.previewToken,
          summary: 'v2',
          idempotencyKey: 'commit-v2',
        ),
      );
      // Rollback to v1.
      final rolled = await gateway.rollbackToVersion(
        RollbackCommand(
          targetVersionId: v1.versionId,
          summary: 'undo v2',
          idempotencyKey: 'rollback-1',
        ),
      );
      expect(rolled.rollbackOf, equals(v1.versionId));
      expect(rolled.isCurrent, isTrue);
      final versions = await gateway.listVersions();
      expect(versions.first.versionId, equals(rolled.versionId));
    });

    test('rollback rejects an unknown target version', () async {
      final gateway = InMemoryCorpusAdminGateway();
      Object? thrown;
      try {
        await gateway.rollbackToVersion(
          const RollbackCommand(
            targetVersionId: 'missing',
            summary: '',
            idempotencyKey: 'rollback-missing',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CorpusAdminGatewayError>());
      expect(
        (thrown! as CorpusAdminGatewayError).statusCode,
        equals(404),
      );
    });
  });
}
