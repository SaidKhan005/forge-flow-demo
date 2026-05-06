// Phase 11W.8 - Operator web vendor connections live gateway tests.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_vendor_connections_gateway.dart';

void main() {
  const proxyBase = 'https://proxy.forgeflow.test';

  Future<String?> tokenProvider() async => 'id-token';

  test('loadBundle uses operator self-service auth route', () async {
    late http.Request captured;
    final gateway = OperatorWebHttpVendorConnectionsGateway(
      proxyClient: OperatorWebProxyClient(
        baseUri: Uri.parse(proxyBase),
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'operator_id': 'op-1',
              'location_id': 'loc-1',
              'connections': const <Object?>[],
              'demo_flags': const <String, Object?>{
                'pos': true,
                'labor': true,
                'reservation': true,
              },
            }),
            200,
          );
        }),
      ),
      idTokenProvider: tokenProvider,
    );

    final bundle = await gateway.loadBundle(
      operatorId: 'op-1',
      locationId: 'loc-1',
    );

    expect(captured.method, 'GET');
    expect(captured.url.path, '/v1/auth/locations/loc-1/integrations');
    expect(captured.headers['authorization'], 'Bearer id-token');
    expect(bundle.operatorId, 'op-1');
    expect(bundle.demoFlags.values, everyElement(isTrue));
  });

  test('write helpers stay on auth self-service routes', () async {
    final captured = <http.Request>[];
    final gateway = OperatorWebHttpVendorConnectionsGateway(
      proxyClient: OperatorWebProxyClient(
        baseUri: Uri.parse(proxyBase),
        httpClient: MockClient((request) async {
          captured.add(request);
          if (request.url.path.endsWith('/start') ||
              request.url.path.endsWith('/connect-key')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'redirect_url': 'https://vendor.example/connect',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/test-connection')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'auth_valid': true,
                'elapsed_ms': 10,
                'sample_summary': 'ok',
                'field_mapping': const <String, Object?>{},
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/logs')) {
            return http.Response(
              jsonEncode(<String, Object?>{'logs': const <Object?>[]}),
              200,
            );
          }
          return http.Response(jsonEncode(<String, Object?>{'ok': true}), 200);
        }),
      ),
      idTokenProvider: tokenProvider,
    );

    await gateway.startConnect(
      operatorId: 'op-1',
      locationId: 'loc-1',
      vendorId: 'toast',
    );
    await gateway.startConnect(
      operatorId: 'op-1',
      locationId: 'loc-1',
      vendorId: 'humanity',
    );
    await gateway.testConnection(
      operatorId: 'op-1',
      locationId: 'loc-1',
      vendorId: 'toast',
    );
    await gateway.disconnect(
      operatorId: 'op-1',
      locationId: 'loc-1',
      vendorId: 'toast',
      reason: 'qa',
    );
    await gateway.loadLogs(
      operatorId: 'op-1',
      locationId: 'loc-1',
      vendorId: 'toast',
    );

    expect(
      captured.map((request) => request.url.path),
      containsAllInOrder(<String>[
        '/v1/auth/integrations/oauth/toast/start',
        '/v1/auth/integrations/humanity/connect-key',
        '/v1/auth/integrations/toast/test-connection',
        '/v1/auth/integrations/toast/disconnect',
        '/v1/auth/integrations/toast/logs',
      ]),
    );
    for (final request in captured) {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['operator_id'], isNull);
        expect(body['location_id'], 'loc-1');
      }
    }
  });
}
