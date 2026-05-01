// Phase 9.UX.2 — Settings → Team → Roles surface.
//
// Renders the operator's role catalog: seeded roles (read-only) and
// operator-scoped custom roles (create / edit / delete). Live wiring
// flows through `auth_operations_gateway.dart` against B17's
// `/v1/admin/auth/roles`. Test wiring passes the catalog seed + raw
// callbacks directly so the surface runs without staging access.
//
// Visibility / mutation gates use the frozen `team.roles.*` keys from
// `docs/contracts/auth_permission_key_catalog.md`:
//
//   * `team.roles.view`        — entry visible at all
//   * `team.roles.create_custom` — Create + Edit + Delete actions
//   * `team.roles.assign`        — Edit (some operators may have edit
//                                  without create — falls back to view)
//
// Seeded / non-editable roles never expose Edit/Delete regardless of
// the actor's permissions; the proxy enforces the same rule, the UI
// just keeps the surface honest.

import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../services/team/team_scope_visibility_policy.dart';
import '../../theme/app_theme.dart';
import 'settings_role_editor.dart';

typedef SettingsRoleCreateRequester =
    Future<TeamRoleCatalogEntry?> Function(SettingsRoleEditorResult result);

typedef SettingsRolePatchRequester =
    Future<TeamRoleCatalogEntry?> Function(SettingsRoleEditorResult result);

typedef SettingsRoleDeleteRequester =
    Future<bool> Function(TeamRoleCatalogEntry role);

typedef SettingsRoleCatalogRetryRequester = Future<void> Function();

class TeamRoleCatalogLoadState {
  const TeamRoleCatalogLoadState({
    this.loading = false,
    this.loaded = true,
    this.errorMessage,
  });

  static const TeamRoleCatalogLoadState ready = TeamRoleCatalogLoadState();
  static const TeamRoleCatalogLoadState waiting = TeamRoleCatalogLoadState(
    loading: true,
    loaded: false,
  );
  static const TeamRoleCatalogLoadState unavailable = TeamRoleCatalogLoadState(
    loaded: false,
  );

  final bool loading;
  final bool loaded;
  final String? errorMessage;

  bool get hasError => errorMessage != null && errorMessage!.trim().isNotEmpty;
  bool get shouldShowNotice => loading || !loaded || hasError;
}

class SettingsCustomRolesSection extends StatefulWidget {
  const SettingsCustomRolesSection({
    super.key,
    required this.actor,
    required this.roleCatalog,
    this.loadState = TeamRoleCatalogLoadState.ready,
    this.onRetry,
    this.onCreateRole,
    this.onPatchRole,
    this.onDeleteRole,
    this.permissionKeys = const <String>{},
  });

  final TeamScopeActor actor;
  final List<TeamRoleCatalogEntry> roleCatalog;
  final TeamRoleCatalogLoadState loadState;
  final SettingsRoleCatalogRetryRequester? onRetry;
  final SettingsRoleCreateRequester? onCreateRole;
  final SettingsRolePatchRequester? onPatchRole;
  final SettingsRoleDeleteRequester? onDeleteRole;

  /// Permission keys offered in the editor. Empty falls back to the
  /// frozen catalog defined in `lib/auth/permission_keys.dart`.
  final Set<String> permissionKeys;

  @override
  State<SettingsCustomRolesSection> createState() =>
      _SettingsCustomRolesSectionState();
}

class _SettingsCustomRolesSectionState
    extends State<SettingsCustomRolesSection> {
  final Set<String> _busyRoleIds = <String>{};
  bool _busyCreate = false;
  bool _retryingCatalog = false;

  bool get _canView =>
      widget.actor.actorPermissions.contains('team.roles.view');

  bool get _canCreate =>
      widget.onCreateRole != null &&
      widget.actor.actorPermissions.contains('team.roles.create_custom');

  bool _canEdit(TeamRoleCatalogEntry role) {
    // Seeded roles ship `is_editable=true` for the four operator-tier
    // baselines, but the operator-facing repository / proxy gateway
    // only mutates operator-scoped custom roles — seeded edits route
    // through `admin.roles.edit_seeded` (super_admin / MFA), not this
    // surface. Treat seeded as View-only regardless of `is_editable`.
    if (role.isSeeded) return false;
    if (!role.isEditable) return false;
    if (widget.onPatchRole == null) return false;
    return widget.actor.actorPermissions.contains('team.roles.create_custom');
  }

  bool _canDelete(TeamRoleCatalogEntry role) {
    if (role.isSeeded || !role.isEditable) return false;
    if (widget.onDeleteRole == null) return false;
    return widget.actor.actorPermissions.contains('team.roles.create_custom');
  }

  @override
  Widget build(BuildContext context) {
    if (!_canView) {
      return Container(
        key: const Key('settings_custom_roles_locked'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Text(
          'Roles are not available for this account.',
          style: AppTextStyles.body13(color: AppColors.textMuted),
        ),
      );
    }

    final seeded = <TeamRoleCatalogEntry>[];
    final custom = <TeamRoleCatalogEntry>[];
    for (final role in widget.roleCatalog) {
      (role.isSeeded ? seeded : custom).add(role);
    }
    seeded.sort((a, b) => a.displayName.compareTo(b.displayName));
    custom.sort((a, b) => a.displayName.compareTo(b.displayName));

    return Column(
      key: const Key('settings_custom_roles_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Custom roles let you tailor permission grants for '
                'this operator without touching the seeded baseline.',
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ),
            if (_canCreate)
              FilledButton.icon(
                key: const Key('settings_custom_roles_create_button'),
                onPressed: _busyCreate ? null : _openCreateDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New role'),
              ),
          ],
        ),
        if (widget.loadState.shouldShowNotice) ...[
          const SizedBox(height: 12),
          _RoleCatalogLoadNotice(
            loadState: widget.loadState,
            retrying: _retryingCatalog,
            onRetry: widget.onRetry == null ? null : _retryCatalog,
          ),
        ],
        const SizedBox(height: 12),
        if (custom.isNotEmpty) ...[
          _GroupHeader(label: 'Custom roles (${custom.length})'),
          for (final role in custom)
            _RoleTile(
              key: Key('settings_custom_role_tile_${role.roleId}'),
              role: role,
              busy: _busyRoleIds.contains(role.roleId),
              canEdit: _canEdit(role),
              canDelete: _canDelete(role),
              onEdit: () => _openEditDialog(role),
              onDelete: () => _confirmDelete(role),
            ),
          const SizedBox(height: 12),
        ] else if (_canCreate)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              key: const Key('settings_custom_roles_empty_custom'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.backgroundSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Text(
                'No custom roles yet. Create one to grant a tailored '
                'permission set.',
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ),
          ),
        if (seeded.isNotEmpty) ...[
          _GroupHeader(label: 'Seeded roles (${seeded.length})'),
          for (final role in seeded)
            _RoleTile(
              key: Key('settings_custom_role_tile_${role.roleId}'),
              role: role,
              busy: false,
              canEdit: _canEdit(role),
              canDelete: _canDelete(role),
              onEdit: () => _openEditDialog(role),
              onDelete: null,
            ),
        ],
      ],
    );
  }

  Future<void> _retryCatalog() async {
    final retry = widget.onRetry;
    if (retry == null || widget.loadState.loading || _retryingCatalog) return;
    setState(() => _retryingCatalog = true);
    try {
      await retry();
    } finally {
      if (mounted) setState(() => _retryingCatalog = false);
    }
  }

  Future<void> _openCreateDialog() async {
    if (!_canCreate) return;
    setState(() => _busyCreate = true);
    final saved = await showDialog<TeamRoleCatalogEntry>(
      context: context,
      builder: (context) => SettingsRoleEditorDialog(
        role: null,
        onSubmit: (result) async {
          final created = await widget.onCreateRole!(result);
          return created;
        },
        permissionKeys: widget.permissionKeys,
      ),
    );
    if (!mounted) return;
    setState(() => _busyCreate = false);
    if (saved != null) {
      _showSnack('Role "${saved.displayName}" created');
    }
  }

  Future<void> _openEditDialog(TeamRoleCatalogEntry role) async {
    final mutating = _canEdit(role);
    if (!mutating && !_canView) return;
    setState(() => _busyRoleIds.add(role.roleId));
    final saved = await showDialog<TeamRoleCatalogEntry>(
      context: context,
      builder: (context) => SettingsRoleEditorDialog(
        role: role,
        readOnly: !mutating,
        onSubmit: (result) async {
          final patcher = widget.onPatchRole;
          if (!mutating || patcher == null) return null;
          final patched = await patcher(result);
          return patched;
        },
        permissionKeys: widget.permissionKeys,
      ),
    );
    if (!mounted) return;
    setState(() => _busyRoleIds.remove(role.roleId));
    if (saved != null && mutating) {
      _showSnack('Role "${saved.displayName}" updated');
    }
  }

  Future<void> _confirmDelete(TeamRoleCatalogEntry role) async {
    if (!_canDelete(role)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete role?'),
        content: Text(
          'Deleting "${role.displayName}" cannot be undone. Any users '
          'currently granted this role will lose its permissions on '
          'their next sign-in.',
        ),
        actions: [
          TextButton(
            key: const Key('settings_custom_roles_delete_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('settings_custom_roles_delete_confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.negative),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyRoleIds.add(role.roleId));
    try {
      final ok = await widget.onDeleteRole!(role);
      if (mounted && ok) {
        _showSnack('Role "${role.displayName}" deleted');
      } else if (mounted) {
        _showSnack('Role could not be deleted.');
      }
    } catch (_) {
      if (mounted) _showSnack('Role could not be deleted.');
    } finally {
      if (mounted) setState(() => _busyRoleIds.remove(role.roleId));
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _RoleCatalogLoadNotice extends StatelessWidget {
  const _RoleCatalogLoadNotice({
    required this.loadState,
    required this.retrying,
    this.onRetry,
  });

  final TeamRoleCatalogLoadState loadState;
  final bool retrying;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final loading = loadState.loading || retrying;
    final message = _message(loading);
    return Container(
      key: const Key('settings_custom_roles_load_notice'),
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
              message,
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
          ] else if (onRetry != null) ...[
            const SizedBox(width: 12),
            TextButton(
              key: const Key('settings_custom_roles_retry_button'),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }

  String _message(bool loading) {
    if (loading) {
      return loadState.loaded
          ? 'Refreshing role catalog...'
          : 'Loading role catalog...';
    }
    final error = loadState.errorMessage?.trim();
    if (error != null && error.isNotEmpty) {
      return loadState.loaded ? '$error Showing last loaded catalog.' : error;
    }
    return 'Role catalog is not loaded yet. Retry to load live roles.';
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: AppTextStyles.mono12(
          color: AppColors.textMuted,
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RoleTile extends StatelessWidget {
  const _RoleTile({
    super.key,
    required this.role,
    required this.busy,
    required this.canEdit,
    required this.canDelete,
    required this.onEdit,
    this.onDelete,
  });

  final TeamRoleCatalogEntry role;
  final bool busy;
  final bool canEdit;
  final bool canDelete;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    var allowCount = 0;
    var denyCount = 0;
    for (final rule in role.permissions) {
      if (rule.effect == 'allow') {
        allowCount += 1;
      } else if (rule.effect == 'deny') {
        denyCount += 1;
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            role.displayName,
                            style: AppTextStyles.body14(
                              color: AppColors.textPrimary,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _RoleBadge(
                          label: role.isSeeded ? 'Seeded' : 'Custom',
                          color: role.isSeeded
                              ? AppColors.peacockDark
                              : AppColors.sunsetDark,
                        ),
                        if (!role.isEditable) ...[
                          const SizedBox(width: 6),
                          _RoleBadge(
                            label: 'Read-only',
                            color: AppColors.textMuted,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      role.roleKey,
                      style: AppTextStyles.mono12(color: AppColors.textMuted),
                    ),
                    if (role.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        role.description,
                        style: AppTextStyles.body12(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _CountChip(
                          key: Key('settings_custom_role_allow_${role.roleId}'),
                          label: '$allowCount allow',
                          color: AppColors.positive,
                        ),
                        _CountChip(
                          key: Key('settings_custom_role_deny_${role.roleId}'),
                          label: '$denyCount deny',
                          color: AppColors.negative,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    'Saving…',
                    style: AppTextStyles.body12(color: AppColors.textMuted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!canEdit)
                TextButton(
                  key: Key('settings_custom_role_view_${role.roleId}'),
                  onPressed: busy ? null : onEdit,
                  child: const Text('View'),
                ),
              if (canEdit)
                TextButton(
                  key: Key('settings_custom_role_edit_${role.roleId}'),
                  onPressed: busy ? null : onEdit,
                  child: const Text('Edit'),
                ),
              if (canDelete && onDelete != null) ...[
                const SizedBox(width: 4),
                TextButton(
                  key: Key('settings_custom_role_delete_${role.roleId}'),
                  onPressed: busy ? null : onDelete,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.negative,
                  ),
                  child: const Text('Delete'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(label, style: AppTextStyles.mono7(color: color)),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(label, style: AppTextStyles.mono7(color: color)),
    );
  }
}
