// Part of sqlite_database.dart. R6 four-period demo proof location seeders.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

// ── R6 — Choose Star Shifts: 4-period demo operator ───────────────────────
//
// Authority: this R6 prompt (authority order #1 — the active prompt) +
//            CLAUDE.md "Demo Mode" (HP #2) + the per-daypart de-hardcode
//            doctrine (`docs/phases/per_daypart_targets_v1/...`).
//
// Why this region exists: every `DemoScope.locations` member is a
// 3-period (lunch/dinner/late_night) dataset — Downtown is the 3-period
// proof reference (HP #11 single-axis tests pin it), North Loop /
// Riverside are replay-seeded 3-period (+ a single-axis week-start /
// wage override), and Harbour is hard-asserted to carry ZERO
// `shift_records` (honest-empty;
// `per_daypart_v1_demo_seed_per_location_data_test.dart:87-90`). So
// there was NO demo dataset whose `service_period_definitions_json`
// defines four periods, and the redesign's daypart de-hardcode (the
// baseline / "Choose Star Shifts" screen currently keys off the fixed
// 3-element `ServicePeriodDefinitionResolver.demoDefinitions`) cannot
// be visually or test-proven against a >3-period restaurant.
//
// This region adds ONE dedicated 4-period proof location
// ([_kDemoFourPeriodRestaurantId]) — its own `restaurant_locations`
// row, a 4-period `restaurant_timing_configs` row, and a deterministic
// 60-day closed `shift_records` cohort whose `daypart` /
// `service_period_key` is drawn from the CONFIGURED period id list (no
// fixed 3-element assumption — the loop is `for (period in
// periods)`), so every one of the four configured periods has closed
// candidates across the 60-day window the baseline-candidate read
// service scans.
//
// Scope discipline (R6 = data/seed only): this is a self-contained
// seeder writing ONLY the same production tables production demo
// seeding uses. It is intentionally NOT a `DemoScope.locations` member
// — adding a 5th entry would ripple through ~6 per-location seeder
// loops, the operator-web team/vendor fixtures, and ≥3 hard-asserted
// location-set tests (out of an R6 data-only slice's scope). The
// per-location replay/operational loops therefore never touch this
// restaurant_id (they iterate `DemoScope.locations`), so there is no
// collision with the 3-period replay cohort and no existing-test
// regression.
//
// HP #2: standard production tables only (`restaurant_locations`,
// `restaurant_timing_configs`, `shift_records`). No `demo_*` table, no
// `kDemoMode` reader branch — writer-side seed only; every reader /
// repository / widget (`RestaurantTimingConfigDao`,
// `ServicePeriodDefinitionResolver`, the baseline candidate read
// service) consumes these rows through the SAME code path in demo and
// prod.
// HP #4: every write is scoped to the single
// [_kDemoFourPeriodRestaurantId]; no cross-(operator, location) write.
//
// Determinism (NO RNG): every value is a compile-time constant or is
// derived deterministically from the seed-anchor business date. Two
// reseeds are byte-identical. Operator-authority-safe: skip-if-present
// guards + `ConflictAlgorithm.ignore` so it can never clobber an
// operator-entered row.

/// The dedicated 4-period "Choose Star Shifts" demo proof location.
/// A stable fixed id (NOT a `DemoScope.locations` member — see the
/// region header). Distinct prefix so it can never collide with a real
/// tenant or a `DemoScope` location id.
const String _kDemoFourPeriodRestaurantId = 'demo_restaurant_four_period';

/// The proof location's display name (scope-drawer-agnostic — surfaced
/// wherever a reader resolves this restaurant_id).
const String _kDemoFourPeriodDisplayName = 'Barrio Legado: Four-Period';

/// Same business-day start + timezone basis as the other demo
/// restaurants so business-date bucketing is consistent.
const String _kDemoFourPeriodBusinessTimezone = 'America/St_Johns';

/// FOUR service periods — Breakfast / Lunch / Dinner / Late night —
/// each with a full id/label/short_label/sort_order/start/end/
/// applicable_days definition. This is the SINGLE source of truth for
/// both the seeded `service_period_definitions_json` and the closed
/// `shift_records` period assignment below; the closed-cohort seeder
/// derives the period key set from THIS list (no hardcoded 3 or 4
/// count), so the dataset stays internally consistent and proves the
/// de-hardcode against an N≠3 period set.
const List<Map<String, Object?>> _kDemoFourPeriodServicePeriods =
    <Map<String, Object?>>[
      {
        'id': 'breakfast',
        'label': 'Breakfast',
        'short_label': 'B',
        'sort_order': 1,
        'start_local_time': '07:00',
        'end_local_time': '11:00',
        'rolls_past_midnight': false,
        // Breakfast every day (a real all-week breakfast service).
        'applicable_days': [1, 2, 3, 4, 5, 6, 7],
      },
      {
        'id': 'lunch',
        'label': 'Lunch',
        'short_label': 'L',
        'sort_order': 2,
        'start_local_time': '11:00',
        'end_local_time': '15:00',
        'rolls_past_midnight': false,
        'applicable_days': [1, 2, 3, 4, 5, 6, 7],
      },
      {
        'id': 'dinner',
        'label': 'Dinner',
        'short_label': 'D',
        'sort_order': 3,
        'start_local_time': '17:00',
        'end_local_time': '23:00',
        'rolls_past_midnight': false,
        'applicable_days': [1, 2, 3, 4, 5, 6, 7],
      },
      {
        'id': 'late_night',
        'label': 'Late night',
        'short_label': 'LN',
        'sort_order': 4,
        'start_local_time': '23:00',
        'end_local_time': '02:00',
        'rolls_past_midnight': true,
        // Late night Thu–Sun only (real weekend-leaning late service).
        'applicable_days': [4, 5, 6, 7],
      },
    ];

/// Maps an ISO weekday (1=Mon..7=Sun) to the canonical day label the
/// `shift_records` schema + baseline candidate read service use.
const List<String> _kIsoWeekdayDayLabels = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Per-period deterministic base metrics for the proof cohort. Values
/// are realistic and distinct per period so the four periods render as
/// materially different candidates (no cloned rows). Keyed by the
/// configured period id — a period absent here still seeds (falls back
/// to the breakfast profile) so the seeder can never silently drop a
/// configured period.
const Map<String, Map<String, num>> _kDemoFourPeriodMetrics =
    <String, Map<String, num>>{
      'breakfast': {'covers': 95, 'ppa': 14.50, 'cplh': 38.0, 'splh': 95.0},
      'lunch': {'covers': 165, 'ppa': 22.00, 'cplh': 44.0, 'splh': 140.0},
      'dinner': {'covers': 210, 'ppa': 31.00, 'cplh': 41.0, 'splh': 170.0},
      'late_night': {'covers': 70, 'ppa': 18.00, 'cplh': 33.0, 'splh': 110.0},
    };

/// Seeds the 4-period proof location's `restaurant_locations` +
/// `restaurant_timing_configs` rows. Idempotent (skip-if-present +
/// `ConflictAlgorithm.ignore`); deterministic (fixed timestamp). The
/// definitions are written exactly as `RestaurantTimingConfigDao.upsert`
/// would (sorted by sort_order then id), so the runtime read seam
/// (`SqliteRestaurantTimingConfigRepository.getTimingConfig` →
/// `ServicePeriodDefinitionResolver`) resolves four ordered periods.
Future<void> _seedDemoFourPeriodTimingConfig(Database db) async {
  // Fixed literal — determinism (never DateTime.now()).
  const ts = '2026-05-16T00:00:00.000Z';

  await db.insert('restaurant_locations', {
    'restaurant_id': _kDemoFourPeriodRestaurantId,
    'display_name': _kDemoFourPeriodDisplayName,
    'business_timezone': _kDemoFourPeriodBusinessTimezone,
    'created_at': ts,
    'updated_at': ts,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  if (!await _tableExists(db, 'restaurant_timing_configs')) return;
  final existing = await db.query(
    'restaurant_timing_configs',
    where: 'restaurant_id = ?',
    whereArgs: [_kDemoFourPeriodRestaurantId],
    limit: 1,
  );
  if (existing.isNotEmpty) return; // operator authority — never clobber

  // Canonicalize order exactly as RestaurantTimingConfigDao.upsert does
  // (sort_order asc, then id asc) so the persisted JSON round-trips to
  // the same ordered definition list the DAO would have produced.
  final sorted = [..._kDemoFourPeriodServicePeriods]
    ..sort((a, b) {
      final cmp = (a['sort_order'] as int).compareTo(b['sort_order'] as int);
      return cmp != 0 ? cmp : (a['id'] as String).compareTo(b['id'] as String);
    });

  await db.insert('restaurant_timing_configs', {
    'restaurant_id': _kDemoFourPeriodRestaurantId,
    'business_day_start_local_time': '04:00',
    'week_start_day': DateTime.monday,
    'service_period_definitions_json': jsonEncode(sorted),
    'created_at': ts,
    'updated_at': ts,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}

/// Seeds a deterministic 60-day closed `shift_records` cohort for the
/// 4-period proof location, anchored at [anchorBusinessDate] (the same
/// seed anchor the rest of the demo cohort uses). For each business
/// date in the trailing 60-day window, the configured periods
/// APPLICABLE on that weekday each get one `closed` shift — the period
/// loop iterates [_kDemoFourPeriodServicePeriods] (no fixed 3/4 count),
/// so every configured period that serves that weekday has closed
/// candidates spread across the whole window.
///
/// Idempotent: clears this restaurant_id's `shift_records` first
/// (matching how `_seedDemoDataFromReplay` reseeds the demo scope) then
/// regenerates the identical deterministic set, so two reseeds are
/// byte-identical and no operator data is at risk (this id is a demo
/// proof location, never an operator scope).
Future<void> _seedDemoFourPeriodClosedShifts(
  Database db, {
  required String anchorBusinessDate,
}) async {
  await db.delete(
    'shift_records',
    where: 'restaurant_id = ?',
    whereArgs: [_kDemoFourPeriodRestaurantId],
  );

  // Period id → applicable ISO weekdays, straight from the configured
  // definitions (no hardcoded period set).
  final periodApplicableDays = <String, Set<int>>{
    for (final p in _kDemoFourPeriodServicePeriods)
      p['id'] as String: ((p['applicable_days'] as List).cast<int>()).toSet(),
  };
  // Stable canonical period order (sort_order then id) so the seeded
  // rows + any ordered read are consistent.
  final orderedPeriodIds =
      (<String>[
        for (final p in _kDemoFourPeriodServicePeriods) p['id'] as String,
      ]..sort((a, b) {
        final pa = _kDemoFourPeriodServicePeriods.firstWhere(
          (p) => p['id'] == a,
        );
        final pb = _kDemoFourPeriodServicePeriods.firstWhere(
          (p) => p['id'] == b,
        );
        final cmp = (pa['sort_order'] as int).compareTo(
          pb['sort_order'] as int,
        );
        return cmp != 0 ? cmp : a.compareTo(b);
      }));

  final batch = db.batch();
  // 60-day trailing window ending at the anchor (inclusive), matching
  // the baseline-candidate read window (`_addIsoDays(anchor, -59)`).
  for (var dayOffset = 59; dayOffset >= 0; dayOffset--) {
    final businessDate = _addIsoDays(anchorBusinessDate, -dayOffset);
    final dt = DateTime.parse(businessDate);
    final isoWeekday = dt.weekday; // 1=Mon..7=Sun
    final dayLabel = _kIsoWeekdayDayLabels[isoWeekday - 1];
    // Mirror the mock-replay weekId convention (YYYY-Www, ISO week).
    final monday = dt.subtract(Duration(days: isoWeekday - 1));
    final jan4 = DateTime(monday.year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    final weekNum = ((monday.difference(week1Monday).inDays) ~/ 7) + 1;
    final weekId = '${monday.year}-W${weekNum.toString().padLeft(2, '0')}';

    for (final periodId in orderedPeriodIds) {
      // De-hardcode proof: a period only contributes a closed shift on
      // a weekday it actually serves — driven purely by the configured
      // `applicable_days`, never a fixed assumption.
      if (!(periodApplicableDays[periodId]?.contains(isoWeekday) ?? false)) {
        continue;
      }
      final m =
          _kDemoFourPeriodMetrics[periodId] ??
          _kDemoFourPeriodMetrics['breakfast']!;
      final covers = (m['covers'] as num).toInt();
      final ppa = (m['ppa'] as num).toDouble();
      final cplh = (m['cplh'] as num).toDouble();
      final splh = (m['splh'] as num).toDouble();
      final sales = covers * ppa;
      final fohHours = (covers / cplh).round().clamp(1, 999999);
      final bohHours = (sales / splh).round().clamp(1, 999999);

      final record = ShiftRecord(
        restaurantId: _kDemoFourPeriodRestaurantId,
        weekId: weekId,
        dayLabel: dayLabel,
        daypart: periodId,
        status: 'closed',
        covers: covers,
        forecastCovers: covers,
        ppa: ppa,
        cplh: cplh,
        splh: splh,
        fohHours: fohHours,
        bohHours: bohHours,
        primaryLever: 'COVERS_DOWN',
        businessDate: businessDate,
        servicePeriodKey: periodId,
        sourceSystem: 'demo_four_period_seed',
      );
      final map = record.toMap()..remove('id');
      batch.insert('shift_records', map);
    }
  }
  await batch.commit(noResult: true);
}
