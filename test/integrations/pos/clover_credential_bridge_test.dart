// Phase 8 framework — Clover credential bridge tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/clover_credential_bridge.dart';

import 'fixtures/credential_pool_fixture.dart';

const String _opId = '11111111-2222-3333-4444-555555555555';
const String _locId = '66666666-7777-8888-9999-aaaaaaaaaaaa';

void main() {
  test('access token source delegates to the broker', () async {
    final pool = CredentialPoolFixture(
      bearerByOp: <String, String>{_opId: 'clover-bearer'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final broker = VendorCredentialBroker(
      tenantWrapper: TenantTransactionWrapper(pool),
      pgcryptoEnvelopeKey: 'env-key',
    );
    final source = makeCloverAccessTokenSource(
      broker: broker,
      operatorId: _opId,
      locationId: _locId,
      oauthRefresh: (_) => throw StateError('refresh should not run'),
    );
    final token = await source();
    expect(token, equals('clover-bearer'));
  });

  test('app token + app id sources return the supplied static value', () {
    final appToken = makeStaticCloverAppTokenSource('TKN');
    final appId = makeStaticCloverAppIdSource('APP-1');
    expect(appToken(), equals('TKN'));
    expect(appId(), equals('APP-1'));
  });
}
