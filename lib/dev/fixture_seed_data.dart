import '../domain/constants/app_defaults.dart';
import '../models/history_pattern_record.dart';
import '../models/shift_record.dart';
import '../models/week_record.dart';
import '../services/labor_model.dart';
import 'demo_fixture_data.dart';

// ─── Demo seed data ────────────────────────────────────────────────────────────
// Current week: 2026-W13 (Mon Mar 23 – Sun Mar 29)
// Daypart matrix: Mon–Thu = Lunch+Dinner, Fri = Lunch+Dinner+Late Night,
//                 Sat = Dinner+Late Night, Sun = Dinner. Total = 14 shifts.
//
// Closed (9): Mon L → Fri L.  Projected (5): Fri D, Fri Late, Sat D, Sat Late, Sun D.
//
// Labor % fields (fohLaborPct, bohLaborPct, totalLaborPct, variancePts, blendedWage)
// are now computed getters on ShiftRecord — do not pass them here.
//
// Historical weekIds use ISO format: "YYYY-Www"
// Newest → oldest: W12, W11, W10, W09, W08, W07, W06, W05, W04, W03, W02, W01
//
// ── Shift design (9 closed) ────────────────────────────────────────────────────
// Total covers: 1,580 vs 1,780 WTD forecast = −200 (−11.2%) → covers_down
// Total FOH: 362 · Total BOH: 373 · Total sales: $67,180
// avgCPLH = 1580/362 = 4.36 (−4.8% vs 4.58 target — below 5% threshold)
// avgSPLH = 67180/373 = 180.1 (within threshold — no SPLH lever)
// cplh per shift = covers/fohHours · splh = covers×ppa/bohHours

class DemoData {
  // ── 7.58.4 lever round-trip helpers ─────────────────────────────────────
  // Every demo fixture row must reproduce its `primaryLever` /
  // `primaryLeverId` when re-fed through `LaborModel.determineLever`. The
  // hand-coded literals below stay in place for reviewer narrative, but
  // they are overwritten at list-build time by these helpers so the
  // engine — not the fixture author — owns the persisted id.
  // See `docs/contracts/phase_7_58_primary_driver_contract.md` (Single
  // Source of Truth) and `docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md`
  // Sub-Slice Family `.4`.

  static String _engineLeverForShift(ShiftRecord s) {
    return LaborModel.determineLever(
      actualCovers: s.covers,
      forecastCovers: s.forecastCovers,
      avgCPLH: s.cplh,
      avgPPA: s.ppa,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      avgSPLH: s.splh,
      targetSPLH: BaselineData.derivedTargetSPLH,
    );
  }

  static String _engineLeverForWeek(WeekRecord w) {
    final avgSPLH = w.totalBohHours > 0
        ? (w.avgPPA * w.totalCovers) / w.totalBohHours
        : 0.0;
    // 7.58.4: matches the axis set already pinned by
    // `lever_logic_test.dart` Demo weekHistory round-trip
    // (covers + ppa + cplh + splh + wages). Hours-flex is intentionally
    // omitted here: each demo `WeekRecord` is shaped to teach a single
    // dominant lever (one of the 12 enumerated in the
    // "12 lever types" test), and the closed weeks where actual
    // FOH/BOH hours align with the cplh/splh story would otherwise
    // re-classify as `foh_hours_over` / `_under` once hours-flex enters
    // the candidate set. The contract has no rule requiring producers
    // to feed every axis; it requires that whatever subset they feed
    // round-trips the same way for fixture and engine.
    return LaborModel.determineLever(
      actualCovers: w.totalCovers,
      forecastCovers: w.forecastCovers,
      avgCPLH: w.avgCPLH,
      avgPPA: w.avgPPA,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      avgFohBlendedWage: w.blendedFohWage,
      targetFohWage: MeridianConfig.fohWage,
      avgBohBlendedWage: w.blendedBohWage,
      targetBohWage: MeridianConfig.bohWage,
    );
  }

  static ShiftRecord _withDerivedLever(ShiftRecord s) {
    return ShiftRecord(
      id: s.id,
      restaurantId: s.restaurantId,
      weekId: s.weekId,
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      status: s.status,
      covers: s.covers,
      forecastCovers: s.forecastCovers,
      ppa: s.ppa,
      cplh: s.cplh,
      splh: s.splh,
      fohHours: s.fohHours,
      bohHours: s.bohHours,
      theoreticalLaborPct: s.theoreticalLaborPct,
      primaryLever: _engineLeverForShift(s).toUpperCase(),
      scheduledFohHours: s.scheduledFohHours,
      scheduledBohHours: s.scheduledBohHours,
      storedFohLaborDollar: s.storedFohLaborDollar,
      storedBohLaborDollar: s.storedBohLaborDollar,
      storedFohLaborPct: s.storedFohLaborPct,
      storedBohLaborPct: s.storedBohLaborPct,
      storedTotalLaborPct: s.storedTotalLaborPct,
      storedBlendedWage: s.storedBlendedWage,
      targetProfileId: s.targetProfileId,
      targetProfileVersionId: s.targetProfileVersionId,
      targetSourceType: s.targetSourceType,
      targetCPLH: s.targetCPLH,
      targetSPLH: s.targetSPLH,
      targetPPA: s.targetPPA,
      targetFohWage: s.targetFohWage,
      targetBohWage: s.targetBohWage,
      opzFloorCPLH: s.opzFloorCPLH,
      opzCeilingCPLH: s.opzCeilingCPLH,
      theoreticalFohLaborPct: s.theoreticalFohLaborPct,
      theoreticalBohLaborPct: s.theoreticalBohLaborPct,
      snapshotBlendedWage: s.snapshotBlendedWage,
      planForecastSales: s.planForecastSales,
      businessDate: s.businessDate,
      sourceSystem: s.sourceSystem,
      sourceShiftId: s.sourceShiftId,
    );
  }

  static WeekRecord _withDerivedWeekLever(WeekRecord w) {
    return WeekRecord(
      id: w.id,
      restaurantId: w.restaurantId,
      weekId: w.weekId,
      weekLabel: w.weekLabel,
      totalCovers: w.totalCovers,
      forecastCovers: w.forecastCovers,
      totalFohHours: w.totalFohHours,
      totalBohHours: w.totalBohHours,
      avgPPA: w.avgPPA,
      avgCPLH: w.avgCPLH,
      theoreticalLaborPct: w.theoreticalLaborPct,
      actualLaborPct: w.actualLaborPct,
      dollarGap: w.dollarGap,
      primaryLeverId: _engineLeverForWeek(w),
      shiftsCompleted: w.shiftsCompleted,
      blendedFohWage: w.blendedFohWage,
      blendedBohWage: w.blendedBohWage,
      hasStoredBlendedWageTruth: w.hasStoredBlendedWageTruth,
      targetSourceType: w.targetSourceType,
      targetCPLH: w.targetCPLH,
      targetSPLH: w.targetSPLH,
      targetPPA: w.targetPPA,
      targetFohWage: w.targetFohWage,
      targetBohWage: w.targetBohWage,
      theoreticalFohLaborPct: w.theoreticalFohLaborPct,
      theoreticalBohLaborPct: w.theoreticalBohLaborPct,
      lockedRequiredFohHours: w.lockedRequiredFohHours,
      lockedRequiredBohHours: w.lockedRequiredBohHours,
      monthDollarImpact: w.monthDollarImpact,
      sixtyDayDollarImpact: w.sixtyDayDollarImpact,
      closedAt: w.closedAt,
      targetCalibrationWindowStart: w.targetCalibrationWindowStart,
      targetCalibrationWindowEnd: w.targetCalibrationWindowEnd,
    );
  }

  // ── Current-week shifts (14 total: 9 closed + 5 projected) ──────────────
  static final List<ShiftRecord> currentWeekShifts =
      List<ShiftRecord>.unmodifiable(_rawCurrentWeekShifts.map(_withDerivedLever));

  static final List<ShiftRecord> _rawCurrentWeekShifts = [

    // ── Monday ──────────────────────────────────────────────────────────────
    // Mon Lunch: 154 vs 180 (−14%). Hours hold; CPLH 4.28.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Mon', daypart: 'lunch', status: 'closed',
      covers: 154, forecastCovers: 180,
      ppa: 41.20, cplh: 4.28, splh: 171.5,
      fohHours: 36, bohHours: 37,
      primaryLever: 'COVERS_DOWN',
    ),
    // Mon Dinner: 196 vs 220 (−11%). Hours hold; CPLH 4.08.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Mon', daypart: 'dinner', status: 'closed',
      covers: 196, forecastCovers: 220,
      ppa: 43.50, cplh: 4.08, splh: 170.5,
      fohHours: 48, bohHours: 50,
      primaryLever: 'COVERS_DOWN',
    ),

    // ── Tuesday ──────────────────────────────────────────────────────────────
    // Tue Lunch: 158 vs 180 (−12%). Lean FOH; CPLH 4.39.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Tue', daypart: 'lunch', status: 'closed',
      covers: 158, forecastCovers: 180,
      ppa: 41.60, cplh: 4.39, splh: 177.6,
      fohHours: 36, bohHours: 37,
      primaryLever: 'COVERS_DOWN',
    ),
    // Tue Dinner: 192 vs 220 (−13%). Held hours; CPLH 4.09.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Tue', daypart: 'dinner', status: 'closed',
      covers: 192, forecastCovers: 220,
      ppa: 43.20, cplh: 4.09, splh: 172.8,
      fohHours: 47, bohHours: 48,
      primaryLever: 'COVERS_DOWN',
    ),

    // ── Wednesday ────────────────────────────────────────────────────────────
    // Wed Lunch: 162 vs 180 (−10%). CPLH 4.50 — nearly on model.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Wed', daypart: 'lunch', status: 'closed',
      covers: 162, forecastCovers: 180,
      ppa: 41.80, cplh: 4.50, splh: 183.0,
      fohHours: 36, bohHours: 37,
      primaryLever: 'COVERS_DOWN',
    ),
    // Wed Dinner: 200 vs 220 (−9%). Best volume recovery of the week.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Wed', daypart: 'dinner', status: 'closed',
      covers: 200, forecastCovers: 220,
      ppa: 43.80, cplh: 4.26, splh: 178.8,
      fohHours: 47, bohHours: 49,
      primaryLever: 'COVERS_DOWN',
    ),

    // ── Thursday ─────────────────────────────────────────────────────────────
    // Thu Lunch: 165 vs 180 (−8%). CPLH 4.58 — exactly on model.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Thu', daypart: 'lunch', status: 'closed',
      covers: 165, forecastCovers: 180,
      ppa: 42.00, cplh: 4.58, splh: 187.3,
      fohHours: 36, bohHours: 37,
      primaryLever: 'COVERS_DOWN',
    ),
    // Thu Dinner: 203 vs 220 (−8%). Best dinner of the week. CPLH 4.32.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Thu', daypart: 'dinner', status: 'closed',
      covers: 203, forecastCovers: 220,
      ppa: 43.50, cplh: 4.32, splh: 184.0,
      fohHours: 47, bohHours: 48,
      primaryLever: 'COVERS_DOWN',
    ),

    // ── Friday ───────────────────────────────────────────────────────────────
    // Fri Lunch: 150 vs 180 (−17%). Lean schedule; CPLH 5.17 (above model).
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Fri', daypart: 'lunch', status: 'closed',
      covers: 150, forecastCovers: 180,
      ppa: 41.00, cplh: 5.17, splh: 205.0,
      fohHours: 29, bohHours: 30,
      primaryLever: 'COVERS_DOWN',
    ),
    // Fri Dinner: LIVE — projected at 310-cover baseline (20.6%).
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Fri', daypart: 'dinner', status: 'projected',
      covers: 310, forecastCovers: 310,
      ppa: 42.00, cplh: 4.50, splh: 180.0,
      fohHours: 69, bohHours: 72,
      primaryLever: 'ON_MODEL',
    ),
    // Fri Late Night: projected at 90-cover baseline.
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Fri', daypart: 'late_night', status: 'projected',
      covers: 90, forecastCovers: 90,
      ppa: 42.00, cplh: 4.50, splh: 180.0,
      fohHours: 20, bohHours: 21,
      primaryLever: 'ON_MODEL',
    ),

    // ── Saturday ─────────────────────────────────────────────────────────────
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Sat', daypart: 'dinner', status: 'projected',
      covers: 310, forecastCovers: 310,
      ppa: 42.00, cplh: 4.50, splh: 180.0,
      fohHours: 69, bohHours: 72,
      primaryLever: 'ON_MODEL',
    ),
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Sat', daypart: 'late_night', status: 'projected',
      covers: 90, forecastCovers: 90,
      ppa: 42.00, cplh: 4.50, splh: 180.0,
      fohHours: 20, bohHours: 21,
      primaryLever: 'ON_MODEL',
    ),

    // ── Sunday ───────────────────────────────────────────────────────────────
    ShiftRecord(
      weekId: '2026-W13', dayLabel: 'Sun', daypart: 'dinner', status: 'projected',
      covers: 180, forecastCovers: 180,
      ppa: 42.00, cplh: 4.50, splh: 180.0,
      fohHours: 40, bohHours: 42,
      primaryLever: 'ON_MODEL',
    ),
  ];

  // ── Historical week records — 12 weeks, newest first ────────────────────
  // One record per Chapter 10 lever type. All use derivedTheoreticalLaborPct
  // ≈ 20.48 as the snapshot (not hardcoded 20.6).
  //
  // Each record's stored fields (avgCPLH, avgPPA, blendedFohWage, blendedBohWage)
  // must reproduce the stored primaryLeverId when passed to determineLever.
  //
  // Scenarios use baseline: forecastCovers=1200, targetCPLH≈4.58,
  // targetSPLH≈180.07, targetPPA≈41.79, fohWage=16.50, bohWage=21.35.
  //
  // Hour derivation: fohHours = round(covers / avgCPLH),
  //                  bohHours = round(covers × avgPPA / avgSPLH)
  // When rates are at target, actual hours = model hours → dollarGap = 0.

  static final List<WeekRecord> weekHistory =
      List<WeekRecord>.unmodifiable(_rawWeekHistory.map(_withDerivedWeekLever));

  static final List<WeekRecord> _rawWeekHistory = [

    // ── W12 — covers_down: volume −4% vs plan, rates on target ──────────────
    // fohHours = round(1152/4.58) = 252 · bohHours = round(1152×41.79/180.07) = 267
    WeekRecord(
      weekId: '2026-W12', weekLabel: 'Mar 17',
      totalCovers: 1152, forecastCovers: 1200,
      totalFohHours: 252, totalBohHours: 267,
      avgPPA: 41.79, avgCPLH: 4.57,   // 1152÷252 = 4.571
      theoreticalLaborPct: 20.48, actualLaborPct: 20.48,
      dollarGap: 0.00,
      primaryLeverId: 'covers_down', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W11 — covers_up: volume +5% vs plan, rates on target ────────────────
    // fohHours = round(1260/4.58) = 275 · bohHours = round(1260×41.79/180.07) = 292
    WeekRecord(
      weekId: '2026-W11', weekLabel: 'Mar 10',
      totalCovers: 1260, forecastCovers: 1200,
      totalFohHours: 275, totalBohHours: 292,
      avgPPA: 41.79, avgCPLH: 4.58,   // 1260÷275 = 4.582
      theoreticalLaborPct: 20.48, actualLaborPct: 20.46,
      dollarGap: 0.00,
      primaryLeverId: 'covers_up', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W10 — ppa_down: avgPPA −5% (39.70 vs 41.79), other rates on target ──
    // fohHours = round(1200/4.58) = 262 · bohHours = round(1200×39.70/180.07) = 265
    WeekRecord(
      weekId: '2026-W10', weekLabel: 'Mar 3',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 265,
      avgPPA: 39.70, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 20.95,
      dollarGap: 0.00,
      primaryLeverId: 'ppa_down', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W09 — ppa_up: avgPPA +8% (45.13 vs 41.79), other rates on target ─────
    // fohHours = 262 · bohHours = round(1200×45.13/180.07) = 301
    WeekRecord(
      weekId: '2026-W09', weekLabel: 'Feb 24',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 301,
      avgPPA: 45.13, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 19.85,
      dollarGap: 0.00,
      primaryLeverId: 'ppa_up', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W08 — cplh_down: CPLH −10% (4.12 vs 4.58), BOH on target ────────────
    // fohHours = round(1200/4.12) = 291 · bohHours = 279
    // dollarGap = 10758.15 − 10279.65 = 478.50
    WeekRecord(
      weekId: '2026-W08', weekLabel: 'Feb 17',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 291, totalBohHours: 279,
      avgPPA: 41.79, avgCPLH: 4.12,
      theoreticalLaborPct: 20.48, actualLaborPct: 21.45,
      dollarGap: 478.50,
      primaryLeverId: 'cplh_down', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W07 — cplh_up: CPLH +10% (5.04 vs 4.58), BOH on target ─────────────
    // fohHours = round(1200/5.04) = 238 · bohHours = 279
    // dollarGap = 9883.65 − 10279.65 = −396.00
    WeekRecord(
      weekId: '2026-W07', weekLabel: 'Feb 10',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 238, totalBohHours: 279,
      avgPPA: 41.79, avgCPLH: 5.04,
      theoreticalLaborPct: 20.48, actualLaborPct: 19.71,
      dollarGap: -396.00,
      primaryLeverId: 'cplh_up', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W06 — splh_down: SPLH −10% (162.06 vs 180.07), FOH on target ─────────
    // fohHours = 262 · bohHours = round(1200×41.79/162.06) = 310
    // dollarGap = 10941.50 − 10279.65 = 661.85
    WeekRecord(
      weekId: '2026-W06', weekLabel: 'Feb 3',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 310,
      avgPPA: 41.79, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 21.82,
      dollarGap: 661.85,
      primaryLeverId: 'splh_down', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W05 — splh_up: SPLH +10% (198.08 vs 180.07), FOH on target ──────────
    // fohHours = 262 · bohHours = round(1200×41.79/198.08) = 253
    // dollarGap = 9724.55 − 10279.65 = −555.10
    WeekRecord(
      weekId: '2026-W05', weekLabel: 'Jan 27',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 253,
      avgPPA: 41.79, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 19.39,
      dollarGap: -555.10,
      primaryLeverId: 'splh_up', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W04 — foh_wage_up: FOH blended wage +9% (17.99 vs 16.50) ─────────────
    // Hours on target. dollarGap = 10670.03 − 10279.65 = 390.38
    WeekRecord(
      weekId: '2026-W04', weekLabel: 'Jan 20',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 279,
      avgPPA: 41.79, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 21.27,
      dollarGap: 390.38,
      primaryLeverId: 'foh_wage_up', shiftsCompleted: 14,
      blendedFohWage: 17.99, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W03 — foh_wage_down: FOH blended wage −10% (14.85 vs 16.50) ──────────
    // Hours on target. dollarGap = 9847.35 − 10279.65 = −432.30
    WeekRecord(
      weekId: '2026-W03', weekLabel: 'Jan 13',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 279,
      avgPPA: 41.79, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 19.63,
      dollarGap: -432.30,
      primaryLeverId: 'foh_wage_down', shiftsCompleted: 14,
      blendedFohWage: 14.85, blendedBohWage: 21.35,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W02 — boh_wage_up: BOH blended wage +13% (24.13 vs 21.35) ────────────
    // Hours on target. dollarGap = 11055.27 − 10279.65 = 775.62
    WeekRecord(
      weekId: '2026-W02', weekLabel: 'Jan 6',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 279,
      avgPPA: 41.79, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 22.04,
      dollarGap: 775.62,
      primaryLeverId: 'boh_wage_up', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 24.13,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),

    // ── W01 — boh_wage_down: BOH blended wage −13% (18.57 vs 21.35) ─────────
    // Hours on target. dollarGap = 9504.03 − 10279.65 = −775.62
    WeekRecord(
      weekId: '2026-W01', weekLabel: 'Dec 30',
      totalCovers: 1200, forecastCovers: 1200,
      totalFohHours: 262, totalBohHours: 279,
      avgPPA: 41.79, avgCPLH: 4.58,
      theoreticalLaborPct: 20.48, actualLaborPct: 18.95,
      dollarGap: -775.62,
      primaryLeverId: 'boh_wage_down', shiftsCompleted: 14,
      blendedFohWage: 16.50, blendedBohWage: 18.57,
      targetSourceType: 'system_baseline',
      targetCPLH: 4.58, targetSPLH: 180.0, targetPPA: 41.50,
      targetFohWage: 16.50, targetBohWage: 21.35,
    ),
  ];

  // ── Historical closed shifts ──────────────────────────────────────────────
  // W05–W12 (60-day window) are expanded to full 14-shift weeks via
  // _generateWeekShifts so that shift-level sums match WeekRecord rollups.
  // W01–W04 (outside 60-day window) keep sparse teaching shifts only.
  //
  // Teaching shifts carry specific lever assignments for HistoryPatternBuilder.
  // Fill shifts use ON_MODEL (filtered out by HistoryPatternBuilder).

  /// Weeks within the 60-day window that get full 14-shift expansion.
  static const _sixtyDayWeekIds = {
    '2026-W12', '2026-W11', '2026-W10', '2026-W09',
    '2026-W08', '2026-W07', '2026-W06', '2026-W05',
  };

  /// 14 daypart slots per complete week (Mon–Sun).
  static const _weekSlots = [
    ('Mon', 'lunch'),    ('Mon', 'dinner'),
    ('Tue', 'lunch'),    ('Tue', 'dinner'),
    ('Wed', 'lunch'),    ('Wed', 'dinner'),
    ('Thu', 'lunch'),    ('Thu', 'dinner'),
    ('Fri', 'lunch'),    ('Fri', 'dinner'),    ('Fri', 'late_night'),
    ('Sat', 'dinner'),   ('Sat', 'late_night'),
    ('Sun', 'dinner'),
  ];

  /// Day-shape cover weights (unnormalized). Derived from
  /// ScheduleForecastDefaults at 1200 weekly total with daypart splits:
  /// Mon–Thu lunch/dinner = 45%/55%, Fri = 45%/40%/15%,
  /// Sat dinner/late_night = 77.5%/22.5%, Sun dinner = 100%.
  static const _slotWeights = <(String, String), double>{
    ('Mon', 'lunch'):      63.0,  ('Mon', 'dinner'):      77.0,
    ('Tue', 'lunch'):      67.5,  ('Tue', 'dinner'):      82.5,
    ('Wed', 'lunch'):      72.0,  ('Wed', 'dinner'):      88.0,
    ('Thu', 'lunch'):      85.5,  ('Thu', 'dinner'):     104.5,
    ('Fri', 'lunch'):      99.0,  ('Fri', 'dinner'):      88.0,
    ('Fri', 'late_night'): 33.0,
    ('Sat', 'dinner'):    178.25, ('Sat', 'late_night'):  51.75,
    ('Sun', 'dinner'):    110.0,
  };

  /// Teaching shifts — the original hand-authored shifts with specific levers.
  /// These are preserved byte-identical; fill shifts are generated around them.
  /// 7.58.4: each row is round-tripped through `LaborModel.determineLever`
  /// at build time so the persisted lever id matches engine truth.
  static final List<ShiftRecord> _teachingShifts =
      List<ShiftRecord>.unmodifiable(_rawTeachingShifts.map(_withDerivedLever));

  static final List<ShiftRecord> _rawTeachingShifts = [
    // ── W12 — Mar 17 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W12', dayLabel: 'Tue', daypart: 'dinner', status: 'closed',
        covers: 178, forecastCovers: 200, ppa: 42.00, cplh: 3.90, splh: 172.0,
        fohHours: 46, bohHours: 44, primaryLever: 'CPLH_DOWN'),
    ShiftRecord(weekId: '2026-W12', dayLabel: 'Thu', daypart: 'dinner', status: 'closed',
        covers: 182, forecastCovers: 200, ppa: 42.20, cplh: 3.95, splh: 174.0,
        fohHours: 46, bohHours: 44, primaryLever: 'CPLH_DOWN'),
    ShiftRecord(weekId: '2026-W12', dayLabel: 'Wed', daypart: 'dinner', status: 'closed',
        covers: 205, forecastCovers: 200, ppa: 42.50, cplh: 5.25, splh: 180.0,
        fohHours: 39, bohHours: 48, primaryLever: 'CPLH_UP'),

    // ── W11 — Mar 10 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W11', dayLabel: 'Tue', daypart: 'dinner', status: 'closed',
        covers: 174, forecastCovers: 200, ppa: 41.80, cplh: 3.87, splh: 171.5,
        fohHours: 45, bohHours: 43, primaryLever: 'CPLH_DOWN'),
    ShiftRecord(weekId: '2026-W11', dayLabel: 'Thu', daypart: 'dinner', status: 'closed',
        covers: 180, forecastCovers: 200, ppa: 42.00, cplh: 3.91, splh: 173.0,
        fohHours: 46, bohHours: 44, primaryLever: 'CPLH_DOWN'),
    ShiftRecord(weekId: '2026-W11', dayLabel: 'Wed', daypart: 'dinner', status: 'closed',
        covers: 208, forecastCovers: 200, ppa: 42.30, cplh: 5.20, splh: 179.5,
        fohHours: 40, bohHours: 49, primaryLever: 'CPLH_UP'),

    // ── W10 — Mar 3 ──────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W10', dayLabel: 'Fri', daypart: 'dinner', status: 'closed',
        covers: 195, forecastCovers: 200, ppa: 42.10, cplh: 4.50, splh: 162.0,
        fohHours: 43, bohHours: 51, primaryLever: 'SPLH_DOWN'),
    ShiftRecord(weekId: '2026-W10', dayLabel: 'Wed', daypart: 'dinner', status: 'closed',
        covers: 198, forecastCovers: 200, ppa: 45.50, cplh: 4.55, splh: 180.5,
        fohHours: 43, bohHours: 50, primaryLever: 'PPA_UP'),

    // ── W09 — Feb 24 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W09', dayLabel: 'Thu', daypart: 'dinner', status: 'closed',
        covers: 176, forecastCovers: 200, ppa: 41.90, cplh: 3.85, splh: 171.0,
        fohHours: 46, bohHours: 43, primaryLever: 'CPLH_DOWN'),

    // ── W08 — Feb 17 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W08', dayLabel: 'Tue', daypart: 'dinner', status: 'closed',
        covers: 172, forecastCovers: 200, ppa: 41.70, cplh: 3.83, splh: 170.5,
        fohHours: 45, bohHours: 43, primaryLever: 'CPLH_DOWN'),

    // ── W07 — Feb 10 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W07', dayLabel: 'Fri', daypart: 'dinner', status: 'closed',
        covers: 193, forecastCovers: 200, ppa: 42.00, cplh: 4.48, splh: 161.5,
        fohHours: 43, bohHours: 50, primaryLever: 'SPLH_DOWN'),
    ShiftRecord(weekId: '2026-W07', dayLabel: 'Thu', daypart: 'dinner', status: 'closed',
        covers: 207, forecastCovers: 200, ppa: 42.40, cplh: 5.18, splh: 179.0,
        fohHours: 40, bohHours: 49, primaryLever: 'CPLH_UP'),

    // ── W06 — Feb 3 ──────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W06', dayLabel: 'Sat', daypart: 'dinner', status: 'closed',
        covers: 190, forecastCovers: 200, ppa: 41.80, cplh: 4.46, splh: 160.0,
        fohHours: 43, bohHours: 50, primaryLever: 'SPLH_DOWN'),

    // ── W05 — Jan 27 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W05', dayLabel: 'Tue', daypart: 'lunch', status: 'closed',
        covers: 148, forecastCovers: 170, ppa: 38.20, cplh: 4.51, splh: 178.0,
        fohHours: 33, bohHours: 32, primaryLever: 'PPA_DOWN'),

    // ── W04 — Jan 20 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W04', dayLabel: 'Fri', daypart: 'dinner', status: 'closed',
        covers: 198, forecastCovers: 200, ppa: 42.00, cplh: 4.53, splh: 180.0,
        fohHours: 44, bohHours: 46, primaryLever: 'FOH_WAGE_UP'),

    // ── W03 — Jan 13 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W03', dayLabel: 'Sat', daypart: 'dinner', status: 'closed',
        covers: 196, forecastCovers: 200, ppa: 42.10, cplh: 4.52, splh: 179.5,
        fohHours: 43, bohHours: 46, primaryLever: 'BOH_WAGE_UP'),

    // ── W02 — Jan 6 ──────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W02', dayLabel: 'Mon', daypart: 'lunch', status: 'closed',
        covers: 140, forecastCovers: 170, ppa: 41.50, cplh: 4.50, splh: 179.0,
        fohHours: 31, bohHours: 32, primaryLever: 'COVERS_DOWN'),

    // ── W01 — Dec 30 ─────────────────────────────────────────────────────────
    ShiftRecord(weekId: '2026-W01', dayLabel: 'Thu', daypart: 'dinner', status: 'closed',
        covers: 200, forecastCovers: 200, ppa: 45.30, cplh: 4.55, splh: 180.5,
        fohHours: 44, bohHours: 50, primaryLever: 'PPA_UP'),
  ];

  /// Teaching shifts grouped by weekId for generator lookup.
  static final Map<String, List<ShiftRecord>> _teachingByWeek = {
    for (final weekId in weekHistory.map((w) => w.weekId))
      weekId: _teachingShifts.where((s) => s.weekId == weekId).toList(),
  };

  /// Full historical closed shifts: 14-shift weeks for W05–W12 (60-day window),
  /// sparse teaching shifts for W01–W04 (outside window).
  static final List<ShiftRecord> historicalClosedShifts = [
    for (final week in weekHistory)
      if (_sixtyDayWeekIds.contains(week.weekId))
        ..._generateWeekShifts(
          weekId: week.weekId,
          weekTarget: week,
          existingShifts: _teachingByWeek[week.weekId] ?? [],
        )
      else
        ...(_teachingByWeek[week.weekId] ?? []),
  ];

  /// Generates a complete 14-shift week from a WeekRecord target and existing
  /// teaching shifts. Fill shifts use ON_MODEL lever and week-level PPA.
  /// Covers, FOH hours, and BOH hours sum exactly to the WeekRecord targets.
  static List<ShiftRecord> _generateWeekShifts({
    required String weekId,
    required WeekRecord weekTarget,
    required List<ShiftRecord> existingShifts,
  }) {
    // 1. Map existing teaching shifts by slot
    final existingBySlot = <(String, String), ShiftRecord>{};
    for (final s in existingShifts) {
      existingBySlot[(s.dayLabel, s.daypart)] = s;
    }

    // 2. Subtract existing contributions from targets
    int remainCovers = weekTarget.totalCovers;
    int remainFoh = weekTarget.totalFohHours;
    int remainBoh = weekTarget.totalBohHours;
    double remainSales = weekTarget.totalCovers * weekTarget.avgPPA;
    for (final s in existingShifts) {
      remainCovers -= s.covers;
      remainFoh -= s.fohHours;
      remainBoh -= s.bohHours;
      remainSales -= s.covers * s.ppa;
    }

    // 3. Identify missing slots and their proportional weights
    final missingSlots = <(String, String)>[];
    double totalMissingWeight = 0;
    for (final slot in _weekSlots) {
      if (!existingBySlot.containsKey(slot)) {
        missingSlots.add(slot);
        totalMissingWeight += _slotWeights[slot]!;
      }
    }

    // 4. Distribute remaining covers/hours proportionally across fill slots
    final fillShifts = <ShiftRecord>[];
    int allocCovers = 0, allocFoh = 0, allocBoh = 0;
    final fillPPA = remainCovers > 0 ? remainSales / remainCovers : weekTarget.avgPPA;

    for (int i = 0; i < missingSlots.length; i++) {
      final slot = missingSlots[i];
      final w = _slotWeights[slot]! / totalMissingWeight;
      final isLast = (i == missingSlots.length - 1);

      final covers = isLast ? remainCovers - allocCovers : (remainCovers * w).round();
      final foh = isLast ? remainFoh - allocFoh : (remainFoh * w).round();
      final boh = isLast ? remainBoh - allocBoh : (remainBoh * w).round();
      allocCovers += covers;
      allocFoh += foh;
      allocBoh += boh;

      final cplh = foh > 0 ? covers / foh : weekTarget.avgCPLH;
      final splh = boh > 0 ? (covers * fillPPA) / boh : 180.0;
      final ppa = double.parse(fillPPA.toStringAsFixed(2));
      final cplhRounded = double.parse(cplh.toStringAsFixed(2));
      final splhRounded = double.parse(splh.toStringAsFixed(2));

      // 7.58.4: round-trip the fill shift's lever through
      // `determineLever` so the engine — not the hand-coded `'ON_MODEL'`
      // sentinel — owns the persisted id. Fill shifts hit the
      // empty-candidate fallback when actuals match forecast at target
      // rates; the engine semantics for that case are out of scope for
      // this slice (see Finding F-2).
      final fillLever = LaborModel.determineLever(
        actualCovers: covers,
        forecastCovers: covers,
        avgCPLH: cplhRounded,
        avgPPA: ppa,
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetPPA: BaselineData.derivedTargetPPA,
        avgSPLH: splhRounded,
        targetSPLH: BaselineData.derivedTargetSPLH,
      );

      fillShifts.add(ShiftRecord(
        weekId: weekId,
        dayLabel: slot.$1,
        daypart: slot.$2,
        status: 'closed',
        covers: covers,
        forecastCovers: covers,
        ppa: ppa,
        cplh: cplhRounded,
        splh: splhRounded,
        fohHours: foh,
        bohHours: boh,
        primaryLever: fillLever.toUpperCase(),
      ));
    }

    // 5. Merge in slot order
    final allShifts = <ShiftRecord>[];
    int fillIdx = 0;
    for (final slot in _weekSlots) {
      if (existingBySlot.containsKey(slot)) {
        allShifts.add(existingBySlot[slot]!);
      } else {
        allShifts.add(fillShifts[fillIdx++]);
      }
    }

    // 6. Assert sum invariants (debug mode only)
    assert(allShifts.length == 14, '$weekId: expected 14 shifts, got ${allShifts.length}');
    assert(allShifts.fold<int>(0, (s, r) => s + r.covers) == weekTarget.totalCovers,
        '$weekId covers mismatch');
    assert(allShifts.fold<int>(0, (s, r) => s + r.fohHours) == weekTarget.totalFohHours,
        '$weekId FOH mismatch');
    assert(allShifts.fold<int>(0, (s, r) => s + r.bohHours) == weekTarget.totalBohHours,
        '$weekId BOH mismatch');

    return allShifts;
  }

  // ── Daypart-level pattern records — teaching layer ────────────────────────
  // One record per notable daypart signal across 17 historical shifts.
  // Used by HistoryTeachingAnalyzer to surface recurring patterns.
  //
  // Expected analyzer output:
  //   mostCommonLeakId    = 'cplh_down'  (count 6)
  //   topLeakDayparts     = ['Thu Dinner', 'Tue Dinner']
  //   mostCommonLeakSide  = 'FOH ONLY'
  //   benchmarkDayparts   = ['Wed Dinner', 'Thu Dinner']
  static const List<HistoryPatternRecord> historyPatternRecords = [
    // ── W12 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W12', weekLabel: 'Mar 17', dayLabel: 'Tue', daypart: 'dinner', leverId: 'cplh_down', isBenchmark: false),
    HistoryPatternRecord(weekId: '2026-W12', weekLabel: 'Mar 17', dayLabel: 'Thu', daypart: 'dinner', leverId: 'cplh_down', isBenchmark: false),
    HistoryPatternRecord(weekId: '2026-W12', weekLabel: 'Mar 17', dayLabel: 'Wed', daypart: 'dinner', leverId: 'cplh_up',   isBenchmark: true),
    // ── W11 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W11', weekLabel: 'Mar 10', dayLabel: 'Tue', daypart: 'dinner', leverId: 'cplh_down', isBenchmark: false),
    HistoryPatternRecord(weekId: '2026-W11', weekLabel: 'Mar 10', dayLabel: 'Thu', daypart: 'dinner', leverId: 'cplh_down', isBenchmark: false),
    HistoryPatternRecord(weekId: '2026-W11', weekLabel: 'Mar 10', dayLabel: 'Wed', daypart: 'dinner', leverId: 'cplh_up',   isBenchmark: true),
    // ── W10 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W10', weekLabel: 'Mar 3',  dayLabel: 'Fri', daypart: 'dinner', leverId: 'splh_down', isBenchmark: false),
    HistoryPatternRecord(weekId: '2026-W10', weekLabel: 'Mar 3',  dayLabel: 'Wed', daypart: 'dinner', leverId: 'ppa_up',    isBenchmark: true),
    // ── W09 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W09', weekLabel: 'Feb 24', dayLabel: 'Thu', daypart: 'dinner', leverId: 'cplh_down', isBenchmark: false),
    // ── W08 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W08', weekLabel: 'Feb 17', dayLabel: 'Tue', daypart: 'dinner', leverId: 'cplh_down', isBenchmark: false),
    // ── W07 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W07', weekLabel: 'Feb 10', dayLabel: 'Fri', daypart: 'dinner', leverId: 'splh_down', isBenchmark: false),
    HistoryPatternRecord(weekId: '2026-W07', weekLabel: 'Feb 10', dayLabel: 'Thu', daypart: 'dinner', leverId: 'cplh_up',   isBenchmark: true),
    // ── W06 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W06', weekLabel: 'Feb 3',  dayLabel: 'Sat', daypart: 'dinner', leverId: 'splh_down', isBenchmark: false),
    // ── W05 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W05', weekLabel: 'Jan 27', dayLabel: 'Tue', daypart: 'lunch',  leverId: 'ppa_down',  isBenchmark: false),
    // ── W04 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W04', weekLabel: 'Jan 20', dayLabel: 'Fri', daypart: 'dinner', leverId: 'foh_wage_up', isBenchmark: false),
    // ── W03 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W03', weekLabel: 'Jan 13', dayLabel: 'Sat', daypart: 'dinner', leverId: 'boh_wage_up', isBenchmark: false),
    // ── W02 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W02', weekLabel: 'Jan 6',  dayLabel: 'Mon', daypart: 'lunch',  leverId: 'covers_down', isBenchmark: false),
    // ── W01 ──────────────────────────────────────────────────────────────────
    HistoryPatternRecord(weekId: '2026-W01', weekLabel: 'Dec 30', dayLabel: 'Thu', daypart: 'dinner', leverId: 'ppa_up',    isBenchmark: true),
  ];
}
