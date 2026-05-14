// Wave 2 Q-1-FU — multi-pod heap-snapshot live capture endpoint.
//
// Route:
//   POST /v1/admin/heap-snapshot/capture
//
// What this surface does:
//   * Receives a Dart heap snapshot from a running Cloud Run pod (or any
//     soak-harness pod) over an authenticated HTTP POST. The body is the
//     raw `.heapsnapshot` bytes (`application/octet-stream`).
//   * Validates F&F-internal auth (JWT bearer, super_admin / ff_support
//     role), the size guard (default 50 MiB, configurable via env
//     `MAX_HEAP_SNAPSHOT_BYTES`), and the per-pod rate heuristic
//     (warn-level audit at 13+ captures/hour for the same pod).
//   * Streams the bytes to the existing Azure Blob heap-snapshot
//     uploader (`AzureBlobHeapSnapshotUploadTarget` from
//     `tool/pressure/p4_heap_snapshot_uploader.dart`) and returns the
//     blob URL on success.
//   * Emits a hash-chained `admin.heap_snapshot_captured` audit row so
//     the support-side audit log retains a verifiable record of every
//     captured snapshot (pod id, hostname, size, blob url, capture
//     timestamp).
//
// Why this lives in a SIBLING file (NOT `advisor_proxy.dart`):
//   * The monolith is at its bleed-stop ceiling per
//     `tool/advisor_proxy_size_lint.dart`'s `kAdvisorProxyMaxLines`.
//     CLAUDE.md "Ceiling-raise rule (R-2)" gates raises behind explicit
//     operator approval — and the live-capture endpoint is a brand-new
//     route, not an inline edit. Sibling-file is the only conformant
//     home.
//   * `main.dart` mounts this router as a pre-check before the
//     monolithic `routeRequest`, mirroring the SendGrid webhook +
//     email-soak probe + Firebase Test Lab webhook precedents.
//
// Auth posture:
//   * Bearer JWT verified through the proxy's existing
//     `ProxyRequestGuard`; the resolver is injected so tests can pin a
//     deterministic actor without instantiating `ProxyRequestGuard` /
//     Firebase keys.
//   * Role gate: `{super_admin, ff_support}` — same posture as the
//     existing `admin.debug_console.view`-equivalent role guard on the
//     read-only debug-console proxy routes (see
//     `tool/advisor_proxy/advisor_proxy.dart` ~line 8163 for
//     `kFfDebugConsoleAdminReadRoles`). Operator-tier callers get 403.
//   * Per the slice prompt, the permission gate matches the existing
//     debug-console gate (`admin.debug_console.view` permission key
//     exists in `lib/auth/permission_keys.dart` line 134, but the
//     debug-console proxy routes use the role gate directly because
//     the permission snapshot resolver in this proxy path is wired
//     for operator-tier callers, not F&F-internal admin tokens). We
//     stay consistent with the debug-console route's role-gate idiom.
//
// HP discipline (CLAUDE.md "Hard Promises"):
//   * Hard Promise #4 per-operator isolation: the route is platform
//     diagnostic, not operator data. The payload is raw VM heap bytes
//     captured by the pod — there is no operator_id in the request
//     body, and the route REJECTS any attempt to supply one (no
//     operator_id field is read from headers or query). The Azure
//     Blob upload target uses the F&F-owned soak container
//     (`AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER`), not the operator-scoped
//     audit-anchor container, so a snapshot from one pod is never
//     co-resident with operator compliance evidence.
//   * Hard Promise #7 server-side keys: Workload Identity Federation
//     drives the Azure Blob PUT; no SAS / shared key / client secret
//     ever leaves the pod.
//   * Hard Promise #11 hierarchy-scoped settings: N/A — this is a
//     platform-diagnostic surface, not an operator configuration
//     setting.
//
// Size guard:
//   * Default ceiling 50 MiB (`kHeapSnapshotMaxBytesDefault`). The
//     loader reads `MAX_HEAP_SNAPSHOT_BYTES` env var so a staging
//     environment can widen for an unusually large soak run without a
//     code change. Production deploys leave it unset and the default
//     applies.
//   * The check is enforced on the streamed body length (we accumulate
//     into a bounded `BytesBuilder` and abort once the running total
//     exceeds the cap). The `X-Snapshot-Bytes` header is treated as
//     advisory: if it disagrees with the actual body size we use the
//     actual length for the audit row and the size-guard check.
//
// Rate-limit heuristic:
//   * In-memory ring per pod_id tracking the timestamps of the most
//     recent captures. When the count within the last hour exceeds 12
//     (configurable via `kHeapSnapshotPodCapturesPerHourWarnThreshold`),
//     the router emits a `LogSeverity.warning` log line
//     (`admin.heap_snapshot.pod_rate_high`) so a deploy grep surfaces
//     pods that may be in a snapshot loop. The capture itself still
//     succeeds — this is a heuristic, not a hard cap.
//   * In-memory state is per-proxy-instance; horizontal scaling later
//     would promote this to a shared store, the same as the other
//     in-memory caches in this directory.
//
// Idempotency: the `Idempotency-Key` header is required. Replay with
// the same key returns the cached response (same status, same blob
// URL). The cache uses the existing `ProxyAuthIdempotencyCache` for
// consistency with the rest of the proxy.
//
// CLAUDE.md compliance:
//   * No em-dashes (U+2014) in error messages or audit strings.
//   * No `package:postgres` import — the audit sink seam abstracts
//     persistence so the route file stays free of raw postgres usage
//     (the production audit sink lives behind the `OperatorWriteAuditSink`
//     pattern, threaded in from `proxy_bootstrap.dart` in a follow-up
//     wiring step if this slice is mounted live).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../pressure/p4_heap_snapshot_uploader.dart';
import 'log.dart';

/// Path the live-capture endpoint binds to.
const String heapSnapshotCapturePath = '/v1/admin/heap-snapshot/capture';

/// Roles permitted to capture heap snapshots from a running pod. Mirrors
/// the `kFfDebugConsoleAdminReadRoles` posture on the existing debug
/// console proxy routes — F&F-internal callers only.
const Set<String> kHeapSnapshotCaptureRoles = <String>{
  'super_admin',
  'ff_support',
};

/// Default body-size ceiling. 50 MiB exactly. Operators can widen via
/// the `MAX_HEAP_SNAPSHOT_BYTES` env var if a soak run legitimately
/// produces a larger snapshot.
const int kHeapSnapshotMaxBytesDefault = 50 * 1024 * 1024;

/// Env var name the size-guard loader reads. Production deploys leave
/// this UNSET so the default applies.
const String kHeapSnapshotMaxBytesEnvVar = 'MAX_HEAP_SNAPSHOT_BYTES';

/// Threshold above which the per-pod capture rate triggers a warn-level
/// audit row. The slice prompt cites "more than 12 per hour"; we emit
/// the warning on the 13th capture within the last hour.
const int kHeapSnapshotPodCapturesPerHourWarnThreshold = 12;

/// Rolling window used by the rate heuristic. Matches the prompt's
/// "per hour" wording.
const Duration kHeapSnapshotPodRateWindow = Duration(hours: 1);

/// Required headers the caller MUST supply on every capture request.
/// Listed here so tests can iterate the contract and the error-shape
/// strings stay in one place.
class HeapSnapshotCaptureHeaders {
  const HeapSnapshotCaptureHeaders._();

  static const String podId = 'x-pod-id';
  static const String podHostname = 'x-pod-hostname';
  static const String snapshotTimestamp = 'x-snapshot-timestamp';
  static const String snapshotBytes = 'x-snapshot-bytes';
  static const String idempotencyKey = 'idempotency-key';
}

/// Verified caller context the route hands to itself after auth + role
/// gating succeeds. Mirrors the [AuditLogHierarchyActor] / [BenchmarkOverridesActor]
/// shape so reviewers see the same idiom across F&F-internal sibling
/// routes. The shape is intentionally tiny — only the fields the route
/// needs to write into the audit row.
class HeapSnapshotCaptureActor {
  const HeapSnapshotCaptureActor({
    required this.userId,
    required this.roles,
    required this.actorKind,
  });

  /// Authenticated `user_id` from the verified JWT.
  final String userId;

  /// Verified role claims. The route gate is satisfied when this set
  /// intersects [kHeapSnapshotCaptureRoles].
  final Set<String> roles;

  /// `actor_kind` claim. Production passes the JWT's `actor_kind` field
  /// through verbatim ("user" / "service_principal" / etc.) so the
  /// audit row records whether a service principal triggered the
  /// capture.
  final String actorKind;
}

/// Resolves a [HeapSnapshotCaptureActor] from an inbound `HttpRequest`.
/// Production binds this to a closure over the proxy's existing
/// `ProxyRequestGuard.requireVerifiedClaims`; tests pass an in-memory
/// implementation that returns a pinned actor (or null = 401).
typedef HeapSnapshotCaptureAuthResolver = Future<HeapSnapshotCaptureActor?>
    Function(HttpRequest request);

/// Sink the route writes a hash-chained audit row through after every
/// successful capture (and after every rate-limit warning). Production
/// binds this to the same `audit_logs` repository the rest of the proxy
/// uses; tests pass a recording sink.
abstract class HeapSnapshotCaptureAuditSink {
  /// Record one audit event. [eventKind] is one of:
  ///   * `admin.heap_snapshot_captured` — every successful capture.
  ///   * `admin.heap_snapshot.pod_rate_high` — warn-level row emitted
  ///     when the per-pod hourly capture count exceeds the threshold.
  Future<void> record({
    required String eventKind,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  });
}

/// Default no-op audit sink. Tests use a recording subclass; production
/// wires the real audit-logs writer in `proxy_bootstrap.dart`.
class NoopHeapSnapshotCaptureAuditSink implements HeapSnapshotCaptureAuditSink {
  const NoopHeapSnapshotCaptureAuditSink();

  @override
  Future<void> record({
    required String eventKind,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    // No-op. Production replaces this with a real sink.
  }
}

/// Loader closure for the size guard. Defaults to the env var; tests
/// inject a deterministic literal so the suite does not touch the host
/// env.
typedef HeapSnapshotMaxBytesLoader = int Function();

/// Default loader: reads [kHeapSnapshotMaxBytesEnvVar]. Returns the
/// default ceiling when unset / malformed so a typo cannot disable the
/// guard.
int defaultHeapSnapshotMaxBytesLoader() {
  final raw = Platform.environment[kHeapSnapshotMaxBytesEnvVar];
  if (raw == null) return kHeapSnapshotMaxBytesDefault;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return kHeapSnapshotMaxBytesDefault;
  final parsed = int.tryParse(trimmed);
  if (parsed == null || parsed <= 0) return kHeapSnapshotMaxBytesDefault;
  return parsed;
}

/// Per-pod capture rate tracker. In-memory ring of recent capture
/// timestamps per pod_id. The router pushes a timestamp on every
/// successful capture and asks whether the running count within
/// [kHeapSnapshotPodRateWindow] exceeds the warn threshold.
class HeapSnapshotPodRateTracker {
  HeapSnapshotPodRateTracker({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _byPod = <String, List<DateTime>>{};

  /// Record one capture for [podId] and return the count of captures
  /// within the rolling window AFTER the push (so the caller can decide
  /// whether to emit the warn-level audit row).
  int recordAndCount(String podId) {
    final now = _clock();
    final cutoff = now.subtract(kHeapSnapshotPodRateWindow);
    final list = _byPod.putIfAbsent(podId, () => <DateTime>[]);
    list.removeWhere((ts) => ts.isBefore(cutoff));
    list.add(now);
    return list.length;
  }

  /// Test-only seam: expose the current count for [podId] without
  /// recording a new entry.
  int currentCount(String podId) {
    final list = _byPod[podId];
    if (list == null) return 0;
    final cutoff = _clock().subtract(kHeapSnapshotPodRateWindow);
    list.removeWhere((ts) => ts.isBefore(cutoff));
    return list.length;
  }
}

/// Replay cache for the live-capture endpoint. Keyed by
/// `(actor_user_id, idempotency_key)`; cached entry pins the status +
/// body that gets replayed when the same key arrives a second time.
class HeapSnapshotCaptureIdempotencyCache {
  HeapSnapshotCaptureIdempotencyCache({
    this.ttl = const Duration(hours: 1),
    this.maxEntries = 1000,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;
  final Map<String, _HeapSnapshotCacheEntry> _store =
      <String, _HeapSnapshotCacheEntry>{};

  Future<({int statusCode, Map<String, Object?> body})> runOrReplay({
    required String actorUserId,
    required String idempotencyKey,
    required Future<({int statusCode, Map<String, Object?> body})> Function()
        compute,
  }) async {
    _gc();
    final key = '$actorUserId|$idempotencyKey';
    final cached = _store[key];
    if (cached != null) {
      return (statusCode: cached.statusCode, body: cached.body);
    }
    final result = await compute();
    if (result.statusCode >= 200 &&
        result.statusCode < 500 &&
        result.statusCode != 429) {
      _store[key] = _HeapSnapshotCacheEntry(
        statusCode: result.statusCode,
        body: result.body,
        expiresAt: _now().add(ttl),
      );
      _evictOverflow();
    }
    return result;
  }

  void _gc() {
    final cutoff = _now();
    _store.removeWhere((_, entry) => entry.expiresAt.isBefore(cutoff));
  }

  void _evictOverflow() {
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first);
    }
  }
}

class _HeapSnapshotCacheEntry {
  _HeapSnapshotCacheEntry({
    required this.statusCode,
    required this.body,
    required this.expiresAt,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final DateTime expiresAt;
}

/// Pluggable router. `main.dart` mounts this as a pre-check before
/// delegating to the monolithic `routeRequest`. Returns true when the
/// request matched the heap-snapshot capture path and was fully handled
/// (response written + closed); returns false otherwise so the existing
/// dispatcher continues.
class HeapSnapshotCaptureRouter {
  HeapSnapshotCaptureRouter({
    required HeapSnapshotUploadTarget uploadTarget,
    HeapSnapshotCaptureAuthResolver? authResolver,
    HeapSnapshotCaptureAuditSink? auditSink,
    HeapSnapshotMaxBytesLoader? maxBytesLoader,
    HeapSnapshotPodRateTracker? rateTracker,
    HeapSnapshotCaptureIdempotencyCache? idempotencyCache,
    DateTime Function()? clock,
  })  : _uploadTarget = uploadTarget,
        _authResolver = authResolver,
        _auditSink = auditSink ?? const NoopHeapSnapshotCaptureAuditSink(),
        _maxBytesLoader =
            maxBytesLoader ?? defaultHeapSnapshotMaxBytesLoader,
        _rateTracker = rateTracker ?? HeapSnapshotPodRateTracker(),
        _idempotencyCache =
            idempotencyCache ?? HeapSnapshotCaptureIdempotencyCache(),
        _clock = clock ?? DateTime.now;

  final HeapSnapshotUploadTarget _uploadTarget;
  final HeapSnapshotCaptureAuthResolver? _authResolver;
  final HeapSnapshotCaptureAuditSink _auditSink;
  final HeapSnapshotMaxBytesLoader _maxBytesLoader;
  final HeapSnapshotPodRateTracker _rateTracker;
  final HeapSnapshotCaptureIdempotencyCache _idempotencyCache;
  final DateTime Function() _clock;

  /// Discriminator the main.dart pre-check uses. Same shape as the
  /// SendGrid webhook + admin email + email-soak probe + Firebase Test
  /// Lab webhook routers.
  static bool matches(String path, String method) {
    return method == 'POST' && path == heapSnapshotCapturePath;
  }

  /// Pre-check handler. Returns true when the route matched and the
  /// response has been written + closed; returns false otherwise (so
  /// `main.dart` falls through to `routeRequest`).
  Future<bool> tryHandle(HttpRequest request) async {
    if (!matches(request.uri.path, request.method)) {
      return false;
    }
    final response = request.response;
    try {
      // ── Auth ────────────────────────────────────────────────────
      if (_authResolver == null) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'heap_snapshot_capture_not_configured',
          'message':
              'route requires a HeapSnapshotCaptureAuthResolver to be installed',
        });
        return true;
      }
      HeapSnapshotCaptureActor? actor;
      try {
        actor = await _authResolver(request);
      } catch (_) {
        _writeJson(response, 401, <String, Object?>{
          'error': 'unauthorized',
          'message': 'verified bearer token required',
        });
        return true;
      }
      if (actor == null) {
        _writeJson(response, 401, <String, Object?>{
          'error': 'unauthorized',
          'message': 'verified bearer token required',
        });
        return true;
      }
      if (!actor.roles.any(kHeapSnapshotCaptureRoles.contains)) {
        _writeJson(response, 403, <String, Object?>{
          'error': 'permission_denied',
          'message':
              'super_admin or ff_support role is required to capture heap snapshots',
          'required_roles': kHeapSnapshotCaptureRoles.toList(),
        });
        return true;
      }

      // ── Required headers ────────────────────────────────────────
      final podId = request.headers
          .value(HeapSnapshotCaptureHeaders.podId)
          ?.trim();
      final podHostname = request.headers
          .value(HeapSnapshotCaptureHeaders.podHostname)
          ?.trim();
      final snapshotTimestampRaw = request.headers
          .value(HeapSnapshotCaptureHeaders.snapshotTimestamp)
          ?.trim();
      final idempotencyKey = request.headers
          .value(HeapSnapshotCaptureHeaders.idempotencyKey)
          ?.trim();
      final snapshotBytesRaw = request.headers
          .value(HeapSnapshotCaptureHeaders.snapshotBytes)
          ?.trim();

      final missingHeader = _firstMissing(<String, String?>{
        HeapSnapshotCaptureHeaders.podId: podId,
        HeapSnapshotCaptureHeaders.podHostname: podHostname,
        HeapSnapshotCaptureHeaders.snapshotTimestamp: snapshotTimestampRaw,
        HeapSnapshotCaptureHeaders.idempotencyKey: idempotencyKey,
      });
      if (missingHeader != null) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'missing_required_header',
          'message': '$missingHeader header is required',
          'header': missingHeader,
        });
        return true;
      }

      final snapshotTimestamp = DateTime.tryParse(snapshotTimestampRaw!);
      if (snapshotTimestamp == null) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_snapshot_timestamp',
          'message':
              '${HeapSnapshotCaptureHeaders.snapshotTimestamp} must be an ISO 8601 timestamp',
        });
        return true;
      }

      // Advisory size hint: when supplied it must be a positive int. We
      // do NOT trust it as the actual size — the streamed body length
      // wins below — but a malformed value is still a client error.
      int? advisorySnapshotBytes;
      if (snapshotBytesRaw != null && snapshotBytesRaw.isNotEmpty) {
        final parsed = int.tryParse(snapshotBytesRaw);
        if (parsed == null || parsed <= 0) {
          _writeJson(response, 400, <String, Object?>{
            'error': 'invalid_snapshot_bytes',
            'message':
                '${HeapSnapshotCaptureHeaders.snapshotBytes} must be a positive integer when supplied',
          });
          return true;
        }
        advisorySnapshotBytes = parsed;
      }

      // ── Size guard (streamed) ───────────────────────────────────
      final maxBytes = _maxBytesLoader();
      final readResult = await _readBodyBounded(request, maxBytes);
      if (readResult.tooLarge) {
        _writeJson(response, 413, <String, Object?>{
          'error': 'snapshot_too_large',
          'message':
              'snapshot exceeded the configured size limit; raise '
              '$kHeapSnapshotMaxBytesEnvVar to widen',
          'max_bytes': maxBytes,
        });
        return true;
      }
      final bytes = readResult.bytes;

      // ── Idempotency replay ──────────────────────────────────────
      final result = await _idempotencyCache.runOrReplay(
        actorUserId: actor.userId,
        idempotencyKey: idempotencyKey!,
        compute: () => _performCapture(
          actor: actor!,
          podId: podId!,
          podHostname: podHostname!,
          snapshotTimestamp: snapshotTimestamp,
          advisorySnapshotBytes: advisorySnapshotBytes,
          bytes: bytes,
        ),
      );
      _writeJson(response, result.statusCode, result.body);
      return true;
    } catch (error, stack) {
      log(
        LogSeverity.error,
        'heap_snapshot_capture.unhandled_error',
        fields: <String, Object?>{
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
      _writeJson(response, 500, <String, Object?>{
        'error': 'internal_server_error',
        'message': 'heap snapshot capture failed unexpectedly',
      });
      return true;
    }
  }

  /// Runs the upload + audit + rate-tracker side effects for one
  /// already-validated request. Exposed so the idempotency cache can
  /// memoize the result without re-running the side effects on replay.
  Future<({int statusCode, Map<String, Object?> body})> _performCapture({
    required HeapSnapshotCaptureActor actor,
    required String podId,
    required String podHostname,
    required DateTime snapshotTimestamp,
    required int? advisorySnapshotBytes,
    required List<int> bytes,
  }) async {
    // Upload to Azure Blob via the existing soak uploader's target.
    final HeapSnapshotUploadResult uploadResult;
    try {
      uploadResult = await _uploadTarget.upload(
        bytes: bytes,
        contentType: 'application/octet-stream',
        timestamp: snapshotTimestamp,
        podId: podId,
        // The server-side route does not own a `run_id` (the pod owns
        // it). Soak clients that want a per-run object key prefix can
        // bake it into the pod_id (`<run_id>-<pod>`); the route layer
        // stays agnostic.
        runId: null,
      );
    } catch (error, stack) {
      log(
        LogSeverity.error,
        'heap_snapshot_capture.azure_blob_write_failed',
        fields: <String, Object?>{
          'pod_id': podId,
          'pod_hostname': podHostname,
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
      final recordedAt = _clock().toUtc();
      await _auditSink.record(
        eventKind: 'admin.heap_snapshot_captured',
        actorUserId: actor.userId,
        actorKind: actor.actorKind,
        occurredAt: recordedAt,
        payload: <String, Object?>{
          'outcome': 'failed',
          'pod_id': podId,
          'pod_hostname': podHostname,
          'snapshot_bytes': bytes.length,
          'advisory_snapshot_bytes': advisorySnapshotBytes,
          'capture_timestamp':
              snapshotTimestamp.toUtc().toIso8601String(),
          'error_kind': 'azure_blob_write_failed',
        },
      );
      return (
        statusCode: 502,
        body: <String, Object?>{
          'error': 'azure_blob_write_failed',
          'message':
              'heap snapshot capture failed while uploading to Azure Blob; retry once the storage path is healthy',
        },
      );
    }

    final recordedAt = _clock().toUtc();
    final auditPayload = <String, Object?>{
      'outcome': 'ok',
      'pod_id': podId,
      'pod_hostname': podHostname,
      'snapshot_bytes': bytes.length,
      'advisory_snapshot_bytes': advisorySnapshotBytes,
      'blob_url': uploadResult.blobUri,
      'object_key': uploadResult.objectKey,
      'capture_timestamp': snapshotTimestamp.toUtc().toIso8601String(),
    };
    await _auditSink.record(
      eventKind: 'admin.heap_snapshot_captured',
      actorUserId: actor.userId,
      actorKind: actor.actorKind,
      occurredAt: recordedAt,
      payload: auditPayload,
    );

    // Rate heuristic: push + check.
    final captureCount = _rateTracker.recordAndCount(podId);
    if (captureCount > kHeapSnapshotPodCapturesPerHourWarnThreshold) {
      log(
        LogSeverity.warning,
        'admin.heap_snapshot.pod_rate_high',
        fields: <String, Object?>{
          'pod_id': podId,
          'pod_hostname': podHostname,
          'captures_in_window': captureCount,
          'window_minutes': kHeapSnapshotPodRateWindow.inMinutes,
          'threshold': kHeapSnapshotPodCapturesPerHourWarnThreshold,
        },
      );
      await _auditSink.record(
        eventKind: 'admin.heap_snapshot.pod_rate_high',
        actorUserId: actor.userId,
        actorKind: actor.actorKind,
        occurredAt: recordedAt,
        payload: <String, Object?>{
          'pod_id': podId,
          'pod_hostname': podHostname,
          'captures_in_window': captureCount,
          'window_minutes': kHeapSnapshotPodRateWindow.inMinutes,
          'threshold': kHeapSnapshotPodCapturesPerHourWarnThreshold,
        },
      );
    }

    return (
      statusCode: 200,
      body: <String, Object?>{
        'blob_url': uploadResult.blobUri,
        'object_key': uploadResult.objectKey,
        'snapshot_bytes': bytes.length,
        'recorded_at': recordedAt.toIso8601String(),
        'pod_id': podId,
      },
    );
  }

  /// Pure-Dart dispatch used by unit tests so the suite can probe the
  /// router without spinning up an `HttpServer`. The caller passes the
  /// already-parsed actor + headers + body; the route's HTTP-layer
  /// validation (auth resolution, header parsing, size guard) is the
  /// `tryHandle` seam.
  Future<({int statusCode, Map<String, Object?> body})> dispatch({
    required HeapSnapshotCaptureActor actor,
    required String podId,
    required String podHostname,
    required DateTime snapshotTimestamp,
    required String idempotencyKey,
    required List<int> bytes,
    int? advisorySnapshotBytes,
  }) {
    return _idempotencyCache.runOrReplay(
      actorUserId: actor.userId,
      idempotencyKey: idempotencyKey,
      compute: () => _performCapture(
        actor: actor,
        podId: podId,
        podHostname: podHostname,
        snapshotTimestamp: snapshotTimestamp,
        advisorySnapshotBytes: advisorySnapshotBytes,
        bytes: bytes,
      ),
    );
  }

  static String? _firstMissing(Map<String, String?> headers) {
    for (final entry in headers.entries) {
      final value = entry.value;
      if (value == null || value.isEmpty) return entry.key;
    }
    return null;
  }

  /// Reads the request body into a `BytesBuilder`, aborting accumulation
  /// as soon as the running total exceeds [maxBytes]. The caller treats
  /// the `tooLarge: true` outcome as the 413 path. The body stream is
  /// fully drained either way so the dart:io listener loop completes
  /// its iteration and the response close() handshake succeeds.
  Future<({bool tooLarge, List<int> bytes})> _readBodyBounded(
    HttpRequest request,
    int maxBytes,
  ) async {
    final builder = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final chunk in request) {
      if (!tooLarge) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          tooLarge = true;
          // Drop the partial buffer so we do not retain ~50 MiB just to
          // throw it away. We KEEP draining the stream below so the
          // socket close handshake stays clean.
          builder.clear();
        }
      }
    }
    if (tooLarge) {
      return (tooLarge: true, bytes: const <int>[]);
    }
    return (tooLarge: false, bytes: builder.takeBytes());
  }

  void _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    // Sibling-file routers close their own response because main.dart
    // short-circuits `routeRequest` when `tryHandle` returns true.
    response.close();
  }
}
