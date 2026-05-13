// Pressure preview v1 — Slice A11.2 (R3 §3 quick-win) — heap-snapshot
// uploader for long-running soak harnesses.
//
// Sprint authority: `docs/_execution/lane_a_code_health/03_execution_slices.md`
// "Slice A11.2 - Soak Harness Durable Extensions". R3 §3 calls out
// threshold-triggered heap-snapshot capture as the next step beyond
// the FD-watcher gauge: when the soak harness or the proxy crosses a
// memory-growth ceiling we want a `.heapsnapshot` shipped to durable
// storage so a developer can post-mortem the leak in DevTools.
//
// Architecture
// ------------
// The uploader is split into three injectable seams so the harness can
// be exercised in tests without burning real cloud quota AND so the
// implementation can be retargeted from GCS to Azure Blob (which is
// what F&F actually uses for `tool/audit_anchor/` immutable storage)
// without rewriting the polling / triggering logic:
//
//   * [HeapSnapshotCapturer] — wraps `dart:developer`'s
//     `NativeRuntime.writeHeapSnapshotToFile`. Production: the default
//     [DartDeveloperHeapSnapshotCapturer]. Tests: a stub that writes
//     synthetic bytes.
//   * [HeapSnapshotUploadTarget] — receives the snapshot bytes + a
//     content-type hint and returns the durable object key on success.
//     Production: [GcsHeapSnapshotUploadTarget] (resumable PUT against
//     `https://storage.googleapis.com/<bucket>/<key>` with a bearer
//     token). Tests: a stub that records calls. The contract is
//     deliberately storage-agnostic so a future slice can swap in an
//     Azure Blob target matching the audit-anchor pattern in
//     `tool/audit_anchor/azure_blob_client.dart`.
//   * [HeapSnapshotUploader] — the orchestrator: polls the
//     trigger-condition, captures via the [HeapSnapshotCapturer], and
//     uploads via the [HeapSnapshotUploadTarget]. Owns the metric
//     emission shape that mirrors `FdWatcher`'s structured JSON line.
//
// Cross-platform behaviour
// ------------------------
// Heap-snapshot capture works on Dart VM on every platform Flutter
// supports for the harness (Linux, Windows, macOS). GCS upload also
// works on every platform. NO platform-specific carve-out is needed.
//
// Env-var conventions
// -------------------
// The default GCS upload target reads:
//   * `GCS_BUCKET_HEAP_SNAPSHOTS` — destination bucket. When unset,
//     the uploader logs a one-time "skipped — no bucket configured"
//     line and switches to a no-op trigger. NEVER throws.
//   * `GCS_BEARER_TOKEN` — short-lived bearer token. When unset, same
//     fallback (no-op + log; no throw). Production wires this from a
//     workload-identity-federation-derived token similar to the Azure
//     pattern in `tool/audit_anchor/azure_blob_client.dart`.
//
// CRITICAL: when either env var is unset, the uploader MUST stay
// alive (so the harness keeps running) and MUST NOT throw.
//
// Output line shape (mirrors FdWatcher)
// -------------------------------------
//   { "ts": "<iso>", "metric": "soak.heap_snapshot.uploaded",
//     "object_key": "<key>", "size_bytes": <int> }
//   { "ts": "<iso>", "metric": "soak.heap_snapshot.skipped",
//     "reason": "<reason>" }
//   { "ts": "<iso>", "metric": "soak.heap_snapshot.error",
//     "stage": "<capture|upload>", "error": "<short>" }

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Captures a Dart heap snapshot to a local file. Production wiring is
/// [DartDeveloperHeapSnapshotCapturer] which delegates to
/// `dart:developer`'s `NativeRuntime.writeHeapSnapshotToFile`.
abstract class HeapSnapshotCapturer {
  /// Writes a `.heapsnapshot` to [filePath]. Returns the path on
  /// success. Throws on failure; the caller catches and logs.
  Future<String> capture(String filePath);
}

/// Default capturer backed by `dart:developer`. Available on Dart 3.6+
/// (the F&F repo runs Dart 3.9.x; see `pubspec.yaml`).
class DartDeveloperHeapSnapshotCapturer implements HeapSnapshotCapturer {
  const DartDeveloperHeapSnapshotCapturer();

  @override
  Future<String> capture(String filePath) async {
    // `writeHeapSnapshotToFile` is synchronous from the caller's POV
    // but does block the VM briefly. We wrap in `Future.sync` so the
    // call participates in the harness's async error boundary.
    await Future<void>.sync(
      () => developer.NativeRuntime.writeHeapSnapshotToFile(filePath),
    );
    return filePath;
  }
}

/// Result of a successful heap-snapshot upload.
class HeapSnapshotUploadResult {
  const HeapSnapshotUploadResult({
    required this.objectKey,
    required this.sizeBytes,
  });

  final String objectKey;
  final int sizeBytes;
}

/// Receives the raw snapshot bytes and a content-type hint and pushes
/// them to durable storage. Production wiring is
/// [GcsHeapSnapshotUploadTarget]; tests inject a stub.
abstract class HeapSnapshotUploadTarget {
  /// Whether the target is configured to accept uploads. When `false`,
  /// [HeapSnapshotUploader] logs a "skipped" line and never invokes
  /// [upload].
  bool get isConfigured;

  /// The reason the target reports `isConfigured == false`. Surfaced
  /// in the structured "skipped" log line.
  String get unconfiguredReason;

  /// Upload [bytes] to the target. The target chooses the object key.
  /// Throws on failure; the caller catches and logs.
  Future<HeapSnapshotUploadResult> upload({
    required List<int> bytes,
    required String contentType,
    required DateTime timestamp,
  });
}

/// Default GCS upload target. Pushes a snapshot to
/// `https://storage.googleapis.com/<bucket>/heap-snapshots/<iso>.heapsnapshot`
/// using a simple bearer-token PUT. Single-object uploads only — large
/// snapshots that need resumable uploads should compose a different
/// target.
///
/// Env vars consumed:
///   * `GCS_BUCKET_HEAP_SNAPSHOTS` — required.
///   * `GCS_BEARER_TOKEN` — required.
class GcsHeapSnapshotUploadTarget implements HeapSnapshotUploadTarget {
  GcsHeapSnapshotUploadTarget({
    Map<String, String>? env,
    HttpClient? httpClient,
  })  : _env = env ?? Platform.environment,
        _httpClient = httpClient ?? HttpClient();

  final Map<String, String> _env;
  final HttpClient _httpClient;

  String? get _bucket => _env['GCS_BUCKET_HEAP_SNAPSHOTS']?.trim().isEmpty == true
      ? null
      : _env['GCS_BUCKET_HEAP_SNAPSHOTS']?.trim();

  String? get _bearerToken => _env['GCS_BEARER_TOKEN']?.trim().isEmpty == true
      ? null
      : _env['GCS_BEARER_TOKEN']?.trim();

  @override
  bool get isConfigured => _bucket != null && _bearerToken != null;

  @override
  String get unconfiguredReason {
    if (_bucket == null && _bearerToken == null) {
      return 'GCS_BUCKET_HEAP_SNAPSHOTS and GCS_BEARER_TOKEN both unset';
    }
    if (_bucket == null) return 'GCS_BUCKET_HEAP_SNAPSHOTS unset';
    return 'GCS_BEARER_TOKEN unset';
  }

  @override
  Future<HeapSnapshotUploadResult> upload({
    required List<int> bytes,
    required String contentType,
    required DateTime timestamp,
  }) async {
    final bucket = _bucket;
    final token = _bearerToken;
    if (bucket == null || token == null) {
      throw StateError(
        'GcsHeapSnapshotUploadTarget.upload called while unconfigured: '
        '$unconfiguredReason',
      );
    }
    final isoStamp = timestamp
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^\w]'), '_');
    final objectKey = 'heap-snapshots/$isoStamp.heapsnapshot';
    final uri = Uri.parse(
      'https://storage.googleapis.com/$bucket/$objectKey',
    );
    final request = await _httpClient.putUrl(uri);
    request.headers.set('authorization', 'Bearer $token');
    request.headers.set('content-type', contentType);
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    // Drain so the connection can be reused / closed cleanly.
    final responseBody = <int>[];
    await for (final chunk in response) {
      responseBody.addAll(chunk);
      if (responseBody.length > 4096) break;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'GCS upload to $uri returned ${response.statusCode}: '
        '${utf8.decode(responseBody, allowMalformed: true)}',
        uri: uri,
      );
    }
    return HeapSnapshotUploadResult(
      objectKey: objectKey,
      sizeBytes: bytes.length,
    );
  }
}

/// Threshold-triggered heap-snapshot uploader. Polls a trigger
/// condition; when it fires, captures the heap and uploads.
class HeapSnapshotUploader {
  HeapSnapshotUploader({
    required bool Function() triggerCondition,
    required HeapSnapshotUploadTarget uploadTarget,
    Duration pollInterval = const Duration(seconds: 60),
    HeapSnapshotCapturer? capturer,
    IOSink? output,
    DateTime Function()? clock,
    Directory? scratchDirectory,
  })  : _triggerCondition = triggerCondition,
        _uploadTarget = uploadTarget,
        _pollInterval = pollInterval,
        _capturer = capturer ?? const DartDeveloperHeapSnapshotCapturer(),
        _output = output ?? stdout,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _scratchDirectory = scratchDirectory ?? Directory.systemTemp;

  final bool Function() _triggerCondition;
  final HeapSnapshotUploadTarget _uploadTarget;
  final Duration _pollInterval;
  final HeapSnapshotCapturer _capturer;
  final IOSink _output;
  final DateTime Function() _clock;
  final Directory _scratchDirectory;

  Timer? _timer;
  bool _stopped = false;
  bool _loggedUnconfigured = false;
  bool _busy = false;
  int _uploadCount = 0;

  /// Whether the uploader is actively polling.
  bool get isPolling => _timer?.isActive == true;

  /// How many successful uploads the uploader has made since [start].
  int get uploadCount => _uploadCount;

  /// Schedule the periodic trigger poll. When the upload target is not
  /// configured, the watcher logs ONE "skipped — no bucket configured"
  /// line and stays inert for the rest of the run (it does NOT poll the
  /// trigger condition because there's no destination anyway).
  void start() {
    if (_stopped) {
      throw StateError('HeapSnapshotUploader.start() called after stop()');
    }
    if (_timer != null) {
      // Idempotent.
      return;
    }
    if (!_uploadTarget.isConfigured) {
      _logSkipped(_uploadTarget.unconfiguredReason);
      _loggedUnconfigured = true;
      return;
    }
    _timer = Timer.periodic(_pollInterval, (_) => _maybeFire());
  }

  /// Cancel the timer. Safe to call multiple times.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Run a single trigger-check + capture + upload pass. Exposed for
  /// tests; the periodic timer simply forwards to this method.
  Future<void> tick() => _maybeFire();

  Future<void> _maybeFire() async {
    if (_busy || _stopped) return;
    bool shouldFire;
    try {
      shouldFire = _triggerCondition();
    } catch (e) {
      _emit(<String, Object?>{
        'ts': _clock().toIso8601String(),
        'metric': 'soak.heap_snapshot.error',
        'stage': 'trigger_condition',
        'error': e.toString().split('\n').first,
      });
      return;
    }
    if (!shouldFire) return;
    _busy = true;
    try {
      await _captureAndUpload();
    } finally {
      _busy = false;
    }
  }

  Future<void> _captureAndUpload() async {
    final timestamp = _clock();
    final isoStamp = timestamp
        .toIso8601String()
        .replaceAll(RegExp(r'[^\w]'), '_');
    final scratchPath =
        '${_scratchDirectory.path}${Platform.pathSeparator}'
        'heap_snapshot_$isoStamp.heapsnapshot';

    // Capture.
    String capturedPath;
    try {
      capturedPath = await _capturer.capture(scratchPath);
    } catch (e) {
      _emit(<String, Object?>{
        'ts': _clock().toIso8601String(),
        'metric': 'soak.heap_snapshot.error',
        'stage': 'capture',
        'error': e.toString().split('\n').first,
      });
      return;
    }

    // Read bytes back (the writer wrote them to disk).
    List<int> bytes;
    try {
      bytes = await File(capturedPath).readAsBytes();
    } catch (e) {
      _emit(<String, Object?>{
        'ts': _clock().toIso8601String(),
        'metric': 'soak.heap_snapshot.error',
        'stage': 'read_back',
        'error': e.toString().split('\n').first,
      });
      _bestEffortDelete(capturedPath);
      return;
    }

    // Upload.
    HeapSnapshotUploadResult result;
    try {
      result = await _uploadTarget.upload(
        bytes: bytes,
        contentType: 'application/octet-stream',
        timestamp: timestamp,
      );
    } catch (e) {
      _emit(<String, Object?>{
        'ts': _clock().toIso8601String(),
        'metric': 'soak.heap_snapshot.error',
        'stage': 'upload',
        'error': e.toString().split('\n').first,
      });
      _bestEffortDelete(capturedPath);
      return;
    }

    _uploadCount += 1;
    _emit(<String, Object?>{
      'ts': _clock().toIso8601String(),
      'metric': 'soak.heap_snapshot.uploaded',
      'object_key': result.objectKey,
      'size_bytes': result.sizeBytes,
    });
    _bestEffortDelete(capturedPath);
  }

  void _bestEffortDelete(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Ignore cleanup failures — disk pressure is not the harness's
      // concern.
    }
  }

  void _logSkipped(String reason) {
    if (_loggedUnconfigured) return;
    _emit(<String, Object?>{
      'ts': _clock().toIso8601String(),
      'metric': 'soak.heap_snapshot.skipped',
      'reason': reason,
    });
  }

  void _emit(Map<String, Object?> line) {
    _output.writeln(jsonEncode(line));
  }
}
