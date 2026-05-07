// Code-Health Lane L9 — blob-breadcrumb rollforward regression test.
//
// Scope (per A3 task spec):
//   * Simulate a crash after Blob write but before anchor row INSERT:
//     write the blob + breadcrumb columns manually (via the fake reader
//     and blob client), DELETE the anchor row (never inserted in this
//     simulation), run `verify`; assert it recovers the anchor row
//     instead of reporting anchorMissing.
//   * Simulate a crash where the Blob is unreachable: verify reports
//     blobUnavailable rather than anchorMissing.
//   * Simulate a crash where the orphan Blob exists but its evidence
//     disagrees with the in-DB chain: verify reports anchorMissing
//     (rollforward refused).
//
// No live Postgres or Azure Blob call is made. All seams are injected
// fakes. The orchestrator's runVerify is driven directly with
// controlled readers/writers/blob clients so the rollforward path
// inside runVerify can be exercised deterministically.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/audit_anchor/audit_anchor.dart';

// ─── constants ────────────────────────────────────────────────────────

const String _opA = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const String _locA = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const String _userA = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
const String _container = 'forge-flow-audit-anchors';

void main() {
  final chainDate = DateTime.utc(2026, 5, 6);
  final originalAnchoredAt = DateTime.utc(2026, 5, 7, 1, 55, 0);
  final blobName = 'audit_anchors/$_opA/2026-05-06.json';

  group('L9 rollforward — runVerify recovers half-written sweep', () {
    test(
        'crash after Blob write but before anchor row INSERT: verify '
        'inserts the missing anchor row and returns ok instead of '
        'anchorMissing', () async {
      final chain = _buildLocalChain(length: 4, chainDate: chainDate);

      // Simulate: blob was written, but audit_chain_anchors row was NOT
      // inserted (binary crashed between blob PUT and DB INSERT).
      final evidenceBytes = const AnchorEvidenceCodec().encode(
        AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: chainDate,
          terminalRowId: chain.last.id,
          terminalRowHashHex: _hex(chain.last.rowHash),
          rowCount: BigInt.from(chain.length),
          anchoredAt: originalAnchoredAt,
        ),
      );
      final blob = _FakeBlobClient()
        ..preload(
          blobName: blobName,
          bytes: evidenceBytes,
          etag: 'etag-crash-recover',
        );

      final writer = _CapturingWriter();
      final reader = _FakeReader(
        chain: chain,
        // No anchor row yet — simulates the crashed state.
        anchor: null,
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: _container,
      );

      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: chainDate,
      );

      // Rollforward succeeded: verify returns ok, not anchorMissing.
      expect(result.outcome, equals(VerifyOutcome.ok),
          reason: 'rollforward must return ok after inserting anchor row');
      expect(result.violations, isEmpty);

      // Exactly one anchor row was inserted by the rollforward.
      expect(writer.inserts, hasLength(1),
          reason: 'rollforward must insert the missing anchor row');
      final anchor = writer.inserts.single;
      expect(anchor.operatorId, equals(_opA));
      expect(anchor.chainDate, equals(chainDate));
      expect(anchor.terminalRowHash, equals(chain.last.rowHash));
      expect(anchor.terminalRowId, equals(chain.last.id));
      expect(anchor.rowCount, equals(BigInt.from(chain.length)));
      expect(anchor.anchoredAt, equals(originalAnchoredAt),
          reason:
              'recovered anchor must use the blob\'s original anchored_at, '
              'not a new timestamp');
      expect(anchor.blobEtag, equals('etag-crash-recover'));

      // No additional blob write — recovery never rewrites an immutable blob.
      expect(blob.writes, isEmpty);
    });

    test(
        'orphan Blob is unreachable (transport error): verify reports '
        'blobUnavailable rather than anchorMissing so the operator '
        'knows to check Azure connectivity', () async {
      final chain = _buildLocalChain(length: 3, chainDate: chainDate);
      // Blob client always throws AuditAnchorBlobUnavailable.
      final blob = _AlwaysUnavailableBlobClient();
      final reader = _FakeReader(chain: chain, anchor: null);
      final writer = _CapturingWriter();
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: _container,
      );

      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: chainDate,
      );

      expect(result.outcome, equals(VerifyOutcome.blobUnavailable),
          reason:
              'unreachable blob during rollforward must surface as '
              'blobUnavailable, not anchorMissing');
      expect(writer.inserts, isEmpty,
          reason: 'no anchor row inserted when blob is unreachable');
    });

    test(
        'orphan Blob exists but evidence disagrees with in-DB chain '
        '(tampered terminal hash): rollforward refuses to insert anchor '
        'row; verify reports anchorMissing', () async {
      final chain = _buildLocalChain(length: 4, chainDate: chainDate);

      // Blob has a wrong terminal_row_hash_hex (simulates tampered evidence
      // or the blob belonging to a different chain state).
      final wrongHashHex = _hex(Uint8List(32)..fillRange(0, 32, 0xDE));
      final tamperedBytes = const AnchorEvidenceCodec().encode(
        AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: chainDate,
          terminalRowId: chain.last.id,
          terminalRowHashHex: wrongHashHex,
          rowCount: BigInt.from(chain.length),
          anchoredAt: originalAnchoredAt,
        ),
      );
      final blob = _FakeBlobClient()
        ..preload(
          blobName: blobName,
          bytes: tamperedBytes,
          etag: 'etag-tampered',
        );
      final reader = _FakeReader(chain: chain, anchor: null);
      final writer = _CapturingWriter();
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: _container,
      );

      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: chainDate,
      );

      // Rollforward refused because the blob disagrees with the chain.
      expect(result.outcome, equals(VerifyOutcome.anchorMissing),
          reason:
              'disagreeing blob must not produce an anchor row; '
              'verify must report anchorMissing');
      expect(
        result.message,
        anyOf(contains('rollforward'), contains('terminal_row_hash_hex')),
        reason: 'message must identify the rollforward refusal so the '
            'runbook triage section is unambiguous',
      );
      expect(writer.inserts, isEmpty,
          reason:
              'no anchor row inserted when blob evidence disagrees with chain');
    });

    test(
        'no orphan Blob (404 on probe): rollforward is a no-op; '
        'verify correctly reports anchorMissing', () async {
      final chain = _buildLocalChain(length: 3, chainDate: chainDate);
      // Blob client has no preloaded blobs → 404 on every read.
      final blob = _FakeBlobClient();
      final reader = _FakeReader(chain: chain, anchor: null);
      final writer = _CapturingWriter();
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: _container,
      );

      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: chainDate,
      );

      expect(result.outcome, equals(VerifyOutcome.anchorMissing));
      expect(writer.inserts, isEmpty,
          reason: 'no anchor row when no orphan blob exists');
    });

    test(
        'anchor row already present: verify takes the normal path and '
        'does not probe the blob for rollforward at all '
        '(rollforward is a fallback, not a primary path)', () async {
      final chain = _buildLocalChain(length: 3, chainDate: chainDate);
      final goodEvidenceBytes = const AnchorEvidenceCodec().encode(
        AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: chainDate,
          terminalRowId: chain.last.id,
          terminalRowHashHex: _hex(chain.last.rowHash),
          rowCount: BigInt.from(chain.length),
          anchoredAt: originalAnchoredAt,
        ),
      );
      final blob = _FakeBlobClient()
        ..preload(
          blobName: blobName,
          bytes: goodEvidenceBytes,
          etag: 'etag-good',
        );
      final existingAnchor = AuditChainAnchor(
        operatorId: _opA,
        chainDate: chainDate,
        terminalRowHash: chain.last.rowHash,
        terminalRowId: chain.last.id,
        rowCount: BigInt.from(chain.length),
        blobUri: 'https://fake/$_container/$blobName',
        blobEtag: 'etag-good',
        anchoredAt: originalAnchoredAt,
      );
      final reader = _FakeReader(chain: chain, anchor: existingAnchor);
      final writer = _CapturingWriter();
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: _container,
      );

      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: chainDate,
      );

      expect(result.outcome, equals(VerifyOutcome.ok));
      expect(writer.inserts, isEmpty,
          reason: 'rollforward must not fire when anchor row exists');
    });
  });
}

// ─── helpers ──────────────────────────────────────────────────────────

String _hex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

List<AuditLogRow> _buildLocalChain({
  required int length,
  required DateTime chainDate,
}) {
  const hasher = AuditChainHasher();
  final rows = <AuditLogRow>[];
  Uint8List? prev;
  for (var i = 0; i < length; i++) {
    final draft = AuditLogRow(
      id: BigInt.from(i + 1),
      operatorId: _opA,
      locationId: _locA,
      chainDate: chainDate,
      occurredAt: DateTime.utc(
          chainDate.year, chainDate.month, chainDate.day, 8, i),
      actorKind: 'user',
      actorUserId: _userA,
      actorPrincipalId: null,
      targetKind: null,
      targetId: null,
      action: 'rollforward.event.$i',
      payloadText: '{"idx": $i}',
      prevRowHash: prev,
      rowHash: Uint8List(32),
    );
    final canonical = hasher.canonicalPayload(draft);
    final hash = Uint8List.fromList(
      sha256.convert(<int>[...?prev, ...canonical]).bytes,
    );
    rows.add(AuditLogRow(
      id: draft.id,
      operatorId: draft.operatorId,
      locationId: draft.locationId,
      chainDate: draft.chainDate,
      occurredAt: draft.occurredAt,
      actorKind: draft.actorKind,
      actorUserId: draft.actorUserId,
      actorPrincipalId: draft.actorPrincipalId,
      targetKind: draft.targetKind,
      targetId: draft.targetId,
      action: draft.action,
      payloadText: draft.payloadText,
      prevRowHash: prev,
      rowHash: hash,
    ));
    prev = hash;
  }
  return rows;
}

// ─── fakes ────────────────────────────────────────────────────────────

class _FakeReader implements AuditChainReader {
  _FakeReader({required this.chain, required this.anchor});

  final List<AuditLogRow> chain;
  final AuditChainAnchor? anchor;

  @override
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  }) async {
    if (anchor == null && chain.isNotEmpty) {
      return [
        AuditChainSummary(operatorId: operatorId, chainDate: chain.first.chainDate),
      ];
    }
    return const [];
  }

  @override
  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      chain;

  @override
  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      anchor;
}

class _CapturingWriter implements AuditChainAnchorWriter {
  final List<AuditChainAnchor> inserts = [];

  @override
  Future<void> insertAnchor(AuditChainAnchor anchor) async {
    inserts.add(anchor);
  }
}

class _FakeBlobClient implements AuditAnchorBlobClient {
  final List<_BlobWrite> writes = [];
  final Map<String, _Preloaded> _store = {};

  void preload({
    required String blobName,
    required List<int> bytes,
    required String etag,
  }) {
    _store[blobName] = _Preloaded(bytes: bytes, etag: etag);
  }

  @override
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  }) async {
    final w = _BlobWrite(
      containerName: containerName,
      blobName: blobName,
      evidenceBytes: evidenceBytes,
    );
    writes.add(w);
    return AnchorBlobWriteResult(
      uri: 'https://fake/$containerName/$blobName',
      etag: 'etag-${writes.length}',
    );
  }

  @override
  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  }) async {
    final p = _store[blobName];
    if (p == null) {
      throw AuditAnchorBlobUnavailable(
          'fake: blob $blobName not found (404)');
    }
    return AnchorBlobReadResult(bytes: p.bytes, etag: p.etag);
  }
}

class _Preloaded {
  _Preloaded({required this.bytes, required this.etag});
  final List<int> bytes;
  final String etag;
}

class _BlobWrite {
  _BlobWrite({
    required this.containerName,
    required this.blobName,
    required this.evidenceBytes,
  });
  final String containerName;
  final String blobName;
  final List<int> evidenceBytes;
}

/// Blob client that always throws transport errors (simulates Azure
/// unreachable for the blobUnavailable rollforward path).
class _AlwaysUnavailableBlobClient implements AuditAnchorBlobClient {
  @override
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  }) async {
    throw const AuditAnchorBlobUnavailable('fake: Azure unreachable');
  }

  @override
  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  }) async {
    throw const AuditAnchorBlobUnavailable('fake: Azure unreachable');
  }
}
