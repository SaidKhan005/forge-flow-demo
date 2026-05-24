// Phase 11A.1 - Operator + location admin screen.
//
// Admin-side CRUD on operators (`operators` table) and their
// locations (`locations` table). Supports onboarding a new operator
// (creates the row, primary location, subscription tier, currency,
// and admin assignment), editing existing operators, suspending +
// reactivating, and add/edit/remove locations with IANA timezone.
// Legacy rollover values remain readable, but Business Timing owns
// business-day start edits.
//
// The screen takes an [OperatorLocationAdminGateway] from the
// outside; production passes the HTTP gateway, demo + widget tests
// pass the in-memory gateway. Brand styling reuses
// `lib/theme/app_theme.dart` verbatim per the 11A non-negotiable.

import 'package:flutter/material.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../theme/app_theme.dart';
import '../../utils/iana_timezones.dart';

import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/email_conflict_details.dart';
import '../models/operator_location_admin_models.dart';
import '../services/admin_business_timing_resolution_gateway.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';
import '../widgets/admin_scope_tree_pane.dart';

const int _kLegacyRolloverHourDefault = 4;

class OperatorLocationAdminScreen extends StatefulWidget {
  const OperatorLocationAdminScreen({
    super.key,
    required this.gateway,
    this.hierarchyGateway,
    this.vendorConnectionsGateway,
    this.timingResolutionGateway,
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

  /// Fix #4 / S4 (G42): READ-ONLY S2 admin cross-tenant business-
  /// timing resolution gateway, threaded into the per-location Timing
  /// dialog. Production binds the HTTP-backed gateway (via
  /// `AdminConsoleServicesScope.timingResolutionGatewayOf`); demo /
  /// widget tests leave it null and the dialog falls back to a seeded
  /// in-memory gateway. This UI reads timing only; server-side super
  /// admin repair routes exist for profile writes.
  final AdminBusinessTimingResolutionGateway? timingResolutionGateway;
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

  // Left scope-pane state. The Business accounts screen now uses the
  // SAME searchable business -> org unit -> location tree as the AI
  // setup tabs (`AdminScopeTreePane`), so scope is presented one way
  // across the admin console.
  late Future<List<AdminScopeTree>> _scopeTreesFuture;
  final TextEditingController _scopeSearchController = TextEditingController();
  final Set<String> _expandedOperatorIds = <String>{};
  String _scopeSearch = '';

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
    _scopeTreesFuture = _loadScopeTrees();
    _scopeSearchController.addListener(() {
      setState(
        () => _scopeSearch = _scopeSearchController.text.trim().toLowerCase(),
      );
    });
    _refresh();
  }

  @override
  void dispose() {
    _scopeSearchController.dispose();
    super.dispose();
  }

  Future<List<AdminScopeTree>> _loadScopeTrees() {
    return loadAdminScopeTrees(
      operatorGateway: widget.gateway,
      hierarchyGateway: widget.hierarchyGateway,
    );
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
        // Rebuild the left scope tree from the refreshed operator set so
        // new / removed businesses and locations appear after a mutation.
        _scopeTreesFuture = _loadScopeTrees();
        // No auto-select: like the AI setup tabs, the right detail pane
        // shows a "Select a business" prompt until the operator picks a
        // node in the left scope tree. A previously-selected business is
        // retained across refresh; it is cleared only if it disappeared.
        if (_selectedOperatorId != null &&
            bundles.every(
              (b) => b.operator.operatorId != _selectedOperatorId,
            )) {
          _selectedOperatorId = null;
        }
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
      // Seed the shell's scope (sidebar cluster + top toggle + the
      // scope other admin surfaces inherit on first open) with the
      // selected business, or, when nothing is picked yet, the first
      // business. This is shell-sync ONLY: the right detail pane stays
      // on its "Select a business" prompt until the operator picks a
      // node in the left scope tree.
      _notifyOperatorScope(
        selectedAfterRefresh ?? (bundles.isEmpty ? null : bundles.first),
      );
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

  void _selectHierarchyScope(AdminHierarchyScopeIntent scope) {
    setState(() {
      _selectedHierarchyScope = scope;
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
    });
  }

  /// Handles a pick from the LEFT shared scope tree. Any node (business
  /// / org unit / location) resolves to its owning business for the
  /// right detail pane, drives the selected hierarchy scope, and (when
  /// the owning business changes) notifies the shell through the SAME
  /// `onSelectOperatorScope` path the screen already used on operator
  /// switch, so the shell scope, sidebar cluster, and top toggle stay
  /// in sync.
  void _selectScopeFromTree(AdminHierarchyScopeIntent scope) {
    final operatorChanged = _selectedOperatorId != scope.operatorId;
    setState(() {
      _selectedOperatorId = scope.operatorId;
      _selectedHierarchyScope = scope;
      _expandedOperatorIds.add(scope.operatorId);
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
    });
    if (operatorChanged) {
      _notifyOperatorScope(_selected);
    }
  }

  void _toggleScopeExpanded(String operatorId) {
    setState(() {
      if (!_expandedOperatorIds.add(operatorId)) {
        _expandedOperatorIds.remove(operatorId);
      }
    });
  }

  void _notifyOperatorScope(OperatorAdminBundle? bundle) {
    final callback = widget.onSelectOperatorScope;
    if (callback == null || bundle == null) return;
    callback(_scopeForBundle(bundle));
  }

  AdminOperatorLocationScopeIntent _scopeForBundle(OperatorAdminBundle bundle) {
    return AdminOperatorLocationScopeIntent(
      operatorId: bundle.operator.operatorId,
      operatorName: bundle.operator.businessName,
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
            const _BusinessAccountsHeader(),
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
            // The scope pane's search field + tree rows need a Material
            // ancestor; this screen is a bare Container (no Scaffold), so
            // provide a transparent Material for the whole body.
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: _buildBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_operators_load_error'),
        message: _loadError!,
      );
    }
    if (!_loading && _bundles.isEmpty) {
      // The scope pane (which hosts the "New business" header button) does
      // not render until at least one business exists, so surface that
      // onboarding affordance directly in the empty state. Otherwise the
      // "Use New business..." copy below would be a dead end when no
      // accounts have been created yet. `_buildNewBusinessButton` returns
      // null in read-only mode, matching the scope-pane behavior.
      final newBusinessButton = _buildNewBusinessButton();
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
                if (newBusinessButton != null) ...[
                  const SizedBox(height: 16),
                  newBusinessButton,
                ],
              ],
            ),
          ),
        ),
      );
    }
    return FutureBuilder<List<AdminScopeTree>>(
      future: _scopeTreesFuture,
      builder: (context, snapshot) {
        final trees = snapshot.data ?? const <AdminScopeTree>[];
        final loading =
            _loading || snapshot.connectionState != ConnectionState.done;
        final scopePane = AdminScopeTreePane(
          trees: trees
              .where((tree) => tree.matchesSearch(_scopeSearch))
              .toList(growable: false),
          searchController: _scopeSearchController,
          selectedScope: _selectedHierarchyScope,
          expandedOperatorIds: _expandedOperatorIds,
          loading: loading,
          onSelectScope: _selectScopeFromTree,
          onToggleExpanded: _toggleScopeExpanded,
          forceExpanded: _scopeSearch.isNotEmpty,
          header: _buildNewBusinessButton(),
        );
        final detailPane = _buildDetailPane();
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 920;
            if (compact) {
              return DefaultTabController(
                length: 2,
                child: Column(
                  key: const Key('admin_operators_workspace_tabs'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Material(
                      color: AppColors.backgroundMid,
                      child: const TabBar(
                        labelColor: AppColors.textPrimary,
                        unselectedLabelColor: AppColors.textMuted,
                        indicatorColor: AppColors.sunsetDark,
                        tabs: [
                          Tab(text: 'Scope'),
                          Tab(text: 'Business'),
                        ],
                      ),
                    ),
                    Expanded(
                      child: TabBarView(children: [scopePane, detailPane]),
                    ),
                  ],
                ),
              );
            }
            return Row(
              key: const Key('admin_operators_workspace_split'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 360, child: scopePane),
                const VerticalDivider(width: 1),
                Expanded(child: detailPane),
              ],
            );
          },
        );
      },
    );
  }

  /// "New business" onboarding affordance, relocated from the page
  /// header into the top of the left scope pane so it stays reachable
  /// after the master list became the shared scope tree. Returns null
  /// in read-only mode so the button is absent (matching the prior
  /// `_BusinessAccountsHeader` behavior).
  Widget? _buildNewBusinessButton() {
    if (!widget.editingEnabled) return null;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const Key('admin_operators_new_button'),
        onPressed: _openOnboardingDialog,
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
      ),
    );
  }

  /// Right detail pane: the selected business profile + location
  /// hierarchy, or a "Select a business" empty prompt before any node
  /// is picked (mirrors the AI tabs' `_FunctionPane` empty state).
  Widget _buildDetailPane() {
    final selected = _selected;
    if (selected == null) {
      return Container(
        key: const Key('admin_operators_detail_pane'),
        color: AppColors.backgroundDeep,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: AdminCard(
              key: const Key('admin_operators_detail_empty'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Business accounts',
                    style: AppTextStyles.sectionTitle(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Select a business, org unit, or location to manage its profile, locations, and hierarchy.',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      key: const Key('admin_operators_detail_pane'),
      color: AppColors.backgroundDeep,
      child: _OperatorDetail(
        bundle: selected,
        hierarchyGateway: widget.hierarchyGateway,
        actorUserId: widget.actorUserId,
        idempotencyKeyFactory: _nextIdempotencyKey,
        selectedHierarchyScope:
            _selectedHierarchyScope ?? _businessHierarchyScope(selected),
        onSelectHierarchyScope: _selectHierarchyScope,
        onEditOperator: _openEditOperatorDialog,
        onSuspend: _suspend,
        onReactivate: _reactivate,
        onAddLocation: _openAddLocationDialog,
        onEditLocation: _openEditLocationDialog,
        onRemoveLocation: _removeLocation,
        onSetPrimary: _setPrimaryLocation,
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
  const _BusinessAccountsHeader();

  @override
  Widget build(BuildContext context) {
    // The "New business" onboarding action now lives at the top of the
    // left scope pane (see `_buildNewBusinessButton`); this header is
    // the page title only.
    return Text(
      'Business accounts',
      style: AppTextStyles.pageTitle(color: AppColors.textPrimary),
    );
  }
}

class _OperatorDetail extends StatelessWidget {
  const _OperatorDetail({
    required this.bundle,
    required this.hierarchyGateway,
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
    required this.selectedParentOrgUnitId,
    this.selectedParentOrgUnitLabel,
    required this.editingEnabled,
  });

  final OperatorAdminBundle bundle;
  final RolesHierarchySessionsAdminGateway? hierarchyGateway;
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
  final String? selectedParentOrgUnitId;
  final String? selectedParentOrgUnitLabel;
  final bool editingEnabled;

  bool get _canAddLocation {
    final parentOrgUnitId = selectedParentOrgUnitId?.trim();
    return editingEnabled &&
        parentOrgUnitId != null &&
        parentOrgUnitId.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final operator = bundle.operator;
    final canAddLocation = _canAddLocation;
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
        ],
      ),
    );
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

  Future<void> _onMoveOrgUnit(OrgUnitAdminNode unit) async {
    final gateway = widget.gateway;
    if (!widget.editingEnabled || gateway == null) return;
    final data = await (_future ?? _load());
    final blockedIds = <String>{unit.orgUnitId, ..._descendantIds(data, unit)};
    final candidates = <_HierarchyMoveTarget>[
      for (final candidate in data.orgUnits)
        if (!blockedIds.contains(candidate.orgUnitId) &&
            candidate.orgUnitId != unit.parentOrgUnitId)
          _HierarchyMoveTarget(
            id: candidate.orgUnitId,
            label: _pathLabelForUnit(data, candidate),
          ),
    ];
    if (unit.parentOrgUnitId == null) {
      _showHierarchySnack('The business root stays at business level.');
      return;
    }
    if (candidates.isEmpty) {
      _showHierarchySnack('No other org unit is available for this move.');
      return;
    }
    if (!mounted) return;
    final result = await showDialog<_MoveHierarchyResult>(
      context: context,
      builder: (_) => _MoveHierarchyDialog(
        dialogKey: const Key('admin_hierarchy_move_org_unit_dialog'),
        targetKey: const Key('admin_hierarchy_move_org_unit_parent'),
        reasonKey: const Key('admin_hierarchy_move_org_unit_reason'),
        submitKey: const Key('admin_hierarchy_move_org_unit_submit'),
        title: 'Move ${unit.name}',
        targetLabel: 'New parent',
        candidates: candidates,
      ),
    );
    if (result == null) return;
    try {
      final moved = await gateway.moveOrgUnit(
        operatorId: widget.bundle.operator.operatorId,
        orgUnitId: unit.orgUnitId,
        newParentOrgUnitId: result.targetId,
        idempotencyKey: widget.idempotencyKeyFactory(),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      );
      if (!mounted) return;
      _selectMovedOrgUnit(moved, data);
      setState(() {
        _future = _load();
      });
      _showHierarchySnack('Moved ${unit.name}');
    } catch (error) {
      if (!mounted) return;
      _showHierarchySnack('Could not move org unit: $error');
    }
  }

  Future<void> _onMoveLocation(
    LocationAdminRecord location, {
    required String? currentOrgUnitId,
  }) async {
    final gateway = widget.gateway;
    if (!widget.editingEnabled || gateway == null) return;
    final data = await (_future ?? _load());
    final candidates = <_HierarchyMoveTarget>[
      for (final candidate in data.orgUnits)
        if (candidate.orgUnitId != currentOrgUnitId)
          _HierarchyMoveTarget(
            id: candidate.orgUnitId,
            label: _pathLabelForUnit(data, candidate),
          ),
    ];
    if (candidates.isEmpty) {
      _showHierarchySnack('No other org unit is available for this move.');
      return;
    }
    if (!mounted) return;
    final result = await showDialog<_MoveHierarchyResult>(
      context: context,
      builder: (_) => _MoveHierarchyDialog(
        dialogKey: const Key('admin_hierarchy_move_location_dialog'),
        targetKey: const Key('admin_hierarchy_move_location_parent'),
        reasonKey: const Key('admin_hierarchy_move_location_reason'),
        submitKey: const Key('admin_hierarchy_move_location_submit'),
        title: 'Move ${location.name}',
        targetLabel: 'New org unit',
        candidates: candidates,
      ),
    );
    if (result == null) return;
    try {
      final moved = await gateway.moveLocation(
        operatorId: widget.bundle.operator.operatorId,
        locationId: location.locationId,
        newOrgUnitId: result.targetId,
        idempotencyKey: widget.idempotencyKeyFactory(),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      );
      if (!mounted) return;
      _selectMovedLocation(location, moved, data);
      setState(() {
        _future = _load();
      });
      _showHierarchySnack('Moved ${location.name}');
    } catch (error) {
      if (!mounted) return;
      _showHierarchySnack('Could not move location: $error');
    }
  }

  Future<void> _onToggleOrgUnitSuspension(OrgUnitAdminNode unit) async {
    final gateway = widget.gateway;
    if (!widget.editingEnabled || gateway == null) return;
    final suspending = !unit.isSuspended;
    if (unit.parentOrgUnitId == null && suspending) {
      _showHierarchySnack('The business root cannot be suspended.');
      return;
    }
    if (!mounted) return;
    final reason = await _askHierarchyReason(
      dialogKey: Key(
        suspending
            ? 'admin_hierarchy_org_unit_suspend_dialog'
            : 'admin_hierarchy_org_unit_reactivate_dialog',
      ),
      reasonKey: Key(
        suspending
            ? 'admin_hierarchy_org_unit_suspend_reason'
            : 'admin_hierarchy_org_unit_reactivate_reason',
      ),
      submitKey: Key(
        suspending
            ? 'admin_hierarchy_org_unit_suspend_submit'
            : 'admin_hierarchy_org_unit_reactivate_submit',
      ),
      title: suspending ? 'Suspend ${unit.name}' : 'Reactivate ${unit.name}',
      message: suspending
          ? 'This keeps the org unit in the hierarchy but blocks it for active use until reactivated.'
          : 'This makes the org unit active again.',
      submitLabel: suspending ? 'Suspend' : 'Reactivate',
      danger: suspending,
    );
    if (reason == null) return;
    try {
      final updated = suspending
          ? await gateway.suspendOrgUnit(
              operatorId: widget.bundle.operator.operatorId,
              orgUnitId: unit.orgUnitId,
              idempotencyKey: widget.idempotencyKeyFactory(),
              actorUserId: widget.actorUserId,
              actorIsForgeAdmin: widget.editingEnabled,
              adminReason: reason,
            )
          : await gateway.reactivateOrgUnit(
              operatorId: widget.bundle.operator.operatorId,
              orgUnitId: unit.orgUnitId,
              idempotencyKey: widget.idempotencyKeyFactory(),
              actorUserId: widget.actorUserId,
              actorIsForgeAdmin: widget.editingEnabled,
              adminReason: reason,
            );
      if (!mounted) return;
      final data = await (_future ?? _load());
      _selectMovedOrgUnit(updated, data);
      setState(() {
        _future = _load();
      });
      _showHierarchySnack(
        suspending ? 'Suspended ${unit.name}' : 'Reactivated ${unit.name}',
      );
    } catch (error) {
      if (!mounted) return;
      _showHierarchySnack(
        suspending
            ? 'Could not suspend org unit: $error'
            : 'Could not reactivate org unit: $error',
      );
    }
  }

  Future<void> _onDeleteOrgUnit(OrgUnitAdminNode unit) async {
    final gateway = widget.gateway;
    if (!widget.editingEnabled || gateway == null) return;
    if (unit.parentOrgUnitId == null) {
      _showHierarchySnack('The business root cannot be deleted.');
      return;
    }
    if (!mounted) return;
    final reason = await _askHierarchyReason(
      dialogKey: const Key('admin_hierarchy_org_unit_delete_dialog'),
      reasonKey: const Key('admin_hierarchy_org_unit_delete_reason'),
      submitKey: const Key('admin_hierarchy_org_unit_delete_submit'),
      title: 'Delete ${unit.name}',
      message:
          'This removes an empty org unit from active hierarchy views. Move any child org units or locations first.',
      submitLabel: 'Delete',
      danger: true,
    );
    if (reason == null) return;
    try {
      await gateway.deleteOrgUnit(
        operatorId: widget.bundle.operator.operatorId,
        orgUnitId: unit.orgUnitId,
        idempotencyKey: widget.idempotencyKeyFactory(),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      );
      if (!mounted) return;
      if (widget.selectedScope.scopeType == AdminHierarchyScopeType.orgUnit &&
          widget.selectedScope.orgUnitId == unit.orgUnitId) {
        widget.onSelectScope(_businessScope());
      }
      setState(() {
        _future = _load();
      });
      _showHierarchySnack('Deleted ${unit.name}');
    } catch (error) {
      if (!mounted) return;
      _showHierarchySnack('Could not delete org unit: $error');
    }
  }

  Future<void> _onToggleLocationSuspension(
    LocationAdminRecord location, {
    required bool isSuspended,
  }) async {
    final gateway = widget.gateway;
    if (!widget.editingEnabled || gateway == null) return;
    final suspending = !isSuspended;
    if (!mounted) return;
    final reason = await _askHierarchyReason(
      dialogKey: Key(
        suspending
            ? 'admin_hierarchy_location_suspend_dialog'
            : 'admin_hierarchy_location_reactivate_dialog',
      ),
      reasonKey: Key(
        suspending
            ? 'admin_hierarchy_location_suspend_reason'
            : 'admin_hierarchy_location_reactivate_reason',
      ),
      submitKey: Key(
        suspending
            ? 'admin_hierarchy_location_suspend_submit'
            : 'admin_hierarchy_location_reactivate_submit',
      ),
      title: suspending
          ? 'Suspend ${location.name}'
          : 'Reactivate ${location.name}',
      message: suspending
          ? 'This keeps the location in the hierarchy but blocks it for active use until reactivated.'
          : 'This makes the location active again.',
      submitLabel: suspending ? 'Suspend' : 'Reactivate',
      danger: suspending,
    );
    if (reason == null) return;
    try {
      final updated = suspending
          ? await gateway.suspendLocation(
              operatorId: widget.bundle.operator.operatorId,
              locationId: location.locationId,
              idempotencyKey: widget.idempotencyKeyFactory(),
              actorUserId: widget.actorUserId,
              actorIsForgeAdmin: widget.editingEnabled,
              adminReason: reason,
            )
          : await gateway.reactivateLocation(
              operatorId: widget.bundle.operator.operatorId,
              locationId: location.locationId,
              idempotencyKey: widget.idempotencyKeyFactory(),
              actorUserId: widget.actorUserId,
              actorIsForgeAdmin: widget.editingEnabled,
              adminReason: reason,
            );
      if (!mounted) return;
      final data = await (_future ?? _load());
      _selectMovedLocation(location, updated, data);
      setState(() {
        _future = _load();
      });
      _showHierarchySnack(
        suspending
            ? 'Suspended ${location.name}'
            : 'Reactivated ${location.name}',
      );
    } catch (error) {
      if (!mounted) return;
      _showHierarchySnack(
        suspending
            ? 'Could not suspend location: $error'
            : 'Could not reactivate location: $error',
      );
    }
  }

  Future<void> _onDeleteHierarchyLocation(LocationAdminRecord location) async {
    final gateway = widget.gateway;
    if (!widget.editingEnabled || gateway == null) {
      widget.onRemoveLocation(location);
      return;
    }
    if (widget.bundle.operator.primaryLocationId == location.locationId) {
      _showHierarchySnack('The primary location cannot be deleted.');
      return;
    }
    if (!mounted) return;
    final reason = await _askHierarchyReason(
      dialogKey: const Key('admin_hierarchy_location_delete_dialog'),
      reasonKey: const Key('admin_hierarchy_location_delete_reason'),
      submitKey: const Key('admin_hierarchy_location_delete_submit'),
      title: 'Delete ${location.name}',
      message:
          "This removes the location from active hierarchy views. The business's primary location cannot be deleted.",
      submitLabel: 'Delete',
      danger: true,
    );
    if (reason == null) return;
    try {
      await gateway.deleteLocation(
        operatorId: widget.bundle.operator.operatorId,
        locationId: location.locationId,
        idempotencyKey: widget.idempotencyKeyFactory(),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      );
      if (!mounted) return;
      if (widget.selectedScope.scopeType == AdminHierarchyScopeType.location &&
          widget.selectedScope.locationId == location.locationId) {
        widget.onSelectScope(_businessScope());
      }
      setState(() {
        _future = _load();
      });
      _showHierarchySnack('Deleted ${location.name}');
    } catch (error) {
      if (!mounted) return;
      _showHierarchySnack('Could not delete location: $error');
    }
  }

  Future<String?> _askHierarchyReason({
    required Key dialogKey,
    required Key reasonKey,
    required Key submitKey,
    required String title,
    required String message,
    required String submitLabel,
    required bool danger,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _HierarchyReasonDialog(
        dialogKey: dialogKey,
        reasonKey: reasonKey,
        submitKey: submitKey,
        title: title,
        message: message,
        submitLabel: submitLabel,
        danger: danger,
      ),
    );
  }

  void _showHierarchySnack(String message) {
    if (Scaffold.maybeOf(context) == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _selectMovedOrgUnit(OrgUnitAdminNode moved, _HierarchyPanelData data) {
    widget.onSelectScope(
      AdminHierarchyScopeIntent.orgUnit(
        operatorId: widget.bundle.operator.operatorId,
        operatorName: widget.bundle.operator.businessName,
        orgUnitId: moved.orgUnitId,
        orgUnitName: moved.name,
        hierarchyPath: _ancestorNamesForUnit(data, moved.parentOrgUnitId),
        effectiveValueLabel: 'Branch default',
        allowedActionsLabel: widget.editingEnabled ? 'Editable' : 'Read-only',
      ),
    );
  }

  void _selectMovedLocation(
    LocationAdminRecord location,
    HierarchyLocationLeaf moved,
    _HierarchyPanelData data,
  ) {
    final parent = _findOrgUnit(data, moved.orgUnitId);
    widget.onSelectScope(
      AdminHierarchyScopeIntent.location(
        operatorId: widget.bundle.operator.operatorId,
        operatorName: widget.bundle.operator.businessName,
        orgUnitId: parent?.orgUnitId,
        orgUnitName: parent?.name,
        locationId: location.locationId,
        locationName: location.name,
        hierarchyPath: _ancestorNamesForUnit(data, parent?.orgUnitId),
        valueState: AdminHierarchyScopeValueState.locationOnly,
        effectiveValueLabel: location.timezone,
        allowedActionsLabel: widget.editingEnabled
            ? 'Location controls'
            : 'Read-only',
      ),
    );
  }

  Set<String> _descendantIds(
    _HierarchyPanelData data,
    OrgUnitAdminNode ancestor,
  ) {
    final childrenByParent = <String, List<OrgUnitAdminNode>>{};
    for (final unit in data.orgUnits) {
      final parentId = unit.parentOrgUnitId;
      if (parentId == null) continue;
      childrenByParent
          .putIfAbsent(parentId, () => <OrgUnitAdminNode>[])
          .add(unit);
    }
    final result = <String>{};
    void walk(String parentId) {
      for (final child
          in childrenByParent[parentId] ?? const <OrgUnitAdminNode>[]) {
        if (result.add(child.orgUnitId)) {
          walk(child.orgUnitId);
        }
      }
    }

    walk(ancestor.orgUnitId);
    return result;
  }

  OrgUnitAdminNode? _findOrgUnit(_HierarchyPanelData data, String? orgUnitId) {
    if (orgUnitId == null) return null;
    for (final unit in data.orgUnits) {
      if (unit.orgUnitId == orgUnitId) return unit;
    }
    return null;
  }

  String _pathLabelForUnit(_HierarchyPanelData data, OrgUnitAdminNode unit) {
    final names = <String>[
      ..._ancestorNamesForUnit(data, unit.parentOrgUnitId),
    ];
    names.add(unit.name);
    return names.join(' / ');
  }

  List<String> _ancestorNamesForUnit(_HierarchyPanelData data, String? unitId) {
    final byId = <String, OrgUnitAdminNode>{
      for (final unit in data.orgUnits) unit.orgUnitId: unit,
    };
    final names = <String>[];
    final seen = <String>{};
    String? cursor = unitId;
    while (cursor != null && seen.add(cursor)) {
      final unit = byId[cursor];
      if (unit == null) break;
      names.insert(0, unit.name);
      cursor = unit.parentOrgUnitId;
    }
    return names;
  }

  AdminHierarchyScopeIntent _businessScope() {
    return AdminHierarchyScopeIntent.business(
      operatorId: widget.bundle.operator.operatorId,
      operatorName: widget.bundle.operator.businessName,
      effectiveValueLabel: 'Business default',
      allowedActionsLabel: widget.editingEnabled ? 'Editable' : 'Read-only',
    );
  }

  Widget _hierarchyIconButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: color,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      visualDensity: VisualDensity.compact,
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
      if (unit.isDeleted) continue;
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
      if (leaf.isDeleted) continue;
      leafParentByLocation[leaf.locationId] = leaf.orgUnitId;
    }
    final leafByLocation = <String, HierarchyLocationLeaf>{
      for (final leaf in data.locations)
        if (!leaf.isDeleted) leaf.locationId: leaf,
    };
    final trustHierarchyLocations =
        widget.gateway != null && data.locations.isNotEmpty;
    final locationsByParent = <String?, List<LocationAdminRecord>>{};
    for (final location in widget.bundle.locations) {
      if (location.isDeleted) continue;
      final leaf = leafByLocation[location.locationId];
      if (trustHierarchyLocations && leaf == null) continue;
      final parentFromData =
          leaf?.orgUnitId ??
          leafParentByLocation[location.locationId] ??
          location.parentOrgUnitId;
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
          allOrgUnits: data.orgUnits,
          leafByLocation: leafByLocation,
          path: const <String>[],
        ),
      );
    }
    final unassigned = locationsByParent[null] ?? const <LocationAdminRecord>[];
    for (final location in unassigned) {
      rows.add(
        _buildLocationRow(
          location: location,
          depth: 0,
          orgUnits: data.orgUnits,
          hierarchyLeaf: leafByLocation[location.locationId],
        ),
      );
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
    required List<OrgUnitAdminNode> allOrgUnits,
    required Map<String, HierarchyLocationLeaf> leafByLocation,
    required List<String> path,
  }) {
    final nextPath = _appendHierarchyPath(path, unit.name);
    final rows = <Widget>[
      Opacity(
        opacity: unit.isSuspended ? 0.6 : 1,
        child: _HierarchyScopeRow(
          key: Key('admin_hierarchy_org_unit_${unit.orgUnitId}'),
          icon: Icons.account_tree_outlined,
          label: unit.name,
          subtitle: unit.isSuspended
              ? (depth == 0 ? 'Suspended org unit' : 'Suspended branch')
              : (depth == 0 ? 'Org unit' : 'Org unit branch'),
          depth: depth,
          selected:
              widget.selectedScope.scopeType ==
                  AdminHierarchyScopeType.orgUnit &&
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
              ? Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    _hierarchyIconButton(
                      key: Key(
                        'admin_hierarchy_org_unit_add_child_${unit.orgUnitId}',
                      ),
                      tooltip: 'Add child org unit',
                      onPressed: () => _onAddChildOrgUnit(unit),
                      icon: Icons.add,
                    ),
                    _hierarchyIconButton(
                      key: Key(
                        'admin_hierarchy_org_unit_move_${unit.orgUnitId}',
                      ),
                      tooltip: unit.parentOrgUnitId == null
                          ? 'Business root stays at business level'
                          : 'Move org unit',
                      onPressed: unit.parentOrgUnitId == null
                          ? null
                          : () => _onMoveOrgUnit(unit),
                      icon: Icons.drive_file_move_outlined,
                    ),
                    _hierarchyIconButton(
                      key: Key(
                        unit.isSuspended
                            ? 'admin_hierarchy_org_unit_reactivate_${unit.orgUnitId}'
                            : 'admin_hierarchy_org_unit_suspend_${unit.orgUnitId}',
                      ),
                      tooltip: unit.parentOrgUnitId == null
                          ? 'Business root cannot be suspended'
                          : unit.isSuspended
                          ? 'Reactivate org unit'
                          : 'Suspend org unit',
                      onPressed: unit.parentOrgUnitId == null
                          ? null
                          : () => _onToggleOrgUnitSuspension(unit),
                      icon: unit.isSuspended
                          ? Icons.play_circle_outline
                          : Icons.pause_circle_outline,
                    ),
                    _hierarchyIconButton(
                      key: Key(
                        'admin_hierarchy_org_unit_delete_${unit.orgUnitId}',
                      ),
                      tooltip: unit.parentOrgUnitId == null
                          ? 'Business root cannot be deleted'
                          : 'Delete org unit',
                      onPressed: unit.parentOrgUnitId == null
                          ? null
                          : () => _onDeleteOrgUnit(unit),
                      icon: Icons.delete_outline,
                      color: AppColors.negative,
                    ),
                  ],
                )
              : null,
        ),
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
          orgUnits: allOrgUnits,
          hierarchyLeaf: leafByLocation[location.locationId],
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
          allOrgUnits: allOrgUnits,
          leafByLocation: leafByLocation,
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
    required List<OrgUnitAdminNode> orgUnits,
    HierarchyLocationLeaf? hierarchyLeaf,
    String? orgUnitId,
    String? orgUnitName,
    List<String> path = const <String>[],
  }) {
    final isPrimary =
        widget.bundle.operator.primaryLocationId == location.locationId;
    final isSuspended =
        widget.bundle.operator.isSuspended ||
        location.isSuspended ||
        hierarchyLeaf?.isSuspended == true;
    return Opacity(
      key: Key('admin_location_suspended_fade_${location.locationId}'),
      opacity: isSuspended ? 0.55 : 1,
      child: _HierarchyScopeRow(
        key: Key('admin_hierarchy_location_${location.locationId}'),
        icon: Icons.storefront_outlined,
        label: location.name,
        subtitle: isSuspended
            ? (isPrimary ? 'Suspended primary location' : 'Suspended location')
            : (isPrimary ? 'Primary location' : 'Location'),
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
                spacing: 4,
                runSpacing: 4,
                children: [
                  _hierarchyIconButton(
                    key: Key('admin_location_move_${location.locationId}'),
                    tooltip: 'Move location',
                    onPressed:
                        widget.gateway == null ||
                            orgUnits
                                .where((unit) => unit.orgUnitId != orgUnitId)
                                .isEmpty
                        ? null
                        : () => _onMoveLocation(
                            location,
                            currentOrgUnitId: orgUnitId,
                          ),
                    icon: Icons.drive_file_move_outlined,
                  ),
                  _hierarchyIconButton(
                    key: Key(
                      isSuspended
                          ? 'admin_location_reactivate_${location.locationId}'
                          : 'admin_location_suspend_${location.locationId}',
                    ),
                    tooltip: isSuspended
                        ? 'Reactivate location'
                        : 'Suspend location',
                    onPressed: widget.gateway == null
                        ? null
                        : () => _onToggleLocationSuspension(
                            location,
                            isSuspended: isSuspended,
                          ),
                    icon: isSuspended
                        ? Icons.play_circle_outline
                        : Icons.pause_circle_outline,
                  ),
                  _hierarchyIconButton(
                    key: Key('admin_location_edit_${location.locationId}'),
                    tooltip: 'Edit location',
                    onPressed: () => widget.onEditLocation(location),
                    icon: Icons.edit_outlined,
                  ),
                  _hierarchyIconButton(
                    key: Key(
                      'admin_location_make_primary_${location.locationId}',
                    ),
                    tooltip: 'Make primary location',
                    onPressed: isPrimary
                        ? null
                        : () => widget.onSetPrimary(location),
                    icon: Icons.star_outline,
                  ),
                  _hierarchyIconButton(
                    key: Key('admin_location_remove_${location.locationId}'),
                    tooltip: widget.gateway == null
                        ? 'Remove location'
                        : 'Delete location',
                    onPressed: isPrimary
                        ? null
                        : () => _onDeleteHierarchyLocation(location),
                    icon: Icons.delete_outline,
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
  final _reasonController = TextEditingController();
  String? _nameError;
  String? _reasonError;

  @override
  void dispose() {
    _nameController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final name = _nameController.text.trim();
    final label = _sanitiseLabel(name);
    final reason = _reasonController.text.trim();
    setState(() {
      _nameError = name.isEmpty
          ? 'Org unit name is required.'
          : widget.existingNames.contains(name.toLowerCase())
          ? 'A sibling org unit already uses this name.'
          : null;
      _reasonError = reason.isEmpty ? 'Add a reason before continuing.' : null;
    });
    if (_nameError != null || _reasonError != null) {
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
                DropdownMenuItem<String>(value: 'brand', child: Text('Brand')),
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

class _HierarchyMoveTarget {
  const _HierarchyMoveTarget({required this.id, required this.label});

  final String id;
  final String label;
}

class _MoveHierarchyResult {
  const _MoveHierarchyResult({
    required this.targetId,
    required this.adminReason,
  });

  final String targetId;
  final String adminReason;
}

class _MoveHierarchyDialog extends StatefulWidget {
  const _MoveHierarchyDialog({
    required this.dialogKey,
    required this.targetKey,
    required this.reasonKey,
    required this.submitKey,
    required this.title,
    required this.targetLabel,
    required this.candidates,
  });

  final Key dialogKey;
  final Key targetKey;
  final Key reasonKey;
  final Key submitKey;
  final String title;
  final String targetLabel;
  final List<_HierarchyMoveTarget> candidates;

  @override
  State<_MoveHierarchyDialog> createState() => _MoveHierarchyDialogState();
}

class _MoveHierarchyDialogState extends State<_MoveHierarchyDialog> {
  late String _selectedTargetId = widget.candidates.first.id;
  final _reasonController = TextEditingController();
  bool _missingReason = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _missingReason = true);
      return;
    }
    Navigator.of(context).pop(
      _MoveHierarchyResult(targetId: _selectedTargetId, adminReason: reason),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: widget.dialogKey,
      backgroundColor: AppColors.backgroundSurface,
      title: Text(widget.title, style: AdminButtonStyles.dialogTitleStyle),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: widget.targetKey,
              initialValue: _selectedTargetId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: widget.targetLabel,
                border: const OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String>>[
                for (final candidate in widget.candidates)
                  DropdownMenuItem<String>(
                    value: candidate.id,
                    child: Text(candidate.label),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _selectedTargetId = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: widget.reasonKey,
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _missingReason
                    ? 'Add a reason before continuing.'
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: widget.submitKey,
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Move'),
        ),
      ],
    );
  }
}

class _HierarchyReasonDialog extends StatefulWidget {
  const _HierarchyReasonDialog({
    required this.dialogKey,
    required this.reasonKey,
    required this.submitKey,
    required this.title,
    required this.message,
    required this.submitLabel,
    required this.danger,
  });

  final Key dialogKey;
  final Key reasonKey;
  final Key submitKey;
  final String title;
  final String message;
  final String submitLabel;
  final bool danger;

  @override
  State<_HierarchyReasonDialog> createState() => _HierarchyReasonDialogState();
}

class _HierarchyReasonDialogState extends State<_HierarchyReasonDialog> {
  final _reasonController = TextEditingController();
  bool _missingReason = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _missingReason = true);
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: widget.dialogKey,
      backgroundColor: AppColors.backgroundSurface,
      title: Text(widget.title, style: AdminButtonStyles.dialogTitleStyle),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.message,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              key: widget.reasonKey,
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _missingReason
                    ? 'Add a reason before continuing.'
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: widget.submitKey,
          style: widget.danger
              ? AdminButtonStyles.danger
              : AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: Text(widget.submitLabel),
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compactActions =
                    trailing != null && constraints.maxWidth < 320;
                final labelRow = Row(
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
                            style: AppTextStyles.mono11(
                              color: AppColors.textMuted,
                            ),
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
                    if (trailing != null && !compactActions) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
                  ],
                );
                if (!compactActions) return labelRow;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    labelRow,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: trailing!),
                  ],
                );
              },
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
              'Support access is read-only. Operator, location, and vendor integration changes are hidden for this role.',
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
        // Compatibility bridge: the current admin create route still
        // requires this legacy column. Business Timing owns edits after
        // onboarding.
        primaryLocationRolloverHour: _kLegacyRolloverHourDefault,
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
                const _LegacyRolloverReadOnly(
                  key: Key('admin_onboard_legacy_rollover_readonly'),
                  rolloverHour: _kLegacyRolloverHourDefault,
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
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _timezone = widget.existing?.timezone ?? 'America/Toronto';
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
          // Compatibility bridge: the current admin create route still
          // requires this legacy column. Business Timing owns edits after
          // creation.
          businessDayRolloverHour: _kLegacyRolloverHourDefault,
          idempotencyKey: widget.idempotencyKey,
        ),
      );
    } else {
      Navigator.of(context).pop(
        LocationPatchCommand(
          locationId: widget.existing!.locationId,
          name: _name.text.trim(),
          timezone: _timezone,
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
              _LegacyRolloverReadOnly(
                key: const Key('admin_location_legacy_rollover_readonly'),
                rolloverHour:
                    widget.existing?.businessDayRolloverHour ??
                    _kLegacyRolloverHourDefault,
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

class _LegacyRolloverReadOnly extends StatelessWidget {
  const _LegacyRolloverReadOnly({super.key, required this.rolloverHour});

  final int? rolloverHour;

  @override
  Widget build(BuildContext context) {
    final display = rolloverHour == null
        ? 'No legacy rollover on file'
        : '${rolloverHour!.toString().padLeft(2, '0')}:00 local';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Legacy rollover',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$display. Edit business-day start in Business Timing.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
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
