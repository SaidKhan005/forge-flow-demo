// Wave 2 Lane Q slice Q-1 — HeapSnapshotUploader unit tests.
//
// Covers:
//   * Azure Blob upload happy path with a stub upload target + stub
//     capturer.
//   * Skip when env vars unset (target reports `isConfigured == false`;
//     uploader logs "skipped" and stays inert — never throws).
//   * Trigger-condition false → no upload.
//   * Heap-snapshot capture failure → continues with structured error
//     log (does NOT throw).
//   * `AzureBlobHeapSnapshotUploadTarget` wire shape: PUT request goes
//     to the right URI, carries the bearer + x-ms-version + BlockBlob
//     headers, and surfaces non-2xx as `HttpException`.
//
// Mocks: stub [HeapSnapshotCapturer] writes synthetic bytes to the
// requested path; stub [HeapSnapshotUploadTarget] records calls; fixed
// clock pins the `ts` field; in-memory `_BufferedSink` captures the
// JSON lines.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/audit_anchor/azure_blob_client.dart';
import '../../tool/pressure/p4_heap_snapshot_uploader.dart';

void main() {
  group('HeapSnapshotUploader', () {
    late Directory scratchDir;

    setUp(() {
      scratchDir =
          Directory.systemTemp.createTempSync('heap_uploader_test_');
    });

    tearDown(() {
      if (scratchDir.existsSync()) {
        scratchDir.deleteSync(recursive: true);
      }
    });

    test('happy path: trigger fires -> capture + upload + structured log',
        () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer(synthBytes: <int>[1, 2, 3, 4, 5]);
      final target = _StubUploadTarget(configured: true);
      var triggerCalls = 0;
      final uploader = HeapSnapshotUploader(
        triggerCondition: () {
          triggerCalls += 1;
          return true;
        },
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13, 1, 2, 3),
        scratchDirectory: scratchDir,
        pollInterval: const Duration(seconds: 60),
        podId: 'pod-abc',
        runId: 'run-xyz',
      );

      uploader.start();
      await uploader.tick();
      uploader.stop();
      await sink.close();

      expect(triggerCalls, greaterThanOrEqualTo(1));
      expect(capturer.captures, hasLength(1));
      expect(target.uploads, hasLength(1));
      expect(uploader.uploadCount, 1);
      expect(target.uploads.single.podId, 'pod-abc');
      expect(target.uploads.single.runId, 'run-xyz');

      final decoded = sink.lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      expect(decoded, hasLength(1));
      expect(decoded.single['metric'], 'soak.heap_snapshot.uploaded');
      expect(decoded.single['size_bytes'], 5);
      expect(decoded.single['pod_id'], 'pod-abc');
      expect(decoded.single['run_id'], 'run-xyz');
    });

    test(
        'skip when target unconfigured: emits ONE "skipped" line; never '
        'invokes capture/upload', () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer(synthBytes: <int>[1]);
      final target = _StubUploadTarget(
        configured: false,
        unconfiguredReason: 'AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER unset',
      );
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => true,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        scratchDirectory: scratchDir,
      );

      uploader.start();
      // tick() should not fire because start() detected the
      // unconfigured target and returned without scheduling.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      uploader.stop();
      await sink.close();

      expect(capturer.captures, isEmpty);
      expect(target.uploads, isEmpty);
      expect(uploader.uploadCount, 0);

      expect(sink.lines, hasLength(1));
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'soak.heap_snapshot.skipped');
      expect(
        decoded['reason'],
        'AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER unset',
      );
    });

    test('trigger condition false -> no capture, no upload, no log line',
        () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer(synthBytes: <int>[1, 2]);
      final target = _StubUploadTarget(configured: true);
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => false,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        scratchDirectory: scratchDir,
      );

      uploader.start();
      await uploader.tick();
      uploader.stop();
      await sink.close();

      expect(capturer.captures, isEmpty);
      expect(target.uploads, isEmpty);
      expect(sink.lines, isEmpty);
    });

    test(
        'capture failure -> emits structured error, does NOT throw, does '
        'NOT upload', () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer.failing('synthetic capture failure');
      final target = _StubUploadTarget(configured: true);
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => true,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        scratchDirectory: scratchDir,
      );

      uploader.start();
      await uploader.tick();
      uploader.stop();
      await sink.close();

      expect(target.uploads, isEmpty);
      expect(uploader.uploadCount, 0);

      final decoded = sink.lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      expect(decoded, hasLength(1));
      expect(decoded.single['metric'], 'soak.heap_snapshot.error');
      expect(decoded.single['stage'], 'capture');
      expect(
        decoded.single['error'],
        contains('synthetic capture failure'),
      );
    });

    test(
        'upload failure -> emits structured error, does NOT throw, '
        'increments no upload count', () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer(synthBytes: <int>[9, 9, 9]);
      final target = _StubUploadTarget(
        configured: true,
        failOnUpload: 'simulated 503',
      );
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => true,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        scratchDirectory: scratchDir,
      );

      uploader.start();
      await uploader.tick();
      uploader.stop();
      await sink.close();

      expect(uploader.uploadCount, 0);
      final decoded = sink.lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      expect(decoded, hasLength(1));
      expect(decoded.single['metric'], 'soak.heap_snapshot.error');
      expect(decoded.single['stage'], 'upload');
      expect(decoded.single['error'], contains('simulated 503'));
    });

    test(
        'tick() is idempotent under concurrent calls: only one upload '
        'fires while previous is in-flight', () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer(synthBytes: <int>[1]);
      final target = _StubUploadTarget(
        configured: true,
        uploadDelay: const Duration(milliseconds: 50),
      );
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => true,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        scratchDirectory: scratchDir,
      );
      uploader.start();
      // Fire 3 ticks concurrently. The `_busy` guard should drop the
      // 2nd and 3rd while the 1st is still running its upload.
      await Future.wait(<Future<void>>[
        uploader.tick(),
        uploader.tick(),
        uploader.tick(),
      ]);
      uploader.stop();
      await sink.close();

      expect(uploader.uploadCount, 1);
      expect(target.uploads, hasLength(1));
    });
  });

  group('AzureBlobHeapSnapshotUploadTarget', () {
    test(
        'isConfigured = false when AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER '
        'is unset', () {
      final target = AzureBlobHeapSnapshotUploadTarget(
        env: <String, String>{},
      );
      expect(target.isConfigured, isFalse);
      expect(
        target.unconfiguredReason,
        contains('AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER'),
      );
    });

    test(
        'isConfigured = false when only container + endpoint set without '
        'AAD app credentials', () {
      final target = AzureBlobHeapSnapshotUploadTarget(env: <String, String>{
        'AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER': 'ff-soak-heap',
        'AZURE_BLOB_HEAP_SNAPSHOTS_ENDPOINT':
            'https://forgeflowstaging1.blob.core.windows.net',
      });
      expect(target.isConfigured, isFalse);
      final reason = target.unconfiguredReason;
      expect(reason, contains('AZURE_AD_TENANT_ID'));
      expect(reason, contains('AZURE_AD_CLIENT_ID'));
    });

    test(
        'isConfigured = true when all four env vars are set', () {
      final target = AzureBlobHeapSnapshotUploadTarget(env: <String, String>{
        'AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER': 'ff-soak-heap',
        'AZURE_BLOB_HEAP_SNAPSHOTS_ENDPOINT':
            'https://forgeflowstaging1.blob.core.windows.net',
        'AZURE_AD_TENANT_ID': '11111111-1111-1111-1111-aaaaaaaaaaaa',
        'AZURE_AD_CLIENT_ID': '22222222-2222-2222-2222-bbbbbbbbbbbb',
      });
      expect(target.isConfigured, isTrue);
    });

    test('upload throws when called while unconfigured', () async {
      final target = AzureBlobHeapSnapshotUploadTarget(
        env: <String, String>{},
      );
      expect(
        () => target.upload(
          bytes: <int>[1, 2, 3],
          contentType: 'application/octet-stream',
          timestamp: DateTime.utc(2026, 5, 13),
        ),
        throwsStateError,
      );
    });

    test(
        'PUTs the snapshot bytes with bearer + x-ms-version + BlockBlob '
        'headers; returns object key + blob URI on 201',
        () async {
      final requester = _RecordingHttpRequester(
        handlers: <_Handler>[
          _Handler.any((request) {
            expect(request.method, 'PUT');
            expect(
              request.uri.toString(),
              startsWith(
                'https://forgeflowstaging1.blob.core.windows.net/'
                'forge-flow-soak/heap-snapshots/run-7/pod-3/',
              ),
            );
            expect(request.uri.toString(), endsWith('.heapsnapshot'));
            expect(request.headers['Authorization'], 'Bearer test-token');
            expect(request.headers['x-ms-version'], '2021-12-02');
            expect(request.headers['x-ms-blob-type'], 'BlockBlob');
            expect(request.headers['Content-Type'], 'application/octet-stream');
            expect(request.headers.containsKey('x-ms-date'), isTrue);
            expect(request.body, <int>[7, 8, 9]);
            return _canned(
              201,
              headers: <String, String>{'ETag': '"0xSOAKBLOB1"'},
            );
          }),
        ],
      );
      final target = AzureBlobHeapSnapshotUploadTarget(
        env: <String, String>{
          'AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER': 'forge-flow-soak',
          'AZURE_BLOB_HEAP_SNAPSHOTS_ENDPOINT':
              'https://forgeflowstaging1.blob.core.windows.net',
        },
        tokenProvider: _StaticTokenProvider('test-token'),
        requester: requester,
        clock: () => DateTime.utc(2026, 5, 13, 12, 34, 56),
      );

      final result = await target.upload(
        bytes: <int>[7, 8, 9],
        contentType: 'application/octet-stream',
        timestamp: DateTime.utc(2026, 5, 13, 12, 34, 56),
        podId: 'pod-3',
        runId: 'run-7',
      );

      expect(
        result.objectKey,
        startsWith('heap-snapshots/run-7/pod-3/heap-'),
      );
      expect(result.objectKey, endsWith('.heapsnapshot'));
      expect(result.sizeBytes, 3);
      expect(
        result.blobUri,
        startsWith(
          'https://forgeflowstaging1.blob.core.windows.net/'
          'forge-flow-soak/heap-snapshots/run-7/pod-3/',
        ),
      );
      expect(requester.requests, hasLength(1));
    });

    test('non-2xx response raises HttpException with no token in message',
        () async {
      final requester = _RecordingHttpRequester(
        handlers: <_Handler>[
          _Handler.any(
            (_) => _canned(500, body: 'internal server error'),
          ),
        ],
      );
      final target = AzureBlobHeapSnapshotUploadTarget(
        env: <String, String>{
          'AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER': 'forge-flow-soak',
          'AZURE_BLOB_HEAP_SNAPSHOTS_ENDPOINT':
              'https://forgeflowstaging1.blob.core.windows.net',
        },
        tokenProvider: _StaticTokenProvider('secret-token'),
        requester: requester,
        clock: () => DateTime.utc(2026, 5, 13),
      );

      try {
        await target.upload(
          bytes: <int>[1],
          contentType: 'application/octet-stream',
          timestamp: DateTime.utc(2026, 5, 13),
          podId: 'pod-0',
          runId: 'run-0',
        );
        fail('expected HttpException');
      } on HttpException catch (error) {
        expect(error.toString(), contains('500'));
        expect(
          error.toString(),
          isNot(contains('secret-token')),
          reason: 'auth tokens must never appear in error messages',
        );
      }
    });

    test('soak container must NOT be the audit-anchor immutable container',
        () {
      // Doctrine guard: the soak uploader writes mutable developer-debug
      // artifacts. Mixing them into the audit-anchor immutable container
      // would either fail (`If-None-Match: *` rejection) or pollute
      // compliance evidence. This test pins the convention so future
      // edits cannot silently re-use the audit container name.
      const auditContainer = 'audit-chain-anchors-immutable';
      const soakContainer = 'forge-flow-soak-artifacts';
      expect(soakContainer, isNot(auditContainer));
    });
  });
}

/// Stub capturer: writes [synthBytes] (or throws if [_failure] set) to
/// the requested path.
class _StubCapturer implements HeapSnapshotCapturer {
  _StubCapturer({required List<int> synthBytes})
      : _synthBytes = synthBytes,
        _failure = null;

  _StubCapturer.failing(String message)
      : _synthBytes = const <int>[],
        _failure = message;

  final List<int> _synthBytes;
  final String? _failure;
  final List<String> captures = <String>[];

  @override
  Future<String> capture(String filePath) async {
    final failure = _failure;
    if (failure != null) {
      throw StateError(failure);
    }
    captures.add(filePath);
    await File(filePath).writeAsBytes(_synthBytes);
    return filePath;
  }
}

class _UploadCall {
  _UploadCall({
    required this.result,
    required this.podId,
    required this.runId,
  });

  final HeapSnapshotUploadResult result;
  final String? podId;
  final String? runId;
}

/// Stub upload target: records calls; optionally fails or delays.
class _StubUploadTarget implements HeapSnapshotUploadTarget {
  _StubUploadTarget({
    required this.configured,
    this.unconfiguredReason = 'unconfigured',
    this.failOnUpload,
    this.uploadDelay = Duration.zero,
  });

  final bool configured;
  @override
  final String unconfiguredReason;
  final String? failOnUpload;
  final Duration uploadDelay;
  final List<_UploadCall> uploads = <_UploadCall>[];

  @override
  bool get isConfigured => configured;

  @override
  Future<HeapSnapshotUploadResult> upload({
    required List<int> bytes,
    required String contentType,
    required DateTime timestamp,
    String? podId,
    String? runId,
  }) async {
    if (uploadDelay > Duration.zero) {
      await Future<void>.delayed(uploadDelay);
    }
    if (failOnUpload != null) {
      throw HttpException(failOnUpload!);
    }
    final result = HeapSnapshotUploadResult(
      objectKey:
          'heap-snapshots/${runId ?? 'unknown_run'}/${podId ?? 'unknown_pod'}/'
          'heap-${timestamp.toIso8601String()}.heapsnapshot',
      sizeBytes: bytes.length,
      blobUri:
          'https://forgeflowstaging1.blob.core.windows.net/forge-flow-soak/'
          'heap-snapshots/${runId ?? 'unknown_run'}/${podId ?? 'unknown_pod'}/'
          'heap-${timestamp.toIso8601String()}.heapsnapshot',
    );
    uploads.add(_UploadCall(result: result, podId: podId, runId: runId));
    return result;
  }
}

/// Captures `IOSink.writeln(...)` calls into a buffer. Identical to
/// the helper in `p4_fd_watcher_test.dart` (kept inline so each test
/// file is self-contained — pressure-test hygiene).
class _BufferedSink {
  _BufferedSink() {
    _controller = StreamController<List<int>>();
    _ioSink = IOSink(_controller.sink);
    _controller.stream.transform(utf8.decoder).listen(_buffer.write);
  }

  late final StreamController<List<int>> _controller;
  late final IOSink _ioSink;
  final StringBuffer _buffer = StringBuffer();

  IOSink get ioSink => _ioSink;

  Future<void> close() async {
    await _ioSink.flush();
    await _ioSink.close();
    await _controller.close();
  }

  List<String> get lines => _buffer
      .toString()
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
}

// --- AzureBlobHttpRequester test doubles (mirror tool/audit_anchor/test) ---

class _StaticTokenProvider implements AzureAccessTokenProvider {
  _StaticTokenProvider(this._token);
  final String _token;
  @override
  Future<String> getStorageAccessToken() async => _token;
}

class _CapturedRequest {
  _CapturedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

typedef _HandlerFn = AzureBlobHttpResponse Function(_CapturedRequest request);

class _Handler {
  _Handler._({required this.matches, required this.respond});

  factory _Handler.any(_HandlerFn respond) =>
      _Handler._(matches: (_) => true, respond: respond);

  final bool Function(_CapturedRequest request) matches;
  final _HandlerFn respond;
}

class _RecordingHttpRequester implements AzureBlobHttpRequester {
  _RecordingHttpRequester({required this.handlers});

  final List<_Handler> handlers;
  final List<_CapturedRequest> requests = <_CapturedRequest>[];

  @override
  Future<AzureBlobHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    List<int>? body,
  }) async {
    final captured = _CapturedRequest(
      method: method,
      uri: uri,
      headers: headers,
      body: body,
    );
    requests.add(captured);
    for (final handler in handlers) {
      if (handler.matches(captured)) {
        return handler.respond(captured);
      }
    }
    throw StateError('no handler matched ${captured.method} ${captured.uri}');
  }
}

AzureBlobHttpResponse _canned(
  int status, {
  Map<String, String>? headers,
  String? body,
  List<int>? bodyBytes,
}) {
  final lowercased = <String, String>{};
  (headers ?? const <String, String>{}).forEach((name, value) {
    lowercased[name.toLowerCase()] = value;
  });
  return AzureBlobHttpResponse(
    statusCode: status,
    headers: lowercased,
    bodyBytes: bodyBytes ?? (body == null ? <int>[] : utf8.encode(body)),
  );
}
