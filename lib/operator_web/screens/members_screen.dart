// Phase 11W.1 - Operator Web Members screen.
//
// Web parity for the mobile Settings -> Team list. Mounted at the
// `/members` route in the operator-web shell. Renders the operator's
// team membership with the locked filter set + cursor-friendly
// pagination + row actions documented in the Team / Roles / Hierarchy
// / Sessions / Audit / Security console parity contract § Members +
// Invites (`11W.1` + `11A.12`):
//
//   * Filter set (locked):
//       status        ∈ {active, suspended, dormant_30, soft_deleted}
//       role_key      ∈ catalog (rendered as role display label)
//       location_id   ∈ visible locations per
//                       team_scope_visibility_policy
//       mfa_enrolled  ∈ {true, false, null}
//       search        free-text on email + display_name
//
//   * Pagination: 50 rows per page; sort
//       last_active_at DESC, email ASC.
//
//   * Row actions: Suspend, Reactivate, Soft delete,
//                  Reset password, Reset MFA.
//                  Soft-deleted rows show no Restore action on the
//                  operator self-service surface; restore lives on
//                  the F&F admin path (Phase 11A.12).
//                  Force sign-out is deferred to Phase 11W.4
//                  Sessions, which owns the session-revocation path
//                  (`team.session.force_logout` writes through
//                  `/v1/auth/session/revoke`, not the team-
//                  users surface). Suspend already cuts the user's
//                  ability to sign in; Force sign-out is the
//                  separate "end every active session right now"
//                  pathway whose audit-row shape belongs to the
//                  Sessions slice.
//
// Permission gates mirror the proxy server-side gate. The screen
// prefers the live `OperatorWebSession.permissions` snapshot
// (hydrated from `/v1/auth/permissions/snapshot`) when present; it
// falls back to a role-tier set so the demo flavor and the
// pre-snapshot bootstrap stage of live mode still render.
//
// Wiring honesty: the screen reads + writes through
// [WebTeamUsersGateway] which the router binds to either the
// `package:http` live impl or the in-memory demo impl. No dart:io,
// no sqflite, no parallel HTTP stack.

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../../services/team/team_users_list_controller.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/demo_team_fixtures.dart';
import '../services/web_team_users_gateway.dart';
import '../../theme/app_theme.dart';
import 'edit_member_dialog.dart';
import 'invite_member_dialog.dart';

/// Roles admitted to the Members surface when the proxy permission
/// snapshot is not yet hydrated (demo flavor + bootstrap). The
/// authoritative gate is the `team.users.view` permission key per
/// the parity contract § Permission gate cheat sheet; this role set
/// is the friendly fallback so the screen renders something useful
/// before the live snapshot lands.
const Set<String> kOperatorWebMembersAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
  'operator_manager',
  'location_manager',
};

/// Role-tier fallback for the destructive row actions. Authoritative
/// gate is the `team.users.*` permission key set; this set kicks in
/// only when `OperatorWebSession.permissions` is empty (demo + boot).
const Set<String> kOperatorWebMembersWriteRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Permission-key bound for the Members read surface. Live source
/// hydrates from `/v1/auth/permissions/snapshot`. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kMembersViewPermissionKey = PermissionKeys.teamUsersView;

/// Permission-key bound for the Invite member action. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kMembersInvitePermissionKey = PermissionKeys.teamUsersInvite;

/// Permission-key bound for the Suspend / Reactivate / Soft delete
/// status mutations. The contract gates each independently, but
/// surfacing one row-action menu requires at least one of them. Each
/// member is aliased to the frozen catalog constant in
/// `lib/auth/permission_keys.dart`.
const Set<String> kMembersStatusMutationKeys = <String>{
  PermissionKeys.teamUsersDeactivate,
  PermissionKeys.teamUsersReactivate,
  PermissionKeys.teamUsersSoftDelete,
};

/// Permission-key bound for the Reset password action. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kMembersResetPasswordPermissionKey =
    PermissionKeys.teamUsersResetPassword;

/// Permission-key bound for the Reset two-factor sign-in action.
/// Aliased to the frozen catalog constant in
/// `lib/auth/permission_keys.dart`.
const String kMembersResetMfaPermissionKey = PermissionKeys.teamUsersResetMfa;

/// Status filter chip catalog (locked by the parity contract).
class MembersStatusOption {
  const MembersStatusOption({required this.value, required this.label});

  final String value;
  final String label;
}

const List<MembersStatusOption> kMembersStatusOptions = <MembersStatusOption>[
  MembersStatusOption(value: 'active', label: 'Active'),
  MembersStatusOption(value: 'suspended', label: 'Suspended'),
  MembersStatusOption(value: 'dormant_30', label: 'Dormant 30+ days'),
  MembersStatusOption(value: 'soft_deleted', label: 'Removed'),
];

/// Page size locked at 50 rows per the parity contract.
const int kMembersPageSize = 50;

/// Operator Web Members screen.
class MembersScreen extends StatefulWidget {
  const MembersScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.idempotencyKeyFactory,
    this.roleOptions = kDemoTeamRolesFixture,
    this.locationOptions = kDemoTeamLocationsFixture,
  });

  final OperatorWebSession session;
  final WebTeamUsersGateway gateway;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway.
  final String Function()? idempotencyKeyFactory;

  /// Role + location dropdown catalogs. Demo build defaults to the
  /// shared fixture set; live build will pass the operator's own
  /// catalog from `/v1/auth/team/roles` + the hierarchy gateway in
  /// the `11W.1.live` follow-up.
  final List<DemoTeamRoleFixture> roleOptions;
  final List<DemoTeamLocationFixture> locationOptions;

  /// True iff the actor may read the Members surface. Prefers the
  /// proxy-side permission snapshot when present; falls back to the
  /// role-tier set so the demo flavor (no permissions snapshot) and
  /// the live bootstrap stage (snapshot still loading) render
  /// something useful.
  bool get _admitted {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kMembersViewPermissionKey);
    }
    return session.roles.any(kOperatorWebMembersAdmittedRoles.contains);
  }

  /// True iff the actor may create or cancel pending invites. Prefers
  /// the permission snapshot; falls back to the role tier when the
  /// snapshot has not hydrated yet.
  bool get _canManageInvites {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kMembersInvitePermissionKey);
    }
    return session.roles.any(kOperatorWebMembersWriteRoles.contains);
  }

  /// True iff the actor may mutate existing member rows. Prefers the
  /// permission snapshot; falls back to the role tier when the
  /// snapshot has not hydrated yet.
  bool get _canWrite {
    if (session.permissions.isNotEmpty) {
      if (session.permissions.any(kMembersStatusMutationKeys.contains)) {
        return true;
      }
      if (session.permissions.contains(kMembersResetPasswordPermissionKey) ||
          session.permissions.contains(kMembersResetMfaPermissionKey)) {
        return true;
      }
      return false;
    }
    return session.roles.any(kOperatorWebMembersWriteRoles.contains);
  }

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  late final TeamUsersListController _controller;
  late final TextEditingController _searchController;
  List<TeamUserListEntry> _users = const <TeamUserListEntry>[];
  List<TeamInviteListEntry> _invites = const <TeamInviteListEntry>[];
  bool _loading = true;
  String? _loadError;
  final Set<String> _busyUserIds = <String>{};
  final Set<String> _busyInviteIds = <String>{};
  int _loadGeneration = 0;
  int _idempotencySeq = 0;

  @override
  void initState() {
    super.initState();
    _controller = TeamUsersListController(pageSize: kMembersPageSize);
    _controller.addListener(_handleControllerChanged);
    _searchController = TextEditingController();
    _searchController.addListener(_handleSearchChanged);
    _loadAll();
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleSearchChanged() {
    final text = _searchController.text;
    if (text == _controller.filter.searchQuery) return;
    _controller.setSearchQuery(text);
  }

  Future<void> _loadAll() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final command = _listCommand();
      final usersFuture = widget.gateway.listUsers(command);
      final invitesFuture = widget.gateway.listInvites(
        TeamInviteListCommand(
          actorUserId: command.actorUserId,
          operatorId: command.operatorId,
          locationId: command.locationId,
        ),
      );
      final results = await Future.wait<Object>([usersFuture, invitesFuture]);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _users = (results[0] as TeamUsersListed).users;
        _invites = (results[1] as TeamInvitesListed).invites;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  String _friendlyLoadError(Object error) {
    if (error is WebTeamUsersError) {
      return 'Could not load the members list (${error.code}). Refresh the '
          'page or try again in a moment.';
    }
    return 'Could not load the members list. Refresh the page or try again '
        'in a moment.';
  }

  TeamUserListCommand _listCommand() {
    return TeamUserListCommand(
      actorUserId: widget.session.uid,
      operatorId: widget.session.operatorId,
      locationId: widget.session.primaryLocationId ?? '',
    );
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-members-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  List<TeamUserListEntry> get _filteredUsers {
    final filter = _controller.filter;
    final q = filter.searchQuery.trim().toLowerCase();
    final candidates = _users.where((user) {
      if (filter.statusFilter != null && user.status != filter.statusFilter) {
        return false;
      }
      if (filter.roleFilter != null && user.roleId != filter.roleFilter) {
        return false;
      }
      if (filter.locationFilter != null &&
          user.locationId != filter.locationFilter) {
        return false;
      }
      if (filter.mfaEnrolledFilter != null &&
          user.mfaEnrolled != filter.mfaEnrolledFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      return user.email.toLowerCase().contains(q) ||
          user.displayName.toLowerCase().contains(q);
    }).toList();
    // Parity contract § Members + Invites: sort `last_active_at DESC`
    // then `email ASC`. Apply on the screen so the live HTTP impl
    // does not have to depend on proxy-side ordering.
    candidates.sort((a, b) {
      final left = a.lastActiveAt;
      final right = b.lastActiveAt;
      if (left != null && right != null) {
        final cmp = right.compareTo(left);
        if (cmp != 0) return cmp;
      } else if (left == null && right != null) {
        return 1;
      } else if (left != null && right == null) {
        return -1;
      }
      return a.email.toLowerCase().compareTo(b.email.toLowerCase());
    });
    return List<TeamUserListEntry>.unmodifiable(candidates);
  }

  List<TeamUserListEntry> get _pagedUsers {
    final filtered = _filteredUsers;
    final pageStart = _controller.pageIndex * _controller.pageSize;
    if (pageStart >= filtered.length) return const <TeamUserListEntry>[];
    final pageEnd = (pageStart + _controller.pageSize).clamp(
      0,
      filtered.length,
    );
    return filtered.sublist(pageStart, pageEnd);
  }

  Future<void> _openInviteDialog() async {
    final result = await showInviteMemberDialog(
      context: context,
      gateway: widget.gateway,
      listCommand: _listCommand(),
      existingEmails: <String>{
        for (final user in _users) user.email.toLowerCase(),
        for (final invite in _invites) invite.email.toLowerCase(),
      },
      roleOptions: widget.roleOptions,
      locationOptions: widget.locationOptions,
      idempotencyKey: _nextIdempotencyKey(),
    );
    if (result == null || !mounted) return;
    await _loadAll();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Invite sent.')));
  }

  Future<void> _runStatusAction({
    required TeamUserListEntry user,
    required Future<TeamUserStatusUpdated> Function(
      TeamUserStatusCommand command, {
      required String idempotencyKey,
    })
    action,
    required String confirmTitle,
    required String confirmBody,
    required String confirmCta,
    required String reasonCode,
    required String successCopy,
  }) async {
    final confirmed = await _confirm(
      title: confirmTitle,
      body: confirmBody,
      cta: confirmCta,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyUserIds.add(user.userId));
    try {
      await action(
        TeamUserStatusCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          targetUserId: user.userId,
          reason: reasonCode,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successCopy)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyUserIds.remove(user.userId));
      }
    }
  }

  Future<void> _resetPassword(TeamUserListEntry user) async {
    final confirmed = await _confirm(
      title: 'Send password reset email',
      body:
          'Send a password reset email to ${user.email}? They can set a '
          'new password from the link in the email.',
      cta: 'Send email',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyUserIds.add(user.userId));
    try {
      await widget.gateway.requestPasswordReset(
        TeamPasswordResetCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          targetUserId: user.userId,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset email queued.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyUserIds.remove(user.userId));
      }
    }
  }

  Future<void> _resetMfa(TeamUserListEntry user) async {
    final confirmed = await _confirm(
      title: 'Start two-factor removal',
      body:
          'Start removing two-factor sign-in for ${user.email}? It will be '
          'removed in 24 hours for security purposes. Check back after the '
          'security window to confirm it is done.',
      cta: 'Start removal',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyUserIds.add(user.userId));
    try {
      await widget.gateway.requestMfaReset(
        TeamMfaResetCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          targetUserId: user.userId,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Two-factor sign-in removal started. It will be removed in 24 '
            'hours.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyUserIds.remove(user.userId));
      }
    }
  }

  Future<void> _editMember(TeamUserListEntry user) async {
    // Wave 2 W-1 — Members edit-user write path. Open the Edit member
    // dialog with the row's current state pre-filled. The dialog
    // mints idempotency keys for the profile patch + the role-grant
    // rotation so a retried Save replays cleanly.
    final result = await showEditMemberDialog(
      context: context,
      gateway: widget.gateway,
      user: user,
      existingEmails: <String>{
        for (final entry in _users) entry.email.toLowerCase(),
        for (final invite in _invites) invite.email.toLowerCase(),
      },
      roleOptions: widget.roleOptions,
      locationOptions: widget.locationOptions,
      actorUserId: widget.session.uid,
      operatorId: widget.session.operatorId,
      locationId: widget.session.primaryLocationId ?? '',
      profileIdempotencyKey: _nextIdempotencyKey(),
      roleGrantIdempotencyKey: _nextIdempotencyKey(),
    );
    if (result == null || !mounted) return;
    await _loadAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Updated ${result.patched.user.email}.')),
    );
  }

  Future<void> _cancelInvite(TeamInviteListEntry invite) async {
    final confirmed = await _confirm(
      title: 'Cancel invite',
      body:
          'Cancel the pending invite for ${invite.email}? Their link will stop '
          'working. You can send a new invite later if they still need access.',
      cta: 'Cancel invite',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyInviteIds.add(invite.inviteId));
    try {
      await widget.gateway.revokeInvite(
        TeamInviteRevokeCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          inviteId: invite.inviteId,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 10),
          content: Text('Invite cancelled. Send a new invite if needed.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyInviteIds.remove(invite.inviteId));
      }
    }
  }

  String _friendlyMutationError(Object error) {
    if (error is WebTeamUsersError) {
      return 'Action could not be completed (${error.code}). Try again in a '
          'moment, or refresh the page if the problem keeps happening.';
    }
    return 'Action could not be completed. Try again in a moment, or refresh '
        'the page if the problem keeps happening.';
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String cta,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('members_confirm_dialog'),
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            key: const Key('members_confirm_dialog_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('members_confirm_dialog_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(cta),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget._admitted) {
      return const _MembersForbiddenSurface(
        key: Key('operator_web_members_forbidden'),
      );
    }
    if (_loading) {
      return const Center(
        key: Key('operator_web_members_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return Center(
        key: const Key('operator_web_members_load_error'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Members could not load',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('operator_web_members_load_retry'),
                    onPressed: _loadAll,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.sunsetDark,
                      side: const BorderSide(
                        color: AppColors.sunsetDark,
                        width: 1,
                      ),
                    ),
                    child: const Text('Retry'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final filteredCount = _filteredUsers.length;
    return SingleChildScrollView(
      key: const Key('operator_web_members_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MembersHeader(
            canInvite: widget._canManageInvites,
            onInvite: _openInviteDialog,
          ),
          const SizedBox(height: 18),
          _MembersFilterRail(
            controller: _controller,
            searchController: _searchController,
            roleOptions: widget.roleOptions,
            locationOptions: widget.locationOptions,
            statusOptions: kMembersStatusOptions,
          ),
          const SizedBox(height: 14),
          _MembersTable(
            users: _pagedUsers,
            canWrite: widget._canWrite,
            busyUserIds: _busyUserIds,
            onEdit: _editMember,
            onSuspend: (user) => _runStatusAction(
              user: user,
              action: widget.gateway.suspendUser,
              confirmTitle: 'Suspend member',
              confirmBody:
                  'Suspend ${user.email} and block sign-in until you '
                  'reactivate them?',
              confirmCta: 'Suspend',
              reasonCode: 'op_web_members_suspend',
              successCopy: 'Member suspended.',
            ),
            onReactivate: (user) => _runStatusAction(
              user: user,
              action: widget.gateway.reactivateUser,
              confirmTitle: 'Reactivate member',
              confirmBody: 'Restore sign-in for ${user.email}?',
              confirmCta: 'Reactivate',
              reasonCode: 'op_web_members_reactivate',
              successCopy: 'Member reactivated.',
            ),
            onSoftDelete: (user) => _runStatusAction(
              user: user,
              action: widget.gateway.softDeleteUser,
              confirmTitle: 'Remove access',
              confirmBody:
                  'Remove ${user.email} from this team? The account stays '
                  'on record so you can restore it from the F&F support '
                  'console if needed.',
              confirmCta: 'Remove',
              reasonCode: 'op_web_members_soft_delete',
              successCopy: 'Member access removed.',
            ),
            onResetPassword: _resetPassword,
            onResetMfa: _resetMfa,
          ),
          const SizedBox(height: 12),
          _MembersPaginationBar(
            controller: _controller,
            totalRows: filteredCount,
          ),
          if (_invites.isNotEmpty) ...[
            const SizedBox(height: 24),
            _PendingInvitesPanel(
              invites: _invites,
              canCancel: widget._canManageInvites,
              busyInviteIds: _busyInviteIds,
              onCancel: _cancelInvite,
            ),
          ],
        ],
      ),
    );
  }
}

class _MembersHeader extends StatelessWidget {
  const _MembersHeader({required this.canInvite, required this.onInvite});

  final bool canInvite;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.group_outlined,
                    size: 22,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Team members',
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            key: const Key('operator_web_members_invite_button'),
            onPressed: canInvite ? onInvite : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sunset,
              foregroundColor: AppColors.backgroundSurface,
              disabledBackgroundColor: AppColors.borderSubtle,
              disabledForegroundColor: AppColors.textMuted,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              textStyle: AppTextStyles.display16(
                color: AppColors.backgroundSurface,
              ),
            ),
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
            label: const Text('Invite member'),
          ),
        ),
      ],
    );
  }
}

class _MembersFilterRail extends StatelessWidget {
  const _MembersFilterRail({
    required this.controller,
    required this.searchController,
    required this.roleOptions,
    required this.locationOptions,
    required this.statusOptions,
  });

  final TeamUsersListController controller;
  final TextEditingController searchController;
  final List<DemoTeamRoleFixture> roleOptions;
  final List<DemoTeamLocationFixture> locationOptions;
  final List<MembersStatusOption> statusOptions;

  @override
  Widget build(BuildContext context) {
    final filter = controller.filter;
    return Container(
      key: const Key('operator_web_members_filter_rail'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              key: const Key('operator_web_members_filter_search'),
              controller: searchController,
              decoration: const InputDecoration(
                labelText: 'Search by name or email',
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String?>(
              key: const Key('operator_web_members_filter_status'),
              initialValue: filter.statusFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: controller.setStatus,
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Any status'),
                ),
                for (final option in statusOptions)
                  DropdownMenuItem<String?>(
                    value: option.value,
                    child: Text(option.label),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String?>(
              key: const Key('operator_web_members_filter_role'),
              initialValue: filter.roleFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Role',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: controller.setRole,
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Any role'),
                ),
                for (final role in roleOptions)
                  DropdownMenuItem<String?>(
                    value: role.roleId,
                    child: Text(role.displayName),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String?>(
              key: const Key('operator_web_members_filter_location'),
              initialValue: filter.locationFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Location',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: controller.setLocation,
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Any location'),
                ),
                for (final location in locationOptions)
                  DropdownMenuItem<String?>(
                    value: location.locationId,
                    child: Text(location.name),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<bool?>(
              key: const Key('operator_web_members_filter_mfa'),
              initialValue: filter.mfaEnrolledFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Two-factor sign-in',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: controller.setMfaEnrolled,
              items: const <DropdownMenuItem<bool?>>[
                DropdownMenuItem<bool?>(value: null, child: Text('Any')),
                DropdownMenuItem<bool?>(value: true, child: Text('On')),
                DropdownMenuItem<bool?>(value: false, child: Text('Off')),
              ],
            ),
          ),
          if (filter.hasAnyFilter)
            TextButton.icon(
              key: const Key('operator_web_members_filter_clear'),
              onPressed: () {
                searchController.text = '';
                controller.clearFilter();
              },
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Clear filters'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.sunsetDark,
              ),
            ),
        ],
      ),
    );
  }
}

class _MembersTable extends StatelessWidget {
  const _MembersTable({
    required this.users,
    required this.canWrite,
    required this.busyUserIds,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final List<TeamUserListEntry> users;
  final bool canWrite;
  final Set<String> busyUserIds;
  final Future<void> Function(TeamUserListEntry user) onEdit;
  final Future<void> Function(TeamUserListEntry user) onSuspend;
  final Future<void> Function(TeamUserListEntry user) onReactivate;
  final Future<void> Function(TeamUserListEntry user) onSoftDelete;
  final Future<void> Function(TeamUserListEntry user) onResetPassword;
  final Future<void> Function(TeamUserListEntry user) onResetMfa;

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) {
      return Container(
        key: const Key('operator_web_members_empty_state'),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'No members match these filters',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Try clearing a filter or use Invite member to add someone '
              'new to the team.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        return Container(
          key: const Key('operator_web_members_table'),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!compact) const _MembersTableHeader(),
              for (var i = 0; i < users.length; i++) ...[
                if (i > 0 || !compact)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: AppColors.borderSubtle,
                  ),
                if (compact)
                  _MembersCompactCard(
                    user: users[i],
                    canWrite: canWrite,
                    busy: busyUserIds.contains(users[i].userId),
                    onEdit: onEdit,
                    onSuspend: onSuspend,
                    onReactivate: onReactivate,
                    onSoftDelete: onSoftDelete,
                    onResetPassword: onResetPassword,
                    onResetMfa: onResetMfa,
                  )
                else
                  _MembersTableRow(
                    user: users[i],
                    canWrite: canWrite,
                    busy: busyUserIds.contains(users[i].userId),
                    onEdit: onEdit,
                    onSuspend: onSuspend,
                    onReactivate: onReactivate,
                    onSoftDelete: onSoftDelete,
                    onResetPassword: onResetPassword,
                    onResetMfa: onResetMfa,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MembersTableHeader extends StatelessWidget {
  const _MembersTableHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: const BoxDecoration(
        color: AppColors.cardGlow,
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Text(
              'Member',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Role',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Location',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Status',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Two-factor sign-in',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          // OW-6d — Trailing affordance column reservation. Width
          // matches the inline Edit text button + smaller 3-dot
          // overflow footprint introduced by the row affordance
          // change so the header columns stay aligned with the row.
          const SizedBox(width: 112),
        ],
      ),
    );
  }
}

class _MembersTableRow extends StatelessWidget {
  const _MembersTableRow({
    required this.user,
    required this.canWrite,
    required this.busy,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final TeamUserListEntry user;
  final bool canWrite;
  final bool busy;
  final Future<void> Function(TeamUserListEntry user) onEdit;
  final Future<void> Function(TeamUserListEntry user) onSuspend;
  final Future<void> Function(TeamUserListEntry user) onReactivate;
  final Future<void> Function(TeamUserListEntry user) onSoftDelete;
  final Future<void> Function(TeamUserListEntry user) onResetPassword;
  final Future<void> Function(TeamUserListEntry user) onResetMfa;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('operator_web_members_row_${user.userId}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  user.displayName.isEmpty ? user.email : user.displayName,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  user.email,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              user.roleLabel,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              user.locationLabel ?? 'All locations',
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
          Expanded(flex: 2, child: _StatusChip(status: user.status)),
          Expanded(
            flex: 2,
            child: Text(
              user.mfaEnrolled ? 'On' : 'Off',
              style: AppTextStyles.body13(
                color: user.mfaEnrolled
                    ? AppColors.positive
                    : AppColors.textSecondary,
              ),
            ),
          ),
          _MembersRowActionsButton(
            user: user,
            canWrite: canWrite,
            busy: busy,
            onEdit: onEdit,
            onSuspend: onSuspend,
            onReactivate: onReactivate,
            onSoftDelete: onSoftDelete,
            onResetPassword: onResetPassword,
            onResetMfa: onResetMfa,
          ),
        ],
      ),
    );
  }
}

class _MembersCompactCard extends StatelessWidget {
  const _MembersCompactCard({
    required this.user,
    required this.canWrite,
    required this.busy,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final TeamUserListEntry user;
  final bool canWrite;
  final bool busy;
  final Future<void> Function(TeamUserListEntry user) onEdit;
  final Future<void> Function(TeamUserListEntry user) onSuspend;
  final Future<void> Function(TeamUserListEntry user) onReactivate;
  final Future<void> Function(TeamUserListEntry user) onSoftDelete;
  final Future<void> Function(TeamUserListEntry user) onResetPassword;
  final Future<void> Function(TeamUserListEntry user) onResetMfa;

  @override
  Widget build(BuildContext context) {
    final displayName = user.displayName.isEmpty
        ? user.email
        : user.displayName;
    return Container(
      key: Key('operator_web_members_row_${user.userId}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        displayName,
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusChip(status: user.status),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  user.email,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    _MemberMetaChip(
                      icon: Icons.badge_outlined,
                      label: user.roleLabel,
                    ),
                    _MemberMetaChip(
                      icon: Icons.storefront_outlined,
                      label: user.locationLabel ?? 'All locations',
                    ),
                    _MemberMetaChip(
                      icon: Icons.verified_user_outlined,
                      label: user.mfaEnrolled ? 'MFA on' : 'MFA off',
                      color: user.mfaEnrolled
                          ? AppColors.positive
                          : AppColors.textSecondary,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _MembersRowActionsButton(
            user: user,
            canWrite: canWrite,
            busy: busy,
            onEdit: onEdit,
            onSuspend: onSuspend,
            onReactivate: onReactivate,
            onSoftDelete: onSoftDelete,
            onResetPassword: onResetPassword,
            onResetMfa: onResetMfa,
          ),
        ],
      ),
    );
  }
}

class _MemberMetaChip extends StatelessWidget {
  const _MemberMetaChip({
    required this.icon,
    required this.label,
    this.color = AppColors.textSecondary,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.mono10(color: color)),
        ],
      ),
    );
  }
}

class _MembersRowActionsButton extends StatelessWidget {
  const _MembersRowActionsButton({
    required this.user,
    required this.canWrite,
    required this.busy,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final TeamUserListEntry user;
  final bool canWrite;
  final bool busy;
  final Future<void> Function(TeamUserListEntry user) onEdit;
  final Future<void> Function(TeamUserListEntry user) onSuspend;
  final Future<void> Function(TeamUserListEntry user) onReactivate;
  final Future<void> Function(TeamUserListEntry user) onSoftDelete;
  final Future<void> Function(TeamUserListEntry user) onResetPassword;
  final Future<void> Function(TeamUserListEntry user) onResetMfa;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 40,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sunsetDark,
            ),
          ),
        ),
      );
    }
    if (!canWrite || user.status == 'soft_deleted') {
      return const SizedBox.shrink();
    }
    // OW-6d — Row trailing affordance: inline "Edit" text button (the
    // primary edit-user write path per the operator decision) +
    // smaller 3-dot overflow that holds only the destructive actions
    // (Suspend / Reactivate / Reset password / Reset two-factor sign-
    // in / Remove from team). The earlier all-in-one 3-dot menu hid
    // the most-reached-for action behind a click; pulling Edit inline
    // honors the debug.md 156 literal ask while keeping the
    // destructive options discoverable but visually de-emphasized.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextButton.icon(
          key: Key('operator_web_members_row_edit_${user.userId}'),
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('Edit'),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.sunsetDark,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () => onEdit(user),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 32,
          height: 32,
          child: PopupMenuButton<_MembersRowAction>(
            key: Key('operator_web_members_row_actions_${user.userId}'),
            tooltip: 'More actions',
            padding: EdgeInsets.zero,
            iconSize: 18,
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (action) {
              switch (action) {
                case _MembersRowAction.suspend:
                  onSuspend(user);
                case _MembersRowAction.reactivate:
                  onReactivate(user);
                case _MembersRowAction.softDelete:
                  onSoftDelete(user);
                case _MembersRowAction.resetPassword:
                  onResetPassword(user);
                case _MembersRowAction.resetMfa:
                  onResetMfa(user);
              }
            },
            itemBuilder: (context) {
              final isSuspended = user.status == 'suspended';
              final isSoftDeleted = user.status == 'soft_deleted';
              return <PopupMenuEntry<_MembersRowAction>>[
                if (!isSuspended && !isSoftDeleted)
                  const PopupMenuItem<_MembersRowAction>(
                    key: Key('members_row_action_suspend'),
                    value: _MembersRowAction.suspend,
                    child: Text('Suspend'),
                  ),
                if (isSuspended)
                  const PopupMenuItem<_MembersRowAction>(
                    key: Key('members_row_action_reactivate'),
                    value: _MembersRowAction.reactivate,
                    child: Text('Reactivate'),
                  ),
                if (!isSoftDeleted) ...<PopupMenuEntry<_MembersRowAction>>[
                  const PopupMenuItem<_MembersRowAction>(
                    key: Key('members_row_action_reset_password'),
                    value: _MembersRowAction.resetPassword,
                    child: Text('Reset password'),
                  ),
                  const PopupMenuItem<_MembersRowAction>(
                    key: Key('members_row_action_reset_mfa'),
                    value: _MembersRowAction.resetMfa,
                    child: Text('Reset two-factor sign-in'),
                  ),
                  const PopupMenuItem<_MembersRowAction>(
                    key: Key('members_row_action_soft_delete'),
                    value: _MembersRowAction.softDelete,
                    child: Text('Remove from team'),
                  ),
                ],
              ];
            },
          ),
        ),
      ],
    );
  }
}

enum _MembersRowAction {
  suspend,
  reactivate,
  softDelete,
  resetPassword,
  resetMfa,
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      'active' => 'Active',
      'suspended' => 'Suspended',
      'dormant_30' => 'Dormant',
      'soft_deleted' => 'Removed',
      _ => status,
    };
    final color = switch (status) {
      'active' => AppColors.positive,
      'suspended' => AppColors.negative,
      'dormant_30' => AppColors.textMuted,
      'soft_deleted' => AppColors.textMuted,
      _ => AppColors.textMuted,
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: AppTextStyles.mono8(color: color)),
      ),
    );
  }
}

class _MembersPaginationBar extends StatelessWidget {
  const _MembersPaginationBar({
    required this.controller,
    required this.totalRows,
  });

  final TeamUsersListController controller;
  final int totalRows;

  @override
  Widget build(BuildContext context) {
    final pageSize = controller.pageSize;
    final pageIndex = controller.pageIndex;
    final start = totalRows == 0 ? 0 : pageIndex * pageSize + 1;
    final end = ((pageIndex + 1) * pageSize).clamp(0, totalRows);
    final canPrev = pageIndex > 0;
    final canNext = end < totalRows;
    return Container(
      key: const Key('operator_web_members_pagination'),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(
        children: <Widget>[
          Text(
            totalRows == 0
                ? 'No members'
                : 'Showing $start to $end of $totalRows',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
          const Spacer(),
          IconButton(
            key: const Key('operator_web_members_pagination_prev'),
            onPressed: canPrev ? controller.previousPage : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            color: AppColors.sunsetDark,
            disabledColor: AppColors.borderSubtle,
            tooltip: 'Previous page',
          ),
          IconButton(
            key: const Key('operator_web_members_pagination_next'),
            onPressed: canNext ? controller.nextPage : null,
            icon: const Icon(Icons.chevron_right, size: 18),
            color: AppColors.sunsetDark,
            disabledColor: AppColors.borderSubtle,
            tooltip: 'Next page',
          ),
        ],
      ),
    );
  }
}

class _PendingInvitesPanel extends StatelessWidget {
  const _PendingInvitesPanel({
    required this.invites,
    required this.canCancel,
    required this.busyInviteIds,
    required this.onCancel,
  });

  final List<TeamInviteListEntry> invites;
  final bool canCancel;
  final Set<String> busyInviteIds;
  final Future<void> Function(TeamInviteListEntry invite) onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_members_pending_invites'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Pending invites',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Invites your team has sent that the new teammate has not '
            'accepted yet.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          for (final invite in invites)
            Padding(
              key: Key('operator_web_pending_invite_${invite.inviteId}'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    flex: 4,
                    child: Text(
                      invite.email,
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      invite.roleLabel,
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      invite.locationLabel ?? 'All locations',
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
                  if (canCancel)
                    SizedBox(
                      width: 88,
                      child: busyInviteIds.contains(invite.inviteId)
                          ? const Align(
                              alignment: Alignment.centerRight,
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.sunsetDark,
                                ),
                              ),
                            )
                          : Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                key: Key(
                                  'operator_web_pending_invite_cancel_'
                                  '${invite.inviteId}',
                                ),
                                onPressed: () => onCancel(invite),
                                child: const Text('Cancel'),
                              ),
                            ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MembersForbiddenSurface extends StatelessWidget {
  const _MembersForbiddenSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Members is owner-managed',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Adding and removing teammates is managed by your operator '
                'admin or owner. Ask them to add you to the right role if '
                'you need to change who is on the team.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
