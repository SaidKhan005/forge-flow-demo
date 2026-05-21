// SQLite bootstrap layer — owns database lifecycle, schema, and migrations.
//
// DatabaseHelper delegates to this for open/init. DAOs and repositories
// operate on the Database instance this class provides.

import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../domain/constants/app_defaults.dart';
import '../../../dev/demo_fixture_data.dart';
import '../../../dev/demo_vendor_integration_state_fixture.dart';
import '../../../dev/demo_vendor_integration_sync_proxy_client.dart';
import '../../../dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/domain/services/recommended_benchmark_selection_service.dart';
import '../../../domain/models/recommended_benchmark_selection.dart';
import '../../../domain/models/active_target_profile.dart';
import '../../../domain/models/import_run.dart';
import '../../../domain/models/open_shift_snapshot.dart';
import '../../../domain/models/raw_import_record.dart';
import '../../../domain/models/reservation_book_snapshot.dart';
import '../../../domain/models/schedule_distribution_weights.dart';
import '../../../domain/models/schedule_forecast_demand.dart';
import '../../../domain/models/schedule_plan.dart';
import '../../../domain/models/target_cycle.dart';
import '../../../domain/models/target_cycle_source.dart';
import '../../../domain/models/weekly_plan_snapshot.dart';
import '../../../domain/models/service_period_definition.dart';
import '../../../domain/services/business_date_resolver.dart';
import '../../../domain/services/distribution_weight_builder.dart';
import '../../../domain/services/schedule_plan_resolver.dart';
import '../../../domain/services/target_cycle_active_target_profile_projector.dart';
import '../../../domain/services/utc_metadata_timestamp.dart';
import '../../../domain/services/weekly_plan_snapshot_bottom_up_reconciler.dart';
import '../../../domain/services/weekly_plan_snapshot_policy.dart';
import '../../../models/baseline_candidate_shift.dart';
import '../../../models/shift_record.dart';
import 'dao/target_cycle_dao.dart';

part 'sqlite_database_schema.dart';
part 'sqlite_database_seed.dart';
// Demo + mock-replay seed helpers, split out of sqlite_database_seed.dart by
// table family (code_hardening_plan 2026-05-21 §4.4 #3). All are `part of`
// this library, so private members + imports resolve library-wide unchanged.
part 'seed/seed_locked_targets.dart';
part 'seed/seed_open_shift_snapshots.dart';
part 'seed/seed_weekly_plan_snapshots.dart';
part 'seed/seed_reservation_book.dart';
part 'seed/seed_restaurant_and_timing.dart';
part 'seed/seed_target_profile_and_cycle.dart';
part 'seed/seed_additional_locations.dart';
part 'seed/seed_replay_entry.dart';
part 'seed/seed_scope_overrides.dart';
part 'seed/seed_four_period.dart';
part 'seed/seed_notifications.dart';
part 'seed/seed_operational_envelope.dart';
part 'sqlite_database_migrations.dart';

/// One location in the demo §2c org hierarchy.
///
/// The mobile app has no SQLite `org_units` table — hierarchy is a
/// Postgres-side production concept (`db/migrations/202604280002_*`).
/// The demo expresses multi-location scope purely via multiple
/// `restaurant_locations` rows (read back by
/// `RestaurantScopeNotifier` into one `BusinessScope` per row). The
/// org tree itself (corp → regions → district) lives in the
/// operator-web fixture `lib/operator_web/services/demo_team_fixtures
/// .dart`; the `region` / `district` labels here document the
/// alignment so the two consoles tell the same story. HP #2: these
/// are plain `restaurant_locations` rows — no `demo_*` table, no
/// `kDemoMode` reader branch.
class DemoLocation {
  const DemoLocation({
    required this.restaurantId,
    required this.displayName,
    required this.businessTimezone,
    required this.region,
    this.district,
  });

  final String restaurantId;
  final String displayName;
  final String businessTimezone;

  /// The §2c region this location rolls up to (`East`/`West`).
  final String region;

  /// The §2c district this location sits in, when any. Only North
  /// Loop sits under a district (`Metro District`); the other three
  /// roll straight up to their region.
  final String? district;
}

/// The demo restaurant scope defaults used across persistence.
class DemoScope {
  /// Downtown's id. Kept as `demo_restaurant_001` for backward
  /// compatibility with every existing test/`DemoScope` assertion.
  static const String restaurantId = 'demo_restaurant_001';

  /// Downtown's display name. Kept exactly `'Barrio Legado'` (not the
  /// §2c label `'Barrio Legado: Downtown'`) because
  /// `persistence_scope_alignment_test.dart` and
  /// `getOrCreateActiveRestaurant` assert this id resolves to this
  /// exact string. Authority order: this prompt's backward-compat
  /// constraint (#1) outranks the spec's proposed label (#2).
  static const String displayName = 'Barrio Legado';
  static const String businessTimezone = 'America/St_Johns';

  // ── §2c hierarchy location ids ────────────────────────────────────
  // Downtown == [restaurantId] (backward compat). The other three are
  // new restaurant_ids under the same demo operator/business.
  static const String downtownRestaurantId = restaurantId;
  static const String northLoopRestaurantId = 'demo_restaurant_north_loop';
  static const String riversideRestaurantId = 'demo_restaurant_riverside';
  static const String harbourRestaurantId = 'demo_restaurant_harbour';

  /// The full §2c demo location set. Seeded into `restaurant_locations`
  /// by `_seedDemoRestaurant`; surfaced by `RestaurantScopeNotifier`
  /// so the scope drawer becomes a real switcher. Downtown is first so
  /// it remains the row `getOrCreateActiveRestaurant` resolves by
  /// default and the row insertion-ordered queries return first.
  static const List<DemoLocation> locations = <DemoLocation>[
    DemoLocation(
      restaurantId: downtownRestaurantId,
      displayName: displayName,
      businessTimezone: businessTimezone,
      region: 'East Region',
    ),
    DemoLocation(
      restaurantId: northLoopRestaurantId,
      displayName: 'Barrio Legado: North Loop',
      businessTimezone: businessTimezone,
      region: 'East Region',
      district: 'Metro District',
    ),
    DemoLocation(
      restaurantId: riversideRestaurantId,
      displayName: 'Barrio Legado: Riverside',
      businessTimezone: businessTimezone,
      region: 'West Region',
    ),
    DemoLocation(
      restaurantId: harbourRestaurantId,
      displayName: 'Barrio Legado: Harbour',
      businessTimezone: businessTimezone,
      region: 'West Region',
    ),
  ];
}

class SqliteDatabase {
  SqliteDatabase._();
  static final SqliteDatabase instance = SqliteDatabase._();

  Database? _db;
  String? _overrideDbPath;

  /// Single-flight guard for [database].
  ///
  /// FU-coldboot-partial-seed: the demo flavor boots several subsystems
  /// (demo auth, restaurant scope, the Shift/Week dashboard notifiers)
  /// that each `await SqliteDatabase.instance.database` at roughly the
  /// same time. The previous `_db ??= await _initDb()` was not
  /// concurrency-safe: every first-caller that arrived before
  /// `_initDb()` resolved saw `_db == null` and kicked off its own
  /// `_initDb()`, opening the same fresh file more than once and racing
  /// the cold-boot seed (a second connection's writes/locks interleaving
  /// with the first connection's seed → a silently half-populated DB).
  /// One in-flight init Future is now shared by all concurrent
  /// first-callers so a clean cold boot opens + seeds exactly once.
  Future<Database>? _initInFlight;

  /// Current schema version.
  static const int schemaVersion = 40;

  Future<Database> get database {
    final existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    return _initInFlight ??= _runInitOnce();
  }

  Future<Database> _runInitOnce() async {
    try {
      final db = await _initDb();
      _db = db;
      return db;
    } finally {
      _initInFlight = null;
    }
  }

  Future<void> useDatabasePath(String path) async {
    await close();
    _overrideDbPath = path;
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _initInFlight = null;
    if (db != null) {
      await db.close();
    }
  }

  Future<Database> _initDb() async {
    String dbPath;
    final overrideDbPath = _overrideDbPath;
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    if (isDesktop) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    if (overrideDbPath != null) {
      dbPath = overrideDbPath;
    } else if (isDesktop) {
      dbPath = p.join(Directory.current.path, 'forge_flow_v2.db');
    } else {
      final dir = await sqflite_mobile.getDatabasesPath();
      dbPath = p.join(dir, 'forge_flow_v2.db');
    }

    await Directory(p.dirname(dbPath)).create(recursive: true);

    _needsColdBootSeed = false;
    final db = await openDatabase(
      dbPath,
      version: schemaVersion,
      onCreate: _createFreshSchema,
      onUpgrade: _onUpgrade,
    );

    // FU-coldboot-partial-seed: run the heavy demo seed POST-open, NOT
    // inside `onCreate`. sqflite executes `onCreate` inside an implicit
    // exclusive transaction; the demo seed invokes DAOs
    // (`TargetCycleDao.upsertCycle`, `WeeklyPlanSnapshotDao`,
    // `OpenShiftSnapshotDao`, `ReservationBookSnapshotDao`, …) that each
    // open their own `Database.transaction()`. A `Database.transaction()`
    // opened while a transaction is already in force on the same
    // connection does not compose on Android native sqflite the way it
    // does on `sqflite_common_ffi`: the inner transactions commit/roll
    // back independently of the outer `onCreate` transaction, so when any
    // later seed step failed the parent-table writes made directly on the
    // `onCreate` handle were rolled back while the independently-committed
    // nested-DAO writes and the final in-memory envelope step survived —
    // a silently half-seeded DB with orphaned child rows and no crash.
    // The reseed/advance path (`reseedMockReplayForBusinessDate`) has
    // always run the SAME seeders with the DB already open (no implicit
    // `onCreate` transaction), so every DAO transaction is a real,
    // atomic, top-level transaction — which is why advance/reset worked
    // on the device while a clean cold boot did not. Seeding post-open
    // unifies cold boot with that proven path. HP #2: writer-side only —
    // same tables, no `demo_*` table, no `kDemoMode` reader branch.
    if (_needsColdBootSeed) {
      _needsColdBootSeed = false;
      await _seedColdBootDemo(db);
    }
    return db;
  }

  // ── Schema creation ─────────────────────────────────────────────────────

  /// Cold-boot demo anchor date (`yyyy-MM-dd`, UTC).
  ///
  /// The Shift dashboard evaluates "current-week open/projected state"
  /// against the real wall clock — `shift_dashboard_notifier.dart:82,126`
  /// use `DateTime.now().toUtc()`. The cold-boot demo seed must pin the
  /// seeded "current week" to *today* on the same UTC basis, otherwise
  /// the seeded current week (week of the fixed
  /// `MockIntegrationReplaySeed.defaultBusinessDate` = 2026-03-27) never
  /// contains "now" and a clean cold boot silently degrades to
  /// "HISTORICAL ONLY".
  ///
  /// HP #2: this is a writer-side anchor only — no reader branches on
  /// `kDemoMode` and no `demo_*` table; readers consume the same tables
  /// either way. `defaultBusinessDate` stays the documented default for
  /// unit tests and `MockIntegrationReplaySeed.output`; only this runtime
  /// cold-boot DB seed is today-anchored.
  ///
  /// [debugColdBootTodayOverride] is a test-only seam so a cold-boot
  /// seed can be exercised against a known "today" deterministically; it
  /// is `null` in production and the real UTC clock is used.
  @visibleForTesting
  static String? debugColdBootTodayOverride;

  /// Test-only seam pinning the restaurant-local **now** (date AND
  /// time-of-day) used ONLY to select which service period is "open" at
  /// seed time (QA fix — Change A). Full local ISO-8601, e.g.
  /// `'2026-05-16T09:25:00'`. `null` in production/demo, where the real
  /// restaurant-local clock is used so a true Saturday 09:25 shows no
  /// open Dinner.
  ///
  /// Precedence for the open-period selection's time-of-day:
  ///   1. [debugColdBootNowOverride] → its time-of-day (date+time pin);
  ///   2. else [debugColdBootTodayOverride] (legacy date-only) → a
  ///      deterministic canonical `19:45` (Dinner in progress) so
  ///      pre-existing date-only tests stay green AND deterministic
  ///      (Dinner applies every weekday);
  ///   3. else → real `DateTime.now()` (production/demo device — the
  ///      actual fix).
  /// In ALL cases the seeded business **date** is unchanged (the W8
  /// today-anchor / reseed `isoDate` still wins); only the time-of-day
  /// used to pick the open period is sourced here.
  @visibleForTesting
  static String? debugColdBootNowOverride;

  static String _coldBootAnchorIsoDate() {
    final nowOverride = debugColdBootNowOverride;
    if (nowOverride != null) {
      // Keep the cold-boot business date consistent with the injected
      // now (business-date-aware, demo 04:00 start).
      return BusinessDateResolver.resolve(
        localTimestamp: DateTime.parse(nowOverride),
        businessDayStartLocalTime: _kDemoBusinessDayStartLocalTime,
      );
    }
    final override = debugColdBootTodayOverride;
    if (override != null) return override;
    final now = DateTime.now().toUtc();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// The clock-derived [OpenPeriodResolution] for a seed pass anchored
  /// to [isoBusinessDate]. The selection's DATE is always
  /// [isoBusinessDate] (W8 / reseed anchor preserved — Time Guardrails);
  /// only the TIME-OF-DAY is sourced here.
  ///
  /// [coldBoot] distinguishes the two seed paths when NO clock anchor is
  /// injected:
  ///  * cold boot (`true`) — a genuine fresh-launch demo seed. With no
  ///    override this uses the REAL restaurant-local clock, so a true
  ///    Saturday 09:25 (before Lunch) yields `openDaypart == null` (no
  ///    open shift) instead of the old hardcoded Dinner. This is the
  ///    actual QA fix for the device-reproduced defect.
  ///  * reseed/advance (`false`) — an explicit demo operator action
  ///    ("advance demo date" / "data reset"). With no override this
  ///    falls back to the deterministic legacy resolution (Dinner open,
  ///    Lunch closed) so the demo affordance is stable and the large
  ///    body of `reseedDemo()`-based tests stays deterministic without
  ///    every one having to pin the clock.
  /// In BOTH paths an injected [debugColdBootNowOverride] (date+time) or
  /// [debugColdBootTodayOverride] (legacy date-only → canonical 19:45,
  /// Dinner) wins, so tests can pin BOTH date and time-of-day.
  static OpenPeriodResolution _openPeriodResolutionForSeed(
    String isoBusinessDate, {
    required bool coldBoot,
  }) {
    final p = isoBusinessDate.split('-');
    final y = int.parse(p[0]);
    final mo = int.parse(p[1]);
    final d = int.parse(p[2]);

    // Fix B (operator decision 2026-05-16): the demo Shift home must
    // NEVER be blank for a connected location. `seedTimeOpenPeriodResolution`
    // returns the honest clock-derived period when one is genuinely live,
    // else the most-relevant period for the business day presented as the
    // open shift (deterministic — derived from the period window, no
    // `DateTime.now()` in any seeded value).
    final nowOverride = debugColdBootNowOverride;
    if (nowOverride != null) {
      final dt = DateTime.parse(nowOverride);
      return seedTimeOpenPeriodResolution(
        localNow: DateTime(y, mo, d, dt.hour, dt.minute, dt.second),
      );
    }
    if (debugColdBootTodayOverride != null) {
      // Deterministic legacy-compat: 19:45 → Dinner in progress (Dinner
      // applies every weekday) so pre-existing date-only override tests
      // stay green and deterministic regardless of the real wall clock.
      return seedTimeOpenPeriodResolution(localNow: DateTime(y, mo, d, 19, 45));
    }
    if (coldBoot) {
      // Production / demo device fresh launch — the real clock decides
      // which period is live; when none is, Fix B selects the
      // most-relevant period so the Shift home is never blank.
      final now = DateTime.now();
      return seedTimeOpenPeriodResolution(
        localNow: DateTime(y, mo, d, now.hour, now.minute, now.second),
      );
    }
    // Reseed/advance with no anchor → deterministic legacy resolution
    // (Dinner open, Lunch closed) — `generateForDate`'s back-compat
    // default. Keeps the demo affordance + bare-`reseedDemo()` tests
    // stable; explicit clock tests still pin the override above.
    return MockIntegrationReplaySeed.legacyDefaultResolution;
  }

  /// True between a fresh-DB schema create and its post-open demo seed.
  /// Set by [_createFreshSchema] (run inside sqflite's implicit
  /// `onCreate` transaction) and consumed by [_initDb] AFTER
  /// `openDatabase` returns, so [_seedColdBootDemo] never runs inside the
  /// `onCreate` transaction. See [_initDb] for the full rationale.
  bool _needsColdBootSeed = false;

  /// Test seam: counts how many times the post-open cold-boot seed body
  /// has run for the lifetime of the process. The regression suite uses
  /// it to prove (a) a clean cold boot seeds exactly once even under
  /// concurrent first-callers (single-flight) and (b) the seed runs
  /// post-open, never from `onCreate`.
  @visibleForTesting
  static int debugColdBootSeedRunCount = 0;

  /// `onCreate` for a fresh DB: schema ONLY — it MUST NOT seed.
  ///
  /// sqflite runs `onCreate` inside an implicit exclusive transaction.
  /// The demo seed invokes DAOs that open their own
  /// `Database.transaction()`; nesting a transaction inside the
  /// `onCreate` transaction does not compose on Android native sqflite
  /// (it did silently half-seed the demo DB — parent tables rolled back,
  /// orphaned child rows surviving, no crash). Keeping `onCreate`
  /// schema-only and deferring the seed to [_initDb]'s post-open step is
  /// the fix. The empty-after-create invariant is locked by the
  /// regression suite.
  Future<void> _createFreshSchema(Database db, int version) async {
    await _createAllTables(db);
    _needsColdBootSeed = true;
  }

  /// Post-open cold-boot demo seed. Invoked by [_initDb] AFTER
  /// `openDatabase` has returned, so [db] is fully open and NOT inside a
  /// transaction — every seed-DAO `Database.transaction()` is therefore a
  /// real, atomic, top-level transaction, exactly as on the
  /// device-proven `reseedMockReplayForBusinessDate` path.
  ///
  /// Fail-fast: nothing here catches. Any fatal seed error propagates out
  /// of [_initDb] and the `database` getter (visible E/flutter; catchable
  /// in tests) instead of leaving a half-populated demo DB masquerading
  /// as a successful cold boot.
  Future<void> _seedColdBootDemo(Database db) async {
    debugColdBootSeedRunCount++;
    await _seedDemoRestaurant(db);
    // Demo-data — cold-boot wage authority. The reseed/advance path
    // seeds `wage_role_rows` (+ the Riverside location override) BEFORE
    // the cycle build so the blended-wage waterfall resolves through
    // real role rows; cold-boot must mirror that so Settings ▸ Wage
    // Authority is populated on the very first launch (per location:
    // Downtown business default, Riverside override, North Loop +
    // Harbour inherit). Idempotent (skip-if-present) — the seeded
    // cohorts blend to exactly MeridianConfig, so the Downtown cycle is
    // byte-identical whether the rows exist or not.
    await _seedDemoWageRoleRows(db);
    await _seedDemoScopeOverrideWageRows(db);

    // R6 — Choose Star Shifts: the dedicated 4-period demo proof
    // location. Additive, self-contained, `restaurant_id`-scoped (HP
    // #4), idempotent + deterministic. Seeded here alongside the other
    // demo scope rows so the 4-period `restaurant_timing_configs` + its
    // 60-day closed cohort are present on the very first cold boot
    // (the daypart de-hardcode can be proven against an N≠3 dataset).
    // Closed cohort is anchored to the same cold-boot business date as
    // the rest of the demo data so its 60-day window aligns with the
    // baseline-candidate read window.
    await _seedDemoFourPeriodTimingConfig(db);

    // Anchor the cold-boot demo seed to *today* (UTC ISO) instead of the
    // fixed `MockIntegrationReplaySeed.defaultBusinessDate`. See
    // [_coldBootAnchorIsoDate]. `generateForDate(today)` builds a
    // coherent current week + 12 historical weeks ending at that week,
    // so "now" always falls inside the seeded current week and Shift
    // finds a current-week open shift on a clean cold boot. This mirrors
    // the date threading already proven in
    // `reseedMockReplayForBusinessDate` — same generator, same
    // `businessDate:`-keyed seeders, just sourced from today.
    final coldBootBusinessDate = _coldBootAnchorIsoDate();
    // QA fix (Change A): the open service period is derived from the
    // restaurant-local clock at seed time, NOT hardcoded to Dinner. A
    // true Saturday 09:25 (before Lunch opens) yields no open shift.
    final replay = MockIntegrationReplaySeed.generateForDate(
      coldBootBusinessDate,
      open: _openPeriodResolutionForSeed(coldBootBusinessDate, coldBoot: true),
    );
    await _seedDemoActiveTargetProfile(
      db,
      businessDate: coldBootBusinessDate,
      replay: replay,
    );

    // Persist the cold-boot mock replay business date. Direct insert:
    // `setMockReplayBusinessDate` awaits `database`, which is still
    // re-entrant during this post-open seed (it runs inside `_initDb`,
    // before `_db`/`_initInFlight` resolve, so awaiting the getter here
    // would await the in-flight init that is running this very seed).
    await db.insert('mock_replay_state', {
      'restaurant_id': DemoScope.restaurantId,
      'current_business_date': coldBootBusinessDate,
    });

    await _seedDemoDataFromReplay(db, replay);
    // R6 — 4-period proof location's 60-day closed cohort, anchored to
    // the SAME cold-boot business date as the replay cohort so its
    // window aligns with the baseline-candidate read window. Runs after
    // `_seedDemoDataFromReplay` (which only wipes/seeds the
    // `DemoScope.restaurantId` scope) so the two cohorts never collide.
    await _seedDemoFourPeriodClosedShifts(
      db,
      anchorBusinessDate: coldBootBusinessDate,
    );
    // Demo-data — cold-boot variance-breach alert. Mirrors the
    // reseed/advance path: emits ONE honest over-plan alert from the
    // freshly seeded `week_records` (no breach → no row). Cold-boot
    // previously had zero notifications; this + the sample inbox below
    // give a populated bell on first launch.
    await _seedDemoVarianceBreachNotification(db);
    await _backfillLockedTargets(db, businessDate: coldBootBusinessDate);
    await _seedOpenShiftSnapshotsFromReplay(db, replay);
    await _seedReservationBookSnapshotsFromReplay(db, replay);
    // FU-mobile-cold-boot-shift-stale-state: seed the locked weekly plan
    // snapshot synchronously during cold-boot so the Shift dashboard's
    // first read finds it. Without this row, the runtime auto-generator
    // is invoked indirectly via WeekDataNotifier on first use — that
    // race meant the ShiftDashboardNotifier's first _load() ran ahead of
    // the snapshot write and cached `lockedPlanUnavailable = true`. HP #2
    // compliance: this is a writer-side bootstrap seed; reader paths
    // remain unchanged and never branch on kDemoMode.
    await _seedWeeklyPlanSnapshotFromReplay(
      db,
      businessDate: coldBootBusinessDate,
    );
    // Demo-data — per-location operational envelope (historical
    // open_shift_snapshots, forward reservation book, historical locked
    // weekly plans + per-daypart child rows, sample notifications).
    // Runs LAST so it reads the fully-seeded cycles + shift set + the
    // existing Downtown in-force snapshot.
    await _seedOperationalEnvelopeFromReplay(db, replay);
  }

  /// Test seam: runs `onCreate`'s schema-only step against [db] so the
  /// regression suite can prove a freshly-created DB is EMPTY of demo
  /// rows (the seed must not run inside `onCreate`).
  @visibleForTesting
  Future<void> debugCreateFreshSchemaOnly(Database db) =>
      _createFreshSchema(db, schemaVersion);

  // ── Seed helpers ────────────────────────────────────────────────────────

  /// Compatibility helper: builds an ActiveTargetProfile from current
  /// BaselineData.
  ///
  /// When [fohWageOverride] or [bohWageOverride] are provided, they replace
  /// the MeridianConfig defaults and theoretical labor % is recomputed from
  /// the resolved wages.
  /// Phase 7.55p.5g — builds an [ActiveTargetProfile] from the current
  /// baseline state with optional wage and target overrides.
  ///
  /// When `targetCPLHOverride` / `targetSPLHOverride` / `targetPPAOverride`
  /// / `opzFloorOverride` / `opzCeilingOverride` are provided, they
  /// replace the `BaselineData`-derived values. This is the integration
  /// point for the recommended-benchmark selection service so the
  /// default recommended/system cycle can carry app-owned recommendation
  /// truth without writing fake manager-override selections to the
  /// baseline-selection table.
  ///
  /// Wage overrides already existed (7.55i.3) — their behavior is
  /// unchanged.
  ///
  /// The override seam is additive. Live bootstrap/backfill now route through
  /// the seeded TargetCycle projection instead; this helper remains for
  /// compatibility/pure-test coverage.
  static ActiveTargetProfile buildActiveTargetProfileFromBaseline(
    String restaurantId, {
    double? fohWageOverride,
    double? bohWageOverride,
    double? targetCPLHOverride,
    double? targetSPLHOverride,
    double? targetPPAOverride,
    double? opzFloorOverride,
    double? opzCeilingOverride,
    String? sourceTypeOverride,
  }) {
    final sourceType =
        sourceTypeOverride ??
        (BaselineData.hasManagerOverride
            ? 'manager_override'
            : 'system_baseline');

    final fohWage = fohWageOverride ?? MeridianConfig.fohWage;
    final bohWage = bohWageOverride ?? MeridianConfig.bohWage;

    final targetCPLH = targetCPLHOverride ?? BaselineData.derivedTargetCPLH;
    final targetSPLH = targetSPLHOverride ?? BaselineData.derivedTargetSPLH;
    final targetPPA = targetPPAOverride ?? BaselineData.derivedTargetPPA;
    final opzFloor = opzFloorOverride ?? BaselineData.opzFloorCPLH;
    final opzCeiling = opzCeilingOverride ?? BaselineData.opzCeilingCPLH;

    return ActiveTargetProfile.build(
      restaurantId: restaurantId,
      sourceType: sourceType,
      targetCPLH: targetCPLH,
      targetSPLH: targetSPLH,
      targetPPA: targetPPA,
      fohWage: fohWage,
      bohWage: bohWage,
      opzFloorCPLH: opzFloor,
      opzCeilingCPLH: opzCeiling,
    );
  }

  // ── Migration ───────────────────────────────────────────────────────────

  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 7) {
      await _migrateToV7(db);
    }
    if (oldV < 8) {
      await _migrateToV8(db);
    }
    if (oldV < 9) {
      await _migrateToV9(db);
    }
    if (oldV < 10) {
      await _migrateToV10(db);
    }
    if (oldV < 11) {
      await _migrateToV11(db);
    }
    if (oldV < 12) {
      await _migrateToV12(db);
    }
    if (oldV < 13) {
      await _migrateToV13(db);
    }
    if (oldV < 14) {
      await _migrateToV14(db);
    }
    if (oldV < 15) {
      await _migrateToV15(db);
    }
    if (oldV < 16) {
      await _migrateToV16(db);
    }
    if (oldV < 17) {
      await _migrateToV17(db);
    }
    if (oldV < 18) {
      await _migrateToV18(db);
    }
    if (oldV < 19) {
      await _migrateToV19(db);
    }
    if (oldV < 20) {
      await _migrateToV20(db);
    }
    if (oldV < 21) {
      await _migrateToV21(db);
    }
    if (oldV < 22) {
      await _migrateToV22(db);
    }
    if (oldV < 23) {
      await _migrateToV23(db);
    }
    if (oldV < 24) {
      await _migrateToV24(db);
    }
    if (oldV < 25) {
      await _migrateToV25(db);
    }
    if (oldV < 26) {
      await _migrateToV26(db);
    }
    if (oldV < 27) {
      await _migrateToV27(db);
    }
    if (oldV < 28) {
      await _migrateToV28(db);
    }
    if (oldV < 29) {
      await _migrateToV29(db);
    }
    if (oldV < 30) {
      await _migrateToV30(db);
    }
    if (oldV < 31) {
      await _migrateToV31(db);
    }
    if (oldV < 32) {
      await _migrateToV32(db);
    }
    if (oldV < 33) {
      await _migrateToV33(db);
    }
    if (oldV < 34) {
      await _migrateToV34(db);
    }
    if (oldV < 35) {
      await _migrateToV35(db);
    }
    if (oldV < 36) {
      await _migrateToV36(db);
    }
    if (oldV < 37) {
      await _migrateToV37(db);
    }
    if (oldV < 38) {
      await _migrateToV38(db);
    }
    if (oldV < 39) {
      await _migrateToV39(db);
    }
    if (oldV < 40) {
      await _migrateToV40(db);
    }
  }

  // Phase 7.55q.5: add preserved locked plan hour columns to week_records.
  // Captured at week close from the WeeklyPlanSnapshot in force for the
  // week's business-date span. Additive + nullable — legacy rows stay
  // null and the Week Detail UI renders "—" honestly for them (no
  // silent re-modeling from actuals).
  // Phase 7.55q.10: add frozen dollar-impact-window columns to week_records.
  // Captured at week close from the closed-truth date-range queries the
  // current-week Variance card was reading. Locks the four-row impact view
  // (Week / Month / 60-day / Annualized) at the close moment so Week Detail
  // mirrors what was on screen the instant the 14th shift closed.
  // Additive + nullable — legacy rows stay null and Week Detail falls back
  // to the existing 2-row + boilerplate-footer view honestly.
  // Phase 7.55q.11: add frozen target calibration-window columns to
  // week_records. Captured at week close from the TargetCycle linked by the
  // locked WeeklyPlanSnapshot so History can show which 60-day window the
  // week's targets were actually built from. Additive + nullable — legacy
  // rows stay null and Week Detail omits the range honestly.
  // Phase 7.55q.11a: repair already-upgraded demo DBs whose V23 schema landed
  // before the historical-week calibration-window backfill logic existed.
  // No schema change here — this is a data repair migration so existing local
  // app DBs pick up the "Built from ..." History subtitle on restart.
  // Phase 7.55n.13: add snapshot_blended_wage column to shift_records.
  // Fixes the pre-existing schema gap where ShiftRecord.toMap() writes
  // snapshot_blended_wage but the table schema did not include it.
  /// Exposed for testing.
  Future<void> migrateToV7ForTest(Database db) => _migrateToV7(db);
  Future<void> migrateToV8ForTest(Database db) => _migrateToV8(db);
  Future<void> migrateToV12ForTest(Database db) => _migrateToV12(db);

  // ── Mock replay state ────────────────────────────────────────────────────

  /// Returns the persisted mock replay business date for [restaurantId],
  /// or null if none is set.
  Future<String?> getMockReplayBusinessDate(String restaurantId) async {
    final db = await database;
    final rows = await db.query(
      'mock_replay_state',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
    if (rows.isEmpty) return null;
    return rows.first['current_business_date'] as String?;
  }

  /// Persists the mock replay business date for [restaurantId].
  Future<void> setMockReplayBusinessDate(
    String restaurantId,
    String isoDate,
  ) async {
    final db = await database;
    await db.insert('mock_replay_state', {
      'restaurant_id': restaurantId,
      'current_business_date': isoDate,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── Reseed ──────────────────────────────────────────────────────────────

  /// Resets to the default mock replay scenario (2026-03-27 Friday dinner).
  ///
  /// Unlike [reseedMockReplayForBusinessDate], this is a full demo reset
  /// and clears weekly_plan_snapshots and target_cycles too. The
  /// replay-advance path preserves the locked snapshot, its referenced
  /// target cycle, and the cycle-projected active profile for the week
  /// already in force.
  Future<void> reseedDemo() async {
    final db = await database;
    await db.delete('weekly_plan_snapshots');
    await db.delete('benchmark_selection_summaries');
    await db.delete('target_cycles');
    await db.delete('app_notifications');
    await reseedMockReplayForBusinessDate(
      MockIntegrationReplaySeed.defaultBusinessDate,
    );
  }

  /// Reseeds all operational tables for an arbitrary mock replay business date.
  ///
  /// This is the scenario-level reset/advance path: shift_records,
  /// week_records, open_shift_snapshots, and reservation_book_snapshots
  /// all move together coherently.
  Future<void> reseedMockReplayForBusinessDate(String isoDate) async {
    final db = await database;

    // ── Replay-regenerated scenario data (cleared and rebuilt) ────────
    // These tables are re-simulated from MockIntegrationReplaySeed for
    // the new date. They are scenario data, not locked truth.
    await db.delete('shift_records');
    await db.delete('week_records');
    await db.delete('baseline_selected_records');
    await db.delete('import_runs');
    await db.delete('raw_import_records');
    await db.delete('sync_watermarks');
    await db.delete('target_profile_versions');
    await db.delete('open_shift_snapshots');
    await db.delete('reservation_book_snapshots');
    // ── Replay-stable locked artifacts (NOT cleared) ─────────────────
    // target_cycles: the locked weekly snapshot references its generating
    // cycle, and that linkage must survive replay advance. (7.55l.6b2)
    // weekly_plan_snapshots: the locked snapshot for the week in force
    // must survive same-week replay advance. (7.55l.6b1)
    // active_target_profiles: conditionally preserved below — when a
    // preserved active cycle exists, its projected profile must not be
    // overwritten with baseline-seeded truth. (7.55l.6b3)
    // benchmark_selection_summaries: tied to the active cycle.
    // See docs/phase_7_55m_2_mock_replay_drift_contract.md for the
    // full two-category classification.

    // Ensure all demo locations exist. Called unconditionally: on an
    // existing demo DB upgraded to the multi-location build, Downtown
    // (`DemoScope.restaurantId`) is already present but North Loop /
    // Riverside / Harbour are not. `_seedDemoRestaurant` is idempotent
    // (ConflictAlgorithm.ignore), so a Downtown-only guard would
    // permanently strand the 3 new locations for existing users.
    await _seedDemoRestaurant(db);

    // Demo-data Slice B (§2g / G7): seed `wage_role_rows` BEFORE any
    // cycle build so `_ensureDemoSeedCycle` resolves the blended FOH/BOH
    // wage through the production `_weightedAvgFromRows` waterfall over
    // real role rows instead of the `MeridianConfig` empty-rows
    // fallback. Idempotent — safe on reseed/advance.
    await _seedDemoWageRoleRows(db);

    // Demo-data Slice F (§2c / Gap G10): one HP #11 override per scope
    // level into the existing production tables — Region (East Region
    // timing override on North Loop), Location (Riverside wage override;
    // Harbour inherits), District (Metro District data-accuracy
    // covers-source override + the business-default baseline). Each is
    // additive, restaurant_id-scoped (HP #4), idempotent + deterministic
    // (skip-if-present + ConflictAlgorithm.ignore + fixed literals).
    // Placed here — alongside `_seedDemoWageRoleRows`, the canonical
    // populated demo path — so the override DATA is present wherever the
    // HP #11 resolver renders. Order is independent of the cycle build
    // (different restaurant_ids / tables).
    await _seedDemoScopeOverrideTimingConfig(db);
    await _seedDemoScopeOverrideWageRows(db);
    await _seedDemoScopeOverrideDataAccuracy(db);

    // R6 — Choose Star Shifts: the 4-period demo proof location's
    // location + timing-config rows (the 60-day closed cohort is
    // seeded below, anchored to `isoDate`). Idempotent
    // (skip-if-present) so the reseed/advance path preserves any
    // operator-entered row and is byte-identical across reseeds.
    await _seedDemoFourPeriodTimingConfig(db);

    // Persist mock replay date
    await setMockReplayBusinessDate(DemoScope.restaurantId, isoDate);

    // Generate scenario-specific replay output. QA fix (Change A): the
    // open service period is clock-derived for `isoDate` (the reseed
    // business date is unchanged — only which period is "open" follows
    // the restaurant-local clock; demo/device use the real clock).
    final replay = MockIntegrationReplaySeed.generateForDate(
      isoDate,
      open: _openPeriodResolutionForSeed(isoDate, coldBoot: false),
    );

    // When a preserved active cycle exists, its projected
    // ActiveTargetProfile is already correct and must not be overwritten
    // with a fresh demo-cycle projection. Only seed a new demo cycle/profile
    // when no cycle is preserved (e.g., after reseedDemo clears target_cycles).
    // (7.55l.6b3)
    final preservedCycles = await db.query(
      'target_cycles',
      where: 'restaurant_id = ? AND deactivated_at IS NULL',
      whereArgs: [DemoScope.restaurantId],
    );
    if (preservedCycles.isEmpty) {
      await _seedDemoActiveTargetProfile(
        db,
        businessDate: isoDate,
        replay: replay,
      );
    }
    await _seedDemoDataFromReplay(db, replay);
    // R6 — 4-period proof location's 60-day closed cohort, anchored to
    // the reseed business date so its window stays aligned with the
    // baseline-candidate read window. Runs after
    // `_seedDemoDataFromReplay` (which only touches the
    // `DemoScope.restaurantId` scope), so the two cohorts never
    // collide and the dataset is byte-identical across reseeds.
    await _seedDemoFourPeriodClosedShifts(db, anchorBusinessDate: isoDate);
    // Demo-data Slice F (§1.6 / Gap G9): emit ONE variance-breach
    // notification from the worst real over-plan week in the freshly
    // seeded `week_records` (Metric Honesty — no fabricated alert; no
    // breach → no row). Must run AFTER `_seedDemoDataFromReplay` so
    // `week_records` exist. `reseedDemo` clears `app_notifications`
    // first, so this re-emits the identical deterministic row → two
    // reseeds byte-identical.
    await _seedDemoVarianceBreachNotification(db);
    await _backfillLockedTargets(db, businessDate: isoDate);
    await _seedOpenShiftSnapshotsFromReplay(db, replay);
    await _seedReservationBookSnapshotsFromReplay(db, replay);
    // FU-mobile-cold-boot-shift-stale-state: ensure a locked weekly plan
    // snapshot exists for the current week after replay advance/reset.
    // Same-week snapshots are preserved (see 7.55l.6b1 comment above);
    // this seeder is a no-op when one already exists for the week-in-force,
    // so cross-week advances and post-reseedDemo bootstraps both produce
    // a snapshot without rewriting same-week locked truth.
    await _seedWeeklyPlanSnapshotFromReplay(db, businessDate: isoDate);
    // Demo-data — per-location operational envelope. Same single seam
    // the cold-boot path uses; runs LAST so it reads the fully-seeded
    // cycles + shift set + the existing Downtown in-force snapshot.
    // Idempotent across reseed/advance: open/reservation snapshots are
    // cleared above and rebuilt; weekly-plan snapshots use a
    // (restaurant_id, week_key) existence guard so locked truth is never
    // rewritten; notifications dedupe on UNIQUE(restaurant_id,
    // event_key).
    await _seedOperationalEnvelopeFromReplay(db, replay);
  }

  /// Clears all operational data while preserving restaurant scope and
  /// connector configs.
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('shift_records');
    await db.delete('week_records');
    await db.delete('baseline_selected_records');
    await db.delete('import_runs');
    await db.delete('raw_import_records');
    await db.delete('sync_watermarks');
    await db.delete('target_profile_versions');
    await db.delete('open_shift_snapshots');
    await db.delete('reservation_book_snapshots');
    await db.delete('active_target_profiles');
    await db.delete('target_cycles');
    await db.delete('weekly_plan_snapshots');
    await db.delete('app_notifications');

    // Reset in-memory compatibility bridge
    BaselineData.clearHistoricalContext();
    BaselineData.clearManagerOverride();
  }
}
