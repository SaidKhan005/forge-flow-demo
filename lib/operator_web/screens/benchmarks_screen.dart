import 'package:flutter/material.dart';

import '../../domain/models/inheritance_tree_node.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../../services/baseline/benchmark_override_resolver.dart';
import '../../services/baseline_authority_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/inheritance_tree.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/demo_team_hierarchy_gateway.dart';
import '../services/operator_web_benchmarks_gateway.dart';
import '../services/web_team_hierarchy_gateway.dart';
import '../widgets/web_app_shell.dart';

class BenchmarksScreen extends StatefulWidget {
  const BenchmarksScreen({
    super.key,
    required this.session,
    required this.selectedScope,
    this.benchmarksGateway,
    this.hierarchyGateway,
  });

  final OperatorWebSession session;
  final OperatorWebManagementScopeOption selectedScope;
  final OperatorWebBenchmarksGateway? benchmarksGateway;
  final WebTeamHierarchyGateway? hierarchyGateway;

  @override
  State<BenchmarksScreen> createState() => _BenchmarksScreenState();
}

class _BenchmarksScreenState extends State<BenchmarksScreen> {
  static const Map<String, String> _metricLabels = <String, String>{
    'target_cplh': 'CPLH',
    'target_splh': 'SPLH',
    'target_ppa': 'PPA',
  };

  final BenchmarkOverrideResolver _resolver = const BenchmarkOverrideResolver();
  late OperatorWebBenchmarksGateway _benchmarksGateway;
  late WebTeamHierarchyGateway _hierarchyGateway;
  String _selectedMetric = 'target_cplh';
  InheritanceTreeNode? _selectedNode;
  InheritanceTreeNode? _tree;
  List<BenchmarkOverrideCandidate> _overrides =
      const <BenchmarkOverrideCandidate>[];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  final TextEditingController _valueController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _benchmarksGateway =
        widget.benchmarksGateway ?? DemoOperatorWebBenchmarksGateway();
    _hierarchyGateway = widget.hierarchyGateway ?? DemoWebTeamHierarchyGateway();
    _load();
  }

  @override
  void didUpdateWidget(covariant BenchmarksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.benchmarksGateway != widget.benchmarksGateway ||
        oldWidget.hierarchyGateway != widget.hierarchyGateway) {
      _benchmarksGateway =
          widget.benchmarksGateway ?? DemoOperatorWebBenchmarksGateway();
      _hierarchyGateway =
          widget.hierarchyGateway ?? DemoWebTeamHierarchyGateway();
      _load();
    }
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hierarchy = await _hierarchyGateway.listOrgHierarchy(
        TeamOrgHierarchyListCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          locationId: widget.session.primaryLocationId,
        ),
      );
      final overrides = await _benchmarksGateway.listOverrides(
        operatorId: widget.session.operatorId,
        locationId: widget.session.primaryLocationId,
        actorUserId: widget.session.uid,
      );
      if (!mounted) return;
      final tree = _treeFromHierarchy(
        hierarchy,
        operatorId: widget.session.operatorId,
        businessName: widget.session.businessName,
      );
      setState(() {
        _tree = tree;
        _selectedNode ??= _nodeForScope(tree, widget.selectedScope) ?? tree;
        _overrides = overrides;
        _loading = false;
      });
      _syncControllerToSelected();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load benchmark overrides: $error';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final node = _selectedNode;
    if (node == null) return;
    final value = double.tryParse(_valueController.text.trim());
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter a positive benchmark value.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final row = await _benchmarksGateway.setOverride(
        operatorId: widget.session.operatorId,
        locationId: widget.session.primaryLocationId,
        actorUserId: widget.session.uid,
        scopeType: _scopeTypeFor(node),
        orgUnitId: node.scopeKind == InheritanceTreeScopeKind.orgUnit
            ? node.scopeId
            : null,
        targetLocationId: node.scopeKind == InheritanceTreeScopeKind.location
            ? node.scopeId
            : null,
        metricKey: _selectedMetric,
        overrideValue: value,
      );
      if (!mounted) return;
      setState(() {
        _overrides = <BenchmarkOverrideCandidate>[
          ..._overrides.where(
            (candidate) =>
                candidate.metricKey != row.metricKey ||
                candidate.scopeType != row.scopeType ||
                candidate.orgUnitId != row.orgUnitId ||
                candidate.locationId != row.locationId,
          ),
          row,
        ];
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not save benchmark override: $error';
        _saving = false;
      });
    }
  }

  Future<void> _clear() async {
    final direct = _directOverrideForSelected();
    if (direct == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _benchmarksGateway.clearOverride(
        operatorId: widget.session.operatorId,
        locationId: widget.session.primaryLocationId,
        actorUserId: widget.session.uid,
        overrideId: direct.overrideId,
      );
      if (!mounted) return;
      setState(() {
        _overrides = _overrides
            .where((row) => row.overrideId != direct.overrideId)
            .toList(growable: false);
        _saving = false;
      });
      _syncControllerToSelected();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not clear benchmark override: $error';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('operator_web_benchmarks_loading'),
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
    if (_error != null && _tree == null) {
      return _ErrorState(message: _error!, onRetry: _load);
    }
    final tree = _tree!;
    final selected = _selectedNode ?? tree;
    final effective = _effectiveForNode(selected);
    final direct = _directOverrideForSelected();
    return SingleChildScrollView(
      key: const Key('operator_web_benchmarks_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: [
              const Icon(
                Icons.speed_outlined,
                size: 22,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Benchmarks',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
              ),
              IconButton(
                key: const Key('operator_web_benchmarks_refresh'),
                tooltip: 'Refresh',
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Selected scope: ${selected.displayName}. Effective '
            '${_metricLabels[_selectedMetric]} is '
            '${_formatValue(effective.value)} from ${effective.sourceLabel}.',
            key: const Key('operator_web_benchmarks_effective_summary'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const Key('operator_web_benchmarks_inline_error'),
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final entry in _metricLabels.entries)
                ChoiceChip(
                  key: Key('operator_web_benchmark_metric_${entry.key}'),
                  label: Text(entry.value),
                  selected: _selectedMetric == entry.key,
                  onSelected: (_) {
                    setState(() => _selectedMetric = entry.key);
                    _syncControllerToSelected();
                  },
                ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final treePane = _TreePane(
                child: InheritanceTree(
                  rootNode: tree,
                  onNodeTap: (node) {
                    setState(() => _selectedNode = node);
                    _syncControllerToSelected();
                  },
                  annotationBuilder: (_, node) =>
                      _BenchmarkAnnotation(value: _effectiveForNode(node)),
                ),
              );
              final editor = _EditorPane(
                selected: selected,
                effective: effective,
                direct: direct,
                controller: _valueController,
                saving: _saving,
                onSave: _save,
                onClear: direct == null ? null : _clear,
              );
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: treePane),
                    const SizedBox(width: 18),
                    SizedBox(width: 360, child: editor),
                  ],
                );
              }
              return Column(
                children: [treePane, const SizedBox(height: 18), editor],
              );
            },
          ),
        ],
      ),
    );
  }

  BenchmarkOverrideResolvedValue _effectiveForNode(InheritanceTreeNode node) {
    return _resolver.resolve(
      metricKey: _selectedMetric,
      operatorId: widget.session.operatorId,
      ancestorOrgUnitIdsNearestFirst:
          (node.metadata['ancestor_ids_nearest'] as List<String>?) ??
          const <String>[],
      locationId: node.scopeKind == InheritanceTreeScopeKind.location
          ? node.scopeId
          : null,
      candidates: _overrides,
      fallbackValue: _fallbackFor(_selectedMetric),
    );
  }

  BenchmarkOverrideCandidate? _directOverrideForSelected() {
    final node = _selectedNode;
    if (node == null) return null;
    for (final row in _overrides) {
      if (row.metricKey != _selectedMetric) continue;
      if (row.scopeType == _scopeTypeFor(node) && row.scopeId == node.scopeId) {
        return row;
      }
    }
    return null;
  }

  void _syncControllerToSelected() {
    final selected = _selectedNode;
    if (selected == null) return;
    _valueController.text = _formatValue(_effectiveForNode(selected).value);
  }

  static BenchmarkOverrideScopeType _scopeTypeFor(InheritanceTreeNode node) {
    return switch (node.scopeKind) {
      InheritanceTreeScopeKind.business =>
        BenchmarkOverrideScopeType.operatorWide,
      InheritanceTreeScopeKind.orgUnit => BenchmarkOverrideScopeType.orgUnit,
      InheritanceTreeScopeKind.location => BenchmarkOverrideScopeType.location,
    };
  }

  static double _fallbackFor(String metric) {
    return switch (metric) {
      'target_splh' => BaselineData.derivedTargetSPLH,
      'target_ppa' => BaselineData.derivedTargetPPA,
      _ => BaselineData.derivedTargetCPLH,
    };
  }

  static String _formatValue(double value) => value.toStringAsFixed(2);

  static InheritanceTreeNode? _nodeForScope(
    InheritanceTreeNode root,
    OperatorWebManagementScopeOption scope,
  ) {
    if (root.scopeId == scope.id) return root;
    for (final child in root.children) {
      final found = _nodeForScope(child, scope);
      if (found != null) return found;
    }
    return null;
  }

  static InheritanceTreeNode _treeFromHierarchy(
    TeamOrgHierarchyListed hierarchy, {
    required String operatorId,
    required String businessName,
  }) {
    final unitsByParent = <String?, List<TeamOrgUnitEntry>>{};
    for (final unit in hierarchy.orgUnits) {
      unitsByParent.putIfAbsent(unit.parentOrgUnitId, () => []).add(unit);
    }
    final locationsByParent = <String, List<TeamOrgLocationEntry>>{};
    for (final location in hierarchy.locations) {
      locationsByParent
          .putIfAbsent(location.parentOrgUnitId, () => [])
          .add(location);
    }
    final roots = [...(unitsByParent[null] ?? const <TeamOrgUnitEntry>[])]
      ..sort((a, b) => a.label.compareTo(b.label));
    return InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.business,
      scopeId: operatorId,
      displayName: businessName,
      parentScopeId: null,
      depth: 0,
      children: <InheritanceTreeNode>[
        for (final root in roots)
          _buildUnitNode(
            root,
            unitsByParent,
            locationsByParent,
            depth: 1,
            ancestorsNearest: const <String>[],
          ),
      ],
    );
  }

  static InheritanceTreeNode _buildUnitNode(
    TeamOrgUnitEntry unit,
    Map<String?, List<TeamOrgUnitEntry>> unitsByParent,
    Map<String, List<TeamOrgLocationEntry>> locationsByParent, {
    required int depth,
    required List<String> ancestorsNearest,
  }) {
    final currentAncestors = <String>[unit.orgUnitId, ...ancestorsNearest];
    final childUnits = [...(unitsByParent[unit.orgUnitId] ?? const [])]
      ..sort((a, b) => a.label.compareTo(b.label));
    final childLocations = [
      ...(locationsByParent[unit.orgUnitId] ?? const <TeamOrgLocationEntry>[]),
    ]..sort((a, b) => a.label.compareTo(b.label));
    return InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.orgUnit,
      scopeId: unit.orgUnitId,
      displayName: unit.label,
      parentScopeId: unit.parentOrgUnitId,
      depth: depth,
      metadata: <String, Object?>{
        'unit_type': unit.unitType,
        'ancestor_ids_nearest': currentAncestors,
      },
      children: <InheritanceTreeNode>[
        for (final child in childUnits)
          _buildUnitNode(
            child,
            unitsByParent,
            locationsByParent,
            depth: depth + 1,
            ancestorsNearest: currentAncestors,
          ),
        for (final location in childLocations)
          InheritanceTreeNode(
            scopeKind: InheritanceTreeScopeKind.location,
            scopeId: location.locationId,
            displayName: location.label,
            parentScopeId: location.parentOrgUnitId,
            depth: depth + 1,
            metadata: <String, Object?>{
              'org_unit_path': location.orgUnitPath,
              'ancestor_ids_nearest': currentAncestors,
            },
          ),
      ],
    );
  }
}

class _TreePane extends StatelessWidget {
  const _TreePane({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_benchmarks_tree_pane'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

class _EditorPane extends StatelessWidget {
  const _EditorPane({
    required this.selected,
    required this.effective,
    required this.direct,
    required this.controller,
    required this.saving,
    required this.onSave,
    required this.onClear,
  });

  final InheritanceTreeNode selected;
  final BenchmarkOverrideResolvedValue effective;
  final BenchmarkOverrideCandidate? direct;
  final TextEditingController controller;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_benchmarks_editor'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            selected.displayName,
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            'Effective value: ${effective.value.toStringAsFixed(2)}',
            key: const Key('operator_web_benchmarks_effective_value'),
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          Text(
            effective.overrideId == null
                ? 'Inherited source: Target cycle'
                : 'Inherited source: ${effective.sourceLabel}',
            key: const Key('operator_web_benchmarks_inherited_source'),
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('operator_web_benchmarks_value_field'),
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Override value'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('operator_web_benchmarks_save'),
                  onPressed: saving ? null : onSave,
                  icon: saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Save'),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                key: const Key('operator_web_benchmarks_clear'),
                tooltip: 'Clear override',
                onPressed: saving ? null : onClear,
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
          if (direct == null) ...[
            const SizedBox(height: 10),
            Text(
              'No direct override at this scope.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _BenchmarkAnnotation extends StatelessWidget {
  const _BenchmarkAnnotation({required this.value});

  final BenchmarkOverrideResolvedValue value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          value.value.toStringAsFixed(2),
          style: AppTextStyles.mono12(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
        Text(
          value.overrideId == null ? 'target cycle' : value.sourceLabel,
          style: AppTextStyles.body12(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            key: const Key('operator_web_benchmarks_error'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: AppTextStyles.body13(color: AppColors.negative)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('operator_web_benchmarks_retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
