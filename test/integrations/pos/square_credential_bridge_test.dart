// Phase 8 framework — SquareBrokerCredentialResolver tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/square_credential_bridge.dart';
import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('delegates resolveAccessToken to the broker and exposes static '
      'OAuth client credentials', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'square-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final resolver = SquareBrokerCredentialResolver(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthRefresh: (_) => throw StateError('refresh should not run'),
      clientId: 'square-client-id',
      clientSecret: 'square-client-secret',
    );
    final token = await resolver.resolveAccessToken(
      const SquareCredentialHandle(
        connectionId: 'conn-1',
        operatorId: _opId,
        locationId: _locId,
      ),
    );
    expect(token, equals('square-bearer'));
    expect(resolver.clientId, equals('square-client-id'));
    expect(resolver.clientSecret, equals('square-client-secret'));
  });
}
