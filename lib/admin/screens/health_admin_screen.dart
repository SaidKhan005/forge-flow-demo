// Phase 11A.UX.health (F.1) - Health admin surface (HP #10 cleanup).
//
// Read-only operator-facing view of the proxy `/health` envelope.
// Three tabs reflect the three D.1 metric tiers:
//
//   * Retrieval - graph (AGE) + vector + rollup freshness signals.
//   * Proxy     - circuit breakers + cache hit ratios + tier routing
//                 + cost-discipline levers + idempotency / caps.
//   * Infra     - postgres extensions, pg_cron, pg_partman, audit
//                 anchor, event_outbox, dependency probes, migration
//                 drift.
//
// A single lead-with-the-answer summary sits at the top of the body and
// gives the operator one verdict before anything else:
//   - Red "Action needed" → a tier-1 metric is failing, a dependency
//     probe is red/yellow, or HTTP 503 left the results stale.
//   - Amber "N things need attention" → nothing critical, but some
//     tier-2/3 check is warning or failing.
//   - Green "Everything looks good" → every reported check passed.
// When red or amber the summary also lists every failing/needs-attention
// check (across all tabs); tapping a row jumps to that check's tab. Per
// metric, the tile still carries its own status pill (yellow = needs
// attention, red = failing, grey = no data) inside its tab.
//
// Health checks are manual-only. The staging `/health` envelope can
// take tens of seconds because it checks real backend dependencies
// and producer freshness, so the screen asks for confirmation before
// sending the read-only request. The "Last checked" timestamp is
// rendered prominently so an operator does not mistake an older
// result for live monitoring.
//
// Read-only: this screen has NO mutate affordances. The proxy gate
// for `/health` is unauthenticated; the admin shell role gate
// (`super_admin` or `ff_support`) is what restricts access. Both
// admit decisions render the same view.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_info_button.dart';
import '../../widgets/console/console_screen_body.dart';
import '../../widgets/console/console_screen_header.dart';
import '../../widgets/console/console_surface.dart';

import '../admin_route_handoff.dart';
import '../admin_human_labels.dart';
import '../models/health_admin_models.dart';
import '../services/health_admin_gateway.dart';
import '../widgets/admin_run_check_controls.dart';
import '../widgets/admin_scope_notice_adapter.dart';
import 'health_admin_copy.dart';
import 'package:forge_and_flow/operator_web/widgets/hierarchy_scope_notice.dart';

/// One tile entry in a tab section.
class _TileSpec {
  const _TileSpec(this.metricKey, {this.shortLabel});

  final String metricKey;
  final String? shortLabel;
}

/// One labelled section inside a tab (e.g. "AGE traversal").
class _SectionSpec {
  const _SectionSpec({required this.title, required this.tiles});
  final String title;
  final List<_TileSpec> tiles;
}

/// One tab in the screen.
class _TabSpec {
  const _TabSpec({
    required this.label,
    required this.keySuffix,
    required this.sections,
  });

  final String label;
  final String keySuffix;
  final List<_SectionSpec> sections;
}

/// Tab catalogue. Stable so widget tests can locate sections by
/// metric key without depending on the proxy contract's internal key
/// ordering.
const List<_TabSpec> _kTabs = <_TabSpec>[
  _TabSpec(
    label: 'Advisor data',
    keySuffix: 'retrieval',
    sections: <_SectionSpec>[
      _SectionSpec(
        title: 'Advisor content freshness',
        tiles: <_TileSpec>[
          _TileSpec('rollup_freshness_per_grain'),
          _TileSpec('rollup_refresh_lag_seconds'),
        ],
      ),
      _SectionSpec(
        title: 'Relationship graph',
        tiles: <_TileSpec>[
          _TileSpec(
            'graph_traversal_latency_ms',
            shortLabel: 'Relationship lookup p95',
          ),
          _TileSpec(
            'graph_traversal_p99_latency_ms',
            shortLabel: 'Relationship lookup p99',
          ),
          _TileSpec('graph_traversal_timeout_rate'),
          _TileSpec('graph_node_count'),
          _TileSpec('graph_edge_count'),
          _TileSpec('graph_projection_age_seconds'),
        ],
      ),
      _SectionSpec(
        title: 'Search index',
        tiles: <_TileSpec>[
          _TileSpec('vector_query_latency_ms', shortLabel: 'Search p50'),
          _TileSpec('vector_query_p99_latency_ms', shortLabel: 'Search p99'),
          _TileSpec('vector_query_timeout_rate'),
          _TileSpec('vector_recall'),
          _TileSpec('vector_index_size_per_corpus'),
          _TileSpec('vector_index_build_age_seconds'),
        ],
      ),
    ],
  ),
  _TabSpec(
    label: 'App service',
    keySuffix: 'proxy',
    sections: <_SectionSpec>[
      _SectionSpec(
        title: 'Provider safeguards',
        tiles: <_TileSpec>[
          _TileSpec('circuit_breaker_anthropic_state'),
          _TileSpec('circuit_breaker_voyage_state'),
          _TileSpec('circuit_breaker_open_count_total'),
        ],
      ),
      _SectionSpec(
        title: 'Saved response reuse',
        tiles: <_TileSpec>[
          _TileSpec('prompt_cache_hit_rate'),
          _TileSpec('response_cache_hit_rate'),
          _TileSpec('semantic_cache_hit_rate'),
        ],
      ),
      _SectionSpec(
        title: 'Model and cost controls',
        tiles: <_TileSpec>[
          _TileSpec('cost_per_query_class_haiku'),
          _TileSpec('cost_per_query_class_sonnet'),
          _TileSpec('cost_per_query_class_voyage'),
          _TileSpec('batch_api_pending_count'),
          _TileSpec('fallback_chain_usage_count_anthropic'),
          _TileSpec('fallback_chain_usage_count_voyage'),
        ],
      ),
      _SectionSpec(
        title: 'Retries and usage limits',
        tiles: <_TileSpec>[
          _TileSpec('proxy_idempotency_cache_alive'),
          _TileSpec('usage_caps_breach_count'),
          _TileSpec('proxy_request_p99_latency_ms'),
          _TileSpec('proxy_request_5xx_rate'),
        ],
      ),
    ],
  ),
  _TabSpec(
    label: 'Behind the scenes',
    keySuffix: 'infra',
    sections: <_SectionSpec>[
      _SectionSpec(
        title: 'Database background work',
        tiles: <_TileSpec>[
          _TileSpec('azure_extensions_present'),
          _TileSpec('pg_cron_scheduler_alive'),
          _TileSpec('pg_cron_jobs_failed_24h'),
          _TileSpec('partition_count_active'),
          _TileSpec('partition_maintenance_last_run_age_seconds'),
          _TileSpec('partition_default_row_count'),
          _TileSpec('migration_apply_drift_count'),
        ],
      ),
      _SectionSpec(
        title: 'Audit and notifications',
        tiles: <_TileSpec>[
          _TileSpec('audit_chain_lag_seconds'),
          _TileSpec('audit_chain_anchor_age_seconds'),
          _TileSpec('event_outbox_undelivered_count'),
          _TileSpec('event_outbox_lag_seconds'),
          _TileSpec('event_outbox_publish_error_rate'),
          _TileSpec('notify_queue_usage_ratio'),
        ],
      ),
      _SectionSpec(
        title: 'Sign-in and hosting',
        tiles: <_TileSpec>[
          _TileSpec('firebase_jwks_fetch_alive'),
          _TileSpec('service_principal_jwt_alive'),
          _TileSpec('cloud_run_instance_count'),
        ],
      ),
    ],
  ),
];

class HealthAdminScreen extends StatefulWidget {
  const HealthAdminScreen({
    super.key,
    required this.gateway,
    this.hierarchyScope,
    this.scopeLocationIds = const <String>{},
    @visibleForTesting this.now,
  });

  final HealthAdminGateway gateway;
  final AdminHierarchyScopeIntent? hierarchyScope;
  final Set<String> scopeLocationIds;

  /// Test-only clock injection so the "Last checked" timestamp is
  /// deterministic. Production uses [DateTime.now].
  final DateTime Function()? now;

  @override
  State<HealthAdminScreen> createState() => _HealthAdminScreenState();
}

class _HealthAdminScreenState extends State<HealthAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  bool _loading = false;
  bool _refreshing = false;
  HealthEnvelope? _envelope;
  String? _loadError;
  DateTime? _lastRefreshed;

  /// Global "Show technical details" switch. When on, every metric
  /// card's Details disclosure renders expanded so a support engineer
  /// can read measured values, thresholds, source, and owner at a
  /// glance. Off by default so the operator sees the calm card face.
  bool _showTechDetails = false;

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
      builder: (context) => const _HealthCheckConfirmDialog(),
    );
    if (confirmed != true || !mounted) return;
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      if (_envelope == null) {
        _loading = true;
      }
      _loadError = null;
    });
    try {
      final envelope = await widget.gateway.fetch(
        HealthAdminFetchRequest(
          operatorId: widget.hierarchyScope?.operatorId,
          locationId: widget.hierarchyScope?.locationId,
          locationIds: widget.scopeLocationIds,
        ),
      );
      if (!mounted) return;
      setState(() {
        _envelope = envelope;
        _loading = false;
        _loadError = null;
        _lastRefreshed = _clockNow();
      });
    } on HealthAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
        _lastRefreshed = _clockNow();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load system health: $error';
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
  }

  @override
  Widget build(BuildContext context) {
    // The TabBar widget requires a Material ancestor; keeping the
    // screen root as Material satisfies that without depending on the
    // outer shell (admin shell wires Scaffold; widget tests pump the
    // screen directly). The Material paints the dark background; the
    // body is centred and capped at the shared operator-web content
    // width through OperatorWebScreenFrame, a no-scroll wrapper so the
    // fixed-height tabbed body (Expanded TabBarView) keeps its fill.
    return Material(
      key: const Key('admin_health_screen'),
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
                onRunHealthCheck: _confirmAndRefresh,
                loading: _loading || _refreshing,
              ),
              const SizedBox(height: 12),
              if (widget.hierarchyScope != null)
                HierarchyScopeNotice(
                  keyName: 'admin_health_scope_notice',
                  selectedScope: adminScopeLevel(
                    widget.hierarchyScope!.scopeType,
                  ),
                  scopeName: widget.hierarchyScope!.displayLabel,
                  effectiveValueSummary:
                      'Platform health checks for the selected business context.',
                  backendOnlyHelpTitle: 'What stays platform-wide',
                  backendOnlyExplainer:
                      'Advisor data, app service, and ecosystem checks are shared signals for the selected business context.',
                ),
              if (_loadError != null)
                _ErrorBanner(
                  key: const Key('admin_health_load_error'),
                  message: _loadError!,
                ),
              if (_envelope != null) _envelopeBody(_envelope!),
              if (_loading && _envelope == null)
                const Expanded(
                  child: Center(
                    key: Key('admin_health_loading'),
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
                _ManualHealthPrompt(onRunHealthCheck: _confirmAndRefresh),
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

  Widget _envelopeBody(HealthEnvelope envelope) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HealthSummary(
            key: const Key('admin_health_summary'),
            envelope: envelope,
            onSelectTab: (index) => _tabs.animateTo(index),
          ),
          const SizedBox(height: 12),
          // One control row above the tabs: the "What these labels mean"
          // info button on the left holds both legends (the colour key +
          // the section definitions) in a single popover, and the
          // "Show technical details" switch sits on the right. The
          // colour key and the definitions are no longer always-on
          // blocks: they were reassurance clutter on the calm default.
          _HealthControlsRow(
            showTechDetails: _showTechDetails,
            onTechDetailsChanged: (next) =>
                setState(() => _showTechDetails = next),
          ),
          const SizedBox(height: 12),
          // The dependency "Service checks" strip is reassurance clutter
          // by default; any failing dependency is already surfaced loudly
          // by the red summary above. Show it only in the technical view.
          if (_showTechDetails) ...[
            _DependenciesStrip(envelope: envelope),
            const SizedBox(height: 12),
          ],
          TabBar(
            key: const Key('admin_health_tabs'),
            controller: _tabs,
            isScrollable: true,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.sunset,
            tabs: <Widget>[
              for (var i = 0; i < _kTabs.length; i++)
                Tab(
                  key: Key('admin_health_tab_${_kTabs[i].keySuffix}'),
                  child: _TabLabel(
                    label: _kTabs[i].label,
                    attention: _tabAttention(_kTabs[i], envelope),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                for (final tab in _kTabs)
                  _TabBody(
                    key: Key('admin_health_tab_body_${tab.keySuffix}'),
                    tab: tab,
                    envelope: envelope,
                    showTechDetails: _showTechDetails,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Count + worst-severity of the metrics in [tab] that need attention,
  /// for the tab's count badge. Returns a zero count when nothing in the
  /// tab is failing (the badge is then omitted).
  _TabAttention _tabAttention(_TabSpec tab, HealthEnvelope envelope) {
    var count = 0;
    var hasRed = false;
    for (final key in _metricKeysForTab(tab)) {
      final metric = envelope.metrics[key];
      if (metric == null || !metric.isFailing) continue;
      count += 1;
      if (metric.status == HealthSeverity.red) hasRed = true;
    }
    return _TabAttention(count: count, hasRed: hasRed);
  }
}

/// Unique metric keys in a tab, in section then tile order. A key that
/// appears in more than one tile (none do today, but the model allows
/// it) is counted once.
List<String> _metricKeysForTab(_TabSpec tab) {
  final keys = <String>[];
  for (final section in tab.sections) {
    for (final tile in section.tiles) {
      if (!keys.contains(tile.metricKey)) keys.add(tile.metricKey);
    }
  }
  return keys;
}

/// The tab index (into [_kTabs]) whose tiles contain [metricKey], or -1
/// when the key lives in no tab.
int _tabIndexForMetric(String metricKey) {
  for (var i = 0; i < _kTabs.length; i++) {
    if (_metricKeysForTab(_kTabs[i]).contains(metricKey)) return i;
  }
  return -1;
}

/// Plain-English tab name for a tab index, used in the summary
/// attention list so the operator knows where a failing check lives.
String _tabLabelForIndex(int index) {
  if (index < 0 || index >= _kTabs.length) return '';
  return _kTabs[index].label;
}

/// Count + worst-severity carried to a tab's count badge.
class _TabAttention {
  const _TabAttention({required this.count, required this.hasRed});

  final int count;
  final bool hasRed;

  bool get isEmpty => count == 0;
}

/// Lead-with-the-answer summary. Renders FIRST in the envelope body and
/// subsumes the old dependencies-unavailable banner, tier-1 failure
/// banner, and overall-severity chip in a single calm verdict the
/// operator reads before anything else. Three states, computed straight
/// from the envelope:
///   * Red "Action needed" - a dependency probe is failing, a 503 made
///     the results stale, or a critical (tier-1) check is failing.
///   * Amber "N things need attention" - nothing critical, but some
///     check is warning or failing.
///   * Green "Everything looks good" - every reported check passed.
/// When red or amber it also lists every check that needs attention
/// (across all tabs); tapping a row jumps to that check's tab.
class _HealthSummary extends StatelessWidget {
  const _HealthSummary({
    super.key,
    required this.envelope,
    required this.onSelectTab,
  });

  final HealthEnvelope envelope;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    final failingDeps = envelope.dependencies
        .where(
          (d) =>
              d.status == HealthSeverity.red ||
              d.status == HealthSeverity.yellow,
        )
        .toList(growable: false);
    final failingTier1 = envelope
        .metricsAtTier(1)
        .where((m) => m.isFailing)
        .toList(growable: false);
    final isRed =
        envelope.dependenciesUnavailable ||
        failingTier1.isNotEmpty ||
        failingDeps.isNotEmpty;

    // Every metric in the envelope that needs attention, in tab order so
    // the triage list reads top-to-bottom like the tabs.
    final attention = _attentionMetrics(envelope);
    final amber = !isRed && attention.isNotEmpty;

    final Color color;
    final IconData icon;
    final String headline;
    final String subLine;
    if (isRed) {
      color = AppColors.negative;
      icon = Icons.error_outline;
      if (failingTier1.isNotEmpty) {
        final n = failingTier1.length;
        headline = n == 1
            ? 'Action needed: 1 critical check failing'
            : 'Action needed: $n critical checks failing';
      } else {
        headline = 'Action needed: a required service is unavailable';
      }
      subLine = _redSubLine(failingDeps);
    } else if (amber) {
      color = AppColors.warning;
      icon = Icons.warning_amber_outlined;
      final n = attention.length;
      headline = n == 1
          ? '1 thing needs attention'
          : '$n things need attention';
      subLine = 'Everything else is running normally.';
    } else {
      color = AppColors.positive;
      icon = Icons.check_circle_outline;
      headline = 'Everything looks good';
      final n = envelope.metrics.length;
      subLine = n == 1 ? 'All 1 check passed.' : 'All $n checks passed.';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      headline,
                      key: const Key('admin_health_summary_headline'),
                      style: AppTextStyles.body14(
                        color: color,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subLine,
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if ((isRed || amber) && attention.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            for (final metric in attention)
              _HealthAttentionRow(
                metricKey: metric.key,
                status: metric.status,
                onTap: () {
                  final index = _tabIndexForMetric(metric.key);
                  if (index >= 0) onSelectTab(index);
                },
              ),
          ],
        ],
      ),
    );
  }

  /// All metrics present in the envelope that are failing/needs-attention,
  /// ordered by their tab (then by tile order within the tab) so the list
  /// mirrors the tab strip left-to-right.
  static List<HealthMetric> _attentionMetrics(HealthEnvelope envelope) {
    final ordered = <HealthMetric>[];
    final seen = <String>{};
    for (final tab in _kTabs) {
      for (final key in _metricKeysForTab(tab)) {
        final metric = envelope.metrics[key];
        if (metric == null || !metric.isFailing) continue;
        if (seen.add(key)) ordered.add(metric);
      }
    }
    // Any failing metric not placed in a tab still belongs in triage.
    for (final metric in envelope.metrics.values) {
      if (!metric.isFailing) continue;
      if (seen.add(metric.key)) ordered.add(metric);
    }
    return ordered;
  }

  String _redSubLine(List<HealthDependency> failingDeps) {
    final services = failingDeps.map(_dependencyLabel).toList(growable: false);
    if (envelope.dependenciesUnavailable) {
      if (services.isNotEmpty) {
        return 'Services affected: ${services.join(", ")}. '
            'Results below may be out of date.';
      }
      return 'Results below may be out of date.';
    }
    if (services.isNotEmpty) {
      return 'Services affected: ${services.join(", ")}. '
          'Fix the cause before relying on this environment.';
    }
    return 'Fix the cause before relying on this environment.';
  }
}

/// One row in the summary's "needs attention" triage list: a status dot,
/// the plain-English check name, the tab it lives in, and a chevron. The
/// whole row is tappable and jumps to that check's tab.
class _HealthAttentionRow extends StatelessWidget {
  const _HealthAttentionRow({
    required this.metricKey,
    required this.status,
    required this.onTap,
  });

  final String metricKey;
  final HealthSeverity status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(status);
    final name = healthMetricName(
      metricKey,
      fallback: _healthMetricLabel(metricKey),
    );
    final tabLabel = _tabLabelForIndex(_tabIndexForMetric(metricKey));
    return InkWell(
      key: Key('admin_health_attn_$metricKey'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: name,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                  children: <InlineSpan>[
                    if (tabLabel.isNotEmpty)
                      TextSpan(
                        text: '  ·  $tabLabel',
                        style: AppTextStyles.body13(
                          color: AppColors.textMuted,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// A tab label with an optional count badge. The badge shows the number
/// of checks in the tab that need attention and is omitted when the tab
/// is all-clear. Badge colour is red when the tab has any failing check,
/// otherwise amber.
class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.label, required this.attention});

  final String label;
  final _TabAttention attention;

  @override
  Widget build(BuildContext context) {
    if (attention.isEmpty) {
      return Text(label);
    }
    final color = attention.hasRed ? AppColors.negative : AppColors.warning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            border: Border.all(color: color, width: 1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '${attention.count}',
            style: AppTextStyles.chipLabel(color: color),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.lastRefreshed,
    required this.onRunHealthCheck,
    required this.loading,
  });

  final DateTime? lastRefreshed;
  final Future<void> Function() onRunHealthCheck;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return OperatorWebScreenHeader(
      icon: Icons.health_and_safety_outlined,
      title: 'System health',
      subtitle:
          'Run a read-only check of advisor data, app service, and platform services.',
      collapseBelowWidth: 640,
      actions: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              AdminRunCheckButton(
                key: const Key('admin_health_refresh_button'),
                onPressed: () {
                  onRunHealthCheck();
                },
                icon: Icons.health_and_safety_outlined,
                label: 'Run system check',
                loadingLabel: 'Running...',
                loading: loading,
              ),
              const SizedBox(height: 6),
              Text(
                lastRefreshed == null
                    ? 'Last checked: -'
                    : 'Last checked: ${adminHumanDateTime(lastRefreshed!)}',
                key: const Key('admin_health_last_refreshed'),
                maxLines: 1,
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

class _HealthCheckConfirmDialog extends StatelessWidget {
  const _HealthCheckConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return const AdminRunCheckConfirmDialog(
      dialogKey: Key('admin_health_confirm_dialog'),
      cancelButtonKey: Key('admin_health_confirm_cancel'),
      confirmButtonKey: Key('admin_health_confirm_run'),
      icon: Icons.health_and_safety_outlined,
      title: 'Run system check',
      description:
          'This reads live staging health and dependency status. It is read-only and usually finishes in a few seconds.',
      confirmLabel: 'Run system check',
      facts: [
        AdminRunCheckFact(
          icon: Icons.visibility_outlined,
          label: 'Read-only',
          text: 'No settings or operator data are changed.',
        ),
        AdminRunCheckFact(
          icon: Icons.schedule_outlined,
          label: 'Timing',
          text: 'Some dependency checks take a few moments to answer.',
        ),
        AdminRunCheckFact(
          icon: Icons.warning_amber_outlined,
          label: 'Results',
          text: 'Warnings usually mean backend state needs review.',
        ),
      ],
    );
  }
}

class _ManualHealthPrompt extends StatelessWidget {
  const _ManualHealthPrompt({required this.onRunHealthCheck});

  final Future<void> Function() onRunHealthCheck;

  @override
  Widget build(BuildContext context) {
    return AdminRunCheckPrompt(
      key: const Key('admin_health_manual_prompt'),
      icon: Icons.health_and_safety_outlined,
      title: 'Check system health',
      description:
          'Start with the current staging picture before investigating service or data issues.',
      buttonLabel: 'Run system check',
      onPressed: () {
        onRunHealthCheck();
      },
      facts: const [
        AdminRunCheckFact(
          icon: Icons.visibility_outlined,
          label: 'Read-only',
          text: 'No settings or operator data are changed.',
        ),
        AdminRunCheckFact(
          icon: Icons.account_tree_outlined,
          label: 'Scope',
          text: 'Dependency status, health signals, and producer freshness.',
        ),
        AdminRunCheckFact(
          icon: Icons.schedule_outlined,
          label: 'Timing',
          text: 'Live staging checks can take 15-30 seconds.',
        ),
      ],
    );
  }
}

/// The single control row above the tab strip: a "What these labels
/// mean" info button on the left (its popover holds BOTH the colour key
/// and the section definitions) and the "Show technical details" switch
/// on the right. On a wide pane both controls share one line (button
/// left, switch right via a [Spacer]); on a narrow (mobile-width) admin
/// viewport the switch stacks under the button so nothing overflows.
class _HealthControlsRow extends StatelessWidget {
  const _HealthControlsRow({
    required this.showTechDetails,
    required this.onTechDetailsChanged,
  });

  final bool showTechDetails;
  final ValueChanged<bool> onTechDetailsChanged;

  @override
  Widget build(BuildContext context) {
    final toggle = _TechDetailsToggle(
      value: showTechDetails,
      onChanged: onTechDetailsChanged,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Below ~420px logical the info-button label and the toggle
        // label cannot both fit on one line, so stack them.
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Align(
                alignment: Alignment.centerLeft,
                child: _HealthLegendInfoButton(),
              ),
              const SizedBox(height: 8),
              toggle,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            // Expanded eats the left space and left-aligns the info
            // button; this pushes the bounded toggle to the right edge
            // without a Spacer (the toggle is a non-flex Row child, so it
            // must be width-bounded for its internal Flexible label).
            const Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _HealthLegendInfoButton(),
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: toggle,
            ),
          ],
        );
      },
    );
  }
}

/// The "What these labels mean" info button. Its popover replaces the two
/// always-on legend cards (the colour key and the plain-English section
/// definitions) so the calm default stays uncluttered while the
/// reference stays one tap away at every width.
class _HealthLegendInfoButton extends StatelessWidget {
  const _HealthLegendInfoButton();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            'What these labels mean',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: 4),
        const OperatorWebInfoButton(
          key: Key('admin_health_legend_info'),
          title: 'What these labels mean',
          tooltip: 'What the colours and section names mean',
          width: 340,
          body: _HealthLegendBody(),
        ),
      ],
    );
  }
}

/// The combined legend shown inside the info-button popover. Two keyed
/// sub-sections: the colour priority key (keyed
/// `admin_health_priority_key`) and the plain-English section
/// definitions (keyed `admin_health_plain_english_definitions`). Both
/// reuse the same item widgets the old always-on cards used; only the
/// container chrome changed (no card border inside the popover).
class _HealthLegendBody extends StatelessWidget {
  const _HealthLegendBody();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Column(
          key: const Key('admin_health_priority_key'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            _PriorityKeyItem(
              label: 'Critical',
              description: 'Core service and data-safety checks.',
              color: AppColors.negative,
            ),
            SizedBox(height: 8),
            _PriorityKeyItem(
              label: 'Important',
              description: 'Reliability, freshness, and cost signals.',
              color: AppColors.warning,
            ),
            SizedBox(height: 8),
            _PriorityKeyItem(
              label: 'Info',
              description: 'Helpful context for support follow-up.',
              color: AppColors.neutral,
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, color: AppColors.borderSubtle),
        const SizedBox(height: 12),
        Column(
          key: const Key('admin_health_plain_english_definitions'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            _HealthDefinitionItem(
              label: 'Advisor data',
              description:
                  'Knowledge, vectors, and rollups the advisor uses to answer accurately.',
            ),
            SizedBox(height: 8),
            _HealthDefinitionItem(
              label: 'App service',
              description:
                  'The backend services that serve admin, advisor, and workflow requests.',
            ),
            SizedBox(height: 8),
            _HealthDefinitionItem(
              label: 'Behind the scenes',
              description:
                  'Shared database, search, queues, and scheduled work that keep the app running.',
            ),
            SizedBox(height: 8),
            _HealthDefinitionItem(
              label: 'Service checks',
              description:
                  'Read-only pings that confirm each required service answered successfully.',
            ),
          ],
        ),
      ],
    );
  }
}

class _PriorityKeyItem extends StatelessWidget {
  const _PriorityKeyItem({
    required this.label,
    required this.description,
    required this.color,
  });

  final String label;
  final String description;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color, width: 1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label, style: AppTextStyles.chipLabel(color: color)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              description,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthDefinitionItem extends StatelessWidget {
  const _HealthDefinitionItem({required this.label, required this.description});

  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Text.rich(
        TextSpan(
          text: label,
          style: AppTextStyles.body12(
            color: AppColors.textPrimary,
          ).copyWith(fontWeight: FontWeight.w700),
          children: <InlineSpan>[
            TextSpan(
              text: ' - $description',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _DependenciesStrip extends StatelessWidget {
  const _DependenciesStrip({required this.envelope});

  final HealthEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    if (envelope.dependencies.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const Key('admin_health_dependencies'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            'Service checks',
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
          ),
          for (final dep in envelope.dependencies)
            _DependencyChip(
              key: Key('admin_health_dependency_${dep.name}'),
              dep: dep,
            ),
        ],
      ),
    );
  }
}

class _DependencyChip extends StatelessWidget {
  const _DependencyChip({super.key, required this.dep});

  final HealthDependency dep;

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(dep.status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${_dependencyLabel(dep)}: ${_severityLabel(dep.status)}',
        style: AppTextStyles.chipLabel(color: color),
      ),
    );
  }
}

class _TechDetailsToggle extends StatelessWidget {
  const _TechDetailsToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // Right-aligned, but the label is Flexible so it ellipsizes instead
    // of overflowing on a narrow (mobile-width) admin viewport.
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        Flexible(
          child: Text(
            'Show technical details',
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          key: const Key('admin_health_tech_toggle'),
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.sunsetDark,
        ),
      ],
    );
  }
}

class _TabBody extends StatelessWidget {
  const _TabBody({
    super.key,
    required this.tab,
    required this.envelope,
    required this.showTechDetails,
  });

  final _TabSpec tab;
  final HealthEnvelope envelope;
  final bool showTechDetails;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final section in tab.sections)
            _Section(
              key: Key(
                'admin_health_section_${tab.keySuffix}_'
                '${section.title.toLowerCase().replaceAll(' ', '_')}',
              ),
              section: section,
              envelope: envelope,
              showTechDetails: showTechDetails,
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.section,
    required this.envelope,
    required this.showTechDetails,
  });

  final _SectionSpec section;
  final HealthEnvelope envelope;
  final bool showTechDetails;

  @override
  Widget build(BuildContext context) {
    // Problems first: order this section's tiles by the effective status
    // of their metric (failing, then needs-attention, then good, then
    // no-data / missing last). Section grouping and headings are
    // untouched; only the within-section order changes so an operator
    // sees what is wrong before what is fine. The original index is the
    // tiebreaker so tiles sharing a rank keep their authored order
    // (Dart's List.sort is not guaranteed stable).
    final indexed = <MapEntry<int, _TileSpec>>[
      for (var i = 0; i < section.tiles.length; i++)
        MapEntry(i, section.tiles[i]),
    ]..sort((a, b) {
      final byRank = _tileStatusRank(
        envelope.metrics[a.value.metricKey],
      ).compareTo(_tileStatusRank(envelope.metrics[b.value.metricKey]));
      return byRank != 0 ? byRank : a.key.compareTo(b.key);
    });
    final orderedTiles = <_TileSpec>[for (final entry in indexed) entry.value];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: OperatorWebPanel(
        title: section.title,
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final tile in orderedTiles)
              _MetricCard(
                // Card identity stays keyed by metric key so later
                // slices and tests locate it the same way.
                key: Key('admin_health_tile_${tile.metricKey}'),
                tile: tile,
                metric: envelope.metrics[tile.metricKey],
                showTechDetails: showTechDetails,
              ),
          ],
        ),
      ),
    );
  }
}

/// Problems-first sort rank for a section tile's metric:
/// 0 = failing (red), 1 = needs-attention (yellow), 2 = good (green),
/// 3 = no-data / unknown / missing from the envelope.
int _tileStatusRank(HealthMetric? metric) {
  if (metric == null) return 3;
  switch (metric.status) {
    case HealthSeverity.red:
      return 0;
    case HealthSeverity.yellow:
      return 1;
    case HealthSeverity.green:
      return 2;
    case HealthSeverity.unknown:
      return 3;
  }
}

/// Slim per-metric card. Face shows the plain-English name, one status
/// pill, and a single line: the curated "meaning" when good, or the
/// actionable next step when not. Everything technical (measured value,
/// healthy range, checked time, source, owner) lives in a collapsible
/// Details disclosure that the global "Show technical details" switch
/// can force open.
class _MetricCard extends StatefulWidget {
  const _MetricCard({
    super.key,
    required this.tile,
    required this.metric,
    required this.showTechDetails,
  });

  final _TileSpec tile;
  final HealthMetric? metric;
  final bool showTechDetails;

  @override
  State<_MetricCard> createState() => _MetricCardState();
}

class _MetricCardState extends State<_MetricCard> {
  @override
  Widget build(BuildContext context) {
    final m = widget.metric;
    final severity = m?.status ?? HealthSeverity.unknown;
    final tier = m?.tier ?? 3;
    final metricKey = widget.tile.metricKey;
    final name = healthMetricName(
      metricKey,
      fallback: _healthMetricLabel(metricKey),
    );
    final pillLabel = _statusPillLabel(m, severity);
    final pillColor = _statusPillColor(m, severity);
    // Good metrics show the calm "what this means" line; everything
    // else (warning / failing / no-data / missing) shows the existing
    // actionable next step so the operator always sees what to do.
    final faceLine = (m != null && severity == HealthSeverity.green)
        ? healthMetricMeaning(metricKey, fallback: m.description)
        : _metricRemediation(m, tier, severity);
    final faceColor = (m != null && severity == HealthSeverity.green)
        ? AppColors.textSecondary
        : _remediationColor(severity);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 360),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    name,
                    style: AppTextStyles.uiLabel(color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _StatusPill(
                  keyName: 'admin_health_tile_${metricKey}_status',
                  label: pillLabel,
                  color: pillColor,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              faceLine,
              key: Key('admin_health_tile_${metricKey}_line'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body12(color: faceColor),
            ),
            const SizedBox(height: 4),
            _MetricDetails(
              metricKey: metricKey,
              metric: m,
              forceExpanded: widget.showTechDetails,
            ),
          ],
        ),
      ),
    );
  }
}

/// Small rounded status chip with a leading dot. Honesty-critical: the
/// label and colour come straight from [_statusPillLabel] /
/// [_statusPillColor], which never present unknown or missing signals
/// as good.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.keyName,
    required this.label,
    required this.color,
  });

  final String keyName;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            key: Key(keyName),
            style: AppTextStyles.chipLabel(color: color),
          ),
        ],
      ),
    );
  }
}

/// Per-card "Details" disclosure. Collapsed by default; the global
/// "Show technical details" switch forces every card open via
/// [forceExpanded]. This is the one place monospace values are allowed.
class _MetricDetails extends StatelessWidget {
  const _MetricDetails({
    required this.metricKey,
    required this.metric,
    required this.forceExpanded,
  });

  final String metricKey;
  final HealthMetric? metric;
  final bool forceExpanded;

  @override
  Widget build(BuildContext context) {
    final m = metric;
    final measured = _metricMeasuredValue(m);
    final healthyRange = _healthyRangeCaption(m);
    final observed = m?.observedAt;
    final source = _metricSourceLabel(m);
    final owner = _metricOwnerLabel(m);

    final rows = <Widget>[
      _DetailRow(
        keyName: 'admin_health_tile_${metricKey}_measured',
        label: 'Measured',
        value: measured,
      ),
      if (healthyRange != null)
        _DetailRow(
          keyName: 'admin_health_tile_${metricKey}_range',
          label: 'Healthy range',
          value: healthyRange,
        ),
      _DetailRow(
        keyName: 'admin_health_tile_${metricKey}_checked',
        label: 'Checked',
        value: observed == null
            ? 'No data'
            : adminHumanDateTime(observed),
      ),
      _DetailRow(
        keyName: 'admin_health_tile_${metricKey}_source',
        label: 'Source',
        value: source,
      ),
      _DetailRow(
        keyName: 'admin_health_tile_${metricKey}_owner',
        label: 'Owner',
        value: owner,
      ),
    ];

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      // The ValueKey embeds `forceExpanded` so flipping the global
      // switch rebuilds the tile with a fresh key, resetting its own
      // expand state to `initiallyExpanded`. The switch therefore always
      // wins; a card the user opened by hand re-syncs on the next flip,
      // which keeps the behaviour simple and predictable.
      child: ExpansionTile(
        key: ValueKey('admin_health_tile_${metricKey}_details_$forceExpanded'),
        initiallyExpanded: forceExpanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        visualDensity: VisualDensity.compact,
        dense: true,
        title: Text(
          'Details',
          style: AppTextStyles.body12(
            color: AppColors.sunsetDark,
          ).copyWith(fontWeight: FontWeight.w700),
        ),
        children: rows,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.keyName,
    required this.label,
    required this.value,
  });

  final String keyName;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              key: Key(keyName),
              style: AppTextStyles.mono12(color: AppColors.textSecondary),
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

Color _severityColor(HealthSeverity severity) {
  switch (severity) {
    case HealthSeverity.green:
      return AppColors.positive;
    case HealthSeverity.yellow:
      return AppColors.warning;
    case HealthSeverity.red:
      return AppColors.negative;
    case HealthSeverity.unknown:
      return AppColors.neutral;
  }
}

String _severityLabel(HealthSeverity severity) {
  switch (severity) {
    case HealthSeverity.green:
      return 'Good';
    case HealthSeverity.yellow:
      return 'Needs attention';
    case HealthSeverity.red:
      return 'Failing';
    case HealthSeverity.unknown:
      return 'No data';
  }
}

/// Status pill label. Honesty-critical: a missing metric (`null`) or an
/// `unknown` status is "No data", never "Good".
String _statusPillLabel(HealthMetric? metric, HealthSeverity severity) {
  if (metric == null) return 'No data';
  switch (severity) {
    case HealthSeverity.green:
      return 'Good';
    case HealthSeverity.yellow:
      return 'Needs attention';
    case HealthSeverity.red:
      return 'Failing';
    case HealthSeverity.unknown:
      return 'No data';
  }
}

/// Status pill colour. Mirrors [_statusPillLabel]: a missing metric or
/// `unknown` status is neutral, never positive (green).
Color _statusPillColor(HealthMetric? metric, HealthSeverity severity) {
  if (metric == null) return AppColors.neutral;
  return _severityColor(severity);
}

/// Measured value for the Details block: value + unit in plain words.
/// Booleans render as "yes"/"no"; a metric with no value shows the `—`
/// empty-state sentinel (allowed by the UX no-em-dash law), never "0".
String _metricMeasuredValue(HealthMetric? metric) {
  if (metric == null) return '—';
  final raw = metric.value;
  if (raw == null) return '—';
  final String shown;
  if (raw is bool) {
    shown = raw ? 'yes' : 'no';
  } else {
    final display = metric.displayValue;
    if (display.trim().isEmpty || display == '-') return '—';
    shown = display;
  }
  final unit = metric.unit.trim();
  // Boolean and bare-state metrics read better without a trailing unit
  // noun ("yes", not "yes boolean"; "closed", not "closed state").
  if (raw is bool || unit.isEmpty || unit == 'boolean' || unit == 'state') {
    return shown;
  }
  return '$shown $unit';
}

/// One-line plain-English healthy range derived from `thresholds`.
/// Returns null when the metric carries no thresholds (the Details row
/// is then omitted). Direction is inferred from the unit: latency, lag,
/// counts, and rates are higher-is-worse; recall and cache-hit ratios
/// are lower-is-worse.
String? _healthyRangeCaption(HealthMetric? metric) {
  if (metric == null) return null;
  final thresholds = metric.thresholds;
  if (thresholds.isEmpty) return null;
  final yellow = thresholds['yellow'];
  final red = thresholds['red'];

  if (_lowerIsWorse(metric.key)) {
    final parts = <String>[];
    if (yellow != null) parts.add('Warns under $yellow');
    if (red != null) parts.add('fails under $red');
    if (parts.isEmpty) return null;
    return _capitaliseFirst(parts.join(', '));
  }

  // Higher-is-worse (the common case): warn/fail "over" the threshold.
  final parts = <String>[];
  if (yellow != null) parts.add('Warns over $yellow');
  if (red != null) {
    // A red-only count threshold (e.g. drift {red: 1}) reads as a hard
    // floor: "Fails at 1 or more".
    parts.add(yellow == null ? 'Fails at $red or more' : 'fails over $red');
  }
  if (parts.isEmpty) return null;
  return _capitaliseFirst(parts.join(', '));
}

/// Metrics where a lower reading is the unhealthy direction (recall and
/// cache-hit ratios). Everything else (latency, lag, counts, error
/// rates) is higher-is-worse.
bool _lowerIsWorse(String key) {
  return key == 'vector_recall' ||
      key == 'prompt_cache_hit_rate' ||
      key == 'response_cache_hit_rate' ||
      key == 'semantic_cache_hit_rate';
}

String _capitaliseFirst(String text) {
  if (text.isEmpty) return text;
  return text[0].toUpperCase() + text.substring(1);
}

String _metricSourceLabel(HealthMetric? metric) {
  final source = metric?.source?.trim();
  if (source == null || source.isEmpty) {
    return metric == null
        ? '/health did not return this signal'
        : 'Not reported';
  }
  return source;
}

String _metricOwnerLabel(HealthMetric? metric) {
  final owner = metric?.owner.trim();
  if (owner == null || owner.isEmpty) {
    return metric == null ? 'Not reported' : 'Unassigned in health envelope';
  }
  return owner;
}

String _metricRemediation(
  HealthMetric? metric,
  int tier,
  HealthSeverity severity,
) {
  if (metric == null) {
    return 'Next step: This signal was missing from the health response. Check the proxy health producer registry before relying on it.';
  }

  final warning = metric.metadata['warning'];
  if (warning is String && warning.isNotEmpty) {
    return 'Next step: ${_producerWarningRemediation(warning)}';
  }

  switch (severity) {
    case HealthSeverity.green:
      return 'Next step: No action needed for this producer.';
    case HealthSeverity.yellow:
      return 'Next step: Investigate this ${_tierLabel(tier).toLowerCase()} signal and rerun the check after the source recovers.';
    case HealthSeverity.red:
      return tier == 1
          ? 'Next step: Treat this as blocking. Fix the source, then rerun the system check.'
          : 'Next step: Fix this producer source before relying on the affected workflow.';
    case HealthSeverity.unknown:
      return 'Next step: No current producer value is available. Confirm the producer is wired, then rerun the system check.';
  }
}

String _producerWarningRemediation(String warning) {
  return switch (warning) {
    'producer_timeout' =>
      'The health producer timed out. Retry once; if it repeats, check the producer budget and proxy logs.',
    'producer_error' =>
      'The health producer failed while collecting this signal. Check proxy logs for the producer.',
    'registry_route_budget_exceeded' =>
      'The health sweep ran out of time before this producer finished. Retry once, then check slow health producers.',
    'registry_outer_failure' =>
      'The registry wrapper failed while collecting this signal. Check proxy health logs before relying on it.',
    _ =>
      'The health producer reported "$warning". Check proxy health logs before relying on this signal.',
  };
}

Color _remediationColor(HealthSeverity severity) {
  switch (severity) {
    case HealthSeverity.green:
      return AppColors.textSecondary;
    case HealthSeverity.yellow:
      return AppColors.warning;
    case HealthSeverity.red:
      return AppColors.negative;
    case HealthSeverity.unknown:
      return AppColors.neutral;
  }
}

String _tierLabel(int tier) {
  return switch (tier) {
    1 => 'Critical',
    2 => 'Important',
    _ => 'Info',
  };
}

String _dependencyLabel(HealthDependency dep) {
  return switch (dep.name.trim().toLowerCase()) {
    'postgres' => 'Database',
    'age' => 'Relationship graph',
    'pgvector' => 'Search index',
    'firebase' => 'Sign-in',
    'cloud_run' => 'Hosting',
    _ => dep.name,
  };
}

String _healthMetricLabel(String key) {
  return switch (key) {
    'rollup_freshness_per_grain' => 'Data freshness',
    'rollup_refresh_lag_seconds' => 'Refresh delay',
    'graph_traversal_latency_ms' => 'Relationship lookup p95',
    'graph_traversal_p99_latency_ms' => 'Relationship lookup p99',
    'graph_traversal_timeout_rate' => 'Relationship lookup timeouts',
    'graph_node_count' => 'Approved items',
    'graph_edge_count' => 'Approved relationships',
    'graph_projection_age_seconds' => 'Relationship search age',
    'vector_query_latency_ms' => 'Search p50',
    'vector_query_p99_latency_ms' => 'Search p99',
    'vector_query_timeout_rate' => 'Search timeouts',
    'vector_recall' => 'Search quality',
    'vector_index_size_per_corpus' => 'Search index size',
    'vector_index_build_age_seconds' => 'Search rebuild age',
    'circuit_breaker_anthropic_state' => 'Anthropic safeguard',
    'circuit_breaker_voyage_state' => 'Voyage safeguard',
    'circuit_breaker_open_count_total' => 'Safeguard activations',
    'prompt_cache_hit_rate' => 'Prompt reuse',
    'response_cache_hit_rate' => 'Saved answer reuse',
    'semantic_cache_hit_rate' => 'Similar answer reuse',
    'cost_per_query_class_haiku' => 'Fast model cost',
    'cost_per_query_class_sonnet' => 'Detailed model cost',
    'cost_per_query_class_voyage' => 'Search model cost',
    'batch_api_pending_count' => 'Queued lower-cost work',
    'fallback_chain_usage_count_anthropic' => 'Anthropic fallback use',
    'fallback_chain_usage_count_voyage' => 'Voyage fallback use',
    'proxy_idempotency_cache_alive' => 'Retry protection',
    'usage_caps_breach_count' => 'Limit reached count',
    'proxy_request_p99_latency_ms' => 'App request p99',
    'proxy_request_5xx_rate' => 'Server error rate',
    'azure_extensions_present' => 'Database extensions',
    'pg_cron_scheduler_alive' => 'Scheduled jobs',
    'pg_cron_jobs_failed_24h' => 'Failed scheduled jobs',
    'partition_count_active' => 'Active data partitions',
    'partition_maintenance_last_run_age_seconds' => 'Partition maintenance age',
    'partition_default_row_count' => 'Unsorted partition rows',
    'migration_apply_drift_count' => 'Database drift',
    'audit_chain_lag_seconds' => 'Audit log delay',
    'audit_chain_anchor_age_seconds' => 'Audit anchor age',
    'event_outbox_undelivered_count' => 'Waiting notifications',
    'event_outbox_lag_seconds' => 'Notification delay',
    'event_outbox_publish_error_rate' => 'Notification errors',
    'notify_queue_usage_ratio' => 'Notification queue usage',
    'firebase_jwks_fetch_alive' => 'Sign-in key check',
    'service_principal_jwt_alive' => 'Service sign-in check',
    'cloud_run_instance_count' => 'Hosting instances',
    _ => key.replaceAll('_', ' ').trim(),
  };
}
