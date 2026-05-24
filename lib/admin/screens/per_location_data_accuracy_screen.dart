// Phase 8 spine-bridge Lane .C - F&F Ops Console "Data Accuracy" tab.
//
// Admin-web UX parity: this screen is a faithful, scope-driven replica
// of the operator-web data-accuracy data-SOURCE controls
// (`lib/operator_web/screens/data_accuracy_screen.dart`) for the
// selected location, edited the web way (inline toggles / cards, not
// the old pop-up dialogs). The admin scope selector (the
// `AdminSetupWorkspace` scope-tree pane) drives it: a single location
// scope edits THAT location; a business / org-unit scope shows a
// "pick a location" surface for the primary section (data accuracy is
// per-location, exactly like operator-web, which always works on one
// location).
//
// The multi-location override table ([PerLocationDataAccuracyTable])
// and the audit-history panel ([DataAccuracyAuditHistoryPanel]) are
// KEPT below the primary surface as clearly-labelled SECONDARY admin
// extras (the table is how an admin repairs many locations at once).
//
// Out-of-scope by design (operator-only / admin-elsewhere): no
// polling-tier request flow (admin manages tiers in Polling Setup /
// Plans) and no wage-RATE editing (admin stays view-only on wage
// rates). Only the data-SOURCE controls (which source feeds covers /
// wages, walk-in handling) are in scope here.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md,
// "Tab 1: Data Accuracy (per-location overrides)" section;
// memory/admin_web_ux_parity.md.
//
// Reuses operator-web's PURE PRESENTATIONAL data-accuracy widgets
// (`CoversSourceToggle`, `WageSourceToggle`, `WalkInHandlingCard`,
// `CoversManualEntryCard` — Flutter + theme + domain models only, no
// operator-web session / gateway) wired to the admin
// [DataAccuracyAdminGateway] via their `onChanged` callbacks. Same
// reuse precedent as the Timing slice's `ServicePeriodEditor`.
//
// Symmetric with [PollingAndPricingAdminScreen] (Tab 2) - both ride
// the [DataAccuracyAdminGateway] so the demo + production wiring are
// identical. Edit affordances gate on `editingEnabled` (which mirrors
// the 11A pattern: super_admin → editable; ff_support → read-only).

import 'package:flutter/material.dart';

import '../../widgets/console/console_screen_body.dart';
import '../../widgets/console/console_screen_header.dart';
import '../../widgets/console/console_surface.dart';
import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../admin_button_styles.dart';
import '../models/admin_hierarchy_settings_scope_policy.dart';
import '../services/data_accuracy_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import '../widgets/admin_responsive_layout.dart';
// Reuse operator-web's PURE PRESENTATIONAL data-accuracy widgets (each
// imports only Flutter + theme + domain/integration models + the
// shared console kit — NO operator-web session / gateway), so the
// admin primary surface renders byte-identical source controls to
// operator-web. Sanctioned by the slice guardrail allowing reuse of
// dependency-free web sub-widgets.
import 'package:forge_and_flow/operator_web/widgets/covers_manual_entry_card.dart';
import 'package:forge_and_flow/operator_web/widgets/covers_source_toggle.dart';
import 'package:forge_and_flow/operator_web/widgets/walk_in_handling_card.dart';
import 'package:forge_and_flow/operator_web/widgets/wage_source_toggle.dart';
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
      }
    }
  }

  @override
  void didUpdateWidget(covariant PerLocationDataAccuracyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialScope != oldWidget.initialScope ||
        widget.initialHierarchyScope != oldWidget.initialHierarchyScope) {
      _scope = _decoratedInitialScope;
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
      builder: (_) => _DataAccuracyOverrideDialog(
        initial: row,
        keyedRows: <DataAccuracyAdminRow>[row],
      ),
    );
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.overrideDataAccuracy(
        operatorId: row.operatorRef.operatorId,
        locationId: row.operatorRef.locationId,
        coversSourcePerServicePeriod: result.coversSourcePerServicePeriod,
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

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_data_accuracy_screen'),
      color: AppColors.backgroundDeep,
      child: _buildBody(),
    );
  }

  List<Widget> _buildHeaderActions() {
    final children = <Widget>[];
    if (widget.onBackToBusinessAccounts != null) {
      children.add(
        AdminBusinessAccountsBackButton(
          onPressed: widget.onBackToBusinessAccounts,
        ),
      );
    }
    return children;
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

  /// The single data-accuracy row backing the selected LOCATION scope,
  /// or null when no location is pinned (business / org-unit scope, or
  /// the location has no row yet). The primary web-style surface edits
  /// exactly this row, mirroring operator-web (always one location).
  DataAccuracyAdminRow? get _selectedLocationRow {
    final scope = _scope;
    if (scope == null || !scope.isLocationScope) return null;
    final locationId = scope.locationId;
    if (locationId == null || locationId.isEmpty) return null;
    for (final row in _rows) {
      if (row.operatorRef.operatorId == scope.operatorId &&
          row.operatorRef.locationId == locationId) {
        return row;
      }
    }
    return null;
  }

  /// Resolver-ordered service periods for the selected location's row.
  /// Falls back to the canonical demo definitions when the row has no
  /// configured periods yet, so the covers cards always render an
  /// honest period set (mirrors operator-web's loader fallback).
  List<ServicePeriodDefinition> _servicePeriodsForRow(
    DataAccuracyAdminRow row,
  ) {
    final configured = row.configuredServicePeriods;
    final defs = configured.isNotEmpty
        ? configured
        : ServicePeriodDefinitionResolver.demoDefinitions;
    return ServicePeriodDefinitionResolver.ordered(defs);
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
    return OperatorWebScreenBody(
      scrollKey: const Key('admin_data_accuracy_screen_body'),
      maxContentWidth: 1120,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OperatorWebScreenHeader(
            icon: Icons.fact_check_outlined,
            title: 'Data accuracy',
            subtitle:
                'Set where covers and labor dollars come from for the '
                'selected location.',
            actions: _buildHeaderActions(),
          ),
          const SizedBox(height: 14),
          if (!widget.editingEnabled) ...[
            const _ReadOnlyBanner(
              key: Key('admin_data_accuracy_readonly_banner'),
            ),
            const SizedBox(height: 4),
          ],
          if (_loadError != null) ...[
            _ErrorBanner(
              key: const Key('admin_data_accuracy_load_error'),
              message: _loadError!,
            ),
            const SizedBox(height: 4),
          ],
          if (_actionError != null) ...[
            _ErrorBanner(
              key: const Key('admin_data_accuracy_action_error'),
              message: _actionError!,
            ),
            const SizedBox(height: 4),
          ],
          // PRIMARY: web-style single-location source controls.
          _buildPrimarySection(),
          const SizedBox(height: 30),
          // SECONDARY (admin extras): the multi-location override table
          // + audit history. Kept available at any scope so an admin can
          // repair many locations at once.
          _AdminExtrasHeading(),
          const SizedBox(height: 14),
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

  /// PRIMARY web-style surface. At a location scope, renders the
  /// operator-web data-SOURCE controls (covers source per service
  /// period, wage source, walk-in handling, manual covers preview) for
  /// that location. At a business / org-unit scope (or no scope),
  /// renders a friendly "pick a location" surface, exactly like
  /// operator-web / the admin vendor screen which always work on one
  /// location.
  Widget _buildPrimarySection() {
    final scope = _scope;
    final row = _selectedLocationRow;
    if (scope == null || !scope.isLocationScope || row == null) {
      return _PickLocationSurface(
        key: const Key('admin_data_accuracy_pick_location'),
        scope: scope,
      );
    }

    final settings = row.settings;
    final periods = _servicePeriodsForRow(row);
    final locationLabel = row.operatorRef.locationName;
    final mutationEnabled = _locationMutationEnabled;

    final section = Column(
      key: const Key('admin_data_accuracy_primary_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SourceSummaryCard(
          locationLabel: locationLabel,
          businessName: row.operatorRef.businessName,
        ),
        const SizedBox(height: 22),
        const _DataAccuracySectionHeading(title: 'Labor'),
        const SizedBox(height: 14),
        // Reused PURE operator-web wage SOURCE toggle. `bundle: null`
        // means "no live vendor bundle on the admin row" so every
        // source option stays selectable (admin cannot inspect the
        // operator's live connections from this cross-tenant row). No
        // wage-RATE editor / wage-authority calculator is wired here
        // (admin stays view-only on rates).
        WageSourceToggle(
          value: settings.wageSource,
          onChanged: (next) => _onWebWageSourceChanged(row, next),
          bundle: null,
          source: settings.wageSourceSource,
        ),
        const SizedBox(height: 30),
        const _DataAccuracySectionHeading(title: 'Covers'),
        const SizedBox(height: 14),
        // Reused PURE operator-web covers-source toggle (one row per
        // configured service period).
        CoversSourceToggle(
          settings: settings,
          servicePeriods: periods,
          onChanged: (periodId, next) =>
              _onWebCoversSourceChanged(row, periodId, next),
          bundle: null,
        ),
        if (_anyPeriodManual(settings, periods)) ...[
          const SizedBox(height: 18),
          // Manual daily covers numbers are operator/manager operational
          // data entered in their own app, not an admin SOURCE setting.
          // The card renders (web-style) so the surface matches, but it
          // is a read-only preview here with an honest note.
          const _ManualCoversNote(),
          const SizedBox(height: 12),
          AbsorbPointer(
            child: Opacity(
              opacity: 0.65,
              child: CoversManualEntryCard(
                businessDateIso: _todayIso,
                yesterdayBusinessDateIso: _yesterdayIso(_todayIso),
                settings: settings,
                servicePeriods: periods,
                onEnterCovers: (_, __) {},
                onCopyYesterday: (_) {},
              ),
            ),
          ),
        ],
        const SizedBox(height: 30),
        const _DataAccuracySectionHeading(title: 'Walk-ins'),
        const SizedBox(height: 14),
        // Reused PURE operator-web walk-in handling card. Only the MODE
        // (a source-style setting) is wired to the gateway; the daily
        // count fields stay read-only (operator operational data).
        AbsorbPointer(
          absorbing: !mutationEnabled,
          child: Opacity(
            opacity: mutationEnabled ? 1 : 0.65,
            child: WalkInHandlingCard(
              mode: _widgetWalkInModeFromDomain(settings.walkInHandlingMode),
              onModeChanged: (next) => _onWebWalkInModeChanged(row, next),
              businessDateIso: _todayIso,
              dailyWalkInCount: settings.dailyWalkInCountFor(_todayIso),
              onDailyWalkInCountChanged: (_) {},
              servicePeriods: periods,
              source: settings.walkInHandlingModeSource,
            ),
          ),
        ),
      ],
    );

    if (mutationEnabled) return section;
    // ff_support read-only: block every write affordance in the primary
    // surface while leaving the controls visible (the secondary table /
    // audit still render below at full opacity).
    return AbsorbPointer(child: Opacity(opacity: 0.65, child: section));
  }

  bool _anyPeriodManual(
    DataAccuracySettings settings,
    List<ServicePeriodDefinition> periods,
  ) {
    for (final period in periods) {
      if (settings.coversSourceFor(period.id) == CoversSource.manual) {
        return true;
      }
    }
    return false;
  }

  // ── Web-style inline write handlers ──────────────────────────────
  //
  // Each fires `overrideDataAccuracy` (the SAME method the table's
  // dialog edit calls) after prompting for the server-required
  // admin_reason, so the inline web controls keep the exact audit
  // semantics of the legacy dialog path (HP: every admin write carries
  // a reason note).

  Future<void> _onWebCoversSourceChanged(
    DataAccuracyAdminRow row,
    String servicePeriodId,
    CoversSource next,
  ) async {
    if (!_locationMutationEnabled) return;
    if (row.settings.coversSourceFor(servicePeriodId) == next) return;
    final reason = await _promptAdminReason();
    if (reason == null) return;
    await _applyOverride(
      row,
      reasonNote: reason,
      coversSourcePerServicePeriod: <String, CoversSource>{
        servicePeriodId: next,
      },
    );
  }

  Future<void> _onWebWageSourceChanged(
    DataAccuracyAdminRow row,
    WageSource next,
  ) async {
    if (!_locationMutationEnabled) return;
    if (row.settings.wageSource == next) return;
    final reason = await _promptAdminReason();
    if (reason == null) return;
    await _applyOverride(row, reasonNote: reason, wageSource: next);
  }

  Future<void> _onWebWalkInModeChanged(
    DataAccuracyAdminRow row,
    WalkInHandlingMode next,
  ) async {
    if (!_locationMutationEnabled) return;
    final domainNext = _domainWalkInModeFromWidget(next);
    if (row.settings.walkInHandlingMode == domainNext) return;
    final reason = await _promptAdminReason();
    if (reason == null) return;
    await _applyOverride(
      row,
      reasonNote: reason,
      walkInHandlingMode: domainNext,
    );
  }

  Future<void> _applyOverride(
    DataAccuracyAdminRow row, {
    required String reasonNote,
    Map<String, CoversSource>? coversSourcePerServicePeriod,
    WageSource? wageSource,
    DataAccuracyWalkInHandlingMode? walkInHandlingMode,
  }) async {
    setState(() => _actionError = null);
    try {
      await widget.gateway.overrideDataAccuracy(
        operatorId: row.operatorRef.operatorId,
        locationId: row.operatorRef.locationId,
        coversSourcePerServicePeriod: coversSourcePerServicePeriod,
        wageSource: wageSource,
        walkInHandlingMode: walkInHandlingMode,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: reasonNote,
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

  /// admin_reason capture dialog. Mirrors the Timing screen's reason
  /// prompt (`_AdminTimingReasonDialog`): blocks empty submissions and
  /// returns the trimmed reason on confirm, null on cancel.
  Future<String?> _promptAdminReason() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _AdminDataAccuracyReasonDialog(),
    );
    final trimmed = reason?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  bool get _locationMutationEnabled {
    return _scopePolicy.allowsLocationMutation(
      _scope,
      editingEnabled: widget.editingEnabled,
    );
  }
}

/// Today's business date in restaurant-local terms. The admin row does
/// not carry a business-day clock, so the manual covers preview + the
/// walk-in card use a stable string; the values shown are read-only
/// here regardless (admins set the SOURCE, not the daily numbers).
String get _todayIso {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

String _yesterdayIso(String today) {
  final t = DateTime.parse(today);
  final y = t.subtract(const Duration(days: 1));
  return '${y.year.toString().padLeft(4, '0')}-'
      '${y.month.toString().padLeft(2, '0')}-'
      '${y.day.toString().padLeft(2, '0')}';
}

/// Maps the domain walk-in handling mode to the operator-web card's
/// widget enum (same mapping operator-web's screen uses privately).
WalkInHandlingMode _widgetWalkInModeFromDomain(
  DataAccuracyWalkInHandlingMode mode,
) {
  switch (mode) {
    case DataAccuracyWalkInHandlingMode.reservationsOnly:
      return WalkInHandlingMode.reservationsOnly;
    case DataAccuracyWalkInHandlingMode.walkInsAddedToReservations:
      return WalkInHandlingMode.walkInsAddedToReservations;
    case DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately:
      return WalkInHandlingMode.walkInsTrackedSeparately;
  }
}

DataAccuracyWalkInHandlingMode _domainWalkInModeFromWidget(
  WalkInHandlingMode mode,
) {
  switch (mode) {
    case WalkInHandlingMode.reservationsOnly:
      return DataAccuracyWalkInHandlingMode.reservationsOnly;
    case WalkInHandlingMode.walkInsAddedToReservations:
      return DataAccuracyWalkInHandlingMode.walkInsAddedToReservations;
    case WalkInHandlingMode.walkInsTrackedSeparately:
      return DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately;
  }
}

class _DataAccuracyOverrideDraft {
  const _DataAccuracyOverrideDraft({
    required this.coversSourcePerServicePeriod,
    required this.wageSource,
    required this.walkInHandlingMode,
    required this.reasonNote,
  });

  final Map<String, CoversSource>? coversSourcePerServicePeriod;
  final WageSource? wageSource;
  final DataAccuracyWalkInHandlingMode? walkInHandlingMode;
  final String reasonNote;
}

class _DataAccuracyOverrideDialog extends StatefulWidget {
  const _DataAccuracyOverrideDialog({required this.initial, this.keyedRows});

  final DataAccuracyAdminRow initial;
  final List<DataAccuracyAdminRow>? keyedRows;

  @override
  State<_DataAccuracyOverrideDialog> createState() =>
      _DataAccuracyOverrideDialogState();
}

class _DataAccuracyOverrideDialogState
    extends State<_DataAccuracyOverrideDialog> {
  late final List<String> _servicePeriodKeys = _servicePeriodKeysForRows(
    widget.keyedRows ?? <DataAccuracyAdminRow>[widget.initial],
  );
  late Map<String, CoversSource> _initialCoversSourcePerServicePeriod;
  late Map<String, CoversSource> _coversSourcePerServicePeriod;
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
              if (_servicePeriodKeys.isEmpty)
                Text(
                  'No configured service periods are available for covers source edits.',
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                )
              else
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
                  ),
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
                coversSourcePerServicePeriod: changedCovers.isNotEmpty
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
    case CoversSource.reservationPlusWalkin:
      return 'Reservations + walk-ins';
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

/// Friendly "pick a location" surface for the PRIMARY section at a
/// business / org-unit scope (or no scope). Mirrors the admin Vendor
/// screen's location-required panel: data accuracy is per-location, so
/// the web-style source controls need a single location pinned. The
/// secondary table below still works at any scope.
class _PickLocationSurface extends StatelessWidget {
  const _PickLocationSurface({super.key, required this.scope});

  final AdminHierarchyScopeIntent? scope;

  @override
  Widget build(BuildContext context) {
    final selected = scope;
    final subtitle = selected == null
        ? 'Pick a location in Business accounts to set where its covers and '
              'labor dollars come from.'
        : 'You selected ${selected.displayLabel}. Data accuracy is set one '
              'location at a time, so pick a location in Business accounts to '
              'edit its covers and labor sources. The location table below '
              'still lets you review and repair every location under this '
              'scope.';
    return OperatorWebPanel(
      key: const Key('admin_data_accuracy_pick_location_panel'),
      title: 'Pick a location to set up data accuracy',
      subtitle: subtitle,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.place_outlined,
            size: 18,
            color: AppColors.sunsetDark,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Covers source, labor source, and walk-in handling are '
              'per-location settings. Choose a single location to edit them '
              'the same way the operator does in their own console.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small read-only summary at the top of the primary surface so the
/// admin always sees which location the source controls write to.
class _SourceSummaryCard extends StatelessWidget {
  const _SourceSummaryCard({
    required this.locationLabel,
    required this.businessName,
  });

  final String locationLabel;
  final String businessName;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_data_accuracy_source_summary'),
      title: 'Editing this location',
      subtitle:
          'Changes apply to this location only. Each save records a reason '
          'in the operator audit log.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdminDetailRow(label: 'Business', value: businessName),
          AdminDetailRow(label: 'Location', value: locationLabel),
        ],
      ),
    );
  }
}

/// Heading for the main vertical groupings ("Labor", "Covers",
/// "Walk-ins"). Mirrors operator-web's `_DataAccuracySectionHeading`.
class _DataAccuracySectionHeading extends StatelessWidget {
  const _DataAccuracySectionHeading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: AppTextStyles.display16(color: AppColors.textPrimary),
    );
  }
}

/// Labelled divider introducing the SECONDARY admin extras (the
/// multi-location table + audit history) below the primary surface.
class _AdminExtrasHeading extends StatelessWidget {
  const _AdminExtrasHeading();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('admin_data_accuracy_extras_heading'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'All locations and audit history',
          style: AppTextStyles.display16(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 6),
        Text(
          'Admin extras: review every location under the selected scope, '
          'repair several at once, and see the audit trail. The controls '
          'above edit the single selected location the web way.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// Honest note above the (read-only) manual covers preview: admins set
/// the SOURCE; the daily manual numbers are entered by the operator or
/// a location manager in their own app.
class _ManualCoversNote extends StatelessWidget {
  const _ManualCoversNote();

  @override
  Widget build(BuildContext context) {
    return const OperatorWebBanner(
      key: Key('admin_data_accuracy_manual_covers_note'),
      icon: Icons.info_outline,
      message:
          'A service period is set to manual covers. The operator or a '
          'location manager types the daily numbers in their own app. This '
          'preview is read-only here.',
    );
  }
}

/// admin_reason capture dialog for inline source edits. Mirrors the
/// Timing screen's `_AdminTimingReasonDialog` (blocks empty
/// submissions; returns the trimmed reason on confirm, null on cancel)
/// so every web-style write keeps the server-required reason note.
class _AdminDataAccuracyReasonDialog extends StatefulWidget {
  const _AdminDataAccuracyReasonDialog();

  @override
  State<_AdminDataAccuracyReasonDialog> createState() =>
      _AdminDataAccuracyReasonDialogState();
}

class _AdminDataAccuracyReasonDialogState
    extends State<_AdminDataAccuracyReasonDialog> {
  final TextEditingController _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_data_accuracy_reason_dialog'),
      title: 'Reason for data accuracy change',
      maxWidth: 460,
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_data_accuracy_reason_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_data_accuracy_reason_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Confirm'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'The operator will see this reason in their audit log. Write a '
            'short, plain-English note about why you are changing where their '
            'covers or labor dollars come from.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('admin_data_accuracy_reason_field'),
            controller: _reasonController,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Reason',
              border: const OutlineInputBorder(),
              errorText: _violated ? 'Add a reason before continuing.' : null,
            ),
          ),
        ],
      ),
    );
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
              'Support can review effective covers, wages, and walk-ins by location. Normal operator edits stay in Operator Web; location repair actions are hidden for this role.',
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
