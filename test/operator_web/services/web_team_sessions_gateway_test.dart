// Phase 11W.4 - Live sessions HTTP gateway wire test.
//
// Pins the route paths + idempotency-key header shape the
// `WebTeamSessionsGatewayLive` impl sends across the wire. Uses
// `MockClient` from `package:http` so the test runs in pure Dart
// (no real network).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/web_team_sessions_gateway.dart';

void main() {
  final Uri kProxyBase = Uri.parse('https://proxy.forgeflow.test');

  Future<String?> tokenProvider() async => 'test-id-token';

  group('WebTeamSessionsGatewayLive', () {
    test('listOwnSessions GETs /v1/auth/sessions with bearer token + no '
        'idempotency key', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessions': <Map<String, Object?>>[
              <String, Object?>{
                'session_id': 's1',
                'created_at': '2026-05-05T14:00:00Z',
                'last_seen_at': '2026-05-05T14:30:00Z',
                'device_label': 'Chrome on macOS',
                'user_agent': 'Mozilla/5.0 (Mac) Chrome/124',
                'geo_city': 'Toronto',
                'geo_country': 'CA',
                'ip': '203.0.113.42',
              },
            ],
          }),
          200,
        );
      });
      final gateway = WebTeamSessionsGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      final result = await gateway.listOwnSessions();

      expect(result.sessions, hasLength(1));
      expect(result.sessions.first.sessionId, 's1');
      expect(result.sessions.first.geoCity, 'Toronto');
      expect(result.sessions.first.geoCountry, 'CA');
      expect(captured.method, 'GET');
      expect(captured.url.scheme, 'https');
      expect(captured.url.host, 'proxy.forgeflow.test');
      expect(captured.url.path, WebTeamSessionsPaths.ownSessions);
      expect(captured.headers['authorization'], 'Bearer test-id-token');
      expect(captured.headers.containsKey('Idempotency-Key'), isFalse);
    });

    test('listOwnSessions never carries the raw IP into the gateway entry '
        '(parity contract: city-level only, never raw IP)', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessions': <Map<String, Object?>>[
              <String, Object?>{
                'session_id': 's1',
                'created_at': '2026-05-05T14:00:00Z',
                'last_seen_at': '2026-05-05T14:30:00Z',
                'device_label': 'Chrome on macOS',
                'user_agent': 'Mozilla/5.0 (Mac) Chrome/124',
                'geo_city': 'Toronto',
                'geo_country': 'CA',
                'ip': '203.0.113.42',
              },
            ],
          }),
          200,
        );
      });
      final gateway = WebTeamSessionsGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      final result = await gateway.listOwnSessions();
      final entry = result.sessions.single;

      // The gateway entry shape carries no `ip` field at all - the
      // dropper is structural rather than runtime, so a future
      // schema regression cannot leak one through.
      final dynamic dynEntry = entry;
      expect(
        () => dynEntry.ip,
        throwsNoSuchMethodError,
        reason: 'WebTeamSessionEntry must NOT expose a raw IP field',
      );
      expect(entry.geoCity, 'Toronto');
      expect(entry.geoCountry, 'CA');
    });

    test('listTeamSessions GETs /v1/auth/team/sessions and includes target '
        'user identity on rows', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessions': <Map<String, Object?>>[
              <String, Object?>{
                'session_id': 's1',
                'created_at': '2026-05-05T14:00:00Z',
                'last_seen_at': '2026-05-05T14:30:00Z',
                'device_label': 'Forge and Flow on iPhone',
                'geo_city': 'Toronto',
                'geo_country': 'CA',
                'user_id': 'u-jordan',
                'display_name': 'Jordan Lee',
                'email': 'jordan.lee@demo.test',
              },
            ],
          }),
          200,
        );
      });
      final gateway = WebTeamSessionsGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      final result = await gateway.listTeamSessions();

      expect(captured.method, 'GET');
      expect(captured.url.path, WebTeamSessionsPaths.teamSessions);
      expect(result.sessions, hasLength(1));
      expect(result.sessions.first.targetUserId, 'u-jordan');
      expect(result.sessions.first.targetUserDisplayName, 'Jordan Lee');
      expect(result.sessions.first.targetUserEmail, 'jordan.lee@demo.test');
    });

    test('revokeSession POSTs /v1/auth/session/revoke with the screen-supplied '
        'idempotency key threaded through', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{'revoked': true}),
          200,
        );
      });
      final gateway = WebTeamSessionsGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      final result = await gateway.revokeSession(
        const WebTeamSessionRevokeCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          sessionId: 'sess-1',
          reason: 'op_web_sessions_revoke',
        ),
        idempotencyKey: 'op-web-sessions-actor-123-1',
      );

      expect(result.revoked, isTrue);
      expect(captured.method, 'POST');
      expect(captured.url.path, WebTeamSessionsPaths.revokeSession);
      expect(
        captured.headers['Idempotency-Key'],
        'op-web-sessions-actor-123-1',
      );
      expect(
        captured.headers['authorization'],
        'Bearer test-id-token',
      );
      final body = jsonDecode(captured.body) as Map<String, Object?>;
      expect(body['session_id'], 'sess-1');
      expect(body['reason'], 'op_web_sessions_revoke');
    });

    test('revokeSession surfaces validation_failed/cannot_revoke_self as a '
        'typed WebTeamSessionsError flagged via isCannotRevokeSelf', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': 'cannot_revoke_self',
            'message': 'Use admin sign-out instead.',
          }),
          400,
        );
      });
      final gateway = WebTeamSessionsGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      WebTeamSessionsError? thrown;
      try {
        await gateway.revokeSession(
          const WebTeamSessionRevokeCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            sessionId: 'sess-self',
          ),
          idempotencyKey: 'op-web-sessions-actor-123-2',
        );
      } on WebTeamSessionsError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.code, 'cannot_revoke_self');
      expect(thrown.statusCode, 400);
      expect(thrown.isCannotRevokeSelf, isTrue);
    });

    test('non-2xx responses surface a typed WebTeamSessionsError with the '
        'proxy-supplied error code', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'error': 'forbidden'}),
          403,
        );
      });
      final gateway = WebTeamSessionsGatewayLive(
        proxyBaseUri: kProxyBase,
        idTokenProvider: tokenProvider,
        httpClient: client,
      );

      WebTeamSessionsError? thrown;
      try {
        await gateway.listTeamSessions();
      } on WebTeamSessionsError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.code, 'forbidden');
      expect(thrown.statusCode, 403);
      expect(thrown.isCannotRevokeSelf, isFalse);
    });
  });
}
