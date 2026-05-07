// Phase 8 framework — Push Operations bearer resolver bridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('resolver returns broker bearer; null on NotFound', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'push-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final resolver = makePushOperationsBearerResolver(broker: broker);
    expect(
      await resolver(operatorId: _opId, locationId: _locId),
      equals('push-bearer'),
    );
    // Different operator → no row → resolver returns null per contract.
    final missing = await resolver(
      operatorId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      locationId: _locId,
    );
    expect(missing, isNull);
  });
}
