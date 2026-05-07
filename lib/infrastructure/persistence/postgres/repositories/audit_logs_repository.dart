// Phase 9.0Σ.f B.2 — AuditLogsRepository + AuditLogsCutoverFlag.
//
// Append-only writer for the hash-chained `public.audit_logs` table
// landed in `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`.
//
// The companion `AuditLogsCutoverFlag` resolves the per-write
// `audit_logs_cutover_enabled` feature flag. Production wires the
// table-driven implementation
// (`FeatureFlagsTableAuditLogsCutoverFlag`) so flipping the seeded
// `feature_flags` row to `false` immediately routes new writes back
// to the legacy `auth_events_audit`-only path. Tests / scaffolds use
// `const FixedAuditLogsCutoverFlag(true|false)`.
//
// The chain (`prev_row_hash`, `row_hash`) is computed by the BEFORE
// INSERT trigger `public.audit_logs_set_chain()` server-side; this
// repository just supplies the row inputs (operator_id, actor, target,
// action, payload). Producers MUST run the insert from inside an
// existing tenant-scoped transaction so the audit_logs row commits
// atomically with whatever business write it accompanies (the
// `auth_events_audit` legacy row, in B.2's case).
//
// Hard rules carried from
// `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`:
//
//   * `chain_date` MUST equal `(occurred_at at time zone 'UTC')::date`.
//     The CHECK on the table rejects any disagreement; we compute
//     `chain_date` from the same UTC instant the row carries.
//   * `actor_kind` is `'user'` or `'service'`. Exactly one of
//     `actor_user_id` (user case) or `actor_principal_id` (service
//     case) must be set. The `audit_logs_actor_shape_check` enforces
//     this — callers that violate the shape get a runtime error from
//     the constraint, which is the desired hard-stop for misuse.
//   * `prev_row_hash` and `row_hash` are NOT supplied here; the
//     BEFORE INSERT trigger sets both before constraint validation.

import 'dart:convert';

import '../postgres_executor.dart';

class AuditLogsRepository {
  const AuditLogsRepository();

  /// Inserts one row into `public.audit_logs` inside the caller's
  /// existing transaction so the new audit-logs write commits
  /// atomically with the business row it accompanies (e.g. the
  /// `auth_events_audit` row written by the auth-event boundary).
  ///
  /// The BEFORE INSERT trigger (`public.audit_logs_set_chain()`)
  /// computes `prev_row_hash` and `row_hash` server-side; this method
  /// supplies the row inputs only.
  ///
  /// `actor_kind` is `'user'` or `'service'`; exactly one of
  /// [actorUserId] (user case) or [actorPrincipalId] (service case)
  /// must be set. The DB CHECK constraint enforces this; callers that
  /// violate the shape get a hard-stop from the constraint.
  Future<void> writeRow(
    PostgresExecutor exec, {
    required String operatorId,
    String? locationId,
    DateTime? occurredAt,
    required String actorKind,
    String? actorUserId,
    String? actorPrincipalId,
    String? targetKind,
    String? targetId,
    required String action,
    Map<String, Object?> payload = const <String, Object?>{},
  }) async {
    final occurred = (occurredAt ?? DateTime.now()).toUtc();
    final chainDate = _formatChainDate(occurred);
    await exec.query(
      'insert into public.audit_logs ('
      'operator_id, location_id, chain_date, occurred_at, '
      'actor_kind, actor_user_id, actor_principal_id, '
      'target_kind, target_id, action, payload) '
      'values ('
      '@operator_id::uuid, @location_id::uuid, @chain_date::date, '
      '@occurred_at::timestamptz, @actor_kind, '
      '@actor_user_id::uuid, @actor_principal_id, '
      '@target_kind, @target_id, @action, @payload::jsonb) '
      'returning id',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'chain_date': chainDate,
        'occurred_at': occurred,
        'actor_kind': actorKind,
        'actor_user_id': actorUserId,
        'actor_principal_id': actorPrincipalId,
        'target_kind': targetKind,
        'target_id': targetId,
        'action': action,
        'payload': jsonEncode(payload),
      },
    );
  }

  static String _formatChainDate(DateTime instant) {
    final utc = instant.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }
}

/// Resolves the `audit_logs_cutover_enabled` feature flag. The
/// repository / gateway fan-out callsites read the flag through this
/// abstraction so a deploy-time bool, a test override, or a live
/// `feature_flags` row can drive the same callsite.
abstract class AuditLogsCutoverFlag {
  /// Reads the current flag value. Implementations may consult
  /// [exec] (the same transaction the audit-event boundary is
  /// running in) so the read participates in the caller's tx.
  Future<bool> isEnabled(PostgresExecutor exec);
}

/// Fixed-value flag — used when the deploy doesn't need to consult
/// the DB (tests, scaffolds, deterministic unit fixtures). Defaults
/// to `true` so the production-shaped construction still emits the
/// fan-out by default.
class FixedAuditLogsCutoverFlag implements AuditLogsCutoverFlag {
  const FixedAuditLogsCutoverFlag(this.enabled);

  final bool enabled;

  @override
  Future<bool> isEnabled(PostgresExecutor exec) async => enabled;
}

/// Production-grade flag resolver that reads
/// `public.feature_flags.audit_logs_cutover_enabled` (system-wide
/// scope: `operator_id = public.feature_flag_system_wide_operator_id()
/// and location_id is null`) inside the caller's transaction.
/// Default-on when the row is missing so a fresh DB that has not run
/// the seed migration still emits the fan-out.
///
/// Per-write SELECT cost is one indexed row read on the operator-
/// scope partial unique index (`feature_flags_operator_scope_idx`);
/// see `db/migrations/202605072000_feature_flags_sentinel_operator
/// .sql` for why the dedicated global-scope index was retired in
/// favor of folding system-wide reads into the tenant-leading
/// index. The RLS posture is `service_role_all using (...)` so the
/// read participates from either the tenant or admin pool.
class FeatureFlagsTableAuditLogsCutoverFlag implements AuditLogsCutoverFlag {
  const FeatureFlagsTableAuditLogsCutoverFlag();

  @override
  Future<bool> isEnabled(PostgresExecutor exec) async {
    final rows = await exec.query(
      "select enabled "
      'from public.feature_flags '
      "where flag_name = 'audit_logs_cutover_enabled' "
      'and operator_id = public.feature_flag_system_wide_operator_id() '
      'and location_id is null '
      'limit 1',
    );
    if (rows.isEmpty) return true;
    final value = rows.single['enabled'];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.toLowerCase() == 'true' || value == 't';
    return true;
  }
}
