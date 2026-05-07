// Phase 11W.8 - Operator web vendor connections live gateway tests.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_gateway.dart';
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

  test(
    'startConnect / test-connection / disconnect target the operator-facing '
    'PR #283 routes',
    () async {
      final captured = <http.Request>[];
      final gateway = OperatorWebHttpVendorConnectionsGateway(
        proxyClient: OperatorWebProxyClient(
          baseUri: Uri.parse(proxyBase),
          httpClient: MockClient((request) async {
            captured.add(request);
            if (request.url.path.endsWith('/begin')) {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'authorization_url': 'https://vendor.example/oauth/consent',
                  'state_token': 'state-stub',
                  'vendor_id': 'toast',
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/connect')) {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'connection_id': 'conn-1',
                  'status': 'connected',
                  'vendor_id': 'humanity',
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/test-connection')) {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'ok': true,
                  'auth_valid': true,
                  'elapsed_ms': 10,
                  'message': 'ok',
                  'sample_summary': 'ok',
                  'field_mapping': const <String, Object?>{},
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode(<String, Object?>{'ok': true}),
              200,
            );
          }),
        ),
        idTokenProvider: tokenProvider,
      );

      final oauthFlow = await gateway.startConnect(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'toast',
      );
      expect(
        oauthFlow.redirectUrl,
        equals('https://vendor.example/oauth/consent'),
      );

      final keyPasteFlow = await gateway.startConnect(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'humanity',
      );
      // api-key connect routes do not return a redirect URL; the
      // gateway returns an empty string so the widget renders the
      // local key-paste form rather than navigating away.
      expect(keyPasteFlow.redirectUrl, isEmpty);

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

      expect(
        captured.map((request) => request.url.path),
        containsAllInOrder(<String>[
          '/v1/integrations/oauth/toast/begin',
          '/v1/integrations/api-key/humanity/connect',
          '/v1/integrations/toast/test-connection',
          '/v1/integrations/toast/disconnect',
        ]),
      );
      for (final request in captured) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          expect(body['operator_id'], isNull);
          expect(body['location_id'], 'loc-1');
        }
      }
    },
  );

  test('loadLogs throws a typed error so the UI can surface gracefully',
      () async {
    final gateway = OperatorWebHttpVendorConnectionsGateway(
      proxyClient: OperatorWebProxyClient(
        baseUri: Uri.parse(proxyBase),
        httpClient: MockClient((request) async {
          throw StateError('logs route should not be invoked');
        }),
      ),
      idTokenProvider: tokenProvider,
    );

    await expectLater(
      gateway.loadLogs(
        operatorId: 'op-1',
        locationId: 'loc-1',
        vendorId: 'toast',
      ),
      throwsA(isA<VendorConnectionsGatewayError>()),
    );
  });
}
