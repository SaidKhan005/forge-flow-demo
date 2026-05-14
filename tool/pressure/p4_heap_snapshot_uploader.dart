// Wave 2 Lane Q slice Q-1 (2026-05-13) — heap-snapshot uploader for
// long-running soak harnesses, swapped from GCS → Azure Blob per the
// `POST_HARDENING_FOLLOWUPS` "Soak Heap-Snapshot Uploader" entry.
//
// Origin: A11.2 (PR #537) introduced `HeapSnapshotUploadTarget` plus
// `GcsHeapSnapshotUploadTarget`. The operator decision recorded in
// `docs/POST_HARDENING_FOLLOWUPS.md` "Soak Heap-Snapshot Uploader"
// section is that F&F will not run two cloud-storage backends — the
// audit-anchor system already targets Azure Blob (see
// `tool/audit_anchor/azure_blob_client.dart`), so the soak uploader
// mirrors that pattern. The GCS implementation is removed; the
// storage-agnostic interface stays as the load-bearing seam.
//
// Architecture
// ------------
// Same three injectable seams as the GCS predecessor:
//
//   * [HeapSnapshotCapturer] — wraps `dart:developer`'s
//     `NativeRuntime.writeHeapSnapshotToFile`. Production: the default
//     [DartDeveloperHeapSnapshotCapturer]. Tests: a stub that writes
//     synthetic bytes.
//   * [HeapSnapshotUploadTarget] — receives the snapshot bytes + a
//     content-type hint and returns the durable object key on success.
//     Production: [AzureBlobHeapSnapshotUploadTarget] (Azure Blob
//     BlockBlob PUT, authenticated via Workload Identity Federation
//     mirroring the audit-anchor pattern). Tests: a stub that records
//     calls.
//   * [HeapSnapshotUploader] — the orchestrator: polls the trigger
//     condition, captures via the [HeapSnapshotCapturer], and uploads
//     via the [HeapSnapshotUploadTarget]. Owns the metric emission
//     shape that mirrors `FdWatcher`'s structured JSON line.
//
// Cross-platform behaviour
// ------------------------
// Heap-snapshot capture works on Dart VM on every platform Flutter
// supports for the harness (Linux, Windows, macOS). Azure Blob upload
// also works on every platform. No platform-specific carve-out.
//
// Env-var conventions
// -------------------
// The default Azure Blob upload target reads:
//   * `AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER` — destination container.
//     When unset, the uploader logs a one-time "skipped — no container
//     configured" line and switches to a no-op trigger. NEVER throws.
//   * `AZURE_BLOB_HEAP_SNAPSHOTS_ENDPOINT` — storage account endpoint
//     (e.g. `https://forgeflowstaging1.blob.core.windows.net`). When
//     unset, same fallback (no-op + log; no throw). Production wires
//     this from the operator's `forge_flow.secrets.ps1`.
//   * `AZURE_AD_TENANT_ID` — Azure AD tenant hosting the federated app
//     registration (shared with the audit-anchor path).
//   * `AZURE_AD_CLIENT_ID` — Azure AD app-registration client id.
//
// All four must be set for `isConfigured == true`. When any are unset,
// the uploader MUST stay alive (so the harness keeps running) and
// MUST NOT throw. Soak artifacts use a separate container from the
// audit-anchor immutable container so they do not collide with
// compliance evidence.
//
// Output line shape (mirrors FdWatcher)
// -------------------------------------
//   { "ts": "<iso>", "metric": "soak.heap_snapshot.uploaded",
//     "object_key": "<key>", "blob_uri": "<full uri>",
//     "size_bytes": <int>, "pod_id": "<pod>", "run_id": "<run>" }
//   { "ts": "<iso>", "metric": "soak.heap_snapshot.skipped",
//     "reason": "<reason>" }
//   { "ts": "<iso>", "metric": "soak.heap_snapshot.error",
//     "stage": "<capture|upload>", "error": "<short>" }

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../audit_anchor/azure_blob_client.dart';

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
    this.blobUri,
  });

  /// The object key the target chose (relative path within the
  /// container, e.g. `heap-snapshots/<run_id>/<pod_id>/<iso>.heapsnapshot`).
  final String objectKey;

  /// The total bytes uploaded.
  final int sizeBytes;

  /// Optional full URI (storage endpoint + container + object key).
  /// Production wiring returns this so the final soak report can link
  /// straight to the blob. Test stubs may omit it.
  final String? blobUri;
}

/// Receives the raw snapshot bytes and a content-type hint and pushes
/// them to durable storage. Production wiring is
/// [AzureBlobHeapSnapshotUploadTarget]; tests inject a stub.
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
  ///
  /// [podId] and [runId] are optional naming hints — production wires
  /// them into the object key so multi-pod runs can be told apart.
  Future<HeapSnapshotUploadResult> upload({
    required List<int> bytes,
    required String contentType,
    required DateTime timestamp,
    String? podId,
    String? runId,
  });
}

/// Env-var names the production Azure Blob upload target reads. Names
/// only; values never logged. Mirrors `AuditAnchorEnvNames`.
class SoakHeapSnapshotEnvNames {
  const SoakHeapSnapshotEnvNames._();

  /// Destination container for soak artifacts. MUST be different from
  /// the audit-anchor immutable container; soak snapshots are
  /// developer-debug artifacts, not compliance evidence.
  static const String azureBlobContainer =
      'AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER';

  /// Storage account endpoint, e.g.
  /// `https://forgeflowstaging1.blob.core.windows.net`.
  static const String azureBlobEndpoint =
      'AZURE_BLOB_HEAP_SNAPSHOTS_ENDPOINT';

  /// Azure AD tenant ID hosting the federated app registration.
  /// Shared with the audit-anchor path.
  static const String azureAdTenantId = 'AZURE_AD_TENANT_ID';

  /// Azure AD app-registration client id for the federated identity.
  /// Shared with the audit-anchor path.
  static const String azureAdClientId = 'AZURE_AD_CLIENT_ID';

  static const List<String> required = <String>[
    azureBlobContainer,
    azureBlobEndpoint,
    azureAdTenantId,
    azureAdClientId,
  ];
}

/// Default Azure Blob upload target. Pushes a snapshot to
/// `<endpoint>/<container>/heap-snapshots/<run_id>/<pod_id>/<iso>.heapsnapshot`
/// as a BlockBlob via the same Workload Identity Federation flow the
/// audit-anchor system uses (`tool/audit_anchor/azure_blob_client.dart`).
/// Soak artifacts use a separate container (not immutable), so the
/// `If-None-Match: *` guard the audit-anchor writer uses is dropped —
/// re-running a soak with the same `run_id` overwrites is fine.
///
/// Env vars consumed: see [SoakHeapSnapshotEnvNames].
class AzureBlobHeapSnapshotUploadTarget implements HeapSnapshotUploadTarget {
  AzureBlobHeapSnapshotUploadTarget({
    Map<String, String>? env,
    AzureBlobHttpRequester? requester,
    AzureAccessTokenProvider? tokenProvider,
    DateTime Function()? clock,
    String apiVersion = '2021-12-02',
  })  : _env = env ?? Platform.environment,
        _requester = requester ?? DartIoAzureBlobHttpRequester(),
        _tokenProviderOverride = tokenProvider,
        _clock = clock ?? DateTime.now,
        _apiVersion = apiVersion;

  final Map<String, String> _env;
  final AzureBlobHttpRequester _requester;
  final AzureAccessTokenProvider? _tokenProviderOverride;
  final DateTime Function() _clock;
  final String _apiVersion;

  AzureAccessTokenProvider? _cachedDefaultProvider;

  String? _readNonEmpty(String name) {
    final raw = _env[name]?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  String? get _container => _readNonEmpty(
        SoakHeapSnapshotEnvNames.azureBlobContainer,
      );

  String? get _endpoint => _readNonEmpty(
        SoakHeapSnapshotEnvNames.azureBlobEndpoint,
      );

  String? get _tenantId => _readNonEmpty(
        SoakHeapSnapshotEnvNames.azureAdTenantId,
      );

  String? get _clientId => _readNonEmpty(
        SoakHeapSnapshotEnvNames.azureAdClientId,
      );

  AzureAccessTokenProvider _resolveTokenProvider() {
    final override = _tokenProviderOverride;
    if (override != null) return override;
    final tenant = _tenantId;
    final client = _clientId;
    if (tenant == null || client == null) {
      throw StateError(
        'AzureBlobHeapSnapshotUploadTarget: token provider requested '
        'while AZURE_AD_TENANT_ID / AZURE_AD_CLIENT_ID are unset',
      );
    }
    return _cachedDefaultProvider ??= WorkloadIdentityFederationTokenProvider(
      tenantId: tenant,
      clientId: client,
      requester: _requester,
    );
  }

  @override
  bool get isConfigured {
    if (_tokenProviderOverride != null) {
      // Tests can wire a fake token provider while leaving the AD env
      // vars unset — they still need container + endpoint.
      return _container != null && _endpoint != null;
    }
    return _container != null &&
        _endpoint != null &&
        _tenantId != null &&
        _clientId != null;
  }

  @override
  String get unconfiguredReason {
    final missing = <String>[];
    if (_container == null) {
      missing.add(SoakHeapSnapshotEnvNames.azureBlobContainer);
    }
    if (_endpoint == null) {
      missing.add(SoakHeapSnapshotEnvNames.azureBlobEndpoint);
    }
    if (_tokenProviderOverride == null) {
      if (_tenantId == null) {
        missing.add(SoakHeapSnapshotEnvNames.azureAdTenantId);
      }
      if (_clientId == null) {
        missing.add(SoakHeapSnapshotEnvNames.azureAdClientId);
      }
    }
    if (missing.isEmpty) {
      // Defensive: should not be reached when isConfigured == false.
      return 'AzureBlobHeapSnapshotUploadTarget unconfigured (no env names captured)';
    }
    return '${missing.join(', ')} unset';
  }

  Uri _blobUri({
    required String endpoint,
    required String container,
    required String blobName,
  }) {
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    final encodedBlob = blobName
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return Uri.parse(
      '$base/${Uri.encodeComponent(container)}/$encodedBlob',
    );
  }

  @override
  Future<HeapSnapshotUploadResult> upload({
    required List<int> bytes,
    required String contentType,
    required DateTime timestamp,
    String? podId,
    String? runId,
  }) async {
    final container = _container;
    final endpoint = _endpoint;
    if (container == null || endpoint == null) {
      throw StateError(
        'AzureBlobHeapSnapshotUploadTarget.upload called while '
        'unconfigured: $unconfiguredReason',
      );
    }
    final tokenProvider = _resolveTokenProvider();
    final token = await tokenProvider.getStorageAccessToken();

    final isoStamp = timestamp
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[^\w]'), '_');
    final safeRun = (runId ?? 'unknown_run').replaceAll(
      RegExp(r'[^A-Za-z0-9._\-]'),
      '_',
    );
    final safePod = (podId ?? 'unknown_pod').replaceAll(
      RegExp(r'[^A-Za-z0-9._\-]'),
      '_',
    );
    final objectKey =
        'heap-snapshots/$safeRun/$safePod/heap-$isoStamp.heapsnapshot';
    final uri = _blobUri(
      endpoint: endpoint,
      container: container,
      blobName: objectKey,
    );
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'x-ms-version': _apiVersion,
      'x-ms-date': HttpDate.format(_clock().toUtc()),
      'x-ms-blob-type': 'BlockBlob',
      'Content-Type': contentType,
    };
    final response = await _requester.send(
      method: 'PUT',
      uri: uri,
      headers: headers,
      body: bytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Azure Blob PUT to $uri returned ${response.statusCode}: '
        '${_truncateExcerpt(utf8.decode(response.bodyBytes, allowMalformed: true))}',
        uri: uri,
      );
    }
    return HeapSnapshotUploadResult(
      objectKey: objectKey,
      sizeBytes: bytes.length,
      blobUri: uri.toString(),
    );
  }
}

String _truncateExcerpt(String text) {
  const limit = 240;
  final stripped = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (stripped.length <= limit) return stripped;
  return '${stripped.substring(0, limit)}…';
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
    String? podId,
    String? runId,
  })  : _triggerCondition = triggerCondition,
        _uploadTarget = uploadTarget,
        _pollInterval = pollInterval,
        _capturer = capturer ?? const DartDeveloperHeapSnapshotCapturer(),
        _output = output ?? stdout,
        _clock = clock ?? (() => DateTime.now().toUtc()),
        _scratchDirectory = scratchDirectory ?? Directory.systemTemp,
        _podId = podId,
        _runId = runId;

  final bool Function() _triggerCondition;
  final HeapSnapshotUploadTarget _uploadTarget;
  final Duration _pollInterval;
  final HeapSnapshotCapturer _capturer;
  final IOSink _output;
  final DateTime Function() _clock;
  final Directory _scratchDirectory;
  final String? _podId;
  final String? _runId;

  Timer? _timer;
  bool _stopped = false;
  bool _loggedUnconfigured = false;
  bool _busy = false;
  int _uploadCount = 0;
  final List<HeapSnapshotUploadResult> _uploads = <HeapSnapshotUploadResult>[];

  /// Whether the uploader is actively polling.
  bool get isPolling => _timer?.isActive == true;

  /// How many successful uploads the uploader has made since [start].
  int get uploadCount => _uploadCount;

  /// All successful upload results since [start] — used by the soak
  /// orchestrator to surface URLs in the final report.
  List<HeapSnapshotUploadResult> get uploads =>
      List<HeapSnapshotUploadResult>.unmodifiable(_uploads);

  /// Schedule the periodic trigger poll. When the upload target is not
  /// configured, the watcher logs ONE "skipped — no container configured"
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
        podId: _podId,
        runId: _runId,
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
    _uploads.add(result);
    _emit(<String, Object?>{
      'ts': _clock().toIso8601String(),
      'metric': 'soak.heap_snapshot.uploaded',
      'object_key': result.objectKey,
      if (result.blobUri != null) 'blob_uri': result.blobUri,
      'size_bytes': result.sizeBytes,
      if (_podId != null) 'pod_id': _podId,
      if (_runId != null) 'run_id': _runId,
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
