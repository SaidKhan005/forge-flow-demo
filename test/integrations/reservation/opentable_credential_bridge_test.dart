// Phase 8 framework — OpenTableBrokerCredentialStore tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('readClientId / readClientSecret pull from broker bundle metadata',
      () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'ot-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      metadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{
          'client_id': 'ot-cid',
          'client_secret': 'ot-csec',
        },
      },
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final store = OpenTableBrokerCredentialStore(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
    );
    expect(await store.readClientId(), equals('ot-cid'));
    expect(await store.readClientSecret(), equals('ot-csec'));
  });
}
