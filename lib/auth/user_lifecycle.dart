// Phase 9.8 - User lifecycle state machine.
//
// Mirrors the `users.status` CHECK constraint from Phase 9.0:
//   ('invited', 'active', 'suspended', 'dormant_30',
//    'dormant_60', 'dormant_90', 'deleted')
//
// Encodes the legal transitions per the plan + decision lock:
//
//                ┌──────────┐
//                │ invited  │   created via invite (auth_invites)
//                └────┬─────┘
//                     ▼ accept
//                ┌──────────┐
//                │ active   │   normal traffic
//                └────┬─────┘
//                     │
//        ┌────────────┼────────────┐
//        ▼            ▼            ▼
//   ┌──────────┐ ┌──────────┐ ┌──────────┐
//   │ suspend  │ │ dormant_*│ │ deleted  │
//   └─────┬────┘ └────┬─────┘ └──────────┘
//         │           │
//         └────►──────┴────► reactivate (back to active)
//
// dormancy advance: 30d skip-precompute → 60d re-auth → 90d
// suspend (HP). The advance + recover paths flow through this
// state machine so the audit row carries the canonical reason.
//
// `deleted` is an absorbing state: GDPR erasure happens after
// soft-delete (a user must be deleted before PII can be redacted)
// and never transitions back. `legal-hold release → hard delete`
// lives outside this state machine and is invoked manually.

enum UserStatus {
  invited,
  active,
  suspended,
  dormant30,
  dormant60,
  dormant90,
  deleted;

  static UserStatus? fromKey(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    switch (normalized) {
      case 'invited':
        return UserStatus.invited;
      case 'active':
        return UserStatus.active;
      case 'suspended':
        return UserStatus.suspended;
      case 'dormant_30':
        return UserStatus.dormant30;
      case 'dormant_60':
        return UserStatus.dormant60;
      case 'dormant_90':
        return UserStatus.dormant90;
      case 'deleted':
        return UserStatus.deleted;
      default:
        return null;
    }
  }

  String toSchemaKey() {
    switch (this) {
      case UserStatus.invited:
        return 'invited';
      case UserStatus.active:
        return 'active';
      case UserStatus.suspended:
        return 'suspended';
      case UserStatus.dormant30:
        return 'dormant_30';
      case UserStatus.dormant60:
        return 'dormant_60';
      case UserStatus.dormant90:
        return 'dormant_90';
      case UserStatus.deleted:
        return 'deleted';
    }
  }
}

enum UserLifecycleAction {
  acceptInvite,
  suspend,
  reactivate,
  advanceDormancy30,
  advanceDormancy60,
  advanceDormancy90,
  recoverFromDormancy,
  softDelete,
}

class UserLifecycleTransition {
  const UserLifecycleTransition({
    required this.from,
    required this.to,
    required this.via,
  });

  final UserStatus from;
  final UserStatus to;
  final UserLifecycleAction via;
}

class UserLifecycleError implements Exception {
  UserLifecycleError(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class UserLifecycleStateMachine {
  UserLifecycleStateMachine._();

  /// Computes the next status for [from] given [action]. Throws
  /// [UserLifecycleError] when the action is not legal from the
  /// current state. Used by the proxy to refuse out-of-order
  /// transitions before any DB write happens.
  static UserLifecycleTransition apply({
    required UserStatus from,
    required UserLifecycleAction action,
  }) {
    final to = _transitionTable[_TransitionKey(from, action)];
    if (to == null) {
      throw UserLifecycleError(
        'illegal user-lifecycle transition: $action from $from',
      );
    }
    return UserLifecycleTransition(from: from, to: to, via: action);
  }

  /// Returns true iff [action] is legal from [from].
  static bool canApply({
    required UserStatus from,
    required UserLifecycleAction action,
  }) {
    return _transitionTable.containsKey(_TransitionKey(from, action));
  }

  static final Map<_TransitionKey, UserStatus> _transitionTable = {
    _TransitionKey(UserStatus.invited, UserLifecycleAction.acceptInvite):
        UserStatus.active,
    _TransitionKey(UserStatus.active, UserLifecycleAction.suspend):
        UserStatus.suspended,
    _TransitionKey(UserStatus.suspended, UserLifecycleAction.reactivate):
        UserStatus.active,
    _TransitionKey(UserStatus.active, UserLifecycleAction.advanceDormancy30):
        UserStatus.dormant30,
    _TransitionKey(UserStatus.dormant30, UserLifecycleAction.advanceDormancy60):
        UserStatus.dormant60,
    _TransitionKey(UserStatus.dormant60, UserLifecycleAction.advanceDormancy90):
        UserStatus.dormant90,
    // dormancy recovery — any dormant tier can come back to active.
    _TransitionKey(UserStatus.dormant30, UserLifecycleAction.recoverFromDormancy):
        UserStatus.active,
    _TransitionKey(UserStatus.dormant60, UserLifecycleAction.recoverFromDormancy):
        UserStatus.active,
    _TransitionKey(UserStatus.dormant90, UserLifecycleAction.recoverFromDormancy):
        UserStatus.active,
    // dormant_90 transitions to suspended via the locked HP rule;
    // the suspend action is the same as for active.
    _TransitionKey(UserStatus.dormant90, UserLifecycleAction.suspend):
        UserStatus.suspended,
    // soft-delete from any non-deleted state (admin path).
    _TransitionKey(UserStatus.invited, UserLifecycleAction.softDelete):
        UserStatus.deleted,
    _TransitionKey(UserStatus.active, UserLifecycleAction.softDelete):
        UserStatus.deleted,
    _TransitionKey(UserStatus.suspended, UserLifecycleAction.softDelete):
        UserStatus.deleted,
    _TransitionKey(UserStatus.dormant30, UserLifecycleAction.softDelete):
        UserStatus.deleted,
    _TransitionKey(UserStatus.dormant60, UserLifecycleAction.softDelete):
        UserStatus.deleted,
    _TransitionKey(UserStatus.dormant90, UserLifecycleAction.softDelete):
        UserStatus.deleted,
  };
}

class _TransitionKey {
  const _TransitionKey(this.from, this.action);
  final UserStatus from;
  final UserLifecycleAction action;

  @override
  bool operator ==(Object other) =>
      other is _TransitionKey &&
      other.from == from &&
      other.action == action;

  @override
  int get hashCode => Object.hash(from, action);
}
