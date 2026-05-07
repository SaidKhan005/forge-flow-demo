// Phase 8 framework — ADP credential providers bridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/adp_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('credential + subscription-secret providers source from broker '
      'metadata', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'adp-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      metadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{
          'client_id': 'adp-cid',
          'client_secret': 'adp-csec',
          kAdpMetadataSubscriptionSecret: 'adp-sub-sec',
        },
      },
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final credentialsProvider = makeAdpCredentialsProvider(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
    );
    final secretProvider = makeAdpSubscriptionSecretProvider(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
    );
    final creds = await credentialsProvider();
    expect(creds.clientId, equals('adp-cid'));
    expect(creds.clientSecret, equals('adp-csec'));
    final secret = await secretProvider();
    expect(secret, equals('adp-sub-sec'));
  });
}
