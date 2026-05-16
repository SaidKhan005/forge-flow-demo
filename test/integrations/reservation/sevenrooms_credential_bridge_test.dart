// Phase 8 framework — SevenRoomsBrokerCredentialStore tests.

import 'dart:convert';

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
      clientSecret: 'csecret',
      venueId: 'venue-9',
      accessToken: 'fresh-bearer',
      lifetime: const Duration(hours: 1),
    );
    expect(credentialId, contains('sevenrooms'));
    final updateRan = pool.transactions.any((tx) => tx.executedSql.any(
        (s) => s.contains('update public.vendor_credentials')));
    expect(updateRan, isTrue);
  });

  // 2026-05-09 P1 closeout: the bridge must persist `client_secret` +
  // `venue_id` on metadata alongside `client_id` so the cross-tenant
  // refresh worker can call `makeSevenRoomsOauthRefreshClosure` without
  // prompting the operator to reconnect. This test pins all three
  // metadata keys reach the broker UPDATE statement's parameter set.
  test(
      'persistIssuedBearerToken records client_id + client_secret + '
      'venue_id on metadata patch', () async {
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
    await store.persistIssuedBearerToken(
      clientId: 'sr-client-id',
      clientSecret: 'sr-client-secret',
      venueId: 'sr-venue-42',
      accessToken: 'fresh-bearer',
      lifetime: const Duration(hours: 1),
    );
    // The broker's UPDATE statement parameterizes the metadataPatch as
    // a JSON blob bound to a named param. Walk every transaction's
    // parameter map and assert each of the three keys appears (as a
    // substring of any bound value — the broker may bind the metadata
    // as a JSON string OR as a Map; cover both shapes).
    final bindHits = <String, bool>{
      'sr-client-id': false,
      'sr-client-secret': false,
      'sr-venue-42': false,
    };
    for (final tx in pool.transactions) {
      for (final paramMap in tx.parameters) {
        for (final value in paramMap.values) {
          final searchable = value is String ? value : jsonEncode(value);
          for (final key in bindHits.keys) {
            if (searchable.contains(key)) {
              bindHits[key] = true;
            }
          }
        }
      }
    }
    expect(
      bindHits['sr-client-id'],
      isTrue,
      reason:
          'client_id must reach the broker bind map so it lands on '
          'vendor_credentials.metadata',
    );
    expect(
      bindHits['sr-client-secret'],
      isTrue,
      reason:
          'client_secret MUST reach the broker bind map so the cross-'
          'tenant refresh worker can read it later via '
          'makeSevenRoomsOauthRefreshClosure',
    );
    expect(
      bindHits['sr-venue-42'],
      isTrue,
      reason:
          'venue_id MUST reach the broker bind map so the closure can '
          'rebuild the /2_2/auth payload without a connector_connection '
          'lookup',
    );
  });
}
