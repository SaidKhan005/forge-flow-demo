// Phase 9.2 - OperatorScopedRepository base class.
//
// Repositories that read/write any operator-scoped Postgres table
// extend this base. The base offers exactly two execution paths:
//
//   - [withTenant] — the normal path. Forces a [TenantContext] in;
//     under the hood it runs the body in a transaction with
//     `SET LOCAL app.operator_id / location_id / user_id` injected.
//
//   - [withSystem] — the admin escape hatch. Runs without tenant
//     SET LOCAL; relies on the `forge_admin` Postgres role's
//     `BYPASSRLS` to read/write across tenants. Callers must pass a
//     non-blank [reason] string for audit attribution.
//
// Subclasses MUST NOT take a `PostgresExecutor` directly or store
// one as a field — the only API surface is the two helpers above.
// That keeps the repository pattern (primary defense) and RLS
// (backup defense) properly layered.

import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

abstract class OperatorScopedRepository {
  OperatorScopedRepository(this._tenantWrapper);

  final TenantTransactionWrapper _tenantWrapper;

  /// Run [body] in a tenant-scoped transaction. Returns whatever
  /// [body] returns; commits on success, rolls back on any error.
  ///
  /// Subclasses use this for every read/write that should be visible
  /// only to the operator named in [context].
  Future<R> withTenant<R>(
    TenantContext context,
    Future<R> Function(PostgresExecutor exec) body,
  ) {
    return _tenantWrapper.runInTenantContext(context, body);
  }

  /// Run [body] in a system-scope transaction (no tenant SET LOCAL).
  /// The [reason] string is required and audited; it should describe
  /// the admin path that justified the bypass (e.g. `'admin.users.soft_delete'`).
  ///
  /// Subclasses should keep this on tightly-scoped paths — anything
  /// that could be expressed via [withTenant] (even for an admin
  /// user) must use [withTenant] so the tenant defense layer stays
  /// engaged.
  Future<R> withSystem<R>(
    Future<R> Function(PostgresExecutor exec) body, {
    required String reason,
  }) {
    return _tenantWrapper.runAsSystem(body, reason: reason);
  }
}
