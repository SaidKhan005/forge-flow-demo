import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../services/team/team_invite_form_controller.dart';
import '../../services/team/team_scope_visibility_policy.dart';
import '../../services/team/team_users_list_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sticky_section_delegate.dart';

typedef TeamInviteSubmitter =
    Future<TeamInviteCreated?> Function(Map<String, Object?> payload);

typedef TeamInviteRevoker = Future<void> Function(String inviteId);

typedef TeamUserActionHandler =
    Future<void> Function(TeamUserActionRequest request);

enum TeamUserAction {
  suspend,
  reactivate,
  softDelete,
  resetPassword,
  resetMfa,
  cancelMfaRemoval,
  createRoleGrant,
  revokeRoleGrant,
}

class TeamUserActionRequest {
  const TeamUserActionRequest({
    required this.action,
    required this.user,
    this.roleId,
    this.scopeType,
    this.locationId,
    this.replaceUserRoleId,
    this.reason,
  });

  final TeamUserAction action;
  final TeamUserListItem user;
  final String? roleId;
  final String? scopeType;
  final String? locationId;
  final String? replaceUserRoleId;
  final String? reason;
}

class TeamRoleOption {
  const TeamRoleOption({required this.roleId, required this.label});

  final String roleId;
  final String label;
}

class TeamLocationOption {
  const TeamLocationOption({required this.locationId, required this.label});

  final String locationId;
  final String label;
}

class TeamUserListItem {
  const TeamUserListItem({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.roleId,
    required this.roleLabel,
    required this.status,
    this.locationId,
    this.locationLabel,
    this.mfaEnrolled = false,
    this.mfaRemovalPending = false,
    this.mfaRemovalRequestId,
    this.userRoleId,
    this.lastActiveAt,
  });

  final String userId;
  final String email;
  final String displayName;
  final String roleId;
  final String roleLabel;
  final String status;
  final String? locationId;
  final String? locationLabel;
  final bool mfaEnrolled;
  final bool mfaRemovalPending;
  final String? mfaRemovalRequestId;
  final String? userRoleId;
  final DateTime? lastActiveAt;
}

class TeamPendingInviteListItem {
  const TeamPendingInviteListItem({
    required this.inviteId,
    required this.email,
    required this.roleId,
    required this.roleLabel,
    required this.scopeType,
    required this.expiresAt,
    this.locationId,
    this.locationLabel,
  });

  final String inviteId;
  final String email;
  final String roleId;
  final String roleLabel;
  final String scopeType;
  final String? locationId;
  final String? locationLabel;
  final DateTime expiresAt;
}

class TeamSettingsDataLoadState {
  const TeamSettingsDataLoadState({this.loading = false, this.loaded = true});

  static const TeamSettingsDataLoadState ready = TeamSettingsDataLoadState();
  static const TeamSettingsDataLoadState waiting = TeamSettingsDataLoadState(
    loading: true,
    loaded: false,
  );
  static const TeamSettingsDataLoadState unavailable =
      TeamSettingsDataLoadState(loaded: false);

  final bool loading;
  final bool loaded;

  bool get shouldShowLoadingMessage => loading || !loaded;
}

class TeamSettingsSection extends StatefulWidget {
  const TeamSettingsSection({
    super.key,
    required this.actor,
    this.users = const <TeamUserListItem>[],
    this.roleOptions = defaultRoleOptions,
    this.locationOptions = const <TeamLocationOption>[],
    this.pendingInvites = const <TeamPendingInviteListItem>[],
    this.usersController,
    this.inviteFormController,
    this.onInviteSubmitted,
    this.onInviteRevoked,
    this.onUserAction,
    this.dataLoadState = TeamSettingsDataLoadState.ready,
  });

  static const List<TeamRoleOption> defaultRoleOptions = <TeamRoleOption>[
    TeamRoleOption(roleId: 'operator_owner', label: 'Owner'),
    TeamRoleOption(roleId: 'operator_manager', label: 'Manager'),
    TeamRoleOption(roleId: 'operator_supervisor', label: 'Supervisor'),
    TeamRoleOption(roleId: 'operator_staff', label: 'Staff'),
  ];

  final TeamScopeActor actor;
  final List<TeamUserListItem> users;
  final List<TeamRoleOption> roleOptions;
  final List<TeamLocationOption> locationOptions;
  final List<TeamPendingInviteListItem> pendingInvites;
  final TeamUsersListController? usersController;
  final TeamInviteFormController? inviteFormController;
  final TeamInviteSubmitter? onInviteSubmitted;
  final TeamInviteRevoker? onInviteRevoked;
  final TeamUserActionHandler? onUserAction;
  final TeamSettingsDataLoadState dataLoadState;

  @override
  State<TeamSettingsSection> createState() => _TeamSettingsSectionState();
}

class _TeamSettingsSectionState extends State<TeamSettingsSection> {
  late final TeamUsersListController _usersController;
  late final TeamInviteFormController _inviteController;
  late final bool _ownsUsersController;
  late final bool _ownsInviteController;
  late final TextEditingController _searchController;
  late final TextEditingController _emailController;
  final Set<String> _busyUserIds = <String>{};
  final Set<String> _busyInviteIds = <String>{};
  final Set<String> _pendingMfaResetUserIds = <String>{};
  final Set<String> _cancelledMfaResetUserIds = <String>{};
  final List<TeamPendingInviteListItem> _locallyCreatedInvites =
      <TeamPendingInviteListItem>[];
  bool _submittingInvite = false;

  @override
  void initState() {
    super.initState();
    _ownsUsersController = widget.usersController == null;
    _ownsInviteController = widget.inviteFormController == null;
    _usersController = widget.usersController ?? TeamUsersListController();
    _inviteController =
        widget.inviteFormController ?? TeamInviteFormController();
    _searchController = TextEditingController(
      text: _usersController.filter.searchQuery,
    );
    _emailController = TextEditingController(text: _inviteController.email);
    _usersController.addListener(_handleControllerChanged);
    _inviteController.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant TeamSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.usersController != widget.usersController ||
        oldWidget.inviteFormController != widget.inviteFormController) {
      throw StateError('TeamSettingsSection controllers must stay stable');
    }
    _pendingMfaResetUserIds.removeWhere((userId) {
      return !widget.users.any((user) {
        return user.userId == userId &&
            (user.mfaEnrolled || user.mfaRemovalPending);
      });
    });
    _cancelledMfaResetUserIds.removeWhere((userId) {
      return !widget.users.any((user) {
        return user.userId == userId && user.mfaRemovalPending;
      });
    });
  }

  @override
  void dispose() {
    _usersController.removeListener(_handleControllerChanged);
    _inviteController.removeListener(_handleControllerChanged);
    _searchController.dispose();
    _emailController.dispose();
    if (_ownsUsersController) _usersController.dispose();
    if (_ownsInviteController) _inviteController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    if (_searchController.text != _usersController.filter.searchQuery) {
      _searchController.text = _usersController.filter.searchQuery;
    }
    if (_emailController.text != _inviteController.email) {
      _emailController.text = _inviteController.email;
    }
    setState(() {});
  }

  List<TeamUserListItem> get _visibleUsers {
    final filter = _usersController.filter;
    final q = filter.searchQuery.trim().toLowerCase();
    return widget.users
        .where((user) {
          if (filter.statusFilter != null &&
              user.status != filter.statusFilter) {
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
        })
        .toList(growable: false);
  }

  List<TeamPendingInviteListItem> get _pendingInvites {
    final serverInviteIds = widget.pendingInvites
        .map((invite) => invite.inviteId)
        .toSet();
    return <TeamPendingInviteListItem>[
      ...widget.pendingInvites,
      ..._locallyCreatedInvites.where(
        (invite) => !serverInviteIds.contains(invite.inviteId),
      ),
    ];
  }

  bool get _canInvite {
    if (!widget.actor.actorPermissions.contains('team.users.invite')) {
      return false;
    }
    if (widget.actor.actorRoles.contains('operator_manager')) {
      return widget.actor.actorAssignedLocationIds.isNotEmpty;
    }
    return TeamScopeVisibilityPolicy.canMutateTarget(
      actor: widget.actor,
      target: TeamScopeTarget(targetOperatorId: widget.actor.actorOperatorId),
      requiredPermissionKey: 'team.users.invite',
    );
  }

  bool get _canViewTeam =>
      widget.actor.actorPermissions.contains('team.users.view');

  bool get _canManageUsers =>
      widget.onUserAction != null &&
      widget.actor.actorPermissions.any(
        const <String>{
          'team.users.deactivate',
          'team.users.reactivate',
          'team.users.soft_delete',
          'team.users.reset_password',
          'team.users.reset_mfa',
          'team.roles.assign',
          'team.roles.revoke',
        }.contains,
      );

  Future<void> _submitInvite() async {
    if (!_canInvite ||
        widget.onInviteSubmitted == null ||
        !_inviteController.isReadyToSubmit) {
      return;
    }
    setState(() => _submittingInvite = true);
    try {
      final payload = _inviteController.toRequestPayload();
      final created = await widget.onInviteSubmitted!(payload);
      if (created != null) {
        _locallyCreatedInvites.add(
          _pendingInviteFromPayload(payload: payload, created: created),
        );
      }
      _inviteController.reset();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invite submitted')));
      }
    } catch (error) {
      debugPrint('Team invite submission failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invite could not be sent. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submittingInvite = false);
    }
  }

  TeamPendingInviteListItem _pendingInviteFromPayload({
    required Map<String, Object?> payload,
    required TeamInviteCreated created,
  }) {
    final roleId = payload['role_id'] as String? ?? '';
    final locationId = payload['location_id'] as String?;
    return TeamPendingInviteListItem(
      inviteId: created.inviteId,
      email: payload['email'] as String? ?? 'Pending invite',
      roleId: roleId,
      roleLabel: _roleLabel(roleId),
      scopeType: payload['scope_type'] as String? ?? 'operator_wide',
      locationId: locationId,
      locationLabel: locationId == null ? null : _locationLabel(locationId),
      expiresAt: created.expiresAt,
    );
  }

  String _roleLabel(String roleId) {
    for (final role in widget.roleOptions) {
      if (role.roleId == roleId) return role.label;
    }
    return roleId;
  }

  String? _locationLabel(String locationId) {
    for (final location in widget.locationOptions) {
      if (location.locationId == locationId) return location.label;
    }
    return null;
  }

  bool _canUsePermission(String permissionKey, {TeamUserListItem? user}) {
    final targetLocationId = user?.locationId;
    return TeamScopeVisibilityPolicy.canMutateTarget(
      actor: widget.actor,
      target: TeamScopeTarget(
        targetOperatorId: widget.actor.actorOperatorId,
        targetLocationId: targetLocationId,
      ),
      requiredPermissionKey: permissionKey,
    );
  }

  Future<void> _revokeInvite(TeamPendingInviteListItem invite) async {
    if (widget.onInviteRevoked == null ||
        !widget.actor.actorPermissions.contains('team.users.invite')) {
      _showSnack('Invite revoke is not available for this account.');
      return;
    }
    final confirmed = await _confirm(
      title: 'Revoke invite',
      message: 'Revoke the pending invite for ${invite.email}?',
      actionLabel: 'Revoke',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyInviteIds.add(invite.inviteId));
    try {
      await widget.onInviteRevoked!(invite.inviteId);
      _locallyCreatedInvites.removeWhere(
        (item) => item.inviteId == invite.inviteId,
      );
      if (mounted) _showSnack('Invite revoked');
    } catch (error) {
      debugPrint('Team invite revoke failed: $error');
      if (mounted) _showSnack('Invite could not be revoked.');
    } finally {
      if (mounted) setState(() => _busyInviteIds.remove(invite.inviteId));
    }
  }

  Future<void> _handleUserAction(
    TeamUserAction action,
    TeamUserListItem user,
  ) async {
    if (widget.onUserAction == null) {
      _showSnack('Team actions are not connected yet.');
      return;
    }
    switch (action) {
      case TeamUserAction.createRoleGrant:
        await _openRoleDialog(user);
      case TeamUserAction.resetPassword:
        await _runConfirmedUserAction(
          action: action,
          user: user,
          title: 'Reset password',
          message: 'Send a password reset email to ${user.email}?',
          actionLabel: 'Send',
          success: 'Password reset email queued',
        );
      case TeamUserAction.resetMfa:
        await _runConfirmedUserAction(
          action: action,
          user: user,
          title: 'Remove two-factor authentication',
          message:
              'Start removing two-factor authentication for ${user.email}? It will be removed in 24 hours for security purposes. Check back after the security window to confirm it is done.',
          actionLabel: 'Start removal',
          success:
              'Two-factor authentication removal started. It will be removed in 24 hours.',
        );
      case TeamUserAction.cancelMfaRemoval:
        await _runConfirmedUserAction(
          action: action,
          user: user,
          title: 'Cancel two-factor removal',
          message: 'Keep two-factor authentication active for ${user.email}?',
          actionLabel: 'Cancel removal',
          success: 'Two-factor authentication removal cancelled.',
        );
      case TeamUserAction.suspend:
        await _runConfirmedUserAction(
          action: action,
          user: user,
          title: 'Suspend user',
          message: 'Suspend ${user.displayName} and block sign-in?',
          actionLabel: 'Suspend',
          success: 'User suspended',
        );
      case TeamUserAction.reactivate:
        await _runConfirmedUserAction(
          action: action,
          user: user,
          title: 'Reactivate user',
          message: 'Restore sign-in for ${user.displayName}?',
          actionLabel: 'Reactivate',
          success: 'User reactivated',
        );
      case TeamUserAction.softDelete:
        await _runConfirmedUserAction(
          action: action,
          user: user,
          title: 'Remove access',
          message: 'Remove ${user.displayName} from this operator?',
          actionLabel: 'Remove',
          success: 'User access removed',
        );
      case TeamUserAction.revokeRoleGrant:
        await _runConfirmedUserAction(
          action: action,
          user: user,
          title: 'Revoke role',
          message: 'Revoke the active role grant for ${user.displayName}?',
          actionLabel: 'Revoke',
          success: 'Role grant revoked',
        );
    }
  }

  Future<void> _runConfirmedUserAction({
    required TeamUserAction action,
    required TeamUserListItem user,
    required String title,
    required String message,
    required String actionLabel,
    required String success,
  }) async {
    final confirmed = await _confirm(
      title: title,
      message: message,
      actionLabel: actionLabel,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyUserIds.add(user.userId));
    try {
      await widget.onUserAction!(
        TeamUserActionRequest(
          action: action,
          user: user,
          replaceUserRoleId: action == TeamUserAction.revokeRoleGrant
              ? user.userRoleId
              : null,
          reason: _reasonFor(action),
        ),
      );
      if (mounted) {
        if (action == TeamUserAction.resetMfa) {
          _pendingMfaResetUserIds.add(user.userId);
          _cancelledMfaResetUserIds.remove(user.userId);
        }
        if (action == TeamUserAction.cancelMfaRemoval) {
          _pendingMfaResetUserIds.remove(user.userId);
          _cancelledMfaResetUserIds.add(user.userId);
        }
        _showSnack(success);
      }
    } catch (error) {
      debugPrint('Team user action failed: $error');
      if (mounted) _showSnack(_messageForUserActionError(error, action));
    } finally {
      if (mounted) setState(() => _busyUserIds.remove(user.userId));
    }
  }

  Future<void> _openRoleDialog(TeamUserListItem user) async {
    final draft = await showDialog<_RoleGrantDraft>(
      context: context,
      builder: (context) => _RoleGrantDialog(
        user: user,
        roleOptions: widget.roleOptions,
        locationOptions: widget.locationOptions,
      ),
    );
    if (draft == null || !mounted) return;
    setState(() => _busyUserIds.add(user.userId));
    try {
      await widget.onUserAction!(
        TeamUserActionRequest(
          action: TeamUserAction.createRoleGrant,
          user: user,
          roleId: draft.roleId,
          scopeType: draft.scopeType,
          locationId: draft.locationId,
          replaceUserRoleId: user.userRoleId,
          reason: 'settings_team_role_change',
        ),
      );
      if (mounted) _showSnack('Role update submitted');
    } catch (error) {
      debugPrint('Team role update failed: $error');
      if (mounted) _showSnack('Role update could not be completed.');
    } finally {
      if (mounted) setState(() => _busyUserIds.remove(user.userId));
    }
  }

  String _reasonFor(TeamUserAction action) {
    return switch (action) {
      TeamUserAction.suspend => 'settings_team_suspend',
      TeamUserAction.reactivate => 'settings_team_reactivate',
      TeamUserAction.softDelete => 'settings_team_remove_access',
      TeamUserAction.resetPassword => 'settings_team_reset_password',
      TeamUserAction.resetMfa => 'settings_team_reset_mfa',
      TeamUserAction.cancelMfaRemoval => 'settings_team_cancel_mfa_removal',
      TeamUserAction.createRoleGrant => 'settings_team_role_change',
      TeamUserAction.revokeRoleGrant => 'settings_team_role_revoke',
    };
  }

  String _messageForUserActionError(Object error, TeamUserAction action) {
    final code = switch (error) {
      AuthOperationRejected(:final code) => code,
      _ => error.toString(),
    };
    if (code.contains('mfa_freshness_required')) {
      return 'Sign in again before removing two-factor authentication.';
    }
    if (action == TeamUserAction.resetMfa) {
      return 'Two-factor removal could not be started.';
    }
    if (action == TeamUserAction.cancelMfaRemoval) {
      return 'Two-factor removal could not be cancelled.';
    }
    return 'Action could not be completed.';
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String actionLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final users = _visibleUsers;
    final pendingInvites = _pendingInvites;
    final dataLoadState = widget.dataLoadState;
    final inviteHasDraft =
        _inviteController.email.trim().isNotEmpty ||
        _inviteController.roleId != null ||
        _inviteController.scope != null ||
        _inviteController.locationId != null;
    final filter = _usersController.filter;
    final hasMemberQuery =
        filter.searchQuery.trim().isNotEmpty ||
        filter.statusFilter != null ||
        filter.roleFilter != null ||
        filter.locationFilter != null ||
        filter.mfaEnrolledFilter != null;
    // Show the full list inline for small teams (the common restaurant
    // case). Above this size, hide behind search to keep the tab quiet
    // and let the operator find a single member without scrolling
    // through everyone.
    const memberSearchThreshold = 8;
    final showMembersList =
        widget.users.length <= memberSearchThreshold || hasMemberQuery;
    const inset = EdgeInsets.symmetric(horizontal: 16);
    final content = Column(
      key: const Key('team_settings_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: inset,
          child: _TeamAccessNotice(
            canViewTeam: _canViewTeam,
            canInvite: _canInvite,
            canManageUsers: _canManageUsers,
          ),
        ),
        if (dataLoadState.shouldShowLoadingMessage) ...[
          const SizedBox(height: 8),
          Padding(
            padding: inset,
            child: _TeamDataLoadingNotice(loading: dataLoadState.loading),
          ),
        ],
        const SizedBox(height: 8),
        const SectionLabel('Members'),
        const SizedBox(height: 8),
        Padding(
          padding: inset,
          child: _TeamFilters(
            controller: _usersController,
            searchController: _searchController,
            roleOptions: widget.roleOptions,
            locationOptions: widget.locationOptions,
            narrow: true,
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: inset,
          child: showMembersList
              ? _TeamMembersViewport(
                  narrow: true,
                  child: _TeamUsersTable(
                    users: users,
                    narrow: true,
                    dataLoadState: dataLoadState,
                    canSuspend: (user) =>
                        _canUsePermission('team.users.deactivate', user: user),
                    canReactivate: (user) =>
                        _canUsePermission('team.users.reactivate', user: user),
                    canSoftDelete: (user) =>
                        _canUsePermission('team.users.soft_delete', user: user),
                    canResetPassword: (user) => _canUsePermission(
                      'team.users.reset_password',
                      user: user,
                    ),
                    canResetMfa: (user) => _canUsePermission(
                      'team.users.reset_mfa',
                      user: user,
                    ),
                    canAssignRole: (user) =>
                        _canUsePermission('team.roles.assign', user: user),
                    canRevokeRole: (user) =>
                        _canUsePermission('team.roles.revoke', user: user),
                    busyUserIds: _busyUserIds,
                    pendingMfaResetUserIds: _pendingMfaResetUserIds,
                    cancelledMfaResetUserIds: _cancelledMfaResetUserIds,
                    onAction: _handleUserAction,
                  ),
                )
              : _TeamMembersSearchPrompt(totalCount: widget.users.length),
        ),
        const SizedBox(height: 16),
        const SectionLabel('Pending invites'),
        const SizedBox(height: 8),
        Padding(
          padding: inset,
          child: _PendingInvitesPanel(
            invites: pendingInvites,
            canRevoke: _canInvite && widget.onInviteRevoked != null,
            busyInviteIds: _busyInviteIds,
            onRevoke: _revokeInvite,
          ),
        ),
        const SizedBox(height: 16),
        const SectionLabel('Invite members'),
        const SizedBox(height: 8),
        Padding(
          padding: inset,
          child: _TeamInvitePanel(
            controller: _inviteController,
            emailController: _emailController,
            roleOptions: widget.roleOptions,
            locationOptions: widget.locationOptions,
            enabled: _canInvite,
            submitEnabled:
                _canInvite &&
                !_submittingInvite &&
                widget.onInviteSubmitted != null &&
                _inviteController.isReadyToSubmit,
            submitting: _submittingInvite,
            initiallyExpanded: inviteHasDraft,
            onSubmit: _submitInvite,
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) return content;
        return SingleChildScrollView(child: content);
      },
    );
  }
}

class _TeamMembersViewport extends StatelessWidget {
  const _TeamMembersViewport({required this.narrow, required this.child});

  final bool narrow;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _ScrollViewportPanel(
      maxHeight: narrow ? 380 : 540,
      scrollKey: const Key('team_members_list_scroll'),
      child: child,
    );
  }
}

/// Bounded, visually distinct scroll panel used by Members and Pending
/// Invites. Renders the child inside a rounded border with a visible
/// scrollbar so the user sees the inner scroll surface and can drag
/// inside it without hijacking the page scroll.
class _ScrollViewportPanel extends StatefulWidget {
  const _ScrollViewportPanel({
    required this.maxHeight,
    required this.scrollKey,
    required this.child,
  });

  final double maxHeight;
  final Key scrollKey;
  final Widget child;

  @override
  State<_ScrollViewportPanel> createState() => _ScrollViewportPanelState();
}

class _ScrollViewportPanelState extends State<_ScrollViewportPanel> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          thickness: 6,
          radius: const Radius.circular(3),
          child: SingleChildScrollView(
            key: widget.scrollKey,
            controller: _controller,
            primary: false,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.only(right: 6),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _TeamAccessNotice extends StatelessWidget {
  const _TeamAccessNotice({
    required this.canViewTeam,
    required this.canInvite,
    required this.canManageUsers,
  });

  final bool canViewTeam;
  final bool canInvite;
  final bool canManageUsers;

  @override
  Widget build(BuildContext context) {
    if (canInvite && canManageUsers) return const SizedBox.shrink();
    final message = !canViewTeam
        ? 'Team settings are visible, but membership data and actions are locked for this account.'
        : !canInvite && !canManageUsers
        ? 'This account can view team membership, but invite and management actions are locked by permissions.'
        : !canInvite
        ? 'Invite actions are locked by permissions. Existing team actions remain available where allowed.'
        : 'Management actions are loading. Invite is available.';
    return Container(
      key: const Key('team_access_notice'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _TeamDataLoadingNotice extends StatelessWidget {
  const _TeamDataLoadingNotice({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('team_data_loading_notice'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(
            loading ? Icons.cloud_sync_outlined : Icons.wifi_off_outlined,
            size: 18,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Staff late looking for Parking lol',
              softWrap: true,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
          if (loading) ...[
            const SizedBox(width: 12),
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }
}

class _TeamFilters extends StatelessWidget {
  const _TeamFilters({
    required this.controller,
    required this.searchController,
    required this.roleOptions,
    required this.locationOptions,
    required this.narrow,
  });

  final TeamUsersListController controller;
  final TextEditingController searchController;
  final List<TeamRoleOption> roleOptions;
  final List<TeamLocationOption> locationOptions;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      SizedBox(
        width: narrow ? double.infinity : 240,
        child: TextField(
          key: const Key('team_search_field'),
          controller: searchController,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 18),
            labelText: 'Search',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: controller.setSearchQuery,
        ),
      ),
      SizedBox(
        width: narrow ? double.infinity : 180,
        child: DropdownButtonFormField<String?>(
          key: const Key('team_status_filter'),
          initialValue: controller.filter.statusFilter,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Status',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: const [
            DropdownMenuItem<String?>(value: null, child: Text('Any')),
            DropdownMenuItem<String?>(value: 'active', child: Text('Active')),
            DropdownMenuItem<String?>(value: 'invited', child: Text('Invited')),
            DropdownMenuItem<String?>(
              value: 'suspended',
              child: Text('Suspended'),
            ),
          ],
          onChanged: controller.setStatus,
        ),
      ),
      SizedBox(
        width: narrow ? double.infinity : 190,
        child: DropdownButtonFormField<String?>(
          key: const Key('team_role_filter'),
          initialValue: controller.filter.roleFilter,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Role',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Any')),
            for (final role in roleOptions)
              DropdownMenuItem<String?>(
                value: role.roleId,
                child: Text(role.label),
              ),
          ],
          onChanged: controller.setRole,
        ),
      ),
      SizedBox(
        width: narrow ? double.infinity : 190,
        child: DropdownButtonFormField<String?>(
          key: const Key('team_location_filter'),
          initialValue: controller.filter.locationFilter,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Location',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Any')),
            for (final location in locationOptions)
              DropdownMenuItem<String?>(
                value: location.locationId,
                child: Text(location.label),
              ),
          ],
          onChanged: controller.setLocation,
        ),
      ),
    ];
    return Wrap(spacing: 10, runSpacing: 10, children: fields);
  }
}

class _TeamUsersTable extends StatelessWidget {
  const _TeamUsersTable({
    required this.users,
    required this.narrow,
    required this.dataLoadState,
    required this.canSuspend,
    required this.canReactivate,
    required this.canSoftDelete,
    required this.canResetPassword,
    required this.canResetMfa,
    required this.canAssignRole,
    required this.canRevokeRole,
    required this.busyUserIds,
    required this.pendingMfaResetUserIds,
    required this.cancelledMfaResetUserIds,
    required this.onAction,
  });

  final List<TeamUserListItem> users;
  final bool narrow;
  final TeamSettingsDataLoadState dataLoadState;
  final bool Function(TeamUserListItem user) canSuspend;
  final bool Function(TeamUserListItem user) canReactivate;
  final bool Function(TeamUserListItem user) canSoftDelete;
  final bool Function(TeamUserListItem user) canResetPassword;
  final bool Function(TeamUserListItem user) canResetMfa;
  final bool Function(TeamUserListItem user) canAssignRole;
  final bool Function(TeamUserListItem user) canRevokeRole;
  final Set<String> busyUserIds;
  final Set<String> pendingMfaResetUserIds;
  final Set<String> cancelledMfaResetUserIds;
  final Future<void> Function(TeamUserAction action, TeamUserListItem user)
  onAction;

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) {
      return Container(
        key: const Key('team_users_empty'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.backgroundMid,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.group_off_outlined,
              size: 20,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'No team members',
                softWrap: true,
                style: AppTextStyles.body14(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      );
    }
    if (narrow) {
      return Column(
        children: [
          for (var i = 0; i < users.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _TeamUserCard(
              key: Key('team_user_row_$i'),
              user: users[i],
              canSuspend: canSuspend(users[i]),
              canReactivate: canReactivate(users[i]),
              canSoftDelete: canSoftDelete(users[i]),
              canResetPassword: canResetPassword(users[i]),
              canResetMfa: canResetMfa(users[i]),
              canAssignRole: canAssignRole(users[i]),
              canRevokeRole: canRevokeRole(users[i]),
              busy: busyUserIds.contains(users[i].userId),
              mfaResetPending: _mfaResetPendingFor(users[i]),
              onAction: onAction,
            ),
          ],
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Column(
          children: [
            const _TeamUsersHeader(),
            for (var i = 0; i < users.length; i++)
              _TeamUserRow(
                key: Key('team_user_row_$i'),
                user: users[i],
                canSuspend: canSuspend(users[i]),
                canReactivate: canReactivate(users[i]),
                canSoftDelete: canSoftDelete(users[i]),
                canResetPassword: canResetPassword(users[i]),
                canResetMfa: canResetMfa(users[i]),
                canAssignRole: canAssignRole(users[i]),
                canRevokeRole: canRevokeRole(users[i]),
                busy: busyUserIds.contains(users[i].userId),
                mfaResetPending: _mfaResetPendingFor(users[i]),
                onAction: onAction,
              ),
          ],
        ),
      ),
    );
  }

  bool _mfaResetPendingFor(TeamUserListItem user) {
    if (cancelledMfaResetUserIds.contains(user.userId)) return false;
    return pendingMfaResetUserIds.contains(user.userId) ||
        user.mfaRemovalPending;
  }
}

class _TeamUsersHeader extends StatelessWidget {
  const _TeamUsersHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.backgroundMid,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('USER', style: AppTextStyles.mono10())),
          Expanded(flex: 2, child: Text('ROLE', style: AppTextStyles.mono10())),
          Expanded(
            flex: 2,
            child: Text('SCOPE', style: AppTextStyles.mono10()),
          ),
          Expanded(
            flex: 2,
            child: Text('STATUS', style: AppTextStyles.mono10()),
          ),
          SizedBox(
            width: 48,
            child: Text('ACTIONS', style: AppTextStyles.mono10()),
          ),
        ],
      ),
    );
  }
}

class _TeamUserRow extends StatelessWidget {
  const _TeamUserRow({
    super.key,
    required this.user,
    required this.canSuspend,
    required this.canReactivate,
    required this.canSoftDelete,
    required this.canResetPassword,
    required this.canResetMfa,
    required this.canAssignRole,
    required this.canRevokeRole,
    required this.busy,
    required this.mfaResetPending,
    required this.onAction,
  });

  final TeamUserListItem user;
  final bool canSuspend;
  final bool canReactivate;
  final bool canSoftDelete;
  final bool canResetPassword;
  final bool canResetMfa;
  final bool canAssignRole;
  final bool canRevokeRole;
  final bool busy;
  final bool mfaResetPending;
  final Future<void> Function(TeamUserAction action, TeamUserListItem user)
  onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.displayName, style: AppTextStyles.body14()),
                const SizedBox(height: 2),
                Text(
                  user.email,
                  style: AppTextStyles.mono12(color: AppColors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(user.roleLabel, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text(
              user.locationLabel ?? 'Operator-wide',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StatusPill(status: user.status),
                if (mfaResetPending)
                  const _MiniPill(
                    label: '24h',
                    icon: Icons.schedule_rounded,
                    color: AppColors.warning,
                  )
                else if (user.mfaEnrolled)
                  const _MiniPill(label: '2FA', icon: Icons.verified_user),
              ],
            ),
          ),
          SizedBox(
            width: 48,
            child: busy
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _TeamUserActionMenu(
                    user: user,
                    canSuspend: canSuspend,
                    canReactivate: canReactivate,
                    canSoftDelete: canSoftDelete,
                    canResetPassword: canResetPassword,
                    canResetMfa: canResetMfa,
                    mfaResetPending: mfaResetPending,
                    canAssignRole: canAssignRole,
                    canRevokeRole: canRevokeRole,
                    onAction: onAction,
                  ),
          ),
        ],
      ),
    );
  }
}

class _TeamUserCard extends StatelessWidget {
  const _TeamUserCard({
    super.key,
    required this.user,
    required this.canSuspend,
    required this.canReactivate,
    required this.canSoftDelete,
    required this.canResetPassword,
    required this.canResetMfa,
    required this.canAssignRole,
    required this.canRevokeRole,
    required this.busy,
    required this.mfaResetPending,
    required this.onAction,
  });

  final TeamUserListItem user;
  final bool canSuspend;
  final bool canReactivate;
  final bool canSoftDelete;
  final bool canResetPassword;
  final bool canResetMfa;
  final bool canAssignRole;
  final bool canRevokeRole;
  final bool busy;
  final bool mfaResetPending;
  final Future<void> Function(TeamUserAction action, TeamUserListItem user)
  onAction;

  @override
  Widget build(BuildContext context) {
    final stripe = _statusStripeColor(user.status);
    final primary = _resolvePrimaryAction(
      user: user,
      mfaResetPending: mfaResetPending,
      canReactivate: canReactivate,
    );
    final showLocation =
        user.locationLabel != null && user.locationLabel!.isNotEmpty;
    final showPersistentStatus = _showStatusPill(user.status);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: stripe ?? Colors.transparent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InitialsAvatar(displayName: user.displayName),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    user.displayName,
                                    style: AppTextStyles.body14(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _MfaIndicator(
                                  enrolled: user.mfaEnrolled,
                                  removalPending: mfaResetPending,
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              user.email,
                              style: AppTextStyles.mono10(
                                color: AppColors.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _RoleChip(label: user.roleLabel),
                                if (showLocation)
                                  _ScopePill(label: user.locationLabel!),
                                if (showPersistentStatus)
                                  _StatusPill(status: user.status),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      if (busy)
                        const SizedBox(
                          width: 32,
                          height: 32,
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (primary != null)
                              _PrimaryActionButton(
                                userId: user.userId,
                                descriptor: primary,
                                onPressed: () => onAction(primary.action, user),
                              ),
                            _TeamUserActionMenu(
                              user: user,
                              canSuspend: canSuspend,
                              canReactivate: canReactivate,
                              canSoftDelete: canSoftDelete,
                              canResetPassword: canResetPassword,
                              canResetMfa: canResetMfa,
                              mfaResetPending: mfaResetPending,
                              canAssignRole: canAssignRole,
                              canRevokeRole: canRevokeRole,
                              onAction: onAction,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TeamUserActionMenu extends StatelessWidget {
  const _TeamUserActionMenu({
    required this.user,
    required this.canSuspend,
    required this.canReactivate,
    required this.canSoftDelete,
    required this.canResetPassword,
    required this.canResetMfa,
    required this.mfaResetPending,
    required this.canAssignRole,
    required this.canRevokeRole,
    required this.onAction,
  });

  final TeamUserListItem user;
  final bool canSuspend;
  final bool canReactivate;
  final bool canSoftDelete;
  final bool canResetPassword;
  final bool canResetMfa;
  final bool mfaResetPending;
  final bool canAssignRole;
  final bool canRevokeRole;
  final Future<void> Function(TeamUserAction action, TeamUserListItem user)
  onAction;

  @override
  Widget build(BuildContext context) {
    final actions = <PopupMenuEntry<TeamUserAction>>[
      if (canAssignRole)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.createRoleGrant,
          child: _MenuItemLabel(
            icon: Icons.badge_outlined,
            label: 'Change role',
          ),
        ),
      if (canResetPassword)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.resetPassword,
          child: _MenuItemLabel(
            icon: Icons.mark_email_read_outlined,
            label: 'Reset password',
          ),
        ),
      if (canResetMfa && mfaResetPending && user.mfaRemovalRequestId != null)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.cancelMfaRemoval,
          child: _MenuItemLabel(
            icon: Icons.event_busy_outlined,
            label: 'Cancel 2FA removal',
          ),
        )
      else if (canResetMfa && !mfaResetPending)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.resetMfa,
          child: _MenuItemLabel(
            icon: Icons.admin_panel_settings_outlined,
            label: 'Remove/reset 2FA',
          ),
        ),
      if (user.status == 'suspended' && canReactivate)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.reactivate,
          child: _MenuItemLabel(
            icon: Icons.person_add_alt_1_outlined,
            label: 'Reactivate',
          ),
        ),
      if (user.status != 'suspended' && user.status != 'deleted' && canSuspend)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.suspend,
          child: _MenuItemLabel(
            icon: Icons.person_off_outlined,
            label: 'Suspend',
          ),
        ),
      if (user.userRoleId != null && canRevokeRole)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.revokeRoleGrant,
          child: _MenuItemLabel(
            icon: Icons.remove_circle_outline,
            label: 'Revoke role',
          ),
        ),
      if (user.status != 'deleted' && canSoftDelete)
        const PopupMenuItem<TeamUserAction>(
          value: TeamUserAction.softDelete,
          child: _MenuItemLabel(
            icon: Icons.delete_outline,
            label: 'Remove access',
          ),
        ),
    ];
    return Tooltip(
      message: actions.isEmpty ? 'No available actions' : 'Team actions',
      child: PopupMenuButton<TeamUserAction>(
        key: Key('team_user_actions_${user.userId}'),
        enabled: actions.isNotEmpty,
        icon: const Icon(Icons.more_horiz, size: 20),
        itemBuilder: (context) => actions,
        onSelected: (action) => onAction(action, user),
      ),
    );
  }
}

class _MenuItemLabel extends StatelessWidget {
  const _MenuItemLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Flexible(child: Text(label)),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'active' => AppColors.positive,
      'invited' => AppColors.peacockDark,
      'suspended' => AppColors.warning,
      _ => AppColors.neutral,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.toUpperCase(),
        style: AppTextStyles.mono10(color: color),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({
    required this.label,
    required this.icon,
    this.color = AppColors.peacockDark,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(label, style: AppTextStyles.mono10(color: color)),
        ],
      ),
    );
  }
}

class _InitialsAvatar extends StatelessWidget {
  const _InitialsAvatar({required this.displayName});

  final String displayName;

  String get _initials {
    final parts = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.14),
        border: Border.all(
          color: AppColors.sunset.withValues(alpha: 0.5),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        _initials,
        style: AppTextStyles.mono12(
          color: AppColors.sunsetDark,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ScopePill extends StatelessWidget {
  const _ScopePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.borderSubtle.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(color: AppColors.textSecondary),
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.borderSubtle.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(color: AppColors.textSecondary),
      ),
    );
  }
}

class _MfaIndicator extends StatelessWidget {
  const _MfaIndicator({required this.enrolled, required this.removalPending});

  final bool enrolled;
  final bool removalPending;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    final String tooltip;
    if (removalPending) {
      icon = Icons.timer_outlined;
      color = AppColors.warning;
      tooltip = '2FA removal pending (24h window)';
    } else if (enrolled) {
      icon = Icons.verified_user_outlined;
      color = AppColors.positive;
      tooltip = '2FA enrolled';
    } else {
      icon = Icons.gpp_maybe_outlined;
      color = AppColors.warning;
      tooltip = '2FA not enrolled';
    }
    return Tooltip(
      message: tooltip,
      child: Icon(icon, size: 16, color: color),
    );
  }
}

class _PrimaryActionDescriptor {
  const _PrimaryActionDescriptor({
    required this.action,
    required this.label,
    required this.icon,
  });

  final TeamUserAction action;
  final String label;
  final IconData icon;
}

_PrimaryActionDescriptor? _resolvePrimaryAction({
  required TeamUserListItem user,
  required bool mfaResetPending,
  required bool canReactivate,
}) {
  if (user.status == 'suspended' && canReactivate) {
    return const _PrimaryActionDescriptor(
      action: TeamUserAction.reactivate,
      label: 'Reactivate',
      icon: Icons.person_add_alt_1_outlined,
    );
  }
  return null;
}

class _PrimaryActionButton extends StatelessWidget {
  const _PrimaryActionButton({
    required this.userId,
    required this.descriptor,
    required this.onPressed,
  });

  final String userId;
  final _PrimaryActionDescriptor descriptor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: Key('team_user_primary_action_$userId'),
      onPressed: onPressed,
      icon: Icon(descriptor.icon, size: 14, color: AppColors.sunsetDark),
      label: Text(descriptor.label),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.sunsetDark,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: AppTextStyles.mono12(
          color: AppColors.sunsetDark,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

Color? _statusStripeColor(String status) {
  return switch (status) {
    'suspended' => AppColors.warning,
    'deleted' => AppColors.negative,
    'invited' => AppColors.peacockDark,
    _ => null,
  };
}

bool _showStatusPill(String status) => status != 'active';

class _PendingInvitesPanel extends StatelessWidget {
  const _PendingInvitesPanel({
    required this.invites,
    required this.canRevoke,
    required this.busyInviteIds,
    required this.onRevoke,
  });

  final List<TeamPendingInviteListItem> invites;
  final bool canRevoke;
  final Set<String> busyInviteIds;
  final Future<void> Function(TeamPendingInviteListItem invite) onRevoke;

  @override
  Widget build(BuildContext context) {
    if (invites.isEmpty) {
      return Container(
        key: const Key('team_pending_invites_panel'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Text(
          'No pending invites',
          style: AppTextStyles.body13(color: AppColors.textMuted),
        ),
      );
    }
    final inviteList = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final invite in invites)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PendingInviteRow(
              invite: invite,
              canRevoke: canRevoke,
              busy: busyInviteIds.contains(invite.inviteId),
              onRevoke: onRevoke,
            ),
          ),
      ],
    );
    // Short list (≤3 invites) renders inline with no nested scroll —
    // page scroll handles it. Longer lists go into a bounded scroll
    // panel with a visible scrollbar so list scroll vs page scroll
    // is visually unambiguous.
    if (invites.length <= 3) {
      return KeyedSubtree(
        key: const Key('team_pending_invites_panel'),
        child: inviteList,
      );
    }
    return KeyedSubtree(
      key: const Key('team_pending_invites_panel'),
      child: _ScrollViewportPanel(
        maxHeight: 320,
        scrollKey: const Key('team_pending_invites_scroll'),
        child: inviteList,
      ),
    );
  }
}

class _TeamMembersSearchPrompt extends StatelessWidget {
  const _TeamMembersSearchPrompt({required this.totalCount});

  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final subtitle = totalCount == 0
        ? 'No team members yet. Invite the first one below.'
        : totalCount == 1
        ? 'Search by name or email to open the member.'
        : 'Search by name or email, or filter by role, location, or status to see team members.';
    return Container(
      key: const Key('team_members_search_prompt'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.10),
              border: Border.all(
                color: AppColors.sunset.withValues(alpha: 0.4),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.search_rounded,
              size: 18,
              color: AppColors.sunsetDark,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  totalCount == 0
                      ? 'No team members yet'
                      : '$totalCount team ${totalCount == 1 ? 'member' : 'members'}',
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingInviteRow extends StatelessWidget {
  const _PendingInviteRow({
    required this.invite,
    required this.canRevoke,
    required this.busy,
    required this.onRevoke,
  });

  final TeamPendingInviteListItem invite;
  final bool canRevoke;
  final bool busy;
  final Future<void> Function(TeamPendingInviteListItem invite) onRevoke;

  @override
  Widget build(BuildContext context) {
    final showLocation =
        invite.scopeType == 'location' &&
        invite.locationLabel != null &&
        invite.locationLabel!.isNotEmpty;
    final synthName = _inviteEmailToName(invite.email);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: AppColors.peacockDark),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InitialsAvatar(displayName: synthName),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              invite.email,
                              style: AppTextStyles.body14(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Expires ${_shortDate(invite.expiresAt)}',
                              style: AppTextStyles.mono10(
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _RoleChip(label: invite.roleLabel),
                                if (showLocation)
                                  _ScopePill(label: invite.locationLabel!),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      busy
                          ? const SizedBox(
                              width: 36,
                              height: 36,
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            )
                          : IconButton(
                              key: Key('team_invite_revoke_${invite.inviteId}'),
                              tooltip: canRevoke
                                  ? 'Revoke invite'
                                  : 'Revoke unavailable',
                              onPressed: canRevoke
                                  ? () => onRevoke(invite)
                                  : null,
                              icon: const Icon(Icons.close, size: 18),
                            ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _inviteEmailToName(String email) {
  final at = email.indexOf('@');
  final local = at >= 0 ? email.substring(0, at) : email;
  return local.replaceAll(RegExp(r'[._\-]'), ' ').trim();
}

class _RoleGrantDraft {
  const _RoleGrantDraft({
    required this.roleId,
    required this.scopeType,
    this.locationId,
  });

  final String roleId;
  final String scopeType;
  final String? locationId;
}

class _RoleGrantDialog extends StatefulWidget {
  const _RoleGrantDialog({
    required this.user,
    required this.roleOptions,
    required this.locationOptions,
  });

  final TeamUserListItem user;
  final List<TeamRoleOption> roleOptions;
  final List<TeamLocationOption> locationOptions;

  @override
  State<_RoleGrantDialog> createState() => _RoleGrantDialogState();
}

class _RoleGrantDialogState extends State<_RoleGrantDialog> {
  late String? _roleId =
      widget.roleOptions.any((role) => role.roleId == widget.user.roleId)
      ? widget.user.roleId
      : (widget.roleOptions.isEmpty ? null : widget.roleOptions.first.roleId);
  late TeamInviteScope _scope = widget.user.locationId == null
      ? TeamInviteScope.operatorWide
      : TeamInviteScope.location;
  late String? _locationId =
      widget.locationOptions.any(
        (location) => location.locationId == widget.user.locationId,
      )
      ? widget.user.locationId
      : null;

  @override
  Widget build(BuildContext context) {
    final needsLocation = _scope == TeamInviteScope.location;
    final canSubmit =
        _roleId != null &&
        _roleId!.isNotEmpty &&
        (!needsLocation || (_locationId != null && _locationId!.isNotEmpty));
    return AlertDialog(
      title: const Text('Change Role'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.user.email, style: AppTextStyles.body13()),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: const Key('team_role_change_role_dropdown'),
              initialValue: _roleId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Role',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final role in widget.roleOptions)
                  DropdownMenuItem<String>(
                    value: role.roleId,
                    child: Text(role.label),
                  ),
              ],
              onChanged: (value) => setState(() => _roleId = value),
            ),
            const SizedBox(height: 12),
            SegmentedButton<TeamInviteScope>(
              key: const Key('team_role_change_scope_segmented'),
              segments: const [
                ButtonSegment<TeamInviteScope>(
                  value: TeamInviteScope.operatorWide,
                  icon: Icon(Icons.apartment, size: 16),
                  label: Text('Operator'),
                ),
                ButtonSegment<TeamInviteScope>(
                  value: TeamInviteScope.location,
                  icon: Icon(Icons.place_outlined, size: 16),
                  label: Text('Location'),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (selection) {
                final next = selection.first;
                setState(() {
                  _scope = next;
                  if (next == TeamInviteScope.operatorWide) {
                    _locationId = null;
                  }
                });
              },
            ),
            if (needsLocation) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('team_role_change_location_dropdown'),
                initialValue: _locationId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Location',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final location in widget.locationOptions)
                    DropdownMenuItem<String>(
                      value: location.locationId,
                      child: Text(location.label),
                    ),
                ],
                onChanged: (value) => setState(() => _locationId = value),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('team_role_change_submit_button'),
          onPressed: canSubmit
              ? () {
                  Navigator.of(context).pop(
                    _RoleGrantDraft(
                      roleId: _roleId!,
                      scopeType: _scope == TeamInviteScope.operatorWide
                          ? 'operator_wide'
                          : 'location',
                      locationId: _scope == TeamInviteScope.location
                          ? _locationId
                          : null,
                    ),
                  );
                }
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

class _TeamInvitePanel extends StatelessWidget {
  const _TeamInvitePanel({
    required this.controller,
    required this.emailController,
    required this.roleOptions,
    required this.locationOptions,
    required this.enabled,
    required this.submitEnabled,
    required this.submitting,
    required this.initiallyExpanded,
    required this.onSubmit,
  });

  final TeamInviteFormController controller;
  final TextEditingController emailController;
  final List<TeamRoleOption> roleOptions;
  final List<TeamLocationOption> locationOptions;
  final bool enabled;
  final bool submitEnabled;
  final bool submitting;
  final bool initiallyExpanded;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final violations = controller.validate();
    final showLocation = controller.scope == TeamInviteScope.location;
    return Container(
      key: const Key('team_invite_panel'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 320.0;
          final stacked = maxWidth < 520;
          double fieldWidth(double preferred) =>
              stacked ? maxWidth : preferred.clamp(160.0, maxWidth).toDouble();
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: fieldWidth(260),
                child: TextField(
                  key: const Key('team_invite_email_field'),
                  controller: emailController,
                  enabled: enabled,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: _emailError(violations),
                  ),
                  onChanged: controller.setEmail,
                ),
              ),
              SizedBox(
                width: fieldWidth(200),
                child: DropdownButtonFormField<String>(
                  key: const Key('team_invite_role_dropdown'),
                  initialValue: controller.roleId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Role',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText:
                        violations.contains(TeamInviteViolation.roleMissing)
                        ? 'Required'
                        : null,
                  ),
                  items: [
                    for (final role in roleOptions)
                      DropdownMenuItem<String>(
                        value: role.roleId,
                        child: Text(role.label),
                      ),
                  ],
                  onChanged: enabled ? controller.setRoleId : null,
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: SegmentedButton<TeamInviteScope>(
                  key: const Key('team_invite_scope_segmented'),
                  segments: const [
                    ButtonSegment<TeamInviteScope>(
                      value: TeamInviteScope.operatorWide,
                      icon: Icon(Icons.apartment, size: 16),
                      label: Text('Operator'),
                    ),
                    ButtonSegment<TeamInviteScope>(
                      value: TeamInviteScope.location,
                      icon: Icon(Icons.place_outlined, size: 16),
                      label: Text('Location'),
                    ),
                  ],
                  selected: {if (controller.scope != null) controller.scope!},
                  emptySelectionAllowed: true,
                  onSelectionChanged: enabled
                      ? (selection) {
                          controller.setScope(
                            selection.isEmpty ? null : selection.first,
                          );
                        }
                      : null,
                ),
              ),
              if (showLocation)
                SizedBox(
                  width: fieldWidth(210),
                  child: DropdownButtonFormField<String>(
                    key: const Key('team_invite_location_dropdown'),
                    initialValue: controller.locationId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Location',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText:
                          violations.contains(
                            TeamInviteViolation.locationMissingForLocationScope,
                          )
                          ? 'Required'
                          : null,
                    ),
                    items: [
                      for (final location in locationOptions)
                        DropdownMenuItem<String>(
                          value: location.locationId,
                          child: Text(location.label),
                        ),
                    ],
                    onChanged: enabled ? controller.setLocationId : null,
                  ),
                ),
              FilledButton.icon(
                key: const Key('team_invite_submit_button'),
                icon: submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined, size: 18),
                label: const Text('Send invite'),
                onPressed: submitEnabled ? onSubmit : null,
              ),
            ],
          );
        },
      ),
    );
  }

  String? _emailError(Set<TeamInviteViolation> violations) {
    if (violations.contains(TeamInviteViolation.emailMissing)) {
      return 'Required';
    }
    if (violations.contains(TeamInviteViolation.emailMalformed)) {
      return 'Invalid';
    }
    return null;
  }
}
