// ─── Labor Model — Single Formula Source ─────────────────────────────────────
// Pure calculation library. No app imports — all config values are passed
// explicitly. This design:
//   • Avoids circular dependencies with the data layer
//   • Makes every formula independently testable
//   • Supports future multi-restaurant configurations
//
// Jim Taylor references:
//   Ch. 5  — Cover-per-labor-hour (CPLH) and schedule construction
//   Ch. 9  — Theoretical labor % derivation from targets and wages
//   Ch. 10 — Variance: model hours vs actual, dollar gap computation

class LaborModel {
  LaborModel._();

  // ── FOH model hours ───────────────────────────────────────────────────────
  // Jim Taylor Ch. 5: covers ÷ targetCPLH, rounded to the nearest whole hour.
  // Use actualCovers for live/closed-shift analysis.
  // Use forecastCovers for schedule projection.
  static int modelFohHours(int covers, double targetCPLH) {
    if (targetCPLH == 0) return 0;
    return (covers / targetCPLH).round();
  }

  // ── BOH model hours ───────────────────────────────────────────────────────
  // Jim Taylor Ch. 5: (covers × ppa) ÷ targetSPLH = sales ÷ targetSPLH
  // Pass avgPPA for closed-shift/WTD analysis; pass targetPPA for projection.
  static int modelBohHours(int covers, double ppa, double targetSPLH) {
    if (targetSPLH == 0) return 0;
    return ((covers * ppa) / targetSPLH).round();
  }

  // ── Theoretical labor % ───────────────────────────────────────────────────
  // Jim Taylor Ch. 9 derivation from target rates and wages.
  //
  //   FOH labor % = fohWage / (targetCPLH × targetPPA) × 100
  //   BOH labor % = bohWage / targetSPLH × 100
  //
  // This is a property of the targets and wages — not of volume.
  // Result is independent of cover count (rounding artifacts aside).
  static double theoreticalLaborPct(
    double targetCPLH,
    double targetSPLH,
    double targetPPA,
    double fohWage,
    double bohWage,
  ) {
    if (targetCPLH == 0 || targetPPA == 0 || targetSPLH == 0) return 0;
    final fohPct = fohWage / (targetCPLH * targetPPA) * 100;
    final bohPct = bohWage / targetSPLH * 100;
    return fohPct + bohPct;
  }

  // ── Dollar gap ────────────────────────────────────────────────────────────
  // Jim Taylor Ch. 10: actual labor cost vs theoretical labor cost for
  // the actual volume worked.
  //
  //   Positive = over model (unfavorable)
  //   Negative = under model (favorable)
  //
  // Pass avgPPA (actual PPA) for WTD/closed-shift analysis.
  static double dollarGap(
    double actualLaborDollar,
    int covers,
    double avgPPA, {
    required double targetCPLH,
    required double targetSPLH,
    required double fohWage,
    required double bohWage,
  }) {
    final theoFoh = modelFohHours(covers, targetCPLH) * fohWage;
    final theoBoh = modelBohHours(covers, avgPPA, targetSPLH) * bohWage;
    return actualLaborDollar - (theoFoh + theoBoh);
  }

  // ── Primary lever detection ───────────────────────────────────────────────
  // Identifies the strongest signal driver from WTD actuals.
  // Returns a LeverCardData.id string (see LeverCards in legacy_fixture_data.dart).
  //
  // Thresholds (% deviation from target before a lever fires):
  //   Covers: ±2%   CPLH/SPLH: ±5%   PPA/wage: ±3%
  // The largest absolute deviation wins.
  // Tie-break priority: covers > ppa > cplh > splh > foh_wage > boh_wage.
  //
  // Optional parameters (null = that lever family is skipped):
  //   avgSPLH / targetSPLH   — enables splh_up / splh_down
  //   avgFohBlendedWage / targetFohWage — enables foh_wage_up / foh_wage_down
  //   avgBohBlendedWage / targetBohWage — enables boh_wage_up / boh_wage_down
  static String determineLever({
    required int actualCovers,
    required int forecastCovers,
    required double avgCPLH,
    required double avgPPA,
    required double targetCPLH,
    required double targetPPA,
    // SPLH lever (BOH only)
    double? avgSPLH,
    double? targetSPLH,
    // FOH wage lever
    double? avgFohBlendedWage,
    double? targetFohWage,
    // BOH wage lever
    double? avgBohBlendedWage,
    double? targetBohWage,
  }) {
    final coversDelta = forecastCovers > 0
        ? (actualCovers - forecastCovers) / forecastCovers
        : 0.0;
    final cplhDelta = targetCPLH > 0
        ? (avgCPLH - targetCPLH) / targetCPLH
        : 0.0;
    final ppaDelta = targetPPA > 0
        ? (avgPPA - targetPPA) / targetPPA
        : 0.0;

    // Priority order for tie-breaking (lower index = higher priority)
    const priorityOrder = [
      'covers_down', 'covers_up',
      'ppa_down',    'ppa_up',
      'cplh_down',   'cplh_up',
      'splh_down',   'splh_up',
      'foh_wage_down', 'foh_wage_up',
      'boh_wage_down', 'boh_wage_up',
    ];

    final candidates = <String, double>{
      if (coversDelta < -0.02) 'covers_down': coversDelta.abs(),
      if (coversDelta > 0.02)  'covers_up':   coversDelta.abs(),
      if (ppaDelta    < -0.03) 'ppa_down':    ppaDelta.abs(),
      if (ppaDelta    > 0.03)  'ppa_up':      ppaDelta.abs(),
      if (cplhDelta   < -0.05) 'cplh_down':   cplhDelta.abs(),
      if (cplhDelta   > 0.05)  'cplh_up':     cplhDelta.abs(),
    };

    // SPLH lever
    if (avgSPLH != null && targetSPLH != null && targetSPLH > 0) {
      final splhDelta = (avgSPLH - targetSPLH) / targetSPLH;
      if (splhDelta < -0.05) candidates['splh_down'] = splhDelta.abs();
      if (splhDelta > 0.05)  candidates['splh_up']   = splhDelta.abs();
    }

    // FOH wage lever
    if (avgFohBlendedWage != null && targetFohWage != null && targetFohWage > 0) {
      final fohWageDelta = (avgFohBlendedWage - targetFohWage) / targetFohWage;
      if (fohWageDelta < -0.03) candidates['foh_wage_down'] = fohWageDelta.abs();
      if (fohWageDelta > 0.03)  candidates['foh_wage_up']   = fohWageDelta.abs();
    }

    // BOH wage lever
    if (avgBohBlendedWage != null && targetBohWage != null && targetBohWage > 0) {
      final bohWageDelta = (avgBohBlendedWage - targetBohWage) / targetBohWage;
      if (bohWageDelta < -0.03) candidates['boh_wage_down'] = bohWageDelta.abs();
      if (bohWageDelta > 0.03)  candidates['boh_wage_up']   = bohWageDelta.abs();
    }

    if (candidates.isEmpty) return 'covers_down';

    // Find the maximum deviation; resolve ties by priority order
    final maxVal = candidates.values.reduce((a, b) => a > b ? a : b);
    final tied = candidates.entries
        .where((e) => e.value == maxVal)
        .map((e) => e.key)
        .toList();

    if (tied.length == 1) return tied.first;

    // Tie-break: return the candidate that appears earliest in priorityOrder
    tied.sort((a, b) =>
        priorityOrder.indexOf(a).compareTo(priorityOrder.indexOf(b)));
    return tied.first;
  }

  // ── Favorable lever classification ────────────────────────────────────────
  // Returns true when the lever id represents a favorable (under-model) outcome.
  static bool isFavorableLever(String leverId) {
    switch (leverId) {
      case 'covers_up':
      case 'ppa_up':
      case 'cplh_up':
      case 'splh_up':
      case 'foh_wage_down':
      case 'boh_wage_down':
        return true;
      default:
        return false;
    }
  }
}
