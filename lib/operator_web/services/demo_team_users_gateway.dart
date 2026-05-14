// Phase 11W.1 - Operator Web team-users demo gateway.
//
// In-memory implementation of [WebTeamUsersGateway] that the
// operator-web shell binds when `OPERATOR_WEB_DEMO_AUTH=true`. Reads
// the shared fixture set at [demo_team_fixtures.dart] so the demo
// walkthroughs across `/members`, `/roles`, `/locations`,
// `/sessions`, `/audit-log`, `/security` see consistent data.
//
// Mutations made during a walkthrough (suspend, reactivate, soft-
// delete, invite) are stored on this instance only - page reload
// resets to the fixture defaults (the shell tears the instance down
// on sign-out / refresh). That keeps the walkthrough reproducible
// across runs without persisting fixture drift.
//
// Idempotency: replays of the same `idempotencyKey` against an
// already-applied mutation surface the original response, mirroring
// the proxy's `proxy_requests` UNIQUE-key replay semantics so the
// demo behaviour matches the live gateway.

import 'dart:async';

import '../../services/auth/auth_operations_gateway.dart';
import 'demo_team_fixtures.dart';
import 'web_team_users_gateway.dart';

/// In-memory demo gateway. Constructs from the shared fixture set
/// declared in [demo_team_fixtures.dart].
class DemoWebTeamUsersGateway implements WebTeamUsersGateway {
  DemoWebTeamUsersGateway() {
    for (final fixture in kDemoTeamUsersFixture) {
      _users[fixture.userId] = teamUserEntryFromFixture(fixture);
    }
    for (final fixture in kDemoTeamInvitesFixture) {
      _invites[fixture.inviteId] = teamInviteEntryFromFixture(fixture);
    }
  }

  final Map<String, TeamUserListEntry> _users = <String, TeamUserListEntry>{};
  final Map<String, TeamInviteListEntry> _invites =
      <String, TeamInviteListEntry>{};

  /// Cached responses keyed by the screen-minted idempotency key, so
  /// a re-submission of the same action returns the original outcome
  /// rather than mutating again.
  final Map<String, _CachedMutation> _idempotency =
      <String, _CachedMutation>{};

  /// Counter for synthesising stable demo invite ids when the
  /// walkthrough creates more than one invite in a session.
  int _nextInviteSeq = 100;

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    final entries = _users.values.toList(growable: false);
    entries.sort((a, b) {
      final left = a.lastActiveAt;
      final right = b.lastActiveAt;
      if (left == null && right == null) {
        return a.email.toLowerCase().compareTo(b.email.toLowerCase());
      }
      if (left == null) return 1;
      if (right == null) return -1;
      final cmp = right.compareTo(left);
      if (cmp != 0) return cmp;
      return a.email.toLowerCase().compareTo(b.email.toLowerCase());
    });
    return TeamUsersListed(users: List<TeamUserListEntry>.unmodifiable(entries));
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) async {
    final entries = _invites.values.toList(growable: false);
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return TeamInvitesListed(
      invites: List<TeamInviteListEntry>.unmodifiable(entries),
    );
  }

  @override
  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedInviteCreated) return cached.created;
    final inviteId = 'demo-invite-seq-${_nextInviteSeq++}';
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(const Duration(days: 7));
    final entry = TeamInviteListEntry(
      inviteId: inviteId,
      email: command.email,
      roleId: command.roleId,
      roleLabel: _roleLabel(command.roleId),
      scopeType: command.scopeType,
      locationId: command.targetLocationId,
      locationLabel: command.targetLocationId == null
          ? null
          : _locationLabel(command.targetLocationId!),
      orgUnitId: command.targetOrgUnitId,
      expiresAt: expiresAt,
      createdAt: now,
    );
    _invites[inviteId] = entry;
    final created = TeamInviteCreated(inviteId: inviteId, expiresAt: expiresAt);
    _idempotency[idempotencyKey] = _CachedInviteCreated(created);
    return created;
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(
    TeamInviteRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedInviteRevoked) return cached.revoked;
    final removed = _invites.remove(command.inviteId);
    final result = TeamInviteRevoked(revoked: removed != null);
    _idempotency[idempotencyKey] = _CachedInviteRevoked(result);
    return result;
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  }) {
    return _updateStatus(command, 'suspended', idempotencyKey);
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  }) {
    return _updateStatus(command, 'active', idempotencyKey);
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  }) {
    return _updateStatus(command, 'soft_deleted', idempotencyKey);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedPasswordReset) return cached.queued;
    const result = TeamPasswordResetQueued();
    _idempotency[idempotencyKey] = const _CachedPasswordReset(result);
    return result;
  }

  @override
  Future<TeamMfaResetQueued> requestMfaReset(
    TeamMfaResetCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedMfaReset) return cached.queued;
    final executeAfter =
        DateTime.now().toUtc().add(const Duration(hours: 24));
    final result = TeamMfaResetQueued(
      requestedCount: 1,
      requestIds: const <String>['demo-mfa-removal-1'],
      executeAfter: executeAfter,
    );
    _idempotency[idempotencyKey] = _CachedMfaReset(result);
    return result;
  }

  @override
  Future<TeamUserProfilePatched> editMember(
    TeamUserProfilePatchCommand command, {
    required String idempotencyKey,
  }) async {
    // Wave 2 W-1 — Members edit-user write path. Demo gateway updates
    // the in-memory `_users` map so the walkthrough can demonstrate
    // the change end-to-end without a backend. Mirrors the live
    // proxy's idempotency replay so re-submitting the same key
    // returns the original patched user.
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedProfilePatched) return cached.patched;
    final existing = _users[command.targetUserId];
    if (existing == null) {
      throw const WebTeamUsersError(
        code: 'user_not_found',
        message: 'team user was not found for this operator',
        statusCode: 404,
      );
    }
    final nextDisplayName = command.displayName?.trim();
    final nextEmail = command.email?.trim();
    if ((nextDisplayName == null || nextDisplayName.isEmpty) &&
        (nextEmail == null || nextEmail.isEmpty)) {
      throw const WebTeamUsersError(
        code: 'no_profile_fields',
        message: 'at least one of display_name or email is required',
        statusCode: 400,
      );
    }
    final updated = TeamUserListEntry(
      userId: existing.userId,
      email: (nextEmail != null && nextEmail.isNotEmpty)
          ? nextEmail
          : existing.email,
      displayName: (nextDisplayName != null && nextDisplayName.isNotEmpty)
          ? nextDisplayName
          : existing.displayName,
      roleId: existing.roleId,
      roleLabel: existing.roleLabel,
      status: existing.status,
      locationId: existing.locationId,
      locationLabel: existing.locationLabel,
      mfaEnrolled: existing.mfaEnrolled,
      mfaRemovalPending: existing.mfaRemovalPending,
      mfaRemovalRequestId: existing.mfaRemovalRequestId,
      userRoleId: existing.userRoleId,
      lastActiveAt: existing.lastActiveAt,
      grants: existing.grants,
    );
    _users[command.targetUserId] = updated;
    final result = TeamUserProfilePatched(user: updated);
    _idempotency[idempotencyKey] = _CachedProfilePatched(result);
    return result;
  }

  Future<TeamUserStatusUpdated> _updateStatus(
    TeamUserStatusCommand command,
    String nextStatus,
    String idempotencyKey,
  ) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedStatusUpdate) return cached.updated;
    final existing = _users[command.targetUserId];
    if (existing == null) {
      const result = TeamUserStatusUpdated(updated: false);
      _idempotency[idempotencyKey] = const _CachedStatusUpdate(result);
      return result;
    }
    _users[command.targetUserId] = TeamUserListEntry(
      userId: existing.userId,
      email: existing.email,
      displayName: existing.displayName,
      roleId: existing.roleId,
      roleLabel: existing.roleLabel,
      status: nextStatus,
      locationId: existing.locationId,
      locationLabel: existing.locationLabel,
      mfaEnrolled: existing.mfaEnrolled,
      mfaRemovalPending: existing.mfaRemovalPending,
      mfaRemovalRequestId: existing.mfaRemovalRequestId,
      userRoleId: existing.userRoleId,
      lastActiveAt: existing.lastActiveAt,
      grants: existing.grants,
    );
    const result = TeamUserStatusUpdated(updated: true);
    _idempotency[idempotencyKey] = const _CachedStatusUpdate(result);
    return result;
  }

  String _roleLabel(String roleId) {
    for (final role in kDemoTeamRolesFixture) {
      if (role.roleId == roleId) return role.displayName;
    }
    return roleId;
  }

  String? _locationLabel(String locationId) {
    for (final location in kDemoTeamLocationsFixture) {
      if (location.locationId == locationId) return location.name;
    }
    return null;
  }
}

abstract class _CachedMutation {
  const _CachedMutation();
}

class _CachedInviteCreated extends _CachedMutation {
  const _CachedInviteCreated(this.created);
  final TeamInviteCreated created;
}

class _CachedInviteRevoked extends _CachedMutation {
  const _CachedInviteRevoked(this.revoked);
  final TeamInviteRevoked revoked;
}

class _CachedStatusUpdate extends _CachedMutation {
  const _CachedStatusUpdate(this.updated);
  final TeamUserStatusUpdated updated;
}

class _CachedPasswordReset extends _CachedMutation {
  const _CachedPasswordReset(this.queued);
  final TeamPasswordResetQueued queued;
}

class _CachedMfaReset extends _CachedMutation {
  const _CachedMfaReset(this.queued);
  final TeamMfaResetQueued queued;
}

class _CachedProfilePatched extends _CachedMutation {
  const _CachedProfilePatched(this.patched);
  final TeamUserProfilePatched patched;
}
