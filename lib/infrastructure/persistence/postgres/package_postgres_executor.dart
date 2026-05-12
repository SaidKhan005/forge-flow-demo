// Phase 9 live-closeout - package:postgres binding.
//
// This is the only production adapter that imports `package:postgres`.
// All application repositories continue to depend on the local
// PostgresExecutor/PostgresPool seams so tenant SET LOCAL injection
// remains centralized in TenantTransactionWrapper.
//
// HARD-G observability: every per-statement call wraps in
// `.timeout(kPostgresPerStatementTimeout)`. `beginTransaction` wraps
// the connection-borrow + initial `BEGIN` in
// `.timeout(kPostgresAcquireConnectionTimeout)`. The production
// `fromUrl` constructor uses a bounded reusable connection pool; the
// direct constructor remains close-on-commit by default for focused
// tests and scaffolds. Tuning constants live in postgres_executor.dart
// so future changes land in one place.

import 'dart:async';
import 'dart:collection';

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

/// Read-only snapshot of [PackagePostgresPool] saturation. Exposed
/// so the proxy `/health` envelope can surface pool gauges without
/// reaching into private state. Counts are non-negative integers.
///
/// A1 §2.4 instrumentation: emit `openConnectionCount`, `idleCount`,
/// `waiterCount` so we can spot Postgres pool exhaustion before it
/// cascades. Pool max is included so a single read of the snapshot
/// answers "are we at the ceiling".
class PostgresPoolGaugeSnapshot {
  const PostgresPoolGaugeSnapshot({
    required this.openConnectionCount,
    required this.idleCount,
    required this.waiterCount,
    required this.maxConnectionCount,
  });

  final int openConnectionCount;
  final int idleCount;
  final int waiterCount;
  final int maxConnectionCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'open_connection_count': openConnectionCount,
        'idle_count': idleCount,
        'waiter_count': waiterCount,
        'max_connection_count': maxConnectionCount,
      };
}

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
    bool reuseConnections = false,
    int maxConnectionCount = kPostgresDefaultMaxConnectionsPerPool,
  }) : _openConnection = openConnection,
       _acquireConnectionTimeout = acquireConnectionTimeout,
       _perStatementTimeout = perStatementTimeout,
       _reusableConnections = reuseConnections
           ? _ReusablePackagePostgresConnections(
               openConnection: openConnection,
               maxConnectionCount: maxConnectionCount,
             )
           : null {
    if (maxConnectionCount < 1) {
      throw ArgumentError.value(
        maxConnectionCount,
        'maxConnectionCount',
        'must be at least 1',
      );
    }
  }

  PackagePostgresPool.fromUrl(
    String connectionString, {
    Duration acquireConnectionTimeout = kPostgresAcquireConnectionTimeout,
    Duration perStatementTimeout = kPostgresPerStatementTimeout,
    int maxConnectionCount = kPostgresDefaultMaxConnectionsPerPool,
  }) : this(
         openConnection: () async => _RealPackagePostgresConnection(
           await pg.Connection.openFromUrl(connectionString),
         ),
         acquireConnectionTimeout: acquireConnectionTimeout,
         perStatementTimeout: perStatementTimeout,
         reuseConnections: true,
         maxConnectionCount: maxConnectionCount,
       );

  final PackagePostgresConnectionFactory _openConnection;
  final Duration _acquireConnectionTimeout;
  final Duration _perStatementTimeout;
  final _ReusablePackagePostgresConnections? _reusableConnections;

  /// Read-only snapshot of pool saturation, surfaced via the proxy
  /// `/health` envelope so we can spot pool exhaustion before it
  /// cascades into root-zone uncaught failures (A1 §2.4 item #3).
  ///
  /// Returns null when this pool runs without connection reuse — in
  /// that mode there is no shared pool to inspect.
  PostgresPoolGaugeSnapshot? get gaugeSnapshot {
    final reusable = _reusableConnections;
    if (reusable == null) return null;
    return reusable._snapshotForGauges();
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final lease = await _borrowConnection();
    try {
      await lease.connection
          .execute('begin', ignoreRows: true)
          .timeout(_perStatementTimeout);
      return _PackagePostgresTransaction(lease, _perStatementTimeout);
    } on TimeoutException {
      await lease.discard();
      throw _emitPostgresTimeout(
        operation: 'begin',
        timeout: _perStatementTimeout,
      );
    } on Exception catch (e) {
      // BEGIN failed for a non-timeout reason (server killed the
      // session, network reset, role-elevate refused, etc.). Discard
      // the lease so the bad connection isn't reused, log structured,
      // and let the caller see the original error.
      log(
        LogSeverity.warning,
        'postgres.begin_failed',
        fields: <String, Object?>{
          'kind': 'exception',
          'error': e.toString(),
        },
      );
      await lease.discard();
      rethrow;
    } on Object catch (e, st) {
      // Non-`Exception` throws (raw `String`, `Error` subclass, etc.).
      // Same posture: discard, log with stack, rethrow.
      log(
        LogSeverity.error,
        'postgres.begin_failed',
        fields: <String, Object?>{
          'kind': 'unhandled',
          'error': e.toString(),
          'stack_first_frame': firstStackFrame(st),
        },
      );
      await lease.discard();
      rethrow;
    }
  }

  Future<void> closeIdleConnections() async {
    await _reusableConnections?.closeIdleConnections();
  }

  Future<_PackagePostgresLease> _borrowConnection() async {
    try {
      final reusableConnections = _reusableConnections;
      if (reusableConnections == null) {
        final connectionFuture = _openConnection();
        try {
          return _PackagePostgresLease.unpooled(
            await connectionFuture.timeout(_acquireConnectionTimeout),
          );
        } on TimeoutException {
          unawaited(
            connectionFuture.then(
              (connection) => connection.close(force: true),
              onError: (_) {},
            ),
          );
          rethrow;
        }
      }
      return _PackagePostgresLease.pooled(
        await reusableConnections.acquire(_acquireConnectionTimeout),
        reusableConnections,
      );
    } on TimeoutException {
      throw _emitPostgresTimeout(
        operation: 'acquire_connection',
        timeout: _acquireConnectionTimeout,
      );
    }
  }
}

class _PackagePostgresLease {
  _PackagePostgresLease.unpooled(this.connection) : _pool = null;

  _PackagePostgresLease.pooled(this.connection, this._pool);

  final PackagePostgresConnection connection;
  final _ReusablePackagePostgresConnections? _pool;

  Future<void> release() async {
    final pool = _pool;
    if (pool == null) {
      await connection.close();
      return;
    }
    pool.release(connection);
  }

  Future<void> discard() async {
    final pool = _pool;
    if (pool == null) {
      await connection.close(force: true);
      return;
    }
    await pool.discard(connection);
  }
}

class _PackagePostgresWaiter {
  _PackagePostgresWaiter(this.timeout);

  final Duration timeout;
  final completer = Completer<PackagePostgresConnection>();
  var canceled = false;
}

class _ReusablePackagePostgresConnections {
  _ReusablePackagePostgresConnections({
    required PackagePostgresConnectionFactory openConnection,
    required int maxConnectionCount,
  }) : _openConnection = openConnection,
       _maxConnectionCount = maxConnectionCount;

  final PackagePostgresConnectionFactory _openConnection;
  final int _maxConnectionCount;
  final _idle = Queue<PackagePostgresConnection>();
  final _waiters = Queue<_PackagePostgresWaiter>();
  var _openConnectionCount = 0;

  /// Snapshot saturation counters for the `/health` envelope. Counted
  /// from the live `Queue` lengths + `_openConnectionCount` so the
  /// values can be sampled at any time without holding a lock — Dart
  /// is single-threaded per isolate, so the read is consistent.
  PostgresPoolGaugeSnapshot _snapshotForGauges() {
    return PostgresPoolGaugeSnapshot(
      openConnectionCount: _openConnectionCount,
      idleCount: _idle.length,
      waiterCount: _waiters.length,
      maxConnectionCount: _maxConnectionCount,
    );
  }

  Future<PackagePostgresConnection> acquire(Duration timeout) async {
    if (_idle.isNotEmpty) return _idle.removeFirst();

    if (_openConnectionCount < _maxConnectionCount) {
      return _openNewConnection(timeout);
    }

    final waiter = _PackagePostgresWaiter(timeout);
    _waiters.addLast(waiter);
    try {
      return await waiter.completer.future.timeout(timeout);
    } on TimeoutException {
      waiter.canceled = true;
      _waiters.remove(waiter);
      rethrow;
    }
  }

  void release(PackagePostgresConnection connection) {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (waiter.canceled) continue;
      waiter.completer.complete(connection);
      return;
    }
    _idle.addLast(connection);
  }

  Future<void> discard(PackagePostgresConnection connection) async {
    if (_openConnectionCount > 0) _openConnectionCount -= 1;
    try {
      await connection.close(force: true);
    } finally {
      _openForNextWaiter();
    }
  }

  Future<void> closeIdleConnections() async {
    while (_idle.isNotEmpty) {
      final connection = _idle.removeFirst();
      if (_openConnectionCount > 0) _openConnectionCount -= 1;
      await connection.close();
    }
  }

  Future<PackagePostgresConnection> _openNewConnection(Duration timeout) async {
    _openConnectionCount += 1;
    final connectionFuture = _openConnection();
    try {
      return await connectionFuture.timeout(timeout);
    } on TimeoutException {
      _openConnectionCount -= 1;
      unawaited(
        connectionFuture.then(
          (connection) => connection.close(force: true),
          onError: (_) {},
        ),
      );
      _openForNextWaiter();
      rethrow;
    } on Exception catch (e) {
      // Non-timeout open failure (DNS, TLS handshake, auth refused).
      // Roll back the count so the pool can try again, log
      // structured, and let the caller see the original error.
      log(
        LogSeverity.warning,
        'postgres.open_connection_failed',
        fields: <String, Object?>{
          'kind': 'exception',
          'error': e.toString(),
        },
      );
      _openConnectionCount -= 1;
      _openForNextWaiter();
      rethrow;
    } on Object catch (e, st) {
      // Non-`Exception` throws — same posture as the `Exception`
      // branch with the stack frame attached for diagnosis.
      log(
        LogSeverity.error,
        'postgres.open_connection_failed',
        fields: <String, Object?>{
          'kind': 'unhandled',
          'error': e.toString(),
          'stack_first_frame': firstStackFrame(st),
        },
      );
      _openConnectionCount -= 1;
      _openForNextWaiter();
      rethrow;
    }
  }

  void _openForNextWaiter() {
    if (_openConnectionCount >= _maxConnectionCount) return;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (waiter.canceled) continue;
      _openConnectionCount += 1;
      final connectionFuture = _openConnection();
      unawaited(
        connectionFuture
            .timeout(waiter.timeout)
            .then(
              (connection) {
                if (waiter.canceled) {
                  release(connection);
                  return;
                }
                waiter.completer.complete(connection);
              },
              onError: (Object error, StackTrace stackTrace) {
                _openConnectionCount -= 1;
                if (error is TimeoutException) {
                  unawaited(
                    connectionFuture.then(
                      (connection) => connection.close(force: true),
                      onError: (_) {},
                    ),
                  );
                }
                if (!waiter.canceled) {
                  waiter.completer.completeError(error, stackTrace);
                }
                _openForNextWaiter();
              },
            ),
      );
      return;
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
  _PackagePostgresTransaction(this._lease, this._perStatementTimeout);

  final _PackagePostgresLease _lease;
  final Duration _perStatementTimeout;
  var _finalized = false;

  PackagePostgresConnection get _connection => _lease.connection;

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
          .execute(pg.Sql.named(sql), parameters: parameters, ignoreRows: true)
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
    var shouldRelease = true;
    try {
      await _connection
          .execute('commit', ignoreRows: true)
          .timeout(_perStatementTimeout);
    } on TimeoutException {
      shouldRelease = false;
      await _lease.discard();
      throw _emitPostgresTimeout(
        operation: 'commit',
        timeout: _perStatementTimeout,
      );
    } on Exception catch (e) {
      // COMMIT failed for a non-timeout reason (constraint deferred
      // to commit time, server abort, etc.). Discard the lease so a
      // wedged session is not returned to the pool, log structured,
      // and let the caller see the original error.
      log(
        LogSeverity.warning,
        'postgres.commit_failed',
        fields: <String, Object?>{
          'kind': 'exception',
          'error': e.toString(),
        },
      );
      shouldRelease = false;
      await _lease.discard();
      rethrow;
    } on Object catch (e, st) {
      // Non-`Exception` throws — same posture, with stack for
      // diagnosis. The original error still reaches the caller.
      log(
        LogSeverity.error,
        'postgres.commit_failed',
        fields: <String, Object?>{
          'kind': 'unhandled',
          'error': e.toString(),
          'stack_first_frame': firstStackFrame(st),
        },
      );
      shouldRelease = false;
      await _lease.discard();
      rethrow;
    } finally {
      if (shouldRelease) {
        await _lease.release();
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
      throw _emitPostgresTimeout(
        operation: 'rollback',
        timeout: _perStatementTimeout,
      );
    } finally {
      await _lease.discard();
    }
  }

  void _ensureOpen() {
    if (_finalized) {
      throw StateError('Postgres transaction already finalized');
    }
  }
}
