// Wave 2 Q-1-FU — heap_snapshot_capture_routes proxy tests.
//
// Pins the contract for:
//
//   POST /v1/admin/heap-snapshot/capture
//
// Covers:
//   * Happy path: small fake snapshot (1 KiB), correct headers, fake
//     Azure upload target returns success → 200 + blob_url surfaced.
//   * Idempotency replay: same key → same response without a second
//     upload call.
//   * Size guard: 51 MiB payload → 413 Payload Too Large.
//   * Permission denial: non-debug-console role → 403.
//   * Missing required header → 400.
//   * Azure write failure → 502 with audit row preserved.
//   * Pod rate-limit warning: 13 successful captures within 1 hour
//     from same pod → warn audit emitted.
//   * matches() returns false on non-POST / wrong path.
//   * Auth resolver returns null → 401.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/heap_snapshot_capture_routes.dart';
import '../../tool/pressure/p4_heap_snapshot_uploader.dart';

void main() {
  group('HeapSnapshotCaptureRouter.matches', () {
    test('matches POST + canonical path', () {
      expect(
        HeapSnapshotCaptureRouter.matches(heapSnapshotCapturePath, 'POST'),
        isTrue,
      );
    });

    test('rejects GET on the same path', () {
      expect(
        HeapSnapshotCaptureRouter.matches(heapSnapshotCapturePath, 'GET'),
        isFalse,
      );
    });

    test('rejects a different POST path', () {
      expect(
        HeapSnapshotCaptureRouter.matches('/v1/something/else', 'POST'),
        isFalse,
      );
    });
  });

  group('HeapSnapshotCaptureRouter.dispatch (pure)', () {
    test('happy path: 1 KiB snapshot → 200 + blob_url + audit row', () async {
      final upload = _RecordingUploadTarget();
      final auditSink = _RecordingAuditSink();
      final rate = HeapSnapshotPodRateTracker(
        clock: () => DateTime.utc(2026, 5, 14, 12),
      );
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: upload,
        auditSink: auditSink,
        maxBytesLoader: () => kHeapSnapshotMaxBytesDefault,
        rateTracker: rate,
        clock: () => DateTime.utc(2026, 5, 14, 12),
      );

      final bytes = List<int>.filled(1024, 0xAB);
      final actor = const HeapSnapshotCaptureActor(
        userId: 'admin-user-1',
        roles: <String>{'super_admin'},
        actorKind: 'user',
      );
      final result = await router.dispatch(
        actor: actor,
        podId: 'pod-A',
        podHostname: 'soak-runner-1.cluster.local',
        snapshotTimestamp: DateTime.utc(2026, 5, 14, 12),
        idempotencyKey: 'key-1',
        bytes: bytes,
        advisorySnapshotBytes: 1024,
      );

      expect(result.statusCode, 200);
      expect(result.body['pod_id'], 'pod-A');
      expect(result.body['snapshot_bytes'], 1024);
      expect(result.body['blob_url'], isNotNull);
      expect(upload.uploads.length, 1);
      expect(upload.uploads.single.podId, 'pod-A');
      expect(upload.uploads.single.bytes.length, 1024);
      expect(auditSink.records.length, 1);
      expect(
        auditSink.records.single.eventKind,
        'admin.heap_snapshot_captured',
      );
      expect(auditSink.records.single.payload['outcome'], 'ok');
      expect(auditSink.records.single.payload['pod_id'], 'pod-A');
      expect(
        auditSink.records.single.payload['pod_hostname'],
        'soak-runner-1.cluster.local',
      );
      expect(auditSink.records.single.payload['snapshot_bytes'], 1024);
    });

    test('idempotency replay: same key returns cached response', () async {
      final upload = _RecordingUploadTarget();
      final auditSink = _RecordingAuditSink();
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: upload,
        auditSink: auditSink,
        rateTracker:
            HeapSnapshotPodRateTracker(clock: () => DateTime.utc(2026, 5, 14)),
        clock: () => DateTime.utc(2026, 5, 14),
      );
      final actor = const HeapSnapshotCaptureActor(
        userId: 'admin-user-1',
        roles: <String>{'super_admin'},
        actorKind: 'user',
      );
      final bytes = List<int>.filled(64, 0x01);
      final first = await router.dispatch(
        actor: actor,
        podId: 'pod-A',
        podHostname: 'host-1',
        snapshotTimestamp: DateTime.utc(2026, 5, 14),
        idempotencyKey: 'key-rep',
        bytes: bytes,
      );
      expect(first.statusCode, 200);
      expect(upload.uploads.length, 1);
      expect(auditSink.records.length, 1);

      final replay = await router.dispatch(
        actor: actor,
        podId: 'pod-A',
        podHostname: 'host-1',
        snapshotTimestamp: DateTime.utc(2026, 5, 14),
        idempotencyKey: 'key-rep',
        bytes: bytes,
      );
      expect(replay.statusCode, 200);
      expect(replay.body['blob_url'], first.body['blob_url']);
      // The replay MUST NOT re-upload nor re-audit.
      expect(upload.uploads.length, 1);
      expect(auditSink.records.length, 1);
    });

    test('Azure write failure → 502 + audit row preserved', () async {
      final upload = _RecordingUploadTarget(
        failNext: const HttpException('boom'),
      );
      final auditSink = _RecordingAuditSink();
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: upload,
        auditSink: auditSink,
        rateTracker:
            HeapSnapshotPodRateTracker(clock: () => DateTime.utc(2026, 5, 14)),
        clock: () => DateTime.utc(2026, 5, 14),
      );
      final actor = const HeapSnapshotCaptureActor(
        userId: 'admin-user-1',
        roles: <String>{'super_admin'},
        actorKind: 'user',
      );
      final result = await router.dispatch(
        actor: actor,
        podId: 'pod-Z',
        podHostname: 'host-9',
        snapshotTimestamp: DateTime.utc(2026, 5, 14),
        idempotencyKey: 'key-fail',
        bytes: List<int>.filled(512, 0x00),
      );
      expect(result.statusCode, 502);
      expect(result.body['error'], 'azure_blob_write_failed');
      // Audit row records the failure too.
      expect(auditSink.records.length, 1);
      expect(
        auditSink.records.single.eventKind,
        'admin.heap_snapshot_captured',
      );
      expect(auditSink.records.single.payload['outcome'], 'failed');
      expect(
        auditSink.records.single.payload['error_kind'],
        'azure_blob_write_failed',
      );
    });

    test('pod rate warn: 13th capture/hour → warn audit emitted', () async {
      final upload = _RecordingUploadTarget();
      final auditSink = _RecordingAuditSink();
      DateTime fixedClock() => DateTime.utc(2026, 5, 14, 12);
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: upload,
        auditSink: auditSink,
        rateTracker: HeapSnapshotPodRateTracker(clock: fixedClock),
        clock: fixedClock,
      );
      final actor = const HeapSnapshotCaptureActor(
        userId: 'admin-user-1',
        roles: <String>{'super_admin'},
        actorKind: 'user',
      );
      // Drive 13 captures from the same pod within the rolling window.
      for (var i = 0; i < 13; i++) {
        await router.dispatch(
          actor: actor,
          podId: 'pod-RATE',
          podHostname: 'host-rate',
          snapshotTimestamp: DateTime.utc(2026, 5, 14, 12),
          idempotencyKey: 'key-$i',
          bytes: List<int>.filled(16, 0x00),
        );
      }
      // 13 successful capture audit rows + 1 warn-level audit row.
      final captureRows = auditSink.records
          .where((r) => r.eventKind == 'admin.heap_snapshot_captured')
          .toList();
      final warnRows = auditSink.records
          .where((r) => r.eventKind == 'admin.heap_snapshot.pod_rate_high')
          .toList();
      expect(captureRows.length, 13);
      expect(warnRows.length, 1);
      expect(warnRows.single.payload['pod_id'], 'pod-RATE');
      expect(warnRows.single.payload['captures_in_window'], 13);
      expect(
        warnRows.single.payload['threshold'],
        kHeapSnapshotPodCapturesPerHourWarnThreshold,
      );
    });

    test(
      'pod rate warn: 12 captures within window → NO warn emitted',
      () async {
        final upload = _RecordingUploadTarget();
        final auditSink = _RecordingAuditSink();
        DateTime fixedClock() => DateTime.utc(2026, 5, 14, 12);
        final router = HeapSnapshotCaptureRouter(
          uploadTarget: upload,
          auditSink: auditSink,
          rateTracker: HeapSnapshotPodRateTracker(clock: fixedClock),
          clock: fixedClock,
        );
        final actor = const HeapSnapshotCaptureActor(
          userId: 'admin-user-1',
          roles: <String>{'super_admin'},
          actorKind: 'user',
        );
        for (var i = 0; i < 12; i++) {
          await router.dispatch(
            actor: actor,
            podId: 'pod-OK',
            podHostname: 'host-ok',
            snapshotTimestamp: DateTime.utc(2026, 5, 14, 12),
            idempotencyKey: 'key-$i',
            bytes: List<int>.filled(16, 0x00),
          );
        }
        final warnRows = auditSink.records
            .where((r) => r.eventKind == 'admin.heap_snapshot.pod_rate_high')
            .toList();
        expect(warnRows, isEmpty);
      },
    );
  });

  group('HeapSnapshotPodRateTracker', () {
    test('count resets when window expires', () {
      var now = DateTime.utc(2026, 5, 14, 12);
      final tracker = HeapSnapshotPodRateTracker(clock: () => now);
      for (var i = 0; i < 5; i++) {
        tracker.recordAndCount('pod-A');
      }
      expect(tracker.currentCount('pod-A'), 5);
      // Advance past the window.
      now = now.add(const Duration(hours: 2));
      expect(tracker.currentCount('pod-A'), 0);
    });

    test('separate pods do not contaminate each other', () {
      final tracker = HeapSnapshotPodRateTracker(
        clock: () => DateTime.utc(2026, 5, 14, 12),
      );
      for (var i = 0; i < 8; i++) {
        tracker.recordAndCount('pod-A');
      }
      expect(tracker.recordAndCount('pod-B'), 1);
      expect(tracker.currentCount('pod-A'), 8);
    });
  });

  group('HeapSnapshotCaptureRouter.tryHandle (HTTP)', () {
    test('auth resolver returns null → 401', () async {
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: _RecordingUploadTarget(),
        authResolver: (_) async => null,
      );
      final result = await _captureRequest(
        router: router,
        method: 'POST',
        path: heapSnapshotCapturePath,
        headers: const <String, String>{
          'X-Pod-Id': 'pod-A',
          'X-Pod-Hostname': 'host',
          'X-Snapshot-Timestamp': '2026-05-14T12:00:00Z',
          'Idempotency-Key': 'k1',
        },
        body: const <int>[1, 2, 3],
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 401);
      expect(result.bodyJson['error'], 'unauthorized');
    });

    test('non-debug-console role → 403', () async {
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: _RecordingUploadTarget(),
        authResolver: (_) async => const HeapSnapshotCaptureActor(
          userId: 'op-1',
          roles: <String>{'operator_owner'},
          actorKind: 'user',
        ),
      );
      final result = await _captureRequest(
        router: router,
        method: 'POST',
        path: heapSnapshotCapturePath,
        headers: const <String, String>{
          'X-Pod-Id': 'pod-A',
          'X-Pod-Hostname': 'host',
          'X-Snapshot-Timestamp': '2026-05-14T12:00:00Z',
          'Idempotency-Key': 'k1',
        },
        body: const <int>[1, 2, 3],
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 403);
      expect(result.bodyJson['error'], 'permission_denied');
    });

    test('missing X-Pod-Id header → 400', () async {
      final router = _buildBasicRouter();
      final result = await _captureRequest(
        router: router,
        method: 'POST',
        path: heapSnapshotCapturePath,
        headers: const <String, String>{
          'X-Pod-Hostname': 'host',
          'X-Snapshot-Timestamp': '2026-05-14T12:00:00Z',
          'Idempotency-Key': 'k1',
        },
        body: const <int>[1, 2, 3],
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_required_header');
      expect(result.bodyJson['header'], 'x-pod-id');
    });

    test('missing Idempotency-Key → 400', () async {
      final router = _buildBasicRouter();
      final result = await _captureRequest(
        router: router,
        method: 'POST',
        path: heapSnapshotCapturePath,
        headers: const <String, String>{
          'X-Pod-Id': 'pod-A',
          'X-Pod-Hostname': 'host',
          'X-Snapshot-Timestamp': '2026-05-14T12:00:00Z',
        },
        body: const <int>[1, 2, 3],
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'missing_required_header');
      expect(result.bodyJson['header'], 'idempotency-key');
    });

    test('invalid X-Snapshot-Timestamp → 400', () async {
      final router = _buildBasicRouter();
      final result = await _captureRequest(
        router: router,
        method: 'POST',
        path: heapSnapshotCapturePath,
        headers: const <String, String>{
          'X-Pod-Id': 'pod-A',
          'X-Pod-Hostname': 'host',
          'X-Snapshot-Timestamp': 'not-a-date',
          'Idempotency-Key': 'k1',
        },
        body: const <int>[1, 2, 3],
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 400);
      expect(result.bodyJson['error'], 'invalid_snapshot_timestamp');
    });

    test('51 MiB body → 413', () async {
      // Use a deliberately low cap so the test does not allocate 51 MiB.
      const lowCap = 1024; // 1 KiB
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: _RecordingUploadTarget(),
        authResolver: (_) async => const HeapSnapshotCaptureActor(
          userId: 'admin-user-1',
          roles: <String>{'super_admin'},
          actorKind: 'user',
        ),
        maxBytesLoader: () => lowCap,
      );
      final tooLarge = List<int>.filled(lowCap + 1, 0x01);
      final result = await _captureRequest(
        router: router,
        method: 'POST',
        path: heapSnapshotCapturePath,
        headers: const <String, String>{
          'X-Pod-Id': 'pod-A',
          'X-Pod-Hostname': 'host',
          'X-Snapshot-Timestamp': '2026-05-14T12:00:00Z',
          'Idempotency-Key': 'k1',
        },
        body: tooLarge,
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 413);
      expect(result.bodyJson['error'], 'snapshot_too_large');
      expect(result.bodyJson['max_bytes'], lowCap);
    });

    test('happy path over HTTP → 200', () async {
      final upload = _RecordingUploadTarget();
      final auditSink = _RecordingAuditSink();
      final router = HeapSnapshotCaptureRouter(
        uploadTarget: upload,
        authResolver: (_) async => const HeapSnapshotCaptureActor(
          userId: 'admin-user-1',
          roles: <String>{'super_admin'},
          actorKind: 'user',
        ),
        auditSink: auditSink,
        maxBytesLoader: () => kHeapSnapshotMaxBytesDefault,
        rateTracker:
            HeapSnapshotPodRateTracker(clock: () => DateTime.utc(2026, 5, 14)),
        clock: () => DateTime.utc(2026, 5, 14),
      );
      final result = await _captureRequest(
        router: router,
        method: 'POST',
        path: heapSnapshotCapturePath,
        headers: const <String, String>{
          'X-Pod-Id': 'pod-A',
          'X-Pod-Hostname': 'host-1',
          'X-Snapshot-Timestamp': '2026-05-14T12:00:00Z',
          'X-Snapshot-Bytes': '1024',
          'Idempotency-Key': 'http-key',
        },
        body: List<int>.filled(1024, 0xAB),
      );
      expect(result.handled, isTrue);
      expect(result.statusCode, 200);
      expect(result.bodyJson['pod_id'], 'pod-A');
      expect(result.bodyJson['snapshot_bytes'], 1024);
      expect(result.bodyJson['blob_url'], isNotNull);
      expect(upload.uploads.length, 1);
      expect(auditSink.records.length, 1);
    });
  });
}

// ───────────────────────────────────────────────────────────────────
// Test helpers
// ───────────────────────────────────────────────────────────────────

HeapSnapshotCaptureRouter _buildBasicRouter() {
  return HeapSnapshotCaptureRouter(
    uploadTarget: _RecordingUploadTarget(),
    authResolver: (_) async => const HeapSnapshotCaptureActor(
      userId: 'admin-user-1',
      roles: <String>{'super_admin'},
      actorKind: 'user',
    ),
  );
}

class _RecordedUploadCall {
  _RecordedUploadCall({
    required this.bytes,
    required this.contentType,
    required this.timestamp,
    required this.podId,
    required this.runId,
  });

  final List<int> bytes;
  final String contentType;
  final DateTime timestamp;
  final String? podId;
  final String? runId;
}

class _RecordingUploadTarget implements HeapSnapshotUploadTarget {
  _RecordingUploadTarget({this.failNext});

  Object? failNext;
  final List<_RecordedUploadCall> uploads = <_RecordedUploadCall>[];

  @override
  bool get isConfigured => true;

  @override
  String get unconfiguredReason => '';

  @override
  Future<HeapSnapshotUploadResult> upload({
    required List<int> bytes,
    required String contentType,
    required DateTime timestamp,
    String? podId,
    String? runId,
  }) async {
    if (failNext != null) {
      final err = failNext!;
      failNext = null;
      throw err;
    }
    uploads.add(_RecordedUploadCall(
      bytes: bytes,
      contentType: contentType,
      timestamp: timestamp,
      podId: podId,
      runId: runId,
    ));
    final isoStamp =
        timestamp.toUtc().toIso8601String().replaceAll(RegExp(r'[^\w]'), '_');
    final key =
        'heap-snapshots/test/${podId ?? 'unknown'}/heap-$isoStamp.heapsnapshot';
    return HeapSnapshotUploadResult(
      objectKey: key,
      sizeBytes: bytes.length,
      blobUri:
          'https://example.blob.core.windows.net/soak-snapshots/$key',
    );
  }
}

class _RecordedAuditRow {
  _RecordedAuditRow({
    required this.eventKind,
    required this.actorUserId,
    required this.actorKind,
    required this.payload,
    required this.occurredAt,
  });

  final String eventKind;
  final String actorUserId;
  final String actorKind;
  final Map<String, Object?> payload;
  final DateTime occurredAt;
}

class _RecordingAuditSink implements HeapSnapshotCaptureAuditSink {
  final List<_RecordedAuditRow> records = <_RecordedAuditRow>[];

  @override
  Future<void> record({
    required String eventKind,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    records.add(_RecordedAuditRow(
      eventKind: eventKind,
      actorUserId: actorUserId,
      actorKind: actorKind,
      payload: Map<String, Object?>.from(payload),
      occurredAt: occurredAt,
    ));
  }
}

class _CapturedResult {
  _CapturedResult({
    required this.handled,
    required this.statusCode,
    required this.bodyText,
  });

  final bool handled;
  final int statusCode;
  final String bodyText;

  Map<String, Object?> get bodyJson {
    if (bodyText.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(bodyText);
    if (decoded is Map) return decoded.cast<String, Object?>();
    return const <String, Object?>{};
  }
}

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

Future<_CapturedResult> _captureRequest({
  required HeapSnapshotCaptureRouter router,
  required String method,
  required String path,
  required Map<String, String> headers,
  required List<int> body,
}) async {
  return _withRealHttp(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handledCompleter = Completer<bool>();
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        final handled = await router.tryHandle(request);
        if (!handledCompleter.isCompleted) {
          handledCompleter.complete(handled);
        }
        if (!handled) {
          request.response.statusCode = 404;
          await request.response.close();
        }
      } catch (_) {
        if (!handledCompleter.isCompleted) {
          handledCompleter.complete(false);
        }
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });

    final client = HttpClient();
    try {
      final clientRequest = await client.openUrl(
        method,
        Uri.parse('http://${server.address.host}:${server.port}$path'),
      );
      clientRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer test-token',
      );
      headers.forEach(clientRequest.headers.set);
      clientRequest.headers.contentType =
          ContentType('application', 'octet-stream');
      clientRequest.contentLength = body.length;
      clientRequest.add(body);
      final response = await clientRequest.close();
      final responseBody = await utf8.decodeStream(response);
      final handled = await handledCompleter.future;
      return _CapturedResult(
        handled: handled,
        statusCode: response.statusCode,
        bodyText: responseBody,
      );
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });
}
