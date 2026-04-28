// Forge & Flow advisor proxy bootstrap helpers.
//
// Kept separate from `main.dart` so production wiring can be tested
// without binding a socket or opening a live database connection.

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';

import 'advisor_proxy.dart';

typedef PostgresPoolFactory = PostgresPool Function(String connectionString);

/// Builds the production auth-session ledger writer for the proxy.
///
/// Auth session writes are tenant-scoped user operations, so they use
/// [ProxySecretNames.postgresUrl] rather than the admin/deployment DSN.
/// The returned writer still fails closed at request time if the
/// database is unavailable; constructing it does not open a network
/// connection.
AuthSessionLedgerWriter buildAuthSessionLedgerWriter(
  ProxyConfig config, {
  PostgresPoolFactory postgresPoolFactory = PackagePostgresPool.fromUrl,
}) {
  final pool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresUrl),
  );
  return RepositoryAuthSessionLedgerWriter(
    repository: AuthSessionsRepository(TenantTransactionWrapper(pool)),
  );
}
