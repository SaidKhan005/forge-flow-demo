// Plans & Limits V1 (Phase 1) - admin Plans & limits screen.
//
// Rebuilt to the operator-approved mockup
// `docs/_mockups/admin_plans_and_limits_redesign.html` and the
// reconciled pricing model in
// `docs/phases/phase_11a/phase_11a_decision_register.md`
// ("Reconciled pricing model (2026-05-24)"). FRONT-END ONLY: this
// slice adds no backend routes and reuses the existing gateways.
//
// Two views:
//
//   * Plans - a laddered map of the six plans (Pilot, Starter, Premium,
//     Elite, Pro, Enterprise): name, price, what it adds, included
//     advisor cap, and a margin estimate. Phase 3 makes plan pricing
//     EDITABLE: the price / per-seat ramp / onboarding range read from
//     the server `pricing_plan_catalog` via `GET /v1/admin/pricing/plans`
//     (falling back to the hard-coded `kPricingPlanPresentations` +
//     `buildFallbackPlanCatalog` when the call fails or in offline demo),
//     and each card carries an "Edit pricing" button that saves through
//     `PATCH /v1/admin/pricing/plans/{tier_key}` (idempotent + audited at
//     the proxy). The "what it adds" copy + laddered accent still come
//     from the static presentation. When `editingEnabled` is false the
//     Edit buttons are hidden (the `ff_support` read-only walkthrough).
//
//   * Businesses - the detail for the business the left scope tree
//     (`hierarchyScope`) selects. The left scope tree is the single
//     business selector here, exactly like every other admin screen, so
//     this tab carries no redundant business master list of its own. The
//     detail shows a plan + margin card, a recent-limit-hits strip, the
//     plan presets, and the usage-limits list where each limit draws a
//     spend-vs-cap bar. With no business resolved from the scope it shows
//     a "Choose a business" empty state.
//
// Spend / margin / cap-breach numbers come from two sources. The
// per-limit spend-vs-cap bar prefers the Phase 2 live spend-summary
// endpoint (`GET /v1/admin/pricing/operators/{id}/spend-summary`,
// month-to-date spend per (location, usage_class)); when that endpoint
// is unavailable (demo mode, or not yet deployed) the bar FALLS BACK
// to the existing observability gateway (`ObservabilityAdminGateway`),
// joining cost telemetry by `operator_id` + `usage_class`. The plan +
// margin card and recent cap-breach strip still read the observability
// envelope, which returns a deterministic seeded envelope in demo.
//
// Usage-limit add/edit/delete flow through the pricing gateway. "Use
// case" is a dropdown of the known classes with friendly labels; the
// raw IDs stay visible in a details expander. Phase 2 re-enables the
// delete-limit affordance: each limit row carries a delete button that
// confirms first, then calls the gateway's `deleteUsageCap` (DELETE
// `/v1/admin/pricing/usage-caps`, idempotent + audited at the proxy).
//
// Inheritance is DISPLAY ONLY: a cap shows "Inherited" vs "Set here"
// from the existing scope info. No inheritance backend is built here.
//
// Brand styling reuses `lib/theme/app_theme.dart` and the shared
// OperatorWeb* widgets verbatim. The screen takes a
// [PricingTierAdminGateway] and an optional [ObservabilityAdminGateway]
// from the outside; production passes the HTTP gateways, demo + widget
// tests pass the in-memory gateways. `editingEnabled` defaults to
// `true`; passing `false` renders a read-only view (used for the
// `ff_support` demo identity walkthrough).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_screen_header.dart';
import '../../widgets/console/console_surface.dart';

import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../admin_visual_system.dart';
import '../models/observability_admin_models.dart';
import '../models/pricing_tier_admin_models.dart';
import '../services/observability_admin_gateway.dart';
import '../services/pricing_tier_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
import '../widgets/admin_responsive_layout.dart';

/// The views the screen exposes. The mockup also carries a "Reconcile"
/// decision-aid tab; that tab is a one-time pricing reconciliation
/// worksheet with no gateway and no persistence, so it is intentionally
/// out of scope for this operational screen.
///
/// Phase 5a adds [features]: an editable matrix of which features each
/// plan includes (`feature_entitlements`). FOUNDATION ONLY — it records
/// the matrix; it does not gate the app yet (deferred Phase 5d).
enum _PricingView { plans, features, businesses }

/// Health bucket for a business, mirroring the mockup's dot/pill tones.
enum _MarginHealth { good, thin, bad, unknown }

class PricingTierAdminScreen extends StatefulWidget {
  const PricingTierAdminScreen({
    super.key,
    required this.gateway,
    this.observabilityGateway,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
    this.hierarchyScope,
    this.scopeLocationIds = const <String>{},
  });

  final PricingTierAdminGateway gateway;

  /// Read-only source for spend / margin / cap-breach figures. When
  /// null the screen renders without those numbers (the plan + limit
  /// structure still paints), so the screen degrades gracefully if a
  /// host does not wire it. Production and demo both pass one.
  final ObservabilityAdminGateway? observabilityGateway;

  /// When false, the screen hides every mutate affordance - used for
  /// the `ff_support` walkthrough path. The proxy enforces the same
  /// gate server-side; this flag keeps the UI honest about it.
  final bool editingEnabled;

  /// Factory for the idempotency key the gateway attaches to each
  /// mutating call. Production binds this to a UUID-shaped generator;
  /// widget tests inject a deterministic counter so retries can be
  /// asserted.
  final String Function()? idempotencyKeyFactory;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final Set<String> scopeLocationIds;

  @override
  State<PricingTierAdminScreen> createState() => _PricingTierAdminScreenState();
}

class _PricingTierAdminScreenState extends State<PricingTierAdminScreen> {
  bool _loading = true;
  String? _loadError;
  List<PricingOperatorBundle> _bundles = const <PricingOperatorBundle>[];
  ObservabilityEnvelope? _observability;
  String? _selectedOperatorId;
  String? _actionError;
  int _idempotencyCounter = 0;
  _PricingView _view = _PricingView.plans;

  /// Phase 2 live spend-vs-cap figures, keyed by operator id. Populated
  /// best-effort from the spend-summary endpoint when an operator is
  /// selected; a null entry means "fall back to the observability
  /// envelope" so demo mode keeps painting bars.
  final Map<String, OperatorSpendSummary> _spendSummaries =
      <String, OperatorSpendSummary>{};

  /// Phase 3 — live plan-pricing catalog keyed by tier_key, read from
  /// `GET /v1/admin/pricing/plans`. When the call fails or returns empty
  /// (offline demo, endpoint not deployed) this falls back to
  /// [buildFallbackPlanCatalog] so the Plans map always paints. The map
  /// is always populated (fallback at construction), then overwritten
  /// with live rows on a successful load.
  Map<String, PricingPlanCatalogEntry> _planCatalog =
      <String, PricingPlanCatalogEntry>{
        for (final entry in buildFallbackPlanCatalog()) entry.tierKey: entry,
      };

  /// Phase 5a — live feature-entitlements matrix keyed by
  /// `tier_key::feature_slug`, read from `GET /v1/admin/pricing/entitlements`.
  /// When the call fails or returns empty (offline demo, endpoint not
  /// deployed) this falls back to [buildDefaultFeatureEntitlements] so the
  /// matrix always paints. Always populated (default at construction), then
  /// overwritten with live rows on a successful load.
  Map<String, FeatureEntitlementEntry> _entitlements =
      <String, FeatureEntitlementEntry>{
        for (final entry in buildDefaultFeatureEntitlements())
          '${entry.tierKey}::${entry.featureSlug}': entry,
      };

  ScopedPricingContractEffectiveResponse? _scopedContract;
  bool _scopedContractLoading = false;
  String? _scopedContractError;
  String? _scopedContractScopeKey;

  /// Mints a fresh idempotency key per user action so a retried PATCH,
  /// PUT, or POST at the proxy collapses to one ledger row + one audit
  /// row in `admin_request_idempotency`.
  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return 'pricing-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant PricingTierAdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hierarchyScope?.cacheKey != widget.hierarchyScope?.cacheKey) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final bundles = await widget.gateway.listOperators();
      // Observability is best-effort: it powers the spend/margin/breach
      // numbers but the plan + limit structure must still render if the
      // read-only figures are unavailable. A failure here is swallowed
      // into a null envelope rather than blocking the whole screen.
      final observability = await _fetchObservability();
      // Phase 3 — best-effort live plan-pricing catalog. A failure or an
      // empty result keeps the hard-coded fallback already in
      // `_planCatalog`, so the Plans map paints either way (HP#2: demo
      // mode works offline). Never blocks the screen.
      final planCatalog = await _fetchPlanCatalog();
      // Phase 5a — best-effort live feature-entitlements matrix. Same
      // posture: a failure or empty result keeps the default ladder
      // already in `_entitlements`, so the matrix paints either way.
      final entitlements = await _fetchEntitlements();
      if (!mounted) return;
      setState(() {
        _bundles = bundles;
        _observability = observability;
        if (planCatalog != null && planCatalog.isNotEmpty) {
          _planCatalog = <String, PricingPlanCatalogEntry>{
            for (final entry in planCatalog) entry.tierKey: entry,
          };
        }
        if (entitlements != null && entitlements.isNotEmpty) {
          _entitlements = <String, FeatureEntitlementEntry>{
            for (final entry in entitlements)
              '${entry.tierKey}::${entry.featureSlug}': entry,
          };
        }
        _loading = false;
        // The left scope tree is the single business selector: the focused
        // operator is the one the scope resolves, never an auto-picked
        // first row. When the scope resolves no operator (nothing selected,
        // or its operator is absent from the gateway result) the selection
        // stays null and the Businesses tab shows the pick-a-business empty
        // state instead of silently defaulting to a random business.
        final visible = _visibleBundles;
        final preferredOperatorId = widget.hierarchyScope?.operatorId;
        if (preferredOperatorId != null &&
            visible.any((b) => b.operatorId == preferredOperatorId)) {
          _selectedOperatorId = preferredOperatorId;
        } else {
          _selectedOperatorId = null;
        }
        _scopedContract = null;
        _scopedContractError = null;
        _scopedContractScopeKey = widget.hierarchyScope?.cacheKey;
      });
      // Best-effort live spend for the operator now in focus. A failure
      // here is swallowed so the bars fall back to the observability
      // envelope (demo mode has no spend-summary endpoint).
      final focused = _selectedOperatorId;
      if (focused != null) {
        unawaited(_fetchSpendSummaryFor(focused));
        unawaited(_fetchScopedContractForCurrentScope());
      }
    } on PricingTierAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load pricing data: $error';
        _loading = false;
      });
    }
  }

  Future<ObservabilityEnvelope?> _fetchObservability() async {
    final gateway = widget.observabilityGateway;
    if (gateway == null) return null;
    try {
      return await gateway.fetch();
    } catch (_) {
      // Spend/margin numbers are advisory here; never let them break
      // the plans + limits structure. The detail cards fall back to the
      // honest empty sentinel when the envelope is missing.
      return null;
    }
  }

  /// Phase 3 — pull the live plan-pricing catalog. Best-effort: any error
  /// (endpoint not deployed, demo gateway, transient failure) returns null
  /// so the caller keeps the hard-coded fallback. The in-memory demo
  /// gateway returns a seeded catalog, so demo mode still shows editable
  /// numbers offline.
  Future<List<PricingPlanCatalogEntry>?> _fetchPlanCatalog() async {
    try {
      return await widget.gateway.listPlanCatalog();
    } catch (_) {
      return null;
    }
  }

  /// Phase 3 — edit one plan's pricing. Opens the editor seeded with the
  /// current catalog values, then saves through the gateway
  /// (`PATCH /v1/admin/pricing/plans/{tier_key}`, idempotent + audited at
  /// the proxy) and refreshes on success. A save error surfaces inline
  /// via `_runAndRefresh`'s `_actionError` banner.
  Future<void> _onEditPlanPricing(PricingPlanCatalogEntry entry) async {
    final command = await showDialog<PricingPlanPricingUpdateCommand>(
      context: context,
      builder: (_) => _PlanPricingDialog(
        entry: entry,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.updatePlanPricing(command);
    }, successHint: 'Plan pricing updated.');
  }

  /// Phase 5a — pull the live feature-entitlements matrix. Best-effort: any
  /// error (endpoint not deployed, demo gateway, transient failure) returns
  /// null so the caller keeps the default ladder. The in-memory demo
  /// gateway returns a seeded matrix, so demo mode still shows an editable
  /// matrix offline.
  Future<List<FeatureEntitlementEntry>?> _fetchEntitlements() async {
    try {
      return await widget.gateway.listEntitlements();
    } catch (_) {
      return null;
    }
  }

  /// Phase 5a — toggle whether one plan includes one feature. Saves through
  /// the gateway
  /// (`PATCH /v1/admin/pricing/entitlements/{tier_key}/{feature_slug}`,
  /// idempotent + audited at the proxy) and refreshes on success. A save
  /// error surfaces inline via `_runAndRefresh`'s `_actionError` banner.
  Future<void> _onToggleEntitlement(
    FeatureEntitlementEntry entry,
    bool enabled,
  ) async {
    final tierName =
        findPricingTierTemplate(entry.tierKey)?.displayName ?? entry.tierKey;
    final featureName = featureSlugDisplayName(entry.featureSlug);
    await _runAndRefresh(
      () async {
        await widget.gateway.updateEntitlement(
          FeatureEntitlementUpdateCommand(
            tierKey: entry.tierKey,
            featureSlug: entry.featureSlug,
            enabled: enabled,
            idempotencyKey: _nextIdempotencyKey(),
          ),
        );
      },
      successHint: enabled
          ? '$tierName now includes $featureName.'
          : '$tierName no longer includes $featureName.',
    );
  }

  /// Phase 2 — pull live month-to-date spend for one operator so the
  /// spend-vs-cap bars show real figures. Best-effort: an empty summary
  /// (demo gateway) or any error leaves `_spendSummaries[operatorId]`
  /// unset, and the bars fall back to the observability envelope.
  Future<void> _fetchSpendSummaryFor(String operatorId) async {
    try {
      final summary = await widget.gateway.fetchSpendSummary(operatorId);
      if (!mounted) return;
      // An empty summary is not stored: that is the demo / endpoint-
      // unavailable case, and storing it would mask the observability
      // fallback behind a phantom "no spend" result.
      if (summary.byLocationAndClass.isEmpty) return;
      setState(() => _spendSummaries[operatorId] = summary);
    } catch (_) {
      // Endpoint not deployed yet or transient failure: keep the
      // observability fallback. No user-facing error for a read.
    }
  }

  Future<void> _fetchScopedContractForCurrentScope() async {
    final selected = _selected;
    final requestScope = selected == null ? null : _contractScopeFor(selected);
    final scopeKey = widget.hierarchyScope?.cacheKey;
    if (requestScope == null || scopeKey == null) return;
    setState(() {
      _scopedContractLoading = true;
      _scopedContractError = null;
      _scopedContractScopeKey = scopeKey;
    });
    try {
      final result = await widget.gateway.fetchEffectiveScopedContract(
        requestScope,
      );
      if (!mounted || widget.hierarchyScope?.cacheKey != scopeKey) return;
      setState(() {
        _scopedContract = result;
        _scopedContractLoading = false;
      });
    } on PricingTierAdminGatewayError catch (error) {
      if (!mounted || widget.hierarchyScope?.cacheKey != scopeKey) return;
      setState(() {
        _scopedContractError = error.message;
        _scopedContractLoading = false;
      });
    } catch (_) {
      if (!mounted || widget.hierarchyScope?.cacheKey != scopeKey) return;
      setState(() {
        _scopedContractError = 'Could not load custom contract terms.';
        _scopedContractLoading = false;
      });
    }
  }

  ScopedPricingContractScope? _contractScopeFor(PricingOperatorBundle bundle) {
    final scope = widget.hierarchyScope;
    if (scope == null) return null;
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return ScopedPricingContractScope(
          operatorId: bundle.operatorId,
          scopeType: ScopedPricingContractScopeType.business,
          displayName: scope.displayLabel,
        );
      case AdminHierarchyScopeType.orgUnit:
        final orgUnitId = scope.orgUnitId;
        if (orgUnitId == null || orgUnitId.isEmpty) return null;
        return ScopedPricingContractScope(
          operatorId: bundle.operatorId,
          scopeType: ScopedPricingContractScopeType.orgUnit,
          orgUnitId: orgUnitId,
          displayName: scope.displayLabel,
        );
      case AdminHierarchyScopeType.location:
        final locationId = scope.locationId;
        if (locationId == null || locationId.isEmpty) return null;
        return ScopedPricingContractScope(
          operatorId: bundle.operatorId,
          scopeType: ScopedPricingContractScopeType.location,
          orgUnitId: scope.orgUnitId,
          locationId: locationId,
          displayName: scope.displayLabel,
        );
    }
  }

  PricingOperatorBundle? get _selected {
    final id = _selectedOperatorId;
    if (id == null) return null;
    for (final b in _visibleBundles) {
      if (b.operatorId == id) return b;
    }
    return null;
  }

  List<PricingOperatorBundle> get _visibleBundles {
    final scope = widget.hierarchyScope;
    if (scope == null) return _bundles;
    return <PricingOperatorBundle>[
      for (final bundle in _bundles)
        if (bundle.operatorId == scope.operatorId) _bundleForScope(bundle),
    ];
  }

  PricingOperatorBundle _bundleForScope(PricingOperatorBundle bundle) {
    final scope = widget.hierarchyScope;
    if (scope == null || scope.isBusinessScope) return bundle;
    final scopedLocationIds = _scopeLocationIds(scope);
    return PricingOperatorBundle(
      operatorId: bundle.operatorId,
      businessName: bundle.businessName,
      subscriptionTier: bundle.subscriptionTier,
      preferredCurrency: bundle.preferredCurrency,
      primaryLocationId: bundle.primaryLocationId,
      primaryLocationName: bundle.primaryLocationName,
      suspended: bundle.suspended,
      caps: bundle.caps
          .where((cap) => scopedLocationIds.contains(cap.locationId))
          .toList(growable: false),
    );
  }

  Set<String> _scopeLocationIds(AdminHierarchyScopeIntent scope) {
    final locationId = scope.locationId;
    if (locationId != null && locationId.isNotEmpty) {
      return <String>{locationId};
    }
    return widget.scopeLocationIds;
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on PricingTierAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Centre + max-width cap matching the shared operator-web body kit.
    return Container(
      key: const Key('admin_pricing_screen'),
      color: AppColors.backgroundDeep,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AdminVisualSystem.screenMaxWidth,
          ),
          child: Padding(
            padding: AdminVisualSystem.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const OperatorWebScreenHeader(
                  icon: Icons.payments_outlined,
                  title: 'Plans and limits',
                  collapseBelowWidth: 0,
                ),
                const SizedBox(height: 16),
                if (!widget.editingEnabled)
                  const _ReadOnlyBanner(
                    key: Key('admin_pricing_readonly_banner'),
                  ),
                if (_actionError != null)
                  _ErrorBanner(
                    key: const Key('admin_pricing_action_error'),
                    message: _actionError!,
                  ),
                _ViewTabs(
                  selected: _view,
                  onSelect: (view) => setState(() => _view = view),
                ),
                const SizedBox(height: 18),
                // Every view (Plans map, Features matrix, and the now
                // single-pane Businesses detail / empty state) is its own
                // scroll view, so the body needs no master/detail floor.
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_pricing_loading'),
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
        key: const Key('admin_pricing_load_error'),
        message: _loadError!,
      );
    }
    if (_view == _PricingView.plans) {
      return _PlansMapView(
        key: const Key('admin_pricing_plans_view'),
        catalog: _planCatalog,
        editingEnabled: widget.editingEnabled,
        onEditPlanPricing: _onEditPlanPricing,
      );
    }
    if (_view == _PricingView.features) {
      return _EntitlementsMatrixView(
        key: const Key('admin_pricing_features_view'),
        entitlements: _entitlements,
        editingEnabled: widget.editingEnabled,
        onToggle: _onToggleEntitlement,
      );
    }
    return _buildBusinessesBody();
  }

  /// Businesses tab body. The left scope tree is the single business
  /// selector now (it drives every other admin screen): this tab shows the
  /// detail for the operator the scope resolves and renders no redundant
  /// master list of its own. The scoped operator is [_selected], set in
  /// [_refresh] strictly from `hierarchyScope.operatorId` (never an
  /// auto-picked first row).
  ///
  /// When no operator resolves (nothing selected in the scope panel, or the
  /// selected scope's operator is not in the gateway result), it shows a
  /// clean empty state rather than crashing or silently picking a random
  /// operator. The distinct "no operators on file" empty state still shows
  /// when the gateway returns no businesses at all.
  Widget _buildBusinessesBody() {
    if (_bundles.isEmpty) {
      return _buildNoOperatorsEmptyState();
    }
    final selected = _selected;
    if (selected == null) {
      return _buildPickBusinessEmptyState();
    }
    return _OperatorPricingDetail(
      bundle: selected,
      observability: _observability,
      spendSummary: _spendSummaries[selected.operatorId],
      scopedContract: _scopedContractScopeKey == widget.hierarchyScope?.cacheKey
          ? _scopedContract
          : null,
      scopedContractLoading: _scopedContractLoading,
      scopedContractError: _scopedContractError,
      editingEnabled: widget.editingEnabled,
      onEditScopedContract: _onEditScopedContract,
      onClearScopedContract: _onClearScopedContract,
      onApplyTemplate: _onApplyTemplate,
      onEditCap: _onEditCap,
      onAddCap: _onAddCap,
      onDeleteCap: _onDeleteCap,
    );
  }

  /// The gateway returned no businesses at all. Distinct from the
  /// "pick a business" prompt (which fires when businesses exist but the
  /// scope has not resolved one).
  Widget _buildNoOperatorsEmptyState() {
    return Center(
      key: const Key('admin_pricing_empty'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No operators on file',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Create an operator first, then return here to review the AI plan and usage limits.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Businesses exist but the scope panel has not resolved one (nothing
  /// picked, or a non-business scope whose operator is absent here). Mirrors
  /// the empty prompt the other scope-driven admin screens use.
  Widget _buildPickBusinessEmptyState() {
    return Center(
      key: const Key('admin_pricing_pick_business'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose a business',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose a business in the scope panel to see its plan and limits.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onEditScopedContract(
    PricingOperatorBundle bundle,
    ScopedPricingContractEffectiveResponse? current,
  ) async {
    final targetScope =
        current?.mutationTarget.scope ?? _contractScopeFor(bundle);
    if (targetScope == null) return;
    final command = await showDialog<ScopedPricingContractSaveCommand>(
      context: context,
      builder: (_) => _ScopedContractDialog(
        scope: targetScope,
        current: current?.effectiveValue,
        existingOverrideId: current?.mutationTarget.existingOverrideId,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.saveScopedContract(command);
    }, successHint: 'Custom contract updated.');
  }

  Future<void> _onClearScopedContract(
    ScopedPricingContractEffectiveResponse contract,
  ) async {
    final overrideId = contract.mutationTarget.existingOverrideId;
    if (overrideId == null || overrideId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Clear this custom contract?',
        message:
            'This scope will inherit pricing from the next parent scope or the global plan catalog.',
        confirmLabel: 'Clear contract',
      ),
    );
    if (confirmed != true) return;
    await _runAndRefresh(() async {
      await widget.gateway.deleteScopedContract(
        ScopedPricingContractDeleteCommand(
          contractOverrideId: overrideId,
          selectedScope: contract.selectedScope,
          adminReason: 'Clear scoped custom contract.',
          idempotencyKey: _nextIdempotencyKey(),
        ),
      );
    }, successHint: 'Custom contract cleared.');
  }

  Future<void> _onApplyTemplate(
    PricingOperatorBundle bundle,
    PricingTierTemplate template,
  ) async {
    // Operator-approved mockup: show a preview diff of exactly which
    // operator/location-level limits this preset adds or changes before
    // applying, instead of a bare "Apply?" confirm.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PresetPreviewDialog(bundle: bundle, template: template),
    );
    if (confirmed != true) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.applyTierTemplate(
        ApplyTierTemplateCommand(
          operatorId: bundle.operatorId,
          tierKey: template.tierKey,
          idempotencyKey: key,
        ),
      );
    }, successHint: '${template.displayName} template applied.');
  }

  Future<void> _onEditCap(PricingOperatorBundle bundle, UsageCapRow row) async {
    final command = await showDialog<UsageCapUpsertCommand>(
      context: context,
      builder: (_) => _UsageCapDialog(
        operatorId: bundle.operatorId,
        primaryLocationId: bundle.primaryLocationId,
        existing: row,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.upsertUsageCap(command);
    }, successHint: 'Usage limit updated.');
  }

  Future<void> _onAddCap(PricingOperatorBundle bundle) async {
    final command = await showDialog<UsageCapUpsertCommand>(
      context: context,
      builder: (_) => _UsageCapDialog(
        operatorId: bundle.operatorId,
        primaryLocationId: _defaultLocationId(bundle),
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.upsertUsageCap(command);
    }, successHint: 'Usage limit added.');
  }

  /// Phase 2 — delete-a-limit. Confirms first (caps gate advisor spend,
  /// so removing one is a real change), then deletes through the
  /// gateway by the cap's logical key. The proxy enforces the same
  /// super_admin gate + writes the audit row.
  Future<void> _onDeleteCap(
    PricingOperatorBundle bundle,
    UsageCapRow row,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Remove this usage limit?',
        message:
            'Removes the ${adminRequestUseCaseLabel(row.usageClass)} limit on '
            '${bundle.businessName}. Advisor spend for this use case will no '
            'longer be capped until you add a new limit. This cannot be '
            'undone.',
        confirmLabel: 'Remove limit',
      ),
    );
    if (confirmed != true) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.deleteUsageCap(
        UsageCapDeleteCommand(
          operatorId: bundle.operatorId,
          locationId: row.locationId,
          usageClass: row.usageClass,
          staffId: row.staffId,
          workflowId: row.workflowId,
          capId: row.capId,
          idempotencyKey: key,
        ),
      );
    }, successHint: 'Usage limit removed.');
  }

  String? _defaultLocationId(PricingOperatorBundle bundle) {
    final scopeLocationId = widget.hierarchyScope?.locationId;
    if (scopeLocationId != null && scopeLocationId.isNotEmpty) {
      return scopeLocationId;
    }
    if (widget.scopeLocationIds.isNotEmpty) {
      return widget.scopeLocationIds.first;
    }
    return bundle.primaryLocationId;
  }
}

// ---------------------------------------------------------------------------
// Shared read-only join helpers (observability -> operator).
// ---------------------------------------------------------------------------

/// Per-operator spend / margin snapshot joined from the observability
/// envelope by `operator_id`. Every number is null when the envelope is
/// missing or has no row for the operator, so callers render the honest
/// empty sentinel instead of a phantom zero.
class _OperatorSpend {
  const _OperatorSpend({
    required this.spendUsd,
    required this.revenueUsd,
    required this.marginRatio,
    required this.health,
  });

  final double? spendUsd;
  final double? revenueUsd;
  final double? marginRatio;
  final _MarginHealth health;

  static const _OperatorSpend empty = _OperatorSpend(
    spendUsd: null,
    revenueUsd: null,
    marginRatio: null,
    health: _MarginHealth.unknown,
  );
}

_OperatorSpend _spendForOperator(
  ObservabilityEnvelope? envelope,
  String operatorId,
) {
  if (envelope == null) return _OperatorSpend.empty;
  final margin = _marginForOperator(envelope, operatorId);
  // Spend is the rolling cost the margin row already carries; fall back
  // to summing the per-class cost telemetry for the operator when no
  // margin row is present.
  final spend =
      margin?.costUsd ?? _costTelemetrySpendForOperator(envelope, operatorId);
  final revenue = margin?.revenueUsd;
  final ratio = margin?.marginRatio;
  return _OperatorSpend(
    spendUsd: spend,
    revenueUsd: revenue,
    marginRatio: (margin != null && (revenue ?? 0) > 0) ? ratio : null,
    health: _healthFor(margin, revenue, spend),
  );
}

MarginEstimateEntry? _marginForOperator(
  ObservabilityEnvelope envelope,
  String operatorId,
) {
  for (final margin in envelope.margins) {
    if (margin.operatorId == operatorId) return margin;
  }
  return null;
}

double? _costTelemetrySpendForOperator(
  ObservabilityEnvelope envelope,
  String operatorId,
) {
  double sum = 0;
  var sawRow = false;
  for (final row in envelope.costTelemetry) {
    if (row.operatorId == operatorId) {
      sum += row.totalUsd;
      sawRow = true;
    }
  }
  return sawRow ? sum : null;
}

_MarginHealth _healthFor(
  MarginEstimateEntry? margin,
  double? revenue,
  double? spend,
) {
  if (margin == null || revenue == null || revenue <= 0) {
    return _MarginHealth.unknown;
  }
  if (margin.isUnderwater) return _MarginHealth.bad;
  final ratio = margin.marginRatio;
  if (ratio < 0.55) return _MarginHealth.thin;
  return _MarginHealth.good;
}

/// Month-to-date spend for one usage limit, joined by operator +
/// usage class. The observability cost rows carry both a coarse
/// `usage_class` (e.g. `advisor_qa`, `workflow`) and a granular
/// `query_class` (e.g. `advisor_qa`, `coach_qa`, `wf_pl`). A cap's
/// `usageClass` (e.g. `coach_qa`, `workflow_pl`) is matched against
/// either, after normalising the workflow aliases, so the spend-vs-cap
/// bar lines up with the cap the admin set. Returns null when no
/// matching telemetry row exists (honest empty, not a zero bar).
double? _spendForCap(
  ObservabilityEnvelope? envelope,
  String operatorId,
  UsageCapRow cap,
) {
  if (envelope == null) return null;
  final target = _normalizeUsageClass(cap.usageClass);
  double sum = 0;
  var matched = false;
  for (final row in envelope.costTelemetry) {
    if (row.operatorId != operatorId) continue;
    final byUsage = _normalizeUsageClass(row.usageClass);
    final byQuery = _normalizeUsageClass(row.queryClass);
    if (byUsage == target || byQuery == target) {
      sum += row.totalUsd;
      matched = true;
    }
  }
  return matched ? sum : null;
}

/// Folds the workflow class aliases together so `workflow`, `wf_pl`,
/// `workflow_pl`, `wf_schedule`, and `workflow_schedule` all compare
/// equal where appropriate. Advisor / coach classes pass through.
String _normalizeUsageClass(String raw) {
  final v = raw.trim().toLowerCase();
  switch (v) {
    case 'wf_pl':
      return 'workflow_pl';
    case 'wf_schedule':
      return 'workflow_schedule';
    default:
      return v;
  }
}

/// Recent cap-breach rows for one operator, joined by `operator_id`.
List<CapEvent> _capEventsForOperator(
  ObservabilityEnvelope? envelope,
  String operatorId,
) {
  if (envelope == null) return const <CapEvent>[];
  return <CapEvent>[
    for (final event in envelope.capEvents)
      if (event.operatorId == operatorId) event,
  ];
}

Color _healthColor(_MarginHealth health) {
  switch (health) {
    case _MarginHealth.good:
      return AppColors.positive;
    case _MarginHealth.thin:
      return AppColors.warning;
    case _MarginHealth.bad:
      return AppColors.negative;
    case _MarginHealth.unknown:
      return AppColors.textMuted;
  }
}

Color _barColor(double ratio) {
  if (ratio >= 0.9) return AppColors.negative;
  if (ratio >= 0.7) return AppColors.warning;
  return AppColors.positive;
}

/// Honest money formatter: the em-dash glyph is the sanctioned
/// empty/missing sentinel (Metric Honesty Doctrine), so a null amount
/// renders as a bare dash rather than a phantom `$0`.
String _money(double? amount) {
  if (amount == null) return '—';
  return '\$${amount.round()}';
}

String _money2(double amount) => '\$${amount.toStringAsFixed(2)}';

// ---------------------------------------------------------------------------
// View tabs.
// ---------------------------------------------------------------------------

class _ViewTabs extends StatelessWidget {
  const _ViewTabs({required this.selected, required this.onSelect});

  final _PricingView selected;
  final ValueChanged<_PricingView> onSelect;

  @override
  Widget build(BuildContext context) {
    // Horizontally scrollable so the three pills never overflow on a
    // narrow (compact) width; the pill visuals are unchanged. shrinkWrap
    // via Align keeps the strip left-aligned and intrinsic-width on wide
    // layouts.
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          decoration: AdminVisualSystem.tabStripDecoration(),
          padding: AdminVisualSystem.tabStripPadding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Tab(
                label: 'Plans',
                tabKey: const Key('admin_pricing_tab_plans'),
                selected: selected == _PricingView.plans,
                onTap: () => onSelect(_PricingView.plans),
              ),
              const SizedBox(width: AdminVisualSystem.tabGap),
              _Tab(
                label: 'Features',
                tabKey: const Key('admin_pricing_tab_features'),
                selected: selected == _PricingView.features,
                onTap: () => onSelect(_PricingView.features),
              ),
              const SizedBox(width: AdminVisualSystem.tabGap),
              _Tab(
                label: 'Businesses',
                tabKey: const Key('admin_pricing_tab_businesses'),
                selected: selected == _PricingView.businesses,
                onTap: () => onSelect(_PricingView.businesses),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.tabKey,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Key tabKey;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AdminVisualSystem.tabRadius),
      child: InkWell(
        key: tabKey,
        borderRadius: BorderRadius.circular(AdminVisualSystem.tabRadius),
        onTap: onTap,
        child: DecoratedBox(
          decoration: AdminVisualSystem.tabDecoration(selected: selected),
          child: Padding(
            padding: AdminVisualSystem.tabPadding,
            child: Text(
              label,
              style: AdminVisualSystem.tabTextStyle(selected: selected),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Plans view (read-only laddered plan map).
// ---------------------------------------------------------------------------

class _PlansMapView extends StatelessWidget {
  const _PlansMapView({
    super.key,
    required this.catalog,
    required this.editingEnabled,
    required this.onEditPlanPricing,
  });

  /// Live (or fallback) plan pricing keyed by tier_key.
  final Map<String, PricingPlanCatalogEntry> catalog;
  final bool editingEnabled;
  final ValueChanged<PricingPlanCatalogEntry> onEditPlanPricing;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) {
              const minCardWidth = 200.0;
              const spacing = 16.0;
              final columns = (constraints.maxWidth / (minCardWidth + spacing))
                  .floor()
                  .clamp(1, kPricingTierTemplates.length);
              final cardWidth =
                  (constraints.maxWidth - (columns - 1) * spacing) / columns;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: <Widget>[
                  for (final template in kPricingTierTemplates)
                    SizedBox(
                      width: cardWidth,
                      height: 360,
                      child: _PlanCard(
                        template: template,
                        entry: catalog[template.tierKey],
                        editingEnabled: editingEnabled,
                        onEdit: onEditPlanPricing,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.template,
    required this.entry,
    required this.editingEnabled,
    required this.onEdit,
  });

  final PricingTierTemplate template;

  /// Live (or fallback) catalog pricing for this plan. Null only if the
  /// catalog has no row for the key (should not happen — the fallback
  /// always carries all six).
  final PricingPlanCatalogEntry? entry;
  final bool editingEnabled;
  final ValueChanged<PricingPlanCatalogEntry> onEdit;

  @override
  Widget build(BuildContext context) {
    final presentation = findPricingPlanPresentation(template.tierKey);
    final advisorCap = _advisorCapUsd(template);
    // Price reads from the editable catalog entry; the static
    // presentation supplies the laddered accent + "what it adds" copy.
    final monthly = entry?.monthlyUsd ?? presentation?.monthlyUsd;
    final seatText = _seatLine(entry, presentation);
    final onboardingText = _onboardingLine(entry, presentation);
    return Container(
      key: Key('admin_pricing_plan_card_${template.tierKey}'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _LadderBar(fraction: presentation?.ladderFraction ?? 0.5),
          const SizedBox(height: 10),
          Text(
            template.displayName,
            style: AppTextStyles.body14(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          _priceRow(monthly),
          const SizedBox(height: 12),
          _PlanCardDetail(label: 'Seats', value: _trimEndingPeriod(seatText)),
          _PlanCardDetail(
            label: 'Advisor cap',
            value: advisorCap == null ? 'Custom' : '${_money(advisorCap)}/mo',
          ),
          _PlanCardDetail(label: 'Onboarding', value: onboardingText),
          const SizedBox(height: 8),
          _MarginTag(label: presentation?.marginEstimate ?? ''),
          const Spacer(),
          ..._editButton(),
        ],
      ),
    );
  }

  /// Price headline row. Renders the monthly price (or "Custom" when the
  /// plan has no fixed monthly) and appends a "/mo" suffix only when a
  /// monthly price exists. Extracted from [build] verbatim.
  Widget _priceRow(double? monthly) {
    final priceText = monthly == null ? 'Custom' : '\$${monthly.round()}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          priceText,
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
        if (monthly != null) ...<Widget>[
          const SizedBox(width: 3),
          Text('/mo', style: AppTextStyles.mono11(color: AppColors.textMuted)),
        ],
      ],
    );
  }

  /// Trailing "Edit pricing" affordance, shown only when editing is
  /// enabled and a catalog entry exists. Returns an empty list otherwise
  /// so the caller can spread it into the card column. Extracted from
  /// [build] verbatim.
  List<Widget> _editButton() {
    if (!editingEnabled || entry == null) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: AdminActionButton(
          key: Key('admin_pricing_plan_edit_${template.tierKey}'),
          label: 'Edit pricing',
          onPressed: () => onEdit(entry!),
          icon: Icons.edit_outlined,
          compact: true,
        ),
      ),
    ];
  }

  /// Per-seat line built from the editable catalog entry, falling back to
  /// the static presentation copy. No em dash (UX no-em-dash law): uses a
  /// comma + "then" for the seat ramp.
  static String _seatLine(
    PricingPlanCatalogEntry? entry,
    PricingPlanPresentation? presentation,
  ) {
    if (entry == null) return presentation?.seatLine ?? '';
    final first = entry.firstSeatUsd;
    if (first == null || first == 0) {
      return entry.monthlyUsd == null ? 'Custom' : 'No seat fee';
    }
    final band = entry.firstNSeats;
    final additional = entry.additionalSeatUsd;
    if (band != null && additional != null) {
      return '${_money(first)}/seat first $band, then ${_money(additional)}.';
    }
    return '${_money(first)}/seat.';
  }

  /// Onboarding range line from the editable catalog entry, falling back
  /// to the static presentation copy. Uses "to" for the range (no em
  /// dash); a $0 range reads "self-serve".
  static String _onboardingLine(
    PricingPlanCatalogEntry? entry,
    PricingPlanPresentation? presentation,
  ) {
    if (entry == null) return presentation?.onboardingRange ?? 'Custom';
    final min = entry.onboardingMinUsd;
    final max = entry.onboardingMaxUsd;
    if (min == null && max == null) {
      // Custom / unset. Prefer the static copy (e.g. "Custom" /
      // "$0 (self-serve)") when it carries meaning.
      return presentation?.onboardingRange ?? 'Custom';
    }
    return _onboardingRangeLine(min, max);
  }

  static String _onboardingRangeLine(double? min, double? max) {
    final lower = min ?? 0;
    final upper = max ?? 0;
    if (lower == 0 && upper == 0) return r'$0 (self-serve)';
    if (min == null || max == null) return _money(min ?? max);
    return '${_money(min)} to ${_money(max)}';
  }

  static double? _advisorCapUsd(PricingTierTemplate template) {
    for (final cap in template.caps) {
      if (cap.usageClass == 'advisor_qa') return cap.monthlyCapUsd;
    }
    return null;
  }

  static String _trimEndingPeriod(String value) {
    final trimmed = value.trim();
    if (trimmed.endsWith('.')) return trimmed.substring(0, trimmed.length - 1);
    return trimmed;
  }
}

class _PlanCardDetail extends StatelessWidget {
  const _PlanCardDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: AppTextStyles.body11(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body11(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _LadderBar extends StatelessWidget {
  const _LadderBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction.clamp(0.0, 1.0),
        child: Container(
          height: 4,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: const LinearGradient(
              colors: <Color>[AppColors.peacock, AppColors.sunset],
            ),
          ),
        ),
      ),
    );
  }
}

class _MarginTag extends StatelessWidget {
  const _MarginTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final isTrial = label.toLowerCase().contains('trial');
    final color = isTrial ? AppColors.textMuted : AppColors.positive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono11(
          color: color,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Included features view (Phase 5a — editable feature-entitlements matrix).
// ---------------------------------------------------------------------------

/// Shows which features each of the six plans includes, with a per-cell
/// on/off toggle. Reads the live `feature_entitlements` matrix (falling
/// back to the default cumulative ladder offline) and saves each toggle
/// through `PATCH /v1/admin/pricing/entitlements/{tier_key}/{feature_slug}`.
/// FOUNDATION ONLY: recording the matrix does not gate the app yet
/// (deferred Phase 5d). Matches the Plans view look (the same surface card
/// + accent tokens), not a new style. When `editingEnabled` is false the
/// switches render disabled (the `ff_support` read-only walkthrough).
class _EntitlementsMatrixView extends StatelessWidget {
  const _EntitlementsMatrixView({
    super.key,
    required this.entitlements,
    required this.editingEnabled,
    required this.onToggle,
  });

  /// Live (or default) entitlements keyed by `tier_key::feature_slug`.
  final Map<String, FeatureEntitlementEntry> entitlements;
  final bool editingEnabled;

  /// Called with the current entry + the requested new value when a cell
  /// is toggled.
  final void Function(FeatureEntitlementEntry entry, bool enabled) onToggle;

  FeatureEntitlementEntry _entryFor(String tierKey, String slug) {
    return entitlements['$tierKey::$slug'] ??
        FeatureEntitlementEntry(
          tierKey: tierKey,
          featureSlug: slug,
          enabled: false,
        );
  }

  @override
  Widget build(BuildContext context) {
    // Material ancestor so the per-cell Switch widgets (which require one)
    // render. Transparent so it does not paint over the screen surface.
    return Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'What each plan includes. Turn a feature on or off for a plan. '
              'This sets the plan map; it does not change what any business '
              'sees yet.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            for (final template in kPricingTierTemplates) ...<Widget>[
              _EntitlementsPlanRow(
                template: template,
                entries: <FeatureEntitlementEntry>[
                  for (final slug in kFeatureSlugOrder)
                    _entryFor(template.tierKey, slug),
                ],
                editingEnabled: editingEnabled,
                onToggle: onToggle,
              ),
              const SizedBox(height: 12),
            ],
            _EntitlementsFootnote(editingEnabled: editingEnabled),
          ],
        ),
      ),
    );
  }
}

/// One plan's row in the included-features matrix: the plan name plus a
/// wrapped set of per-feature on/off toggles. Uses the same surface card
/// as the Plans view so the two tabs read as one screen.
class _EntitlementsPlanRow extends StatelessWidget {
  const _EntitlementsPlanRow({
    required this.template,
    required this.entries,
    required this.editingEnabled,
    required this.onToggle,
  });

  final PricingTierTemplate template;
  final List<FeatureEntitlementEntry> entries;
  final bool editingEnabled;
  final void Function(FeatureEntitlementEntry entry, bool enabled) onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_pricing_entitlements_row_${template.tierKey}'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            template.displayName,
            style: AppTextStyles.mono16(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 12,
            children: <Widget>[
              for (final entry in entries)
                _EntitlementCell(
                  entry: entry,
                  editingEnabled: editingEnabled,
                  onToggle: onToggle,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One on/off cell: a feature label + a Switch. The switch is disabled
/// when editing is off (read-only walkthrough); the proxy enforces the
/// same gate server-side.
class _EntitlementCell extends StatelessWidget {
  const _EntitlementCell({
    required this.entry,
    required this.editingEnabled,
    required this.onToggle,
  });

  final FeatureEntitlementEntry entry;
  final bool editingEnabled;
  final void Function(FeatureEntitlementEntry entry, bool enabled) onToggle;

  @override
  Widget build(BuildContext context) {
    // Fixed-width cell so the Wrap lays cells out in even columns. The
    // Row fills that width (default MainAxisSize.max) so the Flexible text
    // gets a bounded width — a min-sized Row would hand the Flexible
    // unbounded width and overflow.
    return SizedBox(
      width: 180,
      child: Row(
        children: <Widget>[
          // Bare switch inside a dense fixed-width matrix cell: the shared
          // SwitchTheme (AppTheme) gives it the same accent ON / calm OFF
          // treatment as every other console switch, so no per-call colour.
          Switch(
            key: Key(
              'admin_pricing_entitlement_toggle_'
              '${entry.tierKey}_${entry.featureSlug}',
            ),
            value: entry.enabled,
            onChanged: editingEnabled
                ? (value) => onToggle(entry, value)
                : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              featureSlugDisplayName(entry.featureSlug),
              style: AppTextStyles.body13(
                color: entry.enabled
                    ? AppColors.textPrimary
                    : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EntitlementsFootnote extends StatelessWidget {
  const _EntitlementsFootnote({required this.editingEnabled});

  final bool editingEnabled;

  @override
  Widget build(BuildContext context) {
    return OperatorWebBanner(
      icon: Icons.info_outline,
      message: editingEnabled
          ? 'These switches record which features each plan includes. They '
                'are a starting default you can adjust. Changing them does '
                'not yet show or hide anything for a business.'
          : 'These switches record which features each plan includes (view '
                'only). They do not yet show or hide anything for a '
                'business.',
    );
  }
}

// ---------------------------------------------------------------------------
// Businesses view: banners.
//
// The redundant per-business master list was removed: the left scope tree
// (`hierarchyScope`) is the single business selector, matching every other
// admin screen. The Businesses tab renders the selected operator's detail
// directly (see `_buildBusinessesBody`).
// ---------------------------------------------------------------------------

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        icon: Icons.lock_outline,
        message: 'View only: pricing edits require ecosystem admin access.',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Businesses view: detail.
// ---------------------------------------------------------------------------

class _OperatorPricingDetail extends StatelessWidget {
  const _OperatorPricingDetail({
    required this.bundle,
    required this.observability,
    required this.spendSummary,
    required this.scopedContract,
    required this.scopedContractLoading,
    required this.scopedContractError,
    required this.editingEnabled,
    required this.onEditScopedContract,
    required this.onClearScopedContract,
    required this.onApplyTemplate,
    required this.onEditCap,
    required this.onAddCap,
    required this.onDeleteCap,
  });

  final PricingOperatorBundle bundle;
  final ObservabilityEnvelope? observability;
  final OperatorSpendSummary? spendSummary;
  final ScopedPricingContractEffectiveResponse? scopedContract;
  final bool scopedContractLoading;
  final String? scopedContractError;
  final bool editingEnabled;
  final void Function(
    PricingOperatorBundle,
    ScopedPricingContractEffectiveResponse?,
  )
  onEditScopedContract;
  final void Function(ScopedPricingContractEffectiveResponse)
  onClearScopedContract;
  final void Function(PricingOperatorBundle, PricingTierTemplate)
  onApplyTemplate;
  final void Function(PricingOperatorBundle, UsageCapRow) onEditCap;
  final void Function(PricingOperatorBundle) onAddCap;
  final void Function(PricingOperatorBundle, UsageCapRow) onDeleteCap;

  @override
  Widget build(BuildContext context) {
    final spend = _spendForOperator(observability, bundle.operatorId);
    final hits = _capEventsForOperator(observability, bundle.operatorId);
    return SingleChildScrollView(
      key: Key('admin_pricing_detail_${bundle.operatorId}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ScopedContractCard(
            bundle: bundle,
            contract: scopedContract,
            loading: scopedContractLoading,
            error: scopedContractError,
            editingEnabled: editingEnabled,
            onEdit: onEditScopedContract,
            onClear: onClearScopedContract,
          ),
          const SizedBox(height: 14),
          _PlanMarginCard(bundle: bundle, spend: spend),
          const SizedBox(height: 14),
          if (hits.isNotEmpty) ...<Widget>[
            _RecentHitsCard(hits: hits),
            const SizedBox(height: 14),
          ],
          if (editingEnabled) ...<Widget>[
            _PlanPresetsCard(bundle: bundle, onApplyTemplate: onApplyTemplate),
            const SizedBox(height: 14),
          ],
          _UsageLimitsCard(
            bundle: bundle,
            observability: observability,
            spendSummary: spendSummary,
            editingEnabled: editingEnabled,
            onEdit: onEditCap,
            onAdd: onAddCap,
            onDelete: onDeleteCap,
          ),
        ],
      ),
    );
  }
}

class _ScopedContractCard extends StatelessWidget {
  const _ScopedContractCard({
    required this.bundle,
    required this.contract,
    required this.loading,
    required this.error,
    required this.editingEnabled,
    required this.onEdit,
    required this.onClear,
  });

  final PricingOperatorBundle bundle;
  final ScopedPricingContractEffectiveResponse? contract;
  final bool loading;
  final String? error;
  final bool editingEnabled;
  final void Function(
    PricingOperatorBundle,
    ScopedPricingContractEffectiveResponse?,
  )
  onEdit;
  final void Function(ScopedPricingContractEffectiveResponse) onClear;

  @override
  Widget build(BuildContext context) {
    final value = contract?.effectiveValue;
    return OperatorWebPanel(
      title: 'Custom contract',
      padding: const EdgeInsets.all(16),
      trailing: editingEnabled
          ? Wrap(
              spacing: 8,
              children: <Widget>[
                if (contract?.mutationTarget.canDelete == true)
                  AdminActionButton(
                    key: const Key('admin_pricing_clear_contract_button'),
                    label: 'Clear',
                    icon: Icons.close,
                    onPressed: () => onClear(contract!),
                  ),
                AdminActionButton(
                  key: const Key('admin_pricing_edit_contract_button'),
                  label: 'Edit',
                  icon: Icons.edit_outlined,
                  onPressed: () => onEdit(bundle, contract),
                ),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Loading contract terms...',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            )
          else if (error != null)
            Text(error!, style: AppTextStyles.body13(color: AppColors.negative))
          else ...<Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _StatusPill(label: _contractStatusLabel(contract)),
                Text(
                  _contractSourceLabel(contract),
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _PricingSummaryGrid(
              items: <_PricingSummaryItem>[
                _PricingSummaryItem(
                  label: 'Scope',
                  value:
                      contract?.selectedScope.displayName ??
                      bundle.businessName,
                ),
                _PricingSummaryItem(
                  label: 'Plan',
                  value: _tierDisplayName(
                    value?.tierKey ?? bundle.subscriptionTier,
                  ),
                ),
                _PricingSummaryItem(
                  label: 'Monthly',
                  value: _money(value?.monthlyUsd),
                ),
                _PricingSummaryItem(
                  label: 'Advisor cap',
                  value: value?.advisorCapMonthlyUsd == null
                      ? 'Custom'
                      : '${_money(value!.advisorCapMonthlyUsd)}/mo',
                ),
                if (value?.contractLabel != null &&
                    value!.contractLabel!.isNotEmpty)
                  _PricingSummaryItem(
                    label: 'Contract',
                    value: value.contractLabel!,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PricingSummaryItem {
  const _PricingSummaryItem({required this.label, required this.value});

  final String label;
  final String value;
}

class _PricingSummaryGrid extends StatelessWidget {
  const _PricingSummaryGrid({required this.items});

  final List<_PricingSummaryItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 520 ? 2 : 4;
        const spacing = 16.0;
        final itemWidth =
            (constraints.maxWidth - (columns - 1) * spacing) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: 14,
          children: <Widget>[
            for (final item in items)
              SizedBox(
                width: itemWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.label,
                      style: AppTextStyles.body11(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body14(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono11(
          color: AppColors.peacockDark,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _PlanMarginCard extends StatelessWidget {
  const _PlanMarginCard({required this.bundle, required this.spend});

  final PricingOperatorBundle bundle;
  final _OperatorSpend spend;

  @override
  Widget build(BuildContext context) {
    final presentation = findPricingPlanPresentation(bundle.subscriptionTier);
    return OperatorWebPanel(
      title: 'Plan and margin',
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _PricingSummaryGrid(
            items: <_PricingSummaryItem>[
              _PricingSummaryItem(
                label: 'Plan',
                value: _tierDisplayName(bundle.subscriptionTier),
              ),
              _PricingSummaryItem(
                label: 'Pricing',
                value: presentation?.priceLine ?? 'Per contract',
              ),
              _PricingSummaryItem(
                label: 'Spent',
                value: _money(spend.spendUsd),
              ),
              _PricingSummaryItem(
                label: 'Revenue',
                value: _money(spend.revenueUsd),
              ),
              _PricingSummaryItem(
                label: 'Currency',
                value: bundle.preferredCurrency,
              ),
              _PricingSummaryItem(
                label: 'Primary location',
                value: _primaryLocationLabel(bundle),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _MarginPill(spend: spend),
          const SizedBox(height: 4),
          _PricingAdvancedDetails(
            keyName: 'admin_pricing_operator_details_${bundle.operatorId}',
            title: 'Plan details',
            rows: <_PricingDetail>[
              _PricingDetail(label: 'Operator ID', value: bundle.operatorId),
              _PricingDetail(label: 'Plan key', value: bundle.subscriptionTier),
              if (bundle.primaryLocationId != null)
                _PricingDetail(
                  label: 'Primary location ID',
                  value: bundle.primaryLocationId!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MarginPill extends StatelessWidget {
  const _MarginPill({required this.spend});

  final _OperatorSpend spend;

  @override
  Widget build(BuildContext context) {
    final ratio = spend.marginRatio;
    final color = _healthColor(spend.health);
    final text = ratio == null
        ? 'No margin yet'
        : '${(ratio * 100).round()}% margin';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: AppTextStyles.mono14(color: color, weight: FontWeight.w700),
      ),
    );
  }
}

class _RecentHitsCard extends StatelessWidget {
  const _RecentHitsCard({required this.hits});

  final List<CapEvent> hits;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      title: 'Recent limit hits',
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final hit in hits)
            Padding(
              key: Key('admin_pricing_hit_${hit.eventId}'),
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.bolt_outlined,
                    size: 18,
                    color: AppColors.negative,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: adminRequestUseCaseLabel(hit.queryClass),
                            style: AppTextStyles.body13(
                              color: AppColors.textPrimary,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(
                            text:
                                ' refused at ${_money2(hit.capUsd)} cap '
                                '(tried ${_money2(hit.attemptedUsd)}).',
                            style: AppTextStyles.body13(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
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

class _PlanPresetsCard extends StatelessWidget {
  const _PlanPresetsCard({required this.bundle, required this.onApplyTemplate});

  final PricingOperatorBundle bundle;
  final void Function(PricingOperatorBundle, PricingTierTemplate)
  onApplyTemplate;

  @override
  Widget build(BuildContext context) {
    final current = bundle.subscriptionTier.trim().toLowerCase();
    return OperatorWebPanel(
      title: 'Change plan',
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final template in kPricingTierTemplates)
            _PresetTile(
              template: template,
              isCurrent:
                  template.tierKey.toLowerCase() == current ||
                  template.subscriptionTier.toLowerCase() == current,
              onTap: () => onApplyTemplate(bundle, template),
            ),
        ],
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.template,
    required this.isCurrent,
    required this.onTap,
  });

  final PricingTierTemplate template;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final presentation = findPricingPlanPresentation(template.tierKey);
    return SizedBox(
      width: 160,
      child: OutlinedButton(
        key: Key('admin_pricing_template_${template.tierKey}_button'),
        onPressed: onTap,
        style:
            AdminButtonStyles.secondary(
              minWidth: 160,
              minHeight: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              borderColor: isCurrent
                  ? AppColors.sunsetDark
                  : AppColors.borderSubtle,
              emphasized: isCurrent,
            ).copyWith(
              alignment: Alignment.centerLeft,
              backgroundColor: WidgetStatePropertyAll(
                isCurrent
                    ? AppColors.sunset.withValues(alpha: 0.08)
                    : AppColors.backgroundSurface,
              ),
            ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    template.displayName,
                    style: AppTextStyles.mono14(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isCurrent)
                  Text(
                    'CURRENT',
                    style: AppTextStyles.mono8(
                      color: AppColors.peacockDark,
                    ).copyWith(fontWeight: FontWeight.w700),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              presentation?.priceLine ?? template.summary,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageLimitsCard extends StatelessWidget {
  const _UsageLimitsCard({
    required this.bundle,
    required this.observability,
    required this.spendSummary,
    required this.editingEnabled,
    required this.onEdit,
    required this.onAdd,
    required this.onDelete,
  });

  final PricingOperatorBundle bundle;
  final ObservabilityEnvelope? observability;
  final OperatorSpendSummary? spendSummary;
  final bool editingEnabled;
  final void Function(PricingOperatorBundle, UsageCapRow) onEdit;
  final void Function(PricingOperatorBundle) onAdd;
  final void Function(PricingOperatorBundle, UsageCapRow) onDelete;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      title: 'Usage limits',
      padding: const EdgeInsets.all(16),
      trailing: editingEnabled
          ? AdminActionButton(
              key: const Key('admin_pricing_add_cap_button'),
              label: 'Add usage limit',
              onPressed: () => onAdd(bundle),
              icon: Icons.add,
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (bundle.caps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No usage limits yet. Apply a plan above or add one limit.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            )
          else
            ...bundle.caps.map(
              (row) => _UsageCapRowTile(
                bundle: bundle,
                row: row,
                // Phase 2: prefer the live spend-summary figure; fall
                // back to the observability envelope (demo / endpoint
                // unavailable) so the bar still paints.
                spendUsd:
                    spendSummary?.spendFor(row.locationId, row.usageClass) ??
                    _spendForCap(observability, bundle.operatorId, row),
                editingEnabled: editingEnabled,
                onEdit: onEdit,
                onDelete: onDelete,
              ),
            ),
        ],
      ),
    );
  }
}

String _primaryLocationLabel(PricingOperatorBundle bundle) {
  final name = bundle.primaryLocationName?.trim();
  if (name != null && name.isNotEmpty) return name;
  if (bundle.primaryLocationId != null) return 'Primary location selected';
  return 'No primary location';
}

String _tierDisplayName(String tier) {
  final normalized = tier.trim().toLowerCase();
  for (final template in kPricingTierTemplates) {
    if (template.subscriptionTier.toLowerCase() == normalized ||
        template.tierKey.toLowerCase() == normalized) {
      return template.displayName;
    }
  }
  if (normalized.isEmpty) return 'Unknown plan';
  return normalized
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map(
        (part) => part.length == 1
            ? part.toUpperCase()
            : '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

String _contractStatusLabel(ScopedPricingContractEffectiveResponse? contract) {
  switch (contract?.overrideStatus) {
    case ScopedPricingContractOverrideStatus.setHere:
      return 'Set here';
    case ScopedPricingContractOverrideStatus.inherited:
      return 'Inherited';
    case ScopedPricingContractOverrideStatus.catalogDefault:
      return 'Catalog default';
    case null:
      return 'Not loaded';
  }
}

String _contractSourceLabel(ScopedPricingContractEffectiveResponse? contract) {
  if (contract == null) return 'Pricing catalog';
  final source = contract.inheritedSource;
  if (contract.overrideStatus == ScopedPricingContractOverrideStatus.setHere) {
    return contract.selectedScope.displayName ?? 'Selected scope';
  }
  if (contract.overrideStatus ==
      ScopedPricingContractOverrideStatus.catalogDefault) {
    return source.displayName ?? 'Global catalog';
  }
  return source.displayName ?? source.scope?.displayName ?? 'Parent scope';
}

/// Inheritance source label: DISPLAY ONLY. A cap whose `location_id`
/// matches the operator's primary location is treated as "Set here";
/// any other scope is shown as "Inherited". No inheritance backend is
/// resolved here - this only surfaces the scope the existing data
/// already carries.
String _inheritanceLabel(PricingOperatorBundle bundle, UsageCapRow row) {
  final primary = bundle.primaryLocationId;
  if (primary != null && row.locationId == primary) return 'Set here';
  return 'Inherited';
}

String _limitScopeLabel(UsageCapRow row) {
  final parts = <String>[];
  if (row.staffId != null) parts.add('specific staff member');
  if (row.workflowId != null) parts.add('specific workflow');
  if (parts.isEmpty) return 'Applies to all staff and workflows';
  return 'Applies to ${parts.join(' and ')}';
}

class _PricingDetail {
  const _PricingDetail({required this.label, required this.value});

  final String label;
  final String value;
}

class _PricingAdvancedDetails extends StatelessWidget {
  const _PricingAdvancedDetails({
    required this.keyName,
    required this.title,
    required this.rows,
  });

  final String keyName;
  final String title;
  final List<_PricingDetail> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: Key(keyName),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
          title: Text(
            title,
            style: AppTextStyles.mono8(
              color: AppColors.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          children: <Widget>[
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 140,
                      child: Text(
                        row.label,
                        style: AppTextStyles.mono10(color: AppColors.textMuted),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        row.value,
                        style: AppTextStyles.mono10(
                          color: AppColors.textSecondary,
                        ),
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
}

class _UsageCapRowTile extends StatelessWidget {
  const _UsageCapRowTile({
    required this.bundle,
    required this.row,
    required this.spendUsd,
    required this.editingEnabled,
    required this.onEdit,
    required this.onDelete,
  });

  final PricingOperatorBundle bundle;
  final UsageCapRow row;
  final double? spendUsd;
  final bool editingEnabled;
  final void Function(PricingOperatorBundle, UsageCapRow) onEdit;
  final void Function(PricingOperatorBundle, UsageCapRow) onDelete;

  @override
  Widget build(BuildContext context) {
    final keySuffix =
        row.capId ??
        '${row.locationId}:${row.usageClass}:${row.staffId ?? ''}:${row.workflowId ?? ''}';
    final cap = row.monthlyCapUsd;
    final ratio = (spendUsd != null && cap > 0)
        ? (spendUsd! / cap).clamp(0.0, 1.0)
        : null;
    return Container(
      key: Key('admin_pricing_cap_$keySuffix'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  adminRequestUseCaseLabel(row.usageClass),
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _inheritanceLabel(bundle, row),
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
              if (editingEnabled)
                AdminActionBar(
                  spacing: 4,
                  runSpacing: 4,
                  children: <Widget>[
                    AdminIconAction(
                      key: Key('admin_pricing_cap_edit_$keySuffix'),
                      icon: Icons.edit_outlined,
                      tooltip: 'Edit usage limit',
                      onPressed: () => onEdit(bundle, row),
                    ),
                    AdminIconAction(
                      key: Key('admin_pricing_cap_delete_$keySuffix'),
                      icon: Icons.delete_outline,
                      tooltip: 'Remove usage limit',
                      onPressed: () => onDelete(bundle, row),
                      destructive: true,
                    ),
                  ],
                ),
            ],
          ),
          if (row.staffId != null || row.workflowId != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              _limitScopeLabel(row),
              style: AppTextStyles.mono8(color: AppColors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 9),
          _SpendVsCapBar(spendUsd: spendUsd, capUsd: cap, ratio: ratio),
          const SizedBox(height: 7),
          Text(
            '${_money2(row.perInvocationCapUsd)} per request · '
            'Updated ${adminHumanDateTime(row.updatedAt)}',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
            overflow: TextOverflow.ellipsis,
          ),
          _PricingAdvancedDetails(
            keyName: 'admin_pricing_cap_details_$keySuffix',
            title: 'Limit details',
            rows: <_PricingDetail>[
              if (row.capId != null)
                _PricingDetail(label: 'Limit ID', value: row.capId!),
              _PricingDetail(label: 'Use case ID', value: row.usageClass),
              _PricingDetail(label: 'Location ID', value: row.locationId),
              if (row.staffId != null)
                _PricingDetail(label: 'Staff member ID', value: row.staffId!),
              if (row.workflowId != null)
                _PricingDetail(label: 'Workflow ID', value: row.workflowId!),
              if (row.updatedBy != null)
                _PricingDetail(label: 'Updated by', value: row.updatedBy!),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpendVsCapBar extends StatelessWidget {
  const _SpendVsCapBar({
    required this.spendUsd,
    required this.capUsd,
    required this.ratio,
  });

  final double? spendUsd;
  final double capUsd;
  final double? ratio;

  @override
  Widget build(BuildContext context) {
    final r = ratio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${_money(spendUsd)} / ${_money(capUsd)} this month',
                style: AppTextStyles.mono11(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              r == null ? '—' : '${(r * 100).round()}%',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Stack(
            children: <Widget>[
              Container(height: 7, color: AppColors.cardGlow),
              if (r != null)
                FractionallySizedBox(
                  widthFactor: r,
                  child: Container(height: 7, color: _barColor(r)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add / edit usage-limit dialog (cap upsert through the pricing gateway).
// ---------------------------------------------------------------------------

/// Phase 3 — edit one plan's pricing. Seeded with the current catalog
/// values; an empty field clears the value to a genuine SQL NULL (e.g.
/// Enterprise has no monthly price, no-seat plans have null seat fees),
/// matching the nullable proxy body fields. Returns a
/// [PricingPlanPricingUpdateCommand] on save, null on cancel.
class _ScopedContractDialog extends StatefulWidget {
  const _ScopedContractDialog({
    required this.scope,
    required this.current,
    required this.idempotencyKey,
    this.existingOverrideId,
  });

  final ScopedPricingContractScope scope;
  final ScopedPricingContractValue? current;
  final String? existingOverrideId;
  final String idempotencyKey;

  @override
  State<_ScopedContractDialog> createState() => _ScopedContractDialogState();
}

class _ScopedContractDialogState extends State<_ScopedContractDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _monthly;
  late final TextEditingController _advisorCap;
  late final TextEditingController _label;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    _monthly = TextEditingController(text: _numText(current?.monthlyUsd));
    _advisorCap = TextEditingController(
      text: _numText(current?.advisorCapMonthlyUsd),
    );
    _label = TextEditingController(text: current?.contractLabel ?? '');
    _note = TextEditingController(text: current?.internalNote ?? '');
  }

  @override
  void dispose() {
    _monthly.dispose();
    _advisorCap.dispose();
    _label.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_pricing_scoped_contract_dialog'),
      title: 'Edit custom contract',
      icon: Icons.assignment_outlined,
      maxWidth: 540,
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_pricing_contract_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_pricing_contract_submit_button'),
          label: 'Save',
          onPressed: _onSubmit,
          role: AdminActionRole.primary,
        ),
      ],
      child: Flexible(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _DialogSection(
                  title: 'Scope',
                  child: AdminDetailRow(
                    label: 'Selected scope',
                    value: widget.scope.displayName ?? 'Selected scope',
                  ),
                ),
                _DialogSection(
                  title: 'Terms',
                  child: _DialogFieldGrid(
                    children: <Widget>[
                      _LabelledField(
                        label: 'Monthly terms',
                        controller: _monthly,
                        fieldKey: const Key('admin_pricing_contract_monthly'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _optionalDecimalValidator,
                      ),
                      _LabelledField(
                        label: 'Advisor cap',
                        controller: _advisorCap,
                        fieldKey: const Key(
                          'admin_pricing_contract_advisor_cap',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _optionalDecimalValidator,
                      ),
                    ],
                  ),
                ),
                _DialogSection(
                  title: 'Notes',
                  child: Column(
                    children: <Widget>[
                      _LabelledField(
                        label: 'Contract label',
                        controller: _label,
                        fieldKey: const Key('admin_pricing_contract_label'),
                      ),
                      _LabelledField(
                        label: 'Internal note',
                        controller: _note,
                        fieldKey: const Key('admin_pricing_contract_note'),
                        maxLines: 3,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onSubmit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final current = widget.current;
    Navigator.of(context).pop(
      ScopedPricingContractSaveCommand(
        targetScope: widget.scope,
        contractOverrideId: widget.existingOverrideId,
        value: ScopedPricingContractValue(
          tierKey: 'enterprise',
          monthlyUsd: _parseNullableDouble(_monthly.text),
          firstNSeats: current?.firstNSeats,
          firstSeatUsd: current?.firstSeatUsd,
          additionalSeatUsd: current?.additionalSeatUsd,
          onboardingMinUsd: current?.onboardingMinUsd,
          onboardingMaxUsd: current?.onboardingMaxUsd,
          advisorCapMonthlyUsd: _parseNullableDouble(_advisorCap.text),
          billingOwnerOrgUnitId: current?.billingOwnerOrgUnitId,
          effectiveFrom: current?.effectiveFrom,
          effectiveUntil: current?.effectiveUntil,
          contractLabel: _blankToNull(_label.text),
          internalNote: _blankToNull(_note.text),
        ),
        adminReason: 'Set scoped custom contract.',
        idempotencyKey: widget.idempotencyKey,
      ),
    );
  }

  static String _numText(double? value) {
    if (value == null) return '';
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toStringAsFixed(2);
  }

  static double? _parseNullableDouble(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return double.tryParse(trimmed);
  }

  static String? _blankToNull(String raw) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _PlanPricingDialog extends StatefulWidget {
  const _PlanPricingDialog({required this.entry, required this.idempotencyKey});

  final PricingPlanCatalogEntry entry;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

  @override
  State<_PlanPricingDialog> createState() => _PlanPricingDialogState();
}

class _PlanPricingDialogState extends State<_PlanPricingDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _monthly;
  late final TextEditingController _firstNSeats;
  late final TextEditingController _firstSeat;
  late final TextEditingController _additionalSeat;
  late final TextEditingController _onboardingMin;
  late final TextEditingController _onboardingMax;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _monthly = TextEditingController(text: _numText(e.monthlyUsd));
    _firstNSeats = TextEditingController(
      text: e.firstNSeats == null ? '' : '${e.firstNSeats}',
    );
    _firstSeat = TextEditingController(text: _numText(e.firstSeatUsd));
    _additionalSeat = TextEditingController(
      text: _numText(e.additionalSeatUsd),
    );
    _onboardingMin = TextEditingController(text: _numText(e.onboardingMinUsd));
    _onboardingMax = TextEditingController(text: _numText(e.onboardingMaxUsd));
  }

  /// Render a nullable money value as an editable string; null stays
  /// blank so a blank field round-trips back to null on save.
  static String _numText(double? value) {
    if (value == null) return '';
    // Whole numbers render without a trailing ".0"; fractional values
    // keep two decimals so $5.50 stays $5.50.
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _monthly.dispose();
    _firstNSeats.dispose();
    _firstSeat.dispose();
    _additionalSeat.dispose();
    _onboardingMin.dispose();
    _onboardingMax.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayName =
        findPricingTierTemplate(widget.entry.tierKey)?.displayName ??
        widget.entry.tierKey;
    return OperatorWebDialog(
      key: const Key('admin_pricing_plan_dialog'),
      title: 'Edit $displayName pricing',
      icon: Icons.payments_outlined,
      maxWidth: 540,
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_pricing_plan_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_pricing_plan_submit_button'),
          label: 'Save',
          onPressed: _onSubmit,
          role: AdminActionRole.primary,
        ),
      ],
      child: Flexible(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _DialogSection(
                  title: 'Price',
                  child: _LabelledField(
                    label: 'Monthly fee',
                    controller: _monthly,
                    fieldKey: const Key('admin_pricing_plan_monthly'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^[0-9]*\.?[0-9]*'),
                      ),
                    ],
                    validator: _optionalDecimalValidator,
                  ),
                ),
                _DialogSection(
                  title: 'Seats',
                  child: _DialogFieldGrid(
                    children: <Widget>[
                      _LabelledField(
                        label: 'First seats',
                        controller: _firstNSeats,
                        fieldKey: const Key('admin_pricing_plan_first_n_seats'),
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        validator: _optionalIntValidator,
                      ),
                      _LabelledField(
                        label: 'First seat',
                        controller: _firstSeat,
                        fieldKey: const Key('admin_pricing_plan_first_seat'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _optionalDecimalValidator,
                      ),
                      _LabelledField(
                        label: 'Added seat',
                        controller: _additionalSeat,
                        fieldKey: const Key(
                          'admin_pricing_plan_additional_seat',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _optionalDecimalValidator,
                      ),
                    ],
                  ),
                ),
                _DialogSection(
                  title: 'Onboarding',
                  child: _DialogFieldGrid(
                    children: <Widget>[
                      _LabelledField(
                        label: 'Minimum',
                        controller: _onboardingMin,
                        fieldKey: const Key(
                          'admin_pricing_plan_onboarding_min',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _optionalDecimalValidator,
                      ),
                      _LabelledField(
                        label: 'Maximum',
                        controller: _onboardingMax,
                        fieldKey: const Key(
                          'admin_pricing_plan_onboarding_max',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _optionalDecimalValidator,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onSubmit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      PricingPlanPricingUpdateCommand(
        tierKey: widget.entry.tierKey,
        monthlyUsd: _parseNullableDouble(_monthly.text),
        firstNSeats: _parseNullableInt(_firstNSeats.text),
        firstSeatUsd: _parseNullableDouble(_firstSeat.text),
        additionalSeatUsd: _parseNullableDouble(_additionalSeat.text),
        onboardingMinUsd: _parseNullableDouble(_onboardingMin.text),
        onboardingMaxUsd: _parseNullableDouble(_onboardingMax.text),
        idempotencyKey: widget.idempotencyKey,
      ),
    );
  }

  static double? _parseNullableDouble(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return double.tryParse(trimmed);
  }

  static int? _parseNullableInt(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }
}

class _UsageCapDialog extends StatefulWidget {
  const _UsageCapDialog({
    required this.operatorId,
    required this.primaryLocationId,
    required this.idempotencyKey,
    this.existing,
  });

  final String operatorId;
  final String? primaryLocationId;
  final UsageCapRow? existing;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

  @override
  State<_UsageCapDialog> createState() => _UsageCapDialogState();
}

class _UsageCapDialogState extends State<_UsageCapDialog> {
  final _formKey = GlobalKey<FormState>();
  late String _usageClass;
  late final TextEditingController _monthly;
  late final TextEditingController _perInvocation;
  late final TextEditingController _staffId;
  late final TextEditingController _workflowId;

  /// The four known usage classes the operator picks from. Friendly
  /// labels come from [adminRequestUseCaseLabel]; the raw ID stays
  /// visible in the details expander. Editing a cap whose class is not
  /// one of these (e.g. a legacy `workflow_pl` row) keeps the raw class
  /// pinned and locked - we never silently rewrite it.
  static const List<String> _knownClasses = <String>[
    'advisor_qa',
    'coach_qa',
    'wf_pl',
    'wf_schedule',
  ];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _usageClass = existing?.usageClass ?? _knownClasses.first;
    _monthly = TextEditingController(
      text: existing == null ? '' : existing.monthlyCapUsd.toStringAsFixed(2),
    );
    _perInvocation = TextEditingController(
      text: existing == null
          ? ''
          : existing.perInvocationCapUsd.toStringAsFixed(2),
    );
    _staffId = TextEditingController(text: existing?.staffId ?? '');
    _workflowId = TextEditingController(text: existing?.workflowId ?? '');
  }

  @override
  void dispose() {
    _monthly.dispose();
    _perInvocation.dispose();
    _staffId.dispose();
    _workflowId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final classIsKnown = _knownClasses.contains(_usageClass);
    return OperatorWebDialog(
      key: const Key('admin_pricing_cap_dialog'),
      title: editing ? 'Edit usage limit' : 'Add usage limit',
      icon: Icons.speed_outlined,
      maxWidth: 540,
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_pricing_cap_cancel_button'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_pricing_cap_submit_button'),
          label: editing ? 'Save' : 'Add',
          onPressed: _onSubmit,
          role: AdminActionRole.primary,
        ),
      ],
      child: Flexible(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.primaryLocationId == null && !editing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      'This operator needs a primary location before you can add usage limits.',
                      style: AppTextStyles.mono11(color: AppColors.negative),
                    ),
                  ),
                _DialogSection(
                  title: 'Use case',
                  child: _UseCaseField(
                    fieldKey: const Key('admin_pricing_cap_usage_class'),
                    value: _usageClass,
                    options: _knownClasses,
                    classIsKnown: classIsKnown,
                    // Use case is the upsert logical key, so it is fixed
                    // when editing an existing row (same rule as before).
                    enabled: !editing,
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _usageClass = value);
                    },
                  ),
                ),
                _DialogSection(
                  title: 'Limits',
                  child: _DialogFieldGrid(
                    children: <Widget>[
                      _LabelledField(
                        label: 'Monthly limit',
                        controller: _monthly,
                        fieldKey: const Key('admin_pricing_cap_monthly'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _decimalValidator,
                      ),
                      _LabelledField(
                        label: 'Per request limit',
                        controller: _perInvocation,
                        fieldKey: const Key('admin_pricing_cap_per_invocation'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*'),
                          ),
                        ],
                        validator: _decimalValidator,
                      ),
                    ],
                  ),
                ),
                _DialogSection(
                  title: 'Scope',
                  child: _DialogFieldGrid(
                    children: <Widget>[
                      _LabelledField(
                        label: 'Staff member',
                        controller: _staffId,
                        fieldKey: const Key('admin_pricing_cap_staff_id'),
                        enabled: !editing,
                      ),
                      _LabelledField(
                        label: 'Workflow',
                        controller: _workflowId,
                        fieldKey: const Key('admin_pricing_cap_workflow_id'),
                        enabled: !editing,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _onSubmit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final locationId = widget.existing?.locationId ?? widget.primaryLocationId;
    if (locationId == null) return;
    final monthly = double.tryParse(_monthly.text.trim()) ?? 0;
    final perInv = double.tryParse(_perInvocation.text.trim()) ?? 0;
    Navigator.of(context).pop(
      UsageCapUpsertCommand(
        operatorId: widget.operatorId,
        locationId: locationId,
        usageClass: _usageClass,
        monthlyCapUsd: monthly,
        perInvocationCapUsd: perInv,
        staffId: _staffId.text.trim().isEmpty ? null : _staffId.text.trim(),
        workflowId: _workflowId.text.trim().isEmpty
            ? null
            : _workflowId.text.trim(),
        idempotencyKey: widget.idempotencyKey,
      ),
    );
  }
}

/// Use-case dropdown over the four known classes with friendly labels.
/// When editing a row whose class is outside the known set, the field
/// renders the raw class read-only so it is never silently rewritten.
class _UseCaseField extends StatelessWidget {
  const _UseCaseField({
    required this.fieldKey,
    required this.value,
    required this.options,
    required this.classIsKnown,
    required this.enabled,
    required this.onChanged,
  });

  final Key fieldKey;
  final String value;
  final List<String> options;
  final bool classIsKnown;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!classIsKnown) {
      // Legacy / custom class: show its label + raw id, do not coerce
      // it into the known dropdown.
      return InputDecorator(
        decoration: _decoration('Use case'),
        child: Text(
          '${adminRequestUseCaseLabel(value)} ($value)',
          style: AppTextStyles.body14(color: AppColors.textSecondary),
        ),
      );
    }
    return DropdownButtonFormField<String>(
      key: fieldKey,
      initialValue: value,
      isExpanded: true,
      onChanged: enabled ? onChanged : null,
      decoration: _decoration('Use case'),
      items: <DropdownMenuItem<String>>[
        for (final option in options)
          DropdownMenuItem<String>(
            value: option,
            child: Text(
              adminRequestUseCaseLabel(option),
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
      ],
    );
  }

  InputDecoration _decoration(String label) {
    return _compactFieldDecoration(label);
  }
}

class _DialogSection extends StatelessWidget {
  const _DialogSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  color: AppColors.sunset,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: AppTextStyles.body14(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _DialogFieldGrid extends StatelessWidget {
  const _DialogFieldGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final requestedCount = children.length > 3 ? 3 : children.length;
        final count = constraints.maxWidth < 420 ? 1 : requestedCount;
        const spacing = 10.0;
        final width = (constraints.maxWidth - (count - 1) * spacing) / count;
        return Wrap(
          spacing: spacing,
          runSpacing: 0,
          children: <Widget>[
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

class _LabelledField extends StatelessWidget {
  const _LabelledField({
    required this.label,
    required this.controller,
    required this.fieldKey,
    this.validator,
    this.keyboardType,
    this.inputFormatters,
    this.enabled = true,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final Key fieldKey;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        key: fieldKey,
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        enabled: enabled,
        maxLines: maxLines,
        validator: validator,
        decoration: _compactFieldDecoration(label),
      ),
    );
  }
}

InputDecoration _compactFieldDecoration(String label) {
  return InputDecoration(
    labelText: label,
    isDense: true,
    filled: true,
    fillColor: AppColors.backgroundSurface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    labelStyle: AppTextStyles.body11(color: AppColors.textMuted),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.sunsetDark, width: 1.2),
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        tone: OperatorWebBannerTone.error,
        message: message,
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
      key: const Key('admin_pricing_confirm_dialog'),
      title: title,
      icon: Icons.help_outline,
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_pricing_confirm_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(false),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_pricing_confirm_ok'),
          label: confirmLabel,
          onPressed: () => Navigator.of(context).pop(true),
          role: AdminActionRole.primary,
        ),
      ],
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preset preview diff: shown before a plan template is applied.
// ---------------------------------------------------------------------------

/// How one preset cap compares to the operator's current limit for the
/// same use case. Mirrors the operator-approved mockup's NEW / CHANGED /
/// unchanged states (`docs/_mockups/admin_plans_and_limits_redesign.html`,
/// `presetPreview`).
enum _PresetCapChange {
  /// The use case has no current operator/location-level limit; the
  /// preset adds one.
  added,

  /// The use case already has a limit at a different monthly amount; the
  /// preset replaces it.
  changed,

  /// The use case already has a limit at the same monthly amount; the
  /// preset leaves it as-is.
  unchanged,
}

/// One row of the preset preview diff: a preset cap, its change state,
/// and the current monthly amount it replaces (null when [change] is
/// [_PresetCapChange.added]).
@immutable
class _PresetCapDiff {
  const _PresetCapDiff({
    required this.usageClass,
    required this.newMonthlyCapUsd,
    required this.currentMonthlyCapUsd,
    required this.change,
  });

  final String usageClass;
  final double newMonthlyCapUsd;
  final double? currentMonthlyCapUsd;
  final _PresetCapChange change;
}

/// Compute the preview diff for applying [template] to [bundle].
///
/// Matches the mockup: only operator/location-level caps participate
/// (the mockup's `if(!l.who)` filter), so caps scoped to a specific staff
/// member or workflow are ignored when deciding NEW vs CHANGED. The
/// proxy's apply-template path overwrites by `(operator, location,
/// usage_class)` and leaves staff/workflow-scoped rows alone, so this
/// preview reflects the rows the operator will actually see change.
List<_PresetCapDiff> _buildPresetDiff(
  PricingOperatorBundle bundle,
  PricingTierTemplate template,
) {
  // Current operator/location-level monthly cap per use case. A cap
  // scoped to a specific staff member or workflow is skipped, mirroring
  // the mockup. If two location-level rows share a use case the last one
  // wins (the apply path keys on use case at this level).
  final current = <String, double>{};
  for (final cap in bundle.caps) {
    if (cap.staffId != null || cap.workflowId != null) continue;
    current[cap.usageClass] = cap.monthlyCapUsd;
  }
  return <_PresetCapDiff>[
    for (final cap in template.caps)
      _PresetCapDiff(
        usageClass: cap.usageClass,
        newMonthlyCapUsd: cap.monthlyCapUsd,
        currentMonthlyCapUsd: current[cap.usageClass],
        change: !current.containsKey(cap.usageClass)
            ? _PresetCapChange.added
            : (current[cap.usageClass] != cap.monthlyCapUsd
                  ? _PresetCapChange.changed
                  : _PresetCapChange.unchanged),
      ),
  ];
}

/// Preview diff dialog for applying a plan preset. Pops `true` to apply,
/// `false` (or null on dismiss) to cancel. Screen-only: it computes the
/// diff from the in-memory bundle + the static template and never touches
/// the gateway. The actual apply still runs in `_onApplyTemplate` on a
/// `true` result.
class _PresetPreviewDialog extends StatelessWidget {
  const _PresetPreviewDialog({required this.bundle, required this.template});

  final PricingOperatorBundle bundle;
  final PricingTierTemplate template;

  @override
  Widget build(BuildContext context) {
    final diff = _buildPresetDiff(bundle, template);
    // Enterprise (and any preset with no caps) sets the plan but adds no
    // preset limits, so there is no diff list to show.
    final isCustomContract = template.caps.isEmpty;
    return OperatorWebDialog(
      key: const Key('admin_pricing_preset_dialog'),
      title: 'Switch to ${template.displayName}?',
      icon: Icons.tune,
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_pricing_preset_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(false),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_pricing_preset_apply'),
          label: 'Apply ${template.displayName}',
          onPressed: () => Navigator.of(context).pop(true),
          role: AdminActionRole.primary,
        ),
      ],
      child: Flexible(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isCustomContract)
                Text(
                  '${template.displayName} is a custom contract. It sets the '
                  'plan but adds no preset limits. You build the limits by '
                  'hand.',
                  key: const Key('admin_pricing_preset_custom_note'),
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                )
              else ...<Widget>[
                Text(
                  'Sets the plan and these limits. Limits for the same use '
                  'case are replaced; others are kept.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                for (final row in diff) _PresetDiffRow(diff: row),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of the preset preview diff. Shows the use case (friendly
/// label), the new monthly amount, the prior amount when it changes, and
/// a plain-English NEW / CHANGED tag. Unchanged rows carry no tag.
class _PresetDiffRow extends StatelessWidget {
  const _PresetDiffRow({required this.diff});

  final _PresetCapDiff diff;

  @override
  Widget build(BuildContext context) {
    final newAmount = '${_money(diff.newMonthlyCapUsd)}/mo';
    return Padding(
      key: Key('admin_pricing_preset_row_${diff.usageClass}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              adminRequestUseCaseLabel(diff.usageClass),
              style: AppTextStyles.body13(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          // The new amount. When the limit changes, show the prior amount
          // before it, joined with "to" (UX no-em-dash law).
          if (diff.change == _PresetCapChange.changed &&
              diff.currentMonthlyCapUsd != null) ...<Widget>[
            Text(
              _money(diff.currentMonthlyCapUsd),
              style: AppTextStyles.mono11(
                color: AppColors.textMuted,
              ).copyWith(decoration: TextDecoration.lineThrough),
            ),
            const SizedBox(width: 6),
            Text('to', style: AppTextStyles.mono11(color: AppColors.textMuted)),
            const SizedBox(width: 6),
          ],
          Text(
            newAmount,
            style: AppTextStyles.mono11(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          if (diff.change != _PresetCapChange.unchanged) ...<Widget>[
            const SizedBox(width: 8),
            _PresetDiffTag(change: diff.change),
          ],
        ],
      ),
    );
  }
}

/// Plain-English NEW / CHANGED tag for a preset diff row.
class _PresetDiffTag extends StatelessWidget {
  const _PresetDiffTag({required this.change});

  final _PresetCapChange change;

  @override
  Widget build(BuildContext context) {
    final isNew = change == _PresetCapChange.added;
    final color = isNew ? AppColors.positive : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isNew ? 'NEW' : 'CHANGED',
        style: AppTextStyles.mono8(
          color: color,
        ).copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5),
      ),
    );
  }
}

String? _decimalValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  final parsed = double.tryParse(value.trim());
  if (parsed == null) return 'Enter a number';
  if (parsed < 0) return 'Must be 0 or more';
  return null;
}

/// Phase 3 — validator for a plan-pricing money field where blank is a
/// valid "none" (genuine SQL NULL). A present value must be a
/// non-negative number.
String? _optionalDecimalValidator(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final parsed = double.tryParse(value.trim());
  if (parsed == null) return 'Enter a number';
  if (parsed < 0) return 'Must be 0 or more';
  return null;
}

/// Phase 3 — validator for the first-seat band size where blank is a
/// valid "none". A present value must be a non-negative whole number.
String? _optionalIntValidator(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final parsed = int.tryParse(value.trim());
  if (parsed == null) return 'Enter a whole number';
  if (parsed < 0) return 'Must be 0 or more';
  return null;
}
