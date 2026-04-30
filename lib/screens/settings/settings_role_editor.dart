// Phase 9.UX.2 — Settings → Team → Roles editor.
//
// Modal create/edit dialog for operator-scoped custom roles backed by
// the B17 `/v1/admin/auth/roles` route (POST + PATCH). The dialog is
// stateless about transport — it collects display name, description,
// and an `allow / deny / inherit` choice per permission key, then
// returns a [TeamRoleEditorResult] that the caller funnels through
// `auth_operations_gateway.dart`.
//
// Seeded roles are read-only at the catalog level. The editor still
// renders for them in a "view only" form so an operator can inspect
// what a seeded role grants before deciding whether to clone or
// custom-build alongside.

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../../theme/app_theme.dart';

enum SettingsRolePermissionState { allow, deny, inherit }

class SettingsRolePermissionDraft {
  const SettingsRolePermissionDraft({
    required this.permissionKey,
    required this.state,
  });

  final String permissionKey;
  final SettingsRolePermissionState state;

  TeamRolePermissionUpdate? toUpdate(SettingsRolePermissionState? previous) {
    if (state == previous) return null;
    return TeamRolePermissionUpdate(
      permissionKey: permissionKey,
      effect: switch (state) {
        SettingsRolePermissionState.allow => 'allow',
        SettingsRolePermissionState.deny => 'deny',
        SettingsRolePermissionState.inherit => null,
      },
    );
  }
}

/// Outcome of a successful editor save. Consumers map this back to
/// their gateway-facing `TeamRoleCreate`/`TeamRolePatch` calls.
class SettingsRoleEditorResult {
  const SettingsRoleEditorResult({
    required this.isCreate,
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.permissionUpdates,
  });

  final bool isCreate;

  /// Stable backend id for an existing role; empty on create.
  final String roleId;

  /// Operator-chosen short key (e.g. `kitchen_lead`). Immutable after
  /// create — patches do not let operators rewrite the key.
  final String roleKey;
  final String displayName;
  final String description;
  final List<TeamRolePermissionUpdate> permissionUpdates;
}

/// Submission callback. Returns `null` when the save fails so the
/// editor can re-enable the form and surface an error message.
typedef SettingsRoleEditorSubmit =
    Future<TeamRoleCatalogEntry?> Function(SettingsRoleEditorResult result);

class SettingsRoleEditorDialog extends StatefulWidget {
  const SettingsRoleEditorDialog({
    super.key,
    required this.role,
    required this.onSubmit,
    this.permissionKeys = const <String>{},
    this.readOnly = false,
  });

  /// `null` → create flow. Existing entry → edit flow. Seeded or
  /// otherwise non-editable roles still pass `role` here, but the
  /// caller sets [readOnly] so the form fields and Save button stay
  /// inert.
  final TeamRoleCatalogEntry? role;

  final SettingsRoleEditorSubmit onSubmit;

  /// Permission key catalog to expose. Defaults to the frozen 96-key
  /// catalog defined in [PermissionKeys.all].
  final Set<String> permissionKeys;

  /// When true, Save is hidden and every text + permission control is
  /// disabled regardless of [TeamRoleCatalogEntry.isEditable]. The
  /// catalog section uses this for the **View** affordance offered to
  /// actors who only hold `team.roles.view`, and for seeded roles that
  /// the operator UI cannot mutate even when `is_editable=true` in the
  /// payload (only super_admin's `admin.roles.edit_seeded` path edits
  /// seeded roles, and that lives outside this surface).
  final bool readOnly;

  @override
  State<SettingsRoleEditorDialog> createState() =>
      _SettingsRoleEditorDialogState();
}

class _SettingsRoleEditorDialogState extends State<SettingsRoleEditorDialog> {
  late final TextEditingController _roleKey;
  late final TextEditingController _displayName;
  late final TextEditingController _description;
  late final Map<String, SettingsRolePermissionState> _initialStates;
  late Map<String, SettingsRolePermissionState> _states;
  bool _busy = false;
  String? _error;

  bool get _isCreate => widget.role == null;
  bool get _isEditable {
    if (widget.readOnly) return false;
    return widget.role?.isEditable ?? true;
  }

  @override
  void initState() {
    super.initState();
    final role = widget.role;
    _roleKey = TextEditingController(text: role?.roleKey ?? '');
    _displayName = TextEditingController(text: role?.displayName ?? '');
    _description = TextEditingController(text: role?.description ?? '');
    _roleKey.addListener(_handleTextChanged);
    _displayName.addListener(_handleTextChanged);
    _initialStates = _statesFromRole(role);
    _states = Map<String, SettingsRolePermissionState>.from(_initialStates);
  }

  Map<String, SettingsRolePermissionState> _statesFromRole(
    TeamRoleCatalogEntry? role,
  ) {
    final catalog = widget.permissionKeys.isEmpty
        ? PermissionKeys.all
        : widget.permissionKeys;
    final map = <String, SettingsRolePermissionState>{
      for (final key in catalog) key: SettingsRolePermissionState.inherit,
    };
    if (role == null) return map;
    for (final rule in role.permissions) {
      map[rule.permissionKey] = rule.effect == 'deny'
          ? SettingsRolePermissionState.deny
          : SettingsRolePermissionState.allow;
    }
    return map;
  }

  @override
  void dispose() {
    _roleKey.removeListener(_handleTextChanged);
    _displayName.removeListener(_handleTextChanged);
    _roleKey.dispose();
    _displayName.dispose();
    _description.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  bool get _canSubmit {
    if (!_isEditable) return false;
    if (_displayName.text.trim().isEmpty) return false;
    if (_isCreate) {
      final key = _roleKey.text.trim();
      if (key.isEmpty) return false;
      // Mirrors `lib/services/auth/repository_auth_operations_gateway.dart`
      // role-key validation so the operator does not round-trip the
      // proxy to learn the rule. 3–64 chars, lowercase letter prefix,
      // a–z / 0–9 / underscore body.
      if (!RegExp(r'^[a-z][a-z0-9_]{2,63}$').hasMatch(key)) return false;
    }
    return true;
  }

  Future<void> _submit() async {
    if (!_canSubmit || _busy) return;
    final updates = <TeamRolePermissionUpdate>[];
    for (final entry in _states.entries) {
      final previous = _initialStates[entry.key];
      final draft = SettingsRolePermissionDraft(
        permissionKey: entry.key,
        state: entry.value,
      );
      final update = draft.toUpdate(previous);
      if (update != null) updates.add(update);
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = SettingsRoleEditorResult(
      isCreate: _isCreate,
      roleId: widget.role?.roleId ?? '',
      roleKey: _isCreate ? _roleKey.text.trim() : widget.role!.roleKey,
      displayName: _displayName.text.trim(),
      description: _description.text.trim(),
      permissionUpdates: updates,
    );
    try {
      final saved = await widget.onSubmit(result);
      if (!mounted) return;
      if (saved == null) {
        setState(() {
          _busy = false;
          _error = 'Role could not be saved. Please try again.';
        });
        return;
      }
      Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Role could not be saved. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    final title = _isCreate
        ? 'New custom role'
        : (_isEditable ? 'Edit role' : 'View role');
    final protectedRole = role != null && !_isEditable ? role : null;
    final keysByCategory = _groupKeysByCategory(_states.keys);
    final media = MediaQuery.of(context);
    final dialogWidth = media.size.width.clamp(320.0, 520.0);
    final maxBodyHeight = media.size.height * 0.65;

    return AlertDialog(
      key: const Key('settings_role_editor_dialog'),
      title: Text(title),
      content: SizedBox(
        width: dialogWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxBodyHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (protectedRole != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${protectedRole.roleKey} cannot be edited from this '
                      'surface.',
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                  ),
                if (_isCreate)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      key: const Key('settings_role_editor_role_key'),
                      controller: _roleKey,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Role key (a-z, 0-9, underscore)',
                        helperText: 'kitchen_lead, prep_supervisor, …',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                TextField(
                  key: const Key('settings_role_editor_display_name'),
                  controller: _displayName,
                  enabled: !_busy && _isEditable,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('settings_role_editor_description'),
                  controller: _description,
                  enabled: !_busy && _isEditable,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Permissions',
                  style: AppTextStyles.body13(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Each key resolves to allow, deny, or inherit. Deny '
                  'wins; inherit falls back to other grants.',
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                const SizedBox(height: 8),
                for (final entry in keysByCategory.entries)
                  _CategoryGroup(
                    title: _categoryLabel(entry.key),
                    keys: entry.value,
                    states: _states,
                    enabled: !_busy && _isEditable,
                    onChanged: (key, next) {
                      if (!_isEditable) return;
                      setState(() => _states[key] = next);
                    },
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      key: const Key('settings_role_editor_error'),
                      style: AppTextStyles.body12(color: AppColors.negative),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('settings_role_editor_cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(_isEditable ? 'Cancel' : 'Close'),
        ),
        if (_isEditable)
          FilledButton(
            key: const Key('settings_role_editor_save'),
            onPressed: _canSubmit && !_busy ? _submit : null,
            child: Text(_busy ? 'Saving…' : 'Save'),
          ),
      ],
    );
  }

  Map<String, List<String>> _groupKeysByCategory(Iterable<String> keys) {
    final groups = <String, List<String>>{};
    for (final key in keys) {
      final dot = key.indexOf('.');
      final category = dot < 0 ? 'other' : key.substring(0, dot);
      groups.putIfAbsent(category, () => <String>[]).add(key);
    }
    for (final list in groups.values) {
      list.sort();
    }
    return Map<String, List<String>>.fromEntries(
      groups.entries.toList()..sort((a, b) => _categoryOrder(a.key).compareTo(
            _categoryOrder(b.key),
          )),
    );
  }

  static int _categoryOrder(String category) {
    return switch (category) {
      'product' => 0,
      'forgeflow' => 1,
      'barrio' => 2,
      'team' => 3,
      'admin' => 4,
      'billing' => 5,
      'integration' => 6,
      'workflow' => 7,
      _ => 8,
    };
  }

  static String _categoryLabel(String category) {
    return switch (category) {
      'product' => 'Product access',
      'forgeflow' => 'Forge & Flow',
      'barrio' => 'Barrio',
      'team' => 'Team',
      'admin' => 'Admin',
      'billing' => 'Billing',
      'integration' => 'Integrations',
      'workflow' => 'Workflows',
      _ => category,
    };
  }
}

class _CategoryGroup extends StatefulWidget {
  const _CategoryGroup({
    required this.title,
    required this.keys,
    required this.states,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final List<String> keys;
  final Map<String, SettingsRolePermissionState> states;
  final bool enabled;
  final void Function(String key, SettingsRolePermissionState state) onChanged;

  @override
  State<_CategoryGroup> createState() => _CategoryGroupState();
}

class _CategoryGroupState extends State<_CategoryGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    var allowCount = 0;
    var denyCount = 0;
    for (final key in widget.keys) {
      switch (widget.states[key]) {
        case SettingsRolePermissionState.allow:
          allowCount += 1;
        case SettingsRolePermissionState.deny:
          denyCount += 1;
        default:
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: Key('settings_role_editor_category_${widget.title}'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (allowCount > 0) ...[
                      _CountBadge(
                        label: '$allowCount allow',
                        color: AppColors.positive,
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (denyCount > 0)
                      _CountBadge(
                        label: '$denyCount deny',
                        color: AppColors.negative,
                      ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              for (final key in widget.keys)
                _PermissionRow(
                  permissionKey: key,
                  state:
                      widget.states[key] ?? SettingsRolePermissionState.inherit,
                  enabled: widget.enabled,
                  onChanged: (next) => widget.onChanged(key, next),
                ),
          ],
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.permissionKey,
    required this.state,
    required this.enabled,
    required this.onChanged,
  });

  final String permissionKey;
  final SettingsRolePermissionState state;
  final bool enabled;
  final ValueChanged<SettingsRolePermissionState> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            permissionKey,
            style: AppTextStyles.body12(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          SegmentedButton<SettingsRolePermissionState>(
            key: Key('settings_role_editor_perm_$permissionKey'),
            segments: const [
              ButtonSegment<SettingsRolePermissionState>(
                value: SettingsRolePermissionState.allow,
                label: Text('Allow'),
              ),
              ButtonSegment<SettingsRolePermissionState>(
                value: SettingsRolePermissionState.deny,
                label: Text('Deny'),
              ),
              ButtonSegment<SettingsRolePermissionState>(
                value: SettingsRolePermissionState.inherit,
                label: Text('Inherit'),
              ),
            ],
            showSelectedIcon: false,
            selected: <SettingsRolePermissionState>{state},
            onSelectionChanged: enabled
                ? (selection) => onChanged(selection.first)
                : null,
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono7(color: color),
      ),
    );
  }
}
