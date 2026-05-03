// Phase 11A.UX.health (F.1) — Health admin surface (HP #10 cleanup).
//
// Read-only operator-facing view of the proxy `/health` envelope.
// Three tabs reflect the three D.1 metric tiers:
//
//   * Retrieval — graph (AGE) + vector + rollup freshness signals.
//   * Proxy     — circuit breakers + cache hit ratios + tier routing
//                 + cost-discipline levers + idempotency / caps.
//   * Infra     — postgres extensions, pg_cron, pg_partman, audit
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
import '../models/health_admin_models.dart';
import '../services/health_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';

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
    label: 'Retrieval',
    keySuffix: 'retrieval',
    sections: <_SectionSpec>[
      _SectionSpec(
        title: 'Corpus / rollup freshness',
        tiles: <_TileSpec>[
          _TileSpec('rollup_freshness_per_grain'),
          _TileSpec('rollup_refresh_lag_seconds'),
        ],
      ),
      _SectionSpec(
        title: 'AGE graph traversal',
        tiles: <_TileSpec>[
          _TileSpec('graph_traversal_latency_ms', shortLabel: 'AGE p95'),
          _TileSpec('graph_traversal_p99_latency_ms', shortLabel: 'AGE p99'),
          _TileSpec('graph_traversal_timeout_rate'),
          _TileSpec('graph_node_count'),
          _TileSpec('graph_edge_count'),
          _TileSpec('graph_projection_age_seconds'),
        ],
      ),
      _SectionSpec(
        title: 'Vector search',
        tiles: <_TileSpec>[
          _TileSpec('vector_query_latency_ms', shortLabel: 'Vector p50'),
          _TileSpec('vector_query_p99_latency_ms', shortLabel: 'Vector p99'),
          _TileSpec('vector_query_timeout_rate'),
          _TileSpec('vector_recall'),
          _TileSpec('vector_index_size_per_corpus'),
          _TileSpec('vector_index_build_age_seconds'),
        ],
      ),
    ],
  ),
  _TabSpec(
    label: 'Proxy',
    keySuffix: 'proxy',
    sections: <_SectionSpec>[
      _SectionSpec(
        title: 'Circuit breakers',
        tiles: <_TileSpec>[
          _TileSpec('circuit_breaker_anthropic_state'),
          _TileSpec('circuit_breaker_voyage_state'),
          _TileSpec('circuit_breaker_open_count_total'),
        ],
      ),
      _SectionSpec(
        title: 'Cache hit ratios',
        tiles: <_TileSpec>[
          _TileSpec('prompt_cache_hit_rate'),
          _TileSpec('response_cache_hit_rate'),
          _TileSpec('semantic_cache_hit_rate'),
        ],
      ),
      _SectionSpec(
        title: 'Tier routing & cost levers',
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
        title: 'Idempotency & caps',
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
    label: 'Infra',
    keySuffix: 'infra',
    sections: <_SectionSpec>[
      _SectionSpec(
        title: 'Database extensions & jobs',
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
        title: 'Audit chain & event outbox',
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
        title: 'Identity & runtime',
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
    @visibleForTesting this.now,
  });

  final HealthAdminGateway gateway;

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
      final envelope = await widget.gateway.fetch();
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
        _loadError = 'Could not load health envelope: $error';
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
    // The TabBar widget requires a Material ancestor; wrapping the
    // screen root in Material satisfies that without depending on the
    // outer shell (admin shell wires Scaffold; widget tests pump the
    // screen directly).
    return Material(
      key: const Key('admin_health_screen'),
      color: AppColors.backgroundDeep,
      type: MaterialType.canvas,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              lastRefreshed: _lastRefreshed,
              onRunHealthCheck: _confirmAndRefresh,
              loading: _loading || _refreshing,
            ),
            const SizedBox(height: 12),
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
            if (!_loading && _envelope == null && _loadError == null)
              Expanded(
                child: _ManualHealthPrompt(
                  onRunHealthCheck: _confirmAndRefresh,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _envelopeBody(HealthEnvelope envelope) {
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
    return AdminPageHeader(
      title: 'Health',
      subtitle:
          'Manual, read-only diagnostic for the proxy /health envelope. '
          'Three tabs mirror the D.1 contract tiers after a check runs.',
      compactBreakpoint: 640,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton.icon(
              key: const Key('admin_health_refresh_button'),
              onPressed: loading ? null : () => onRunHealthCheck(),
              icon: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.health_and_safety_outlined, size: 16),
              label: Text(loading ? 'Running...' : 'Run health check'),
            ),
            const SizedBox(height: 6),
            Text(
              lastRefreshed == null
                  ? 'Last checked: -'
                  : 'Last checked: '
                        '${lastRefreshed!.toUtc().toIso8601String()}',
              key: const Key('admin_health_last_refreshed'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthCheckConfirmDialog extends StatelessWidget {
  const _HealthCheckConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_health_confirm_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Run health check?',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: Text(
        'This can take 15-30+ seconds because staging checks real '
        'dependencies and producer freshness, including Postgres, AGE, '
        'pgvector, audit chain, event outbox, and proxy metrics. It is '
        'read-only, and red or yellow results may reflect real backend '
        'state rather than a console issue.',
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          key: const Key('admin_health_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('admin_health_confirm_run'),
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          icon: const Icon(Icons.play_arrow, size: 16),
          label: const Text('Run check'),
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
    return Center(
      key: const Key('admin_health_manual_prompt'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No health check run in this session',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Run a live diagnostic when you need the current staging '
                'state. The request is read-only and may take 15-30+ '
                'seconds because it checks real backend dependencies.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('admin_health_manual_run_button'),
                onPressed: () => onRunHealthCheck(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sunset,
                  foregroundColor: AppColors.backgroundSurface,
                ),
                icon: const Icon(Icons.health_and_safety_outlined, size: 16),
                label: const Text('Run health check'),
              ),
            ],
          ),
        ),
      ),
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
              'Dependencies unavailable — proxy /health returned HTTP 503. '
              'A required dependency probe (postgres, AGE, or pgvector) '
              'is failing. The metrics below may be stale.',
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
        .map((d) => d.name)
        .toList(growable: false);
    final failingTier1 = envelope
        .metricsAtTier(1)
        .where((m) => m.isFailing)
        .map((m) => m.key)
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
                  'Tier-1 health signals failing — investigate before '
                  'shipping.',
                  style: AppTextStyles.mono11(color: AppColors.negative),
                ),
                if (failingDeps.isNotEmpty)
                  Text(
                    'Failing dependencies: ${failingDeps.join(", ")}',
                    style: AppTextStyles.mono10(color: AppColors.textSecondary),
                  ),
                if (failingTier1.isNotEmpty)
                  Text(
                    'Failing tier-1 metrics: ${failingTier1.join(", ")}',
                    style: AppTextStyles.mono10(color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
        ],
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
            'Dependencies',
            style: AppTextStyles.mono11(
              color: AppColors.textMuted,
            ).copyWith(fontWeight: FontWeight.w600),
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
        '${dep.name} · ${dep.check} · ${_severityLabel(dep.status)}',
        style: AppTextStyles.mono10(
          color: color,
        ).copyWith(fontWeight: FontWeight.w600),
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
              'Overall severity: ${_severityLabel(severity)}'
              '${envelope.status.isEmpty ? '' : ' · status ${envelope.status}'}',
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono11(
                color: AppColors.textPrimary,
              ).copyWith(fontWeight: FontWeight.w600),
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
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              section.title,
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
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
    final value = m?.displayValue ?? '—';
    final unit = m?.unit ?? '';
    final threshold = m?.thresholdCaption;
    final observed = m?.observedAt;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
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
                    tile.shortLabel ?? tile.metricKey,
                    style: AppTextStyles.mono11(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
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
              unit.isEmpty ? value : '$value $unit',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
            if (threshold != null) ...[
              const SizedBox(height: 4),
              Text(
                'thresholds: $threshold',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              observed == null
                  ? 'observed: —'
                  : 'observed: ${observed.toUtc().toIso8601String()}',
              style: AppTextStyles.mono8(color: AppColors.textMuted),
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
    final label = 'T$tier · ${_severityLabel(severity)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(
          color: color,
        ).copyWith(fontWeight: FontWeight.w700),
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
      return 'green';
    case HealthSeverity.yellow:
      return 'yellow';
    case HealthSeverity.red:
      return 'red';
    case HealthSeverity.unknown:
      return 'unknown';
  }
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
