// Phase 8 framework — Libro bearer token resolver bridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/reservation/libro_credential_bridge.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolver closure delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'libro-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final resolver = makeLibroBearerTokenResolver(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthRefresh: (_) => throw StateError('refresh should not run'),
    );
    final token = await resolver(
      const VendorCredentialHandle(credentialId: 'c-1'),
    );
    expect(token, equals('libro-bearer'));
  });
}
