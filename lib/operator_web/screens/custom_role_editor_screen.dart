// Phase 11W.2 - Operator Web custom-role editor screen.
//
// Builder UX for the operator self-service custom role flow per the
// Team / Roles / Hierarchy / Sessions / Audit / Security console
// parity contract § Roles + Permission Explainer (`11W.2` +
// `11A.13` Roles tab):
//
//   "Operator self-service via `team.roles.create_custom`. ...
//    Builder UX: name + description + permission picker (multi-select
//    tree organized by category). Server enforces frozen catalog -
//    keys outside `PermissionKeys.all` are rejected with
//    `validation_failed/permission_key_unknown`. Custom-role rows
//    carry `operator_id` (operator-scoped); F&F-admin-created custom
//    roles carry the target operator's ID, not NULL."
//
// Mounted at:
//   * `/roles/edit/:id` for editing an existing custom role.
//   * `/roles/edit/new` for creating a new custom role (passing
//     `existing == null`).
//
// Seeded roles never reach this screen on the operator self-service
// surface - the roles list hides the Edit affordance for them
// (`is_editable=false` enforced server-side). When the screen is
// mounted in read-only mode (e.g. for a future supervisor read view),
// every input + the save button disable so the operator can browse
// without mutating.

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../../services/auth/custom_role_validator.dart';
import '../../services/auth/role_warning_dismissal_store.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/web_team_roles_gateway.dart';
import '../../theme/app_theme.dart';
import 'permission_explainer_screen.dart';

/// Permission key validation rule. Mirrors the proxy-side
/// `validation_failed/permission_key_unknown` error code so the
/// client and server reject the same set.
const String kCustomRoleEditorUnknownKeyMessage =
    'One or more permission keys are not in the catalog. Pick keys '
    'from the list below.';

/// Process-lifetime fallback used when the caller does not pass a
/// [RoleWarningDismissalStore]. The default is intentionally an
/// in-memory store so the operator-web SPA keeps dismissals across
/// editor open/close within the same session; durable persistence
/// will plug in via constructor injection from the higher-level
/// route once `package:shared_preferences` is wired in for the web
/// shell.
final RoleWarningDismissalStore _kDefaultDismissalStore =
    MemoryRoleWarningDismissalStore();

/// Operator Web custom-role builder screen. Pass `existing == null`
/// to create a new role; pass an existing role to edit it.
class CustomRoleEditorScreen extends StatefulWidget {
  CustomRoleEditorScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.existing,
    this.idempotencyKeyFactory,
    this.onSaved,
    this.onClose,
    this.readOnly = false,
    this.roleScope = RoleScope.location,
    this.validator = const CustomRoleValidator(),
    RoleWarningDismissalStore? dismissalStore,
  }) : dismissalStore = dismissalStore ?? _kDefaultDismissalStore;

  final OperatorWebSession session;
  final WebTeamRolesGateway gateway;

  /// Hierarchy scope this role is being authored at. The operator-web
  /// custom role flow today is implicitly location-scoped (the
  /// session carries a `primaryLocationId`); a future business-scope
  /// editor surface can pass `RoleScope.business` to suppress the
  /// org-wide-key-at-location-scope advisory.
  ///
  /// Defaults to [RoleScope.location] so the warning surface is on by
  /// default for the current operator-web shell.
  final RoleScope roleScope;

  /// Advisory validator that produces the inline warning list. Pure
  /// Dart; the editor calls it on every selection change. Override in
  /// tests to pin a specific warning set without seeding permission
  /// keys.
  final CustomRoleValidator validator;

  /// Persistent store for "Don't show this warning again for this
  /// role" dismissals. Defaults to a process-lifetime in-memory store
  /// so the SPA-session experience matches the operator's intuition
  /// ("I dismissed it, I do not want to see it again"). Tests inject
  /// a fresh [MemoryRoleWarningDismissalStore] so dismissals from
  /// other tests do not bleed in.
  final RoleWarningDismissalStore dismissalStore;

  /// Existing role to edit. `null` means "create a new custom role".
  final TeamRoleCatalogEntry? existing;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway.
  final String Function()? idempotencyKeyFactory;

  /// Callback fired after a successful create / patch. The router
  /// uses this to refresh the roles list.
  final ValueChanged<TeamRoleCatalogEntry>? onSaved;

  /// Callback fired when the operator dismisses the editor without
  /// saving. The router uses this to swap back to the roles list.
  final VoidCallback? onClose;

  /// True iff the editor is mounted as a read-only inspector. The
  /// builder screen on operator self-service is never read-only for
  /// editable roles; this flag exists for future read-only audiences.
  final bool readOnly;

  @override
  State<CustomRoleEditorScreen> createState() => _CustomRoleEditorScreenState();
}

class _CustomRoleEditorScreenState extends State<CustomRoleEditorScreen> {
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final Set<String> _selectedPermissions = <String>{};
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _saving = false;
  String? _saveError;
  int _idempotencySeq = 0;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _displayNameController.text = existing.displayName;
      _descriptionController.text = existing.description;
      for (final rule in existing.permissions) {
        if (rule.effect == 'allow' &&
            PermissionKeys.all.contains(rule.permissionKey)) {
          _selectedPermissions.add(rule.permissionKey);
        }
      }
    }
    // The non-Owner billing-subscription warning (Rule 6c) reads the
    // display name. Rebuild on name change so the warning surfaces /
    // disappears as the operator types.
    _displayNameController.addListener(_onDisplayNameChanged);
  }

  void _onDisplayNameChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _displayNameController.removeListener(_onDisplayNameChanged);
    _displayNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _isCreate => widget.existing == null;

  bool get _barrioPlanIncluded =>
      widget.session.permissions.contains(PermissionKeys.productBarrioAccess);

  bool get _canSave {
    if (widget.readOnly) return false;
    final name = _displayNameController.text.trim();
    if (name.isEmpty) return false;
    return _selectedPermissions.isNotEmpty;
  }

  /// Derive a stable, proxy-compatible role_key from the display name.
  /// The role_key field is no longer surfaced in the UI per Wave 2 U-5
  /// UX cleanup; we still mint it locally so the proxy contract (which
  /// requires a unique snake_case key per role) keeps working.
  String _deriveRoleKey(String displayName) {
    final lowered = displayName.toLowerCase();
    final sanitized = StringBuffer();
    var lastWasUnderscore = false;
    for (final code in lowered.codeUnits) {
      final char = String.fromCharCode(code);
      final isAlpha = code >= 0x61 && code <= 0x7a;
      final isDigit = code >= 0x30 && code <= 0x39;
      if (isAlpha || isDigit) {
        sanitized.write(char);
        lastWasUnderscore = false;
      } else if (!lastWasUnderscore && sanitized.isNotEmpty) {
        sanitized.write('_');
        lastWasUnderscore = true;
      }
    }
    var key = sanitized.toString();
    while (key.endsWith('_')) {
      key = key.substring(0, key.length - 1);
    }
    // role_key regex requires a leading letter; prepend "role_" if the
    // first usable character was a digit so we always satisfy the
    // /^[a-z][a-z0-9_]{1,63}$/ rule the proxy enforces.
    if (key.isEmpty || !RegExp(r'^[a-z]').hasMatch(key)) {
      key = 'role_${key.isEmpty ? 'custom' : key}';
    }
    if (key.length > 64) {
      key = key.substring(0, 64);
      while (key.endsWith('_') && key.isNotEmpty) {
        key = key.substring(0, key.length - 1);
      }
    }
    // Suffix with a short timestamp so two roles created with the same
    // display name don't collide on role_key. Falls within the 64-char
    // ceiling because we trim above first.
    final suffix = DateTime.now().toUtc().millisecondsSinceEpoch
        .remainder(1000000)
        .toString();
    final maxBase = 64 - suffix.length - 1;
    final base = key.length > maxBase ? key.substring(0, maxBase) : key;
    return '${base}_$suffix';
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-roles-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  Future<void> _save() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;
    final unknown = _selectedPermissions
        .where((key) => !PermissionKeys.all.contains(key))
        .toList();
    if (unknown.isNotEmpty) {
      setState(() => _saveError = kCustomRoleEditorUnknownKeyMessage);
      return;
    }
    if (_selectedPermissions.isEmpty) {
      setState(
        () => _saveError = 'Pick at least one permission for this role.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final permissions = _selectedPermissions
          .map(
            (key) =>
                TeamRolePermissionUpdate(permissionKey: key, effect: 'allow'),
          )
          .toList(growable: false);
      TeamRoleCatalogEntry saved;
      if (_isCreate) {
        final created = await widget.gateway.createRole(
          TeamRoleCreateCommand(
            actorUserId: widget.session.uid,
            operatorId: widget.session.operatorId,
            locationId: widget.session.primaryLocationId,
            roleKey: _deriveRoleKey(_displayNameController.text.trim()),
            displayName: _displayNameController.text.trim(),
            description: _descriptionController.text.trim(),
            permissions: permissions,
            reason: 'op_web_roles_create',
          ),
          idempotencyKey: _nextIdempotencyKey(),
        );
        saved = created.role;
      } else {
        final patched = await widget.gateway.patchRole(
          TeamRolePatchCommand(
            actorUserId: widget.session.uid,
            operatorId: widget.session.operatorId,
            locationId: widget.session.primaryLocationId,
            roleId: widget.existing!.roleId,
            displayName: _displayNameController.text.trim(),
            description: _descriptionController.text.trim(),
            permissions: _diffPermissions(),
            reason: 'op_web_roles_patch',
          ),
          idempotencyKey: _nextIdempotencyKey(),
        );
        saved = patched.role;
      }
      if (!mounted) return;
      widget.onSaved?.call(saved);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isCreate
                ? 'Role "${saved.displayName}" created.'
                : 'Role "${saved.displayName}" updated.',
          ),
        ),
      );
      if (widget.onClose != null) {
        widget.onClose!();
      } else if (Navigator.canPop(context)) {
        Navigator.of(context).pop(saved);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _saveError = _friendlySaveError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<TeamRolePermissionUpdate> _diffPermissions() {
    final existing = widget.existing;
    if (existing == null) {
      return _selectedPermissions
          .map(
            (key) =>
                TeamRolePermissionUpdate(permissionKey: key, effect: 'allow'),
          )
          .toList(growable: false);
    }
    final existingAllow = <String>{
      for (final rule in existing.permissions)
        if (rule.effect == 'allow') rule.permissionKey,
    };
    final updates = <TeamRolePermissionUpdate>[];
    for (final key in _selectedPermissions) {
      if (!existingAllow.contains(key)) {
        updates.add(
          TeamRolePermissionUpdate(permissionKey: key, effect: 'allow'),
        );
      }
    }
    for (final key in existingAllow) {
      if (!_selectedPermissions.contains(key)) {
        // `null` effect tells the gateway to clear the rule; falls
        // back to inherited behaviour per the catalog.
        updates.add(TeamRolePermissionUpdate(permissionKey: key, effect: null));
      }
    }
    return updates;
  }

  String _friendlySaveError(Object error) {
    if (error is WebTeamRolesError) {
      if (error.code == 'permission_key_unknown' ||
          error.code == 'validation_failed') {
        return kCustomRoleEditorUnknownKeyMessage;
      }
      return 'Could not save the role (${error.code}). Try again in a '
          'moment, or refresh the page if the problem keeps happening.';
    }
    return 'Could not save the role. Try again in a moment, or refresh '
        'the page if the problem keeps happening.';
  }

  void _togglePermission(String key, bool selected) {
    setState(() {
      if (selected) {
        _selectedPermissions.add(key);
      } else {
        _selectedPermissions.remove(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('operator_web_custom_role_editor_screen'),
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundSurface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: IconButton(
          key: const Key('operator_web_custom_role_editor_back'),
          icon: const Icon(Icons.arrow_back, size: 18),
          onPressed: widget.onClose ?? () => Navigator.of(context).maybePop(),
          tooltip: 'Back to Roles & permissions',
        ),
        title: Text(
          _isCreate ? 'New custom role' : 'Edit role',
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _MetaCard(
                  readOnly: widget.readOnly,
                  displayNameController: _displayNameController,
                  descriptionController: _descriptionController,
                ),
                const SizedBox(height: 16),
                _PermissionPickerCard(
                  selected: _selectedPermissions,
                  readOnly: widget.readOnly,
                  barrioPlanIncluded: _barrioPlanIncluded,
                  onToggle: _togglePermission,
                ),
                Builder(builder: (context) {
                  final warnings = widget.validator.validate(
                    _selectedPermissions,
                    scope: widget.roleScope,
                    roleDisplayName: _displayNameController.text,
                  );
                  final roleId = widget.existing?.roleId;
                  final visibleWarnings = warnings
                      .where(
                        (w) => !widget.dismissalStore.isDismissed(
                          roleId: roleId,
                          warning: w,
                        ),
                      )
                      .toList(growable: false);
                  if (visibleWarnings.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _RoleWarningPanel(
                      warnings: visibleWarnings,
                      onDismiss: (warning) async {
                        await widget.dismissalStore.dismiss(
                          roleId: roleId,
                          warning: warning,
                        );
                        if (!mounted) return;
                        setState(() {});
                      },
                    ),
                  );
                }),
                if (_saveError != null) ...<Widget>[
                  const SizedBox(height: 14),
                  _SaveErrorPanel(message: _saveError!),
                ],
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    OutlinedButton(
                      key: const Key('operator_web_custom_role_editor_cancel'),
                      onPressed: _saving
                          ? null
                          : (widget.onClose ??
                                () => Navigator.of(context).maybePop()),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.sunsetDark,
                        side: const BorderSide(
                          color: AppColors.sunsetDark,
                          width: 1,
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      key: const Key('operator_web_custom_role_editor_save'),
                      onPressed: _canSave && !_saving ? _save : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.sunset,
                        foregroundColor: AppColors.backgroundSurface,
                        disabledBackgroundColor: AppColors.borderSubtle,
                        disabledForegroundColor: AppColors.textMuted,
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.backgroundSurface,
                              ),
                            )
                          : Text(_isCreate ? 'Create role' : 'Save changes'),
                    ),
                    const Spacer(),
                    Text(
                      '${_selectedPermissions.length} '
                      '${_selectedPermissions.length == 1 ? 'permission' : 'permissions'} '
                      'selected',
                      key: const Key('operator_web_custom_role_editor_count'),
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _RoleEditorProduct {
  forgeFlow(label: 'Forge & Flow'),
  barrio(label: 'Barrio');

  const _RoleEditorProduct({required this.label});

  final String label;
}

_RoleEditorProduct _productForPermission(String permissionKey) {
  if (permissionKey == PermissionKeys.productBarrioAccess ||
      permissionKey.startsWith('barrio.')) {
    return _RoleEditorProduct.barrio;
  }
  return _RoleEditorProduct.forgeFlow;
}

String _resourceLabelForPermission(String permissionKey) {
  if (permissionKey == PermissionKeys.productForgeflowAccess ||
      permissionKey == PermissionKeys.productBarrioAccess) {
    return 'Product access';
  }
  final parts = permissionKey.split('.');
  if (parts.length < 2) return permissionKey;
  final product = _productForPermission(permissionKey);
  final resourceParts = switch (product) {
    _RoleEditorProduct.forgeFlow when parts.first == 'forgeflow' =>
      parts.skip(1).take(1),
    _RoleEditorProduct.barrio when parts.first == 'barrio' =>
      parts.skip(1).take(1),
    _ => parts.take(parts.length - 1),
  };
  return resourceParts.map(_titleCasePermissionPart).join(' ');
}

String _titleCasePermissionPart(String part) {
  return part
      .split('_')
      .where((token) => token.isNotEmpty)
      .map((token) {
        if (token.length == 1) return token.toUpperCase();
        return token.substring(0, 1).toUpperCase() +
            token.substring(1).toLowerCase();
      })
      .join(' ');
}

List<String> _orderedPermissionKeysForProduct(_RoleEditorProduct product) {
  final byCategory = permissionExplainerByCategory();
  final keys = <String>[];
  for (final category in kPermissionExplainerCategories) {
    for (final key in byCategory[category] ?? const <String>[]) {
      if (_productForPermission(key) == product) keys.add(key);
    }
  }
  return keys;
}

Map<String, List<String>> _permissionKeysByResource(
  _RoleEditorProduct product,
) {
  final grouped = <String, List<String>>{};
  for (final key in _orderedPermissionKeysForProduct(product)) {
    grouped
        .putIfAbsent(_resourceLabelForPermission(key), () => <String>[])
        .add(key);
  }
  return grouped;
}

class _MetaCard extends StatelessWidget {
  const _MetaCard({
    required this.readOnly,
    required this.displayNameController,
    required this.descriptionController,
  });

  final bool readOnly;
  final TextEditingController displayNameController;
  final TextEditingController descriptionController;

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
          Text(
            'Role details',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pick a name and short description so your team knows what '
            'this role is for. Names show on Team members.',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          TextFormField(
            key: const Key('operator_web_custom_role_editor_display_name'),
            controller: displayNameController,
            enabled: !readOnly,
            decoration: const InputDecoration(
              labelText: 'Role name',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Role name is required.';
              }
              if (value.trim().length > 80) {
                return 'Keep the role name under 80 characters.';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('operator_web_custom_role_editor_description'),
            controller: descriptionController,
            enabled: !readOnly,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Description',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            validator: (value) {
              if (value != null && value.length > 500) {
                return 'Keep the description under 500 characters.';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }
}

class _PermissionPickerCard extends StatefulWidget {
  const _PermissionPickerCard({
    required this.selected,
    required this.readOnly,
    required this.barrioPlanIncluded,
    required this.onToggle,
  });

  final Set<String> selected;
  final bool readOnly;
  final bool barrioPlanIncluded;
  final void Function(String key, bool selected) onToggle;

  @override
  State<_PermissionPickerCard> createState() => _PermissionPickerCardState();
}

class _PermissionPickerCardState extends State<_PermissionPickerCard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: _RoleEditorProduct.values.length,
    vsync: this,
  );

  _RoleEditorProduct _activeProduct = _RoleEditorProduct.forgeFlow;

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final product = _activeProduct;
    final productDisabled =
        product == _RoleEditorProduct.barrio && !widget.barrioPlanIncluded;
    return Container(
      key: const Key('operator_web_custom_role_editor_permissions'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              color: AppColors.cardGlow,
              border: Border(
                bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Permissions',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pick the permissions this role grants. Lock chips '
                  'mark permissions that need multi-factor authentication.',
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          TabBar(
            key: const Key('operator_web_custom_role_editor_product_tabs'),
            controller: _tabController,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textMuted,
            indicatorColor: AppColors.sunset,
            onTap: (index) {
              setState(() => _activeProduct = _RoleEditorProduct.values[index]);
            },
            tabs: const <Widget>[
              Tab(
                key: Key('operator_web_custom_role_editor_tab_forgeflow'),
                text: 'Forge & Flow',
              ),
              Tab(
                key: Key('operator_web_custom_role_editor_tab_barrio'),
                text: 'Barrio',
              ),
            ],
          ),
          if (productDisabled)
            const _DormantProductNotice(
              key: Key('operator_web_custom_role_editor_barrio_coming_soon'),
            ),
          for (final entry in _permissionKeysByResource(product).entries)
            _PickerResourceSection(
              key: Key(
                'operator_web_custom_role_editor_resource_'
                '${product.name}_${entry.key}',
              ),
              resourceLabel: entry.key,
              permissionKeys: entry.value,
              selected: widget.selected,
              readOnly: widget.readOnly || productDisabled,
              onToggle: widget.onToggle,
            ),
        ],
      ),
    );
  }
}

class _DormantProductNotice extends StatelessWidget {
  const _DormantProductNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.32),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Coming soon. Barrio permissions are visible for planning, '
              'but this operator plan does not include Barrio yet.',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerResourceSection extends StatelessWidget {
  const _PickerResourceSection({
    super.key,
    required this.resourceLabel,
    required this.permissionKeys,
    required this.selected,
    required this.readOnly,
    required this.onToggle,
  });

  final String resourceLabel;
  final List<String> permissionKeys;
  final Set<String> selected;
  final bool readOnly;
  final void Function(String key, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    final selectedInCategory = permissionKeys.where(selected.contains).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  resourceLabel,
                  style: AppTextStyles.mono12(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$selectedInCategory / ${permissionKeys.length}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final permissionKey in permissionKeys)
            _PermissionCheckbox(
              key: Key('operator_web_custom_role_editor_perm_$permissionKey'),
              permissionKey: permissionKey,
              selected: selected.contains(permissionKey),
              readOnly: readOnly,
              onChanged: (value) => onToggle(permissionKey, value ?? false),
            ),
        ],
      ),
    );
  }
}

class _PermissionCheckbox extends StatelessWidget {
  const _PermissionCheckbox({
    super.key,
    required this.permissionKey,
    required this.selected,
    required this.readOnly,
    required this.onChanged,
  });

  final String permissionKey;
  final bool selected;
  final bool readOnly;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final description =
        kPermissionExplainerDescriptions[permissionKey] ?? permissionKey;
    final requiresMfa = PermissionKeys.requiresMfa.contains(permissionKey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Checkbox(value: selected, onChanged: readOnly ? null : onChanged),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        permissionKey,
                        style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (requiresMfa) ...<Widget>[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: kPermissionExplainerMfaTooltip,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withValues(alpha: 0.12),
                            border: Border.all(
                              color: AppColors.warning.withValues(alpha: 0.45),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Icon(
                                Icons.lock_outline,
                                size: 11,
                                color: AppColors.warning,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                'MFA',
                                style: AppTextStyles.mono8(
                                  color: AppColors.warning,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  description,
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

/// Inline advisory panel for [RoleWarning]s emitted by
/// [CustomRoleValidator]. Warnings are advisory only - the save
/// button stays enabled regardless of how many warnings render. Each
/// row carries a "Don't show this warning again for this role"
/// affordance that fires [onDismiss] for the operator to persist via
/// the editor's [RoleWarningDismissalStore].
class _RoleWarningPanel extends StatelessWidget {
  const _RoleWarningPanel({
    required this.warnings,
    required this.onDismiss,
  });

  final List<RoleWarning> warnings;
  final ValueChanged<RoleWarning> onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_custom_role_editor_warnings'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.info_outline,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Heads up: this role has ${warnings.length} '
                  '${warnings.length == 1 ? 'thing' : 'things'} '
                  'worth a second look',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'You can save anyway. These notes call out permission '
            'combinations that may hide the screen the role needs.',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RoleWarningRow(
                warning: warning,
                onDismiss: () => onDismiss(warning),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoleWarningRow extends StatelessWidget {
  const _RoleWarningRow({
    required this.warning,
    required this.onDismiss,
  });

  final RoleWarning warning;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(
        'operator_web_custom_role_editor_warning_${warning.code.name}',
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            warning.message,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              for (final key in warning.affectedKeys)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.cardGlow,
                    border: Border.all(
                      color: AppColors.borderSubtle,
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    key,
                    style: AppTextStyles.mono10(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: Key(
                'operator_web_custom_role_editor_warning_dismiss_'
                '${warning.code.name}',
              ),
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textMuted,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                "Don't show this for this role",
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveErrorPanel extends StatelessWidget {
  const _SaveErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_custom_role_editor_error'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 18, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
