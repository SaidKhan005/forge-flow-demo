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
      );
      return HttpWebAccountGateway(
        client: client,
        idTokenProvider: () async => token,
      );
    }

    test('uses operator-scoped path (never /admin/)', () {
      expect(HttpWebAccountGateway.operatorAccountPath, '/v1/operator/account');
      expect(
        HttpWebAccountGateway.operatorAccountPath.contains('/admin/'),
        isFalse,
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
      await gateway.patchAccount(
        const AccountIdentityPatch(clearLogo: true),
      );
      final json =
          jsonDecode(capturedRequests.single.body) as Map<String, Object?>;
      expect(json.containsKey('logoUrl'), isTrue);
      expect(json['logoUrl'], isNull);
    });

    test('parses 200 response into AccountIdentity', () async {
      final gateway = buildGateway();
      final identity =
          await gateway.patchAccount(const AccountIdentityPatch());
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
      final identity =
          await gateway.patchAccount(const AccountIdentityPatch());
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
  });
}
