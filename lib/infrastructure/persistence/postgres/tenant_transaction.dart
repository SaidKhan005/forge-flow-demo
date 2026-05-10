// Phase 9.2 - Tenant transaction wrapper.
//
// Every operator-scoped Postgres operation goes through
// [TenantTransactionWrapper.runInTenantContext]. The wrapper:
//
//   1. Opens a transaction on the underlying [PostgresPool].
//   2. Issues `SET LOCAL` for `app.operator_id`, `app.location_id`,
//      and (when present) `app.user_id` so the per-tenant RLS
//      policies can read them via `current_setting(..., true)`.
//   3. Runs the caller's body with the transaction handle.
//   4. Commits on success, rolls back on any error.
//
// `SET LOCAL` (transaction-scoped) is the locked decision. Plain
// `SET` would survive past the transaction on a pooled connection
// and leak tenant context into the next request — see CLAUDE.md
// "RLS performance discipline".
//
// System-operation paths (admin endpoints under `/v1/admin/*`) use
// [runAsSystem] instead. That code path skips tenant SET LOCAL
// entirely and relies on the `forge_admin` Postgres role's
// `BYPASSRLS` privilege. Every system-operation transaction marks
// `app.bypass_rls_audit = 'system'` so any incidental read of
// `current_setting('app.bypass_rls_audit', true)` from an audit
// trigger picks it up.

import 'dart:async';

import '../../../services/observability/log.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';

/// Structured-log helper for rollback failures inside a `finally`
/// block. The original body error is the one we want to surface to
/// the caller; a secondary rollback failure would only mask it. We
/// classify each rollback exception via typed-catch arms (matches
/// PR #364 pattern: `TimeoutException` → `Exception` → `Object`) so
/// SREs see when a connection is wedged without losing the original
/// error to the caller.
void _logRollbackFailure({
  required String operation,
  required String kind,
  required Object error,
  StackTrace? stackTrace,
}) {
  log(
    LogSeverity.warning,
    'tenant_transaction.rollback_failed',
    fields: <String, Object?>{
      'operation': operation,
      'kind': kind,
      'error': error.toString(),
      if (stackTrace != null) 'stack_first_frame': firstStackFrame(stackTrace),
    },
  );
}

class TenantTransactionWrapper {
  TenantTransactionWrapper(this._pool);

  final PostgresPool _pool;

  /// Runs [body] inside a transaction with the tenant context
  /// injected via `SET LOCAL`. Commits on success; rolls back and
  /// rethrows on any error from the body or the SET LOCAL calls.
  ///
  /// Returns whatever [body] returns. The transaction handle passed
  /// to [body] is the same [PostgresTransaction] the wrapper opened;
  /// callers should issue all reads/writes through it so they share
  /// the SET LOCAL session-state.
  Future<R> runInTenantContext<R>(
    TenantContext context,
    Future<R> Function(PostgresExecutor exec) body,
  ) async {
    final tx = await _pool.beginTransaction();
    var finalized = false;
    try {
      // Use `select set_config(..., true)` rather than `SET LOCAL <name> = '<value>'`
      // so the value flows through parameter binding instead of string
      // interpolation. The third argument `true` makes set_config
      // transaction-local, equivalent to SET LOCAL semantically.
      await tx.execute(
        "select set_config('app.operator_id', @value, true)",
        parameters: <String, Object?>{'value': context.operatorId},
      );
      await tx.execute(
        "select set_config('app.location_id', @value, true)",
        parameters: <String, Object?>{'value': context.locationId},
      );
      final userId = context.userId;
      if (userId != null) {
        await tx.execute(
          "select set_config('app.user_id', @value, true)",
          parameters: <String, Object?>{'value': userId},
        );
      }
      // Mark the session as a tenant-scoped (non-system) op for
      // any audit trigger that wants to differentiate the two.
      await tx.execute(
        "select set_config('app.bypass_rls_audit', 'tenant', true)",
      );
      final result = await body(tx);
      await tx.commit();
      finalized = true;
      return result;
    } finally {
      if (!finalized) {
        try {
          await tx.rollback();
        } on TimeoutException catch (e, st) {
          // Rollback failures are intentionally swallowed: the
          // original error from the body is more useful, and
          // surfacing a secondary rollback failure would mask it.
          // Structured-log so SREs see when a connection is wedged.
          _logRollbackFailure(
            operation: 'runInTenantContext',
            kind: 'timeout',
            error: e,
            stackTrace: st,
          );
        } on Exception catch (e, st) {
          _logRollbackFailure(
            operation: 'runInTenantContext',
            kind: 'exception',
            error: e,
            stackTrace: st,
          );
        } on Object catch (e, st) {
          _logRollbackFailure(
            operation: 'runInTenantContext',
            kind: 'unhandled',
            error: e,
            stackTrace: st,
          );
        }
      }
    }
  }

  /// Runs [body] inside a transaction with only `app.user_id`
  /// injected (no operator/location SET LOCAL). For per-user tables
  /// whose RLS policy filters by `public.app_current_actor_user()`
  /// (e.g. `recovery_code_attempts`) and that have no `operator_id`
  /// column to gate on. The audit marker is `'user'`; no
  /// `set local role forge_admin` is issued — the policy itself
  /// admits the row when `app.user_id` matches.
  ///
  /// Commit/rollback semantics mirror [runInTenantContext]: commits
  /// on body success, rolls back and rethrows on any error from the
  /// body or the SET LOCAL calls. Secondary rollback failures are
  /// swallowed so the original error wins.
  Future<R> runInUserContext<R>(
    String userId,
    Future<R> Function(PostgresExecutor exec) body,
  ) async {
    final tx = await _pool.beginTransaction();
    var finalized = false;
    try {
      await tx.execute(
        "select set_config('app.user_id', @value, true)",
        parameters: <String, Object?>{'value': userId},
      );
      // Audit marker mirrors the tenant path's `'tenant'` so
      // anything reading current_setting('app.bypass_rls_audit', true)
      // can distinguish a user-scoped op from a system op.
      await tx.execute(
        "select set_config('app.bypass_rls_audit', 'user', true)",
      );
      final result = await body(tx);
      await tx.commit();
      finalized = true;
      return result;
    } finally {
      if (!finalized) {
        try {
          await tx.rollback();
        } on TimeoutException catch (e, st) {
          // See [runInTenantContext]; keep the original error.
          _logRollbackFailure(
            operation: 'runInUserContext',
            kind: 'timeout',
            error: e,
            stackTrace: st,
          );
        } on Exception catch (e, st) {
          _logRollbackFailure(
            operation: 'runInUserContext',
            kind: 'exception',
            error: e,
            stackTrace: st,
          );
        } on Object catch (e, st) {
          _logRollbackFailure(
            operation: 'runInUserContext',
            kind: 'unhandled',
            error: e,
            stackTrace: st,
          );
        }
      }
    }
  }

  /// Runs [body] inside a transaction WITHOUT tenant SET LOCAL —
  /// the `forge_admin` Postgres role's `BYPASSRLS` privilege is the
  /// safety net here, and every call audits via the
  /// `app.bypass_rls_audit = 'system'` marker. Reserved for admin
  /// endpoints (`/v1/admin/*`) and confirmed-safe background jobs.
  ///
  /// This is a deliberate escape hatch; callers should NOT use it
  /// for anything that could be expressed in a tenant-scoped
  /// transaction, even an "admin" one. Phase 9.6 audits every
  /// invocation through `auth_events_audit`.
  Future<R> runAsSystem<R>(
    Future<R> Function(PostgresExecutor exec) body, {
    required String reason,
  }) async {
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'must be non-blank');
    }
    final tx = await _pool.beginTransaction();
    var finalized = false;
    try {
      // Audit marker first so any failure of `SET LOCAL ROLE` leaves
      // a trace with the reason. The proxy connects as a Postgres
      // user that holds both `service_role` and `forge_admin`; this
      // SET LOCAL ROLE elevates only for the lifetime of the
      // transaction so RLS bypass is opt-in and time-bounded.
      await tx.execute(
        "select set_config('app.bypass_rls_audit', @value, true)",
        parameters: <String, Object?>{'value': 'system:$reason'},
      );
      await tx.execute('set local role forge_admin');
      final result = await body(tx);
      await tx.commit();
      finalized = true;
      return result;
    } finally {
      if (!finalized) {
        try {
          await tx.rollback();
        } on TimeoutException catch (e, st) {
          // See [runInTenantContext]; keep the original error.
          _logRollbackFailure(
            operation: 'runAsSystem',
            kind: 'timeout',
            error: e,
            stackTrace: st,
          );
        } on Exception catch (e, st) {
          _logRollbackFailure(
            operation: 'runAsSystem',
            kind: 'exception',
            error: e,
            stackTrace: st,
          );
        } on Object catch (e, st) {
          _logRollbackFailure(
            operation: 'runAsSystem',
            kind: 'unhandled',
            error: e,
            stackTrace: st,
          );
        }
      }
    }
  }
}
