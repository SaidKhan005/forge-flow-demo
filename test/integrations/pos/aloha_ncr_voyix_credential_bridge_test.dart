// Phase 8 framework — Aloha NCR Voyix credential store bridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_adapter.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('store closure assembles AlohaNcrVoyixResolvedCredentials from '
      'the broker bundle + connection metadata', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'aloha-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      metadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{
          kAlohaNcrVoyixMetadataApplicationKey: 'app-key-9',
          kAlohaNcrVoyixMetadataOrganizationId: 'org-1',
        },
      },
      connectionMetadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{
          kAlohaNcrVoyixConnectionMetadataSiteId: 'site-9',
        },
      },
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final store = makeAlohaNcrVoyixCredentialStore(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthRefresh: (_) => throw StateError('refresh should not run'),
    );
    final resolved = await store(const AlohaNcrVoyixCredentialHandle(
      connectionId: 'conn-1',
      siteId: 'fallback-site',
    ));
    expect(resolved.accessToken, equals('aloha-bearer'));
    expect(resolved.applicationKey, equals('app-key-9'));
    expect(resolved.organizationId, equals('org-1'));
    expect(resolved.siteId, equals('site-9'),
        reason: 'connection metadata wins over the handle fallback');
  });
}
