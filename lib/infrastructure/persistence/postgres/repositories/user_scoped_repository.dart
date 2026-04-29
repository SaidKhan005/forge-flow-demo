// Phase 9 live-closeout B39 - UserScopedRepository base class.
//
// Repositories that read/write a per-user Postgres table whose RLS
// policy filters by `public.app_current_actor_user()` (i.e. the
// `app.user_id` GUC) — and that have no `operator_id` column to gate
// on — extend this base instead of [OperatorScopedRepository].
//
// The single execution path is [withUser], which routes through
// [TenantTransactionWrapper.runInUserContext]. That wrapper:
//
//   * sets only `app.user_id` transaction-locally via
//     `select set_config(..., true)` with parameter binding,
//   * marks the audit slot `app.bypass_rls_audit = 'user'`, and
//   * does NOT issue `set local role forge_admin` — RLS itself
//     admits the row when `user_id = app_current_actor_user()`.
//
// Subclasses MUST NOT take a `PostgresExecutor` directly or store one
// as a field. The narrow surface keeps the repository pattern (primary
// defense) and RLS (backup defense) properly layered, same as the
// operator-scoped base.

import '../postgres_executor.dart';
import '../tenant_transaction.dart';

abstract class UserScopedRepository {
  UserScopedRepository(this._tenantWrapper);

  final TenantTransactionWrapper _tenantWrapper;

  /// Run [body] in a per-user transaction with `app.user_id` injected
  /// for [userId]. Returns whatever [body] returns; commits on
  /// success, rolls back on any error.
  Future<R> withUser<R>(
    String userId,
    Future<R> Function(PostgresExecutor exec) body,
  ) {
    return _tenantWrapper.runInUserContext(userId, body);
  }
}
