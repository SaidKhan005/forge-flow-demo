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
//   * Businesses - master/detail. The master is the business list with
//     a health dot, this-month spend, and margin %. The detail shows a
//     plan + margin card, a recent-limit-hits strip, the plan presets,
//     and the usage-limits list where each limit draws a spend-vs-cap
//     bar.
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
import '../models/observability_admin_models.dart';
import '../models/pricing_tier_admin_models.dart';
import '../services/observability_admin_gateway.dart';
import '../services/pricing_tier_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';

/// The two views the screen exposes. The mockup also carries a
/// "Reconcile" decision-aid tab; that tab is a one-time pricing
/// reconciliation worksheet with no gateway and no persistence, so it
/// is intentionally out of scope for this operational screen.
enum _PricingView { plans, businesses }

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
      if (!mounted) return;
      setState(() {
        _bundles = bundles;
        _observability = observability;
        if (planCatalog != null && planCatalog.isNotEmpty) {
          _planCatalog = <String, PricingPlanCatalogEntry>{
            for (final entry in planCatalog) entry.tierKey: entry,
          };
        }
        _loading = false;
        final visible = _visibleBundles;
        final preferredOperatorId = widget.hierarchyScope?.operatorId;
        if (preferredOperatorId != null &&
            visible.any((b) => b.operatorId == preferredOperatorId)) {
          _selectedOperatorId = preferredOperatorId;
        }
        if (_selectedOperatorId != null &&
            visible.every((b) => b.operatorId != _selectedOperatorId)) {
          _selectedOperatorId = null;
        }
        _selectedOperatorId ??= visible.isEmpty
            ? null
            : visible.first.operatorId;
      });
      // Best-effort live spend for the operator now in focus. A failure
      // here is swallowed so the bars fall back to the observability
      // envelope (demo mode has no spend-summary endpoint).
      final focused = _selectedOperatorId;
      if (focused != null) {
        unawaited(_fetchSpendSummaryFor(focused));
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

  /// Floor height the master/detail body needs before the compact
  /// (stacked) layout can render without clipping. Pure layout: no
  /// change to which affordances render or to any gateway call.
  static const double _kBodyMinHeight =
      kAdminDefaultCompactMasterHeight + 16 + 200;

  @override
  Widget build(BuildContext context) {
    // Centre + max-width cap matching the shared operator-web body kit.
    return Container(
      key: const Key('admin_pricing_screen'),
      color: AppColors.backgroundDeep,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const OperatorWebScreenHeader(
                  icon: Icons.payments_outlined,
                  title: 'Plans and limits',
                  collapseBelowWidth: 0,
                  subtitle:
                      'Set each business\'s Forge & Flow AI plan and the limits that keep advisor spend predictable. Operators never see this.',
                ),
                const SizedBox(height: 14),
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
                const SizedBox(height: 16),
                Expanded(child: _buildBoundedBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBoundedBody() {
    if (_view == _PricingView.plans) {
      // The plan map is its own scroll view; no master/detail floor.
      return _buildBody();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final body = _buildBody();
        if (!constraints.hasBoundedHeight ||
            constraints.maxHeight >= _kBodyMinHeight) {
          return body;
        }
        return SingleChildScrollView(
          child: SizedBox(height: _kBodyMinHeight, child: body),
        );
      },
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
    return _buildBusinessesBody();
  }

  Widget _buildBusinessesBody() {
    final visibleBundles = _visibleBundles;
    if (visibleBundles.isEmpty) {
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
    return AdminMasterDetailLayout(
      master: _OperatorList(
        bundles: visibleBundles,
        observability: _observability,
        selectedOperatorId: _selectedOperatorId,
        onSelect: (id) {
          setState(() => _selectedOperatorId = id);
          if (!_spendSummaries.containsKey(id)) {
            unawaited(_fetchSpendSummaryFor(id));
          }
        },
      ),
      detail: _selected == null
          ? const SizedBox.shrink()
          : _OperatorPricingDetail(
              bundle: _selected!,
              observability: _observability,
              spendSummary: _spendSummaries[_selected!.operatorId],
              editingEnabled: widget.editingEnabled,
              onApplyTemplate: _onApplyTemplate,
              onEditCap: _onEditCap,
              onAddCap: _onAddCap,
              onDeleteCap: _onDeleteCap,
            ),
    );
  }

  Future<void> _onApplyTemplate(
    PricingOperatorBundle bundle,
    PricingTierTemplate template,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Apply ${template.displayName} template?',
        message:
            'Sets the Forge & Flow AI plan to ${template.displayName} and '
            'replaces ${template.caps.length} usage limit'
            '${template.caps.length == 1 ? '' : 's'} '
            'on ${bundle.businessName}. Existing limits for the same '
            'use case are overwritten; other limits are preserved.',
        confirmLabel: 'Apply',
      ),
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
  MarginEstimateEntry? margin;
  for (final m in envelope.margins) {
    if (m.operatorId == operatorId) {
      margin = m;
      break;
    }
  }
  // Spend is the rolling cost the margin row already carries; fall back
  // to summing the per-class cost telemetry for the operator when no
  // margin row is present.
  double? spend = margin?.costUsd;
  if (spend == null) {
    double sum = 0;
    var sawRow = false;
    for (final row in envelope.costTelemetry) {
      if (row.operatorId == operatorId) {
        sum += row.totalUsd;
        sawRow = true;
      }
    }
    if (sawRow) spend = sum;
  }
  final revenue = margin?.revenueUsd;
  final ratio = margin?.marginRatio;
  return _OperatorSpend(
    spendUsd: spend,
    revenueUsd: revenue,
    marginRatio: (margin != null && (revenue ?? 0) > 0) ? ratio : null,
    health: _healthFor(margin, revenue, spend),
  );
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
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(999),
        ),
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Tab(
              label: 'Plans',
              tabKey: const Key('admin_pricing_tab_plans'),
              selected: selected == _PricingView.plans,
              onTap: () => onSelect(_PricingView.plans),
            ),
            const SizedBox(width: 4),
            _Tab(
              label: 'Businesses',
              tabKey: const Key('admin_pricing_tab_businesses'),
              selected: selected == _PricingView.businesses,
              onTap: () => onSelect(_PricingView.businesses),
            ),
          ],
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
      color: selected
          ? AppColors.sunset.withValues(alpha: 0.13)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        key: tabKey,
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Text(
            label,
            style: AppTextStyles.body13(
              color: selected ? AppColors.sunsetDark : AppColors.textMuted,
            ).copyWith(fontWeight: FontWeight.w600),
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
          Text(
            'How the six plans ladder up. Each plan includes everything below it and raises the included AI allowance. Margins are estimates from the pricing model.',
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              const minCardWidth = 200.0;
              const spacing = 14.0;
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
          const SizedBox(height: 14),
          _PlanMapFootnote(editingEnabled: editingEnabled),
        ],
      ),
    );
  }
}

class _PlanMapFootnote extends StatelessWidget {
  const _PlanMapFootnote({required this.editingEnabled});

  final bool editingEnabled;

  @override
  Widget build(BuildContext context) {
    return OperatorWebBanner(
      icon: Icons.info_outline,
      message: editingEnabled
          ? 'Plan prices come from the pricing catalog. Use "Edit pricing" on '
                'a plan to change its monthly fee, per-seat ramp, or onboarding '
                'range. The dollar limits in Businesses cap AI cost, not the '
                'subscription price.'
          : 'Plan prices come from the pricing catalog (view only). The dollar '
                'limits in Businesses cap AI cost, not the subscription price.',
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
    final priceText = monthly == null ? 'Custom' : '\$${monthly.round()}';
    final seatText = _seatLine(entry, presentation);
    final onboardingText = _onboardingLine(entry, presentation);
    return Container(
      key: Key('admin_pricing_plan_card_${template.tierKey}'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _LadderBar(fraction: presentation?.ladderFraction ?? 0.5),
          const SizedBox(height: 10),
          Text(
            template.displayName,
            style: AppTextStyles.mono16(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                priceText,
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              if (monthly != null) ...<Widget>[
                const SizedBox(width: 3),
                Text(
                  '/mo',
                  style: AppTextStyles.mono11(color: AppColors.textMuted),
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            seatText,
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
          const SizedBox(height: 9),
          Text(
            presentation?.includes ?? template.summary,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 9),
          Text(
            advisorCap == null
                ? 'Custom limits'
                : 'Advisor cap ${_money(advisorCap)}/mo',
            style: AppTextStyles.mono11(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          _MarginTag(label: presentation?.marginEstimate ?? ''),
          const SizedBox(height: 8),
          Text(
            'Onboarding $onboardingText',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
          if (editingEnabled && entry != null) ...<Widget>[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: Key('admin_pricing_plan_edit_${template.tierKey}'),
                style: AdminButtonStyles.secondary(),
                onPressed: () => onEdit(entry!),
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: const Text('Edit pricing'),
              ),
            ),
          ],
        ],
      ),
    );
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
      // No per-seat fee. Keep the static seat-line copy when present
      // (e.g. "No seat fee.") so the card reads naturally.
      return presentation?.seatLine ?? 'No seat fee.';
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
    if ((min ?? 0) == 0 && (max ?? 0) == 0) return r'$0 (self-serve)';
    if (min != null && max != null) {
      return '${_money(min)} to ${_money(max)}';
    }
    return _money(min ?? max);
  }

  static double? _advisorCapUsd(PricingTierTemplate template) {
    for (final cap in template.caps) {
      if (cap.usageClass == 'advisor_qa') return cap.monthlyCapUsd;
    }
    return null;
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
// Businesses view: master list.
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

class _OperatorList extends StatelessWidget {
  const _OperatorList({
    required this.bundles,
    required this.observability,
    required this.selectedOperatorId,
    required this.onSelect,
  });

  final List<PricingOperatorBundle> bundles;
  final ObservabilityEnvelope? observability;
  final String? selectedOperatorId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_pricing_operator_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: bundles.length,
        separatorBuilder: (_, __) => Container(
          height: 1,
          color: AppColors.borderSubtle.withValues(alpha: 0.4),
        ),
        itemBuilder: (context, index) {
          final bundle = bundles[index];
          final selected = bundle.operatorId == selectedOperatorId;
          final spend = _spendForOperator(observability, bundle.operatorId);
          return Material(
            color: selected
                ? AppColors.sunset.withValues(alpha: 0.10)
                : Colors.transparent,
            child: InkWell(
              key: Key('admin_pricing_row_${bundle.operatorId}'),
              onTap: () => onSelect(bundle.operatorId),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: <Widget>[
                    _HealthDot(health: spend.health),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            bundle.businessName,
                            style: AppTextStyles.mono14(
                              color: AppColors.textPrimary,
                              weight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${_tierDisplayName(bundle.subscriptionTier)} · '
                            '${_money(spend.spendUsd)} spent',
                            style: AppTextStyles.mono11(
                              color: AppColors.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      spend.marginRatio == null
                          ? '—'
                          : '${(spend.marginRatio! * 100).round()}%',
                      style: AppTextStyles.mono14(
                        color: _healthColor(spend.health),
                        weight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HealthDot extends StatelessWidget {
  const _HealthDot({required this.health});

  final _MarginHealth health;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: _healthColor(health),
        shape: BoxShape.circle,
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
    required this.editingEnabled,
    required this.onApplyTemplate,
    required this.onEditCap,
    required this.onAddCap,
    required this.onDeleteCap,
  });

  final PricingOperatorBundle bundle;
  final ObservabilityEnvelope? observability;
  final OperatorSpendSummary? spendSummary;
  final bool editingEnabled;
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
          _PlanMarginCard(bundle: bundle, spend: spend),
          const SizedBox(height: 16),
          if (hits.isNotEmpty) ...<Widget>[
            _RecentHitsCard(hits: hits),
            const SizedBox(height: 16),
          ],
          if (editingEnabled) ...<Widget>[
            _PlanPresetsCard(bundle: bundle, onApplyTemplate: onApplyTemplate),
            const SizedBox(height: 16),
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

class _PlanMarginCard extends StatelessWidget {
  const _PlanMarginCard({required this.bundle, required this.spend});

  final PricingOperatorBundle bundle;
  final _OperatorSpend spend;

  @override
  Widget build(BuildContext context) {
    final presentation = findPricingPlanPresentation(bundle.subscriptionTier);
    return OperatorWebPanel(
      title: 'Plan and margin',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _tierDisplayName(bundle.subscriptionTier),
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            presentation?.priceLine ?? 'Plan price set per contract',
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          Text(
            presentation?.includes ?? 'Custom plan.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 26,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _MetricCell(
                value: _money(spend.spendUsd),
                label: 'Spent this month',
              ),
              _MetricCell(value: _money(spend.revenueUsd), label: 'Revenue'),
              _MarginPill(spend: spend),
            ],
          ),
          const SizedBox(height: 6),
          AdminDetailRow(label: 'Currency', value: bundle.preferredCurrency),
          AdminDetailRow(
            label: 'Primary location',
            value: _primaryLocationLabel(bundle),
          ),
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

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          value,
          style: AppTextStyles.mono16(
            color: AppColors.textPrimary,
          ).copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 1),
        Text(label, style: AppTextStyles.mono11(color: AppColors.textMuted)),
      ],
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
      trailing: editingEnabled
          ? OutlinedButton.icon(
              key: const Key('admin_pricing_add_cap_button'),
              onPressed: () => onAdd(bundle),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('Add usage limit'),
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
              if (editingEnabled) ...<Widget>[
                const SizedBox(width: 2),
                IconButton(
                  key: Key('admin_pricing_cap_edit_$keySuffix'),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Edit usage limit',
                  onPressed: () => onEdit(bundle, row),
                ),
                IconButton(
                  key: Key('admin_pricing_cap_delete_$keySuffix'),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove usage limit',
                  onPressed: () => onDelete(bundle, row),
                ),
              ],
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
      actions: <Widget>[
        TextButton(
          key: const Key('admin_pricing_plan_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_pricing_plan_submit_button'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Save'),
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Leave a field blank for "none" (for example a custom-contract plan has no monthly price, and a plan with no per-seat fee has blank seat fields).',
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
                ),
                _LabelledField(
                  label: 'Monthly fee (USD, blank for custom)',
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: _LabelledField(
                        label: 'First seats',
                        controller: _firstNSeats,
                        fieldKey: const Key('admin_pricing_plan_first_n_seats'),
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        validator: _optionalIntValidator,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: _LabelledField(
                        label: 'First seat (USD)',
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
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: _LabelledField(
                        label: 'Added seat (USD)',
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
                    ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: _LabelledField(
                        label: 'Onboarding min (USD)',
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
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: _LabelledField(
                        label: 'Onboarding max (USD)',
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
                    ),
                  ],
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
      actions: <Widget>[
        TextButton(
          key: const Key('admin_pricing_cap_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_pricing_cap_submit_button'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: Text(editing ? 'Save' : 'Add'),
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: _LabelledField(
                        label: 'Monthly limit (USD)',
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
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: _LabelledField(
                        label: 'Per request limit (USD)',
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
                    ),
                  ],
                ),
                _LabelledField(
                  label: 'Staff member ID (optional)',
                  controller: _staffId,
                  fieldKey: const Key('admin_pricing_cap_staff_id'),
                  hintText: 'Leave blank for all staff',
                  enabled: !editing,
                ),
                _LabelledField(
                  label: 'Workflow ID (optional)',
                  controller: _workflowId,
                  fieldKey: const Key('admin_pricing_cap_workflow_id'),
                  hintText: 'Leave blank for all workflows',
                  enabled: !editing,
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
    return InputDecoration(
      labelText: label,
      labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
      ),
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
    this.hintText,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final Key fieldKey;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? hintText;
  final bool enabled;

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
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
          hintText: hintText,
          hintStyle: AppTextStyles.mono11(color: AppColors.textMuted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(
              color: AppColors.borderSubtle,
              width: 1,
            ),
          ),
        ),
      ),
    );
  }
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
        TextButton(
          key: const Key('admin_pricing_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_pricing_confirm_ok'),
          style: AdminButtonStyles.primary,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
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
