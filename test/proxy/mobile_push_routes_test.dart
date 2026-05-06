import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/mobile_push_notifications.dart';

const String _op = '11111111-1111-1111-1111-111111111111';
const String _loc = '22222222-2222-2222-2222-222222222222';
const String _user = '33333333-3333-3333-3333-333333333333';

void main() {
  group('mobile push token proxy routes', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<
      ({
        HttpServer server,
        HttpClient client,
        Uri baseUri,
        _FakeMobilePushTokenGateway gateway,
      })
    >
    spinUp({bool gatewayConfigured = true}) async {
      final verifier = _SettableVerifier(
        const ProxyJwtClaims(
          userId: _user,
          operatorId: _op,
          locationId: _loc,
          roles: <String>['operator_owner'],
          firebaseUid: 'firebase-uid',
        ),
      );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = _FakeMobilePushTokenGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            mobilePushTokenGateway: gatewayConfigured ? gateway : null,
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

    test('register returns 503 when gateway is not installed', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(gatewayConfigured: false);
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(authMobilePushTokenRegisterPath),
            authorization: 'Bearer fake.token',
            body: _registerBody(),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            body['error'],
            equals('mobile_push_token_gateway_not_configured'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'register routes authenticated scope and never echoes token material',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve(authMobilePushTokenRegisterPath),
              authorization: 'Bearer fake.token',
              body: _registerBody(),
            );
            expect(response.statusCode, equals(200));
            expect(response.body, isNot(contains('raw-fcm-token')));
            expect(response.body, isNot(contains('hash-from-buggy-gateway')));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['ok'], isTrue);
            expect(body['push_token_id'], equals('push-token-id'));
            expect(ctx.gateway.lastRegisterActorUserId, equals(_user));
            expect(ctx.gateway.lastRegisterOperatorId, equals(_op));
            expect(ctx.gateway.lastRegisterLocationId, equals(_loc));
            expect(
              ctx.gateway.lastRegisterBody?['token'],
              equals('raw-fcm-token'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'revoke routes authenticated scope and returns affected count',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpJson(
              ctx.client,
              ctx.baseUri.resolve(authMobilePushTokenRevokePath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'app_variant': 'operator',
                'app_environment': 'staging',
                'installation_id': 'install-1',
              },
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['ok'], isTrue);
            expect(body['revoked_count'], equals(1));
            expect(ctx.gateway.lastRevokeActorUserId, equals(_user));
            expect(
              ctx.gateway.lastRevokeBody?['installation_id'],
              equals('install-1'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

Map<String, Object?> _registerBody() => const <String, Object?>{
  'token': 'raw-fcm-token',
  'platform': 'android',
  'provider': 'fcm',
  'app_variant': 'operator',
  'app_environment': 'staging',
  'installation_id': 'install-1',
  'client_info': <String, Object?>{'app_version': '1.2.3'},
};

class _FakeMobilePushTokenGateway implements MobilePushTokenGateway {
  String? lastRegisterActorUserId;
  String? lastRegisterOperatorId;
  String? lastRegisterLocationId;
  Map<String, Object?>? lastRegisterBody;
  String? lastRevokeActorUserId;
  Map<String, Object?>? lastRevokeBody;

  @override
  Future<Map<String, Object?>> register({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    lastRegisterActorUserId = actorUserId;
    lastRegisterOperatorId = operatorId;
    lastRegisterLocationId = locationId;
    lastRegisterBody = body;
    return <String, Object?>{
      'push_token_id': 'push-token-id',
      'platform': 'android',
      'provider': 'fcm',
      'token': 'raw-fcm-token',
      'token_hash': 'hash-from-buggy-gateway',
    };
  }

  @override
  Future<int> revoke({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    lastRevokeActorUserId = actorUserId;
    lastRevokeBody = body;
    return 1;
  }
}

class _SettableVerifier implements ProxyJwtVerifier {
  const _SettableVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpJson(
  HttpClient client,
  Uri uri, {
  required String authorization,
  required Map<String, Object?> body,
}) async {
  final request = await client.postUrl(uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  request.headers.contentType = ContentType.json;
  final encoded = utf8.encode(jsonEncode(body));
  request.contentLength = encoded.length;
  request.add(encoded);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
