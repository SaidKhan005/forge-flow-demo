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
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/vendor_applicability_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
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

const double _kVendorApplicabilityMaxWidth = 960;
const double _kVendorApplicabilityCenterBreakpoint = 1280;

class VendorApplicabilityAdminScreen extends StatefulWidget {
  const VendorApplicabilityAdminScreen({
    super.key,
    required this.gateway,
    this.operatorLocationGateway,
    this.editingEnabled = true,
    this.initialSettingKind = VendorApplicabilitySettingKind.wage,
  });

  final VendorApplicabilityAdminGateway gateway;

  /// Optional operator + location source for the "Applies to" picker. When
  /// null the dialog can still publish all-operators (global) rules; the
  /// per-operator and per-location choices show a friendly "not available"
  /// note instead of a dropdown.
  final OperatorLocationAdminGateway? operatorLocationGateway;

  final bool editingEnabled;
  final String initialSettingKind;

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

  // Operators + their locations, loaded once so the Add/Edit "Applies to"
  // picker can resolve business names and location names without a
  // per-dialog round-trip. Stays empty (and the picker stays
  // global-only) when no gateway is wired.
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
      // The "Applies to" picker degrades to all-operators only; surfacing
      // a hard error here would block the (working) global path.
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

  List<VendorApplicabilityAdminRow> get _currentRows =>
      _rows.where((row) => row.effectiveUntil == null).toList(growable: false);

  List<VendorApplicabilityAdminRow> get _historyRows =>
      _rows.where((row) => row.effectiveUntil != null).toList(growable: false);

  String _newIdempotencyKey(String action) {
    _idempotencyCounter += 1;
    return 'admin-vendor-applicability-$action-'
        '${DateTime.now().microsecondsSinceEpoch}-$_idempotencyCounter';
  }

  Future<void> _openAddDialog() async {
    final draft = await showDialog<_VendorApplicabilityDraft>(
      context: context,
      builder: (_) => _VendorApplicabilityEditDialog(
        settingKind: _selectedKind,
        operators: _operators,
      ),
    );
    if (draft == null) return;
    await _upsertDraft(draft);
  }

  Future<void> _openEditDialog(VendorApplicabilityAdminRow row) async {
    final draft = await showDialog<_VendorApplicabilityDraft>(
      context: context,
      builder: (_) => _VendorApplicabilityEditDialog(
        settingKind: row.settingKind,
        operators: _operators,
        initial: row,
      ),
    );
    if (draft == null) return;
    await _upsertDraft(draft);
  }

  Future<void> _endRow(VendorApplicabilityAdminRow row) async {
    if (!widget.editingEnabled || _saving || row.effectiveUntil != null) return;
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
          final visiblePaneWidth =
              constraints.maxWidth >= _kVendorApplicabilityCenterBreakpoint
              ? constraints.maxWidth
              : constraints.maxWidth
                    .clamp(0.0, _kVendorApplicabilityMaxWidth)
                    .toDouble();
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
                        const OperatorWebScreenHeader(
                          icon: Icons.rule_outlined,
                          title: 'Vendor Applicability',
                          collapseBelowWidth: 0,
                          subtitle:
                              'Choose which vendors are allowed to power wage, '
                              'covers, and data freshness settings.',
                        ),
                        const SizedBox(height: 14),
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
                          allowedCount: allowedCount,
                          blockedCount: blockedCount,
                          saving: _saving,
                          editingEnabled: widget.editingEnabled,
                          onAdd: _openAddDialog,
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
                vendorLabel: _vendorLabel(row.vendorSlug),
                editingEnabled: widget.editingEnabled,
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

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.guide,
    required this.allowedCount,
    required this.blockedCount,
    required this.saving,
    required this.editingEnabled,
    required this.onAdd,
    required this.onRefresh,
  });

  final String guide;
  final int allowedCount;
  final int blockedCount;
  final bool saving;
  final bool editingEnabled;
  final VoidCallback onAdd;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: const Key('admin_vendor_applicability_toolbar'),
      builder: (context, constraints) {
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdminIconAction(
              key: const Key('admin_vendor_applicability_refresh'),
              icon: Icons.refresh_outlined,
              tooltip: 'Refresh',
              onPressed: saving ? null : onRefresh,
            ),
            const SizedBox(width: 8),
            AdminActionButton(
              key: const Key('admin_vendor_applicability_add'),
              label: saving ? 'Saving...' : 'Add rule',
              onPressed: editingEnabled && !saving ? onAdd : null,
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
              '$allowedCount allowed, $blockedCount blocked',
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
    required this.vendorLabel,
    required this.editingEnabled,
    required this.saving,
    required this.onEdit,
    required this.onEnd,
  });

  final VendorApplicabilityAdminRow row;
  final String appliesTo;
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 4,
            child: _RuleTextBlock(
              title: vendorLabel,
              subtitle: vendorCategoryLabel(row.vendorSlug),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(width: 88, child: _EnabledPill(enabled: row.enabled)),
          const SizedBox(width: 16),
          Expanded(
            flex: 4,
            child: _RuleTextBlock(title: appliesTo, subtitle: 'Scope'),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: _RuleTextBlock(
              title: _formatDate(row.effectiveFrom),
              subtitle: 'Effective since',
            ),
          ),
          if (editingEnabled) ...[
            const SizedBox(width: 8),
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
          ] else
            const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _RuleTextBlock extends StatelessWidget {
  const _RuleTextBlock({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
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

// ── Applies-to choice ────────────────────────────────────────────────

enum _AppliesToScope { allOperators, oneOperator, oneLocation }

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
    required this.operators,
    this.initial,
  });

  final String settingKind;
  final List<OperatorAdminBundle> operators;
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

  // Applies to.
  late _AppliesToScope _scope;
  String? _operatorId;
  String? _locationId;

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
  bool _scopeExpanded = false;
  bool _detailsExpanded = false;
  bool _advancedExpanded = false;
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

    // Applies-to seed.
    if (initial?.locationId != null) {
      _scope = _AppliesToScope.oneLocation;
      _operatorId = initial!.operatorId;
      _locationId = initial.locationId;
    } else if (initial?.operatorId != null) {
      _scope = _AppliesToScope.oneOperator;
      _operatorId = initial!.operatorId;
    } else {
      _scope = _AppliesToScope.allOperators;
    }

    final metadata = initial?.metadata ?? const <String, Object?>{};
    _scopeExpanded = false;
    _detailsExpanded = false;
    _seedFriendlyFieldsFromMetadata(metadata);
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

  OperatorAdminBundle? get _selectedOperatorBundle {
    final id = _operatorId;
    if (id == null) return null;
    for (final b in widget.operators) {
      if (b.operator.operatorId == id) return b;
    }
    return null;
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
    // Applies-to resolution + location-requires-operator (UI mirror of the
    // DB CHECK + proxy validation).
    String? operatorId;
    String? locationId;
    switch (_scope) {
      case _AppliesToScope.allOperators:
        break;
      case _AppliesToScope.oneOperator:
        if (_operatorId == null) {
          setState(() => _error = 'Choose an operator.');
          return;
        }
        operatorId = _operatorId;
        break;
      case _AppliesToScope.oneLocation:
        if (_operatorId == null) {
          setState(() => _error = 'Choose an operator.');
          return;
        }
        if (_locationId == null) {
          setState(() => _error = 'Choose a location (or pick all operators).');
          return;
        }
        operatorId = _operatorId;
        locationId = _locationId;
        break;
    }
    if (reason.isEmpty) {
      setState(() => _error = 'Tell us why you are making this change.');
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
    final formMaxHeight = (MediaQuery.sizeOf(context).height - 440)
        .clamp(300.0, 520.0)
        .toDouble();
    return OperatorWebDialog(
      key: const Key('admin_vendor_applicability_edit_dialog'),
      title: _isEditing ? 'Edit rule' : 'Add rule',
      maxWidth: 920,
      actions: [
        AdminActionButton(
          key: const Key('admin_vendor_applicability_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_vendor_applicability_submit'),
          label: _isEditing ? 'Save rule' : 'Add rule',
          onPressed: _submit,
          role: AdminActionRole.primary,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: formMaxHeight),
            child: SingleChildScrollView(
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
                  const SizedBox(height: 10),
                  _buildRuleFolds(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _FieldLabel(
            label: 'Why are you making this change?',
            example: 'Saved with the audit log. Example: Ticket VA-200.',
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('admin_vendor_applicability_reason'),
            controller: _reason,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleBasics() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 680) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildVendorPicker(),
              const SizedBox(height: 18),
              _buildAllowedToggle(),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildVendorPicker()),
            const SizedBox(width: 22),
            Expanded(child: _buildAllowedToggle()),
          ],
        );
      },
    );
  }

  Widget _buildRuleFolds() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final appliesTo = _buildAppliesTo();
        final optionalFields = _buildOptionalFields();
        final advanced = _buildAdvanced();
        if (constraints.maxWidth >= 760 &&
            !_scopeExpanded &&
            !_detailsExpanded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: appliesTo),
                  const SizedBox(width: 10),
                  Expanded(child: optionalFields),
                ],
              ),
              const SizedBox(height: 10),
              advanced,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            appliesTo,
            const SizedBox(height: 10),
            optionalFields,
            const SizedBox(height: 10),
            advanced,
          ],
        );
      },
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

  Widget _buildAppliesTo() {
    final operatorsAvailable = widget.operators.isNotEmpty;
    final bundle = _selectedOperatorBundle;
    final locations = bundle?.locations ?? const <LocationAdminRecord>[];
    return _AdvancedFold(
      foldKey: const Key('admin_vendor_applicability_scope_toggle'),
      title: 'Applies to: ${_draftScopeLabel()}',
      expanded: _scopeExpanded,
      onToggle: () => setState(() => _scopeExpanded = !_scopeExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'The most specific rule wins.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          _RadioTile<_AppliesToScope>(
            tileKey: const Key('admin_vendor_applicability_scope_all'),
            value: _AppliesToScope.allOperators,
            groupValue: _scope,
            title: 'All operators',
            onChanged: (value) => setState(() {
              _scope = value;
              _operatorId = null;
              _locationId = null;
            }),
          ),
          _RadioTile<_AppliesToScope>(
            tileKey: const Key('admin_vendor_applicability_scope_operator'),
            value: _AppliesToScope.oneOperator,
            groupValue: _scope,
            title: 'One operator',
            enabled: operatorsAvailable,
            onChanged: (value) => setState(() {
              _scope = value;
              _locationId = null;
            }),
          ),
          _RadioTile<_AppliesToScope>(
            tileKey: const Key('admin_vendor_applicability_scope_location'),
            value: _AppliesToScope.oneLocation,
            groupValue: _scope,
            title: 'One location',
            enabled: operatorsAvailable,
            onChanged: (value) => setState(() => _scope = value),
          ),
          if (!operatorsAvailable)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Operator list is not available here, so only an all-operators '
                'rule can be set.',
                key: const Key('admin_vendor_applicability_no_operators_note'),
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ),
          if (operatorsAvailable &&
              (_scope == _AppliesToScope.oneOperator ||
                  _scope == _AppliesToScope.oneLocation)) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: const Key('admin_vendor_applicability_operator_dropdown'),
              initialValue: _operatorId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Operator',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Choose an operator'),
              items: <DropdownMenuItem<String>>[
                for (final b in widget.operators)
                  DropdownMenuItem<String>(
                    key: Key(
                      'admin_vendor_applicability_operator_item_'
                      '${b.operator.operatorId}',
                    ),
                    value: b.operator.operatorId,
                    child: Text(b.operator.businessName),
                  ),
              ],
              onChanged: (value) => setState(() {
                _operatorId = value;
                _locationId = null;
              }),
            ),
          ],
          if (operatorsAvailable && _scope == _AppliesToScope.oneLocation) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: const Key('admin_vendor_applicability_location_dropdown'),
              initialValue: _locationId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Location',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Choose a location'),
              items: <DropdownMenuItem<String>>[
                for (final l in locations)
                  DropdownMenuItem<String>(
                    key: Key(
                      'admin_vendor_applicability_location_item_${l.locationId}',
                    ),
                    value: l.locationId,
                    child: Text(l.name),
                  ),
              ],
              onChanged: bundle == null
                  ? null
                  : (value) => setState(() => _locationId = value),
            ),
          ],
        ],
      ),
    );
  }

  String _draftScopeLabel() {
    switch (_scope) {
      case _AppliesToScope.allOperators:
        return 'All operators';
      case _AppliesToScope.oneOperator:
        return _selectedOperatorBundle?.operator.businessName ?? 'One operator';
      case _AppliesToScope.oneLocation:
        final bundle = _selectedOperatorBundle;
        final locationId = _locationId;
        if (bundle == null || locationId == null) return 'One location';
        for (final location in bundle.locations) {
          if (location.locationId == locationId) {
            return '${bundle.operator.businessName}: ${location.name}';
          }
        }
        return '${bundle.operator.businessName}: $locationId';
    }
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
      title: 'Special handling: ${_specialHandlingSummary()}',
      expanded: _detailsExpanded,
      onToggle: () => setState(() => _detailsExpanded = !_detailsExpanded),
      child: Column(
        key: const Key('admin_vendor_applicability_optional_block'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Leave these blank unless this vendor needs special handling.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
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
    return chips.join(', ');
  }

  Widget _buildWageFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldLabel(
          label: 'How should we work out each person\'s pay rate?',
          example: 'Leave blank to use the operator\'s usual wage setup.',
        ),
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
        _FieldLabel(
          label: 'Which guests count?',
          example: 'Leave blank to count covers the way the vendor reports.',
        ),
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
        _FieldLabel(
          label: 'Which parts of the day?',
          example:
              'Leave empty to apply to every service period. Add the period '
              'keys this rule should cover.',
        ),
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
        _FieldLabel(
          label: 'Check frequency',
          example:
              'Standard and Premium use the built-in cadences. Choose Custom '
              'to set your own.',
        ),
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
          _FieldLabel(
            label: 'Check every __ minutes',
            example: 'Between 1 minute and 1440 minutes (24 hours).',
          ),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: AppTextStyles.mono12(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label, this.example});

  final String label;
  final String? example;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.body14(color: AppColors.textPrimary)),
        if (example != null) ...[
          const SizedBox(height: 2),
          Text(
            example!,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ],
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

class _RadioTile<T> extends StatelessWidget {
  const _RadioTile({
    required this.tileKey,
    required this.value,
    required this.groupValue,
    required this.title,
    required this.onChanged,
    this.enabled = true,
  });

  final Key tileKey;
  final T value;
  final T groupValue;
  final String title;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return InkWell(
      key: tileKey,
      onTap: enabled ? () => onChanged(value) : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: !enabled
                  ? AppColors.textMuted.withValues(alpha: 0.5)
                  : selected
                  ? AppColors.sunsetDark
                  : AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: AppTextStyles.body14(
                  color: enabled ? AppColors.textPrimary : AppColors.textMuted,
                ),
              ),
            ),
          ],
        ),
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
  });

  final Key foldKey;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: foldKey,
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: child,
            ),
        ],
      ),
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
      setState(() => _error = 'Tell us why you are making this change.');
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
              labelText: 'Why are you making this change?',
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
