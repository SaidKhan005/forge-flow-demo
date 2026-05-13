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

  static const fohHoursOver = LeverCardData(
    id: 'foh_hours_over',
    metric: 'FOH HOURS DID NOT FLEX DOWN',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The floor carried more hours than the covers needed. The model says you needed fewer FOH hours '
        'for what actually walked in — but the schedule didn\'t come down. Those excess hours are showing '
        'up as labor cost above model. Your BOH is unaffected — this is a front-of-house flex issue.',
    whatToDo:
        'Compare your published FOH schedule to the model hours for each daypart. Where the gap is widest, '
        'that\'s where hours need to be pulled before the shift opens. Don\'t wait until close to find out.',
    teachingNote:
        'Study which FOH dayparts carry the most excess hours. If the same slots repeat, the schedule is '
        'being built above what the forecast supports. The fix is pre-shift — cut before you open, not after.',
    shortLabel: 'HOURS',
    isFavorable: false,
    weekActionLine: 'Pull FOH hours to match model before shifts open.',
  );

  static const fohHoursUnder = LeverCardData(
    id: 'foh_hours_under',
    metric: 'FOH RAN LEAN ON HOURS',
    causeCategory: 'SCHEDULING',
    side: LeverSide.foh,
    direction: LeverDirection.favorable,
    whatHappened:
        'FOH hours came in below what the model needed for the volume. The floor ran lean — fewer servers '
        'covered more guests. As long as PPA held and CPLH stayed inside the OPZ ceiling, this is exactly '
        'what efficient scheduling looks like. Check your PPA — if it dropped, the team was stretched too thin.',
    whatToDo:
        'Cross-check PPA and CPLH for this shift. If PPA held and CPLH stayed below the ceiling, document '
        'this FOH configuration — it\'s your benchmark. If PPA dropped, the floor was too lean to sell.',
    teachingNote:
        'Lean hours are favorable when service metrics hold. Study whether PPA dips when FOH hours run below '
        'model — if it does, you found the staffing floor. If it doesn\'t, you found the efficient setup.',
    shortLabel: 'HOURS',
    isFavorable: true,
    weekActionLine: 'Document this FOH setup if PPA and service held.',
  );

  static const bohHoursOver = LeverCardData(
    id: 'boh_hours_over',
    metric: 'BOH HOURS DID NOT FLEX DOWN',
    causeCategory: 'SCHEDULING',
    side: LeverSide.boh,
    direction: LeverDirection.unfavorable,
    whatHappened:
        'The kitchen carried more hours than the sales volume required. The model says you needed fewer BOH '
        'hours for what actually came through — but the schedule didn\'t flex. Those excess hours are driving '
        'labor cost above theoretical. Your FOH is unaffected — this is a back-of-house scheduling issue.',
    whatToDo:
        'Review your BOH lineup against actual sales by daypart. Where prep hours or line cooks exceeded what '
        'the volume needed, that\'s where to tighten. Build next week\'s BOH schedule from sales forecast ÷ '
        'target SPLH.',
    teachingNote:
        'Study which BOH dayparts carry the most excess hours. If kitchen overstaffing repeats in the same '
        'slots, the schedule is being built above what the sales forecast supports.',
    shortLabel: 'HOURS',
    isFavorable: false,
    weekActionLine: 'Tighten BOH lineup to match model hours by daypart.',
  );

  static const bohHoursUnder = LeverCardData(
    id: 'boh_hours_under',
    metric: 'BOH RAN LEAN ON HOURS',
    causeCategory: 'SCHEDULING',
    side: LeverSide.boh,
    direction: LeverDirection.favorable,
    whatHappened:
        'BOH hours came in below what the model needed for the sales volume. The kitchen ran lean — fewer '
        'hours covered more output. If ticket times stayed clean and food quality held, this is a well-run '
        'kitchen. Check your SPLH — if it\'s above target, the deployment worked.',
    whatToDo:
        'Cross-check SPLH and ticket times. If both held, document this BOH configuration — station '
        'assignments, prep staging, lineup. That is your replicable kitchen setup. If ticket times slipped, '
        'the kitchen was stretched too thin.',
    teachingNote:
        'Lean kitchen hours are favorable when throughput holds. Study whether ticket times slip when BOH '
        'hours run below model — if they do, you found the staffing floor. If they don\'t, you found efficiency.',
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
