// Phase 8 W2.B - HTTP-level tests for the three notification
// preferences routes:
//   GET    /v1/operator/notification-preferences
//   PUT    /v1/operator/notification-preferences/:eventKey/:channel
//   DELETE /v1/operator/notification-preferences/:eventKey/:channel

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/notification_preference.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kUserA = '44444444-4444-4444-4444-444444444444';
const String _kUserB = '55555555-5555-5555-5555-555555555555';

void main() {
  group('notification preferences routes', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<({
      HttpServer server,
      HttpClient client,
      Uri baseUri,
      _RecordingNotificationGateway gateway,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      bool routerConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims ??
          const ProxyJwtClaims(
            userId: _kUserA,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = _RecordingNotificationGateway();
      final router = NotificationPreferencesRouter(gateway: gateway);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            notificationPreferencesRouter: routerConfigured ? router : null,
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {}
        }
      });
      final client = HttpClient();
      final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        gateway: gateway,
      );
    }

    test('GET happy path returns the actor\'s rows only (RLS by default)',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          // Seed gateway with one row for actor A.
          ctx.gateway.seedListRows(<NotificationPreference>[
            _seedPref(
              operatorId: _kOpA,
              userId: _kUserA,
              eventKey: 'notif.backfill.complete',
              channel: NotificationChannel.push,
            ),
          ]);
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(notificationPreferencesPath),
            method: 'GET',
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final prefs = body['preferences'] as List<Object?>;
          expect(prefs, hasLength(1));
          final first = prefs.single as Map<String, Object?>;
          expect(first['user_id'], equals(_kUserA));
          // Gateway received the actor's userId from the JWT.
          expect(ctx.gateway.lastListUserId, equals(_kUserA));
          expect(ctx.gateway.lastListOperatorId, equals(_kOpA));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET 401 when bearer token is rejected', () async {
      await withRealHttp(() async {
        final verifier = _SettableVerifier();
        verifier.error = ProxyJwtVerificationError('rejected');
        final guard = ProxyRequestGuard(verifier: verifier);
        final gateway = _RecordingNotificationGateway();
        final router = NotificationPreferencesRouter(gateway: gateway);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // ignore: unawaited_futures
        server.listen((request) async {
          await routeRequest(
            request,
            guard,
            notificationPreferencesRouter: router,
          );
        });
        final client = HttpClient();
        try {
          final response = await _http(
            client,
            Uri.parse('http://${server.address.host}:${server.port}')
                .resolve(notificationPreferencesPath),
            method: 'GET',
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, anyOf(401, 403));
        } finally {
          client.close(force: true);
          await server.close(force: true);
        }
      });
    });

    test('PUT requires Idempotency-Key header', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: null,
            body: const <String, Object?>{'enabled': false},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_missing'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PUT round-trips and forwards the actor\'s userId from the JWT',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/email'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-001',
            body: const <String, Object?>{'enabled': false},
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['event_key'], equals('notif.backfill.complete'));
          expect(body['channel'], equals('email'));
          expect(body['enabled'], isFalse);
          expect(body['scope_kind'], equals('operator'));
          expect(body['scope_id'], isNull);
          // Actor's userId came from the JWT, not from the body or URL.
          expect(ctx.gateway.upsertCalls, hasLength(1));
          expect(ctx.gateway.upsertCalls.single['userId'], equals(_kUserA));
          expect(ctx.gateway.upsertCalls.single['operatorId'], equals(_kOpA));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PUT idempotent replay returns the same response', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final first = await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-replay',
            body: const <String, Object?>{'enabled': true},
          );
          final second = await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-replay',
            body: const <String, Object?>{'enabled': true},
          );
          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(first.body, equals(second.body));
          // Gateway saw the call exactly once.
          expect(ctx.gateway.upsertCalls, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PUT 409 idempotency_key_conflict when same key + different body',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-collide',
            body: const <String, Object?>{'enabled': true},
          );
          final second = await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-collide',
            body: const <String, Object?>{'enabled': false},
          );
          expect(second.statusCode, equals(409));
          final body = jsonDecode(second.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_conflict'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant write impossible: gateway always sees JWT operator',
        () async {
      await withRealHttp(() async {
        final verifier = _SettableVerifier();
        final gateway = _RecordingNotificationGateway();
        final guard = ProxyRequestGuard(verifier: verifier);
        final router = NotificationPreferencesRouter(gateway: gateway);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // ignore: unawaited_futures
        server.listen((request) async {
          await routeRequest(
            request,
            guard,
            notificationPreferencesRouter: router,
          );
        });
        final client = HttpClient();
        try {
          // Operator A user A.
          verifier.claims = const ProxyJwtClaims(
            userId: _kUserA,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          await _http(
            client,
            Uri.parse('http://${server.address.host}:${server.port}').resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-a',
            body: const <String, Object?>{'enabled': true},
          );
          // Operator B user B.
          verifier.claims = const ProxyJwtClaims(
            userId: _kUserB,
            operatorId: _kOpB,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          await _http(
            client,
            Uri.parse('http://${server.address.host}:${server.port}').resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-b',
            body: const <String, Object?>{'enabled': true},
          );
          expect(gateway.upsertCalls, hasLength(2));
          expect(gateway.upsertCalls[0]['operatorId'], equals(_kOpA));
          expect(gateway.upsertCalls[0]['userId'], equals(_kUserA));
          expect(gateway.upsertCalls[1]['operatorId'], equals(_kOpB));
          expect(gateway.upsertCalls[1]['userId'], equals(_kUserB));
        } finally {
          client.close(force: true);
          await server.close(force: true);
        }
      });
    });

    test('PUT 400 invalid_channel on unsupported channel', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/sms'
                '?scope_kind=operator'),
            method: 'PUT',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-bad-channel',
            body: const <String, Object?>{'enabled': true},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_channel'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('DELETE removes the row and returns removed=true', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.deleteAffected = true;
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(
                '$notificationPreferencesPath/notif.backfill.complete/push'
                '?scope_kind=operator'),
            method: 'DELETE',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-del',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['removed'], isTrue);
          expect(ctx.gateway.deleteCalls, hasLength(1));
          expect(ctx.gateway.deleteCalls.single['userId'], equals(_kUserA));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when router is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(routerConfigured: false);
        try {
          final response = await _http(
            ctx.client,
            ctx.baseUri.resolve(notificationPreferencesPath),
            method: 'GET',
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            body['error'],
            equals('notification_preferences_router_not_configured'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

NotificationPreference _seedPref({
  required String operatorId,
  required String userId,
  required String eventKey,
  required NotificationChannel channel,
}) {
  return NotificationPreference(
    id: '99999999-9999-9999-9999-999999999999',
    operatorId: operatorId,
    userId: userId,
    eventKey: eventKey,
    channel: channel,
    scopeKind: NotificationScopeKind.operator,
    scopeId: null,
    enabled: true,
    createdAt: DateTime.utc(2026, 5, 7),
    updatedAt: DateTime.utc(2026, 5, 7),
  );
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  Object? error;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final err = error;
    if (err != null) throw err;
    final c = claims;
    if (c == null) {
      throw ProxyJwtVerificationError('no claims set');
    }
    return c;
  }
}

class _RecordingNotificationGateway implements NotificationPreferencesGateway {
  List<NotificationPreference> _listSeed = const <NotificationPreference>[];
  String? lastListOperatorId;
  String? lastListUserId;
  bool deleteAffected = true;

  final List<Map<String, Object?>> upsertCalls = <Map<String, Object?>>[];
  final List<Map<String, Object?>> deleteCalls = <Map<String, Object?>>[];

  void seedListRows(List<NotificationPreference> rows) {
    _listSeed = rows;
  }

  @override
  Future<List<NotificationPreference>> listForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    lastListOperatorId = operatorId;
    lastListUserId = userId;
    return _listSeed;
  }

  @override
  Future<NotificationPreference> upsert({
    required String operatorId,
    required String locationId,
    required String userId,
    required String eventKey,
    required NotificationChannel channel,
    required NotificationScopeKind scopeKind,
    required String? scopeId,
    required bool enabled,
  }) async {
    upsertCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'userId': userId,
      'eventKey': eventKey,
      'channel': channel.wire,
      'scopeKind': scopeKind.wire,
      'scopeId': scopeId,
      'enabled': enabled,
    });
    return NotificationPreference(
      id: '99999999-9999-9999-9999-999999999999',
      operatorId: operatorId,
      userId: userId,
      eventKey: eventKey,
      channel: channel,
      scopeKind: scopeKind,
      scopeId: scopeId,
      enabled: enabled,
      createdAt: DateTime.utc(2026, 5, 7),
      updatedAt: DateTime.utc(2026, 5, 7),
    );
  }

  @override
  Future<bool> delete({
    required String operatorId,
    required String locationId,
    required String userId,
    required String eventKey,
    required NotificationChannel channel,
    required NotificationScopeKind scopeKind,
    required String? scopeId,
  }) async {
    deleteCalls.add(<String, Object?>{
      'operatorId': operatorId,
      'userId': userId,
      'eventKey': eventKey,
      'channel': channel.wire,
    });
    return deleteAffected;
  }
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _http(
  HttpClient client,
  Uri uri, {
  required String method,
  required String authorization,
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
