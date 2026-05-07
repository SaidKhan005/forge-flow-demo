// Phase 8 framework — VendorCredentialBroker tests.
//
// Covers the six behaviours the slice promises:
//
//   1. Resolve happy path — cached bearer returned without DB round
//      trip on the second call.
//   2. Resolve when expired — refresh closure called once, new bearer
//      cached.
//   3. Concurrent refresh dedup — two simultaneous resolveAccessToken
//      calls collapse to one OAuth round trip.
//   4. Cross-tenant isolation — tenant A's call cannot read tenant B's
//      credential row (every read rides withTenant; SET LOCAL precedes
//      the SELECT).
//   5. Decrypt failure surfaces as VendorCredentialDecryptFailed.
//   6. invalidate() drops the cache.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';

const String _opA = '11111111-2222-3333-4444-555555555555';
const String _opB = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff';
const String _loc = '66666666-7777-8888-9999-aaaaaaaaaaaa';
const String _vendorId = 'toast';
const String _envelopeKey = 'test-envelope-key';

void main() {
  group('resolveAccessToken — happy path', () {
    test('returns the decrypted bearer and caches it', () async {
      final pool = _BrokerPool(
        rowsByTenant: <String, Map<String, Object?>>{
          '$_opA|$_loc': _credentialRow(
            accessTokenPlaintext: 'bearer-1',
            expiresAt:
                DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        },
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final first = await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      expect(first, equals('bearer-1'));
      expect(pool.transactions.length, equals(1));

      // Second call — cache hit, no new transaction.
      final second = await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      expect(second, equals('bearer-1'));
      expect(pool.transactions.length, equals(1));

      // SET LOCAL fired before the SELECT.
      final tx = pool.transactions.single;
      expect(
        tx.executedSql.first,
        contains("'app.operator_id'"),
        reason: 'tenant SET LOCAL must run before any DB read',
      );
      expect(
        tx.executedSql.any((s) => s.contains('pgp_sym_decrypt')),
        isTrue,
        reason: 'broker uses pgp_sym_decrypt to read the bearer',
      );
    });
  });

  group('resolveAccessToken — refresh required', () {
    test('calls the refresh closure once when token expired', () async {
      final pool = _BrokerPool(
        rowsByTenant: <String, Map<String, Object?>>{
          '$_opA|$_loc': _credentialRow(
            accessTokenPlaintext: 'stale-bearer',
            // Expired well before now() so the broker forces a refresh.
            expiresAt:
                DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
        },
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      var refreshCalls = 0;
      Future<TokenRefreshResult> doRefresh(VendorCredentialBundle current) async {
        refreshCalls += 1;
        expect(current.accessToken, equals('stale-bearer'));
        return TokenRefreshResult(
          accessToken: 'fresh-bearer',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
      }

      // After the refresh closure runs, the broker UPDATEs the
      // ciphertext in vendor_credentials and updates its in-memory
      // cache; the next read should pull from the cache.
      final first = await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
        doRefresh: doRefresh,
      );
      expect(first, equals('fresh-bearer'));
      expect(refreshCalls, equals(1));

      final second = await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
        doRefresh: doRefresh,
      );
      expect(second, equals('fresh-bearer'));
      expect(refreshCalls, equals(1),
          reason: 'cached bearer should serve the second call');

      // The persist path executed the UPDATE.
      final updateRan = pool.transactions.any((tx) => tx.executedSql.any(
          (s) => s.contains('update public.vendor_credentials')));
      expect(updateRan, isTrue);
    });
  });

  group('resolveAccessToken — concurrent refresh dedup', () {
    test('two simultaneous calls collapse to one refresh closure call',
        () async {
      final pool = _BrokerPool(
        rowsByTenant: <String, Map<String, Object?>>{
          '$_opA|$_loc': _credentialRow(
            accessTokenPlaintext: 'expired',
            expiresAt:
                DateTime.now().toUtc().subtract(const Duration(hours: 1)),
          ),
        },
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final completer = Completer<void>();
      var refreshCalls = 0;
      Future<TokenRefreshResult> doRefresh(VendorCredentialBundle current) async {
        refreshCalls += 1;
        // Block until released so we can prove the second call queues.
        await completer.future;
        return TokenRefreshResult(
          accessToken: 'fresh',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        );
      }

      final f1 = broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
        doRefresh: doRefresh,
      );
      final f2 = broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
        doRefresh: doRefresh,
      );
      // Let the futures register.
      await Future<void>.delayed(Duration.zero);
      completer.complete();
      final results = await Future.wait<String>(<Future<String>>[f1, f2]);
      expect(results, equals(<String>['fresh', 'fresh']));
      expect(refreshCalls, equals(1),
          reason: 'concurrent calls must dedup via in-flight Future map');
    });
  });

  group('cross-tenant isolation', () {
    test('tenant A and tenant B see different bearers', () async {
      final pool = _BrokerPool(
        rowsByTenant: <String, Map<String, Object?>>{
          '$_opA|$_loc': _credentialRow(
            accessTokenPlaintext: 'A-bearer',
            expiresAt:
                DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
          '$_opB|$_loc': _credentialRow(
            accessTokenPlaintext: 'B-bearer',
            expiresAt:
                DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        },
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );

      final aBearer = await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      final bBearer = await broker.resolveAccessToken(
        operatorId: _opB,
        locationId: _loc,
        vendorId: _vendorId,
      );
      expect(aBearer, equals('A-bearer'));
      expect(bBearer, equals('B-bearer'));

      // Each transaction SET LOCAL'd with the right operator UUID.
      expect(pool.transactions.length, equals(2));
      final tx1 = pool.transactions[0];
      final tx2 = pool.transactions[1];
      final setOp1Idx = tx1.executedSql
          .indexWhere((s) => s.contains("'app.operator_id'"));
      final setOp2Idx = tx2.executedSql
          .indexWhere((s) => s.contains("'app.operator_id'"));
      expect(tx1.parameters[setOp1Idx]['value'], equals(_opA));
      expect(tx2.parameters[setOp2Idx]['value'], equals(_opB));
      // The SELECT bound the same operator id.
      final select1Idx = tx1.executedSql
          .indexWhere((s) => s.contains('from public.vendor_credentials'));
      final select2Idx = tx2.executedSql
          .indexWhere((s) => s.contains('from public.vendor_credentials'));
      expect(tx1.parameters[select1Idx]['operator_id'], equals(_opA));
      expect(tx2.parameters[select2Idx]['operator_id'], equals(_opB));
    });
  });

  group('decrypt failures', () {
    test('null plaintext surfaces as VendorCredentialDecryptFailed',
        () async {
      final pool = _BrokerPool(
        rowsByTenant: <String, Map<String, Object?>>{
          '$_opA|$_loc': _credentialRow(
            accessTokenPlaintext: null,
            expiresAt:
                DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        },
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );
      await expectLater(
        broker.resolveAccessToken(
          operatorId: _opA,
          locationId: _loc,
          vendorId: _vendorId,
        ),
        throwsA(isA<VendorCredentialDecryptFailed>()),
      );
    });

    test('decrypt exception is wrapped as VendorCredentialDecryptFailed',
        () async {
      final pool = _BrokerPool(
        rowsByTenant: const <String, Map<String, Object?>>{},
        throwOnSelect: true,
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );
      await expectLater(
        broker.resolveAccessToken(
          operatorId: _opA,
          locationId: _loc,
          vendorId: _vendorId,
        ),
        throwsA(isA<VendorCredentialDecryptFailed>()),
      );
    });

    test('missing row surfaces as VendorCredentialNotFound', () async {
      final pool = _BrokerPool(
        rowsByTenant: const <String, Map<String, Object?>>{},
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );
      await expectLater(
        broker.resolveAccessToken(
          operatorId: _opA,
          locationId: _loc,
          vendorId: _vendorId,
        ),
        throwsA(isA<VendorCredentialNotFound>()),
      );
    });
  });

  group('invalidate', () {
    test('drops the in-memory cache so the next call rereads', () async {
      final pool = _BrokerPool(
        rowsByTenant: <String, Map<String, Object?>>{
          '$_opA|$_loc': _credentialRow(
            accessTokenPlaintext: 'cached',
            expiresAt:
                DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        },
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );
      await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      expect(pool.transactions.length, equals(1));
      // Cached.
      await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      expect(pool.transactions.length, equals(1));
      // Invalidate, then read again — fresh transaction.
      await broker.invalidate(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      await broker.resolveAccessToken(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      expect(pool.transactions.length, equals(2));
    });
  });

  group('resolveCredentialBundle', () {
    test('hoists known metadata keys into typed accessors', () async {
      final pool = _BrokerPool(
        rowsByTenant: <String, Map<String, Object?>>{
          '$_opA|$_loc': _credentialRow(
            accessTokenPlaintext: 'bearer',
            expiresAt:
                DateTime.now().toUtc().add(const Duration(hours: 1)),
            metadata: <String, Object?>{
              'api_key': 'ak-123',
              'client_id': 'cid-1',
              'client_secret': 'cs-1',
              'extra_field': 'left-in-metadata',
            },
            connectionMetadata: <String, Object?>{
              'merchant_id': 'mid-9',
              'webhook_subscription_id': 'sub-7',
              'restaurant_guid': 'rg-1',
            },
          ),
        },
      );
      final broker = VendorCredentialBroker(
        tenantWrapper: TenantTransactionWrapper(pool),
        pgcryptoEnvelopeKey: _envelopeKey,
      );
      final bundle = await broker.resolveCredentialBundle(
        operatorId: _opA,
        locationId: _loc,
        vendorId: _vendorId,
      );
      expect(bundle.accessToken, equals('bearer'));
      expect(bundle.apiKey, equals('ak-123'));
      expect(bundle.clientId, equals('cid-1'));
      expect(bundle.clientSecret, equals('cs-1'));
      expect(bundle.merchantId, equals('mid-9'));
      expect(bundle.webhookSubscriptionId, equals('sub-7'));
      // Vendor-specific keys stay reachable through the metadata map.
      expect(bundle.metadata['extra_field'], equals('left-in-metadata'));
      expect(bundle.connectionMetadata['restaurant_guid'], equals('rg-1'));
      // Hoisted keys are stripped from the metadata map (no double
      // exposure).
      expect(bundle.metadata.containsKey('api_key'), isFalse);
    });
  });

  group('constructor validation', () {
    test('rejects an empty pgcrypto envelope key', () {
      expect(
        () => VendorCredentialBroker(
          tenantWrapper: TenantTransactionWrapper(_BrokerPool()),
          pgcryptoEnvelopeKey: '',
        ),
        throwsArgumentError,
      );
    });
  });
}

// ── Helpers ─────────────────────────────────────────────────────────

Map<String, Object?> _credentialRow({
  required String? accessTokenPlaintext,
  required DateTime? expiresAt,
  String? refreshTokenPlaintext,
  Map<String, Object?> metadata = const <String, Object?>{},
  Map<String, Object?> connectionMetadata = const <String, Object?>{},
}) {
  return <String, Object?>{
    'access_token_plaintext': accessTokenPlaintext,
    'refresh_token_plaintext': refreshTokenPlaintext,
    'token_expires_at': expiresAt,
    'metadata': metadata,
    'connection_metadata': connectionMetadata,
  };
}

class _BrokerPool implements PostgresPool {
  _BrokerPool({
    this.rowsByTenant = const <String, Map<String, Object?>>{},
    this.throwOnSelect = false,
  });

  /// Map keyed by `operatorId|locationId` producing the row the
  /// broker's SELECT returns.
  final Map<String, Map<String, Object?>> rowsByTenant;

  /// When true, the SELECT throws so the test can assert decrypt
  /// errors are wrapped.
  final bool throwOnSelect;

  final List<_BrokerTransaction> transactions = <_BrokerTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _BrokerTransaction(
      rowsByTenant: rowsByTenant,
      throwOnSelect: throwOnSelect,
    );
    transactions.add(tx);
    return tx;
  }
}

class _BrokerTransaction extends PostgresTransaction {
  _BrokerTransaction({
    required this.rowsByTenant,
    required this.throwOnSelect,
  });

  final Map<String, Map<String, Object?>> rowsByTenant;
  final bool throwOnSelect;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];

  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.vendor_credentials') &&
        sql.contains('pgp_sym_decrypt')) {
      if (throwOnSelect) {
        throw FormatException('decrypt failed');
      }
      final operatorId = parameters['operator_id']! as String;
      final locationId = parameters['location_id']! as String;
      final key = '$operatorId|$locationId';
      final row = rowsByTenant[key];
      if (row == null) return <PostgresRow>[];
      // Project the row into the column shape the broker expects.
      final metadataValue = row['metadata'];
      final connectionMetadataValue = row['connection_metadata'];
      return <PostgresRow>[
        <String, Object?>{
          'access_token_plaintext': row['access_token_plaintext'],
          'refresh_token_plaintext': row['refresh_token_plaintext'],
          'token_expires_at': row['token_expires_at'],
          'metadata': metadataValue is Map
              ? jsonEncode(metadataValue)
              : metadataValue,
          'connection_metadata': connectionMetadataValue is Map
              ? jsonEncode(connectionMetadataValue)
              : connectionMetadataValue,
        },
      ];
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}
