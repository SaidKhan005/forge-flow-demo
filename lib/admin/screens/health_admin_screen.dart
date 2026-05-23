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
// Tier coloring per F.1 prompt:
//   - Tier-1 fail (or HTTP 503 dependency probe) → red top-of-page
//     banner ("Dependencies unavailable" or
//     "Tier-1 signals failing").
//   - Tier-2 fail → yellow chip on the offending tile.
//   - Tier-3 fail → grey chip on the offending tile (informational).
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
import '../../widgets/console/console_screen_body.dart';
import '../../widgets/console/console_screen_header.dart';
import '../../widgets/console/console_surface.dart';

import '../admin_route_handoff.dart';
import '../admin_human_labels.dart';
import '../models/health_admin_models.dart';
import '../services/health_admin_gateway.dart';
import '../widgets/admin_run_check_controls.dart';
import '../widgets/admin_scope_notice_adapter.dart';
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
    label: 'Ecosystem',
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
    final showDefinitions = MediaQuery.sizeOf(context).width >= 520;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (envelope.dependenciesUnavailable)
            const _DependenciesUnavailableBanner(
              key: Key('admin_health_dependencies_unavailable'),
            )
          else if (envelope.hasTier1Failure)
            _Tier1FailureBanner(
              key: const Key('admin_health_tier1_banner'),
              envelope: envelope,
            ),
          const _HealthPriorityKey(),
          const SizedBox(height: 12),
          if (showDefinitions) ...[
            const _HealthDefinitionsCard(),
            const SizedBox(height: 12),
          ],
          _DependenciesStrip(envelope: envelope),
          const SizedBox(height: 12),
          _OverallSeverityChip(envelope: envelope),
          const SizedBox(height: 12),
          TabBar(
            key: const Key('admin_health_tabs'),
            controller: _tabs,
            isScrollable: true,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.sunset,
            tabs: <Widget>[
              for (final tab in _kTabs)
                Tab(
                  key: Key('admin_health_tab_${tab.keySuffix}'),
                  text: tab.label,
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
                  ),
              ],
            ),
          ),
        ],
      ),
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

class _DependenciesUnavailableBanner extends StatelessWidget {
  const _DependenciesUnavailableBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'A required service check is failing, so the results below may be stale.',
              style: AppTextStyles.mono11(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tier1FailureBanner extends StatelessWidget {
  const _Tier1FailureBanner({super.key, required this.envelope});

  final HealthEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final failingDeps = envelope.dependencies
        .where(
          (d) =>
              d.status == HealthSeverity.red ||
              d.status == HealthSeverity.yellow,
        )
        .map(_dependencyLabel)
        .toList(growable: false);
    final failingTier1 = envelope
        .metricsAtTier(1)
        .where((m) => m.isFailing)
        .map((m) => _healthMetricLabel(m.key))
        .toList(growable: false);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 18, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Critical checks are failing. Fix the cause before relying on this environment.',
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
                if (failingDeps.isNotEmpty)
                  Text(
                    'Services affected: ${failingDeps.join(", ")}',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                if (failingTier1.isNotEmpty)
                  Text(
                    'Critical checks affected: ${failingTier1.join(", ")}',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthPriorityKey extends StatelessWidget {
  const _HealthPriorityKey();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        return Container(
          key: const Key('admin_health_priority_key'),
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: compact ? 8 : 12,
          ),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: compact
              ? Text(
                  'Critical = core checks | Important = reliability/freshness | Info = context',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                )
              : Wrap(
                  spacing: 16,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: const <Widget>[
                    _PriorityKeyItem(
                      label: 'Critical',
                      description: 'Core service and data-safety checks.',
                      color: AppColors.negative,
                    ),
                    _PriorityKeyItem(
                      label: 'Important',
                      description: 'Reliability, freshness, and cost signals.',
                      color: AppColors.warning,
                    ),
                    _PriorityKeyItem(
                      label: 'Info',
                      description: 'Helpful context for support follow-up.',
                      color: AppColors.neutral,
                    ),
                  ],
                ),
        );
      },
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

class _HealthDefinitionsCard extends StatelessWidget {
  const _HealthDefinitionsCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_health_plain_english_definitions'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 900
              ? 4
              : constraints.maxWidth >= 520
              ? 2
              : 1;
          const gap = 10.0;
          final itemWidth =
              (constraints.maxWidth - (gap * (columns - 1))) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              _HealthDefinitionItem(
                width: itemWidth,
                label: 'Advisor data',
                description:
                    'Knowledge, vectors, and rollups the advisor uses to answer accurately.',
              ),
              _HealthDefinitionItem(
                width: itemWidth,
                label: 'App service',
                description:
                    'The backend services that serve admin, advisor, and workflow requests.',
              ),
              _HealthDefinitionItem(
                width: itemWidth,
                label: 'Ecosystem',
                description:
                    'Shared database, search, queues, and scheduled work that keep the app running.',
              ),
              _HealthDefinitionItem(
                width: itemWidth,
                label: 'Service checks',
                description:
                    'Read-only pings that confirm each required service answered successfully.',
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HealthDefinitionItem extends StatelessWidget {
  const _HealthDefinitionItem({
    required this.width,
    required this.label,
    required this.description,
  });

  final double width;
  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
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

class _OverallSeverityChip extends StatelessWidget {
  const _OverallSeverityChip({required this.envelope});

  final HealthEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final severity = envelope.severity;
    final color = _severityColor(severity);
    return Container(
      key: const Key('admin_health_overall_severity'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _overallStatusLabel(envelope),
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabBody extends StatelessWidget {
  const _TabBody({super.key, required this.tab, required this.envelope});

  final _TabSpec tab;
  final HealthEnvelope envelope;

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
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.section, required this.envelope});

  final _SectionSpec section;
  final HealthEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: OperatorWebPanel(
        title: section.title,
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final tile in section.tiles)
              _MetricTile(
                key: Key('admin_health_tile_${tile.metricKey}'),
                tile: tile,
                metric: envelope.metrics[tile.metricKey],
              ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({super.key, required this.tile, required this.metric});

  final _TileSpec tile;
  final HealthMetric? metric;

  @override
  Widget build(BuildContext context) {
    final m = metric;
    final severity = m?.status ?? HealthSeverity.unknown;
    final tier = m?.tier ?? 3;
    final chipColor = _tierChipColor(tier, severity);
    final value = _metricDisplayValue(m);
    final unit = m?.unit ?? '';
    final threshold = m?.thresholdCaption;
    final observed = m?.observedAt;
    final source = _metricSourceLabel(m);
    final owner = _metricOwnerLabel(m);
    final remediation = _metricRemediation(m, tier, severity);

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
                    tile.shortLabel ?? _healthMetricLabel(tile.metricKey),
                    style: AppTextStyles.uiLabel(color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _TierChip(
                  key: Key('admin_health_tile_${tile.metricKey}_chip'),
                  tier: tier,
                  severity: severity,
                  color: chipColor,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              unit.isEmpty || value == 'No value yet' ? value : '$value $unit',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Producer state: ${_severityLabel(severity)}',
              key: Key('admin_health_tile_${tile.metricKey}_state'),
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
            if (m != null && m.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                m.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
            ],
            if (threshold != null) ...[
              const SizedBox(height: 4),
              Text(
                'limits: $threshold',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Source: $source',
              key: Key('admin_health_tile_${tile.metricKey}_source'),
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
            const SizedBox(height: 2),
            Text(
              'Owner: $owner',
              key: Key('admin_health_tile_${tile.metricKey}_owner'),
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
            const SizedBox(height: 2),
            Text(
              observed == null
                  ? 'Checked: no data'
                  : 'Checked: ${adminHumanDateTime(observed)}',
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
            const SizedBox(height: 6),
            Text(
              remediation,
              key: Key('admin_health_tile_${tile.metricKey}_remediation'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body12(color: _remediationColor(severity)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TierChip extends StatelessWidget {
  const _TierChip({
    super.key,
    required this.tier,
    required this.severity,
    required this.color,
  });

  final int tier;
  final HealthSeverity severity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = '${_tierLabel(tier)}: ${_compactSeverityLabel(severity)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: AppTextStyles.chipLabel(color: color)),
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

String _compactSeverityLabel(HealthSeverity severity) {
  switch (severity) {
    case HealthSeverity.green:
      return 'Good';
    case HealthSeverity.yellow:
      return 'Check';
    case HealthSeverity.red:
      return 'Fail';
    case HealthSeverity.unknown:
      return 'No data';
  }
}

String _metricDisplayValue(HealthMetric? metric) {
  if (metric == null || metric.value == null) return 'No value yet';
  final value = metric.displayValue;
  if (value == '-' || value.trim().isEmpty) return 'No value yet';
  return value;
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

String _friendlyEnvelopeStatus(String status) {
  return switch (status.trim().toLowerCase()) {
    'ok' => 'all clear',
    'degraded' => 'needs attention',
    'down' => 'failing',
    _ => status,
  };
}

String _overallStatusLabel(HealthEnvelope envelope) {
  final severity = _severityLabel(envelope.severity);
  final status = _friendlyEnvelopeStatus(envelope.status);
  if (status.isEmpty || status == severity.toLowerCase()) {
    return 'Overall status: $severity';
  }
  if (status == 'all clear' && envelope.severity == HealthSeverity.green) {
    return 'Overall status: Good';
  }
  if (status == 'needs attention' &&
      envelope.severity == HealthSeverity.yellow) {
    return 'Overall status: Needs attention';
  }
  if (status == 'failing' && envelope.severity == HealthSeverity.red) {
    return 'Overall status: Failing';
  }
  return 'Overall status: $severity - $status';
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

/// Tier coloring rule from the F.1 prompt:
///   * Tier 1 fail → red chip.
///   * Tier 2 fail → yellow chip.
///   * Tier 3 fail → grey/neutral chip (informational).
///   * Healthy chips reflect the metric's own severity (green or
///     unknown).
Color _tierChipColor(int tier, HealthSeverity severity) {
  if (severity == HealthSeverity.green) return AppColors.positive;
  if (severity == HealthSeverity.unknown) return AppColors.neutral;
  // Failing severity: route through tier ladder per F.1 prompt.
  if (tier == 1) return AppColors.negative;
  if (tier == 2) return AppColors.warning;
  return AppColors.neutral;
}
