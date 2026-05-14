// Lane B B2.2 - Default Role catalog admin editor surface.
//
// F&F internal-only surface backed by the B2.1 admin gateway
// (`lib/admin/services/default_role_catalog_admin_gateway.dart`). The
// screen has three logical regions:
//
//   * Current version - the lone `is_current = true` row from the
//     gateway. If null, the screen explains the genesis state (no
//     catalog published yet; the hard-coded fallback is active).
//   * History - up to 20 prior versions ordered newest first. Each row
//     expands to show the payload as read-only JSON.
//   * Draft editor - starts from the current payload (or empty). The
//     super_admin can add / remove / edit role definitions. The draft
//     is local widget state only - there is NO backend draft
//     persistence (intentional; out of scope for B2.2). The
//     class-level dartdoc captures the limitation; the screen surfaces
//     a "Discard draft?" warning when the operator leaves with unsaved
//     changes via the discard button.
//
// Publish path:
//
//   * The "Publish" button at the bottom of the editor is disabled
//     when the draft has zero roles OR equals the current payload.
//     Tapping it opens
//     [showDefaultRoleCatalogPublishDialog] which owns the double-
//     confirm flow. On success the screen reloads the listing.
//
// The screen does NOT compute blast-radius numbers itself. The B2.1
// admin gateway does not expose an operator / location / user count
// endpoint; the count lives in the audit event payload only. The
// publish dialog renders plain-English consequence copy in lieu of
// numeric counts. This gap is documented in the slice return summary
// for a future backend slice to address.
//
// Permission gate (Wave 2 RP-9, 2026-05-14):
//
//   Authority: `PermissionKeys.teamRolesDefaultCatalogView` /
//   `PermissionKeys.teamRolesDefaultCatalogEdit`
//   (`lib/auth/permission_keys.dart`). The two keys are catalog-
//   registered (migration
//   `202605150300_phase_rp_9_default_catalog_edit_permission_key.sql`)
//   so the gate is visible in the audit log + permission resolver.
//
//   The admin console's `AdminAuthSession` (`lib/admin/admin_auth_gate.dart`)
//   only carries role claims at the gate layer, not resolved permission
//   keys. So the route-level wrapper in `admin_routes.dart` ->
//   `_buildDefaultRoleCatalog` translates the role tier into the
//   permission decision: a user is "in" if their role tier is one of
//   the canonical roles that hold the permission key in the seeded
//   catalog. This file exposes:
//
//     * [kDefaultRoleCatalogScreenViewRoles] -> role tiers granted
//       `team.roles.default_catalog.view` (super_admin + ff_support).
//     * [kDefaultRoleCatalogScreenEditRoles] -> role tiers granted
//       `team.roles.default_catalog.edit` (super_admin only).
//
//   Both sets MUST stay in lockstep with the migration seed +
//   `kDefaultRoleCatalogAdminReadRoles` /
//   `kDefaultRoleCatalogAdminWriteRoles` in
//   `tool/advisor_proxy/admin_default_role_catalog_routes.dart`.
//   `tool/permission_key_lint.dart` keeps the catalog mirror in sync;
//   the role-tier <-> permission-key mapping here is the defense-in-
//   depth fallback the screen + route can read without a wired
//   `PermissionResolver`. When the admin console grows a permission-
//   resolver wiring, the route builder should switch to
//   `resolver.has(PermissionKeys.teamRolesDefaultCatalogEdit)` and
//   drop the role-tier check.
//
//   The screen receives only the resolved `editingEnabled` flag (true
//   iff the user has the edit key). Read access is still enforced one
//   layer up — the route doesn't mount the screen at all for an actor
//   that lacks the view key.
//
// Tested by:
//   * test/admin/default_role_catalog_admin_screen_test.dart

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../auth/permission_key_metadata.dart';
import '../../auth/permission_keys.dart';
import '../../services/auth/custom_role_validator.dart' show RoleScope;
import '../../theme/app_theme.dart';
import '../../widgets/role_permission_picker.dart';
import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../services/default_role_catalog_admin_gateway.dart';
import 'default_role_catalog_publish_dialog.dart';

/// Role tiers granted `team.roles.default_catalog.view` by the seeded
/// catalog (migration
/// `202605150300_phase_rp_9_default_catalog_edit_permission_key.sql`).
/// Mirrors `kDefaultRoleCatalogAdminReadRoles` in
/// `tool/advisor_proxy/admin_default_role_catalog_routes.dart`. DO NOT
/// widen this set to operator-tier roles — the surface is F&F-internal.
const Set<String> kDefaultRoleCatalogScreenViewRoles = <String>{
  PermissionKeys.roleSuperAdmin,
  PermissionKeys.roleFfSupport,
};

/// Role tiers granted `team.roles.default_catalog.edit` by the seeded
/// catalog. Mirrors `kDefaultRoleCatalogAdminWriteRoles` in
/// `tool/advisor_proxy/admin_default_role_catalog_routes.dart`. Edit is
/// `super_admin` ONLY — publishing a new default catalog version
/// affects every operator in the F&F deployment.
const Set<String> kDefaultRoleCatalogScreenEditRoles = <String>{
  PermissionKeys.roleSuperAdmin,
};

/// Resolves whether [actorRoles] satisfies the
/// `team.roles.default_catalog.edit` permission key for the admin
/// surface. Returns true iff any role in the actor's claim set is in
/// [kDefaultRoleCatalogScreenEditRoles].
///
/// Defense-in-depth: when the actor carries a role that holds the view
/// key but NOT the edit key (e.g. `ff_support`), this helper logs a
/// `debugPrint` if [actorHasEditKeyHint] disagrees with the role-tier
/// decision. The mismatch is never silently honoured — the role-tier
/// check is authoritative here because the admin console does not yet
/// thread a `PermissionResolver` into the auth session. Removing the
/// fallback requires wiring the resolver and dropping this helper.
bool defaultRoleCatalogScreenCanEdit({
  required Iterable<String> actorRoles,
  bool? actorHasEditKeyHint,
}) {
  final canEditByRole = actorRoles.any(
    kDefaultRoleCatalogScreenEditRoles.contains,
  );
  if (actorHasEditKeyHint != null && actorHasEditKeyHint != canEditByRole) {
    // Defense-in-depth: warn loudly when a future permission-resolver
    // wiring disagrees with the role-tier fallback. Either the role
    // catalog drifted (a new role inherited the edit key without being
    // added to [kDefaultRoleCatalogScreenEditRoles]) or the resolver
    // was fed a stale grant. Logged via `debugPrint` so the message
    // surfaces in the admin console's debug stream without crashing
    // a live admin session.
    debugPrint(
      'default_role_catalog_admin_screen: permission-key vs role-tier '
      'mismatch — actorHasEditKeyHint=$actorHasEditKeyHint but '
      'canEditByRole=$canEditByRole for roles=$actorRoles. The role-tier '
      'check wins until the admin console threads a PermissionResolver.',
    );
  }
  return canEditByRole;
}

/// Default Role catalog admin editor screen.
///
/// The draft editor manages role definitions entirely in widget state.
/// Navigating away with unsaved changes loses the draft - intentional
/// for B2.2; backend draft persistence is explicitly out of scope.
class DefaultRoleCatalogAdminScreen extends StatefulWidget {
  const DefaultRoleCatalogAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
  });

  final DefaultRoleCatalogAdminGateway gateway;

  /// When false, the screen hides every mutate affordance. Used for
  /// the `ff_support` read-only branch. The proxy enforces the same
  /// gate server-side - this flag keeps the UI honest about it.
  final bool editingEnabled;

  @override
  State<DefaultRoleCatalogAdminScreen> createState() =>
      _DefaultRoleCatalogAdminScreenState();
}

class _DefaultRoleCatalogAdminScreenState
    extends State<DefaultRoleCatalogAdminScreen> {
  bool _loading = true;
  String? _loadError;
  DefaultRoleCatalogListing? _listing;

  /// Draft role definitions. Each entry is a `Map<String, Object?>`
  /// matching one role-definition shape from the published catalog
  /// payload. Local widget state only; the draft is lost if the
  /// operator navigates away.
  List<Map<String, Object?>> _draft = <Map<String, Object?>>[];

  /// Set of expanded version IDs in the history pane.
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final listing = await widget.gateway.listCatalogs(historyLimit: 20);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _draft = _draftFromPayload(listing.current?.payload);
        _loading = false;
      });
    } on DefaultRoleCatalogAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load the default role catalog '
            '(${error.errorCode}). Try again in a moment.';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load the default role catalog: $error';
        _loading = false;
      });
    }
  }

  static List<Map<String, Object?>> _draftFromPayload(List<Object?>? payload) {
    if (payload == null) return <Map<String, Object?>>[];
    final list = <Map<String, Object?>>[];
    for (final entry in payload) {
      if (entry is Map) {
        list.add(Map<String, Object?>.from(entry.cast<String, Object?>()));
      }
    }
    return list;
  }

  bool get _draftEqualsCurrent {
    final current = _listing?.current;
    if (current == null) return _draft.isEmpty;
    // Compare canonical JSON; identical bytes mean identical role
    // definitions, which is the exact gate the publish-disabled check
    // needs (the proxy will reject a republish of identical bytes via
    // payload_sha256 + version_number invariants anyway, but this
    // surfaces the "no change" state to the operator immediately).
    return _canonical(_draft) == _canonical(current.payload);
  }

  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      final entries = <String>[
        for (final k in keys) '${jsonEncode(k)}:${_canonical(value[k])}',
      ];
      return '{${entries.join(',')}}';
    }
    if (value is List) {
      final items = <String>[for (final entry in value) _canonical(entry)];
      return '[${items.join(',')}]';
    }
    return jsonEncode(value);
  }

  void _addRole() {
    setState(() {
      _draft = <Map<String, Object?>>[
        ..._draft,
        <String, Object?>{
          'role_key': '',
          'display_name': '',
          'description': '',
          'permissions': <Object?>[],
        },
      ];
    });
  }

  void _removeRole(int index) {
    setState(() {
      final next = List<Map<String, Object?>>.from(_draft);
      next.removeAt(index);
      _draft = next;
    });
  }

  void _updateRole(int index, String field, Object? value) {
    setState(() {
      final next = List<Map<String, Object?>>.from(_draft);
      next[index] = <String, Object?>{...next[index], field: value};
      _draft = next;
    });
  }

  void _discardDraft() {
    setState(() {
      _draft = _draftFromPayload(_listing?.current?.payload);
    });
  }

  bool get _canPublish {
    if (!widget.editingEnabled) return false;
    if (_draft.isEmpty) return false;
    if (_draftEqualsCurrent) return false;
    // Reject obviously incomplete role definitions before sending; the
    // proxy will also reject but a fail-fast keeps the publish dialog
    // honest.
    for (final role in _draft) {
      final key = (role['role_key'] as String?)?.trim() ?? '';
      final name = (role['display_name'] as String?)?.trim() ?? '';
      if (key.isEmpty || name.isEmpty) return false;
    }
    return true;
  }

  Future<void> _openPublishDialog() async {
    final current = _listing?.current;
    final nextNumber = (current?.versionNumber ?? 0) + 1;
    final result = await showDefaultRoleCatalogPublishDialog(
      context: context,
      gateway: widget.gateway,
      priorCurrent: current,
      nextVersionNumber: nextNumber,
      proposedPayload: List<Object?>.from(_draft),
    );
    if (!mounted) return;
    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Default catalog version ${result.versionNumber} is now active.',
          ),
        ),
      );
      await _refresh();
    }
  }

  void _toggleExpanded(String versionId) {
    setState(() {
      if (_expanded.contains(versionId)) {
        _expanded.remove(versionId);
      } else {
        _expanded.add(versionId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_default_role_catalog_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const _Header(),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(
                key: Key('admin_default_role_catalog_readonly_banner'),
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_default_role_catalog_loading'),
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
      return _ErrorBanner(
        key: const Key('admin_default_role_catalog_load_error'),
        message: _loadError!,
      );
    }
    final listing = _listing;
    if (listing == null) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      key: const Key('admin_default_role_catalog_scroll'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _CurrentVersionPanel(current: listing.current),
          const SizedBox(height: 18),
          _DraftEditorPanel(
            draft: _draft,
            canEdit: widget.editingEnabled,
            canPublish: _canPublish,
            draftEqualsCurrent: _draftEqualsCurrent,
            onAddRole: widget.editingEnabled ? _addRole : null,
            onRemoveRole: widget.editingEnabled ? _removeRole : null,
            onUpdateRole: widget.editingEnabled ? _updateRole : null,
            onDiscardDraft: widget.editingEnabled ? _discardDraft : null,
            onPublish: widget.editingEnabled ? _openPublishDialog : null,
          ),
          const SizedBox(height: 18),
          _HistoryPanel(
            history: listing.history,
            expanded: _expanded,
            onToggle: _toggleExpanded,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.shield_outlined,
              size: 22,
              color: AppColors.sunsetDark,
            ),
            const SizedBox(width: 8),
            Text(
              'Default roles',
              style: AppTextStyles.display28(color: AppColors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Edit the starter role set every Forge & Flow business begins '
          'with. Publish creates a new version; businesses set to follow '
          'the latest see the change immediately. Customized roles are '
          'unaffected.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
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
              'View only: ecosystem admin access is required to publish '
              'a new default catalog version.',
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

class _CurrentVersionPanel extends StatelessWidget {
  const _CurrentVersionPanel({required this.current});

  final DefaultRoleCatalogVersionView? current;

  @override
  Widget build(BuildContext context) {
    if (current == null) {
      return Container(
        key: const Key('admin_default_role_catalog_current_empty'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'No default catalog published yet',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Forge & Flow is using the built-in starter roles. Publish '
              'a first version to put the catalog under change control.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }
    final c = current!;
    return Container(
      key: const Key('admin_default_role_catalog_current_panel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.sunset, width: 1.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'Current version: v${c.versionNumber}',
                key: const Key('admin_default_role_catalog_current_version'),
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(width: 10),
              _Pill(
                label: 'Active',
                background: AppColors.positive.withValues(alpha: 0.15),
                foreground: AppColors.positive,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Published by ${c.publishedByUserId} on '
            '${adminHumanDateTime(c.publishedAt)}',
            style: AppTextStyles.mono11(color: AppColors.textSecondary),
          ),
          if (c.notes != null && c.notes!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Notes: ${c.notes!}',
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Contains ${c.payload.length} role definitions',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          Text(
            'Content fingerprint: ${c.payloadSha256.substring(0, 12)}...',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _DraftEditorPanel extends StatelessWidget {
  const _DraftEditorPanel({
    required this.draft,
    required this.canEdit,
    required this.canPublish,
    required this.draftEqualsCurrent,
    required this.onAddRole,
    required this.onRemoveRole,
    required this.onUpdateRole,
    required this.onDiscardDraft,
    required this.onPublish,
  });

  final List<Map<String, Object?>> draft;
  final bool canEdit;
  final bool canPublish;
  final bool draftEqualsCurrent;
  final VoidCallback? onAddRole;
  final void Function(int index)? onRemoveRole;
  final void Function(int index, String field, Object? value)? onUpdateRole;
  final VoidCallback? onDiscardDraft;
  final VoidCallback? onPublish;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_default_role_catalog_draft_panel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                'Draft',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(width: 10),
              if (!draftEqualsCurrent)
                _Pill(
                  key: const Key(
                    'admin_default_role_catalog_draft_dirty_pill',
                  ),
                  label: 'Unsaved changes',
                  background: AppColors.warning.withValues(alpha: 0.15),
                  foreground: AppColors.warning,
                )
              else
                _Pill(
                  key: const Key(
                    'admin_default_role_catalog_draft_clean_pill',
                  ),
                  label: 'Matches current',
                  background: AppColors.backgroundDeep,
                  foreground: AppColors.textMuted,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Add, remove, or edit roles below. Drafts are not saved on '
            'the server - if you leave the page, the changes are lost.',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          if (draft.isEmpty)
            Padding(
              key: const Key(
                'admin_default_role_catalog_draft_empty',
              ),
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                'Draft is empty. Add at least one role to publish.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            )
          else
            for (var i = 0; i < draft.length; i++)
              _RoleEditorRow(
                key: Key('admin_default_role_catalog_draft_row_$i'),
                index: i,
                role: draft[i],
                canEdit: canEdit,
                onRemove: onRemoveRole,
                onUpdate: onUpdateRole,
              ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: <Widget>[
              if (canEdit)
                OutlinedButton.icon(
                  key: const Key('admin_default_role_catalog_add_role'),
                  onPressed: onAddRole,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add role'),
                  style: AdminButtonStyles.secondary(),
                ),
              if (canEdit && !draftEqualsCurrent)
                OutlinedButton(
                  key: const Key(
                    'admin_default_role_catalog_discard_draft',
                  ),
                  onPressed: onDiscardDraft,
                  style: AdminButtonStyles.secondary(
                    foregroundColor: AppColors.textPrimary,
                    borderColor: AppColors.borderSubtle,
                  ),
                  child: const Text('Discard draft'),
                ),
              FilledButton(
                key: const Key('admin_default_role_catalog_publish_button'),
                onPressed: canPublish ? onPublish : null,
                style: AdminButtonStyles.primary,
                child: const Text('Publish'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoleEditorRow extends StatelessWidget {
  const _RoleEditorRow({
    super.key,
    required this.index,
    required this.role,
    required this.canEdit,
    required this.onRemove,
    required this.onUpdate,
  });

  final int index;
  final Map<String, Object?> role;
  final bool canEdit;
  final void Function(int index)? onRemove;
  final void Function(int index, String field, Object? value)? onUpdate;

  /// Wave 2 S-3 (RP-14) — Extract the role's current allow keys from
  /// the persisted JSON shape (`permissions: [{permission_key, effect}]`).
  /// The picker treats every persisted allow key as explicit on load
  /// so the operator can drop any of them.
  Set<String> _allowKeysFromPermissions(List<Object?> permissions) {
    final out = <String>{};
    for (final entry in permissions) {
      if (entry is Map) {
        final key = entry['permission_key'];
        final effect = entry['effect'];
        if (key is String && effect == 'allow') {
          out.add(key);
        }
      }
    }
    return out;
  }

  /// Wave 2 S-3 (RP-14) — When the operator ticks / unticks a key in
  /// the picker we rewrite the role's `permissions` JSON array. The
  /// expansion is the transitive `implies[]` closure of the explicit
  /// set; deny rules + any unknown extra metadata are NOT touched.
  void _onTogglePermission(String key, bool selected) {
    final permissions = (role['permissions'] as List?) ?? const <Object?>[];
    final explicit = _allowKeysFromPermissions(permissions);
    if (selected) {
      explicit.add(key);
    } else {
      explicit.remove(key);
    }
    final expanded =
        PermissionKeyMetadataCatalog.expandImplies(explicit).toList()
          ..sort();
    // Preserve any non-allow rules (deny, future shapes) from the
    // existing list so the editor stays additive.
    final preserved = <Object?>[];
    for (final entry in permissions) {
      if (entry is Map &&
          entry['permission_key'] is String &&
          entry['effect'] == 'allow') {
        continue; // rewritten below
      }
      preserved.add(entry);
    }
    final next = <Object?>[
      ...preserved,
      for (final k in expanded)
        <String, Object?>{'permission_key': k, 'effect': 'allow'},
    ];
    onUpdate?.call(index, 'permissions', next);
  }

  @override
  Widget build(BuildContext context) {
    final roleKey = (role['role_key'] as String?) ?? '';
    final displayName = (role['display_name'] as String?) ?? '';
    final description = (role['description'] as String?) ?? '';
    final permissions = (role['permissions'] as List?) ?? const <Object?>[];
    final explicitAllow = _allowKeysFromPermissions(permissions);
    final displayedAllow =
        PermissionKeyMetadataCatalog.expandImplies(explicitAllow);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: _Field(
                  keyValue: Key(
                    'admin_default_role_catalog_draft_role_key_$index',
                  ),
                  label: 'Role key',
                  initial: roleKey,
                  enabled: canEdit,
                  onChanged: (value) => onUpdate?.call(index, 'role_key', value),
                  hint: 'lowercase_snake_case',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Field(
                  keyValue: Key(
                    'admin_default_role_catalog_draft_display_name_$index',
                  ),
                  label: 'Display name',
                  initial: displayName,
                  enabled: canEdit,
                  onChanged: (value) =>
                      onUpdate?.call(index, 'display_name', value),
                  hint: 'e.g. Floor Manager',
                ),
              ),
              if (canEdit && onRemove != null)
                IconButton(
                  key: Key(
                    'admin_default_role_catalog_draft_remove_$index',
                  ),
                  tooltip: 'Remove role',
                  onPressed: () => onRemove!(index),
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.negative,
                    size: 20,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _Field(
            keyValue: Key(
              'admin_default_role_catalog_draft_description_$index',
            ),
            label: 'Description',
            initial: description,
            enabled: canEdit,
            onChanged: (value) => onUpdate?.call(index, 'description', value),
            hint: 'What this role can do, in plain English.',
            maxLines: 2,
          ),
          const SizedBox(height: 10),
          RolePermissionPickerCard(
            key: Key(
              'admin_default_role_catalog_draft_permissions_$index',
            ),
            selected: displayedAllow,
            explicit: explicitAllow,
            // Default-catalog roles are business-scoped (org-wide
            // permissions are coherent) so the scope-conflict filter
            // does not engage here.
            roleScope: RoleScope.business,
            readOnly: !canEdit,
            onToggle: _onTogglePermission,
            keyPrefix: 'admin_default_role_catalog_draft_picker_$index',
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.keyValue,
    required this.label,
    required this.initial,
    required this.enabled,
    required this.onChanged,
    required this.hint,
    this.maxLines = 1,
  });

  final Key keyValue;
  final String label;
  final String initial;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final String hint;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: AppTextStyles.mono10(color: AppColors.textSecondary)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        TextFormField(
          key: keyValue,
          initialValue: initial,
          enabled: enabled,
          minLines: 1,
          maxLines: maxLines,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            hintStyle: AppTextStyles.body12(color: AppColors.textMuted),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(
                color: AppColors.borderSubtle,
                width: 1,
              ),
            ),
          ),
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
      ],
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({
    required this.history,
    required this.expanded,
    required this.onToggle,
  });

  final List<DefaultRoleCatalogVersionView> history;
  final Set<String> expanded;
  final void Function(String versionId) onToggle;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return Container(
        key: const Key('admin_default_role_catalog_history_empty'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'History will appear here after the first publish.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      );
    }
    return Container(
      key: const Key('admin_default_role_catalog_history_panel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'History',
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'Up to 20 most recent versions. Tap a row to see its full role '
            'definitions.',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          for (final version in history)
            _HistoryRow(
              key: Key(
                'admin_default_role_catalog_history_row_${version.versionId}',
              ),
              version: version,
              expanded: expanded.contains(version.versionId),
              onToggle: () => onToggle(version.versionId),
            ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.version,
    required this.expanded,
    required this.onToggle,
  });

  final DefaultRoleCatalogVersionView version;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(
          color: version.isCurrent
              ? AppColors.sunset
              : AppColors.borderSubtle,
          width: version.isCurrent ? 1.2 : 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: Key(
              'admin_default_role_catalog_history_toggle_'
              '${version.versionId}',
            ),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              'v${version.versionNumber}',
                              style: AppTextStyles.body14(
                                color: AppColors.textPrimary,
                              ).copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(width: 8),
                            if (version.isCurrent)
                              _Pill(
                                label: 'Current',
                                background: AppColors.positive
                                    .withValues(alpha: 0.15),
                                foreground: AppColors.positive,
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Published by ${version.publishedByUserId} on '
                          '${adminHumanDateTime(version.publishedAt)}',
                          style: AppTextStyles.mono10(
                            color: AppColors.textSecondary,
                          ),
                        ),
                        if (version.notes != null &&
                            version.notes!.trim().isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            version.notes!,
                            maxLines: expanded ? null : 2,
                            overflow: expanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                            style: AppTextStyles.body12(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.textMuted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Content fingerprint: ${version.payloadSha256}',
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    key: Key(
                      'admin_default_role_catalog_history_payload_'
                      '${version.versionId}',
                    ),
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSurface,
                      border: Border.all(
                        color: AppColors.borderSubtle,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _prettyJson(version.payload),
                      style: AppTextStyles.mono10(color: AppColors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _prettyJson(Object? value) {
    final encoder = JsonEncoder.withIndent('  ');
    try {
      return encoder.convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(color: foreground)
            .copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
