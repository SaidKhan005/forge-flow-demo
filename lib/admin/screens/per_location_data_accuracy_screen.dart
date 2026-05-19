// Phase 8 spine-bridge Lane .C - F&F Ops Console "Data Accuracy" tab.
//
// Tab 1 of the per-location data accuracy admin surface. Operator
// picks covers source per daypart + wage source on their own web
// console (Lane .B); this screen is the cross-operator view F&F
// support uses to inspect / override those settings + audit the
// trail.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md,
// "Tab 1: Data Accuracy (per-location overrides)" section.
//
// Symmetric with [PollingAndPricingAdminScreen] (Tab 2) - both ride
// the [DataAccuracyAdminGateway] so the demo + production wiring are
// identical. Edit affordances gate on `editingEnabled` (which mirrors
// the 11A pattern: super_admin → editable; ff_support → read-only).

import 'package:flutter/material.dart';

import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../admin_button_styles.dart';
import '../models/admin_hierarchy_settings_scope_policy.dart';
import '../services/data_accuracy_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import '../widgets/admin_responsive_layout.dart';
import '../widgets/admin_hierarchy_scope_notice.dart';
import '../widgets/admin_hierarchy_scope_prompt.dart';
import '../widgets/data_accuracy_audit_history_panel.dart';
import '../widgets/per_location_data_accuracy_table.dart';

class PerLocationDataAccuracyScreen extends StatefulWidget {
  const PerLocationDataAccuracyScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    this.editingEnabled = true,
    this.initialScope,
    this.initialHierarchyScope,
    this.scopeLocationIds,
    this.onBackToBusinessAccounts,
    this.showPageHeader = true,
    this.showScopeControls = true,
  });

  final DataAccuracyAdminGateway gateway;
  final String actorUserId;
  final AdminOperatorLocationScopeIntent? initialScope;
  final AdminHierarchyScopeIntent? initialHierarchyScope;
  final Set<String>? scopeLocationIds;
  final VoidCallback? onBackToBusinessAccounts;
  final bool showPageHeader;
  final bool showScopeControls;

  /// Mirror of the pricing screen pattern: when false, the screen
  /// hides every mutate affordance. The gateway is the second line of
  /// defence - it throws [DataAccuracyAdminForbiddenException] if a
  /// non-forge-admin caller tries to mutate.
  final bool editingEnabled;

  @override
  State<PerLocationDataAccuracyScreen> createState() =>
      _PerLocationDataAccuracyScreenState();
}

class _PerLocationDataAccuracyScreenState
    extends State<PerLocationDataAccuracyScreen> {
  static const AdminHierarchySettingsScopePolicy _scopePolicy =
      AdminHierarchySettingsScopePolicy(
        AdminHierarchySettingsSurface.dataAccuracy,
      );

  bool _loading = true;
  String? _loadError;
  String? _actionError;
  List<DataAccuracyAdminRow> _rows = const <DataAccuracyAdminRow>[];
  List<DataAccuracyAdminAuditEvent> _auditEvents =
      const <DataAccuracyAdminAuditEvent>[];
  late AdminHierarchyScopeIntent? _scope = _decoratedInitialScope;
  AdminHierarchyScopeIntent? _lastHandoffScope;
  bool _showScopePrompt = false;
  int _refreshGeneration = 0;

  AdminHierarchyScopeIntent? get _rawInitialScope =>
      widget.initialHierarchyScope ?? widget.initialScope?.toHierarchyScope();

  AdminHierarchyScopeIntent? get _decoratedInitialScope {
    final scope = _rawInitialScope;
    if (scope == null) return null;
    return _decorateScope(scope);
  }

  AdminHierarchyScopeIntent _decorateScope(AdminHierarchyScopeIntent scope) {
    return _scopePolicy.decorate(scope, editingEnabled: widget.editingEnabled);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final handoffScope = AdminRouteHandoff.maybeOf(
      context,
    )?.effectiveHierarchyScope;
    if (handoffScope != _lastHandoffScope) {
      _lastHandoffScope = handoffScope;
      if (handoffScope != null) {
        _scope = _decorateScope(handoffScope);
        _showScopePrompt = false;
      }
    }
  }

  @override
  void didUpdateWidget(covariant PerLocationDataAccuracyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialScope != oldWidget.initialScope ||
        widget.initialHierarchyScope != oldWidget.initialHierarchyScope) {
      _scope = _decoratedInitialScope;
      _showScopePrompt = false;
    } else if (widget.editingEnabled != oldWidget.editingEnabled &&
        _scope != null) {
      _scope = _decorateScope(_scope!);
    }
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait<Object>([
        widget.gateway.listDataAccuracyRows(),
        widget.gateway.listAuditHistory(),
      ]);
      if (generation != _refreshGeneration) return;
      final rows = results[0] as List<DataAccuracyAdminRow>;
      final hydratedRows = await Future.wait<DataAccuracyAdminRow>(
        rows.map((row) async {
          final servicePeriodRows = await widget.gateway
              .listDataAccuracyServicePeriodRows(
                operatorId: row.operatorRef.operatorId,
                locationId: row.operatorRef.locationId,
              );
          return row.copyWith(servicePeriodSettings: servicePeriodRows);
        }),
      );
      // Tab 1's audit panel surfaces only data-accuracy override
      // events. The shared audit log buffer also records Tab 2 events
      // (`admin.polling_tier_*`, `admin.margin_rollup.export_csv`)
      // which belong on Tab 2's own Card 5; filtering here prevents
      // cross-surface audit bleed.
      final events = results[1] as List<DataAccuracyAdminAuditEvent>;
      final filtered = events
          .where((e) => e.eventType.startsWith('admin.data_accuracy.'))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _rows = hydratedRows;
        _auditEvents = filtered;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load data accuracy rows: $error';
        _loading = false;
      });
    }
  }

  Future<void> _onEditRow(DataAccuracyAdminRow row) async {
    if (!_locationMutationEnabled) return;
    final result = await showDialog<_DataAccuracyOverrideDraft>(
      context: context,
      builder: (_) => _DataAccuracyOverrideDialog(initial: row),
    );
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.overrideDataAccuracy(
        operatorId: row.operatorRef.operatorId,
        locationId: row.operatorRef.locationId,
        coversSourceLunch: result.coversSourceLunch,
        coversSourceDinner: result.coversSourceDinner,
        coversSourceLateNight: result.coversSourceLateNight,
        wageSource: result.wageSource,
        walkInHandlingMode: result.walkInHandlingMode,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: result.reasonNote,
      );
      await _refresh();
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Override failed: $error');
    }
  }

  Future<void> _onEditServicePeriod(DataAccuracyAdminRow row) async {
    if (!_locationMutationEnabled) return;
    final draft = await showDialog<_ServicePeriodOverrideDraft>(
      context: context,
      builder: (_) => _ServicePeriodOverrideDialog(initial: row),
    );
    if (draft == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.overrideDataAccuracyServicePeriod(
        operatorId: row.operatorRef.operatorId,
        locationId: row.operatorRef.locationId,
        servicePeriodKey: draft.servicePeriodKey,
        coversSource: draft.coversSource,
        wageSource: draft.wageSource,
        effectiveAtBusinessDateIso: draft.effectiveAtBusinessDateIso,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: draft.reasonNote,
      );
      await _refresh();
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Service-period override failed: $error');
    }
  }

  Future<void> _onEditSelectedScope() async {
    if (!_scopeMutationEnabled) return;
    final rows = _visibleRows;
    if (rows.isEmpty) return;
    final scope = _scope!;
    final result = await showDialog<_DataAccuracyOverrideDraft>(
      context: context,
      builder: (_) => _DataAccuracyOverrideDialog(
        initial: rows.first,
        keyedRows: rows,
        title: 'Apply data accuracy to ${scope.displayLabel}',
      ),
    );
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      final update = await widget.gateway.overrideDataAccuracyScope(
        operatorId: scope.operatorId,
        scopeType: _mutationScopeType(scope),
        orgUnitId: scope.orgUnitId,
        locationId: scope.locationId,
        coversSourcePerServicePeriod: result.coversSourcePerServicePeriod,
        wageSource: result.wageSource,
        walkInHandlingMode: result.walkInHandlingMode,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: result.reasonNote,
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Applied covers and wage settings to '
            '${update.affectedLocationCount} location'
            '${update.affectedLocationCount == 1 ? '' : 's'}.',
          ),
        ),
      );
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Scope override failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_data_accuracy_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showPageHeader) ...[
              AdminPageHeader(
                title: 'Covers and Wage Data Accuracy',
                subtitle:
                    'Operator edits live on Operator Web; this view is for F&F support to review covers, wages, walk-ins, and audit history.',
                leading: widget.onBackToBusinessAccounts == null
                    ? null
                    : AdminBusinessAccountsBackButton(
                        onPressed: widget.onBackToBusinessAccounts,
                      ),
              ),
              const SizedBox(height: 14),
            ],
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(
                key: Key('admin_data_accuracy_readonly_banner'),
              ),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_data_accuracy_action_error'),
                message: _actionError!,
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  List<DataAccuracyAdminRow> get _visibleRows {
    final scope = _scope;
    if (scope == null) return _rows;
    return _rows
        .where(
          (row) => _includesOperatorLocation(
            scope,
            operatorId: row.operatorRef.operatorId,
            locationId: row.operatorRef.locationId,
          ),
        )
        .toList(growable: false);
  }

  List<DataAccuracyAdminAuditEvent> get _visibleAuditEvents {
    final scope = _scope;
    if (scope == null) return _auditEvents;
    return _auditEvents
        .where(
          (event) => _includesOperatorLocation(
            scope,
            operatorId: event.operatorId,
            locationId: event.locationId,
          ),
        )
        .toList(growable: false);
  }

  String? get _scopeRestrictionCopy => _scopePolicy.restrictionCopy(_scope);

  /// Mirrors PR #485's `admin_timing_scope_inheritance_notice` gate
  /// (`admin_timing_setup_screen.dart:164-182`): at a non-location
  /// scope where exactly one location lives under the scope, return
  /// that location's name so the inheritance-notice card can warn the
  /// F&F admin that the displayed value is effectively a single-
  /// location pull. Returns null when the scope is itself a location,
  /// or when the count of covered locations is not exactly one.
  String? get _singleCoveredLocationName {
    final scope = _scope;
    if (scope == null || scope.isLocationScope) return null;
    final visible = _visibleRows;
    final scopeIds = widget.scopeLocationIds;
    final coveredCount = (scopeIds != null && scopeIds.isNotEmpty)
        ? scopeIds.length
        : visible.length;
    if (coveredCount != 1) return null;
    if (visible.isEmpty) return null;
    return visible.first.operatorRef.locationName;
  }

  bool _includesOperatorLocation(
    AdminHierarchyScopeIntent? scope, {
    required String operatorId,
    required String? locationId,
  }) {
    if (scope == null) return true;
    if (scope.operatorId != operatorId) return false;
    if (locationId == null) return true;
    final locationIds = widget.scopeLocationIds;
    if (locationIds != null && locationIds.isNotEmpty) {
      return locationIds.contains(locationId);
    }
    return _scopePolicy.includesOperatorLocation(
      scope,
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  List<AdminHierarchyScopeIntent> get _availableScopes {
    final selectedOperatorId = _scope?.operatorId;
    final scopesByKey = <String, AdminHierarchyScopeIntent>{};

    void add(AdminHierarchyScopeIntent scope) {
      final decorated = _decorateScope(scope);
      scopesByKey.putIfAbsent(decorated.cacheKey, () => decorated);
    }

    final selected = _scope;
    if (selected != null) {
      add(selected);
    }
    for (final row in _rows) {
      final ref = row.operatorRef;
      if (selectedOperatorId != null && ref.operatorId != selectedOperatorId) {
        continue;
      }
      add(
        AdminHierarchyScopeIntent.business(
          operatorId: ref.operatorId,
          operatorName: ref.businessName,
        ),
      );
      add(
        AdminHierarchyScopeIntent.location(
          operatorId: ref.operatorId,
          locationId: ref.locationId,
          operatorName: ref.businessName,
          locationName: ref.locationName,
        ),
      );
    }
    return scopesByKey.values.toList(growable: false);
  }

  void _selectScope(AdminHierarchyScopeIntent scope) {
    setState(() {
      _scope = _decorateScope(scope);
      _showScopePrompt = false;
    });
  }

  void _clearScope() {
    setState(() {
      _scope = null;
      _showScopePrompt = false;
    });
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_data_accuracy_loading'),
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
        key: const Key('admin_data_accuracy_load_error'),
        message: _loadError!,
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showScopeControls && _showScopePrompt)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AdminHierarchyScopePrompt(
                surfaceName: 'Covers and Wage Data Accuracy',
                selectedScope: _scope,
                scopes: _availableScopes,
                onScopeSelected: _selectScope,
                onCancel: () => setState(() => _showScopePrompt = false),
              ),
            ),
          if (widget.showScopeControls && _scope != null)
            AdminHierarchyScopeBanner(
              scope: _scope!,
              surfaceName: 'covers and wage data accuracy',
              onChangeScope: () =>
                  setState(() => _showScopePrompt = !_showScopePrompt),
              onClear: _clearScope,
            ),
          if (widget.showScopeControls && _scopeRestrictionCopy != null)
            AdminHierarchyScopeNotice(message: _scopeRestrictionCopy!),
          if (_singleCoveredLocationName != null)
            // Mirrors the inheritance notice landed in PR #485 for the
            // Timing tile (`admin_timing_scope_inheritance_notice`).
            // Fires at business/org_unit scope when the scope covers a
            // single location, so the F&F admin knows the displayed
            // covers and wage data is effectively a single-location pull
            // even though the selected scope is "broader" (HP #11 —
            // hierarchy honesty). See B1.a in
            // docs/archive/_execution/lane_b_features/03_execution_slices.md.
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                key: const Key('admin_data_accuracy_scope_inheritance_notice'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'This scope only covers $_singleCoveredLocationName. Adjusting data accuracy here is equivalent to a per-location change. There are no other locations under this scope to inherit from.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
            ),
          if (_scopeMutationEnabled) ...[
            const SizedBox(height: 16),
            _ScopedDataAccuracyActionCard(
              scope: _scope!,
              locationCount: _visibleRows.length,
              onPressed: _onEditSelectedScope,
            ),
          ],
          const SizedBox(height: 16),
          PerLocationDataAccuracyTable(
            rows: _visibleRows,
            editingEnabled: _locationMutationEnabled,
            onEditRow: _onEditRow,
            onEditServicePeriod: _onEditServicePeriod,
          ),
          const SizedBox(height: 16),
          DataAccuracyAuditHistoryPanel(events: _visibleAuditEvents),
        ],
      ),
    );
  }

  bool get _locationMutationEnabled {
    return _scopePolicy.allowsLocationMutation(
      _scope,
      editingEnabled: widget.editingEnabled,
    );
  }

  bool get _scopeMutationEnabled {
    final scope = _scope;
    return widget.editingEnabled &&
        scope != null &&
        !scope.isLocationScope &&
        _visibleRows.isNotEmpty;
  }

  AdminDataAccuracyMutationScopeType _mutationScopeType(
    AdminHierarchyScopeIntent scope,
  ) {
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return AdminDataAccuracyMutationScopeType.business;
      case AdminHierarchyScopeType.orgUnit:
        return AdminDataAccuracyMutationScopeType.orgUnit;
      case AdminHierarchyScopeType.location:
        return AdminDataAccuracyMutationScopeType.location;
    }
  }
}

class _ScopedDataAccuracyActionCard extends StatelessWidget {
  const _ScopedDataAccuracyActionCard({
    required this.scope,
    required this.locationCount,
    required this.onPressed,
  });

  final AdminHierarchyScopeIntent scope;
  final int locationCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      key: const Key('admin_data_accuracy_scope_action_card'),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined, color: AppColors.peacockDark),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Apply to selected ${scope.scopeType.label.toLowerCase()}',
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'This saves one scoped covers and wage override and lets the covered $locationCount location${locationCount == 1 ? '' : 's'} inherit it until a lower scope overrides it.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const Key('admin_data_accuracy_scope_override'),
            style: AdminButtonStyles.primary,
            onPressed: onPressed,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit scope'),
          ),
        ],
      ),
    );
  }
}

class _DataAccuracyOverrideDraft {
  const _DataAccuracyOverrideDraft({
    required this.coversSourceLunch,
    required this.coversSourceDinner,
    required this.coversSourceLateNight,
    required this.coversSourcePerServicePeriod,
    required this.wageSource,
    required this.walkInHandlingMode,
    required this.reasonNote,
  });

  final CoversSource? coversSourceLunch;
  final CoversSource? coversSourceDinner;
  final CoversSource? coversSourceLateNight;
  final Map<String, CoversSource>? coversSourcePerServicePeriod;
  final WageSource? wageSource;
  final DataAccuracyWalkInHandlingMode? walkInHandlingMode;
  final String reasonNote;
}

class _DataAccuracyOverrideDialog extends StatefulWidget {
  const _DataAccuracyOverrideDialog({
    required this.initial,
    this.keyedRows,
    this.title,
  });

  final DataAccuracyAdminRow initial;
  final List<DataAccuracyAdminRow>? keyedRows;
  final String? title;

  @override
  State<_DataAccuracyOverrideDialog> createState() =>
      _DataAccuracyOverrideDialogState();
}

class _DataAccuracyOverrideDialogState
    extends State<_DataAccuracyOverrideDialog> {
  late final bool _usesKeyedCovers = widget.keyedRows != null;
  late final List<String> _servicePeriodKeys = _usesKeyedCovers
      ? _servicePeriodKeysForRows(widget.keyedRows!)
      : const <String>[];
  late Map<String, CoversSource> _initialCoversSourcePerServicePeriod;
  late Map<String, CoversSource> _coversSourcePerServicePeriod;
  late CoversSource _lunch;
  late CoversSource _dinner;
  late CoversSource _lateNight;
  late WageSource _wage;
  late DataAccuracyWalkInHandlingMode _walkInMode;
  final TextEditingController _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialCoversSourcePerServicePeriod = <String, CoversSource>{
      for (final key in _servicePeriodKeys)
        key: _initialCoversSourceForKey(key),
    };
    _coversSourcePerServicePeriod = Map<String, CoversSource>.of(
      _initialCoversSourcePerServicePeriod,
    );
    _lunch = widget.initial.settings.coversSourceFor('lunch');
    _dinner = widget.initial.settings.coversSourceFor('dinner');
    _lateNight = widget.initial.settings.coversSourceFor('late_night');
    _wage = widget.initial.settings.wageSource;
    _walkInMode = widget.initial.settings.walkInHandlingMode;
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  CoversSource _initialCoversSourceForKey(String key) {
    for (final row in widget.keyedRows ?? const <DataAccuracyAdminRow>[]) {
      final explicit = row.settings.coversSourcePerServicePeriod[key];
      if (explicit != null) return explicit;
    }
    return widget.initial.settings.coversSourceFor(key);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_data_accuracy_override_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        widget.title ??
            'Override data accuracy: ${widget.initial.operatorRef.businessName} '
                '/ ${widget.initial.operatorRef.locationName}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_usesKeyedCovers)
                for (final key in _servicePeriodKeys)
                  _CoversSourceField(
                    label: 'Covers source - ${_servicePeriodKeyLabel(key)}',
                    fieldKey: Key('admin_data_accuracy_covers_source_$key'),
                    value: _coversSourcePerServicePeriod[key]!,
                    onChanged: (v) => setState(
                      () => _coversSourcePerServicePeriod =
                          <String, CoversSource>{
                            ..._coversSourcePerServicePeriod,
                            key: v,
                          },
                    ),
                  )
              else ...[
                _CoversSourceField(
                  label: 'Covers source - lunch',
                  fieldKey: const Key('admin_data_accuracy_lunch'),
                  value: _lunch,
                  onChanged: (v) => setState(() => _lunch = v),
                ),
                _CoversSourceField(
                  label: 'Covers source - dinner',
                  fieldKey: const Key('admin_data_accuracy_dinner'),
                  value: _dinner,
                  onChanged: (v) => setState(() => _dinner = v),
                ),
                _CoversSourceField(
                  label: 'Covers source - late night',
                  fieldKey: const Key('admin_data_accuracy_late_night'),
                  value: _lateNight,
                  onChanged: (v) => setState(() => _lateNight = v),
                ),
              ],
              const SizedBox(height: 8),
              _WageSourceField(
                value: _wage,
                onChanged: (v) => setState(() => _wage = v),
              ),
              const SizedBox(height: 8),
              _WalkInHandlingField(
                value: _walkInMode,
                onChanged: (v) => setState(() => _walkInMode = v),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_data_accuracy_reason_note'),
                controller: _reason,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason for override',
                  hintText: 'Brief explanation for the audit log',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_data_accuracy_override_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_data_accuracy_override_submit'),
          style: AdminButtonStyles.primary,
          onPressed: () {
            final note = _reason.text.trim();
            if (note.isEmpty) return;
            final changedCovers = <String, CoversSource>{
              for (final entry in _coversSourcePerServicePeriod.entries)
                if (_initialCoversSourcePerServicePeriod[entry.key] !=
                    entry.value)
                  entry.key: entry.value,
            };
            Navigator.of(context).pop(
              _DataAccuracyOverrideDraft(
                coversSourceLunch: _usesKeyedCovers ? null : _lunch,
                coversSourceDinner: _usesKeyedCovers ? null : _dinner,
                coversSourceLateNight: _usesKeyedCovers ? null : _lateNight,
                coversSourcePerServicePeriod:
                    _usesKeyedCovers && changedCovers.isNotEmpty
                    ? Map<String, CoversSource>.unmodifiable(changedCovers)
                    : null,
                wageSource: _wage,
                walkInHandlingMode: _walkInMode,
                reasonNote: note,
              ),
            );
          },
          child: const Text('Apply override'),
        ),
      ],
    );
  }
}

class _CoversSourceField extends StatelessWidget {
  const _CoversSourceField({
    required this.label,
    required this.fieldKey,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Key fieldKey;
  final CoversSource value;
  final ValueChanged<CoversSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 200,
            child: Text(
              label,
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: DropdownButtonFormField<CoversSource>(
              key: fieldKey,
              initialValue: value,
              items: CoversSource.values
                  .map(
                    (c) => DropdownMenuItem<CoversSource>(
                      value: c,
                      child: Text(_coversSourceLabel(c)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

List<String> _servicePeriodKeysForRows(List<DataAccuracyAdminRow> rows) {
  final seen = <String>{};
  final keys = <String>[];

  void add(String key) {
    final normalized = key.trim();
    if (normalized.isEmpty) return;
    if (!seen.add(normalized)) return;
    keys.add(normalized);
  }

  for (final row in rows) {
    for (final definition in row.configuredServicePeriods) {
      add(definition.id);
    }
    for (final key in row.settings.coversSourcePerServicePeriod.keys) {
      add(key);
    }
    for (final setting in row.servicePeriodSettings) {
      add(setting.servicePeriodKey);
    }
  }
  return keys;
}

class _WageSourceField extends StatelessWidget {
  const _WageSourceField({required this.value, required this.onChanged});

  final WageSource value;
  final ValueChanged<WageSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 200,
            child: Text(
              'Wage source',
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: DropdownButtonFormField<WageSource>(
              key: const Key('admin_data_accuracy_wage_source'),
              initialValue: value,
              items: WageSource.values
                  .map(
                    (s) => DropdownMenuItem<WageSource>(
                      value: s,
                      child: Text(_wageSourceLabel(s)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WalkInHandlingField extends StatelessWidget {
  const _WalkInHandlingField({required this.value, required this.onChanged});

  final DataAccuracyWalkInHandlingMode value;
  final ValueChanged<DataAccuracyWalkInHandlingMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 200,
            child: Text(
              'Walk-in handling',
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: DropdownButtonFormField<DataAccuracyWalkInHandlingMode>(
              key: const Key('admin_data_accuracy_walk_in_mode'),
              initialValue: value,
              items: DataAccuracyWalkInHandlingMode.values
                  .map(
                    (s) => DropdownMenuItem<DataAccuracyWalkInHandlingMode>(
                      value: s,
                      child: Text(_walkInHandlingLabel(s)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ServicePeriodOverrideDraft {
  const _ServicePeriodOverrideDraft({
    required this.servicePeriodKey,
    required this.coversSource,
    required this.wageSource,
    required this.effectiveAtBusinessDateIso,
    required this.reasonNote,
  });

  final String servicePeriodKey;
  final ServicePeriodCoversSource coversSource;
  final ServicePeriodWageSource wageSource;
  final String effectiveAtBusinessDateIso;
  final String reasonNote;
}

class _ServicePeriodOverrideDialog extends StatefulWidget {
  const _ServicePeriodOverrideDialog({required this.initial});

  final DataAccuracyAdminRow initial;

  @override
  State<_ServicePeriodOverrideDialog> createState() =>
      _ServicePeriodOverrideDialogState();
}

class _ServicePeriodOverrideDialogState
    extends State<_ServicePeriodOverrideDialog> {
  static final RegExp _keyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static final RegExp _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  final TextEditingController _keyCtl = TextEditingController();
  final TextEditingController _dateCtl = TextEditingController();
  final TextEditingController _reasonCtl = TextEditingController();
  ServicePeriodCoversSource _covers = ServicePeriodCoversSource.vendor;
  ServicePeriodWageSource _wage = ServicePeriodWageSource.vendorPerEmployee;
  String? _errorText;

  List<String> get _configuredServicePeriodKeys => widget
      .initial
      .configuredServicePeriods
      .map((period) => period.id.trim())
      .where((key) => key.isNotEmpty)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    final configured = _configuredServicePeriodKeys;
    if (configured.isNotEmpty) {
      _keyCtl.text = configured.first;
    }
  }

  @override
  void dispose() {
    _keyCtl.dispose();
    _dateCtl.dispose();
    _reasonCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final key = _keyCtl.text.trim();
    final date = _dateCtl.text.trim();
    final reason = _reasonCtl.text.trim();
    if (!_keyPattern.hasMatch(key)) {
      setState(() {
        _errorText =
            'Service period key must start with a lowercase letter and use '
            'only lowercase letters, numbers, or underscores.';
      });
      return;
    }
    if (!_datePattern.hasMatch(date)) {
      setState(() {
        _errorText = 'Effective date must be YYYY-MM-DD.';
      });
      return;
    }
    if (reason.isEmpty) {
      setState(() {
        _errorText = 'Reason note is required for the audit log.';
      });
      return;
    }
    Navigator.of(context).pop(
      _ServicePeriodOverrideDraft(
        servicePeriodKey: key,
        coversSource: _covers,
        wageSource: _wage,
        effectiveAtBusinessDateIso: date,
        reasonNote: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_data_accuracy_service_period_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Service-period override: ${widget.initial.operatorRef.businessName} '
        '/ ${widget.initial.operatorRef.locationName}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_configuredServicePeriodKeys.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  key: const Key('admin_data_accuracy_service_period_picker'),
                  initialValue:
                      _configuredServicePeriodKeys.contains(_keyCtl.text)
                      ? _keyCtl.text
                      : _configuredServicePeriodKeys.first,
                  decoration: const InputDecoration(
                    labelText: 'Configured service period',
                    helperText:
                        'Pick from this location\'s business timing setup.',
                    border: OutlineInputBorder(),
                  ),
                  items: _configuredServicePeriodKeys
                      .map(
                        (key) => DropdownMenuItem<String>(
                          value: key,
                          child: Text(_servicePeriodKeyLabel(key)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _keyCtl.text = value);
                  },
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                key: const Key('admin_data_accuracy_service_period_key'),
                controller: _keyCtl,
                decoration: const InputDecoration(
                  labelText: 'Service period key',
                  helperText:
                      'Use the configured picker above when available. '
                      'Custom keys are for migration/support repair.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key(
                  'admin_data_accuracy_service_period_effective_date',
                ),
                controller: _dateCtl,
                decoration: const InputDecoration(
                  labelText: 'Effective from (business date)',
                  helperText: 'YYYY-MM-DD.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ServicePeriodCoversSource>(
                key: const Key(
                  'admin_data_accuracy_service_period_covers_source',
                ),
                initialValue: _covers,
                decoration: const InputDecoration(
                  labelText: 'Covers source',
                  border: OutlineInputBorder(),
                ),
                items: ServicePeriodCoversSource.values
                    .map(
                      (s) => DropdownMenuItem<ServicePeriodCoversSource>(
                        value: s,
                        child: Text(_servicePeriodCoversLabel(s)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) setState(() => _covers = value);
                },
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ServicePeriodWageSource>(
                key: const Key(
                  'admin_data_accuracy_service_period_wage_source',
                ),
                initialValue: _wage,
                decoration: const InputDecoration(
                  labelText: 'Wage source',
                  border: OutlineInputBorder(),
                ),
                items: ServicePeriodWageSource.values
                    .map(
                      (s) => DropdownMenuItem<ServicePeriodWageSource>(
                        value: s,
                        child: Text(_servicePeriodWageLabel(s)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) setState(() => _wage = value);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key(
                  'admin_data_accuracy_service_period_reason_note',
                ),
                controller: _reasonCtl,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason for override',
                  hintText: 'Brief explanation for the audit log',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorText!,
                  key: const Key(
                    'admin_data_accuracy_service_period_dialog_error',
                  ),
                  style: AppTextStyles.body12(color: AppColors.warning),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_data_accuracy_service_period_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_data_accuracy_service_period_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _submit,
          child: const Text('Apply override'),
        ),
      ],
    );
  }
}

String _servicePeriodCoversLabel(ServicePeriodCoversSource source) {
  switch (source) {
    case ServicePeriodCoversSource.vendor:
      return 'Vendor (POS) feed';
    case ServicePeriodCoversSource.forecast:
      return 'Forecast substitution';
    case ServicePeriodCoversSource.manual:
      return 'Manual entry';
    case ServicePeriodCoversSource.reservationPlusWalkin:
      return 'Reservations + walk-ins';
  }
}

String _servicePeriodWageLabel(ServicePeriodWageSource source) {
  switch (source) {
    case ServicePeriodWageSource.vendorPerEmployee:
      return 'Vendor per employee';
    case ServicePeriodWageSource.vendorPerPosition:
      return 'Vendor per position';
    case ServicePeriodWageSource.targetSubstitution:
      return 'Target substitution';
    case ServicePeriodWageSource.manualMix:
      return 'Manual mix';
  }
}

String _servicePeriodKeyLabel(String key) {
  return key
      .split('_')
      .where((part) => part.isNotEmpty)
      .map(
        (part) => part.length == 1
            ? part.toUpperCase()
            : '${part[0].toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

String _coversSourceLabel(CoversSource source) {
  switch (source) {
    case CoversSource.vendor:
      return 'Vendor feed';
    case CoversSource.forecast:
      return 'Forecast';
    case CoversSource.manual:
      return 'Manual entry';
  }
}

String _wageSourceLabel(WageSource source) {
  switch (source) {
    case WageSource.vendor:
      return 'Vendor wage data';
    case WageSource.manualMix:
      return 'Manual mix';
  }
}

String _walkInHandlingLabel(DataAccuracyWalkInHandlingMode mode) {
  switch (mode) {
    case DataAccuracyWalkInHandlingMode.reservationsOnly:
      return 'Reservations only';
    case DataAccuracyWalkInHandlingMode.walkInsAddedToReservations:
      return 'Add walk-ins';
    case DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately:
      return 'Track separately';
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
              'Operator edits live on Operator Web; this view is for F&F support.',
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
