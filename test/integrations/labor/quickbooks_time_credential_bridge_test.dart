// Phase 8 framework — QuickBooks Time credential bridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('readAccessToken delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'qbt-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final store = QuickBooksTimeBrokerCredentialStore(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthRefresh: (_) => throw StateError('refresh should not run'),
    );
    expect(await store.readAccessToken(), equals('qbt-bearer'));
  });

  test('static OAuth client credentials expose the supplied values', () {
    const creds = StaticQuickBooksTimeBrokerOauthClientCredentials(
      clientId: 'qbt-cid',
      clientSecret: 'qbt-csec',
    );
    expect(creds.clientId, equals('qbt-cid'));
    expect(creds.clientSecret, equals('qbt-csec'));
  });
}
