// Wave 2 Q-2c — Firebase Test Lab matrix-completion webhook receiver.
//
// Route:
//   POST /v1/test-lab/webhook/matrix-complete
//
// What this surface does:
//   * Receives a JSON callback from a Firebase Test Lab matrix-
//     completion notifier (gcloud's built-in Pub/Sub fanout, or the
//     soak orchestrator emitting from its own polling loop).
//   * Validates the `X-Firebase-Test-Lab-Webhook-Secret` shared
//     secret against the env var `FIREBASE_TEST_LAB_WEBHOOK_SECRET`.
//     When the env var is unset on the proxy, the route returns
//     `503 firebase_test_lab_webhook_disabled` so production
//     deploys are inert by default.
//   * Decodes the JSON body, requires `matrix_id`, `state`,
//     `outcome` — other fields are optional pass-through.
//   * Records the matrix outcome in an in-memory store keyed by
//     `matrix_id`. The store survives the process lifetime, not
//     restarts. A future slice can swap a SQLite-backed store if
//     soak runs need persistence across proxy restarts.
//
// Why a SIBLING file (NOT `advisor_proxy.dart`):
//   * The monolith is at its bleed-stop ceiling per
//     `tool/advisor_proxy_size_lint.dart`'s `kAdvisorProxyMaxLines`.
//     CLAUDE.md "Ceiling-raise rule (R-2)" gates raises behind
//     explicit operator approval.
//   * Slice mounts this router as a pre-check before `routeRequest`
//     in `main.dart`, mirroring the SendGrid webhook + email-soak
//     probe patterns.
//
// Auth posture:
//   * No operator-facing permission key. Test Lab is an external
//     server-to-server caller (or the local soak orchestrator); no
//     Firebase JWT is in scope. The route is auth-gated by the
//     shared secret ONLY.
//   * Constant-time comparison on the secret header so a probing
//     attacker cannot timing-channel the secret byte-by-byte.
//
// CLAUDE.md compliance:
//   * Hard Promise #4 — per-operator isolation: the webhook payload
//     carries a `matrix_id` + outcome; there is NO operator scope
//     in flight. The receiver is platform-internal — Test Lab
//     matrices are scoped by the Test Lab project, not by the
//     application's operator hierarchy. The in-memory store is keyed
//     only by `matrix_id`, so two operators driving their own soaks
//     against the same proxy would NOT see each other's matrices
//     unless they both already had the shared secret AND the same
//     matrix id, which is a non-issue in practice (matrix ids are
//     cloud-assigned UUIDs).
//   * Hard Promise #7 — server-side secrets: the webhook secret is
//     a server-side env var; clients never see it. The local soak
//     orchestrator consumes it from its own env, never from a
//     request.
//   * No `package:postgres` import — the in-memory store has no
//     persistence seam to Postgres.
//
// Idempotency: replays with the same `matrix_id` overwrite the prior
// entry. Operators can re-POST a matrix outcome after a fix without
// the receiver complaining; the most recent outcome wins.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'log.dart';

/// Path the matrix-completion webhook binds to.
const String firebaseTestLabMatrixCompleteWebhookPath =
    '/v1/test-lab/webhook/matrix-complete';

/// Env var the proxy reads the shared bearer secret from. Production
/// leaves this UNSET so the route returns 503 inert. Test / staging
/// deploys wire a long random secret via Cloud Run env config or the
/// equivalent secret manager binding.
const String kFirebaseTestLabWebhookSecretEnvVar =
    'FIREBASE_TEST_LAB_WEBHOOK_SECRET';

/// Header the webhook caller supplies the shared secret in.
const String kFirebaseTestLabWebhookSecretHeader =
    'x-firebase-test-lab-webhook-secret';

/// Maximum raw-body byte length we admit. Test Lab matrix-completion
/// payloads are tiny (a UUID + a state string + a results URL); 16
/// KB is a comfortable upper bound that still rejects a malicious
/// 100 MB body before any parsing.
const int kFirebaseTestLabMaxBodyBytes = 16 * 1024;

/// Loader closure for the shared secret. Defaults to the env var;
/// tests inject a deterministic literal so the suite does not touch
/// the host env.
typedef FirebaseTestLabWebhookSecretLoader = String? Function();

/// Default loader — reads [kFirebaseTestLabWebhookSecretEnvVar].
/// Returns null when unset / empty so the route returns 503 inert.
String? defaultFirebaseTestLabWebhookSecretLoader() {
  final raw = Platform.environment[kFirebaseTestLabWebhookSecretEnvVar];
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

/// Recorded matrix outcome the webhook persists into the store.
/// Exposed so the soak orchestrator (and any future poller) can read
/// the most recent outcome by matrix id.
class FirebaseTestLabMatrixOutcomeRecord {
  const FirebaseTestLabMatrixOutcomeRecord({
    required this.matrixId,
    required this.state,
    required this.outcome,
    required this.recordedAt,
    this.projectId,
    this.resultsUrl,
    this.completedAt,
    this.extra,
  });

  /// Cloud-assigned UUID identifying this matrix run.
  final String matrixId;

  /// Test Lab `state` field. Documented values include `PENDING`,
  /// `RUNNING`, `FINISHED`, `ERROR`, `CANCELLED`. We record the
  /// string verbatim — no enum mapping — so a future Test Lab
  /// schema change does not silently drop entries.
  final String state;

  /// Test Lab `outcome` field. Documented values include `success`,
  /// `failure`, `inconclusive`, `skipped`. Recorded verbatim.
  final String outcome;

  /// UTC instant the proxy received the callback. Used by the
  /// orchestrator's "matrix recorded at" log line.
  final DateTime recordedAt;

  /// Optional Test Lab project id. Surfaces in the JSONL report.
  final String? projectId;

  /// Optional console URL the operator can click to see per-device
  /// detail. Surfaces in the JSONL report.
  final String? resultsUrl;

  /// Optional UTC timestamp Test Lab reports as the matrix
  /// completion instant (may lag [recordedAt] by a few seconds).
  final DateTime? completedAt;

  /// Pass-through map for any additional fields the caller supplied.
  /// We do not enforce a closed schema so a future Test Lab field
  /// addition does not require a code change here.
  final Map<String, Object?>? extra;

  Map<String, Object?> toJson() => <String, Object?>{
        'matrix_id': matrixId,
        'state': state,
        'outcome': outcome,
        'recorded_at': recordedAt.toUtc().toIso8601String(),
        if (projectId != null) 'project_id': projectId,
        if (resultsUrl != null) 'results_url': resultsUrl,
        if (completedAt != null)
          'completed_at': completedAt!.toUtc().toIso8601String(),
        if (extra != null && extra!.isNotEmpty) 'extra': extra,
      };
}

/// Abstract store seam. The default is an in-memory map; a future
/// slice can swap a SQLite-backed store without touching the route
/// handler.
abstract class FirebaseTestLabMatrixOutcomeStore {
  /// Record (or overwrite) the outcome for [record.matrixId].
  Future<void> record(FirebaseTestLabMatrixOutcomeRecord record);

  /// Look up the most recent outcome for [matrixId], or null when
  /// no entry has been recorded.
  Future<FirebaseTestLabMatrixOutcomeRecord?> findByMatrixId(String matrixId);

  /// Snapshot of all currently-recorded outcomes. Exposed so tests
  /// can assert without poking the store internals.
  Future<List<FirebaseTestLabMatrixOutcomeRecord>> snapshot();
}

/// Default in-memory implementation. The map survives the process
/// lifetime, not restarts. Documented choice — soak runs that span
/// a proxy restart are out of scope for the V1 receiver. Swap a
/// SQLite-backed store in a future slice if needed.
class InMemoryFirebaseTestLabMatrixOutcomeStore
    implements FirebaseTestLabMatrixOutcomeStore {
  InMemoryFirebaseTestLabMatrixOutcomeStore();

  final Map<String, FirebaseTestLabMatrixOutcomeRecord> _byId =
      <String, FirebaseTestLabMatrixOutcomeRecord>{};

  @override
  Future<void> record(FirebaseTestLabMatrixOutcomeRecord record) async {
    _byId[record.matrixId] = record;
  }

  @override
  Future<FirebaseTestLabMatrixOutcomeRecord?> findByMatrixId(
    String matrixId,
  ) async {
    return _byId[matrixId];
  }

  @override
  Future<List<FirebaseTestLabMatrixOutcomeRecord>> snapshot() async {
    return List<FirebaseTestLabMatrixOutcomeRecord>.unmodifiable(
      _byId.values,
    );
  }
}

/// Router for the matrix-completion webhook.
///
/// Production wiring (`proxy_bootstrap.dart`) constructs one of these
/// with the default in-memory store, the default env-var secret
/// loader, and a `DateTime.now` clock. `main.dart` mounts the router
/// as a pre-check in the per-request IIFE so the monolithic
/// dispatcher never sees this URL.
class FirebaseTestLabWebhookRouter {
  FirebaseTestLabWebhookRouter({
    FirebaseTestLabMatrixOutcomeStore? store,
    FirebaseTestLabWebhookSecretLoader? secretLoader,
    DateTime Function()? clock,
  })  : _store = store ?? InMemoryFirebaseTestLabMatrixOutcomeStore(),
        _secretLoader =
            secretLoader ?? defaultFirebaseTestLabWebhookSecretLoader,
        _clock = clock ?? DateTime.now;

  final FirebaseTestLabMatrixOutcomeStore _store;
  final FirebaseTestLabWebhookSecretLoader _secretLoader;
  final DateTime Function() _clock;

  /// Expose the store so the soak orchestrator + tests can read
  /// outcomes back without re-routing through HTTP.
  FirebaseTestLabMatrixOutcomeStore get store => _store;

  /// Returns true when [path] / [method] matches the receiver route.
  /// Mirrors the discriminator the other proxy routers expose so the
  /// main.dart pre-check is uniform.
  static bool matches(String path, String method) {
    return method == 'POST' && path == firebaseTestLabMatrixCompleteWebhookPath;
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
      final secret = _secretLoader();
      if (secret == null || secret.isEmpty) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'firebase_test_lab_webhook_disabled',
          'message':
              '$kFirebaseTestLabWebhookSecretEnvVar is unset on this proxy. '
              'The Firebase Test Lab webhook is intentionally inert in '
              'production deploys.',
        });
        return true;
      }
      final supplied =
          request.headers.value(kFirebaseTestLabWebhookSecretHeader);
      if (supplied == null || !_constantTimeEquals(supplied.trim(), secret)) {
        _writeJson(response, 401, <String, Object?>{
          'error': 'bad_secret',
          'message':
              'request is missing a valid Firebase Test Lab webhook '
              'shared secret.',
        });
        return true;
      }

      final bodyBytes = await _readBody(request);
      if (bodyBytes.length > kFirebaseTestLabMaxBodyBytes) {
        _writeJson(response, 413, <String, Object?>{
          'error': 'body_too_large',
          'message':
              'request body exceeded the Firebase Test Lab webhook '
              'accept limit.',
        });
        return true;
      }
      final dispatchResult = await dispatch(bodyBytes: bodyBytes);
      if (dispatchResult.body == null) {
        response.statusCode = dispatchResult.statusCode;
      } else {
        _writeJson(response, dispatchResult.statusCode, dispatchResult.body!);
      }
      return true;
    } catch (error, stack) {
      log(
        LogSeverity.error,
        'firebase_test_lab_webhook.unhandled_error',
        fields: <String, Object?>{
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
      _writeJson(response, 500, <String, Object?>{
        'error': 'internal_server_error',
        'message':
            'Firebase Test Lab webhook failed to record the matrix outcome.',
      });
      return true;
    }
  }

  /// Pure-Dart dispatch used by unit tests so the suite can probe the
  /// router without spinning up an `HttpServer`. Skips the secret
  /// check; callers test that separately via [tryHandle].
  Future<({int statusCode, Map<String, Object?>? body})> dispatch({
    required List<int> bodyBytes,
  }) async {
    if (bodyBytes.length > kFirebaseTestLabMaxBodyBytes) {
      return (
        statusCode: 413,
        body: <String, Object?>{
          'error': 'body_too_large',
          'message':
              'request body exceeded the Firebase Test Lab webhook '
              'accept limit.',
        },
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bodyBytes));
    } on FormatException {
      return (
        statusCode: 400,
        body: <String, Object?>{
          'error': 'malformed_json',
          'message': 'request body is not valid JSON.',
        },
      );
    }
    if (decoded is! Map) {
      return (
        statusCode: 400,
        body: <String, Object?>{
          'error': 'malformed_json',
          'message':
              'request body must be a JSON object describing the matrix '
              'outcome.',
        },
      );
    }
    final payload = decoded.cast<String, Object?>();
    final matrixId = _requireString(payload, 'matrix_id');
    final state = _requireString(payload, 'state');
    final outcome = _requireString(payload, 'outcome');
    if (matrixId.error != null) return matrixId.error!;
    if (state.error != null) return state.error!;
    if (outcome.error != null) return outcome.error!;

    final completedAtRaw = payload['completed_at'];
    DateTime? completedAt;
    if (completedAtRaw is String && completedAtRaw.isNotEmpty) {
      completedAt = DateTime.tryParse(completedAtRaw);
      if (completedAt == null) {
        return (
          statusCode: 400,
          body: <String, Object?>{
            'error': 'malformed_timestamp',
            'message':
                'completed_at must be an RFC3339 timestamp string when '
                'supplied.',
          },
        );
      }
    }

    final extra = <String, Object?>{};
    for (final entry in payload.entries) {
      const reserved = <String>{
        'matrix_id',
        'state',
        'outcome',
        'project_id',
        'results_url',
        'completed_at',
      };
      if (!reserved.contains(entry.key)) {
        extra[entry.key] = entry.value;
      }
    }
    final record = FirebaseTestLabMatrixOutcomeRecord(
      matrixId: matrixId.value!,
      state: state.value!,
      outcome: outcome.value!,
      recordedAt: _clock().toUtc(),
      projectId: _optionalString(payload, 'project_id'),
      resultsUrl: _optionalString(payload, 'results_url'),
      completedAt: completedAt,
      extra: extra.isEmpty ? null : extra,
    );
    await _store.record(record);
    log(
      LogSeverity.info,
      'firebase_test_lab_webhook.matrix_recorded',
      fields: <String, Object?>{
        'matrix_id': record.matrixId,
        'state': record.state,
        'outcome': record.outcome,
        'project_id': record.projectId,
      },
    );
    return (statusCode: 204, body: null);
  }

  static bool _constantTimeEquals(String supplied, String expected) {
    if (supplied.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= supplied.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  static _RequiredStringResult _requireString(
    Map<String, Object?> payload,
    String field,
  ) {
    final value = payload[field];
    if (value is! String || value.trim().isEmpty) {
      return _RequiredStringResult.error(
        statusCode: 400,
        body: <String, Object?>{
          'error': 'missing_field',
          'message':
              '$field must be a non-empty string in the webhook payload.',
          'field': field,
        },
      );
    }
    return _RequiredStringResult.ok(value);
  }

  static String? _optionalString(Map<String, Object?> payload, String field) {
    final value = payload[field];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _writeJson(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }
}

/// Internal helper carrying either a required-string success value or
/// the ({statusCode, body}) tuple the caller writes back on failure.
class _RequiredStringResult {
  const _RequiredStringResult.ok(this.value) : error = null;
  const _RequiredStringResult.error({
    required int statusCode,
    required Map<String, Object?> body,
  })  : value = null,
        error = (statusCode: statusCode, body: body);

  final String? value;
  final ({int statusCode, Map<String, Object?> body})? error;
}
