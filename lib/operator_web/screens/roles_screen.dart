// Phase 11W.2 - Operator Web Roles screen.
//
// Web parity for the mobile Settings -> Roles surface. Mounted at the
// `/roles` route in the operator-web shell. Renders the operator's
// role catalog as two groups (custom roles + seeded roles) per the
// Team / Roles / Hierarchy / Sessions / Audit / Security console
// parity contract § Roles + Permission Explainer (`11W.2` +
// `11A.13` Roles tab):
//
//   * Seeded roles render `is_editable=false` on operator self-
//     service - no Edit / Delete buttons. The proxy enforces the same
//     rule; the UI just keeps the surface honest.
//   * Custom roles can be created via [CustomRoleEditorScreen].
//   * Permission Explainer is reachable at the top of the list via
//     [PermissionExplainerScreen] mounted at `/roles/explainer`.
//   * MFA-required permission keys render with a 🔒 chip + tooltip
//     "Requires multi-factor authentication." (per the parity contract
//     § Roles + Permission Explainer MFA-required keys rule.)
//
// Permission gates mirror the proxy. The screen prefers the live
// `OperatorWebSession.permissions` snapshot when present and falls
// back to a role-tier set so the demo flavor and the pre-snapshot
// bootstrap stage of live mode still render usefully.
//
// Wiring honesty: the screen reads + writes through
// [WebTeamRolesGateway] which the router binds to either the
// `package:http` live impl or the in-memory demo impl. No dart:io,
// no sqflite, no parallel HTTP stack.

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/web_team_roles_gateway.dart';
import '../../theme/app_theme.dart';
import 'custom_role_editor_screen.dart';
import 'permission_explainer_screen.dart';

/// Roles admitted to the Roles surface when the proxy permission
/// snapshot is not yet hydrated (demo flavor + bootstrap). Mirrors the
/// `team.roles.view` gate the proxy enforces. Floor managers
/// (`location_manager`) get read-only roles per the parity contract
/// § Permission gate cheat sheet.
const Set<String> kOperatorWebRolesAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
  'operator_manager',
  'location_manager',
};

/// Role-tier fallback for the create / edit / delete actions.
/// Authoritative gate is `team.roles.create_custom`.
const Set<String> kOperatorWebRolesWriteRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Permission-key bound for the read surface. Aliased to the frozen
/// catalog constant in `lib/auth/permission_keys.dart`.
const String kRolesViewPermissionKey = PermissionKeys.teamRolesView;

/// Permission-key bound for the create / patch / delete actions.
/// Aliased to the frozen catalog constant in
/// `lib/auth/permission_keys.dart`.
const String kRolesWritePermissionKey = PermissionKeys.teamRolesCreateCustom;

/// Operator Web Roles screen.
class RolesScreen extends StatefulWidget {
  const RolesScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.idempotencyKeyFactory,
    this.onOpenExplainer,
    this.onOpenEditor,
  });

  final OperatorWebSession session;
  final WebTeamRolesGateway gateway;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway.
  final String Function()? idempotencyKeyFactory;

  /// Callback fired when the operator taps "Permission Explainer".
  /// The router uses this to swap the body to the explainer screen
  /// (mirrors `/roles/explainer`); tests can pass a custom hook to
  /// assert the navigation.
  final VoidCallback? onOpenExplainer;

  /// Callback fired when the operator taps "New role" or "Edit". The
  /// router uses this to swap the body to the editor screen (mirrors
  /// `/roles/edit/:id`). `null` means "create new"; non-null means
  /// "edit this role".
  final ValueChanged<TeamRoleCatalogEntry?>? onOpenEditor;

  /// True iff the actor may read the Roles surface.
  bool get _admitted {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kRolesViewPermissionKey);
    }
    return session.roles.any(kOperatorWebRolesAdmittedRoles.contains);
  }

  /// True iff the actor may create / patch / delete custom roles.
  bool get _canWrite {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kRolesWritePermissionKey);
    }
    return session.roles.any(kOperatorWebRolesWriteRoles.contains);
  }

  @override
  State<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends State<RolesScreen> {
  List<TeamRoleCatalogEntry> _roles = const <TeamRoleCatalogEntry>[];
  bool _loading = true;
  String? _loadError;
  final Set<String> _busyRoleIds = <String>{};
  int _loadGeneration = 0;
  int _idempotencySeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-roles-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.gateway.listRoles(
        TeamRoleCatalogListCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
        ),
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _roles = result.roles;
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
    if (error is WebTeamRolesError) {
      return 'Could not load the roles list (${error.code}). Refresh the '
          'page or try again in a moment.';
    }
    return 'Could not load the roles list. Refresh the page or try again '
        'in a moment.';
  }

  Future<void> _confirmDelete(TeamRoleCatalogEntry role) async {
    final confirmed = await _confirm(
      title: 'Delete role',
      body:
          'Delete "${role.displayName}"? Members holding this role will '
          'lose its permissions on their next sign-in. Revoke the role '
          'from every member first if you have not already.',
      cta: 'Delete',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyRoleIds.add(role.roleId));
    try {
      await widget.gateway.deleteRole(
        TeamRoleDeleteCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId ?? '',
          roleId: role.roleId,
          reason: 'op_web_roles_delete',
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Role "${role.displayName}" deleted.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    } finally {
      if (mounted) {
        setState(() => _busyRoleIds.remove(role.roleId));
      }
    }
  }

  String _friendlyMutationError(Object error) {
    if (error is WebTeamRolesError) {
      if (error.code == 'role_has_active_grants') {
        return 'Revoke this role from every member before deleting it.';
      }
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
        key: const Key('roles_confirm_dialog'),
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            key: const Key('roles_confirm_dialog_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('roles_confirm_dialog_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.negative,
              foregroundColor: AppColors.backgroundSurface,
            ),
            child: Text(cta),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _openExplainer() {
    final hook = widget.onOpenExplainer;
    if (hook != null) {
      hook();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/roles/explainer'),
        builder: (_) => const PermissionExplainerScreen(),
      ),
    );
  }

  Future<void> _openEditor(TeamRoleCatalogEntry? role) async {
    final hook = widget.onOpenEditor;
    if (hook != null) {
      hook(role);
      return;
    }
    final saved = await Navigator.of(context).push<TeamRoleCatalogEntry>(
      MaterialPageRoute<TeamRoleCatalogEntry>(
        settings: RouteSettings(
          name: role == null ? '/roles/edit/new' : '/roles/edit/${role.roleId}',
        ),
        builder: (_) => CustomRoleEditorScreen(
          session: widget.session,
          gateway: widget.gateway,
          existing: role,
          idempotencyKeyFactory: widget.idempotencyKeyFactory,
        ),
      ),
    );
    if (saved != null) await _load();
  }

  /// Public refresh used by the router when an editor swap returns to
  /// the list view, so the operator sees their just-created role.
  Future<void> refresh() => _load();

  @override
  Widget build(BuildContext context) {
    if (!widget._admitted) {
      return const _RolesForbiddenSurface(
        key: Key('operator_web_roles_forbidden'),
      );
    }
    if (_loading) {
      return const Center(
        key: Key('operator_web_roles_loading'),
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
        key: const Key('operator_web_roles_load_error'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Roles could not load',
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
                    key: const Key('operator_web_roles_load_retry'),
                    onPressed: _load,
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
    final seeded = <TeamRoleCatalogEntry>[];
    final custom = <TeamRoleCatalogEntry>[];
    for (final role in _roles) {
      (role.isSeeded ? seeded : custom).add(role);
    }
    seeded.sort((a, b) => a.displayName.compareTo(b.displayName));
    custom.sort((a, b) => a.displayName.compareTo(b.displayName));
    return SingleChildScrollView(
      key: const Key('operator_web_roles_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _RolesHeader(
            canWrite: widget._canWrite,
            onOpenExplainer: _openExplainer,
            onCreateRole: () => _openEditor(null),
          ),
          const SizedBox(height: 18),
          if (custom.isEmpty)
            _EmptyCustomRolesPanel(
              canWrite: widget._canWrite,
              onCreateRole: () => _openEditor(null),
            )
          else
            _RoleGroup(
              key: const Key('operator_web_roles_custom_group'),
              title: 'Custom roles (${custom.length})',
              subtitle:
                  'Roles you have built for this operator. Edit or delete '
                  'them as your team changes.',
              roles: custom,
              busyRoleIds: _busyRoleIds,
              canWrite: widget._canWrite,
              onEdit: (role) => _openEditor(role),
              onDelete: _confirmDelete,
            ),
          const SizedBox(height: 18),
          _RoleGroup(
            key: const Key('operator_web_roles_seeded_group'),
            title: 'Default roles (${seeded.length})',
            roles: seeded,
            busyRoleIds: _busyRoleIds,
            canWrite: false,
            onEdit: null,
            onDelete: null,
          ),
        ],
      ),
    );
  }
}

class _RolesHeader extends StatelessWidget {
  const _RolesHeader({
    required this.canWrite,
    required this.onOpenExplainer,
    required this.onCreateRole,
  });

  final bool canWrite;
  final VoidCallback onOpenExplainer;
  final VoidCallback onCreateRole;

  @override
  Widget build(BuildContext context) {
    final title = Row(
      children: <Widget>[
        const Icon(
          Icons.shield_outlined,
          size: 22,
          color: AppColors.sunsetDark,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            'Roles & permissions',
            maxLines: 2,
            softWrap: true,
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
        ),
      ],
    );

    final actions = Wrap(
      spacing: 10,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: <Widget>[
        SizedBox(
          height: 38,
          child: OutlinedButton.icon(
            key: const Key('operator_web_roles_open_explainer'),
            onPressed: onOpenExplainer,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.sunsetDark,
              side: const BorderSide(color: AppColors.sunsetDark, width: 1),
            ),
            icon: const Icon(Icons.help_outline, size: 16),
            label: const Text('Permission Explainer'),
          ),
        ),
        SizedBox(
          height: 38,
          child: FilledButton.icon(
            key: const Key('operator_web_roles_new_role'),
            onPressed: canWrite ? onCreateRole : null,
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
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[title, const SizedBox(height: 12), actions],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: title),
            const SizedBox(width: 16),
            actions,
          ],
        );
      },
    );
  }
}

class _RoleGroup extends StatelessWidget {
  const _RoleGroup({
    super.key,
    required this.title,
    this.subtitle,
    required this.roles,
    required this.busyRoleIds,
    required this.canWrite,
    required this.onEdit,
    required this.onDelete,
  });

  final String title;
  final String? subtitle;
  final List<TeamRoleCatalogEntry> roles;
  final Set<String> busyRoleIds;
  final bool canWrite;
  final ValueChanged<TeamRoleCatalogEntry>? onEdit;
  final ValueChanged<TeamRoleCatalogEntry>? onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitleText = subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          title,
          style: AppTextStyles.mono14(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
        if (subtitleText != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            subtitleText,
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
        ],
        const SizedBox(height: 10),
        for (final role in roles)
          _RoleTile(
            key: Key('operator_web_role_tile_${role.roleId}'),
            role: role,
            busy: busyRoleIds.contains(role.roleId),
            canWrite: canWrite,
            onEdit: onEdit,
            onDelete: onDelete,
          ),
      ],
    );
  }
}

class _RoleTile extends StatelessWidget {
  const _RoleTile({
    super.key,
    required this.role,
    required this.busy,
    required this.canWrite,
    required this.onEdit,
    required this.onDelete,
  });

  final TeamRoleCatalogEntry role;
  final bool busy;
  final bool canWrite;
  final ValueChanged<TeamRoleCatalogEntry>? onEdit;
  final ValueChanged<TeamRoleCatalogEntry>? onDelete;

  @override
  Widget build(BuildContext context) {
    // Wave 2 S-3 (RP-8) — simplified tile. Roles list shows ONLY the
    // role's display name, a short description (first sentence of the
    // description), and an Edit / View button. Permission counts,
    // role_key chips, Default / Custom badges, MFA chips, and the
    // F&F-managed annotation are intentionally hidden here. The
    // editor screen carries the long-form metadata.
    final mutable = canWrite && !role.isSeeded && role.isEditable;
    final shortDescription = _shortRoleDescription(role.description);
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
                  role.displayName,
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                if (shortDescription.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    shortDescription,
                    style: AppTextStyles.body13(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(left: 8, right: 4),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sunsetDark,
                ),
              ),
            ),
          if (!mutable && onEdit != null)
            TextButton(
              key: Key('operator_web_role_view_${role.roleId}'),
              onPressed: busy ? null : () => onEdit?.call(role),
              child: const Text('View'),
            ),
          if (mutable) ...<Widget>[
            TextButton(
              key: Key('operator_web_role_edit_${role.roleId}'),
              onPressed: busy ? null : () => onEdit?.call(role),
              child: const Text('Edit'),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: Key('operator_web_role_delete_${role.roleId}'),
              onPressed: busy ? null : () => onDelete?.call(role),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.negative,
              ),
              child: const Text('Delete'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Wave 2 S-3 (RP-8). Trims a role's description to the first
/// sentence so the simplified row stays compact. Returns an empty
/// string when the description is empty.
@visibleForTesting
String shortRoleDescriptionForTest(String description) {
  return _shortRoleDescription(description);
}

String _shortRoleDescription(String description) {
  final trimmed = description.trim();
  if (trimmed.isEmpty) return '';
  // First period/exclamation/question mark followed by whitespace or
  // end-of-string ends the sentence. We avoid splitting on periods
  // inside abbreviations like "e.g." by requiring trailing whitespace
  // or end-of-input.
  final sentenceEnd = RegExp(r'([.!?])(\s|$)');
  final match = sentenceEnd.firstMatch(trimmed);
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
      key: const Key('operator_web_roles_empty_custom'),
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
                key: const Key('operator_web_roles_empty_create'),
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

class _RolesForbiddenSurface extends StatelessWidget {
  const _RolesForbiddenSurface({super.key});

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
                      'Roles are owner-managed',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Building and assigning roles is managed by your operator '
                'admin or owner. Ask them to update your role if you need '
                'to change what your team can see and do.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lane B B2.4 — Plain-English annotation for the seeded-role row.
///
/// When the catalog version's `published_at` is non-null, renders
/// "Updated by F&F on Mon D, YYYY" using the operator's local time
/// zone (same `toLocal()` posture the audit-log row uses for its
/// timestamp formatter). Falls back to the B2.2 "Managed by Forge
/// & Flow" copy when the field is null (genesis state — no catalog
/// version published yet — or a legacy proxy build that doesn't
/// carry the field).
@visibleForTesting
String defaultAnnotationCopyForCatalogPublishedAt(DateTime? publishedAt) {
  return _defaultAnnotationCopy(publishedAt);
}

String _defaultAnnotationCopy(DateTime? publishedAt) {
  if (publishedAt == null) return 'Managed by Forge & Flow';
  final local = publishedAt.toLocal();
  final month = _kRolesAnnotationMonthNames[local.month - 1];
  return 'Updated by F&F on $month ${local.day}, ${local.year}';
}

const List<String> _kRolesAnnotationMonthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
