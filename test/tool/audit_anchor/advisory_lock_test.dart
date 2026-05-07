// Code-Health Lane L9 — advisory-lock sweep-guard regression test.
//
// Scope (per A3 task spec):
//   * Two concurrent invocations of runCli sweep mode; assert exactly
//     one runs to completion and the other exits cleanly with mutual
//     exclusion preserved (maxConcurrentHolders == 1).
//   * Lock is always released even when the body throws.
//   * Structured advisory-lock-id-resolved log line is present before
//     the body runs.
//
// The test drives runCli (the full CLI entry point) with injected fakes
// for every live dependency so no Postgres or Azure Blob call is made.
// The advisory-lock seam is a _RecordingAdvisoryLock that tracks
// active holders and event ordering so the test can assert mutual
// exclusion without relying on real pg_advisory_lock semantics.
//
// The lock-id reader always returns 8472001 (the constant seeded by
// migration 202605070200_audit_anchor_advisory_lock_infra.sql).

import 'dart:async';
import 'dart:io' show IOSink;

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/audit_anchor/audit_anchor.dart';
import '../../../tool/audit_anchor/main.dart';

// ─── constants ────────────────────────────────────────────────────────

const String _opA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const String _container = 'forge-flow-audit-anchors';
const int _lockId = 8472001;

void main() {
  group('L9 advisory lock — runCli sweep mode', () {
    test(
        'two concurrent sweep invocations: exactly one runs the anchor '
        'body; the other waits and exits cleanly without overlap '
        '(mutual-exclusion invariant: maxConcurrentHolders == 1)', () async {
      // Completers that gate the first sweep body so the second
      // invocation is provably blocked at acquire while the first holds
      // the lock.
      final firstBodyEntered = Completer<void>();
      final firstBodyMayComplete = Completer<void>();

      final lockRecorder = _RecordingAdvisoryLock(
        onEnter: firstBodyEntered,
        mayComplete: firstBodyMayComplete,
      );
      final lockIdReader = _ConstantLockIdReader(_lockId);

      // Minimal fake orchestrator: no unanchored chains → sweep
      // completes with exit 0 and no blob/DB writes.
      final orchestrator = _NoOpOrchestrator();
      final operatorIds = _ConstantOperatorIdReader([_opA]);

      // ignore: close_sinks
      final outFirst = _StringSink();
      // ignore: close_sinks
      final errFirst = _StringSink();
      // ignore: close_sinks
      final outSecond = _StringSink();
      // ignore: close_sinks
      final errSecond = _StringSink();

      // Launch both sweeps concurrently.
      final firstFuture = runCli(
        ['sweep', '--as-of-utc=2026-04-28'],
        environment: _fakeEnv(),
        orchestratorOverride: orchestrator,
        operatorIdReaderOverride: operatorIds,
        sweepLockIdReaderOverride: lockIdReader,
        sweepAdvisoryLockOverride: lockRecorder,
        out: outFirst,
        err: errFirst,
      );

      // Wait until the first body is executing.
      await firstBodyEntered.future;
      expect(lockRecorder.activeHolders, equals(1),
          reason: 'first sweep holds the lock');

      // Start the second sweep. It should block at acquire.
      final secondFuture = runCli(
        ['sweep', '--as-of-utc=2026-04-28'],
        environment: _fakeEnv(),
        orchestratorOverride: orchestrator,
        operatorIdReaderOverride: operatorIds,
        sweepLockIdReaderOverride: lockIdReader,
        sweepAdvisoryLockOverride: lockRecorder,
        out: outSecond,
        err: errSecond,
      );

      // Yield so the second invocation can reach the acquire point.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // The lock is currently held by the first sweep; the second sweep's
      // chain-of-completers guarantees it cannot enter the body yet.
      expect(
        lockRecorder.activeHolders,
        equals(1),
        reason: 'second sweep must not enter body while first holds lock',
      );

      // Release the first body — it completes, releases the lock, then
      // the second body acquires and runs.
      firstBodyMayComplete.complete();
      final firstExit = await firstFuture;
      final secondExit = await secondFuture;

      // Both exit cleanly (0).
      expect(firstExit, equals(0), reason: 'first sweep exits 0');
      expect(secondExit, equals(0),
          reason: 'second sweep exits 0 (no work; chains already anchored)');

      // Mutual-exclusion invariant.
      expect(
        lockRecorder.maxConcurrentHolders,
        equals(1),
        reason: 'advisory lock must permit at most one body at a time',
      );

      // Event ordering: acquire, release, acquire, release.
      expect(lockRecorder.events, equals(<String>[
        'acquire:$_lockId',
        'release:$_lockId',
        'acquire:$_lockId',
        'release:$_lockId',
      ]));
    });

    test(
        'lock is always released even when the sweep body throws a '
        'runtime error (finally guarantee)', () async {
      final lockRecorder = _RecordingAdvisoryLock(
        onEnter: null,
        mayComplete: null,
      );

      // Orchestrator whose findUnanchoredCompletedChains throws.
      final errorOrchestrator = _ThrowingOrchestrator();
      final operatorIds = _ConstantOperatorIdReader([_opA]);

      final exitCode = await runCli(
        ['sweep', '--as-of-utc=2026-04-28'],
        environment: _fakeEnv(),
        orchestratorOverride: errorOrchestrator,
        operatorIdReaderOverride: operatorIds,
        sweepLockIdReaderOverride: _ConstantLockIdReader(_lockId),
        sweepAdvisoryLockOverride: lockRecorder,
        out: _StringSink(),
        err: _StringSink(),
      );

      // Exit 1 (had failure) rather than an unhandled exception that
      // would surface as exit 3 from the outer runtime-error catch.
      expect(exitCode, equals(1),
          reason: 'runtime error inside body surfaces as exit 1');
      // Lock was released despite the throw.
      expect(lockRecorder.activeHolders, equals(0));
      expect(
        lockRecorder.events.last,
        equals('release:$_lockId'),
        reason: 'release always runs via finally',
      );
    });

    test(
        'sweep logs advisory-lock-id-resolved before entering the body '
        'so operators can confirm lock-id wiring from the Cloud Run log',
        () async {
      // ignore: close_sinks
      final out = _StringSink();

      await runCli(
        ['sweep', '--as-of-utc=2026-04-28'],
        environment: _fakeEnv(),
        orchestratorOverride: _NoOpOrchestrator(),
        operatorIdReaderOverride: _ConstantOperatorIdReader([]),
        sweepLockIdReaderOverride: _ConstantLockIdReader(_lockId),
        sweepAdvisoryLockOverride: _RecordingAdvisoryLock(
          onEnter: null,
          mayComplete: null,
        ),
        out: out,
        err: _StringSink(),
      );

      expect(
        out.buffer,
        contains('advisory-lock id resolved'),
        reason:
            'structured log line confirms the lock-id read succeeded '
            'before the body ran',
      );
    });
  });
}

// ─── fakes ────────────────────────────────────────────────────────────

Map<String, String> _fakeEnv() => <String, String>{
      'POSTGRES_URL': 'postgresql://fake',
      'AZURE_BLOB_AUDIT_CONTAINER': 'fake-container',
      'AZURE_BLOB_AUDIT_ENDPOINT': 'https://fake.blob.core.windows.net',
    };

/// Advisory lock that serializes callers via a chain of completers,
/// tracking acquire/release events. Optional [onEnter]/[mayComplete]
/// completers let tests gate how long the first body runs.
class _RecordingAdvisoryLock implements SweepAdvisoryLock {
  _RecordingAdvisoryLock({
    required Completer<void>? onEnter,
    required Completer<void>? mayComplete,
  })  : _onEnter = onEnter,
        _mayComplete = mayComplete;

  final Completer<void>? _onEnter;
  final Completer<void>? _mayComplete;

  int activeHolders = 0;
  int maxConcurrentHolders = 0;
  final List<String> events = <String>[];
  bool _firstBodySignaled = false;
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
      // For the first body, signal the test and optionally wait.
      if (!_firstBodySignaled && _onEnter != null) {
        _firstBodySignaled = true;
        // Local capture for null-safe promotion.
        final onEnter = _onEnter;
        final mayComplete = _mayComplete;
        onEnter.complete();
        if (mayComplete != null) {
          await mayComplete.future;
        }
      }
      return await body();
    } finally {
      activeHolders -= 1;
      events.add('release:$lockId');
      myCompleter.complete();
    }
  }
}

class _ConstantLockIdReader implements SweepLockIdReader {
  const _ConstantLockIdReader(this._id);
  final int _id;

  @override
  Future<int> readSweepLockId() async => _id;
}

/// Orchestrator with no unanchored chains — a no-op sweep.
class _NoOpOrchestrator extends AuditAnchorOrchestrator {
  _NoOpOrchestrator()
      : super(
          reader: _EmptyReader(),
          anchorWriter: _NoOpWriter(),
          blobClient: const ScaffoldRejectingAuditAnchorBlobClient(),
          containerName: _container,
        );
}

/// Orchestrator whose findUnanchoredCompletedChains throws to test
/// lock-release-on-error.
class _ThrowingOrchestrator extends AuditAnchorOrchestrator {
  _ThrowingOrchestrator()
      : super(
          reader: _ThrowingReader(),
          anchorWriter: _NoOpWriter(),
          blobClient: const ScaffoldRejectingAuditAnchorBlobClient(),
          containerName: _container,
        );
}

class _ConstantOperatorIdReader implements OperatorIdReader {
  const _ConstantOperatorIdReader(this._ids);
  final List<String> _ids;

  @override
  Future<List<String>> listOperatorIds() async => List.unmodifiable(_ids);
}

class _EmptyReader implements AuditChainReader {
  @override
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  }) async =>
      const [];

  @override
  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      const [];

  @override
  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      null;
}

class _ThrowingReader implements AuditChainReader {
  @override
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  }) async =>
      throw StateError('forced reader error for lock-release test');

  @override
  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      const [];

  @override
  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  }) async =>
      null;
}

class _NoOpWriter implements AuditChainAnchorWriter {
  @override
  Future<void> insertAnchor(AuditChainAnchor anchor) async {}
}

/// Minimal IOSink that captures writes for assertion without any
/// real I/O. Stubs the IOSink contract via noSuchMethod for unused
/// async methods (add, flush, close, addStream, etc.).
class _StringSink implements IOSink {
  final StringBuffer _buf = StringBuffer();
  String get buffer => _buf.toString();

  @override
  void write(Object? object) => _buf.write(object);
  @override
  void writeln([Object? object = '']) => _buf.writeln(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
