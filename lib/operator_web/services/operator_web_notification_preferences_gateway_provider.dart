// Phase 8 W2.B - operator-web notification preferences gateway.
//
// Three routes, all on the actor's own preferences:
//
//   GET    /v1/operator/notification-preferences
//   PUT    /v1/operator/notification-preferences/:eventKey/:channel
//          ?scope_kind=operator|location&scope_id=<uuid>
//   DELETE /v1/operator/notification-preferences/:eventKey/:channel
//          ?scope_kind=operator|location&scope_id=<uuid>
//
// Web-safe: pure-Dart, no `dart:io`, no `sqflite`. Both the demo and
// live impls live here so the operator-web build picks one based on
// the auth source.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Wire shape of one notification preference row, used by both demo
/// and live gateway impls + the screen.
class WebNotificationPreference {
  const WebNotificationPreference({
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

/// Thrown when the proxy returns a non-2xx, or the response body
/// cannot be parsed.
class WebNotificationPreferencesError implements Exception {
  const WebNotificationPreferencesError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'WebNotificationPreferencesError'
      '(code: $code, status: $statusCode, message: $message)';
}

/// Gateway interface the screen calls.
abstract class WebNotificationPreferencesGateway {
  Future<List<WebNotificationPreference>> listPreferences();

  Future<WebNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  });

  Future<void> deletePreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required String idempotencyKey,
  });
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebNotificationPreferencesGateway]. Live wiring
/// (Firebase source + proxy) implements this; demo / fixture sources
/// may leave it absent so the screen renders honest read-only state.
abstract class OperatorWebNotificationPreferencesGatewayProvider {
  WebNotificationPreferencesGateway get notificationPreferencesGateway;
}

/// In-memory demo gateway. The operator-web demo source mixes this
/// in so the screen renders + toggles end-to-end without a live
/// proxy.
class DemoWebNotificationPreferencesGateway
    implements WebNotificationPreferencesGateway {
  DemoWebNotificationPreferencesGateway({
    Iterable<WebNotificationPreference> initial = const <WebNotificationPreference>[],
  }) : _store = <_Key, WebNotificationPreference>{
          for (final p in initial) _Key.fromPreference(p): p,
        };

  final Map<_Key, WebNotificationPreference> _store;

  @override
  Future<List<WebNotificationPreference>> listPreferences() async {
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
  Future<WebNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  }) async {
    final pref = WebNotificationPreference(
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: scopeKind == 'operator' ? null : scopeId,
      enabled: enabled,
    );
    _store[_Key.fromPreference(pref)] = pref;
    return pref;
  }

  @override
  Future<void> deletePreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required String idempotencyKey,
  }) async {
    _store.remove(_Key(
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: scopeKind == 'operator' ? null : scopeId,
    ));
  }
}

/// Live HTTP gateway. Reaches the proxy directly with a Bearer token
/// from [idTokenProvider] on every call.
class HttpWebNotificationPreferencesGateway
    implements WebNotificationPreferencesGateway {
  HttpWebNotificationPreferencesGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? client,
  })  : _baseUri = proxyBaseUri,
        _idTokenProvider = idTokenProvider,
        _client = client ?? http.Client();

  final Uri _baseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _client;

  Future<Map<String, String>> _authHeaders({String? idempotencyKey}) async {
    final token = await _idTokenProvider();
    if (token == null || token.isEmpty) {
      throw const WebNotificationPreferencesError(
        code: 'unauthenticated',
        message: 'Not signed in',
      );
    }
    return <String, String>{
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
      if (idempotencyKey != null) 'idempotency-key': idempotencyKey,
    };
  }

  Uri _resolve(String path, {Map<String, String>? query}) {
    var uri = _baseUri.resolve(path);
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    return uri;
  }

  @override
  Future<List<WebNotificationPreference>> listPreferences() async {
    final headers = await _authHeaders();
    final response = await _client.get(
      _resolve('/v1/operator/notification-preferences'),
      headers: headers,
    );
    final body = _decode(response);
    final raw = body['preferences'];
    if (raw is! List) {
      throw const WebNotificationPreferencesError(
        code: 'malformed_response',
        message: 'response missing `preferences` array',
      );
    }
    return <WebNotificationPreference>[
      for (final entry in raw)
        if (entry is Map<String, Object?>)
          WebNotificationPreference(
            eventKey: entry['event_key'] as String,
            channel: entry['channel'] as String,
            scopeKind: entry['scope_kind'] as String,
            scopeId: entry['scope_id'] as String?,
            enabled: entry['enabled'] as bool,
          ),
    ];
  }

  @override
  Future<WebNotificationPreference> upsertPreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required bool enabled,
    required String idempotencyKey,
  }) async {
    final headers = await _authHeaders(idempotencyKey: idempotencyKey);
    final query = <String, String>{
      'scope_kind': scopeKind,
      if (scopeKind == 'location' && scopeId != null) 'scope_id': scopeId,
    };
    final encodedEvent = Uri.encodeComponent(eventKey);
    final encodedChannel = Uri.encodeComponent(channel);
    final response = await _client.put(
      _resolve(
        '/v1/operator/notification-preferences/$encodedEvent/$encodedChannel',
        query: query,
      ),
      headers: headers,
      body: jsonEncode(<String, Object?>{'enabled': enabled}),
    );
    final body = _decode(response);
    return WebNotificationPreference(
      eventKey: body['event_key'] as String,
      channel: body['channel'] as String,
      scopeKind: body['scope_kind'] as String,
      scopeId: body['scope_id'] as String?,
      enabled: body['enabled'] as bool,
    );
  }

  @override
  Future<void> deletePreference({
    required String eventKey,
    required String channel,
    required String scopeKind,
    String? scopeId,
    required String idempotencyKey,
  }) async {
    final headers = await _authHeaders(idempotencyKey: idempotencyKey);
    final query = <String, String>{
      'scope_kind': scopeKind,
      if (scopeKind == 'location' && scopeId != null) 'scope_id': scopeId,
    };
    final encodedEvent = Uri.encodeComponent(eventKey);
    final encodedChannel = Uri.encodeComponent(channel);
    final response = await _client.delete(
      _resolve(
        '/v1/operator/notification-preferences/$encodedEvent/$encodedChannel',
        query: query,
      ),
      headers: headers,
    );
    _decode(response);
  }

  Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?> body;
    try {
      body = jsonDecode(response.body) as Map<String, Object?>;
    } catch (_) {
      throw WebNotificationPreferencesError(
        code: 'malformed_response',
        message: 'response body was not JSON',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      throw WebNotificationPreferencesError(
        code: (body['error'] as String?) ?? 'request_failed',
        message: (body['message'] as String?) ?? 'request failed',
        statusCode: response.statusCode,
      );
    }
    return body;
  }
}

class _Key {
  const _Key({
    required this.eventKey,
    required this.channel,
    required this.scopeKind,
    required this.scopeId,
  });

  factory _Key.fromPreference(WebNotificationPreference p) => _Key(
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
