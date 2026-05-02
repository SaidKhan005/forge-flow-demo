// Phase 9.2 - Postgres execution seam.
//
// The seam abstracts every SQL execution call so the repository
// pattern can be unit-tested with fakes. The production
// `package:postgres` adapter lives in package_postgres_executor.dart;
// repositories still depend only on this seam.
//
// Hard rules carried from CLAUDE.md:
//   * Only files under `lib/infrastructure/persistence/postgres/` may
//     import the concrete `package:postgres` binding directly.
//     Everything else routes through this seam.
//   * Tenant injection uses `SET LOCAL` (transaction-scoped). Pooled
//     connection reuse must NOT carry tenant context across
//     transactions — see [TenantTransactionWrapper].
//   * Statement parameters are positional/named bindings, never
//     string concatenation.
//
// HARD-G observability defaults (the contract pins these values):
//   * `kPostgresPerStatementTimeout` — every executed query / write
//     must complete within 5 s. The package adapter wraps each
//     `query`/`execute` call in `.timeout(...)`; on expiry the call
//     throws so callers surface the failure as `dependency_timeout`.
//   * `kPostgresAcquireConnectionTimeout` — pool `beginTransaction`
//     must borrow a connection and complete the initial `BEGIN` within
//     10 s. The package adapter wraps the connection-borrow + initial
//     `BEGIN` in `.timeout(...)`. At startup the proxy refuses to
//     bind a port if the timer elapses (exit 78).
//   * `kPostgresDefaultMaxConnectionsPerPool` - production
//     `PackagePostgresPool.fromUrl` keeps a small per-process pool so
//     Cloud Run does not open a new Postgres session for every request.

const Duration kPostgresPerStatementTimeout = Duration(seconds: 5);
const Duration kPostgresAcquireConnectionTimeout = Duration(seconds: 10);
const int kPostgresDefaultMaxConnectionsPerPool = 4;

/// Result row shape. Column names map to dynamic values produced by
/// the underlying driver (UUIDs as strings, timestamptz as
/// `DateTime`, etc.).
typedef PostgresRow = Map<String, Object?>;

/// SQL parameter map. Implementations bind these via the underlying
/// driver's parameter mechanism (`@name` placeholders for
/// `package:postgres`). Tests pass arbitrary maps to assert what was
/// bound on each call.
typedef PostgresParameters = Map<String, Object?>;

/// Anything that can run SQL. A [PostgresTransaction] is one; in
/// principle a pool-level autocommit handle could be another, but
/// the repository pattern intentionally never exposes pool-level
/// execution — every operation runs inside a transaction so SET
/// LOCAL semantics hold.
abstract class PostgresExecutor {
  /// Runs a SELECT (or DML with RETURNING) and returns rows.
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  });

  /// Runs a write (INSERT / UPDATE / DELETE / DDL) without expecting
  /// rows back. Returns the affected-row count when the underlying
  /// driver reports it; implementations that cannot report it (e.g.
  /// DDL) return 0.
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  });
}

/// A transaction handle. Borrowed from a [PostgresPool], used to run
/// SET LOCAL + the body, and committed/rolled back exactly once.
abstract class PostgresTransaction extends PostgresExecutor {
  /// Commits the transaction. Idempotent: calling commit on an
  /// already-finalized transaction is a no-op (the wrapper relies
  /// on this when handling double-finalization paths).
  Future<void> commit();

  /// Rolls back the transaction. Idempotent for the same reasons as
  /// [commit].
  Future<void> rollback();
}

/// A connection pool. The wrapper opens one transaction per request
/// and discards it on commit/rollback. Tests inject a fake pool that
/// hands out fake transactions.
abstract class PostgresPool {
  /// Borrows a connection and starts a transaction on it. The
  /// returned handle owns the transaction lifecycle until commit /
  /// rollback. The pool MUST guarantee that `SET LOCAL` issued
  /// inside the transaction does not survive past commit/rollback —
  /// pooled connection reuse with leaked tenant context is the exact
  /// hazard the RLS performance discipline lock calls out (see
  /// CLAUDE.md "RLS performance discipline").
  Future<PostgresTransaction> beginTransaction();
}
