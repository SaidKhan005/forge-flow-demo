// Phase 9.UX.4 — Settings → Team → Org Hierarchy.
//
// Renders the per-operator `org_units` tree alongside the locations
// attached to each unit. The actor can:
//
//   * Browse the hierarchy (read-only when the actor has
//     `team.users.view` but not `team.roles.assign`).
//   * Add a child unit under a selected parent (gated by
//     `team.roles.assign`).
//   * Move a location to another unit (gated by
//     `team.roles.assign`).
//
// Mutations are funneled through [TeamOrgUnitCreateRequester] /
// [TeamLocationOrgUnitMoveRequester] callbacks so the live wiring
// in `forge_flow_app.dart` can route them to the proxy gateway and
// the demo wiring in tests can capture them locally.

import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../services/team/team_scope_visibility_policy.dart';
import '../../theme/app_theme.dart';

typedef TeamOrgUnitCreateRequester =
    Future<TeamOrgUnitCreated?> Function(TeamOrgUnitCreateDraft draft);

typedef TeamLocationOrgUnitMoveRequester =
    Future<TeamLocationOrgUnitMoved?> Function(
      TeamLocationOrgUnitMoveDraft draft,
    );

class TeamOrgUnitCreateDraft {
  const TeamOrgUnitCreateDraft({
    required this.parentOrgUnitId,
    required this.unitType,
    required this.label,
    required this.name,
  });

  final String parentOrgUnitId;
  final String unitType;
  final String label;
  final String name;
}

class TeamLocationOrgUnitMoveDraft {
  const TeamLocationOrgUnitMoveDraft({
    required this.locationId,
    required this.parentOrgUnitId,
  });

  final String locationId;
  final String parentOrgUnitId;
}

class SettingsOrgHierarchySection extends StatefulWidget {
  const SettingsOrgHierarchySection({
    super.key,
    required this.actor,
    required this.orgUnits,
    required this.locations,
    this.onCreateOrgUnit,
    this.onMoveLocation,
  });

  final TeamScopeActor actor;
  final List<TeamOrgUnitEntry> orgUnits;
  final List<TeamOrgLocationEntry> locations;
  final TeamOrgUnitCreateRequester? onCreateOrgUnit;
  final TeamLocationOrgUnitMoveRequester? onMoveLocation;

  @override
  State<SettingsOrgHierarchySection> createState() =>
      _SettingsOrgHierarchySectionState();
}

class _SettingsOrgHierarchySectionState
    extends State<SettingsOrgHierarchySection> {
  bool _busy = false;

  bool get _canMutate =>
      widget.actor.actorPermissions.contains('team.roles.assign');

  @override
  Widget build(BuildContext context) {
    if (widget.orgUnits.isEmpty) {
      return Container(
        key: const Key('org_hierarchy_empty'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: Text(
          'No org hierarchy yet.',
          style: AppTextStyles.body13(color: AppColors.textMuted),
        ),
      );
    }

    final byParent = <String?, List<TeamOrgUnitEntry>>{};
    for (final unit in widget.orgUnits) {
      byParent.putIfAbsent(unit.parentOrgUnitId, () => <TeamOrgUnitEntry>[]).add(
        unit,
      );
    }
    final locationsByParent = <String, List<TeamOrgLocationEntry>>{};
    for (final loc in widget.locations) {
      locationsByParent
          .putIfAbsent(loc.parentOrgUnitId, () => <TeamOrgLocationEntry>[])
          .add(loc);
    }

    final roots = byParent[null] ?? const <TeamOrgUnitEntry>[];

    return Column(
      key: const Key('org_hierarchy_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_canMutate)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Read-only view. Hierarchy edits and grants are locked '
              'for this account.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        for (final root in roots)
          _OrgUnitNode(
            unit: root,
            depth: 0,
            byParent: byParent,
            locationsByParent: locationsByParent,
            canMutate: _canMutate,
            busy: _busy,
            onAddChild: _onAddChild,
            onMoveLocation: _onMoveLocation,
          ),
      ],
    );
  }

  Future<void> _onAddChild(TeamOrgUnitEntry parent) async {
    final requester = widget.onCreateOrgUnit;
    if (!_canMutate || requester == null) return;
    final draft = await showDialog<_AddOrgUnitDraft>(
      context: context,
      builder: (context) => _AddChildOrgUnitDialog(parent: parent),
    );
    if (draft == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await requester(
        TeamOrgUnitCreateDraft(
          parentOrgUnitId: parent.orgUnitId,
          unitType: draft.unitType,
          label: draft.label,
          name: draft.name,
        ),
      );
      if (mounted) _showSnack('Org unit added');
    } catch (error) {
      if (mounted) _showSnack('Org unit could not be added.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onMoveLocation(TeamOrgLocationEntry location) async {
    final requester = widget.onMoveLocation;
    if (!_canMutate || requester == null) return;
    final allTargets = widget.orgUnits
        .where((unit) => unit.orgUnitId != location.parentOrgUnitId)
        .toList(growable: false);
    if (allTargets.isEmpty) return;
    final selected = await showDialog<TeamOrgUnitEntry>(
      context: context,
      builder: (context) => _MoveLocationDialog(
        location: location,
        targets: allTargets,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await requester(
        TeamLocationOrgUnitMoveDraft(
          locationId: location.locationId,
          parentOrgUnitId: selected.orgUnitId,
        ),
      );
      if (mounted) _showSnack('Location moved');
    } catch (error) {
      if (mounted) _showSnack('Location could not be moved.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _OrgUnitNode extends StatelessWidget {
  const _OrgUnitNode({
    required this.unit,
    required this.depth,
    required this.byParent,
    required this.locationsByParent,
    required this.canMutate,
    required this.busy,
    required this.onAddChild,
    required this.onMoveLocation,
  });

  final TeamOrgUnitEntry unit;
  final int depth;
  final Map<String?, List<TeamOrgUnitEntry>> byParent;
  final Map<String, List<TeamOrgLocationEntry>> locationsByParent;
  final bool canMutate;
  final bool busy;
  final ValueChanged<TeamOrgUnitEntry> onAddChild;
  final ValueChanged<TeamOrgLocationEntry> onMoveLocation;

  @override
  Widget build(BuildContext context) {
    final children = byParent[unit.orgUnitId] ?? const <TeamOrgUnitEntry>[];
    final locations =
        locationsByParent[unit.orgUnitId] ?? const <TeamOrgLocationEntry>[];
    final indent = depth * 16.0;
    return Padding(
      padding: EdgeInsets.only(left: indent, top: depth == 0 ? 0 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _iconFor(unit.unitType),
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      unit.label,
                      style: AppTextStyles.body13(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      _unitTypeLabel(unit.unitType),
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (canMutate)
                IconButton(
                  key: Key('org_unit_add_child_${unit.orgUnitId}'),
                  tooltip: 'Add child unit',
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  onPressed: busy ? null : () => onAddChild(unit),
                ),
            ],
          ),
          for (final loc in locations)
            Padding(
              padding: EdgeInsets.only(left: indent + 24, top: 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.place_outlined,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      loc.label,
                      style: AppTextStyles.body12(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (canMutate)
                    TextButton(
                      key: Key('org_unit_move_location_${loc.locationId}'),
                      onPressed: busy ? null : () => onMoveLocation(loc),
                      child: const Text('Move'),
                    ),
                ],
              ),
            ),
          for (final child in children)
            _OrgUnitNode(
              unit: child,
              depth: depth + 1,
              byParent: byParent,
              locationsByParent: locationsByParent,
              canMutate: canMutate,
              busy: busy,
              onAddChild: onAddChild,
              onMoveLocation: onMoveLocation,
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(String unitType) {
    return switch (unitType) {
      'corp' => Icons.apartment,
      'region' => Icons.public,
      'district' => Icons.map_outlined,
      'location_group' => Icons.layers_outlined,
      _ => Icons.account_tree_outlined,
    };
  }

  static String _unitTypeLabel(String unitType) {
    return switch (unitType) {
      'corp' => 'Operator',
      'region' => 'Region',
      'district' => 'District',
      'location_group' => 'Location group',
      _ => unitType,
    };
  }
}

class _AddOrgUnitDraft {
  const _AddOrgUnitDraft({
    required this.unitType,
    required this.label,
    required this.name,
  });

  final String unitType;
  final String label;
  final String name;
}

class _AddChildOrgUnitDialog extends StatefulWidget {
  const _AddChildOrgUnitDialog({required this.parent});

  final TeamOrgUnitEntry parent;

  @override
  State<_AddChildOrgUnitDialog> createState() => _AddChildOrgUnitDialogState();
}

class _AddChildOrgUnitDialogState extends State<_AddChildOrgUnitDialog> {
  String _unitType = 'region';
  final TextEditingController _label = TextEditingController();
  final TextEditingController _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Without these listeners the Add button stays disabled because
    // its onPressed predicate runs only on rebuild — typing into the
    // TextFields doesn't otherwise trigger one.
    _label.addListener(_handleTextChanged);
    _name.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _label.removeListener(_handleTextChanged);
    _name.removeListener(_handleTextChanged);
    _label.dispose();
    _name.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add child unit'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Under ${widget.parent.label}',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('org_unit_add_child_unit_type'),
              initialValue: _unitType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Unit type',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'region', child: Text('Region')),
                DropdownMenuItem(value: 'district', child: Text('District')),
                DropdownMenuItem(
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
              key: const Key('org_unit_add_child_label'),
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Label (a-z, 0-9, underscore)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('org_unit_add_child_name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('org_unit_add_child_submit'),
          onPressed: _label.text.trim().isEmpty || _name.text.trim().isEmpty
              ? null
              : () {
                  Navigator.of(context).pop(
                    _AddOrgUnitDraft(
                      unitType: _unitType,
                      label: _label.text.trim(),
                      name: _name.text.trim(),
                    ),
                  );
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _MoveLocationDialog extends StatefulWidget {
  const _MoveLocationDialog({required this.location, required this.targets});

  final TeamOrgLocationEntry location;
  final List<TeamOrgUnitEntry> targets;

  @override
  State<_MoveLocationDialog> createState() => _MoveLocationDialogState();
}

class _MoveLocationDialogState extends State<_MoveLocationDialog> {
  String? _selectedOrgUnitId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move location'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.location.label,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('org_unit_move_target_dropdown'),
              initialValue: _selectedOrgUnitId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Move under',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final target in widget.targets)
                  DropdownMenuItem<String>(
                    value: target.orgUnitId,
                    child: Text('${target.label} (${target.path})'),
                  ),
              ],
              onChanged: (value) =>
                  setState(() => _selectedOrgUnitId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('org_unit_move_submit'),
          onPressed: _selectedOrgUnitId == null
              ? null
              : () {
                  final picked = widget.targets.firstWhere(
                    (target) => target.orgUnitId == _selectedOrgUnitId,
                  );
                  Navigator.of(context).pop(picked);
                },
          child: const Text('Move'),
        ),
      ],
    );
  }
}
