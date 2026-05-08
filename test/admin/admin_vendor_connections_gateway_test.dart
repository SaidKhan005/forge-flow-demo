// Admin per-location vendor connections gateway tests.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/admin/services/admin_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';

void main() {
  const proxyBase = 'https://proxy.forgeflow.test';
  const operatorId = '11111111-1111-4111-8111-111111111111';
  const locationId = '22222222-2222-4222-8222-222222222222';

  Future<String> tokenProvider() async => 'admin-token';

  test(
    'loadBundle uses the admin operator/location integrations route',
    () async {
      late http.Request captured;
      final gateway = AdminHttpVendorConnectionsGateway(
        baseUri: Uri.parse(proxyBase),
        bearerTokenProvider: tokenProvider,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'operator_id': operatorId,
              'location_id': locationId,
              'location_name': 'Harbour',
              'connections': <Object?>[
                <String, Object?>{
                  'connection_id': 'conn-toast',
                  'vendor_id': 'toast',
                  'category': 'pos',
                  'status': 'connected',
                  'first_backfill': <String, Object?>{
                    'status': 'running',
                    'processed_days': 12,
                    'total_days': 60,
                  },
                },
              ],
              'demo_flags': const <String, Object?>{
                'pos': false,
                'labor': true,
                'reservation': true,
              },
            }),
            200,
          );
        }),
      );

      final bundle = await gateway.loadBundle(
        operatorId: operatorId,
        locationId: locationId,
      );

      expect(captured.method, 'GET');
      expect(
        captured.url.path,
        '/v1/admin/operators/$operatorId/locations/$locationId/integrations',
      );
      expect(captured.headers['authorization'], 'Bearer admin-token');
      expect(bundle.locationName, 'Harbour');
      expect(bundle.posConnection!.vendorId, 'toast');
      expect(
        bundle.posConnection!.firstBackfill!.status,
        VendorConnectionFirstBackfillStatus.running,
      );
      expect(bundle.demoFlags[VendorCategory.pos], isFalse);
    },
  );

  test(
    'admin writes include operator/location scope and idempotency headers',
    () async {
      var idempotencyCounter = 0;
      final captured = <_CapturedRequest>[];
      final gateway = AdminHttpVendorConnectionsGateway(
        baseUri: Uri.parse(proxyBase),
        bearerTokenProvider: tokenProvider,
        idempotencyKeyFactory: () {
          idempotencyCounter += 1;
          return 'idem-$idempotencyCounter';
        },
        httpClient: MockClient((request) async {
          captured.add(_CapturedRequest.from(request));
          if (request.url.path.endsWith('/start')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'redirect_url': 'https://vendor.example/oauth',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/connect-key')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'connection_id': 'conn-toast',
                'connected_at': '2026-05-08T12:00:00.000Z',
                'first_backfill_status': 'enqueued',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/test-connection')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'auth_valid': true,
                'elapsed_ms': 11,
                'sample_summary': 'ok',
                'field_mapping': const <String, Object?>{'covers': '4'},
              }),
              200,
            );
          }
          return http.Response(jsonEncode(<String, Object?>{'ok': true}), 200);
        }),
      );

      final flow = await gateway.startConnect(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'square',
        module: 'restaurants',
      );
      final connect = await gateway.connectWithApiKey(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        apiKey: 'toast-key',
        apiSecret: 'restaurant-guid',
      );
      final diagnostic = await gateway.testConnection(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
      );
      await gateway.disconnect(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        reason: 'qa',
      );

      expect(flow.redirectUrl, 'https://vendor.example/oauth');
      expect(connect.firstBackfillStarted, isTrue);
      expect(diagnostic.fieldMapping['covers'], '4');
      expect(
        captured.map((request) => request.path),
        containsAllInOrder(<String>[
          '/v1/admin/integrations/oauth/square/start',
          '/v1/admin/integrations/toast/connect-key',
          '/v1/admin/integrations/toast/test-connection',
          '/v1/admin/integrations/toast/disconnect',
        ]),
      );
      for (var i = 0; i < captured.length; i += 1) {
        final request = captured[i];
        expect(request.headers['authorization'], 'Bearer admin-token');
        expect(request.headers['Idempotency-Key'], 'idem-${i + 1}');
        expect(request.body['operator_id'], operatorId);
        expect(request.body['location_id'], locationId);
      }
      expect(captured[1].body['api_key'], 'toast-key');
      expect(captured[1].body['username'], 'restaurant-guid');
      expect(captured[1].body.containsKey('api_secret'), isFalse);
    },
  );

  test(
    'loadLogs uses the admin sync-log route with location query scope',
    () async {
      late http.Request captured;
      final gateway = AdminHttpVendorConnectionsGateway(
        baseUri: Uri.parse(proxyBase),
        bearerTokenProvider: tokenProvider,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'logs': <Object?>[
                <String, Object?>{
                  'occurred_at': '2026-05-08T13:00:00.000Z',
                  'event_kind': 'poll_success',
                  'records_count': 3,
                },
              ],
            }),
            200,
          );
        }),
      );

      final logs = await gateway.loadLogs(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        limit: 25,
      );

      expect(captured.method, 'GET');
      expect(captured.url.path, '/v1/admin/integrations/toast/logs');
      expect(captured.url.queryParameters['operator_id'], operatorId);
      expect(captured.url.queryParameters['location_id'], locationId);
      expect(captured.url.queryParameters['limit'], '25');
      expect(logs.single.eventKind, 'poll_success');
      expect(logs.single.recordsCount, 3);
    },
  );

  test('blank location id fails before hitting the proxy', () async {
    final gateway = AdminHttpVendorConnectionsGateway(
      baseUri: Uri.parse(proxyBase),
      bearerTokenProvider: tokenProvider,
      httpClient: MockClient((request) async {
        throw StateError('proxy must not be hit without a location');
      }),
    );

    await expectLater(
      gateway.loadBundle(operatorId: operatorId, locationId: ' '),
      throwsA(isA<VendorConnectionsGatewayError>()),
    );
  });
}

class _CapturedRequest {
  const _CapturedRequest({
    required this.path,
    required this.headers,
    required this.body,
  });

  final String path;
  final Map<String, String> headers;
  final Map<String, Object?> body;

  static _CapturedRequest from(http.Request request) {
    Map<String, Object?> body = const <String, Object?>{};
    if (request.body.isNotEmpty) {
      body = (jsonDecode(request.body) as Map).cast<String, Object?>();
    }
    return _CapturedRequest(
      path: request.url.path,
      headers: Map<String, String>.from(request.headers),
      body: body,
    );
  }
}
