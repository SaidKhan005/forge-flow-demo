// Lane C C-2-D — VendorSyncOutageDetector tests.
//
// Drives the detector against an in-memory fake repository + a
// recording enqueue seam to assert the state-machine cases:
//
//   * No outage (poll_success after poll_success).
//   * Fresh streak below threshold → state row recorded, no email.
//   * Fresh streak crosses threshold → email enqueued + notified_at
//     stamped.
//   * Existing notified outage + another failure → no duplicate email
//     (load-bearing idempotency).
//   * Outage recovers (poll_success) → state row cleared.
//   * Second outage AFTER recovery → fresh notified_at + new email.
//   * Threshold + lookback edge cases (stale failures don't count,
//     non-failure / non-success rows are ignored).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/vendor_sync/vendor_sync_outage_detector.dart';

void main() {
  group('VendorSyncOutageDetector.observe', () {
    test('poll_success with no prior state is a no-op', () async {
      final repository = _FakeRepository();
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 0),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_success',
      );

      expect(outcome.action, OutageDetectionAction.noOp);
      expect(enqueue.calls, isEmpty);
      expect(repository.upserts, isEmpty);
      expect(repository.clears, isEmpty);
    });

    test(
        'poll_error below threshold records state but does NOT enqueue email',
        () async {
      final repository = _FakeRepository()
        ..seedLogEntries('conn-1', <SyncLogEntry>[
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 55),
            errorMessage: 'OAuth refresh token rejected',
          ),
          SyncLogEntry(
            eventKind: 'poll_success',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 50),
          ),
        ]);
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 0),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_error',
      );

      expect(outcome.action, OutageDetectionAction.recordedFailure);
      expect(outcome.consecutiveFailureCount, 1);
      expect(enqueue.calls, isEmpty);
      expect(repository.upserts, hasLength(1));
      expect(repository.upserts.single.notifiedAt, isNull);
      expect(
        repository.upserts.single.lastErrorMessage,
        'OAuth refresh token rejected',
      );
    });

    test(
        'streak crosses threshold → email enqueued + notified_at stamped',
        () async {
      final repository = _FakeRepository()
        ..seedLogEntries('conn-1', <SyncLogEntry>[
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 58),
            errorMessage: 'vendor returned 500',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 55),
            errorMessage: 'vendor returned 500',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 50),
            errorMessage: 'vendor returned 500',
          ),
        ]);
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 0),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_error',
      );

      expect(outcome.action, OutageDetectionAction.enqueuedEmail);
      expect(outcome.consecutiveFailureCount, 3);
      expect(outcome.outageStartedAt, DateTime.utc(2026, 5, 13, 9, 50));
      expect(enqueue.calls, hasLength(1));
      final call = enqueue.calls.single;
      expect(call.operatorId, 'op-1');
      expect(call.connectionId, 'conn-1');
      expect(call.outageStartedAt, DateTime.utc(2026, 5, 13, 9, 50));
      expect(call.errorSummary, 'vendor returned 500');
      expect(repository.upserts, hasLength(1));
      expect(repository.upserts.single.notifiedAt, isNotNull);
    });

    test('repeated failure after notification does NOT enqueue another email',
        () async {
      final repository = _FakeRepository()
        ..seedLogEntries('conn-1', <SyncLogEntry>[
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 5),
            errorMessage: 'still failing',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 0),
            errorMessage: 'still failing',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 55),
            errorMessage: 'first failure',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 50),
            errorMessage: 'first failure',
          ),
        ])
        ..seedExistingState(
          'conn-1',
          VendorSyncOutageStateRow(
            outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
            consecutiveFailureCount: 3,
            notifiedAt: DateTime.utc(2026, 5, 13, 9, 58),
            lastErrorMessage: 'first failure',
          ),
        );
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 10),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_error',
      );

      expect(outcome.action, OutageDetectionAction.alreadyNotified);
      expect(outcome.consecutiveFailureCount, 4);
      expect(enqueue.calls, isEmpty);
      // State row keeps the original notified_at — defence in depth so
      // an extra "is this row notified?" check elsewhere is correct.
      expect(repository.upserts, hasLength(1));
      expect(
        repository.upserts.single.notifiedAt,
        DateTime.utc(2026, 5, 13, 9, 58),
      );
      // Outage_started_at stays sticky to the oldest streak member.
      expect(
        repository.upserts.single.outageStartedAt,
        DateTime.utc(2026, 5, 13, 9, 50),
      );
    });

    test('poll_success after an outage clears the state row', () async {
      final repository = _FakeRepository()
        ..seedExistingState(
          'conn-1',
          VendorSyncOutageStateRow(
            outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
            consecutiveFailureCount: 4,
            notifiedAt: DateTime.utc(2026, 5, 13, 9, 58),
            lastErrorMessage: 'vendor 500',
          ),
        );
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 15),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_success',
      );

      expect(outcome.action, OutageDetectionAction.clearedRecovery);
      expect(enqueue.calls, isEmpty);
      expect(repository.clears, hasLength(1));
      expect(repository.upserts, isEmpty);
    });

    test('fresh outage AFTER a recovered one fires a new email', () async {
      // Sequence:
      //   tick 1: poll_success (no state)
      //   tick 2-4: 3x poll_error (email fires, state stamped)
      //   tick 5: poll_success (clears state)
      //   tick 6-8: 3x poll_error (NEW email fires, fresh state)
      //
      // Test focuses on the tick-8 observation: log table has the
      // newest 3 errors PLUS the prior success, repository has NO
      // state row (cleared at tick 5).
      final repository = _FakeRepository()
        ..seedLogEntries('conn-1', <SyncLogEntry>[
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 30),
            errorMessage: 'second outage error',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 25),
            errorMessage: 'second outage error',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 20),
            errorMessage: 'second outage error',
          ),
          SyncLogEntry(
            eventKind: 'poll_success',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 15),
          ),
        ]);
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 30),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_error',
      );

      expect(outcome.action, OutageDetectionAction.enqueuedEmail);
      expect(outcome.consecutiveFailureCount, 3);
      expect(outcome.outageStartedAt, DateTime.utc(2026, 5, 13, 10, 20));
      expect(enqueue.calls, hasLength(1));
      // Fresh outage_started_at — not the prior outage's stamp.
      expect(
        enqueue.calls.single.outageStartedAt,
        DateTime.utc(2026, 5, 13, 10, 20),
      );
    });

    test('non-failure / non-success rows do not affect the streak', () async {
      // Tick stream has a `sanity_drop` interleaved between failures.
      // The detector should ignore it: 3 failures still count as a
      // 3-streak.
      final repository = _FakeRepository()
        ..seedLogEntries('conn-1', <SyncLogEntry>[
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 0),
            errorMessage: 'rate limited',
          ),
          SyncLogEntry(
            eventKind: 'sanity_drop',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 58),
            errorMessage: 'future-dated event',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 55),
            errorMessage: 'rate limited',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 50),
            errorMessage: 'rate limited',
          ),
        ]);
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 0),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_error',
      );

      expect(outcome.action, OutageDetectionAction.enqueuedEmail);
      expect(outcome.consecutiveFailureCount, 3);
      expect(enqueue.calls, hasLength(1));
    });

    test('auth_refresh_failed counts as a failure', () async {
      final repository = _FakeRepository()
        ..seedLogEntries('conn-1', <SyncLogEntry>[
          SyncLogEntry(
            eventKind: 'auth_refresh_failed',
            occurredAt: DateTime.utc(2026, 5, 13, 10, 0),
            errorMessage: 'invalid_grant',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 55),
            errorMessage: 'token expired',
          ),
          SyncLogEntry(
            eventKind: 'poll_error',
            occurredAt: DateTime.utc(2026, 5, 13, 9, 50),
            errorMessage: 'token expired',
          ),
        ]);
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 0),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'auth_refresh_failed',
      );

      expect(outcome.action, OutageDetectionAction.enqueuedEmail);
      expect(outcome.consecutiveFailureCount, 3);
      expect(enqueue.calls.single.errorSummary, 'invalid_grant');
    });

    test('custom threshold can be raised', () async {
      // Operator may tune the threshold up to 5; ensure 4 failures do
      // NOT fire when threshold is 5.
      final repository = _FakeRepository()
        ..seedLogEntries('conn-1', <SyncLogEntry>[
          for (var i = 0; i < 4; i++)
            SyncLogEntry(
              eventKind: 'poll_error',
              occurredAt: DateTime.utc(2026, 5, 13, 10, -5 * i),
              errorMessage: 'vendor 500',
            ),
        ]);
      final enqueue = _RecordingEnqueueSeam();
      final detector = VendorSyncOutageDetector(
        repository: repository,
        enqueueAlert: enqueue.call,
        failureThreshold: 5,
        now: () => DateTime.utc(2026, 5, 13, 10, 0),
      );

      final outcome = await detector.observe(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        latestEventKind: 'poll_error',
      );

      expect(outcome.action, OutageDetectionAction.recordedFailure);
      expect(outcome.consecutiveFailureCount, 4);
      expect(enqueue.calls, isEmpty);
    });
  });

  group('VendorSyncOutageDetector construction', () {
    test('throws when failureThreshold is non-positive', () {
      expect(
        () => VendorSyncOutageDetector(
          repository: _FakeRepository(),
          enqueueAlert: _RecordingEnqueueSeam().call,
          failureThreshold: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('throws when lookbackEntryLimit < failureThreshold', () {
      expect(
        () => VendorSyncOutageDetector(
          repository: _FakeRepository(),
          enqueueAlert: _RecordingEnqueueSeam().call,
          failureThreshold: 5,
          lookbackEntryLimit: 3,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

// ─── In-memory fakes ───────────────────────────────────────────────

class _FakeRepository implements VendorSyncOutageStateRepository {
  final Map<String, List<SyncLogEntry>> _logEntries =
      <String, List<SyncLogEntry>>{};
  final Map<String, VendorSyncOutageStateRow> _state =
      <String, VendorSyncOutageStateRow>{};

  final List<_UpsertCall> upserts = <_UpsertCall>[];
  final List<String> clears = <String>[];

  void seedLogEntries(
    String connectionId,
    List<SyncLogEntry> entries,
  ) {
    _logEntries[connectionId] = entries;
  }

  void seedExistingState(
    String connectionId,
    VendorSyncOutageStateRow row,
  ) {
    _state[connectionId] = row;
  }

  @override
  Future<List<SyncLogEntry>> fetchRecentSyncLogEntries({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required Duration lookback,
    required int limit,
  }) async {
    final all = _logEntries[connectionId] ?? const <SyncLogEntry>[];
    return all.take(limit).toList(growable: false);
  }

  @override
  Future<VendorSyncOutageStateRow?> fetchForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    return _state[connectionId];
  }

  @override
  Future<void> upsert({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required DateTime outageStartedAt,
    required int consecutiveFailureCount,
    DateTime? notifiedAt,
    String? lastErrorMessage,
  }) async {
    upserts.add(_UpsertCall(
      connectionId: connectionId,
      outageStartedAt: outageStartedAt,
      consecutiveFailureCount: consecutiveFailureCount,
      notifiedAt: notifiedAt,
      lastErrorMessage: lastErrorMessage,
    ));
    _state[connectionId] = VendorSyncOutageStateRow(
      outageStartedAt: outageStartedAt,
      consecutiveFailureCount: consecutiveFailureCount,
      notifiedAt: notifiedAt,
      lastErrorMessage: lastErrorMessage,
    );
  }

  @override
  Future<void> clearForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    clears.add(connectionId);
    _state.remove(connectionId);
  }
}

class _UpsertCall {
  _UpsertCall({
    required this.connectionId,
    required this.outageStartedAt,
    required this.consecutiveFailureCount,
    this.notifiedAt,
    this.lastErrorMessage,
  });

  final String connectionId;
  final DateTime outageStartedAt;
  final int consecutiveFailureCount;
  final DateTime? notifiedAt;
  final String? lastErrorMessage;
}

class _RecordingEnqueueSeam {
  final List<_EnqueueCall> calls = <_EnqueueCall>[];

  Future<void> call({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required DateTime outageStartedAt,
    required String? errorSummary,
  }) async {
    calls.add(_EnqueueCall(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      outageStartedAt: outageStartedAt,
      errorSummary: errorSummary,
    ));
  }
}

class _EnqueueCall {
  _EnqueueCall({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.outageStartedAt,
    required this.errorSummary,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final DateTime outageStartedAt;
  final String? errorSummary;
}
