// Phase 11A.6 - AI Metrics (observability) dashboard surface.
//
// Read-only operator-facing view of the cost-telemetry, dormancy,
// margin, cap-event, graph, retry, latency, and Cloud Run rows the
// observability proxy assembles. Redesigned to the approved AI Metrics
// mockup (`docs/_mockups/ai_metrics_redesign/index.html`): four
// plain-English tabs and four hero summary cards, consuming the same
// `ObservabilityEnvelope` producers as before.
//
//   * Money       - cost-by-use-case donut (cost telemetry summed by
//                   query_class), saved-answer reuse bars (cache hit
//                   rates), and cost controls (model mix + batch share).
//   * Customers   - top spenders bars (top expensive) and a "Needs
//                   attention" list (losing money / limit hits /
//                   inactive) with View account drill-downs.
//   * Reliability - speed & uptime (links out to System health for
//                   latency), background jobs (projection retries),
//                   hosting (Cloud Run), and live sync (bridge
//                   tripwires when wired).
//   * Knowledge   - graph counts (approved / suggested / unlinked) and
//                   freshness (projection age, lookup speed).
//
// The /health envelope (dependency probes, tier-1 / tier-2 / tier-3
// metric tiers) is owned by the F.1 health surface. The header keeps a
// "Open System health" hint so the F&F admin can jump there for
// dependency checks without duplicating chrome.
//
// MONTH SELECTOR: the "This month / Last month" control threads the
// `ObservabilityFetchRequest.month` field into the fetch. Because
// `usage_logs` is a monthly rollup, only `current` and `previous` are
// honest choices (Metric Honesty Doctrine).
//
// METRIC HONESTY DOCTRINE: "Losing money" (margins) has no backend
// pricing source yet (Plans & limits owns pricing) - it renders an
// honest "Not available yet" empty state, never $0 / 0%. Cloud Run
// counts that are unknown render "unknown", never 0. No real red/yellow
// state is laundered to green.
//
// Performance posture (per docs/contracts/slice_runtime_acceptance_contract.md):
// the cost / dormancy queries scan rolling windows on `usage_logs` and
// can take seconds. The screen does NOT auto-poll. The first paint
// renders a manual-run prompt; the operator confirms a "Run metrics
// check" before any fetch fires. Refresh and month change use the same
// path. Stacked in-flight requests are blocked by `_refreshing`.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../services/realtime/outbox_tripwire_evaluator.dart';
import '../../theme/app_theme.dart';

import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../admin_routes.dart' show kAdminOperatorsRouteId;
import '../models/observability_admin_models.dart';
import '../services/observability_admin_gateway.dart';
import '../services/realtime_tripwire_admin_gateway.dart';
import '../widgets/admin_observability_run_controls.dart';
import '../widgets/admin_run_check_controls.dart';

/// One tab in the redesigned AI Metrics screen.
class _TabSpec {
  const _TabSpec({
    required this.label,
    required this.keySuffix,
    required this.icon,
  });
  final String label;
  final String keySuffix;
  final IconData icon;
}

const List<_TabSpec> _kTabs = <_TabSpec>[
  _TabSpec(label: 'Money', keySuffix: 'money', icon: Icons.payments_outlined),
  _TabSpec(
    label: 'Customers',
    keySuffix: 'customers',
    icon: Icons.storefront_outlined,
  ),
  _TabSpec(
    label: 'Reliability',
    keySuffix: 'reliability',
    icon: Icons.speed_outlined,
  ),
  _TabSpec(
    label: 'Knowledge',
    keySuffix: 'knowledge',
    icon: Icons.menu_book_outlined,
  ),
];

/// Donut / legend accent palette for the cost-by-use-case chart. Drawn
/// from the existing brand palette (no new theme tokens): sunset,
/// peacock, ocean, redSand. A fifth+ slice cycles back through the list.
const List<Color> _kUseCaseAccents = <Color>[
  AppColors.sunset,
  AppColors.peacock,
  AppColors.ocean,
  AppColors.redSand,
];

class ObservabilityAdminScreen extends StatefulWidget {
  const ObservabilityAdminScreen({
    super.key,
    required this.gateway,
    this.tripwireGateway,
    this.hierarchyScope,
    this.scopeLocationIds = const <String>{},
    @visibleForTesting this.now,
  });

  final ObservabilityAdminGateway gateway;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final Set<String> scopeLocationIds;

  /// Phase 10a.4 - optional gateway for the Realtime bridge tripwire
  /// (live sync) section. When wired, the manual run-check refreshes
  /// both the observability envelope AND the tripwire status; the
  /// section renders inside the Reliability tab. When null, the section
  /// is hidden and existing tests stay green without modification.
  final RealtimeTripwireAdminGateway? tripwireGateway;

  /// Test-only clock injection so the "Last refreshed" timestamp is
  /// deterministic. Production uses [DateTime.now].
  final DateTime Function()? now;

  @override
  State<ObservabilityAdminScreen> createState() =>
      _ObservabilityAdminScreenState();
}

class _ObservabilityAdminScreenState extends State<ObservabilityAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  bool _loading = false;
  bool _refreshing = false;
  ObservabilityEnvelope? _envelope;
  String? _loadError;
  DateTime? _lastRefreshed;

  /// Selected calendar-month bucket for the cost surfaces. Threaded into
  /// the fetch request. Defaults to the current month.
  ObservabilityMonth _month = ObservabilityMonth.current;

  // Phase 10a.4 - bridge tripwire (live sync) state. Loads alongside the
  // observability envelope when [widget.tripwireGateway] is wired.
  RealtimeTripwireSnapshot? _tripwires;
  String? _tripwireError;

  DateTime _clockNow() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _kTabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _confirmAndRefresh() async {
    if (_refreshing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _ObservabilityConfirmDialog(),
    );
    if (confirmed != true || !mounted) return;
    await _refresh();
  }

  /// Switch the active month bucket. When an envelope is already loaded,
  /// re-fetch in place (the confirmation dialog is for the first
  /// expensive run; re-scoping an already-loaded view is the runtime
  /// contract's "scope down" path). Before the first run we only store
  /// the selection so the eventual confirmed run uses it.
  Future<void> _selectMonth(ObservabilityMonth month) async {
    if (month == _month) return;
    setState(() => _month = month);
    if (_envelope != null && !_refreshing) {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      if (_envelope == null) _loading = true;
      _loadError = null;
      _tripwireError = null;
    });
    try {
      final request = ObservabilityFetchRequest(
        operatorId: widget.hierarchyScope?.operatorId,
        locationId: widget.hierarchyScope?.locationId,
        locationIds: widget.scopeLocationIds,
        month: _month,
      );
      final envelope = await widget.gateway.fetch(request);
      if (!mounted) return;
      setState(() {
        _envelope = envelope;
        _loading = false;
        _loadError = null;
        _lastRefreshed = _clockNow();
      });
    } on ObservabilityAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
        _lastRefreshed = _clockNow();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load AI Metrics: $error';
        _loading = false;
        _lastRefreshed = _clockNow();
      });
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      } else {
        _refreshing = false;
      }
    }
    // Phase 10a.4 - refresh the tripwire envelope after the main fetch
    // settles. Failure here does not poison the rest of the screen; the
    // live-sync section renders an inline error instead.
    final tripwireGateway = widget.tripwireGateway;
    if (tripwireGateway != null && mounted) {
      try {
        final snapshot = await tripwireGateway.fetch();
        if (!mounted) return;
        setState(() {
          _tripwires = snapshot;
          _tripwireError = null;
        });
      } on RealtimeTripwireAdminGatewayError catch (error) {
        if (!mounted) return;
        setState(() => _tripwireError = error.message);
      } catch (error) {
        if (!mounted) return;
        setState(
          () => _tripwireError = 'Could not load live sync status: $error',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The TabBar requires a Material ancestor; keeping the root as Material
    // satisfies that without depending on the outer shell. The whole surface
    // is ONE page scroll (actions + hero + tabs + the active tab body),
    // matching the mockup, rather than each tab body scrolling inside its own
    // fixed-height pane.
    return Material(
      key: const Key('admin_observability_screen'),
      color: AppColors.backgroundDeep,
      type: MaterialType.canvas,
      child: OperatorWebScreenFrame(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Builder(
          builder: (context) {
            final showManualPrompt =
                !_loading && _envelope == null && _loadError == null;
            final children = <Widget>[
              if (!showManualPrompt) ...<Widget>[
                _ObservabilityActionsRow(
                  lastRefreshed: _lastRefreshed,
                  onRunCheck: _confirmAndRefresh,
                  loading: _loading || _refreshing,
                  month: _month,
                  onSelectMonth: _selectMonth,
                ),
                const SizedBox(height: 12),
              ],
              if (_loadError != null)
                _ErrorBanner(
                  key: const Key('admin_observability_load_error'),
                  message: _loadError!,
                ),
              if (_envelope != null) ..._envelopeBody(_envelope!),
              if (_loading && _envelope == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 80),
                  child: Center(
                    key: Key('admin_observability_loading'),
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.sunsetDark,
                      ),
                    ),
                  ),
                ),
              if (showManualPrompt)
                AdminObservabilityManualRunPrompt(
                  onRunCheck: _confirmAndRefresh,
                  loading: _loading || _refreshing,
                  month: _month,
                  onSelectMonth: _selectMonth,
                ),
            ];
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _envelopeBody(ObservabilityEnvelope envelope) {
    return <Widget>[
      _AsOfStrip(envelope: envelope, month: _month),
      _HeroCards(envelope: envelope),
      const SizedBox(height: 18),
      TabBar(
        key: const Key('admin_observability_tabs'),
        controller: _tabs,
        isScrollable: true,
        labelColor: AppColors.textPrimary,
        unselectedLabelColor: AppColors.textSecondary,
        indicatorColor: AppColors.sunset,
        tabs: <Widget>[
          for (final tab in _kTabs)
            Tab(
              key: Key('admin_observability_tab_${tab.keySuffix}'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(tab.icon, size: 16),
                  const SizedBox(width: 8),
                  Text(tab.label),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      // Only the active tab body is built, so the page height matches the
      // visible tab (mirrors the mockup's hidden panels) and the single page
      // scroll owns all vertical overflow.
      AnimatedBuilder(
        animation: _tabs,
        builder: (context, _) {
          switch (_tabs.index) {
            case 0:
              return _MoneyTab(
                key: const Key('admin_observability_tab_body_money'),
                envelope: envelope,
              );
            case 1:
              return _CustomersTab(
                key: const Key('admin_observability_tab_body_customers'),
                envelope: envelope,
              );
            case 2:
              return _ReliabilityTab(
                key: const Key('admin_observability_tab_body_reliability'),
                envelope: envelope,
                tripwireGateway: widget.tripwireGateway,
                tripwires: _tripwires,
                tripwireError: _tripwireError,
              );
            case 3:
            default:
              return _KnowledgeTab(
                key: const Key('admin_observability_tab_body_knowledge'),
                envelope: envelope,
              );
          }
        },
      ),
    ];
  }
}

// Actions row.

class _ObservabilityActionsRow extends StatelessWidget {
  const _ObservabilityActionsRow({
    required this.lastRefreshed,
    required this.onRunCheck,
    required this.loading,
    required this.month,
    required this.onSelectMonth,
  });

  final DateTime? lastRefreshed;
  final Future<void> Function() onRunCheck;
  final bool loading;
  final ObservabilityMonth month;
  final ValueChanged<ObservabilityMonth> onSelectMonth;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: <Widget>[
        AdminObservabilityMonthSelector(
          month: month,
          onSelectMonth: onSelectMonth,
          enabled: !loading,
        ),
        Text(
          lastRefreshed == null
              ? 'Last refreshed: -'
              : 'Last refreshed: ${adminHumanDateTime(lastRefreshed!)}',
          key: const Key('admin_observability_last_refreshed'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        AdminRunCheckButton(
          key: const Key('admin_observability_refresh_button'),
          onPressed: () {
            onRunCheck();
          },
          icon: Icons.insights_outlined,
          label: 'Run metrics check',
          loadingLabel: 'Running...',
          loading: loading,
        ),
      ],
    );
  }
}

class _ObservabilityConfirmDialog extends StatelessWidget {
  const _ObservabilityConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return const AdminRunCheckConfirmDialog(
      dialogKey: Key('admin_observability_confirm_dialog'),
      cancelButtonKey: Key('admin_observability_confirm_cancel'),
      confirmButtonKey: Key('admin_observability_confirm_run'),
      icon: Icons.insights_outlined,
      title: 'Run metrics check',
      description: 'Refresh the current AI Metrics snapshot from staging.',
      confirmLabel: 'Run metrics check',
      facts: [
        AdminRunCheckFact(
          icon: Icons.schedule_outlined,
          label: 'Timing',
          text: 'The page can take a few minutes to update.',
        ),
      ],
    );
  }
}

/// As-of strip: one line giving the data timestamp, the active month
/// bucket, and the platform-wide reminder (mirrors the mockup's context
/// line under the title).
class _AsOfStrip extends StatelessWidget {
  const _AsOfStrip({required this.envelope, required this.month});

  final ObservabilityEnvelope envelope;
  final ObservabilityMonth month;

  @override
  Widget build(BuildContext context) {
    final monthLabel = month == ObservabilityMonth.current
        ? 'This month'
        : 'Last month';
    return Padding(
      key: const Key('admin_observability_as_of_strip'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(
        '$monthLabel · updated ${adminHumanDateTime(envelope.asOf)}',
        style: AppTextStyles.body12(color: AppColors.textMuted),
      ),
    );
  }
}

// ── Hero cards ───────────────────────────────────────────────────────

/// Four hero summary cards mirroring the mockup: AI spend, Businesses
/// using AI, Speed & uptime, Advisor knowledge. Each card leads with a
/// big number/word and an honest caption; honesty-critical cards (spend
/// margin, speed) avoid laundering unknown state to green.
class _HeroCards extends StatelessWidget {
  const _HeroCards({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final totalSpend = _totalSpend(envelope);
    final usingAi = _businessesUsingAi(envelope);
    final inactive = envelope.dormantOperators.length;
    final underwater = envelope.underwaterOperators.length;
    final speed = _speedSummary(envelope);
    final graph = envelope.graph;

    final cards = <Widget>[
      _HeroCard(
        keyName: 'admin_observability_hero_spend',
        accent: AppColors.sunset,
        icon: Icons.payments_outlined,
        label: 'AI spend',
        value: '\$${_formatUsd(totalSpend)}',
        caption: 'Across every use case this month.',
      ),
      _HeroCard(
        keyName: 'admin_observability_hero_customers',
        accent: AppColors.peacock,
        icon: Icons.storefront_outlined,
        label: 'Businesses using AI',
        value: usingAi == null ? '—' : '$usingAi',
        caption: usingAi == null
            ? 'No activity reported yet.'
            : inactive == 0
            ? 'All active.'
            : '$inactive inactive.',
        pill: underwater > 0
            ? _HeroPill(
                label: underwater == 1
                    ? '1 losing money'
                    : '$underwater losing money',
                tone: _HeroTone.bad,
              )
            : null,
      ),
      _HeroCard(
        keyName: 'admin_observability_hero_speed',
        accent: AppColors.positive,
        icon: Icons.speed_outlined,
        label: 'Speed & uptime',
        value: speed.headline,
        caption: speed.caption,
        pill: speed.pill,
      ),
      _HeroCard(
        keyName: 'admin_observability_hero_knowledge',
        accent: AppColors.warning,
        icon: Icons.menu_book_outlined,
        label: 'Advisor knowledge',
        value: graph.isolatedNodeCount > 0 ? 'Review' : 'Healthy',
        caption: graph.isolatedNodeCount == 0
            ? 'Everything is linked.'
            : graph.isolatedNodeCount == 1
            ? '1 item not linked yet.'
            : '${graph.isolatedNodeCount} items not linked yet.',
        pill: graph.isolatedNodeCount > 0
            ? const _HeroPill(label: 'Review suggested', tone: _HeroTone.watch)
            : const _HeroPill(label: 'Up to date', tone: _HeroTone.ok),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 14.0;
        // Equal-width AND equal-height tiles (IntrinsicHeight + stretch),
        // mirroring the mockup's `repeat(4, 1fr)` grid: 4-up when wide,
        // 2x2 when narrow. No more content-sized Wrap with ragged heights.
        final perRow = constraints.maxWidth >= 900 ? 4 : 2;
        final rows = <Widget>[];
        for (var i = 0; i < cards.length; i += perRow) {
          final end = (i + perRow) > cards.length ? cards.length : i + perRow;
          final rowCards = cards.sublist(i, end);
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var j = 0; j < rowCards.length; j++) ...<Widget>[
                    if (j > 0) const SizedBox(width: gap),
                    Expanded(child: rowCards[j]),
                  ],
                ],
              ),
            ),
          );
          if (end < cards.length) rows.add(const SizedBox(height: gap));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

enum _HeroTone { ok, watch, bad }

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, required this.tone});

  final String label;
  final _HeroTone tone;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (tone) {
      case _HeroTone.ok:
        color = AppColors.positive;
        break;
      case _HeroTone.watch:
        color = AppColors.warning;
        break;
      case _HeroTone.bad:
        color = AppColors.negative;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.chipLabel(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.keyName,
    required this.accent,
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
    this.pill,
  });

  final String keyName;
  final Color accent;
  final IconData icon;
  final String label;
  final String value;
  final String caption;
  final Widget? pill;

  @override
  Widget build(BuildContext context) {
    // A non-uniform Border (accent top + subtle sides) cannot carry a
    // borderRadius in Flutter. To get the mockup's coloured top edge on
    // a rounded card, use a uniform border and clip a 3px accent strip
    // above the body.
    return Container(
      key: Key(keyName),
      constraints: const BoxConstraints(minHeight: 178),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: AppColors.textPrimary.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(height: 4, color: accent),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.12),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.24),
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(icon, size: 21, color: accent),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.uiLabel(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.mono28(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                  if (pill != null) ...<Widget>[
                    const SizedBox(height: 12),
                    pill!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Money tab ────────────────────────────────────────────────────────

class _MoneyTab extends StatelessWidget {
  const _MoneyTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final slices = _costByUseCase(envelope);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_cost_telemetry',
            title: 'Where the money goes',
            subtitle: 'Cost by kind of AI work this month.',
            child: slices.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_cost_by_use_case_empty',
                    label: 'No cost recorded in this month yet.',
                  )
                : _CostDonut(slices: slices),
          ),
          _Panel(
            keyName: 'admin_observability_section_cache_hit_rates',
            title: 'Saved answer reuse',
            subtitle:
                'Higher is cheaper. Reusing a saved answer avoids paying for a new one.',
            child: envelope.cacheHitRates.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_cache_hit_rates_empty',
                    label: 'No saved-answer data in this month.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final entry in envelope.cacheHitRates)
                        _ReuseBar(
                          key: Key(
                            'admin_observability_cache_hit_rate_'
                            '${entry.queryClass}',
                          ),
                          entry: entry,
                        ),
                    ],
                  ),
          ),
          _Panel(
            keyName: 'admin_observability_section_cost_controls',
            title: 'Cost controls',
            subtitle: 'Levers that keep AI spend down.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _SubHead(
                  text: 'Which model handled the work',
                  hint: 'More of the cheaper, faster model is better.',
                ),
                const SizedBox(height: 8),
                if (envelope.modelMix.isEmpty)
                  const _EmptyState(
                    keyName: 'admin_observability_model_mix_empty',
                    label: 'No model routing data in this month.',
                  )
                else ...<Widget>[
                  const _ModelMixLegend(),
                  const SizedBox(height: 6),
                  for (final entry in envelope.modelMix)
                    _ModelMixBar(
                      key: Key(
                        'admin_observability_model_mix_${entry.queryClass}',
                      ),
                      entry: entry,
                    ),
                ],
                const SizedBox(height: 18),
                _SubHead(
                  text: 'Lower-cost batch work',
                  hint:
                      'Higher is cheaper. Batch work is billed at a lower rate.',
                ),
                const SizedBox(height: 8),
                if (envelope.batchModeShare.isEmpty)
                  const _EmptyState(
                    keyName: 'admin_observability_batch_mode_share_empty',
                    label: 'No batch work in this month.',
                  )
                else
                  for (final entry in envelope.batchModeShare)
                    _BatchShareBar(
                      key: Key(
                        'admin_observability_batch_mode_share_'
                        '${entry.queryClass}',
                      ),
                      entry: entry,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cost-by-use-case donut + legend. Renders a custom-painted ring with a
/// centered total and one legend row per use case (amount + percent).
class _CostDonut extends StatelessWidget {
  const _CostDonut({required this.slices});

  final List<_CostSlice> slices;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<double>(0, (sum, s) => sum + s.amount);
    return Wrap(
      key: const Key('admin_observability_cost_donut'),
      spacing: 30,
      runSpacing: 20,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 170,
          height: 170,
          child: CustomPaint(
            painter: _DonutPainter(slices: slices, total: total),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '\$${_formatUsd(total)}',
                    style: AppTextStyles.mono20(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'total',
                    style: AppTextStyles.body12(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 260, maxWidth: 360),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final slice in slices)
                Padding(
                  key: Key(
                    'admin_observability_cost_legend_${slice.queryClass}',
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          color: slice.color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          slice.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.body13(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '\$${_formatUsd(slice.amount)}',
                        style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 42,
                        child: Text(
                          total <= 0
                              ? '—'
                              : '${((slice.amount / total) * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: AppTextStyles.body12(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.slices, required this.total});

  final List<_CostSlice> slices;
  final double total;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 24.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Track.
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = AppColors.shimmer;
    canvas.drawCircle(center, radius, track);

    if (total <= 0) return;

    var startAngle = -math.pi / 2; // 12 o'clock.
    for (final slice in slices) {
      final sweep = (slice.amount / total) * 2 * math.pi;
      if (sweep <= 0) continue;
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt
        ..color = slice.color;
      canvas.drawArc(rect, startAngle, sweep, false, arc);
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) {
    return oldDelegate.total != total || oldDelegate.slices != slices;
  }
}

/// Saved-answer reuse horizontal bar. Colour follows the model's
/// green/yellow/red severity so a low-reuse class reads as a cost risk.
class _ReuseBar extends StatelessWidget {
  const _ReuseBar({super.key, required this.entry});

  final CacheHitRateEntry entry;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (entry.severity) {
      case HitRateSeverity.green:
        color = AppColors.positive;
        break;
      case HitRateSeverity.yellow:
        color = AppColors.warning;
        break;
      case HitRateSeverity.red:
        color = AppColors.negative;
        break;
    }
    final pct = (entry.hitRate * 100);
    return _LabeledBar(
      label: adminRequestUseCaseLabel(entry.queryClass),
      fraction: entry.hitRate,
      barColor: color,
      valueText: '${pct.toStringAsFixed(0)}%',
      valueColor: color,
    );
  }
}

class _ModelMixLegend extends StatelessWidget {
  const _ModelMixLegend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: <Widget>[
        _LegendSwatch(color: AppColors.positive, label: 'Fast model (cheaper)'),
        _LegendSwatch(
          color: AppColors.warning,
          label: 'Detailed model (pricier)',
        ),
      ],
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  const _LegendSwatch({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppTextStyles.body12(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// Model-mix split bar: a single track split into cheaper (green) and
/// pricier (amber) shares. An over-target detailed share carries an
/// "Over target" tag.
class _ModelMixBar extends StatelessWidget {
  const _ModelMixBar({super.key, required this.entry});

  final ModelMixEntry entry;

  @override
  Widget build(BuildContext context) {
    final over = entry.sonnetShareExceedsCeiling;
    final detailedPct = (entry.sonnetShare * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 160,
            child: Text(
              adminRequestUseCaseLabel(entry.queryClass),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body13(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 14,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      flex: math.max(0, (entry.haikuShare * 1000).round()),
                      child: const ColoredBox(color: AppColors.positive),
                    ),
                    Expanded(
                      flex: math.max(0, (entry.sonnetShare * 1000).round()),
                      child: const ColoredBox(color: AppColors.warning),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 190,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                Flexible(
                  child: Text(
                    '$detailedPct% detailed',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body12(color: AppColors.textSecondary),
                  ),
                ),
                if (over) ...<Widget>[
                  const SizedBox(width: 6),
                  Container(
                    key: Key(
                      'admin_observability_model_mix_over_${entry.queryClass}',
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      'Over target',
                      style: AppTextStyles.chipLabel(color: AppColors.warning),
                    ),
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

/// Lower-cost batch-work bar. Green when at or above target, neutral
/// otherwise; the caption states the target so the operator knows the
/// goal.
class _BatchShareBar extends StatelessWidget {
  const _BatchShareBar({super.key, required this.entry});

  final BatchModeShareEntry entry;

  @override
  Widget build(BuildContext context) {
    final meetsTarget = entry.batchShare >= entry.targetShare;
    final color = meetsTarget ? AppColors.positive : AppColors.warning;
    final pct = (entry.batchShare * 100).round();
    final targetPct = (entry.targetShare * 100).round();
    return _LabeledBar(
      label: adminRequestUseCaseLabel(entry.queryClass),
      fraction: entry.batchShare,
      barColor: color,
      valueText: '$pct% · target $targetPct%',
      valueColor: color,
    );
  }
}

/// Shared horizontal bar with a leading label, a track, and a trailing
/// value. The bold value uses [valueColor]; the rest of the trailing
/// caption stays muted.
class _LabeledBar extends StatelessWidget {
  const _LabeledBar({
    required this.label,
    required this.fraction,
    required this.barColor,
    required this.valueText,
    required this.valueColor,
  });

  final String label;
  final double fraction;
  final Color barColor;
  final String valueText;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 168,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body13(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 12,
                child: Stack(
                  children: <Widget>[
                    const Positioned.fill(
                      child: ColoredBox(color: AppColors.shimmer),
                    ),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: clamped == 0 ? 0.001 : clamped,
                      child: ColoredBox(color: barColor),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: Text(
              valueText,
              textAlign: TextAlign.right,
              style: AppTextStyles.body12(
                color: valueColor,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Customers tab ────────────────────────────────────────────────────

class _CustomersTab extends StatelessWidget {
  const _CustomersTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_top_spenders',
            title: 'Top spenders',
            subtitle:
                'The businesses, staff, and workflows using the most AI budget.',
            child: _TopSpenders(envelope: envelope),
          ),
          _Panel(
            keyName: 'admin_observability_section_needs_attention',
            title: 'Needs attention',
            subtitle: 'Businesses to follow up with.',
            child: _NeedsAttention(envelope: envelope),
          ),
        ],
      ),
    );
  }
}

/// Top spenders with a rolling-window selector (24 hours / 7 days /
/// 30 days). Bars are scaled to the largest spender in the window.
class _TopSpenders extends StatefulWidget {
  const _TopSpenders({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  State<_TopSpenders> createState() => _TopSpendersState();
}

class _TopSpendersState extends State<_TopSpenders> {
  ObservabilityWindow _window = ObservabilityWindow.sevenDays;

  @override
  Widget build(BuildContext context) {
    final rows =
        widget.envelope.topExpensiveForWindow(_window).toList(growable: false)
          ..sort((a, b) => b.totalUsd.compareTo(a.totalUsd));
    final maxUsd = rows.isEmpty
        ? 0.0
        : rows.map((r) => r.totalUsd).reduce(math.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: Alignment.centerRight,
          child: _WindowSelector(
            window: _window,
            onSelect: (w) => setState(() => _window = w),
          ),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          _EmptyState(
            keyName:
                'admin_observability_top_${observabilityWindowKey(_window)}_empty',
            label: 'No spending recorded in this window.',
          )
        else
          for (final row in rows)
            _SpenderRow(
              key: Key(
                'admin_observability_spender_'
                '${observabilityWindowKey(_window)}_${row.axis}_${row.label}',
              ),
              row: row,
              fraction: maxUsd <= 0 ? 0 : row.totalUsd / maxUsd,
            ),
      ],
    );
  }
}

class _WindowSelector extends StatelessWidget {
  const _WindowSelector({required this.window, required this.onSelect});

  final ObservabilityWindow window;
  final ValueChanged<ObservabilityWindow> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final entry in const <(ObservabilityWindow, String)>[
            (ObservabilityWindow.oneDay, '24 hours'),
            (ObservabilityWindow.sevenDays, '7 days'),
            (ObservabilityWindow.thirtyDays, '30 days'),
          ])
            InkWell(
              key: Key(
                'admin_observability_window_'
                '${observabilityWindowKey(entry.$1)}',
              ),
              onTap: () => onSelect(entry.$1),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: window == entry.$1
                      ? AppColors.sunset
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  entry.$2,
                  style:
                      AppTextStyles.body12(
                        color: window == entry.$1
                            ? AppColors.backgroundSurface
                            : AppColors.textSecondary,
                      ).copyWith(
                        fontWeight: window == entry.$1
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SpenderRow extends StatelessWidget {
  const _SpenderRow({super.key, required this.row, required this.fraction});

  final TopExpensiveEntry row;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 190,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  row.label.isEmpty ? 'Unnamed' : row.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body13(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  _spenderAxisLabel(row.axis),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 14,
                child: Stack(
                  children: <Widget>[
                    const Positioned.fill(
                      child: ColoredBox(color: AppColors.shimmer),
                    ),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: clamped == 0 ? 0.001 : clamped,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: <Color>[
                              AppColors.sunset,
                              AppColors.redSand,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 64,
            child: Text(
              '\$${_formatUsd(row.totalUsd)}',
              textAlign: TextAlign.right,
              style: AppTextStyles.mono12(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (row.operatorId != null && row.operatorId!.isNotEmpty)
            _ViewAccountLink(
              keyName:
                  'admin_observability_spender_view_'
                  '${observabilityWindowKey(row.window)}_${row.axis}_${row.label}',
              operatorId: row.operatorId!,
              operatorName: row.label,
            )
          else
            const SizedBox(width: 64),
        ],
      ),
    );
  }
}

/// "Needs attention" list. Three honest sources:
///   * Losing money (margins) - NO backend pricing source yet (Plans &
///     limits owns pricing), so when no margin rows are present this
///     renders an explicit "Not available yet" empty state, never $0.
///   * Limit hits (cap events) - one row per business that hit a limit.
///   * Inactive (dormancy) - businesses with no recent AI activity.
class _NeedsAttention extends StatelessWidget {
  const _NeedsAttention({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final underwater = envelope.underwaterOperators.toList(growable: false);
    final capByOperator = _capEventsByOperator(envelope);
    final dormant = envelope.dormantOperators.toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Losing money - honest empty state when pricing data is absent.
        _SubHead(
          text: 'Losing money',
          hint: 'AI cost is higher than the plan brings in.',
        ),
        const SizedBox(height: 8),
        if (envelope.margins.isEmpty)
          const _EmptyState(
            keyName: 'admin_observability_losing_money_unavailable',
            label:
                'Not available yet. Plan pricing is set in Plans and limits; '
                'margin comparison turns on once it is connected.',
          )
        else if (underwater.isEmpty)
          const _EmptyState(
            keyName: 'admin_observability_losing_money_empty',
            label: 'No businesses are losing money this month.',
          )
        else
          for (final margin in underwater)
            _AttentionRow(
              key: Key(
                'admin_observability_attention_losing_${margin.operatorId}',
              ),
              category: 'losing',
              tone: _HeroTone.bad,
              pillLabel: 'Losing money',
              lead: margin.businessName,
              why:
                  'Costs \$${_formatUsd(margin.costUsd - margin.revenueUsd)} '
                  'more than their plan brings in.',
              operatorId: margin.operatorId,
              operatorName: margin.businessName,
            ),
        const SizedBox(height: 18),
        // Limit hits.
        _SubHead(
          text: 'Limit hits',
          hint: 'A request was stopped because a usage limit was reached.',
        ),
        const SizedBox(height: 8),
        if (capByOperator.isEmpty)
          const _EmptyState(
            keyName: 'admin_observability_limit_hits_empty',
            label: 'No usage limits were reached this month.',
          )
        else
          for (final event in capByOperator)
            _AttentionRow(
              key: Key(
                'admin_observability_attention_limit_${event.operatorId}',
              ),
              category: 'limit',
              tone: _HeroTone.watch,
              pillLabel: 'Limit hit',
              lead: event.businessName,
              why:
                  'Reached its limit during '
                  '${adminRequestUseCaseLabel(event.queryClass)}.',
              operatorId: event.operatorId,
              operatorName: event.businessName,
            ),
        const SizedBox(height: 18),
        // Inactive.
        _SubHead(
          text: 'Inactive',
          hint: 'No recent AI activity. Support may want to follow up.',
        ),
        const SizedBox(height: 8),
        if (dormant.isEmpty)
          const _EmptyState(
            keyName: 'admin_observability_inactive_empty',
            label: 'Every business has been active recently.',
          )
        else
          for (final entry in dormant)
            _AttentionRow(
              key: Key(
                'admin_observability_attention_inactive_${entry.operatorId}',
              ),
              category: 'inactive',
              tone: _HeroTone.watch,
              pillLabel: 'Inactive',
              lead: entry.businessName,
              why: _dormancyWhy(entry),
              operatorId: entry.operatorId,
              operatorName: entry.businessName,
            ),
      ],
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    super.key,
    required this.category,
    required this.tone,
    required this.pillLabel,
    required this.lead,
    required this.why,
    required this.operatorId,
    required this.operatorName,
  });

  /// Category slug (`losing` / `limit` / `inactive`). Keeps the View
  /// account link key unique when one operator surfaces in more than one
  /// attention category.
  final String category;
  final _HeroTone tone;
  final String pillLabel;
  final String lead;
  final String why;
  final String operatorId;
  final String operatorName;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 104,
            child: _HeroPill(label: pillLabel, tone: tone),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  lead,
                  style: AppTextStyles.body13(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  why,
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ViewAccountLink(
            keyName:
                'admin_observability_attention_view_${category}_$operatorId',
            operatorId: operatorId,
            operatorName: operatorName,
          ),
        ],
      ),
    );
  }
}

/// "View account" drill-down. Dispatches an [AdminRouteIntent] to the
/// Business accounts route scoped to the chosen operator via the
/// [AdminRouteHandoff]. When no handoff is in scope (e.g. a bare widget
/// test pump) the link renders disabled so the screen never throws.
class _ViewAccountLink extends StatelessWidget {
  const _ViewAccountLink({
    required this.keyName,
    required this.operatorId,
    required this.operatorName,
  });

  final String keyName;
  final String operatorId;
  final String operatorName;

  @override
  Widget build(BuildContext context) {
    final handoff = AdminRouteHandoff.maybeOf(context);
    return InkWell(
      key: Key(keyName),
      onTap: handoff == null
          ? null
          : () => handoff.onSelectRoute(
              AdminRouteIntent(
                routeId: kAdminOperatorsRouteId,
                operatorLocationScope: AdminOperatorLocationScopeIntent(
                  operatorId: operatorId,
                  operatorName: operatorName.isEmpty ? null : operatorName,
                ),
              ),
            ),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'View account',
              style: AppTextStyles.body12(
                color: handoff == null
                    ? AppColors.textMuted
                    : AppColors.sunsetDark,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.arrow_forward,
              size: 14,
              color: handoff == null
                  ? AppColors.textMuted
                  : AppColors.sunsetDark,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Reliability tab ──────────────────────────────────────────────────

class _ReliabilityTab extends StatelessWidget {
  const _ReliabilityTab({
    super.key,
    required this.envelope,
    required this.tripwireGateway,
    required this.tripwires,
    required this.tripwireError,
  });

  final ObservabilityEnvelope envelope;
  final RealtimeTripwireAdminGateway? tripwireGateway;
  final RealtimeTripwireSnapshot? tripwires;
  final String? tripwireError;

  @override
  Widget build(BuildContext context) {
    final counts = envelope.projectionRetries.statusCounts;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_speed',
            title: 'Speed & uptime',
            subtitle: 'Per-request response time lives in System health.',
            child: _SpeedUptime(envelope: envelope),
          ),
          _Panel(
            keyName: 'admin_observability_section_background_jobs',
            title: 'Background jobs',
            subtitle:
                'Shift and open-period projection work waiting, running, or stuck.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _StatGrid(
                  stats: <_Stat>[
                    _Stat(
                      keyName: 'admin_observability_jobs_pending',
                      value: '${counts.pending}',
                      label: 'Waiting',
                      alert: false,
                    ),
                    _Stat(
                      keyName: 'admin_observability_jobs_running',
                      value: '${counts.running}',
                      label: 'In progress',
                      alert: false,
                    ),
                    _Stat(
                      keyName: 'admin_observability_jobs_dead_lettered',
                      value: '${counts.deadLettered}',
                      label: 'Stuck',
                      caption: counts.deadLettered > 0
                          ? 'Needs a person'
                          : null,
                      alert: counts.deadLettered > 0,
                    ),
                    _Stat(
                      keyName: 'admin_observability_jobs_succeeded',
                      value: '${counts.succeeded}',
                      label: 'Done',
                      alert: false,
                    ),
                  ],
                ),
                if (counts.deadLettered > 0) ...<Widget>[
                  const SizedBox(height: 14),
                  _InlineHint(
                    keyName: 'admin_observability_jobs_stuck_hint',
                    tone: _HeroTone.bad,
                    message: counts.deadLettered == 1
                        ? '1 job is stuck and needs support triage.'
                        : '${counts.deadLettered} jobs are stuck and need support triage.',
                  ),
                ],
              ],
            ),
          ),
          _Panel(
            keyName: 'admin_observability_section_cloud_run_instances',
            title: 'Hosting capacity',
            subtitle:
                'Servers running each AI service. Platform-wide, not per business.',
            child: envelope.cloudRun.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_cloud_run_empty',
                    label: 'No hosting services reported in this window.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final svc in envelope.cloudRun)
                        _HostingRow(
                          key: Key(
                            'admin_observability_cloud_run_${svc.serviceName}',
                          ),
                          service: svc,
                        ),
                    ],
                  ),
          ),
          if (tripwireGateway != null)
            _Panel(
              keyName: 'admin_observability_section_live_sync',
              title: 'Live sync',
              subtitle:
                  'Whether updates are flowing from the database to the apps.',
              child: _LiveSync(snapshot: tripwires, error: tripwireError),
            ),
        ],
      ),
    );
  }
}

/// Speed & uptime block. Per-route latency is empty on this surface
/// (owned by System health), so this links out honestly rather than
/// inventing numbers.
class _SpeedUptime extends StatelessWidget {
  const _SpeedUptime({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return _InlineHint(
      keyName: 'admin_observability_speed_health_link',
      tone: _HeroTone.watch,
      message:
          'Per-request response time and error rate live in System health. '
          'Open it for typical reply time, slow-request percentiles, and uptime.',
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});

  final List<_Stat> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 13.0;
        final columns = constraints.maxWidth >= 520 ? 4 : 2;
        final itemWidth =
            (constraints.maxWidth - (gap * (columns - 1))) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final stat in stats)
              SizedBox(
                width: itemWidth,
                child: _StatBlock(stat: stat),
              ),
          ],
        );
      },
    );
  }
}

class _Stat {
  const _Stat({
    required this.keyName,
    required this.value,
    required this.label,
    required this.alert,
    this.caption,
  });

  final String keyName;
  final String value;
  final String label;
  final bool alert;
  final String? caption;
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(stat.keyName),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: <Widget>[
          Text(
            stat.value,
            style: AppTextStyles.mono20(
              color: stat.alert ? AppColors.negative : AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            stat.label,
            textAlign: TextAlign.center,
            style: AppTextStyles.body12(
              color: AppColors.textSecondary,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
          if (stat.caption != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              stat.caption!,
              textAlign: TextAlign.center,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hosting capacity row. The active instance count can legitimately be
/// unknown; rather than implying zero servers, a missing count renders
/// the "—" sentinel with an "unknown" caption (Metric Honesty Doctrine).
class _HostingRow extends StatelessWidget {
  const _HostingRow({super.key, required this.service});

  final CloudRunInstanceMetric service;

  @override
  Widget build(BuildContext context) {
    final hasCount = service.instanceCount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          const Icon(Icons.dns_outlined, size: 20, color: AppColors.textMuted),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _hostingServiceLabel(service.serviceName),
              style: AppTextStyles.body13(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          if (hasCount)
            Text.rich(
              TextSpan(
                text: '${service.instanceCount}',
                style: AppTextStyles.mono16(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w700),
                children: <InlineSpan>[
                  TextSpan(
                    text: ' running',
                    style: AppTextStyles.body12(color: AppColors.textMuted),
                  ),
                ],
              ),
            )
          else
            // Honest unknown count: a standalone '—' missing-value
            // sentinel (the only sanctioned use of the glyph), then a
            // plain-English "unknown" descriptor. NOT "— running" with
            // the glyph as a separator (that would trip the no-em-dash
            // law).
            Row(
              key: Key(
                'admin_observability_cloud_run_unknown_${service.serviceName}',
              ),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '—',
                  style: AppTextStyles.mono16(
                    color: AppColors.textMuted,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                Text(
                  'running count unknown',
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          const SizedBox(width: 16),
          SizedBox(
            width: 220,
            child: Text(
              'Scales ${service.minInstances} to ${service.maxInstances} '
              'servers automatically',
              textAlign: TextAlign.right,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live sync (Realtime bridge tripwires). One row per Q22 metric with a
/// value, the yellow/red thresholds, and a status pill; the panel header
/// shows the worst-wins severity. Renders an inline error when the
/// gateway failed and a quiet loading line until the first snapshot.
class _LiveSync extends StatelessWidget {
  const _LiveSync({required this.snapshot, required this.error});

  final RealtimeTripwireSnapshot? snapshot;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Text(
        error!,
        key: const Key('admin_observability_live_sync_error'),
        style: AppTextStyles.mono11(color: AppColors.negative),
      );
    }
    final snap = snapshot;
    if (snap == null) {
      return Text(
        'Loading live sync status...',
        style: AppTextStyles.mono11(color: AppColors.textMuted),
      );
    }
    return Column(
      key: const Key('admin_observability_bridge_tripwires_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                _liveSyncHeadline(snap.status),
                style: AppTextStyles.body13(
                  color: _tripwireColor(snap.status),
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            _TripwirePill(status: snap.status),
          ],
        ),
        const SizedBox(height: 10),
        for (final row in snap.metrics)
          Padding(
            key: Key('admin_observability_bridge_tripwire_row_${row.key}'),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: _LiveSyncRow(row: row),
          ),
      ],
    );
  }
}

class _LiveSyncRow extends StatelessWidget {
  const _LiveSyncRow({required this.row});

  final RealtimeTripwireMetricRow row;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 180,
          child: Text(
            row.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
        ),
        SizedBox(
          width: 96,
          child: Text(
            row.value == null
                ? '—'
                : _formatTripwireValue(row.metric, row.value!),
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
        ),
        Expanded(
          child: Text(
            'Warns at ${_formatTripwireThreshold(row.metric, row.yellow)}, '
            'red at ${_formatTripwireThreshold(row.metric, row.red)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ),
        _RowTripwirePill(status: row.status),
      ],
    );
  }
}

// ── Knowledge tab ────────────────────────────────────────────────────

class _KnowledgeTab extends StatelessWidget {
  const _KnowledgeTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final graph = envelope.graph;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_graph_counts',
            title: 'What the advisor knows',
            subtitle:
                'Approved facts and links, system suggestions, and anything not linked yet.',
            child: _StatGrid(
              stats: <_Stat>[
                _Stat(
                  keyName: 'admin_observability_graph_approved_nodes',
                  value: '${graph.approvedNodeCount}',
                  label: 'Approved facts',
                  alert: false,
                ),
                _Stat(
                  keyName: 'admin_observability_graph_approved_edges',
                  value: '${graph.approvedEdgeCount}',
                  label: 'Approved links',
                  alert: false,
                ),
                _Stat(
                  keyName: 'admin_observability_graph_inferred_approved',
                  value: '${graph.inferredApprovedCount}',
                  label: 'System-suggested',
                  caption: 'Approved after review',
                  alert: false,
                ),
                _Stat(
                  keyName: 'admin_observability_graph_isolated_nodes',
                  value: '${graph.isolatedNodeCount}',
                  label: 'Not linked yet',
                  alert: graph.isolatedNodeCount > 0,
                ),
              ],
            ),
          ),
          _Panel(
            keyName: 'admin_observability_section_graph_freshness',
            title: 'Knowledge freshness',
            subtitle:
                'How recently the advisor knowledge was rebuilt and how fast it answers.',
            child: _StatGrid(
              stats: <_Stat>[
                _Stat(
                  keyName: 'admin_observability_graph_projection_age',
                  value: _ageLabel(graph.projectionAgeSeconds),
                  label: 'Last rebuild',
                  caption: graph.projectionAgeSeconds > 3600
                      ? 'Getting stale'
                      : 'Recent',
                  alert: false,
                ),
                _Stat(
                  keyName: 'admin_observability_graph_traversal_p95',
                  value: '${graph.traversalP95Ms}ms',
                  label: 'Lookup speed',
                  caption: 'Most lookups this fast',
                  alert: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared building blocks ───────────────────────────────────────────

/// Dashboard section panel. Routes every section through the shared
/// [OperatorWebPanel] console widget so the AI Metrics surface matches
/// the admin parity kit. The section [keyName] moves onto the panel so
/// widget tests resolve it; the outer [Padding] preserves inter-card
/// rhythm.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.keyName,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String keyName;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: OperatorWebPanel(
        key: Key(keyName),
        title: title,
        subtitle: subtitle,
        child: child,
      ),
    );
  }
}

class _SubHead extends StatelessWidget {
  const _SubHead({required this.text, required this.hint});

  final String text;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Text(
          text,
          style: AppTextStyles.body13(
            color: AppColors.textPrimary,
          ).copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _InlineHint extends StatelessWidget {
  const _InlineHint({
    required this.keyName,
    required this.tone,
    required this.message,
  });

  final String keyName;
  final _HeroTone tone;
  final String message;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    switch (tone) {
      case _HeroTone.ok:
        color = AppColors.positive;
        icon = Icons.check_circle_outline;
        break;
      case _HeroTone.watch:
        color = AppColors.warning;
        icon = Icons.info_outline;
        break;
      case _HeroTone.bad:
        color = AppColors.negative;
        icon = Icons.error_outline;
        break;
    }
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.32), width: 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.keyName, required this.label});

  final String keyName;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: AppTextStyles.body13(color: AppColors.textMuted),
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
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
  }
}

// ── Tripwire pills (reused from the pre-redesign live-sync section) ───

class _TripwirePill extends StatelessWidget {
  const _TripwirePill({required this.status});

  final OutboxTripwireStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = _paletteFor(status);
    return Container(
      key: Key(
        'admin_observability_bridge_tripwire_status_'
        '${outboxTripwireStatusKey(status)}',
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.background,
        border: Border.all(color: palette.border, width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        palette.label,
        style: AppTextStyles.chipLabel(color: palette.text),
      ),
    );
  }
}

class _RowTripwirePill extends StatelessWidget {
  const _RowTripwirePill({required this.status});

  final RealtimeTripwireRowStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = _rowPaletteFor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: palette.background,
        border: Border.all(color: palette.border, width: 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        palette.label,
        style: AppTextStyles.chipLabel(color: palette.text),
      ),
    );
  }
}

class _TripwirePalette {
  const _TripwirePalette({
    required this.label,
    required this.text,
    required this.background,
    required this.border,
  });

  final String label;
  final Color text;
  final Color background;
  final Color border;
}

_TripwirePalette _paletteFor(OutboxTripwireStatus status) {
  switch (status) {
    case OutboxTripwireStatus.green:
      return const _TripwirePalette(
        label: 'Healthy',
        text: AppColors.positive,
        background: Color(0x26256B29),
        border: Color(0x66256B29),
      );
    case OutboxTripwireStatus.yellow:
      return const _TripwirePalette(
        label: 'Needs attention',
        text: AppColors.warning,
        background: AppColors.warningBadgeBg,
        border: Color(0x66997000),
      );
    case OutboxTripwireStatus.red:
      return const _TripwirePalette(
        label: 'Degraded',
        text: AppColors.negative,
        background: Color(0x26C62828),
        border: Color(0x66C62828),
      );
  }
}

_TripwirePalette _rowPaletteFor(RealtimeTripwireRowStatus status) {
  switch (status) {
    case RealtimeTripwireRowStatus.green:
      return _paletteFor(OutboxTripwireStatus.green);
    case RealtimeTripwireRowStatus.yellow:
      return _paletteFor(OutboxTripwireStatus.yellow);
    case RealtimeTripwireRowStatus.red:
      return _paletteFor(OutboxTripwireStatus.red);
    case RealtimeTripwireRowStatus.unknown:
      return const _TripwirePalette(
        label: 'Unknown',
        text: AppColors.textMuted,
        background: AppColors.backgroundDeep,
        border: AppColors.borderSubtle,
      );
  }
}

Color _tripwireColor(OutboxTripwireStatus status) {
  switch (status) {
    case OutboxTripwireStatus.green:
      return AppColors.positive;
    case OutboxTripwireStatus.yellow:
      return AppColors.warning;
    case OutboxTripwireStatus.red:
      return AppColors.negative;
  }
}

String _liveSyncHeadline(OutboxTripwireStatus status) {
  switch (status) {
    case OutboxTripwireStatus.green:
      return 'Updates are flowing with no delays.';
    case OutboxTripwireStatus.yellow:
      return 'Updates are flowing, but one signal needs attention.';
    case OutboxTripwireStatus.red:
      return 'Updates are delayed. The live sync bridge is degraded.';
  }
}

// ── Derivations + formatting ─────────────────────────────────────────

class _CostSlice {
  const _CostSlice({
    required this.queryClass,
    required this.label,
    required this.amount,
    required this.color,
  });

  final String queryClass;
  final String label;
  final double amount;
  final Color color;
}

class _SpeedSummary {
  const _SpeedSummary({
    required this.headline,
    required this.caption,
    required this.pill,
  });

  final String headline;
  final String caption;
  final Widget? pill;
}

/// Sums cost telemetry by `query_class` into donut slices, largest
/// first. Each slice gets a stable accent from [_kUseCaseAccents].
List<_CostSlice> _costByUseCase(ObservabilityEnvelope envelope) {
  final totals = <String, double>{};
  for (final row in envelope.costTelemetry) {
    totals[row.queryClass] = (totals[row.queryClass] ?? 0) + row.totalUsd;
  }
  final entries = totals.entries.where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return <_CostSlice>[
    for (var i = 0; i < entries.length; i++)
      _CostSlice(
        queryClass: entries[i].key,
        label: adminRequestUseCaseLabel(entries[i].key),
        amount: entries[i].value,
        color: _kUseCaseAccents[i % _kUseCaseAccents.length],
      ),
  ];
}

double _totalSpend(ObservabilityEnvelope envelope) {
  var sum = 0.0;
  for (final row in envelope.costTelemetry) {
    sum += row.totalUsd;
  }
  return sum;
}

/// Count of businesses with reported AI activity. Returns null (→ "—")
/// when no dormancy/margin rows exist, so the hero card never implies a
/// hard zero where the producer simply reported nothing.
int? _businessesUsingAi(ObservabilityEnvelope envelope) {
  if (envelope.dormancy.isEmpty && envelope.margins.isEmpty) return null;
  if (envelope.dormancy.isNotEmpty) {
    return envelope.dormancy.where((d) => !d.isDormant).length;
  }
  return envelope.margins.length;
}

/// Speed hero summary. Per-route latency is empty on this surface
/// (owned by System health), so the headline avoids inventing a number
/// and points the operator to System health instead of laundering an
/// unknown to "Fast".
_SpeedSummary _speedSummary(ObservabilityEnvelope envelope) {
  final deadLettered = envelope.projectionRetries.statusCounts.deadLettered;
  if (deadLettered > 0) {
    return _SpeedSummary(
      headline: 'Check',
      caption: 'Background jobs are stuck. See Reliability.',
      pill: const _HeroPill(label: 'Needs attention', tone: _HeroTone.watch),
    );
  }
  return const _SpeedSummary(
    headline: 'See health',
    caption: 'Response time and uptime live in System health.',
    pill: _HeroPill(label: 'In System health', tone: _HeroTone.ok),
  );
}

/// One cap event per operator (most recent wins) for the "Limit hits"
/// list, so a runaway operator does not flood the section with rows.
List<CapEvent> _capEventsByOperator(ObservabilityEnvelope envelope) {
  final byOperator = <String, CapEvent>{};
  for (final event in envelope.capEvents) {
    final existing = byOperator[event.operatorId];
    if (existing == null || event.occurredAt.isAfter(existing.occurredAt)) {
      byOperator[event.operatorId] = event;
    }
  }
  return byOperator.values.toList(growable: false);
}

String _dormancyWhy(OperatorDormancyEntry entry) {
  if (entry.neverActive) return 'No AI activity yet.';
  final silent = entry.daysSilent;
  if (silent == null) return 'No recent AI activity.';
  return 'No AI activity for $silent days.';
}

String _spenderAxisLabel(String axis) {
  switch (axis.trim().toLowerCase()) {
    case 'operator':
      return 'Business';
    case 'staff':
      return 'Staff member';
    case 'workflow':
      return 'Workflow';
    default:
      return axis.isEmpty ? 'Scope' : axis;
  }
}

String _hostingServiceLabel(String serviceName) {
  final lower = serviceName.toLowerCase();
  if (lower.contains('advisor')) return 'Advisor service';
  if (lower.contains('admin')) return 'Admin service';
  return 'Hosting service';
}

/// Plain-English elapsed-time label for the knowledge-freshness card.
String _ageLabel(int seconds) {
  if (seconds <= 0) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '${minutes}m ago';
  final hours = (seconds / 3600).round();
  if (hours < 24) return '${hours}h ago';
  final days = (seconds / 86400).round();
  return '${days}d ago';
}

/// Currency formatter: thousands separator, no cents above $100 so the
/// hero numbers stay scannable; cents below for small figures.
String _formatUsd(double value) {
  final abs = value.abs();
  final fixed = abs >= 100 ? value.roundToDouble() : value;
  final hasCents = abs < 100;
  final str = hasCents ? fixed.toStringAsFixed(2) : fixed.toStringAsFixed(0);
  final parts = str.split('.');
  final intPart = parts[0];
  final buffer = StringBuffer();
  final digits = intPart.replaceFirst('-', '');
  final negative = intPart.startsWith('-');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  final withCommas = '${negative ? '-' : ''}$buffer';
  return hasCents ? '$withCommas.${parts[1]}' : withCommas;
}

String _formatTripwireValue(OutboxTripwireMetric metric, num value) {
  switch (metric) {
    case OutboxTripwireMetric.bridgeLagSeconds:
      return '${value.toStringAsFixed(0)} s';
    case OutboxTripwireMetric.undeliveredCount:
      return value.toInt().toString();
    case OutboxTripwireMetric.publishErrorRate:
    case OutboxTripwireMetric.notifyQueueUsage:
      return '${(value * 100).toStringAsFixed(2)} %';
  }
}

String _formatTripwireThreshold(OutboxTripwireMetric metric, num value) {
  switch (metric) {
    case OutboxTripwireMetric.bridgeLagSeconds:
      return '${value.toStringAsFixed(0)} s';
    case OutboxTripwireMetric.undeliveredCount:
      return value.toInt().toString();
    case OutboxTripwireMetric.publishErrorRate:
    case OutboxTripwireMetric.notifyQueueUsage:
      return '${(value * 100).toStringAsFixed(2)} %';
  }
}
