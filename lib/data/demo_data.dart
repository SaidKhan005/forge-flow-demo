import '../models/history_pattern_record.dart';
import '../models/shift_record.dart';
import '../models/week_record.dart';

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
  // ── Current-week shifts (14 total: 9 closed + 5 projected) ──────────────
  static final List<ShiftRecord> currentWeekShifts = [

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

  static final List<WeekRecord> weekHistory = [

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
    ),
  ];

  // ── Historical closed shifts — teaching layer source of truth ────────────
  // One representative closed shift per notable daypart signal across weeks
  // W01–W12.  HistoryPatternBuilder.fromClosedShifts() reads these records and
  // produces HistoryPatternRecords for HistoryTeachingAnalyzer.
  //
  // primaryLever is stored in uppercase underscore form (matches production
  // convention). normalizedLeverId lowercases it at read time.
  //
  // Numeric values are simple and plausible — not re-derived from lever logic.
  // The teaching summary in Phase 2 relies on stored shift levers, not
  // re-computed levers.
  static final List<ShiftRecord> historicalClosedShifts = [
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
