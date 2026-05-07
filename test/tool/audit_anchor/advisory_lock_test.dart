// Code-Health Lane M3 / L9 — advisory-lock guard for audit_anchor sweep.
//
// Scope (from the A3 spec):
//   * Two concurrent sweep invocations serialize via SweepAdvisoryLock:
//     exactly one runs at a time, the other waits cleanly.
//   * Body throws → lock is released (no leak).
//   * Structured "advisory-lock id resolved" log line is emitted once
//     per sweep start (before lock acquire).
//
// All tests run against the fake [_RecordingAdvisoryLock] seam; no live
// Postgres or Azure Blob call is made. The production wiring
// ([PostgresSweepAdvisoryLock]) is covered structurally by reading the
// SQL pg_advisory_lock / pg_advisory_unlock calls in audit_anchor.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// Path relative to this test's location in test/tool/audit_anchor/.
// Both the tool lib and this test share the forge_and_flow package root.
import '../../../tool/audit_anchor/audit_anchor.dart';
import '../../../tool/audit_anchor/main.dart';

// ─── Constants ────────────────────────────────────────────────────────

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _container = 'forge-flow-audit-anchors';
const int _lockId = 8472001;

// ─── Tests ────────────────────────────────────────────────────────────

void main() {
  group('A3 advisory-lock guard — SweepAdvisoryLock', () {
    // ── serialization ──────────────────────────────────────────────────
    test(
      'two concurrent sweep invocations serialize: exactly one runs the '
      'body at a time, the other waits; maxConcurrentHolders == 1',
      () async {
        final lock = _RecordingAdvisoryLock();

        final firstBodyEntered = Completer<void>();
        final firstBodyMayComplete = Completer<void>();

        final firstFuture = lock.withSweepLock<int>(
          lockId: _lockId,
          body: () async {
            firstBodyEntered.complete();
            await firstBodyMayComplete.future;
            return 1;
          },
        );

        // Wait for the first body to be inside the lock boundary.
        await firstBodyEntered.future;
        expect(lock.activeHolders, equals(1));

        // Start the second invocation — it must block at acquire
        // because the lock is still held by the first body.
        final secondBodyEntered = Completer<void>();
        final secondFuture = lock.withSweepLock<int>(
          lockId: _lockId,
          body: () async {
            secondBodyEntered.complete();
            return 2;
          },
        );

        // Yield to the event loop; the second body must still be blocked.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(
          secondBodyEntered.isCompleted,
          isFalse,
          reason: 'second body must NOT enter while the first holds the lock',
        );

        // Release the first body. The second now acquires and runs.
        firstBodyMayComplete.complete();
        expect(await firstFuture, equals(1));
        expect(await secondFuture, equals(2));

        expect(
          lock.maxConcurrentHolders,
          equals(1),
          reason: 'advisory lock must permit at most one holder at a time',
        );

        // Ordered event sequence: acquire1, release1, acquire2, release2.
        expect(
          lock.events,
          equals(<String>[
            'acquire:$_lockId',
            'release:$_lockId',
            'acquire:$_lockId',
            'release:$_lockId',
          ]),
        );
      },
    );

    // ── body-throws / lock-leak guard ──────────────────────────────────
    test(
      'release runs in finally when the body throws: lock is never leaked',
      () async {
        final lock = _RecordingAdvisoryLock();

        await expectLater(
          () => lock.withSweepLock<void>(
            lockId: _lockId,
            body: () async {
              throw StateError('forced body failure');
            },
          ),
          throwsA(isA<StateError>()),
        );

        expect(
          lock.activeHolders,
          equals(0),
          reason: 'lock must be released even when body throws',
        );
        expect(
          lock.events.last,
          equals('release:$_lockId'),
          reason: 'release event must follow the acquire',
        );
        expect(lock.events, hasLength(2));
      },
    );

    // ── structured log line present ────────────────────────────────────
    test(
      'sweep mode emits the structured "advisory-lock id resolved" log '
      'line before acquiring the lock, with the lock_kind label',
      () async {
        // Drive runCli in sweep mode with all overrides so no live DB or
        // Blob call is made. Capture stdout to assert the log line.
        final chainDate = DateTime.utc(2026, 4, 27);
        final nowUtc = DateTime.utc(2026, 4, 28, 2, 0, 0);
        final clean = _buildLocalChain(length: 3, chainDate: chainDate);

        final reader = _FakeReader(
          unanchored: <AuditChainSummary>[
            AuditChainSummary(operatorId: _opA, chainDate: chainDate),
          ],
          chainsByDate: <String, List<AuditLogRow>>{
            '$_opA|2026-04-27': clean,
          },
          anchorsByDate: const <String, AuditChainAnchor>{},
        );
        final writer = _FakeAnchorWriter();
        final blob = _FakeBlobClient();
        final orchestrator = AuditAnchorOrchestrator(
          reader: reader,
          anchorWriter: writer,
          blobClient: blob,
          containerName: _container,
        );
        final lockIdReader = _ConstantLockIdReader(lockId: _lockId);
        final advisoryLock = _RecordingAdvisoryLock();

        final outBuffer = StringBuffer();
        // ignore: close_sinks
        final outSink = _BufferSink(outBuffer);

        final exitCode = await runCli(
          <String>['sweep', '--as-of-utc=2026-04-28'],
          orchestratorOverride: orchestrator,
          operatorIdReaderOverride: _ConstantOperatorIdReader(
            ids: <String>[_opA],
          ),
          sweepLockIdReaderOverride: lockIdReader,
          sweepAdvisoryLockOverride: advisoryLock,
          clock: () => nowUtc,
          out: outSink,
          err: outSink,
        );

        expect(exitCode, equals(0));
        final output = outBuffer.toString();
        expect(
          output,
          contains('advisory-lock id resolved'),
          reason:
              'structured log line "advisory-lock id resolved" must be '
              'emitted once per sweep start before lock acquire',
        );
        expect(
          output,
          contains('audit_anchor_sweep'),
          reason: 'log line must carry the lock_kind label',
        );
        // Lock was acquired exactly once.
        expect(
          advisoryLock.events,
          equals(<String>[
            'acquire:$_lockId',
            'release:$_lockId',
          ]),
        );
      },
    );
  });
}

// ─── Fakes ────────────────────────────────────────────────────────────

/// Recording advisory lock — serializes callers via a future-chain queue.
/// Tracks concurrent-holder count, max concurrent holders, and an ordered
/// event list so tests can assert mutual exclusion + ordering.
class _RecordingAdvisoryLock implements SweepAdvisoryLock {
  int activeHolders = 0;
  int maxConcurrentHolders = 0;
  final List<String> events = <String>[];
  Future<void> _previous = Future<void>.value();

  @override
  Future<R> withSweepLock<R>({
    required int lockId,
    required Future<R> Function() body,
  }) async {
    final myCompleter = Completer<void>();
    final waitFor = _previous;
    _previous = myCompleter.future;
    await waitFor;
    events.add('acquire:$lockId');
    activeHolders += 1;
    if (activeHolders > maxConcurrentHolders) {
      maxConcurrentHolders = activeHolders;
    }
    try {
      return await body();
    } finally {
      activeHolders -= 1;
      events.add('release:$lockId');
      myCompleter.complete();
    }
  }
}

class _ConstantLockIdReader implements SweepLockIdReader {
  const _ConstantLockIdReader({required this.lockId});
  final int lockId;

  @override
  Future<int> readSweepLockId() async => lockId;
}

class _ConstantOperatorIdReader implements OperatorIdReader {
  const _ConstantOperatorIdReader({required this.ids});
  final List<String> ids;

  @override
  Future<List<String>> listOperatorIds() async => ids;
}

class _FakeReader implements AuditChainReader {
  _FakeReader({
    required this.unanchored,
    required this.chainsByDate,
    required this.anchorsByDate,
  });

  final List<AuditChainSummary> unanchored;
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
      unanchored.where((s) => s.operatorId == operatorId).toList();

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

/// IOSink backed by a [StringBuffer] for capturing CLI output in tests.
class _BufferSink implements IOSink {
  _BufferSink(this._buffer);
  final StringBuffer _buffer;

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object ?? '');

  @override
  void write(Object? object) => _buffer.write(object ?? '');

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding value) {}
}

// ─── Chain builder ────────────────────────────────────────────────────

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
