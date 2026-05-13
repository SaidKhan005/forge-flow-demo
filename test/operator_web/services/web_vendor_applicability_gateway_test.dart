import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/web_vendor_applicability_gateway.dart';

void main() {
  const proxyBase = 'https://proxy.forgeflow.test';

  group('HttpWebVendorApplicabilityGateway', () {
    test('list uses the operator route with setting filters', () async {
      late http.Request captured;
      final gateway = HttpWebVendorApplicabilityGateway(
        proxyBaseUri: Uri.parse(proxyBase),
        idTokenProvider: () async => 'operator-token',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'rows': <Object?>[_row()],
            }),
            200,
          );
        }),
      );

      final rows = await gateway.list(
        settingKind: 'wage',
        settingKey: 'tip_credit',
      );

      expect(captured.method, 'GET');
      expect(captured.url.path, '/v1/operator/vendor-applicability');
      expect(captured.url.queryParameters['setting_kind'], 'wage');
      expect(captured.url.queryParameters['setting_key'], 'tip_credit');
      expect(captured.headers['authorization'], 'Bearer operator-token');
      expect(rows.single.settingKind, 'wage');
      expect(rows.single.vendorSlug, 'toast');
    });

    test('rejects calls when no bearer token is available', () async {
      final gateway = HttpWebVendorApplicabilityGateway(
        proxyBaseUri: Uri.parse(proxyBase),
        idTokenProvider: () async => null,
        client: MockClient((request) async {
          fail('request should not reach the proxy without a token');
        }),
      );

      await expectLater(
        gateway.list(settingKind: 'wage'),
        throwsA(
          isA<WebVendorApplicabilityGatewayError>().having(
            (error) => error.code,
            'code',
            'unauthenticated',
          ),
        ),
      );
    });
  });
}

Map<String, Object?> _row() => const <String, Object?>{
  'id': '44444444-4444-4444-8444-444444444444',
  'operator_id': null,
  'setting_kind': 'wage',
  'setting_key': 'tip_credit',
  'vendor_slug': 'toast',
  'enabled': true,
  'metadata': <String, Object?>{'authority_basis': 'job_code'},
  'effective_from': '2026-05-13T15:00:00.000Z',
  'effective_until': null,
  'created_at': '2026-05-13T15:00:00.000Z',
  'created_by': '11111111-1111-4111-8111-111111111111',
};
