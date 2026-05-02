// Phase 11A.4 — Real GCP Secret Manager KMS provider.
//
// Server-side only. Implements [KmsProvider] against Google Cloud
// Secret Manager's REST API. The advisor proxy bootstrap binds this
// for any lane whose `kms_real_provider_<kind>_enabled` feature flag
// is ON; lanes whose flag is OFF still run the in-memory
// [KmsStubProvider]. Both providers share the same contract so the
// admin gateway code path stays identical — only the binding inside
// [KmsLaneRouter] changes.
//
// This file lives under `lib/infrastructure/kms/` so the abstract
// `KmsProvider` contract can be reused, but the class is only ever
// instantiated from `tool/advisor_proxy/proxy_bootstrap.dart`. Hard
// Promise #7 (F&F holds all provider keys server-side) is preserved
// because the OAuth access token used here is sourced from the
// metadata server on Cloud Run; the client app never holds these
// credentials.
//
// Failing-closed posture: plaintext is never written to logs, never
// embedded in thrown exceptions, never echoed in error strings. On
// any non-success status the upstream response body is surfaced for
// telemetry, but the [plaintext] argument is excluded from every
// error path.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/auth/firebase_admin_auth_client.dart'
    show OAuthAccessTokenProvider;
import 'kms_provider.dart';
import 'kms_stub_provider.dart' show maskCredentialForDisplay;

/// Hostname for the Secret Manager REST API. Hardcoded because it is
/// fixed across all GCP regions; the regional routing happens at the
/// load-balancer layer behind this hostname.
const String _secretManagerHost = 'secretmanager.googleapis.com';

/// Real KMS provider that persists rotated secrets in Google Cloud
/// Secret Manager. See file header for the failing-closed contract.
class GcpSecretManagerKmsProvider implements KmsProvider {
  /// Prefix that every pointer this provider produces starts with. The
  /// rotation handler in `proxy_bootstrap.dart` gates the Cloud Run
  /// revision restart on this prefix: a [kRuntimeReadKeyKinds] rotation
  /// only restarts Cloud Run when the persisted pointer actually came
  /// from Secret Manager. This prevents the
  /// `flag-OFF + GCP-wired + runtime-read-lane` combo from PATCHing
  /// Cloud Run for a write that never actually landed in Secret
  /// Manager (the lane router routed to the stub, returning
  /// `kms://stub/<uuid>`).
  static const String pointerPrefix = 'kms://gcp-secret-manager/';

  GcpSecretManagerKmsProvider({
    required this.projectId,
    required OAuthAccessTokenProvider accessTokenProvider,
    this.secretNamePrefix = 'forge-flow',
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 10),
  }) : _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client();

  /// GCP project the secrets live in. Threaded into every request URL.
  final String projectId;

  /// Prefix prepended to every secret id. Lets non-prod environments
  /// run their own bucket of secrets without colliding with prod.
  final String secretNamePrefix;

  /// Per-request timeout. Both the create and addVersion calls each
  /// get this budget independently.
  final Duration timeout;

  final OAuthAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;

  @override
  Future<KmsWriteResult> writeSecret({
    required String logicalKeyKind,
    required String plaintext,
  }) async {
    final secretId = _resolveSecretId(logicalKeyKind);
    try {
      await _ensureSecretExists(secretId: secretId, kind: logicalKeyKind);
      final versionName = await _addVersion(
        secretId: secretId,
        plaintext: plaintext,
        kind: logicalKeyKind,
      );
      return KmsWriteResult(
        secretName: '$pointerPrefix$versionName',
        maskedDisplay: maskCredentialForDisplay(plaintext),
      );
    } on TimeoutException {
      throw KmsWriteFailure('gcp_secret_manager_timeout: $logicalKeyKind');
    }
  }

  /// Map a logical key kind onto a Secret Manager-compatible secret
  /// id. Underscores are not allowed in Secret Manager secret ids, so
  /// they are replaced with dashes. Most lanes use the `*-api-key`
  /// suffix; `azure_db` uses `*-superuser` because its plaintext is
  /// the Postgres super-user password (NOT an API key), and the
  /// 11A.4c rollout plan + operator runbook reference that exact
  /// secret id (`forge-flow-azure-db-superuser`).
  String _resolveSecretId(String logicalKeyKind) {
    final dashed = logicalKeyKind.replaceAll('_', '-');
    if (logicalKeyKind == 'azure_db') {
      return '$secretNamePrefix-$dashed-superuser';
    }
    return '$secretNamePrefix-$dashed-api-key';
  }

  /// Create the Secret Manager secret if it does not already exist.
  /// 200 means newly created; 409 means a previous rotation already
  /// created it and we treat that as success. Anything else fails
  /// closed with a [KmsWriteFailure] that excludes [plaintext].
  Future<void> _ensureSecretExists({
    required String secretId,
    required String kind,
  }) async {
    final token = await _accessTokenProvider.accessToken();
    final uri = Uri.https(
      _secretManagerHost,
      '/v1/projects/$projectId/secrets',
      <String, String>{'secretId': secretId},
    );
    final response = await _httpClient
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'replication': <String, Object?>{
              'automatic': <String, Object?>{},
            },
          }),
        )
        .timeout(timeout);
    if (response.statusCode == 200) return;
    if (response.statusCode == 409) return;
    throw KmsWriteFailure(
      'gcp_secret_manager_create_failed: $kind '
      'status=${response.statusCode}${_safeErrorSummary(response.body)}',
    );
  }

  /// Add a new version of [secretId] with [plaintext] base64-encoded
  /// per the Secret Manager wire format. Returns the full version
  /// name (`projects/<P>/secrets/<S>/versions/<N>`) so the caller can
  /// build a stable `kms://` pointer.
  Future<String> _addVersion({
    required String secretId,
    required String plaintext,
    required String kind,
  }) async {
    final token = await _accessTokenProvider.accessToken();
    final uri = Uri.https(
      _secretManagerHost,
      '/v1/projects/$projectId/secrets/$secretId:addVersion',
    );
    final encodedPayload = base64Encode(utf8.encode(plaintext));
    final response = await _httpClient
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'payload': <String, Object?>{'data': encodedPayload},
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw KmsWriteFailure(
        'gcp_secret_manager_add_version_failed: $kind '
        'status=${response.statusCode}${_safeErrorSummary(response.body)}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      // Don't surface the body even on malformed-success — it could
      // include the request payload echoed by a misbehaving
      // intermediary, which would leak the rotated plaintext.
      throw KmsWriteFailure(
        'gcp_secret_manager_add_version_malformed: $kind',
      );
    }
    final name = decoded['name'];
    if (name is! String || name.isEmpty) {
      throw KmsWriteFailure(
        'gcp_secret_manager_add_version_missing_name: $kind',
      );
    }
    return name;
  }

  /// Build a sanitized summary of an error response body for
  /// inclusion in audit-bound exception messages.
  ///
  /// We NEVER include the raw response body — the addVersion request
  /// body literally contains `{"payload": {"data": "<base64-plaintext>"}}`
  /// and a misbehaving HTTP intermediary that echoes the request in
  /// the response (e.g. a buggy load balancer, a custom 4xx page)
  /// would leak the rotated plaintext into `audit_logs` via
  /// `KmsWriteFailure.message`.
  ///
  /// Instead we parse the body as JSON and extract only the
  /// GCP-standard `error.code` and `error.status` fields. Both are
  /// short, opinionated values produced by GCP itself — they don't
  /// contain request payload echoes. The `error.message` field is
  /// deliberately omitted: it's also produced by GCP, but the
  /// shipping rule is "fail closed on this surface" and operators
  /// can read the full `error.message` from GCP Cloud Logging when
  /// they need it.
  ///
  /// Returns an empty string when the body cannot be parsed or has
  /// no `error` object — leaving the caller's exception with just
  /// the HTTP status code.
  String _safeErrorSummary(String body) {
    if (body.isEmpty) return '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return '';
      final error = decoded['error'];
      if (error is! Map) return '';
      final parts = <String>[];
      final code = error['code'];
      if (code is num) parts.add('code=${code.toInt()}');
      final status = error['status'];
      if (status is String && status.isNotEmpty) {
        // Last-line guard: drop the status string if it somehow
        // looks base64-ish. GCP's status values are short SCREAMING
        // SNAKE constants like `PERMISSION_DENIED`, never base64.
        if (!_looksLikeBase64Plaintext(status)) {
          parts.add('status_text=$status');
        }
      }
      return parts.isEmpty ? '' : ' ${parts.join(' ')}';
    } catch (_) {
      return '';
    }
  }

  /// True when [value] contains any 16+ char run of base64-alphabet
  /// characters. Used as a defense-in-depth check against accidental
  /// plaintext echo through fields that should not contain it.
  static final RegExp _base64Run = RegExp(r'[A-Za-z0-9+/]{16,}={0,2}');
  bool _looksLikeBase64Plaintext(String value) =>
      _base64Run.hasMatch(value);
}
