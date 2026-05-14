// Lane B B8.b — operator-web hierarchy filter pane for the Audit Log
// screen.
//
// Companion to `audit_log_screen.dart`. Decomposed into its own file
// to keep the parent screen below the operator-web ceiling
// (`audit_log_screen.dart` is already > 1,300 LoC and the hierarchy
// surface adds tree visualization + a paginated row list keyed off a
// separate gateway). Mirrors the sibling-file precedent the proxy
// uses for the route handler (`tool/advisor_proxy/
// operator_web_audit_log_hierarchy_routes.dart`).
//
// What the pane shows:
//
//   * The shared [InheritanceTree] visualization
//     (`lib/widgets/inheritance_tree.dart`, L_A1) of the operator's
//     Business -> Org Unit -> Location tree. Tapping a row picks the
//     scope branch (`operator_wide` / `org_unit` / `location`).
//   * A scope-branch dropdown + paired filter fields that mirror the
//     proxy-route query parameters (org_unit_id, location_filter,
//     actor_user_id, action, time range).
//   * A "Run filter" button that calls the hierarchy gateway and
//     renders the returned rows underneath the picker.
//
// What the pane DOES NOT do:
//
//   * No CSV export. CSV stays on the legacy unfiltered audit-log
//     surface (the parent screen). Adding hierarchy-filtered CSV is
//     a future-slice item, intentionally deferred to keep B8.b
//     scoped.
//   * No mutate affordances. The pane is a pure read-side surface;
//     mutations on the audit log are forbidden by HP #4 + the
//     audit_logs_update_lint.
//   * No `kDemoMode` carve-out. The pane reads through the gateway
//     boundary; the router binds either the live or demo gateway and
//     the pane behaves identically.
//
// Permission gating:
//
//   The parent screen already gates the entire Audit Log surface on
//   `team.audit_log.view` (see `audit_log_screen.dart#_canView`); the
//   pane is mounted only when the parent renders. The proxy route
//   re-checks the same permission key server-side as defense in
//   depth.

import 'package:flutter/material.dart';

import '../../domain/models/inheritance_tree_node.dart';
import '../../services/auth/actor_kind_label_catalog.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../../theme/app_theme.dart';
import '../../widgets/inheritance_tree.dart';
import '../services/web_audit_log_hierarchy_gateway.dart';
import '../services/web_team_hierarchy_gateway.dart';

/// Stateful pane the parent audit-log screen mounts in its build
/// path. The parent owns the gateway instances; the pane owns the
/// filter state + loading + error envelope.
class AuditLogHierarchyFilterPane extends StatefulWidget {
  const AuditLogHierarchyFilterPane({
    super.key,
    required this.hierarchyGateway,
    required this.teamHierarchyGateway,
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.clock,
  });

  /// Read seam against `/v1/auth/audit-log/hierarchy`. The router
  /// binds the HTTP impl in production and the in-memory demo impl
  /// for fixture-driven walkthroughs.
  final WebAuditLogHierarchyGateway hierarchyGateway;

  /// Read seam for the operator's org-unit + location tree. We
  /// reuse the existing operator-web hierarchy gateway so the pane
  /// renders the same tree shape the Locations screen does (HP #11
  /// — hierarchy-scoped settings: one tree, one source of truth).
  final WebTeamHierarchyGateway teamHierarchyGateway;

  /// Session-bound actor id. Threaded to the team-hierarchy gateway
  /// so the existing proxy route can authorize the read (the audit
  /// log gateway clamps to the JWT operator/location regardless).
  final String actorUserId;

  /// Session-bound operator id (matches the JWT scope).
  final String operatorId;

  /// Session-bound location id (matches the JWT scope).
  final String locationId;

  /// Optional override for tests so the default time window is
  /// deterministic.
  final DateTime Function()? clock;

  @override
  State<AuditLogHierarchyFilterPane> createState() =>
      _AuditLogHierarchyFilterPaneState();
}

class _AuditLogHierarchyFilterPaneState
    extends State<AuditLogHierarchyFilterPane> {
  /// Default time window matches the proxy route's default (7d).
  static const Duration _defaultWindow = Duration(days: 7);

  bool _treeLoading = true;
  String? _treeLoadError;
  List<TeamOrgUnitEntry> _orgUnits = const <TeamOrgUnitEntry>[];
  List<TeamOrgLocationEntry> _locations = const <TeamOrgLocationEntry>[];

  WebAuditLogHierarchyScopeType _scopeType =
      WebAuditLogHierarchyScopeType.operatorWide;
  String? _selectedOrgUnitId;
  String? _selectedLocationId;
  String _selectedScopeLabel = 'Whole business';

  late final TextEditingController _actorUserIdController;
  late final TextEditingController _actionController;
  late DateTime _fromUtc;
  late DateTime _toUtc;

  bool _rowsLoading = false;
  String? _rowsLoadError;
  List<WebAuditLogHierarchyRow> _rows = const <WebAuditLogHierarchyRow>[];
  String? _nextCursor;

  @override
  void initState() {
    super.initState();
    _actorUserIdController = TextEditingController();
    _actionController = TextEditingController();
    final now = (widget.clock ?? DateTime.now)().toUtc();
    _toUtc = now;
    _fromUtc = now.subtract(_defaultWindow);
    _loadTree();
  }

  @override
  void dispose() {
    _actorUserIdController.dispose();
    _actionController.dispose();
    super.dispose();
  }

  Future<void> _loadTree() async {
    setState(() {
      _treeLoading = true;
      _treeLoadError = null;
    });
    try {
      final listed = await widget.teamHierarchyGateway.listOrgHierarchy(
        TeamOrgHierarchyListCommand(
          actorUserId: widget.actorUserId,
          operatorId: widget.operatorId,
          locationId: widget.locationId,
        ),
      );
      if (!mounted) return;
      setState(() {
        _orgUnits = listed.orgUnits;
        _locations = listed.locations;
        _treeLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _treeLoading = false;
        _treeLoadError =
            'Could not load the hierarchy. Refresh the page or try '
            'again in a moment.';
      });
    }
  }

  void _onNodeTap(InheritanceTreeNode node) {
    setState(() {
      switch (node.scopeKind) {
        case InheritanceTreeScopeKind.business:
          _scopeType = WebAuditLogHierarchyScopeType.operatorWide;
          _selectedOrgUnitId = null;
          _selectedLocationId = null;
          _selectedScopeLabel = 'Whole business';
          break;
        case InheritanceTreeScopeKind.orgUnit:
          _scopeType = WebAuditLogHierarchyScopeType.orgUnit;
          _selectedOrgUnitId = node.scopeId;
          _selectedLocationId = null;
          _selectedScopeLabel = 'Region or district: ${node.displayName}';
          break;
        case InheritanceTreeScopeKind.location:
          _scopeType = WebAuditLogHierarchyScopeType.location;
          _selectedOrgUnitId = null;
          _selectedLocationId = node.scopeId;
          _selectedScopeLabel = 'Location: ${node.displayName}';
          break;
      }
    });
  }

  Future<void> _runFilter({String? cursor}) async {
    setState(() {
      _rowsLoading = true;
      _rowsLoadError = null;
    });
    try {
      final command = WebAuditLogHierarchyListCommand(
        scopeType: _scopeType,
        orgUnitId: _scopeType == WebAuditLogHierarchyScopeType.orgUnit
            ? _selectedOrgUnitId
            : null,
        locationFilter:
            _scopeType == WebAuditLogHierarchyScopeType.location
                ? _selectedLocationId
                : null,
        from: _fromUtc,
        to: _toUtc,
        actorUserId: _trimmedOrNull(_actorUserIdController.text),
        action: _trimmedOrNull(_actionController.text),
        beforeId: cursor,
      );
      final result =
          await widget.hierarchyGateway.listByHierarchy(command);
      if (!mounted) return;
      setState(() {
        _rowsLoading = false;
        if (cursor == null) {
          _rows = result.rows;
        } else {
          _rows = <WebAuditLogHierarchyRow>[..._rows, ...result.rows];
        }
        _nextCursor = result.nextCursor;
      });
    } on WebAuditLogHierarchyGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _rowsLoading = false;
        _rowsLoadError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _rowsLoading = false;
        _rowsLoadError =
            'Could not run the hierarchy filter. Refresh the page or '
            'try again in a moment.';
      });
    }
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().toUtc().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(
        start: _fromUtc.toLocal(),
        end: _toUtc.toLocal(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final start = picked.start.toLocal();
      _fromUtc = DateTime(start.year, start.month, start.day).toUtc();
      final end = picked.end.toLocal();
      _toUtc = DateTime(
        end.year,
        end.month,
        end.day,
        23,
        59,
        59,
        999,
      ).toUtc();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_hierarchy_pane'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Filter by hierarchy',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pick a region, district, or location in the tree below to '
            'narrow the audit log to that scope. Tap "Whole business" '
            'to clear the scope.',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          _buildTreeBody(),
          const SizedBox(height: 10),
          _buildScopeSummary(),
          const SizedBox(height: 12),
          _buildTimeRangeRow(),
          const SizedBox(height: 10),
          _buildFilterRow(),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              ElevatedButton(
                key: const Key('operator_web_audit_log_hierarchy_run'),
                onPressed: _rowsLoading ? null : () => _runFilter(),
                child: Text(_rowsLoading ? 'Loading…' : 'Run filter'),
              ),
              const SizedBox(width: 12),
              if (_nextCursor != null && !_rowsLoading)
                TextButton(
                  key: const Key(
                    'operator_web_audit_log_hierarchy_load_more',
                  ),
                  onPressed: () => _runFilter(cursor: _nextCursor),
                  child: const Text('Load older rows'),
                ),
            ],
          ),
          if (_rowsLoadError != null) ...<Widget>[
            const SizedBox(height: 10),
            _ErrorBanner(message: _rowsLoadError!),
          ],
          const SizedBox(height: 12),
          _buildResults(),
        ],
      ),
    );
  }

  Widget _buildTreeBody() {
    if (_treeLoading) {
      return const Padding(
        key: Key('operator_web_audit_log_hierarchy_tree_loading'),
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sunsetDark,
            ),
          ),
        ),
      );
    }
    if (_treeLoadError != null) {
      return _ErrorBanner(message: _treeLoadError!);
    }
    if (_orgUnits.isEmpty) {
      return Padding(
        key: const Key('operator_web_audit_log_hierarchy_tree_empty'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No hierarchy yet. Set up your org units first to filter by '
          'region, district, or location.',
          style: AppTextStyles.body13(color: AppColors.textMuted),
        ),
      );
    }
    final rootNode = _buildInheritanceRoot();
    return InheritanceTree(
      key: const Key('operator_web_audit_log_hierarchy_tree'),
      rootNode: rootNode,
      onNodeTap: _onNodeTap,
      annotationBuilder: (context, node) => const SizedBox.shrink(),
    );
  }

  Widget _buildScopeSummary() {
    return Container(
      key: const Key('operator_web_audit_log_hierarchy_scope_summary'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.account_tree_outlined,
              size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Selected scope: $_selectedScopeLabel',
              style: AppTextStyles.body12(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRangeRow() {
    final dateFormat = _formatDate;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            'Time range: ${dateFormat(_fromUtc)} to ${dateFormat(_toUtc)}',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          key: const Key('operator_web_audit_log_hierarchy_pick_range'),
          onPressed: _pickRange,
          child: const Text('Change'),
        ),
      ],
    );
  }

  Widget _buildFilterRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            key: const Key('operator_web_audit_log_hierarchy_actor_user_id'),
            controller: _actorUserIdController,
            decoration: const InputDecoration(
              labelText: 'Actor user ID (optional)',
              hintText: 'uuid to narrow to one person',
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            key: const Key('operator_web_audit_log_hierarchy_action'),
            controller: _actionController,
            decoration: const InputDecoration(
              labelText: 'Action (optional)',
              hintText: 'e.g. auth.password_changed',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_rowsLoading && _rows.isEmpty) {
      return const Padding(
        key: Key('operator_web_audit_log_hierarchy_loading'),
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sunsetDark,
            ),
          ),
        ),
      );
    }
    if (_rows.isEmpty && !_rowsLoading && _rowsLoadError == null) {
      return Padding(
        key: const Key('operator_web_audit_log_hierarchy_empty'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          _selectedScopeLabel == 'Whole business'
              ? 'Tap "Run filter" to load rows for the whole business.'
              : 'No audit log rows match the current scope and filters. '
                  'Widen the time range, clear the actor or action filter, '
                  'or pick a broader scope.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      );
    }
    return Column(
      key: const Key('operator_web_audit_log_hierarchy_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final row in _rows) _HierarchyRowTile(row: row),
      ],
    );
  }

  InheritanceTreeNode _buildInheritanceRoot() {
    final byParent = <String?, List<TeamOrgUnitEntry>>{};
    for (final unit in _orgUnits) {
      byParent
          .putIfAbsent(unit.parentOrgUnitId, () => <TeamOrgUnitEntry>[])
          .add(unit);
    }
    for (final list in byParent.values) {
      list.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    }
    final locationsByParent = <String, List<TeamOrgLocationEntry>>{};
    for (final location in _locations) {
      locationsByParent
          .putIfAbsent(
            location.parentOrgUnitId,
            () => <TeamOrgLocationEntry>[],
          )
          .add(location);
    }
    for (final list in locationsByParent.values) {
      list.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    }
    final roots = byParent[null] ?? const <TeamOrgUnitEntry>[];
    if (roots.length == 1) {
      return _buildUnitNode(
        roots.single,
        depth: 0,
        byParent: byParent,
        locationsByParent: locationsByParent,
      );
    }
    final children = <InheritanceTreeNode>[
      for (final root in roots)
        _buildUnitNode(
          root,
          depth: 1,
          byParent: byParent,
          locationsByParent: locationsByParent,
        ),
    ];
    return InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.business,
      scopeId: 'operator_web_audit_log_hierarchy_root',
      displayName: 'Whole business',
      children: children,
    );
  }

  InheritanceTreeNode _buildUnitNode(
    TeamOrgUnitEntry unit, {
    required int depth,
    required Map<String?, List<TeamOrgUnitEntry>> byParent,
    required Map<String, List<TeamOrgLocationEntry>> locationsByParent,
  }) {
    final childOrgUnits =
        byParent[unit.orgUnitId] ?? const <TeamOrgUnitEntry>[];
    final childLocations =
        locationsByParent[unit.orgUnitId] ?? const <TeamOrgLocationEntry>[];
    final childNodes = <InheritanceTreeNode>[
      for (final child in childOrgUnits)
        _buildUnitNode(
          child,
          depth: depth + 1,
          byParent: byParent,
          locationsByParent: locationsByParent,
        ),
      for (final location in childLocations)
        InheritanceTreeNode(
          scopeKind: InheritanceTreeScopeKind.location,
          scopeId: location.locationId,
          displayName: location.label,
          parentScopeId: location.parentOrgUnitId,
          depth: depth + 1,
        ),
    ]..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    return InheritanceTreeNode(
      scopeKind: unit.parentOrgUnitId == null
          ? InheritanceTreeScopeKind.business
          : InheritanceTreeScopeKind.orgUnit,
      scopeId: unit.orgUnitId,
      displayName: unit.label,
      parentScopeId: unit.parentOrgUnitId,
      depth: depth,
      children: List<InheritanceTreeNode>.unmodifiable(childNodes),
    );
  }

  static String _formatDate(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String? _trimmedOrNull(String raw) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _HierarchyRowTile extends StatelessWidget {
  const _HierarchyRowTile({required this.row});

  final WebAuditLogHierarchyRow row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        key: Key('operator_web_audit_log_hierarchy_row_${row.id}'),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.backgroundDeep,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    row.action,
                    style: AppTextStyles.body13(color: AppColors.textPrimary)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  row.occurredAt.toIso8601String(),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Actor: ${_actorLabel(row)}  Target: ${_targetLabel(row)}',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
            if (row.locationId != null)
              Text(
                'Location: ${row.locationId}',
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
          ],
        ),
      ),
    );
  }

  static String _actorLabel(WebAuditLogHierarchyRow row) {
    // Wave 2 AC-1 - raw actor_kind enum strings ("user", "forge_admin",
    // "service_principal", "system", ...) are translated to plain
    // English via the shared catalog so the operator-web row reads as
    // UX copy. Falls back to the raw string if the proxy ever ships a
    // brand-new enum value.
    final label = ActorKindLabelCatalog.labelFor(row.actorKind);
    if (row.actorUserId != null) return '$label ${row.actorUserId}';
    if (row.actorPrincipalId != null) {
      return '$label ${row.actorPrincipalId}';
    }
    return label;
  }

  static String _targetLabel(WebAuditLogHierarchyRow row) {
    if (row.targetKind == null && row.targetId == null) return 'n/a';
    return '${row.targetKind ?? '?'} ${row.targetId ?? ''}'.trim();
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_hierarchy_error_banner'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.body12(color: AppColors.textPrimary),
      ),
    );
  }
}
