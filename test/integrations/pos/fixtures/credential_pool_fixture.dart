// Test-only PostgresPool stub shared across the 17 vendor credential
// bridge tests. Returns a single decrypted credential row keyed by
// operator id, so a bridge can prove its delegation chain without
// duplicating the broker-side fake in every test file.

import 'dart:convert';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

class CredentialPoolFixture implements PostgresPool {
  CredentialPoolFixture({
    required this.bearerByOp,
    required this.expiresAt,
    this.refreshTokenByOp = const <String, String>{},
    this.metadataByOp = const <String, Map<String, Object?>>{},
    this.connectionMetadataByOp = const <String, Map<String, Object?>>{},
  });

  /// Map keyed by `operatorId` — the bridge passes a single
  /// `(operatorId, locationId, vendorId)` triple, so the location/vendor
  /// dimensions are folded out for brevity.
  final Map<String, String> bearerByOp;
  final Map<String, String> refreshTokenByOp;
  final DateTime expiresAt;
  final Map<String, Map<String, Object?>> metadataByOp;
  final Map<String, Map<String, Object?>> connectionMetadataByOp;

  final List<CredentialPoolTransaction> transactions =
      <CredentialPoolTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = CredentialPoolTransaction(
      bearerByOp: bearerByOp,
      refreshTokenByOp: refreshTokenByOp,
      expiresAt: expiresAt,
      metadataByOp: metadataByOp,
      connectionMetadataByOp: connectionMetadataByOp,
    );
    transactions.add(tx);
    return tx;
  }
}

class CredentialPoolTransaction extends PostgresTransaction {
  CredentialPoolTransaction({
    required this.bearerByOp,
    required this.refreshTokenByOp,
    required this.expiresAt,
    required this.metadataByOp,
    required this.connectionMetadataByOp,
  });

  final Map<String, String> bearerByOp;
  final Map<String, String> refreshTokenByOp;
  final DateTime expiresAt;
  final Map<String, Map<String, Object?>> metadataByOp;
  final Map<String, Map<String, Object?>> connectionMetadataByOp;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];

  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.vendor_credentials') &&
        sql.contains('pgp_sym_decrypt')) {
      final operatorId = parameters['operator_id'] as String?;
      final bearer = bearerByOp[operatorId];
      if (bearer == null) return <PostgresRow>[];
      final metadata = metadataByOp[operatorId] ?? const <String, Object?>{};
      final connectionMetadata =
          connectionMetadataByOp[operatorId] ?? const <String, Object?>{};
      return <PostgresRow>[
        <String, Object?>{
          'access_token_plaintext': bearer,
          'refresh_token_plaintext': refreshTokenByOp[operatorId],
          'token_expires_at': expiresAt,
          'metadata': jsonEncode(metadata),
          'connection_metadata': jsonEncode(connectionMetadata),
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
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
  }
}
