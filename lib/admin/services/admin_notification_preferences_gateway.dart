// X-G71 (cross-surface parity register §0b) - admin self-service
// notification-preferences gateway.
//
// The customer operator-web console has a full notification-preferences
// editor (`lib/operator_web/screens/settings_notifications_screen.dart`
// + its gateway). The mobile app is a read-only inbox. The F&F-internal
// admin console had NO notification-preferences surface at all - a
// missing-surface parity gap. This gateway closes the wiring half; the
// matching screen lives in
// `lib/admin/screens/admin_notification_preferences_screen.dart`.
//
// Wire shape: the proxy routes are the SAME ones the operator-web side
// calls - the actor's own preferences only:
//
//   GET    /v1/operator/notification-preferences
//   PUT    /v1/operator/notification-preferences/:eventKey/:channel
//          ?scope_kind=operator|location&scope_id=<uuid>
//
// The proxy resolves operator / location / user from the verified
// bearer token (`_resolveOperatorContextOrWrite` in
// `tool/advisor_proxy/advisor_proxy.dart`), never from the URL or
// actor kind, and operates on "the actor's own row". So the admin
// caller targets themselves automatically and NO separate
// `/v1/admin/...` route is needed - that would force a parallel
// permission catalog entry, which CLAUDE.md HP #11 + R-2 disallow.
// This mirrors exactly the merged G4 admin self-MFA pattern (reused
// the existing `/v1/auth/*` routes) and the W-3 admin self-account
// pattern (reused `/v1/auth/self/profile`).
//
// DELETE is intentionally NOT surfaced: the admin screen, like the
// operator-web screen, only toggles channels on/off via PUT
// (`enabled: true|false`); it never deletes preference rows. Keeping
// the gateway to the two routes the screen actually uses keeps the
// admin contract narrow.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to every proxy call. Production
/// binds this to the admin Firebase ID-token stream; tests pin a
/// synthetic value. Same typedef shape as the sibling admin gateways.
typedef AdminNotificationPreferencesBearerTokenProvider = Future<String>
    Function();

/// Wire shape of one notification-preference row. Mirrors the
/// operator-web `WebNotificationPreference` so the admin screen
/// resolves toggles the same way.
@immutable
class AdminNotificationPreference {
  const AdminNotificationPreference({
    required this.eventKey,
    required this.channel,
    required this.scopeKind,
    required this.scopeId,
    required this.enabled,
  });

  final String eventKey;

  /// Wire value: `push` / `email` / `inbox`.
  final String channel;

  /// Wire value: `operator` / `location`.
  final String scopeKind;

  /// `null` for `operator`-scope rows.
  final String? scopeId;
  final bool enabled;
}

/// Errors emitted by the gateway. Mirrors the existing admin gateway
/// error shape so the screen layer can show a calm friendly message.
class AdminNotificationPreferencesGatewayError implements Exception {
  const AdminNotificationPreferencesGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final int statusCode;
  final String errorCode;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'AdminNotificationPreferencesGatewayError'
      '($statusCode/$errorCode): $message';
}

/// Self-service notification-preferences surface for the F&F admin
/// console. Read + write the signed-in admin's own preferences.
abstract class AdminNotificationPreferencesGateway {
  /// Lists the signed-in admin's own preference rows.
  Future<List<AdminNotificationPreference>> listPreferences();

  /// Turns one channel on/off for one event for the signed-in admin.
  ///
  /// [idempotencyKey] is required so a retry replays the same response
  /// without writing twice. The screen mints ONE key per logical
  /// toggle and reuses it across retries (G60/G70 bug class: never
  /// mint a fresh key per attempt).
  Future<AdminNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  });
}

/// Production HTTP implementation. Mirrors the `HttpAdminAccountGateway`
/// shape: the bearer source is injected so the admin Firebase ID-token
/// stream binds at startup and tests pin a synthetic value.
class HttpAdminNotificationPreferencesGateway
    implements AdminNotificationPreferencesGateway {
  HttpAdminNotificationPreferencesGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri baseUri;
  final AdminNotificationPreferencesBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Shared route - admin + operator-web both hit this path. The proxy
  /// resolves the actor from the verified bearer token, so the admin
  /// caller targets themselves automatically.
  static const String basePath = '/v1/operator/notification-preferences';

  @override
  Future<List<AdminNotificationPreference>> listPreferences() async {
    final body = await _send(method: 'GET', path: basePath);
    final raw = body['preferences'];
    if (raw is! List) {
      throw const AdminNotificationPreferencesGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin notification-preferences proxy returned an '
            'incomplete response',
      );
    }
    return <AdminNotificationPreference>[
      for (final entry in raw)
        if (entry is Map)
          _parseRow(Map<String, Object?>.from(entry)),
    ];
  }

  @override
  Future<AdminNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  }) async {
    final query = <String, String>{
      'scope_kind': scopeKind,
      if (scopeKind == 'location' && scopeId != null) 'scope_id': scopeId,
    };
    final encodedEvent = Uri.encodeComponent(eventKey);
    final encodedChannel = Uri.encodeComponent(channel);
    final body = await _send(
      method: 'PUT',
      path: '$basePath/$encodedEvent/$encodedChannel',
      query: query,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{'enabled': enabled},
    );
    return _parseRow(body);
  }

  AdminNotificationPreference _parseRow(Map<String, Object?> json) {
    final eventKey = json['event_key'];
    final channel = json['channel'];
    final scopeKind = json['scope_kind'];
    final enabled = json['enabled'];
    if (eventKey is! String ||
        channel is! String ||
        scopeKind is! String ||
        enabled is! bool) {
      throw const AdminNotificationPreferencesGatewayError(
        statusCode: 502,
        errorCode: 'malformed_response',
        message: 'admin notification-preferences proxy response missing '
            'required fields',
      );
    }
    return AdminNotificationPreference(
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: json['scope_id'] as String?,
      enabled: enabled,
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String>? query,
    String? idempotencyKey,
    Map<String, Object?>? jsonBody,
  }) async {
    final token = await bearerTokenProvider();
    var uri = baseUri.resolve(path);
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw AdminNotificationPreferencesGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message: 'admin notification-preferences proxy timed out '
            'after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    final message = (parsed['message'] as String?) ??
        'admin notification-preferences proxy returned an error';
    throw AdminNotificationPreferencesGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: message,
      details: parsed,
    );
  }
}

/// In-memory demo gateway. Mirrors the operator-web
/// `DemoWebNotificationPreferencesGateway` so the kDemoMode /
/// share-preview walkthrough renders the editable surface without a
/// backend. Records every upsert call (with its idempotency key) so
/// tests can assert key stability across retries.
class InMemoryAdminNotificationPreferencesGateway
    implements AdminNotificationPreferencesGateway {
  InMemoryAdminNotificationPreferencesGateway({
    Iterable<AdminNotificationPreference> initial =
        const <AdminNotificationPreference>[],
  }) : _store = <_Key, AdminNotificationPreference>{
          for (final p in initial) _Key.fromPreference(p): p,
        };

  final Map<_Key, AdminNotificationPreference> _store;
  final List<AdminNotificationPreferenceUpsertCall> calls =
      <AdminNotificationPreferenceUpsertCall>[];

  @override
  Future<List<AdminNotificationPreference>> listPreferences() async {
    final list = _store.values.toList()
      ..sort((a, b) {
        final byEvent = a.eventKey.compareTo(b.eventKey);
        if (byEvent != 0) return byEvent;
        final byChannel = a.channel.compareTo(b.channel);
        if (byChannel != 0) return byChannel;
        final byScopeKind = a.scopeKind.compareTo(b.scopeKind);
        if (byScopeKind != 0) return byScopeKind;
        return (a.scopeId ?? '').compareTo(b.scopeId ?? '');
      });
    return list;
  }

  @override
  Future<AdminNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  }) async {
    calls.add(AdminNotificationPreferenceUpsertCall(
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: scopeId,
      enabled: enabled,
      idempotencyKey: idempotencyKey,
    ));
    final pref = AdminNotificationPreference(
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: scopeKind == 'operator' ? null : scopeId,
      enabled: enabled,
    );
    _store[_Key.fromPreference(pref)] = pref;
    return pref;
  }
}

@immutable
class AdminNotificationPreferenceUpsertCall {
  const AdminNotificationPreferenceUpsertCall({
    required this.eventKey,
    required this.channel,
    required this.scopeKind,
    required this.scopeId,
    required this.enabled,
    required this.idempotencyKey,
  });

  final String eventKey;
  final String channel;
  final String scopeKind;
  final String? scopeId;
  final bool enabled;
  final String idempotencyKey;
}

class _Key {
  const _Key({
    required this.eventKey,
    required this.channel,
    required this.scopeKind,
    required this.scopeId,
  });

  factory _Key.fromPreference(AdminNotificationPreference p) => _Key(
        eventKey: p.eventKey,
        channel: p.channel,
        scopeKind: p.scopeKind,
        scopeId: p.scopeId,
      );

  final String eventKey;
  final String channel;
  final String scopeKind;
  final String? scopeId;

  @override
  bool operator ==(Object other) =>
      other is _Key &&
      other.eventKey == eventKey &&
      other.channel == channel &&
      other.scopeKind == scopeKind &&
      other.scopeId == scopeId;

  @override
  int get hashCode => Object.hash(eventKey, channel, scopeKind, scopeId);
}
