// Phase 11A.13 - F&F Operations Console "Roles + permissions"
// inspect surface.
//
// Cross-operator inspect for the F&F admin to inspect and audit-edit
// the picked operator's role catalog. Active sessions now live under
// Security/audit/sessions; the reusable panel remains in this file
// because it shares the roles/hierarchy/sessions gateway contract.
//
// Mounts in the admin shell at `/admin/roles-hierarchy-sessions`.
// The shell passes the shared Operations operator context when one
// exists; the picker is only opened when the admin needs to choose
// or change operator.
//
// Authority: docs/contracts/team_roles_hierarchy_console_parity_contract.md
// "§ Roles + Permission Explainer (11W.2 + 11A.13 Roles tab)" +
// "§ Sessions (11W.4 + 11A.13 Sessions tab)" +
// "§ Operator self-service vs F&F admin path" +
// "§ Idempotency keys" + "§ Audit-row shape".

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../auth/permission_key_metadata.dart';
import '../../auth/permission_keys.dart';
import '../../services/auth/custom_role_validator.dart';
import '../../services/auth/role_key_generator.dart';
import '../../theme/app_theme.dart';
import '../../widgets/role_permission_picker.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import '../widgets/admin_responsive_layout.dart';
import '../widgets/admin_role_warning_panel.dart';
import 'operator_picker_screen.dart';

class RolesHierarchySessionsAdminScreen extends StatefulWidget {
  const RolesHierarchySessionsAdminScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    required this.pickedOperator,
    this.editingEnabled = true,
    this.canEditSeededRoles = false,
    this.idempotencyKeyFactory,
    this.onChangeOperator,
    this.onBackToBusinessAccounts,
    this.initialScope,
  });

  final RolesHierarchySessionsAdminGateway gateway;
  final String actorUserId;
  final OperatorPickerResult pickedOperator;

  /// Mirrors the 11A.12 Members pattern: when false, every mutate
  /// affordance is hidden. The gateway also throws
  /// [RolesHierarchySessionsForbiddenException] if a non-forge-admin
  /// call reaches the seam, so this is the user-facing layer of a
  /// two-layer defence.
  final bool editingEnabled;

  /// Per the parity contract § "Seeded roles" line 104: edit on
  /// seeded roles is gated on `admin.roles.edit_seeded` (MFA-required).
  /// This flag is the screen-level mirror; production wires it from
  /// the signed-in admin's MFA-required claims, demo defaults false.
  final bool canEditSeededRoles;

  final String Function()? idempotencyKeyFactory;

  /// Re-opens the operator picker. Wired by the route shell so the
  /// admin can switch operators without leaving the surface.
  final VoidCallback? onChangeOperator;
  final VoidCallback? onBackToBusinessAccounts;
  final AdminHierarchyScopeIntent? initialScope;

  @override
  State<RolesHierarchySessionsAdminScreen> createState() =>
      _RolesHierarchySessionsAdminScreenState();
}

class _RolesHierarchySessionsAdminScreenState
    extends State<RolesHierarchySessionsAdminScreen> {
  bool _rolesLoading = true;
  String? _rolesLoadError;
  String? _actionError;

  List<RoleAdminRow> _roles = const <RoleAdminRow>[];
  int _rolesGeneration = 0;

  int _idempotencyCounter = 0;

  String _nextIdempotencyKey(String operation) {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return '$operation-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  @override
  void initState() {
    super.initState();
    _refreshRoles();
  }

  Future<void> _refreshRoles() async {
    final generation = ++_rolesGeneration;
    setState(() {
      _rolesLoading = true;
      _rolesLoadError = null;
    });
    try {
      final operatorId = widget.pickedOperator.operatorId;
      final roles = await widget.gateway.listRoles(operatorId: operatorId);
      if (generation != _rolesGeneration) return;
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _rolesLoading = false;
      });
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _rolesLoadError = error.message;
        _rolesLoading = false;
      });
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _rolesLoadError = error.message;
        _rolesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rolesLoadError = 'Could not load roles: $error';
        _rolesLoading = false;
      });
    }
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    required Future<void> Function() refresh,
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  Future<String?> _promptAdminReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _AdminReasonDialog(title: title),
    );
  }

  // --- Roles tab actions -------------------------------------------------

  Future<void> _onCreateCustomRole() async {
    final scope =
        widget.initialScope ?? _scopeFromPickedOperator(widget.pickedOperator);
    final result = await showDialog<CustomRoleDraft>(
      context: context,
      builder: (_) => CreateCustomRoleDialog(
        existingRoleKeys: <String>{for (final r in _roles) r.roleKey},
        roleScope: _roleScopeFromAdminScope(scope.scopeType),
      ),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.createCustomRole(
        operatorId: widget.pickedOperator.operatorId,
        roleKey: result.roleKey,
        displayName: result.displayName,
        description: result.description,
        permissionKeys: result.permissionKeys,
        idempotencyKey: _nextIdempotencyKey('roles-create-custom'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      ),
      refresh: _refreshRoles,
      successHint: 'Created ${result.displayName}',
    );
  }

  Future<void> _onEditCustomRole(RoleAdminRow row) async {
    final scope =
        widget.initialScope ?? _scopeFromPickedOperator(widget.pickedOperator);
    final result = await showDialog<CustomRoleDraft>(
      context: context,
      builder: (_) => CreateCustomRoleDialog(
        existingRoleKeys: <String>{
          for (final r in _roles)
            if (r.roleId != row.roleId) r.roleKey,
        },
        existing: row,
        roleScope: _roleScopeFromAdminScope(scope.scopeType),
      ),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.updateCustomRole(
        operatorId: widget.pickedOperator.operatorId,
        roleId: row.roleId,
        displayName: result.displayName,
        description: result.description,
        previousPermissionKeys: row.permissionKeys,
        permissionKeys: result.permissionKeys,
        idempotencyKey: _nextIdempotencyKey('roles-update-custom'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      ),
      refresh: _refreshRoles,
      successHint: 'Updated ${result.displayName}',
    );
  }

  Future<void> _onDeleteCustomRole(RoleAdminRow row) async {
    final confirmed = await showOperatorWebDialog<bool>(
      context: context,
      title: 'Delete role',
      icon: Icons.delete_outline,
      child: Text(
        'Delete "${roleAdminDisplayLabel(row)}"? Members holding this role '
        'will lose its permissions on their next sign-in. Revoke the role '
        'from every member first if you have not already.',
        style: AppTextStyles.body13(color: AppColors.textPrimary),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_rhs_delete_role_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_delete_role_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.negative,
            foregroundColor: AppColors.backgroundSurface,
          ),
          child: const Text('Delete'),
        ),
      ],
    );
    if (confirmed != true) return;
    final reason = await _promptAdminReason(
      'Delete ${roleAdminDisplayLabel(row)}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.deleteCustomRole(
        operatorId: widget.pickedOperator.operatorId,
        roleId: row.roleId,
        idempotencyKey: _nextIdempotencyKey('roles-delete-custom'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      refresh: _refreshRoles,
      successHint: 'Deleted ${roleAdminDisplayLabel(row)}',
    );
  }

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const Key('admin_roles_hierarchy_sessions_screen'),
      color: AppColors.backgroundDeep,
      child: OperatorWebScreenBody(
        scrollKey: const Key('admin_rhs_roles_screen'),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OperatorWebScreenHeader(
              icon: Icons.shield_outlined,
              title: 'Roles & permissions',
              actions: _buildHeaderActions(),
            ),
            const SizedBox(height: 12),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(key: Key('admin_rhs_readonly_banner')),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_rhs_action_error'),
                message: _actionError!,
              ),
            _buildBody(),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildHeaderActions() {
    final children = <Widget>[
      SizedBox(
        height: 38,
        child: FilledButton.icon(
          key: const Key('admin_rhs_roles_new_role'),
          onPressed: widget.editingEnabled ? _onCreateCustomRole : null,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
            disabledBackgroundColor: AppColors.borderSubtle,
            disabledForegroundColor: AppColors.textMuted,
          ),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('New role'),
        ),
      ),
      if (widget.onBackToBusinessAccounts != null)
        AdminBusinessAccountsBackButton(
          onPressed: widget.onBackToBusinessAccounts,
        ),
    ];
    if (widget.onChangeOperator != null) {
      children.add(
        OutlinedButton.icon(
          key: const Key('admin_rhs_change_operator'),
          onPressed: widget.onChangeOperator,
          style: AdminButtonStyles.secondary(),
          icon: const Icon(Icons.swap_horiz, size: 16),
          label: const Text('Change operator'),
        ),
      );
    }
    return children;
  }

  Widget _buildBody() {
    return _TabLoadBody(
      loading: _rolesLoading,
      error: _rolesLoadError,
      loadingKey: const Key('admin_rhs_loading'),
      errorKey: const Key('admin_rhs_load_error'),
      child: RolePolicyAdminPanel(
        roles: _roles,
        editingEnabled: widget.editingEnabled,
        onEditCustom: _onEditCustomRole,
        onCreateCustom: _onCreateCustomRole,
        onDeleteCustom: _onDeleteCustomRole,
      ),
    );
  }
}

class _TabLoadBody extends StatelessWidget {
  const _TabLoadBody({
    required this.loading,
    required this.error,
    required this.loadingKey,
    required this.errorKey,
    required this.child,
  });

  final bool loading;
  final String? error;
  final Key loadingKey;
  final Key errorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        key: loadingKey,
        child: const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (error != null) {
      return _ErrorBanner(key: errorKey, message: error!);
    }
    return child;
  }
}

AdminHierarchyScopeIntent _scopeFromPickedOperator(
  OperatorPickerResult picked,
) {
  if (picked.locationId.trim().isEmpty) {
    return AdminHierarchyScopeIntent.business(
      operatorId: picked.operatorId,
      operatorName: picked.operatorBusinessName,
    );
  }
  return AdminHierarchyScopeIntent.location(
    operatorId: picked.operatorId,
    locationId: picked.locationId,
    operatorName: picked.operatorBusinessName,
    locationName: picked.locationName,
    valueState: AdminHierarchyScopeValueState.locationOnly,
  );
}

/// Map the admin shell's working hierarchy scope onto the shared
/// [RoleScope] the [CustomRoleValidator] understands, so the admin
/// custom-role editor surfaces the same coherence warnings as the
/// operator-web editor (W4 parity). The two enums mirror each other
/// one-for-one (business / org unit / location).
RoleScope _roleScopeFromAdminScope(AdminHierarchyScopeType type) {
  switch (type) {
    case AdminHierarchyScopeType.business:
      return RoleScope.business;
    case AdminHierarchyScopeType.orgUnit:
      return RoleScope.orgUnit;
    case AdminHierarchyScopeType.location:
      return RoleScope.location;
  }
}

// ---------------------------------------------------------------------
// Roles tab
// ---------------------------------------------------------------------

class RolePolicyAdminPanel extends StatelessWidget {
  const RolePolicyAdminPanel({
    super.key,
    required this.roles,
    required this.editingEnabled,
    required this.onEditCustom,
    required this.onCreateCustom,
    required this.onDeleteCustom,
  });

  final List<RoleAdminRow> roles;
  final bool editingEnabled;
  final ValueChanged<RoleAdminRow> onEditCustom;
  final VoidCallback onCreateCustom;
  final ValueChanged<RoleAdminRow> onDeleteCustom;

  @override
  Widget build(BuildContext context) {
    final seeded = roles.where((r) => r.isSeeded).toList(growable: true)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final custom = roles.where((r) => !r.isSeeded).toList(growable: true)
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return Column(
      key: const Key('admin_rhs_roles_tab'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (custom.isEmpty)
          _EmptyCustomRolesPanel(
            canWrite: editingEnabled,
            onCreateRole: onCreateCustom,
          )
        else
          _RoleGroup(
            key: const Key('admin_rhs_roles_custom_group'),
            title: 'Custom roles (${custom.length})',
            subtitle:
                'Roles you have built for this operator. Edit or delete '
                'them as your team changes.',
            roles: custom,
            canWrite: editingEnabled,
            onEditCustom: onEditCustom,
            onDelete: onDeleteCustom,
          ),
        const SizedBox(height: 18),
        _RoleGroup(
          key: const Key('admin_rhs_roles_seeded_group'),
          title: 'Default roles (${seeded.length})',
          roles: seeded,
          canWrite: false,
          onEditCustom: onEditCustom,
          onDelete: onDeleteCustom,
        ),
      ],
    );
  }
}

class _RoleGroup extends StatelessWidget {
  const _RoleGroup({
    super.key,
    required this.title,
    this.subtitle,
    required this.roles,
    required this.canWrite,
    required this.onEditCustom,
    required this.onDelete,
  });

  final String title;
  final String? subtitle;
  final List<RoleAdminRow> roles;
  final bool canWrite;
  final ValueChanged<RoleAdminRow> onEditCustom;
  final ValueChanged<RoleAdminRow> onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitleText = subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        OperatorWebSectionHeading(
          title: title,
          trailing: subtitleText == null
              ? null
              : OperatorWebInfoButton(
                  title: title,
                  tooltip: title,
                  body: Text(
                    subtitleText,
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ),
        ),
        const SizedBox(height: 10),
        for (final role in roles)
          _RoleRowTile(
            key: Key('admin_rhs_role_row_${role.roleId}'),
            row: role,
            canWrite: canWrite,
            onEditCustom: onEditCustom,
            onDelete: onDelete,
          ),
      ],
    );
  }
}

class _RoleRowTile extends StatelessWidget {
  const _RoleRowTile({
    super.key,
    required this.row,
    required this.canWrite,
    required this.onEditCustom,
    required this.onDelete,
  });

  final RoleAdminRow row;
  final bool canWrite;
  final ValueChanged<RoleAdminRow> onEditCustom;
  final ValueChanged<RoleAdminRow> onDelete;

  @override
  Widget build(BuildContext context) {
    final mutable = canWrite && !row.isSeeded;
    final shortDescription = _shortRoleDescription(row.description);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  roleAdminDisplayLabel(row),
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                if (shortDescription.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    shortDescription,
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          if (mutable) ...<Widget>[
            TextButton(
              key: Key('admin_rhs_role_edit_${row.roleId}'),
              onPressed: () => onEditCustom(row),
              child: const Text('Edit'),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: Key('admin_rhs_role_delete_${row.roleId}'),
              onPressed: () => onDelete(row),
              style: TextButton.styleFrom(foregroundColor: AppColors.negative),
              child: const Text('Delete'),
            ),
          ],
        ],
      ),
    );
  }
}

@visibleForTesting
String adminShortRoleDescriptionForTest(String description) {
  return _shortRoleDescription(description);
}

String _shortRoleDescription(String description) {
  final trimmed = description.trim();
  if (trimmed.isEmpty) return '';
  final match = RegExp(r'([.!?])(\s|$)').firstMatch(trimmed);
  if (match == null) return trimmed;
  return trimmed.substring(0, match.end).trim();
}

class _EmptyCustomRolesPanel extends StatelessWidget {
  const _EmptyCustomRolesPanel({
    required this.canWrite,
    required this.onCreateRole,
  });

  final bool canWrite;
  final VoidCallback onCreateRole;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_rhs_roles_empty_custom'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Create custom role',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          if (canWrite) ...<Widget>[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('admin_rhs_roles_empty_create'),
                onPressed: onCreateRole,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sunset,
                  foregroundColor: AppColors.backgroundSurface,
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New custom role'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

List<String> _orderedSelectedPermissionKeys(Set<String> selected) {
  final ordered = PermissionKeys.all
      .where(selected.contains)
      .toList(growable: true);
  final unknown =
      selected
          .where((key) => !PermissionKeys.all.contains(key))
          .toList(growable: false)
        ..sort();
  ordered.addAll(unknown);
  return ordered;
}

// ---------------------------------------------------------------------
// Sessions tab
// ---------------------------------------------------------------------

class ActiveSessionsAdminPanel extends StatefulWidget {
  const ActiveSessionsAdminPanel({
    super.key,
    required this.gateway,
    required this.operatorId,
    required this.operatorName,
    required this.actorUserId,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
  });

  final RolesHierarchySessionsAdminGateway gateway;
  final String operatorId;
  final String operatorName;
  final String actorUserId;
  final bool editingEnabled;
  final String Function()? idempotencyKeyFactory;

  @override
  State<ActiveSessionsAdminPanel> createState() =>
      _ActiveSessionsAdminPanelState();
}

class _ActiveSessionsAdminPanelState extends State<ActiveSessionsAdminPanel> {
  bool _loading = true;
  String? _loadError;
  String? _actionError;
  List<SessionAdminRow> _sessions = const <SessionAdminRow>[];
  int _refreshGeneration = 0;
  int _idempotencyCounter = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ActiveSessionsAdminPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operatorId != widget.operatorId ||
        oldWidget.gateway != widget.gateway) {
      _refresh();
    }
  }

  String _nextIdempotencyKey(String operation) {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return '$operation-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final sessions = await widget.gateway.listSessions(
        operatorId: widget.operatorId,
      );
      if (generation != _refreshGeneration) return;
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load sessions: $error';
        _loading = false;
      });
    }
  }

  Future<String?> _promptAdminReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _AdminReasonDialog(title: title),
    );
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  Future<void> _onForceLogoutSession(SessionAdminRow row) async {
    if (row.userId == widget.actorUserId) {
      setState(() {
        _actionError = SessionsValidationCopy.cannotRevokeSelf;
      });
      return;
    }
    final reason = await _promptAdminReason(
      'Sign out ${row.userDisplayName} from this device',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.forceLogoutSession(
        operatorId: widget.operatorId,
        sessionId: row.sessionId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('sessions-force-logout'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Signed out ${row.userDisplayName} from that device.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('admin_security_sessions_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_actionError != null)
          _ErrorBanner(
            key: const Key('admin_security_sessions_action_error'),
            message: _actionError!,
          ),
        _TabLoadBody(
          loading: _loading,
          error: _loadError,
          loadingKey: const Key('admin_security_sessions_loading'),
          errorKey: const Key('admin_security_sessions_load_error'),
          child: _SessionsTab(
            sessions: _sessions,
            operatorName: widget.operatorName,
            editingEnabled: widget.editingEnabled,
            actorUserId: widget.actorUserId,
            onForceLogout: _onForceLogoutSession,
          ),
        ),
      ],
    );
  }
}

class _SessionsTab extends StatelessWidget {
  const _SessionsTab({
    required this.sessions,
    required this.operatorName,
    required this.editingEnabled,
    required this.actorUserId,
    required this.onForceLogout,
  });

  final List<SessionAdminRow> sessions;
  final String operatorName;
  final bool editingEnabled;
  final String actorUserId;
  final ValueChanged<SessionAdminRow> onForceLogout;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('admin_rhs_sessions_tab'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OperatorWebPanel(
            title: 'People and devices signed in',
            trailing: Text(
              '${sessions.length} session'
              '${sessions.length == 1 ? '' : 's'}',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '$operatorName has ${_peopleCount(sessions)} signed-in '
                  '${_peopleCount(sessions) == 1 ? 'person' : 'people'} '
                  'across ${sessions.length} active '
                  '${sessions.length == 1 ? 'device' : 'devices'}. '
                  'Signing out a device is audit-logged; this surface cannot '
                  'sign out the admin device you are using.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                if (sessions.isEmpty)
                  Text(
                    'No active sessions.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  )
                else
                  for (final row in sessions)
                    _SessionRowTile(
                      key: Key('admin_rhs_session_row_${row.sessionId}'),
                      row: row,
                      isOwn: row.userId == actorUserId,
                      editingEnabled: editingEnabled,
                      onForceLogout: onForceLogout,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static int _peopleCount(List<SessionAdminRow> sessions) {
    return sessions.map((row) => row.userId).toSet().length;
  }
}

class _SessionRowTile extends StatelessWidget {
  const _SessionRowTile({
    super.key,
    required this.row,
    required this.isOwn,
    required this.editingEnabled,
    required this.onForceLogout,
  });

  final SessionAdminRow row;
  final bool isOwn;
  final bool editingEnabled;
  final ValueChanged<SessionAdminRow> onForceLogout;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    "${row.userDisplayName}'s device",
                    style: AppTextStyles.body14(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (isOwn)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSurface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppColors.borderSubtle,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'This admin device',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${row.userDisplayName} (${row.userEmail})',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _SessionFact(
                  icon: Icons.devices_outlined,
                  label: 'Device',
                  value: row.deviceFingerprint,
                ),
                _SessionFact(
                  icon: Icons.location_city_outlined,
                  label: 'Place',
                  value: row.ipGeoCity,
                ),
                _SessionFact(
                  icon: Icons.schedule_outlined,
                  label: 'Last active',
                  value: _formatRelative(row.lastActiveAt),
                ),
              ],
            ),
            if (editingEnabled) ...<Widget>[
              const SizedBox(height: 10),
              OutlinedButton(
                key: Key('admin_rhs_session_force_logout_${row.sessionId}'),
                onPressed: isOwn ? null : () => onForceLogout(row),
                style: AdminButtonStyles.secondary(),
                child: const Text('Sign out device'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatRelative(DateTime at) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(at.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

// ---------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------

class _SessionFact extends StatelessWidget {
  const _SessionFact({
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
          Text(
            value,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View only. Ask a super admin if a setting needs to change.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
  }
}

class _AdminReasonDialog extends StatefulWidget {
  const _AdminReasonDialog({required this.title});

  final String title;

  @override
  State<_AdminReasonDialog> createState() => _AdminReasonDialogState();
}

class _AdminReasonDialogState extends State<_AdminReasonDialog> {
  final _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_rhs_reason_dialog'),
      title: widget.title,
      icon: Icons.edit_note_outlined,
      maxWidth: 520,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_rhs_reason_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_reason_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Confirm'),
        ),
      ],
      child: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'The operator will see this reason in their audit log. '
              'Write a short, plain-English note about why you are '
              'making this change.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_reason_field'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _violated ? 'Add a reason before continuing.' : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Roles tab dialogs
// ---------------------------------------------------------------------

class CustomRoleDraft {
  const CustomRoleDraft({
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.permissionKeys,
    required this.adminReason,
  });

  final String roleKey;
  final String displayName;
  final String description;
  final List<String> permissionKeys;
  final String adminReason;
}

class CreateCustomRoleDialog extends StatefulWidget {
  const CreateCustomRoleDialog({
    super.key,
    required this.existingRoleKeys,
    this.existing,
    this.roleScope = RoleScope.business,
    this.validator = const CustomRoleValidator(),
  });

  final Set<String> existingRoleKeys;
  final RoleAdminRow? existing;

  /// Working hierarchy scope this role is being authored at, so the
  /// validator's location-scope warnings fire as on operator-web.
  final RoleScope roleScope;

  /// Advisory validator for the inline coherence warnings. Override in
  /// tests to pin a warning set without seeding keys (as operator-web).
  final CustomRoleValidator validator;

  @override
  State<CreateCustomRoleDialog> createState() => _CreateCustomRoleDialogState();
}

class _CreateCustomRoleDialogState extends State<CreateCustomRoleDialog> {
  final _displayNameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _reasonController = TextEditingController();
  final Set<String> _explicitPermissionKeys = <String>{};
  String? _displayNameError;
  String? _permissionsError;
  String? _reasonError;

  bool get _isCreate => widget.existing == null;

  Set<String> get _selectedPermissionKeys =>
      PermissionKeyMetadataCatalog.expandImplies(_explicitPermissionKeys);

  bool get _canSubmit =>
      _displayNameController.text.trim().isNotEmpty &&
      _selectedPermissionKeys.isNotEmpty &&
      _reasonController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _displayNameController.text = roleAdminDisplayLabel(existing);
      _descriptionController.text = existing.description;
      _explicitPermissionKeys.addAll(existing.permissionKeys);
    }
    _displayNameController.addListener(_onFieldChanged);
    _reasonController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _displayNameController.removeListener(_onFieldChanged);
    _reasonController.removeListener(_onFieldChanged);
    _displayNameController.dispose();
    _descriptionController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final displayName = _displayNameController.text.trim();
    final roleKey =
        widget.existing?.roleKey ??
        generateRoleKeyFromDisplayName(
          displayName,
          existingKeys: widget.existingRoleKeys,
        );
    final reason = _reasonController.text.trim();
    final effectivePermissions = _selectedPermissionKeys;
    setState(() {
      _displayNameError = displayName.isEmpty ? 'Role name is required.' : null;
      _permissionsError = effectivePermissions.isEmpty
          ? 'Pick at least one permission for this role.'
          : null;
      _reasonError = reason.isEmpty ? 'Add a reason before continuing.' : null;
    });
    if (_displayNameError != null ||
        _permissionsError != null ||
        _reasonError != null) {
      return;
    }
    Navigator.of(context).pop(
      CustomRoleDraft(
        roleKey: roleKey,
        displayName: displayName,
        description: _descriptionController.text.trim(),
        permissionKeys: _orderedSelectedPermissionKeys(effectivePermissions),
        adminReason: reason,
      ),
    );
  }

  void _togglePermission(String permissionKey, bool selected) {
    setState(() {
      if (selected) {
        _explicitPermissionKeys.add(permissionKey);
      } else {
        _explicitPermissionKeys.remove(permissionKey);
      }
      _permissionsError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_rhs_create_custom_role_dialog'),
      title: _isCreate ? 'New custom role' : 'Edit role',
      icon: Icons.person_add_alt_outlined,
      maxWidth: 780,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_create_custom_role_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _canSubmit ? _onSubmit : null,
          child: Text(_isCreate ? 'Create role' : 'Save changes'),
        ),
      ],
      child: SizedBox(
        width: 720,
        height: 760,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _AdminRoleEditorScopePanel(
              scopeLabel: _adminRoleScopeLabel(widget.roleScope),
              roleScope: widget.roleScope,
            ),
            const SizedBox(height: 16),
            _AdminRoleDetailsCard(
              displayNameController: _displayNameController,
              descriptionController: _descriptionController,
              displayNameError: _displayNameError,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: RolePermissionPickerCard(
                  key: const Key('admin_rhs_custom_role_editor_permissions'),
                  header: const OperatorWebSectionHeading(title: 'Permissions'),
                  selected: _selectedPermissionKeys,
                  explicit: _explicitPermissionKeys,
                  readOnly: false,
                  barrioPlanIncluded: true,
                  roleScope: widget.roleScope,
                  onToggle: _togglePermission,
                  keyPrefix: 'admin_rhs_custom_role_editor',
                ),
              ),
            ),
            if (_permissionsError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _permissionsError!,
                key: const Key(
                  'admin_rhs_create_custom_role_permissions_error',
                ),
                style: AppTextStyles.body12(color: AppColors.negative),
              ),
            ],
            AdminRoleWarningPanel(
              permissionKeys: _selectedPermissionKeys,
              scope: widget.roleScope,
              roleDisplayName: _displayNameController.text,
              validator: widget.validator,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_rhs_create_custom_role_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _reasonError,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${_selectedPermissionKeys.length} '
                "${_selectedPermissionKeys.length == 1 ? 'permission' : 'permissions'} "
                'selected',
                key: const Key('admin_rhs_custom_role_editor_count'),
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminRoleEditorScopePanel extends StatelessWidget {
  const _AdminRoleEditorScopePanel({
    required this.scopeLabel,
    required this.roleScope,
  });

  final String scopeLabel;
  final RoleScope roleScope;

  @override
  Widget build(BuildContext context) {
    final limited = roleScope != RoleScope.business;
    return Container(
      key: const Key('admin_rhs_custom_role_editor_scope_context'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.account_tree_outlined, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Scope: $scopeLabel',
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  limited
                      ? 'Business-wide permissions are hidden here. Assign '
                            'this role from Team members to keep access scoped.'
                      : 'All permissions are available here. Assign this role '
                            'from Team members when choosing who receives it.',
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminRoleDetailsCard extends StatelessWidget {
  const _AdminRoleDetailsCard({
    required this.displayNameController,
    required this.descriptionController,
    required this.displayNameError,
  });

  final TextEditingController displayNameController;
  final TextEditingController descriptionController;
  final String? displayNameError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          OperatorWebSectionHeading(
            title: 'Role details',
            trailing: OperatorWebInfoButton(
              title: 'Role details',
              tooltip: 'Role details',
              body: Text(
                'Pick a name and short description so your team knows what '
                'this role is for. Names show on Team members.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('admin_rhs_create_custom_role_name'),
            controller: displayNameController,
            decoration: InputDecoration(
              labelText: 'Role name',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: displayNameError,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('admin_rhs_create_custom_role_description'),
            controller: descriptionController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Description',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}

String _adminRoleScopeLabel(RoleScope scope) {
  switch (scope) {
    case RoleScope.business:
      return 'Business';
    case RoleScope.orgUnit:
      return 'Org unit';
    case RoleScope.location:
      return 'Location';
  }
}

// Hierarchy tab dialogs
// ---------------------------------------------------------------------

class _AddOrgUnitResult {
  const _AddOrgUnitResult({
    required this.unitType,
    required this.label,
    required this.name,
    required this.adminReason,
  });

  final String unitType;
  final String label;
  final String name;
  final String adminReason;
}

class _AddChildOrgUnitDialog extends StatefulWidget {
  const _AddChildOrgUnitDialog({
    required this.parent,
    required this.existingNames,
    required this.parentDepth,
  });

  final OrgUnitAdminNode parent;
  final Set<String> existingNames;

  /// GAP A4 — depth of [parent] in the org-unit chain, computed by the
  /// caller by walking in-memory parent links (the admin node model
  /// carries no ltree path). The in-dialog backstop re-checks the cap
  /// here so a stale tree still gets a friendly inline error.
  final int parentDepth;

  @override
  State<_AddChildOrgUnitDialog> createState() => _AddChildOrgUnitDialogState();
}

class _AddChildOrgUnitDialogState extends State<_AddChildOrgUnitDialog> {
  String _unitType = 'region';
  final _nameController = TextEditingController();
  final _labelController = TextEditingController();
  final _reasonController = TextEditingController();
  String? _nameError;
  String? _reasonError;

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final name = _nameController.text.trim();
    final reason = _reasonController.text.trim();
    setState(() {
      // GAP A4 — second guard layer (backstop). Mirrors the proxy
      // guard at org_units_repository.dart:241 exactly. Surfaces on
      // the name field since the dialog has no dedicated depth field.
      _nameError = !OrgUnitDepthRule.canAddChild(widget.parentDepth)
          ? HierarchyValidationCopy.depthCapReached
          : name.isEmpty
          ? HierarchyValidationCopy.orgUnitNameEmpty
          : widget.existingNames.contains(name.toLowerCase())
          ? HierarchyValidationCopy.orgUnitNameDuplicate
          : null;
      _reasonError = reason.isEmpty ? 'Add a reason before continuing.' : null;
    });
    if (_nameError != null || _reasonError != null) return;
    final rawLabel = _labelController.text.trim();
    final label = rawLabel.isEmpty ? _sanitiseLabel(name) : rawLabel;
    Navigator.of(context).pop(
      _AddOrgUnitResult(
        unitType: _unitType,
        label: label,
        name: name,
        adminReason: reason,
      ),
    );
  }

  static String _sanitiseLabel(String name) {
    final collapsed = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_rhs_add_child_org_unit_dialog'),
      title: 'Add child org unit',
      icon: Icons.add_circle_outline,
      maxWidth: 560,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_rhs_add_org_unit_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_add_org_unit_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Add'),
        ),
      ],
      child: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Under ${widget.parent.name}',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('admin_rhs_add_org_unit_type'),
              initialValue: _unitType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Unit type',
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(value: 'brand', child: Text('Brand')),
                DropdownMenuItem<String>(
                  value: 'region',
                  child: Text('Region'),
                ),
                DropdownMenuItem<String>(
                  value: 'district',
                  child: Text('District'),
                ),
                DropdownMenuItem<String>(
                  value: 'location_group',
                  child: Text('Location group'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _unitType = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_add_org_unit_name'),
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Display name',
                border: const OutlineInputBorder(),
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_add_org_unit_label'),
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Label (a-z, 0-9, underscore)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_add_org_unit_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _reasonError,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// GAP A1 — rename an org unit's display name (F&F admin path). The
/// corp root IS renameable (it is the operator-facing Business label),
/// so this dialog has no root carve-out. Duplicate-name-within-parent
/// is re-validated client-side with the same locked copy the server
/// returns. The admin_reason is collected by a separate
/// `_promptAdminReason` step after this dialog returns (matching the
/// delete affordance flow), so this dialog only captures the new name.
class _RenameOrgUnitDialog extends StatefulWidget {
  const _RenameOrgUnitDialog({required this.node, required this.existingNames});

  final OrgUnitAdminNode node;

  /// Sibling display names (lowercased) in the same parent, excluding
  /// this node, so re-submitting its own current name is allowed.
  final Set<String> existingNames;

  @override
  State<_RenameOrgUnitDialog> createState() => _RenameOrgUnitDialogState();
}

class _RenameOrgUnitDialogState extends State<_RenameOrgUnitDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.node.name,
  );
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final name = _nameController.text.trim();
    setState(() {
      _nameError = name.isEmpty
          ? HierarchyValidationCopy.orgUnitNameEmpty
          : widget.existingNames.contains(name.toLowerCase())
          ? HierarchyValidationCopy.orgUnitNameDuplicate
          : null;
    });
    if (_nameError != null) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_rhs_rename_org_unit_dialog'),
      title: 'Rename org unit',
      icon: Icons.drive_file_rename_outline,
      maxWidth: 560,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_rhs_rename_org_unit_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_rename_org_unit_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Continue'),
        ),
      ],
      child: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'This changes how the unit is named everywhere the team '
              'sees it. It does not move anything. You will add a reason '
              'on the next step.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_rename_org_unit_name'),
              controller: _nameController,
              autofocus: true,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Display name',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _nameError,
              ),
              onSubmitted: (_) => _onSubmit(),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoveLocationResult {
  const _MoveLocationResult({
    required this.newOrgUnitId,
    required this.adminReason,
  });

  final String newOrgUnitId;
  final String adminReason;
}

class _MoveLocationDialog extends StatefulWidget {
  const _MoveLocationDialog({required this.leaf, required this.candidates});

  final HierarchyLocationLeaf leaf;
  final List<OrgUnitAdminNode> candidates;

  @override
  State<_MoveLocationDialog> createState() => _MoveLocationDialogState();
}

class _MoveLocationDialogState extends State<_MoveLocationDialog> {
  late String _selectedOrgUnitId = widget.leaf.orgUnitId;
  final _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(
      _MoveLocationResult(
        newOrgUnitId: _selectedOrgUnitId,
        adminReason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_rhs_move_location_dialog'),
      title: 'Move ${widget.leaf.name}',
      icon: Icons.swap_horiz,
      maxWidth: 540,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_move_location_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Move'),
        ),
      ],
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: const Key('admin_rhs_move_location_org_unit'),
              initialValue: _selectedOrgUnitId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'New org unit',
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String>>[
                for (final candidate in widget.candidates)
                  DropdownMenuItem<String>(
                    value: candidate.orgUnitId,
                    child: Text(candidate.name),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _selectedOrgUnitId = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_move_location_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _violated ? 'Add a reason before continuing.' : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
