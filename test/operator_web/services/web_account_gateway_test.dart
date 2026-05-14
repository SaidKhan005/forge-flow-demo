// Phase 11W.7 / Wave A2 - WebAccountGateway tests.
//
// Pin the contract that the A2-backend lane implements:
//   - PATCH /v1/operator/account
//   - Idempotency-Key on every write
//   - Authorization: Bearer <token>
//   - JSON body shape (partial PATCH)
//   - Response shape parsing
//   - 401 / 403 / 503 mapping
//   - Operator-scoped path (NOT /v1/admin/*)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/auth/mfa_freshness_redirect_listener.dart';
import 'package:forge_and_flow/operator_web/account/operator_web_account_actions.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_team_gateway_providers.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/web_account_gateway.dart';

void main() {
  group('HttpWebAccountGateway', () {
    late List<http.Request> capturedRequests;
    late List<int> sequenceStatuses;
    late List<Map<String, Object?>> sequenceBodies;

    setUp(() {
      capturedRequests = <http.Request>[];
      sequenceStatuses = <int>[200];
      sequenceBodies = <Map<String, Object?>>[
        <String, Object?>{
          'operatorId': 'op-1',
          'businessName': 'Brio Restaurants',
          'logoUrl': 'https://cdn.brio.example/logo.png',
          'currencyCode': 'USD',
          'localeTag': 'en-US',
          'weekStartDay': 'monday',
          'rolloverHour': 4,
          'updatedAt': '2026-05-06T18:00:00.000Z',
        },
      ];
    });

    HttpWebAccountGateway buildGateway({
      String? token = 'demo-id-token',
      MfaFreshnessRedirectListener? freshnessListener,
      DateTime Function()? now,
    }) {
      var index = 0;
      final mock = MockClient((request) async {
        capturedRequests.add(request);
        final status = sequenceStatuses[index];
        final body = sequenceBodies[index];
        index++;
        return http.Response(
          jsonEncode(body),
          status,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = OperatorWebProxyClient(
        baseUri: Uri.parse('https://proxy.test/'),
        httpClient: mock,
        idempotencyKeyFactory: () => 'idem-key-fixture',
        mfaFreshnessRedirectListener: freshnessListener,
      );
      return HttpWebAccountGateway(
        client: client,
        idTokenProvider: () async => token,
        now: now,
      );
    }

    test('uses operator-scoped path (never /admin/)', () {
      expect(HttpWebAccountGateway.operatorAccountPath, '/v1/operator/account');
      expect(HttpWebAccountGateway.activeSessionsPath, '/v1/auth/sessions');
      expect(
        HttpWebAccountGateway.revokeSessionPath,
        '/v1/auth/session/revoke',
      );
      expect(
        HttpWebAccountGateway.operatorAccountPath.contains('/admin/'),
        isFalse,
      );
      expect(
        HttpWebAccountGateway.activeSessionsPath.contains('/admin/'),
        isFalse,
      );
      expect(
        HttpWebAccountGateway.revokeSessionPath.contains('revoke-all'),
        isFalse,
      );
    });

    // 11W.7 ops-debt - GET /v1/operator/account companion. The
    // Settings shell hydrates the AccountScreen by GETting the
    // operator row before letting the user PATCH it.
    test(
      'GET hits /v1/operator/account with Bearer auth + parses 200',
      () async {
        final gateway = buildGateway();
        final identity = await gateway.getAccount();
        expect(capturedRequests, hasLength(1));
        final request = capturedRequests.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/operator/account');
        expect(request.headers['authorization'], 'Bearer demo-id-token');
        expect(identity.operatorId, 'op-1');
        expect(identity.businessName, 'Brio Restaurants');
      },
    );

    test(
      'active sessions GET uses existing self-service route + parses 200',
      () async {
        sequenceBodies = <Map<String, Object?>>[
          <String, Object?>{
            'sessions': <Map<String, Object?>>[
              <String, Object?>{
                'session_id': 'session-current',
                'device_label': 'Safari on Mac',
                'user_agent': 'Mozilla/5.0',
                'device_fingerprint': 'fp-current',
                'geo_city': 'Portland',
                'geo_country': 'US',
                'ip': '203.0.113.10',
                'created_at': '2026-05-01T12:00:00.000Z',
                'last_seen_at': '2026-05-06T18:00:00.000Z',
              },
            ],
          },
        ];
        final gateway = buildGateway();

        final listed = await gateway.listActiveSessions();

        expect(capturedRequests, hasLength(1));
        final request = capturedRequests.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/auth/sessions');
        expect(request.headers['authorization'], 'Bearer demo-id-token');
        expect(listed.sessions, hasLength(1));
        final session = listed.sessions.single;
        expect(session.sessionId, 'session-current');
        expect(session.deviceLabel, 'Safari on Mac');
        expect(session.geoCity, 'Portland');
        expect(session.lastActiveAt.isUtc, isTrue);
      },
    );

    test(
      'signOutOtherSessions revokes each supplied id via single revoke route',
      () async {
        sequenceStatuses = <int>[200, 200];
        sequenceBodies = <Map<String, Object?>>[
          <String, Object?>{'ok': true},
          <String, Object?>{'revoked': true},
        ];
        final now = DateTime.utc(2026, 5, 6, 18, 30);
        final token = _idTokenWithAuthTime(
          now.subtract(const Duration(minutes: 5)),
        );
        final gateway = buildGateway(token: token, now: () => now);

        final result = await gateway.signOutOtherSessions(
          sessionIds: <String>[' session-a ', 'session-a', '', 'session-b'],
        );

        expect(result.revokedCount, 2);
        expect(capturedRequests, hasLength(2));
        expect(
          capturedRequests.map((request) => request.url.path),
          everyElement(equals('/v1/auth/session/revoke')),
        );
        expect(
          capturedRequests.any(
            (request) => request.url.path.contains('revoke-all'),
          ),
          isFalse,
        );
        for (final request in capturedRequests) {
          expect(request.method, 'POST');
          expect(request.headers['idempotency-key'], 'idem-key-fixture');
          expect(request.headers['authorization'], 'Bearer $token');
          final json = jsonDecode(request.body) as Map<String, Object?>;
          expect(json['reason'], 'my_account.sign_out_other_sessions');
        }
        final firstBody =
            jsonDecode(capturedRequests.first.body) as Map<String, Object?>;
        final secondBody =
            jsonDecode(capturedRequests.last.body) as Map<String, Object?>;
        expect(firstBody['session_id'], 'session-a');
        expect(secondBody['session_id'], 'session-b');
      },
    );

    test(
      'signOutOtherSessions requires fresh auth_time before revoke',
      () async {
        final now = DateTime.utc(2026, 5, 6, 18, 30);
        final gateway = buildGateway(
          token: _idTokenWithAuthTime(now.subtract(const Duration(hours: 2))),
          now: () => now,
        );

        await expectLater(
          () => gateway.signOutOtherSessions(sessionIds: <String>['session-a']),
          throwsA(
            isA<AccountSessionFreshMfaRequiredException>().having(
              (error) => error.isMfaFreshnessRedirect,
              'isMfaFreshnessRedirect',
              isTrue,
            ),
          ),
        );
        expect(capturedRequests, isEmpty);
      },
    );

    test('GET surfaces 503 as a typed OperatorWebProxyException', () async {
      sequenceStatuses = <int>[503];
      sequenceBodies = <Map<String, Object?>>[
        <String, Object?>{'error': 'account_unavailable', 'message': 'offline'},
      ];
      final gateway = buildGateway();
      await expectLater(
        () => gateway.getAccount(),
        throwsA(
          isA<OperatorWebProxyException>().having(
            (e) => e.code,
            'code',
            'account_unavailable',
          ),
        ),
      );
    });

    test('PATCH carries Idempotency-Key + Bearer auth + JSON body', () async {
      final gateway = buildGateway();
      await gateway.patchAccount(
        const AccountIdentityPatch(
          businessName: 'Brio Restaurants',
          currencyCode: 'USD',
          localeTag: 'en-US',
          weekStartDay: 'monday',
          rolloverHour: 4,
        ),
      );
      expect(capturedRequests, hasLength(1));
      final request = capturedRequests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/v1/operator/account');
      expect(request.headers['idempotency-key'], 'idem-key-fixture');
      expect(request.headers['authorization'], 'Bearer demo-id-token');
      final json = jsonDecode(request.body) as Map<String, Object?>;
      expect(json['businessName'], 'Brio Restaurants');
      expect(json['currencyCode'], 'USD');
      expect(json['localeTag'], 'en-US');
      expect(json['weekStartDay'], 'monday');
      expect(json['rolloverHour'], 4);
    });

    test('partial patch only includes non-null fields', () async {
      final gateway = buildGateway();
      await gateway.patchAccount(
        const AccountIdentityPatch(currencyCode: 'CAD'),
      );
      final json =
          jsonDecode(capturedRequests.single.body) as Map<String, Object?>;
      expect(json.keys, containsAll(<String>['currencyCode']));
      expect(json.containsKey('businessName'), isFalse);
      expect(json.containsKey('logoUrl'), isFalse);
      expect(json.containsKey('localeTag'), isFalse);
    });

    test('clearLogo serializes logoUrl: null distinct from omission', () async {
      final gateway = buildGateway();
      await gateway.patchAccount(const AccountIdentityPatch(clearLogo: true));
      final json =
          jsonDecode(capturedRequests.single.body) as Map<String, Object?>;
      expect(json.containsKey('logoUrl'), isTrue);
      expect(json['logoUrl'], isNull);
    });

    test('parses 200 response into AccountIdentity', () async {
      final gateway = buildGateway();
      final identity = await gateway.patchAccount(const AccountIdentityPatch());
      expect(identity.operatorId, 'op-1');
      expect(identity.businessName, 'Brio Restaurants');
      expect(identity.logoUrl, 'https://cdn.brio.example/logo.png');
      expect(identity.currencyCode, 'USD');
      expect(identity.localeTag, 'en-US');
      expect(identity.weekStartDay, 'monday');
      expect(identity.rolloverHour, 4);
      expect(identity.updatedAt.isUtc, isTrue);
    });

    test('null logoUrl in response surfaces as Dart null', () async {
      sequenceBodies = <Map<String, Object?>>[
        <String, Object?>{
          'operatorId': 'op-2',
          'businessName': 'Demo Co',
          'logoUrl': null,
          'currencyCode': 'CAD',
          'localeTag': 'en-CA',
          'weekStartDay': 'monday',
          'rolloverHour': 3,
          'updatedAt': '2026-05-06T18:00:00.000Z',
        },
      ];
      final gateway = buildGateway();
      final identity = await gateway.patchAccount(const AccountIdentityPatch());
      expect(identity.logoUrl, isNull);
    });

    test('missing token raises unauthenticated', () async {
      final gateway = buildGateway(token: '');
      await expectLater(
        () => gateway.patchAccount(const AccountIdentityPatch()),
        throwsA(
          isA<OperatorWebProxyException>().having(
            (e) => e.code,
            'code',
            'unauthenticated',
          ),
        ),
      );
      // No request should have hit the wire when token was empty.
      expect(capturedRequests, isEmpty);
    });

    test('proxy 403 maps to OperatorWebProxyException with code', () async {
      sequenceStatuses = <int>[403];
      sequenceBodies = <Map<String, Object?>>[
        <String, Object?>{
          'error': 'forbidden',
          'message':
              'Only operator owners and admins can change business identity.',
        },
      ];
      final gateway = buildGateway();
      await expectLater(
        () => gateway.patchAccount(const AccountIdentityPatch()),
        throwsA(
          isA<OperatorWebProxyException>().having(
            (e) => e.code,
            'code',
            'forbidden',
          ),
        ),
      );
    });

    test('proxy 503 maps to unavailable error', () async {
      sequenceStatuses = <int>[503];
      sequenceBodies = <Map<String, Object?>>[
        <String, Object?>{
          'error': 'account_unavailable',
          'message': 'The account write surface is offline.',
        },
      ];
      final gateway = buildGateway();
      await expectLater(
        () => gateway.patchAccount(const AccountIdentityPatch()),
        throwsA(
          isA<OperatorWebProxyException>().having(
            (e) => e.code,
            'code',
            'account_unavailable',
          ),
        ),
      );
    });

    test('malformed response throws malformed_account_identity', () async {
      sequenceBodies = <Map<String, Object?>>[
        <String, Object?>{'operatorId': 'op-1'},
      ];
      final gateway = buildGateway();
      await expectLater(
        () => gateway.patchAccount(const AccountIdentityPatch()),
        throwsA(
          isA<OperatorWebProxyException>().having(
            (e) => e.code,
            'code',
            'malformed_account_identity',
          ),
        ),
      );
    });

    // Wave 2 W-6 — location timezone PATCH.

    test(
      'patchLocationTimezone hits /v1/operator/location-timezone with '
      'Bearer + Idempotency-Key + JSON body',
      () async {
        sequenceStatuses = <int>[200];
        sequenceBodies = <Map<String, Object?>>[
          <String, Object?>{
            'operatorId': 'op-1',
            'locationId': 'loc-1',
            'ianaTimezone': 'America/Toronto',
            'updatedAt': '2026-05-14T12:00:00.000Z',
          },
        ];
        final gateway = buildGateway();
        final result = await gateway.patchLocationTimezone(
          const AccountLocationTimezonePatch(ianaTimezone: 'America/Toronto'),
        );
        expect(capturedRequests, hasLength(1));
        final request = capturedRequests.single;
        expect(request.method, 'PATCH');
        expect(request.url.path, '/v1/operator/location-timezone');
        expect(request.headers['authorization'], 'Bearer demo-id-token');
        expect(request.headers['idempotency-key'], 'idem-key-fixture');
        final json = jsonDecode(request.body) as Map<String, Object?>;
        expect(json['ianaTimezone'], 'America/Toronto');
        expect(result.operatorId, 'op-1');
        expect(result.locationId, 'loc-1');
        expect(result.ianaTimezone, 'America/Toronto');
        expect(result.updatedAt.isUtc, isTrue);
      },
    );

    test(
      'patchLocationTimezone path is operator-scoped (never /admin/)',
      () {
        expect(
          HttpWebAccountGateway.operatorLocationTimezonePath,
          '/v1/operator/location-timezone',
        );
        expect(
          HttpWebAccountGateway.operatorLocationTimezonePath.contains(
            '/admin/',
          ),
          isFalse,
        );
      },
    );

    test(
      'patchLocationTimezone surfaces malformed proxy response as code',
      () async {
        sequenceStatuses = <int>[200];
        sequenceBodies = <Map<String, Object?>>[
          // Missing ianaTimezone + updatedAt -> the parser refuses.
          <String, Object?>{'operatorId': 'op-1', 'locationId': 'loc-1'},
        ];
        final gateway = buildGateway();
        await expectLater(
          () => gateway.patchLocationTimezone(
            const AccountLocationTimezonePatch(ianaTimezone: 'UTC'),
          ),
          throwsA(
            isA<OperatorWebProxyException>().having(
              (e) => e.code,
              'code',
              'malformed_location_timezone',
            ),
          ),
        );
      },
    );

    test(
      'patchLocationTimezone refuses to fire when no token is available',
      () async {
        final gateway = buildGateway(token: '');
        await expectLater(
          () => gateway.patchLocationTimezone(
            const AccountLocationTimezonePatch(ianaTimezone: 'UTC'),
          ),
          throwsA(
            isA<OperatorWebProxyException>().having(
              (e) => e.code,
              'code',
              'unauthenticated',
            ),
          ),
        );
        expect(capturedRequests, isEmpty);
      },
    );
  });

  group('OperatorWebAccountActions session freshness', () {
    test(
      'dispatches the existing fresh-MFA listener for client-side gate',
      () async {
        final actions = _FreshnessDispatchAccountActions();

        await expectLater(
          () => actions.signOutOtherAccountSessions(
            sessionIds: const <String>['session-a'],
          ),
          throwsA(isA<AccountSessionFreshMfaRequiredException>()),
        );

        expect(actions.events, hasLength(1));
        expect(
          actions.events.single.redirectUri,
          '/auth/login?reason=fresh_mfa_required',
        );
      },
    );
  });
}

String _idTokenWithAuthTime(DateTime authTime) {
  String encode(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final seconds = authTime.toUtc().millisecondsSinceEpoch ~/ 1000;
  return '${encode(<String, Object?>{'alg': 'none'})}.'
      '${encode(<String, Object?>{'auth_time': seconds})}.sig';
}

class _FreshnessDispatchAccountActions extends OperatorWebAccountActions
    implements OperatorWebAccountGatewayProvider, MfaFreshnessRedirectListener {
  _FreshnessDispatchAccountActions()
    : accountGateway = _FreshnessRequiredGateway();

  @override
  final WebAccountGateway accountGateway;

  final List<MfaFreshnessRedirectPayload> events =
      <MfaFreshnessRedirectPayload>[];

  @override
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) {
    throw UnimplementedError();
  }

  @override
  void onMfaFreshnessRedirect(MfaFreshnessRedirectPayload payload) {
    events.add(payload);
  }
}

class _FreshnessRequiredGateway
    implements WebAccountGateway, WebAccountSessionGateway {
  @override
  Future<AccountIdentity> getAccount() {
    throw UnimplementedError();
  }

  @override
  Future<AccountActiveSessionsListed> listActiveSessions() {
    throw UnimplementedError();
  }

  @override
  Future<AccountIdentity> patchAccount(AccountIdentityPatch patch) {
    throw UnimplementedError();
  }

  @override
  Future<AccountLocationTimezone> patchLocationTimezone(
    AccountLocationTimezonePatch patch,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<SelfProfilePatchResult> patchSelfProfile(
    SelfProfilePatchPayload patch,
  ) {
    throw const AccountSessionFreshMfaRequiredException();
  }

  @override
  Future<AccountSessionSignOutOthersResult> signOutOtherSessions({
    required Iterable<String> sessionIds,
  }) {
    throw const AccountSessionFreshMfaRequiredException();
  }
}
