// Admin: Vendor applicability (friendly redesign).
//
// Vendor applicability is the F&F-set allow-list of which connected
// vendors may power three operator settings: how labor dollars are
// worked out (wage), where covers come from (covers), and how often
// F&F checks for fresh data (data freshness / polling). A rule can be
// scoped to all operators, one operator, or one operator + one
// location; the most specific current rule wins.
//
// This screen replaces the earlier raw-JSON editor with a plain-English
// surface that mirrors operator-web's wording (the same words operators
// read on the Data accuracy screen) so support and operators describe
// the same setting the same way. The friendly Add/Edit form generates
// the narrow per-kind metadata JSON; an "Advanced" fold still exposes
// the raw JSON for power users behind the advanced editor. Writes stay
// temporal (a new dated row per change, nothing deleted), idempotent,
// and audited through the location-aware admin gateway.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../services/settings/applicability_metadata_schemas.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/vendor_applicability_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
import 'vendor_applicability_recommended_defaults.dart';
import 'vendor_applicability_vendor_catalog.dart';

ButtonStyle _adminSegmentedButtonStyle() {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(
      Size(0, AdminButtonStyles.controlHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
      ),
    ),
    textStyle: WidgetStatePropertyAll(
      AppTextStyles.buttonLabel(color: AppColors.textPrimary),
    ),
  );
}

const double _kVendorApplicabilityMaxWidth = 1180;
const double _kVendorApplicabilityCenterBreakpoint = 1280;
const double _kAdminShellSideNavWidth = 304;
const double _kAdminWorkspaceScopePaneWidth = 361;
const double _kAdminWorkspaceSplitBreakpoint = 920;
const double _kAdminWorkspaceShellBreakpoint = 720;

class VendorApplicabilityAdminScreen extends StatefulWidget {
  const VendorApplicabilityAdminScreen({
    super.key,
    required this.gateway,
    this.operatorLocationGateway,
    this.editingEnabled = true,
    this.initialSettingKind = VendorApplicabilitySettingKind.wage,
    this.hierarchyScope,
    this.scopeLocationIds = const <String>{},
    this.showPageHeader = true,
  });

  final VendorApplicabilityAdminGateway gateway;

  /// Optional operator + location source for resolving business/location
  /// names in rule rows. Scope is owned by the shared admin scope tree that
  /// wraps this screen in the route builder.
  final OperatorLocationAdminGateway? operatorLocationGateway;

  final bool editingEnabled;
  final String initialSettingKind;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final Set<String> scopeLocationIds;
  final bool showPageHeader;

  @override
  State<VendorApplicabilityAdminScreen> createState() =>
      _VendorApplicabilityAdminScreenState();
}

class _VendorApplicabilityAdminScreenState
    extends State<VendorApplicabilityAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _actionError;
  List<VendorApplicabilityAdminRow> _rows =
      const <VendorApplicabilityAdminRow>[];
  int _loadGeneration = 0;
  int _idempotencyCounter = 0;

  // Operators + their locations, loaded once so rule rows can resolve
  // business names and location names without a per-row round-trip.
  List<OperatorAdminBundle> _operators = const <OperatorAdminBundle>[];

  static const List<_SettingKindSpec> _tabs = <_SettingKindSpec>[
    _SettingKindSpec(
      kind: VendorApplicabilitySettingKind.wage,
      label: 'Wage',
      // Mirrors operator-web "How labor dollars are calculated".
      guide:
          'Choose which connected vendors are allowed to work out labor '
          'dollars (the wage source operators see under Data accuracy).',
    ),
    _SettingKindSpec(
      kind: VendorApplicabilitySettingKind.covers,
      label: 'Covers',
      // Mirrors operator-web "Where covers come from".
      guide:
          'Choose which connected vendors are allowed to supply covers '
          '(guest counts) for each service period.',
    ),
    _SettingKindSpec(
      kind: VendorApplicabilitySettingKind.polling,
      label: 'Data freshness',
      // Mirrors operator-web "Data Freshness" tier card.
      guide:
          'Choose which connected vendors are allowed to use each data '
          'freshness setup (how often Forge & Flow checks for new data).',
    ),
  ];

  String get _selectedKind => _tabs[_tabController.index].kind;

  @override
  void initState() {
    super.initState();
    final initialIndex = _tabs.indexWhere(
      (tab) => tab.kind == widget.initialSettingKind,
    );
    _tabController =
        TabController(
          length: _tabs.length,
          vsync: this,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
        )..addListener(() {
          if (!_tabController.indexIsChanging) _refresh();
        });
    _loadOperators();
    _refresh();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadOperators() async {
    final gateway = widget.operatorLocationGateway;
    if (gateway == null) return;
    try {
      final operators = await gateway.listOperators();
      if (!mounted) return;
      setState(() => _operators = operators);
    } catch (_) {
      // Row labels degrade to IDs; surfacing a hard error here would block
      // the still-working rule list and global write path.
      if (!mounted) return;
      setState(() => _operators = const <OperatorAdminBundle>[]);
    }
  }

  Future<void> _refresh() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
      _actionError = null;
    });
    try {
      final rows = await widget.gateway.list(
        filter: VendorApplicabilityAdminFilter(
          settingKind: _selectedKind,
          currentOnly: false,
        ),
      );
      rows.sort(_compareRows);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = 'Could not load vendor applicability: $error';
        _loading = false;
      });
    }
  }

  // Current rows first (most specific scope first, then vendor), then
  // history newest-first. Keeps the "Current rules" list readable and
  // the History section chronological.
  int _compareRows(
    VendorApplicabilityAdminRow a,
    VendorApplicabilityAdminRow b,
  ) {
    final scope = _scopeRank(a).compareTo(_scopeRank(b));
    if (scope != 0) return scope;
    final vendor = _vendorLabel(
      a.vendorSlug,
    ).compareTo(_vendorLabel(b.vendorSlug));
    if (vendor != 0) return vendor;
    final key = a.settingKey.compareTo(b.settingKey);
    if (key != 0) return key;
    return b.effectiveFrom.compareTo(a.effectiveFrom);
  }

  // Location-scoped (0) before operator-scoped (1) before global (2).
  int _scopeRank(VendorApplicabilityAdminRow row) {
    if (row.locationId != null) return 0;
    if (row.operatorId != null) return 1;
    return 2;
  }

  List<VendorApplicabilityAdminRow> get _visibleRows =>
      _rows.where(_rowAppliesToSelectedScope).toList(growable: false);

  List<VendorApplicabilityAdminRow> get _currentRows => _visibleRows
      .where((row) => row.effectiveUntil == null)
      .toList(growable: false);

  List<VendorApplicabilityAdminRow> get _historyRows => _visibleRows
      .where((row) => row.effectiveUntil != null)
      .toList(growable: false);

  bool _rowAppliesToSelectedScope(VendorApplicabilityAdminRow row) {
    final scope = widget.hierarchyScope;
    if (scope == null) return true;
    final rowOperatorId = row.operatorId;
    if (rowOperatorId == null) return true;
    if (rowOperatorId != scope.operatorId) return false;
    final rowLocationId = row.locationId;
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return true;
      case AdminHierarchyScopeType.orgUnit:
        return rowLocationId == null ||
            widget.scopeLocationIds.contains(rowLocationId);
      case AdminHierarchyScopeType.location:
        return rowLocationId == null || rowLocationId == scope.locationId;
    }
  }

  String _newIdempotencyKey(String action) {
    _idempotencyCounter += 1;
    return 'admin-vendor-applicability-$action-'
        '${DateTime.now().microsecondsSinceEpoch}-$_idempotencyCounter';
  }

  Future<void> _openAddDialog() async {
    if (!_canWriteSelectedScope) {
      setState(
        () => _actionError =
            'Vendor applicability can view org-unit scope, but rules are '
            'stored at business or location scope today.',
      );
      return;
    }
    final draft = await showDialog<_VendorApplicabilityDraft>(
      context: context,
      builder: (_) => _VendorApplicabilityEditDialog(
        settingKind: _selectedKind,
        operatorId: _selectedScopeOperatorId,
        locationId: _selectedScopeLocationId,
        scopeLabel: _selectedScopeLabel,
        scopeSummaryLabel: 'New rule scope',
      ),
    );
    if (draft == null) return;
    await _upsertDraft(draft);
  }

  Future<void> _openEditDialog(VendorApplicabilityAdminRow row) async {
    final inherited = _rowIsInheritedIntoSelectedScope(row);
    final draft = await showDialog<_VendorApplicabilityDraft>(
      context: context,
      builder: (_) => _VendorApplicabilityEditDialog(
        settingKind: row.settingKind,
        operatorId: inherited ? _selectedScopeOperatorId : row.operatorId,
        locationId: inherited ? _selectedScopeLocationId : row.locationId,
        scopeLabel: inherited ? _selectedScopeLabel : _appliesToLabel(row),
        scopeSummaryLabel: inherited ? 'New override scope' : 'Rule scope',
        inheritedOverride: inherited,
        initial: row,
      ),
    );
    if (draft == null) return;
    await _upsertDraft(draft);
  }

  Future<void> _endRow(VendorApplicabilityAdminRow row) async {
    if (!widget.editingEnabled || _saving || row.effectiveUntil != null) return;
    if (_rowIsInheritedIntoSelectedScope(row)) {
      await _blockInheritedRowAtSelectedScope(row);
      return;
    }
    final reason = await _askReason(
      title: 'Stop using ${_vendorLabel(row.vendorSlug)}?',
      helper:
          'This ends the current rule from today. The previous rule stays in '
          'history; nothing is deleted.',
    );
    if (reason == null) return;
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      await widget.gateway.end(
        VendorApplicabilityEndCommand(
          operatorId: row.operatorId,
          locationId: row.locationId,
          settingKind: row.settingKind,
          settingKey: row.settingKey,
          vendorSlug: row.vendorSlug,
          adminReason: 'admin.vendor_applicability.end',
          reasonNote: reason,
          idempotencyKey: _newIdempotencyKey('end'),
        ),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Could not end this rule: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _blockInheritedRowAtSelectedScope(
    VendorApplicabilityAdminRow row,
  ) async {
    if (!_canWriteSelectedScope) return;
    final reason = await _askReason(
      title: 'Block ${_vendorLabel(row.vendorSlug)} here?',
      helper:
          'This adds a rule for $_selectedScopeLabel and leaves the wider '
          'rule unchanged.',
    );
    if (reason == null) return;
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      await widget.gateway.upsert(
        VendorApplicabilityUpsertCommand(
          operatorId: _selectedScopeOperatorId,
          locationId: _selectedScopeLocationId,
          settingKind: row.settingKind,
          settingKey: row.settingKey,
          vendorSlug: row.vendorSlug,
          enabled: false,
          metadata: row.metadata,
          adminReason: 'admin.vendor_applicability.upsert',
          reasonNote: reason,
          idempotencyKey: _newIdempotencyKey('override'),
        ),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Could not block this vendor here: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _upsertDraft(_VendorApplicabilityDraft draft) async {
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      await widget.gateway.upsert(
        VendorApplicabilityUpsertCommand(
          operatorId: draft.operatorId,
          locationId: draft.locationId,
          settingKind: draft.settingKind,
          settingKey: draft.settingKey,
          vendorSlug: draft.vendorSlug,
          enabled: draft.enabled,
          metadata: draft.metadata,
          adminReason: 'admin.vendor_applicability.upsert',
          reasonNote: draft.reasonNote,
          idempotencyKey: _newIdempotencyKey('upsert'),
        ),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Could not save this rule: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openRecommendedDefaultsDialog() async {
    if (!_canWriteSelectedScope) {
      setState(
        () => _actionError =
            'Vendor applicability can view org-unit scope, but rules are '
            'stored at business or location scope today.',
      );
      return;
    }
    final proposal = _buildRecommendedDefaultsProposal();
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _RecommendedDefaultsDialog(
        scopeLabel: _selectedScopeLabel,
        settingLabel: _recommendedDefaultsSettingLabel,
        proposal: proposal,
      ),
    );
    if (reason == null || proposal.missing.isEmpty) return;
    await _applyRecommendedDefaults(proposal.missing, reason);
  }

  _RecommendedDefaultsProposal _buildRecommendedDefaultsProposal() {
    final defaults = recommendedVendorApplicabilityDefaultsFor(_selectedKind);
    final currentRows = _currentRows;
    final missing = <VendorApplicabilityRecommendedDefault>[];
    final review = <VendorApplicabilityRecommendedDefault>[];
    var matching = 0;

    for (final recommended in defaults) {
      final candidates = currentRows
          .where(
            (row) =>
                row.settingKind == recommended.settingKind &&
                row.settingKey == recommended.settingKey &&
                row.vendorSlug == recommended.vendorSlug,
          )
          .toList(growable: false);
      if (candidates.isEmpty) {
        missing.add(recommended);
        continue;
      }
      if (candidates.any((row) => _rowMatchesRecommended(row, recommended))) {
        matching += 1;
      } else {
        review.add(recommended);
      }
    }

    return _RecommendedDefaultsProposal(
      missing: missing,
      review: review,
      matchingCount: matching,
    );
  }

  bool _rowMatchesRecommended(
    VendorApplicabilityAdminRow row,
    VendorApplicabilityRecommendedDefault recommended,
  ) {
    return row.enabled == recommended.enabled &&
        _jsonLikeEquals(row.metadata, recommended.metadata);
  }

  Future<void> _applyRecommendedDefaults(
    List<VendorApplicabilityRecommendedDefault> defaults,
    String reason,
  ) async {
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      for (final recommended in defaults) {
        await widget.gateway.upsert(
          VendorApplicabilityUpsertCommand(
            operatorId: _selectedScopeOperatorId,
            locationId: _selectedScopeLocationId,
            settingKind: recommended.settingKind,
            settingKey: recommended.settingKey,
            vendorSlug: recommended.vendorSlug,
            enabled: recommended.enabled,
            metadata: recommended.metadata,
            adminReason: 'admin.vendor_applicability.upsert',
            reasonNote: reason,
            idempotencyKey: _newIdempotencyKey('recommended'),
          ),
        );
      }
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _actionError = 'Could not apply recommended defaults: $error',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _askReason({required String title, required String helper}) {
    return showDialog<String>(
      context: context,
      builder: (_) => _ReasonDialog(title: title, helper: helper),
    );
  }

  String _appliesToLabel(VendorApplicabilityAdminRow row) {
    return appliesToLabelFor(
      operators: _operators,
      operatorId: row.operatorId,
      locationId: row.locationId,
    );
  }

  String _vendorLabel(String vendorSlug) => vendorDisplayName(vendorSlug);

  String _scopeSubtitleForRow(VendorApplicabilityAdminRow row) {
    final scope = widget.hierarchyScope;
    if (scope == null) return 'Scope';
    if (row.operatorId == null) return 'Inherited';
    if (row.locationId == null) {
      return scope.isBusinessScope ? 'Selected business' : 'Inherited';
    }
    if (scope.isLocationScope && row.locationId == scope.locationId) {
      return 'Selected location';
    }
    if (scope.isOrgUnitScope &&
        widget.scopeLocationIds.contains(row.locationId)) {
      return 'Location in selected scope';
    }
    return 'Scope';
  }

  bool _rowIsInheritedIntoSelectedScope(VendorApplicabilityAdminRow row) {
    final scope = widget.hierarchyScope;
    if (scope == null || scope.isOrgUnitScope) return false;
    if (row.operatorId == null) return true;
    if (row.operatorId != scope.operatorId) return false;
    if (scope.isBusinessScope) return false;
    return row.locationId != scope.locationId;
  }

  bool get _canWriteSelectedScope {
    final scope = widget.hierarchyScope;
    return scope == null || scope.isBusinessScope || scope.isLocationScope;
  }

  String get _selectedScopeLabel {
    final scope = widget.hierarchyScope;
    if (scope == null) return 'All businesses';
    return scope.displayLabel;
  }

  String? get _selectedScopeOperatorId {
    final scope = widget.hierarchyScope;
    if (scope == null) return null;
    return scope.operatorId;
  }

  String? get _selectedScopeLocationId {
    final scope = widget.hierarchyScope;
    if (scope == null || !scope.isLocationScope) return null;
    return scope.locationId;
  }

  String get _recommendedDefaultsSettingLabel {
    switch (_selectedKind) {
      case VendorApplicabilitySettingKind.wage:
        return 'wage';
      case VendorApplicabilitySettingKind.covers:
        return 'covers';
      case VendorApplicabilitySettingKind.polling:
        return 'data freshness';
      default:
        return 'vendor';
    }
  }

  double _contentWidthFor(BuildContext context, BoxConstraints constraints) {
    final boundedWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : MediaQuery.sizeOf(context).width;
    if (widget.showPageHeader) {
      return boundedWidth >= _kVendorApplicabilityCenterBreakpoint
          ? boundedWidth
          : boundedWidth.clamp(0.0, _kVendorApplicabilityMaxWidth).toDouble();
    }

    final viewportWidth = MediaQuery.sizeOf(context).width;
    final shellBodyWidth = viewportWidth >= _kAdminWorkspaceShellBreakpoint
        ? viewportWidth - _kAdminShellSideNavWidth
        : viewportWidth;
    final splitWorkspace = shellBodyWidth >= _kAdminWorkspaceSplitBreakpoint;
    final embeddedPaneWidth = splitWorkspace
        ? shellBodyWidth - _kAdminWorkspaceScopePaneWidth
        : shellBodyWidth;
    final width = boundedWidth < embeddedPaneWidth
        ? boundedWidth
        : embeddedPaneWidth;
    return width.clamp(0.0, _kVendorApplicabilityMaxWidth).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final spec = _tabs[_tabController.index];
    final currentRows = _currentRows;
    final allowedCount = currentRows.where((row) => row.enabled).length;
    final blockedCount = currentRows.length - allowedCount;
    return ColoredBox(
      key: const Key('admin_vendor_applicability_screen'),
      color: AppColors.backgroundDeep,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final visiblePaneWidth = _contentWidthFor(context, constraints);
          return Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: visiblePaneWidth,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: _kVendorApplicabilityMaxWidth,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.showPageHeader) ...[
                          const OperatorWebScreenHeader(
                            icon: Icons.rule_outlined,
                            title: 'Vendor Applicability',
                            collapseBelowWidth: 0,
                            subtitle:
                                'Choose which vendors are allowed to power '
                                'wage, covers, and data freshness settings.',
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (!widget.editingEnabled)
                          const _InlineBanner(
                            key: Key('admin_vendor_applicability_readonly'),
                            icon: Icons.lock_outline,
                            message:
                                'Only super admins can change vendor '
                                'applicability. This view is read-only for '
                                'support.',
                          ),
                        if (_actionError != null)
                          _InlineBanner(
                            key: const Key(
                              'admin_vendor_applicability_action_error',
                            ),
                            icon: Icons.warning_amber_rounded,
                            message: _actionError!,
                            isError: true,
                          ),
                        if (!_canWriteSelectedScope)
                          const _InlineBanner(
                            key: Key(
                              'admin_vendor_applicability_org_unit_notice',
                            ),
                            icon: Icons.account_tree_outlined,
                            message:
                                'Org-unit scope is visible here, but vendor '
                                'applicability rules are saved at business or '
                                'location scope today.',
                          ),
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.backgroundSurface,
                            border: Border.all(
                              color: AppColors.borderSubtle,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: TabBar(
                            controller: _tabController,
                            labelColor: AppColors.textPrimary,
                            unselectedLabelColor: AppColors.textMuted,
                            indicatorColor: AppColors.sunsetDark,
                            tabs: [
                              for (final tab in _tabs) Tab(text: tab.label),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _Toolbar(
                          guide: spec.guide,
                          scopeLabel: _selectedScopeLabel,
                          allowedCount: allowedCount,
                          blockedCount: blockedCount,
                          saving: _saving,
                          editingEnabled: widget.editingEnabled,
                          canAdd: _canWriteSelectedScope,
                          onAdd: _openAddDialog,
                          onRecommendedDefaults: _openRecommendedDefaultsDialog,
                          onRefresh: _refresh,
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: Container(
                            key: const Key(
                              'admin_vendor_applicability_body_surface',
                            ),
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: AppColors.backgroundSurface,
                              border: Border.all(
                                color: AppColors.borderSubtle,
                                width: 1,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: _buildBody(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_vendor_applicability_loading'),
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.sunsetDark,
        ),
      );
    }
    if (_loadError != null) {
      return _InlineBanner(
        key: const Key('admin_vendor_applicability_load_error'),
        icon: Icons.warning_amber_rounded,
        message: _loadError!,
        isError: true,
      );
    }
    final current = _currentRows;
    final history = _historyRows;
    if (current.isEmpty && history.isEmpty) {
      return const _EmptyState();
    }
    return Scrollbar(
      child: ListView(
        key: const Key('admin_vendor_applicability_list'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        children: [
          _SectionLabel(text: 'Current rules', count: current.length),
          const SizedBox(height: 10),
          if (current.isEmpty)
            const _MutedNote(
              text:
                  'No current rule for this setting. Add one to allow or block '
                  'a vendor.',
            )
          else
            for (final row in current) ...[
              _RuleCard(
                row: row,
                appliesTo: _appliesToLabel(row),
                appliesToSubtitle: _scopeSubtitleForRow(row),
                vendorLabel: _vendorLabel(row.vendorSlug),
                editingEnabled: widget.editingEnabled && _canWriteSelectedScope,
                saving: _saving,
                onEdit: () => _openEditDialog(row),
                onEnd: () => _endRow(row),
              ),
              const SizedBox(height: 10),
            ],
          if (history.isNotEmpty) ...[
            const SizedBox(height: 8),
            _HistorySection(
              rows: history,
              appliesToLabel: _appliesToLabel,
              vendorLabel: _vendorLabel,
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingKindSpec {
  const _SettingKindSpec({
    required this.kind,
    required this.label,
    required this.guide,
  });

  final String kind;
  final String label;
  final String guide;
}

class _RecommendedDefaultsProposal {
  const _RecommendedDefaultsProposal({
    required this.missing,
    required this.review,
    required this.matchingCount,
  });

  final List<VendorApplicabilityRecommendedDefault> missing;
  final List<VendorApplicabilityRecommendedDefault> review;
  final int matchingCount;
}

class _RecommendedDefaultsDialog extends StatefulWidget {
  const _RecommendedDefaultsDialog({
    required this.scopeLabel,
    required this.settingLabel,
    required this.proposal,
  });

  final String scopeLabel;
  final String settingLabel;
  final _RecommendedDefaultsProposal proposal;

  @override
  State<_RecommendedDefaultsDialog> createState() =>
      _RecommendedDefaultsDialogState();
}

class _RecommendedDefaultsDialogState
    extends State<_RecommendedDefaultsDialog> {
  late final TextEditingController _reason = TextEditingController(
    text: 'Apply recommended ${widget.settingLabel} defaults',
  );

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.proposal.missing.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final reason = _reason.text.trim();
    Navigator.of(
      context,
    ).pop(reason.isEmpty ? 'Apply recommended defaults' : reason);
  }

  @override
  Widget build(BuildContext context) {
    final missing = widget.proposal.missing;
    final reviewCount = widget.proposal.review.length;
    final visibleMissing = missing.take(3).toList(growable: false);
    final hiddenMissingCount = missing.length - visibleMissing.length;
    final title = missing.isEmpty
        ? 'Recommended defaults are in place.'
        : 'Add ${missing.length} missing ${widget.settingLabel} '
              '${missing.length == 1 ? 'rule' : 'rules'}.';
    return OperatorWebDialog(
      key: const Key('admin_vendor_applicability_recommended_dialog'),
      title: 'Use recommended defaults?',
      icon: Icons.playlist_add_check_outlined,
      maxWidth: 640,
      actions: [
        AdminActionButton(
          label: missing.isEmpty ? 'Close' : 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        if (missing.isNotEmpty)
          AdminActionButton(
            key: const Key('admin_vendor_applicability_recommended_apply'),
            label:
                'Add ${missing.length} ${missing.length == 1 ? 'rule' : 'rules'}',
            onPressed: _submit,
            role: AdminActionRole.primary,
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.scopeLabel, style: AppTextStyles.body13()),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: AppColors.cardGlow,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.body15Bold(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  'Existing rules will not be changed.',
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          if (visibleMissing.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final recommended in visibleMissing) ...[
              _RecommendedDefaultRow(recommended: recommended),
              const SizedBox(height: 8),
            ],
          ],
          if (hiddenMissingCount > 0) ...[
            const SizedBox(height: 2),
            Text(
              '$hiddenMissingCount more will be added.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
          if (reviewCount > 0) ...[
            const SizedBox(height: 10),
            Text(
              '$reviewCount existing ${reviewCount == 1 ? 'rule differs' : 'rules differ'}. Review separately.',
              style: AppTextStyles.body12(color: AppColors.sunsetDark),
            ),
          ],
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 14),
            TextField(
              key: const Key('admin_vendor_applicability_recommended_reason'),
              controller: _reason,
              decoration: const InputDecoration(
                labelText: 'Reason',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecommendedDefaultRow extends StatelessWidget {
  const _RecommendedDefaultRow({required this.recommended});

  final VendorApplicabilityRecommendedDefault recommended;

  @override
  Widget build(BuildContext context) {
    final chips = friendlyMetadataChips(
      settingKind: recommended.settingKind,
      metadata: recommended.metadata,
    );
    final subtitle = chips.isEmpty
        ? (recommended.enabled ? 'Allowed' : 'Blocked')
        : chips.first;
    return Container(
      key: Key(
        'admin_vendor_applicability_recommended_${recommended.settingKind}_'
        '${recommended.settingKey}_${recommended.vendorSlug}',
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: _EnabledPill(enabled: recommended.enabled),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _RuleTextBlock(
              title: vendorDisplayName(recommended.vendorSlug),
              subtitle: subtitle,
              titleMaxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.guide,
    required this.scopeLabel,
    required this.allowedCount,
    required this.blockedCount,
    required this.saving,
    required this.editingEnabled,
    required this.canAdd,
    required this.onAdd,
    required this.onRecommendedDefaults,
    required this.onRefresh,
  });

  final String guide;
  final String scopeLabel;
  final int allowedCount;
  final int blockedCount;
  final bool saving;
  final bool editingEnabled;
  final bool canAdd;
  final VoidCallback onAdd;
  final VoidCallback onRecommendedDefaults;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: const Key('admin_vendor_applicability_toolbar'),
      builder: (context, constraints) {
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AdminIconAction(
              key: const Key('admin_vendor_applicability_refresh'),
              icon: Icons.refresh_outlined,
              tooltip: 'Refresh',
              onPressed: saving ? null : onRefresh,
            ),
            AdminActionButton(
              key: const Key('admin_vendor_applicability_recommended_defaults'),
              label: 'Use defaults',
              onPressed: editingEnabled && canAdd && !saving
                  ? onRecommendedDefaults
                  : null,
              role: AdminActionRole.secondary,
              compact: true,
              minWidth: 96,
            ),
            AdminActionButton(
              key: const Key('admin_vendor_applicability_add'),
              label: saving ? 'Saving...' : 'Add rule',
              onPressed: editingEnabled && canAdd && !saving ? onAdd : null,
              icon: Icons.add_outlined,
              role: AdminActionRole.primary,
            ),
          ],
        );
        final summary = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              guide,
              key: const Key('admin_vendor_applicability_guide'),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              '$allowedCount allowed, $blockedCount blocked. '
              'Viewing: $scopeLabel',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ],
        );
        final child = constraints.maxWidth < 720
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              )
            : Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: 18),
                  actions,
                ],
              );
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, this.count});

  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final suffix = count == null ? '' : ' ($count)';
    return Text(
      '$text$suffix',
      style: AppTextStyles.mono12(
        color: AppColors.textPrimary,
        weight: FontWeight.w700,
      ),
    );
  }
}

class _MutedNote extends StatelessWidget {
  const _MutedNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppTextStyles.body13(color: AppColors.textMuted));
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.row,
    required this.appliesTo,
    required this.appliesToSubtitle,
    required this.vendorLabel,
    required this.editingEnabled,
    required this.saving,
    required this.onEdit,
    required this.onEnd,
  });

  final VendorApplicabilityAdminRow row;
  final String appliesTo;
  final String appliesToSubtitle;
  final String vendorLabel;
  final bool editingEnabled;
  final bool saving;
  final VoidCallback onEdit;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('vendor_applicability_${row.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vendorBlock = _RuleTextBlock(
            title: vendorLabel,
            subtitle: vendorCategoryLabel(row.vendorSlug),
            titleMaxLines: 2,
          );
          final scopeBlock = _RuleTextBlock(
            title: appliesTo,
            subtitle: appliesToSubtitle,
            titleMaxLines: 2,
          );
          final dateBlock = _RuleTextBlock(
            title: _formatDate(row.effectiveFrom),
            subtitle: 'Effective since',
          );
          final status = SizedBox(
            width: 88,
            child: _EnabledPill(enabled: row.enabled),
          );
          final actions = editingEnabled
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AdminIconAction(
                      key: Key('admin_vendor_applicability_edit_${row.id}'),
                      icon: Icons.edit_outlined,
                      tooltip: 'Edit rule',
                      onPressed: saving ? null : onEdit,
                    ),
                    AdminIconAction(
                      key: Key('admin_vendor_applicability_end_${row.id}'),
                      icon: Icons.event_busy_outlined,
                      tooltip: 'Stop using this vendor',
                      onPressed: saving ? null : onEnd,
                      destructive: true,
                    ),
                  ],
                )
              : const SizedBox(width: 48);

          if (constraints.maxWidth < 980) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: vendorBlock),
                    const SizedBox(width: 12),
                    status,
                    const SizedBox(width: 6),
                    actions,
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: scopeBlock),
                    const SizedBox(width: 16),
                    SizedBox(width: 112, child: dateBlock),
                  ],
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 5, child: vendorBlock),
              const SizedBox(width: 16),
              status,
              const SizedBox(width: 16),
              Expanded(flex: 4, child: scopeBlock),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: dateBlock),
              const SizedBox(width: 8),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _RuleTextBlock extends StatelessWidget {
  const _RuleTextBlock({
    required this.title,
    required this.subtitle,
    this.titleMaxLines = 1,
  });

  final String title;
  final String subtitle;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.mono11(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _EnabledPill extends StatelessWidget {
  const _EnabledPill({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.positive : AppColors.negative;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.42), width: 1),
        borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
      ),
      child: Text(
        enabled ? 'Allowed' : 'Blocked',
        style: AppTextStyles.mono11(color: color),
      ),
    );
  }
}

class _AppliesToChip extends StatelessWidget {
  const _AppliesToChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return _SummaryChip(
      label: 'Applies to: $label',
      icon: Icons.place_outlined,
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: AppColors.textMuted),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _HistorySection extends StatefulWidget {
  const _HistorySection({
    required this.rows,
    required this.appliesToLabel,
    required this.vendorLabel,
  });

  final List<VendorApplicabilityAdminRow> rows;
  final String Function(VendorApplicabilityAdminRow) appliesToLabel;
  final String Function(String) vendorLabel;

  @override
  State<_HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<_HistorySection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_vendor_applicability_history'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('admin_vendor_applicability_history_toggle'),
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SectionLabel(
                      text: 'History (older or ended rules)',
                      count: widget.rows.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                children: [
                  for (final row in widget.rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _HistoryRow(
                        row: row,
                        appliesTo: widget.appliesToLabel(row),
                        vendorLabel: widget.vendorLabel(row.vendorSlug),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.row,
    required this.appliesTo,
    required this.vendorLabel,
  });

  final VendorApplicabilityAdminRow row;
  final String appliesTo;
  final String vendorLabel;

  @override
  Widget build(BuildContext context) {
    final range =
        '${_formatDate(row.effectiveFrom)} to ${_formatDate(row.effectiveUntil)}';
    return Container(
      key: ValueKey('vendor_applicability_history_${row.id}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                vendorLabel,
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              _EnabledPill(enabled: row.enabled),
              _AppliesToChip(label: appliesTo),
            ],
          ),
          const SizedBox(height: 6),
          Text(range, style: AppTextStyles.body12(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

// ── Add / Edit dialog ────────────────────────────────────────────────

class _VendorApplicabilityDraft {
  const _VendorApplicabilityDraft({
    required this.operatorId,
    required this.locationId,
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    required this.enabled,
    required this.metadata,
    required this.reasonNote,
  });

  final String? operatorId;
  final String? locationId;
  final String settingKind;
  final String settingKey;
  final String vendorSlug;
  final bool enabled;
  final Map<String, Object?> metadata;
  final String reasonNote;
}

class _VendorApplicabilityEditDialog extends StatefulWidget {
  const _VendorApplicabilityEditDialog({
    required this.settingKind,
    required this.operatorId,
    required this.locationId,
    required this.scopeLabel,
    required this.scopeSummaryLabel,
    this.inheritedOverride = false,
    this.initial,
  });

  final String settingKind;
  final String? operatorId;
  final String? locationId;
  final String scopeLabel;
  final String scopeSummaryLabel;
  final bool inheritedOverride;
  final VendorApplicabilityAdminRow? initial;

  @override
  State<_VendorApplicabilityEditDialog> createState() =>
      _VendorApplicabilityEditDialogState();
}

class _VendorApplicabilityEditDialogState
    extends State<_VendorApplicabilityEditDialog> {
  static final RegExp _slugPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  // Vendor + allow/block.
  String? _vendorSlug;
  bool _showAllVendors = false;
  bool _enabled = true;

  // Per-kind friendly fields.
  // Wage.
  String? _authorityBasis;
  bool _requiresJobCode = false;
  // Covers.
  String? _coverFilter;
  final Set<String> _servicePeriods = <String>{};
  bool _excludeVoids = false;
  // Data freshness (polling).
  String _tierKey = 'standard';
  final TextEditingController _pollingMinutes = TextEditingController();

  // Progressive disclosure.
  bool _detailsExpanded = false;
  bool _advancedExpanded = false;
  bool _specialHelpExpanded = false;
  late final TextEditingController _settingKey;
  late final TextEditingController _metadataJson;
  bool _userEditedJson = false;

  final TextEditingController _reason = TextEditingController();
  final TextEditingController _servicePeriodEntry = TextEditingController();
  String? _error;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _settingKey = TextEditingController(text: initial?.settingKey ?? 'default');
    _metadataJson = TextEditingController();
    _vendorSlug = initial?.vendorSlug;
    _enabled = initial?.enabled ?? true;
    // A vendor that is not in the per-kind filtered list (e.g. a row that
    // was set before this redesign, or a slug the catalog does not know)
    // forces the "show all" toggle on so the dropdown can render it.
    if (_vendorSlug != null &&
        !_filteredVendors().any((v) => v.vendorId == _vendorSlug)) {
      _showAllVendors = true;
    }

    final metadata = initial?.metadata ?? const <String, Object?>{};
    _seedFriendlyFieldsFromMetadata(metadata);
    _detailsExpanded = _buildMetadata().isNotEmpty;
    _metadataJson.text = _prettyJson(_buildMetadata());
  }

  @override
  void dispose() {
    _settingKey.dispose();
    _metadataJson.dispose();
    _pollingMinutes.dispose();
    _reason.dispose();
    _servicePeriodEntry.dispose();
    super.dispose();
  }

  void _seedFriendlyFieldsFromMetadata(Map<String, Object?> metadata) {
    switch (widget.settingKind) {
      case VendorApplicabilitySettingKind.wage:
        final basis = metadata['authority_basis'];
        if (basis is String) _authorityBasis = basis;
        _requiresJobCode = metadata['requires_job_code'] == true;
        break;
      case VendorApplicabilitySettingKind.covers:
        final filter = metadata['cover_filter'];
        if (filter is String) _coverFilter = filter;
        final periods = metadata['service_periods'];
        if (periods is List) {
          for (final p in periods) {
            if (p is String) _servicePeriods.add(p);
          }
        }
        _excludeVoids = metadata['exclude_voids'] == true;
        break;
      case VendorApplicabilitySettingKind.polling:
        final tier = metadata['tier_key'];
        if (tier is String) _tierKey = tier;
        final seconds = metadata['polling_seconds_override'];
        if (seconds is int) {
          _pollingMinutes.text = (seconds ~/ 60).toString();
        }
        break;
    }
  }

  // Builds the narrow per-kind metadata map from the friendly fields,
  // mirroring `applicability_metadata_schemas.dart`. Omitted (null /
  // empty) fields are simply absent, which the schema treats as
  // "optional / not set".
  Map<String, Object?> _buildMetadata() {
    final out = <String, Object?>{};
    switch (widget.settingKind) {
      case VendorApplicabilitySettingKind.wage:
        if (_authorityBasis != null) out['authority_basis'] = _authorityBasis;
        if (_requiresJobCode) out['requires_job_code'] = true;
        break;
      case VendorApplicabilitySettingKind.covers:
        if (_coverFilter != null) out['cover_filter'] = _coverFilter;
        if (_servicePeriods.isNotEmpty) {
          out['service_periods'] = _servicePeriods.toList(growable: false);
        }
        if (_excludeVoids) out['exclude_voids'] = true;
        break;
      case VendorApplicabilitySettingKind.polling:
        out['tier_key'] = _tierKey;
        if (_tierKey == 'custom') {
          final minutes = int.tryParse(_pollingMinutes.text.trim());
          if (minutes != null) {
            out['polling_seconds_override'] = minutes * 60;
          }
        }
        break;
    }
    return out;
  }

  List<AdminVendorOption> _filteredVendors() {
    if (_showAllVendors) return kAdminVendorApplicabilityOptions;
    return vendorsForSettingKind(widget.settingKind);
  }

  void _syncJsonFromFriendlyFields() {
    if (_userEditedJson) return;
    _metadataJson.text = _prettyJson(_buildMetadata());
  }

  // The raw-JSON fold is the power-user authority once touched; the
  // friendly fields generate it otherwise. On submit we read whichever
  // is authoritative so the two never silently disagree.
  Map<String, Object?> _resolveMetadataOrThrow() {
    if (_userEditedJson) {
      final raw = _metadataJson.text.trim();
      final parsed = jsonDecode(raw.isEmpty ? '{}' : raw);
      if (parsed is! Map) {
        throw const FormatException('Metadata JSON must be an object.');
      }
      return parsed.cast<String, Object?>();
    }
    return _buildMetadata();
  }

  void _submit() {
    final vendorSlug = _vendorSlug;
    final settingKey = _settingKey.text.trim();
    final reason = _reason.text.trim();

    if (vendorSlug == null || !_slugPattern.hasMatch(vendorSlug)) {
      setState(() => _error = 'Choose a vendor.');
      return;
    }
    if (!_slugPattern.hasMatch(settingKey)) {
      setState(
        () => _error = 'Setting key must be a lowercase key (default is fine).',
      );
      return;
    }
    // Location-scoped writes always carry their parent operator (UI mirror
    // of the DB CHECK + proxy validation).
    final operatorId = widget.operatorId;
    final locationId = widget.locationId;
    if (locationId != null && operatorId == null) {
      setState(() => _error = 'Location rules must include their business.');
      return;
    }
    if (reason.isEmpty) {
      setState(() => _error = 'Add a reason before saving.');
      return;
    }

    late final Map<String, Object?> metadata;
    try {
      metadata = _resolveMetadataOrThrow();
      assertApplicabilityMetadataValid(
        settingKind: widget.settingKind,
        metadata: metadata,
      );
    } on FormatException catch (error) {
      setState(() => _error = 'Advanced JSON is invalid: ${error.message}');
      return;
    } on ApplicabilityMetadataValidationException catch (error) {
      setState(() => _error = error.message);
      return;
    }

    Navigator.of(context).pop(
      _VendorApplicabilityDraft(
        operatorId: operatorId,
        locationId: locationId,
        settingKind: widget.settingKind,
        settingKey: settingKey,
        vendorSlug: vendorSlug,
        enabled: _enabled,
        metadata: metadata,
        reasonNote: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_vendor_applicability_edit_dialog'),
      title: widget.inheritedOverride
          ? 'Add override'
          : _isEditing
          ? 'Edit rule'
          : 'Add rule',
      icon: Icons.rule_folder_outlined,
      maxWidth: 1020,
      actions: [
        AdminActionButton(
          key: const Key('admin_vendor_applicability_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_vendor_applicability_submit'),
          label: widget.inheritedOverride
              ? 'Save override'
              : _isEditing
              ? 'Save rule'
              : 'Add rule',
          onPressed: _submit,
          role: AdminActionRole.primary,
        ),
      ],
      child: SizedBox(
        width: 960,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              OperatorWebBanner(
                key: const Key('admin_vendor_applicability_dialog_error'),
                icon: Icons.warning_amber_rounded,
                message: _error!,
                tone: OperatorWebBannerTone.error,
              ),
              const SizedBox(height: 14),
            ],
            _DialogGroup(title: 'Rule', child: _buildRuleBasics()),
            const SizedBox(height: 12),
            _CenteredDialogSection(child: _buildRuleFolds()),
            const SizedBox(height: 16),
            _CenteredDialogSection(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _FieldLabel(label: 'Reason'),
                  const SizedBox(height: 6),
                  TextField(
                    key: const Key('admin_vendor_applicability_reason'),
                    controller: _reason,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Ticket VA-200',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRuleBasics() {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget withScopeSummary(Widget child) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              child,
              const SizedBox(height: 14),
              _ScopeSummaryField(
                label: widget.scopeLabel,
                subtitle: widget.scopeSummaryLabel,
              ),
            ],
          );
        }

        if (constraints.maxWidth < 620) {
          return withScopeSummary(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildVendorPicker(),
                const SizedBox(height: 16),
                _buildAllowedToggle(),
              ],
            ),
          );
        }
        return withScopeSummary(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 12, child: _buildVendorPicker()),
              const SizedBox(width: 22),
              Expanded(flex: 10, child: _buildAllowedToggle()),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRuleFolds() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_buildOptionalFields(), _buildAdvanced()],
    );
  }

  Widget _buildVendorPicker() {
    final vendors = _filteredVendors();
    // If the seeded vendor is not in the (possibly filtered) list, add it
    // so the Dropdown value resolves without asserting.
    final items = <DropdownMenuItem<String>>[
      for (final v in vendors)
        DropdownMenuItem<String>(
          key: Key('admin_vendor_applicability_vendor_item_${v.vendorId}'),
          value: v.vendorId,
          child: Text(v.displayName),
        ),
    ];
    final hasSelected = items.any((item) => item.value == _vendorSlug);
    if (_vendorSlug != null && !hasSelected) {
      items.add(
        DropdownMenuItem<String>(
          value: _vendorSlug,
          child: Text(vendorDisplayName(_vendorSlug!)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _FieldLabel(label: 'Vendor')),
            TextButton.icon(
              key: const Key('admin_vendor_applicability_show_all_vendors'),
              onPressed: () =>
                  setState(() => _showAllVendors = !_showAllVendors),
              icon: Icon(
                _showAllVendors
                    ? Icons.filter_alt_off_outlined
                    : Icons.filter_alt_outlined,
                size: 16,
              ),
              label: Text(
                _showAllVendors ? 'Show fitting vendors' : 'Show all',
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: const Key('admin_vendor_applicability_vendor_dropdown'),
          initialValue: _vendorSlug,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          hint: const Text('Choose a vendor'),
          items: items,
          onChanged: (value) => setState(() => _vendorSlug = value),
        ),
      ],
    );
  }

  Widget _buildAllowedToggle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel(label: 'Status'),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          key: const Key('admin_vendor_applicability_enabled'),
          style: _adminSegmentedButtonStyle(),
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: true, label: Text('Allowed')),
            ButtonSegment<bool>(value: false, label: Text('Blocked')),
          ],
          selected: <bool>{_enabled},
          onSelectionChanged: (selection) =>
              setState(() => _enabled = selection.first),
        ),
      ],
    );
  }

  Widget _buildOptionalFields() {
    final Widget body;
    switch (widget.settingKind) {
      case VendorApplicabilitySettingKind.wage:
        body = _buildWageFields();
        break;
      case VendorApplicabilitySettingKind.covers:
        body = _buildCoversFields();
        break;
      case VendorApplicabilitySettingKind.polling:
        body = _buildPollingFields();
        break;
      default:
        body = const SizedBox.shrink();
    }
    return _AdvancedFold(
      foldKey: const Key('admin_vendor_applicability_details_toggle'),
      title: 'Special handling',
      subtitle: _specialHandlingSummary(),
      trailing: _InfoToggleButton(
        selected: _specialHelpExpanded,
        onPressed: () =>
            setState(() => _specialHelpExpanded = !_specialHelpExpanded),
      ),
      expanded: _detailsExpanded,
      onToggle: () => setState(() => _detailsExpanded = !_detailsExpanded),
      child: Column(
        key: const Key('admin_vendor_applicability_optional_block'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_specialHelpExpanded) ...[
            _SpecialHandlingHelp(settingKind: widget.settingKind),
            const SizedBox(height: 12),
          ],
          body,
        ],
      ),
    );
  }

  String _specialHandlingSummary() {
    final chips = friendlyMetadataChips(
      settingKind: widget.settingKind,
      metadata: _buildMetadata(),
    );
    if (chips.isEmpty) return 'None';
    final count = chips.length;
    return '$count ${count == 1 ? 'setting' : 'settings'} applied';
  }

  Widget _buildWageFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel(label: 'Pay rate'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String?>(
          key: const Key('admin_vendor_applicability_wage_authority'),
          initialValue: _authorityBasis,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          hint: const Text('Not set'),
          items: const <DropdownMenuItem<String?>>[
            DropdownMenuItem<String?>(value: null, child: Text('Not set')),
            DropdownMenuItem<String?>(
              value: 'job_code',
              child: Text('By role (job code)'),
            ),
            DropdownMenuItem<String?>(
              value: 'vendor_pay_rate',
              child: Text('From the vendor\'s pay rate'),
            ),
            DropdownMenuItem<String?>(
              value: 'manual_mapping',
              child: Text('Manual mapping'),
            ),
          ],
          onChanged: (value) => setState(() {
            _authorityBasis = value;
            _syncJsonFromFriendlyFields();
          }),
        ),
        const SizedBox(height: 10),
        _CheckRow(
          rowKey: const Key('admin_vendor_applicability_requires_job_code'),
          value: _requiresJobCode,
          title: 'Only count shifts that have a role',
          onChanged: (value) => setState(() {
            _requiresJobCode = value;
            _syncJsonFromFriendlyFields();
          }),
        ),
      ],
    );
  }

  Widget _buildCoversFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel(label: 'Guest count'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String?>(
          key: const Key('admin_vendor_applicability_cover_filter'),
          initialValue: _coverFilter,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          hint: const Text('Not set'),
          items: const <DropdownMenuItem<String?>>[
            DropdownMenuItem<String?>(value: null, child: Text('Not set')),
            DropdownMenuItem<String?>(
              value: 'dine_in_only',
              child: Text('Dine-in guests only'),
            ),
            DropdownMenuItem<String?>(
              value: 'all_covers',
              child: Text('All guests'),
            ),
            DropdownMenuItem<String?>(
              value: 'exclude_cancelled',
              child: Text('Leave out cancelled guests'),
            ),
          ],
          onChanged: (value) => setState(() {
            _coverFilter = value;
            _syncJsonFromFriendlyFields();
          }),
        ),
        const SizedBox(height: 12),
        const _FieldLabel(label: 'Service periods'),
        const SizedBox(height: 6),
        if (_servicePeriods.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final period in _servicePeriods)
                InputChip(
                  key: Key('admin_vendor_applicability_service_period_$period'),
                  label: Text(period),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      AdminButtonStyles.radius,
                    ),
                    side: const BorderSide(color: AppColors.borderSubtle),
                  ),
                  onDeleted: () => setState(() {
                    _servicePeriods.remove(period);
                    _syncJsonFromFriendlyFields();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('admin_vendor_applicability_service_period_add'),
                controller: _servicePeriodEntry,
                decoration: const InputDecoration(
                  hintText: 'e.g. lunch, dinner, brunch',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _addServicePeriod(),
              ),
            ),
            const SizedBox(width: 8),
            AdminActionButton(
              key: const Key(
                'admin_vendor_applicability_service_period_button',
              ),
              label: 'Add',
              onPressed: _addServicePeriod,
              compact: true,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _CheckRow(
          rowKey: const Key('admin_vendor_applicability_exclude_voids'),
          value: _excludeVoids,
          title: 'Leave out voided checks',
          onChanged: (value) => setState(() {
            _excludeVoids = value;
            _syncJsonFromFriendlyFields();
          }),
        ),
      ],
    );
  }

  void _addServicePeriod() {
    final raw = _servicePeriodEntry.text.trim().toLowerCase();
    if (raw.isEmpty) return;
    if (!RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(raw)) {
      setState(
        () => _error =
            'Service period keys must be lowercase letters, numbers, or '
            'underscores.',
      );
      return;
    }
    setState(() {
      _servicePeriods.add(raw);
      _servicePeriodEntry.clear();
      _error = null;
      _syncJsonFromFriendlyFields();
    });
  }

  Widget _buildPollingFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel(label: 'Check frequency'),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          key: const Key('admin_vendor_applicability_tier_key'),
          style: _adminSegmentedButtonStyle(),
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'standard', label: Text('Standard')),
            ButtonSegment<String>(value: 'premium', label: Text('Premium')),
            ButtonSegment<String>(value: 'custom', label: Text('Custom')),
          ],
          selected: <String>{_tierKey},
          onSelectionChanged: (selection) => setState(() {
            _tierKey = selection.first;
            _syncJsonFromFriendlyFields();
          }),
        ),
        if (_tierKey == 'custom') ...[
          const SizedBox(height: 12),
          const _FieldLabel(label: 'Minutes between checks'),
          const SizedBox(height: 6),
          TextField(
            key: const Key('admin_vendor_applicability_polling_minutes'),
            controller: _pollingMinutes,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: const InputDecoration(
              suffixText: 'minutes',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _syncJsonFromFriendlyFields(),
          ),
        ],
      ],
    );
  }

  Widget _buildAdvanced() {
    return _AdvancedFold(
      foldKey: const Key('admin_vendor_applicability_advanced_toggle'),
      title: 'Advanced settings',
      subtitle: 'Setting key and raw JSON',
      expanded: _advancedExpanded,
      onToggle: () => setState(() => _advancedExpanded = !_advancedExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Leave as "default" unless this setting has named variants.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('admin_vendor_applicability_setting_key'),
            controller: _settingKey,
            decoration: const InputDecoration(
              labelText: 'Setting key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Raw JSON reflects the details above. Editing it directly takes '
            'over from the friendly fields.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('admin_vendor_applicability_metadata'),
            controller: _metadataJson,
            minLines: 4,
            maxLines: 8,
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Metadata JSON',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _userEditedJson = true,
          ),
          if (_userEditedJson) ...[
            const SizedBox(height: 6),
            AdminActionButton(
              key: const Key('admin_vendor_applicability_reset_json'),
              label: 'Reset to the details above',
              onPressed: () => setState(() {
                _userEditedJson = false;
                _metadataJson.text = _prettyJson(_buildMetadata());
              }),
              role: AdminActionRole.quiet,
            ),
          ],
        ],
      ),
    );
  }
}

class _DialogGroup extends StatelessWidget {
  const _DialogGroup({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: AppTextStyles.uiLabel(color: AppColors.textMuted)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _CenteredDialogSection extends StatelessWidget {
  const _CenteredDialogSection({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: child,
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.body14(color: AppColors.textPrimary)),
      ],
    );
  }
}

class _ScopeSummaryField extends StatelessWidget {
  const _ScopeSummaryField({required this.label, required this.subtitle});

  final String label;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_vendor_applicability_scope_summary'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.account_tree_outlined,
            size: 18,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _RuleTextBlock(title: label, subtitle: subtitle),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.rowKey,
    required this.value,
    required this.title,
    required this.onChanged,
  });

  final Key rowKey;
  final bool value;
  final String title;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: rowKey,
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: [
          Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvancedFold extends StatelessWidget {
  const _AdvancedFold({
    required this.foldKey,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final Key foldKey;
  final String title;
  final String? subtitle;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final summary = subtitle?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1, color: AppColors.borderSubtle),
        InkWell(
          key: foldKey,
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTextStyles.body14(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (summary != null && summary.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.body12(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 0, 16),
            child: child,
          ),
      ],
    );
  }
}

class _InfoToggleButton extends StatelessWidget {
  const _InfoToggleButton({required this.selected, required this.onPressed});

  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('admin_vendor_applicability_special_info'),
      tooltip: selected ? 'Hide special handling notes' : 'Explain options',
      visualDensity: VisualDensity.compact,
      icon: Icon(
        selected ? Icons.info : Icons.info_outline,
        size: 18,
        color: AppColors.sunsetDark,
      ),
      onPressed: onPressed,
    );
  }
}

class _SpecialHandlingHelp extends StatelessWidget {
  const _SpecialHandlingHelp({required this.settingKind});

  final String settingKind;

  @override
  Widget build(BuildContext context) {
    final lines = _helpLines();
    return Container(
      key: const Key('admin_vendor_applicability_special_help'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Use these only when allow/block is not enough.',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < lines.length; i++) ...[
            _HelpLine(label: lines[i].$1, text: lines[i].$2),
            if (i != lines.length - 1) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  List<(String, String)> _helpLines() {
    switch (settingKind) {
      case VendorApplicabilitySettingKind.wage:
        return const <(String, String)>[
          ('Not set', 'Use the operator\'s normal wage setup.'),
          ('By role', 'Match vendor job codes to F&F roles.'),
          ('From vendor', 'Use the pay rate sent by the vendor.'),
          ('Manual mapping', 'Use a custom mapping managed in advanced JSON.'),
          ('Role required', 'Ignore shifts that do not have a role.'),
        ];
      case VendorApplicabilitySettingKind.covers:
        return const <(String, String)>[
          ('Not set', 'Use covers the way the vendor reports them.'),
          ('Dine-in only', 'Only count in-restaurant guests.'),
          ('All guests', 'Count every guest the vendor sends.'),
          ('Cancelled', 'Leave cancelled guests out.'),
          ('Periods', 'Leave empty for every service period.'),
        ];
      case VendorApplicabilitySettingKind.polling:
        return const <(String, String)>[
          ('Standard', 'Use the default data freshness cadence.'),
          ('Premium', 'Use the faster built-in cadence.'),
          ('Custom', 'Set the minutes between checks manually.'),
        ];
      default:
        return const <(String, String)>[];
    }
  }
}

class _HelpLine extends StatelessWidget {
  const _HelpLine({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: AppTextStyles.mono11(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.helper});

  final String title;
  final String helper;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Add a reason before continuing.');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_vendor_applicability_reason_dialog'),
      title: widget.title,
      maxWidth: 420,
      actions: [
        AdminActionButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          label: 'Continue',
          onPressed: _submit,
          role: AdminActionRole.primary,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.helper),
          const SizedBox(height: 10),
          TextField(
            key: const Key('admin_vendor_applicability_reason_note'),
            controller: _controller,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Reason',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AppTextStyles.body12(color: AppColors.negative),
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    super.key,
    required this.icon,
    required this.message,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        icon: icon,
        message: message,
        tone: isError
            ? OperatorWebBannerTone.error
            : OperatorWebBannerTone.neutral,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('admin_vendor_applicability_empty'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          'No rules yet for this setting. Add a rule to allow or block a '
          'vendor for wage, covers, or data freshness.',
          textAlign: TextAlign.center,
          style: AppTextStyles.body14(color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

bool _jsonLikeEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (!right.containsKey(key)) return false;
      if (!_jsonLikeEquals(left[key], right[key])) return false;
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_jsonLikeEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

String _prettyJson(Map<String, Object?> value) {
  return const JsonEncoder.withIndent('  ').convert(value);
}

String _formatDate(DateTime? value) {
  if (value == null) return 'now';
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}
