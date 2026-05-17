// Phase 7.55e.5 — Deterministic mock POS/labor integration replay seed.
//
// Generates realistic historical and current-week operational data through
// the same model path that live Phase 8 adapters will use:
//   mock POS/labor replay -> canonical app models -> SQLite operational tables.
//
// Replaces direct DemoData fixture copies in SQLite bootstrap.
// DemoData still exists for static preview paths (7.55e.6 handles cleanup).
//
// Phase 7.55f.4 — Parameterized by scenario business date.
// generateForDate(isoDate) produces coherent output for any date.
// The default scenario (2026-03-27) is preserved for backward compat.
//
// All variation is deterministic — no random generators.

import '../models/shift_record.dart';
import '../models/week_record.dart';
import '../services/labor_model.dart';

/// The service period the demo "live" shift is in, derived from a
/// restaurant-local clock at seed time (NOT hardcoded to dinner).
///
/// QA fix (device-reproduced 2026-05-16, Sat ~09:25): the seed used to
/// hardcode `openShiftDaypart='dinner'` with a fabricated mid-service
/// snapshot (`0.63` / `7:45 PM` / `3h 15m`) that never consulted the
/// clock, so Dinner always showed "live" numbers even before it opened.
/// This value type carries the *clock-derived* answer:
///
/// * [openDaypart] — the single period currently IN PROGRESS at the
///   restaurant-local now, or `null` when no period is in progress
///   (e.g. 09:25, before Lunch opens → no open shift at all).
/// * [openProgressFraction] / [openTimeLabel] /
///   [openServiceElapsedLabel] — the live progress of that period,
///   computed from `now` vs the period window. `null` when there is no
///   open period (honest — no fabricated mid-service state).
/// * [currentDayClosedPeriods] — periods on the current business day
///   that already ended (→ seeded `closed` with actuals; closed truth
///   is not rewritten). Everything else on the current day that is not
///   the open period is `projected` (forecast-only, honest).
///
/// Determinism (file-header no-randomness invariant): the *selection* is
/// the only clock-relative input and it is supplied through an
/// injectable anchor (see `SqliteDatabase.debugColdBootNowOverride`);
/// no seeded VALUE depends on `DateTime.now()`.
class OpenPeriodResolution {
  final String? openDaypart;
  final double? openProgressFraction;
  final String? openTimeLabel;
  final String? openServiceElapsedLabel;
  final List<String> currentDayClosedPeriods;

  const OpenPeriodResolution({
    required this.openDaypart,
    required this.openProgressFraction,
    required this.openTimeLabel,
    required this.openServiceElapsedLabel,
    required this.currentDayClosedPeriods,
  });

  bool get hasOpenPeriod => openDaypart != null;
}

/// Describes the mock replay scenario for a given business date.
class MockReplayScenario {
  final String currentBusinessDate; // ISO date, e.g. '2026-03-27'
  final String currentWeekId;       // e.g. '2026-W13'
  final String openShiftDayLabel;   // e.g. 'Fri' (the current business day)

  /// The clock-derived open service period, or `null` when NO period is
  /// in progress at seed time (honest — no open shift, upcoming periods
  /// are `projected`). Was a non-null hardcoded `'dinner'`; QA fix.
  final String? openShiftDaypart;

  /// Live progress of the open period (fraction / wall-clock label /
  /// elapsed-into-service label), all `null` when [openShiftDaypart] is
  /// `null`. Replaces the fixed `0.63` / `7:45 PM` / `3h 15m` fabrication.
  final double? openProgressFraction;
  final String? openTimeLabel;
  final String? openServiceElapsedLabel;

  /// Periods on [openShiftDayLabel] that already ended at seed time and
  /// are seeded `closed` (with actuals). Defaults to `['lunch']` for the
  /// back-compat (no clock injected) path so the static generator output
  /// and unit-test scenario stay byte-identical.
  final List<String> currentDayClosedPeriods;

  const MockReplayScenario({
    required this.currentBusinessDate,
    required this.currentWeekId,
    required this.openShiftDayLabel,
    required this.openShiftDaypart,
    this.openProgressFraction,
    this.openTimeLabel,
    this.openServiceElapsedLabel,
    this.currentDayClosedPeriods = const ['lunch'],
  });
}

/// Output of the mock integration replay generator.
class MockReplayOutput {
  final List<ShiftRecord> historicalClosedShifts;
  final List<ShiftRecord> currentWeekShifts;
  final List<WeekRecord> weekRecords;
  final MockReplayScenario scenario;

  const MockReplayOutput({
    required this.historicalClosedShifts,
    required this.currentWeekShifts,
    required this.weekRecords,
    required this.scenario,
  });
}

/// One service period's deterministic locked target band, exposed by
/// [MockIntegrationReplaySeed.demoDaypartTargetBand] so the demo cycle
/// seeder can stamp differentiated per-period rows without reaching into
/// the seed's private maps.
class DemoDaypartTargetBand {
  final double targetCPLH;
  final double targetSPLH;
  final double targetPPA;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;

  const DemoDaypartTargetBand({
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
  });
}

/// Deterministic mock POS/labor replay generator.
///
/// Produces operationally coherent shift and week records that behave like
/// Phase 8 live POS/labor adapter output. All derived metrics use
/// [LaborModel] as the single formula source.
///
/// No randomness — all variation is deterministic from week/day indices.
class MockIntegrationReplaySeed {
  MockIntegrationReplaySeed._();

  /// Source system identifier for records generated by this replay.
  static const String sourceSystem = 'mock_pos_labor_replay';

  /// Per-Daypart V1 (Slice 1, Gap 22) — deterministic timing-profile id
  /// used by the demo seeder so closed shifts carry a
  /// `business_timing_profile_id` + `business_timing_profile_version_id`
  /// + `service_period_key` that round-trip through the standard read
  /// path. Production live writes resolve this from
  /// `restaurant_timing_configs` via the BusinessTimingProfileResolver;
  /// the demo deterministic id stays stable across runs.
  static const String demoBusinessTimingProfileId =
      'demo_business_timing_profile_v1';

  /// Per-Daypart V1 (Slice 1) — per-period locked target stamps the
  /// demo seeder writes onto closed shifts so the History grader and
  /// per-period analytics consumers see realistic per-period bands.
  /// Values mirror the demo cycle's intended per-period output (the
  /// recommendation engine would produce these from the seeded
  /// candidate cohort; the seeder mirrors them directly so reseed runs
  /// are deterministic).
  static const Map<String, double> _daypartTargetCPLH = {
    'lunch': 4.40,
    'dinner': 4.80,
    'late_night': 3.90,
  };
  static const Map<String, double> _daypartTargetSPLH = {
    'lunch': 165.0,
    'dinner': 200.0,
    'late_night': 150.0,
  };
  static const Map<String, double> _daypartTargetPPA = {
    'lunch': 40.50,
    'dinner': 43.00,
    'late_night': 38.50,
  };
  static const Map<String, double> _daypartOpzFloor = {
    'lunch': 4.00,
    'dinner': 4.30,
    'late_night': 3.50,
  };
  static const Map<String, double> _daypartOpzCeiling = {
    'lunch': 5.00,
    'dinner': 5.40,
    'late_night': 4.40,
  };

  /// Service-period ids the demo scenario is built around, in display
  /// order. These are the same keys used by the demo timing config's
  /// `service_period_definitions_json` and by [demoDaypartTargetBand].
  static const List<String> demoServicePeriodIds = [
    'lunch',
    'dinner',
    'late_night',
  ];

  /// Per-Daypart V1 demo fidelity — the deterministic per-period locked
  /// target band the demo seeder stamps onto the demo `TargetCycle`'s
  /// per-period rows when the recommendation cohort yields no
  /// per-period stats for [periodId]. Returns `null` for an unknown
  /// period id (Design Rule 2 — absent means unavailable, never a `0`
  /// sentinel; the caller decides the fallback). The five values are
  /// the same constants already stamped onto demo closed shifts so the
  /// cycle and the history grader agree.
  static DemoDaypartTargetBand? demoDaypartTargetBand(String periodId) {
    final cplh = _daypartTargetCPLH[periodId];
    if (cplh == null) return null;
    return DemoDaypartTargetBand(
      targetCPLH: cplh,
      targetSPLH: _daypartTargetSPLH[periodId] ?? _targetSPLH,
      targetPPA: _daypartTargetPPA[periodId] ?? _targetPPA,
      opzFloorCPLH: _daypartOpzFloor[periodId]!,
      opzCeilingCPLH: _daypartOpzCeiling[periodId]!,
    );
  }

  /// Default mock replay business date (Friday dinner scenario).
  static const String defaultBusinessDate = '2026-03-27';

  /// Current week for the default scenario (backward compat).
  static const String currentWeekId = '2026-W13';

  /// Number of closed historical weeks generated before the current
  /// week. Demo-data Slice B (§2d): raised 8 → 12 so Variance/History
  /// show ≥70 days of non-flat week-to-week deltas with a seasonal
  /// trend and a soft week. The week-level variance is now derived
  /// functionally from the week index (see [_weekAmp] / [_weekVolume])
  /// instead of fixed 8-element bands, so any week count is safe.
  static const int historicalWeekCount = 12;

  /// Historical weekIds for the default scenario, newest first.
  /// Computed from [defaultBusinessDate] through the same week-id math
  /// the generator uses so it can never drift from [historicalWeekCount]
  /// (was a hand-typed 8-element const; Slice B made it 12 + derived).
  static final List<String> historicalWeekIds = _historicalWeekIdsFor(
    defaultBusinessDate,
  );

  static List<String> _historicalWeekIdsFor(String isoBusinessDate) {
    final parts = isoBusinessDate.split('-');
    final dt = DateTime(
        int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    final currentMonday =
        DateTime(dt.year, dt.month, dt.day - (dt.weekday - 1));
    // Newest first: i=1 is the week immediately before the current week.
    return [
      for (int i = 1; i <= historicalWeekCount; i++)
        _weekIdFromDate(DateTime(currentMonday.year, currentMonday.month,
            currentMonday.day - 7 * i)),
    ];
  }

  // ── Target standards (from MeridianConfig / BaselineData) ───────────────
  static const double _targetCPLH = 4.58;
  static const double _targetSPLH = 180.0;
  static const double _targetPPA = 41.50;
  static const double _fohWage = 16.50;
  static const double _bohWage = 21.35;
  static const double _theoreticalLaborPct = 20.48;

  // ── Operating pattern: 16 shifts per week ───────────────────────────────
  // Mon–Thu: lunch + dinner. Fri: lunch + dinner + late_night.
  // Sat: lunch + dinner + late_night. Sun: lunch + dinner.
  //
  // QA fix (Change B, device-reproduced 2026-05-16): weekends now serve
  // a Lunch (weekend lunch/brunch) like a real restaurant. Previously
  // Sat/Sun had NO lunch slot, so a Saturday's only seeded actuals were
  // the one open-Dinner row and Whole-Day collapsed to ≡ Dinner. The
  // weekend lunch covers flow through the SAME deterministic
  // per-location variance + cycle/locked-plan machinery as weekday
  // lunch (the 'lunch' per-period band already exists), so two reseeds
  // stay byte-identical and whole-day = cover-weighted Σ of periods.
  static const List<(String, String)> weekSlots = [
    ('Mon', 'lunch'), ('Mon', 'dinner'),
    ('Tue', 'lunch'), ('Tue', 'dinner'),
    ('Wed', 'lunch'), ('Wed', 'dinner'),
    ('Thu', 'lunch'), ('Thu', 'dinner'),
    ('Fri', 'lunch'), ('Fri', 'dinner'), ('Fri', 'late_night'),
    ('Sat', 'lunch'), ('Sat', 'dinner'), ('Sat', 'late_night'),
    ('Sun', 'lunch'), ('Sun', 'dinner'),
  ];

  // ── Day-of-week base cover distribution (weekly sum = 1200) ─────────────
  // Monday slowest, Saturday dinner strongest, Sunday soft.
  static const Map<String, int> _dayBaseCovers = {
    'Mon': 140, 'Tue': 150, 'Wed': 160, 'Thu': 190,
    'Fri': 220, 'Sat': 230, 'Sun': 110,
  };

  // ── Daypart split ratios per day of week ────────────────────────────────
  static const Map<String, Map<String, double>> _daypartRatios = {
    'Mon': {'lunch': 0.45, 'dinner': 0.55},
    'Tue': {'lunch': 0.45, 'dinner': 0.55},
    'Wed': {'lunch': 0.45, 'dinner': 0.55},
    'Thu': {'lunch': 0.45, 'dinner': 0.55},
    'Fri': {'lunch': 0.45, 'dinner': 0.40, 'late_night': 0.15},
    // QA fix (Change B): Saturday gets a strong brunch alongside its
    // peak dinner; Sunday mirrors the weekday lunch/dinner split (soft
    // day, no late_night). Each map sums to 1.0 so the day's
    // `_dayBaseCovers` total is fully partitioned (pool consistency).
    'Sat': {'lunch': 0.30, 'dinner': 0.55, 'late_night': 0.15},
    'Sun': {'lunch': 0.45, 'dinner': 0.55},
  };

  // ── Per-period base productivity (= the locked per-period targets) ──────
  // Demo-data Slice B (§2a/§2b): the closed-shift generator builds
  // actuals AROUND each period's own target and judges the per-shift
  // primary lever against that SAME per-period target. This mirrors
  // production `ShiftFactBuilder.fromClosedShiftInput`, which feeds the
  // per-period target snapshot (not a whole-day pooled rate) into
  // `LaborModel.determineLever`. Reusing `_daypartTargetCPLH/SPLH/PPA`
  // as the base keeps the recommendation cohort, the locked per-period
  // cycle, and the History grader mutually consistent — and makes
  // `recommendation.perDaypartStats` come back materially differentiated
  // (lunch 4.40 / dinner 4.80 / late_night 3.90 CPLH, etc.) instead of
  // the old flat ≈4.58 every period.
  static double _basePeriodCPLH(String daypart) =>
      _daypartTargetCPLH[daypart] ?? _targetCPLH;
  static double _basePeriodSPLH(String daypart) =>
      _daypartTargetSPLH[daypart] ?? _targetSPLH;
  static double _basePeriodPPA(String daypart) =>
      _daypartTargetPPA[daypart] ?? _targetPPA;

  // ── Per-(day,period) driver intent — the "all covers covers covers" fix ─
  // Demo-data Slice B (§2a): each weekly slot deterministically owns ONE
  // driver axis so the closed cohort spans 8 lever families (13 distinct
  // lever ids) with `covers_down` on a single slot (Sun dinner) ≈ 7% of
  // the cohort — never the >50% degenerate mass it was. The mapping is
  // fixed per (day, period) so the leak/benchmark recurrence Learn needs
  // (§2e, Slice D) is already engineered in: e.g. Fri dinner is always
  // `ppa_down`, Tue lunch always `ppa_up`. Index aligns 1:1 with
  // [weekSlots].
  //
  // Each entry is (axis, sign): axis ∈ {covers, ppa, cplh, splh,
  // fohWage, bohWage, fohHours, bohHours}; sign +1 = the "up/over"
  // lever, -1 = the "down/under" lever.
  //
  // QA fix (Change B): two weekend-lunch slots added (indices 11, 14).
  // Their axes are NOT `covers,-1` so Sun dinner (index 15) stays the
  // SINGLE `covers_down` slot (≈1/16 of the cohort) — the §2a
  // anti-degeneracy invariant is preserved. All other indices shift to
  // stay 1:1 with [weekSlots].
  static const List<(String, int)> _slotDriverIntent = [
    ('cplh', -1), //  0 Mon lunch       → cplh_down
    ('bohHours', 1), //  1 Mon dinner    → boh_hours_over
    ('ppa', 1), //  2 Tue lunch         → ppa_up      (Tue-lunch benchmark)
    ('splh', 1), //  3 Tue dinner       → splh_up
    ('fohWage', 1), //  4 Wed lunch     → foh_wage_up
    ('cplh', 1), //  5 Wed dinner       → cplh_up
    ('bohWage', 1), //  6 Thu lunch     → boh_wage_up
    ('covers', 1), //  7 Thu dinner     → covers_up
    ('splh', -1), //  8 Fri lunch       → splh_down
    ('ppa', -1), //  9 Fri dinner       → ppa_down    (Fri-dinner leak)
    ('covers', 1), // 10 Fri late_night → covers_up
    ('ppa', 1), // 11 Sat lunch         → ppa_up      (weekend brunch)
    ('fohHours', 1), // 12 Sat dinner   → foh_hours_over
    ('splh', -1), // 13 Sat late_night  → splh_down   (late_night noisiest)
    ('splh', 1), // 14 Sun lunch        → splh_up     (weekend brunch)
    ('covers', -1), // 15 Sun dinner    → covers_down (only covers_down slot)
  ];

  // ── Per-WEEK dominant driver layer (Variance/History honesty fix) ──────
  // Demo-data follow-up (Variance → History): the per-(day,period)
  // [_slotDriverIntent] above gives each *shift* a genuine one-axis
  // driver, but summed across the 16 shifts in a week those per-slot
  // tilts dilute to <~1% week-level deviation on every axis, so the
  // week aggregate never crosses any `determineLever` threshold and
  // every historical week falls to the empty-candidate `covers_down`
  // fallback. The Variance → History tab therefore showed the SAME
  // washed-out driver for all 12 weeks.
  //
  // Fix: add a small, uniform, week-wide tilt on ONE assigned axis per
  // historical week, applied to EVERY closed shift of that week, so the
  // WEEK AGGREGATE genuinely crosses that axis's threshold and that
  // axis is the dominant week-level deviation — while the tilt stays
  // strictly smaller than every per-shift owned-axis magnitude
  // ([_intentBaseMag]) so each shift's own per-slot driver still wins
  // per shift (per-shift pedagogy / `demo_slice_b_driver_variance_test`
  // preserved unchanged).
  //
  // This layer is ADDITIVE to [_slotDriverIntent], NOT a replacement:
  // per-shift levers remain engine-derived against the per-period
  // target; the week tilt only nudges the WEEK AGGREGATE. Honesty is
  // structural — the tilt is applied to the STORED shift inputs and the
  // week `primaryLeverId` is re-derived by `_deriveWeekRecord` via
  // `LaborModel.determineLever` on the real aggregate (no hardcoded
  // lever; the round-trip test proves the engine reproduces it).
  //
  // [_weekDriverIntent] — length [historicalWeekCount] (12), indexed by
  // historical week index (0 = OLDEST … 11 = NEWEST; the newest weeks
  // render at the TOP of the History tab). Each entry `(axis, sign)`;
  // sign +1 = the up/over lever, -1 = the down/under lever. The 12
  // rate/volume lever families (covers±, ppa±, cplh±, splh±, fohWage±,
  // bohWage±) are each used EXACTLY ONCE so the History tab demonstrates
  // the full badge set. fohHours/bohHours are deliberately EXCLUDED: an
  // hours-flex week tilt large enough to clear its 10% threshold would
  // exceed the 0.07 per-shift wage magnitude and flip per-shift wage
  // levers — hours-flex stays a shift-level-only driver (still visible
  // on the Shift screen via [_slotDriverIntent] indices 1 & 12).
  //
  // Index → lever mapping (oldest → newest). The newest 6 (indices
  // 6–11, shown top-of-History) are intentionally spread so no two
  // adjacent top rows share a lever family:
  //   0  2025-W53  (covers,-1)  covers_down
  //   1  2026-W02  (cplh,  +1)  cplh_up
  //   2  2026-W03  (ppa,   -1)  ppa_down
  //   3  2026-W04  (splh,  +1)  splh_up
  //   4  2026-W05  (bohWage,-1) boh_wage_down
  //   5  2026-W06  (fohWage,+1) foh_wage_up
  //   6  2026-W07  (ppa,   +1)  ppa_up
  //   7  2026-W08  (covers,+1)  covers_up
  //   8  2026-W09  (splh,  -1)  splh_down
  //   9  2026-W10  (fohWage,-1) foh_wage_down
  //   10 2026-W11  (cplh,  -1)  cplh_down
  //   11 2026-W12  (bohWage,+1) boh_wage_up
  static const List<(String, int)> _weekDriverIntent = [
    ('covers', -1), //  0 oldest  → covers_down
    ('cplh', 1), //  1            → cplh_up
    ('ppa', -1), //  2            → ppa_down
    ('splh', 1), //  3            → splh_up
    ('bohWage', -1), //  4        → boh_wage_down
    ('fohWage', 1), //  5         → foh_wage_up
    ('ppa', 1), //  6             → ppa_up
    ('covers', 1), //  7          → covers_up
    ('splh', -1), //  8           → splh_down
    ('fohWage', -1), //  9        → foh_wage_down
    ('cplh', -1), // 10           → cplh_down
    ('bohWage', 1), // 11 newest  → boh_wage_up
  ];

  // Absolute week-wide tilt fraction per axis. Each MUST (a) clear the
  // axis's week threshold with a safe margin AFTER realistic week
  // aggregation against the POOLED targets (_targetCPLH 4.58 / _targetSPLH
  // 180 / _targetPPA 41.50 / _fohWage 16.50 / _bohWage 21.35 — note the
  // per-period bases differ from these, so a slot tilt does not map 1:1
  // to the week deviation; these were TUNED empirically against the
  // aggregate so every week's `determineLever` returns the assigned
  // lever), and (b) stay strictly LESS than the smallest per-shift owned
  // magnitude that could be flipped — every value here is ≤ 0.055, well
  // below the wage owned mag 0.07 (the smallest in [_intentBaseMag]),
  // ppa 0.085, covers 0.10, cplh/splh 0.12 — so the per-slot owned axis
  // still dominates per shift and per-shift levers are preserved.
  //
  // Tuning record: cplh/splh per-period bases (4.40/4.80/3.90 and
  // 165/200/150) differ from the pooled targets (4.58 / 180) and
  // integer-hour rounding in `modelFohHours`/`modelBohHoursFromSales`
  // dilutes the rate tilt at the week aggregate (~0.89×), so cplh/splh
  // need a slightly larger tilt than the rate-threshold suggests to
  // clear 5% with safe margin at the aggregate. 0.058/0.062 were the
  // smallest values that made every week's `determineLever` return the
  // assigned lever while still leaving every per-shift owned axis
  // (min 0.07) strictly dominant — `demo_slice_b_driver_variance_test`
  // passes unchanged (8 families, covers_down share ≈ 0.083, Fri
  // dinner ppa_down, Tue lunch ppa_up all preserved).
  static const Map<String, double> _weekDriverMag = {
    'covers': 0.040, // week thr 2%
    'ppa': 0.045, // week thr 3%
    'cplh': 0.058, // week thr 5%
    'splh': 0.062, // week thr 5%
    'fohWage': 0.045, // week thr 3%
    'bohWage': 0.045, // week thr 3%
  };

  // Base intent magnitude per axis — sized to clear each axis's
  // `determineLever` threshold (covers 2%, ppa/wage 3%, cplh/splh 5%,
  // hours-flex 10%) with margin even at the most negative week
  // amplitude × period volatility (worst-case checked: every axis still
  // clears its threshold). All other axes are held EXACTLY on the
  // period target on a non-owning slot, so the owned axis is the only
  // candidate and `determineLever` returns it deterministically.
  static const Map<String, double> _intentBaseMag = {
    'covers': 0.10, // thr 2%
    'ppa': 0.085, // thr 3%
    'cplh': 0.12, // thr 5%
    'splh': 0.12, // thr 5%
    'fohWage': 0.07, // thr 3%
    'bohWage': 0.07, // thr 3%
    'fohHours': 0.19, // thr 10%
    'bohHours': 0.19, // thr 10%
  };

  // Per-period volatility multiplier (§2d: "lunch flatter, dinner
  // volatile, late_night noisiest"). Scales the week-amplitude breathing
  // applied to a slot's owned axis so per-period History grades differ
  // in spread, not just level.
  static const Map<String, double> _periodVolatility = {
    'lunch': 0.7,
    'dinner': 1.0,
    'late_night': 1.4,
  };

  // ── Per-shift realism variance (Slice SA) ──────────────────────────────
  // Before Slice SA every NON-owned rate axis on a closed shift was
  // pinned to the EXACT per-period target, so within a daypart all
  // non-driver shifts had byte-identical CPLH/SPLH/PPA. The demo cohort
  // therefore had ~zero per-shift dispersion (lunch/dinner ≈86%, late
  // night 100% identical CPLH) and the benchmark card read a degenerate
  // SPIKE as "RANGE UNCERTAIN" — an OPZ is a *range*, not a point.
  //
  // Slice SA layers a deterministic, seeded, CORRELATED per-shift
  // realism profile onto the NON-owned rate axes only, so a true range
  // exists while every test invariant is preserved:
  //
  //  * Determinism — pure function of (weekIndex, period-membership
  //    index); NO RNG, NO DateTime.now(). Two reseeds stay byte-stable
  //    (file-header no-randomness invariant; `demo_slice_b` determinism
  //    tests unchanged).
  //  * The owned axis is NEVER touched by the profile (it keeps its
  //    full per-slot driver `dev`), and every profile offset is
  //    STRICTLY below its axis's `determineLever` firing threshold
  //    (cplh/splh < 5%, ppa < 3%), so a perturbed non-owned axis can
  //    never become a `determineLever` candidate — per-shift levers,
  //    the 8-family span, the covers_down share, and the recurring
  //    Fri-dinner `ppa_down` / Tue-lunch `ppa_up` pins are all
  //    preserved (`demo_slice_b_driver_variance_test`).
  //  * Every axis's offset vector is EXACTLY zero-sum across the six
  //    membership positions of a 6-slot period (and across the two of
  //    late_night). The weekly rotation is a pure index rotation, which
  //    preserves the sum, so each (week, period) keeps the SAME mean as
  //    before Slice SA — the week aggregate `determineLever` result and
  //    the 12 distinct week-driver families are unchanged
  //    (`replay_week_driver_rotation_test`).
  //
  // Cluster semantics by membership position (the realistic shapes the
  // benchmark range should show):
  //  * positions 0,1,2 — GOOD core: CPLH, SPLH, PPA all lifted together
  //    (high covers-per-hour WITH strong sales-per-hour and spend).
  //  * position 3 — STRETCHED: CPLH high, SPLH and PPA collapsed
  //    (above-OPZ-ceiling behaviour — running lean on bodies but the
  //    revenue per labour hour / per cover did not follow).
  //  * positions 4,5 — SOFT / overstaffed: CPLH below target, spend
  //    roughly normal.
  // Net mix ≈ 50% good / 14% stretched / 36% soft across the cohort
  // (6-slot periods 3/1/2; the 2-slot late_night contributes 1 good /
  // 1 soft) — good is the plurality, soft is the remainder.
  //
  // ── Slice SA.1 recalibration (closes SD §5.7) ──────────────────────────
  // SA's original ±2–5% perturbation passed SA's own unfiltered
  // dispersion test but the kept-cohort all-three-strong band collapsed
  // after SB's Phase-1 eligibility gates + Phase-3 MAD filter + the joint
  // at/above-kept-median selection: the good-core CPLH offsets were three
  // near-identical values (+1.4/+1.8/+2.2%) that, after the seeded
  // `toStringAsFixed(2)` CPLH storage rounding, collapsed the
  // benchmark-set P25–P75 width below SB's principled
  // `minTeachableWidthCPLH` floor — `building_flat` for lunch — and
  // late_night's 2-slot symmetric pair put all "good" shifts on ONE CPLH
  // value (band width 0, only 4 all-three-strong < `minBenchmark`).
  // Operator decision (SD gate): TUNE SA UP, keep SB's floor unchanged —
  // real shift-to-shift variation is far larger than ±2–5%
  // (cf. `_realisticCandidates` in the validated pressure harness:
  // correlated good core +4–16%, stretched +18–28%, soft −8–20%).
  //
  // The recalibration keeps SA's structure (deterministic, zero-sum per
  // (week, period), owned-axis & week-tilt-axis excluded) but the SPREAD
  // now comes from multiplying the whole zero-sum cluster vector by a
  // per-week CONTINUOUS scalar [_realismWeekScale] (range ≈ 0.74…1.26)
  // so the good core fans across a CONTINUUM of CPLH over the 12 weeks
  // instead of landing on 3 discrete (post-`toStringAsFixed(2)` ≈1)
  // values — giving the all-three-strong cohort a real P25–P75 band
  // well above SB's `minTeachableWidthCPLH`. Scaling a zero-sum vector
  // by a per-week scalar is still exactly zero-sum per (week, period),
  // so the week aggregate `determineLever` result and the 12 distinct
  // week-driver families are unchanged (`replay_week_driver_rotation_
  // test`). The base offsets stay deliberately SMALL (max 0.037) so that
  // even at the 1.26 max scalar the largest scaled offset (≈0.0466)
  // never crosses any rate axis's own `determineLever` firing threshold
  // (cplh/splh 0.05, ppa 0.03) — a perturbed non-owned axis is therefore
  // never even a lever CANDIDATE on a driver slot, so per-shift levers,
  // the 8-family span, the covers_down share, and the recurring
  // Fri-dinner `ppa_down` / Tue-lunch `ppa_up` pins are all preserved
  // unconditionally (`demo_slice_b_driver_variance_test`, plus the SA.1
  // exhaustive lever-safety sweep: 0 violations across 16 slots ×
  // 12 weeks).
  //
  // Magnitude sizing (SA.1): every scaled offset (base × the per-week
  // scalar, max scalar 1.26) stays STRICTLY below 0.047 — well under the
  // smallest co-occurring owned-axis `determineLever` magnitude on any
  // realism-eligible slot. Empirically (SA.1 exhaustive lever-safety
  // sweep over all 16 slots × 12 weeks) the largest scaled realism
  // offset never even crosses its OWN `determineLever` firing threshold
  // (cplh/splh 0.05, ppa 0.03) on a driver slot, so a perturbed
  // non-owned axis is never a lever CANDIDATE there — the owned-axis
  // lever wins unconditionally and the per-shift driver pins
  // (Fri-dinner `ppa_down`, Tue-lunch `ppa_up`, 8-family span,
  // covers_down share) are preserved with margin. The band/teachable
  // spread instead comes from the per-week continuous scalar fanning the
  // good core across the 12 weeks (a scalar × zero-sum vector is still
  // zero-sum, so the week aggregate is unchanged).
  static const List<double> _realismCPLH6 = [
    0.014, 0.020, 0.026, 0.014, -0.037, -0.037,
  ];
  static const List<double> _realismSPLH6 = [
    0.014, 0.020, 0.026, -0.030, -0.015, -0.015,
  ];
  static const List<double> _realismPPA6 = [
    0.009, 0.013, 0.018, -0.022, -0.009, -0.009,
  ];
  // late_night has only two slots/week (Fri + Sat). The 2-slot zero-sum
  // constraint forces `offset(Fri) = -offset(Sat)` every week, so ANY
  // per-week magnitude keeps the (week, period) sum exactly zero. SA.1
  // therefore gives late_night its OWN per-week magnitude
  // ([_lateNightMag]) rather than the shared [_realismWeekScale] ×
  // small-constant path: late_night is sparse and the recommendation
  // engine only sees the shifts inside the cycle's 60-day calibration
  // window — i.e. a CONTIGUOUS ~8-week slice of the 12, not all 12. A
  // monotone ramp over 0..11 would put the windowed weeks on a narrow
  // sub-segment of the ramp (band collapse → `building_flat`). A
  // deterministic mixing spread instead fans the magnitude across the
  // full 0.022…0.048 range within ANY contiguous window, so the ≥5
  // Fri-good shifts the windowed cohort feeds to the all-three-strong
  // set have a P25–P75 CPLH width above SB's `minTeachableWidthCPLH`.
  // The 0.048 ceiling stays below 0.05 (late_night's own cplh/splh
  // `determineLever` threshold) and below the Sat slot's splh-owned
  // magnitude (~0.0675 at the most-negative week amplitude × the 1.4
  // late_night volatility), so the per-shift owned levers (Fri
  // `covers_up`, Sat `splh_down`) are preserved. SPLH/PPA poles track
  // CPLH at the same correlated ratios SA used. Pure / no RNG.
  static double _lateNightMag(int weekIndex) {
    // Deterministic mixing (a coprime stride mod 7) so any contiguous
    // window of weeks still spans the full 0.022…0.048 magnitude range.
    final phase = ((weekIndex * 5 + 2) % 7) / 6.0; // 0 … 1
    return 0.022 + 0.026 * phase; // 0.022 … 0.048
  }

  /// Per-week continuous scalar applied to the whole zero-sum realism
  /// vector. A scalar × zero-sum vector is still exactly zero-sum, so the
  /// per-(week, period) mean — and therefore the week aggregate
  /// `determineLever` result — is unchanged. The ramp spreads the
  /// good-core CPLH across a CONTINUUM over the 12 historical weeks so
  /// the all-three-strong benchmark set has a real P25–P75 band (the
  /// pre-SA.1 three-discrete-values collapse is what tripped SB's
  /// `minTeachableWidthCPLH`). Range ≈ [0.74, 1.26]; combined with the
  /// widest base magnitude (0.037, the SOFT CPLH position) the largest
  /// possible scaled offset is 0.037 × 1.26 ≈ 0.0466. That is below every
  /// rate axis's own `determineLever` firing threshold (cplh/splh 0.05),
  /// so on a driver slot a perturbed non-owned rate axis is never even a
  /// lever CANDIDATE — the owned-axis lever wins unconditionally,
  /// independent of how small the owned magnitude breathes (the
  /// SA.1 exhaustive lever-safety sweep confirms 0 violations / realism
  /// never crosses threshold on any of the 16 slots × 12 weeks). The
  /// good-core spread that produces the teachable band is therefore
  /// entirely the per-week scalar fanning the small good offsets
  /// (0.014…0.026) across a 0.74…1.26 continuum.
  static double _realismWeekScale(int weekIndex) {
    // Deterministic continuous ramp across the 12 historical weeks
    // (index 0 oldest … 11 newest); the current week (index ==
    // historicalWeekCount) is never realism-perturbed by the caller.
    final span = (historicalWeekCount - 1).clamp(1, 1 << 30);
    return 0.74 + 0.52 * (weekIndex / span);
  }

  /// Multiplicative realism factors `(cplh, splh, ppa)` for one closed
  /// shift, applied to the NON-owned rate axes only (the caller skips
  /// the owned axis). For the 6-slot periods (lunch / dinner)
  /// `weekIndex` rotates the cluster-role assignment so a given slot is
  /// not stuck in one cluster across history (realistic week-to-week
  /// movement); for the 2-slot late_night the role is FIXED by
  /// `periodMemberIndex` (Fri good / Sat soft — see the inline note).
  /// In BOTH cases `weekIndex` also scales the zero-sum vector by the
  /// continuous [_realismWeekScale] so the good core spreads across a
  /// real CPLH band. The rotation (a pure permutation), the fixed 2-slot
  /// assignment, and the per-week scalar each preserve the
  /// per-(week, period) zero sum exactly, so the week aggregate mean is
  /// unchanged from pre-Slice-SA.
  ///
  /// `periodMemberIndex` is the slot's 0-based position within its
  /// period's ordered slot list for the week (lunch/dinner have six,
  /// late_night two). Pure function — no RNG, byte-stable across runs.
  static ({double cplh, double splh, double ppa}) _realismProfile({
    required String daypart,
    required int periodMemberIndex,
    required int weekIndex,
  }) {
    final scale = _realismWeekScale(weekIndex);
    if (daypart == 'late_night') {
      // SA.1: late_night has only TWO slots/week (Fri + Sat) and the
      // 2-slot zero-sum constraint forces `offset(Fri) = -offset(Sat)`
      // every week — a per-week-rotating role would alternate which of
      // the two is the "good" one, but Sat late_night OWNS the `splh`
      // driver (weekSlots idx 13 → splh,-1) so its SPLH is pushed ~12%
      // BELOW the cohort median and Sat can essentially never enter the
      // all-three-strong (CPLH∧SPLH∧PPA ≥ kept-median) set. With the
      // rotation, only the few even weeks where Fri was "good" AND no
      // rate axis was the week-tilt produced an all-three-strong shift
      // (≈4 < `minBenchmark`=5, collapsed band → `building_few_strong`).
      //
      // Fix (operator-sanctioned "raise the good-core share for sparse
      // periods"): pin Fri (periodMemberIndex 0, owns `covers` so ALL
      // three rate axes are realism-eligible) to the GOOD pole and Sat
      // (periodMemberIndex 1) to the SOFT pole EVERY week. This is still
      // exactly zero-sum per (week, period) — Fri offset + Sat offset =
      // +x + (−x) = 0 on every axis — so the late_night week aggregate
      // mean (and `replay_week_driver_rotation_test`) is unchanged. The
      // teachable band spread comes from the per-week ramped
      // [_lateNightMag] fanning Fri's good CPLH across the 12 weeks; ≥5
      // of those Fri-good shifts land all-three-strong with a P25–P75
      // width above SB's `minTeachableWidthCPLH`.
      final sign = periodMemberIndex % 2 == 0 ? 1.0 : -1.0; // Fri + / Sat −
      final mag = _lateNightMag(weekIndex);
      return (
        cplh: 1 + sign * mag,
        splh: 1 + sign * mag * 0.76, // SA's 0.026/0.034 SPLH:CPLH ratio
        ppa: 1 + sign * mag * 0.50, //  SA's 0.017/0.034 PPA:CPLH ratio
      );
    }
    // 6-slot period (lunch / dinner). Rotate the role by the week so
    // each membership position cycles through all six cluster roles
    // across history; the rotation is a pure permutation so the
    // per-(week, period) sum on every axis stays exactly zero. The
    // per-week scalar multiplies that zero-sum vector → still zero-sum.
    final role = (periodMemberIndex + weekIndex) % 6;
    return (
      cplh: 1 + _realismCPLH6[role] * scale,
      splh: 1 + _realismSPLH6[role] * scale,
      ppa: 1 + _realismPPA6[role] * scale,
    );
  }

  /// 0-based position of [slotIndex] within its period's ordered slot
  /// list across [weekSlots] (e.g. the four-th lunch slot → 3). Pure
  /// lookup over the static [weekSlots] table; deterministic.
  static int _periodMemberIndex(int slotIndex, String daypart) {
    var n = 0;
    for (var i = 0; i < slotIndex; i++) {
      if (weekSlots[i].$2 == daypart) n++;
    }
    return n;
  }

  // ── Week-level deterministic variation (§2d) ────────────────────────────
  // Replaces the fixed 8-element bands. All variation is a pure function
  // of the week index (0 = oldest .. historicalWeekCount-1 = newest;
  // the current week uses index = historicalWeekCount) — no RNG, so two
  // reseeds are byte-identical (file-header no-randomness invariant).

  /// Lever-NEUTRAL volume scale applied to BOTH forecast and actual
  /// covers, so the covers lever reflects only the per-cell covers
  /// intent (not the week's volume swing) while Variance/History still
  /// see real ±8–12% week-to-week volume deltas plus a gentle upward
  /// seasonal trend and one mid-history soft week.
  static double _weekVolume(int wi) {
    // Gentle upward trend across history (older = quieter).
    final trend = 0.94 + 0.010 * wi;
    // Deterministic ±~9% saw ripple.
    final ripple = 0.09 * ((((wi * 5 + 2) % 7) - 3) / 3.0);
    // One soft week mid-history.
    final soft = (wi == historicalWeekCount - 4) ? -0.07 : 0.0;
    return trend + ripple + soft;
  }

  /// Week amplitude breathing added to a slot's owned-axis magnitude so
  /// the weekly aggregate dollar gap and primary lever move week to week
  /// (non-flat Variance) with a gentle operational-improvement trend
  /// (older weeks run looser) and one soft week. Range ≈ [-0.043, +0.036].
  static double _weekAmp(int wi) {
    final trend = 0.030 - 0.0045 * wi;
    final softWeek = (wi == historicalWeekCount - 4) ? -0.012 : 0.0;
    final ripple = 0.006 * ((((wi * 7 + 3) % 5) - 2) / 2.0);
    return trend + softWeek + ripple;
  }

  // ── Open shift in-progress state — BACK-COMPAT DEFAULT ONLY ─────────────
  // These were the hardcoded mid-service fabrication the QA defect was
  // about (Dinner always "live" regardless of the clock). They are now
  // used ONLY by [_legacyDefaultResolution] — the deterministic
  // no-clock-injected fallback that keeps `MockIntegrationReplaySeed
  // .output` and the static unit-test scenario byte-identical. The
  // demo/device cold-boot + reseed paths inject a clock-derived
  // [OpenPeriodResolution] instead (see `SqliteDatabase` /
  // `resolveDemoOpenPeriod`), so a real Saturday 09:25 no longer shows
  // Dinner "live".
  static const double openProgressFraction = 0.63;
  static const String openShiftTimeLabel = '7:45 PM';
  static const String openShiftServiceElapsedLabel = '3h 15m into service';

  /// The deterministic back-compat resolution used when no clock anchor
  /// is injected: Dinner is the open period, Lunch on the current day is
  /// already closed — exactly the pre-fix static behaviour, so unit
  /// tests reading `generateForDate(date)` / `output` stay byte-stable.
  /// The clock-relative behaviour only activates when the demo/device
  /// path injects an [OpenPeriodResolution] (the actual defect fix).
  static const OpenPeriodResolution _legacyDefaultResolution =
      OpenPeriodResolution(
    openDaypart: 'dinner',
    openProgressFraction: openProgressFraction,
    openTimeLabel: openShiftTimeLabel,
    openServiceElapsedLabel: openShiftServiceElapsedLabel,
    currentDayClosedPeriods: ['lunch'],
  );

  /// Public accessor for [_legacyDefaultResolution] — the deterministic
  /// no-clock-injected fallback (Dinner open, Lunch closed). Consumed by
  /// `SqliteDatabase`'s reseed/advance path when no clock anchor is
  /// injected so the demo affordance + bare-`reseedDemo()` tests stay
  /// deterministic. The cold-boot/device path injects a real
  /// clock-derived resolution instead (the actual QA fix).
  static OpenPeriodResolution get legacyDefaultResolution =>
      _legacyDefaultResolution;

  /// Fraction of [dayLabel]'s whole-day cover volume that belongs to
  /// [daypart] (the SAME split the closed-shift generator uses for cover
  /// distribution). Returns `0.0` for a (day, daypart) the scenario does
  /// not serve. Consumers that hold a whole-day figure (e.g. the demo
  /// reservation book's whole-day unseated-covers baseline) multiply by
  /// this so the per-daypart rows sum back to the intended whole-day
  /// total instead of replicating the whole-day figure per period.
  static double daypartCoverShare(String dayLabel, String daypart) =>
      _daypartRatios[dayLabel]?[daypart] ?? 0.0;

  /// Source shift ID for the default scenario's open shift (backward compat).
  static const String openShiftSourceShiftId = 'w13-fri-dinner-open';

  /// Deterministic source shift ID for seeded open_shift_snapshots rows.
  ///
  /// Format: `w{weekNum}-{day}-{daypart}-{status}`
  /// e.g. `w13-fri-late_night-projected`, `w13-fri-lunch-closed`.
  /// The current open shift uses [openShiftSourceShiftIdFor] instead.
  static String snapshotSourceShiftId({
    required String weekId,
    required String dayLabel,
    required String daypart,
    required String status,
  }) {
    final weekNum = weekId.split('-W').last;
    return 'w$weekNum-${dayLabel.toLowerCase()}-$daypart-$status';
  }

  /// Source shift ID for the scenario's open shift, or `null` when the
  /// scenario has no open period (clock-derived; QA fix). Callers seed
  /// an open snapshot only when this is non-null.
  static String? openShiftSourceShiftIdFor(MockReplayScenario scenario) {
    final daypart = scenario.openShiftDaypart;
    if (daypart == null) return null;
    final weekNum = scenario.currentWeekId.split('-W').last;
    return 'w$weekNum-${scenario.openShiftDayLabel.toLowerCase()}'
        '-$daypart-open';
  }

  /// Default-scenario output — cached for backward compatibility.
  static final MockReplayOutput output = generateForDate(defaultBusinessDate);

  // ── Parameterized generator ─────────────────────────────────────────────

  /// Generates a full mock replay output for an arbitrary business date.
  ///
  /// The default business date [defaultBusinessDate] produces output
  /// identical to the pre-7.55f.4 fixed generator.
  ///
  /// [open] is the clock-derived open-period resolution. When omitted
  /// the deterministic [_legacyDefaultResolution] is used so the static
  /// generator output and all non-injecting unit tests stay
  /// byte-identical (back-compat). The demo/device cold-boot + reseed
  /// paths pass a real clock-derived resolution (see `SqliteDatabase`),
  /// which is the actual QA fix.
  static MockReplayOutput generateForDate(
    String isoBusinessDate, {
    OpenPeriodResolution? open,
  }) {
    final resolution = open ?? _legacyDefaultResolution;
    final parts = isoBusinessDate.split('-');
    final dt = DateTime(
        int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    final dayLabel = _dayLabelFromDate(dt);
    final weekId = _weekIdFromDate(dt);
    final dayIndex = dt.weekday - 1; // 0=Mon .. 6=Sun

    // [historicalWeekCount] historical weeks before the current week
    // (newest first). Slice B (§2d) raised this 8 → 12.
    final currentMonday =
        DateTime(dt.year, dt.month, dt.day - (dt.weekday - 1));
    final histWeekIds = <String>[];
    for (int i = 1; i <= historicalWeekCount; i++) {
      final prev = DateTime(
          currentMonday.year, currentMonday.month, currentMonday.day - 7 * i);
      histWeekIds.add(_weekIdFromDate(prev));
    }

    final allHistorical = <ShiftRecord>[];
    final weekRecords = <WeekRecord>[];

    // Generate oldest first so week indices map to variation arrays.
    // After each week's shifts are added to `allHistorical`, derive its
    // WeekRecord against the cumulative pool so the frozen month + 60-day
    // dollar-impact windows (Phase 7.55q.10) reflect what would have been
    // on the live Variance card the moment that week closed.
    for (int wi = 0; wi < histWeekIds.length; wi++) {
      final wid = histWeekIds[histWeekIds.length - 1 - wi];
      final shifts = _generateClosedWeek(wid, wi);
      allHistorical.addAll(shifts);
      weekRecords.add(_deriveWeekRecord(wid, shifts, allHistorical));
    }
    weekRecords.sort((a, b) => b.weekId.compareTo(a.weekId));

    final currentWeekShifts = _generateCurrentWeekForDate(
      weekId,
      dayIndex,
      resolution.currentDayClosedPeriods,
    );

    // QA fix: the open period is clock-derived (or the deterministic
    // back-compat default), NOT hardcoded to dinner. `openShiftDaypart`
    // is `null` when no period is in progress (honest — no open shift;
    // upcoming periods are projected).
    final scenario = MockReplayScenario(
      currentBusinessDate: isoBusinessDate,
      currentWeekId: weekId,
      openShiftDayLabel: dayLabel,
      openShiftDaypart: resolution.openDaypart,
      openProgressFraction: resolution.openProgressFraction,
      openTimeLabel: resolution.openTimeLabel,
      openServiceElapsedLabel: resolution.openServiceElapsedLabel,
      currentDayClosedPeriods: resolution.currentDayClosedPeriods,
    );

    return MockReplayOutput(
      historicalClosedShifts: allHistorical,
      currentWeekShifts: currentWeekShifts,
      weekRecords: weekRecords,
      scenario: scenario,
    );
  }

  // ── Day-of-week helpers ─────────────────────────────────────────────────

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _dayLabelFromDate(DateTime dt) => _dayLabels[dt.weekday - 1];

  /// Compute ISO week-id from a [DateTime].
  ///
  /// Uses UTC internally to avoid DST-induced off-by-one in
  /// [DateTime.difference] (the spring-forward day is only 23 hours).
  static String _weekIdFromDate(DateTime dt) {
    final monday = DateTime.utc(dt.year, dt.month, dt.day - (dt.weekday - 1));
    final jan4 = DateTime.utc(monday.year, 1, 4);
    final w1Monday =
        DateTime.utc(jan4.year, jan4.month, jan4.day - (jan4.weekday - 1));
    final weekNum =
        ((monday.difference(w1Monday).inDays) / 7).floor() + 1;
    return '${monday.year}-W${weekNum.toString().padLeft(2, '0')}';
  }

  // ── Generator ───────────────────────────────────────────────────────────

  /// Generate all closed shifts for one historical week. Each weekly
  /// slot's index is passed through so the deterministic per-(day,
  /// period) driver intent ([_slotDriverIntent]) is stable across weeks.
  static List<ShiftRecord> _generateClosedWeek(String weekId, int weekIndex) {
    final shifts = <ShiftRecord>[];
    for (int slotIndex = 0; slotIndex < weekSlots.length; slotIndex++) {
      final slot = weekSlots[slotIndex];
      shifts.add(_generateShift(
        weekId: weekId,
        day: slot.$1,
        daypart: slot.$2,
        status: 'closed',
        weekIndex: weekIndex,
        slotIndex: slotIndex,
      ));
    }
    return shifts;
  }

  /// Generate one shift with deterministic variation.
  ///
  /// Demo-data Slice B: closed shifts are built around their period's
  /// own target ([_basePeriodCPLH]/SPLH/PPA) and the per-shift primary
  /// lever is judged against that SAME per-period target — mirroring
  /// production `ShiftFactBuilder.fromClosedShiftInput`. Each weekly
  /// slot owns exactly one driver axis ([_slotDriverIntent]); that axis
  /// is pushed past its `determineLever` threshold while every other
  /// axis is held exactly on the period target, so the engine returns
  /// the intended lever deterministically and the closed cohort spans
  /// 8 lever families instead of collapsing to `covers_down`.
  static ShiftRecord _generateShift({
    required String weekId,
    required String day,
    required String daypart,
    required String status,
    required int weekIndex,
    required int slotIndex,
  }) {
    final dayIndex =
        const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexOf(day);
    final dayCovers = _dayBaseCovers[day]!;
    final ratio = _daypartRatios[day]![daypart]!;

    final baseCPLH = _basePeriodCPLH(daypart);
    final baseSPLH = _basePeriodSPLH(daypart);
    final basePPA = _basePeriodPPA(daypart);

    final businessDate = _businessDateFromWeekDay(weekId, day)!;

    // Lever-NEUTRAL volume: the week volume scale + day jitter are
    // applied to BOTH forecast and actual covers, so the covers lever
    // reflects only the per-cell covers intent (not the week's volume
    // swing). Variance/History still see the real ±8–12% week-to-week
    // volume deltas + seasonal trend through the absolute cover counts.
    final dayJitter = 0.97 + ((weekIndex * 3 + dayIndex * 5 + 1) % 7) * 0.01;
    final baseCoversF = dayCovers * ratio * _weekVolume(weekIndex) * dayJitter;
    final forecastCovers = baseCoversF.round().clamp(10, 9999);

    if (status != 'closed') {
      // Projected: on-model at the PERIOD target (period-differentiated
      // so projected period cards / Full Week Projection rows differ per
      // period and roll up consistently). Wages match target; the
      // empty-candidate fallback (`covers_down`) is engine truth, not a
      // hand-coded sentinel. The non-closed `on_model` sentinel remains
      // the property of `CurrentWeekState.shiftRecordFromSnapshot`
      // (open snapshots), per the phase 7.58 contract Output Cardinality.
      final foh = LaborModel.modelFohHours(forecastCovers, baseCPLH);
      final boh = LaborModel.modelBohHoursFromSales(
        forecastCovers * basePPA,
        baseSPLH,
      );
      final projectedLever = LaborModel.determineLever(
        actualCovers: forecastCovers,
        forecastCovers: forecastCovers,
        avgCPLH: baseCPLH,
        avgPPA: basePPA,
        targetCPLH: baseCPLH,
        targetPPA: basePPA,
        avgSPLH: baseSPLH,
        targetSPLH: baseSPLH,
        avgFohBlendedWage: _fohWage,
        targetFohWage: _fohWage,
        avgBohBlendedWage: _bohWage,
        targetBohWage: _bohWage,
        scheduledFohHours: foh,
        modelFohHours: foh,
        scheduledBohHours: boh,
        modelBohHours: boh,
      );
      return ShiftRecord(
        weekId: weekId,
        dayLabel: day,
        daypart: daypart,
        status: status,
        businessDate: businessDate,
        covers: forecastCovers,
        forecastCovers: forecastCovers,
        ppa: double.parse(basePPA.toStringAsFixed(2)),
        cplh: double.parse(baseCPLH.toStringAsFixed(2)),
        splh: double.parse(baseSPLH.toStringAsFixed(2)),
        fohHours: foh,
        bohHours: boh,
        // On-model labor-dollar source facts. The closed branch stamps
        // `storedFohLaborDollar`/`storedBohLaborDollar` (hours × wage);
        // the projected/open branch must too, or `ShiftRecord.blendedWage`
        // falls through to `totalLaborDollar / totalHours = 0` (no
        // source-backed dollars → 0), which then seeds the open-shift
        // snapshot with `blendedWage = 0` and renders per-daypart LABOR %
        // as a phantom 0%. On the on-model branch wages equal target
        // (`_fohWage`/`_bohWage`, same constants this branch already
        // passes to `determineLever` above), so model-hours × target-wage
        // IS the honest on-model labor-dollar truth — not a fabricated
        // figure.
        storedFohLaborDollar: foh * _fohWage,
        storedBohLaborDollar: boh * _bohWage,
        theoreticalLaborPct: _theoreticalLaborPct,
        primaryLever: projectedLever.toUpperCase(),
        sourceSystem: sourceSystem,
        // Per-Daypart V1 (Slice 1, Gap 22) — timing-provenance stamps
        // also on the projected/open-shift seed branch so reads see a
        // consistent shape across closed and projected rows.
        businessTimingProfileId: demoBusinessTimingProfileId,
        businessTimingProfileVersionId: demoBusinessTimingProfileId,
        servicePeriodKey: daypart,
      );
    }

    // ── Closed shift — one deterministic driver per (day, period) ─────────

    final intent = _slotDriverIntent[slotIndex];
    final axis = intent.$1;
    final intentSign = intent.$2;

    // Owned-axis magnitude: base (clears the axis threshold) + week
    // amplitude breathing × per-period volatility (lunch flatter,
    // late_night noisiest). Floored at the base magnitude as a belt-and-
    // suspenders guard — by construction every axis already clears its
    // threshold at the most-negative week amplitude.
    final breathed = _intentBaseMag[axis]! +
        _weekAmp(weekIndex) * (_periodVolatility[daypart] ?? 1.0);
    final m = breathed > 0 ? breathed : _intentBaseMag[axis]!;
    final dev = 1 + intentSign * m;

    // ── Per-week dominant driver tilt (Variance → History honesty) ──────
    // Resolve this week's assigned (axis, sign) and the uniform tilt
    // factor applied to EVERY closed shift of the week. Only historical
    // closed weeks (`weekIndex < historicalWeekCount`) get a tilt; the
    // current week (`weekIndex == historicalWeekCount`) and any
    // projected/open shifts get NONE — History is historical weeks only.
    // The factor multiplies the SAME quantity the per-slot intent
    // mutates for that axis (actual covers / ppa / cplh-rate /
    // splh-rate / wage), so all downstream derived values stay
    // internally consistent and the week aggregate genuinely crosses
    // the assigned axis's `determineLever` threshold. By constraint the
    // tilt magnitude is strictly below every per-shift owned magnitude,
    // so a slot whose own axis equals the week axis with the opposite
    // sign still keeps its per-shift lever (the per-shift owned tilt
    // dominates); a same-axis/same-sign slot simply adds (still that
    // lever, stronger). See [_weekDriverIntent] / [_weekDriverMag].
    double weekFactor(String forAxis) {
      if (weekIndex >= historicalWeekCount) return 1.0;
      final wIntent = _weekDriverIntent[weekIndex];
      if (wIntent.$1 != forAxis) return 1.0;
      return 1 + wIntent.$2 * _weekDriverMag[forAxis]!;
    }

    // Every non-owned axis is held EXACTLY on the period target, so it
    // contributes zero per-shift deviation and the owned axis is the
    // sole — and therefore winning — per-shift `determineLever`
    // candidate. The per-WEEK tilt rides on top of the assigned axis
    // uniformly across the week so only the WEEK AGGREGATE crosses the
    // assigned axis's threshold (the round-trip + demo_slice_b tests
    // pin both invariants).
    //
    // Covers note: the per-slot covers intent normally tilts BOTH
    // forecast and actual (lever-NEUTRAL volume) so the covers lever
    // reflects only the per-cell intent. The WEEK covers driver MUST
    // break that neutrality for the assigned week, so the week factor
    // is applied to ACTUAL covers only (not forecast), making the
    // week's covers-vs-forecast deviation real.
    // ── Per-shift realism profile (Slice SA) ───────────────────────────
    // Deterministic, seeded, correlated good/stretched/soft variation
    // applied to the NON-owned rate axes (cplh / splh / ppa) only, so a
    // true per-shift RANGE exists instead of every non-driver shift
    // sitting on the exact per-period target. The owned axis is
    // EXCLUDED (it keeps its full per-slot driver `dev`); covers and
    // wages are left to their existing per-slot/per-week machinery
    // (covers' ±2% threshold is too tight to perturb safely and it also
    // drives sales). Every offset is strictly below its axis's lever
    // threshold and zero-sum across the period, so per-shift levers and
    // the week aggregate are both preserved (see [_realismProfile]).
    // The week-tilted axis (if any) is ALSO excluded from the realism
    // profile: that axis is already deliberately moved week-wide by the
    // tuned [_weekDriverMag] tilt, and layering an extra ±offset on it
    // would (a) compound past its lever threshold on a non-owned slot
    // (false candidate) and (b) inject non-zero-sum noise into the very
    // week aggregate `replay_week_driver_rotation_test` pins. Realism
    // therefore rides ONLY on rate axes that are neither this slot's
    // owned driver nor this week's tilted driver — leaving both the
    // per-shift lever and the week aggregate exactly as before Slice SA.
    final weekTiltAxis = weekIndex < historicalWeekCount
        ? _weekDriverIntent[weekIndex].$1
        : null;
    final realism = _realismProfile(
      daypart: daypart,
      periodMemberIndex: _periodMemberIndex(slotIndex, daypart),
      weekIndex: weekIndex,
    );
    final realismCPLH =
        (axis == 'cplh' || weekTiltAxis == 'cplh') ? 1.0 : realism.cplh;
    final realismSPLH =
        (axis == 'splh' || weekTiltAxis == 'splh') ? 1.0 : realism.splh;
    final realismPPA =
        (axis == 'ppa' || weekTiltAxis == 'ppa') ? 1.0 : realism.ppa;

    final wCovers = weekFactor('covers');
    final covers = axis == 'covers'
        ? (baseCoversF * dev * wCovers).round().clamp(10, 9999)
        : (baseCoversF * wCovers).round().clamp(10, 9999);
    final effPPA = (axis == 'ppa' ? basePPA * dev : basePPA) *
        weekFactor('ppa') *
        realismPPA;
    final ppa = double.parse(effPPA.toStringAsFixed(2));
    final sales = covers * ppa;

    // Reported cplh/splh are the constructed RATES (not covers ÷ rounded
    // integer hours). Storing the rate keeps tiny late_night shifts from
    // letting integer-hour rounding spuriously cross a lever threshold,
    // while fohHours/bohHours remain the realistic integer model hours.
    // The week cplh/splh tilt rides on the rate; hours then follow from
    // covers/sales ÷ rate exactly as the per-slot path does.
    final effCPLH = (axis == 'cplh' ? baseCPLH * dev : baseCPLH) *
        weekFactor('cplh') *
        realismCPLH;
    final effSPLH = (axis == 'splh' ? baseSPLH * dev : baseSPLH) *
        weekFactor('splh') *
        realismSPLH;
    final fohHours = LaborModel.modelFohHours(covers, effCPLH);
    final bohHours = LaborModel.modelBohHoursFromSales(sales, effSPLH);

    final fohWage =
        (axis == 'fohWage' ? _fohWage * dev : _fohWage) * weekFactor('fohWage');
    final bohWage =
        (axis == 'bohWage' ? _bohWage * dev : _bohWage) * weekFactor('bohWage');

    // Model hours are vs the PERIOD target (what the hours-flex lever
    // compares the schedule against); scheduled = model unless this
    // slot owns an hours-flex axis.
    final modelFoh = LaborModel.modelFohHours(covers, baseCPLH);
    final modelBoh = LaborModel.modelBohHoursFromSales(sales, baseSPLH);
    final scheduledFoh = axis == 'fohHours'
        ? (modelFoh * dev).round().clamp(1, 999999)
        : modelFoh;
    final scheduledBoh = axis == 'bohHours'
        ? (modelBoh * dev).round().clamp(1, 999999)
        : modelBoh;

    final cplh = effCPLH;
    final splh = effSPLH;

    // F-3: pass the full axis set, judged against the PERIOD target
    // (mirrors production `ShiftFactBuilder.fromClosedShiftInput`, which
    // feeds the per-period target snapshot — not a whole-day pooled
    // rate). Exactly one axis deviates, so the engine returns the
    // intended lever; the closed cohort therefore spans 8 lever
    // families with `covers_down` on a single slot.
    final lever = LaborModel.determineLever(
      actualCovers: covers,
      forecastCovers: forecastCovers,
      avgCPLH: cplh,
      avgPPA: ppa,
      targetCPLH: baseCPLH,
      targetPPA: basePPA,
      avgSPLH: splh,
      targetSPLH: baseSPLH,
      avgFohBlendedWage: fohWage,
      targetFohWage: _fohWage,
      avgBohBlendedWage: bohWage,
      targetBohWage: _bohWage,
      scheduledFohHours: scheduledFoh,
      modelFohHours: modelFoh,
      scheduledBohHours: scheduledBoh,
      modelBohHours: modelBoh,
    );

    return ShiftRecord(
      weekId: weekId,
      dayLabel: day,
      daypart: daypart,
      status: 'closed',
      businessDate: businessDate,
      covers: covers,
      forecastCovers: forecastCovers,
      ppa: ppa,
      cplh: double.parse(cplh.toStringAsFixed(2)),
      splh: double.parse(splh.toStringAsFixed(2)),
      fohHours: fohHours,
      bohHours: bohHours,
      theoreticalLaborPct: _theoreticalLaborPct,
      primaryLever: lever.toUpperCase(),
      scheduledFohHours: scheduledFoh,
      scheduledBohHours: scheduledBoh,
      storedFohLaborDollar: fohHours * fohWage,
      storedBohLaborDollar: bohHours * bohWage,
      sourceSystem: sourceSystem,
      // Per-Daypart V1 (Slice 1, Gap 22 fix): demo seeder writes
      // shift_records with the demo restaurant's timing-provenance
      // fields populated. The demo timing config (see
      // `sqlite_database_seed.dart`) is hardcoded to a 3-period
      // setup keyed on profile_id `demoBusinessTimingProfileId`. The
      // `daypart` value already carries the service-period identifier
      // ('lunch' / 'dinner' / 'late_night'), so the same string is the
      // canonical service period key.
      businessTimingProfileId: demoBusinessTimingProfileId,
      businessTimingProfileVersionId: demoBusinessTimingProfileId,
      servicePeriodKey: daypart,
      // Per-Daypart V1 (Slice 1): per-shift per-period locked target
      // stamps. Demo regenerate runs through the same DAOs as
      // production close-shifts, so these stamps mirror the demo
      // cycle's per-period rows. Stamping at seed time keeps the
      // history grader honest: each closed shift is judged against
      // its period's locked target, not the whole-day pool.
      daypartTargetCPLH: _daypartTargetCPLH[daypart],
      daypartTargetSPLH: _daypartTargetSPLH[daypart],
      daypartTargetPPA: _daypartTargetPPA[daypart] ?? _targetPPA,
      daypartOpzFloorCPLH: _daypartOpzFloor[daypart],
      daypartOpzCeilingCPLH: _daypartOpzCeiling[daypart],
    );
  }

  /// Derive a [WeekRecord] from a week's closed shifts.
  ///
  /// All aggregate metrics are computed from the shift-level data.
  /// Target fields are left null — the backfill pass stamps them.
  ///
  /// Phase 7.55q.10: also captures `closedAt` (last business date of the
  /// week) and the frozen month + 60-day dollar-impact windows by filtering
  /// [historicalPool] (all historical shifts seeded so far, including this
  /// week's). Mirrors the runtime `_buildWeekRecord` capture in
  /// `lib/services/shift_service.dart` so demo history shows the same
  /// 4-row Dollar Impact view the live Variance card would have shown.
  static WeekRecord _deriveWeekRecord(
    String weekId,
    List<ShiftRecord> shifts,
    List<ShiftRecord> historicalPool,
  ) {
    final totalCovers = shifts.fold<int>(0, (s, r) => s + r.covers);
    final forecastCovers = shifts.fold<int>(0, (s, r) => s + r.forecastCovers);
    final totalFoh = shifts.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBoh = shifts.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales = shifts.fold<double>(0, (s, r) => s + r.actualSales);
    final totalLabor = shifts.fold<double>(0, (s, r) => s + r.totalLaborDollar);

    final avgPPA = totalCovers > 0 ? totalSales / totalCovers : _targetPPA;
    final avgCPLH = totalFoh > 0 ? totalCovers / totalFoh : _targetCPLH;
    final actualLaborPct =
        totalSales > 0 ? totalLabor / totalSales * 100 : 0.0;

    final dollarGap = LaborModel.dollarGap(
      totalLabor,
      totalCovers,
      avgPPA,
      targetCPLH: _targetCPLH,
      targetSPLH: _targetSPLH,
      fohWage: _fohWage,
      bohWage: _bohWage,
    );

    final avgSPLH = totalBoh > 0 ? totalSales / totalBoh : _targetSPLH;
    // 7.58.4 / F-3: include wages + hours-flex so the seed-derived
    // weekly lever mirrors `ShiftService._buildWeekRecord` (which feeds
    // the same axis set into the week-level producer at close time).
    // Demo wages match target — wage axis stays quiet — but the call
    // shape now matches the live producer for round-trip parity.
    // 7.58.0a / Finding F-2: this is a week-level aggregate producer,
    // so it uses `determineLeverGated` — an on-model demo week (axis
    // deltas wash out across the week) surfaces the `on_model`
    // sentinel and the History tile renders "—" instead of a false
    // red COVERS. Per-shift / projected seed levers above stay on
    // `determineLever` (7.61 catalog discipline; projected rows are
    // overridden to "Not yet available" by the projection read
    // service regardless of the stored id).
    final wkFohLaborDollar =
        shifts.fold<double>(0, (s, r) => s + r.fohLaborDollar);
    final wkBohLaborDollar =
        shifts.fold<double>(0, (s, r) => s + r.bohLaborDollar);
    final wkBlendedFohWage =
        totalFoh > 0 ? wkFohLaborDollar / totalFoh : _fohWage;
    final wkBlendedBohWage =
        totalBoh > 0 ? wkBohLaborDollar / totalBoh : _bohWage;
    final wkModelFoh = LaborModel.modelFohHours(totalCovers, _targetCPLH);
    final wkModelBoh =
        LaborModel.modelBohHoursFromSales(totalSales, _targetSPLH);
    final lever = LaborModel.determineLeverGated(
      actualCovers: totalCovers,
      forecastCovers: forecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: _targetCPLH,
      targetPPA: _targetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: _targetSPLH,
      avgFohBlendedWage: wkBlendedFohWage,
      targetFohWage: _fohWage,
      avgBohBlendedWage: wkBlendedBohWage,
      targetBohWage: _bohWage,
      scheduledFohHours: totalFoh,
      modelFohHours: wkModelFoh,
      scheduledBohHours: totalBoh,
      modelBohHours: wkModelBoh,
    );

    // ── Frozen Dollar Impact windows (7.55q.10) ────────────────────────
    // Compute the month + 60-day dollar-impact windows that the live
    // Variance card would have shown the moment this week closed, plus
    // the close timestamp itself. Reuses the same window math the
    // runtime path uses; see `_buildWeekRecord` and
    // `_accumulateDollarImpact` in `lib/services/shift_service.dart`.
    final closedAt = shifts
        .map((s) => s.businessDate)
        .whereType<String>()
        .fold<String?>(null,
            (max, d) => max == null || d.compareTo(max) > 0 ? d : max);
    double? monthDollarImpact;
    double? sixtyDayDollarImpact;
    if (closedAt != null) {
      final closedDt = _parseDate(closedAt);
      final monthStart =
          _formatDate(DateTime.utc(closedDt.year, closedDt.month, 1));
      final monthShifts = historicalPool.where((s) {
        final bd = s.businessDate;
        return bd != null &&
            bd.compareTo(monthStart) >= 0 &&
            bd.compareTo(closedAt) <= 0;
      }).toList();
      monthDollarImpact = _accumulateDollarImpactSeed(monthShifts);
      final sixtyDayStart =
          _formatDate(closedDt.subtract(const Duration(days: 59)));
      final sixtyDayShifts = historicalPool.where((s) {
        final bd = s.businessDate;
        return bd != null &&
            bd.compareTo(sixtyDayStart) >= 0 &&
            bd.compareTo(closedAt) <= 0;
      }).toList();
      sixtyDayDollarImpact = _accumulateDollarImpactSeed(sixtyDayShifts);
    }

    return WeekRecord(
      weekId: weekId,
      weekLabel: _weekLabel(weekId),
      totalCovers: totalCovers,
      forecastCovers: forecastCovers,
      totalFohHours: totalFoh,
      totalBohHours: totalBoh,
      avgPPA: double.parse(avgPPA.toStringAsFixed(2)),
      avgCPLH: double.parse(avgCPLH.toStringAsFixed(2)),
      theoreticalLaborPct: _theoreticalLaborPct,
      actualLaborPct: double.parse(actualLaborPct.toStringAsFixed(2)),
      dollarGap: double.parse(dollarGap.toStringAsFixed(2)),
      primaryLeverId: lever,
      shiftsCompleted: shifts.length,
      blendedFohWage: _fohWage,
      blendedBohWage: _bohWage,
      monthDollarImpact: monthDollarImpact,
      sixtyDayDollarImpact: sixtyDayDollarImpact,
      closedAt: closedAt,
    );
  }

  /// Seed-side mirror of `ShiftService._accumulateDollarImpact`. Uses the
  /// seed's own target standards instead of per-shift locked targets,
  /// because seed shifts don't carry `targetCPLH` / `targetSPLH` /
  /// `targetFohWage` / `targetBohWage` (those come from the per-shift
  /// backfill that runs after seed insertion). Same formula otherwise:
  /// actualLabor − (modelFoh × fohWage + modelBoh × bohWage).
  static double _accumulateDollarImpactSeed(List<ShiftRecord> shifts) {
    return shifts.fold<double>(0, (sum, s) {
      final actualLabor = s.fohLaborDollar + s.bohLaborDollar;
      final modelFoh = LaborModel.modelFohHours(s.covers, _targetCPLH);
      final modelBoh =
          LaborModel.modelBohHoursFromSales(s.actualSales, _targetSPLH);
      final theoreticalLabor = modelFoh * _fohWage + modelBoh * _bohWage;
      return sum + (actualLabor - theoreticalLabor);
    });
  }

  // ── Date helpers (local to seed; mirror shift_service helpers) ─────────

  static DateTime _parseDate(String iso) {
    final p = iso.split('-');
    return DateTime.utc(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  static String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  /// Generate current week with status derived from the business date.
  ///
  /// [dayIndex] is 0=Mon .. 6=Sun within the current week.
  /// Shifts before the current day are closed. Shifts after are projected.
  /// On the current day, [currentDayClosedPeriods] (clock-derived: the
  /// periods that already ended) are `closed`; every other current-day
  /// period is `projected` (the open one is upgraded to `open` by the
  /// snapshot builder; when no period is in progress none is, so the
  /// whole current day is honestly projected/closed — never a fabricated
  /// "live" period). QA fix: replaces the hardcoded "lunch closed, rest
  /// projected" that made Dinner always look open.
  static List<ShiftRecord> _generateCurrentWeekForDate(
      String weekId, int dayIndex, List<String> currentDayClosedPeriods) {
    // The current week's index sits one past the newest historical
    // week so its volume/amplitude band is distinct and deterministic.
    const weekIndex = historicalWeekCount;

    final shifts = <ShiftRecord>[];
    for (int slotIndex = 0; slotIndex < weekSlots.length; slotIndex++) {
      final slot = weekSlots[slotIndex];
      final slotDayIndex = _dayLabels.indexOf(slot.$1);

      String status;
      if (slotDayIndex < dayIndex) {
        // Past day — closed
        status = 'closed';
      } else if (slotDayIndex > dayIndex) {
        // Future day — projected
        status = 'projected';
      } else {
        // Current day — clock-derived: periods that already ended are
        // closed; everything else is projected (the open period, if
        // any, is upgraded to `open` by the snapshot builder).
        status = currentDayClosedPeriods.contains(slot.$2)
            ? 'closed'
            : 'projected';
      }

      shifts.add(_generateShift(
        weekId: weekId,
        day: slot.$1,
        daypart: slot.$2,
        status: status,
        weekIndex: weekIndex,
        slotIndex: slotIndex,
      ));
    }
    return shifts;
  }

  /// Human-readable week label from weekId (e.g., '2026-W05' -> 'Jan 26').
  static String _weekLabel(String weekId) {
    final parts = weekId.split('-W');
    if (parts.length != 2) return weekId;
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return weekId;

    final jan4 = DateTime(year, 1, 4);
    final w1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    final monday = w1Monday.add(Duration(days: (week - 1) * 7));

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[monday.month - 1]} ${monday.day}';
  }

  /// Strict YYYY-W## weekId + known dayLabel → ISO date, or null.
  static final _weekIdPattern = RegExp(r'^\d{4}-W\d{2}$');

  static String? _businessDateFromWeekDay(String weekId, String dayLabel) {
    const dayOffset = {
      'Mon': 0, 'Tue': 1, 'Wed': 2, 'Thu': 3,
      'Fri': 4, 'Sat': 5, 'Sun': 6,
    };
    if (!dayOffset.containsKey(dayLabel)) return null;
    if (!_weekIdPattern.hasMatch(weekId)) return null;
    final parts = weekId.split('-W');
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return null;
    final jan4 = DateTime(year, 1, 4);
    final w1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    final monday = w1Monday.add(Duration(days: (week - 1) * 7));
    final date = monday.add(Duration(days: dayOffset[dayLabel]!));
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
