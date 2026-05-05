// Phase 11A.7 - Feature flags admin value objects.
//
// Carries the `feature_flags` row shape the admin Feature Flags screen
// needs to render and toggle, plus the toggle command. Mirrors the
// columns from
// `db/migrations/202604250005_advisor_cloud_foundation.sql` plus the
// `kind` / `description` / `updated_by` additions from
// `db/migrations/202605020400_phase_11A_7_feature_flags_admin_columns.sql`.
//
// Scope axis (`operatorId` / `locationId` nullable) follows the
// partial-unique-index shape on `feature_flags`:
//
//   * global       → both null
//   * operator     → operator non-null, location null
//   * location     → both non-null
//
// The launch admin UX renders all three scopes in one list; per-scope
// edit affordances land in a follow-up slice.

import 'package:flutter/foundation.dart';

/// Two `feature_flags.kind` values the launch admin UX recognises.
/// `destructive` flags surface a DANGER chip and force a
/// confirm-by-typing dialog. The DB CHECK constraint pins these same
/// two values so client + server stay in sync.
const String kFeatureFlagKindStandard = 'standard';
const String kFeatureFlagKindDestructive = 'destructive';
const Set<String> kFeatureFlagKinds = <String>{
  kFeatureFlagKindStandard,
  kFeatureFlagKindDestructive,
};

/// One `feature_flags` row projected for the admin grid.
@immutable
class FeatureFlagAdminRow {
  const FeatureFlagAdminRow({
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

  /// Actor of the last toggle. Plain string (UUID for users,
  /// `sp:<id>` for service principals, null for unattributed seed
  /// rows that pre-date the 11A.7 admin UX).
  final String? updatedBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isDestructive => kind == kFeatureFlagKindDestructive;

  /// Logical scope label rendered in the grid: `global`, `operator`,
  /// or `location`. Derived from the `(operator_id, location_id)`
  /// combination; matches the partial-unique-index shape.
  String get scopeLabel {
    if (operatorId == null && locationId == null) return 'global';
    if (locationId == null) return 'operator';
    return 'location';
  }

  static FeatureFlagAdminRow fromJson(Map<String, Object?> json) {
    return FeatureFlagAdminRow(
      flagId: json['flag_id']! as String,
      flagName: json['flag_name']! as String,
      operatorId: json['operator_id'] as String?,
      locationId: json['location_id'] as String?,
      enabled: (json['enabled'] as bool?) ?? false,
      kind: (json['kind'] as String?) ?? kFeatureFlagKindStandard,
      description: json['description'] as String?,
      updatedBy: json['updated_by'] as String?,
      createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
      updatedAt: DateTime.parse(json['updated_at']! as String).toUtc(),
    );
  }

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

/// Toggle command for `POST /v1/admin/feature-flags/toggle`. The proxy
/// derives the new value from `enabled`; the screen reads the prior
/// value and sends the inverted bit so the server still validates
/// against the persisted row.
@immutable
class FeatureFlagToggleCommand {
  const FeatureFlagToggleCommand({
    required this.flagId,
    required this.enabled,
    required this.idempotencyKey,
  });

  final String flagId;
  final bool enabled;

  /// Per-toggle idempotency key. The proxy stores it on
  /// `proxy_requests` (UNIQUE) so a retried POST collapses to one
  /// toggle and one audit row, not two.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'flag_id': flagId,
    'enabled': enabled,
  };
}
