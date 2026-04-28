import 'package:flutter/material.dart';

import '../../services/team/team_invite_form_controller.dart';
import '../../services/team/team_scope_visibility_policy.dart';
import '../../services/team/team_users_list_controller.dart';
import '../../theme/app_theme.dart';

typedef TeamInviteSubmitter = Future<void> Function(
  Map<String, Object?> payload,
);

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
}

class TeamSettingsSection extends StatefulWidget {
  const TeamSettingsSection({
    super.key,
    required this.actor,
    this.users = const <TeamUserListItem>[],
    this.roleOptions = defaultRoleOptions,
    this.locationOptions = const <TeamLocationOption>[],
    this.usersController,
    this.inviteFormController,
    this.onInviteSubmitted,
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
  final TeamUsersListController? usersController;
  final TeamInviteFormController? inviteFormController;
  final TeamInviteSubmitter? onInviteSubmitted;

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
    return widget.users.where((user) {
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
    }).toList(growable: false);
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

  Future<void> _submitInvite() async {
    if (!_canInvite ||
        widget.onInviteSubmitted == null ||
        !_inviteController.isReadyToSubmit) {
      return;
    }
    setState(() => _submittingInvite = true);
    try {
      await widget.onInviteSubmitted!(_inviteController.toRequestPayload());
      _inviteController.reset();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invite submitted')),
        );
      }
    } finally {
      if (mounted) setState(() => _submittingInvite = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = _visibleUsers;
    return Container(
      key: const Key('team_settings_section'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 720;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TeamSummaryStrip(
                visibleCount: users.length,
                totalCount: widget.users.length,
                canInvite: _canInvite,
              ),
              const SizedBox(height: 16),
              _TeamFilters(
                controller: _usersController,
                searchController: _searchController,
                roleOptions: widget.roleOptions,
                locationOptions: widget.locationOptions,
                narrow: narrow,
              ),
              const SizedBox(height: 14),
              _TeamUsersTable(users: users),
              const SizedBox(height: 16),
              _TeamInvitePanel(
                controller: _inviteController,
                emailController: _emailController,
                roleOptions: widget.roleOptions,
                locationOptions: widget.locationOptions,
                enabled: _canInvite,
                submitEnabled: _canInvite &&
                    !_submittingInvite &&
                    widget.onInviteSubmitted != null &&
                    _inviteController.isReadyToSubmit,
                submitting: _submittingInvite,
                onSubmit: _submitInvite,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TeamSummaryStrip extends StatelessWidget {
  const _TeamSummaryStrip({
    required this.visibleCount,
    required this.totalCount,
    required this.canInvite,
  });

  final int visibleCount;
  final int totalCount;
  final bool canInvite;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _TeamMetricChip(
          icon: Icons.group_outlined,
          label: 'VISIBLE',
          value: '$visibleCount / $totalCount',
        ),
        _TeamMetricChip(
          icon: canInvite ? Icons.person_add_alt_1 : Icons.lock_outline,
          label: 'INVITES',
          value: canInvite ? 'AVAILABLE' : 'LOCKED',
        ),
      ],
    );
  }
}

class _TeamMetricChip extends StatelessWidget {
  const _TeamMetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: AppColors.peacockDark),
          const SizedBox(width: 8),
          Text(label, style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(width: 8),
          Text(
            value,
            style: AppTextStyles.mono12(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
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
      IconButton.filledTonal(
        key: const Key('team_clear_filters_button'),
        tooltip: 'Clear filters',
        icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
        onPressed: controller.filter.hasAnyFilter ? controller.clearFilter : null,
      ),
    ];
    return Wrap(spacing: 10, runSpacing: 10, children: fields);
  }
}

class _TeamUsersTable extends StatelessWidget {
  const _TeamUsersTable({required this.users});

  final List<TeamUserListItem> users;

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
            const Icon(Icons.group_off_outlined, size: 20),
            const SizedBox(width: 10),
            Text('No team members', style: AppTextStyles.body14()),
          ],
        ),
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
              _TeamUserRow(key: Key('team_user_row_$i'), user: users[i]),
          ],
        ),
      ),
    );
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
          Expanded(
            flex: 4,
            child: Text('USER', style: AppTextStyles.mono10()),
          ),
          Expanded(
            flex: 2,
            child: Text('ROLE', style: AppTextStyles.mono10()),
          ),
          Expanded(
            flex: 2,
            child: Text('SCOPE', style: AppTextStyles.mono10()),
          ),
          Expanded(
            flex: 2,
            child: Text('STATUS', style: AppTextStyles.mono10()),
          ),
        ],
      ),
    );
  }
}

class _TeamUserRow extends StatelessWidget {
  const _TeamUserRow({super.key, required this.user});

  final TeamUserListItem user;

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
          Expanded(flex: 2, child: Text(user.roleLabel)),
          Expanded(
            flex: 2,
            child: Text(user.locationLabel ?? 'Operator-wide'),
          ),
          Expanded(
            flex: 2,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StatusPill(status: user.status),
                if (user.mfaEnrolled)
                  const _MiniPill(label: '2FA', icon: Icons.verified_user),
              ],
            ),
          ),
        ],
      ),
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
  const _MiniPill({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.peacockDark),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.mono10(color: AppColors.peacockDark)),
        ],
      ),
    );
  }
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
    required this.onSubmit,
  });

  final TeamInviteFormController controller;
  final TextEditingController emailController;
  final List<TeamRoleOption> roleOptions;
  final List<TeamLocationOption> locationOptions;
  final bool enabled;
  final bool submitEnabled;
  final bool submitting;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final violations = controller.validate();
    final showLocation = controller.scope == TeamInviteScope.location;
    return Container(
      key: const Key('team_invite_panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_add_alt_1, size: 20),
              const SizedBox(width: 8),
              Text('Invite', style: AppTextStyles.display16()),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
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
                width: 200,
                child: DropdownButtonFormField<String>(
                  key: const Key('team_invite_role_dropdown'),
                  initialValue: controller.roleId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Role',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: violations.contains(
                      TeamInviteViolation.roleMissing,
                    )
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
              SegmentedButton<TeamInviteScope>(
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
                selected: {
                  if (controller.scope != null) controller.scope!,
                },
                emptySelectionAllowed: true,
                onSelectionChanged: enabled
                    ? (selection) {
                        controller.setScope(
                          selection.isEmpty ? null : selection.first,
                        );
                      }
                    : null,
              ),
              if (showLocation)
                SizedBox(
                  width: 210,
                  child: DropdownButtonFormField<String>(
                    key: const Key('team_invite_location_dropdown'),
                    initialValue: controller.locationId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Location',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: violations.contains(
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
                label: const Text('Send'),
                onPressed: submitEnabled ? onSubmit : null,
              ),
            ],
          ),
        ],
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
