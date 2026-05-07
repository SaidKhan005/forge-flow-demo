// Code-Health Lane M3 / L9 — verify rollforward path test.
//
// Scope (from the A3 spec — five cases):
//   1. crash-after-blob: blob reachable, chain matches →
//      anchor row inserted, verify returns ok.
//   2. blob unreachable → blobUnavailable (never anchorMissing).
//   3. orphan blob disagrees with chain →
//      anchorMissing with explicit "rollforward refused" in message.
//   4. no orphan blob (404 probe) → anchorMissing (ordinary path).
//   5. normal: anchor row present → ok, no rollforward triggered.
//
// All tests drive [AuditAnchorOrchestrator.runVerify] with fake
// [AuditChainReader], [AuditChainAnchorWriter], and
// [AuditAnchorBlobClient] seams; no live Postgres or Azure Blob calls.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/audit_anchor/audit_anchor.dart';

// ─── Constants ────────────────────────────────────────────────────────

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _container = 'forge-flow-audit-anchors';

// ─── Tests ────────────────────────────────────────────────────────────

void main() {
  final chainDate = DateTime.utc(2026, 4, 27);
  final nowUtc = DateTime.utc(2026, 4, 28, 2, 0, 0);
  final blobName = anchorBlobName(operatorId: _opA, chainDate: chainDate);

  group('A3 rollforward path — runVerify', () {
    // ── Case 1: crash-after-blob recovery ─────────────────────────────
    test(
      'case 1 (crash-after-blob): blob reachable and chain matches → '
      'anchor row inserted, verify returns ok without re-writing the blob',
      () async {
        final clean = _buildLocalChain(length: 5, chainDate: chainDate);
        final originalAnchoredAt = DateTime.utc(2026, 4, 27, 23, 55, 0);
        final blobBytes = const AnchorEvidenceCodec().encode(
          AnchorEvidence(
            schemaVersion: 1,
            operatorId: _opA,
            chainDate: chainDate,
            terminalRowId: clean.last.id,
            terminalRowHashHex: _hex(clean.last.rowHash),
            rowCount: BigInt.from(clean.length),
            anchoredAt: originalAnchoredAt,
          ),
        );
        final blob = _FakeBlobClient()
          ..preload(blobName: blobName, bytes: blobBytes, etag: 'etag-orig');

        final reader = _FakeReader(
          chainsByDate: <String, List<AuditLogRow>>{
            '$_opA|2026-04-27': clean,
          },
          // No anchor row — simulates crash before INSERT.
          anchorsByDate: const <String, AuditChainAnchor>{},
        );
        final writer = _FakeAnchorWriter();
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

        // Returns ok (rollforward committed).
        expect(result.outcome, equals(VerifyOutcome.ok));
        expect(result.message, contains('rollforward committed'));
        // Anchor row inserted using the blob's original anchored_at.
        expect(writer.inserts, hasLength(1));
        final anchor = writer.inserts.single;
        expect(anchor.operatorId, equals(_opA));
        expect(anchor.chainDate, equals(chainDate));
        expect(anchor.anchoredAt, equals(originalAnchoredAt));
        expect(anchor.terminalRowHash, equals(clean.last.rowHash));
        expect(anchor.terminalRowId, equals(clean.last.id));
        expect(anchor.rowCount, equals(BigInt.from(clean.length)));
        expect(anchor.blobEtag, equals('etag-orig'));
        // No new blob written (immutable blobs are never rewritten).
        expect(blob.writes, isEmpty);
      },
    );

    // ── Case 2: blob unreachable ───────────────────────────────────────
    test(
      'case 2 (blob unreachable): blob probe throws '
      'AuditAnchorBlobUnavailable → outcome is blobUnavailable, '
      'never anchorMissing',
      () async {
        final clean = _buildLocalChain(length: 5, chainDate: chainDate);
        // No preloaded blob → readImmutable throws AuditAnchorBlobUnavailable.
        final blob = _FakeBlobClient();

        final reader = _FakeReader(
          chainsByDate: <String, List<AuditLogRow>>{
            '$_opA|2026-04-27': clean,
          },
          anchorsByDate: const <String, AuditChainAnchor>{},
        );
        final writer = _FakeAnchorWriter();
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

        expect(
          result.outcome,
          equals(VerifyOutcome.blobUnavailable),
          reason: 'unreachable blob must produce blobUnavailable, '
              'never anchorMissing',
        );
        expect(result.message, isNotNull);
        expect(writer.inserts, isEmpty);
      },
    );

    // ── Case 3: orphan blob disagrees with chain ───────────────────────
    test(
      'case 3 (orphan blob disagrees): blob reachable but terminal hash '
      'mismatch → outcome is anchorMissing with "rollforward refused" in '
      'message; no anchor row inserted',
      () async {
        final clean = _buildLocalChain(length: 5, chainDate: chainDate);
        // Blob carries a wrong terminal hash — simulates tampered evidence
        // or a chain that drifted since the orphan blob was written.
        final wrongHashHex = _hex(Uint8List(32)..fillRange(0, 32, 0xCC));
        final blobBytes = const AnchorEvidenceCodec().encode(
          AnchorEvidence(
            schemaVersion: 1,
            operatorId: _opA,
            chainDate: chainDate,
            terminalRowId: clean.last.id,
            terminalRowHashHex: wrongHashHex,
            rowCount: BigInt.from(clean.length),
            anchoredAt: nowUtc,
          ),
        );
        final blob = _FakeBlobClient()
          ..preload(blobName: blobName, bytes: blobBytes, etag: 'etag-bad');

        final reader = _FakeReader(
          chainsByDate: <String, List<AuditLogRow>>{
            '$_opA|2026-04-27': clean,
          },
          anchorsByDate: const <String, AuditChainAnchor>{},
        );
        final writer = _FakeAnchorWriter();
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
        expect(
          result.message,
          contains('rollforward refused'),
          reason: 'message must explicitly say rollforward was refused',
        );
        // No anchor row inserted — rollforward refusal is safe by design.
        expect(writer.inserts, isEmpty);
        // No new blob written.
        expect(blob.writes, isEmpty);
      },
    );

    // ── Case 4: no orphan blob ────────────────────────────────────────
    test(
      'case 4 (no orphan blob): blob probe returns 404 → outcome is '
      'blobUnavailable (blob is unreachable / not found), no anchor row',
      () async {
        final clean = _buildLocalChain(length: 5, chainDate: chainDate);
        // Empty fake blob client: readImmutable always returns
        // AuditAnchorBlobUnavailable("not preloaded").
        final blob = _FakeBlobClient();

        final reader = _FakeReader(
          chainsByDate: <String, List<AuditLogRow>>{
            '$_opA|2026-04-27': clean,
          },
          anchorsByDate: const <String, AuditChainAnchor>{},
        );
        final writer = _FakeAnchorWriter();
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

        // The rollforward probe threw AuditAnchorBlobUnavailable, so
        // the outcome is blobUnavailable rather than anchorMissing.
        expect(result.outcome, equals(VerifyOutcome.blobUnavailable));
        expect(writer.inserts, isEmpty);
      },
    );

    // ── Case 5: normal — anchor present ──────────────────────────────
    test(
      'case 5 (normal): anchor row present → ok returned without '
      'triggering rollforward; no anchor inserted, no blob written',
      () async {
        final clean = _buildLocalChain(length: 5, chainDate: chainDate);
        final goodEvidenceBytes = const AnchorEvidenceCodec().encode(
          AnchorEvidence(
            schemaVersion: 1,
            operatorId: _opA,
            chainDate: chainDate,
            terminalRowId: clean.last.id,
            terminalRowHashHex: _hex(clean.last.rowHash),
            rowCount: BigInt.from(clean.length),
            anchoredAt: nowUtc,
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
          terminalRowHash: clean.last.rowHash,
          terminalRowId: clean.last.id,
          rowCount: BigInt.from(clean.length),
          blobUri: 'https://fake/$_container/$blobName',
          blobEtag: 'etag-good',
          anchoredAt: nowUtc,
        );

        final reader = _FakeReader(
          chainsByDate: <String, List<AuditLogRow>>{
            '$_opA|2026-04-27': clean,
          },
          anchorsByDate: <String, AuditChainAnchor>{
            '$_opA|2026-04-27': existingAnchor,
          },
        );
        final writer = _FakeAnchorWriter();
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
        expect(result.violations, isEmpty);
        // Rollforward must NOT have run — no anchor inserted.
        expect(
          writer.inserts,
          isEmpty,
          reason: 'rollforward must not run when anchor row already exists',
        );
        // Blob was read once for normal verification; no blob written.
        expect(blob.writes, isEmpty);
      },
    );
  });
}

// ─── Fakes ────────────────────────────────────────────────────────────

class _FakeReader implements AuditChainReader {
  _FakeReader({
    required this.chainsByDate,
    required this.anchorsByDate,
  });

  final Map<String, List<AuditLogRow>> chainsByDate;
  final Map<String, AuditChainAnchor> anchorsByDate;

  String _key(String operatorId, DateTime chainDate) {
    final utc = chainDate.toUtc();
    return '$operatorId|'
        '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  @override
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  }) async =>
      const <AuditChainSummary>[];

  @override
  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      chainsByDate[_key(operatorId, chainDate)] ?? const <AuditLogRow>[];

  @override
  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      anchorsByDate[_key(operatorId, chainDate)];
}

class _FakeAnchorWriter implements AuditChainAnchorWriter {
  final List<AuditChainAnchor> inserts = <AuditChainAnchor>[];

  @override
  Future<void> insertAnchor(AuditChainAnchor anchor) async {
    inserts.add(anchor);
  }
}

class _FakeBlobClient implements AuditAnchorBlobClient {
  final List<_FakeBlobWrite> writes = <_FakeBlobWrite>[];
  final Map<String, _PreloadedBlob> _preload = <String, _PreloadedBlob>{};

  void preload({
    required String blobName,
    required List<int> bytes,
    required String etag,
  }) {
    _preload[blobName] = _PreloadedBlob(bytes: bytes, etag: etag);
  }

  @override
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  }) async {
    final write = _FakeBlobWrite(
      containerName: containerName,
      blobName: blobName,
      evidenceBytes: evidenceBytes,
      fakeUri: 'https://fake/$containerName/$blobName',
      fakeEtag: 'etag-${writes.length + 1}',
    );
    writes.add(write);
    return AnchorBlobWriteResult(uri: write.fakeUri, etag: write.fakeEtag);
  }

  @override
  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  }) async {
    final preloaded = _preload[blobName];
    if (preloaded == null) {
      throw AuditAnchorBlobUnavailable('fake: blob $blobName not preloaded');
    }
    return AnchorBlobReadResult(bytes: preloaded.bytes, etag: preloaded.etag);
  }
}

class _FakeBlobWrite {
  _FakeBlobWrite({
    required this.containerName,
    required this.blobName,
    required this.evidenceBytes,
    required this.fakeUri,
    required this.fakeEtag,
  });
  final String containerName;
  final String blobName;
  final List<int> evidenceBytes;
  final String fakeUri;
  final String fakeEtag;
}

class _PreloadedBlob {
  _PreloadedBlob({required this.bytes, required this.etag});
  final List<int> bytes;
  final String etag;
}

// ─── Chain builder ────────────────────────────────────────────────────

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
      occurredAt: DateTime.utc(chainDate.year, chainDate.month, chainDate.day, 8, i),
      actorKind: 'user',
      actorUserId: _userA,
      actorPrincipalId: null,
      targetKind: null,
      targetId: null,
      action: 'session.event.$i',
      payloadText: '{"seq": $i}',
      prevRowHash: prev,
      rowHash: Uint8List(32),
    );
    final canonical = hasher.canonicalPayload(draft);
    final hash = Uint8List.fromList(
      sha256.convert(<int>[...?prev, ...canonical]).bytes,
    );
    rows.add(
      AuditLogRow(
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
      ),
    );
    prev = hash;
  }
  return rows;
}
