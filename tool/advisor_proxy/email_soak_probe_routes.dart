// Wave 2 Q-2a — Email soak harness probe route (test-time observation).
//
// Route:
//   GET /v1/admin/email-soak/events
//
// Query params:
//   * provider_message_id (required): the SendGrid message id returned
//     by `POST /v1/admin/integrations/email/test` (or any future
//     test-trigger surface).
//   * since (optional): RFC3339 timestamp. Only rows with
//     `received_at >= since` are returned. Lets the harness scope a
//     poll to the message it just sent.
//   * kind (optional): SendGrid event kind filter (e.g. `delivered`,
//     `bounced`). When omitted, every kind matching the provider
//     message id is returned.
//
// Why this lives in a SIBLING file (NOT advisor_proxy.dart):
//   * The monolith is at its bleed-stop ceiling per
//     `tool/advisor_proxy_size_lint.dart`'s `kAdvisorProxyMaxLines`.
//     CLAUDE.md "Ceiling-raise rule (R-2)" gates raises behind explicit
//     operator approval.
//   * Slice mounts this router as a pre-check before `routeRequest`
//     mirroring the SendGrid webhook + admin email patterns.
//
// Auth posture: env-var gated. The route is INERT unless the proxy
// loads a non-empty `EMAIL_SOAK_PROBE_TOKEN` env var; production
// deploys leave it unset. Callers must supply the matching token via
// the `Authorization: Bearer <token>` header. Mirrors the
// "env-gated-inert" pattern used by `HeapSnapshotUploader` and the
// pressure-preview harnesses so the read seam ships ready to wire
// without ever shipping live.
//
// Why a dedicated probe token (rather than `super_admin` JWT):
//   1. Production has no `super_admin` (operator decision 2026-05-08
//      audit; super_admin is reserved for F&F bench access).
//   2. The harness is a Dart CLI; it has no Firebase identity provider.
//      A static bearer matches the pressure-harness env-gated posture.
//   3. The token belongs to the test/staging env's secret store; it is
//      never co-resident with production data because the env var
//      stays unset on production deploys.
//
// Read-only by construction: the route hits
// `EmailEventRepository.findEventsByProviderMessageId`, which is a
// SELECT with no write paths. The repository runs `withSystem` because
// inbound `email_event` rows have no operator scope until the FK to
// `email_outbox` is resolved (see the repository header). The probe
// route's audit reason is `email_event.email_soak_probe_find_by_message_id`
// so the `app.bypass_rls_audit` GUC names the probe path distinctly
// from inbound webhook inserts.
//
// CLAUDE.md compliance:
//   * Hard Promise #2 — same tables in demo + prod; the route is a
//     read on the same `email_event` table either way.
//   * Hard Promise #4 — per-operator isolation: the probe does NOT
//     expose `event_payload` JSONB (which can carry the recipient
//     email + smtp-id). Only `event_kind`, timestamps, and the
//     opaque message + event ids surface. Even if the env-var gate
//     accidentally leaked, the probe is structurally incapable of
//     exfiltrating per-operator personal data.
//   * Hard Promise #7 — server-side keys: `EMAIL_SOAK_PROBE_TOKEN`
//     is server-side; the harness consumes it from its own env, never
//     from a client request beyond the bearer header.
//   * No `package:postgres` import — the repository seam handles
//     persistence per `tool/postgres_import_lint.dart`.
//
// Idempotency: GET is idempotent by construction. Re-polling within
// the harness's latency budget is safe.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/email_event_repository.dart';

import 'log.dart';

/// Path the probe route binds to.
const String emailSoakEventsProbePath = '/v1/admin/email-soak/events';

/// Env var the proxy loads the shared bearer token from. Production
/// leaves this UNSET so the route returns 503 inert. Test / staging
/// deploys wire a long random secret via Cloud Run env config or the
/// equivalent secret manager binding.
const String kEmailSoakProbeTokenEnvVar = 'EMAIL_SOAK_PROBE_TOKEN';

/// Default upper bound on rows returned per call. The repository
/// already clamps; the route applies the same cap defensively so a
/// malformed `limit` query param cannot widen the read.
const int kEmailSoakProbeDefaultLimit = 25;

/// Loader closure for the bearer token. Defaults to the env var; tests
/// inject a deterministic literal so the suite does not touch env.
typedef EmailSoakProbeTokenLoader = String? Function();

/// Default loader — reads [kEmailSoakProbeTokenEnvVar]. Returns null
/// when unset / empty so the route returns 503 inert.
String? defaultEmailSoakProbeTokenLoader() {
  final raw = Platform.environment[kEmailSoakProbeTokenEnvVar];
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

/// JSON envelope returned by the probe route.
class EmailSoakProbeEventsResponse {
  const EmailSoakProbeEventsResponse({
    required this.providerMessageId,
    required this.since,
    required this.kindFilter,
    required this.events,
  });

  final String providerMessageId;
  final DateTime? since;
  final String? kindFilter;
  final List<EmailEventSummary> events;

  Map<String, Object?> toJson() => <String, Object?>{
        'provider_message_id': providerMessageId,
        if (since != null) 'since': since!.toUtc().toIso8601String(),
        if (kindFilter != null) 'kind': kindFilter,
        'event_count': events.length,
        'events': events
            .map(
              (e) => <String, Object?>{
                'event_id': e.eventId,
                'event_kind': e.eventKind,
                'occurred_at': e.occurredAt.toUtc().toIso8601String(),
                'received_at': e.receivedAt.toUtc().toIso8601String(),
                'provider_event_id': e.providerEventId,
                'provider_message_id': e.providerMessageId,
              },
            )
            .toList(growable: false),
      };
}

/// Pluggable router that the marked region in main.dart mounts before
/// delegating to the monolithic `routeRequest`. Returns true when the
/// request was fully handled (the listener loop must skip
/// `routeRequest`); returns false otherwise so the existing dispatcher
/// continues.
class EmailSoakProbeRouter {
  EmailSoakProbeRouter({
    required EmailEventRepository repository,
    EmailSoakProbeTokenLoader? tokenLoader,
  })  : _repository = repository,
        _tokenLoader = tokenLoader ?? defaultEmailSoakProbeTokenLoader;

  final EmailEventRepository _repository;
  final EmailSoakProbeTokenLoader _tokenLoader;

  /// Returns true when the request matched and was fully handled.
  Future<bool> tryHandle(HttpRequest request) async {
    if (!matches(request.uri.path, request.method)) {
      return false;
    }
    final response = request.response;
    try {
      final token = _tokenLoader();
      if (token == null || token.isEmpty) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'email_soak_probe_disabled',
          'message':
              'EMAIL_SOAK_PROBE_TOKEN is unset on this proxy. The email '
              'soak probe route is intentionally inert in production '
              'deploys.',
        });
        return true;
      }
      final authz = request.headers.value('authorization');
      if (authz == null || !_bearerMatches(authz, token)) {
        _writeJson(response, 401, <String, Object?>{
          'error': 'bad_bearer',
          'message':
              'request is missing a valid email-soak probe bearer token.',
        });
        return true;
      }
      final dispatchResult = await dispatch(
        queryParameters: request.uri.queryParameters,
      );
      _writeJson(response, dispatchResult.statusCode, dispatchResult.body);
      return true;
    } catch (error, stack) {
      log(
        LogSeverity.error,
        'email_soak_probe.unhandled_error',
        fields: <String, Object?>{
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
      _writeJson(response, 500, <String, Object?>{
        'error': 'internal_server_error',
        'message': 'email soak probe failed to read the event log.',
      });
      return true;
    }
  }

  /// Pure-Dart dispatch used by unit tests (no HttpServer). Skips the
  /// bearer check (callers test that separately via [tryHandle]).
  Future<({int statusCode, Object body})> dispatch({
    required Map<String, String> queryParameters,
  }) async {
    final providerMessageId =
        queryParameters['provider_message_id']?.trim() ?? '';
    if (providerMessageId.isEmpty) {
      return (
        statusCode: 400,
        body: <String, Object?>{
          'error': 'provider_message_id_required',
          'message': 'provider_message_id query parameter is required.',
        },
      );
    }

    DateTime? since;
    final sinceRaw = queryParameters['since']?.trim();
    if (sinceRaw != null && sinceRaw.isNotEmpty) {
      final parsed = DateTime.tryParse(sinceRaw);
      if (parsed == null) {
        return (
          statusCode: 400,
          body: <String, Object?>{
            'error': 'since_malformed',
            'message': 'since must be an RFC3339 timestamp.',
          },
        );
      }
      since = parsed.toUtc();
    }

    final kindRaw = queryParameters['kind']?.trim();
    final kindFilter =
        (kindRaw == null || kindRaw.isEmpty) ? null : kindRaw;

    var limit = kEmailSoakProbeDefaultLimit;
    final limitRaw = queryParameters['limit']?.trim();
    if (limitRaw != null && limitRaw.isNotEmpty) {
      final parsed = int.tryParse(limitRaw);
      if (parsed == null || parsed <= 0) {
        return (
          statusCode: 400,
          body: <String, Object?>{
            'error': 'limit_malformed',
            'message': 'limit must be a positive integer.',
          },
        );
      }
      limit = parsed;
    }

    final events = await _repository.findEventsByProviderMessageId(
      providerMessageId: providerMessageId,
      since: since,
      kindFilter: kindFilter,
      limit: limit,
    );

    final envelope = EmailSoakProbeEventsResponse(
      providerMessageId: providerMessageId,
      since: since,
      kindFilter: kindFilter,
      events: events,
    );
    return (statusCode: 200, body: envelope.toJson());
  }

  /// Discriminator the main.dart pre-check uses; same shape as the
  /// SendGrid webhook + admin email routers.
  static bool matches(String path, String method) {
    return method == 'GET' && path == emailSoakEventsProbePath;
  }

  static bool _bearerMatches(String header, String expected) {
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return false;
    final supplied = header.substring(prefix.length).trim();
    if (supplied.isEmpty) return false;
    // Constant-time-ish comparison: the supplied + expected lengths
    // may differ (a probe attacker could time the differ-on-first-byte
    // shortcut otherwise), so we always walk to the longer length.
    if (supplied.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= supplied.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  void _writeJson(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }
}
