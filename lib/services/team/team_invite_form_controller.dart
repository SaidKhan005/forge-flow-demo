// Phase 9.10 - Team Invite form controller.
//
// Pure-logic state holder for the invite form. Holds:
//
//   * email — RFC-5322 lite validation (non-empty + contains '@'.
//     Server re-validates).
//   * roleId — the role being granted.
//   * scopeType — `operator_wide`, `org_unit`, or `location` (per
//     9.0a's `user_roles.scope_type` column + 9.UX.4's hierarchy
//     wiring migration).
//   * locationId — required when scopeType = `location`.
//   * orgUnitId — required when scopeType = `org_unit`.
//
// `validate()` returns the violation set. Empty = ready to submit.

import 'package:flutter/foundation.dart';

enum TeamInviteScope { operatorWide, orgUnit, location }

extension TeamInviteScopeKey on TeamInviteScope {
  /// SQL value matching the 9.0a + 9.UX.4 CHECK constraint.
  String get sqlKey {
    switch (this) {
      case TeamInviteScope.operatorWide:
        return 'operator_wide';
      case TeamInviteScope.orgUnit:
        return 'org_unit';
      case TeamInviteScope.location:
        return 'location';
    }
  }
}

enum TeamInviteViolation {
  emailMissing,
  emailMalformed,
  roleMissing,
  scopeMissing,
  locationMissingForLocationScope,
  orgUnitMissingForOrgUnitScope,
  locationProvidedButOperatorWide,
}

class TeamInviteFormController extends ChangeNotifier {
  TeamInviteFormController();

  String _email = '';
  String? _roleId;
  TeamInviteScope? _scope;
  String? _locationId;
  String? _orgUnitId;

  String get email => _email;
  String? get roleId => _roleId;
  TeamInviteScope? get scope => _scope;
  String? get locationId => _locationId;
  String? get orgUnitId => _orgUnitId;

  void setEmail(String value) {
    if (_email == value) return;
    _email = value;
    notifyListeners();
  }

  void setRoleId(String? value) {
    if (_roleId == value) return;
    _roleId = value;
    notifyListeners();
  }

  void setScope(TeamInviteScope? value) {
    if (_scope == value) return;
    _scope = value;
    if (value == TeamInviteScope.operatorWide) {
      // Switching to operator-wide clears any selected location or
      // org unit so the payload never carries a stale id.
      _locationId = null;
      _orgUnitId = null;
    } else if (value == TeamInviteScope.location) {
      _orgUnitId = null;
    } else if (value == TeamInviteScope.orgUnit) {
      _locationId = null;
    }
    notifyListeners();
  }

  void setLocationId(String? value) {
    if (_locationId == value) return;
    _locationId = value;
    notifyListeners();
  }

  void setOrgUnitId(String? value) {
    if (_orgUnitId == value) return;
    _orgUnitId = value;
    notifyListeners();
  }

  void reset() {
    _email = '';
    _roleId = null;
    _scope = null;
    _locationId = null;
    _orgUnitId = null;
    notifyListeners();
  }

  Set<TeamInviteViolation> validate() {
    final violations = <TeamInviteViolation>{};
    final trimmed = _email.trim();
    if (trimmed.isEmpty) {
      violations.add(TeamInviteViolation.emailMissing);
    } else if (!_looksLikeEmail(trimmed)) {
      violations.add(TeamInviteViolation.emailMalformed);
    }
    if (_roleId == null || _roleId!.isEmpty) {
      violations.add(TeamInviteViolation.roleMissing);
    }
    if (_scope == null) {
      violations.add(TeamInviteViolation.scopeMissing);
    } else if (_scope == TeamInviteScope.location &&
        (_locationId == null || _locationId!.isEmpty)) {
      violations.add(TeamInviteViolation.locationMissingForLocationScope);
    } else if (_scope == TeamInviteScope.orgUnit &&
        (_orgUnitId == null || _orgUnitId!.isEmpty)) {
      violations.add(TeamInviteViolation.orgUnitMissingForOrgUnitScope);
    } else if (_scope == TeamInviteScope.operatorWide &&
        (_locationId != null || _orgUnitId != null)) {
      violations.add(TeamInviteViolation.locationProvidedButOperatorWide);
    }
    return violations;
  }

  bool get isReadyToSubmit => validate().isEmpty;

  /// Snapshot the form into a payload the proxy invite endpoint
  /// understands. Caller must verify [validate] is empty first.
  Map<String, Object?> toRequestPayload() {
    if (!isReadyToSubmit) {
      throw StateError('TeamInviteFormController is not ready to submit');
    }
    return <String, Object?>{
      'email': _email.trim(),
      'role_id': _roleId,
      'scope_type': _scope!.sqlKey,
      if (_scope == TeamInviteScope.location && _locationId != null)
        'location_id': _locationId,
      if (_scope == TeamInviteScope.orgUnit && _orgUnitId != null)
        'org_unit_id': _orgUnitId,
    };
  }

  static bool _looksLikeEmail(String value) {
    final atIndex = value.indexOf('@');
    if (atIndex <= 0) return false;
    if (atIndex == value.length - 1) return false;
    if (value.contains(' ')) return false;
    return true;
  }
}
