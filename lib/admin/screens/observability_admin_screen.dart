// Phase 11A.6 — Observability dashboard surface.
//
// Read-only operator-facing view of the cost-telemetry, dormancy,
// margin, cap-event, graph, latency, and Cloud Run rows the
// observability proxy assembles. Tabs:
//
//   * Cost      — cost telemetry by axis, cache hit rate, model mix,
//                 batch-mode share.
//   * Top-N     — most-expensive operators / staff / workflows over
//                 1d / 7d / 30d rolling windows.
//   * Operators — dormancy + per-tier margin estimates.
//   * Cap events — refused requests when usage_caps was reached.
//   * Graph     — approved / inferred / rejected / isolated counts,
//                 projection freshness, traversal p95.
//   * Cloud Run — per-route latency p50/p95/p99 + error rate, plus
//                 active Cloud Run instances by service.
//
// The /health envelope (dependency probes, tier-1 / tier-2 / tier-3
// metric tiers) is owned by the F.1 health surface. The header
// includes a "View health envelope" link out so the F&F admin can
// jump to it without duplicating chrome.
//
// Performance posture (per docs/contracts/slice_runtime_acceptance_contract.md):
// the cost / dormancy queries scan rolling windows on `usage_logs` and
// can take seconds. The screen does NOT auto-poll. The first paint
// renders a manual-run prompt; the operator confirms a "Run
// observability check" before any fetch fires. Refresh is the same
// path. Stacked in-flight requests are blocked by `_refreshing`.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../models/observability_admin_models.dart';
import '../services/observability_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';

class _TabSpec {
  const _TabSpec({required this.label, required this.keySuffix});
  final String label;
  final String keySuffix;
}

const List<_TabSpec> _kTabs = <_TabSpec>[
  _TabSpec(label: 'Cost', keySuffix: 'cost'),
  _TabSpec(label: 'Top-N', keySuffix: 'top'),
  _TabSpec(label: 'Operators', keySuffix: 'operators'),
  _TabSpec(label: 'Cap events', keySuffix: 'cap_events'),
  _TabSpec(label: 'Graph', keySuffix: 'graph'),
  _TabSpec(label: 'Cloud Run', keySuffix: 'cloud_run'),
];

class ObservabilityAdminScreen extends StatefulWidget {
  const ObservabilityAdminScreen({
    super.key,
    required this.gateway,
    @visibleForTesting this.now,
  });

  final ObservabilityAdminGateway gateway;

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
  final TextEditingController _queryClassFilterController =
      TextEditingController();

  bool _loading = false;
  bool _refreshing = false;
  ObservabilityEnvelope? _envelope;
  String? _loadError;
  DateTime? _lastRefreshed;
  String? _activeQueryClassFilter;

  DateTime _clockNow() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _kTabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _queryClassFilterController.dispose();
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

  /// Re-fetch using the current query_class filter. Skips the
  /// confirmation dialog because narrowing the cost table in-place is
  /// the runtime contract's "scope down" path; confirmation is for
  /// the initial expensive run.
  Future<void> _applyFilterAndRefetch() async {
    if (_refreshing) return;
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      if (_envelope == null) _loading = true;
      _loadError = null;
    });
    try {
      final filter = _queryClassFilterController.text.trim();
      final request = ObservabilityFetchRequest(
        queryClassFilter: filter.isEmpty ? null : filter,
      );
      final envelope = await widget.gateway.fetch(request);
      if (!mounted) return;
      setState(() {
        _envelope = envelope;
        _activeQueryClassFilter = filter.isEmpty ? null : filter;
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
        _loadError = 'Could not load observability envelope: $error';
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
    return Material(
      key: const Key('admin_observability_screen'),
      color: AppColors.backgroundDeep,
      type: MaterialType.canvas,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              lastRefreshed: _lastRefreshed,
              onRunCheck: _confirmAndRefresh,
              loading: _loading || _refreshing,
            ),
            const SizedBox(height: 12),
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
            if (!_loading && _envelope == null && _loadError == null)
              Expanded(
                child: _ManualRunPrompt(onRunCheck: _confirmAndRefresh),
              ),
          ],
        ),
      ),
    );
  }

  Widget _envelopeBody(ObservabilityEnvelope envelope) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AsOfStrip(envelope: envelope),
          const SizedBox(height: 12),
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
                  text: tab.label,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _CostTab(
                  key: const Key('admin_observability_tab_body_cost'),
                  envelope: envelope,
                  filterController: _queryClassFilterController,
                  activeFilter: _activeQueryClassFilter,
                  onApplyFilter: _applyFilterAndRefetch,
                  filterApplying: _refreshing,
                ),
                _TopNTab(
                  key: const Key('admin_observability_tab_body_top'),
                  envelope: envelope,
                ),
                _OperatorsTab(
                  key: const Key('admin_observability_tab_body_operators'),
                  envelope: envelope,
                ),
                _CapEventsTab(
                  key: const Key('admin_observability_tab_body_cap_events'),
                  envelope: envelope,
                ),
                _GraphTab(
                  key: const Key('admin_observability_tab_body_graph'),
                  envelope: envelope,
                ),
                _CloudRunTab(
                  key: const Key('admin_observability_tab_body_cloud_run'),
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
    required this.onRunCheck,
    required this.loading,
  });

  final DateTime? lastRefreshed;
  final Future<void> Function() onRunCheck;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return AdminPageHeader(
      title: 'Observability',
      subtitle:
          'Cost telemetry, dormancy, margin, cap events, graph, and '
          'Cloud Run signals. Read-only. Health dependency probes and '
          'tier-1/2/3 metric tiles live on the Health surface.',
      compactBreakpoint: 720,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton.icon(
              key: const Key('admin_observability_refresh_button'),
              onPressed: loading ? null : () => onRunCheck(),
              icon: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.insights_outlined, size: 16),
              label: Text(loading ? 'Running...' : 'Run observability check'),
            ),
            const SizedBox(height: 6),
            Text(
              lastRefreshed == null
                  ? 'Last refreshed: -'
                  : 'Last refreshed: '
                      '${lastRefreshed!.toUtc().toIso8601String()}',
              key: const Key('admin_observability_last_refreshed'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              'View health envelope on the Health surface.',
              key: const Key('admin_observability_health_link_hint'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ObservabilityConfirmDialog extends StatelessWidget {
  const _ObservabilityConfirmDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_observability_confirm_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Run observability check?',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: Text(
        'This scans rolling cost windows in usage_logs, computes margin '
        'estimates, and aggregates Cloud Run shape. Reads only — but '
        'the producer queries can take 10-30+ seconds against a real '
        'staging dataset, so manual confirmation prevents accidental '
        'load on the proxy.',
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          key: const Key('admin_observability_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('admin_observability_confirm_run'),
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

class _ManualRunPrompt extends StatelessWidget {
  const _ManualRunPrompt({required this.onRunCheck});

  final Future<void> Function() onRunCheck;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('admin_observability_manual_prompt'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
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
                'No observability run in this session',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Cost telemetry, dormancy, margin, and Cloud Run rows '
                'are computed on demand. The producer queries can scan '
                'rolling 30-day windows, so the first run is manual.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('admin_observability_manual_run_button'),
                onPressed: () => onRunCheck(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sunset,
                  foregroundColor: AppColors.backgroundSurface,
                ),
                icon: const Icon(Icons.insights_outlined, size: 16),
                label: const Text('Run observability check'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AsOfStrip extends StatelessWidget {
  const _AsOfStrip({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final dormantCount = envelope.dormantOperators.length;
    final underwaterCount = envelope.underwaterOperators.length;
    final capEventCount = envelope.capEvents.length;
    return Container(
      key: const Key('admin_observability_as_of_strip'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            'As of: ${envelope.asOf.toUtc().toIso8601String()}',
            style: AppTextStyles.mono11(color: AppColors.textPrimary)
                .copyWith(fontWeight: FontWeight.w600),
          ),
          _SummaryChip(
            label: 'Dormant',
            value: '$dormantCount',
            severity: dormantCount > 0
                ? _SummarySeverity.warning
                : _SummarySeverity.neutral,
          ),
          _SummaryChip(
            label: 'Underwater',
            value: '$underwaterCount',
            severity: underwaterCount > 0
                ? _SummarySeverity.negative
                : _SummarySeverity.neutral,
          ),
          _SummaryChip(
            label: 'Cap events',
            value: '$capEventCount',
            severity: capEventCount > 0
                ? _SummarySeverity.warning
                : _SummarySeverity.neutral,
          ),
        ],
      ),
    );
  }
}

enum _SummarySeverity { neutral, warning, negative }

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.value,
    required this.severity,
  });

  final String label;
  final String value;
  final _SummarySeverity severity;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (severity) {
      case _SummarySeverity.neutral:
        color = AppColors.neutral;
        break;
      case _SummarySeverity.warning:
        color = AppColors.warning;
        break;
      case _SummarySeverity.negative:
        color = AppColors.negative;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label: $value',
        style: AppTextStyles.mono10(color: color)
            .copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Tabs ─────────────────────────────────────────────────────────────

class _CostTab extends StatelessWidget {
  const _CostTab({
    super.key,
    required this.envelope,
    required this.filterController,
    required this.activeFilter,
    required this.onApplyFilter,
    required this.filterApplying,
  });

  final ObservabilityEnvelope envelope;
  final TextEditingController filterController;
  final String? activeFilter;
  final Future<void> Function() onApplyFilter;
  final bool filterApplying;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionCard(
            keyName: 'admin_observability_section_cost_telemetry',
            title: 'Cost telemetry by axis',
            subtitle:
                'Total cost grouped by (operator, location, staff, '
                'workflow, usage_class, query_class). Rows with null IDs '
                'are aggregates at that level. The table is bounded — '
                'use the query_class filter to narrow scope when '
                'truncated.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _CostTelemetryFilterBar(
                  controller: filterController,
                  activeFilter: activeFilter,
                  onApply: onApplyFilter,
                  applying: filterApplying,
                ),
                const SizedBox(height: 8),
                _CostTelemetryTruncationHint(envelope: envelope),
                const SizedBox(height: 8),
                if (envelope.costTelemetry.isEmpty)
                  const _EmptyState(
                    keyName: 'admin_observability_cost_telemetry_empty',
                    label:
                        'No cost rows in window — usage_logs is empty '
                        '(or the query_class filter excluded every row).',
                  )
                else
                  _CostTelemetryTable(rows: envelope.costTelemetry),
              ],
            ),
          ),
          _SectionCard(
            keyName: 'admin_observability_section_cache_hit_rates',
            title: 'Cache hit rate per query_class',
            subtitle:
                'Hard Promise #9 lever 3. Below 30% trips the warning '
                'chip; below 10% trips negative.',
            child: envelope.cacheHitRates.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_cache_hit_rates_empty',
                    label: 'No cache events in window.',
                  )
                : Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      for (final entry in envelope.cacheHitRates)
                        _HitRateTile(
                          key: Key(
                            'admin_observability_cache_hit_rate_'
                            '${entry.queryClass}',
                          ),
                          entry: entry,
                        ),
                    ],
                  ),
          ),
          _SectionCard(
            keyName: 'admin_observability_section_model_mix',
            title: 'Model mix per query_class',
            subtitle:
                'Hard Promise #9 lever 2. Sonnet share above the policy '
                'ceiling for a query_class trips the warning chip.',
            child: envelope.modelMix.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_model_mix_empty',
                    label: 'No routed requests in window.',
                  )
                : Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      for (final entry in envelope.modelMix)
                        _ModelMixTile(
                          key: Key(
                            'admin_observability_model_mix_'
                            '${entry.queryClass}',
                          ),
                          entry: entry,
                        ),
                    ],
                  ),
          ),
          _SectionCard(
            keyName: 'admin_observability_section_batch_mode_share',
            title: 'Batch-mode share per query_class',
            subtitle:
                'Hard Promise #9 lever 5. Higher share means more async '
                'workloads land in the Anthropic Batch API discount.',
            child: envelope.batchModeShare.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_batch_mode_share_empty',
                    label: 'No async workloads in window.',
                  )
                : Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      for (final entry in envelope.batchModeShare)
                        _BatchModeShareTile(
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

/// Filter bar above the cost-telemetry table. The text field accepts
/// a single `query_class` value (e.g. `advisor_qa`); applying the
/// filter re-fetches the envelope through the gateway with the
/// scope narrowed server-side.
class _CostTelemetryFilterBar extends StatelessWidget {
  const _CostTelemetryFilterBar({
    required this.controller,
    required this.activeFilter,
    required this.onApply,
    required this.applying,
  });

  final TextEditingController controller;
  final String? activeFilter;
  final Future<void> Function() onApply;
  final bool applying;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: TextField(
            key: const Key('admin_observability_cost_query_class_filter'),
            controller: controller,
            enabled: !applying,
            onSubmitted: (_) => applying ? null : onApply(),
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter by query_class (e.g. advisor_qa)',
              hintStyle: AppTextStyles.mono10(color: AppColors.textMuted),
              filled: true,
              fillColor: AppColors.backgroundSurface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
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
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          key: const Key(
            'admin_observability_cost_query_class_filter_apply',
          ),
          onPressed: applying ? null : () => onApply(),
          icon: applying
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.filter_alt_outlined, size: 14),
          label: const Text('Apply'),
        ),
        if (activeFilter != null) ...<Widget>[
          const SizedBox(width: 8),
          Container(
            key: const Key(
              'admin_observability_cost_query_class_filter_chip',
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: AppColors.shimmer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'query_class = $activeFilter',
              style: AppTextStyles.mono10(color: AppColors.textMuted)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ],
    );
  }
}

/// "Showing N of M (truncated — refine the filter)" hint above the
/// cost-telemetry table. Always rendered so the operator knows the
/// surface count even when the result is exhaustive.
class _CostTelemetryTruncationHint extends StatelessWidget {
  const _CostTelemetryTruncationHint({required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final shown = envelope.costTelemetry.length;
    final total = envelope.costTelemetryTotalCount;
    final truncated = envelope.costTelemetryTruncated;
    final color = truncated ? AppColors.warning : AppColors.textMuted;
    final label = truncated
        ? 'Showing $shown of $total rows (server-side cap reached — '
            'refine the query_class filter to narrow the scope).'
        : 'Showing $shown of $total rows.';
    return Container(
      key: truncated
          ? const Key('admin_observability_cost_truncated')
          : const Key('admin_observability_cost_count'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        label,
        style: AppTextStyles.mono10(color: color),
      ),
    );
  }
}

/// Bounded, virtualized cost-telemetry table. Uses
/// [ListView.builder] inside a fixed-height container so an envelope
/// at the [kObservabilityCostTelemetryLimit] cap renders only the
/// visible rows. The wrapping `SingleChildScrollView` on the cost tab
/// ensures the rest of the page (cache hit / model mix / batch tiles)
/// scrolls past the table.
class _CostTelemetryTable extends StatelessWidget {
  const _CostTelemetryTable({required this.rows});

  final List<CostTelemetryEntry> rows;

  static const double _maxTableHeight = 360;
  static const double _rowExtent = 52;

  @override
  Widget build(BuildContext context) {
    final tableHeight =
        (rows.length * _rowExtent + 32).clamp(120.0, _maxTableHeight);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 4,
                child: Text(
                  'operator / location / staff / workflow',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'usage / query',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'cost (USD) / requests',
                  textAlign: TextAlign.right,
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          key: const Key('admin_observability_cost_table_viewport'),
          height: tableHeight,
          child: ListView.builder(
            itemCount: rows.length,
            itemExtent: _rowExtent,
            itemBuilder: (context, index) {
              final row = rows[index];
              return Container(
                key: Key(_costRowKey(row)),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: AppColors.borderSubtle,
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            row.operatorId,
                            style: AppTextStyles.mono11(
                              color: AppColors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'loc: ${row.locationId ?? '—'} · '
                            'staff: ${row.staffId ?? '—'} · '
                            'wf: ${row.workflowId ?? '—'}',
                            style: AppTextStyles.mono10(
                              color: AppColors.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            row.usageClass,
                            style: AppTextStyles.mono11(
                              color: AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            row.queryClass,
                            style: AppTextStyles.mono10(
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            '\$${row.totalUsd.toStringAsFixed(2)}',
                            style: AppTextStyles.mono14(
                              color: AppColors.textPrimary,
                              weight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '${row.requestCount} req',
                            style: AppTextStyles.mono10(
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HitRateTile extends StatelessWidget {
  const _HitRateTile({super.key, required this.entry});

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
    return _MetricTileShell(
      label: entry.queryClass,
      value: '${(entry.hitRate * 100).toStringAsFixed(1)}%',
      caption:
          'thresholds yellow: ${(entry.yellowThreshold * 100).toStringAsFixed(0)}% · '
          'red: ${(entry.redThreshold * 100).toStringAsFixed(0)}%',
      accent: color,
    );
  }
}

class _ModelMixTile extends StatelessWidget {
  const _ModelMixTile({super.key, required this.entry});

  final ModelMixEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = entry.sonnetShareExceedsCeiling
        ? AppColors.warning
        : AppColors.positive;
    return _MetricTileShell(
      label: entry.queryClass,
      value:
          'Haiku ${(entry.haikuShare * 100).toStringAsFixed(0)}% · '
          'Sonnet ${(entry.sonnetShare * 100).toStringAsFixed(0)}%',
      caption:
          'sonnet ceiling: ${(entry.sonnetShareCeiling * 100).toStringAsFixed(0)}%',
      accent: color,
    );
  }
}

class _BatchModeShareTile extends StatelessWidget {
  const _BatchModeShareTile({super.key, required this.entry});

  final BatchModeShareEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = entry.batchShare >= entry.targetShare
        ? AppColors.positive
        : AppColors.neutral;
    return _MetricTileShell(
      label: entry.queryClass,
      value: '${(entry.batchShare * 100).toStringAsFixed(0)}%',
      caption:
          'target ${(entry.targetShare * 100).toStringAsFixed(0)}%',
      accent: color,
    );
  }
}

class _TopNTab extends StatelessWidget {
  const _TopNTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final window in ObservabilityWindow.values)
            _SectionCard(
              keyName:
                  'admin_observability_section_top_${observabilityWindowKey(window)}',
              title: 'Top expensive · ${observabilityWindowKey(window)}',
              subtitle:
                  'Most-expensive operators / staff / workflows over the '
                  '${observabilityWindowKey(window)} rolling window.',
              child: _TopExpensiveList(
                window: window,
                rows: envelope.topExpensiveForWindow(window).toList(
                      growable: false,
                    ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopExpensiveList extends StatelessWidget {
  const _TopExpensiveList({required this.window, required this.rows});

  final ObservabilityWindow window;
  final List<TopExpensiveEntry> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyState(
        keyName:
            'admin_observability_top_${observabilityWindowKey(window)}_empty',
        label: 'No rows in this window.',
      );
    }
    final sorted = [...rows]
      ..sort((a, b) => b.totalUsd.compareTo(a.totalUsd));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final row in sorted)
          Container(
            key: Key(
              'admin_observability_top_row_'
              '${observabilityWindowKey(window)}_${row.axis}_${row.label}',
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
              ),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.shimmer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    row.axis,
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    row.label,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.mono11(color: AppColors.textPrimary),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '\$${row.totalUsd.toStringAsFixed(2)}',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${row.requestCount} req)',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _OperatorsTab extends StatelessWidget {
  const _OperatorsTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionCard(
            keyName: 'admin_observability_section_dormancy',
            title: 'Operator dormancy',
            subtitle:
                'last_active_at vs. as_of. Operators silent for '
                '$kObservabilityDormancyDaysThreshold+ days are flagged so '
                'precompute can skip them.',
            child: envelope.dormancy.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_dormancy_empty',
                    label: 'No operators registered yet.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final entry in envelope.dormancy)
                        _DormancyRow(
                          key: Key(
                            'admin_observability_dormancy_row_'
                            '${entry.operatorId}',
                          ),
                          entry: entry,
                        ),
                    ],
                  ),
          ),
          _SectionCard(
            keyName: 'admin_observability_section_margin',
            title: 'Per-tier margin estimate',
            subtitle:
                'Revenue from subscription_tier minus rolling cost. '
                'Underwater operators surface in red.',
            child: envelope.margins.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_margin_empty',
                    label: 'No margin rows yet.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final entry in envelope.margins)
                        _MarginRow(
                          key: Key(
                            'admin_observability_margin_row_'
                            '${entry.operatorId}',
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

class _DormancyRow extends StatelessWidget {
  const _DormancyRow({super.key, required this.entry});

  final OperatorDormancyEntry entry;

  @override
  Widget build(BuildContext context) {
    final dormant = entry.isDormant;
    final neverActive = entry.neverActive;
    // Never-active is the strongest "skip-precompute" signal — render
    // negative so the F&F admin can spot a row the producer has never
    // had data for. Known-silent dormants (>= 30d) stay warning;
    // active operators stay positive.
    final Color color;
    if (neverActive) {
      color = AppColors.negative;
    } else if (dormant) {
      color = AppColors.warning;
    } else {
      color = AppColors.positive;
    }
    final lastActive = entry.lastActiveAt;
    final silent = entry.daysSilent;
    final String chipLabel;
    if (neverActive) {
      chipLabel = 'never active · DORMANT';
    } else if (silent == null) {
      chipLabel = 'silence unknown';
    } else if (dormant) {
      chipLabel = '${silent}d silent · DORMANT';
    } else {
      chipLabel = '${silent}d silent';
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.businessName,
                  style: AppTextStyles.mono14(color: AppColors.textPrimary),
                ),
                Text(
                  'operator: ${entry.operatorId} · tier: '
                  '${entry.subscriptionTier ?? '—'}',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
                Text(
                  lastActive == null
                      ? 'last active: —'
                      : 'last active: ${lastActive.toUtc().toIso8601String()}',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            key: dormant
                ? Key(
                    'admin_observability_dormancy_flag_${entry.operatorId}',
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color, width: 1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              chipLabel,
              style: AppTextStyles.mono10(color: color)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _MarginRow extends StatelessWidget {
  const _MarginRow({super.key, required this.entry});

  final MarginEstimateEntry entry;

  @override
  Widget build(BuildContext context) {
    final underwater = entry.isUnderwater;
    final color = underwater ? AppColors.negative : AppColors.positive;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.businessName,
                  style: AppTextStyles.mono14(color: AppColors.textPrimary),
                ),
                Text(
                  'tier: ${entry.subscriptionTier} · operator: '
                  '${entry.operatorId}',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                'rev \$${entry.revenueUsd.toStringAsFixed(2)}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
              Text(
                'cost \$${entry.costUsd.toStringAsFixed(2)}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
              Container(
                key: underwater
                    ? Key(
                        'admin_observability_margin_underwater_'
                        '${entry.operatorId}',
                      )
                    : null,
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  border: Border.all(color: color, width: 1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'margin \$${entry.marginUsd.toStringAsFixed(2)}',
                  style: AppTextStyles.mono10(color: color)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CapEventsTab extends StatelessWidget {
  const _CapEventsTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionCard(
            keyName: 'admin_observability_section_cap_events',
            title: 'Cap events',
            subtitle:
                'Requests refused because usage_caps was reached. The '
                'stream is the canonical signal a runaway operator hit '
                'its monthly or per-invocation cap.',
            child: envelope.capEvents.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_cap_events_empty',
                    label: 'No cap breaches in window.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final event in envelope.capEvents)
                        _CapEventRow(
                          key: Key(
                            'admin_observability_cap_event_${event.eventId}',
                          ),
                          event: event,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _CapEventRow extends StatelessWidget {
  const _CapEventRow({super.key, required this.event});

  final CapEvent event;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${event.businessName} · ${event.usageClass} / '
                  '${event.queryClass}',
                  style: AppTextStyles.mono11(color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  event.occurredAt.toUtc().toIso8601String(),
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  'cap \$${event.capUsd.toStringAsFixed(2)}',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
                Text(
                  'attempted \$${event.attemptedUsd.toStringAsFixed(2)}',
                  style: AppTextStyles.mono14(
                    color: AppColors.negative,
                    weight: FontWeight.w700,
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

class _GraphTab extends StatelessWidget {
  const _GraphTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final graph = envelope.graph;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionCard(
            keyName: 'admin_observability_section_graph_counts',
            title: 'Graph approvals',
            subtitle:
                'Counts in canonical graph tables and rejection audit '
                'as of envelope refresh.',
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                _MetricTileShell(
                  key: const Key('admin_observability_graph_approved_nodes'),
                  label: 'Approved nodes',
                  value: '${graph.approvedNodeCount}',
                  caption: 'public.graph_nodes',
                  accent: AppColors.positive,
                ),
                _MetricTileShell(
                  key: const Key('admin_observability_graph_approved_edges'),
                  label: 'Approved edges',
                  value: '${graph.approvedEdgeCount}',
                  caption: 'public.graph_edges',
                  accent: AppColors.positive,
                ),
                _MetricTileShell(
                  key:
                      const Key('admin_observability_graph_inferred_approved'),
                  label: 'Inferred approved',
                  value: '${graph.inferredApprovedCount}',
                  caption: 'confidence_label = INFERRED',
                  accent: AppColors.warning,
                ),
                _MetricTileShell(
                  key: const Key('admin_observability_graph_rejected'),
                  label: 'Rejected candidates',
                  value: '${graph.rejectedCandidateCount}',
                  caption: 'public.graphify_review_audit',
                  accent: AppColors.neutral,
                ),
                _MetricTileShell(
                  key: const Key('admin_observability_graph_isolated_nodes'),
                  label: 'Isolated nodes',
                  value: '${graph.isolatedNodeCount}',
                  caption: 'no incident edges',
                  accent: graph.isolatedNodeCount > 0
                      ? AppColors.warning
                      : AppColors.positive,
                ),
              ],
            ),
          ),
          _SectionCard(
            keyName: 'admin_observability_section_graph_freshness',
            title: 'Graph freshness',
            subtitle:
                'AGE projection age + traversal p95 latency. Yellow if '
                'projection age exceeds 1 hour or traversal p95 exceeds '
                '250 ms.',
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                _MetricTileShell(
                  key: const Key('admin_observability_graph_projection_age'),
                  label: 'Projection age',
                  value: '${graph.projectionAgeSeconds}s',
                  caption: 'AGE last rebuild',
                  accent: graph.projectionAgeSeconds > 3600
                      ? AppColors.warning
                      : AppColors.positive,
                ),
                _MetricTileShell(
                  key: const Key('admin_observability_graph_traversal_p95'),
                  label: 'Traversal p95',
                  value: '${graph.traversalP95Ms}ms',
                  caption: 'graph_benchmark_runs',
                  accent: graph.traversalP95Ms > 250
                      ? AppColors.warning
                      : AppColors.positive,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CloudRunTab extends StatelessWidget {
  const _CloudRunTab({super.key, required this.envelope});

  final ObservabilityEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionCard(
            keyName: 'admin_observability_section_route_latency',
            title: 'Latency / error rate by route',
            subtitle:
                'Per-route p50/p95/p99 latency and 5xx rate. Drills '
                'into platform-wide signals already on the Health '
                'envelope.',
            child: envelope.routeLatency.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_route_latency_empty',
                    label: 'No route metrics in window.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              flex: 4,
                              child: Text(
                                'route',
                                style: AppTextStyles.mono10(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'p50',
                                textAlign: TextAlign.right,
                                style: AppTextStyles.mono10(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'p95',
                                textAlign: TextAlign.right,
                                style: AppTextStyles.mono10(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'p99',
                                textAlign: TextAlign.right,
                                style: AppTextStyles.mono10(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'errors',
                                textAlign: TextAlign.right,
                                style: AppTextStyles.mono10(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (final row in envelope.routeLatency)
                        Container(
                          key: Key(
                            'admin_observability_route_latency_'
                            '${_routeKey(row.route)}',
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: AppColors.borderSubtle,
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                flex: 4,
                                child: Text(
                                  row.route,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.mono11(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${row.p50Ms}ms',
                                  textAlign: TextAlign.right,
                                  style: AppTextStyles.mono11(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${row.p95Ms}ms',
                                  textAlign: TextAlign.right,
                                  style: AppTextStyles.mono11(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${row.p99Ms}ms',
                                  textAlign: TextAlign.right,
                                  style: AppTextStyles.mono11(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${(row.errorRate * 100).toStringAsFixed(2)}%',
                                  textAlign: TextAlign.right,
                                  style: AppTextStyles.mono11(
                                    color: row.errorRate > 0.01
                                        ? AppColors.warning
                                        : AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          _SectionCard(
            keyName: 'admin_observability_section_cloud_run_instances',
            title: 'Cloud Run instances',
            subtitle:
                'Active instance counts and the revision currently '
                'serving traffic. Bookmark the revision before a '
                'deploy so a rollback target is on the screen.',
            child: envelope.cloudRun.isEmpty
                ? const _EmptyState(
                    keyName: 'admin_observability_cloud_run_empty',
                    label: 'No Cloud Run services reporting.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final svc in envelope.cloudRun)
                        Container(
                          key: Key(
                            'admin_observability_cloud_run_'
                            '${svc.serviceName}',
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: AppColors.borderSubtle,
                                width: 1,
                              ),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      svc.serviceName,
                                      style: AppTextStyles.mono14(
                                        color: AppColors.textPrimary,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      'revision: ${svc.revisionId}',
                                      style: AppTextStyles.mono10(
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.end,
                                  children: <Widget>[
                                    Text(
                                      '${svc.instanceCount} active',
                                      style: AppTextStyles.mono14(
                                        color: AppColors.textPrimary,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      'min ${svc.minInstances} · max '
                                      '${svc.maxInstances}',
                                      style: AppTextStyles.mono10(
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
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

String _routeKey(String route) =>
    route.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');

/// Stable cost-row key. Uses an explicit `none` placeholder when an
/// axis (location, staff, workflow) is null so widget tests do not
/// have to decode underscore counts.
String _costRowKey(CostTelemetryEntry row) =>
    'admin_observability_cost_row_'
    '${row.operatorId}_'
    '${row.locationId ?? 'none'}_'
    '${row.staffId ?? 'none'}_'
    '${row.workflowId ?? 'none'}_'
    '${row.queryClass}';

// ── Shared building blocks ──────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({
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
      child: Container(
        key: Key(keyName),
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
              title,
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
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
        style: AppTextStyles.mono11(color: AppColors.textMuted),
      ),
    );
  }
}

class _MetricTileShell extends StatelessWidget {
  const _MetricTileShell({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
    required this.accent,
  });

  final String label;
  final String value;
  final String caption;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
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
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.mono11(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              caption,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ],
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
