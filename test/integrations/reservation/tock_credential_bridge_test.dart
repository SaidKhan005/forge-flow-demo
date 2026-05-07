// Phase 8 framework — TockBrokerCredentialResolver tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/tock_credential_bridge.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolveApiKey reads the broker bundle apiKey field', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'fallback-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      metadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{'api_key': 'tock-key'},
      },
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final resolver = TockBrokerCredentialResolver(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
    );
    final key = await resolver.resolveApiKey(
      handle: const TockCredentialHandle(
        connectionId: 'conn-1',
        businessId: 'biz-9',
      ),
    );
    expect(key, equals('tock-key'));
  });

  test('resolvePastedApiKey passes through unchanged', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: const <String, String>{},
      expiresAt: DateTime.now().toUtc(),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final resolver = TockBrokerCredentialResolver(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
    );
    final key = await resolver.resolvePastedApiKey(
      operatorId: _opId,
      locationId: _locId,
      pastedApiKey: 'pasted-key',
    );
    expect(key, equals('pasted-key'));
  });
}
