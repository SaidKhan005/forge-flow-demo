import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_benchmarks_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/services/baseline/benchmark_override_resolver.dart';

void main() {
  group('OperatorWebHttpBenchmarksGateway', () {
    test('lists overrides through the live operator proxy route', () async {
      late http.Request captured;
      final gateway = _gateway((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'overrides': <Map<String, Object?>>[_rowJson()],
          }),
          200,
        );
      });

      final rows = await gateway.listOverrides(
        operatorId: 'op-a',
        locationId: 'loc-a',
        actorUserId: 'user-a',
      );

      expect(captured.method, 'GET');
      expect(captured.url.path, kOperatorWebBenchmarkOverridesPath);
      expect(captured.headers['authorization'], 'Bearer token-a');
      expect(rows.single.metricKey, 'target_cplh');
    });

    test('posts and deletes with Idempotency-Key headers', () async {
      final methods = <String>[];
      final idemKeys = <String?>[];
      final gateway = _gateway((request) async {
        methods.add(request.method);
        idemKeys.add(request.headers['Idempotency-Key']);
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          expect(body['scope_type'], 'location');
          expect(body['location_id'], 'loc-a');
        }
        return http.Response(
          jsonEncode(<String, Object?>{'override': _rowJson()}),
          200,
        );
      });

      await gateway.setOverride(
        operatorId: 'op-a',
        locationId: 'loc-a',
        actorUserId: 'user-a',
        scopeType: BenchmarkOverrideScopeType.location,
        orgUnitId: null,
        targetLocationId: 'loc-a',
        metricKey: 'target_cplh',
        overrideValue: 9.5,
      );
      await gateway.clearOverride(
        operatorId: 'op-a',
        locationId: 'loc-a',
        actorUserId: 'user-a',
        overrideId: 'override-a',
      );

      expect(methods, <String>['POST', 'DELETE']);
      expect(idemKeys, everyElement(isNotEmpty));
    });
  });
}

OperatorWebHttpBenchmarksGateway _gateway(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = OperatorWebProxyClient(
    baseUri: Uri.parse('https://proxy.test'),
    httpClient: MockClient(handler),
    idempotencyKeyFactory: () => 'idem-test',
  );
  return OperatorWebHttpBenchmarksGateway(
    client: client,
    idTokenProvider: () async => 'token-a',
  );
}

Map<String, Object?> _rowJson() {
  return <String, Object?>{
    'override_id': 'override-a',
    'operator_id': 'op-a',
    'scope_type': 'location',
    'org_unit_id': null,
    'location_id': 'loc-a',
    'metric_key': 'target_cplh',
    'override_value': 9.5,
    'effective_from': DateTime.utc(2026, 5, 13, 18).toIso8601String(),
    'effective_until': null,
    'created_by': 'user-a',
    'source_label': 'Main Street',
  };
}
