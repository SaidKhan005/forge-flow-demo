// Phase 9.UX.3 — Settings → Team → Explain permissions.
//
// Read-only consumer of the permission resolver. Lets an operator with
// `team.users.view` pick a target user and a permission key and see
// the resolution chain (per role grant) plus the final effect that
// `lib/auth/permission_resolution.dart` would return for the same
// (actor + key + scope) tuple.
//
// Hard guardrails (mirror the Phase 9.UX.3 prompt):
//   * The resolver is the single source of truth for the final
//     effect — we call `PermissionResolver.resolve()`. Only the
//     per-step trace is rendered above the final pill.
//   * No new permission keys, no new gateway methods, no new proxy
//     routes. The screen consumes the role catalog + org hierarchy
//     options the parent already loaded for the Team tab.
//   * Pure UI consumer — the file does not touch
//     `lib/services/auth/`, the postgres layer, db migrations, or the
//     proxy.
//   * The screen is gated on `team.users.view` (existing key) at the
//     entry point in `team_settings_section.dart`. The screen itself
//     also short-circuits to a polite refusal banner if it ever
//     receives an actor without that key.

import 'package:flutter/material.dart';

import '../../auth/permission_effect.dart';
import '../../auth/permission_keys.dart';
import '../../auth/permission_resolution.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../../services/team/team_scope_visibility_policy.dart';
import '../../theme/app_theme.dart';
import '../team/team_settings_section.dart';

/// Full-screen route reachable from the Team user-action menu's
/// "Explain permissions" entry. Renders a permission picker plus the
/// resolution chain for the selected permission key against the
/// target user's grants.
class SettingsPermissionExplainer extends StatefulWidget {
  const SettingsPermissionExplainer({
    super.key,
    required this.actor,
    required this.target,
    this.roleCatalog = const <TeamRoleCatalogEntry>[],
    this.orgUnitOptions = const <TeamOrgUnitOption>[],
    this.locationOptions = const <TeamLocationOption>[],
    this.initialPermissionKey,
    this.initialLocationId,
    DateTime? now,
  }) : _injectedNow = now;

  final TeamScopeActor actor;
  final TeamUserListItem target;
  final List<TeamRoleCatalogEntry> roleCatalog;
  final List<TeamOrgUnitOption> orgUnitOptions;
  final List<TeamLocationOption> locationOptions;

  /// Test seam — preselects the picker at open time.
  final String? initialPermissionKey;

  /// Test seam — preselects the scope picker. `null` → operator-wide.
  final String? initialLocationId;

  /// Test seam — pinned `now` for deterministic resolver output.
  final DateTime? _injectedNow;

  @override
  State<SettingsPermissionExplainer> createState() =>
      _SettingsPermissionExplainerState();
}

class _SettingsPermissionExplainerState
    extends State<SettingsPermissionExplainer> {
  late String _selectedKey;
  String? _selectedLocationId;

  static const String _operatorWideScopeId = '__operator_wide__';

  static const List<String> _categoryOrder = <String>[
    'product',
    'forgeflow',
    'barrio',
    'admin',
    'team',
    'billing',
    'integration',
    'workflow',
  ];

  @override
  void initState() {
    super.initState();
    _selectedKey = _resolveInitialKey();
    _selectedLocationId = _resolveInitialLocationId();
  }

  String _resolveInitialKey() {
    final candidate = widget.initialPermissionKey;
    if (candidate != null && PermissionKeys.all.contains(candidate)) {
      return candidate;
    }
    final keys = _orderedKeys();
    return keys.isEmpty ? '' : keys.first;
  }

  /// Initial location-context for the resolver. Only honors a candidate
  /// (the explicit `initialLocationId` or the target's primary
  /// `locationId`) when it actually appears in `locationOptions`. If
  /// the candidate is stale / missing, fall back to operator-wide so
  /// the dropdown never receives a value with no matching item (which
  /// would assert before the operator could switch scopes).
  String? _resolveInitialLocationId() {
    final candidate = widget.initialLocationId ?? widget.target.locationId;
    if (candidate == null) return null;
    for (final option in widget.locationOptions) {
      if (option.locationId == candidate) return candidate;
    }
    return null;
  }

  List<String> _orderedKeys() {
    final byCategory = <String, List<String>>{};
    for (final key in PermissionKeys.all) {
      final category = _categoryOf(key);
      byCategory.putIfAbsent(category, () => <String>[]).add(key);
    }
    final ordered = <String>[];
    for (final category in _categoryOrder) {
      final keys = byCategory.remove(category);
      if (keys == null) continue;
      keys.sort();
      ordered.addAll(keys);
    }
    final remaining = byCategory.keys.toList()..sort();
    for (final category in remaining) {
      final keys = byCategory[category]!..sort();
      ordered.addAll(keys);
    }
    return ordered;
  }

  String _categoryOf(String key) {
    final dot = key.indexOf('.');
    return dot < 0 ? key : key.substring(0, dot);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.actor.actorPermissions.contains('team.users.view')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Explain permissions')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'You do not have permission to view team membership.',
            style: AppTextStyles.body14(color: AppColors.textMuted),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Explain permissions',
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.backgroundSurface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      backgroundColor: AppColors.backgroundDeep,
      body: SingleChildScrollView(
        key: const Key('settings_permission_explainer'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TargetHeader(
              target: widget.target,
              explainerGrantCount: _explainerGrants().length,
            ),
            const SizedBox(height: 16),
            _PermissionPicker(
              keys: _orderedKeys(),
              selectedKey: _selectedKey,
              onChanged: (key) => setState(() => _selectedKey = key),
            ),
            const SizedBox(height: 12),
            _ScopePicker(
              locationOptions: widget.locationOptions,
              selectedLocationId: _selectedLocationId,
              operatorWideId: _operatorWideScopeId,
              onChanged: (value) => setState(() {
                _selectedLocationId =
                    value == _operatorWideScopeId ? null : value;
              }),
            ),
            const SizedBox(height: 20),
            _ResolutionChainHeader(permissionKey: _selectedKey),
            const SizedBox(height: 8),
            _ResolutionChain(
              target: widget.target,
              grants: _explainerGrants(),
              permissionKey: _selectedKey,
              roleCatalog: widget.roleCatalog,
              orgUnitOptions: widget.orgUnitOptions,
              locationOptions: widget.locationOptions,
              selectedLocationId: _selectedLocationId,
            ),
            const SizedBox(height: 20),
            _FinalEffectPill(
              effect: _resolveFinalEffect(),
              hasMatchingGrant: _hasMatchingGrant(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  PermissionEffect _resolveFinalEffect() {
    if (!PermissionKeys.all.contains(_selectedKey)) {
      return PermissionEffect.deny;
    }
    final grants = _explainerGrants().map((eg) => eg.toResolverGrant(
          userId: widget.target.userId,
          operatorId: widget.actor.actorOperatorId,
        ));
    final rules = _convertedRules();
    return PermissionResolver.resolve(
      permissionKey: _selectedKey,
      grants: grants,
      rules: rules,
      operatorId: widget.actor.actorOperatorId,
      locationId: _selectedLocationId ?? '',
      now: widget._injectedNow ?? DateTime.now(),
    );
  }

  /// `true` iff at least one of the target's grants both (a) covers
  /// the currently selected scope and (b) references a role rule for
  /// the selected permission key. Drives the "Not granted" vs
  /// "Deny" copy on the final-effect pill so the operator can tell
  /// the difference between "no rule applies at this scope" and "an
  /// explicit deny rule wins."
  bool _hasMatchingGrant() {
    if (!PermissionKeys.all.contains(_selectedKey)) return false;
    final locationId = _selectedLocationId ?? '';
    for (final eg in _explainerGrants()) {
      final grant = eg.grant;
      if (!_grantCoversLocation(grant, locationId)) continue;
      final role = _roleFor(grant.roleId);
      if (role == null) continue;
      for (final rule in role.permissions) {
        if (rule.permissionKey == _selectedKey) return true;
      }
    }
    return false;
  }

  bool _grantCoversLocation(TeamUserRoleGrant grant, String requestedLocation) {
    switch (grant.scopeType) {
      case 'operator_wide':
        return true;
      case 'location':
        return grant.locationId == requestedLocation;
      case 'org_unit':
        return grant.effectiveLocationIds.contains(requestedLocation);
      default:
        return false;
    }
  }

  /// Returns the grants the explainer should reason over. When the
  /// upstream `TeamUserListEntry` already carries an authoritative
  /// grant set (post `9.UX.6` / gateway grant-list slice), we use it
  /// as-is. When it is empty — the production path today, see the
  /// note on `_teamUserFromEntry` in `forge_flow_app.dart` — we
  /// synthesize one fallback grant from the entry's primary `roleId`
  /// + `userRoleId` so the screen still resolves against the user's
  /// real role rather than reporting "No matching grant" +
  /// default-deny for every key.
  ///
  /// **Synthesis is always `operator_wide`.** The `TeamUserListEntry`
  /// shape projects `coalesce(ur.location_id, u.primary_location_id)`
  /// into `entry.locationId`, so a non-null `target.locationId` is
  /// ambiguous: it can be either a `location`-scoped grant's
  /// `ur.location_id` OR an operator-wide grant attached to a user
  /// with a primary location. Synthesizing as `'location'` would
  /// silently drop operator-wide grants at every other scope (the
  /// resolver's `coversLocation` filter excludes them) and the final
  /// pill would say "Not granted" even though the real
  /// `PermissionResolver` with the authoritative grant would allow.
  /// `'operator_wide'` is the safer floor: the role's rules surface
  /// at every scope, and the inline hint on the row tells the
  /// operator the trace is approximate. The exact answer arrives
  /// when the upstream gateway slice populates the real grant set.
  List<_ExplainerGrant> _explainerGrants() {
    if (widget.target.grants.isNotEmpty) {
      return widget.target.grants
          .map((grant) => _ExplainerGrant(grant: grant, isSynthesized: false))
          .toList(growable: false);
    }
    if (widget.target.userRoleId == null) {
      return const <_ExplainerGrant>[];
    }
    final fallback = TeamUserRoleGrant(
      userRoleId: widget.target.userRoleId!,
      roleId: widget.target.roleId,
      roleLabel: widget.target.roleLabel,
      scopeType: 'operator_wide',
    );
    return <_ExplainerGrant>[
      _ExplainerGrant(grant: fallback, isSynthesized: true),
    ];
  }

  Iterable<RolePermissionRule> _convertedRules() {
    return widget.roleCatalog.expand((role) {
      return role.permissions.map((rule) {
        return RolePermissionRule(
          roleId: role.roleId,
          permissionKey: rule.permissionKey,
          effect: rule.effect == 'deny'
              ? PermissionEffect.deny
              : PermissionEffect.allow,
        );
      });
    });
  }

  TeamRoleCatalogEntry? _roleFor(String roleId) {
    for (final role in widget.roleCatalog) {
      if (role.roleId == roleId) return role;
    }
    return null;
  }
}

class _TargetHeader extends StatelessWidget {
  const _TargetHeader({
    required this.target,
    required this.explainerGrantCount,
  });

  final TeamUserListItem target;
  final int explainerGrantCount;

  @override
  Widget build(BuildContext context) {
    final grantsLabel = explainerGrantCount == 0
        ? 'No grants'
        : '$explainerGrantCount grant'
              '${explainerGrantCount == 1 ? '' : 's'}';
    return Container(
      key: const Key('settings_permission_explainer_target_header'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(target.displayName, style: AppTextStyles.body14()),
          const SizedBox(height: 4),
          Text(
            target.email,
            style: AppTextStyles.mono12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _Chip(label: target.roleLabel, tone: _ChipTone.brand),
              if (target.locationLabel != null &&
                  target.locationLabel!.isNotEmpty)
                _Chip(label: target.locationLabel!, tone: _ChipTone.neutral),
              _Chip(label: grantsLabel, tone: _ChipTone.neutral),
            ],
          ),
        ],
      ),
    );
  }
}

class _PermissionPicker extends StatelessWidget {
  const _PermissionPicker({
    required this.keys,
    required this.selectedKey,
    required this.onChanged,
  });

  final List<String> keys;
  final String selectedKey;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = <DropdownMenuItem<String>>[];
    String? lastCategory;
    for (final key in keys) {
      final category = _categoryOf(key);
      if (category != lastCategory) {
        lastCategory = category;
      }
      items.add(
        DropdownMenuItem<String>(
          value: key,
          child: _PermissionPickerItem(
            permissionKey: key,
            categoryLabel: _categoryLabel(category),
          ),
        ),
      );
    }
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Permission',
        labelStyle: AppTextStyles.mono10(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderStrong),
        ),
        filled: true,
        fillColor: AppColors.backgroundSurface,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('settings_permission_explainer_picker'),
          isExpanded: true,
          value: keys.contains(selectedKey) ? selectedKey : null,
          items: items,
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ),
    );
  }

  String _categoryOf(String key) {
    final dot = key.indexOf('.');
    return dot < 0 ? key : key.substring(0, dot);
  }

  String _categoryLabel(String category) {
    switch (category) {
      case 'product':
        return 'Product';
      case 'forgeflow':
        return 'Forge & Flow';
      case 'barrio':
        return 'Barrio';
      case 'admin':
        return 'Admin';
      case 'team':
        return 'Team';
      case 'billing':
        return 'Billing';
      case 'integration':
        return 'Integration';
      case 'workflow':
        return 'Workflow';
      default:
        return category;
    }
  }
}

class _PermissionPickerItem extends StatelessWidget {
  const _PermissionPickerItem({
    required this.permissionKey,
    required this.categoryLabel,
  });

  final String permissionKey;
  final String categoryLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.cardGlow,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Text(
            categoryLabel,
            style: AppTextStyles.mono10(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            permissionKey,
            style: AppTextStyles.mono12(),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _ScopePicker extends StatelessWidget {
  const _ScopePicker({
    required this.locationOptions,
    required this.selectedLocationId,
    required this.operatorWideId,
    required this.onChanged,
  });

  final List<TeamLocationOption> locationOptions;
  final String? selectedLocationId;
  final String operatorWideId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem<String>(
        value: operatorWideId,
        child: Text('Operator-wide', style: AppTextStyles.body13()),
      ),
      for (final loc in locationOptions)
        DropdownMenuItem<String>(
          value: loc.locationId,
          child: Text(loc.label, style: AppTextStyles.body13()),
        ),
    ];
    final candidate = selectedLocationId;
    final hasCandidate = candidate == null
        ? true
        : locationOptions.any((opt) => opt.locationId == candidate);
    final dropdownValue = hasCandidate
        ? (candidate ?? operatorWideId)
        : operatorWideId;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Resolve at scope',
        labelStyle: AppTextStyles.mono10(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderStrong),
        ),
        filled: true,
        fillColor: AppColors.backgroundSurface,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('settings_permission_explainer_scope_picker'),
          isExpanded: true,
          value: dropdownValue,
          items: items,
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ),
    );
  }
}

class _ResolutionChainHeader extends StatelessWidget {
  const _ResolutionChainHeader({required this.permissionKey});

  final String permissionKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Resolution chain', style: AppTextStyles.mono11()),
        const SizedBox(width: 8),
        Expanded(
          child: Container(height: 1, color: AppColors.borderSubtle),
        ),
        const SizedBox(width: 8),
        Text(
          permissionKey,
          style: AppTextStyles.mono12(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// Lightweight wrapper carrying a [TeamUserRoleGrant] plus the
/// `isSynthesized` flag the explainer uses to mark fallback rows
/// (built when the upstream entry has no authoritative grant set).
class _ExplainerGrant {
  const _ExplainerGrant({required this.grant, required this.isSynthesized});

  final TeamUserRoleGrant grant;
  final bool isSynthesized;

  UserRoleGrant toResolverGrant({
    required String userId,
    required String operatorId,
  }) {
    return UserRoleGrant(
      userRoleId: grant.userRoleId,
      userId: userId,
      roleId: grant.roleId,
      operatorId: operatorId,
      validFrom: DateTime.utc(2000),
      scopeType: grant.scopeType,
      locationId: grant.locationId,
      orgUnitId: grant.orgUnitId,
      effectiveLocationIds: grant.effectiveLocationIds,
    );
  }
}

class _ResolutionChain extends StatelessWidget {
  const _ResolutionChain({
    required this.target,
    required this.grants,
    required this.permissionKey,
    required this.roleCatalog,
    required this.orgUnitOptions,
    required this.locationOptions,
    required this.selectedLocationId,
  });

  final TeamUserListItem target;
  final List<_ExplainerGrant> grants;
  final String permissionKey;
  final List<TeamRoleCatalogEntry> roleCatalog;
  final List<TeamOrgUnitOption> orgUnitOptions;
  final List<TeamLocationOption> locationOptions;
  final String? selectedLocationId;

  @override
  Widget build(BuildContext context) {
    if (grants.isEmpty) {
      return _ChainEmptyNotice(
        key: const Key('settings_permission_explainer_no_grants'),
        message: 'No matching grant — this user has no role grants.',
      );
    }
    if (!PermissionKeys.all.contains(permissionKey)) {
      return _ChainEmptyNotice(
        key: const Key('settings_permission_explainer_unknown_key'),
        message: 'Unknown permission key. Pick one from the catalog above.',
      );
    }
    final rows = <Widget>[];
    for (var i = 0; i < grants.length; i++) {
      final eg = grants[i];
      final grant = eg.grant;
      final role = _roleFor(grant.roleId);
      final ruleEffect = _ruleEffectFor(role, permissionKey);
      final scopeApplies = _scopeApplies(grant);
      rows.add(
        _ChainRow(
          key: Key('settings_permission_explainer_chain_${grant.userRoleId}'),
          grant: grant,
          role: role,
          ruleEffect: ruleEffect,
          scopeApplies: scopeApplies,
          scopeLabel: _scopeLabelFor(grant),
          permissionKey: permissionKey,
          isSynthesized: eg.isSynthesized,
        ),
      );
      if (i < grants.length - 1) {
        rows.add(const SizedBox(height: 8));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  TeamRoleCatalogEntry? _roleFor(String roleId) {
    for (final role in roleCatalog) {
      if (role.roleId == roleId) return role;
    }
    return null;
  }

  /// Returns the rule effect this role declares for [permissionKey],
  /// or `null` when the role has no explicit rule (inherits / no
  /// rule). Used by the chain row to render `Allow` / `Deny` /
  /// `Inherit (no rule)` per role.
  String? _ruleEffectFor(TeamRoleCatalogEntry? role, String permissionKey) {
    if (role == null) return null;
    for (final rule in role.permissions) {
      if (rule.permissionKey == permissionKey) {
        return rule.effect;
      }
    }
    return null;
  }

  bool _scopeApplies(TeamUserRoleGrant grant) {
    final loc = selectedLocationId;
    switch (grant.scopeType) {
      case 'operator_wide':
        return true;
      case 'location':
        if (loc == null) return false;
        return grant.locationId == loc;
      case 'org_unit':
        if (loc == null) return false;
        return grant.effectiveLocationIds.contains(loc);
      default:
        return false;
    }
  }

  String _scopeLabelFor(TeamUserRoleGrant grant) {
    switch (grant.scopeType) {
      case 'operator_wide':
        return 'Operator-wide';
      case 'location':
        return _locationLabel(grant.locationId) ?? 'Location (unknown)';
      case 'org_unit':
        final unit = _orgUnitLabel(grant.orgUnitId);
        if (unit == null) return 'Org unit (unknown)';
        final count = grant.effectiveLocationIds.length;
        if (count == 0) return unit;
        return '$unit ($count location${count == 1 ? '' : 's'})';
      default:
        return '${grant.scopeType} (unknown)';
    }
  }

  String? _locationLabel(String? locationId) {
    if (locationId == null) return null;
    for (final loc in locationOptions) {
      if (loc.locationId == locationId) return loc.label;
    }
    return null;
  }

  String? _orgUnitLabel(String? orgUnitId) {
    if (orgUnitId == null) return null;
    for (final unit in orgUnitOptions) {
      if (unit.orgUnitId == orgUnitId) return unit.label;
    }
    return null;
  }
}

class _ChainEmptyNotice extends StatelessWidget {
  const _ChainEmptyNotice({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline,
            size: 18,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChainRow extends StatelessWidget {
  const _ChainRow({
    super.key,
    required this.grant,
    required this.role,
    required this.ruleEffect,
    required this.scopeApplies,
    required this.scopeLabel,
    required this.permissionKey,
    this.isSynthesized = false,
  });

  final TeamUserRoleGrant grant;
  final TeamRoleCatalogEntry? role;
  final String? ruleEffect;
  final bool scopeApplies;
  final String scopeLabel;
  final String permissionKey;
  final bool isSynthesized;

  @override
  Widget build(BuildContext context) {
    final roleLabel = role?.displayName ?? grant.roleLabel;
    final ruleTone = _toneForRule(ruleEffect);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(roleLabel, style: AppTextStyles.body14()),
              ),
              _Chip(
                label: _ruleLabelFor(ruleEffect),
                tone: ruleTone,
                keyValue: Key(
                  'settings_permission_explainer_rule_${grant.userRoleId}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _ChainAttribute(label: 'Source role', value: roleLabel),
          _ChainAttribute(
            label: 'Scope',
            value: isSynthesized ? '$scopeLabel (inferred)' : scopeLabel,
          ),
          _ChainAttribute(
            label: 'Scope applies at selected location',
            value: scopeApplies ? 'Yes' : 'No — grant excluded at this scope',
            valueColor:
                scopeApplies ? AppColors.textPrimary : AppColors.textMuted,
          ),
          _ChainAttribute(
            label: 'Rule effect for $permissionKey',
            value: _ruleDescriptionFor(ruleEffect, role: role),
            valueColor: _toneColorFor(ruleTone),
          ),
          if (isSynthesized) ...[
            const SizedBox(height: 8),
            _SynthesizedGrantHint(
              key: Key(
                'settings_permission_explainer_synth_${grant.userRoleId}',
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _ruleLabelFor(String? effect) {
    switch (effect) {
      case 'allow':
        return 'Allow';
      case 'deny':
        return 'Deny';
      default:
        return 'Inherit';
    }
  }

  String _ruleDescriptionFor(
    String? effect, {
    required TeamRoleCatalogEntry? role,
  }) {
    if (role == null) return 'No matching role rule (role not in catalog)';
    switch (effect) {
      case 'allow':
        return 'Allow — the role grants this permission';
      case 'deny':
        return 'Deny — the role explicitly blocks this permission and wins '
            'over allow rules';
      default:
        return 'No rule on this role (inherits from defaults)';
    }
  }

  _ChipTone _toneForRule(String? effect) {
    switch (effect) {
      case 'allow':
        return _ChipTone.allow;
      case 'deny':
        return _ChipTone.deny;
      default:
        return _ChipTone.neutral;
    }
  }

  Color? _toneColorFor(_ChipTone tone) {
    switch (tone) {
      case _ChipTone.allow:
        return AppColors.positive;
      case _ChipTone.deny:
        return AppColors.negative;
      case _ChipTone.brand:
      case _ChipTone.neutral:
        return null;
    }
  }
}

class _ChainAttribute extends StatelessWidget {
  const _ChainAttribute({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              label,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body13(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline hint rendered on synthesized chain rows. Surfaces the
/// "scope inferred from primary grant" caveat so the operator knows
/// the row was derived from the entry's primary `roleId` /
/// `locationId` rather than an authoritative `user_roles` row. This
/// goes away as soon as the upstream gateway slice populates the
/// real grant set on `TeamUserListEntry`.
class _SynthesizedGrantHint extends StatelessWidget {
  const _SynthesizedGrantHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.warningBadgeBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline,
            size: 14,
            color: AppColors.warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Scope inferred from primary grant — full grant set is not '
              'yet projected onto this user.',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _FinalEffectPill extends StatelessWidget {
  const _FinalEffectPill({required this.effect, required this.hasMatchingGrant});

  final PermissionEffect effect;
  final bool hasMatchingGrant;

  @override
  Widget build(BuildContext context) {
    final isAllow = effect == PermissionEffect.allow;
    final isNotGranted = !isAllow && !hasMatchingGrant;
    final label = isAllow
        ? 'Allow'
        : isNotGranted
            ? 'Not granted'
            : 'Deny';
    final tone = isAllow
        ? _ChipTone.allow
        : isNotGranted
            ? _ChipTone.neutral
            : _ChipTone.deny;
    return Container(
      key: const Key('settings_permission_explainer_final_effect'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        children: [
          Text('Final effect', style: AppTextStyles.body14()),
          const SizedBox(width: 12),
          _Chip(
            label: label,
            tone: tone,
            keyValue: Key('settings_permission_explainer_effect_$label'),
          ),
        ],
      ),
    );
  }
}

enum _ChipTone { allow, deny, neutral, brand }

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.tone, this.keyValue});

  final String label;
  final _ChipTone tone;
  final Key? keyValue;

  @override
  Widget build(BuildContext context) {
    final fg = switch (tone) {
      _ChipTone.allow => AppColors.positive,
      _ChipTone.deny => AppColors.negative,
      _ChipTone.brand => AppColors.sunsetDark,
      _ChipTone.neutral => AppColors.textSecondary,
    };
    final bg = switch (tone) {
      _ChipTone.allow => const Color(0x14256B29),
      _ChipTone.deny => const Color(0x14C62828),
      _ChipTone.brand => const Color(0x14CC7A3E),
      _ChipTone.neutral => AppColors.cardGlow,
    };
    return Container(
      key: keyValue,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(color: fg),
      ),
    );
  }
}
