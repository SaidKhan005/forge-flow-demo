// Phase 9 live-closeout - package:postgres binding.
//
// This is the only production adapter that imports `package:postgres`.
// All application repositories continue to depend on the local
// PostgresExecutor/PostgresPool seams so tenant SET LOCAL injection
// remains centralized in TenantTransactionWrapper.
//
// HARD-G observability: every per-statement call wraps in
// `.timeout(kPostgresPerStatementTimeout)`. `beginTransaction` wraps
// the connection-open + initial `BEGIN` in
// `.timeout(kPostgresAcquireConnectionTimeout)`. Both constants live
// in postgres_executor.dart so future tuning lands in one place.

import 'dart:async';

import 'package:postgres/postgres.dart' as pg;

import '../../../services/observability/dependency_timeout_exception.dart';
import '../../../services/observability/log.dart';
import 'postgres_executor.dart';

DependencyTimeoutException _emitPostgresTimeout({
  required String operation,
  required Duration timeout,
}) {
  final exception = DependencyTimeoutException(
    surface: 'postgres',
    operation: operation,
    elapsedMs: timeout.inMilliseconds,
  );
  log(
    LogSeverity.error,
    'request.dependency_timeout',
    fields: <String, Object?>{
      'surface': exception.surface,
      'operation': exception.operation,
      'elapsed_ms': exception.elapsedMs,
    },
  );
  return exception;
}

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
    Duration acquireConnectionTimeout = kPostgresAcquireConnectionTimeout,
    Duration perStatementTimeout = kPostgresPerStatementTimeout,
  }) : _openConnection = openConnection,
       _acquireConnectionTimeout = acquireConnectionTimeout,
       _perStatementTimeout = perStatementTimeout;

  PackagePostgresPool.fromUrl(String connectionString)
    : this(
        openConnection: () async => _RealPackagePostgresConnection(
          await pg.Connection.openFromUrl(connectionString),
        ),
      );

  final PackagePostgresConnectionFactory _openConnection;
  final Duration _acquireConnectionTimeout;
  final Duration _perStatementTimeout;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final PackagePostgresConnection connection;
    try {
      connection = await _openConnection().timeout(
        _acquireConnectionTimeout,
      );
    } on TimeoutException {
      throw _emitPostgresTimeout(
        operation: 'acquire_connection',
        timeout: _acquireConnectionTimeout,
      );
    }
    try {
      await connection
          .execute('begin', ignoreRows: true)
          .timeout(_perStatementTimeout);
      return _PackagePostgresTransaction(connection, _perStatementTimeout);
    } on TimeoutException {
      await connection.close(force: true);
      throw _emitPostgresTimeout(
        operation: 'begin',
        timeout: _perStatementTimeout,
      );
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
  _PackagePostgresTransaction(this._connection, this._perStatementTimeout);

  final PackagePostgresConnection _connection;
  final Duration _perStatementTimeout;
  var _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    _ensureOpen();
    try {
      final result = await _connection
          .execute(pg.Sql.named(sql), parameters: parameters)
          .timeout(_perStatementTimeout);
      return result
          .map((row) => Map<String, Object?>.from(row.toColumnMap()))
          .toList(growable: false);
    } on TimeoutException {
      throw _emitPostgresTimeout(
        operation: 'query',
        timeout: _perStatementTimeout,
      );
    }
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    _ensureOpen();
    try {
      final result = await _connection
          .execute(
            pg.Sql.named(sql),
            parameters: parameters,
            ignoreRows: true,
          )
          .timeout(_perStatementTimeout);
      return result.affectedRows;
    } on TimeoutException {
      throw _emitPostgresTimeout(
        operation: 'execute',
        timeout: _perStatementTimeout,
      );
    }
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    var timedOut = false;
    try {
      await _connection
          .execute('commit', ignoreRows: true)
          .timeout(_perStatementTimeout);
    } on TimeoutException {
      timedOut = true;
      await _connection.close(force: true);
      throw _emitPostgresTimeout(
        operation: 'commit',
        timeout: _perStatementTimeout,
      );
    } finally {
      if (!timedOut) {
        await _connection.close();
      }
    }
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    try {
      await _connection
          .execute('rollback', ignoreRows: true)
          .timeout(_perStatementTimeout);
    } on TimeoutException {
      await _connection.close(force: true);
      throw _emitPostgresTimeout(
        operation: 'rollback',
        timeout: _perStatementTimeout,
      );
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
