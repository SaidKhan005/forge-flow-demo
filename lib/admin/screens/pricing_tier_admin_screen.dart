// Plans & Limits V1 (Phase 1 + Phase 2) - admin Plans & limits screen.
//
// Rebuilt to the operator-approved mockup
// `docs/_mockups/admin_plans_and_limits_redesign.html` and the
// reconciled pricing model in
// `docs/phases/phase_11a/phase_11a_decision_register.md`
// ("Reconciled pricing model (2026-05-24)"). Phase 1 was front-end
// only; Phase 2 turns on two live affordances against new proxy routes
// (see below): delete-a-limit and a month-to-date spend-summary feed.
//
// Two views:
//
//   * Plans - a read-only laddered map of the six plans (Pilot,
//     Starter, Premium, Elite, Pro, Enterprise): name, price, what it
//     adds, included advisor cap, and a margin estimate. Read from the
//     locked tier templates (`kPricingTierTemplates`) plus the
//     reconciled presentation values (`kPricingPlanPresentations`).
//     There is no pricing editor save path - editable pricing is
//     Phase 3 (schema + proxy) and does not exist yet, so this view is
//     read-only by construction.
//
//   * Businesses - master/detail. The master is the business list with
//     a health dot, this-month spend, and margin %. The detail shows a
//     plan + margin card, a recent-limit-hits strip, the plan presets,
//     and the usage-limits list where each limit draws a spend-vs-cap
//     bar.
//
// Margin / cap-breach numbers are READ from the existing observability
// gateway (`ObservabilityAdminGateway`). In demo that gateway returns a
// deterministic seeded envelope; that is expected. Cost telemetry, cap
// events, and margin estimates are joined to each operator by
// `operator_id`.
//
// The per-limit spend-vs-cap bars prefer the Phase 2
// `GET /v1/admin/pricing/operators/{id}/spend-summary` endpoint (live
// month-to-date `SUM(cost_usd)` per cap identity), FALLING BACK to the
// observability cost telemetry (joined by `usage_class`) when that
// endpoint is unavailable - so demo mode, which has no spend-summary
// endpoint, keeps painting exactly as Phase 1 did.
//
// Usage-limit add/edit keeps the existing cap upsert through the
// pricing gateway. "Use case" is a dropdown of the known classes with
// friendly labels; the raw IDs stay visible in a details expander.
// Phase 2 re-enables delete-a-limit: each limit row carries a delete
// button that confirms, then calls the idempotent + audited Phase 2
// `DELETE /v1/admin/pricing/usage-caps` route through the gateway.
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

  /// Live month-to-date spend per operator from the Phase 2
  /// `spend-summary` endpoint, joined onto the spend-vs-cap bars. A
  /// missing entry (endpoint unavailable, e.g. demo mode) leaves the
  /// bars to fall back to the observability envelope, so demo keeps
  /// working. Keyed by `operator_id`.
  final Map<String, OperatorSpendSummary> _spendSummaries =
      <String, OperatorSpendSummary>{};
  String? _selectedOperatorId;
  String? _actionError;
  int _idempotencyCounter = 0;
  _PricingView _view = _PricingView.plans;

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
      // Live per-operator spend-summary (Phase 2). Best-effort too: a
      // host without the endpoint (demo mode) leaves the map empty and
      // the bars fall back to the observability envelope.
      final spendSummaries = await _fetchSpendSummaries(bundles);
      if (!mounted) return;
      setState(() {
        _bundles = bundles;
        _observability = observability;
        _spendSummaries
          ..clear()
          ..addAll(spendSummaries);
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

  /// Fetches the Phase 2 `spend-summary` for each visible operator,
  /// best-effort. A failure on any one operator (or the whole endpoint
  /// being absent in demo) is swallowed so the bars fall back to the
  /// observability envelope and the screen still paints. Returns a map
  /// keyed by `operator_id`; absent keys signal "no live figure, use
  /// the fallback".
  Future<Map<String, OperatorSpendSummary>> _fetchSpendSummaries(
    List<PricingOperatorBundle> bundles,
  ) async {
    final result = <String, OperatorSpendSummary>{};
    // Only the operators in scope are rendered, so only fetch those.
    final scope = widget.hierarchyScope;
    final targets = <PricingOperatorBundle>[
      for (final bundle in bundles)
        if (scope == null || bundle.operatorId == scope.operatorId) bundle,
    ];
    for (final bundle in targets) {
      try {
        result[bundle.operatorId] = await widget.gateway.fetchSpendSummary(
          bundle.operatorId,
        );
      } catch (_) {
        // Endpoint unavailable for this operator: leave it out so the
        // bar uses the observability fallback.
      }
    }
    return result;
  }

  OperatorSpendSummary? _spendSummaryFor(String operatorId) =>
      _spendSummaries[operatorId];

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
      return const _PlansMapView(key: Key('admin_pricing_plans_view'));
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
        onSelect: (id) => setState(() => _selectedOperatorId = id),
      ),
      detail: _selected == null
          ? const SizedBox.shrink()
          : _OperatorPricingDetail(
              bundle: _selected!,
              observability: _observability,
              spendSummary: _spendSummaryFor(_selected!.operatorId),
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

  Future<void> _onDeleteCap(
    PricingOperatorBundle bundle,
    UsageCapRow row,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Delete this usage limit?',
        message:
            'Removes the ${adminRequestUseCaseLabel(row.usageClass)} limit '
            '(${_money2(row.monthlyCapUsd)} per month) from '
            '${bundle.businessName}. Advisor spend for this use case will no '
            'longer be capped here until you add a new limit. Spending '
            'already recorded this month is not changed.',
        confirmLabel: 'Delete limit',
      ),
    );
    if (confirmed != true) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.deleteUsageCap(
        UsageCapDeleteCommand.forRow(row, idempotencyKey: key),
      );
    }, successHint: 'Usage limit deleted.');
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

/// Month-to-date spend for one cap, preferring the live Phase 2
/// `spend-summary` (matched on the exact cap identity:
/// location + usage_class + staff + workflow) and FALLING BACK to the
/// observability envelope when no live summary line exists for the cap.
/// The fallback keeps demo mode working: demo has no `spend-summary`
/// endpoint, so [summary] is null there and the bar uses the seeded
/// observability cost telemetry exactly as Phase 1 did. Returns null
/// when neither source has a figure (honest empty, not a zero bar).
double? _liveSpendForCap(
  OperatorSpendSummary? summary,
  ObservabilityEnvelope? envelope,
  String operatorId,
  UsageCapRow cap,
) {
  if (summary != null) {
    for (final line in summary.lines) {
      if (line.locationId == cap.locationId &&
          _normalizeUsageClass(line.usageClass) ==
              _normalizeUsageClass(cap.usageClass) &&
          line.staffId == cap.staffId &&
          line.workflowId == cap.workflowId) {
        return line.monthlyUsedUsd;
      }
    }
  }
  return _spendForCap(envelope, operatorId, cap);
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
  const _PlansMapView({super.key});

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
                      child: _PlanCard(template: template),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          const _PlanMapFootnote(),
        ],
      ),
    );
  }
}

class _PlanMapFootnote extends StatelessWidget {
  const _PlanMapFootnote();

  @override
  Widget build(BuildContext context) {
    return const OperatorWebBanner(
      icon: Icons.info_outline,
      message:
          'Plan prices are read-only here. Editing the pricing catalog is a '
          'later step. The dollar limits cap AI cost, not the subscription '
          'price.',
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.template});

  final PricingTierTemplate template;

  @override
  Widget build(BuildContext context) {
    final presentation = findPricingPlanPresentation(template.tierKey);
    final advisorCap = _advisorCapUsd(template);
    final monthly = presentation?.monthlyUsd;
    final priceText = monthly == null
        ? 'Custom'
        : '\$${monthly.round()}';
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
            presentation?.seatLine ?? '',
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
            'Onboarding ${presentation?.onboardingRange ?? 'Custom'}',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
        ],
      ),
    );
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
        style: AppTextStyles.mono11(color: color).copyWith(
          fontWeight: FontWeight.w700,
        ),
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
              _MetricCell(
                value: _money(spend.revenueUsd),
                label: 'Revenue',
              ),
              _MarginPill(spend: spend),
            ],
          ),
          const SizedBox(height: 6),
          AdminDetailRow(
            label: 'Currency',
            value: bundle.preferredCurrency,
          ),
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
        style: AppTextStyles.mono14(
          color: color,
          weight: FontWeight.w700,
        ),
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
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          side: BorderSide(
            color: isCurrent ? AppColors.peacock : AppColors.borderSubtle,
            width: 1,
          ),
          backgroundColor: isCurrent
              ? AppColors.peacock.withValues(alpha: 0.06)
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
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
                    style: AppTextStyles.mono8(color: AppColors.peacockDark)
                        .copyWith(fontWeight: FontWeight.w700),
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
                spendUsd: _liveSpendForCap(
                  spendSummary,
                  observability,
                  bundle.operatorId,
                  row,
                ),
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
                  tooltip: 'Delete usage limit',
                  color: AppColors.negative,
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
                        fieldKey: const Key(
                          'admin_pricing_cap_per_invocation',
                        ),
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
