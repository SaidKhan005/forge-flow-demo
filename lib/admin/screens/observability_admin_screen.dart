// Phase 11A.6 / AI Metrics redesign — Observability dashboard surface.
//
// Read-only operator-facing view of the cost-telemetry, dormancy,
// margin, cap-event, graph, latency, and Cloud Run rows the
// observability proxy assembles. Rebuilt to the approved AI Metrics
// mockup (docs/_mockups/ai_metrics_redesign/index.html): four
// plain-English tabs instead of seven dense ones, four hero summary
// cards, a cost-by-use-case donut, and horizontal reuse bars.
//
//   * Money       — cost by use case (donut), saved-answer reuse (bars),
//                   cost controls (model mix + lower-cost batch).
//   * Customers   — top spenders (bars) + a "Needs attention" list
//                   (losing money / limit hits / inactive) with
//                   "View account" drill-down handoffs.
//   * Reliability — speed & uptime (links to System health for
//                   latency), background jobs (projection retries),
//                   hosting (Cloud Run), live sync (bridge tripwires).
//   * Knowledge   — graph counts (approved / suggested / unlinked) and
//                   freshness (projection age, lookup speed).
//
// The /health envelope (dependency probes, tier-1 / tier-2 / tier-3
// metric tiers) is owned by the F.1 health surface. The header keeps
// the "Open System health" hint so the F&F admin can jump there for
// dependency checks and latency detail without duplicating chrome.
//
// METRIC HONESTY DOCTRINE (binding): no phantom zeros. "Losing money"
// (margins) has no real backend producer yet (Plans & limits owns
// pricing); when every margin row is a placeholder zero the surface
// renders an honest "Not available yet" empty state rather than a
// fabricated $0. Cloud Run live counts that are unknown stay "unknown",
// never 0. The `—` glyph is the sanctioned missing-value sentinel.
//
// Performance posture (per docs/contracts/slice_runtime_acceptance_contract.md):
// the cost / dormancy queries scan rolling windows on `usage_logs` and
// can take seconds. The screen does NOT auto-poll. The first paint
// renders a manual-run prompt; the operator confirms a "Run metrics
// check" before any fetch fires. Refresh and the month switch reuse
// the same fetch path. Stacked in-flight requests are blocked by
// `_refreshing`.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../services/realtime/outbox_tripwire_evaluator.dart';
import '../../theme/app_theme.dart';

import '../admin_human_labels.dart';
import '../admin_route_handoff.dart';
import '../admin_routes.dart' show kAdminOperatorsRouteId;
import '../models/observability_admin_models.dart';
import '../services/observability_admin_gateway.dart';
import '../services/realtime_tripwire_admin_gateway.dart';
import '../widgets/admin_run_check_controls.dart';
import '../widgets/admin_scope_notice_adapter.dart';
import 'package:forge_and_flow/operator_web/widgets/hierarchy_scope_notice.dart';

/// One of the four redesigned tabs.
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
  _TabSpec(label: 'Money', keySuffix: 'money', icon: Icons.savings_outlined),
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

/// Donut / bar accent palette for the cost-by-use-case ring. Reuses
/// the existing brand tokens (sunset, peacock, ocean, sand) so the
/// chart needs no new theme colours; mirrors the four wedges in the
/// approved mockup.
const List<Color> _kUseCasePalette = <Color>[
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

  /// Phase 10a.4 — optional gateway for the Realtime bridge tripwire
  /// section. When wired, the manual run-check refreshes both the
  /// observability envelope AND the tripwire status; the section
  /// renders inside the Reliability tab ("Live sync"). When null, the
  /// section is omitted and existing tests stay green without it.
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

  /// "This month / Last month" selector wired into the fetch
  /// (`ObservabilityFetchRequest.month`). Because `usage_logs` is a
  /// monthly rollup, only current / previous are honest choices.
  ObservabilityMonth _month = ObservabilityMonth.current;

  // Phase 10a.4 — bridge tripwire state. Loads alongside the
  // observability envelope when [widget.tripwireGateway] is wired;
  // renders inside the Reliability tab.
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

  /// Switch the calendar-month bucket and re-fetch. Skips the
  /// confirmation dialog — narrowing/sliding the window in place is the
  /// runtime contract's "scope down" path; the confirmation guards the
  /// first expensive run only. No-ops before the first envelope loads.
  Future<void> _selectMonth(ObservabilityMonth month) async {
    if (_month == month || _refreshing) return;
    setState(() => _month = month);
    if (_envelope == null && _loadError == null) return;
    await _refresh();
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
        _loadError = 'Could not load AI metrics: $error';
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
    // Phase 10a.4 — refresh the tripwire envelope after the main fetch
    // settles. Failure here does not poison the rest of the screen; the
    // section renders an inline error chip instead.
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
              _Header(
                lastRefreshed: _lastRefreshed,
                onRunCheck: _confirmAndRefresh,
                loading: _loading || _refreshing,
                month: _month,
                onSelectMonth: _selectMonth,
              ),
              const SizedBox(height: 12),
              if (widget.hierarchyScope != null)
                HierarchyScopeNotice(
                  keyName: 'admin_observability_scope_notice',
                  selectedScope: adminScopeLevel(
                    widget.hierarchyScope!.scopeType,
                  ),
                  scopeName: widget.hierarchyScope!.displayLabel,
                  effectiveValueSummary:
                      'AI usage, cost, and reliability for the selected scope.',
                  backendOnlyHelpTitle: 'What stays platform-wide',
                  backendOnlyExplainer:
                      'Hosting and knowledge graph signals stay platform-wide when they are not stored per business.',
                ),
              if (_loadError != null)
                _ErrorBanner(
                  key: const Key('admin_observability_load_error'),
                  message: _loadError!,
                ),
              if (_envelope != null) _envelopeBody(_envelope!),
              if (_loading && _envelope == null)
                const Expanded(
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
                _ManualRunPrompt(onRunCheck: _confirmAndRefresh),
            ];
            final column = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            );
            if (!showManualPrompt) return column;
            return SingleChildScrollView(child: column);
          },
        ),
      ),
    );
  }

  Widget _envelopeBody(ObservabilityEnvelope envelope) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeroCards(envelope: envelope),
          const SizedBox(height: 18),
          TabBar(
            key: const Key('admin_observability_tabs'),
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.sunset,
            tabs: <Widget>[
              for (final tab in _kTabs)
                Tab(
                  key: Key('admin_observability_tab_${tab.keySuffix}'),
                  height: 44,
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
          const SizedBox(height: 12),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _MoneyTab(
                  key: const Key('admin_observability_tab_body_money'),
                  envelope: envelope,
                ),
                _CustomersTab(
                  key: const Key('admin_observability_tab_body_customers'),
                  envelope: envelope,
                ),
                _ReliabilityTab(
                  key: const Key('admin_observability_tab_body_reliability'),
                  envelope: envelope,
                  tripwires: _tripwires,
                  tripwireError: _tripwireError,
                  showTripwires: widget.tripwireGateway != null,
                ),
                _KnowledgeTab(
                  key: const Key('admin_observability_tab_body_knowledge'),
                  envelope: envelope,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Header ───────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
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
    return OperatorWebScreenHeader(
      icon: Icons.insights_outlined,
      title: 'AI Metrics',
      subtitle:
          'What the AI advisor costs, who uses it, and whether it is healthy.',
      collapseBelowWidth: 720,
      actions: <Widget>[
        _MonthSelector(
          month: month,
          enabled: !loading,
          onSelectMonth: onSelectMonth,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
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
              const SizedBox(height: 6),
              Text(
                lastRefreshed == null
                    ? 'Last refreshed: -'
                    : 'Last refreshed: ${adminHumanDateTime(lastRefreshed!)}',
                key: const Key('admin_observability_last_refreshed'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
              const SizedBox(height: 4),
              Text(
                'Open System health for dependency checks.',
                key: const Key('admin_observability_health_link_hint'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "This month / Last month" segmented control. Maps to the
/// [ObservabilityMonth] wire enum; only two honest buckets exist
/// because `usage_logs` is a monthly rollup.
class _MonthSelector extends StatelessWidget {
  const _MonthSelector({
    required this.month,
    required this.enabled,
    required this.onSelectMonth,
  });

  final ObservabilityMonth month;
  final bool enabled;
  final ValueChanged<ObservabilityMonth> onSelectMonth;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_observability_month_selector'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _MonthSegment(
            keyName: 'admin_observability_month_current',
            label: 'This month',
            selected: month == ObservabilityMonth.current,
            enabled: enabled,
            onTap: () => onSelectMonth(ObservabilityMonth.current),
          ),
          _MonthSegment(
            keyName: 'admin_observability_month_previous',
            label: 'Last month',
            selected: month == ObservabilityMonth.previous,
            enabled: enabled,
            onTap: () => onSelectMonth(ObservabilityMonth.previous),
          ),
        ],
      ),
    );
  }
}

class _MonthSegment extends StatelessWidget {
  const _MonthSegment({
    required this.keyName,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String keyName;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: Key(keyName),
        onTap: enabled && !selected ? onTap : null,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.sunset : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: AppTextStyles.body12(
              color: selected
                  ? AppColors.backgroundSurface
                  : AppColors.textSecondary,
            ).copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
          ),
        ),
      ),
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
      description:
          'This reads recent usage, cost, limits, activity, and hosting data. It is read-only and can take 10-30 seconds.',
      confirmLabel: 'Run metrics check',
      facts: [
        AdminRunCheckFact(
          icon: Icons.visibility_outlined,
          label: 'Read-only',
          text: 'No plans, limits, or records are changed.',
        ),
        AdminRunCheckFact(
          icon: Icons.query_stats_outlined,
          label: 'Scope',
          text: 'Cost, usage, customer activity, knowledge, and hosting rows.',
        ),
        AdminRunCheckFact(
          icon: Icons.schedule_outlined,
          label: 'Timing',
          text: 'Live staging metrics can take a few moments to load.',
        ),
      ],
    );
  }
}

class _ManualRunPrompt extends StatelessWidget {
  const _ManualRunPrompt({required this.onRunCheck});

  final Future<void> Function() onRunCheck;

  @override
  Widget build(BuildContext context) {
    return AdminRunCheckPrompt(
      key: const Key('admin_observability_manual_prompt'),
      icon: Icons.insights_outlined,
      title: 'Check AI Metrics',
      description:
          'Load the current staging view before comparing cost, usage, limits, and hosting signals.',
      buttonLabel: 'Run metrics check',
      onPressed: () {
        onRunCheck();
      },
      facts: const [
        AdminRunCheckFact(
          icon: Icons.visibility_outlined,
          label: 'Read-only',
          text: 'No plans, limits, or records are changed.',
        ),
        AdminRunCheckFact(
          icon: Icons.query_stats_outlined,
          label: 'Scope',
          text: 'Usage, cost, customer activity, knowledge, and hosting.',
        ),
        AdminRunCheckFact(
          icon: Icons.schedule_outlined,
          label: 'Timing',
          text: 'Recent usage reads can take 10-30 seconds.',
        ),
      ],
    );
  }
}

// ── Hero summary cards ───────────────────────────────────────────────

/// The four hero cards across the top of every tab: AI spend,
/// Businesses using AI, Speed & uptime, Advisor knowledge. Each maps
/// to live envelope fields; honesty-critical fields ("Losing money",
/// unknown speed) degrade to neutral copy rather than a green zero.
class _HeroCards extends StatelessWidget {
  const _HeroCards({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final spend = envelope.costTelemetry.fold<double>(
      0,
      (sum, row) => sum + row.totalUsd,
    );
    final totalBusinesses = envelope.dormancy.length;
    final activeBusinesses = envelope.dormancy
        .where((d) => !d.isDormant)
        .length;
    final inactiveBusinesses = totalBusinesses - activeBusinesses;
    final underwaterCount = _realUnderwaterCount(envelope);

    // Speed: median of the per-route p50s, when route latency is
    // populated. route_latency is empty today, so this honestly reads
    // "See System health" rather than fabricating a number.
    final speedCard = _heroSpeedCard(envelope);

    // Knowledge: graph health summary.
    final graph = envelope.graph;
    final knowledgeUnlinked = graph.isolatedNodeCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 880
            ? 4
            : constraints.maxWidth >= 460
            ? 2
            : 1;
        const gap = 14.0;
        final cardWidth =
            (constraints.maxWidth - (gap * (columns - 1))) / columns;
        final cards = <Widget>[
          _HeroCard(
            keyName: 'admin_observability_hero_spend',
            icon: Icons.savings_outlined,
            accent: AppColors.sunset,
            label: 'AI spend this view',
            value: _formatUsd(spend),
            caption: 'Across all use cases in the selected window.',
          ),
          _HeroCard(
            keyName: 'admin_observability_hero_businesses',
            icon: Icons.storefront_outlined,
            accent: AppColors.peacock,
            label: 'Businesses using AI',
            value: totalBusinesses == 0
                ? '—'
                : '$activeBusinesses / $totalBusinesses',
            caption: totalBusinesses == 0
                ? 'No businesses registered yet.'
                : '$inactiveBusinesses inactive.',
            pill: underwaterCount == null
                ? const _HeroPill(
                    label: 'Profit not tracked yet',
                    tone: _HeroPillTone.neutral,
                  )
                : underwaterCount > 0
                ? _HeroPill(
                    label: '$underwaterCount losing money',
                    tone: _HeroPillTone.bad,
                  )
                : const _HeroPill(
                    label: 'All covered',
                    tone: _HeroPillTone.ok,
                  ),
          ),
          speedCard,
          _HeroCard(
            keyName: 'admin_observability_hero_knowledge',
            icon: Icons.menu_book_outlined,
            accent: AppColors.warning,
            label: 'Advisor knowledge',
            value: knowledgeUnlinked > 0 ? 'Review' : 'Healthy',
            caption: knowledgeUnlinked > 0
                ? '$knowledgeUnlinked items not linked yet.'
                : 'Everything is linked.',
            pill: knowledgeUnlinked > 0
                ? const _HeroPill(
                    label: 'Review suggested',
                    tone: _HeroPillTone.watch,
                  )
                : const _HeroPill(label: 'Up to date', tone: _HeroPillTone.ok),
          ),
        ];
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final card in cards)
              SizedBox(width: math.max(cardWidth, 0), child: card),
          ],
        );
      },
    );
  }

  Widget _heroSpeedCard(ObservabilityEnvelope envelope) {
    final rows = envelope.routeLatency;
    if (rows.isEmpty) {
      return const _HeroCard(
        keyName: 'admin_observability_hero_speed',
        icon: Icons.speed_outlined,
        accent: AppColors.positive,
        label: 'Speed & uptime',
        value: '—',
        caption: 'See System health for live response times.',
        pill: _HeroPill(label: 'In System health', tone: _HeroPillTone.neutral),
      );
    }
    final medianP50 =
        (rows.map((r) => r.p50Ms).reduce((a, b) => a + b) / rows.length)
            .round();
    final worstError = rows
        .map((r) => r.errorRate)
        .reduce((a, b) => a > b ? a : b);
    final healthy = worstError <= 0.01;
    return _HeroCard(
      keyName: 'admin_observability_hero_speed',
      icon: Icons.speed_outlined,
      accent: AppColors.positive,
      label: 'Speed & uptime',
      value: healthy ? 'Fast' : 'Watch',
      caption: 'Typical reply ${medianP50}ms.',
      pill: healthy
          ? const _HeroPill(label: 'Healthy', tone: _HeroPillTone.ok)
          : const _HeroPill(label: 'Errors rising', tone: _HeroPillTone.bad),
    );
  }
}

enum _HeroPillTone { ok, watch, bad, neutral }

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, required this.tone});

  final String label;
  final _HeroPillTone tone;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (tone) {
      case _HeroPillTone.ok:
        color = AppColors.positive;
        break;
      case _HeroPillTone.watch:
        color = AppColors.warning;
        break;
      case _HeroPillTone.bad:
        color = AppColors.negative;
        break;
      case _HeroPillTone.neutral:
        color = AppColors.neutral;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color, width: 1),
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
          Text(
            label,
            style: AppTextStyles.chipLabel(color: color),
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.keyName,
    required this.icon,
    required this.accent,
    required this.label,
    required this.value,
    required this.caption,
    this.pill,
  });

  final String keyName;
  final IconData icon;
  final Color accent;
  final String label;
  final String value;
  final String caption;
  final Widget? pill;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border(
          top: BorderSide(color: accent, width: 3),
          left: BorderSide(color: AppColors.borderSubtle, width: 1),
          right: BorderSide(color: AppColors.borderSubtle, width: 1),
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(4),
          bottom: Radius.circular(12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.uiLabel(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: AppTextStyles.mono20(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            caption,
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          if (pill != null) ...<Widget>[
            const SizedBox(height: 9),
            pill!,
          ],
        ],
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_cost_by_use_case',
            title: 'Where the money goes',
            subtitle: 'Estimated cost by kind of AI work for this window.',
            child: _CostByUseCase(rows: envelope.costTelemetry),
          ),
          _Panel(
            keyName: 'admin_observability_section_cache_hit_rates',
            title: 'Saved answer reuse',
            subtitle:
                'How often a saved answer is reused instead of paying again. Higher is cheaper.',
            child: envelope.cacheHitRates.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_cache_hit_rates_empty',
                    label: 'No saved-answer data in this window.',
                  )
                : Column(
                    children: <Widget>[
                      for (final entry in _sortedHitRates(envelope.cacheHitRates))
                        _ReuseBar(
                          key: Key(
                            'admin_observability_cache_hit_rate_'
                            '${entry.queryClass}',
                          ),
                          label: adminRequestUseCaseLabel(entry.queryClass),
                          fraction: entry.hitRate,
                          color: _hitRateColor(entry.severity),
                          valueLabel:
                              '${(entry.hitRate * 100).toStringAsFixed(0)}%',
                        ),
                    ],
                  ),
          ),
          _Panel(
            keyName: 'admin_observability_section_cost_controls',
            title: 'Cost controls',
            subtitle: 'Levers that keep AI spend down.',
            child: _CostControls(envelope: envelope),
          ),
        ],
      ),
    );
  }
}

/// Cost-by-use-case donut + legend (mockup "Where the money goes").
/// Groups `cost_telemetry` rows by `query_class`, sums USD, and draws
/// a ring with one wedge per use case plus a plain-language legend.
class _CostByUseCase extends StatelessWidget {
  const _CostByUseCase({required this.rows});

  final List<CostTelemetryEntry> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const _EmptyState(
        keyName: 'admin_observability_cost_by_use_case_empty',
        label: 'No cost rows in this window yet.',
      );
    }
    final totals = <String, double>{};
    for (final row in rows) {
      totals[row.queryClass] = (totals[row.queryClass] ?? 0) + row.totalUsd;
    }
    final entries = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final grandTotal = entries.fold<double>(0, (sum, e) => sum + e.value);
    final segments = <_DonutSegment>[
      for (var i = 0; i < entries.length; i++)
        _DonutSegment(
          color: _kUseCasePalette[i % _kUseCasePalette.length],
          fraction: grandTotal <= 0 ? 0 : entries[i].value / grandTotal,
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final donut = SizedBox(
          width: 170,
          height: 170,
          child: CustomPaint(
            painter: _DonutPainter(segments: segments),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _formatUsd(grandTotal),
                    key: const Key('admin_observability_cost_total'),
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
        );
        final legend = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < entries.length; i++)
              _LegendRow(
                key: Key(
                  'admin_observability_cost_legend_${entries[i].key}',
                ),
                color: _kUseCasePalette[i % _kUseCasePalette.length],
                label: adminRequestUseCaseLabel(entries[i].key),
                amount: _formatUsd(entries[i].value),
                percent: grandTotal <= 0
                    ? '0%'
                    : '${(entries[i].value / grandTotal * 100).toStringAsFixed(0)}%',
              ),
          ],
        );
        if (constraints.maxWidth < 460) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[donut, const SizedBox(height: 18), legend],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            donut,
            const SizedBox(width: 28),
            Expanded(child: legend),
          ],
        );
      },
    );
  }
}

class _DonutSegment {
  const _DonutSegment({required this.color, required this.fraction});
  final Color color;
  final double fraction;
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({required this.segments});

  final List<_DonutSegment> segments;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 24.0;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = AppColors.shimmer;
    canvas.drawArc(rect, 0, math.pi * 2, false, track);

    var start = -math.pi / 2;
    const gap = 0.04;
    for (final segment in segments) {
      final sweep = segment.fraction * math.pi * 2;
      if (sweep <= 0) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt
        ..color = segment.color;
      final drawnSweep = (sweep - gap).clamp(0.0, math.pi * 2).toDouble();
      canvas.drawArc(rect, start + gap / 2, drawnSweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.segments != segments;
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    super.key,
    required this.color,
    required this.label,
    required this.amount,
    required this.percent,
  });

  final Color color;
  final String label;
  final String amount;
  final String percent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body13(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            amount,
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Text(
              percent,
              textAlign: TextAlign.right,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal labelled bar used for saved-answer reuse and batch share.
class _ReuseBar extends StatelessWidget {
  const _ReuseBar({
    super.key,
    required this.label,
    required this.fraction,
    required this.color,
    required this.valueLabel,
    this.trailingNote,
  });

  final String label;
  final double fraction;
  final Color color;
  final String valueLabel;
  final String? trailingNote;

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 168,
            child: Text(
              label,
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
              child: Container(
                height: 12,
                color: AppColors.shimmer,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: clamped,
                  child: Container(color: color),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: trailingNote == null ? 56 : 132,
            child: Text.rich(
              TextSpan(
                text: valueLabel,
                style: AppTextStyles.mono12(color: color, weight: FontWeight.w700),
                children: <InlineSpan>[
                  if (trailingNote != null)
                    TextSpan(
                      text: ' $trailingNote',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                ],
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

/// Cost controls panel: model mix (which model handled the work) and
/// lower-cost batch share, grouped exactly as in the mockup.
class _CostControls extends StatelessWidget {
  const _CostControls({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final hasModelMix = envelope.modelMix.isNotEmpty;
    final hasBatch = envelope.batchModeShare.isNotEmpty;
    if (!hasModelMix && !hasBatch) {
      return const _EmptyState(
        keyName: 'admin_observability_cost_controls_empty',
        label: 'No model-routing or batch data in this window.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SubHead(
          title: 'Which model handled the work',
          note: 'More of the cheaper model is better.',
        ),
        if (!hasModelMix)
          const _EmptyState(
            keyName: 'admin_observability_model_mix_empty',
            label: 'No model routing data in this window.',
          )
        else ...<Widget>[
          const SizedBox(height: 4),
          _ModelMixLegend(),
          const SizedBox(height: 6),
          for (final entry in envelope.modelMix)
            _ModelMixBar(
              key: Key(
                'admin_observability_model_mix_${entry.queryClass}',
              ),
              entry: entry,
            ),
        ],
        const SizedBox(height: 14),
        const _ThinDivider(),
        const SizedBox(height: 14),
        _SubHead(
          title: 'Lower-cost batch work',
          note: 'Higher is cheaper.',
        ),
        if (!hasBatch)
          const _EmptyState(
            keyName: 'admin_observability_batch_mode_share_empty',
            label: 'No batch work in this window.',
          )
        else
          for (final entry in envelope.batchModeShare)
            _ReuseBar(
              key: Key(
                'admin_observability_batch_mode_share_${entry.queryClass}',
              ),
              label: adminRequestUseCaseLabel(entry.queryClass),
              fraction: entry.batchShare,
              color: entry.batchShare >= entry.targetShare
                  ? AppColors.positive
                  : AppColors.warning,
              valueLabel: '${(entry.batchShare * 100).toStringAsFixed(0)}%',
              trailingNote:
                  'target ${(entry.targetShare * 100).toStringAsFixed(0)}%',
            ),
      ],
    );
  }
}

class _ModelMixLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _LegendSwatch(color: AppColors.positive, label: 'Fast model (cheaper)'),
        const SizedBox(width: 18),
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
        Text(label, style: AppTextStyles.body12(color: AppColors.textSecondary)),
      ],
    );
  }
}

/// Split bar showing the cheaper-vs-pricier model split for one use
/// case, with an "over target" tag when the detailed-model share
/// exceeds its ceiling.
class _ModelMixBar extends StatelessWidget {
  const _ModelMixBar({super.key, required this.entry});

  final ModelMixEntry entry;

  @override
  Widget build(BuildContext context) {
    final cheap = entry.haikuShare.clamp(0.0, 1.0).toDouble();
    final pricey = entry.sonnetShare.clamp(0.0, 1.0).toDouble();
    final total = cheap + pricey;
    final cheapFlex = (cheap / (total <= 0 ? 1 : total) * 1000).round();
    final priceyFlex = (pricey / (total <= 0 ? 1 : total) * 1000).round();
    final over = entry.sonnetShareExceedsCeiling;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 168,
            child: Text(
              adminRequestUseCaseLabel(entry.queryClass),
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
                      flex: math.max(cheapFlex, 0),
                      child: Container(color: AppColors.positive),
                    ),
                    Expanded(
                      flex: math.max(priceyFlex, 0),
                      child: Container(color: AppColors.warning),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 132,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                Text(
                  '${(pricey * 100).toStringAsFixed(0)}% detailed',
                  style: AppTextStyles.mono10(color: AppColors.textSecondary),
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
                      color: AppColors.warning.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      'over target',
                      style: AppTextStyles.mono8(color: AppColors.warning),
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

// ── Customers tab ────────────────────────────────────────────────────

class _CustomersTab extends StatelessWidget {
  const _CustomersTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_top_spenders',
            title: 'Top spenders',
            subtitle: 'Highest-cost businesses, staff, and workflows.',
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

/// Top spenders as horizontal bars over the 7-day window (the
/// mockup's default). Bars scale to the largest spender.
class _TopSpenders extends StatelessWidget {
  const _TopSpenders({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final rows =
        envelope
            .topExpensiveForWindow(ObservabilityWindow.sevenDays)
            .toList(growable: false)
          ..sort((a, b) => b.totalUsd.compareTo(a.totalUsd));
    if (rows.isEmpty) {
      return const _EmptyState(
        keyName: 'admin_observability_top_spenders_empty',
        label: 'No spend recorded in this window yet.',
      );
    }
    final maxUsd = rows.first.totalUsd;
    final handoff = AdminRouteHandoff.maybeOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final row in rows)
          _SpenderRow(
            key: Key(
              'admin_observability_top_spender_${row.axis}_'
              '${row.operatorId ?? row.label}',
            ),
            row: row,
            fraction: maxUsd <= 0 ? 0 : row.totalUsd / maxUsd,
            onView: _viewHandler(handoff, row),
          ),
      ],
    );
  }

  VoidCallback? _viewHandler(
    AdminRouteHandoff? handoff,
    TopExpensiveEntry row,
  ) {
    final operatorId = row.operatorId;
    if (handoff == null || operatorId == null || operatorId.isEmpty) {
      return null;
    }
    return () => handoff.onSelectRoute(
      AdminRouteIntent(
        routeId: kAdminOperatorsRouteId,
        hierarchyScope: AdminHierarchyScopeIntent.business(
          operatorId: operatorId,
          operatorName: row.label,
        ),
      ),
    );
  }
}

class _SpenderRow extends StatelessWidget {
  const _SpenderRow({
    super.key,
    required this.row,
    required this.fraction,
    required this.onView,
  });

  final TopExpensiveEntry row;
  final double fraction;
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 184,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  row.label,
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
          const SizedBox(width: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 14,
                color: AppColors.shimmer,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction.clamp(0.02, 1.0).toDouble(),
                  child: Container(color: AppColors.sunset),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: Text(
              _formatUsd(row.totalUsd),
              textAlign: TextAlign.right,
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: onView == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerRight,
                    child: _ViewAccountLink(
                      keyName:
                          'admin_observability_top_spender_view_'
                          '${row.operatorId}',
                      onPressed: onView!,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// "Needs attention" list: losing-money rows (honest empty state when
/// pricing is not tracked), limit hits, and inactive businesses.
class _NeedsAttention extends StatelessWidget {
  const _NeedsAttention({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final handoff = AdminRouteHandoff.maybeOf(context);
    final underwater = _realUnderwater(envelope).toList(growable: false);
    final capEvents = envelope.capEvents;
    final dormant = envelope.dormancy
        .where((d) => d.isDormant)
        .toList(growable: false);

    final pricingTracked = _pricingTracked(envelope);

    final items = <Widget>[];

    // Losing money — honest empty state when no real producer data.
    if (!pricingTracked) {
      items.add(
        const _LosingMoneyNotAvailable(
          key: Key('admin_observability_losing_money_unavailable'),
        ),
      );
    } else if (underwater.isEmpty) {
      items.add(
        const _AttentionRow(
          tone: _HeroPillTone.ok,
          pillLabel: 'Profit',
          lead: 'Every business is covered',
          why: 'No business is spending more on AI than its plan brings in.',
        ),
      );
    } else {
      for (final m in underwater) {
        items.add(
          _AttentionRow(
            key: Key(
              'admin_observability_attention_underwater_${m.operatorId}',
            ),
            tone: _HeroPillTone.bad,
            pillLabel: 'Losing money',
            lead: m.businessName,
            why:
                'Costs ${_formatUsd(m.costUsd - m.revenueUsd)} more than the plan brings in.',
            onView: _viewHandler(handoff, m.operatorId, m.businessName),
          ),
        );
      }
    }

    // Limit hits (deduped by operator).
    final seenCapOperators = <String>{};
    for (final event in capEvents) {
      if (!seenCapOperators.add(event.operatorId)) continue;
      items.add(
        _AttentionRow(
          key: Key(
            'admin_observability_attention_limit_${event.operatorId}',
          ),
          tone: _HeroPillTone.watch,
          pillLabel: 'Limit hit',
          lead: event.businessName,
          why:
              'Hit a usage limit during ${adminRequestUseCaseLabel(event.queryClass)}.',
          onView: _viewHandler(handoff, event.operatorId, event.businessName),
        ),
      );
    }

    // Inactive.
    for (final d in dormant) {
      final silent = d.daysSilent;
      items.add(
        _AttentionRow(
          key: Key(
            'admin_observability_attention_inactive_${d.operatorId}',
          ),
          tone: _HeroPillTone.watch,
          pillLabel: 'Inactive',
          lead: d.businessName,
          why: d.neverActive
              ? 'No AI activity yet.'
              : silent == null
              ? 'Quiet for a while.'
              : 'No AI activity for $silent days.',
          onView: _viewHandler(handoff, d.operatorId, d.businessName),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: item,
          ),
      ],
    );
  }

  VoidCallback? _viewHandler(
    AdminRouteHandoff? handoff,
    String operatorId,
    String businessName,
  ) {
    if (handoff == null || operatorId.isEmpty) return null;
    return () => handoff.onSelectRoute(
      AdminRouteIntent(
        routeId: kAdminOperatorsRouteId,
        hierarchyScope: AdminHierarchyScopeIntent.business(
          operatorId: operatorId,
          operatorName: businessName,
        ),
      ),
    );
  }
}

/// Honest "Not available yet" state for the losing-money surface.
/// Metric Honesty Doctrine: pricing margins have no real producer yet
/// (Plans & limits owns pricing), so we show this instead of a
/// fabricated $0 / 0% underwater count.
class _LosingMoneyNotAvailable extends StatelessWidget {
  const _LosingMoneyNotAvailable({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.neutral.withValues(alpha: 0.12),
              border: Border.all(color: AppColors.neutral, width: 1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Losing money',
              style: AppTextStyles.chipLabel(color: AppColors.neutral),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Not available yet',
                  style: AppTextStyles.body13(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Per-business profit needs the plan pricing from Plans and limits. We show this once that is connected.',
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    super.key,
    required this.tone,
    required this.pillLabel,
    required this.lead,
    required this.why,
    this.onView,
  });

  final _HeroPillTone tone;
  final String pillLabel;
  final String lead;
  final String why;
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (tone) {
      case _HeroPillTone.ok:
        color = AppColors.positive;
        break;
      case _HeroPillTone.watch:
        color = AppColors.warning;
        break;
      case _HeroPillTone.bad:
        color = AppColors.negative;
        break;
      case _HeroPillTone.neutral:
        color = AppColors.neutral;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color, width: 1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                pillLabel,
                style: AppTextStyles.chipLabel(color: color),
              ),
            ),
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
          if (onView != null) ...<Widget>[
            const SizedBox(width: 12),
            _ViewAccountLink(
              keyName: 'admin_observability_attention_view',
              onPressed: onView!,
            ),
          ],
        ],
      ),
    );
  }
}

class _ViewAccountLink extends StatelessWidget {
  const _ViewAccountLink({required this.keyName, required this.onPressed});

  final String keyName;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: Key(keyName),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: AppColors.sunsetDark,
      ),
      child: Text(
        'View account',
        style: AppTextStyles.body12(
          color: AppColors.sunsetDark,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ── Reliability tab ──────────────────────────────────────────────────

class _ReliabilityTab extends StatelessWidget {
  const _ReliabilityTab({
    super.key,
    required this.envelope,
    required this.tripwires,
    required this.tripwireError,
    required this.showTripwires,
  });

  final ObservabilityEnvelope envelope;
  final RealtimeTripwireSnapshot? tripwires;
  final String? tripwireError;
  final bool showTripwires;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_speed',
            title: 'Speed & uptime',
            subtitle: 'How fast the AI services respond.',
            child: _SpeedAndUptime(envelope: envelope),
          ),
          _Panel(
            keyName: 'admin_observability_section_background_jobs',
            title: 'Background jobs',
            subtitle:
                'Shift and open-period projection work waiting, running, or stuck.',
            child: _BackgroundJobs(envelope: envelope),
          ),
          _Panel(
            keyName: 'admin_observability_section_hosting',
            title: 'Hosting capacity',
            subtitle: 'Servers running each AI service.',
            child: _Hosting(envelope: envelope),
          ),
          if (showTripwires)
            _Panel(
              keyName: 'admin_observability_section_live_sync',
              title: 'Live sync',
              subtitle:
                  'Whether updates flow from the database to the apps without delay.',
              child: _LiveSync(snapshot: tripwires, error: tripwireError),
            ),
        ],
      ),
    );
  }
}

/// Speed & uptime block. route_latency is empty today, so the honest
/// default is a hint that points to System health for live latency
/// rather than fabricating numbers; when route data lands it renders
/// the median / 95th / 99th stats.
class _SpeedAndUptime extends StatelessWidget {
  const _SpeedAndUptime({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final rows = envelope.routeLatency;
    if (rows.isEmpty) {
      return Container(
        key: const Key('admin_observability_speed_health_hint'),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.cardGlow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.speed_outlined,
              size: 18,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Live response times are on the System health screen. This view does not track per-request speed yet.',
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    final median =
        (rows.map((r) => r.p50Ms).reduce((a, b) => a + b) / rows.length)
            .round();
    final p95 = rows.map((r) => r.p95Ms).reduce(math.max);
    final p99 = rows.map((r) => r.p99Ms).reduce(math.max);
    final worstError = rows
        .map((r) => r.errorRate)
        .reduce((a, b) => a > b ? a : b);
    return _StatGrid(
      stats: <_Stat>[
        _Stat(value: '${median}ms', label: 'Typical reply', sub: 'Half faster'),
        _Stat(value: '${p95}ms', label: 'Most replies under', sub: 'p95'),
        _Stat(value: '${p99}ms', label: 'Nearly all under', sub: 'p99'),
        _Stat(
          value: '${(worstError * 100).toStringAsFixed(2)}%',
          label: 'Errors',
          sub: 'Server errors',
          alert: worstError > 0.01,
        ),
      ],
    );
  }
}

/// Background jobs: projection retry status counts as stat blocks, plus
/// a hint when anything is dead-lettered.
class _BackgroundJobs extends StatelessWidget {
  const _BackgroundJobs({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final counts = envelope.projectionRetries.statusCounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _StatGrid(
          stats: <_Stat>[
            _Stat(
              keyName: 'admin_observability_jobs_pending',
              value: '${counts.pending}',
              label: 'Waiting',
            ),
            _Stat(
              keyName: 'admin_observability_jobs_running',
              value: '${counts.running}',
              label: 'In progress',
            ),
            _Stat(
              keyName: 'admin_observability_jobs_dead_lettered',
              value: '${counts.deadLettered}',
              label: 'Stuck',
              sub: counts.deadLettered > 0 ? 'Needs a person' : null,
              alert: counts.deadLettered > 0,
            ),
            _Stat(
              keyName: 'admin_observability_jobs_succeeded',
              value: '${counts.succeeded}',
              label: 'Completed',
            ),
          ],
        ),
        if (counts.deadLettered > 0) ...<Widget>[
          const SizedBox(height: 12),
          Container(
            key: const Key('admin_observability_jobs_stuck_hint'),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.negative.withValues(alpha: 0.08),
              border: Border.all(
                color: AppColors.negative.withValues(alpha: 0.3),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.error_outline,
                  size: 17,
                  color: AppColors.negative,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${counts.deadLettered} stuck. Open Support logs to triage the failed jobs.',
                    style: AppTextStyles.body12(color: AppColors.negative),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Hosting capacity: one row per Cloud Run service with its active
/// instance count and autoscaling range. Honesty: a service whose
/// instance count is unknown shows the `—` sentinel, never 0.
class _Hosting extends StatelessWidget {
  const _Hosting({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final services = envelope.cloudRun;
    if (services.isEmpty) {
      return const _EmptyState(
        keyName: 'admin_observability_hosting_empty',
        label: 'No hosting services reported in this window.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final svc in services)
          Padding(
            key: Key('admin_observability_hosting_${svc.serviceName}'),
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.dns_outlined,
                  size: 20,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _hostingServiceLabel(svc.serviceName),
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Scales ${svc.minInstances} to ${svc.maxInstances} servers automatically.',
                        style: AppTextStyles.body12(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text.rich(
                  TextSpan(
                    text: svc.instanceCount < 0
                        ? '—'
                        : '${svc.instanceCount}',
                    style: AppTextStyles.mono20(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    ),
                    children: <InlineSpan>[
                      TextSpan(
                        text: '  running',
                        style: AppTextStyles.body12(color: AppColors.textMuted),
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

/// Live sync block (bridge tripwires). Worst-wins status pill + one row
/// per Q22 metric, or an honest inline error / loading state.
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
        style: AppTextStyles.body12(color: AppColors.negative),
      );
    }
    if (snapshot == null) {
      return Text(
        'Loading...',
        style: AppTextStyles.body12(color: AppColors.textMuted),
      );
    }
    final palette = _tripwirePalette(snapshot!.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                palette.headline,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
            Container(
              key: Key(
                'admin_observability_live_sync_status_'
                '${outboxTripwireStatusKey(snapshot!.status)}',
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: palette.color.withValues(alpha: 0.12),
                border: Border.all(color: palette.color, width: 1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                palette.label,
                style: AppTextStyles.chipLabel(color: palette.color),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final row in snapshot!.metrics)
          Padding(
            key: Key('admin_observability_live_sync_row_${row.key}'),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    row.label,
                    style: AppTextStyles.body13(color: AppColors.textPrimary),
                  ),
                ),
                Text(
                  row.value == null
                      ? '—'
                      : _formatTripwireValue(row.metric, row.value!),
                  style: AppTextStyles.mono12(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            keyName: 'admin_observability_section_graph_counts',
            title: 'What the advisor knows',
            subtitle:
                'Approved facts and links, plus anything waiting on review.',
            child: _StatGrid(
              stats: <_Stat>[
                _Stat(
                  keyName: 'admin_observability_graph_approved_nodes',
                  value: '${graph.approvedNodeCount}',
                  label: 'Approved facts',
                  valueColor: AppColors.positive,
                ),
                _Stat(
                  keyName: 'admin_observability_graph_approved_edges',
                  value: '${graph.approvedEdgeCount}',
                  label: 'Approved links',
                  valueColor: AppColors.positive,
                ),
                _Stat(
                  keyName: 'admin_observability_graph_inferred_approved',
                  value: '${graph.inferredApprovedCount}',
                  label: 'System-suggested',
                  sub: 'Approved after review',
                ),
                _Stat(
                  keyName: 'admin_observability_graph_isolated_nodes',
                  value: '${graph.isolatedNodeCount}',
                  label: 'Not linked yet',
                  valueColor: graph.isolatedNodeCount > 0
                      ? AppColors.warning
                      : AppColors.positive,
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
              columns: 2,
              stats: <_Stat>[
                _Stat(
                  keyName: 'admin_observability_graph_projection_age',
                  value: '${graph.projectionAgeSeconds}s',
                  label: 'Since last rebuild',
                  sub: 'Lower is fresher',
                  alert: graph.projectionAgeSeconds > 3600,
                ),
                _Stat(
                  keyName: 'admin_observability_graph_traversal_p95',
                  value: '${graph.traversalP95Ms}ms',
                  label: 'Lookup speed',
                  sub: 'Most lookups this fast',
                  alert: graph.traversalP95Ms > 250,
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
/// the admin parity kit. The [keyName] moves onto the panel so widget
/// tests resolve it; the outer [Padding] keeps inter-card rhythm.
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
  const _SubHead({required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Flexible(
            child: Text(
              title,
              style: AppTextStyles.body13(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            note,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ThinDivider extends StatelessWidget {
  const _ThinDivider();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: AppColors.borderSubtle);
  }
}

class _Stat {
  const _Stat({
    required this.value,
    required this.label,
    this.sub,
    this.alert = false,
    this.valueColor,
    this.keyName,
  });

  final String value;
  final String label;
  final String? sub;
  final bool alert;
  final Color? valueColor;
  final String? keyName;
}

/// Responsive grid of centered stat blocks (mockup ".stats").
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats, this.columns});

  final List<_Stat> stats;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols =
            columns ??
            (constraints.maxWidth >= 560
                ? 4
                : constraints.maxWidth >= 320
                ? 2
                : 1);
        const gap = 13.0;
        final width = (constraints.maxWidth - (gap * (cols - 1))) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final stat in stats)
              SizedBox(
                width: math.max(width, 0),
                child: _StatBlock(stat: stat),
              ),
          ],
        );
      },
    );
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    final valueColor =
        stat.valueColor ?? (stat.alert ? AppColors.negative : AppColors.textPrimary);
    return Container(
      key: stat.keyName == null ? null : Key(stat.keyName!),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            stat.value,
            style: AppTextStyles.mono20(color: valueColor, weight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            stat.label,
            textAlign: TextAlign.center,
            style: AppTextStyles.body13(
              color: AppColors.textSecondary,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
          if (stat.sub != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              stat.sub!,
              textAlign: TextAlign.center,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────

String _formatUsd(double value) {
  if (value >= 1000) {
    return '\$${value.toStringAsFixed(0)}';
  }
  return '\$${value.toStringAsFixed(2)}';
}

List<CacheHitRateEntry> _sortedHitRates(List<CacheHitRateEntry> rows) {
  final sorted = [...rows]..sort((a, b) => b.hitRate.compareTo(a.hitRate));
  return sorted;
}

Color _hitRateColor(HitRateSeverity severity) {
  switch (severity) {
    case HitRateSeverity.green:
      return AppColors.positive;
    case HitRateSeverity.yellow:
      return AppColors.warning;
    case HitRateSeverity.red:
      return AppColors.negative;
  }
}

String _spenderAxisLabel(String axis) {
  switch (axis.toLowerCase()) {
    case 'operator':
      return 'Business';
    case 'staff':
      return 'Staff member';
    case 'workflow':
      return 'Workflow';
    default:
      return axis;
  }
}

String _hostingServiceLabel(String serviceName) {
  final lower = serviceName.toLowerCase();
  if (lower.contains('advisor')) return 'Advisor service';
  if (lower.contains('admin')) return 'Admin service';
  return 'Hosting service';
}

/// Whether the margin surface carries a real pricing producer.
///
/// Plans & limits owns pricing and has not landed a producer for these
/// margins yet; the placeholder rows arrive with revenue == 0. When
/// EVERY margin row reports zero revenue we treat pricing as untracked
/// and render the honest "Not available yet" state instead of a
/// fabricated underwater count (Metric Honesty Doctrine).
bool _pricingTracked(ObservabilityEnvelope envelope) {
  if (envelope.margins.isEmpty) return false;
  return envelope.margins.any((m) => m.revenueUsd > 0);
}

/// Underwater operators, but only counted when pricing is actually
/// tracked (see [_pricingTracked]). A zero-revenue placeholder row is
/// NOT "losing money".
Iterable<MarginEstimateEntry> _realUnderwater(ObservabilityEnvelope envelope) {
  if (!_pricingTracked(envelope)) return const <MarginEstimateEntry>[];
  return envelope.margins.where((m) => m.revenueUsd > 0 && m.isUnderwater);
}

int? _realUnderwaterCount(ObservabilityEnvelope envelope) {
  if (!_pricingTracked(envelope)) return null;
  return _realUnderwater(envelope).length;
}

String _formatTripwireValue(OutboxTripwireMetric metric, num value) {
  switch (metric) {
    case OutboxTripwireMetric.bridgeLagSeconds:
      return '${value.toStringAsFixed(0)}s';
    case OutboxTripwireMetric.undeliveredCount:
      return value.toInt().toString();
    case OutboxTripwireMetric.publishErrorRate:
    case OutboxTripwireMetric.notifyQueueUsage:
      return '${(value * 100).toStringAsFixed(2)}%';
  }
}

class _TripwireUiPalette {
  const _TripwireUiPalette({
    required this.label,
    required this.headline,
    required this.color,
  });
  final String label;
  final String headline;
  final Color color;
}

_TripwireUiPalette _tripwirePalette(OutboxTripwireStatus status) {
  switch (status) {
    case OutboxTripwireStatus.green:
      return const _TripwireUiPalette(
        label: 'Healthy',
        headline: 'Updates are flowing to the apps with no delays.',
        color: AppColors.positive,
      );
    case OutboxTripwireStatus.yellow:
      return const _TripwireUiPalette(
        label: 'Slowing',
        headline: 'Updates are reaching the apps a little slowly.',
        color: AppColors.warning,
      );
    case OutboxTripwireStatus.red:
      return const _TripwireUiPalette(
        label: 'Degraded',
        headline: 'Updates to the apps are delayed. Investigate the bridge.',
        color: AppColors.negative,
      );
  }
}
