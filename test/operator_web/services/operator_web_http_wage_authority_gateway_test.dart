// Phase 8 W5.A.2 - HTTP wage authority gateway tests.
//
// Coverage:
//   * GET round-trip parses the proxy `_wageRoleRowJson` shape
//   * POST sends `Idempotency-Key` and the upsert body
//   * DELETE sends `Idempotency-Key`
//   * 4xx error surfaces a plain-English message via
//     WageAuthorityGatewayException
//   * missing id token short-circuits before any HTTP call

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_wage_authority_gateway.dart';

void main() {
  group('OperatorWebHttpWageAuthorityGateway', () {
    late List<http.Request> capturedRequests;

    Map<String, Object?> rowPayload({
      String serverId = 'row-1',
      String roleName = 'Server',
      String laborBucket = 'foh',
      double hourlyRate = 18.50,
    }) {
      return <String, Object?>{
        'server_id': serverId,
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'restaurant_id': 'rest-1',
        'role_name': roleName,
        'labor_bucket': laborBucket,
        'hourly_rate': hourlyRate,
        'weighted_hours': 32.0,
        'job_code': null,
        'vendor_id': null,
        'vendor_role_id': null,
        'source': 'operator_manual',
        'is_active': true,
        'effective_at': '2026-05-07T12:00:00Z',
        'metadata': <String, Object?>{},
        'created_at': '2026-05-07T12:00:00Z',
        'updated_at': '2026-05-07T12:00:00Z',
        'updated_by': 'user-1',
      };
    }

    OperatorWebHttpWageAuthorityGateway buildGateway({
      String? token = 'demo-id-token',
      List<http.Response> Function()? responses,
    }) {
      capturedRequests = <http.Request>[];
      var index = 0;
      final mock = MockClient((request) async {
        capturedRequests.add(request);
        if (responses == null) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'wage_role_rows': <Map<String, Object?>>[rowPayload()],
              'next_cursor': null,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        }
        final list = responses();
        return list[index++];
      });
      return OperatorWebHttpWageAuthorityGateway(
        proxyBaseUri: Uri.parse('https://proxy.test/'),
        idTokenProvider: () async => token,
        client: mock,
      );
    }

    test('list parses the proxy `wage_role_rows` envelope', () async {
      final gateway = buildGateway();
      final rows = await gateway.list(operatorId: 'op-1', locationId: 'loc-1');

      expect(rows, hasLength(1));
      expect(rows.single.wageRoleRowId, 'row-1');
      expect(rows.single.roleName, 'Server');
      expect(rows.single.laborBucket, 'foh');
      expect(rows.single.hourlyRate, 18.50);
      final request = capturedRequests.single;
      expect(request.method, 'GET');
      expect(
        request.url.path,
        '/v1/operators/op-1/locations/loc-1/wage_role_rows',
      );
      expect(request.headers['authorization'], 'Bearer demo-id-token');
    });

    test('upsert sends Idempotency-Key + the request body', () async {
      final gateway = buildGateway(
        responses: () => <http.Response>[
          http.Response(
            jsonEncode(rowPayload()),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
        ],
      );
      final saved = await gateway.upsert(
        request: const WageRoleRowUpsert(
          restaurantId: 'rest-1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 18.50,
          weightedHours: 32,
        ),
        idempotencyKey: 'idem-upsert-1',
      );
      expect(saved.wageRoleRowId, 'row-1');
      final request = capturedRequests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/operator/wage-role-rows');
      expect(request.headers['Idempotency-Key'], 'idem-upsert-1');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['restaurant_id'], 'rest-1');
      expect(body['role_name'], 'Server');
      expect(body['labor_bucket'], 'foh');
      expect(body['hourly_rate'], 18.50);
      expect(body['weighted_hours'], 32);
    });

    test('delete sends Idempotency-Key', () async {
      final gateway = buildGateway(
        responses: () => <http.Response>[
          http.Response(
            jsonEncode(<String, Object?>{
              'wage_role_row_id': 'row-1',
              'removed': true,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
        ],
      );
      final removed = await gateway.delete(
        wageRoleRowId: 'row-1',
        idempotencyKey: 'idem-delete-1',
      );
      expect(removed, isTrue);
      final request = capturedRequests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/v1/operator/wage-role-rows/row-1');
      expect(request.headers['Idempotency-Key'], 'idem-delete-1');
    });

    test('4xx surfaces a plain-English message', () async {
      final gateway = buildGateway(
        responses: () => <http.Response>[
          http.Response(
            jsonEncode(<String, Object?>{
              'error': 'invalid_role_name',
              'message': 'role_name must not be blank',
            }),
            400,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
        ],
      );
      try {
        await gateway.upsert(
          request: const WageRoleRowUpsert(
            restaurantId: 'rest-1',
            roleName: '',
            laborBucket: 'foh',
            hourlyRate: 0,
            weightedHours: 0,
          ),
          idempotencyKey: 'idem-1',
        );
        fail('expected WageAuthorityGatewayException');
      } on WageAuthorityGatewayException catch (error) {
        expect(error.statusCode, 400);
        expect(error.code, 'invalid_role_name');
        expect(error.message, 'role_name must not be blank');
      }
    });

    test('missing id token throws before any HTTP call', () async {
      final gateway = buildGateway(token: null);
      expect(
        () => gateway.list(operatorId: 'op-1', locationId: 'loc-1'),
        throwsA(isA<WageAuthorityGatewayException>()),
      );
      expect(capturedRequests, isEmpty);
    });

    test('upsert request omits null optional fields', () async {
      final gateway = buildGateway(
        responses: () => <http.Response>[
          http.Response(
            jsonEncode(rowPayload()),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
        ],
      );
      await gateway.upsert(
        request: const WageRoleRowUpsert(
          restaurantId: 'rest-1',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 18.50,
          weightedHours: 32,
        ),
        idempotencyKey: 'idem-1',
      );
      final body = jsonDecode(capturedRequests.single.body)
          as Map<String, Object?>;
      // Optional fields missing → omitted from the wire body.
      expect(body.containsKey('job_code'), isFalse);
      expect(body.containsKey('vendor_id'), isFalse);
      expect(body.containsKey('vendor_role_id'), isFalse);
      expect(body.containsKey('source'), isFalse);
      expect(body.containsKey('metadata'), isFalse);
    });
  });

  group('WageRoleRowUpsert', () {
    test('toJson includes optional fields when set', () {
      final upsert = const WageRoleRowUpsert(
        restaurantId: 'rest-1',
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 18.50,
        weightedHours: 32,
        jobCode: 'JC-100',
        vendorId: 'vendor-1',
        vendorRoleId: 'vendor-role-1',
        source: WageRoleRowSource.operatorManual,
        metadata: <String, Object?>{'note': 'demo'},
      );
      final json = upsert.toJson();
      expect(json['job_code'], 'JC-100');
      expect(json['vendor_id'], 'vendor-1');
      expect(json['vendor_role_id'], 'vendor-role-1');
      expect(json['source'], 'operator_manual');
      expect(json['metadata'], isA<Map<String, Object?>>());
    });
  });
}
