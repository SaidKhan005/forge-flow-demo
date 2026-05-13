import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/admin/services/vendor_applicability_admin_gateway.dart';

void main() {
  const proxyBase = 'https://proxy.forgeflow.test';

  Future<String> tokenProvider() async => 'admin-token';

  group('HttpVendorApplicabilityAdminGateway', () {
    test(
      'list uses the admin vendor-applicability route and filters',
      () async {
        late http.Request captured;
        final gateway = HttpVendorApplicabilityAdminGateway(
          baseUri: Uri.parse(proxyBase),
          bearerTokenProvider: tokenProvider,
          httpClient: MockClient((request) async {
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
          filter: const VendorApplicabilityAdminFilter(
            settingKind: 'wage',
            settingKey: 'tip_credit',
            vendorSlug: 'toast',
            currentOnly: false,
          ),
        );

        expect(captured.method, 'GET');
        expect(captured.url.path, '/v1/admin/vendor-applicability');
        expect(captured.url.queryParameters['setting_kind'], 'wage');
        expect(captured.url.queryParameters['setting_key'], 'tip_credit');
        expect(captured.url.queryParameters['vendor_slug'], 'toast');
        expect(captured.url.queryParameters['current_only'], 'false');
        expect(captured.headers['authorization'], 'Bearer admin-token');
        expect(rows.single.vendorSlug, 'toast');
      },
    );

    test('writes include body shape and Idempotency-Key header', () async {
      final captured = <http.Request>[];
      final gateway = HttpVendorApplicabilityAdminGateway(
        baseUri: Uri.parse(proxyBase),
        bearerTokenProvider: tokenProvider,
        httpClient: MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{'row': _row()}),
            200,
          );
        }),
      );

      await gateway.upsert(
        VendorApplicabilityUpsertCommand(
          settingKind: 'wage',
          settingKey: 'tip_credit',
          vendorSlug: 'toast',
          enabled: true,
          metadata: const <String, Object?>{'authority_basis': 'job_code'},
          adminReason: 'Ticket VA-123 launch wage defaults',
          reasonNote: 'launch',
          idempotencyKey: 'idem-upsert',
        ),
      );
      await gateway.end(
        const VendorApplicabilityEndCommand(
          settingKind: 'wage',
          settingKey: 'tip_credit',
          vendorSlug: 'toast',
          adminReason: 'Ticket VA-124 retire stale default',
          reasonNote: 'retired',
          idempotencyKey: 'idem-end',
        ),
      );

      expect(
        captured.map((request) => request.method),
        containsAllInOrder(<String>['POST', 'PATCH']),
      );
      expect(captured[0].url.path, '/v1/admin/vendor-applicability');
      expect(captured[1].url.path, '/v1/admin/vendor-applicability');
      expect(captured[0].headers['Idempotency-Key'], 'idem-upsert');
      expect(captured[1].headers['Idempotency-Key'], 'idem-end');
      final upsertBody = jsonDecode(captured[0].body) as Map<String, Object?>;
      expect(upsertBody['setting_kind'], 'wage');
      expect(upsertBody['setting_key'], 'tip_credit');
      expect(upsertBody['vendor_slug'], 'toast');
      expect(upsertBody['enabled'], isTrue);
      expect(upsertBody['metadata'], isA<Map<String, Object?>>());
      expect(upsertBody['admin_reason'], 'Ticket VA-123 launch wage defaults');
      final endBody = jsonDecode(captured[1].body) as Map<String, Object?>;
      expect(endBody['action'], 'end');
      expect(endBody['admin_reason'], 'Ticket VA-124 retire stale default');
      expect(endBody['reason_note'], 'retired');
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
