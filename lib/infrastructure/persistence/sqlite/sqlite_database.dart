// SQLite bootstrap layer — owns database lifecycle, schema, and migrations.
//
// DatabaseHelper delegates to this for open/init. DAOs and repositories
// operate on the Database instance this class provides.

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../data/app_defaults.dart';
import '../../../dev/demo_fixture_data.dart';
import '../../../data/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/domain/services/recommended_benchmark_selection_service.dart';
import '../../../domain/models/active_target_profile.dart';
import '../../../domain/models/import_run.dart';
import '../../../domain/models/open_shift_snapshot.dart';
import '../../../domain/models/raw_import_record.dart';
import '../../../domain/models/reservation_book_snapshot.dart';
import '../../../domain/models/target_cycle.dart';
import '../../../domain/models/target_cycle_source.dart';
import '../../../domain/services/target_cycle_active_target_profile_projector.dart';
import '../../../domain/services/utc_metadata_timestamp.dart';
import '../../../models/baseline_candidate_shift.dart';
import '../../../models/shift_record.dart';

part 'sqlite_database_schema.dart';
part 'sqlite_database_seed.dart';
part 'sqlite_database_migrations.dart';

/// The demo restaurant scope defaults used across persistence.
class DemoScope {
  static const String restaurantId = 'demo_restaurant_001';
  static const String displayName = 'Barrio Legado';
  static const String businessTimezone = 'America/St_Johns';
}

class SqliteDatabase {
  SqliteDatabase._();
  static final SqliteDatabase instance = SqliteDatabase._();

  Database? _db;
  String? _overrideDbPath;

  /// Current schema version.
  static const int schemaVersion = 24;

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<void> useDatabasePath(String path) async {
    await close();
    _overrideDbPath = path;
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
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

    return openDatabase(
      dbPath,
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // ── Schema creation ─────────────────────────────────────────────────────

  Future<void> _onCreate(Database db, int version) async {
    await _createAllTables(db);
    await _seedDemoRestaurant(db);
    await _seedDemoActiveTargetProfile(
      db,
      businessDate: MockIntegrationReplaySeed.defaultBusinessDate,
      replay: MockIntegrationReplaySeed.output,
    );

    // Persist default mock replay business date
    await db.insert('mock_replay_state', {
      'restaurant_id': DemoScope.restaurantId,
      'current_business_date': MockIntegrationReplaySeed.defaultBusinessDate,
    });

    final replay = MockIntegrationReplaySeed.output;
    await _seedDemoDataFromReplay(db, replay);
    await _backfillLockedTargets(
      db,
      businessDate: MockIntegrationReplaySeed.defaultBusinessDate,
    );
    await _seedOpenShiftSnapshotsFromReplay(db, replay);
    await _seedReservationBookSnapshotsFromReplay(db, replay);
  }

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
    final sourceType = sourceTypeOverride ??
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
    final rows = await db.query('mock_replay_state',
        where: 'restaurant_id = ?', whereArgs: [restaurantId]);
    if (rows.isEmpty) return null;
    return rows.first['current_business_date'] as String?;
  }

  /// Persists the mock replay business date for [restaurantId].
  Future<void> setMockReplayBusinessDate(
      String restaurantId, String isoDate) async {
    final db = await database;
    await db.insert(
      'mock_replay_state',
      {
        'restaurant_id': restaurantId,
        'current_business_date': isoDate,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
        MockIntegrationReplaySeed.defaultBusinessDate);
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

    // Ensure restaurant exists
    final existing = await db.query('restaurant_locations',
        where: 'restaurant_id = ?', whereArgs: [DemoScope.restaurantId]);
    if (existing.isEmpty) {
      await _seedDemoRestaurant(db);
    }

    // Persist mock replay date
    await setMockReplayBusinessDate(DemoScope.restaurantId, isoDate);

    // Generate scenario-specific replay output
    final replay = MockIntegrationReplaySeed.generateForDate(isoDate);

    // When a preserved active cycle exists, its projected
    // ActiveTargetProfile is already correct and must not be overwritten
    // with a fresh demo-cycle projection. Only seed a new demo cycle/profile
    // when no cycle is preserved (e.g., after reseedDemo clears target_cycles).
    // (7.55l.6b3)
    final preservedCycles = await db.query('target_cycles',
        where: 'restaurant_id = ? AND deactivated_at IS NULL',
        whereArgs: [DemoScope.restaurantId]);
    if (preservedCycles.isEmpty) {
      await _seedDemoActiveTargetProfile(
        db,
        businessDate: isoDate,
        replay: replay,
      );
    }
    await _seedDemoDataFromReplay(db, replay);
    await _backfillLockedTargets(db, businessDate: isoDate);
    await _seedOpenShiftSnapshotsFromReplay(db, replay);
    await _seedReservationBookSnapshotsFromReplay(db, replay);
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

