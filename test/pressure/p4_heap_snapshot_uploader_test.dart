// Slice A11.2 — HeapSnapshotUploader unit tests.
//
// Covers:
//   * GCS upload happy path with a stub upload target + stub capturer.
//   * GCS upload skip when env var unset (target reports
//     `isConfigured == false`; uploader logs "skipped" and stays inert
//     — never throws).
//   * Trigger-condition false → no upload.
//   * Heap-snapshot capture failure → continues with structured error
//     log (does NOT throw).
//
// Mocks: stub [HeapSnapshotCapturer] writes synthetic bytes to the
// requested path; stub [HeapSnapshotUploadTarget] records calls;
// fixed clock pins the `ts` field for snapshot assertions; in-memory
// `_BufferedSink` captures the JSON lines.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

    test('happy path: trigger fires → capture + upload + structured log',
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
        clock: () => DateTime.utc(2026, 5, 12, 1, 2, 3),
        scratchDirectory: scratchDir,
        pollInterval: const Duration(seconds: 60),
      );

      uploader.start();
      await uploader.tick();
      uploader.stop();
      await sink.close();

      expect(triggerCalls, greaterThanOrEqualTo(1));
      expect(capturer.captures, hasLength(1));
      expect(target.uploads, hasLength(1));
      expect(uploader.uploadCount, 1);

      final decoded = sink.lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      // The single emitted line should be the "uploaded" success
      // record (no skipped/error lines on the happy path).
      expect(decoded, hasLength(1));
      expect(decoded.single['metric'], 'soak.heap_snapshot.uploaded');
      expect(decoded.single['size_bytes'], 5);
      expect(decoded.single['object_key'], target.uploads.single.objectKey);
    });

    test(
        'skip when target unconfigured: emits ONE "skipped" line; never '
        'invokes capture/upload', () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer(synthBytes: <int>[1]);
      final target = _StubUploadTarget(
        configured: false,
        unconfiguredReason: 'GCS_BUCKET_HEAP_SNAPSHOTS unset',
      );
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => true,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 12),
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
      expect(decoded['reason'], 'GCS_BUCKET_HEAP_SNAPSHOTS unset');
    });

    test('trigger condition false → no capture, no upload, no log line',
        () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer(synthBytes: <int>[1, 2]);
      final target = _StubUploadTarget(configured: true);
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => false,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 12),
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
        'capture failure → emits structured error, does NOT throw, does '
        'NOT upload', () async {
      final sink = _BufferedSink();
      final capturer = _StubCapturer.failing('synthetic capture failure');
      final target = _StubUploadTarget(configured: true);
      final uploader = HeapSnapshotUploader(
        triggerCondition: () => true,
        uploadTarget: target,
        capturer: capturer,
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 12),
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
        'upload failure → emits structured error, does NOT throw, '
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
        clock: () => DateTime.utc(2026, 5, 12),
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
        clock: () => DateTime.utc(2026, 5, 12),
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

  group('GcsHeapSnapshotUploadTarget', () {
    test(
        'isConfigured = false when GCS_BUCKET_HEAP_SNAPSHOTS env var '
        'is unset', () {
      final target = GcsHeapSnapshotUploadTarget(env: <String, String>{});
      expect(target.isConfigured, isFalse);
      expect(
        target.unconfiguredReason,
        contains('GCS_BUCKET_HEAP_SNAPSHOTS'),
      );
    });

    test('isConfigured = false when only bucket is set', () {
      final target = GcsHeapSnapshotUploadTarget(env: <String, String>{
        'GCS_BUCKET_HEAP_SNAPSHOTS': 'ff-soak-heap',
      });
      expect(target.isConfigured, isFalse);
      expect(target.unconfiguredReason, contains('GCS_BEARER_TOKEN'));
    });

    test('isConfigured = true when both env vars are set', () {
      final target = GcsHeapSnapshotUploadTarget(env: <String, String>{
        'GCS_BUCKET_HEAP_SNAPSHOTS': 'ff-soak-heap',
        'GCS_BEARER_TOKEN': 'ya29.abc',
      });
      expect(target.isConfigured, isTrue);
    });

    test('upload throws when called while unconfigured', () async {
      final target = GcsHeapSnapshotUploadTarget(env: <String, String>{});
      expect(
        () => target.upload(
          bytes: <int>[1, 2, 3],
          contentType: 'application/octet-stream',
          timestamp: DateTime.utc(2026, 5, 12),
        ),
        throwsStateError,
      );
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
  final List<HeapSnapshotUploadResult> uploads = <HeapSnapshotUploadResult>[];

  @override
  bool get isConfigured => configured;

  @override
  Future<HeapSnapshotUploadResult> upload({
    required List<int> bytes,
    required String contentType,
    required DateTime timestamp,
  }) async {
    if (uploadDelay > Duration.zero) {
      await Future<void>.delayed(uploadDelay);
    }
    if (failOnUpload != null) {
      throw HttpException(failOnUpload!);
    }
    final result = HeapSnapshotUploadResult(
      objectKey: 'heap-snapshots/${timestamp.toIso8601String()}.heapsnapshot',
      sizeBytes: bytes.length,
    );
    uploads.add(result);
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
