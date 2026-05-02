// Phase 11A.7 — FeatureFlagsRepository.
//
// Persistence layer for `public.feature_flags` (the launch flag
// catalog backing the admin Feature Flags surface). The table is
// platform-wide — flags can be global (operator_id null), operator-
// wide (operator_id set, location_id null), or location-scoped (both
// set) — so every statement runs through `withSystem` with a
// non-blank [adminReason] string.
//
// Idempotent toggle contract:
//
//   * `toggleFlag` uses `update … set enabled = @enabled, updated_by
//     = @actor` on the matching `flag_id`. The trigger
//     `feature_flags_set_updated_at` carries `updated_at` forward; we
//     read the resulting row back via `RETURNING *` so the proxy
//     route handler can project it without a follow-up SELECT.
//
//   * `listFlags` reads every row, ordered destructive-first then
//     alphabetical so the admin grid surfaces kill switches at the
//     top.
//
// Plaintext flag values are not secrets — the table holds gating bits
// and operator-facing copy only — so the repository does not redact.
// `auth_events_audit` / `audit_logs` carry the actor + intent durably;
// the row's `updated_by` is the cheap denormalized read for the grid.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

class FeatureFlagsRepository extends OperatorScopedRepository {
  FeatureFlagsRepository(super.tenantWrapper);

  static const String _selectColumns =
      'flag_id::text as flag_id, '
      'flag_name, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'enabled, '
      'kind, '
      'description, '
      'updated_by, '
      'created_at, '
      'updated_at';

  /// SELECT every row in `feature_flags`. Ordered destructive-first
  /// then by `flag_name` so the admin grid surfaces kill switches up
  /// top.
  Future<List<FeatureFlagRow>> listFlags({required String adminReason}) {
    return withSystem<List<FeatureFlagRow>>((exec) async {
      final rows = await exec.query(
        'select $_selectColumns from public.feature_flags '
        'order by case when kind = \'destructive\' then 0 else 1 end, '
        'flag_name asc',
      );
      return <FeatureFlagRow>[
        for (final row in rows) _rowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// SELECT one row by `flag_id`. Returns null when the row is missing
  /// — the admin proxy projects that into a 404 `unknown_flag`.
  Future<FeatureFlagRow?> findById({
    required String flagId,
    required String adminReason,
  }) {
    return withSystem<FeatureFlagRow?>((exec) async {
      final rows = await exec.query(
        'select $_selectColumns from public.feature_flags '
        'where flag_id = @flag_id::uuid limit 1',
        parameters: <String, Object?>{'flag_id': flagId},
      );
      if (rows.isEmpty) return null;
      return _rowFromMap(rows.first);
    }, reason: adminReason);
  }

  /// UPDATE `enabled` + `updated_by` on the row keyed by `flag_id`.
  /// Returns the post-update row, or null when no row matches (the
  /// proxy treats null as 404 `unknown_flag`).
  ///
  /// [actorUserId] is REQUIRED. The proxy resolves the verified
  /// Firebase UID into a Postgres `users.user_id` (UUID-shaped string)
  /// before this method runs and rejects with 403
  /// `actor_user_not_resolvable` when no active row matches.
  ///
  /// [onCommit], when supplied, runs after the UPDATE returns its row
  /// but BEFORE the `withSystem` transaction commits. Both the
  /// UPDATE and the [onCommit] callback share the same Postgres
  /// executor, so any writes the callback issues commit atomically
  /// with the flag mutation. HARD-D's audit-row write rides this
  /// seam so the `feature_flags` row update and the
  /// `auth_events_audit` (+ hash-chained `audit_logs`) write either
  /// both commit or both roll back. If [onCommit] throws, the
  /// transaction rolls back and no flag mutation lands. The
  /// callback is not invoked when the UPDATE matches no rows
  /// (returns null).
  Future<FeatureFlagRow?> toggleFlag({
    required String flagId,
    required bool enabled,
    required String actorUserId,
    required String adminReason,
    Future<void> Function(PostgresExecutor exec, FeatureFlagRow row)? onCommit,
  }) {
    return withSystem<FeatureFlagRow?>((exec) async {
      final rows = await exec.query(
        'update public.feature_flags '
        'set enabled = @enabled, '
        '    updated_by = @actor '
        'where flag_id = @flag_id::uuid '
        'returning $_selectColumns',
        parameters: <String, Object?>{
          'enabled': enabled,
          'actor': actorUserId,
          'flag_id': flagId,
        },
      );
      if (rows.isEmpty) return null;
      final row = _rowFromMap(rows.single);
      if (onCommit != null) await onCommit(exec, row);
      return row;
    }, reason: adminReason);
  }
}

/// Projection of one `feature_flags` row. Mirrors the table columns
/// plus the 11A.7 admin additions (`kind`, `description`,
/// `updated_by`).
class FeatureFlagRow {
  const FeatureFlagRow({
    required this.flagId,
    required this.flagName,
    required this.operatorId,
    required this.locationId,
    required this.enabled,
    required this.kind,
    required this.description,
    required this.updatedBy,
    required this.createdAt,
    required this.updatedAt,
  });

  final String flagId;
  final String flagName;
  final String? operatorId;
  final String? locationId;
  final bool enabled;
  final String kind;
  final String? description;
  final String? updatedBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'flag_id': flagId,
        'flag_name': flagName,
        'operator_id': operatorId,
        'location_id': locationId,
        'enabled': enabled,
        'kind': kind,
        'description': description,
        'updated_by': updatedBy,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}

FeatureFlagRow _rowFromMap(PostgresRow row) {
  return FeatureFlagRow(
    flagId: row['flag_id']! as String,
    flagName: row['flag_name']! as String,
    operatorId: row['operator_id'] as String?,
    locationId: row['location_id'] as String?,
    enabled: row['enabled'] as bool? ?? false,
    kind: (row['kind'] as String?) ?? 'standard',
    description: row['description'] as String?,
    updatedBy: row['updated_by'] as String?,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
