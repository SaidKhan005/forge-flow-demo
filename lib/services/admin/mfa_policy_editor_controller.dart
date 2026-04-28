// Phase 9.9 - MFA enforcement policy editor.
//
// Pure logic backing the per-tier defaults + per-operator override
// surface. The locked decision is:
//
//   * Admin tier (super_admin / ff_support / operator_owner /
//     operator_manager) requires MFA at every subscription tier.
//   * Staff tier does not have mandatory MFA by subscription tier.
//     Operators may still opt their own staff into MFA.
//
// The editor lets a super_admin (the only role allowed to change
// the per-tier defaults) flip the per-operator override for staff
// MFA. The defaults themselves are immutable from the UI — the
// decision lock is the source of truth. Changing the defaults
// requires a code change + migration.

import '../../auth/mfa_policy.dart';

class MfaPolicyEditorState {
  MfaPolicyEditorState({
    required Map<String, bool> staffOverrideByOperatorId,
  }) : _baseline = Map<String, bool>.unmodifiable(staffOverrideByOperatorId),
       _current = Map<String, bool>.from(staffOverrideByOperatorId);

  final Map<String, bool> _baseline;
  final Map<String, bool> _current;

  /// Returns the current effective MFA-required-for-staff value for
  /// [operatorId] given the operator's [tier]:
  ///
  ///   * All tiers: default false for staff; per-operator override may
  ///     flip it true when an operator voluntarily requires staff MFA.
  bool effectiveStaffMfaRequired({
    required String operatorId,
    required OperatorSubscriptionTier tier,
  }) {
    return _current[operatorId] ?? false;
  }

  /// Sets the per-operator staff MFA override.
  void setStaffOverride({
    required String operatorId,
    required bool requireStaffMfa,
  }) {
    _current[operatorId] = requireStaffMfa;
  }

  void clearStaffOverride(String operatorId) {
    _current.remove(operatorId);
  }

  bool get isDirty {
    if (_current.length != _baseline.length) return true;
    for (final entry in _current.entries) {
      if (_baseline[entry.key] != entry.value) return true;
    }
    return false;
  }

  /// Diff vs the baseline as a map of operator_id → before/after.
  Map<String, MfaOverrideChange> diff() {
    final out = <String, MfaOverrideChange>{};
    final keys = <String>{..._baseline.keys, ..._current.keys};
    for (final key in keys) {
      final from = _baseline[key];
      final to = _current[key];
      if (from != to) {
        out[key] = MfaOverrideChange(from: from ?? false, to: to ?? false);
      }
    }
    return out;
  }

  /// Diff payload the proxy persists on the
  /// `role_audit_log.change_payload` (or a future
  /// `mfa_policy_audit` table) when the editor saves.
  Map<String, Object?> diffPayload() {
    final changes = diff();
    final entries = <Map<String, Object?>>[];
    final ordered = changes.keys.toList()..sort();
    for (final operatorId in ordered) {
      final c = changes[operatorId]!;
      entries.add(<String, Object?>{
        'operator_id': operatorId,
        'from': c.from,
        'to': c.to,
      });
    }
    return <String, Object?>{
      'change_count': changes.length,
      'changes': entries,
    };
  }
}

class MfaOverrideChange {
  const MfaOverrideChange({required this.from, required this.to});
  final bool from;
  final bool to;
}

abstract class MfaPolicyEditorPolicy {
  MfaPolicyEditorPolicy._();

  /// Returns true iff [actorRoles] include `super_admin`. Editing
  /// the MFA enforcement policy is super_admin only per the plan.
  static bool actorMayEdit(Iterable<String> actorRoles) {
    for (final role in actorRoles) {
      if (role.trim().toLowerCase() == 'super_admin') return true;
    }
    return false;
  }
}
