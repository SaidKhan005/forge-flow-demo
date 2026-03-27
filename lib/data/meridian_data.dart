// Forge & Flow -Single source of truth.
// Every number in the app traces to this file.
// Do not hardcode values elsewhere in the codebase.

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

// ─── Demo shift snapshot -Friday dinner, 7:42 PM ─────────────────────────────

class ShiftSnapshot {
  static const String daypart = 'Dinner';
  static const String day = 'Friday';
  static const String time = '7:42 PM';
  static const String serviceElapsed = '3h 14m into service';

  static const int actualCovers = 1140;
  static const int actualFohHours = 280;
  static const int actualBohHours = 290;
  static const double actualFohLaborPct = 9.7;
  static const double actualBohLaborPct = 12.9;
  static const double actualTotalLaborPct = 22.6;
  static const double actualPPA = 41.20;
  static const double actualCPLH = 4.1;
  static const double actualSPLH = 174.0;
  static const double blendedWage = 18.74;

  static const double dollarGapWeekly = 958.0;
  static const double dollarGapAnnualized = 49816.0;

  // OPZ status -'below' | 'in' | 'above'
  static const String opzStatus = 'in';
  static const String opzSubLabel =
      'Team is producing. Watch covers -if volume drops further, you will drift below.';
}

// ─── Weekly variance ──────────────────────────────────────────────────────────

class WeeklyVariance {
  static const String weekLabel = 'Week of Mar 24';

  static const int theoreticalCovers = MeridianConfig.weeklyCovers;
  static const int actualCovers = ShiftSnapshot.actualCovers;
  static const int coversVariance = actualCovers - theoreticalCovers; // -60

  static const int theoreticalFohHours = MeridianConfig.requiredFohHours;
  static const int actualFohHours = ShiftSnapshot.actualFohHours;
  static const int fohHoursVariance = actualFohHours - theoreticalFohHours; // +13

  static const int theoreticalBohHours = MeridianConfig.requiredBohHours;
  static const int actualBohHours = ShiftSnapshot.actualBohHours;
  static const int bohHoursVariance = actualBohHours - theoreticalBohHours; // +10

  static const double theoreticalFohLaborPct = MeridianConfig.fohTheoreticalLaborPct;
  static const double actualFohLaborPct = ShiftSnapshot.actualFohLaborPct;
  static const double fohLaborPctVariance =
      actualFohLaborPct - theoreticalFohLaborPct; // +1.0

  static const double theoreticalBohLaborPct = MeridianConfig.bohTheoreticalLaborPct;
  static const double actualBohLaborPct = ShiftSnapshot.actualBohLaborPct;
  static const double bohLaborPctVariance =
      actualBohLaborPct - theoreticalBohLaborPct; // +1.0

  static const double theoreticalTotalLaborPct =
      MeridianConfig.totalTheoreticalLaborPct;
  static const double actualTotalLaborPct = ShiftSnapshot.actualTotalLaborPct;
  static const double totalLaborPctVariance =
      actualTotalLaborPct - theoreticalTotalLaborPct; // +2.0

  static const double dollarGapWeekly = ShiftSnapshot.dollarGapWeekly;
  static const double dollarGapAnnualized = ShiftSnapshot.dollarGapAnnualized;
  static const String annualizedContext = 'At \$3M annual sales. One location. Recoverable.';

  static const String fohExcessCost = '\$215';
  static const String bohExcessCost = '\$214 + overtime';

  static const String plainLanguageRead =
      'This week, covers ran light and the schedule did not adjust to match. '
      'Thirteen fewer FOH hours next week closes the gap. Not a wage conversation. '
      'Not a performance review. A scheduling decision made before the week starts.';
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

  const LeverCardData({
    required this.id,
    required this.metric,
    required this.causeCategory,
    required this.side,
    required this.direction,
    required this.whatHappened,
    required this.whatToDo,
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
    whatHappened:
        'Fewer guests than you planned for, and the hours did not move with it. '
        'That gap is where your variance came from -not your team, not your wages. '
        'The schedule just did not flex when the volume did.',
    whatToDo:
        'Watch your cover pace mid-week. If Tuesday is tracking low, pull hours '
        'Wednesday before the cost compounds. The adjustment happens before the shift, not after it.',
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
    bohWageUp,
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
  final String statusLine;
  final bool fullWidth;

  const InputMetric({
    required this.name,
    required this.currentFormatted,
    required this.targetFormatted,
    required this.deltaFormatted,
    required this.deltaUnfavorable,
    required this.statusLine,
    this.fullWidth = false,
  });
}

class ShiftMetrics {
  static const List<InputMetric> cards = [
    InputMetric(
      name: 'COVERS',
      currentFormatted: '1,140',
      targetFormatted: 'Target 1,200',
      deltaFormatted: '−60',
      deltaUnfavorable: true,
      statusLine: 'Light',
    ),
    InputMetric(
      name: 'PPA',
      currentFormatted: '\$41.20',
      targetFormatted: 'Target \$42.00',
      deltaFormatted: '−\$0.80',
      deltaUnfavorable: true,
      statusLine: 'Watch',
    ),
    InputMetric(
      name: 'CPLH',
      currentFormatted: '4.1',
      targetFormatted: 'Target 4.5',
      deltaFormatted: '−0.4',
      deltaUnfavorable: true,
      statusLine: 'Below target',
    ),
    InputMetric(
      name: 'SPLH',
      currentFormatted: '\$174',
      targetFormatted: 'Target \$180',
      deltaFormatted: '−\$6',
      deltaUnfavorable: true,
      statusLine: 'Below target',
    ),
    InputMetric(
      name: 'BLENDED WAGE',
      currentFormatted: '\$18.74',
      targetFormatted: 'Model \$18.74',
      deltaFormatted: '-',
      deltaUnfavorable: false,
      statusLine: 'Neutral',
      fullWidth: true,
    ),
  ];
}

// ─── Baseline data -60 days ──────────────────────────────────────────────────

class DailyBaseline {
  final double cplh;
  final double splh;
  final double ppa;
  final int covers;

  const DailyBaseline({
    required this.cplh,
    required this.splh,
    required this.ppa,
    required this.covers,
  });
}

class DaypartStat {
  final String label;
  final int avgCovers;
  final double avgCPLH;
  final double avgSPLH;
  final double avgPPA;

  const DaypartStat({
    required this.label,
    required this.avgCovers,
    required this.avgCPLH,
    required this.avgSPLH,
    required this.avgPPA,
  });
}

class BaselineData {
  static const int totalCoversTracked = 10286;
  static const int weeklyAvgCovers = 1200;
  static const double bestDaysAvgCPLH = 5.28;
  static const double worstDaysAvgCPLH = 3.51;

  static const List<DaypartStat> dayparts = [
    DaypartStat(
      label: 'Lunch (M–F)',
      avgCovers: 180,
      avgCPLH: 4.8,
      avgSPLH: 185,
      avgPPA: 38,
    ),
    DaypartStat(
      label: 'Dinner (M–Th)',
      avgCovers: 220,
      avgCPLH: 4.4,
      avgSPLH: 178,
      avgPPA: 44,
    ),
    DaypartStat(
      label: 'Dinner (F–Sa)',
      avgCovers: 310,
      avgCPLH: 4.2,
      avgSPLH: 172,
      avgPPA: 43,
    ),
    DaypartStat(
      label: 'Late Night',
      avgCovers: 90,
      avgCPLH: 5.1,
      avgSPLH: 188,
      avgPPA: 36,
    ),
  ];

  static const String daypartNote =
      'Lunch and dinner are different businesses. A strong dinner can mask a '
      'bleeding lunch every day of the week. Tracking by daypart gives you the '
      'resolution to see which shift is consistently off target.';

  static const String baselineTargetsNote =
      'These are your numbers. Not a benchmark. Not last year. Built from your best 60 days.';

  // 60 days of daily CPLH data -realistic variance around targets
  static const List<DailyBaseline> days = [
    DailyBaseline(cplh: 4.6, splh: 182, ppa: 42, covers: 168),
    DailyBaseline(cplh: 4.2, splh: 175, ppa: 40, covers: 155),
    DailyBaseline(cplh: 5.1, splh: 188, ppa: 44, covers: 195),
    DailyBaseline(cplh: 4.4, splh: 179, ppa: 41, covers: 172),
    DailyBaseline(cplh: 3.8, splh: 168, ppa: 39, covers: 145),
    DailyBaseline(cplh: 4.9, splh: 185, ppa: 43, covers: 190),
    DailyBaseline(cplh: 5.3, splh: 191, ppa: 45, covers: 205),
    DailyBaseline(cplh: 4.1, splh: 172, ppa: 40, covers: 160),
    DailyBaseline(cplh: 4.7, splh: 183, ppa: 42, covers: 178),
    DailyBaseline(cplh: 3.6, splh: 165, ppa: 38, covers: 140),
    DailyBaseline(cplh: 4.5, splh: 180, ppa: 42, covers: 171),
    DailyBaseline(cplh: 5.6, splh: 193, ppa: 46, covers: 215),
    DailyBaseline(cplh: 4.3, splh: 177, ppa: 41, covers: 165),
    DailyBaseline(cplh: 4.8, splh: 184, ppa: 43, covers: 185),
    DailyBaseline(cplh: 3.9, splh: 170, ppa: 39, covers: 148),
    DailyBaseline(cplh: 4.4, splh: 179, ppa: 41, covers: 170),
    DailyBaseline(cplh: 5.2, splh: 189, ppa: 44, covers: 200),
    DailyBaseline(cplh: 4.6, splh: 181, ppa: 42, covers: 176),
    DailyBaseline(cplh: 4.0, splh: 171, ppa: 40, covers: 153),
    DailyBaseline(cplh: 6.1, splh: 195, ppa: 47, covers: 235),
    DailyBaseline(cplh: 4.5, splh: 180, ppa: 42, covers: 172),
    DailyBaseline(cplh: 3.7, splh: 167, ppa: 38, covers: 143),
    DailyBaseline(cplh: 4.9, splh: 185, ppa: 43, covers: 188),
    DailyBaseline(cplh: 5.4, splh: 192, ppa: 45, covers: 208),
    DailyBaseline(cplh: 4.2, splh: 176, ppa: 41, covers: 162),
    DailyBaseline(cplh: 4.7, splh: 183, ppa: 42, covers: 180),
    DailyBaseline(cplh: 3.5, splh: 163, ppa: 37, covers: 135),
    DailyBaseline(cplh: 4.4, splh: 179, ppa: 41, covers: 169),
    DailyBaseline(cplh: 5.8, splh: 194, ppa: 46, covers: 222),
    DailyBaseline(cplh: 4.1, splh: 173, ppa: 40, covers: 158),
    DailyBaseline(cplh: 4.6, splh: 181, ppa: 42, covers: 175),
    DailyBaseline(cplh: 4.3, splh: 177, ppa: 41, covers: 164),
    DailyBaseline(cplh: 5.0, splh: 187, ppa: 43, covers: 192),
    DailyBaseline(cplh: 3.8, splh: 168, ppa: 39, covers: 146),
    DailyBaseline(cplh: 4.5, splh: 180, ppa: 42, covers: 171),
    DailyBaseline(cplh: 5.5, splh: 193, ppa: 45, covers: 211),
    DailyBaseline(cplh: 4.2, splh: 175, ppa: 40, covers: 161),
    DailyBaseline(cplh: 4.8, splh: 184, ppa: 43, covers: 184),
    DailyBaseline(cplh: 3.9, splh: 170, ppa: 39, covers: 149),
    DailyBaseline(cplh: 4.4, splh: 179, ppa: 41, covers: 168),
    DailyBaseline(cplh: 5.9, splh: 196, ppa: 47, covers: 228),
    DailyBaseline(cplh: 4.1, splh: 172, ppa: 40, covers: 157),
    DailyBaseline(cplh: 4.7, splh: 183, ppa: 42, covers: 179),
    DailyBaseline(cplh: 4.3, splh: 177, ppa: 41, covers: 166),
    DailyBaseline(cplh: 5.1, splh: 188, ppa: 44, covers: 197),
    DailyBaseline(cplh: 3.6, splh: 165, ppa: 38, covers: 138),
    DailyBaseline(cplh: 4.5, splh: 180, ppa: 42, covers: 172),
    DailyBaseline(cplh: 4.0, splh: 171, ppa: 40, covers: 154),
    DailyBaseline(cplh: 5.3, splh: 190, ppa: 44, covers: 203),
    DailyBaseline(cplh: 4.6, splh: 181, ppa: 42, covers: 176),
    DailyBaseline(cplh: 4.2, splh: 176, ppa: 41, covers: 163),
    DailyBaseline(cplh: 5.7, splh: 194, ppa: 46, covers: 218),
    DailyBaseline(cplh: 3.9, splh: 169, ppa: 39, covers: 150),
    DailyBaseline(cplh: 4.4, splh: 178, ppa: 41, covers: 167),
    DailyBaseline(cplh: 4.8, splh: 184, ppa: 43, covers: 183),
    DailyBaseline(cplh: 4.1, splh: 173, ppa: 40, covers: 156),
    DailyBaseline(cplh: 5.2, splh: 189, ppa: 44, covers: 199),
    DailyBaseline(cplh: 4.5, splh: 180, ppa: 42, covers: 171),
    DailyBaseline(cplh: 3.7, splh: 166, ppa: 38, covers: 142),
    DailyBaseline(cplh: 4.1, splh: 174, ppa: 40, covers: 159),
  ];
}

// ─── Schedule forecast ────────────────────────────────────────────────────────

class ScheduleDay {
  final String day;
  final int forecastCovers;

  const ScheduleDay({required this.day, required this.forecastCovers});

  int get requiredFohHours =>
      (forecastCovers / MeridianConfig.targetCPLH).round();

  int get requiredBohHours =>
      ((forecastCovers * MeridianConfig.targetPPA) / MeridianConfig.targetSPLH)
          .round();
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
