// Part of sqlite_database.dart. Slice F HP #11 scope-level override seeders.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

// ── Demo-data Slice F — HP #11 scope-level overrides + notifications ───────
//
// Authority: docs/_audits/per_daypart_v1/full_demo_data_spec.md Slice F
//            (§2c "HP #11 override examples, one per scope level",
//            lines 140-144; §1.6 Notifications line 80; Gap G9/G10);
//            CLAUDE.md HP #11 / HP #2 / HP #4.
//
// Why this region exists (Gap G10 + G9): before Slice F there were NO
// scope-level override rows, so HP #11 inherited-vs-effective pills
// resolved trivially (one value at one scope), and there were NO
// notification/alert rows so the Notifications surface was empty.
//
// Realization (spec §4 watch item, line 210): mobile SQLite has NO
// `org_units` / scope-level columns — `restaurant_timing_configs`
// (PK `restaurant_id`), `wage_role_rows` (UNIQUE `restaurant_id`,
// `role_name`), and `data_accuracy_service_period_settings_cache`
// (PK `restaurant_id`, ...) are all `restaurant_id`-keyed. The §2c
// scope hierarchy (corp → region → district → location) lives in the
// operator-web fixture; on mobile a scope-level override is realized
// as a per-`restaurant_id` row, and "inherits" is realized as the
// ABSENCE of a per-location row (the production reader returns null /
// no cached row → the caller falls back to the business default). So:
//
//   * Business/operator default (the inherited-FROM source):
//       Downtown (`DemoScope.restaurantId`) — its existing
//       `_seedDemoTimingConfig` (week-start Monday) + `_seedDemoWageRoleRows`
//       (FOH 16.50 / BOH 21.35) + the data-accuracy baseline seeded
//       here (all periods covers_source `vendor`). UNCHANGED by this
//       region — it IS the baseline every other scope inherits.
//   * Region scope — East Region overrides timing: North Loop (the
//       other East-Region location) gets a `restaurant_timing_configs`
//       row whose week-start is Sunday (≠ business default Monday).
//   * District scope — Metro District overrides a data-accuracy
//       covers-source: North Loop (the sole location under Metro
//       District) gets a `data_accuracy_service_period_settings_cache`
//       dinner row with covers_source `manual` (≠ business default
//       `vendor`). Its lunch / late_night have NO row → inherit.
//   * Location scope — Riverside overrides wages (location wins over
//       the business default); Harbour inherits unchanged: Riverside
//       gets `wage_role_rows` blending FOH 17.50 / BOH 22.35
//       (≠ business default 16.50 / 21.35); Harbour gets NO override
//       row in ANY of the three tables, so every reader resolves
//       Harbour to the inherited business default — the "inherited
//       from Business" pill is exercised end-to-end.
//
// HP #2: standard production tables only (`restaurant_timing_configs`,
// `wage_role_rows`, `data_accuracy_service_period_settings_cache`,
// `app_notifications`). No `demo_*` table, no `kDemoMode` reader
// branch — writer-side seed only; every reader/repository/widget is
// untouched and resolves demo and prod identically.
// HP #4: every write is scoped to one demo `restaurant_id`; no
// cross-(operator, location) write.
// HP #11: this region ONLY ADDS override rows. It never deletes or
// rewrites a scope/inherited/effective affordance, and never touches
// Downtown's business-default rows. The operator-web wage/data-accuracy
// inherited-source PILL itself is Gap 32 (wage authority resolver
// hardcoded to location scope) / Gap 29 (no data-accuracy
// `HierarchyScopeNotice` yet) per the spec §1.7 — those are
// gated/incomplete UI, not removed affordances; this slice shapes the
// DATA so the inheritance is correct the moment those notices land,
// and mirrors the wage scope story into the operator-web demo gateway
// (`OperatorWebDemoWageAuthorityGateway` default fixture).
//
// Determinism (NO RNG): every value is a compile-time constant or is
// derived from already-deterministic seeded `week_records`. Timestamps
// are fixed literals (never `DateTime.now()`), so two reseeds are
// byte-identical. Operator-authority-safe: each seeder skips a
// `restaurant_id` that already has a row (mirrors `_seedDemoWageRoleRows`)
// and uses `ConflictAlgorithm.ignore`, so it can never clobber an
// operator's configured value.

/// Demo operator id used for the data-accuracy cache scope columns.
/// Mirrors `kDemoOperatorOperatorId` (`'n'`) from
/// `lib/services/auth/demo_auth_login_service.dart` without importing
/// the auth layer into persistence. The cache reader filters by
/// `restaurant_id` only; `operator_id` / `location_id` are stored
/// scope columns kept consistent with the runtime convention
/// (`location_id == restaurant_id`).
const String _kDemoScopeOperatorId = 'n';

/// The three demo service periods, identical to `_seedDemoTimingConfig`'s
/// business default ([_kDemoDowntownServicePeriods]). Replicated (not
/// shared) so the East-Region timing override is a clean SINGLE-axis
/// change (week-start only) — the service-period set stays byte-equal to
/// the business default so the HP #11 diff renders as exactly "week
/// start: Sunday (set at East Region) vs Monday (inherited from
/// Business)". QA fix (Change B): `lunch.applicable_days` includes Sat
/// (6) + Sun (7), kept byte-equal to [_kDemoDowntownServicePeriods] so
/// the single-axis invariant holds.
const List<Map<String, Object?>> _kDemoBusinessDefaultServicePeriods =
    <Map<String, Object?>>[
      {
        'id': 'lunch',
        'label': 'Lunch',
        'short_label': 'L',
        'sort_order': 1,
        'start_local_time': '11:00',
        'end_local_time': '15:00',
        'rolls_past_midnight': false,
        'applicable_days': [1, 2, 3, 4, 5, 6, 7],
      },
      {
        'id': 'dinner',
        'label': 'Dinner',
        'short_label': 'D',
        'sort_order': 2,
        'start_local_time': '17:00',
        'end_local_time': '23:00',
        'rolls_past_midnight': false,
        'applicable_days': [1, 2, 3, 4, 5, 6, 7],
      },
      {
        'id': 'late_night',
        'label': 'Late Night',
        'short_label': 'LN',
        'sort_order': 3,
        'start_local_time': '23:00',
        'end_local_time': '02:00',
        'rolls_past_midnight': true,
        'applicable_days': [5, 6],
      },
    ];

/// Region scope (§2c) — East Region overrides timing.
///
/// East Region = Downtown + North Loop. Downtown carries the business
/// default (`_seedDemoTimingConfig`, week-start Monday) and is left
/// untouched. North Loop — the other East-Region location — gets a
/// `restaurant_timing_configs` row whose `week_start_day` is Sunday,
/// so the HP #11 resolver renders North Loop's effective week-start as
/// the East-Region override and Riverside / Harbour (no row →
/// `RestaurantTimingConfigDao.getConfig` returns null → caller
/// inherits) as the inherited business default.
Future<void> _seedDemoScopeOverrideTimingConfig(Database db) async {
  if (!await _tableExists(db, 'restaurant_timing_configs')) return;
  const overrideRestaurantId = DemoScope.northLoopRestaurantId;
  final existing = await db.query(
    'restaurant_timing_configs',
    where: 'restaurant_id = ?',
    whereArgs: [overrideRestaurantId],
    limit: 1,
  );
  if (existing.isNotEmpty) return; // operator authority — never clobber
  const now = '2026-05-15T00:00:00.000Z'; // fixed — determinism (NO now())
  await db.insert('restaurant_timing_configs', {
    'restaurant_id': overrideRestaurantId,
    'business_day_start_local_time': '04:00',
    // East-Region timing override: Sunday week-start (business
    // default is Monday). Single-axis HP #11 diff.
    'week_start_day': DateTime.sunday,
    'service_period_definitions_json': jsonEncode(
      _kDemoBusinessDefaultServicePeriods,
    ),
    'created_at': now,
    'updated_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}

/// Location scope (§2c) — Riverside overrides wages; Harbour inherits.
///
/// Riverside gets a full FOH/BOH `wage_role_rows` cohort whose weighted
/// blend (FOH 17.50 / BOH 22.35) deviates from the business default
/// (`_seedDemoWageRoleRows`: FOH 16.50 / BOH 21.35) — location wins
/// over the business default. North Loop + Harbour get NO wage rows, so
/// the wage waterfall / `_weightedAvgFromRows` resolves them to the
/// inherited business default (the empty-rows fallback == the business
/// default by construction), exercising the "inherited from Business"
/// pill for Harbour.
Future<void> _seedDemoScopeOverrideWageRows(Database db) async {
  const overrideRestaurantId = DemoScope.riversideRestaurantId;
  final existing = await db.query(
    'wage_role_rows',
    where: 'restaurant_id = ?',
    whereArgs: [overrideRestaurantId],
    limit: 1,
  );
  if (existing.isNotEmpty) return; // operator authority — never clobber
  const rows = <Map<String, Object?>>[
    // FOH cohort — weighted blend = (15.50 + 19.50) / 2 = 17.50
    // (business default 16.50 → +$1.00 location override).
    {
      'role_name': 'Server',
      'labor_bucket': 'foh',
      'hourly_rate': 15.50,
      'weighted_hours': 500.0,
    },
    {
      'role_name': 'Bartender',
      'labor_bucket': 'foh',
      'hourly_rate': 19.50,
      'weighted_hours': 500.0,
    },
    // BOH cohort — weighted blend = (20.35 + 24.35) / 2 = 22.35
    // (business default 21.35 → +$1.00 location override).
    {
      'role_name': 'Prep Cook',
      'labor_bucket': 'boh',
      'hourly_rate': 20.35,
      'weighted_hours': 500.0,
    },
    {
      'role_name': 'Line Cook',
      'labor_bucket': 'boh',
      'hourly_rate': 24.35,
      'weighted_hours': 500.0,
    },
  ];
  final batch = db.batch();
  for (final r in rows) {
    batch.insert('wage_role_rows', {
      'restaurant_id': overrideRestaurantId,
      'role_name': r['role_name'],
      'labor_bucket': r['labor_bucket'],
      'hourly_rate': r['hourly_rate'],
      'weighted_hours': r['weighted_hours'],
      'source': 'demo_seed',
      'is_active': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  await batch.commit(noResult: true);
}

/// District scope (§2c) — Metro District overrides a data-accuracy
/// covers-source; also seeds the business-default baseline.
///
/// Business default (the inherited-FROM source): Downtown gets the
/// three service-period rows with covers_source `vendor`. Metro
/// District (= North Loop, the sole location under it) gets a single
/// `dinner` row with covers_source `manual` — the deliberate one-axis
/// district override. North Loop's lunch / late_night and all of
/// Riverside / Harbour get NO row → the cache reader returns nothing →
/// the caller resolves them to the inherited business default.
Future<void> _seedDemoScopeOverrideDataAccuracy(Database db) async {
  if (!await _tableExists(db, 'data_accuracy_service_period_settings_cache')) {
    return;
  }
  const businessRid = DemoScope.restaurantId; // Downtown = business default
  const districtRid = DemoScope.northLoopRestaurantId; // Metro District
  final existing = await db.query(
    'data_accuracy_service_period_settings_cache',
    where: 'restaurant_id IN (?, ?)',
    whereArgs: [businessRid, districtRid],
    limit: 1,
  );
  if (existing.isNotEmpty) return; // operator authority — never clobber
  // Fixed literals — determinism (never DateTime.now()). The reader
  // picks the most recent row at-or-before the business date; a far-past
  // effective date keeps the baseline applicable to every demo date.
  const effectiveDate = '2020-01-01';
  const ts = '2026-05-15T00:00:00.000Z';
  Map<String, Object?> row({
    required String rid,
    required String period,
    required String coversSource,
  }) => <String, Object?>{
    'restaurant_id': rid,
    'service_period_key': period,
    'effective_at_business_date': effectiveDate,
    'id': 'demo_das_${rid}_$period',
    'operator_id': _kDemoScopeOperatorId,
    'location_id': rid, // runtime convention: location_id == rid
    'covers_source': coversSource,
    'wage_source': 'vendor_per_employee',
    'created_at': ts,
    'updated_at': ts,
    'updated_by': 'demo_seed',
    'cached_at': ts,
  };
  final batch = db.batch();
  // Business-default baseline — Downtown, all 3 periods `vendor`.
  for (final period in const ['lunch', 'dinner', 'late_night']) {
    batch.insert(
      'data_accuracy_service_period_settings_cache',
      row(rid: businessRid, period: period, coversSource: 'vendor'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
  // Metro District override — North Loop dinner covers_source `manual`.
  // Only the dinner row is seeded; lunch / late_night intentionally
  // have NO row so they inherit the business default (HP #11
  // inheritance is exercised WITHIN the district location too).
  batch.insert(
    'data_accuracy_service_period_settings_cache',
    row(rid: districtRid, period: 'dinner', coversSource: 'manual'),
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
  await batch.commit(noResult: true);
}
