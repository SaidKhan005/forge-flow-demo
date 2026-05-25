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
import '../../theme/scope_icons.dart';
import '../../utils/iana_timezones.dart';
import '../../widgets/console/console_action_bar.dart';
import '../../widgets/console/console_screen_body.dart';
import '../../widgets/console/console_screen_header.dart';
import '../../widgets/console/console_surface.dart';

import '../admin_route_handoff.dart';
import '../models/email_conflict_details.dart';
import '../models/operator_location_admin_models.dart';
import '../services/admin_business_timing_resolution_gateway.dart';
import '../services/operator_location_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
import '../widgets/admin_responsive_layout.dart';
import '../widgets/admin_scope_tree_pane.dart';

const int _kLegacyRolloverHourDefault = 4;
const double _kBusinessAccountDetailMaxWidth = 1360;

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
    this.onChooseBusinessScope,
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

  /// Fired when the operator DELIBERATELY picks a business / org unit /
  /// location node in the LEFT shared scope tree (or any genuinely
  /// user-initiated selection), as opposed to the on-load seed that
  /// auto-highlights the first business. The shell uses this to flip its
  /// "a business has been chosen" latch so the per-business sidebar
  /// cluster activates. It carries the picked [AdminHierarchyScopeIntent]
  /// so the shell can light the cluster header with the business name and
  /// keep the top-bar picker in sync. The on-load seed path
  /// ([_notifyOperatorScope] from [_refresh]) NEVER calls this, so the
  /// cluster stays "Pick a business first" until a real pick happens.
  final ValueChanged<AdminHierarchyScopeIntent>? onChooseBusinessScope;
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
  /// right detail pane, drives the selected hierarchy scope, and — because
  /// this is a DELIBERATE, user-initiated pick (never the on-load seed) —
  /// notifies the shell so the sidebar per-business cluster activates and
  /// the top-bar picker stays in sync.
  ///
  /// The cluster activation depends on the shell receiving an intent that
  /// carries a `hierarchyScope` (see `admin_shell.dart`
  /// `_intentChoosesBusinessScope`); the on-load seed
  /// ([_notifyOperatorScope] from [_refresh]) emits only an
  /// operatorLocationScope, so it never activates the cluster.
  void _selectScopeFromTree(AdminHierarchyScopeIntent scope) {
    final operatorChanged = _selectedOperatorId != scope.operatorId;
    setState(() {
      _selectedOperatorId = scope.operatorId;
      _selectedHierarchyScope = scope;
      _expandedOperatorIds.add(scope.operatorId);
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
    });
    final chooseBusinessScope = widget.onChooseBusinessScope;
    if (chooseBusinessScope != null) {
      // Carries a hierarchyScope to the shell, which both flips the
      // "business chosen" latch (cluster activates) AND syncs the
      // operator-location scope (the shell derives it from the hierarchy
      // scope), so the separate operator-scope notify is not needed here.
      chooseBusinessScope(scope);
    } else if (operatorChanged) {
      // Backward-compatible fallback for callers that wire only the
      // operator-scope notify (e.g. older hosts / tests): keep the prior
      // behavior of syncing the shell scope when the business changes.
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
    return ColoredBox(
      key: const Key('admin_operators_screen'),
      color: AppColors.backgroundDeep,
      child: OperatorWebScreenFrame(
        maxContentWidth: _kBusinessAccountDetailMaxWidth,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
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
      child: AdminActionButton(
        key: const Key('admin_operators_new_button'),
        label: 'New business',
        onPressed: _openOnboardingDialog,
        icon: Icons.add,
        role: AdminActionRole.primary,
        minWidth: 168,
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
        title: 'Delete ${location.name}?',
        message:
            'This cannot be undone. The location must not be the '
            "operator's primary location.",
        confirmLabel: 'Delete',
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
    }, successHint: 'Location deleted.');
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
    return const OperatorWebScreenHeader(
      icon: Icons.apartment_outlined,
      title: 'Business accounts',
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
    final primaryLocation = bundle.primaryLocation?.name ?? 'No primary';
    return SingleChildScrollView(
      key: Key('admin_operator_detail_${operator.operatorId}'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _kBusinessAccountDetailMaxWidth,
          ),
          child: Container(
            key: const Key('admin_business_account_detail_surface'),
            decoration: BoxDecoration(
              color: AppColors.backgroundSurface.withValues(alpha: 0.96),
              border: Border.all(
                color: AppColors.borderSubtle.withValues(alpha: 0.76),
              ),
              borderRadius: AppRadius.cardR,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: AppColors.textPrimary.withValues(alpha: 0.06),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  key: const Key('admin_operator_profile_card'),
                  padding: const EdgeInsets.fromLTRB(40, 38, 40, 34),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _OperatorProfileHeader(
                        operator: operator,
                        editingEnabled: editingEnabled,
                        onEdit: () => onEditOperator(bundle),
                        onSuspend: () => onSuspend(bundle),
                        onReactivate: () => onReactivate(bundle),
                      ),
                      const SizedBox(height: 34),
                      _OperatorSummaryStrip(
                        children: [
                          _OperatorSummaryTile(
                            label: 'Email',
                            value: operator.ownerEmail,
                            icon: Icons.mail_outline,
                          ),
                          _OperatorSummaryTile(
                            label: 'Currency',
                            value: operator.preferredCurrency,
                            icon: Icons.payments_outlined,
                          ),
                          _OperatorSummaryTile(
                            label: 'Primary',
                            value: primaryLocation,
                            icon: Icons.location_on_outlined,
                          ),
                          _OperatorSummaryTile(
                            key: const Key('admin_operator_ai_plan_detail_row'),
                            label: 'Plan',
                            value: operator.subscriptionTier,
                            icon: Icons.auto_awesome_outlined,
                            muted: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Container(
                    height: 1,
                    color: AppColors.borderSubtle.withValues(alpha: 0.58),
                  ),
                ),
                _BusinessHierarchyPanel(
                  bundle: bundle,
                  gateway: hierarchyGateway,
                  actorUserId: actorUserId,
                  idempotencyKeyFactory: idempotencyKeyFactory,
                  selectedScope: selectedHierarchyScope,
                  onSelectScope: onSelectHierarchyScope,
                  onAddLocation: canAddLocation
                      ? () => onAddLocation(bundle)
                      : null,
                  addLocationEnabled: canAddLocation,
                  onEditLocation: onEditLocation,
                  onRemoveLocation: onRemoveLocation,
                  onSetPrimary: (location) => onSetPrimary(bundle, location),
                  editingEnabled: editingEnabled,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OperatorProfileHeader extends StatelessWidget {
  const _OperatorProfileHeader({
    required this.operator,
    required this.editingEnabled,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
  });

  final OperatorAdminRecord operator;
  final bool editingEnabled;
  final VoidCallback onEdit;
  final VoidCallback onSuspend;
  final VoidCallback onReactivate;

  @override
  Widget build(BuildContext context) {
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            operator.businessName,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
        ),
        if (operator.isSuspended) ...[
          const SizedBox(width: 10),
          _StatusPill(label: 'suspended', color: AppColors.negative),
        ],
      ],
    );
    final actions = _ActionRowWrap(
      children: [
        if (editingEnabled)
          _OperatorActionButton(
            buttonKey: const Key('admin_operator_edit_button'),
            label: 'Edit',
            icon: Icons.edit_outlined,
            tooltip: 'Edit account profile',
            onPressed: onEdit,
          ),
        if (editingEnabled && operator.isSuspended)
          _OperatorActionButton(
            buttonKey: const Key('admin_operator_reactivate_button'),
            label: 'Reactivate',
            icon: Icons.play_arrow_outlined,
            tooltip: 'Reactivate this business account',
            onPressed: onReactivate,
          ),
        if (editingEnabled && !operator.isSuspended)
          _OperatorActionButton(
            buttonKey: const Key('admin_operator_suspend_button'),
            label: 'Suspend',
            icon: Icons.pause_outlined,
            tooltip: 'Suspend this business account',
            destructive: true,
            onPressed: onSuspend,
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 240),
                child: title,
              ),
              actions,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: title),
            const SizedBox(width: 24),
            actions,
          ],
        );
      },
    );
  }
}

class _OperatorSummaryStrip extends StatelessWidget {
  const _OperatorSummaryStrip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 760) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) const SizedBox(width: 24),
                Expanded(child: children[index]),
              ],
            ],
          );
        }
        return Wrap(spacing: 24, runSpacing: 12, children: children);
      },
    );
  }
}

class _OperatorSummaryTile extends StatelessWidget {
  const _OperatorSummaryTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.muted = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 190, maxWidth: 270),
      child: Row(
        children: [
          _HierarchyIconTile(icon: icon, muted: muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!muted) return content;
    return Opacity(opacity: 0.56, child: content);
  }
}

class _HierarchyIconTile extends StatelessWidget {
  const _HierarchyIconTile({
    required this.icon,
    this.selected = false,
    this.muted = false,
  });

  final IconData icon;
  final bool selected;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final activeColor = selected ? AppColors.sunsetDark : AppColors.textMuted;
    final color = muted ? activeColor.withValues(alpha: 0.72) : activeColor;
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected
            ? AppColors.sunset.withValues(alpha: 0.08)
            : AppColors.backgroundSurface,
        border: Border.all(
          color: selected
              ? AppColors.sunsetDark.withValues(alpha: 0.34)
              : AppColors.borderSubtle.withValues(alpha: 0.74),
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          if (!selected)
            BoxShadow(
              color: AppColors.textPrimary.withValues(alpha: 0.025),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
        ],
      ),
      child: Icon(icon, size: 21, color: color),
    );
  }
}

class _BusinessHierarchyHeading extends StatelessWidget {
  const _BusinessHierarchyHeading({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final heading = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 3,
              height: 22,
              decoration: BoxDecoration(
                color: AppColors.sunsetDark,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.mono16(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
        final action = trailing == null
            ? null
            : OperatorWebActionBar(children: [trailing!]);
        final stacked = action != null && constraints.maxWidth < 620;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stacked) ...[
              heading,
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: action),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: heading),
                  if (action != null) ...[const SizedBox(width: 16), action],
                ],
              ),
            const SizedBox(height: 12),
            Container(
              height: 1,
              color: AppColors.borderSubtle.withValues(alpha: 0.64),
            ),
          ],
        );
      },
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

  /// Accumulated set of location ids the hierarchy gateway has EVER
  /// surfaced (as an active leaf) for this panel instance, unioned
  /// across every reload. It distinguishes the two "no live hierarchy
  /// leaf" sub-cases in [_buildTreeRows]:
  ///   * an id that was surfaced before and is now gone: the leaf was
  ///     deleted via the hierarchy gateway, so the row must HIDE (the
  ///     operator bundle still lists it because the hierarchy delete
  ///     does not mutate the operator gateway);
  ///   * an id that was NEVER surfaced: a location just added through
  ///     the operator gateway whose hierarchy leaf has not arrived yet
  ///     (always true for the demo's two divergent in-memory stores;
  ///     transiently true in production until the next hierarchy read),
  ///     so the row must SHOW immediately, placed by its own
  ///     `parentOrgUnitId`.
  /// Without this, a freshly-added location was silently filtered out
  /// and never appeared after the "Location added" toast.
  final Set<String> _everSurfacedLocationIds = <String>{};

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
        oldWidget.gateway != widget.gateway ||
        _locationSignature(oldWidget.bundle) !=
            _locationSignature(widget.bundle)) {
      // Reload when the operator, the gateway, OR the operator's own
      // location set changes. The location-set check is the refresh half
      // of the add-location fix: after `_runAndRefresh` re-fetches the
      // operator bundles, the parent rebuilds this panel with the SAME
      // operator id and gateway reference, so without it the cached
      // `_future` from initState would never re-run and the hierarchy
      // tree would stay stale (the new location would not appear until a
      // manual reload).
      _future = _load();
    }
  }

  /// Order-independent signature of the operator bundle's live (not
  /// soft-deleted) location ids. Changes whenever a location is added or
  /// removed, which is exactly when the hierarchy panel must reload.
  static String _locationSignature(OperatorAdminBundle bundle) {
    final ids = <String>[
      for (final location in bundle.locations)
        if (!location.isDeleted) location.locationId,
    ]..sort();
    return ids.join('|');
  }

  Future<_HierarchyPanelData> _load() async {
    final gateway = widget.gateway;
    if (gateway == null) return _HierarchyPanelData.empty();
    final operatorId = widget.bundle.operator.operatorId;
    final results = await Future.wait<Object>([
      gateway.listOrgUnits(operatorId: operatorId),
      gateway.listHierarchyLocations(operatorId: operatorId),
    ]);
    final locations = results[1] as List<HierarchyLocationLeaf>;
    // Remember every id the hierarchy gateway surfaces so a later
    // disappearance is read as a hierarchy delete (hide) rather than a
    // fresh operator-gateway add (show). See [_everSurfacedLocationIds].
    for (final leaf in locations) {
      _everSurfacedLocationIds.add(leaf.locationId);
    }
    return _HierarchyPanelData(
      orgUnits: results[0] as List<OrgUnitAdminNode>,
      locations: locations,
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('admin_business_hierarchy_panel'),
      padding: const EdgeInsets.fromLTRB(40, 24, 40, 44),
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
              _BusinessHierarchyHeading(
                title: 'Location hierarchy',
                trailing: widget.editingEnabled
                    ? Tooltip(
                        message: widget.addLocationEnabled
                            ? 'Add location'
                            : 'Select an org unit before adding a location',
                        child: AdminActionButton(
                          key: const Key('admin_operator_add_location_button'),
                          label: 'Add location',
                          onPressed: widget.addLocationEnabled
                              ? widget.onAddLocation
                              : null,
                          icon: Icons.add,
                          minWidth: 136,
                        ),
                      )
                    : null,
              ),
              if (snapshot.hasError) ...[
                const SizedBox(height: 12),
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
              const SizedBox(height: 18),
              _HierarchyScopeRow(
                key: const Key('admin_hierarchy_business_scope_row'),
                icon: scopeIcon(kind: ScopeEntityKind.business),
                label: widget.bundle.operator.businessName,
                subtitle: 'Business',
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
      // When the hierarchy gateway is the placement source, a location
      // with no live leaf is dropped ONLY if that leaf was deleted via
      // the hierarchy gateway (the id was surfaced on an earlier load and
      // is now gone). That is the audited hierarchy-delete-hides path.
      // A location whose id the hierarchy gateway has NEVER surfaced is a
      // fresh operator-gateway add (the demo's two in-memory stores never
      // share it; production has not re-read it yet), so it must still
      // render, placed below by its own `parentOrgUnitId`. This is the
      // display half of the add-location fix.
      if (trustHierarchyLocations &&
          leaf == null &&
          _everSurfacedLocationIds.contains(location.locationId)) {
        continue;
      }
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
    final selected =
        widget.selectedScope.scopeType == AdminHierarchyScopeType.orgUnit &&
        widget.selectedScope.orgUnitId == unit.orgUnitId;
    final rows = <Widget>[
      Opacity(
        opacity: unit.isSuspended ? 0.6 : 1,
        child: _HierarchyScopeRow(
          key: Key('admin_hierarchy_org_unit_${unit.orgUnitId}'),
          // Canonical org-unit glyph keyed off the real `org_units.unit_type`
          // (GAP A3): brand / region / district / location group each get
          // their canonical sub-type glyph, and an unknown / null type falls
          // back to the generic org-unit icon (identical to the prior
          // hardcoded `Icons.account_tree_outlined`).
          icon: scopeIconForUnitType(unit.unitType),
          label: unit.name,
          subtitle: _orgUnitSubtitle(unit),
          depth: depth,
          selected: selected,
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
          trailing: selected ? _buildOrgUnitActions(unit) : null,
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

  String _orgUnitSubtitle(OrgUnitAdminNode unit) {
    final label = _orgUnitTypeLabel(unit.unitType);
    if (!unit.isSuspended) return label;
    return 'Suspended ${_lowerInitial(label)}';
  }

  String _orgUnitTypeLabel(String? unitType) {
    return switch (unitType) {
      'corp' => 'Business',
      'brand' => 'Brand',
      'region' => 'Region',
      'district' => 'District',
      'location_group' => 'Location group',
      _ => 'Org unit',
    };
  }

  String _lowerInitial(String value) {
    if (value.isEmpty) return value;
    return value[0].toLowerCase() + value.substring(1);
  }

  /// Trailing action-button cluster for an org-unit hierarchy row.
  ///
  /// Extracted from [_buildOrgUnitRows] verbatim (behavior-preserving) to
  /// keep that method under the cyclomatic-complexity engineering bar; the
  /// per-button enable/disable and suspend/reactivate ternaries live here
  /// now. Returns `null` when the row is read-only or no gateway is wired,
  /// exactly as the prior inline `trailing:` expression did. Widget keys
  /// are unchanged.
  Widget? _buildOrgUnitActions(OrgUnitAdminNode unit) {
    if (!widget.editingEnabled || widget.gateway == null) {
      return null;
    }
    return OperatorWebActionBar(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        _HierarchyActionButton(
          buttonKey: Key(
            'admin_hierarchy_org_unit_add_child_${unit.orgUnitId}',
          ),
          label: 'Add org unit',
          tooltip: 'Add org unit',
          onPressed: () => _onAddChildOrgUnit(unit),
          icon: Icons.add,
        ),
        _HierarchyOverflowMenu(
          menuKey: Key('admin_hierarchy_org_unit_more_${unit.orgUnitId}'),
          tooltip: 'More org unit actions',
          actions: <_HierarchyOverflowAction>[
            _HierarchyOverflowAction(
              itemKey: Key('admin_hierarchy_org_unit_move_${unit.orgUnitId}'),
              label: 'Move',
              tooltip: unit.parentOrgUnitId == null
                  ? 'Business root stays at business level'
                  : 'Move org unit',
              onSelected: unit.parentOrgUnitId == null
                  ? null
                  : () => _onMoveOrgUnit(unit),
              icon: Icons.drive_file_move_outlined,
            ),
            _buildOrgUnitSuspendAction(unit),
            _HierarchyOverflowAction(
              itemKey: Key('admin_hierarchy_org_unit_delete_${unit.orgUnitId}'),
              label: 'Delete',
              tooltip: unit.parentOrgUnitId == null
                  ? 'Business root cannot be deleted'
                  : 'Delete org unit',
              onSelected: unit.parentOrgUnitId == null
                  ? null
                  : () => _onDeleteOrgUnit(unit),
              icon: Icons.delete_outline,
              destructive: true,
            ),
          ],
        ),
      ],
    );
  }

  /// Suspend / reactivate overflow action for an org-unit hierarchy row.
  ///
  /// Extracted verbatim from the action cluster (behavior-preserving) so
  /// both [_buildOrgUnitActions] and this action stay under the
  /// cyclomatic-complexity bar; the business-root guard, the
  /// suspended-vs-active key/label/icon swap, and the nested tooltip
  /// ternary are unchanged. Widget keys are identical to the prior inline
  /// expression.
  _HierarchyOverflowAction _buildOrgUnitSuspendAction(OrgUnitAdminNode unit) {
    return _HierarchyOverflowAction(
      itemKey: Key(
        unit.isSuspended
            ? 'admin_hierarchy_org_unit_reactivate_${unit.orgUnitId}'
            : 'admin_hierarchy_org_unit_suspend_${unit.orgUnitId}',
      ),
      label: unit.isSuspended ? 'Reactivate' : 'Suspend',
      tooltip: unit.parentOrgUnitId == null
          ? 'Business root cannot be suspended'
          : unit.isSuspended
          ? 'Reactivate org unit'
          : 'Suspend org unit',
      onSelected: unit.parentOrgUnitId == null
          ? null
          : () => _onToggleOrgUnitSuspension(unit),
      icon: unit.isSuspended
          ? Icons.play_circle_outline
          : Icons.pause_circle_outline,
    );
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
    final locationBaseSubtitle = isPrimary ? 'Primary location' : 'Location';
    final locationSubtitle = isSuspended
        ? 'Suspended ${_lowerInitial(locationBaseSubtitle)}'
        : locationBaseSubtitle;
    final selected =
        widget.selectedScope.scopeType == AdminHierarchyScopeType.location &&
        widget.selectedScope.locationId == location.locationId;
    return Opacity(
      key: Key('admin_location_suspended_fade_${location.locationId}'),
      opacity: isSuspended ? 0.55 : 1,
      child: _HierarchyScopeRow(
        key: Key('admin_hierarchy_location_${location.locationId}'),
        icon: scopeIcon(kind: ScopeEntityKind.location),
        label: location.name,
        subtitle: locationSubtitle,
        depth: depth,
        selected: selected,
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
        trailing: selected && widget.editingEnabled
            ? OperatorWebActionBar(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  _HierarchyActionButton(
                    buttonKey: Key(
                      'admin_location_edit_${location.locationId}',
                    ),
                    label: 'Edit',
                    tooltip: 'Edit location',
                    onPressed: () => widget.onEditLocation(location),
                    icon: Icons.edit_outlined,
                  ),
                  _HierarchyOverflowMenu(
                    menuKey: Key('admin_location_more_${location.locationId}'),
                    tooltip: 'More location actions',
                    actions: <_HierarchyOverflowAction>[
                      _HierarchyOverflowAction(
                        itemKey: Key(
                          'admin_location_move_${location.locationId}',
                        ),
                        label: 'Move',
                        tooltip: 'Move location',
                        onSelected:
                            widget.gateway == null ||
                                orgUnits
                                    .where(
                                      (unit) => unit.orgUnitId != orgUnitId,
                                    )
                                    .isEmpty
                            ? null
                            : () => _onMoveLocation(
                                location,
                                currentOrgUnitId: orgUnitId,
                              ),
                        icon: Icons.drive_file_move_outlined,
                      ),
                      _HierarchyOverflowAction(
                        itemKey: Key(
                          isSuspended
                              ? 'admin_location_reactivate_${location.locationId}'
                              : 'admin_location_suspend_${location.locationId}',
                        ),
                        label: isSuspended ? 'Reactivate' : 'Suspend',
                        tooltip: isSuspended
                            ? 'Reactivate location'
                            : 'Suspend location',
                        onSelected: widget.gateway == null
                            ? null
                            : () => _onToggleLocationSuspension(
                                location,
                                isSuspended: isSuspended,
                              ),
                        icon: isSuspended
                            ? Icons.play_circle_outline
                            : Icons.pause_circle_outline,
                      ),
                      _HierarchyOverflowAction(
                        itemKey: Key(
                          'admin_location_make_primary_${location.locationId}',
                        ),
                        label: 'Make primary',
                        tooltip: 'Make primary location',
                        onSelected: isPrimary
                            ? null
                            : () => widget.onSetPrimary(location),
                        icon: Icons.star_outline,
                      ),
                      _HierarchyOverflowAction(
                        itemKey: Key(
                          'admin_location_remove_${location.locationId}',
                        ),
                        label: 'Delete',
                        tooltip: 'Delete location',
                        onSelected: isPrimary
                            ? null
                            : () => _onDeleteHierarchyLocation(location),
                        icon: Icons.delete_outline,
                        destructive: true,
                      ),
                    ],
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
    return OperatorWebDialog(
      key: const Key('admin_hierarchy_add_child_org_unit_dialog'),
      title: 'Add org unit',
      icon: Icons.account_tree_outlined,
      maxWidth: 560,
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_hierarchy_add_org_unit_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_hierarchy_add_org_unit_submit'),
          label: 'Add',
          onPressed: _onSubmit,
          role: AdminActionRole.primary,
        ),
      ],
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
              DropdownMenuItem<String>(value: 'region', child: Text('Region')),
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
    return OperatorWebDialog(
      key: widget.dialogKey,
      title: widget.title,
      icon: Icons.drive_file_move_outlined,
      maxWidth: 560,
      actions: <Widget>[
        AdminActionButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: widget.submitKey,
          label: 'Move',
          onPressed: _onSubmit,
          role: AdminActionRole.primary,
        ),
      ],
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
    return OperatorWebDialog(
      key: widget.dialogKey,
      title: widget.title,
      icon: widget.danger ? Icons.warning_amber_outlined : Icons.edit_note,
      maxWidth: 560,
      actions: <Widget>[
        AdminActionButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: widget.submitKey,
          label: widget.submitLabel,
          onPressed: _onSubmit,
          role: widget.danger
              ? AdminActionRole.danger
              : AdminActionRole.primary,
        ),
      ],
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
    final isNested = depth > 0;
    final radius = BorderRadius.circular(6);
    final rowMaxWidth = trailing == null ? 1080.0 : 1260.0;
    final fillColor = selected
        ? AppColors.sunset.withValues(alpha: 0.06)
        : Colors.transparent;
    final borderColor = selected
        ? AppColors.sunsetDark.withValues(alpha: 0.16)
        : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: rowMaxWidth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (isNested) _HierarchyConnector(depth: depth),
              Expanded(
                child: Material(
                  color: fillColor,
                  borderRadius: radius,
                  child: InkWell(
                    onTap: onTap,
                    borderRadius: radius,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: borderColor, width: 1),
                        borderRadius: radius,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compactActions =
                              trailing != null && constraints.maxWidth < 880;
                          final showLeadingIcon = constraints.maxWidth >= 96;
                          final showAccent =
                              selected && constraints.maxWidth >= 128;
                          final labelBlock = Row(
                            children: [
                              if (showAccent) ...[
                                Container(
                                  width: 3,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: AppColors.sunsetDark,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              if (showLeadingIcon) ...[
                                _HierarchyIconTile(
                                  icon: icon,
                                  selected: selected,
                                ),
                                const SizedBox(width: 14),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      label,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTextStyles.body14(
                                        color: selected
                                            ? AppColors.textPrimary
                                            : AppColors.textSecondary,
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
                            ],
                          );
                          if (trailing == null) return labelBlock;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (compactActions) ...[
                                labelBlock,
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: trailing!,
                                ),
                              ] else
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(child: labelBlock),
                                    const SizedBox(width: 16),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 650,
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: trailing!,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HierarchyConnector extends StatelessWidget {
  const _HierarchyConnector({required this.depth});

  final int depth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: Key('admin_hierarchy_connector_depth_$depth'),
      width: depth * 52.0,
      height: 64,
      child: CustomPaint(painter: _DashedHierarchyConnectorPainter(depth)),
    );
  }
}

class _DashedHierarchyConnectorPainter extends CustomPainter {
  const _DashedHierarchyConnectorPainter(this.depth);

  final int depth;

  @override
  void paint(Canvas canvas, Size size) {
    if (depth <= 0) return;
    final paint = Paint()
      ..color = AppColors.borderSubtle.withValues(alpha: 0.9)
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final centerY = size.height / 2;
    for (var level = 0; level < depth; level++) {
      final x = 22.0 + (level * 52.0);
      _drawDashedLine(canvas, Offset(x, 0), Offset(x, size.height), paint);
    }
    final elbowX = 22.0 + ((depth - 1) * 52.0);
    _drawDashedLine(
      canvas,
      Offset(elbowX, centerY),
      Offset(size.width - 9, centerY),
      paint,
    );
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dash = 4.5;
    const gap = 4.0;
    final isVertical = start.dx == end.dx;
    final length = isVertical
        ? (end.dy - start.dy).abs()
        : (end.dx - start.dx).abs();
    var distance = 0.0;
    while (distance < length) {
      final next = distance + dash > length ? length : distance + dash;
      final segmentStart = isVertical
          ? Offset(start.dx, start.dy + distance)
          : Offset(start.dx + distance, start.dy);
      final segmentEnd = isVertical
          ? Offset(end.dx, start.dy + next)
          : Offset(start.dx + next, end.dy);
      canvas.drawLine(segmentStart, segmentEnd, paint);
      distance += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedHierarchyConnectorPainter oldDelegate) {
    return oldDelegate.depth != depth;
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
      child: AdminActionButton(
        key: buttonKey,
        label: label,
        onPressed: onPressed,
        icon: icon,
        role: destructive
            ? AdminActionRole.dangerSecondary
            : AdminActionRole.secondary,
      ),
    );
  }
}

class _HierarchyActionButton extends StatelessWidget {
  const _HierarchyActionButton({
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: AdminActionButton(
        key: buttonKey,
        label: label,
        onPressed: onPressed,
        icon: icon,
        role: AdminActionRole.secondary,
        compact: true,
        minWidth: 84,
      ),
    );
  }
}

class _HierarchyOverflowAction {
  const _HierarchyOverflowAction({
    required this.itemKey,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });

  final Key itemKey;
  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onSelected;
  final bool destructive;
}

class _HierarchyOverflowMenu extends StatelessWidget {
  const _HierarchyOverflowMenu({
    required this.menuKey,
    required this.tooltip,
    required this.actions,
  });

  final Key menuKey;
  final String tooltip;
  final List<_HierarchyOverflowAction> actions;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_HierarchyOverflowAction>(
      key: menuKey,
      tooltip: tooltip,
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (action) => action.onSelected?.call(),
      itemBuilder: (context) {
        return <PopupMenuEntry<_HierarchyOverflowAction>>[
          for (final action in actions)
            PopupMenuItem<_HierarchyOverflowAction>(
              key: action.itemKey,
              value: action,
              enabled: action.onSelected != null,
              child: Tooltip(
                message: action.tooltip,
                child: Row(
                  children: <Widget>[
                    Icon(
                      action.icon,
                      size: 16,
                      color: _overflowActionColor(action),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        action.label,
                        style: AppTextStyles.buttonLabel(
                          color: _overflowActionColor(action),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ];
      },
    );
  }

  Color _overflowActionColor(_HierarchyOverflowAction action) {
    if (action.destructive) return AppColors.negative;
    if (action.onSelected == null) return AppColors.textMuted;
    return AppColors.textPrimary;
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
            AdminActionButton(
              key: Key('admin_operators_email_conflict_open_${usage.email}'),
              label: 'Open operator',
              onPressed: () => onShowConflict!(usage),
              role: AdminActionRole.quiet,
              compact: true,
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
    return OperatorWebDialog(
      key: const Key('admin_onboard_operator_dialog'),
      title: 'New operator',
      icon: Icons.business_outlined,
      maxWidth: 520,
      actions: [
        AdminActionButton(
          key: const Key('admin_onboard_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_onboard_submit_button'),
          label: 'Onboard operator',
          onPressed: _submit,
          role: AdminActionRole.primary,
        ),
      ],
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
    return OperatorWebDialog(
      key: const Key('admin_edit_operator_dialog'),
      title: 'Account profile',
      icon: Icons.business_center_outlined,
      maxWidth: 520,
      actions: [
        AdminActionButton(
          key: const Key('admin_edit_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_edit_submit_button'),
          label: 'Save profile',
          onPressed: _submit,
          role: AdminActionRole.primary,
        ),
      ],
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
    return OperatorWebDialog(
      key: Key(
        isEdit ? 'admin_location_edit_dialog' : 'admin_location_add_dialog',
      ),
      title: isEdit ? 'Edit location' : 'Add location',
      icon: Icons.place_outlined,
      maxWidth: 480,
      actions: [
        AdminActionButton(
          key: const Key('admin_location_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_location_submit_button'),
          label: isEdit ? 'Save' : 'Add',
          onPressed: _submit,
          role: AdminActionRole.primary,
        ),
      ],
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
    return OperatorWebDialog(
      key: const Key('admin_confirm_dialog'),
      title: title,
      icon: Icons.warning_amber_outlined,
      maxWidth: 420,
      actions: [
        AdminActionButton(
          key: const Key('admin_confirm_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(false),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_confirm_confirm_button'),
          label: confirmLabel,
          onPressed: () => Navigator.of(context).pop(true),
          role: AdminActionRole.danger,
        ),
      ],
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
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
    return OperatorWebDialog(
      key: const Key('admin_timezone_picker_dialog'),
      title: 'Select IANA timezone',
      icon: Icons.public_outlined,
      maxWidth: 520,
      actions: [
        AdminActionButton(
          key: const Key('admin_timezone_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
      ],
      child: SizedBox(
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
