// Ops-debt fix `claude/ops-debt.7shifts-vendor-id` — the 7shifts
// vendor identifier had drifted into two values: `'7shifts'` in the
// credential bridge / OAuth descriptors and `'seven_shifts'` in the
// adapter / labor registry / dispatcher set. A connection persisted by
// the OAuth flow with `vendor_id='7shifts'` would then fail
// `_isVendorRegistered` and emit `vendor_not_registered`. This test
// pins the canonical value to `'seven_shifts'` across every key
// surface so that regression cannot reappear.
//
// What it asserts:
//   (a) `kSevenShiftsVendorId == 'seven_shifts'` — single canonical
//       constant resolved through the credential bridge re-export.
//   (b) The OAuth descriptor + exchanger maps register 7shifts under
//       the `'seven_shifts'` key (not `'7shifts'`).
//   (c) The dispatcher's `registeredLaborVendorIds` set contains
//       `'seven_shifts'` (so `_isVendorRegistered` returns true for
//       a row written by the OAuth flow).
//   (d) The vendor admin status catalog returns a profile keyed by
//       `'seven_shifts'` whose operator-facing `displayName` is the
//       `'7shifts'` brand string.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_credential_bridge.dart'
    as seven_shifts_bridge;
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';
import '../../../tool/advisor_proxy/integration_oauth_routes.dart';
import '../../../tool/advisor_proxy/labor_adapter_registry.dart';
import '../../../tool/advisor_proxy/vendor_admin_status_catalog.dart';

void main() {
  group('7shifts vendor_id alignment', () {
    test(
      '(a) kSevenShiftsVendorId is the canonical "seven_shifts" key '
      'and the credential bridge re-export resolves to the same const',
      () {
        expect(kSevenShiftsVendorId, equals('seven_shifts'));
        expect(kSevenShiftsDisplayName, equals('7shifts'));
        // The bridge re-exports the adapter-side constant. Importing it
        // through the bridge prefix must yield the same string.
        expect(seven_shifts_bridge.kSevenShiftsVendorId, same(kSevenShiftsVendorId));
        // Belt and braces — the framework category map keys the labor
        // wave under the canonical snake_case id, never `'7shifts'`.
        expect(
          kPhase8VendorCategories['seven_shifts'],
          equals(IntegrationCategory.labor),
        );
        expect(kPhase8VendorCategories.containsKey('7shifts'), isFalse);
      },
    );

    test(
      '(b) the OAuth descriptor + exchanger maps register 7shifts '
      'under the "seven_shifts" key',
      () {
        final config = ProxyConfig.fromEnvironment(<String, String>{
          ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
          ProxySecretNames.voyageApiKey: 'placeholder-voyage',
          ProxySecretNames.postgresUrl:
              'postgres://app-role.example/forgeflow',
          ProxySecretNames.postgresAdminUrl:
              'postgres://admin-role.example/forgeflow',
          ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web',
          ProxySecretNames.servicePrincipalJwtSecret: 'placeholder-sp-jwt',
          ProxySecretNames.pgcryptoEnvelopeKey: 'placeholder-pgcrypto',
          ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
          ProxySecretNames.sevenShiftsClientId: '7s-client',
          ProxySecretNames.sevenShiftsClientSecret: '7s-secret',
        });
        final wiring = buildPhase8OperatorOAuthWiring(
          proxyConfig: config,
          connectionWriter: _noopConnectionWriter,
        );

        expect(
          wiring.oauthBeginDescriptors.containsKey('seven_shifts'),
          isTrue,
          reason: 'descriptor map must key 7shifts under "seven_shifts"',
        );
        expect(
          wiring.oauthBeginDescriptors.containsKey('7shifts'),
          isFalse,
          reason: 'no descriptor should be registered under the legacy '
              '"7shifts" key',
        );
        expect(
          wiring.oauthExchangers.containsKey('seven_shifts'),
          isTrue,
        );
        expect(wiring.oauthExchangers.containsKey('7shifts'), isFalse);
        // Descriptor's own `vendorId` field also matches the canonical
        // key — the OAuth begin endpoint emits `vendor_id=seven_shifts`
        // back to the operator UI on the state row.
        expect(
          wiring.oauthBeginDescriptors['seven_shifts']!.vendorId,
          equals('seven_shifts'),
        );
      },
    );

    test(
      '(b.2) when 7shifts app credentials are absent the disabled-vendors '
      'map keys the entry under "seven_shifts"',
      () {
        final config = ProxyConfig.fromEnvironment(<String, String>{
          ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
          ProxySecretNames.voyageApiKey: 'placeholder-voyage',
          ProxySecretNames.postgresUrl:
              'postgres://app-role.example/forgeflow',
          ProxySecretNames.postgresAdminUrl:
              'postgres://admin-role.example/forgeflow',
          ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web',
          ProxySecretNames.servicePrincipalJwtSecret: 'placeholder-sp-jwt',
          ProxySecretNames.pgcryptoEnvelopeKey: 'placeholder-pgcrypto',
          ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
        });
        final wiring = buildPhase8OperatorOAuthWiring(
          proxyConfig: config,
          connectionWriter: _noopConnectionWriter,
        );
        expect(wiring.disabledVendors.containsKey('seven_shifts'), isTrue);
        expect(wiring.disabledVendors.containsKey('7shifts'), isFalse);
      },
    );

    test(
      '(c) the dispatcher\'s registered-labor-vendor set contains '
      '"seven_shifts" so a connection row written by the OAuth flow '
      'will pass _isVendorRegistered',
      () {
        expect(
          registeredLaborVendorIds.toSet().contains('seven_shifts'),
          isTrue,
          reason: 'a connector_connection row with vendor_id=seven_shifts '
              'must dispatch — otherwise the sync worker emits '
              'vendor_not_registered after every connect.',
        );
        expect(
          registeredLaborVendorIds.toSet().contains('7shifts'),
          isFalse,
        );
      },
    );

    test(
      '(d) the admin-visible vendor status catalog returns the 7shifts '
      'profile when looked up by "seven_shifts" with the brand display '
      'name preserved',
      () {
        final byVendorId = <String, VendorCapabilityProfile>{
          for (final profile in kAdminVisibleVendorCapabilityProfiles)
            profile.vendorId: profile,
        };
        final profile = byVendorId['seven_shifts'];
        expect(profile, isNotNull,
            reason: 'admin catalog must expose a row keyed by '
                '"seven_shifts" so the operator dashboard can render the '
                '7shifts capability card');
        expect(profile!.displayName, equals('7shifts'),
            reason: 'operator-facing brand name stays "7shifts" — only '
                'the internal vendor_id key is canonicalised');
        expect(profile.category, equals(IntegrationCategory.labor));
        expect(byVendorId.containsKey('7shifts'), isFalse);
      },
    );
  });
}

Future<Map<String, Object?>> _noopConnectionWriter({
  required String operatorId,
  required String locationId,
  required String actorUserId,
  required String vendorId,
  required IntegrationCategory category,
  required String accessTokenPlaintext,
  String? refreshTokenPlaintext,
  DateTime? tokenExpiresAt,
  Map<String, Object?> metadata = const <String, Object?>{},
  String? webhookUrl,
  String? module,
  bool firstBackfillStarted = true,
}) async {
  return <String, Object?>{
    'connection_id': '00000000-0000-0000-0000-000000000000',
    'credential_id': '00000000-0000-0000-0000-000000000000',
    'vendor_id': vendorId,
    'status': 'connected',
  };
}
