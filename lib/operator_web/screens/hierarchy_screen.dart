// Phase 11W.3 - Operator Web Hierarchy screen.
//
// Web parity for the mobile Settings -> Org Hierarchy section. Mounted
// at the `/locations` route in the operator-web shell. Renders the
// per-operator org-unit tree with locations as leaves per the parity
// contract § Hierarchy:
//
//   * Tree shape: `org_units` form an n-ary tree per operator;
//     `locations` are leaves attached to a single `org_unit_id`.
//     Roots are units with `parent_org_unit_id IS NULL`.
//   * Display order: children sorted alphabetically by `name`;
//     locations sorted alphabetically within their org-unit.
//   * Move semantics: gated on `team.roles.assign`. Audited via the
//     existing proxy route + audit-log producer.
//   * Read-only audiences: floor managers (`location_manager`) and
//     `operator_supervisor` see read-only; mutate buttons hidden;
//     tree expand/collapse stays interactive.
//   * Validation copy locked verbatim against the parity contract:
//       - empty name -> "Org unit name is required."
//       - duplicate name within parent -> "An org unit with this name
//         already exists in this group."
//       - move would create a cycle -> "Cannot move into a child of
//         itself."
//
// Permission gates mirror the proxy server-side gate. The screen
// prefers the live `OperatorWebSession.permissions` snapshot when
// present; it falls back to a role-tier set so the demo flavor and
// the pre-snapshot bootstrap stage of live mode still render.
//
// Wiring honesty: the screen reads + writes through
// [WebTeamHierarchyGateway] which the router binds to either the
// `package:http` live impl or the in-memory demo impl. No `dart:io`,
// no `sqflite`, no parallel HTTP stack.

import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/web_team_hierarchy_gateway.dart';
import '../widgets/org_unit_tree_view.dart';
import '../../theme/app_theme.dart';

/// Roles admitted to the Hierarchy surface when the proxy permission
/// snapshot is not yet hydrated (demo flavor + bootstrap). The
/// authoritative gate is the `team.users.view` permission key per the
/// parity contract § Permission gate cheat sheet (Hierarchy row).
const Set<String> kOperatorWebHierarchyAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
  'operator_manager',
  'operator_supervisor',
  'location_manager',
};

/// Role-tier fallback for the mutate actions (create org unit, move
/// location). Authoritative gate is the `team.roles.assign`
/// permission key; this set kicks in only when
/// `OperatorWebSession.permissions` is empty (demo + boot).
const Set<String> kOperatorWebHierarchyWriteRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Permission-key bound for the Hierarchy read surface. Live source
/// hydrates from `/v1/auth/permissions/snapshot`.
const String kHierarchyViewPermissionKey = 'team.users.view';

/// Permission-key bound for the create org unit + move location
/// actions per the parity contract § Hierarchy.
const String kHierarchyAssignPermissionKey = 'team.roles.assign';

/// Locked copy strings keyed off the parity contract § Hierarchy
/// Validation copy block. Pinned in `HierarchyCopy` so widget tests
/// can assert each one verbatim.
class HierarchyCopy {
  const HierarchyCopy._();

  static const String emptyOrgUnitName = 'Org unit name is required.';
  static const String duplicateOrgUnitName =
      'An org unit with this name already exists in this group.';
  static const String moveCycle = 'Cannot move into a child of itself.';

  /// Friendly fallback when the proxy returns a non-`validation_failed`
  /// error code. Pinned here so the widget tests can assert the
  /// fallback path without coupling to dynamic strings.
  static const String mutationFailed =
      'Action could not be completed. Try again in a moment, or refresh '
      'the page if the problem keeps happening.';
}

/// Operator Web Hierarchy screen.
class HierarchyScreen extends StatefulWidget {
  const HierarchyScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.idempotencyKeyFactory,
  });

  final OperatorWebSession session;
  final WebTeamHierarchyGateway gateway;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway.
  final String Function()? idempotencyKeyFactory;

  /// True iff the actor may read the Hierarchy surface. Prefers the
  /// proxy-side permission snapshot when present; falls back to the
  /// role-tier set so the demo flavor (no permissions snapshot) and
  /// the live bootstrap stage (snapshot still loading) render
  /// something useful.
  bool get _admitted {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kHierarchyViewPermissionKey);
    }
    return session.roles.any(kOperatorWebHierarchyAdmittedRoles.contains);
  }

  /// True iff the actor may create org units + move locations.
  /// Prefers the permission snapshot; falls back to the role tier
  /// when the snapshot has not hydrated yet.
  bool get _canMutate {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kHierarchyAssignPermissionKey);
    }
    return session.roles.any(kOperatorWebHierarchyWriteRoles.contains);
  }

  @override
  State<HierarchyScreen> createState() => _HierarchyScreenState();
}

class _HierarchyScreenState extends State<HierarchyScreen> {
  List<TeamOrgUnitEntry> _orgUnits = const <TeamOrgUnitEntry>[];
  List<TeamOrgLocationEntry> _locations = const <TeamOrgLocationEntry>[];
  bool _loading = true;
  String? _loadError;
  final Set<String> _busyOrgUnitIds = <String>{};
  final Set<String> _busyLocationIds = <String>{};
  int _idempotencySeq = 0;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.gateway.listOrgHierarchy(_listCommand());
      if (!mounted) return;
      setState(() {
        _orgUnits = result.orgUnits;
        _locations = result.locations;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  String _friendlyLoadError(Object error) {
    if (error is WebTeamHierarchyError) {
      return 'Could not load the locations list (${error.code}). Refresh '
          'the page or try again in a moment.';
    }
    return 'Could not load the locations list. Refresh the page or try '
        'again in a moment.';
  }

  TeamOrgHierarchyListCommand _listCommand() {
    return TeamOrgHierarchyListCommand(
      actorUserId: widget.session.uid,
      operatorId: widget.session.operatorId,
      locationId: widget.session.primaryLocationId,
    );
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-hierarchy-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  Future<void> _onAddChildOrgUnit(TeamOrgUnitEntry parent) async {
    if (!widget._canMutate) return;
    final draft = await showDialog<_AddOrgUnitDraft>(
      context: context,
      builder: (context) => _AddChildOrgUnitDialog(
        parent: parent,
        existingNames: _siblingNames(parent.orgUnitId),
      ),
    );
    if (draft == null || !mounted) return;
    setState(() => _busyOrgUnitIds.add(parent.orgUnitId));
    try {
      await widget.gateway.createOrgUnit(
        TeamOrgUnitCreateCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId,
          parentOrgUnitId: parent.orgUnitId,
          unitType: draft.unitType,
          label: draft.label,
          name: draft.name,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Org unit added.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyMutationError(error))),
      );
    } finally {
      if (mounted) {
        setState(() => _busyOrgUnitIds.remove(parent.orgUnitId));
      }
    }
  }

  Future<void> _onMoveLocation(TeamOrgLocationEntry location) async {
    if (!widget._canMutate) return;
    final targets = _orgUnits
        .where((unit) => unit.orgUnitId != location.parentOrgUnitId)
        .toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add another unit before moving this location.'),
        ),
      );
      return;
    }
    final selected = await showDialog<TeamOrgUnitEntry>(
      context: context,
      builder: (context) => _MoveLocationDialog(
        location: location,
        targets: targets,
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _busyLocationIds.add(location.locationId));
    try {
      await widget.gateway.moveLocationToOrgUnit(
        TeamLocationOrgUnitMoveCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId,
          targetLocationId: location.locationId,
          parentOrgUnitId: selected.orgUnitId,
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location moved.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyMutationError(error))),
      );
    } finally {
      if (mounted) {
        setState(() => _busyLocationIds.remove(location.locationId));
      }
    }
  }

  Set<String> _siblingNames(String parentOrgUnitId) {
    return <String>{
      for (final unit in _orgUnits)
        if (unit.parentOrgUnitId == parentOrgUnitId) unit.label.toLowerCase(),
    };
  }

  String _friendlyMutationError(Object error) {
    if (error is WebTeamHierarchyError) {
      if (error.code == 'validation_failed') {
        return error.message;
      }
      if (error.code == 'cycle_detected') {
        return HierarchyCopy.moveCycle;
      }
      return 'Action could not be completed (${error.code}). Try again in '
          'a moment, or refresh the page if the problem keeps happening.';
    }
    return HierarchyCopy.mutationFailed;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget._admitted) {
      return const _HierarchyForbiddenSurface(
        key: Key('operator_web_hierarchy_forbidden'),
      );
    }
    if (_loading) {
      return const Center(
        key: Key('operator_web_hierarchy_loading'),
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
        key: const Key('operator_web_hierarchy_load_error'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Locations could not load',
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
                    key: const Key('operator_web_hierarchy_load_retry'),
                    onPressed: _loadAll,
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
    return SingleChildScrollView(
      key: const Key('operator_web_hierarchy_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _HierarchyHeader(),
          const SizedBox(height: 18),
          if (!widget._canMutate)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Read-only view. Hierarchy edits are managed by your '
                'operator owner or admin.',
                key: const Key('operator_web_hierarchy_readonly_notice'),
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ),
          OrgUnitTreeView(
            orgUnits: _orgUnits,
            locations: _locations,
            canMutate: widget._canMutate,
            busyOrgUnitIds: _busyOrgUnitIds,
            busyLocationIds: _busyLocationIds,
            onAddChildOrgUnit: _onAddChildOrgUnit,
            onMoveLocation: _onMoveLocation,
          ),
        ],
      ),
    );
  }
}

class _HierarchyHeader extends StatelessWidget {
  const _HierarchyHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.account_tree_outlined,
              size: 22,
              color: AppColors.sunsetDark,
            ),
            const SizedBox(width: 10),
            Text(
              'Locations',
              style: AppTextStyles.display20(color: AppColors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Group your locations under regions and districts so the right '
          'people see the right business in Forge & Flow. Changes apply '
          'across every device the team uses.',
          key: const Key('operator_web_hierarchy_subtitle'),
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _HierarchyForbiddenSurface extends StatelessWidget {
  const _HierarchyForbiddenSurface({super.key});

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
                      'Locations is owner-managed',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Grouping locations under regions or districts is managed '
                'by your operator owner or admin. Ask them to add you to '
                'the right role if you need to change the layout.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
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
  const _AddChildOrgUnitDialog({
    required this.parent,
    required this.existingNames,
  });

  final TeamOrgUnitEntry parent;
  final Set<String> existingNames;

  @override
  State<_AddChildOrgUnitDialog> createState() => _AddChildOrgUnitDialogState();
}

class _AddChildOrgUnitDialogState extends State<_AddChildOrgUnitDialog> {
  String _unitType = 'region';
  final TextEditingController _label = TextEditingController();
  final TextEditingController _name = TextEditingController();
  String? _errorText;

  @override
  void initState() {
    super.initState();
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
    if (mounted) setState(() => _errorText = null);
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _errorText = HierarchyCopy.emptyOrgUnitName);
      return;
    }
    if (widget.existingNames.contains(name.toLowerCase())) {
      setState(() => _errorText = HierarchyCopy.duplicateOrgUnitName);
      return;
    }
    final rawLabel = _label.text.trim();
    final label = rawLabel.isEmpty ? _sanitiseLabel(name) : rawLabel;
    Navigator.of(context).pop(
      _AddOrgUnitDraft(unitType: _unitType, label: label, name: name),
    );
  }

  /// Squashes a free-text display name into the `a-z, 0-9, underscore`
  /// label format the proxy expects when the user has not typed an
  /// explicit label. Any non-alphanumeric run becomes a single
  /// underscore; leading and trailing underscores are trimmed so a
  /// name like `"South-West Region"` lands as `"south_west_region"`
  /// rather than `"south-west_region"` (which would fail server-side
  /// label validation).
  static String _sanitiseLabel(String name) {
    final lowered = name.toLowerCase();
    final collapsed = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('operator_web_org_unit_add_dialog'),
      title: const Text('Add child unit'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Under ${widget.parent.label}',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('operator_web_org_unit_add_dialog_unit_type'),
              initialValue: _unitType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Unit type',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'region', child: Text('Region')),
                DropdownMenuItem(
                  value: 'district',
                  child: Text('District'),
                ),
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
              key: const Key('operator_web_org_unit_add_dialog_name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('operator_web_org_unit_add_dialog_label'),
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Label (a-z, 0-9, underscore)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_errorText != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _errorText!,
                key: const Key('operator_web_org_unit_add_dialog_error'),
                style: AppTextStyles.body12(color: AppColors.negative),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('operator_web_org_unit_add_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('operator_web_org_unit_add_dialog_submit'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _MoveLocationDialog extends StatefulWidget {
  const _MoveLocationDialog({
    required this.location,
    required this.targets,
  });

  final TeamOrgLocationEntry location;
  final List<TeamOrgUnitEntry> targets;

  @override
  State<_MoveLocationDialog> createState() => _MoveLocationDialogState();
}

class _MoveLocationDialogState extends State<_MoveLocationDialog> {
  String? _selectedOrgUnitId;

  @override
  Widget build(BuildContext context) {
    final sortedTargets = <TeamOrgUnitEntry>[...widget.targets]..sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    return AlertDialog(
      key: const Key('operator_web_location_move_dialog'),
      title: const Text('Move location'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.location.label,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('operator_web_location_move_dialog_target'),
              initialValue: _selectedOrgUnitId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Move under',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: <DropdownMenuItem<String>>[
                for (final target in sortedTargets)
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
      actions: <Widget>[
        TextButton(
          key: const Key('operator_web_location_move_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('operator_web_location_move_dialog_submit'),
          onPressed: _selectedOrgUnitId == null
              ? null
              : () {
                  final picked = sortedTargets.firstWhere(
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
