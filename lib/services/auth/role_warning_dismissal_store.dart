// Wave 2 Q-4 follow-up - persistent "Don't show this warning again
// for this role" store for the Custom Role editor.
//
// The validator at `lib/services/auth/custom_role_validator.dart`
// emits a deterministic list of advisory `RoleWarning`s per
// (selection, scope, role display name). When the operator dismisses
// a warning the editor needs to remember that decision so the
// warning does not reappear next time they open the same role.
//
// Persistence shape:
//   * Each dismissal is keyed by (roleId, warningCode,
//     affectedKeysFingerprint). The fingerprint is the
//     comma-separated, sorted affectedKeys list so a warning whose
//     affectedKeys change (different missing-view pair, different
//     org-wide key, etc.) re-appears.
//   * `roleId == null` is allowed for brand-new roles - dismissals
//     persist under a synthetic `new_role::<displayName>` namespace
//     so the warning stays gone while the operator edits the same
//     unsaved role. Once the role is saved the editor migrates the
//     dismissals to the real role id (best-effort - missing migration
//     just means the operator will see the warning once more).
//
// Implementations:
//   * [MemoryRoleWarningDismissalStore] - in-memory map. Used by
//     tests + as a safe fallback when persistent storage is not
//     available (eg. headless / SSR contexts).
//   * [SharedPreferencesRoleWarningDismissalStore] - wraps
//     `package:shared_preferences/shared_preferences.dart`. Lives at
//     `lib/services/auth/role_warning_dismissal_store_prefs.dart` so
//     this file stays pure-Dart and easy to unit-test without a
//     Flutter binding.

import 'custom_role_validator.dart';

/// Persistent store for warning dismissals on a per-role basis.
///
/// All implementations must be safe to call from the UI thread; the
/// editor reads `isDismissed` synchronously while rendering each
/// `RoleWarning`. `dismiss` may complete asynchronously (durable
/// writes to disk) but the snapshot is updated in-memory first so
/// the next `isDismissed` read after `dismiss` reflects the change.
abstract class RoleWarningDismissalStore {
  /// True iff the operator previously dismissed the given
  /// [warning] for [roleId]. `roleId == null` falls back to the
  /// synthetic new-role namespace described in the module header.
  bool isDismissed({
    required String? roleId,
    required RoleWarning warning,
  });

  /// Record [warning] as dismissed for [roleId]. The next call to
  /// [isDismissed] with the same key returns `true`.
  ///
  /// Returns a future that completes when the dismissal is durably
  /// persisted. The in-memory snapshot is updated synchronously
  /// regardless.
  Future<void> dismiss({
    required String? roleId,
    required RoleWarning warning,
  });

  /// Remove all dismissals for [roleId]. Used after the editor saves
  /// a brand-new role to migrate any synthetic-namespace dismissals
  /// to the real role id - and as a "reset" affordance the editor
  /// can wire up later if needed.
  Future<void> clearForRole(String roleId);
}

/// In-memory implementation. Persistence lasts for the lifetime of
/// the process - durable enough for the Flutter Web operator console
/// session, and the default test fixture.
class MemoryRoleWarningDismissalStore implements RoleWarningDismissalStore {
  MemoryRoleWarningDismissalStore();

  final Map<String, Set<String>> _dismissedByRole = <String, Set<String>>{};

  @override
  bool isDismissed({
    required String? roleId,
    required RoleWarning warning,
  }) {
    final scope = _scopeKey(roleId);
    final dismissed = _dismissedByRole[scope];
    if (dismissed == null) return false;
    return dismissed.contains(buildWarningFingerprint(warning));
  }

  @override
  Future<void> dismiss({
    required String? roleId,
    required RoleWarning warning,
  }) async {
    final scope = _scopeKey(roleId);
    _dismissedByRole
        .putIfAbsent(scope, () => <String>{})
        .add(buildWarningFingerprint(warning));
  }

  @override
  Future<void> clearForRole(String roleId) async {
    _dismissedByRole.remove(roleId);
  }

  String _scopeKey(String? roleId) => roleId ?? _kNewRoleScopeKey;

  /// Test-only snapshot of the dismissed fingerprints for [roleId].
  /// Returns an empty unmodifiable set when nothing is dismissed.
  Set<String> debugFingerprintsFor(String? roleId) {
    final dismissed = _dismissedByRole[_scopeKey(roleId)];
    if (dismissed == null) return const <String>{};
    return Set<String>.unmodifiable(dismissed);
  }
}

/// Stable namespace used for dismissals against a brand-new role that
/// has not been saved yet. Surfaced as a constant so the prefs-backed
/// implementation can mirror the same scoping rule.
const String _kNewRoleScopeKey = '__new_role__';

/// Build the deterministic fingerprint a [RoleWarningDismissalStore]
/// keys dismissals by. Public so the prefs-backed implementation can
/// share the same hashing rule. The fingerprint shape is:
///
///   `<warningCode>::<comma-joined,sorted,affectedKeys>`
///
/// `affectedKeys` is sorted so two warnings with the same key set
/// produced in different iteration orders collapse to the same
/// fingerprint. Two warnings of the same code but different affected
/// keys (eg. orphan implies on a different pair) get different
/// fingerprints so dismissing one does not silence the other.
String buildWarningFingerprint(RoleWarning warning) {
  final keys = List<String>.from(warning.affectedKeys)..sort();
  return '${warning.code.name}::${keys.join(',')}';
}
