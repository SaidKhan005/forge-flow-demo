// Phase 8 framework — SevenRoomsBrokerCredentialStore tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolveBearerToken delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'sr-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final store = SevenRoomsBrokerCredentialStore(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
    );
    expect(
      await store.resolveBearerToken(credentialId: 'cred-1'),
      equals('sr-bearer'),
    );
  });

  test('persistIssuedBearerToken writes through the broker UPDATE path',
      () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'old-bearer'},
      expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final store = SevenRoomsBrokerCredentialStore(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
    );
    final credentialId = await store.persistIssuedBearerToken(
      clientId: 'cid',
      venueId: 'venue-9',
      accessToken: 'fresh-bearer',
      lifetime: const Duration(hours: 1),
    );
    expect(credentialId, contains('sevenrooms'));
    final updateRan = pool.transactions.any((tx) => tx.executedSql.any(
        (s) => s.contains('update public.vendor_credentials')));
    expect(updateRan, isTrue);
  });
}
