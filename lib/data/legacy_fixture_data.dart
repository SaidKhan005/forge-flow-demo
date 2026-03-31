// Forge & Flow — Single source of truth.
// Every number in the app traces to this file.
// Do not hardcode values elsewhere in the codebase.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/labor_model.dart';

// ─── ISO week-id helper ───────────────────────────────────────────────────────
// Returns "YYYY-Www" for the Monday-anchored ISO week containing [date].

String getWeekId(DateTime date) {
  final monday = date.subtract(Duration(days: date.weekday - 1));
  final startOfYear = DateTime(monday.year, 1, 1);
  final firstMonday = startOfYear.weekday <= 4
      ? startOfYear.subtract(Duration(days: startOfYear.weekday - 1))
      : startOfYear.add(Duration(days: 8 - startOfYear.weekday));
  final weekNumber =
      ((monday.difference(firstMonday).inDays) / 7).floor() + 1;
  return '${monday.year}-W${weekNumber.toString().padLeft(2, '0')}';
}

// ─── Restaurant configuration ─────────────────────────────────────────────────

class MeridianConfig {
  static const String restaurantName = 'Barrio Legado';
  static const int seats = 120;
  static const String location = 'Atlantic Canada';

  // Weekly targets
  static const int weeklyCovers = 1200;
  static const double targetCPLH = 4.5;
  static const double opzCeilingCPLH = 5.8;
  static const double opzFloorCPLH = 3.5;
  static const double targetSPLH = 180.0;
  static const double targetPPA = 42.0;

  // Wages
  static const double fohWage = 16.50;
  static const double bohWage = 21.35;

  // Theoretical labor
  static const int requiredFohHours = 267;
  static const int requiredBohHours = 280;
  static const double fohTheoreticalLaborDollar = 4405.0;
  static const double bohTheoreticalLaborDollar = 5978.0;
  static const double fohTheoreticalLaborPct = 8.7;
  static const double bohTheoreticalLaborPct = 11.9;
  static const double totalTheoreticalLaborPct = 20.6;
}

// ─── Demo shift snapshot — Friday dinner, 7:42 PM (shift-level) ──────────────
// Actual shift numbers vs the dinner_weekend daypart forecast (220 covers).

class ShiftSnapshot {
  static const String daypart = 'Dinner';
  static const String day = 'Friday';
  static const String time = '7:42 PM';
  static const String serviceElapsed = '3h 14m into service';

  // Shift-level actuals
  static const int actualCovers = 140;         // running count so far
  static const int shiftForecastCovers = 220;  // dinner_weekend plan
  static const int scheduledFohHours = 34;     // hours on the floor tonight
  static const int scheduledBohHours = 33;     // hours in the kitchen tonight

  // Computed shift metrics
  static const double actualPPA = 41.20;       // sales ÷ covers
  static const double actualCPLH = 4.1;        // 140 ÷ 34
  static const double actualSPLH = 174.0;      // (140 × 41.20) ÷ 33
  static const double blendedWage = 18.74;

  // Model needed for 140 covers
  static const int modelFohHours = 31;   // 140 ÷ 4.5, rounded
  static const int modelBohHours = 32;   // 140 × 42 ÷ 180, rounded

  // OPZ status — 'below' | 'in' | 'above'
  static const String opzStatus = 'in';
  static const String opzSubLabel = 'Team is producing. Watch covers.';

  // ── Runtime active lever (Prompt 7.11) ──────────────────────────────────
  // Uses the same lever-detection model as WTD/History to determine
  // which metric is the primary driver of this shift's variance.

  static String get primaryLeverId => LaborModel.determineLever(
        actualCovers: actualCovers,
        forecastCovers: shiftForecastCovers,
        avgCPLH: actualCPLH,
        avgPPA: actualPPA,
        targetCPLH: BaselineData.derivedTargetCPLH,
        targetPPA: BaselineData.derivedTargetPPA,
        avgSPLH: actualSPLH,
        targetSPLH: BaselineData.derivedTargetSPLH,
      );

  static LeverCardData get primaryLeverCard => LeverCards.all.firstWhere(
        (l) => l.id == primaryLeverId,
        orElse: () => LeverCards.coversDown,
      );
}

// ─── Week-to-date totals (9 closed shifts Mon–Fri lunch) ─────────────────────

class WeekToDate {
  static const String currentWeekId = '2026-W13';
  static const String weekLabel = 'Week of Mar 24';

  // ── 9 closed shifts: Mon L → Fri L ────────────────────────────────────────
  // covers: 154+196+158+192+162+200+165+203+150 = 1,580
  // FOH:     36+ 48+ 36+ 47+ 36+ 47+ 36+ 47+ 29 = 362
  // BOH:     37+ 50+ 37+ 48+ 37+ 49+ 37+ 48+ 30 = 373
  // sales ≈ $67,180 · avgCPLH = 4.36 · avgSPLH = 180.1

  static const int totalCovers = 1580;
  static const int forecastCovers = MeridianConfig.weeklyCovers;
  static const int coversVariance = totalCovers - forecastCovers;

  static const int totalFohHours = 362;
  static const int totalBohHours = 373;

  // ── Schedule context ──────────────────────────────────────────────────────
  static const int shiftsCompleted = 9;
  static const int shiftsTotal = 14;
  static const String lastClosedDay  = 'Friday';  // last closed shift day (full name)
  static const int    closedDayNumber = 5;         // Mon=1, Tue=2, …, Fri=5, Sat=6, Sun=7

  // ── Jim Taylor model targets for actual WTD volume ────────────────────────
  // Covers: sum of shift forecasts for the 9 closed shifts
  //   5 lunches × 180 + 4 dinners × 220 = 900 + 880 = 1,780
  static const int wtdForecastCovers = 1780;

  // Model FOH hours = actual covers ÷ target CPLH = 1,580 ÷ 4.58 = 345.0 → 345
  static const int modelFohHoursWtd = 345;

  // Model BOH hours = actual sales ÷ target SPLH = $67,180 ÷ $180.07 = 373.1 → 373
  static const int modelBohHoursWtd = 373;

  // ── Rate metrics (WTD actuals from 9 closed shifts) ───────────────────────
  static const double avgPPA          = 42.52;  // $67,180 ÷ 1,580
  static const double avgCPLH         =  4.36;  // 1,580 ÷ 362
  static const double avgSPLH         = 180.1;  // $67,180 ÷ 373
  static const double avgBlendedWage  = 18.96;  // (362×16.50 + 373×21.35) ÷ 735
  // Demo blended wages — same as target (no wage lever fires for demo WTD)
  static const double blendedFohWage  = MeridianConfig.fohWage;
  static const double blendedBohWage  = MeridianConfig.bohWage;

  // Theoretical blended wage = weighted avg at model hours (345 FOH, 373 BOH)
  static const double theoreticalBlendedWage = 19.02; // (345×16.50 + 373×21.35) / 718

  // ── Labor % (WTD) ─────────────────────────────────────────────────────────
  static const int theoreticalFohHours = MeridianConfig.requiredFohHours; // full-week model
  static const int theoreticalBohHours = MeridianConfig.requiredBohHours; // full-week model
  // WTD variances use model hours for actual volume (Taylor Ch. 10)
  static const int fohHoursVariance = totalFohHours - modelFohHoursWtd; // 362 − 345 = +17
  static const int bohHoursVariance = totalBohHours - modelBohHoursWtd; // 373 − 373 = 0

  static const double theoreticalFohLaborPct = MeridianConfig.fohTheoreticalLaborPct;
  static const double actualFohLaborPct = 9.7;
  static const double fohLaborPctVariance = actualFohLaborPct - theoreticalFohLaborPct; // +1.0

  static const double theoreticalBohLaborPct = MeridianConfig.bohTheoreticalLaborPct;
  static const double actualBohLaborPct = 12.9;
  static const double bohLaborPctVariance = actualBohLaborPct - theoreticalBohLaborPct; // +1.0

  static const double theoreticalTotalLaborPct = MeridianConfig.totalTheoreticalLaborPct;
  static const double actualTotalLaborPct = 22.6;
  static const double totalLaborPctVariance =
      actualTotalLaborPct - theoreticalTotalLaborPct; // +2.0

  // ── Dollar impact ─────────────────────────────────────────────────────────
  static const double dollarGapWeekly    = 958.0;
  static const double dollarGapAnnualized = 49816.0;
  static const String annualizedContext  = 'At \$3M annual sales. One location. Recoverable.';

  static const String fohExcessCost = '\$215';
  static const String bohExcessCost = '\$214 + overtime';

  static const String plainLanguageRead =
      'Covers ran light. Schedule −13 FOH hours next week.';

  // ── Projected full-week totals (closed actuals + 5 projected at 20.6%) ───
  // Used by Projected Total Row in Full Week section.
  static const double projTargetLaborPct  = 20.6;
  static const double projActualLaborPct  = 21.4;
  static const double projVariancePts     =  0.8;
  static const double projDollarGapWeekly = 623.0;
  static const double projDollarGapAnnual = 32396.0;
}

// ─── Weekly variance — delegates to WeekToDate ────────────────────────────────

class WeeklyVariance {
  static const String weekLabel = WeekToDate.weekLabel;

  static const int theoreticalCovers = WeekToDate.forecastCovers;
  static const int actualCovers = WeekToDate.totalCovers;
  static const int coversVariance = WeekToDate.coversVariance;

  static const int theoreticalFohHours = WeekToDate.theoreticalFohHours;
  static const int actualFohHours = WeekToDate.totalFohHours;
  static const int fohHoursVariance = WeekToDate.fohHoursVariance;

  static const int theoreticalBohHours = WeekToDate.theoreticalBohHours;
  static const int actualBohHours = WeekToDate.totalBohHours;
  static const int bohHoursVariance = WeekToDate.bohHoursVariance;

  static const double theoreticalFohLaborPct = WeekToDate.theoreticalFohLaborPct;
  static const double actualFohLaborPct = WeekToDate.actualFohLaborPct;
  static const double fohLaborPctVariance = WeekToDate.fohLaborPctVariance;

  static const double theoreticalBohLaborPct = WeekToDate.theoreticalBohLaborPct;
  static const double actualBohLaborPct = WeekToDate.actualBohLaborPct;
  static const double bohLaborPctVariance = WeekToDate.bohLaborPctVariance;

  static const double theoreticalTotalLaborPct = WeekToDate.theoreticalTotalLaborPct;
  static const double actualTotalLaborPct = WeekToDate.actualTotalLaborPct;
  static const double totalLaborPctVariance = WeekToDate.totalLaborPctVariance;

  static const double dollarGapWeekly = WeekToDate.dollarGapWeekly;
  static const double dollarGapAnnualized = WeekToDate.dollarGapAnnualized;
  static const String annualizedContext = WeekToDate.annualizedContext;

  static const String fohExcessCost = WeekToDate.fohExcessCost;
  static const String bohExcessCost = WeekToDate.bohExcessCost;

  static const String plainLanguageRead = WeekToDate.plainLanguageRead;
}

// ─── Lever card model ─────────────────────────────────────────────────────────

enum LeverDirection { favorable, unfavorable }
enum LeverSide { foh, boh, both }

class LeverCardData {
  final String id;
  final String metric;
  final String causeCategory;
  final LeverSide side;
  final LeverDirection direction;
  final String whatHappened;
  final String whatToDo;
  final String teachingNote;    // replaces "WHAT TO DO" in the lever card UI

  // ── Interpretation fields — consumed by widgets, never re-derived ────────
  final String shortLabel;      // badge text: 'COVERS', 'CPLH', 'PPA', 'SPLH', 'WAGE'
  final bool isFavorable;       // true = positive (green); false = unfavorable (red)
  final String weekActionLine;  // kept for backwards compat; no longer rendered in UI

  const LeverCardData({
    required this.id,
    required this.metric,
    required this.causeCategory,
    required this.side,
    required this.direction,
    required this.whatHappened,
    required this.whatToDo,
    required this.teachingNote,
    required this.shortLabel,
    required this.isFavorable,
    required this.weekActionLine,
  });

  String get sideLabel {
    switch (side) {
      case LeverSide.foh:
        return 'FOH ONLY';
      case LeverSide.boh:
        return 'BOH ONLY';
      case LeverSide.both:
        return 'BOTH SIDES';
    }
  }
}

class LeverCards {
  static const coversDown = LeverCardData(
    id: 'covers_down',
    metric: 'COVERS CAME IN LIGHT',
    causeCategory: 'VOLUME',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened: 'Guest volume came in below plan. FOH hours did not flex down to match.',
    whatToDo:
        'Pull FOH hours from Fri, Sat, and Sun shifts before they open. '
        'Volume is tracking below plan — don\'t carry over-scheduled hours into the weekend.',
    teachingNote:
        'Study forecast accuracy and hour flex by daypart. If this repeats in the same dayparts, '
        'the leak is forecast and schedule discipline, not a one-week miss.',
    shortLabel: 'COVERS',
    isFavorable: false,
    weekActionLine: 'Schedule fewer FOH hours to match actual cover pace.',
  );

  static const coversUp = LeverCardData(
    id: 'covers_up',
    metric: 'VOLUME CAME IN ABOVE PLAN',
    causeCategory: 'VOLUME',
    side: LeverSide.both,
    direction: LeverDirection.favorable,
    whatHappened:
        'Volume came in above what you planned for, and both sides of the house improved. '
        'More guests across the same hours -the sales denominator grew and labor landed better than model.',
    whatToDo:
        'If this is happening consistently, your weekly cover forecast is running conservative. '
        'Adjust it upward for next week so your schedule matches what your restaurant is actually doing.',
    teachingNote:
        'Study whether forecast is consistently conservative. If this repeats, update the weekly forecast '
        'and protect the staffing pattern that absorbed the volume.',
    shortLabel: 'COVERS',
    isFavorable: true,
    weekActionLine: 'Raise your weekly cover forecast for next week.',
  );

  static const ppaDown = LeverCardData(
    id: 'ppa_down',
    metric: 'PPA RUNNING BELOW TARGET',
    causeCategory: 'GUEST EXPERIENCE',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'Guests spent less per head than your target. When check-backs stop happening and upsells die, '
        'this is usually the first place it shows up. Check your CPLH for this shift -if the team was '
        'above their ceiling, they were stretched too thin to take care of the guest properly.',
    whatToDo:
        'Cross-reference your CPLH. If it was above the OPZ ceiling, the fix is a staffing level '
        'adjustment, not a training conversation. A team that is running too lean cannot sell. Give them the floor to do it.',
    teachingNote:
        'Study whether this repeats when FOH productivity runs above the OPZ ceiling. '
        'If PPA drops cluster in the same dayparts, guest attention is being lost there.',
    shortLabel: 'PPA',
    isFavorable: false,
    weekActionLine: 'Cross-check CPLH. If above ceiling, fix staffing first.',
  );

  static const ppaUp = LeverCardData(
    id: 'ppa_up',
    metric: 'PPA ABOVE TARGET',
    causeCategory: 'GUEST EXPERIENCE',
    side: LeverSide.both,
    direction: LeverDirection.favorable,
    whatHappened:
        'Guests spent more per head. Check-backs happened. Upsells landed. The team had enough '
        'floor to take care of people, and people responded. This is exactly what the OPZ is designed to produce.',
    whatToDo:
        'Write down what made this shift work -covers, daypart, who was on floor, how the team was deployed. '
        'You cannot replicate what you do not understand. This is a benchmark shift.',
    teachingNote:
        'Treat this as a benchmark pattern. Study staffing level, deployment, and guest behavior '
        'in these dayparts and look for repeats.',
    shortLabel: 'PPA',
    isFavorable: true,
    weekActionLine: 'Write down what made this week work. Replicate it.',
  );

  static const cplhDown = LeverCardData(
    id: 'cplh_down',
    metric: 'CPLH BELOW TARGET',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'More front-of-house hours were scheduled than the covers required. Servers had too few tables. '
        'Hours were paid that the volume did not need. Your BOH is holding fine -this is a front-of-house '
        'scheduling decision, and the fix is straightforward.',
    whatToDo:
        'Before you build next week\'s FOH schedule, start here: forecasted covers divided by your CPLH '
        'target of 4.5. That number is your required FOH hours. Build from that, not from last week\'s sheet.',
    teachingNote:
        'Study whether this repeats in the same FOH dayparts. If it does, hours are being built above '
        'actual cover demand there.',
    shortLabel: 'CPLH',
    isFavorable: false,
    weekActionLine: 'Start next week\'s FOH schedule from covers ÷ 4.5.',
  );

  static const cplhUp = LeverCardData(
    id: 'cplh_up',
    metric: 'CPLH ABOVE TARGET',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.favorable,
    whatHappened:
        'Front-of-house hours were well-matched to the volume that came in. The team moved efficiently '
        'and labor landed below model. As long as CPLH stayed inside the OPZ ceiling, this is what a '
        'well-scheduled shift looks like.',
    whatToDo:
        'Check your OPZ position. If CPLH stayed below the ceiling, document this shift -staffing level, '
        'cover count, daypart. That is your replicable setup. If CPLH pushed above the ceiling, the team '
        'was stretched and service likely felt it.',
    teachingNote:
        'Treat this as a benchmark FOH productivity pattern if service held. Study which dayparts can '
        'sustain it without pushing above the OPZ ceiling.',
    shortLabel: 'CPLH',
    isFavorable: true,
    weekActionLine: 'Document this shift — that is your replicable setup.',
  );

  static const splhDown = LeverCardData(
    id: 'splh_down',
    metric: 'SPLH BELOW TARGET',
    causeCategory: 'KITCHEN PRODUCTIVITY',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The kitchen is generating less sales per hour than your model requires. Your FOH is unaffected -'
        'this is a back-of-house issue. It could be ticket times running slow, or it could be that BOH '
        'was simply overstaffed for the sales volume that came in.',
    whatToDo:
        'Check two things: kitchen ticket time logs, and BOH hours against actual sales. If ticket times '
        'were clean, you have an overstaffing issue. If ticket times were slow, you have a throughput issue. '
        'They are different problems with different fixes.',
    teachingNote:
        'Study recurring kitchen leaks by daypart. If this repeats in the same BOH dayparts, inspect '
        'throughput, deployment, and station load there.',
    shortLabel: 'SPLH',
    isFavorable: false,
    weekActionLine: 'Pull BOH ticket-time logs. Identify overstaffed positions.',
  );

  static const splhUp = LeverCardData(
    id: 'splh_up',
    metric: 'SPLH ABOVE TARGET',
    causeCategory: 'KITCHEN PRODUCTIVITY',
    side: LeverSide.boh,
    direction: LeverDirection.favorable,
    whatHappened:
        'The kitchen is generating more sales per hour than your model. Ticket times are likely clean and '
        'the BOH is right-sized for what came in. Your FOH is unaffected. This is a well-run kitchen shift.',
    whatToDo:
        'Note your BOH configuration for this shift -who was on which station, what the lineup looked like, '
        'how prep was staged. That is your replicable kitchen setup. Write it down before the next roster goes out.',
    teachingNote:
        'Treat this as a benchmark kitchen pattern. Study ticket flow, prep readiness, and station setup '
        'in these dayparts.',
    shortLabel: 'SPLH',
    isFavorable: true,
    weekActionLine: 'Document your BOH configuration. Use it as the baseline.',
  );

  static const fohWageUp = LeverCardData(
    id: 'foh_wage_up',
    metric: 'FOH BLENDED WAGE ABOVE MODEL',
    causeCategory: 'WAGE MIX',
    side: LeverSide.foh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The hours were right. The cost attached to those hours was not. FOH blended wage ran above your '
        'model rate, which usually means someone went into overtime, or a higher-cost role covered a position '
        'they do not normally fill. Your BOH is unaffected.',
    whatToDo:
        'Pull FOH clock-out times and check role assignments for this shift. Identify who went over their '
        'hours or who covered outside their normal classification. This is a deployment decision for next week, not a performance conversation.',
    teachingNote:
        'Study which FOH dayparts repeatedly trigger overtime or expensive role mix. This is a deployment '
        'pattern, not a generic labor problem.',
    shortLabel: 'WAGE',
    isFavorable: false,
    weekActionLine: 'Review FOH clock-outs and role assignments for overtime.',
  );

  static const bohWageUp = LeverCardData(
    id: 'boh_wage_up',
    metric: 'BOH BLENDED WAGE ABOVE MODEL',
    causeCategory: 'WAGE MIX',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'BOH blended wage ran above your model rate. FOH is unaffected. The most common cause is a kitchen '
        'manager or sous chef dropping to a line position during a rush and logging hours at a higher rate. '
        'The hours may have been necessary -the deployment around them may not have been.',
    whatToDo:
        'Review BOH time cards and station assignments. Look for who was working outside their usual role '
        'and what triggered it. The fix is smarter BOH deployment before the shift starts -knowing in advance '
        'which positions need coverage and at what rate.',
    teachingNote:
        'Study which BOH dayparts repeatedly trigger overtime or manager coverage. This is a deployment '
        'pattern, not a general kitchen problem.',
    shortLabel: 'WAGE',
    isFavorable: false,
    weekActionLine: 'Review BOH time cards for off-classification coverage.',
  );

  static const fohWageDown = LeverCardData(
    id: 'foh_wage_down',
    metric: 'FOH BLENDED WAGE BELOW MODEL',
    causeCategory: 'WAGE MIX',
    side: LeverSide.foh,
    direction: LeverDirection.favorable,
    whatHappened:
        'FOH blended wage came in below your model rate. Right roles on right shifts — '
        'lower-cost coverage was aligned with volume without sacrificing floor quality. Your BOH is unaffected.',
    whatToDo:
        'Document the FOH schedule configuration that produced this result. '
        'Which roles were deployed, at what hours, and against what cover pace. Replicate the deployment pattern next week.',
    teachingNote:
        'Treat this as a favorable FOH deployment pattern. Study which role mix produced it and where it repeats.',
    shortLabel: 'WAGE',
    isFavorable: true,
    weekActionLine: 'Note the FOH role mix that produced this result. Replicate it.',
  );

  static const bohWageDown = LeverCardData(
    id: 'boh_wage_down',
    metric: 'BOH BLENDED WAGE BELOW MODEL',
    causeCategory: 'WAGE MIX',
    side: LeverSide.boh,
    direction: LeverDirection.favorable,
    whatHappened:
        'BOH blended wage came in below your model rate. Kitchen deployment matched volume '
        'without overtime or off-classification coverage. Your FOH is unaffected.',
    whatToDo:
        'Document the BOH station assignments and shift times that produced this result. '
        'This is your benchmark kitchen configuration. Use it as the starting point for next week\'s lineup.',
    teachingNote:
        'Treat this as a favorable BOH deployment pattern. Study which kitchen setup produced it and where it repeats.',
    shortLabel: 'WAGE',
    isFavorable: true,
    weekActionLine: 'Note the kitchen deployment that produced this result.',
  );

  static const List<LeverCardData> all = [
    coversDown,
    coversUp,
    ppaDown,
    ppaUp,
    cplhDown,
    cplhUp,
    splhDown,
    splhUp,
    fohWageUp,
    fohWageDown,
    bohWageUp,
    bohWageDown,
  ];

  // Primary lever for demo scenario
  static const LeverCardData primaryDemoLever = coversDown;
}

// ─── Input metric card model ──────────────────────────────────────────────────

class InputMetric {
  final String name;
  final String currentFormatted;
  final String targetFormatted;
  final String deltaFormatted;
  final bool deltaUnfavorable;
  // Independent of deltaUnfavorable: controls status-line color.
  // null → falls back to !deltaUnfavorable (standard behavior).
  // Set explicitly when OPZ acceptability differs from raw delta direction
  // (e.g. CPLH below target but within OPZ → deltaUnfavorable:true, statusFavorable:true).
  final bool? statusFavorable;
  // True for the card representing the primary driver of this shift's variance.
  // Renders with a thicker border to draw the operator's eye.
  final bool isHero;
  final String statusLine;
  final bool fullWidth;

  const InputMetric({
    required this.name,
    required this.currentFormatted,
    required this.targetFormatted,
    required this.deltaFormatted,
    required this.deltaUnfavorable,
    this.statusFavorable,
    this.isHero = false,
    required this.statusLine,
    this.fullWidth = false,
  });
}

class ShiftMetrics {
  // ── Hero mapping (Prompt 7.11) ──────────────────────────────────────────
  // Maps a lever id to the metric card name that should be highlighted.

  static String heroMetricNameForLever(String leverId) {
    if (leverId.startsWith('covers_')) return 'COVERS';
    if (leverId.startsWith('ppa_')) return 'PPA';
    if (leverId.startsWith('cplh_')) return 'CPLH';
    if (leverId.startsWith('splh_')) return 'SPLH';
    if (leverId.startsWith('foh_wage_') || leverId.startsWith('boh_wage_')) {
      return 'BLENDED WAGE';
    }
    return 'COVERS';
  }

  // ── Runtime Shift cards (Prompt 7.11) ────────────────────────────────────
  // Built from current ShiftSnapshot + BaselineData truth.
  // Exactly one card has isHero = true, matching the active lever family.

  static List<InputMetric> get cards {
    final leverId = ShiftSnapshot.primaryLeverId;
    final heroName = heroMetricNameForLever(leverId);

    // ── Covers ──────────────────────────────────────────────────────────
    final coversDelta = ShiftSnapshot.actualCovers - ShiftSnapshot.shiftForecastCovers;
    final coversUnfavorable = ShiftSnapshot.actualCovers < ShiftSnapshot.shiftForecastCovers;
    final coversStatus = coversUnfavorable
        ? 'Light'
        : (ShiftSnapshot.actualCovers > ShiftSnapshot.shiftForecastCovers ? 'Heavy' : 'On pace');

    // ── PPA ─────────────────────────────────────────────────────────────
    final ppaDelta = ShiftSnapshot.actualPPA - BaselineData.derivedTargetPPA;
    final ppaUnfavorable = ShiftSnapshot.actualPPA < BaselineData.derivedTargetPPA;
    final ppaStatus = ppaUnfavorable
        ? 'Watch'
        : (ShiftSnapshot.actualPPA > BaselineData.derivedTargetPPA ? 'Ahead' : 'On target');

    // ── CPLH ────────────────────────────────────────────────────────────
    final cplhDelta = ShiftSnapshot.actualCPLH - BaselineData.derivedTargetCPLH;
    final cplhUnfavorable = ShiftSnapshot.actualCPLH < BaselineData.derivedTargetCPLH;
    final opzLabel = BaselineData.opzStatusLabelForCplh(ShiftSnapshot.actualCPLH);
    String cplhStatus;
    switch (opzLabel) {
      case 'BELOW OPZ': cplhStatus = 'Below OPZ'; break;
      case 'IN OPZ':    cplhStatus = 'In OPZ';    break;
      case 'ABOVE OPZ': cplhStatus = 'Above OPZ'; break;
      default:          cplhStatus = 'In OPZ';
    }
    final cplhStatusFavorable =
        BaselineData.opzStatusForCplh(ShiftSnapshot.actualCPLH) == 'in';

    // ── SPLH ────────────────────────────────────────────────────────────
    final splhDelta = ShiftSnapshot.actualSPLH - BaselineData.derivedTargetSPLH;
    final splhUnfavorable = ShiftSnapshot.actualSPLH < BaselineData.derivedTargetSPLH;
    final splhStatus = splhUnfavorable
        ? 'Below target'
        : (ShiftSnapshot.actualSPLH > BaselineData.derivedTargetSPLH ? 'Above target' : 'On target');

    return [
      InputMetric(
        name: 'COVERS',
        currentFormatted: '${ShiftSnapshot.actualCovers}',
        targetFormatted: 'Forecast ${ShiftSnapshot.shiftForecastCovers}',
        deltaFormatted: '${coversDelta >= 0 ? '+' : ''}$coversDelta',
        deltaUnfavorable: coversUnfavorable,
        isHero: heroName == 'COVERS',
        statusLine: coversStatus,
      ),
      InputMetric(
        name: 'PPA',
        currentFormatted: '\$${ShiftSnapshot.actualPPA.toStringAsFixed(2)}',
        targetFormatted: 'Target \$${BaselineData.derivedTargetPPA.toStringAsFixed(2)}',
        deltaFormatted: ppaDelta >= 0
            ? '+\$${ppaDelta.toStringAsFixed(2)}'
            : '-\$${ppaDelta.abs().toStringAsFixed(2)}',
        deltaUnfavorable: ppaUnfavorable,
        isHero: heroName == 'PPA',
        statusLine: ppaStatus,
      ),
      InputMetric(
        name: 'CPLH',
        currentFormatted: ShiftSnapshot.actualCPLH.toStringAsFixed(1),
        targetFormatted: 'Target ${BaselineData.derivedTargetCPLH.toStringAsFixed(1)}',
        deltaFormatted: '${cplhDelta >= 0 ? '+' : ''}${cplhDelta.toStringAsFixed(1)}',
        deltaUnfavorable: cplhUnfavorable,
        statusFavorable: cplhStatusFavorable,
        isHero: heroName == 'CPLH',
        statusLine: cplhStatus,
      ),
      InputMetric(
        name: 'SPLH',
        currentFormatted: '\$${ShiftSnapshot.actualSPLH.toStringAsFixed(0)}',
        targetFormatted: 'Target \$${BaselineData.derivedTargetSPLH.toStringAsFixed(0)}',
        deltaFormatted: splhDelta >= 0
            ? '+\$${splhDelta.toStringAsFixed(0)}'
            : '-\$${splhDelta.abs().toStringAsFixed(0)}',
        deltaUnfavorable: splhUnfavorable,
        isHero: heroName == 'SPLH',
        statusLine: splhStatus,
      ),
      InputMetric(
        name: 'BLENDED WAGE',
        currentFormatted: '\$${ShiftSnapshot.blendedWage.toStringAsFixed(2)}',
        targetFormatted: 'Model \$${ShiftSnapshot.blendedWage.toStringAsFixed(2)}',
        deltaFormatted: '\u2014',
        deltaUnfavorable: false,
        isHero: heroName == 'BLENDED WAGE',
        statusLine: 'On model',
        fullWidth: true,
      ),
    ];
  }
}

// ─── OPZ validation result ────────────────────────────────────────────────────

class OpzValidation {
  final double floorCPLH;
  final double ceilingCPLH;
  final double targetCPLH;
  final double headroomCPLH;
  final double usedPct;
  final String status;
  final String statusLabel;
  final String message;
  final bool showWarning;

  const OpzValidation({
    required this.floorCPLH,
    required this.ceilingCPLH,
    required this.targetCPLH,
    required this.headroomCPLH,
    required this.usedPct,
    required this.status,
    required this.statusLabel,
    required this.message,
    required this.showWarning,
  });
}

// ─── Baseline range validation (Ch. 11 — benchmark selection quality) ────────

class BaselineRangeValidation {
  final double rangeStartCPLH;
  final double rangeEndCPLH;
  final double rangeWidthCPLH;
  final int selectedCount;
  final String status;
  final String statusLabel;
  final String message;
  final bool showWarning;

  const BaselineRangeValidation({
    required this.rangeStartCPLH,
    required this.rangeEndCPLH,
    required this.rangeWidthCPLH,
    required this.selectedCount,
    required this.status,
    required this.statusLabel,
    required this.message,
    required this.showWarning,
  });
}

// ─── Baseline data — 55 daypart records ──────────────────────────────────────
// Each record is one historical shift tagged by daypart and manager-selection.
// Targets are derived from isSelected records; no manual constants needed.

class DaypartBaseline {
  final String daypart;  // 'lunch' | 'dinner' | 'late_night'
  final double cplh;
  final double splh;
  final double ppa;
  final int covers;
  final bool isSelected; // manager-flagged high-performing shift

  const DaypartBaseline({
    required this.daypart,
    required this.cplh,
    required this.splh,
    required this.ppa,
    required this.covers,
    this.isSelected = false,
  });
}

// Full range analytics for one daypart — computed from DaypartBaseline records.
class DaypartRange {
  final String id;           // 'lunch' | 'dinner' | 'late_night'
  final String label;        // 'Lunch', 'Dinner', 'Late Night'
  final int sampleSize;
  final int selectedCount;
  final int avgCovers;
  final double avgCPLH;
  final double avgSPLH;
  final double avgPPA;
  final double minCPLH;
  final double maxCPLH;
  final double targetCPLH;   // avg CPLH of selected records
  final double targetSPLH;
  final double targetPPA;
  final int targetCovers;    // used by ScheduleDay.daypartBreakdown

  const DaypartRange({
    required this.id,
    required this.label,
    required this.sampleSize,
    required this.selectedCount,
    required this.avgCovers,
    required this.avgCPLH,
    required this.avgSPLH,
    required this.avgPPA,
    required this.minCPLH,
    required this.maxCPLH,
    required this.targetCPLH,
    required this.targetSPLH,
    required this.targetPPA,
    required this.targetCovers,
  });
}

// Per-daypart cover forecast with computed model hours — output of
// ScheduleDay.daypartBreakdown. Drives expandable rows in ScheduleBuilder.
class DaypartForecast {
  final String daypart;
  final String label;
  final int forecastCovers;

  const DaypartForecast({
    required this.daypart,
    required this.label,
    required this.forecastCovers,
  });

  int get requiredFohHours =>
      LaborModel.modelFohHours(forecastCovers, BaselineData.derivedTargetCPLH);

  int get requiredBohHours => LaborModel.modelBohHours(
      forecastCovers, BaselineData.derivedTargetPPA, BaselineData.derivedTargetSPLH);
}

class BaselineData {
  static const String daypartNote = '';

  static const String baselineTargetsNote =
      'These are your numbers. Not a benchmark. Not last year. Built from your best shifts.';

  // ── Runtime override storage ──────────────────────────────────────────────
  // Phase 5: manager can select star shifts from tracked history.
  // When set, all computed getters read from this list instead of _seedRecords.

  static List<DaypartBaseline>? _runtimeRecords;
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static List<DaypartBaseline> get records => _runtimeRecords ?? _seedRecords;

  static bool get hasManagerOverride => _runtimeRecords != null;

  static int get selectedRecordCount =>
      records.where((r) => r.isSelected).length;

  static void applyManagerOverride(List<DaypartBaseline> overrideRecords) {
    _runtimeRecords = List.unmodifiable(overrideRecords);
    revision.value++;
  }

  static void clearManagerOverride() {
    _runtimeRecords = null;
    revision.value++;
  }

  // ── Historical context storage (60-day full context) ─────────────────────
  // Separate from the active selected benchmark set so that context metrics
  // (total covers, weekly avg) remain stable regardless of override state.

  static List<DaypartBaseline>? _runtimeHistoricalContextRecords;

  static List<DaypartBaseline> get historicalContextRecords =>
      _runtimeHistoricalContextRecords ?? _seedRecords;

  static void applyHistoricalContext(List<DaypartBaseline> records) {
    _runtimeHistoricalContextRecords = List.unmodifiable(records);
    revision.value++;
  }

  static void clearHistoricalContext() {
    _runtimeHistoricalContextRecords = null;
    revision.value++;
  }

  // ── 55 daypart records: 20 lunch · 25 dinner · 10 late_night ─────────────
  // isSelected = true on 14 records that represent high-performing shifts
  // (5 lunch + 6 dinner + 3 late_night).
  // derivedTargetCPLH = avg CPLH of selected ≈ 4.58  (MeridianConfig = 4.5)
  // worstDaysAvgCPLH  = avg CPLH of bottom quartile ≈ 3.52
  static const List<DaypartBaseline> _seedRecords = [
    // ── Lunch ──────────────────────────────────────────────────────────────
    DaypartBaseline(daypart: 'lunch', cplh: 4.4, splh: 178, ppa: 41, covers: 165, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.5, splh: 180, ppa: 42, covers: 170, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.6, splh: 181, ppa: 42, covers: 172, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.7, splh: 182, ppa: 43, covers: 175, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.8, splh: 183, ppa: 43, covers: 178, isSelected: true),
    DaypartBaseline(daypart: 'lunch', cplh: 4.3, splh: 177, ppa: 41, covers: 162),
    DaypartBaseline(daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 160),
    DaypartBaseline(daypart: 'lunch', cplh: 4.1, splh: 175, ppa: 40, covers: 157),
    DaypartBaseline(daypart: 'lunch', cplh: 4.0, splh: 174, ppa: 40, covers: 155),
    DaypartBaseline(daypart: 'lunch', cplh: 3.9, splh: 173, ppa: 40, covers: 153),
    DaypartBaseline(daypart: 'lunch', cplh: 3.8, splh: 171, ppa: 39, covers: 150),
    DaypartBaseline(daypart: 'lunch', cplh: 3.7, splh: 170, ppa: 39, covers: 148),
    DaypartBaseline(daypart: 'lunch', cplh: 3.6, splh: 169, ppa: 38, covers: 145),
    DaypartBaseline(daypart: 'lunch', cplh: 3.5, splh: 167, ppa: 38, covers: 142),
    DaypartBaseline(daypart: 'lunch', cplh: 3.6, splh: 169, ppa: 38, covers: 144),
    DaypartBaseline(daypart: 'lunch', cplh: 3.7, splh: 170, ppa: 39, covers: 147),
    DaypartBaseline(daypart: 'lunch', cplh: 3.8, splh: 171, ppa: 39, covers: 149),
    DaypartBaseline(daypart: 'lunch', cplh: 4.0, splh: 174, ppa: 40, covers: 154),
    DaypartBaseline(daypart: 'lunch', cplh: 4.2, splh: 176, ppa: 41, covers: 159),
    DaypartBaseline(daypart: 'lunch', cplh: 3.9, splh: 172, ppa: 39, covers: 152),
    // ── Dinner ─────────────────────────────────────────────────────────────
    DaypartBaseline(daypart: 'dinner', cplh: 4.2, splh: 176, ppa: 43, covers: 225, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.3, splh: 177, ppa: 43, covers: 228, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.4, splh: 178, ppa: 44, covers: 232, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.5, splh: 180, ppa: 44, covers: 238, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.6, splh: 181, ppa: 45, covers: 242, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.7, splh: 182, ppa: 45, covers: 248, isSelected: true),
    DaypartBaseline(daypart: 'dinner', cplh: 4.1, splh: 175, ppa: 43, covers: 220),
    DaypartBaseline(daypart: 'dinner', cplh: 4.0, splh: 174, ppa: 42, covers: 215),
    DaypartBaseline(daypart: 'dinner', cplh: 3.9, splh: 173, ppa: 42, covers: 210),
    DaypartBaseline(daypart: 'dinner', cplh: 3.8, splh: 172, ppa: 41, covers: 205),
    DaypartBaseline(daypart: 'dinner', cplh: 3.7, splh: 171, ppa: 41, covers: 200),
    DaypartBaseline(daypart: 'dinner', cplh: 3.6, splh: 170, ppa: 41, covers: 195),
    DaypartBaseline(daypart: 'dinner', cplh: 3.5, splh: 168, ppa: 40, covers: 190),
    DaypartBaseline(daypart: 'dinner', cplh: 3.4, splh: 167, ppa: 40, covers: 185),
    DaypartBaseline(daypart: 'dinner', cplh: 3.4, splh: 167, ppa: 40, covers: 183),
    DaypartBaseline(daypart: 'dinner', cplh: 3.5, splh: 168, ppa: 40, covers: 188),
    DaypartBaseline(daypart: 'dinner', cplh: 4.1, splh: 175, ppa: 43, covers: 218),
    DaypartBaseline(daypart: 'dinner', cplh: 3.9, splh: 173, ppa: 42, covers: 208),
    DaypartBaseline(daypart: 'dinner', cplh: 3.7, splh: 171, ppa: 41, covers: 200),
    DaypartBaseline(daypart: 'dinner', cplh: 4.0, splh: 174, ppa: 42, covers: 212),
    DaypartBaseline(daypart: 'dinner', cplh: 3.6, splh: 170, ppa: 41, covers: 193),
    DaypartBaseline(daypart: 'dinner', cplh: 3.8, splh: 172, ppa: 41, covers: 203),
    DaypartBaseline(daypart: 'dinner', cplh: 3.6, splh: 170, ppa: 41, covers: 193),
    DaypartBaseline(daypart: 'dinner', cplh: 3.5, splh: 168, ppa: 40, covers: 187),
    DaypartBaseline(daypart: 'dinner', cplh: 3.9, splh: 173, ppa: 42, covers: 207),
    // ── Late Night ──────────────────────────────────────────────────────────
    DaypartBaseline(daypart: 'late_night', cplh: 4.6, splh: 179, ppa: 36, covers: 85, isSelected: true),
    DaypartBaseline(daypart: 'late_night', cplh: 4.8, splh: 181, ppa: 37, covers: 90, isSelected: true),
    DaypartBaseline(daypart: 'late_night', cplh: 5.0, splh: 183, ppa: 37, covers: 92, isSelected: true),
    DaypartBaseline(daypart: 'late_night', cplh: 4.2, splh: 177, ppa: 35, covers: 80),
    DaypartBaseline(daypart: 'late_night', cplh: 4.0, splh: 175, ppa: 35, covers: 77),
    DaypartBaseline(daypart: 'late_night', cplh: 3.8, splh: 173, ppa: 34, covers: 74),
    DaypartBaseline(daypart: 'late_night', cplh: 3.6, splh: 171, ppa: 34, covers: 71),
    DaypartBaseline(daypart: 'late_night', cplh: 3.5, splh: 170, ppa: 34, covers: 69),
    DaypartBaseline(daypart: 'late_night', cplh: 3.4, splh: 169, ppa: 33, covers: 67),
    DaypartBaseline(daypart: 'late_night', cplh: 3.6, splh: 171, ppa: 34, covers: 71),
  ];

  // ── Computed aggregates ───────────────────────────────────────────────────

  static List<DaypartBaseline> get _selected =>
      records.where((r) => r.isSelected).toList();

  // OPZ source set — same selected benchmark/star-shift proxy records that
  // drive the target. Falls back to all records only if nothing is selected.
  // Manager override (Phase 5) will later supply a refined selection.
  static List<DaypartBaseline> get _opzSourceRecords =>
      _selected.isNotEmpty ? _selected : records;

  /// Avg CPLH of manager-selected records (the high-performing shifts).
  static double get bestDaysAvgCPLH =>
      _selected.fold(0.0, (s, r) => s + r.cplh) / _selected.length;

  /// Avg CPLH of the bottom quartile of all records.
  static double get worstDaysAvgCPLH {
    final sorted = [...records]..sort((a, b) => a.cplh.compareTo(b.cplh));
    final bottom = sorted.take(records.length ~/ 4).toList();
    return bottom.fold(0.0, (s, r) => s + r.cplh) / bottom.length;
  }

  static int get totalCoversTracked =>
      records.fold(0, (s, r) => s + r.covers);

  static int get weeklyAvgCovers => MeridianConfig.weeklyCovers;

  // ── Historical context metrics (Ch. 9 — always 60-day, never overridden) ─

  static int get historicalTotalCoversTracked =>
      historicalContextRecords.fold(0, (s, r) => s + r.covers);

  static int get historicalWeeklyAvgCovers =>
      (historicalTotalCoversTracked / (60 / 7)).round();

  // ── Derived targets — from selected records, replace hardcoded config ─────

  static double get derivedTargetCPLH =>
      _selected.fold(0.0, (s, r) => s + r.cplh) / _selected.length;

  static double get derivedTargetSPLH =>
      _selected.fold(0.0, (s, r) => s + r.splh) / _selected.length;

  static double get derivedTargetPPA =>
      _selected.fold(0.0, (s, r) => s + r.ppa) / _selected.length;

  static double get derivedTheoreticalLaborPct => LaborModel.theoreticalLaborPct(
      derivedTargetCPLH, derivedTargetSPLH, derivedTargetPPA,
      MeridianConfig.fohWage, MeridianConfig.bohWage);

  // FOH theoretical labor % = fohWage / (targetCPLH × targetPPA) × 100
  static double get derivedFohTheoreticalLaborPct =>
      (derivedTargetCPLH == 0 || derivedTargetPPA == 0)
          ? 0
          : MeridianConfig.fohWage / (derivedTargetCPLH * derivedTargetPPA) * 100;

  // BOH theoretical labor % = bohWage / targetSPLH × 100
  static double get derivedBohTheoreticalLaborPct =>
      derivedTargetSPLH == 0
          ? 0
          : MeridianConfig.bohWage / derivedTargetSPLH * 100;

  // ── OPZ helpers (Jim Taylor Ch. 11) ──────────────────────────────────────
  // OPZ is now historically derived from the same selected benchmark/star-shift
  // proxy records that drive derivedTargetCPLH (Ch. 9 → Ch. 11 chain).
  // MeridianConfig.opzFloorCPLH / opzCeilingCPLH remain as legacy demo
  // constants but are no longer the primary runtime OPZ source.

  static double get opzFloorCPLH =>
      _opzSourceRecords.map((r) => r.cplh).reduce(math.min);
  static double get opzCeilingCPLH =>
      _opzSourceRecords.map((r) => r.cplh).reduce(math.max);

  /// Headroom = how far below the ceiling the target sits.
  static double get opzHeadroomCPLH => opzCeilingCPLH - derivedTargetCPLH;

  /// Where the target sits in the OPZ band, expressed as 0–100%.
  static double get opzUsedPct {
    final band = opzCeilingCPLH - opzFloorCPLH;
    if (band <= 0) return 0;
    return ((derivedTargetCPLH - opzFloorCPLH) / band * 100).clamp(0, 100);
  }

  /// Full OPZ validation result — status, label, message, and warning flag.
  static OpzValidation get opzValidation {
    final target = derivedTargetCPLH;
    final floor = opzFloorCPLH;
    final ceiling = opzCeilingCPLH;
    final headroom = opzHeadroomCPLH;
    final used = opzUsedPct;

    String status;
    String statusLabel;
    String message;
    bool showWarning;

    if (target > ceiling) {
      status = 'above_ceiling';
      statusLabel = 'ABOVE CEILING';
      message = 'Target is above the OPZ ceiling. Chapter 11 treats this as an unstable standard, not a teachable baseline.';
      showWarning = true;
    } else if (target >= ceiling - 0.30) {
      status = 'near_ceiling';
      statusLabel = 'NEAR CEILING';
      message = 'Target is too close to the OPZ ceiling. Chapter 11 calls for sustainable productivity with usable headroom, not ceiling chasing.';
      showWarning = true;
    } else if (target < floor) {
      status = 'below_floor';
      statusLabel = 'BELOW FLOOR';
      message = 'Target sits below the OPZ floor. Review whether the baseline is too soft to teach the operation.';
      showWarning = true;
    } else {
      status = 'in_zone';
      statusLabel = 'IN OPZ';
      message = 'Target sits inside the OPZ with usable headroom. This is a teachable standard.';
      showWarning = false;
    }

    return OpzValidation(
      floorCPLH: floor,
      ceilingCPLH: ceiling,
      targetCPLH: target,
      headroomCPLH: headroom,
      usedPct: used,
      status: status,
      statusLabel: statusLabel,
      message: message,
      showWarning: showWarning,
    );
  }

  /// OPZ zone for a live CPLH reading: 'below' | 'in' | 'above'.
  static String opzStatusForCplh(double currentCplh) {
    if (currentCplh < opzFloorCPLH) return 'below';
    if (currentCplh > opzCeilingCPLH) return 'above';
    return 'in';
  }

  /// Human-readable OPZ zone label.
  static String opzStatusLabelForCplh(double currentCplh) {
    switch (opzStatusForCplh(currentCplh)) {
      case 'below': return 'BELOW OPZ';
      case 'above': return 'ABOVE OPZ';
      default:      return 'IN OPZ';
    }
  }

  /// One-line teaching sub-label for the current CPLH zone.
  static String opzSubLabelForCplh(double currentCplh) {
    switch (opzStatusForCplh(currentCplh)) {
      case 'below':
        return 'Productivity is below the OPZ floor. The shift is underproducing the standard.';
      case 'above':
        return 'Productivity is above the OPZ ceiling. Service risk rises here.';
      default:
        return 'Productivity is inside the OPZ. Protect guest attention and hold the pattern.';
    }
  }

  // ── Baseline range validation (Ch. 11 — benchmark selection quality) ──────

  static BaselineRangeValidation get baselineRangeValidation {
    final selected = records.where((r) => r.isSelected).toList();
    if (selected.length < 2) {
      return const BaselineRangeValidation(
        rangeStartCPLH: 0,
        rangeEndCPLH: 0,
        rangeWidthCPLH: 0,
        selectedCount: 0,
        status: 'too_narrow',
        statusLabel: 'OPZ RANGE TOO NARROW',
        message:
            'Selected star shifts are clustered too tightly to teach a repeatable standard. '
            'Add more star shifts that felt right so the team has usable flex.',
        showWarning: true,
      );
    }

    final rangeStart = selected.map((r) => r.cplh).reduce(math.min);
    final rangeEnd = selected.map((r) => r.cplh).reduce(math.max);
    final rangeWidth = rangeEnd - rangeStart;

    String status;
    String statusLabel;
    String message;
    bool showWarning;

    if (rangeWidth < 0.15) {
      status = 'too_narrow';
      statusLabel = 'OPZ RANGE TOO NARROW';
      message =
          'Selected star shifts are clustered too tightly to teach a repeatable standard. '
          'Add more star shifts that felt right so the team has usable flex.';
      showWarning = true;
    } else if (rangeWidth > 1.25) {
      status = 'too_wide';
      statusLabel = 'OPZ RANGE TOO WIDE';
      message =
          'Selected star shifts span too much of the operating range to teach one clean standard. '
          'Tighten the set around the shifts that felt consistently right.';
      showWarning = true;
    } else {
      status = 'healthy';
      statusLabel = 'GOOD OPZ RANGE';
      message =
          'Recommended target sits inside a usable benchmark range. '
          'This gives the team room to flex up or down while still holding a teachable standard.';
      showWarning = false;
    }

    return BaselineRangeValidation(
      rangeStartCPLH: rangeStart,
      rangeEndCPLH: rangeEnd,
      rangeWidthCPLH: rangeWidth,
      selectedCount: selected.length,
      status: status,
      statusLabel: statusLabel,
      message: message,
      showWarning: showWarning,
    );
  }

  // ── DaypartRange list — computed from records ─────────────────────────────

  static List<DaypartRange> get daypartRanges =>
      ['lunch', 'dinner', 'late_night'].map(_rangeFor).toList();

  static DaypartRange _rangeFor(String id) {
    final all      = records.where((r) => r.daypart == id).toList();
    final selected = all.where((r) => r.isSelected).toList();
    final n        = all.length;
    if (n == 0) return _emptyRange(id);
    final avgCovers = all.fold(0, (s, r) => s + r.covers) ~/ n;
    final avgCPLH   = all.fold(0.0, (s, r) => s + r.cplh) / n;
    final avgSPLH   = all.fold(0.0, (s, r) => s + r.splh) / n;
    final avgPPA    = all.fold(0.0, (s, r) => s + r.ppa) / n;
    final minCPLH   = all.map((r) => r.cplh).reduce((a, b) => a < b ? a : b);
    final maxCPLH   = all.map((r) => r.cplh).reduce((a, b) => a > b ? a : b);
    final sel       = selected.isEmpty ? all : selected;
    return DaypartRange(
      id: id,
      label: _labelFor(id),
      sampleSize: n,
      selectedCount: selected.length,
      avgCovers: avgCovers,
      avgCPLH: avgCPLH,
      avgSPLH: avgSPLH,
      avgPPA: avgPPA,
      minCPLH: minCPLH,
      maxCPLH: maxCPLH,
      targetCPLH: sel.fold(0.0, (s, r) => s + r.cplh) / sel.length,
      targetSPLH: sel.fold(0.0, (s, r) => s + r.splh) / sel.length,
      targetPPA:  sel.fold(0.0, (s, r) => s + r.ppa) / sel.length,
      targetCovers: sel.fold(0, (s, r) => s + r.covers) ~/ sel.length,
    );
  }

  static String _labelFor(String id) {
    switch (id) {
      case 'lunch':      return 'Lunch';
      case 'dinner':     return 'Dinner';
      case 'late_night': return 'Late Night';
      default:           return id;
    }
  }

  static DaypartRange _emptyRange(String id) => DaypartRange(
        id: id,
        label: _labelFor(id),
        sampleSize: 0,
        selectedCount: 0,
        avgCovers: 0,
        avgCPLH: 0,
        avgSPLH: 0,
        avgPPA: 0,
        minCPLH: 0,
        maxCPLH: 0,
        targetCPLH: MeridianConfig.targetCPLH,
        targetSPLH: MeridianConfig.targetSPLH,
        targetPPA: MeridianConfig.targetPPA,
        targetCovers: 0,
      );

  // ── Graph model (Jim Taylor Ch. 9–12) ─────────────────────────────────────
  // Historical context = full 60-day lived range (Ch. 9) — always the outer scale.
  // Active range = selected benchmark/star-shift range (Ch. 11–12) — inner highlight.
  // Display range is always the historical context so the 60-day truth stays visible.

  static BaselineRangeGraphModel get rangeGraphModel {
    // A. Historical context — always the outer display range
    final histCplh = historicalContextRecords.map((r) => r.cplh).toList();
    final histMin = histCplh.reduce(math.min);
    final histMax = histCplh.reduce(math.max);

    // B. Active selected range — inner highlighted range
    final selected = records.where((r) => r.isSelected).toList();
    final activeMin = selected.map((r) => r.cplh).reduce(math.min);
    final activeMax = selected.map((r) => r.cplh).reduce(math.max);

    // C. Target
    final target = derivedTargetCPLH;

    // D. Display range is always historical
    final displayMin = histMin;
    final displayMax = histMax;

    // E. Inner range label depends on override state
    final rangeLabel = hasManagerOverride ? 'STAR SHIFT RANGE' : 'BENCHMARK RANGE';

    // F. Position normalization — always against the historical scale
    var scaleMin = displayMin;
    var scaleMax = displayMax;
    if (scaleMax <= scaleMin) {
      scaleMin = math.max(0.0, target - 1.0);
      scaleMax = target + 1.0;
    }
    final scaleRange = scaleMax - scaleMin;

    final activeStartPos = scaleRange > 0
        ? ((activeMin - scaleMin) / scaleRange).clamp(0.0, 1.0)
        : 0.0;
    final activeEndPos = scaleRange > 0
        ? ((activeMax - scaleMin) / scaleRange).clamp(0.0, 1.0)
        : 1.0;
    final targetPos = scaleRange > 0
        ? ((target - scaleMin) / scaleRange).clamp(0.0, 1.0)
        : 0.5;

    return BaselineRangeGraphModel(
      historicalRangeStartCPLH: histMin,
      historicalRangeEndCPLH:   histMax,
      displayRangeStartCPLH:   displayMin,
      displayRangeEndCPLH:     displayMax,
      activeRangeStartCPLH:    activeMin,
      activeRangeEndCPLH:      activeMax,
      targetCPLH:              target,
      displayRangeStartPosition: 0.0,
      displayRangeEndPosition:   1.0,
      activeRangeStartPosition:  activeStartPos,
      activeRangeEndPosition:    activeEndPos,
      targetPosition:            targetPos,
      title:                   'RECOMMENDED TARGET',
      startLabel:              'LOWEST CPLH LAST 60 DAYS',
      endLabel:                'HIGHEST CPLH LAST 60 DAYS',
      rangeLabel:              rangeLabel,
      recommendedExplanation:  baselineRangeValidation.message,
      overrideLabel:           'MANAGER OVERRIDE BASED ON STAR SHIFTS',
    );
  }
}

// ─── Baseline range graph model (Jim Taylor Ch. 9–12) ────────────────────────
// Immutable read-model for the CPLH range graph.
// historicalRange   = full 60-day min/max CPLH (Ch. 9 lived range).
// activeRange       = selected star-shift min/max CPLH (Ch. 11–12 benchmark).
// displayRange      = what the graph endpoints show: historical or star-shift.
// target            = recommended target inside the zone, built from benchmark shifts (Ch. 12).
// Positions are normalized 0.0–1.0 within [displayRangeStart, displayRangeEnd].

class BaselineRangeGraphModel {
  final double historicalRangeStartCPLH;
  final double historicalRangeEndCPLH;
  final double displayRangeStartCPLH;
  final double displayRangeEndCPLH;
  final double activeRangeStartCPLH;
  final double activeRangeEndCPLH;
  final double targetCPLH;
  final double displayRangeStartPosition;
  final double displayRangeEndPosition;
  final double activeRangeStartPosition;
  final double activeRangeEndPosition;
  final double targetPosition;
  final String title;
  final String startLabel;
  final String endLabel;
  final String rangeLabel;
  final String recommendedExplanation;
  final String overrideLabel;

  const BaselineRangeGraphModel({
    required this.historicalRangeStartCPLH,
    required this.historicalRangeEndCPLH,
    required this.displayRangeStartCPLH,
    required this.displayRangeEndCPLH,
    required this.activeRangeStartCPLH,
    required this.activeRangeEndCPLH,
    required this.targetCPLH,
    required this.displayRangeStartPosition,
    required this.displayRangeEndPosition,
    required this.activeRangeStartPosition,
    required this.activeRangeEndPosition,
    required this.targetPosition,
    required this.title,
    required this.startLabel,
    required this.endLabel,
    required this.rangeLabel,
    required this.recommendedExplanation,
    required this.overrideLabel,
  });
}

// ─── Schedule forecast ────────────────────────────────────────────────────────

class ScheduleDay {
  final String day;
  final int forecastCovers;

  const ScheduleDay({required this.day, required this.forecastCovers});

  int get requiredFohHours =>
      LaborModel.modelFohHours(forecastCovers, BaselineData.derivedTargetCPLH);

  int get requiredBohHours =>
      LaborModel.modelBohHours(
          forecastCovers, BaselineData.derivedTargetPPA, BaselineData.derivedTargetSPLH);

  /// Per-daypart cover breakdown for this day, proportional to BaselineData
  /// targetCovers for each daypart. Drives expandable rows in ScheduleBuilder.
  List<DaypartForecast> get daypartBreakdown {
    final ids    = WeekDayOrder.daypartsFor(day);
    final ranges = BaselineData.daypartRanges
        .where((r) => ids.contains(r.id))
        .toList();
    final total  = ranges.fold(0, (s, r) => s + r.targetCovers);
    if (total == 0) return [];
    return ranges
        .map((r) => DaypartForecast(
              daypart: r.id,
              label:   r.label,
              forecastCovers:
                  (forecastCovers * r.targetCovers / total).round(),
            ))
        .toList();
  }
}

class ScheduleForecastDefaults {
  static const List<ScheduleDay> defaultDays = [
    ScheduleDay(day: 'Mon', forecastCovers: 140),
    ScheduleDay(day: 'Tue', forecastCovers: 150),
    ScheduleDay(day: 'Wed', forecastCovers: 160),
    ScheduleDay(day: 'Thu', forecastCovers: 190),
    ScheduleDay(day: 'Fri', forecastCovers: 220),
    ScheduleDay(day: 'Sat', forecastCovers: 230),
    ScheduleDay(day: 'Sun', forecastCovers: 110),
  ];

  static const int defaultWeeklyCovers = 1200;

  static const String principleStatement =
      'You are not scheduling to last Friday\'s sales. You are scheduling to next '
      "Friday's guests. The covers tell you how many people are coming. CPLH tells "
      'you how many hours you need to serve them. That is the schedule.';
}

// ─── Day-order constants for Full Week section ────────────────────────────────
// Specifies the canonical Mon→Sun order and which dayparts each day has.

class WeekDayOrder {
  static const List<String> dayLabels = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];

  static List<String> daypartsFor(String dayLabel) {
    switch (dayLabel) {
      case 'Mon':
      case 'Tue':
      case 'Wed':
      case 'Thu':
        return ['lunch', 'dinner'];
      case 'Fri':
        return ['lunch', 'dinner', 'late_night'];
      case 'Sat':
        return ['dinner', 'late_night'];
      case 'Sun':
        return ['dinner'];
      default:
        return [];
    }
  }
}
