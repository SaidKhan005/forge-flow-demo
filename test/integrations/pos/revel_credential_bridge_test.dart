// Phase 8 framework — RevelBrokerCredentialBridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/revel_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolveAccessToken delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'revel-jwt'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      metadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{
          'client_id': 'revel-cid',
          'client_secret': 'revel-csec',
        },
      },
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final bridge = RevelBrokerCredentialBridge(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthExchange: (_) => throw StateError('refresh should not run'),
    );
    expect(await bridge.resolveAccessToken(), equals('revel-jwt'));
    final bundle = await bridge.resolveBundle();
    expect(bundle.clientId, equals('revel-cid'));
    expect(bundle.clientSecret, equals('revel-csec'));
  });
}
