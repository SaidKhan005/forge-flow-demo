// Phase 8 framework — OracleMicrosSimphonyBrokerTokenStore tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_production_api_client.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('fetchAccessToken returns the broker bearer + bundle expiry',
      () async {
    final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 1));
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'simphony-bearer'},
      expiresAt: expiresAt,
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final store = OracleMicrosSimphonyBrokerTokenStore(
      broker: broker,
      oauthExchange: (_) => throw StateError('refresh should not run'),
    );
    final token = await store.fetchAccessToken(
      operatorId: _opId,
      locationId: _locId,
      credential: const SimphonyVendorCredentialHandle(credentialId: 'c-1'),
    );
    expect(token.accessToken, equals('simphony-bearer'));
    expect(token.expiresAt.toUtc(), equals(expiresAt.toUtc()));
  });
}
