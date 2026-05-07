// Phase 8 framework — AgendrixBrokerCredentialStore tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('returns AgendrixCredential from broker bundle + connection metadata',
      () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'agendrix-key'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      metadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{'api_key': 'agendrix-key'},
      },
      connectionMetadataByOp: <String, Map<String, Object?>>{
        _opId: <String, Object?>{
          kAgendrixConnectionMetadataCompanyId: 'company-9',
        },
      },
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final store = AgendrixBrokerCredentialStore(broker: broker);
    final creds = await store.readCredential(
      operatorId: _opId,
      locationId: _locId,
    );
    expect(creds.apiKey, equals('agendrix-key'));
    expect(creds.companyId, equals('company-9'));
  });
}
