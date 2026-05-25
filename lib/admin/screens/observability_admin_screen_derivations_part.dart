part of 'observability_admin_screen.dart';

// ── Derivations + formatting ─────────────────────────────────────────
//
// Pure derivation + formatting helpers for the AI Metrics screen,
// extracted from observability_admin_screen.dart as a `part` (size-lint
// slim-down, 2026-05-25) so privacy and the shared library scope (imports,
// private types, `_kUseCaseAccents`, `_HeroPill`/`_HeroTone`) are
// preserved. No behaviour change in the move; `_spendForUseCase` is the
// only new helper, added for the use-case filter.

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

/// Spend for a single use case (`query_class`). Sums the cost-telemetry
/// rows for that class only; the whole-page "Use case" filter feeds the
/// hero "AI spend" tile from here.
double _spendForUseCase(ObservabilityEnvelope envelope, String queryClass) {
  var sum = 0.0;
  for (final row in envelope.costTelemetry) {
    if (row.queryClass == queryClass) sum += row.totalUsd;
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
