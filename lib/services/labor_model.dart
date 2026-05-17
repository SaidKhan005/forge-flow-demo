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

  /// No-signal sentinel returned by [determineLeverGated] when no axis
  /// crossed its firing threshold (the week/shift was on-model). It is
  /// intentionally outside the 16 catalog ids; `LeverCards.lookup`
  /// resolves it to `null` so renderers surface the degraded
  /// "Not yet on-model" / "—" treatment instead of a false leak claim.
  /// 7.58.0a remediation of Primary Driver Contract Finding F-2.
  static const String onModelSentinel = 'on_model';

  /// No-signal sentinel returned by [determineLeverGated] when no axis
  /// crossed its firing threshold (the week/shift was on-model). It is
  /// intentionally outside the 16 catalog ids; `LeverCards.lookup`
  /// resolves it to `null` so renderers surface the degraded
  /// "Not yet on-model" / "—" treatment instead of a false leak claim.
  /// 7.58.0a remediation of Primary Driver Contract Finding F-2.
  static const String onModelSentinel = 'on_model';

  /// No-signal sentinel returned by [determineLeverGated] when no axis
  /// crossed its firing threshold (the week/shift was on-model). It is
  /// intentionally outside the 16 catalog ids; `LeverCards.lookup`
  /// resolves it to `null` so renderers surface the degraded
  /// "Not yet on-model" / "—" treatment instead of a false leak claim.
  /// 7.58.0a remediation of Primary Driver Contract Finding F-2.
  static const String onModelSentinel = 'on_model';

  // ── FOH model hours ───────────────────────────────────────────────────────
  // Jim Taylor Ch. 5: covers ÷ targetCPLH, rounded to the nearest whole hour.
  // Use actualCovers for live/closed-shift analysis.
  // Use forecastCovers for schedule projection.
  static int modelFohHours(int covers, double targetCPLH) {
    if (targetCPLH == 0) return 0;
    return (covers / targetCPLH).round();
  }

  // ── BOH model hours (sales-first) ──────────────────────────────────────────
  // Jim Taylor Ch. 5: forecastSales ÷ targetSPLH, rounded to nearest whole hour.
  // This is the primary BOH formula — BOH staffing is driven by sales volume.
  static int modelBohHoursFromSales(double forecastSales, double targetSPLH) {
    if (targetSPLH == 0) return 0;
    return (forecastSales / targetSPLH).round();
  }

  // ── BOH model hours (derived-sales compatibility) ─────────────────────────
  // Convenience wrapper for surfaces that only have covers + PPA.
  // Derives forecast sales as covers × ppa, then delegates to the
  // sales-first formula.
  static int modelBohHours(int covers, double ppa, double targetSPLH) {
    return modelBohHoursFromSales(covers * ppa, targetSPLH);
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
  // Returns a LeverCardData.id string (see LeverCards in app_defaults.dart).
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
  //   scheduledFohHours / modelFohHours — enables foh_hours_over / foh_hours_under
  //   scheduledBohHours / modelBohHours — enables boh_hours_over / boh_hours_under
  //
  // Two entry points share one candidate engine:
  //   • [determineLever]       — legacy single-source semantics. When no
  //                              axis fires it returns the literal
  //                              `'covers_down'` (Primary Driver Contract
  //                              Decision Logic step 3 / Finding F-2, test
  //                              R10/R6). Never returns [onModelSentinel].
  //   • [determineLeverGated]  — producer-side entry point for any code
  //                              that PERSISTS or renders a primary lever.
  //                              Identical selection, except the empty-
  //                              candidate (on-model) state returns
  //                              [onModelSentinel] instead of the false
  //                              `'covers_down'` overclaim. 7.58.0a.
  static String determineLever({
    required int actualCovers,
    required int forecastCovers,
    required double avgCPLH,
    required double avgPPA,
    required double targetCPLH,
    required double targetPPA,
    double? avgSPLH,
    double? targetSPLH,
    double? avgFohBlendedWage,
    double? targetFohWage,
    double? avgBohBlendedWage,
    double? targetBohWage,
    int? scheduledFohHours,
    int? modelFohHours,
    int? scheduledBohHours,
    int? modelBohHours,
  }) {
    final candidates = _leverCandidates(
      actualCovers: actualCovers,
      forecastCovers: forecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: targetCPLH,
      targetPPA: targetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: targetSPLH,
      avgFohBlendedWage: avgFohBlendedWage,
      targetFohWage: targetFohWage,
      avgBohBlendedWage: avgBohBlendedWage,
      targetBohWage: targetBohWage,
      scheduledFohHours: scheduledFohHours,
      modelFohHours: modelFohHours,
      scheduledBohHours: scheduledBohHours,
      modelBohHours: modelBohHours,
    );
    // Legacy single-source fallback — preserved verbatim (contract R10).
    if (candidates.isEmpty) return 'covers_down';
    return _selectLever(candidates);
  }

  /// On-model-honest variant of [determineLever]. Identical inputs and
  /// identical winner selection, but the empty-candidate state returns
  /// [onModelSentinel] instead of the legacy `'covers_down'` overclaim.
  ///
  /// Every site that PERSISTS a primary lever id (WeekRecord / WeekData /
  /// ShiftRecord / ShiftFact) or renders one on a leak/history surface
  /// MUST call this, so an on-model week is reported as "no driver"
  /// rather than a false red COVERS. Closes Primary Driver Contract
  /// Finding F-2 (7.58.0a). The contract-pinned [determineLever]
  /// keeps its legacy fallback for single-source / R10 callers.
  static String determineLeverGated({
    required int actualCovers,
    required int forecastCovers,
    required double avgCPLH,
    required double avgPPA,
    required double targetCPLH,
    required double targetPPA,
    double? avgSPLH,
    double? targetSPLH,
    double? avgFohBlendedWage,
    double? targetFohWage,
    double? avgBohBlendedWage,
    double? targetBohWage,
    int? scheduledFohHours,
    int? modelFohHours,
    int? scheduledBohHours,
    int? modelBohHours,
  }) {
    final candidates = _leverCandidates(
      actualCovers: actualCovers,
      forecastCovers: forecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: targetCPLH,
      targetPPA: targetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: targetSPLH,
      avgFohBlendedWage: avgFohBlendedWage,
      targetFohWage: targetFohWage,
      avgBohBlendedWage: avgBohBlendedWage,
      targetBohWage: targetBohWage,
      scheduledFohHours: scheduledFohHours,
      modelFohHours: modelFohHours,
      scheduledBohHours: scheduledBohHours,
      modelBohHours: modelBohHours,
    );
    if (candidates.isEmpty) return onModelSentinel;
    return _selectLever(candidates);
  }

  // Priority order for tie-breaking (lower index = higher priority).
  // Volume axes outrank productivity outrank wage outrank hours-flex.
  static const List<String> _priorityOrder = [
    'covers_down', 'covers_up',
    'ppa_down',    'ppa_up',
    'cplh_down',   'cplh_up',
    'splh_down',   'splh_up',
    'foh_wage_down', 'foh_wage_up',
    'boh_wage_down', 'boh_wage_up',
    'foh_hours_over', 'foh_hours_under',
    'boh_hours_over', 'boh_hours_under',
  ];

  // Shared candidate engine for both [determineLever] and
  // [determineLeverGated]. An axis contributes its matched id (up vs
  // down) with weight `|delta|` only when it crosses its threshold; a
  // null optional input silently skips that axis (no fallback, no zero
  // treated as real). The two public entry points differ ONLY in how
  // they treat the empty return.
  static Map<String, double> _leverCandidates({
    required int actualCovers,
    required int forecastCovers,
    required double avgCPLH,
    required double avgPPA,
    required double targetCPLH,
    required double targetPPA,
    double? avgSPLH,
    double? targetSPLH,
    double? avgFohBlendedWage,
    double? targetFohWage,
    double? avgBohBlendedWage,
    double? targetBohWage,
    int? scheduledFohHours,
    int? modelFohHours,
    int? scheduledBohHours,
    int? modelBohHours,
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

    // FOH hours flex lever — schedule vs model ±10%
    if (scheduledFohHours != null && modelFohHours != null && modelFohHours > 0) {
      final fohFlexDelta = (scheduledFohHours - modelFohHours) / modelFohHours;
      if (fohFlexDelta > 0.10) candidates['foh_hours_over'] = fohFlexDelta.abs();
      if (fohFlexDelta < -0.10) candidates['foh_hours_under'] = fohFlexDelta.abs();
    }

    // BOH hours flex lever — schedule vs model ±10%
    if (scheduledBohHours != null && modelBohHours != null && modelBohHours > 0) {
      final bohFlexDelta = (scheduledBohHours - modelBohHours) / modelBohHours;
      if (bohFlexDelta > 0.10) candidates['boh_hours_over'] = bohFlexDelta.abs();
      if (bohFlexDelta < -0.10) candidates['boh_hours_under'] = bohFlexDelta.abs();
    }

    return candidates;
  }

  // Winner selection — assumes a non-empty candidate set. Max `|delta|`
  // wins; ties resolve by [_priorityOrder] (lower index wins).
  static String _selectLever(Map<String, double> candidates) {
    final maxVal = candidates.values.reduce((a, b) => a > b ? a : b);
    final tied = candidates.entries
        .where((e) => e.value == maxVal)
        .map((e) => e.key)
        .toList();

    if (tied.length == 1) return tied.first;

    tied.sort((a, b) =>
        _priorityOrder.indexOf(a).compareTo(_priorityOrder.indexOf(b)));
    return tied.first;
  }

  // ── Per-axis dollar impact attribution ────────────────────────────────────
  // Decomposes the whole-shift / WTD dollar gap into per-axis dollar
  // contributions keyed by lever id. The renderer (7.58.UX.1) consumes the
  // returned map to say "covers down was the $112 piece of this week's $180
  // gap" — mapping the Primary Driver to a concrete dollar share.
  //
  // Cited authority:
  //   docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md
  //     Sub-Slice Family row `.1` (per-driver dollar-impact attribution).
  //     Findings F-3 — producer call sites pass different optional-axis
  //     subsets; this function tolerates the divergence by attributing 0 to
  //     missing axes (sum drops below dollarGap by the missing term, which
  //     is honest about partial inputs rather than synthesizing a fallback).
  //
  // Decomposition — a six-step walk that rotates one variable at a time
  // from baseline (forecast volume + target rates + target wages) to its
  // actual value, accumulating the marginal effect on the dollar gap:
  //
  //   1. covers      : -(modelFohHours_actual - modelFohHours_forecast) × targetFohWage
  //                  + -(modelBohHours_atActualCoversTargetPpa - modelBohHours_forecast) × targetBohWage
  //   2. ppa         : -(modelBohHours_actual - modelBohHours_atActualCoversTargetPpa) × targetBohWage
  //   3. FOH hours   :  (actualFohHours - modelFohHours_forecast) × targetFohWage
  //   4. BOH hours   :  (actualBohHours - modelBohHours_forecast) × targetBohWage
  //   5. FOH wage    :   actualFohHours × (actualFohWage - targetFohWage)
  //   6. BOH wage    :   actualBohHours × (actualBohWage - targetBohWage)
  //
  // The six terms sum to `LaborModel.dollarGap(...)` exactly when all axes
  // are provided (modulo the integer rounding that `modelFohHours` /
  // `modelBohHours` apply). Telescoping verification:
  //   FOH: −Δ_modelFoh × tFw + Δ_actualFoh × tFw + actualFoh × (aFw − tFw)
  //      = (actualFoh − modelFoh_actual) × tFw + actualFoh × (aFw − tFw)
  //      = actualFoh × aFw − modelFoh_actual × tFw  = fohGap
  //   BOH: same shape with PPA folded in.
  //
  // Axis assignment (sign-based; positive = adverse, negative = favorable):
  //   - covers      → covers_down (>0) / covers_up (<0)
  //   - ppa         → ppa_down (>0)    / ppa_up (<0)
  //   - FOH hours   → cplh_down (>0) / cplh_up (<0) when avgCPLH provided;
  //                   else foh_hours_over (>0) / foh_hours_under (<0) when
  //                   scheduledFohHours + modelFohHoursDenominator provided;
  //                   else 0 (axis pair disabled).
  //   - BOH hours   → splh_down / splh_up; else boh_hours_over / under.
  //   - FOH wage    → foh_wage_up (>0) / foh_wage_down (<0); 0 when actual
  //                   blended wage not provided.
  //   - BOH wage    → boh_wage_up / boh_wage_down.
  //
  // Operator narrative the walk supports: covers axis carries the dollars
  // the model shed when covers came in low (the gap your forecast schedule
  // would have left if you hadn't flexed). cplh/splh / hours-flex carry
  // the additional dollars from running schedule different from the
  // forecast baseline (productivity rate or schedule discipline). When
  // schedule flexes perfectly with covers, covers and cplh/hours-flex
  // offset each other and net to zero — exactly the right answer.
  //
  // Sign convention matches `isFavorableLever` polarity throughout.
  //
  // Optional axes whose inputs are null contribute 0 dollars to that axis
  // pair (per F-3 — producers may pass different subsets). When wages are
  // null the function defaults the actual blended wage to the target wage
  // (no premium) and the wage axis returns 0; the hours-vs-baseline term
  // still computes against the target wage in that case so the structural
  // gap is not lost.
  static Map<String, double> attributeDollarImpactByAxis({
    required int actualCovers,
    required int forecastCovers,
    required int actualFohHours,
    required int actualBohHours,
    required double avgPPA,
    required double targetCPLH,
    required double targetSPLH,
    required double targetPPA,
    required double targetFohWage,
    required double targetBohWage,
    // Productivity (cplh / splh) — null skips the axis pair; the FOH/BOH
    // hours-vs-baseline dollars then route to the hours-flex fallback if
    // its inputs are present, otherwise drop to 0.
    double? avgCPLH,
    double? avgSPLH,
    // Wage axes — null defaults actual to target (no premium) and returns
    // 0 for the wage lever pair.
    double? avgFohBlendedWage,
    double? avgBohBlendedWage,
    // Hours-flex axes — used as fallback for the FOH/BOH hours-vs-baseline
    // dollars when the productivity axis is null.
    int? scheduledFohHours,
    int? modelFohHoursDenominator,
    int? scheduledBohHours,
    int? modelBohHoursDenominator,
  }) {
    final result = <String, double>{
      for (final id in const [
        'covers_down', 'covers_up',
        'ppa_down', 'ppa_up',
        'cplh_down', 'cplh_up',
        'splh_down', 'splh_up',
        'foh_wage_down', 'foh_wage_up',
        'boh_wage_down', 'boh_wage_up',
        'foh_hours_over', 'foh_hours_under',
        'boh_hours_over', 'boh_hours_under',
      ])
        id: 0.0,
    };

    // ── Baseline + intermediate model hours ─────────────────────────────
    // The walk rotates one input at a time from baseline (forecast volume,
    // target rates, target wages) to its actual value. Each rotation
    // produces a marginal gap delta credited to one axis.
    final modelFohForecast = modelFohHours(forecastCovers, targetCPLH);
    final modelBohForecast = modelBohHours(forecastCovers, targetPPA, targetSPLH);
    final modelFohActual = modelFohHours(actualCovers, targetCPLH);
    final modelBohActualCoversTargetPpa =
        modelBohHours(actualCovers, targetPPA, targetSPLH);
    final modelBohActual = modelBohHours(actualCovers, avgPPA, targetSPLH);

    // Resolve actual wages — default to target = no premium when null.
    final actualFohWage = avgFohBlendedWage ?? targetFohWage;
    final actualBohWage = avgBohBlendedWage ?? targetBohWage;

    // ── Step 1 — covers axis (model shifts due to volume change) ────────
    // Sign: actualCovers < forecastCovers → modelHours drop → adverse.
    final coversTerm =
        -(modelFohActual - modelFohForecast) * targetFohWage +
            -(modelBohActualCoversTargetPpa - modelBohForecast) *
                targetBohWage;
    if (coversTerm > 0) {
      result['covers_down'] = coversTerm;
    } else if (coversTerm < 0) {
      result['covers_up'] = coversTerm;
    }

    // ── Step 2 — ppa axis (BOH model shifts due to per-cover spend) ─────
    final ppaTerm = -(modelBohActual - modelBohActualCoversTargetPpa) *
        targetBohWage;
    if (ppaTerm > 0) {
      result['ppa_down'] = ppaTerm;
    } else if (ppaTerm < 0) {
      result['ppa_up'] = ppaTerm;
    }

    // ── Step 3 — FOH schedule deviation from forecast baseline ──────────
    // Captures how far actualFohHours sits from the forecast model. When
    // schedule flexes with covers (closed-shift case) the sign here is
    // opposite to step 1's contribution and they offset cleanly.
    final fohHoursTerm =
        (actualFohHours - modelFohForecast) * targetFohWage;
    if (avgCPLH != null) {
      if (fohHoursTerm > 0) {
        result['cplh_down'] = fohHoursTerm;
      } else if (fohHoursTerm < 0) {
        result['cplh_up'] = fohHoursTerm;
      }
    } else if (scheduledFohHours != null && modelFohHoursDenominator != null) {
      if (fohHoursTerm > 0) {
        result['foh_hours_over'] = fohHoursTerm;
      } else if (fohHoursTerm < 0) {
        result['foh_hours_under'] = fohHoursTerm;
      }
    }

    // ── Step 4 — BOH schedule deviation from forecast baseline ──────────
    final bohHoursTerm =
        (actualBohHours - modelBohForecast) * targetBohWage;
    if (avgSPLH != null) {
      if (bohHoursTerm > 0) {
        result['splh_down'] = bohHoursTerm;
      } else if (bohHoursTerm < 0) {
        result['splh_up'] = bohHoursTerm;
      }
    } else if (scheduledBohHours != null && modelBohHoursDenominator != null) {
      if (bohHoursTerm > 0) {
        result['boh_hours_over'] = bohHoursTerm;
      } else if (bohHoursTerm < 0) {
        result['boh_hours_under'] = bohHoursTerm;
      }
    }

    // ── Step 5 — FOH wage premium on actual hours ───────────────────────
    if (avgFohBlendedWage != null) {
      final fohWageTerm = actualFohHours * (actualFohWage - targetFohWage);
      if (fohWageTerm > 0) {
        result['foh_wage_up'] = fohWageTerm;
      } else if (fohWageTerm < 0) {
        result['foh_wage_down'] = fohWageTerm;
      }
    }

    // ── Step 6 — BOH wage premium on actual hours ───────────────────────
    if (avgBohBlendedWage != null) {
      final bohWageTerm = actualBohHours * (actualBohWage - targetBohWage);
      if (bohWageTerm > 0) {
        result['boh_wage_up'] = bohWageTerm;
      } else if (bohWageTerm < 0) {
        result['boh_wage_down'] = bohWageTerm;
      }
    }

    return result;
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
      case 'foh_hours_under':
      case 'boh_hours_under':
        return true;
      default:
        return false;
    }
  }
}
