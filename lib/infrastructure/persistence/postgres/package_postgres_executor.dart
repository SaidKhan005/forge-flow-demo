// Phase 9 live-closeout - package:postgres binding.
//
// This is the only production adapter that imports `package:postgres`.
// All application repositories continue to depend on the local
// PostgresExecutor/PostgresPool seams so tenant SET LOCAL injection
// remains centralized in TenantTransactionWrapper.

import 'package:postgres/postgres.dart' as pg;

import 'postgres_executor.dart';

typedef PackagePostgresConnectionFactory =
    Future<PackagePostgresConnection> Function();

abstract class PackagePostgresConnection {
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
  });

  Future<void> close({bool force = false});
}

class PackagePostgresPool implements PostgresPool {
  PackagePostgresPool({
    required PackagePostgresConnectionFactory openConnection,
  }) : _openConnection = openConnection;

  PackagePostgresPool.fromUrl(String connectionString)
    : this(
        openConnection: () async => _RealPackagePostgresConnection(
          await pg.Connection.openFromUrl(connectionString),
        ),
      );

  final PackagePostgresConnectionFactory _openConnection;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final connection = await _openConnection();
    try {
      await connection.execute('begin', ignoreRows: true);
      return _PackagePostgresTransaction(connection);
    } catch (_) {
      await connection.close(force: true);
      rethrow;
    }
  }
}

class _RealPackagePostgresConnection implements PackagePostgresConnection {
  _RealPackagePostgresConnection(this._connection);

  final pg.Connection _connection;

  @override
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
  }) {
    return _connection.execute(
      query,
      parameters: parameters,
      ignoreRows: ignoreRows,
    );
  }

  @override
  Future<void> close({bool force = false}) {
    return _connection.close(force: force);
  }
}

class _PackagePostgresTransaction implements PostgresTransaction {
  _PackagePostgresTransaction(this._connection);

  final PackagePostgresConnection _connection;
  var _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    _ensureOpen();
    final result = await _connection.execute(
      pg.Sql.named(sql),
      parameters: parameters,
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    _ensureOpen();
    final result = await _connection.execute(
      pg.Sql.named(sql),
      parameters: parameters,
      ignoreRows: true,
    );
    return result.affectedRows;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    try {
      await _connection.execute('commit', ignoreRows: true);
    } finally {
      await _connection.close();
    }
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    try {
      await _connection.execute('rollback', ignoreRows: true);
    } finally {
      await _connection.close(force: true);
    }
  }

  void _ensureOpen() {
    if (_finalized) {
      throw StateError('Postgres transaction already finalized');
    }
  }
}
