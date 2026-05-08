// Theme D — Cloud Pub/Sub realtime publisher (production wire-up).
//
// Replaces `_unwiredPubsubMessagePublisher` from
// `tool/advisor_proxy/main.dart` with a real REST-API publisher that
// uses Application Default Credentials (Cloud Run metadata server) for
// bearer-token auth. Mirrors the existing `GcpSecretManagerKmsProvider`
// pattern (see `lib/infrastructure/kms/gcp_secret_manager_kms_provider.dart`)
// — no `googleapis` SDK dependency, just `package:http` + the
// metadata-server token provider that already lives at
// `lib/services/auth/firebase_admin_auth_client.dart`.
//
// Why REST instead of `googleapis`/`gcloud_pubsub`: those packages ship
// gRPC stubs that pull in dart:io ports + extra deps. The proxy already
// uses raw REST to talk to Secret Manager; copying that pattern keeps
// the binary footprint flat and avoids a transitive dep audit.
//
// Hard contract reminders:
//   * `PubsubMessagePublisher` callback contract: throw on graceful
//     failure so the bridge worker's lease retry kicks in. We rethrow
//     after wrapping non-2xx responses in [PubsubPublishFailure].
//   * Operator scoping is carried in Pub/Sub message attributes
//     (`operator_id`, `topic`, `event_id`); per
//     `docs/contracts/event_outbox_contract.md` "Topic Shape", a
//     subscription filter pins `operator_id` to the connecting tenant
//     so subscribers never see cross-operator events.
//   * Body is base64-encoded per Pub/Sub REST wire format; a publish
//     POSTs to `/v1/projects/{project}/topics/{topic}:publish`.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/firebase_admin_auth_client.dart' show OAuthAccessTokenProvider;

/// Hostname for the Pub/Sub REST API. Hardcoded — Pub/Sub is regionless
/// from the client's perspective; routing happens server-side based on
/// topic location.
const String kGoogleCloudPubsubHost = 'pubsub.googleapis.com';

/// Default per-call publish timeout. Pub/Sub publish latency p99 is
/// well under 1s; 10s gives a comfortable margin without letting a
/// hung connection wedge a bridge claim slot.
const Duration kGoogleCloudPubsubDefaultTimeout = Duration(seconds: 10);

/// Failure type thrown when the Pub/Sub REST API returns a non-2xx
/// response. Carries the HTTP status + a sanitized snippet so the
/// bridge log fields show what went wrong without leaking the raw
/// response (which could echo the publish body and therefore tenant
/// payload). Construction never includes the request body itself.
class PubsubPublishFailure implements Exception {
  PubsubPublishFailure({
    required this.topicName,
    required this.statusCode,
    required this.shortMessage,
  });

  final String topicName;
  final int statusCode;
  final String shortMessage;

  @override
  String toString() =>
      'PubsubPublishFailure(topic=$topicName, status=$statusCode, '
      '$shortMessage)';
}

/// Builds the production Pub/Sub message-publisher callback that the
/// `selectRealtimePublisher` helper hands to `PubsubRealtimePublisher`.
///
/// Reads:
///   * [projectId]    — GCP project id (Cloud Run env: `PUBSUB_REALTIME_PROJECT`)
///   * [accessTokenProvider] — Cloud Run metadata-server ADC, shared with
///     the existing KMS + Firebase admin clients.
///   * [httpClient]   — injected for tests; production passes `http.Client()`.
///   * [timeout]      — per-publish timeout.
class GoogleCloudPubsubMessagePublisher {
  GoogleCloudPubsubMessagePublisher({
    required this.projectId,
    required OAuthAccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
    this.timeout = kGoogleCloudPubsubDefaultTimeout,
  })  : _accessTokenProvider = accessTokenProvider,
        _httpClient = httpClient ?? http.Client();

  /// GCP project the topic lives in.
  final String projectId;

  /// Per-call timeout. Both publish API + token refresh are bounded by
  /// the same value.
  final Duration timeout;

  final OAuthAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;

  /// Publish callback wired through `PubsubMessagePublisher` typedef
  /// in `lib/services/realtime/pubsub_realtime_publisher.dart`. Returns
  /// when the API has acked the publish; throws [PubsubPublishFailure]
  /// (or rethrows the underlying TimeoutException) on failure so the
  /// bridge worker re-claims the row on the next lease tick.
  Future<void> publish({
    required String topicName,
    required String body,
    required Map<String, String> attributes,
  }) async {
    final token = await _accessTokenProvider.accessToken().timeout(timeout);
    final uri = Uri.https(
      kGoogleCloudPubsubHost,
      '/v1/projects/$projectId/topics/$topicName:publish',
    );
    // Pub/Sub wire format: data is base64(utf8(body)); attributes are
    // simple string pairs. We emit a single-message envelope per
    // publish — batch publishing is a future micro-optimization that
    // does not affect correctness.
    final encodedBody = base64Encode(utf8.encode(body));
    final response = await _httpClient
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'messages': <Object?>[
              <String, Object?>{
                'data': encodedBody,
                if (attributes.isNotEmpty) 'attributes': attributes,
              },
            ],
          }),
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PubsubPublishFailure(
        topicName: topicName,
        statusCode: response.statusCode,
        shortMessage: _safeErrorSummary(response.body),
      );
    }
  }

  /// Best-effort sanitized error summary. Pub/Sub returns a Google
  /// API error envelope `{"error":{"code":..,"status":..,"message":..}}`
  /// — we only surface the code + status, never the message (the
  /// message can echo Pub/Sub's view of the request which is OK for
  /// triage but we prefer to keep the log envelope tight).
  String _safeErrorSummary(String body) {
    if (body.isEmpty) return 'empty_body';
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return 'non_json_body';
      final error = decoded['error'];
      if (error is! Map) return 'no_error_envelope';
      final parts = <String>[];
      final code = error['code'];
      if (code is num) parts.add('code=${code.toInt()}');
      final status = error['status'];
      if (status is String && status.isNotEmpty) {
        parts.add('status=$status');
      }
      return parts.isEmpty ? 'no_error_fields' : parts.join(',');
    } catch (_) {
      return 'malformed_json_body';
    }
  }
}
