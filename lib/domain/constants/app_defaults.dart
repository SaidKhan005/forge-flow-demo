// Forge & Flow — runtime defaults and static UI/domain metadata.
//
// 7.57.1a extracted these constants/config-style values into a dedicated
// runtime-defaults module so production code can depend on real defaults
// without pulling in the demo restaurant dataset.
//
// What lives here:
//   * `MeridianConfig`       — restaurant-level runtime config / fallbacks
//   * `LeverDirection`       — lever favorability enum
//   * `LeverSide`            — lever side-of-house enum
//   * `LeverCardData`        — lever card value type
//   * `LeverCards`           — 16 const lever cards (pure metadata)
//   * `InputMetric`          — pure value type for metric cards
//   * `WeekDayOrder`         — thin bridge to `CanonicalDayOrder.labels`
//
// What does NOT live here (lives in `lib/dev/demo_fixture_data.dart`,
// kDemoMode only):
//   * sample shift / week-to-date / variance / baseline data
//   * `BaselineData`, `ShiftSnapshot`, `WeekToDate`, `WeeklyVariance`,
//     `ShiftMetrics`, `ScheduleDay`, `ScheduleForecastDefaults`
//   * `DaypartBaseline`, `DaypartRange`, `DaypartForecast`,
//     `BaselineRecommendationSignals`, `BaselineRangeGraphModel`,
//     `OpzValidation`, `BaselineRangeValidation`

import '../canonical_day_order.dart';

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

// ─── Lever metadata ───────────────────────────────────────────────────────────

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
    metric: 'Covers came in light',
    causeCategory: 'VOLUME',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'Fewer guests walked in than the schedule was built for, and the hours did not come down to meet the lighter volume. Both sides drift up because the sales side shrank while labor held. This is a forecast or scheduling gap, not a team problem.',
    whatToDo:
        'Track covers mid-week against the forecast. When the pace is running light, cut hours in real time, do not wait for close. Build next week from covers divided by your CPLH target so the schedule starts where demand actually is.',
    teachingNote:
        'Covers down with hours that did not flex is the most common bleed. One light week is normal variation. The same daypart light week after week means the forecast is overstating demand there.',
    shortLabel: 'COVERS',
    isFavorable: false,
    weekActionLine: 'Schedule fewer FOH hours to match actual cover pace.',
  );

  static const coversUp = LeverCardData(
    id: 'covers_up',
    metric: 'Volume came in above plan',
    causeCategory: 'VOLUME',
    side: LeverSide.both,
    direction: LeverDirection.favorable,
    whatHappened:
        'More guests showed up than you forecast, and the team carried them on the hours already scheduled. Both sides looked better because the extra covers grew the sales side. The rule before you celebrate a good number: check CPLH. If it held in the zone this was design. If it ran soft, the volume did work the schedule should have done.',
    whatToDo:
        'If CPLH held, write down the staffing setup that absorbed the covers, that is a benchmark. If CPLH ran below target, do not raise the forecast yet, first build the schedule from covers divided by your CPLH target.',
    teachingNote:
        'A hot week can rescue a bloated schedule and still post a good number. That is luck, not a system. If covers keep beating forecast in the same dayparts and CPLH holds, recalibrate the forecast upward. If CPLH does not hold, the leak is the schedule.',
    shortLabel: 'COVERS',
    isFavorable: true,
    weekActionLine: 'Raise your weekly cover forecast for next week.',
  );

  static const ppaDown = LeverCardData(
    id: 'ppa_down',
    metric: 'PPA running below target',
    causeCategory: 'GUEST EXPERIENCE',
    side: LeverSide.both,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'Guests spent less per head. The first check is not the menu, it is CPLH. When the team is pushed above the OPZ ceiling, check-backs stop and upsells die. Look at productivity before you talk about training.',
    whatToDo:
        'Cross-reference CPLH. If it was above the ceiling, the fix is staffing level, not a coaching conversation. A team running too lean cannot sell. Give them the floor to do it.',
    teachingNote:
        'Upsells die above the OPZ ceiling. If PPA drops cluster in the same dayparts where CPLH runs hot, guest attention is being lost there. That is a staffing pattern, not a people problem.',
    shortLabel: 'PPA',
    isFavorable: false,
    weekActionLine: 'Cross-check CPLH. If above ceiling, fix staffing first.',
  );

  static const ppaUp = LeverCardData(
    id: 'ppa_up',
    metric: 'PPA above target',
    causeCategory: 'GUEST EXPERIENCE',
    side: LeverSide.both,
    direction: LeverDirection.favorable,
    whatHappened:
        'Guests spent more per head. Check-backs happened, upsells landed, service was not rushed. This is the OPZ working as designed: the team had enough floor to take care of people and people responded.',
    whatToDo:
        'Write down what made this shift work: covers, daypart, who was on the floor, how the team was deployed. You cannot replicate what you do not understand. This is a benchmark shift.',
    teachingNote:
        'PPA rises when the team is inside the zone, busy but not overwhelmed. Study which dayparts produce it and protect the staffing level that left room to sell.',
    shortLabel: 'PPA',
    isFavorable: true,
    weekActionLine: 'Write down what made this week work. Replicate it.',
  );

  static const cplhDown = LeverCardData(
    id: 'cplh_down',
    metric: 'CPLH below target',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'More front-of-house hours were scheduled than the covers required. Servers had tables to spare and you paid for hours the volume never used. BOH is unaffected, this is a front-of-house scheduling decision.',
    whatToDo:
        'Build next week\'s FOH schedule from the math: forecast covers divided by your CPLH target. That number is your required FOH hours. Build from that, not from last week\'s sheet.',
    teachingNote:
        'Scheduling to last week or to revenue is why this repeats. If the same FOH dayparts run below target, hours are being built above actual cover demand there. Fix the schedule input, not the team.',
    shortLabel: 'CPLH',
    isFavorable: false,
    weekActionLine: 'Start next week\'s FOH schedule from covers ÷ 4.5.',
  );

  static const cplhUp = LeverCardData(
    id: 'cplh_up',
    metric: 'CPLH above target',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.favorable,
    whatHappened:
        'Front-of-house covered the volume with fewer hours than model. The team moved efficiently and FOH labor landed below model. As long as CPLH stayed under the OPZ ceiling, this is what a well-scheduled shift looks like.',
    whatToDo:
        'Check OPZ position. Below the ceiling: document this shift, staffing level, cover count, daypart, that is your replicable setup. Above the ceiling: the team was stretched and service likely felt it even if the number looked good.',
    teachingNote:
        'Efficient is only a win inside the zone. Study which dayparts can sustain this CPLH without pushing past the ceiling. That range is your real FOH target.',
    shortLabel: 'CPLH',
    isFavorable: true,
    weekActionLine: 'Document this shift. That is your replicable setup.',
  );

  static const splhDown = LeverCardData(
    id: 'splh_down',
    metric: 'SPLH below target',
    causeCategory: 'KITCHEN PRODUCTIVITY',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The kitchen produced fewer sales per labor hour than model. FOH is unaffected, the leak is back of house. It is either ticket times running slow or BOH simply overstaffed for the sales that came in.',
    whatToDo:
        'Check two things: kitchen ticket-time logs and BOH hours against actual sales. Clean tickets mean overstaffing. Slow tickets mean throughput. Different problems, different fixes.',
    teachingNote:
        'A drop in SPLH with steady covers means the kitchen took longer per ticket or carried hours the volume did not need. If it repeats in the same BOH dayparts, inspect station load and throughput there.',
    shortLabel: 'SPLH',
    isFavorable: false,
    weekActionLine: 'Pull BOH ticket-time logs. Identify overstaffed positions.',
  );

  static const splhUp = LeverCardData(
    id: 'splh_up',
    metric: 'SPLH above target',
    causeCategory: 'KITCHEN PRODUCTIVITY',
    side: LeverSide.boh,
    direction: LeverDirection.favorable,
    whatHappened:
        'The kitchen generated more sales per labor hour than model. Ticket times were likely clean and BOH was right-sized for what came in. FOH is unaffected, this is a well-run kitchen shift.',
    whatToDo:
        'Note the BOH configuration: who was on which station, the lineup, how prep was staged. That is your replicable kitchen setup. Write it down before the next roster goes out.',
    teachingNote:
        'SPLH is the kitchen’s productivity read. Study ticket flow, prep readiness, and station setup in the dayparts where it holds, and protect that setup.',
    shortLabel: 'SPLH',
    isFavorable: true,
    weekActionLine: 'Document your BOH configuration. Use it as the baseline.',
  );

  static const fohWageUp = LeverCardData(
    id: 'foh_wage_up',
    metric: 'FOH blended wage above model',
    causeCategory: 'WAGE MIX',
    side: LeverSide.foh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The hours were right, the cost on those hours was not. FOH blended wage ran above model, usually overtime or a higher-cost role covering a position it does not normally fill. BOH is unaffected.',
    whatToDo:
        'Pull FOH clock-outs and role assignments for the shift. Find who went over hours or covered outside their classification. This is a deployment decision for next week, not a performance conversation.',
    teachingNote:
        'Wage mix is largely outside the manager’s control, but deployment is not. If the same FOH dayparts keep triggering overtime or expensive coverage, that is a roster pattern to fix, not a labor problem to absorb.',
    shortLabel: 'WAGE',
    isFavorable: false,
    weekActionLine: 'Review FOH clock-outs and role assignments for overtime.',
  );

  static const bohWageUp = LeverCardData(
    id: 'boh_wage_up',
    metric: 'BOH blended wage above model',
    causeCategory: 'WAGE MIX',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'BOH blended wage ran above model. FOH is unaffected. The usual cause is a kitchen manager or sous chef dropping to a line position during a rush and logging hours at a higher rate. The hours may have been necessary, the deployment around them may not have been.',
    whatToDo:
        'Review BOH time cards and station assignments. Find who worked outside their usual role and what triggered it. The fix is smarter pre-shift BOH deployment: know which positions need coverage and at what rate before the shift starts.',
    teachingNote:
        'If the same BOH dayparts keep triggering overtime or manager coverage, that is a deployment pattern, not a general kitchen problem.',
    shortLabel: 'WAGE',
    isFavorable: false,
    weekActionLine: 'Review BOH time cards for off-classification coverage.',
  );

  static const fohWageDown = LeverCardData(
    id: 'foh_wage_down',
    metric: 'FOH blended wage below model',
    causeCategory: 'WAGE MIX',
    side: LeverSide.foh,
    direction: LeverDirection.favorable,
    whatHappened:
        'FOH blended wage came in below model. The right roles were on the right shifts, lower-cost coverage aligned with volume without sacrificing floor quality. BOH is unaffected.',
    whatToDo:
        'Document the FOH schedule configuration that produced this: which roles, at what hours, against what cover pace. Replicate the deployment pattern next week.',
    teachingNote:
        'A favorable wage mix is a deployment pattern worth banking. Study which role mix produced it and where it repeats.',
    shortLabel: 'WAGE',
    isFavorable: true,
    weekActionLine: 'Note the FOH role mix that produced this result. Replicate it.',
  );

  static const bohWageDown = LeverCardData(
    id: 'boh_wage_down',
    metric: 'BOH blended wage below model',
    causeCategory: 'WAGE MIX',
    side: LeverSide.boh,
    direction: LeverDirection.favorable,
    whatHappened:
        'BOH blended wage came in below model. Kitchen deployment matched volume without overtime or off-classification coverage. FOH is unaffected.',
    whatToDo:
        'Document the BOH station assignments and shift times that produced this. It is your benchmark kitchen configuration, the starting point for next week\'s lineup.',
    teachingNote:
        'Bank the kitchen setup that produced the favorable mix and study where it repeats.',
    shortLabel: 'WAGE',
    isFavorable: true,
    weekActionLine: 'Note the kitchen deployment that produced this result.',
  );

  static const fohHoursOver = LeverCardData(
    id: 'foh_hours_over',
    metric: 'FOH hours did not flex down',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The floor carried more hours than the covers needed. The model called for fewer FOH hours for what walked in, but the schedule never came down, so the excess shows up as labor above model. BOH is unaffected, this is a front-of-house flex issue.',
    whatToDo:
        'Compare the published FOH schedule to model hours by daypart. Where the gap is widest, pull hours before the shift opens. The discipline is to cut before you open, not after you find out at close.',
    teachingNote:
        'This is the covers-down bleed seen from the hours side. If the same FOH slots carry excess week after week, the schedule is being built above what the forecast supports.',
    shortLabel: 'HOURS',
    isFavorable: false,
    weekActionLine: 'Pull FOH hours to match model before shifts open.',
  );

  static const fohHoursUnder = LeverCardData(
    id: 'foh_hours_under',
    metric: 'FOH ran lean on hours',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.favorable,
    whatHappened:
        'FOH hours came in below model for the volume. The floor ran lean, fewer servers covered more guests. That is efficient only if PPA held and CPLH stayed under the OPZ ceiling, so check PPA before you call it a win.',
    whatToDo:
        'Cross-check PPA and CPLH. PPA held and CPLH below the ceiling: document this FOH setup, it is your benchmark. PPA dropped: the floor was too lean to sell, you found the staffing floor, not the efficient setup.',
    teachingNote:
        'Lean is favorable until it crosses the ceiling. Study whether PPA dips when FOH hours run below model. That line is where efficiency turns into understaffing.',
    shortLabel: 'HOURS',
    isFavorable: true,
    weekActionLine: 'Document this FOH setup if PPA and service held.',
  );

  static const bohHoursOver = LeverCardData(
    id: 'boh_hours_over',
    metric: 'BOH hours did not flex down',
    causeCategory: 'SCHEDULING',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The kitchen carried more hours than the sales volume required. The model called for fewer BOH hours for what came through, but the schedule did not flex, driving labor above theoretical. FOH is unaffected, this is a back-of-house scheduling issue.',
    whatToDo:
        'Review the BOH lineup against actual sales by daypart. Where prep hours or line cooks exceeded what the volume needed, tighten there. Build next week\'s BOH from forecast sales divided by target SPLH.',
    teachingNote:
        'If kitchen overstaffing repeats in the same slots, the schedule is being built above what the sales forecast supports there.',
    shortLabel: 'HOURS',
    isFavorable: false,
    weekActionLine: 'Tighten BOH lineup to match model hours by daypart.',
  );

  static const bohHoursUnder = LeverCardData(
    id: 'boh_hours_under',
    metric: 'BOH ran lean on hours',
    causeCategory: 'SCHEDULING',
    side: LeverSide.boh,
    direction: LeverDirection.favorable,
    whatHappened:
        'BOH hours came in below model for the sales volume. The kitchen ran lean, fewer hours covered more output. That is a well-run kitchen only if ticket times stayed clean and quality held, so check SPLH and tickets.',
    whatToDo:
        'Cross-check SPLH and ticket times. Both held: document the BOH configuration, station assignments, prep staging, lineup, that is your replicable setup. Tickets slipped: the kitchen was stretched too thin.',
    teachingNote:
        'Lean kitchen hours are favorable when throughput holds. Study whether ticket times slip when BOH runs below model. That is where efficiency turns into understaffing.',
    shortLabel: 'HOURS',
    isFavorable: true,
    weekActionLine: 'Document this BOH setup if ticket times and quality held.',
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
    fohHoursOver,
    fohHoursUnder,
    bohHoursOver,
    bohHoursUnder,
  ];

  // Primary lever for demo scenario
  static const LeverCardData primaryDemoLever = coversDown;

  /// User-facing label for rows whose lever id is the `on_model` sentinel
  /// or anything outside the 16 known ids. Renderers MUST surface this
  /// state explicitly instead of falling through to a real lever card.
  /// See `docs/contracts/phase_7_58_primary_driver_contract.md` Finding F-1.
  static const String notYetOnModelLabel = 'Not yet on-model';

  /// Returns the [LeverCardData] for [id], or `null` for the `on_model`
  /// sentinel, an unknown id, or empty/null input. Lookup is
  /// case-insensitive: storage form `'COVERS_DOWN'` and engine form
  /// `'covers_down'` both match `coversDown`.
  ///
  /// Renderers MUST handle the null return as a degraded "Not yet
  /// on-model" state — the silent fall-through to [coversDown] that
  /// existed before phase 7.58.UX.5 overclaimed a real driver that the
  /// engine had not detected.
  static LeverCardData? lookup(String? id) {
    if (id == null || id.isEmpty) return null;
    final normalized = id.toLowerCase();
    if (normalized == 'on_model') return null;
    for (final card in all) {
      if (card.id == normalized) return card;
    }
    return null;
  }

  /// Metric-direction glyph for [id], derived from the catalog id
  /// suffix (`_up` / `_over` → `↑`; `_down` / `_under` → `↓`). This
  /// is the *raw metric movement*, distinct from
  /// [LeverCardData.direction] (favorable/unfavorable). For example,
  /// `foh_wage_down` is favorable but the metric movement is down.
  ///
  /// Returns `null` for unknown / sentinel / null / empty input —
  /// renderers must handle that as a degraded state alongside the
  /// matching [lookup] call. Catalog membership is gated by
  /// [lookup] first, so an unknown id with a coincidental suffix
  /// (e.g. `not_catalog_up`) cannot leak an arrow that would imply
  /// a real catalog id.
  static String? metricDirectionGlyph(String? id) {
    if (lookup(id) == null) return null;
    final normalized = id!.toLowerCase();
    if (normalized.endsWith('_up') || normalized.endsWith('_over')) {
      return '↑';
    }
    if (normalized.endsWith('_down') || normalized.endsWith('_under')) {
      return '↓';
    }
    return null; // unreachable: every catalog id ends in a known suffix.
  }
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
  /// Optional support line rendered directly under targetFormatted.
  /// Used for contextual signals like "In the books 72" on the COVERS card.
  final String? targetSupportFormatted;

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
    this.targetSupportFormatted,
  });
}

// ─── Day-order constants for Full Week section ────────────────────────────────
// Thin bridge: delegates to CanonicalDayOrder for day-label iteration.
// The per-day daypart-ID lookup helper was retired in Phase 7.55r item 2;
// callers now read `RestaurantTimingConfig.servicePeriodDefinitions`
// (via `RestaurantTimingConfigReadService`) and call
// `ServicePeriodDefinitionResolver.idsForDayLabel(defs, dayLabel)` directly,
// with `demoDefinitions` as honest fallback when no persisted config exists.

class WeekDayOrder {
  /// Canonical Mon–Sun day-label list.
  ///
  /// Thin bridge: delegates to [CanonicalDayOrder.labels].
  static const List<String> dayLabels = CanonicalDayOrder.labels;
}
