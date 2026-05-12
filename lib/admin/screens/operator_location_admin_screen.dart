// Phase 11A.1 - Operator + location admin screen.
//
// Admin-side CRUD on operators (`operators` table) and their
// locations (`locations` table). Supports onboarding a new operator
// (creates the row, primary location, subscription tier, currency,
// and admin assignment), editing existing operators, suspending +
// reactivating, and add/edit/remove locations with IANA timezone +
// business-day rollover hour validation.
//
// The screen takes an [OperatorLocationAdminGateway] from the
// outside; production passes the HTTP gateway, demo + widget tests
// pass the in-memory gateway. Brand styling reuses
// `lib/theme/app_theme.dart` verbatim per the 11A non-negotiable.

import 'package:flutter/material.dart';

import '../../domain/models/business_timing_profile.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/business_timing_profile_resolver.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../theme/app_theme.dart';
import '../../utils/iana_timezones.dart';

import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/email_conflict_details.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_hierarchy_scope_prompt.dart';
import '../widgets/admin_responsive_layout.dart';
// Phase 8.0 - vendor connections mount (per-location admin sub-route).
// Append-only addition; the existing Edit / Remove / Make-primary
// affordances stay untouched.
import 'vendor_connections/vendor_connections_admin_mount.dart';

class OperatorLocationAdminScreen extends StatefulWidget {
  const OperatorLocationAdminScreen({
    super.key,
    required this.gateway,
    this.hierarchyGateway,
    this.vendorConnectionsGateway,
    this.idempotencyKeyFactory,
    this.onOpenSupportLogs,
    this.onOpenSupportLogsScope,
    this.onOpenDataAccuracy,
    this.onOpenDataAccuracyScope,
    this.onOpenPollingPricing,
    this.onOpenPollingPricingScope,
    this.onOpenIntegrationsScope,
    this.onOpenTimingScope,
    this.onOpenSupportOperatorView,
    this.onOpenTeam,
    this.onOpenAccess,
    this.onOpenPeopleAccessRolesScope,
    this.onOpenAuditSupport,
    this.onOpenSecurityAuditSessionsScope,
    this.onSelectOperatorScope,
    this.selectedParentOrgUnitId,
    this.selectedParentOrgUnitLabel,
    this.editingEnabled = true,
    this.actorUserId = 'admin-console',
  });

  final OperatorLocationAdminGateway gateway;
  final RolesHierarchySessionsAdminGateway? hierarchyGateway;
  final VendorConnectionsGateway? vendorConnectionsGateway;
  final String? selectedParentOrgUnitId;
  final String? selectedParentOrgUnitLabel;
  final void Function(String operatorId, String? locationId)? onOpenSupportLogs;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenSupportLogsScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenDataAccuracy;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenDataAccuracyScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenPollingPricing;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenPollingPricingScope;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenIntegrationsScope;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenTimingScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>?
  onOpenSupportOperatorView;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenTeam;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenAccess;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenPeopleAccessRolesScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenAuditSupport;
  final ValueChanged<AdminHierarchyScopeIntent>?
  onOpenSecurityAuditSessionsScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onSelectOperatorScope;
  final bool editingEnabled;
  final String actorUserId;

  /// Factory for the idempotency key the gateway attaches to each
  /// mutating call. Production binds this to a UUID-shaped generator;
  /// widget tests inject a deterministic counter so retries can be
  /// asserted.
  final String Function()? idempotencyKeyFactory;

  @override
  State<OperatorLocationAdminScreen> createState() =>
      _OperatorLocationAdminScreenState();
}

class _OperatorLocationAdminScreenState
    extends State<OperatorLocationAdminScreen> {
  bool _loading = true;
  String? _loadError;
  List<OperatorAdminBundle> _bundles = const <OperatorAdminBundle>[];
  String? _selectedOperatorId;
  AdminHierarchyScopeIntent? _selectedHierarchyScope;
  String? _actionError;
  List<AdminEmailConflictUsage> _actionEmailConflicts =
      const <AdminEmailConflictUsage>[];
  int _idempotencyCounter = 0;

  /// Mints a fresh idempotency key per user action so a retried POST
  /// or PATCH at the proxy collapses to one ledger row + one audit
  /// row in `admin_request_idempotency`. A new key is minted each
  /// time the user triggers a mutation; it is NEVER reused across
  /// re-renders or repeated screen builds.
  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return 'operator-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final bundles = await widget.gateway.listOperators();
      if (!mounted) return;
      OperatorAdminBundle? selectedAfterRefresh;
      setState(() {
        _bundles = bundles;
        _loading = false;
        if (_selectedOperatorId != null &&
            bundles.every(
              (b) => b.operator.operatorId != _selectedOperatorId,
            )) {
          _selectedOperatorId = null;
        }
        _selectedOperatorId ??= bundles.isEmpty
            ? null
            : bundles.first.operator.operatorId;
        selectedAfterRefresh = _selected;
        if (selectedAfterRefresh == null) {
          _selectedHierarchyScope = null;
        } else if (_selectedHierarchyScope?.operatorId !=
            selectedAfterRefresh!.operator.operatorId) {
          _selectedHierarchyScope = _businessHierarchyScope(
            selectedAfterRefresh!,
          );
        }
      });
      _notifyOperatorScope(selectedAfterRefresh);
    } on OperatorLocationAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load operators: $error';
        _loading = false;
      });
    }
  }

  void _selectOperator(String id) {
    OperatorAdminBundle? selected;
    setState(() {
      _selectedOperatorId = id;
      selected = _selected;
      _selectedHierarchyScope = selected == null
          ? null
          : _businessHierarchyScope(selected!);
    });
    _notifyOperatorScope(selected);
  }

  void _selectHierarchyScope(AdminHierarchyScopeIntent scope) {
    setState(() {
      _selectedHierarchyScope = scope;
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
    });
  }

  void _notifyOperatorScope(OperatorAdminBundle? bundle) {
    final callback = widget.onSelectOperatorScope;
    if (callback == null || bundle == null) return;
    callback(_scopeForBundle(bundle));
  }

  AdminOperatorLocationScopeIntent _scopeForBundle(OperatorAdminBundle bundle) {
    final primaryLocation = bundle.primaryLocation;
    final fallbackLocation = bundle.locations.isEmpty
        ? null
        : bundle.locations.first;
    final location = primaryLocation ?? fallbackLocation;
    return AdminOperatorLocationScopeIntent(
      operatorId: bundle.operator.operatorId,
      operatorName: bundle.operator.businessName,
      locationId: location?.locationId,
      locationName: location?.name,
    );
  }

  AdminHierarchyScopeIntent _businessHierarchyScope(
    OperatorAdminBundle bundle,
  ) {
    return AdminHierarchyScopeIntent.business(
      operatorId: bundle.operator.operatorId,
      operatorName: bundle.operator.businessName,
      effectiveValueLabel: 'Business default',
      allowedActionsLabel: widget.editingEnabled ? 'Editable' : 'Read-only',
    );
  }

  OperatorAdminBundle? get _selected {
    final id = _selectedOperatorId;
    if (id == null) return null;
    for (final b in _bundles) {
      if (b.operator.operatorId == id) return b;
    }
    return null;
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() {
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
    });
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on OperatorLocationAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.message;
        _actionEmailConflicts = AdminEmailConflictUsage.listFromDetails(
          error.details,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_operators_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BusinessAccountsHeader(
              onNewBusiness: widget.editingEnabled
                  ? _openOnboardingDialog
                  : null,
            ),
            const SizedBox(height: 14),
            if (!widget.editingEnabled) const _ReadOnlyBanner(),
            if (!widget.editingEnabled) const SizedBox(height: 12),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_operators_action_error'),
                message: _actionError!,
                emailConflicts: _actionEmailConflicts,
                onShowConflict: _showEmailConflict,
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
        key: Key('admin_operators_loading'),
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
        key: const Key('admin_operators_load_error'),
        message: _loadError!,
      );
    }
    if (_bundles.isEmpty) {
      return Center(
        key: const Key('admin_operators_empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No business accounts yet',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Use "New business" to add the account, primary location, and first admin user.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return AdminMasterDetailLayout(
      masterWidth: 300,
      compactMasterHeight: 240,
      master: _OperatorList(
        bundles: _bundles,
        selectedOperatorId: _selectedOperatorId,
        onSelect: _selectOperator,
      ),
      detail: _selected == null
          ? const SizedBox.shrink()
          : _OperatorDetail(
              bundle: _selected!,
              hierarchyGateway: widget.hierarchyGateway,
              vendorConnectionsGateway: widget.vendorConnectionsGateway,
              actorUserId: widget.actorUserId,
              idempotencyKeyFactory: _nextIdempotencyKey,
              selectedHierarchyScope:
                  _selectedHierarchyScope ??
                  _businessHierarchyScope(_selected!),
              onSelectHierarchyScope: _selectHierarchyScope,
              onEditOperator: _openEditOperatorDialog,
              onSuspend: _suspend,
              onReactivate: _reactivate,
              onAddLocation: _openAddLocationDialog,
              onEditLocation: _openEditLocationDialog,
              onRemoveLocation: _removeLocation,
              onSetPrimary: _setPrimaryLocation,
              onOpenSupportLogs: widget.onOpenSupportLogs,
              onOpenSupportLogsScope: widget.onOpenSupportLogsScope,
              onOpenDataAccuracy: widget.onOpenDataAccuracy,
              onOpenDataAccuracyScope: widget.onOpenDataAccuracyScope,
              onOpenPollingPricing: widget.onOpenPollingPricing,
              onOpenPollingPricingScope: widget.onOpenPollingPricingScope,
              onOpenIntegrationsScope: widget.onOpenIntegrationsScope,
              onOpenTimingScope: widget.onOpenTimingScope,
              onOpenSupportOperatorView: widget.onOpenSupportOperatorView,
              onOpenTeam: widget.onOpenTeam,
              onOpenAccess: widget.onOpenAccess,
              onOpenPeopleAccessRolesScope: widget.onOpenPeopleAccessRolesScope,
              onOpenAuditSupport: widget.onOpenAuditSupport,
              onOpenSecurityAuditSessionsScope:
                  widget.onOpenSecurityAuditSessionsScope,
              selectedParentOrgUnitId:
                  _selectedHierarchyScope?.scopeType ==
                      AdminHierarchyScopeType.orgUnit
                  ? _selectedHierarchyScope?.orgUnitId
                  : widget.selectedParentOrgUnitId,
              selectedParentOrgUnitLabel:
                  _selectedHierarchyScope?.scopeType ==
                      AdminHierarchyScopeType.orgUnit
                  ? _selectedHierarchyScope?.orgUnitName
                  : widget.selectedParentOrgUnitLabel,
              editingEnabled: widget.editingEnabled,
            ),
    );
  }

  Future<void> _openOnboardingDialog() async {
    if (!widget.editingEnabled) return;
    final command = await showDialog<OperatorOnboardCommand>(
      context: context,
      builder: (_) =>
          _OnboardOperatorDialog(idempotencyKey: _nextIdempotencyKey()),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.onboardOperator(command);
    }, successHint: 'Operator onboarded.');
  }

  Future<void> _openEditOperatorDialog(OperatorAdminBundle bundle) async {
    if (!widget.editingEnabled) return;
    final patch = await showDialog<OperatorPatchCommand>(
      context: context,
      builder: (_) => _EditOperatorDialog(
        bundle: bundle,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (patch == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.patchOperator(patch);
    }, successHint: 'Account profile updated.');
  }

  Future<void> _suspend(OperatorAdminBundle bundle) async {
    if (!widget.editingEnabled) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.suspendOperator(
        bundle.operator.operatorId,
        idempotencyKey: key,
      );
    }, successHint: 'Operator suspended.');
  }

  Future<void> _reactivate(OperatorAdminBundle bundle) async {
    if (!widget.editingEnabled) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.reactivateOperator(
        bundle.operator.operatorId,
        idempotencyKey: key,
      );
    }, successHint: 'Operator reactivated.');
  }

  Future<void> _openAddLocationDialog(OperatorAdminBundle bundle) async {
    if (!widget.editingEnabled) return;
    final selectedOrgUnitScope =
        _selectedHierarchyScope?.scopeType == AdminHierarchyScopeType.orgUnit
        ? _selectedHierarchyScope
        : null;
    final parentOrgUnitId =
        selectedOrgUnitScope?.orgUnitId?.trim() ??
        widget.selectedParentOrgUnitId?.trim();
    final parentOrgUnitLabel =
        selectedOrgUnitScope?.orgUnitName ?? widget.selectedParentOrgUnitLabel;
    if (parentOrgUnitId == null || parentOrgUnitId.isEmpty) {
      setState(() {
        _actionError = 'Select an org unit before adding a location.';
        _actionEmailConflicts = const <AdminEmailConflictUsage>[];
      });
      return;
    }
    final command = await showDialog<LocationCreateCommand>(
      context: context,
      builder: (_) => _LocationDialog(
        operatorId: bundle.operator.operatorId,
        parentOrgUnitId: parentOrgUnitId,
        parentOrgUnitLabel: parentOrgUnitLabel,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.addLocation(command);
    }, successHint: 'Location added.');
  }

  Future<void> _openEditLocationDialog(LocationAdminRecord location) async {
    if (!widget.editingEnabled) return;
    final command = await showDialog<LocationPatchCommand>(
      context: context,
      builder: (_) => _LocationDialog(
        operatorId: location.operatorId,
        existing: location,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.patchLocation(command);
    }, successHint: 'Location updated.');
  }

  Future<void> _removeLocation(LocationAdminRecord location) async {
    if (!widget.editingEnabled) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Remove ${location.name}?',
        message:
            'This cannot be undone. The location must not be the '
            "operator's primary location.",
        confirmLabel: 'Remove',
      ),
    );
    if (confirmed != true) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.removeLocation(
        operatorId: location.operatorId,
        locationId: location.locationId,
        idempotencyKey: key,
      );
    }, successHint: 'Location removed.');
  }

  Future<void> _setPrimaryLocation(
    OperatorAdminBundle bundle,
    LocationAdminRecord location,
  ) async {
    if (!widget.editingEnabled) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.patchOperator(
        OperatorPatchCommand(
          operatorId: bundle.operator.operatorId,
          primaryLocationId: location.locationId,
          idempotencyKey: key,
        ),
      );
    }, successHint: 'Primary location updated.');
  }

  void _showEmailConflict(AdminEmailConflictUsage usage) {
    final operatorId = usage.operatorId;
    if (operatorId == null || operatorId.isEmpty) return;
    OperatorAdminBundle? selected;
    setState(() {
      _selectedOperatorId = operatorId;
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
      selected = _selected;
    });
    _notifyOperatorScope(selected);
  }
}

class _BusinessAccountsHeader extends StatelessWidget {
  const _BusinessAccountsHeader({required this.onNewBusiness});

  final VoidCallback? onNewBusiness;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      'Business accounts',
      style: AppTextStyles.pageTitle(color: AppColors.textPrimary),
    );
    final action = onNewBusiness == null
        ? null
        : FilledButton.icon(
            key: const Key('admin_operators_new_button'),
            onPressed: onNewBusiness,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sunset,
              foregroundColor: AppColors.backgroundSurface,
              disabledBackgroundColor: AppColors.sunset.withValues(alpha: 0.45),
              disabledForegroundColor: AppColors.backgroundSurface.withValues(
                alpha: 0.78,
              ),
              minimumSize: const Size(168, 52),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
              ),
              textStyle: AppTextStyles.body14(
                color: AppColors.backgroundSurface,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New business'),
          );
    if (action == null) return title;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [title, const SizedBox(height: 10), action],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: title),
            const SizedBox(width: 12),
            action,
          ],
        );
      },
    );
  }
}

class _OperatorList extends StatefulWidget {
  const _OperatorList({
    required this.bundles,
    required this.selectedOperatorId,
    required this.onSelect,
  });

  final List<OperatorAdminBundle> bundles;
  final String? selectedOperatorId;
  final ValueChanged<String> onSelect;

  @override
  State<_OperatorList> createState() => _OperatorListState();
}

class _OperatorListState extends State<_OperatorList> {
  final _search = TextEditingController();
  late List<_SearchableOperatorBundle> _searchIndex;
  _BusinessAccountFilter _accountFilter = _BusinessAccountFilter.all;

  @override
  void initState() {
    super.initState();
    _searchIndex = _buildSearchIndex(widget.bundles);
  }

  @override
  void didUpdateWidget(covariant _OperatorList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundles != widget.bundles) {
      _searchIndex = _buildSearchIndex(widget.bundles);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<_SearchableOperatorBundle> _buildSearchIndex(
    List<OperatorAdminBundle> bundles,
  ) {
    return <_SearchableOperatorBundle>[
      for (final bundle in bundles) _SearchableOperatorBundle(bundle),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final filtered = _searchIndex
        .where(
          (entry) =>
              entry.matches(query) &&
              _matchesAccountFilter(entry.bundle, _accountFilter),
        )
        .map((entry) => entry.bundle)
        .toList(growable: false);

    return Container(
      key: const Key('admin_operators_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('admin_operators_search_field'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      style: AppTextStyles.body14(color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Search business accounts',
                        hintStyle: AppTextStyles.body13(
                          color: AppColors.textMuted,
                        ),
                        prefixIcon: const Icon(
                          Icons.search,
                          size: 18,
                          color: AppColors.textMuted,
                        ),
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                key: const Key('admin_operators_search_clear'),
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close, size: 16),
                                color: AppColors.textMuted,
                                onPressed: () {
                                  _search.clear();
                                  setState(() {});
                                },
                              ),
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.backgroundSurface,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(
                            color: AppColors.borderSubtle,
                            width: 1,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(
                            color: AppColors.borderSubtle,
                            width: 1,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(
                            color: AppColors.sunset,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Filter business accounts',
                    child: PopupMenuButton<_BusinessAccountFilter>(
                      key: const Key('admin_operators_filter_button'),
                      tooltip: 'Filter business accounts',
                      initialValue: _accountFilter,
                      onSelected: (value) =>
                          setState(() => _accountFilter = value),
                      itemBuilder: (context) =>
                          <PopupMenuEntry<_BusinessAccountFilter>>[
                            for (final value in _BusinessAccountFilter.values)
                              PopupMenuItem<_BusinessAccountFilter>(
                                value: value,
                                child: Text(value.label),
                              ),
                          ],
                      child: Container(
                        height: 44,
                        width: 44,
                        decoration: BoxDecoration(
                          color: _accountFilter == _BusinessAccountFilter.all
                              ? AppColors.backgroundSurface
                              : AppColors.sunset.withValues(alpha: 0.10),
                          border: Border.all(
                            color: _accountFilter == _BusinessAccountFilter.all
                                ? AppColors.borderSubtle
                                : AppColors.sunset,
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.filter_list,
                          size: 18,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      key: const Key('admin_operators_no_matches'),
                      child: Text(
                        'No business accounts match',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final bundle = filtered[index];
                        final selected =
                            bundle.operator.operatorId ==
                            widget.selectedOperatorId;
                        return _OperatorTile(
                          key: Key(
                            'admin_operator_row_${bundle.operator.operatorId}',
                          ),
                          bundle: bundle,
                          selected: selected,
                          onSelect: () =>
                              widget.onSelect(bundle.operator.operatorId),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static bool _matchesAccountFilter(
    OperatorAdminBundle bundle,
    _BusinessAccountFilter filter,
  ) {
    switch (filter) {
      case _BusinessAccountFilter.all:
        return true;
      case _BusinessAccountFilter.active:
        return !bundle.operator.isSuspended;
      case _BusinessAccountFilter.suspended:
        return bundle.operator.isSuspended;
      case _BusinessAccountFilter.missingPrimary:
        return bundle.primaryLocation == null;
      case _BusinessAccountFilter.setupNeedsReview:
        return bundle.primaryLocation == null || bundle.locations.isEmpty;
    }
  }
}

enum _BusinessAccountFilter {
  all,
  active,
  suspended,
  missingPrimary,
  setupNeedsReview;

  String get label {
    switch (this) {
      case _BusinessAccountFilter.all:
        return 'All accounts';
      case _BusinessAccountFilter.active:
        return 'Active';
      case _BusinessAccountFilter.suspended:
        return 'Suspended';
      case _BusinessAccountFilter.missingPrimary:
        return 'Missing primary location';
      case _BusinessAccountFilter.setupNeedsReview:
        return 'Setup needs review';
    }
  }
}

class _SearchableOperatorBundle {
  _SearchableOperatorBundle(this.bundle)
    : searchableText = _buildSearchableText(bundle);

  final OperatorAdminBundle bundle;
  final String searchableText;

  bool matches(String query) => query.isEmpty || searchableText.contains(query);

  static String _buildSearchableText(OperatorAdminBundle bundle) {
    final operator = bundle.operator;
    return <String>[
      operator.businessName,
      operator.ownerEmail,
      operator.subscriptionTier,
      operator.preferredCurrency,
      for (final location in bundle.locations) location.name,
      for (final location in bundle.locations) location.timezone,
    ].join(' ').toLowerCase();
  }
}

class _OperatorTile extends StatelessWidget {
  const _OperatorTile({
    super.key,
    required this.bundle,
    required this.selected,
    required this.onSelect,
  });

  final OperatorAdminBundle bundle;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final operator = bundle.operator;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: selected
            ? AppColors.sunset.withValues(alpha: 0.09)
            : AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? AppColors.sunset : AppColors.borderSubtle,
                width: selected ? 1.4 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? AppColors.sunsetDark : AppColors.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    operator.businessName,
                    style: AppTextStyles.sectionTitle(
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OperatorDetail extends StatelessWidget {
  const _OperatorDetail({
    required this.bundle,
    required this.hierarchyGateway,
    required this.vendorConnectionsGateway,
    required this.actorUserId,
    required this.idempotencyKeyFactory,
    required this.selectedHierarchyScope,
    required this.onSelectHierarchyScope,
    required this.onEditOperator,
    required this.onSuspend,
    required this.onReactivate,
    required this.onAddLocation,
    required this.onEditLocation,
    required this.onRemoveLocation,
    required this.onSetPrimary,
    required this.onOpenSupportLogs,
    required this.onOpenSupportLogsScope,
    required this.onOpenDataAccuracy,
    required this.onOpenDataAccuracyScope,
    required this.onOpenPollingPricing,
    required this.onOpenPollingPricingScope,
    required this.onOpenIntegrationsScope,
    required this.onOpenTimingScope,
    required this.onOpenSupportOperatorView,
    required this.onOpenTeam,
    required this.onOpenAccess,
    required this.onOpenPeopleAccessRolesScope,
    required this.onOpenAuditSupport,
    required this.onOpenSecurityAuditSessionsScope,
    required this.selectedParentOrgUnitId,
    this.selectedParentOrgUnitLabel,
    required this.editingEnabled,
  });

  final OperatorAdminBundle bundle;
  final RolesHierarchySessionsAdminGateway? hierarchyGateway;
  final VendorConnectionsGateway? vendorConnectionsGateway;
  final String actorUserId;
  final String Function() idempotencyKeyFactory;
  final AdminHierarchyScopeIntent selectedHierarchyScope;
  final ValueChanged<AdminHierarchyScopeIntent> onSelectHierarchyScope;
  final ValueChanged<OperatorAdminBundle> onEditOperator;
  final ValueChanged<OperatorAdminBundle> onSuspend;
  final ValueChanged<OperatorAdminBundle> onReactivate;
  final ValueChanged<OperatorAdminBundle> onAddLocation;
  final ValueChanged<LocationAdminRecord> onEditLocation;
  final ValueChanged<LocationAdminRecord> onRemoveLocation;
  final void Function(OperatorAdminBundle, LocationAdminRecord) onSetPrimary;
  final void Function(String operatorId, String? locationId)? onOpenSupportLogs;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenSupportLogsScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenDataAccuracy;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenDataAccuracyScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenPollingPricing;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenPollingPricingScope;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenIntegrationsScope;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenTimingScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>?
  onOpenSupportOperatorView;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenTeam;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenAccess;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenPeopleAccessRolesScope;
  final ValueChanged<AdminOperatorLocationScopeIntent>? onOpenAuditSupport;
  final ValueChanged<AdminHierarchyScopeIntent>?
  onOpenSecurityAuditSessionsScope;
  final String? selectedParentOrgUnitId;
  final String? selectedParentOrgUnitLabel;
  final bool editingEnabled;

  bool get _canAddLocation {
    final parentOrgUnitId = selectedParentOrgUnitId?.trim();
    return editingEnabled &&
        parentOrgUnitId != null &&
        parentOrgUnitId.isNotEmpty;
  }

  LocationAdminRecord? get _selectedLocationForScope {
    final locationId = selectedHierarchyScope.locationId;
    if (locationId == null) return null;
    for (final location in bundle.locations) {
      if (location.locationId == locationId) return location;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final operator = bundle.operator;
    final canAddLocation = _canAddLocation;
    final selectedLocation = _selectedLocationForScope;
    final timingLocation =
        selectedLocation ??
        bundle.primaryLocation ??
        (bundle.locations.isEmpty ? null : bundle.locations.first);
    return SingleChildScrollView(
      key: Key('admin_operator_detail_${operator.operatorId}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminCard(
            key: const Key('admin_operator_profile_card'),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        operator.businessName,
                        style: AppTextStyles.display20(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (operator.isSuspended)
                      _StatusPill(
                        label: 'suspended',
                        color: AppColors.negative,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                AdminDetailRow(
                  label: 'Contact email',
                  value: operator.ownerEmail,
                ),
                AdminDetailRow(
                  key: const Key('admin_operator_ai_plan_detail_row'),
                  label: 'Forge & Flow AI plan',
                  value: operator.subscriptionTier,
                  muted: true,
                ),
                AdminDetailRow(
                  label: 'Currency',
                  value: operator.preferredCurrency,
                ),
                AdminDetailRow(
                  label: 'Primary location',
                  value: bundle.primaryLocation?.name ?? 'No primary location',
                ),
                const SizedBox(height: 14),
                _ActionRowWrap(
                  children: [
                    if (editingEnabled)
                      _OperatorActionButton(
                        buttonKey: const Key('admin_operator_edit_button'),
                        label: 'Account profile',
                        icon: Icons.badge_outlined,
                        tooltip: 'Edit account profile',
                        onPressed: () => onEditOperator(bundle),
                      ),
                    if (editingEnabled && operator.isSuspended)
                      _OperatorActionButton(
                        buttonKey: const Key(
                          'admin_operator_reactivate_button',
                        ),
                        label: 'Reactivate',
                        icon: Icons.play_arrow_outlined,
                        tooltip: 'Reactivate this business account',
                        onPressed: () => onReactivate(bundle),
                      ),
                    if (editingEnabled && !operator.isSuspended)
                      _OperatorActionButton(
                        buttonKey: const Key('admin_operator_suspend_button'),
                        label: 'Suspend',
                        icon: Icons.pause_outlined,
                        tooltip: 'Suspend this business account',
                        destructive: true,
                        onPressed: () => onSuspend(bundle),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _BusinessHierarchyPanel(
            bundle: bundle,
            gateway: hierarchyGateway,
            actorUserId: actorUserId,
            idempotencyKeyFactory: idempotencyKeyFactory,
            selectedScope: selectedHierarchyScope,
            onSelectScope: onSelectHierarchyScope,
            onAddLocation: canAddLocation ? () => onAddLocation(bundle) : null,
            addLocationEnabled: canAddLocation,
            onEditLocation: onEditLocation,
            onRemoveLocation: onRemoveLocation,
            onSetPrimary: (location) => onSetPrimary(bundle, location),
            editingEnabled: editingEnabled,
          ),
          const SizedBox(height: 12),
          _BusinessSetupCard(
            bundle: bundle,
            selectedScope: selectedHierarchyScope,
            onSelectScope: onSelectHierarchyScope,
            onOpenDataAccuracy:
                onOpenDataAccuracyScope ??
                (onOpenDataAccuracy == null
                    ? null
                    : (scope) =>
                          onOpenDataAccuracy!(scope.toOperatorLocationScope())),
            onOpenPollingPricing:
                onOpenPollingPricingScope ??
                (onOpenPollingPricing == null
                    ? null
                    : (scope) => onOpenPollingPricing!(
                        scope.toOperatorLocationScope(),
                      )),
            onOpenPeopleAccessRoles:
                onOpenPeopleAccessRolesScope ??
                (onOpenAccess == null
                    ? onOpenTeam == null
                          ? null
                          : (scope) =>
                                onOpenTeam!(scope.toOperatorLocationScope())
                    : (scope) =>
                          onOpenAccess!(scope.toOperatorLocationScope())),
            onOpenSecurityAuditSessions:
                onOpenSecurityAuditSessionsScope ??
                (onOpenAuditSupport == null
                    ? null
                    : (scope) =>
                          onOpenAuditSupport!(scope.toOperatorLocationScope())),
            onOpenSupportLogs:
                onOpenSupportLogsScope ??
                (onOpenSupportLogs == null
                    ? null
                    : (scope) => onOpenSupportLogs!(
                        scope.operatorId,
                        scope.locationId,
                      )),
            onOpenIntegrations:
                onOpenIntegrationsScope ??
                (scope) {
                  final scopedLocation = _locationForScope(bundle, scope);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(
                        name: '/vendor-connections',
                      ),
                      builder: (_) => VendorConnectionsAdminMount(
                        operatorId: operator.operatorId,
                        locationId: scopedLocation?.locationId,
                        locationName: scopedLocation?.name,
                        selectedScope: scope,
                        gateway: vendorConnectionsGateway,
                        canMutate: editingEnabled,
                        onBackToBusinessAccounts: () =>
                            Navigator.of(context).maybePop(),
                      ),
                    ),
                  );
                },
            onOpenTiming:
                onOpenTimingScope ??
                (scope) {
                  final scopedTimingLocation =
                      _locationForScope(bundle, scope) ?? timingLocation;
                  showDialog<void>(
                    context: context,
                    builder: (_) => _AdminLocationTimingDialog(
                      operatorName: operator.businessName,
                      selectedScope: scope,
                      timingLocation: scopedTimingLocation,
                      editingEnabled: editingEnabled,
                    ),
                  );
                },
          ),
        ],
      ),
    );
  }

  LocationAdminRecord? _locationForScope(
    OperatorAdminBundle bundle,
    AdminHierarchyScopeIntent scope,
  ) {
    final locationId = scope.locationId;
    if (locationId == null) return null;
    for (final location in bundle.locations) {
      if (location.locationId == locationId) return location;
    }
    return null;
  }
}

class _BusinessSetupCard extends StatelessWidget {
  const _BusinessSetupCard({
    required this.bundle,
    required this.selectedScope,
    required this.onSelectScope,
    required this.onOpenPeopleAccessRoles,
    required this.onOpenSecurityAuditSessions,
    required this.onOpenDataAccuracy,
    required this.onOpenPollingPricing,
    required this.onOpenSupportLogs,
    required this.onOpenIntegrations,
    required this.onOpenTiming,
  });

  final OperatorAdminBundle bundle;
  final AdminHierarchyScopeIntent selectedScope;
  final ValueChanged<AdminHierarchyScopeIntent> onSelectScope;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenPeopleAccessRoles;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenSecurityAuditSessions;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenDataAccuracy;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenPollingPricing;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenSupportLogs;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenIntegrations;
  final ValueChanged<AdminHierarchyScopeIntent>? onOpenTiming;

  VoidCallback? _scopedTileHandler(
    ValueChanged<AdminHierarchyScopeIntent>? onOpen, {
    AdminHierarchyScopeIntent? overrideScope,
  }) {
    if (onOpen == null) return null;
    return () {
      final scope = overrideScope ?? selectedScope;
      onSelectScope(scope);
      onOpen(scope);
    };
  }

  @override
  Widget build(BuildContext context) {
    final operator = bundle.operator;
    const operationsTone = AppColors.peacockDark;
    const peopleTone = AppColors.ocean;
    const safetyTone = AppColors.sunsetDark;
    return AdminCard(
      key: Key('admin_business_setup_${operator.operatorId}'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.checklist_rtl_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Business setup',
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                '${bundle.locations.length} location'
                '${bundle.locations.length == 1 ? '' : 's'}',
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            key: const Key('admin_business_setup_scope_summary'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.peacock.withValues(alpha: 0.08),
              border: Border.all(
                color: AppColors.peacock.withValues(alpha: 0.28),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Selected ${selectedScope.scopeType.label.toLowerCase()} scope',
                  style: AppTextStyles.uiLabel(color: AppColors.peacockDark),
                ),
                const SizedBox(height: 2),
                Text(
                  selectedScope.displayLabel,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SetupTileGroup(
            groupKey: const Key('admin_business_setup_group_operations'),
            label: 'Operations',
            tone: operationsTone,
            children: [
              _SetupTile(
                tileKey: const Key('admin_business_setup_tile_integrations'),
                label: 'Integrations',
                scopeLabel: _scopeLabel(locationRequired: true),
                icon: Icons.link_outlined,
                tone: operationsTone,
                onPressed: _scopedTileHandler(onOpenIntegrations),
              ),
              _SetupTile(
                tileKey: const Key('admin_business_setup_tile_data_accuracy'),
                label: 'Covers and Wage Data Accuracy',
                scopeLabel: _scopeLabel(),
                icon: Icons.fact_check_outlined,
                tone: operationsTone,
                onPressed: _scopedTileHandler(onOpenDataAccuracy),
              ),
              _SetupTile(
                tileKey: const Key('admin_business_setup_tile_polling_pricing'),
                label: 'Polling setup',
                scopeLabel: _scopeLabel(),
                icon: Icons.payments_outlined,
                tone: operationsTone,
                onPressed: _scopedTileHandler(onOpenPollingPricing),
              ),
              _SetupTile(
                tileKey: const Key('admin_business_setup_tile_timing'),
                label: 'Timing',
                scopeLabel: _scopeLabel(),
                icon: Icons.schedule_outlined,
                tone: operationsTone,
                onPressed: _scopedTileHandler(onOpenTiming),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SetupTileGroup(
            groupKey: const Key('admin_business_setup_group_people'),
            label: 'People',
            tone: peopleTone,
            children: [
              _SetupTile(
                tileKey: const Key(
                  'admin_business_setup_tile_people_access_roles',
                ),
                label: 'People, access, and roles',
                scopeLabel: _scopeLabel(),
                icon: Icons.people_alt_outlined,
                tone: peopleTone,
                onPressed: _scopedTileHandler(onOpenPeopleAccessRoles),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SetupTileGroup(
            groupKey: const Key('admin_business_setup_group_safety_support'),
            label: 'Safety/Support',
            tone: safetyTone,
            children: [
              _SetupTile(
                tileKey: const Key(
                  'admin_business_setup_tile_security_audit_sessions',
                ),
                label: 'Security, audit, and sessions',
                scopeLabel: _scopeLabel(),
                icon: Icons.security_outlined,
                tone: safetyTone,
                onPressed: _scopedTileHandler(onOpenSecurityAuditSessions),
              ),
              _SetupTile(
                tileKey: const Key('admin_business_setup_tile_support_logs'),
                label: 'Support logs',
                scopeLabel: _scopeLabel(),
                icon: Icons.support_agent_outlined,
                tone: safetyTone,
                onPressed: _scopedTileHandler(onOpenSupportLogs),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _scopeLabel({bool locationRequired = false}) {
    if (locationRequired && !selectedScope.isLocationScope) {
      return 'Select a location';
    }
    switch (selectedScope.scopeType) {
      case AdminHierarchyScopeType.business:
        return 'Business scope';
      case AdminHierarchyScopeType.orgUnit:
        return 'Org unit scope';
      case AdminHierarchyScopeType.location:
        return 'Location scope';
    }
  }
}

class _BusinessHierarchyPanel extends StatefulWidget {
  const _BusinessHierarchyPanel({
    required this.bundle,
    required this.gateway,
    required this.actorUserId,
    required this.idempotencyKeyFactory,
    required this.selectedScope,
    required this.onSelectScope,
    required this.onAddLocation,
    required this.addLocationEnabled,
    required this.onEditLocation,
    required this.onRemoveLocation,
    required this.onSetPrimary,
    required this.editingEnabled,
  });

  final OperatorAdminBundle bundle;
  final RolesHierarchySessionsAdminGateway? gateway;
  final String actorUserId;
  final String Function() idempotencyKeyFactory;
  final AdminHierarchyScopeIntent selectedScope;
  final ValueChanged<AdminHierarchyScopeIntent> onSelectScope;
  final VoidCallback? onAddLocation;
  final bool addLocationEnabled;
  final ValueChanged<LocationAdminRecord> onEditLocation;
  final ValueChanged<LocationAdminRecord> onRemoveLocation;
  final ValueChanged<LocationAdminRecord> onSetPrimary;
  final bool editingEnabled;

  @override
  State<_BusinessHierarchyPanel> createState() =>
      _BusinessHierarchyPanelState();
}

class _BusinessHierarchyPanelState extends State<_BusinessHierarchyPanel> {
  Future<_HierarchyPanelData>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _BusinessHierarchyPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundle.operator.operatorId !=
            widget.bundle.operator.operatorId ||
        oldWidget.gateway != widget.gateway) {
      _future = _load();
    }
  }

  Future<_HierarchyPanelData> _load() async {
    final gateway = widget.gateway;
    if (gateway == null) return _HierarchyPanelData.empty();
    final operatorId = widget.bundle.operator.operatorId;
    final results = await Future.wait<Object>([
      gateway.listOrgUnits(operatorId: operatorId),
      gateway.listHierarchyLocations(operatorId: operatorId),
    ]);
    return _HierarchyPanelData(
      orgUnits: results[0] as List<OrgUnitAdminNode>,
      locations: results[1] as List<HierarchyLocationLeaf>,
    );
  }

  Future<void> _onAddChildOrgUnit(OrgUnitAdminNode parent) async {
    final gateway = widget.gateway;
    if (!widget.editingEnabled || gateway == null) return;
    final data = await (_future ?? _load());
    final existingNames = <String>{
      for (final unit in data.orgUnits)
        if (unit.parentOrgUnitId == parent.orgUnitId) unit.name.toLowerCase(),
    };
    if (!mounted) return;
    final result = await showDialog<_AddOrgUnitResult>(
      context: context,
      builder: (_) =>
          _AddChildOrgUnitDialog(parent: parent, existingNames: existingNames),
    );
    if (result == null) return;
    try {
      await gateway.createOrgUnit(
        operatorId: widget.bundle.operator.operatorId,
        parentOrgUnitId: parent.orgUnitId,
        unitType: result.unitType,
        label: result.label,
        name: result.name,
        idempotencyKey: widget.idempotencyKeyFactory(),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      );
      if (!mounted) return;
      setState(() {
        _future = _load();
      });
      if (Scaffold.maybeOf(context) != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Added ${result.name}')));
      }
    } catch (error) {
      if (!mounted) return;
      if (Scaffold.maybeOf(context) != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add org unit: $error')),
        );
      }
    }
  }

  AdminHierarchyScopeIntent _businessScope() {
    return AdminHierarchyScopeIntent.business(
      operatorId: widget.bundle.operator.operatorId,
      operatorName: widget.bundle.operator.businessName,
      effectiveValueLabel: 'Business default',
      allowedActionsLabel: widget.editingEnabled ? 'Editable' : 'Read-only',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 250),
      child: AdminCard(
        key: const Key('admin_business_hierarchy_panel'),
        padding: const EdgeInsets.all(24),
        child: FutureBuilder<_HierarchyPanelData>(
          future: _future,
          builder: (context, snapshot) {
            final data = snapshot.data ?? _HierarchyPanelData.empty();
            final loading =
                snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Text(
                      'Location hierarchy',
                      style: AppTextStyles.sectionTitle(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (widget.editingEnabled)
                      Tooltip(
                        message: widget.addLocationEnabled
                            ? 'Add location'
                            : 'Select an org unit before adding a location',
                        child: OutlinedButton.icon(
                          key: const Key('admin_operator_add_location_button'),
                          onPressed: widget.addLocationEnabled
                              ? widget.onAddLocation
                              : null,
                          icon: const Icon(Icons.add, size: 14),
                          label: const Text('Add location'),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Select business, org-unit, or location scope before opening setup.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                if (widget.editingEnabled && !widget.addLocationEnabled) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Select an org unit before adding a location.',
                    key: const Key(
                      'admin_location_parent_org_unit_required_copy',
                    ),
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ],
                if (snapshot.hasError) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Hierarchy details are unavailable; showing known locations.',
                    key: const Key('admin_business_hierarchy_load_error'),
                    style: AppTextStyles.body13(color: AppColors.warning),
                  ),
                ],
                if (loading) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(
                    key: Key('admin_business_hierarchy_loading'),
                    minHeight: 2,
                    color: AppColors.sunsetDark,
                  ),
                ],
                const SizedBox(height: 16),
                _HierarchyScopeRow(
                  key: const Key('admin_hierarchy_business_scope_row'),
                  icon: Icons.business_outlined,
                  label: widget.bundle.operator.businessName,
                  subtitle: 'Business scope',
                  selected:
                      widget.selectedScope.scopeType ==
                      AdminHierarchyScopeType.business,
                  onTap: () => widget.onSelectScope(_businessScope()),
                ),
                const SizedBox(height: 8),
                ..._buildTreeRows(data),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildTreeRows(_HierarchyPanelData data) {
    final unitsByParent = <String?, List<OrgUnitAdminNode>>{};
    final unitNames = <String, String>{};
    for (final unit in data.orgUnits) {
      unitNames[unit.orgUnitId] = unit.name;
      unitsByParent
          .putIfAbsent(unit.parentOrgUnitId, () => <OrgUnitAdminNode>[])
          .add(unit);
    }
    for (final list in unitsByParent.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }

    final leafParentByLocation = <String, String>{};
    for (final leaf in data.locations) {
      leafParentByLocation[leaf.locationId] = leaf.orgUnitId;
    }
    final locationsByParent = <String?, List<LocationAdminRecord>>{};
    for (final location in widget.bundle.locations) {
      final parentFromData =
          location.parentOrgUnitId ?? leafParentByLocation[location.locationId];
      final parent = unitNames.containsKey(parentFromData)
          ? parentFromData
          : null;
      locationsByParent
          .putIfAbsent(parent, () => <LocationAdminRecord>[])
          .add(location);
    }
    for (final list in locationsByParent.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }

    final rows = <Widget>[];
    final rootUnits = unitsByParent[null] ?? const <OrgUnitAdminNode>[];
    if (rootUnits.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: Text(
            'No org units yet for this business.',
            key: const Key('admin_business_hierarchy_no_org_units'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    for (final unit in rootUnits) {
      rows.addAll(
        _buildOrgUnitRows(
          unit: unit,
          depth: 0,
          unitsByParent: unitsByParent,
          unitNames: unitNames,
          locationsByParent: locationsByParent,
          path: const <String>[],
        ),
      );
    }
    final unassigned = locationsByParent[null] ?? const <LocationAdminRecord>[];
    for (final location in unassigned) {
      rows.add(_buildLocationRow(location: location, depth: 0));
    }
    if (rows.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'No locations yet.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return rows;
  }

  List<Widget> _buildOrgUnitRows({
    required OrgUnitAdminNode unit,
    required int depth,
    required Map<String?, List<OrgUnitAdminNode>> unitsByParent,
    required Map<String, String> unitNames,
    required Map<String?, List<LocationAdminRecord>> locationsByParent,
    required List<String> path,
  }) {
    final nextPath = _appendHierarchyPath(path, unit.name);
    final rows = <Widget>[
      _HierarchyScopeRow(
        key: Key('admin_hierarchy_org_unit_${unit.orgUnitId}'),
        icon: Icons.account_tree_outlined,
        label: unit.name,
        subtitle: depth == 0 ? 'Org unit' : 'Org unit branch',
        depth: depth,
        selected:
            widget.selectedScope.scopeType == AdminHierarchyScopeType.orgUnit &&
            widget.selectedScope.orgUnitId == unit.orgUnitId,
        onTap: () => widget.onSelectScope(
          AdminHierarchyScopeIntent.orgUnit(
            operatorId: widget.bundle.operator.operatorId,
            operatorName: widget.bundle.operator.businessName,
            orgUnitId: unit.orgUnitId,
            orgUnitName: unit.name,
            hierarchyPath: path,
            effectiveValueLabel: 'Branch default',
            allowedActionsLabel: widget.editingEnabled
                ? 'Editable'
                : 'Read-only',
          ),
        ),
        trailing: widget.editingEnabled && widget.gateway != null
            ? OutlinedButton.icon(
                key: Key(
                  'admin_hierarchy_org_unit_add_child_${unit.orgUnitId}',
                ),
                onPressed: () => _onAddChildOrgUnit(unit),
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Add child'),
              )
            : null,
      ),
    ];
    final locations =
        locationsByParent[unit.orgUnitId] ?? const <LocationAdminRecord>[];
    for (final location in locations) {
      rows.add(
        _buildLocationRow(
          location: location,
          depth: depth + 1,
          orgUnitId: unit.orgUnitId,
          orgUnitName: unitNames[unit.orgUnitId] ?? unit.name,
          path: nextPath,
        ),
      );
    }
    final children =
        unitsByParent[unit.orgUnitId] ?? const <OrgUnitAdminNode>[];
    for (final child in children) {
      rows.addAll(
        _buildOrgUnitRows(
          unit: child,
          depth: depth + 1,
          unitsByParent: unitsByParent,
          unitNames: unitNames,
          locationsByParent: locationsByParent,
          path: nextPath,
        ),
      );
    }
    return rows;
  }

  List<String> _appendHierarchyPath(List<String> path, String nextLabel) {
    final businessName = widget.bundle.operator.businessName;
    final next = <String>[
      for (final label in path)
        if (label != businessName && label.trim().isNotEmpty) label,
    ];
    if (nextLabel != businessName && !next.contains(nextLabel)) {
      next.add(nextLabel);
    }
    return next;
  }

  Widget _buildLocationRow({
    required LocationAdminRecord location,
    required int depth,
    String? orgUnitId,
    String? orgUnitName,
    List<String> path = const <String>[],
  }) {
    final isPrimary =
        widget.bundle.operator.primaryLocationId == location.locationId;
    return Opacity(
      key: Key('admin_location_suspended_fade_${location.locationId}'),
      opacity: widget.bundle.operator.isSuspended ? 0.55 : 1,
      child: _HierarchyScopeRow(
        key: Key('admin_hierarchy_location_${location.locationId}'),
        icon: Icons.storefront_outlined,
        label: location.name,
        subtitle: isPrimary ? 'Primary location' : 'Location',
        depth: depth,
        selected:
            widget.selectedScope.scopeType ==
                AdminHierarchyScopeType.location &&
            widget.selectedScope.locationId == location.locationId,
        onTap: () => widget.onSelectScope(
          AdminHierarchyScopeIntent.location(
            operatorId: widget.bundle.operator.operatorId,
            operatorName: widget.bundle.operator.businessName,
            orgUnitId: orgUnitId,
            orgUnitName: orgUnitName,
            locationId: location.locationId,
            locationName: location.name,
            hierarchyPath: path,
            valueState: AdminHierarchyScopeValueState.locationOnly,
            effectiveValueLabel: location.timezone,
            allowedActionsLabel: widget.editingEnabled
                ? 'Location controls'
                : 'Read-only',
          ),
        ),
        trailing: widget.editingEnabled
            ? Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  IconButton(
                    key: Key('admin_location_edit_${location.locationId}'),
                    tooltip: 'Edit location',
                    onPressed: () => widget.onEditLocation(location),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                  IconButton(
                    key: Key(
                      'admin_location_make_primary_${location.locationId}',
                    ),
                    tooltip: 'Make primary location',
                    onPressed: isPrimary
                        ? null
                        : () => widget.onSetPrimary(location),
                    icon: const Icon(Icons.star_outline, size: 18),
                  ),
                  IconButton(
                    key: Key('admin_location_remove_${location.locationId}'),
                    tooltip: 'Remove location',
                    onPressed: isPrimary
                        ? null
                        : () => widget.onRemoveLocation(location),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    color: AppColors.negative,
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

class _AddOrgUnitResult {
  const _AddOrgUnitResult({
    required this.unitType,
    required this.label,
    required this.name,
    required this.adminReason,
  });

  final String unitType;
  final String label;
  final String name;
  final String adminReason;
}

class _AddChildOrgUnitDialog extends StatefulWidget {
  const _AddChildOrgUnitDialog({
    required this.parent,
    required this.existingNames,
  });

  final OrgUnitAdminNode parent;
  final Set<String> existingNames;

  @override
  State<_AddChildOrgUnitDialog> createState() => _AddChildOrgUnitDialogState();
}

class _AddChildOrgUnitDialogState extends State<_AddChildOrgUnitDialog> {
  String _unitType = 'region';
  final _nameController = TextEditingController();
  final _labelController = TextEditingController();
  final _reasonController = TextEditingController();
  String? _nameError;
  String? _labelError;
  String? _reasonError;

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final name = _nameController.text.trim();
    final rawLabel = _labelController.text.trim();
    final label = rawLabel.isEmpty ? _sanitiseLabel(name) : rawLabel;
    final reason = _reasonController.text.trim();
    setState(() {
      _nameError = name.isEmpty
          ? 'Org unit name is required.'
          : widget.existingNames.contains(name.toLowerCase())
          ? 'A sibling org unit already uses this name.'
          : null;
      _labelError = label.isEmpty || !RegExp(r'^[a-z0-9_]+$').hasMatch(label)
          ? 'Use lowercase letters, numbers, and underscores.'
          : null;
      _reasonError = reason.isEmpty ? 'Add a reason before continuing.' : null;
    });
    if (_nameError != null || _labelError != null || _reasonError != null) {
      return;
    }
    Navigator.of(context).pop(
      _AddOrgUnitResult(
        unitType: _unitType,
        label: label,
        name: name,
        adminReason: reason,
      ),
    );
  }

  static String _sanitiseLabel(String name) {
    final collapsed = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_hierarchy_add_child_org_unit_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Add child org unit',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Under ${widget.parent.name}',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('admin_hierarchy_add_org_unit_type'),
              initialValue: _unitType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Unit type',
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(
                  value: 'region',
                  child: Text('Region'),
                ),
                DropdownMenuItem<String>(
                  value: 'district',
                  child: Text('District'),
                ),
                DropdownMenuItem<String>(
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
              key: const Key('admin_hierarchy_add_org_unit_name'),
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Display name',
                border: const OutlineInputBorder(),
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_hierarchy_add_org_unit_label'),
              controller: _labelController,
              decoration: InputDecoration(
                labelText: 'Label (a-z, 0-9, underscore)',
                border: const OutlineInputBorder(),
                errorText: _labelError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_hierarchy_add_org_unit_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _reasonError,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_hierarchy_add_org_unit_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_hierarchy_add_org_unit_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _HierarchyPanelData {
  const _HierarchyPanelData({required this.orgUnits, required this.locations});

  const _HierarchyPanelData.empty()
    : orgUnits = const <OrgUnitAdminNode>[],
      locations = const <HierarchyLocationLeaf>[];

  final List<OrgUnitAdminNode> orgUnits;
  final List<HierarchyLocationLeaf> locations;
}

class _HierarchyScopeRow extends StatelessWidget {
  const _HierarchyScopeRow({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.depth = 0,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final int depth;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, top: 6, bottom: 6),
      child: Material(
        color: selected
            ? AppColors.peacock.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? AppColors.peacock : AppColors.borderSubtle,
                width: selected ? 1.4 : 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(icon, size: 17, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.body14(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono11(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.check_circle,
                      size: 16,
                      color: AppColors.peacockDark,
                    ),
                  ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupTileGroup extends StatelessWidget {
  const _SetupTileGroup({
    required this.groupKey,
    required this.label,
    required this.tone,
    required this.children,
  });

  final Key groupKey;
  final String label;
  final Color tone;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: groupKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.uiLabel(color: tone)),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: children),
      ],
    );
  }
}

class _SetupTile extends StatelessWidget {
  const _SetupTile({
    required this.tileKey,
    required this.label,
    required this.scopeLabel,
    required this.icon,
    required this.tone,
    this.onPressed,
  });

  final Key tileKey;
  final String label;
  final String scopeLabel;
  final IconData icon;
  final Color tone;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      key: tileKey,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: '$label, $scopeLabel',
        child: SizedBox(
          width: 232,
          height: 120,
          child: Material(
            color: enabled
                ? tone.withValues(alpha: 0.1)
                : AppColors.backgroundMid.withValues(alpha: 0.65),
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: enabled
                    ? tone.withValues(alpha: 0.5)
                    : AppColors.borderSubtle,
                width: enabled ? 1.2 : 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              hoverColor: tone.withValues(alpha: 0.08),
              splashColor: tone.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          icon,
                          size: 18,
                          color: enabled ? tone : AppColors.textMuted,
                        ),
                        const Spacer(),
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: enabled ? tone : AppColors.textMuted,
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body14(
                        color: enabled
                            ? AppColors.textPrimary
                            : AppColors.textMuted,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      scopeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body12(
                        color: enabled
                            ? AppColors.textSecondary
                            : AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OperatorActionButton extends StatelessWidget {
  const _OperatorActionButton({
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.destructive = false,
  });

  final Key buttonKey;
  final String label;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        style: destructive
            ? AdminButtonStyles.dangerSecondary()
            : AdminButtonStyles.secondary(),
        icon: Icon(icon, size: 14),
        label: Text(label, overflow: TextOverflow.ellipsis, softWrap: false),
      ),
    );
  }
}

// Retained for the older per-location row tests until the hierarchy IA
// fully replaces those expectations.
// ignore: unused_element
class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.operatorName,
    required this.location,
    required this.muted,
    required this.isPrimary,
    required this.onEdit,
    required this.onRemove,
    required this.onMakePrimary,
    required this.onOpenSupportLogs,
    required this.onOpenDataAccuracy,
    required this.onOpenPollingPricing,
    required this.onOpenSupportOperatorView,
    required this.onOpenTeam,
    required this.onOpenAccess,
    required this.onOpenAuditSupport,
    required this.editingEnabled,
  });

  final String operatorName;
  final LocationAdminRecord location;
  final bool muted;
  final bool isPrimary;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onMakePrimary;
  final VoidCallback? onOpenSupportLogs;
  final VoidCallback? onOpenDataAccuracy;
  final VoidCallback? onOpenPollingPricing;
  final VoidCallback? onOpenSupportOperatorView;
  final VoidCallback? onOpenTeam;
  final VoidCallback? onOpenAccess;
  final VoidCallback? onOpenAuditSupport;
  final bool editingEnabled;

  @override
  Widget build(BuildContext context) {
    final rolloverHour = location.businessDayRolloverHour ?? 0;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              location.name,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
            if (isPrimary)
              _StatusPill(label: 'primary location', color: AppColors.peacock),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${location.timezone} - business day starts ${rolloverHour.toString().padLeft(2, '0')}:00',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final actions = _LocationActionWrap(
      operatorName: operatorName,
      location: location,
      isPrimary: isPrimary,
      onEdit: onEdit,
      onRemove: onRemove,
      onMakePrimary: onMakePrimary,
      onOpenSupportLogs: onOpenSupportLogs,
      onOpenDataAccuracy: onOpenDataAccuracy,
      onOpenPollingPricing: onOpenPollingPricing,
      onOpenSupportOperatorView: onOpenSupportOperatorView,
      onOpenTeam: onOpenTeam,
      onOpenAccess: onOpenAccess,
      onOpenAuditSupport: onOpenAuditSupport,
      editingEnabled: editingEnabled,
    );

    return Opacity(
      key: Key('admin_location_suspended_fade_${location.locationId}'),
      opacity: muted ? 0.52 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 620) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [summary, const SizedBox(height: 10), actions],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: summary),
                const SizedBox(width: 18),
                Flexible(child: actions),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LocationActionWrap extends StatelessWidget {
  const _LocationActionWrap({
    required this.operatorName,
    required this.location,
    required this.isPrimary,
    required this.onEdit,
    required this.onRemove,
    required this.onMakePrimary,
    required this.onOpenSupportLogs,
    required this.onOpenDataAccuracy,
    required this.onOpenPollingPricing,
    required this.onOpenSupportOperatorView,
    required this.onOpenTeam,
    required this.onOpenAccess,
    required this.onOpenAuditSupport,
    required this.editingEnabled,
  });

  final String operatorName;
  final LocationAdminRecord location;
  final bool isPrimary;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onMakePrimary;
  final VoidCallback? onOpenSupportLogs;
  final VoidCallback? onOpenDataAccuracy;
  final VoidCallback? onOpenPollingPricing;
  final VoidCallback? onOpenSupportOperatorView;
  final VoidCallback? onOpenTeam;
  final VoidCallback? onOpenAccess;
  final VoidCallback? onOpenAuditSupport;
  final bool editingEnabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _ActionRowWrap(
          children: [
            _LocationActionButton(
              buttonKey: Key(
                'admin_location_support_view_${location.locationId}',
              ),
              label: 'Support view',
              icon: Icons.support_agent_outlined,
              tooltip: 'Open the support workspace for this location scope',
              minWidth: 132,
              onPressed: onOpenSupportOperatorView,
            ),
            _LocationActionButton(
              buttonKey: Key('admin_location_team_${location.locationId}'),
              label: 'People',
              icon: Icons.people_alt_outlined,
              tooltip: 'Open people for this location scope',
              minWidth: 104,
              onPressed: onOpenTeam,
            ),
            _LocationActionButton(
              buttonKey: Key('admin_location_access_${location.locationId}'),
              label: 'Access',
              icon: Icons.account_tree_outlined,
              tooltip: 'Open access and hierarchy for this location scope',
              minWidth: 108,
              onPressed: onOpenAccess,
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ActionRowWrap(
          children: [
            if (editingEnabled)
              _LocationActionButton(
                buttonKey: Key('admin_location_edit_${location.locationId}'),
                label: 'Edit',
                icon: Icons.edit_outlined,
                tooltip: 'Edit location',
                minWidth: 90,
                onPressed: onEdit,
              ),
            if (editingEnabled && !isPrimary)
              _LocationActionButton(
                buttonKey: Key(
                  'admin_location_make_primary_${location.locationId}',
                ),
                label: 'Make primary',
                icon: Icons.star_outline,
                tooltip: 'Make primary location',
                minWidth: 132,
                onPressed: onMakePrimary,
              ),
            if (editingEnabled)
              _LocationActionButton(
                buttonKey: Key('admin_location_remove_${location.locationId}'),
                label: 'Remove',
                icon: Icons.delete_outline,
                tooltip: 'Remove location',
                minWidth: 108,
                destructive: true,
                onPressed: isPrimary ? null : onRemove,
              ),
          ],
        ),
        const SizedBox(height: 8),
        _ActionRowWrap(
          children: [
            _LocationActionButton(
              buttonKey: Key('admin_location_timing_${location.locationId}'),
              label: 'Timing',
              icon: Icons.schedule_outlined,
              tooltip: 'View timing for this location',
              minWidth: 108,
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => _AdminLocationTimingDialog(
                    operatorName: operatorName,
                    selectedScope: AdminHierarchyScopeIntent.location(
                      operatorId: location.operatorId,
                      locationId: location.locationId,
                      operatorName: operatorName,
                      orgUnitId: location.parentOrgUnitId,
                      locationName: location.name,
                    ),
                    timingLocation: location,
                    editingEnabled: editingEnabled,
                  ),
                );
              },
            ),
            _LocationActionButton(
              buttonKey: Key(
                'admin_location_data_accuracy_${location.locationId}',
              ),
              label: 'Covers and wage',
              icon: Icons.fact_check_outlined,
              tooltip: 'View covers and wage data for this location',
              minWidth: 136,
              onPressed: onOpenDataAccuracy,
            ),
            _LocationActionButton(
              buttonKey: Key(
                'admin_location_polling_pricing_${location.locationId}',
              ),
              label: 'Polling setup',
              icon: Icons.payments_outlined,
              tooltip: 'View polling setup for this location',
              minWidth: 148,
              onPressed: onOpenPollingPricing,
            ),
            _LocationActionButton(
              buttonKey: Key(
                'admin_location_audit_support_${location.locationId}',
              ),
              label: 'Security',
              icon: Icons.security_outlined,
              tooltip: 'Open security and audit for this location scope',
              minWidth: 112,
              onPressed: onOpenAuditSupport,
            ),
            _LocationActionButton(
              buttonKey: Key(
                'admin_location_support_logs_${location.locationId}',
              ),
              label: 'View logs',
              icon: Icons.bug_report_outlined,
              tooltip: 'View logs for this location',
              minWidth: 116,
              onPressed: onOpenSupportLogs,
            ),
            Builder(
              builder: (subContext) => _LocationActionButton(
                buttonKey: Key(
                  'admin_location_vendor_connections_${location.locationId}',
                ),
                label: 'Integrations',
                icon: Icons.link,
                tooltip: 'Manage integrations',
                minWidth: 128,
                emphasized: true,
                onPressed: () {
                  Navigator.of(subContext).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(
                        name: '/vendor-connections',
                      ),
                      builder: (_) => VendorConnectionsAdminMount(
                        operatorId: location.operatorId,
                        locationId: location.locationId,
                        locationName: location.name,
                        canMutate: editingEnabled,
                        onBackToBusinessAccounts: () =>
                            Navigator.of(subContext).maybePop(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ActionRowWrap extends StatelessWidget {
  const _ActionRowWrap({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

class _AdminLocationTimingDialog extends StatelessWidget {
  const _AdminLocationTimingDialog({
    required this.operatorName,
    required this.selectedScope,
    required this.timingLocation,
    required this.editingEnabled,
  });

  final String operatorName;
  final AdminHierarchyScopeIntent selectedScope;
  final LocationAdminRecord? timingLocation;
  final bool editingEnabled;

  @override
  Widget build(BuildContext context) {
    final resolution = _AdminTimingResolution.forScope(
      operatorName: operatorName,
      selectedScope: selectedScope,
      timingLocation: timingLocation,
    );
    final effective = resolution.effective;
    return AlertDialog(
      key: const Key('admin_location_timing_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Timing',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdminHierarchyScopeBanner(
                scope: resolution.bannerScope,
                surfaceName: 'timing',
                onChangeScope: () {},
              ),
              const SizedBox(height: 10),
              _TimingDialogRow(label: 'Scope', value: resolution.scopeLabel),
              if (effective == null) ...[
                Text(
                  'Timing cannot resolve without at least one location timezone. Add a location with an IANA timezone before reviewing effective timing.',
                  key: const Key('admin_timing_unavailable_copy'),
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ] else ...[
                _TimingDialogRow(
                  label: 'Effective timezone',
                  value: effective.businessTimezone,
                ),
                _TimingDialogRow(
                  label: 'Timezone source',
                  value: resolution.timezoneSource,
                ),
                _TimingDialogRow(
                  label: 'Business day starts',
                  value: effective.businessDayStartLocalTime,
                ),
                _TimingDialogRow(
                  label: 'Day-start source',
                  value: resolution.dayStartSource,
                ),
                _TimingDialogRow(
                  label: 'Week starts',
                  value: _weekdayLabel(effective.weekStartDay),
                ),
                _TimingDialogRow(
                  label: 'Shift close authority',
                  value: _shiftCloseAuthorityLabel(
                    effective.shiftCloseAuthority,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (effective != null)
                Container(
                  key: const Key('admin_timing_service_periods_panel'),
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
                        'Effective service periods',
                        style: AppTextStyles.mono11(
                          color: AppColors.sunsetDark,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final period
                          in effective.servicePeriodDefinitions.toList()..sort(
                            (a, b) => a.sortOrder.compareTo(b.sortOrder),
                          ))
                        _TimingPeriodLine(
                          name: period.label,
                          range:
                              '${period.startLocalTime} - ${period.endLocalTime}',
                          source: resolution.servicePeriodSource,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                editingEnabled
                    ? 'Override controls are staged for audited support use, '
                          'but this dialog has no backend write path. No timing '
                          'change was written.'
                    : 'Read-only support view. Timing overrides require an '
                          'audited admin write path before this dialog can '
                          'change anything.',
                key: const Key('admin_location_timing_safe_copy'),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              if (editingEnabled) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('admin_location_timing_audit_reason'),
                  enabled: false,
                  decoration: InputDecoration(
                    labelText: 'Audit reason',
                    labelStyle: AppTextStyles.uiLabel(
                      color: AppColors.textMuted,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(
                        color: AppColors.borderSubtle,
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (editingEnabled)
          OutlinedButton.icon(
            key: const Key('admin_location_timing_save_disabled'),
            onPressed: null,
            icon: const Icon(Icons.save_outlined, size: 15),
            label: const Text('Save override'),
          ),
        TextButton(
          key: const Key('admin_location_timing_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _AdminTimingResolution {
  const _AdminTimingResolution({
    required this.bannerScope,
    required this.scopeLabel,
    required this.effective,
    required this.timezoneSource,
    required this.dayStartSource,
    required this.servicePeriodSource,
  });

  final AdminHierarchyScopeIntent bannerScope;
  final String scopeLabel;
  final EffectiveBusinessTimingProfile? effective;
  final String timezoneSource;
  final String dayStartSource;
  final String servicePeriodSource;

  static _AdminTimingResolution forScope({
    required String operatorName,
    required AdminHierarchyScopeIntent selectedScope,
    required LocationAdminRecord? timingLocation,
  }) {
    final effectiveScope = _timingBannerScope(selectedScope);
    final scopeLabel = selectedScope.isLocationScope && timingLocation != null
        ? '$operatorName / ${timingLocation.name}'
        : selectedScope.displayLabel;
    if (timingLocation == null) {
      return _AdminTimingResolution(
        bannerScope: effectiveScope,
        scopeLabel: scopeLabel,
        effective: null,
        timezoneSource: 'Unavailable',
        dayStartSource: 'Unavailable',
        servicePeriodSource: 'Unavailable',
      );
    }

    final businessProfile = BusinessTimingProfile(
      profileId: 'admin-${selectedScope.operatorId}-business-default',
      scope: BusinessTimingScope.operatorDefault,
      scopeId: selectedScope.operatorId,
      businessTimezone: timingLocation.timezone,
      businessDayStartLocalTime: _rolloverToLocalTime(
        timingLocation.businessDayRolloverHour,
      ),
      weekStartDay: DateTime.monday,
      servicePeriodDefinitions: _defaultAdminTimingServicePeriods,
      shiftCloseAuthority: ShiftCloseAuthority.appLocalCutoffFallback,
      localCloseFallback: _rolloverToLocalTime(
        timingLocation.businessDayRolloverHour,
      ),
    );
    final candidates = <BusinessTimingProfile>[businessProfile];

    if (selectedScope.isOrgUnitScope) {
      candidates.add(
        BusinessTimingProfile(
          profileId: 'admin-${selectedScope.orgUnitId}-org-unit',
          scope: BusinessTimingScope.orgUnit,
          scopeId: selectedScope.orgUnitId ?? selectedScope.operatorId,
        ),
      );
    }
    if (selectedScope.isLocationScope) {
      candidates.add(
        BusinessTimingProfile(
          profileId: 'admin-${timingLocation.locationId}-location',
          scope: BusinessTimingScope.location,
          scopeId: timingLocation.locationId,
          businessTimezone: timingLocation.timezone,
          businessDayStartLocalTime: _rolloverToLocalTime(
            timingLocation.businessDayRolloverHour,
          ),
        ),
      );
    }

    final effective = BusinessTimingProfileResolver.resolve(candidates);
    return _AdminTimingResolution(
      bannerScope: effectiveScope,
      scopeLabel: scopeLabel,
      effective: effective,
      timezoneSource: selectedScope.isOrgUnitScope
          ? 'Inherited from business'
          : 'Set at this scope',
      dayStartSource: selectedScope.isOrgUnitScope
          ? 'Inherited from business'
          : 'Set at this scope',
      servicePeriodSource: selectedScope.isBusinessScope
          ? 'Set at this scope'
          : 'Inherited from business',
    );
  }

  static AdminHierarchyScopeIntent _timingBannerScope(
    AdminHierarchyScopeIntent scope,
  ) {
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return AdminHierarchyScopeIntent.business(
          operatorId: scope.operatorId,
          operatorName: scope.operatorName,
          valueState: AdminHierarchyScopeValueState.setAtScope,
          effectiveValueLabel: 'Business timing default',
          allowedActionsLabel: 'Read-only until write route exists',
        );
      case AdminHierarchyScopeType.orgUnit:
        return AdminHierarchyScopeIntent.orgUnit(
          operatorId: scope.operatorId,
          orgUnitId: scope.orgUnitId!,
          operatorName: scope.operatorName,
          orgUnitName: scope.orgUnitName,
          hierarchyPath: scope.hierarchyPath,
          valueState: AdminHierarchyScopeValueState.inheritedFromBusiness,
          inheritedFromLabel: 'business',
          effectiveValueLabel: 'Inherited timing',
          allowedActionsLabel: 'Read-only until write route exists',
        );
      case AdminHierarchyScopeType.location:
        return AdminHierarchyScopeIntent.location(
          operatorId: scope.operatorId,
          locationId: scope.locationId!,
          operatorName: scope.operatorName,
          orgUnitId: scope.orgUnitId,
          orgUnitName: scope.orgUnitName,
          locationName: scope.locationName,
          hierarchyPath: scope.hierarchyPath,
          valueState: AdminHierarchyScopeValueState.locationOnly,
          effectiveValueLabel: 'Location timezone and day start',
          allowedActionsLabel: 'Read-only until write route exists',
        );
    }
  }
}

const List<ServicePeriodDefinition> _defaultAdminTimingServicePeriods =
    <ServicePeriodDefinition>[
      ServicePeriodDefinition(
        id: 'lunch',
        label: 'Lunch',
        shortLabel: 'L',
        sortOrder: 10,
        startLocalTime: '11:00',
        endLocalTime: '15:00',
        rollsPastMidnight: false,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'dinner',
        label: 'Dinner',
        shortLabel: 'D',
        sortOrder: 20,
        startLocalTime: '17:00',
        endLocalTime: '22:00',
        rollsPastMidnight: false,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      ),
      ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late night',
        shortLabel: 'LN',
        sortOrder: 30,
        startLocalTime: '22:00',
        endLocalTime: '01:00',
        rollsPastMidnight: true,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      ),
    ];

String _rolloverToLocalTime(int? rolloverHour) {
  final normalized = rolloverHour == null ? 0 : rolloverHour.clamp(0, 23);
  return '${normalized.toString().padLeft(2, '0')}:00';
}

String _weekdayLabel(int weekStartDay) {
  return switch (weekStartDay) {
    DateTime.monday => 'Monday',
    DateTime.tuesday => 'Tuesday',
    DateTime.wednesday => 'Wednesday',
    DateTime.thursday => 'Thursday',
    DateTime.friday => 'Friday',
    DateTime.saturday => 'Saturday',
    DateTime.sunday => 'Sunday',
    _ => 'Unknown',
  };
}

String _shiftCloseAuthorityLabel(ShiftCloseAuthority authority) {
  return switch (authority) {
    ShiftCloseAuthority.vendorFinalization => 'Vendor finalization',
    ShiftCloseAuthority.appLocalCutoffFallback => 'App local cutoff fallback',
  };
}

class _TimingDialogRow extends StatelessWidget {
  const _TimingDialogRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimingPeriodLine extends StatelessWidget {
  const _TimingPeriodLine({
    required this.name,
    required this.range,
    required this.source,
  });

  final String name;
  final String range;
  final String source;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
          Text(
            range,
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
          const SizedBox(width: 10),
          Text(source, style: AppTextStyles.mono8(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _LocationActionButton extends StatelessWidget {
  const _LocationActionButton({
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.minWidth,
    required this.onPressed,
    this.emphasized = false,
    this.destructive = false,
  });

  final Key buttonKey;
  final String label;
  final IconData icon;
  final String tooltip;
  final double minWidth;
  final VoidCallback? onPressed;
  final bool emphasized;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final activeColor = destructive
        ? AppColors.negative
        : emphasized
        ? AppColors.sunsetDark
        : AppColors.textPrimary;
    final borderColor = enabled
        ? (destructive
              ? AppColors.negative
              : emphasized
              ? AppColors.sunset
              : AppColors.borderSubtle)
        : AppColors.borderSubtle;

    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        style: AdminButtonStyles.secondary(
          foregroundColor: activeColor,
          borderColor: borderColor,
          minWidth: minWidth,
          emphasized: emphasized,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        icon: Icon(icon, size: 15),
        label: Text(label, overflow: TextOverflow.ellipsis, softWrap: false),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: AppTextStyles.chipLabel(color: color)),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_operators_readonly_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.34),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.visibility_outlined,
            size: 16,
            color: AppColors.peacockDark,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Support access is read-only. Operator, location, and vendor connection changes are hidden for this role.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    super.key,
    required this.message,
    this.emailConflicts = const <AdminEmailConflictUsage>[],
    this.onShowConflict,
  });

  final String message;
  final List<AdminEmailConflictUsage> emailConflicts;
  final ValueChanged<AdminEmailConflictUsage>? onShowConflict;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
                if (emailConflicts.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Where this email is used',
                    style: AppTextStyles.uiLabel(color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 6),
                  for (final usage in emailConflicts)
                    _OperatorEmailConflictTile(
                      usage: usage,
                      onShowConflict: onShowConflict,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OperatorEmailConflictTile extends StatelessWidget {
  const _OperatorEmailConflictTile({
    required this.usage,
    required this.onShowConflict,
  });

  final AdminEmailConflictUsage usage;
  final ValueChanged<AdminEmailConflictUsage>? onShowConflict;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      usage.sourceLabel,
      if (usage.roleLabel != null) usage.roleLabel!,
      if (usage.status != null) usage.status!,
    ].join(' | ');
    final canOpen = usage.operatorId != null && onShowConflict != null;
    return Container(
      key: Key('admin_operators_email_conflict_${usage.email}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.manage_search, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  usage.scopeLabel,
                  style: AppTextStyles.body13(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  details,
                  style: AppTextStyles.mono11(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          if (canOpen) ...[
            const SizedBox(width: 8),
            TextButton(
              key: Key('admin_operators_email_conflict_open_${usage.email}'),
              onPressed: () => onShowConflict!(usage),
              child: const Text('Open operator'),
            ),
          ],
        ],
      ),
    );
  }
}

class _OnboardOperatorDialog extends StatefulWidget {
  const _OnboardOperatorDialog({required this.idempotencyKey});

  /// Per-action idempotency key minted by the screen and threaded
  /// down so the proxy dedups on retries - see `_nextIdempotencyKey`
  /// in `_OperatorLocationAdminScreenState`.
  final String idempotencyKey;

  @override
  State<_OnboardOperatorDialog> createState() => _OnboardOperatorDialogState();
}

class _OnboardOperatorDialogState extends State<_OnboardOperatorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _businessName = TextEditingController();
  final _ownerEmail = TextEditingController();
  final _adminEmail = TextEditingController();
  final _locationName = TextEditingController();
  String _locationTimezone = 'America/Toronto';
  final String _subscriptionTier = 'launch';
  String _preferredCurrency = 'CAD';
  int _rolloverHour = 4;

  @override
  void dispose() {
    _businessName.dispose();
    _ownerEmail.dispose();
    _adminEmail.dispose();
    _locationName.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      OperatorOnboardCommand(
        businessName: _businessName.text.trim(),
        ownerEmail: _ownerEmail.text.trim(),
        subscriptionTier: _subscriptionTier,
        preferredCurrency: _preferredCurrency,
        primaryLocationName: _locationName.text.trim(),
        primaryLocationTimezone: _locationTimezone,
        primaryLocationRolloverHour: _rolloverHour,
        adminUserEmail: _adminEmail.text.trim(),
        idempotencyKey: widget.idempotencyKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_onboard_operator_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'New operator',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DialogField(
                  fieldKey: const Key('admin_onboard_business_name'),
                  controller: _businessName,
                  label: 'Business name',
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _DialogField(
                  fieldKey: const Key('admin_onboard_owner_email'),
                  controller: _ownerEmail,
                  label: 'Contact email',
                  helperText:
                      'Business contact for records. This does not create console access.',
                  keyboardType: TextInputType.emailAddress,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _DialogField(
                  fieldKey: const Key('admin_onboard_admin_email'),
                  controller: _adminEmail,
                  label: 'Owner login email',
                  helperText:
                      'Invite is sent here. This is the person who signs in.',
                  keyboardType: TextInputType.emailAddress,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _SubscriptionTierDropdown(value: _subscriptionTier),
                const SizedBox(height: 12),
                _CurrencyDropdown(
                  value: _preferredCurrency,
                  onChanged: (v) => setState(() => _preferredCurrency = v),
                ),
                const SizedBox(height: 16),
                Text(
                  'Primary location',
                  style: AppTextStyles.uiLabel(color: AppColors.textMuted),
                ),
                const SizedBox(height: 6),
                _DialogField(
                  fieldKey: const Key('admin_onboard_location_name'),
                  controller: _locationName,
                  label: 'Location name',
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _TimezoneDropdown(
                  fieldKey: const Key('admin_onboard_location_timezone'),
                  value: _locationTimezone,
                  onChanged: (v) => setState(() => _locationTimezone = v),
                ),
                const SizedBox(height: 12),
                _RolloverHourDropdown(
                  value: _rolloverHour,
                  onChanged: (v) => setState(() => _rolloverHour = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_onboard_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_onboard_submit_button'),
          onPressed: _submit,
          style: AdminButtonStyles.primary,
          child: const Text('Onboard operator'),
        ),
      ],
    );
  }
}

class _EditOperatorDialog extends StatefulWidget {
  const _EditOperatorDialog({
    required this.bundle,
    required this.idempotencyKey,
  });

  final OperatorAdminBundle bundle;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

  @override
  State<_EditOperatorDialog> createState() => _EditOperatorDialogState();
}

class _EditOperatorDialogState extends State<_EditOperatorDialog> {
  late final TextEditingController _businessName;
  late final TextEditingController _ownerEmail;
  late String _subscriptionTier;
  late String _preferredCurrency;
  late String? _primaryLocationId;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _businessName = TextEditingController(
      text: widget.bundle.operator.businessName,
    );
    _ownerEmail = TextEditingController(
      text: widget.bundle.operator.ownerEmail,
    );
    _subscriptionTier = widget.bundle.operator.subscriptionTier;
    _preferredCurrency = widget.bundle.operator.preferredCurrency;
    _primaryLocationId = widget.bundle.operator.primaryLocationId;
  }

  @override
  void dispose() {
    _businessName.dispose();
    _ownerEmail.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      OperatorPatchCommand(
        operatorId: widget.bundle.operator.operatorId,
        businessName: _businessName.text.trim(),
        ownerEmail: _ownerEmail.text.trim(),
        subscriptionTier: _subscriptionTier,
        preferredCurrency: _preferredCurrency,
        primaryLocationId: _primaryLocationId,
        idempotencyKey: widget.idempotencyKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_edit_operator_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Account profile',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DialogField(
                  fieldKey: const Key('admin_edit_business_name'),
                  controller: _businessName,
                  label: 'Business name',
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _DialogField(
                  fieldKey: const Key('admin_edit_owner_email'),
                  controller: _ownerEmail,
                  label: 'Contact email',
                  helperText:
                      'Updates business contact only. Team access is managed from Members.',
                  keyboardType: TextInputType.emailAddress,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _SubscriptionTierDropdown(value: _subscriptionTier),
                const SizedBox(height: 12),
                _CurrencyDropdown(
                  value: _preferredCurrency,
                  onChanged: (v) => setState(() => _preferredCurrency = v),
                ),
                const SizedBox(height: 12),
                _PrimaryLocationDropdown(
                  locations: widget.bundle.locations,
                  value: _primaryLocationId,
                  onChanged: (v) => setState(() => _primaryLocationId = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_edit_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_edit_submit_button'),
          onPressed: _submit,
          style: AdminButtonStyles.primary,
          child: const Text('Save profile'),
        ),
      ],
    );
  }
}

class _LocationDialog extends StatefulWidget {
  const _LocationDialog({
    required this.operatorId,
    required this.idempotencyKey,
    this.parentOrgUnitId,
    this.parentOrgUnitLabel,
    this.existing,
  });

  final String operatorId;
  final String? parentOrgUnitId;
  final String? parentOrgUnitLabel;
  final LocationAdminRecord? existing;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late final TextEditingController _name;
  late String _timezone;
  late int _rolloverHour;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _timezone = widget.existing?.timezone ?? 'America/Toronto';
    _rolloverHour = widget.existing?.businessDayRolloverHour ?? 4;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if (widget.existing == null) {
      Navigator.of(context).pop(
        LocationCreateCommand(
          operatorId: widget.operatorId,
          parentOrgUnitId: widget.parentOrgUnitId?.trim(),
          name: _name.text.trim(),
          timezone: _timezone,
          businessDayRolloverHour: _rolloverHour,
          idempotencyKey: widget.idempotencyKey,
        ),
      );
    } else {
      Navigator.of(context).pop(
        LocationPatchCommand(
          locationId: widget.existing!.locationId,
          name: _name.text.trim(),
          timezone: _timezone,
          businessDayRolloverHour: _rolloverHour,
          idempotencyKey: widget.idempotencyKey,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      key: Key(
        isEdit ? 'admin_location_edit_dialog' : 'admin_location_add_dialog',
      ),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        isEdit ? 'Edit location' : 'Add location',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!isEdit) ...[
                _LocationParentOrgUnitField(
                  label: widget.parentOrgUnitLabel?.trim().isNotEmpty == true
                      ? widget.parentOrgUnitLabel!.trim()
                      : widget.parentOrgUnitId ?? 'Selected org unit',
                ),
                const SizedBox(height: 12),
              ],
              _DialogField(
                fieldKey: const Key('admin_location_name_field'),
                controller: _name,
                label: 'Location name',
                validator: _requiredValidator,
              ),
              const SizedBox(height: 12),
              _TimezoneDropdown(
                fieldKey: const Key('admin_location_timezone_field'),
                value: _timezone,
                onChanged: (v) => setState(() => _timezone = v),
              ),
              const SizedBox(height: 12),
              _RolloverHourDropdown(
                value: _rolloverHour,
                onChanged: (v) => setState(() => _rolloverHour = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_location_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_location_submit_button'),
          onPressed: _submit,
          style: AdminButtonStyles.primary,
          child: Text(isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_confirm_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        title,
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 320,
        child: Text(
          message,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_confirm_cancel_button'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_confirm_confirm_button'),
          onPressed: () => Navigator.of(context).pop(true),
          style: AdminButtonStyles.danger,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

class _DialogField extends StatelessWidget {
  const _DialogField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.helperText,
    this.keyboardType,
    this.validator,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? helperText;
  final TextInputType? keyboardType;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );
    return TextFormField(
      key: fieldKey,
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      style: AppTextStyles.body14(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
        helperMaxLines: 2,
        floatingLabelStyle: AppTextStyles.uiLabel(color: AppColors.sunsetDark),
        filled: true,
        fillColor: AppColors.backgroundSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.sunset, width: 1.6),
        ),
      ),
    );
  }
}

class _LocationParentOrgUnitField extends StatelessWidget {
  const _LocationParentOrgUnitField({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );
    return InputDecorator(
      key: const Key('admin_location_parent_org_unit_field'),
      decoration: InputDecoration(
        labelText: 'Parent org unit',
        labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
        filled: true,
        fillColor: AppColors.cardGlow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: border,
        enabledBorder: border,
      ),
      child: Text(
        label,
        style: AppTextStyles.body14(color: AppColors.textPrimary),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _SubscriptionTierDropdown extends StatelessWidget {
  const _SubscriptionTierDropdown({required this.value});

  final String value;

  static const List<String> _tiers = <String>[
    'launch',
    'pilot',
    'starter',
    'premium',
    'elite',
    'pro',
    'enterprise',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _StatusPill(label: 'Coming soon', color: AppColors.peacockDark),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: const Key('admin_subscription_tier_dropdown'),
          initialValue: value,
          decoration: InputDecoration(
            labelText: 'Forge & Flow AI plan',
            labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(
                color: AppColors.borderSubtle,
                width: 1,
              ),
            ),
          ),
          items: <DropdownMenuItem<String>>[
            for (final tier in _tiers)
              DropdownMenuItem<String>(value: tier, child: Text(tier)),
          ],
          onChanged: null,
        ),
      ],
    );
  }
}

class _CurrencyDropdown extends StatelessWidget {
  const _CurrencyDropdown({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const List<String> _currencies = <String>[
    'CAD',
    'USD',
    'EUR',
    'GBP',
    'AUD',
  ];

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const Key('admin_currency_dropdown'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Preferred currency',
        labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      items: <DropdownMenuItem<String>>[
        for (final currency in _currencies)
          DropdownMenuItem<String>(value: currency, child: Text(currency)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _TimezoneDropdown extends StatelessWidget {
  const _TimezoneDropdown({
    required this.fieldKey,
    required this.value,
    required this.onChanged,
  });

  final Key fieldKey;
  final String value;
  final ValueChanged<String> onChanged;

  static const List<String> _priorityTimezones = <String>[
    'America/Toronto',
    'America/Vancouver',
    'America/St_Johns',
    'America/Halifax',
    'America/New_York',
    'America/Chicago',
    'America/Winnipeg',
    'America/Regina',
    'America/Denver',
    'America/Edmonton',
    'America/Phoenix',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
    'UTC',
  ];

  List<String> _options() {
    final names = ianaTimezoneNames();
    final seen = <String>{};
    final ordered = <String>[];

    void add(String timezone) {
      if (seen.add(timezone)) ordered.add(timezone);
    }

    if (!names.contains(value)) add(value);
    for (final timezone in _priorityTimezones) {
      if (names.contains(timezone) || timezone == value) add(timezone);
    }
    for (final timezone in names) {
      add(timezone);
    }
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    return FormField<String>(
      initialValue: value,
      validator: _timezoneValidator,
      builder: (field) {
        return InkWell(
          key: fieldKey,
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            final selected = await showDialog<String>(
              context: context,
              builder: (_) => _TimezonePickerDialog(
                options: _options(),
                selectedTimezone: value,
              ),
            );
            if (selected == null || !context.mounted) return;
            field.didChange(selected);
            onChanged(selected);
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'IANA timezone',
              labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
              errorText: field.errorText,
              suffixIcon: const Icon(
                Icons.search,
                size: 18,
                color: AppColors.textMuted,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(
                  color: AppColors.borderSubtle,
                  width: 1,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(
                  color: AppColors.borderSubtle,
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(
                  color: AppColors.sunset,
                  width: 1.5,
                ),
              ),
            ),
            child: Text(
              value,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }
}

class _TimezonePickerDialog extends StatefulWidget {
  const _TimezonePickerDialog({
    required this.options,
    required this.selectedTimezone,
  });

  final List<String> options;
  final String selectedTimezone;

  @override
  State<_TimezonePickerDialog> createState() => _TimezonePickerDialogState();
}

class _TimezonePickerDialogState extends State<_TimezonePickerDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> _filteredOptions() {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.options;
    return widget.options
        .where((timezone) => timezone.toLowerCase().contains(query))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredOptions();
    return AlertDialog(
      key: const Key('admin_timezone_picker_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Select IANA timezone',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        height: 430,
        child: Column(
          children: [
            TextField(
              key: const Key('admin_timezone_search_field'),
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: AppTextStyles.body14(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search timezones',
                hintStyle: AppTextStyles.body13(color: AppColors.textMuted),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 18,
                  color: AppColors.textMuted,
                ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.borderSubtle,
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.borderSubtle,
                    width: 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.sunset,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      key: const Key('admin_timezone_no_matches'),
                      child: Text(
                        'No timezones match',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => Container(
                        height: 1,
                        color: AppColors.borderSubtle.withValues(alpha: 0.4),
                      ),
                      itemBuilder: (context, index) {
                        final timezone = filtered[index];
                        final selected = timezone == widget.selectedTimezone;
                        return Material(
                          color: selected
                              ? AppColors.sunset.withValues(alpha: 0.10)
                              : Colors.transparent,
                          child: InkWell(
                            key: Key('admin_timezone_option_$timezone'),
                            onTap: () => Navigator.of(context).pop(timezone),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      timezone,
                                      key: Key(
                                        'admin_timezone_option_text_$timezone',
                                      ),
                                      style: AppTextStyles.body14(
                                        color: AppColors.textPrimary,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (selected)
                                    const Icon(
                                      Icons.check,
                                      size: 16,
                                      color: AppColors.sunsetDark,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_timezone_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _RolloverHourDropdown extends StatelessWidget {
  const _RolloverHourDropdown({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      key: const Key('admin_rollover_hour_dropdown'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Business-day rollover hour (0-23)',
        labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      items: <DropdownMenuItem<int>>[
        for (var hour = 0; hour < 24; hour++)
          DropdownMenuItem<int>(
            value: hour,
            child: Text('${hour.toString().padLeft(2, '0')}:00'),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _PrimaryLocationDropdown extends StatelessWidget {
  const _PrimaryLocationDropdown({
    required this.locations,
    required this.value,
    required this.onChanged,
  });

  final List<LocationAdminRecord> locations;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const Key('admin_primary_location_dropdown'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Primary location',
        labelStyle: AppTextStyles.uiLabel(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      items: <DropdownMenuItem<String>>[
        for (final loc in locations)
          DropdownMenuItem<String>(
            value: loc.locationId,
            child: Text(loc.name),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

String? _requiredValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  return null;
}

String? _timezoneValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  if (!isLikelyIanaTimezone(value)) {
    return 'Use an IANA name like America/Toronto';
  }
  return null;
}
