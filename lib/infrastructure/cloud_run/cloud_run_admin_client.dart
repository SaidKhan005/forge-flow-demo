// Forge & Flow — Cloud Run Admin client.
//
// Phase 9 / 11A KMS-rotation seam. Server-side only. Used by the
// rotation handler in the advisor proxy to force a Cloud Run revision
// after a Secret Manager version is created. The label-based PATCH is
// intentional: changing `template.labels` is the lightest possible
// no-op change that still triggers a new revision, so all running
// instances restart and pick up the latest secret version on next
// boot.
//
// `forceNewRevision` returns the long-running operation name reported
// by Cloud Run (e.g. `projects/<P>/locations/<R>/operations/<op-id>`)
// — NOT the new revision name, which Cloud Run assigns asynchronously
// after the operation completes. The rotation audit row records the
// operation name so an operator can correlate via
// `gcloud run operations describe <op>` (and from there list the
// revisions the operation spawned). Surfacing a synthetic / projected
// revision name would risk recording a value that doesn't actually
// exist in Cloud Run.
//
// Auth follows the same pattern as
// `lib/services/auth/firebase_admin_auth_client.dart`: an injected
// [OAuthAccessTokenProvider] (production: metadata server; tests:
// fake). Errors NEVER include the access token or Authorization
// header.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/auth/firebase_admin_auth_client.dart';

/// Cloud Run Admin client contract. The launch product only needs
/// "force a new revision" — a full Cloud Run management surface is
/// out of scope.
abstract class CloudRunAdminClient {
  /// Force a new Cloud Run revision (same config, new revision-suffix)
  /// so all running instances restart and pick up the latest Secret
  /// Manager version. Returns the long-running operation name Cloud
  /// Run reports for the PATCH (e.g.
  /// `projects/<P>/locations/<R>/operations/<op-id>`). The actual
  /// revision name is assigned asynchronously after the operation
  /// completes; an operator can resolve it via
  /// `gcloud run operations describe <op-name>`.
  ///
  /// [reason] is a short string included in a label on the new
  /// revision so audits can correlate the restart with what triggered
  /// it (e.g. `kms_rotation:anthropic:<credential_id>`).
  Future<String> forceNewRevision({required String reason});
}

/// Error thrown by [HttpCloudRunAdminClient]. Never includes the
/// bearer token or any sensitive request header.
class CloudRunAdminError implements Exception {
  CloudRunAdminError({required this.message, required this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'CloudRunAdminError($statusCode): $message';
}

/// Production implementation: PATCHes the Cloud Run service via the
/// Cloud Run Admin API v2. Changing `template.labels` is enough to
/// trigger a new revision.
class HttpCloudRunAdminClient implements CloudRunAdminClient {
  HttpCloudRunAdminClient({
    required String projectId,
    required String region,
    required String serviceName,
    required OAuthAccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    String Function()? rotationIdGenerator,
  }) : _projectId = projectId,
       _region = region,
       _serviceName = serviceName,
       _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _timeout = timeout,
       _rotationIdGenerator = rotationIdGenerator ?? _defaultRotationId;

  final String _projectId;
  final String _region;
  final String _serviceName;
  final OAuthAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;
  final String Function() _rotationIdGenerator;

  static String _defaultRotationId() {
    // Cloud Run label values must match `[a-z0-9_-]{0,63}`. ms
    // timestamps trivially satisfy that (digits only). UUIDs would
    // need lower-casing + `-` already fits, but a ms timestamp is
    // simpler and monotonic per host clock.
    return DateTime.now().toUtc().millisecondsSinceEpoch.toString();
  }

  /// Sanitize an arbitrary string for use as a Cloud Run label value.
  /// Cloud Run allows `[a-z0-9_-]` up to 63 chars.
  static String _sanitizeLabelValue(String raw) {
    final lower = raw.toLowerCase();
    final buf = StringBuffer();
    for (final code in lower.codeUnits) {
      final isLowerAlpha = code >= 0x61 && code <= 0x7a; // a-z
      final isDigit = code >= 0x30 && code <= 0x39; // 0-9
      final isAllowedPunct = code == 0x5f || code == 0x2d; // _ -
      if (isLowerAlpha || isDigit || isAllowedPunct) {
        buf.writeCharCode(code);
      } else {
        buf.write('-');
      }
    }
    final sanitized = buf.toString();
    if (sanitized.length <= 63) return sanitized;
    return sanitized.substring(0, 63);
  }

  @override
  Future<String> forceNewRevision({required String reason}) async {
    final rotationId = _rotationIdGenerator();
    final sanitizedReason = _sanitizeLabelValue(reason);

    final uri = Uri.https(
      'run.googleapis.com',
      '/v2/projects/$_projectId/locations/$_region/services/$_serviceName',
      <String, String>{'updateMask': 'template.labels'},
    );

    final token = await _accessTokenProvider.accessToken();
    final body = jsonEncode(<String, Object?>{
      'template': <String, Object?>{
        'labels': <String, String>{
          'forge-flow-rotation-id': rotationId,
          'forge-flow-rotation-reason': sanitizedReason,
        },
      },
    });

    http.Response response;
    try {
      response = await _httpClient
          .patch(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: body,
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw CloudRunAdminError(
        message: 'cloud_run_patch_timeout',
        statusCode: null,
      );
    }

    if (response.statusCode != 200) {
      throw CloudRunAdminError(
        message: _decodeErrorMessage(response.body) ?? 'request_failed',
        statusCode: response.statusCode,
      );
    }

    // PATCH returns a long-running operation. Parse the `name` field
    // and return it verbatim — that's the truthful correlation value
    // for the rotation audit row. The actual revision name is
    // assigned asynchronously after the operation completes; an
    // operator resolves it via `gcloud run operations describe`.
    final operationName = _extractOperationName(response.body);
    if (operationName == null) {
      throw CloudRunAdminError(
        message: 'cloud_run_patch_response_missing_operation_name',
        statusCode: response.statusCode,
      );
    }
    return operationName;
  }

  /// Extract the long-running operation `name` from a successful
  /// Cloud Run Admin v2 PATCH response. Returns null when the body
  /// is missing or malformed.
  String? _extractOperationName(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final name = decoded['name'];
      if (name is! String || name.isEmpty) return null;
      return name;
    } catch (_) {
      return null;
    }
  }

  String? _decodeErrorMessage(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (decoded['message'] is String) {
          return decoded['message'] as String;
        }
      }
    } catch (_) {
      // Fall through to raw body.
    }
    return raw;
  }
}

/// No-op implementation. Used by:
///  - tests that exercise the rotation handler without HTTP, and
///  - lanes that don't need a Cloud Run restart (e.g. `azure_db`),
///    where the Postgres connection pool will pick up the rotated
///    secret on the next reconnect.
class NoOpCloudRunAdminClient implements CloudRunAdminClient {
  const NoOpCloudRunAdminClient();

  @override
  Future<String> forceNewRevision({required String reason}) async {
    return 'no-op-cloud-run:$reason';
  }
}
