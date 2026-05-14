// Wave 2 S-1 — Blended wage mix calculator (pure Dart, no I/O).
//
// Origin: debug.md:198-235 (OW-13a + OW-13b). The Wage Authority screen
// renders FOH / BOH / Management role rows. Each row carries an hourly
// rate and a "weighted hours" forecast (how many hours per week we
// expect that role to work). The operator sees a live summary at the
// top of the form that reads:
//
//     Total hourly cost: $282.00 / 16 weighted hours
//     Blended wage mix: $17.62/hr
//
// This file is pure-Dart on purpose. The widget passes saved rows + the
// operator's in-flight draft edits into [BlendedWageInputRow], the
// calculator returns a [BlendedWageSummary], and the widget renders.
// Easy to unit-test with no Flutter machinery.
//
// Authority anchors:
//   * docs/contracts/core_app_architecture.md — wage authority is the
//     model's labor-dollar input (Layer 4 wage source class). Same
//     formula a vendor-per-position adapter would produce when it
//     pushes rows of `wage_role_rows` upstream.
//   * `lib/services/integration/labor_wage_source_class.dart` — the
//     four wage source classes the aggregator consults. This summary is
//     the operator-set `manual_mix` projection.

library;

/// One input row to the blended-wage formula.
///
/// `weightedHours` is the per-week forecast hours for this role, lifted
/// from the most recent locked weekly plan when present, or the
/// operator's manual estimate when no plan has been locked yet.
class BlendedWageInputRow {
  const BlendedWageInputRow({
    required this.laborBucket,
    required this.hourlyRate,
    required this.weightedHours,
  });

  /// `'foh' | 'boh' | 'manager'` — matches the migration CHECK.
  final String laborBucket;
  final double hourlyRate;
  final double weightedHours;
}

/// Per-bucket subtotal that feeds the screen's bucket-section badge.
class BucketBlendedWage {
  const BucketBlendedWage({
    required this.laborBucket,
    required this.totalWeightedHours,
    required this.totalWeightedDollars,
    required this.blendedHourlyRate,
  });

  final String laborBucket;
  final double totalWeightedHours;
  final double totalWeightedDollars;

  /// `null` when [totalWeightedHours] is zero — division-by-zero is a
  /// genuine "no data yet" state, not a numeric error.
  final double? blendedHourlyRate;

  bool get hasRows => totalWeightedHours > 0;
}

/// Whole-screen blended-wage summary card model.
class BlendedWageSummary {
  const BlendedWageSummary({
    required this.totalWeightedHours,
    required this.totalWeightedDollars,
    required this.blendedHourlyRate,
    required this.perBucket,
    required this.rowCount,
  });

  final double totalWeightedHours;
  final double totalWeightedDollars;

  /// `null` when [totalWeightedHours] is zero. The widget renders an
  /// empty-state message instead of a number.
  final double? blendedHourlyRate;

  /// Subtotal per labor bucket, ordered as supplied by the caller. The
  /// widget walks this list to render per-bucket badges.
  final List<BucketBlendedWage> perBucket;

  /// Number of non-zero rows that contributed to the total. The widget
  /// uses this in the "across N roles" copy so the operator can sanity-
  /// check at a glance.
  final int rowCount;

  bool get hasAnyHours => totalWeightedHours > 0;
}

/// Compute the blended-wage summary for [rows].
///
/// Rows with `weightedHours <= 0` or `hourlyRate < 0` are skipped — the
/// operator's intent is "this role is not staffed this week" or "this
/// row is misconfigured", not "treat as zero-dollar coverage". They
/// also do not count toward [BlendedWageSummary.rowCount].
///
/// [bucketOrder] forces a stable order on the per-bucket list (so the
/// widget renders FOH → BOH → Management even when no rows exist for
/// some buckets, which preserves layout stability while the operator
/// types).
BlendedWageSummary computeBlendedWageSummary({
  required Iterable<BlendedWageInputRow> rows,
  required List<String> bucketOrder,
}) {
  final byBucket = <String, _BucketAccumulator>{
    for (final wire in bucketOrder) wire: _BucketAccumulator(wire),
  };
  var totalHours = 0.0;
  var totalDollars = 0.0;
  var rowCount = 0;
  for (final row in rows) {
    if (row.weightedHours <= 0) continue;
    if (row.hourlyRate < 0) continue;
    rowCount += 1;
    final acc = byBucket.putIfAbsent(
      row.laborBucket,
      () => _BucketAccumulator(row.laborBucket),
    );
    acc.hours += row.weightedHours;
    acc.dollars += row.weightedHours * row.hourlyRate;
    totalHours += row.weightedHours;
    totalDollars += row.weightedHours * row.hourlyRate;
  }
  return BlendedWageSummary(
    totalWeightedHours: totalHours,
    totalWeightedDollars: totalDollars,
    blendedHourlyRate: totalHours > 0 ? totalDollars / totalHours : null,
    perBucket: <BucketBlendedWage>[
      for (final wire in bucketOrder)
        byBucket[wire]!.toBucketBlendedWage(),
      // Surface any unexpected bucket wire (e.g. seeded data carrying a
      // legacy value) at the tail so it is visible rather than silently
      // dropped.
      for (final entry in byBucket.entries)
        if (!bucketOrder.contains(entry.key))
          entry.value.toBucketBlendedWage(),
    ],
    rowCount: rowCount,
  );
}

class _BucketAccumulator {
  _BucketAccumulator(this.wire);
  final String wire;
  double hours = 0;
  double dollars = 0;

  BucketBlendedWage toBucketBlendedWage() => BucketBlendedWage(
        laborBucket: wire,
        totalWeightedHours: hours,
        totalWeightedDollars: dollars,
        blendedHourlyRate: hours > 0 ? dollars / hours : null,
      );
}
