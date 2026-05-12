// Phase 8 spine-bridge Lane .C - F&F Ops Console "Polling & Pricing" tab.
//
// Tab 2 of the per-location data accuracy admin surface. F&F-internal:
// operators NEVER see this surface. Carries the F&F-controlled tier
// model (REVERSED 2026-05-05) where F&F absorbs vendor API costs and
// packages them into operator-facing tier prices.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Tab 2: Polling & Pricing (F&F-controlled, well-labeled)" section,
// including the verbatim plain-English explainer card text.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/admin_hierarchy_settings_scope_policy.dart';
import '../services/data_accuracy_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import '../widgets/admin_responsive_layout.dart';
import '../widgets/admin_hierarchy_scope_notice.dart';
import '../widgets/admin_hierarchy_scope_prompt.dart';
import '../widgets/data_accuracy_audit_history_panel.dart';
import '../widgets/margin_rollup_card.dart';
import '../widgets/per_location_tier_assignment_table.dart';
import '../widgets/per_vendor_cadence_editor.dart';
import '../widgets/plain_english_explainer_card.dart';
import '../widgets/tier_change_requests_card.dart';
import '../widgets/tier_definition_edit_dialog.dart';
import '../widgets/tier_definitions_card.dart';

class PollingAndPricingAdminScreen extends StatefulWidget {
  const PollingAndPricingAdminScreen({
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
  final bool editingEnabled;
  final AdminOperatorLocationScopeIntent? initialScope;
  final AdminHierarchyScopeIntent? initialHierarchyScope;
  final Set<String>? scopeLocationIds;
  final VoidCallback? onBackToBusinessAccounts;
  final bool showPageHeader;
  final bool showScopeControls;

  @override
  State<PollingAndPricingAdminScreen> createState() =>
      _PollingAndPricingAdminScreenState();
}

class _PollingAndPricingAdminScreenState
    extends State<PollingAndPricingAdminScreen> {
  static const AdminHierarchySettingsScopePolicy _scopePolicy =
      AdminHierarchySettingsScopePolicy(
        AdminHierarchySettingsSurface.pollingPricing,
      );

  bool _loading = true;
  String? _loadError;
  String? _actionError;
  List<TierDefinition> _definitions = const <TierDefinition>[];
  List<TierAssignmentAdminRow> _assignments = const <TierAssignmentAdminRow>[];
  TierMarginRollup _rollup = const TierMarginRollup(
    totalMonthlyPriceCents: 0,
    totalMonthlyVendorCostCents: 0,
    perTier: <TierMarginPerTier>[],
    perVendor: <TierMarginPerVendor>[],
  );
  List<TierChangeRequest> _changeRequests = const <TierChangeRequest>[];
  List<DataAccuracyAdminAuditEvent> _tierAuditEvents =
      const <DataAccuracyAdminAuditEvent>[];

  PollingTierKey? _tierFilter;
  String? _marginBandFilter;
  String? _locationCountFilter;
  String _operatorNameFilter = '';
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
  void didUpdateWidget(covariant PollingAndPricingAdminScreen oldWidget) {
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
        widget.gateway.listTierDefinitions(),
        widget.gateway.listTierAssignments(),
        widget.gateway.summarizeMargin(),
        widget.gateway.listTierChangeRequests(),
        widget.gateway.listAuditHistory(),
      ]);
      if (generation != _refreshGeneration) return;
      final defs = results[0] as List<TierDefinition>;
      final assignments = results[1] as List<TierAssignmentAdminRow>;
      final rollup = results[2] as TierMarginRollup;
      final changes = results[3] as List<TierChangeRequest>;
      // Tab 2 Card 5 (audit history) surfaces only the polling-tier
      // events: tier definition edits, tier assignments, change
      // request resolutions, and CSV exports. Data-accuracy override
      // events stay on Tab 1.
      final allEvents = results[4] as List<DataAccuracyAdminAuditEvent>;
      final tierEvents = allEvents
          .where(
            (e) =>
                e.eventType.startsWith('admin.polling_') ||
                e.eventType.startsWith('admin.margin_rollup.'),
          )
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _definitions = defs;
        _assignments = assignments;
        _rollup = rollup;
        _changeRequests = changes;
        _tierAuditEvents = tierEvents;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load polling & pricing data: $error';
        _loading = false;
      });
    }
  }

  List<TierAssignmentAdminRow> get _filteredAssignments {
    final perOperatorLocationCount = <String, int>{};
    for (final row in _assignments) {
      perOperatorLocationCount.update(
        row.operatorRef.operatorId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return _assignments
        .where((row) {
          // The tier filter applies only to rows with an assignment.
          // Unassigned rows (assignment == null) are filtered out when
          // a specific tier is selected; they pass when "All tiers" is
          // selected.
          if (_tierFilter != null) {
            if (row.assignment == null) return false;
            if (row.assignment!.tierKey != _tierFilter) return false;
          }
          final scope = _scope;
          if (scope != null &&
              !_includesOperatorLocation(
                scope,
                operatorId: row.operatorRef.operatorId,
                locationId: row.operatorRef.locationId,
              )) {
            return false;
          }
          final band = _marginBandFilter;
          if (band != null) {
            // Margin band only meaningful for assigned rows; unassigned
            // rows are filtered out when a band is selected.
            if (row.assignment == null) return false;
            final margin = row.assignment!.netMarginCents ?? 0;
            if (band == 'positive' && margin <= 0) return false;
            if (band == 'break_even' && margin != 0) return false;
            if (band == 'negative' && margin >= 0) return false;
          }
          final loc = _locationCountFilter;
          if (loc != null) {
            final count =
                perOperatorLocationCount[row.operatorRef.operatorId] ?? 0;
            if (loc == 'single' && count != 1) return false;
            if (loc == 'multi' && count < 2) return false;
          }
          final query = _operatorNameFilter.trim().toLowerCase();
          if (query.isNotEmpty &&
              !row.operatorRef.businessName.toLowerCase().contains(query) &&
              !row.operatorRef.locationName.toLowerCase().contains(query)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  List<TierChangeRequest> get _visibleChangeRequests {
    final scope = _scope;
    if (scope == null) return _changeRequests;
    return _changeRequests
        .where(
          (request) => _includesOperatorLocation(
            scope,
            operatorId: request.operatorRef.operatorId,
            locationId: request.operatorRef.locationId,
          ),
        )
        .toList(growable: false);
  }

  List<DataAccuracyAdminAuditEvent> get _visibleTierAuditEvents {
    final scope = _scope;
    if (scope == null) return _tierAuditEvents;
    return _tierAuditEvents
        .where(
          (event) => _includesOperatorLocation(
            scope,
            operatorId: event.operatorId,
            locationId: event.locationId,
          ),
        )
        .toList(growable: false);
  }

  TierMarginRollup get _visibleRollup {
    final hasLocalFilter =
        _scope != null ||
        _tierFilter != null ||
        _marginBandFilter != null ||
        _locationCountFilter != null ||
        _operatorNameFilter.trim().isNotEmpty;
    if (!hasLocalFilter) return _rollup;
    return _buildRollupFromRows(_filteredAssignments);
  }

  bool get _locationMutationEnabled {
    return _scopePolicy.allowsLocationMutation(
      _scope,
      editingEnabled: widget.editingEnabled,
    );
  }

  String? get _scopeRestrictionCopy => _scopePolicy.restrictionCopy(_scope);

  bool _includesOperatorLocation(
    AdminHierarchyScopeIntent? scope, {
    required String operatorId,
    required String? locationId,
  }) {
    if (scope == null) return true;
    if (scope.operatorId != operatorId) return false;
    final locationIds = widget.scopeLocationIds;
    if (locationIds != null && locationIds.isNotEmpty) {
      return locationId != null && locationIds.contains(locationId);
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
    for (final row in _assignments) {
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

  Future<void> _onEditDefinition(TierDefinition definition) async {
    if (!_locationMutationEnabled) return;
    final result = await TierDefinitionEditDialog.show(context, definition);
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.updateTierDefinition(
        tierKey: definition.tierKey,
        descriptionMd: result.descriptionMd,
        pollingCadencePerVendorSeconds: result.pollingCadencePerVendorSeconds,
        defaultMonthlyPriceCents: result.defaultMonthlyPriceCents,
        vendorApiCostEstimateCentsMonthly:
            result.vendorApiCostEstimateCentsMonthly,
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
      setState(() => _actionError = 'Tier definition update failed: $error');
    }
  }

  Future<void> _onAssignTier(TierAssignmentAdminRow row) async {
    if (!_locationMutationEnabled) return;
    final result = await showDialog<_TierAssignmentDraft>(
      context: context,
      builder: (_) =>
          _TierAssignmentDialog(row: row, definitions: _definitions),
    );
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.assignTier(
        operatorId: row.operatorRef.operatorId,
        locationId: row.operatorRef.locationId,
        tierKey: result.tierKey,
        customCadencePerVendorSeconds: result.customCadence,
        monthlyPriceCentsOverride: result.monthlyPriceCentsOverride,
        vendorApiCostEstimateCentsMonthlyOverride:
            result.vendorApiCostEstimateCentsMonthlyOverride,
        adminNotes: result.adminNotes,
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
      setState(() => _actionError = 'Tier assignment failed: $error');
    }
  }

  Future<void> _onAssignSelectedScope() async {
    if (!_scopeMutationEnabled) return;
    final rows = _filteredAssignments;
    if (rows.isEmpty) return;
    final scope = _scope!;
    final result = await showDialog<_TierAssignmentDraft>(
      context: context,
      builder: (_) => _TierAssignmentDialog(
        row: rows.first,
        definitions: _definitions,
        title: 'Assign polling setup to ${scope.displayLabel}',
        scopeLocationCount: rows.length,
      ),
    );
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      for (final row in rows) {
        await widget.gateway.assignTier(
          operatorId: row.operatorRef.operatorId,
          locationId: row.operatorRef.locationId,
          tierKey: result.tierKey,
          customCadencePerVendorSeconds: result.customCadence,
          monthlyPriceCentsOverride: result.monthlyPriceCentsOverride,
          vendorApiCostEstimateCentsMonthlyOverride:
              result.vendorApiCostEstimateCentsMonthlyOverride,
          adminNotes: result.adminNotes,
          actorUserId: widget.actorUserId,
          actorIsForgeAdmin: widget.editingEnabled,
          reasonNote: result.reasonNote,
        );
      }
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Applied polling setup to ${rows.length} location'
            '${rows.length == 1 ? '' : 's'}.',
          ),
        ),
      );
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Scope tier assignment failed: $error');
    }
  }

  Future<void> _onResolveChangeRequest(
    TierChangeRequest request,
    TierChangeRequestStatus newStatus,
  ) async {
    if (!_locationMutationEnabled) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.resolveTierChangeRequest(
        requestId: request.requestId,
        newStatus: newStatus,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: 'forge_admin resolved tier change request',
      );
      await _refresh();
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Tier change resolution failed: $error');
    }
  }

  Future<void> _onExportCsv() async {
    if (!_locationMutationEnabled) return;
    try {
      final csv = await widget.gateway.exportMarginRollupCsv(
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
      );
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: csv));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Margin rollup CSV copied to clipboard.')),
      );
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'CSV export failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_polling_pricing_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (widget.showPageHeader) ...[
              AdminPageHeader(
                title: 'Polling Setup',
                subtitle:
                    'Set vendor polling tiers, estimate cost, and review margin for the selected scope.',
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
                key: Key('admin_polling_pricing_readonly_banner'),
              ),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_polling_pricing_action_error'),
                message: _actionError!,
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_polling_pricing_loading'),
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
        key: const Key('admin_polling_pricing_load_error'),
        message: _loadError!,
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.showScopeControls && _showScopePrompt)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AdminHierarchyScopePrompt(
                surfaceName: 'Polling Setup',
                selectedScope: _scope,
                scopes: _availableScopes,
                onScopeSelected: _selectScope,
                onCancel: () => setState(() => _showScopePrompt = false),
              ),
            ),
          if (widget.showScopeControls && _scope != null)
            AdminHierarchyScopeBanner(
              scope: _scope!,
              surfaceName: 'polling setup',
              onChangeScope: () =>
                  setState(() => _showScopePrompt = !_showScopePrompt),
              onClear: _clearScope,
            ),
          if (widget.showScopeControls && _scopeRestrictionCopy != null)
            AdminHierarchyScopeNotice(message: _scopeRestrictionCopy!),
          _buildPollingSummary(),
          if (_scopeMutationEnabled) ...[
            const SizedBox(height: 16),
            _ScopedPollingActionCard(
              scope: _scope!,
              locationCount: _filteredAssignments.length,
              onPressed: _onAssignSelectedScope,
            ),
          ],
          const SizedBox(height: 16),
          const PlainEnglishExplainerCard(),
          const SizedBox(height: 16),
          TierDefinitionsCard(
            definitions: _definitions,
            editingEnabled: _locationMutationEnabled,
            onEdit: _onEditDefinition,
          ),
          const SizedBox(height: 16),
          PerLocationTierAssignmentTable(
            rows: _filteredAssignments,
            tierDefinitions: _definitions,
            editingEnabled: _locationMutationEnabled,
            onAssign: _onAssignTier,
            tierFilter: _tierFilter,
            marginBandFilter: _marginBandFilter,
            locationCountFilter: _locationCountFilter,
            operatorNameFilter: _operatorNameFilter,
            onTierFilterChanged: (v) => setState(() => _tierFilter = v),
            onMarginBandFilterChanged: (v) =>
                setState(() => _marginBandFilter = v),
            onLocationCountFilterChanged: (v) =>
                setState(() => _locationCountFilter = v),
            onOperatorNameFilterChanged: (v) =>
                setState(() => _operatorNameFilter = v),
          ),
          const SizedBox(height: 16),
          MarginRollupCard(
            rollup: _visibleRollup,
            canExportCsv: _locationMutationEnabled,
            onExportCsv: _onExportCsv,
          ),
          const SizedBox(height: 16),
          TierChangeRequestsCard(
            requests: _visibleChangeRequests,
            editingEnabled: _locationMutationEnabled,
            onResolve: _onResolveChangeRequest,
          ),
          const SizedBox(height: 16),
          // Card 5 (Audit history) per contract - every tier
          // definition edit, tier assignment, change-request
          // resolution, and CSV export the F&F admin runs lands here
          // with prior → new diff display + actor + timestamp + reason
          // note. Filtered to polling-tier event types so Tab 1 data-
          // accuracy overrides do not leak in.
          DataAccuracyAuditHistoryPanel(
            key: const Key('admin_polling_pricing_audit_panel'),
            events: _visibleTierAuditEvents,
            title: 'Audit history',
            emptyText: 'No tier changes recorded yet.',
          ),
        ],
      ),
    );
  }

  Widget _buildPollingSummary() {
    final rows = _filteredAssignments;
    final assignedRows = rows.where((row) => row.assignment != null).length;
    final openRequests = _visibleChangeRequests
        .where(
          (request) =>
              request.status == TierChangeRequestStatus.pending ||
              request.status == TierChangeRequestStatus.negotiating,
        )
        .length;
    final margin = _visibleRollup.totalMonthlyMarginCents;
    final marginLabel = formatCents(margin);
    return AdminStatStrip(
      items: <AdminStatItem>[
        AdminStatItem(label: 'Visible locations', value: '${rows.length}'),
        AdminStatItem(label: 'Assigned tiers', value: '$assignedRows'),
        AdminStatItem(label: 'Open requests', value: '$openRequests'),
        AdminStatItem(label: 'Net margin', value: marginLabel),
        AdminStatItem(
          label: 'Audit rows',
          value: '${_visibleTierAuditEvents.length}',
        ),
      ],
    );
  }

  TierMarginRollup _buildRollupFromRows(List<TierAssignmentAdminRow> rows) {
    final perTier = <PollingTierKey, _MutableTierMargin>{};
    final perVendor = <String, int>{};
    var totalPrice = 0;
    var totalCost = 0;

    for (final row in rows) {
      final assignment = row.assignment;
      if (assignment == null) continue;
      final definition = _definitionFor(assignment.tierKey);
      final price =
          assignment.monthlyPriceCents ??
          definition?.defaultMonthlyPriceCents ??
          0;
      final cost =
          assignment.vendorApiCostEstimateCentsMonthly ??
          definition?.vendorApiCostEstimateCentsMonthly ??
          0;
      totalPrice += price;
      totalCost += cost;
      perTier
          .putIfAbsent(assignment.tierKey, () => _MutableTierMargin())
          .add(price: price, cost: cost);

      final vendors = assignment.pollingCadencePerVendorSeconds.keys.toList();
      if (vendors.isEmpty) {
        perVendor.update(
          kUnallocatedVendorId,
          (value) => value + cost,
          ifAbsent: () => cost,
        );
      } else {
        final perVendorCost = cost ~/ vendors.length;
        var remainder = cost - (perVendorCost * vendors.length);
        for (final vendor in vendors) {
          final share = perVendorCost + (remainder > 0 ? 1 : 0);
          if (remainder > 0) remainder -= 1;
          perVendor.update(
            vendor,
            (value) => value + share,
            ifAbsent: () => share,
          );
        }
      }
    }

    return TierMarginRollup(
      totalMonthlyPriceCents: totalPrice,
      totalMonthlyVendorCostCents: totalCost,
      perTier: <TierMarginPerTier>[
        for (final entry in perTier.entries)
          TierMarginPerTier(
            tierKey: entry.key,
            assignmentCount: entry.value.count,
            totalMonthlyPriceCents: entry.value.price,
            totalMonthlyVendorCostCents: entry.value.cost,
          ),
      ],
      perVendor: <TierMarginPerVendor>[
        for (final entry in perVendor.entries)
          TierMarginPerVendor(
            vendorId: entry.key,
            totalMonthlyVendorCostCents: entry.value,
          ),
      ],
    );
  }

  TierDefinition? _definitionFor(PollingTierKey tierKey) {
    for (final definition in _definitions) {
      if (definition.tierKey == tierKey) return definition;
    }
    return null;
  }

  bool get _scopeMutationEnabled {
    final scope = _scope;
    return widget.editingEnabled &&
        scope != null &&
        !scope.isLocationScope &&
        _filteredAssignments.isNotEmpty;
  }
}

class _ScopedPollingActionCard extends StatelessWidget {
  const _ScopedPollingActionCard({
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
      key: const Key('admin_polling_setup_scope_action_card'),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined, color: AppColors.peacockDark),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Assign selected ${scope.scopeType.label.toLowerCase()}',
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'This updates polling tier, price, cost basis, and notes for $locationCount visible location${locationCount == 1 ? '' : 's'}.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const Key('admin_polling_setup_scope_assign'),
            style: AdminButtonStyles.primary,
            onPressed: onPressed,
            icon: const Icon(Icons.payments_outlined),
            label: const Text('Assign scope'),
          ),
        ],
      ),
    );
  }
}

class _MutableTierMargin {
  int count = 0;
  int price = 0;
  int cost = 0;

  void add({required int price, required int cost}) {
    count += 1;
    this.price += price;
    this.cost += cost;
  }
}

class _TierAssignmentDraft {
  const _TierAssignmentDraft({
    required this.tierKey,
    required this.customCadence,
    required this.monthlyPriceCentsOverride,
    required this.vendorApiCostEstimateCentsMonthlyOverride,
    required this.adminNotes,
    required this.reasonNote,
  });

  final PollingTierKey tierKey;
  final Map<String, int>? customCadence;
  final int? monthlyPriceCentsOverride;
  final int? vendorApiCostEstimateCentsMonthlyOverride;
  final String? adminNotes;
  final String reasonNote;
}

class _TierAssignmentDialog extends StatefulWidget {
  const _TierAssignmentDialog({
    required this.row,
    required this.definitions,
    this.title,
    this.scopeLocationCount = 1,
  });

  final TierAssignmentAdminRow row;
  final List<TierDefinition> definitions;
  final String? title;
  final int scopeLocationCount;

  @override
  State<_TierAssignmentDialog> createState() => _TierAssignmentDialogState();
}

class _TierAssignmentDialogState extends State<_TierAssignmentDialog> {
  // Default tier for never-assigned rows is `standard` (the contract's
  // "Default for new operators" tier). For rows with a prior
  // assignment we pre-populate every field from it.
  late PollingTierKey _tierKey =
      widget.row.assignment?.tierKey ?? PollingTierKey.standard;
  late Map<String, int> _customCadence = Map<String, int>.from(
    widget.row.assignment?.pollingCadencePerVendorSeconds ??
        const <String, int>{},
  );
  late final TextEditingController _price = TextEditingController(
    text: widget.row.assignment?.monthlyPriceCents == null
        ? ''
        : (widget.row.assignment!.monthlyPriceCents! / 100).toStringAsFixed(2),
  );
  late final TextEditingController _cost = TextEditingController(
    text: widget.row.assignment?.vendorApiCostEstimateCentsMonthly == null
        ? ''
        : (widget.row.assignment!.vendorApiCostEstimateCentsMonthly! / 100)
              .toStringAsFixed(2),
  );
  final TextEditingController _callsPerDay = TextEditingController();
  final TextEditingController _apiCostPerCall = TextEditingController();
  late final TextEditingController _notes = TextEditingController(
    text: widget.row.adminNotes ?? '',
  );
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _price.dispose();
    _cost.dispose();
    _callsPerDay.dispose();
    _apiCostPerCall.dispose();
    _notes.dispose();
    _reason.dispose();
    super.dispose();
  }

  int? _parseCents(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final dollars = double.tryParse(trimmed);
    if (dollars == null) return null;
    return (dollars * 100).round();
  }

  double? _parsePositiveDouble(String raw) {
    final value = double.tryParse(raw.trim());
    if (value == null || value < 0) return null;
    return value;
  }

  int? get _calculatorMonthlyCostCents {
    final callsPerDay = _parsePositiveDouble(_callsPerDay.text);
    final costPerCall = _parsePositiveDouble(_apiCostPerCall.text);
    if (callsPerDay == null || costPerCall == null) return null;
    return (callsPerDay * costPerCall * 30 * 100).round();
  }

  String _formatCents(int cents) => (cents / 100).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_tier_assignment_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        widget.title ??
            'Assign tier - ${widget.row.operatorRef.businessName} '
                '/ ${widget.row.operatorRef.locationName}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DropdownButtonFormField<PollingTierKey>(
                key: const Key('admin_tier_assignment_dialog_tier'),
                initialValue: _tierKey,
                decoration: const InputDecoration(
                  labelText: 'Tier',
                  border: OutlineInputBorder(),
                ),
                items: PollingTierKey.values
                    .map(
                      (t) => DropdownMenuItem<PollingTierKey>(
                        value: t,
                        child: Text(_tierLabel(t)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (v) {
                  if (v != null) setState(() => _tierKey = v);
                },
              ),
              const SizedBox(height: 12),
              if (_tierKey == PollingTierKey.custom)
                PerVendorCadenceEditor(
                  initialCadence: _customCadence,
                  onChanged: (next) => setState(() => _customCadence = next),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_price'),
                controller: _price,
                decoration: const InputDecoration(
                  labelText: 'Price override (USD/month)',
                  hintText: 'Leave blank to use tier default',
                  border: OutlineInputBorder(),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_cost'),
                controller: _cost,
                decoration: const InputDecoration(
                  labelText: 'Cost basis override (USD/month)',
                  hintText: 'Leave blank to use tier default',
                  border: OutlineInputBorder(),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('admin_polling_cost_calculator'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.peacock.withValues(alpha: 0.06),
                  border: Border.all(
                    color: AppColors.peacock.withValues(alpha: 0.24),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Cost calculator',
                      style: AppTextStyles.uiLabel(
                        color: AppColors.peacockDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key(
                              'admin_polling_calculator_calls_per_day',
                            ),
                            controller: _callsPerDay,
                            decoration: const InputDecoration(
                              labelText: 'Calls per day per location',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: const Key(
                              'admin_polling_calculator_cost_per_call',
                            ),
                            controller: _apiCostPerCall,
                            decoration: const InputDecoration(
                              labelText: 'API cost per call (USD)',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (context) {
                        final perLocation = _calculatorMonthlyCostCents;
                        final scopeTotal = perLocation == null
                            ? null
                            : perLocation * widget.scopeLocationCount;
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                perLocation == null
                                    ? 'Enter calls and API cost to estimate monthly cost.'
                                    : 'Estimate: \$${_formatCents(perLocation)} per location, \$${_formatCents(scopeTotal!)} for ${widget.scopeLocationCount} location${widget.scopeLocationCount == 1 ? '' : 's'}.',
                                style: AppTextStyles.body13(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              key: const Key(
                                'admin_polling_calculator_use_estimate',
                              ),
                              onPressed: perLocation == null
                                  ? null
                                  : () => setState(() {
                                      _cost.text = _formatCents(perLocation);
                                    }),
                              icon: const Icon(Icons.calculate_outlined),
                              label: const Text('Use estimate'),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_notes'),
                controller: _notes,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Admin notes',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_reason'),
                controller: _reason,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason for assignment',
                  hintText: 'Required for the audit log',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_tier_assignment_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_tier_assignment_dialog_submit'),
          style: AdminButtonStyles.primary,
          onPressed: () {
            final reason = _reason.text.trim();
            if (reason.isEmpty) return;
            Navigator.of(context).pop(
              _TierAssignmentDraft(
                tierKey: _tierKey,
                customCadence: _tierKey == PollingTierKey.custom
                    ? Map<String, int>.from(_customCadence)
                    : null,
                monthlyPriceCentsOverride: _parseCents(_price.text),
                vendorApiCostEstimateCentsMonthlyOverride: _parseCents(
                  _cost.text,
                ),
                adminNotes: _notes.text.trim().isEmpty
                    ? null
                    : _notes.text.trim(),
                reasonNote: reason,
              ),
            );
          },
          child: const Text('Assign / update'),
        ),
      ],
    );
  }
}

String _tierLabel(PollingTierKey tier) {
  switch (tier) {
    case PollingTierKey.standard:
      return 'Standard';
    case PollingTierKey.premium:
      return 'Premium';
    case PollingTierKey.custom:
      return 'Custom';
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
              'View only: tier definitions and assignments require ecosystem admin access.',
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
