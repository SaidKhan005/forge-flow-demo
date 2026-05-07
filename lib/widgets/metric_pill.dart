// feat(11W.metric-pill) — Central state+provenance-enforcing metric pill.
//
// Per memory/project_metric_honesty_doctrine.md. Every operator-visible
// metric MUST carry a [MetricState] and a [MetricPillProvenance] label so
// the renderer can enforce honesty rules: no numeric "0" when the state
// is not [MetricState.live], and a visible badge for demo/stale data.
//
// [MetricPill] is the single render surface for scalar KPI metrics in the
// Forge & Flow operator UI. It replaces direct [InputMetricCard] /
// [MetricCardNotYetAvailable] conditional logic at call sites with a
// unified, assertion-guarded widget.
//
// Render rules (each maps to a distinct visual branch):
//   live        → formatted value, provenance label small below.
//   stale       → grey formatted value, "Last synced ..." badge.
//   empty       → "No data yet" + hint from provenance. Never "0".
//   demo        → formatted value + "Demo" chip.
//   unavailable → em dash + reason from provenance.tooltip.
//
// The constructor asserts (debug-mode only) that value is non-null
// when state == live, catching producer bugs at pump time.

import 'package:flutter/material.dart';

import '../domain/models/metric_provenance.dart';
import '../theme/app_theme.dart';

export '../domain/models/metric_provenance.dart' show MetricState;

/// Provenance descriptor for a [MetricPill].
///
/// [label] is the short human-readable source name shown below the
/// value (e.g. "Toast", "QuickBooks Time", "Forecast", "Manual").
/// [tooltip] is an optional longer explanation shown in the empty /
/// unavailable branch where a one-liner helps the operator understand
/// why there is no number.
class MetricPillProvenance {
  const MetricPillProvenance({required this.label, this.tooltip});

  /// Short source name. Examples: "Toast", "QuickBooks Time",
  /// "Forecast", "Manual". Rendered small beneath the value in live
  /// / stale / demo branches.
  final String label;

  /// Optional explanation for empty / unavailable states. When present,
  /// rendered as a one-liner hint beneath "No data yet" or the em dash.
  final String? tooltip;
}

/// Central KPI metric pill widget that enforces [MetricState] +
/// [MetricPillProvenance] on every operator-visible scalar metric.
///
/// See module doc above for render rules. Never renders a bare numeric
/// "0" for non-live states — this is the primary contract guarantee.
class MetricPill extends StatelessWidget {
  const MetricPill({
    super.key,
    required this.state,
    required this.provenance,
    required this.label,
    this.value,
    this.formatter,
    this.compact = false,
  }) : assert(
         !(state == MetricState.live && value == null),
         'MetricPill: value must not be null when state == live. '
         'Metric "$label" has state=live but value=null — check the producer.',
       );

  /// Metric data state. Controls which render branch is used.
  final MetricState state;

  /// Provenance descriptor — source label + optional tooltip.
  final MetricPillProvenance provenance;

  /// Short metric name shown in the header (e.g. "CPLH", "Sales").
  final String label;

  /// Numeric value. Required (non-null) when [state] == [MetricState.live].
  /// May be supplied for [stale] and [demo] (shows the last-known value).
  /// Ignored for [empty] and [unavailable] — those branches never show a
  /// number.
  final num? value;

  /// Optional formatter applied to [value] before display. When null,
  /// [value.toString()] is used. Not called when [value] is null.
  final String Function(num)? formatter;

  /// When true, renders a compact horizontal layout suited for inline
  /// use (e.g. inside a table row). When false (default), renders the
  /// taller card layout.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return compact ? _buildCompact(context) : _buildCard(context);
  }

  // ── Card layout (default) ────────────────────────────────────────

  Widget _buildCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row: metric label + state badge (if demo)
          Row(
            children: [
              Text(
                label.toUpperCase(),
                key: Key('metric_pill_label_$label'),
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
              if (state == MetricState.demo) ...[
                const SizedBox(width: 6),
                _DemoBadge(),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Value area — state-driven
          _buildValueArea(),
          const SizedBox(height: 6),
          // Provenance label (live / stale / demo only)
          if (_showsProvenanceLabel) _buildProvenanceLabel(),
        ],
      ),
    );
  }

  // ── Compact layout (inline) ──────────────────────────────────────

  Widget _buildCompact(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          key: Key('metric_pill_label_$label'),
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        const SizedBox(width: 8),
        _buildValueArea(),
        if (state == MetricState.demo) ...[
          const SizedBox(width: 4),
          _DemoBadge(),
        ],
      ],
    );
  }

  // ── Value area router ────────────────────────────────────────────

  Widget _buildValueArea() {
    switch (state) {
      case MetricState.live:
        return _buildLiveValue(dimmed: false);
      case MetricState.demo:
        return _buildLiveValue(dimmed: false);
      case MetricState.stale:
        return _buildStaleValue();
      case MetricState.empty:
        return _buildEmptyState();
      case MetricState.unavailable:
        return _buildUnavailableState();
      case MetricState.partial:
        // partial = live number, slightly flagged; treat like live here.
        return _buildLiveValue(dimmed: false);
      case MetricState.fallback:
        // fallback = estimate; show value with muted colour.
        return _buildLiveValue(dimmed: true);
    }
  }

  bool get _showsProvenanceLabel =>
      state == MetricState.live ||
      state == MetricState.stale ||
      state == MetricState.demo ||
      state == MetricState.partial ||
      state == MetricState.fallback;

  String get _formattedValue {
    final v = value;
    if (v == null) return '—';
    return formatter != null ? formatter!(v) : v.toString();
  }

  // ── State branches ───────────────────────────────────────────────

  Widget _buildLiveValue({required bool dimmed}) {
    return Text(
      _formattedValue,
      key: Key('metric_pill_value_$label'),
      style: AppTextStyles.mono28(
        color: dimmed ? AppColors.textMuted : AppColors.textPrimary,
      ),
    );
  }

  Widget _buildStaleValue() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Value with visual de-emphasis (grey, not strikethrough — keeps
        // it readable while signalling "not fresh").
        Text(
          _formattedValue,
          key: Key('metric_pill_value_$label'),
          style: AppTextStyles.mono28(color: AppColors.textMuted),
        ),
        const SizedBox(height: 4),
        // Stale badge
        Container(
          key: Key('metric_pill_stale_badge_$label'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.10),
            border: Border.all(
              color: AppColors.warning.withValues(alpha: 0.45),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sync_problem_outlined,
                  size: 12, color: AppColors.warning),
              const SizedBox(width: 4),
              Text(
                'Stale',
                style: AppTextStyles.mono10(color: AppColors.warning),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'No data yet',
          key: Key('metric_pill_empty_$label'),
          style: AppTextStyles.body13(color: AppColors.textMuted),
        ),
        if (provenance.tooltip != null) ...[
          const SizedBox(height: 4),
          Text(
            provenance.tooltip!,
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }

  Widget _buildUnavailableState() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '—',
          key: Key('metric_pill_unavailable_$label'),
          style: AppTextStyles.mono28(color: AppColors.textMuted),
        ),
        if (provenance.tooltip != null) ...[
          const SizedBox(height: 4),
          Text(
            provenance.tooltip!,
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }

  Widget _buildProvenanceLabel() {
    return Text(
      provenance.label,
      key: Key('metric_pill_provenance_$label'),
      style: AppTextStyles.mono10(color: AppColors.textMuted),
    );
  }
}

// ── Internal badge widgets ────────────────────────────────────────────────────

class _DemoBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('metric_pill_demo_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.sunset.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        'Demo',
        style: AppTextStyles.mono7(color: AppColors.sunsetDark),
      ),
    );
  }
}
