// Phase 8 W2.B - audit_anchor onAnchorFailure hook wiring test.
//
// Asserts that audit_anchor's runCli fires the optional
// onAnchorFailure hook on chain-hash-mismatch outcomes and on the
// blob-unavailable / runtime-error error paths. The hook is the
// seam the production binder threads to
// `notification_event_hooks.emitAuditAnchorFailure`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/audit_anchor/audit_anchor.dart';
import '../../../tool/audit_anchor/main.dart' as audit_anchor_main;

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('audit_anchor onAnchorFailure hook', () {
    test(
      'chainHashMismatch fires onAnchorFailure with chain date',
      () async {
        final calls = <_HookCall>[];
        // Build a chain whose row_hash does not match recompute -> the
        // orchestrator emits AnchorOutcome.chainHashMismatch.
        final tamperedRow = _buildLogRow(
          id: BigInt.from(1),
          chainDate: DateTime.utc(2026, 5, 6),
          // intentionally wrong rowHash
          forgeBadHash: true,
        );
        final orchestrator = AuditAnchorOrchestrator(
          reader: _FakeReader(
            unanchored: <AuditChainSummary>[
              AuditChainSummary(
                operatorId: _opA,
                chainDate: DateTime.utc(2026, 5, 6),
              ),
            ],
            chainsByDate: <String, List<AuditLogRow>>{
              '2026-05-06': <AuditLogRow>[tamperedRow],
            },
          ),
          anchorWriter: _FakeAnchorWriter(),
          blobClient: _FakeBlobClient(),
          containerName: 'forge-flow-audit-anchors',
        );

        // ignore: close_sinks
        final out = _StringSink();
        // ignore: close_sinks
        final err = _StringSink();
        final code = await audit_anchor_main.runCli(
          <String>[
            'anchor',
            '--operator-id=$_opA',
            '--as-of-utc=2026-05-07',
          ],
          orchestratorOverride: orchestrator,
          shutdownSignals: audit_anchor_main.ShutdownSignals.test(),
          onAnchorFailure: ({
            required String operatorId,
            required String chainDateIso,
            required String reason,
          }) async {
            calls.add(_HookCall(
              operatorId: operatorId,
              chainDateIso: chainDateIso,
              reason: reason,
            ));
          },
          out: out,
          err: err,
        );

        // Exit 1 because we surfaced a chain hash mismatch.
        expect(code, 1);
        expect(calls, hasLength(1));
        expect(calls.single.operatorId, _opA);
        expect(calls.single.chainDateIso, '2026-05-06');
        expect(calls.single.reason, contains('chain_hash_mismatch'));
      },
    );

    test('verify chainHashMismatch fires onAnchorFailure', () async {
      final calls = <_HookCall>[];
      final tampered = _buildLogRow(
        id: BigInt.from(1),
        chainDate: DateTime.utc(2026, 5, 6),
        forgeBadHash: true,
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: _FakeReader(
          unanchored: const <AuditChainSummary>[],
          chainsByDate: <String, List<AuditLogRow>>{
            '2026-05-06': <AuditLogRow>[tampered],
          },
        ),
        anchorWriter: _FakeAnchorWriter(),
        blobClient: _FakeBlobClient(),
        containerName: 'forge-flow-audit-anchors',
      );

      // ignore: close_sinks
      final out = _StringSink();
      // ignore: close_sinks
      final err = _StringSink();
      final code = await audit_anchor_main.runCli(
        <String>[
          'verify',
          '--operator-id=$_opA',
          '--chain-date=2026-05-06',
        ],
        orchestratorOverride: orchestrator,
        shutdownSignals: audit_anchor_main.ShutdownSignals.test(),
        onAnchorFailure: ({
          required String operatorId,
          required String chainDateIso,
          required String reason,
        }) async {
          calls.add(_HookCall(
            operatorId: operatorId,
            chainDateIso: chainDateIso,
            reason: reason,
          ));
        },
        out: out,
        err: err,
      );
      expect(code, 1);
      expect(calls, hasLength(1));
      expect(calls.single.reason, contains('verify_chainHashMismatch'));
    });
  });
}

class _HookCall {
  _HookCall({
    required this.operatorId,
    required this.chainDateIso,
    required this.reason,
  });
  final String operatorId;
  final String chainDateIso;
  final String reason;
}

AuditLogRow _buildLogRow({
  required BigInt id,
  required DateTime chainDate,
  bool forgeBadHash = false,
}) {
  final hasher = const AuditChainHasher();
  final row = AuditLogRow(
    id: id,
    operatorId: _opA,
    locationId: null,
    chainDate: chainDate,
    occurredAt: DateTime.utc(2026, 5, 6, 10),
    actorKind: 'service',
    actorUserId: null,
    actorPrincipalId: 'sp:test',
    targetKind: null,
    targetId: null,
    action: 'test',
    payloadText: '{"k":"v"}',
    prevRowHash: null,
    rowHash: forgeBadHash
        ? Uint8List.fromList(List.filled(32, 0xff))
        : Uint8List(32),
  );
  if (forgeBadHash) return row;
  // Real hash for non-forged path.
  final correctHash = hasher.recomputeRowHash(row);
  return AuditLogRow(
    id: row.id,
    operatorId: row.operatorId,
    locationId: row.locationId,
    chainDate: row.chainDate,
    occurredAt: row.occurredAt,
    actorKind: row.actorKind,
    actorUserId: row.actorUserId,
    actorPrincipalId: row.actorPrincipalId,
    targetKind: row.targetKind,
    targetId: row.targetId,
    action: row.action,
    payloadText: row.payloadText,
    prevRowHash: row.prevRowHash,
    rowHash: correctHash,
  );
}

// Minimal fakes -- mirror the shapes used in
// `test/phase_9_0sigma_f_audit_logs_test.dart` but keep the surface
// tight to what this test exercises.

class _FakeReader implements AuditChainReader {
  _FakeReader({
    required this.unanchored,
    required this.chainsByDate,
    Map<String, AuditChainAnchor>? anchorsByDate,
  }) : anchorsByDate = anchorsByDate ?? const <String, AuditChainAnchor>{};

  final List<AuditChainSummary> unanchored;
  final Map<String, List<AuditLogRow>> chainsByDate;
  final Map<String, AuditChainAnchor> anchorsByDate;

  @override
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  }) async => unanchored;

  @override
  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  }) async {
    final key =
        '${chainDate.year.toString().padLeft(4, '0')}-'
        '${chainDate.month.toString().padLeft(2, '0')}-'
        '${chainDate.day.toString().padLeft(2, '0')}';
    return chainsByDate[key] ?? const <AuditLogRow>[];
  }

  @override
  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  }) async {
    final key =
        '${chainDate.year.toString().padLeft(4, '0')}-'
        '${chainDate.month.toString().padLeft(2, '0')}-'
        '${chainDate.day.toString().padLeft(2, '0')}';
    return anchorsByDate[key];
  }
}

class _FakeAnchorWriter implements AuditChainAnchorWriter {
  final List<AuditChainAnchor> writes = <AuditChainAnchor>[];

  @override
  Future<void> insertAnchor(AuditChainAnchor anchor) async {
    writes.add(anchor);
  }
}

class _FakeBlobClient implements AuditAnchorBlobClient {
  @override
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  }) async {
    return AnchorBlobWriteResult(
      uri: '$containerName/$blobName',
      etag: '"etag-${sha256.convert(evidenceBytes).bytes.length}"',
    );
  }

  @override
  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  }) async {
    throw const AuditAnchorBlobUnavailable('not preloaded');
  }
}

class _StringSink implements IOSink {
  final StringBuffer _b = StringBuffer();

  @override
  void writeln([Object? obj = '']) => _b.writeln(obj);

  @override
  String toString() => _b.toString();

  @override
  void write(Object? obj) => _b.write(obj);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _b.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _b.writeCharCode(charCode);

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();

  @override
  Encoding get encoding => systemEncoding;

  @override
  set encoding(Encoding _) {}

  @override
  Future<void> flush() async {}
}
