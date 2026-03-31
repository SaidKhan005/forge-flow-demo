// SQLite bootstrap layer — owns database lifecycle, schema, and migrations.
//
// DatabaseHelper delegates to this for open/init. DAOs and repositories
// operate on the Database instance this class provides.

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../data/fixture_seed_data.dart';
import '../../../data/legacy_fixture_data.dart';
import '../../../domain/models/active_target_profile.dart';
import '../../../domain/models/import_run.dart';
import '../../../domain/models/open_shift_snapshot.dart';
import '../../../domain/models/raw_import_record.dart';

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
  static const int schemaVersion = 10;

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
    await _seedDemoActiveTargetProfile(db);
    await _seedDemoData(db);
    await _backfillLockedTargets(db);
    await _seedOpenShiftSnapshots(db);
  }

  Future<void> _createAllTables(Database db) async {
    // ── Restaurant / connector scope ──────────────────────────────────────
    await db.execute('''
      CREATE TABLE restaurant_locations (
        restaurant_id      TEXT PRIMARY KEY NOT NULL,
        display_name       TEXT NOT NULL,
        business_timezone  TEXT NOT NULL,
        created_at         TEXT NOT NULL,
        updated_at         TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE connector_configs (
        connector_id         TEXT PRIMARY KEY NOT NULL,
        restaurant_id        TEXT NOT NULL,
        source_type          TEXT NOT NULL,
        external_location_id TEXT NOT NULL,
        status               TEXT NOT NULL,
        created_at           TEXT NOT NULL,
        updated_at           TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX ux_connector_configs_restaurant_source
      ON connector_configs(restaurant_id, source_type)
    ''');

    // ── Raw import layer ──────────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE import_runs (
        import_run_id  TEXT PRIMARY KEY NOT NULL,
        restaurant_id  TEXT NOT NULL,
        mode           TEXT NOT NULL,
        started_at     TEXT NOT NULL,
        completed_at   TEXT,
        status         TEXT NOT NULL,
        cursor_json    TEXT,
        error_summary  TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE raw_import_records (
        raw_import_id      TEXT PRIMARY KEY NOT NULL,
        import_run_id      TEXT NOT NULL,
        restaurant_id      TEXT NOT NULL,
        source_type        TEXT NOT NULL,
        source_entity_type TEXT NOT NULL,
        source_entity_id   TEXT NOT NULL,
        payload_hash       TEXT NOT NULL,
        business_date      TEXT NOT NULL,
        received_at        TEXT NOT NULL,
        status             TEXT NOT NULL,
        payload_json       TEXT,
        error_summary      TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_watermarks (
        restaurant_id   TEXT NOT NULL,
        source_type     TEXT NOT NULL,
        watermark_type  TEXT NOT NULL,
        watermark_value TEXT NOT NULL,
        updated_at      TEXT NOT NULL,
        PRIMARY KEY (restaurant_id, source_type, watermark_type)
      )
    ''');

    // ── Target profile layer ─────────────────────────────────────────────
    await db.execute('''
      CREATE TABLE active_target_profiles (
        restaurant_id              TEXT PRIMARY KEY NOT NULL,
        target_profile_id          TEXT NOT NULL,
        source_type                TEXT NOT NULL,
        target_cplh                REAL NOT NULL,
        target_splh                REAL NOT NULL,
        target_ppa                 REAL NOT NULL,
        foh_wage                   REAL NOT NULL,
        boh_wage                   REAL NOT NULL,
        opz_floor_cplh             REAL NOT NULL,
        opz_ceiling_cplh           REAL NOT NULL,
        theoretical_foh_labor_pct  REAL NOT NULL,
        theoretical_boh_labor_pct  REAL NOT NULL,
        theoretical_labor_pct      REAL NOT NULL,
        built_at                   TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE target_profile_versions (
        target_profile_version_id  TEXT PRIMARY KEY NOT NULL,
        target_profile_id          TEXT NOT NULL,
        restaurant_id              TEXT NOT NULL,
        source_type                TEXT NOT NULL,
        target_cplh                REAL NOT NULL,
        target_splh                REAL NOT NULL,
        target_ppa                 REAL NOT NULL,
        foh_wage                   REAL NOT NULL,
        boh_wage                   REAL NOT NULL,
        opz_floor_cplh             REAL NOT NULL,
        opz_ceiling_cplh           REAL NOT NULL,
        theoretical_foh_labor_pct  REAL NOT NULL,
        theoretical_boh_labor_pct  REAL NOT NULL,
        theoretical_labor_pct      REAL NOT NULL,
        created_at                 TEXT NOT NULL
      )
    ''');

    // ── Canonical operational layer ───────────────────────────────────────
    await db.execute('''
      CREATE TABLE shift_records (
        id                         INTEGER PRIMARY KEY AUTOINCREMENT,
        restaurant_id              TEXT NOT NULL DEFAULT '${DemoScope.restaurantId}',
        week_id                    TEXT NOT NULL,
        day_label                  TEXT NOT NULL,
        daypart                    TEXT NOT NULL,
        status                     TEXT NOT NULL DEFAULT 'closed',
        covers                     INTEGER NOT NULL,
        forecast_covers            INTEGER NOT NULL,
        ppa                        REAL NOT NULL,
        cplh                       REAL NOT NULL,
        splh                       REAL NOT NULL,
        blended_wage               REAL NOT NULL,
        foh_hours                  INTEGER NOT NULL,
        boh_hours                  INTEGER NOT NULL,
        foh_labor_pct              REAL NOT NULL,
        boh_labor_pct              REAL NOT NULL,
        total_labor_pct            REAL NOT NULL,
        theoretical_labor_pct      REAL NOT NULL DEFAULT 20.6,
        variance_pts               REAL NOT NULL,
        primary_lever              TEXT NOT NULL,
        scheduled_foh_hours        INTEGER,
        scheduled_boh_hours        INTEGER,
        foh_labor_dollar           REAL,
        boh_labor_dollar           REAL,
        source_system              TEXT,
        source_shift_id            TEXT,
        target_profile_id          TEXT,
        target_profile_version_id  TEXT,
        target_source_type         TEXT,
        target_cplh                REAL,
        target_splh                REAL,
        target_ppa                 REAL,
        target_foh_wage            REAL,
        target_boh_wage            REAL,
        opz_floor_cplh             REAL,
        opz_ceiling_cplh           REAL,
        theoretical_foh_labor_pct  REAL,
        theoretical_boh_labor_pct  REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE week_records (
        id                         INTEGER PRIMARY KEY AUTOINCREMENT,
        restaurant_id              TEXT NOT NULL DEFAULT '${DemoScope.restaurantId}',
        week_id                    TEXT NOT NULL,
        week_label                 TEXT NOT NULL,
        total_covers               INTEGER NOT NULL,
        forecast_covers            INTEGER NOT NULL,
        total_foh_hours            INTEGER NOT NULL,
        total_boh_hours            INTEGER NOT NULL,
        avg_ppa                    REAL NOT NULL,
        avg_cplh                   REAL NOT NULL,
        theoretical_labor_pct      REAL NOT NULL,
        actual_labor_pct           REAL NOT NULL,
        dollar_gap                 REAL NOT NULL,
        primary_lever_id           TEXT NOT NULL,
        shifts_completed           INTEGER NOT NULL DEFAULT 14,
        blended_foh_wage           REAL NOT NULL DEFAULT 16.50,
        blended_boh_wage           REAL NOT NULL DEFAULT 21.35,
        target_source_type         TEXT,
        target_cplh                REAL,
        target_splh                REAL,
        target_ppa                 REAL,
        target_foh_wage            REAL,
        target_boh_wage            REAL,
        theoretical_foh_labor_pct  REAL,
        theoretical_boh_labor_pct  REAL,
        UNIQUE(restaurant_id, week_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE baseline_selected_records (
        restaurant_id TEXT NOT NULL DEFAULT '${DemoScope.restaurantId}',
        record_key    TEXT NOT NULL,
        PRIMARY KEY (restaurant_id, record_key)
      )
    ''');

    await db.execute('''
      CREATE TABLE open_shift_snapshots (
        id                      INTEGER PRIMARY KEY AUTOINCREMENT,
        restaurant_id           TEXT NOT NULL,
        week_id                 TEXT NOT NULL,
        day_label               TEXT NOT NULL,
        daypart                 TEXT NOT NULL,
        status                  TEXT NOT NULL DEFAULT 'projected',
        business_date           TEXT NOT NULL,
        forecast_covers         INTEGER NOT NULL,
        current_covers          INTEGER NOT NULL,
        scheduled_foh_hours     INTEGER NOT NULL,
        scheduled_boh_hours     INTEGER NOT NULL,
        current_ppa             REAL NOT NULL,
        current_cplh            REAL NOT NULL,
        current_splh            REAL NOT NULL,
        blended_wage            REAL NOT NULL,
        time_label              TEXT NOT NULL DEFAULT '',
        service_elapsed_label   TEXT NOT NULL DEFAULT '',
        source_system           TEXT,
        source_shift_id         TEXT,
        last_event_at           TEXT,
        updated_at              TEXT NOT NULL,
        UNIQUE(restaurant_id, week_id, day_label, daypart)
      )
    ''');
  }

  /// Backfills locked-target columns on shift_records and week_records
  /// that lack them, using the current active target profile.
  /// Also ensures target-profile provenance and a compat version row.
  Future<void> _backfillLockedTargets(Database db) async {
    final profile = buildActiveTargetProfileFromBaseline(DemoScope.restaurantId);
    final compatVersionId = 'compat_${DemoScope.restaurantId}_v8_backfill';

    // Ensure a compat target_profile_versions row exists
    await db.insert('target_profile_versions', {
      'target_profile_version_id': compatVersionId,
      'target_profile_id': profile.targetProfileId,
      'restaurant_id': DemoScope.restaurantId,
      'source_type': profile.sourceType,
      'target_cplh': profile.targetCPLH,
      'target_splh': profile.targetSPLH,
      'target_ppa': profile.targetPPA,
      'foh_wage': profile.fohWage,
      'boh_wage': profile.bohWage,
      'opz_floor_cplh': profile.opzFloorCPLH,
      'opz_ceiling_cplh': profile.opzCeilingCPLH,
      'theoretical_foh_labor_pct': profile.theoreticalFohLaborPct,
      'theoretical_boh_labor_pct': profile.theoreticalBohLaborPct,
      'theoretical_labor_pct': profile.theoreticalLaborPct,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    await db.execute('''
      UPDATE shift_records SET
        target_profile_id = ?,
        target_profile_version_id = ?,
        target_source_type = ?,
        target_cplh = ?,
        target_splh = ?,
        target_ppa = ?,
        target_foh_wage = ?,
        target_boh_wage = ?,
        opz_floor_cplh = ?,
        opz_ceiling_cplh = ?,
        theoretical_foh_labor_pct = ?,
        theoretical_boh_labor_pct = ?
      WHERE target_cplh IS NULL AND restaurant_id = ?
    ''', [
      profile.targetProfileId,
      compatVersionId,
      profile.sourceType,
      profile.targetCPLH,
      profile.targetSPLH,
      profile.targetPPA,
      profile.fohWage,
      profile.bohWage,
      profile.opzFloorCPLH,
      profile.opzCeilingCPLH,
      profile.theoreticalFohLaborPct,
      profile.theoreticalBohLaborPct,
      DemoScope.restaurantId,
    ]);

    // ── Provenance-only repair for partially migrated rows ──────────────────
    // Rows that already have numeric locked targets but lack identity fields.
    await db.execute('''
      UPDATE shift_records SET
        target_profile_id = ?,
        target_profile_version_id = ?
      WHERE restaurant_id = ?
        AND target_cplh IS NOT NULL
        AND (target_profile_id IS NULL OR target_profile_version_id IS NULL)
    ''', [
      profile.targetProfileId,
      compatVersionId,
      DemoScope.restaurantId,
    ]);

    await db.execute('''
      UPDATE week_records SET
        target_source_type = ?,
        target_cplh = ?,
        target_splh = ?,
        target_ppa = ?,
        target_foh_wage = ?,
        target_boh_wage = ?,
        theoretical_foh_labor_pct = ?,
        theoretical_boh_labor_pct = ?
      WHERE target_cplh IS NULL AND restaurant_id = ?
    ''', [
      profile.sourceType,
      profile.targetCPLH,
      profile.targetSPLH,
      profile.targetPPA,
      profile.fohWage,
      profile.bohWage,
      profile.theoreticalFohLaborPct,
      profile.theoreticalBohLaborPct,
      DemoScope.restaurantId,
    ]);
  }

  /// Seeds open/projected shift snapshots for the current week from fixture data.
  Future<void> _seedOpenShiftSnapshots(Database db) async {
    final now = DateTime.now().toIso8601String();
    final projectedShifts =
        DemoData.currentWeekShifts.where((s) => s.isProjected).toList();

    final snapshots = <OpenShiftSnapshot>[];

    for (final s in projectedShifts) {
      // Skip Fri/dinner — we'll insert the open shift for that slot instead
      if (s.dayLabel == 'Fri' && s.daypart == 'dinner') continue;

      snapshots.add(OpenShiftSnapshot(
        restaurantId: DemoScope.restaurantId,
        weekId: s.weekId,
        dayLabel: s.dayLabel,
        daypart: s.daypart,
        status: 'projected',
        businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel),
        forecastCovers: s.forecastCovers,
        currentCovers: s.covers,
        scheduledFohHours: s.scheduledFohHours ?? s.fohHours,
        scheduledBohHours: s.scheduledBohHours ?? s.bohHours,
        currentPPA: s.ppa,
        currentCPLH: s.cplh,
        currentSPLH: s.splh,
        blendedWage: s.blendedWage,
        updatedAt: now,
      ));
    }

    // One current open shift: Fri dinner from ShiftSnapshot fixture truth
    snapshots.add(OpenShiftSnapshot(
      restaurantId: DemoScope.restaurantId,
      weekId: '2026-W13',
      dayLabel: 'Fri',
      daypart: 'dinner',
      status: 'open',
      businessDate: _businessDateFromWeekDay('2026-W13', 'Fri'),
      forecastCovers: ShiftSnapshot.shiftForecastCovers,
      currentCovers: ShiftSnapshot.actualCovers,
      scheduledFohHours: ShiftSnapshot.scheduledFohHours,
      scheduledBohHours: ShiftSnapshot.scheduledBohHours,
      currentPPA: ShiftSnapshot.actualPPA,
      currentCPLH: ShiftSnapshot.actualCPLH,
      currentSPLH: ShiftSnapshot.actualSPLH,
      blendedWage: ShiftSnapshot.blendedWage,
      timeLabel: ShiftSnapshot.time,
      serviceElapsedLabel: ShiftSnapshot.serviceElapsed,
      updatedAt: now,
    ));

    final batch = db.batch();
    for (final snap in snapshots) {
      batch.insert('open_shift_snapshots', snap.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  // ── Seed helpers ────────────────────────────────────────────────────────

  Future<void> _seedDemoRestaurant(Database db) async {
    final now = DateTime.now().toIso8601String();
    await db.insert('restaurant_locations', {
      'restaurant_id': DemoScope.restaurantId,
      'display_name': DemoScope.displayName,
      'business_timezone': DemoScope.businessTimezone,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// Builds and persists an active target profile from current BaselineData.
  Future<void> _seedDemoActiveTargetProfile(Database db) async {
    final profile = buildActiveTargetProfileFromBaseline(DemoScope.restaurantId);
    await db.insert('active_target_profiles', profile.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Builds an ActiveTargetProfile from current BaselineData + MeridianConfig.
  static ActiveTargetProfile buildActiveTargetProfileFromBaseline(
      String restaurantId) {
    final sourceType = BaselineData.hasManagerOverride
        ? 'manager_override'
        : 'system_baseline';
    return ActiveTargetProfile(
      targetProfileId: '${restaurantId}_active',
      restaurantId: restaurantId,
      sourceType: sourceType,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
      opzFloorCPLH: BaselineData.opzFloorCPLH,
      opzCeilingCPLH: BaselineData.opzCeilingCPLH,
      theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
      theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
      theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
      builtAt: DateTime.now().toIso8601String(),
    );
  }

  Future<void> _seedDemoData(Database db) async {
    final now = DateTime.now().toIso8601String();
    final importRunId = 'fixture_replay_seed_${now.replaceAll(RegExp(r'[^0-9]'), '')}';

    final batch = db.batch();

    for (final s in DemoData.currentWeekShifts) {
      final map = s.toMap()..remove('id');
      map['restaurant_id'] = DemoScope.restaurantId;
      batch.insert('shift_records', map);
    }
    for (final s in DemoData.historicalClosedShifts) {
      final map = s.toMap()..remove('id');
      map['restaurant_id'] = DemoScope.restaurantId;
      batch.insert('shift_records', map);
    }
    for (final w in DemoData.weekHistory) {
      final map = w.toMap()..remove('id');
      map['restaurant_id'] = DemoScope.restaurantId;
      batch.insert('week_records', map);
    }
    await batch.commit(noResult: true);

    // Record a fixture_replay import run
    final importRun = ImportRun(
      importRunId: importRunId,
      restaurantId: DemoScope.restaurantId,
      mode: 'fixture_replay',
      startedAt: now,
      completedAt: now,
      status: 'completed',
    );
    await db.insert('import_runs', importRun.toMap());

    // Insert raw import records for seeded shifts
    final allShifts = [
      ...DemoData.currentWeekShifts,
      ...DemoData.historicalClosedShifts,
    ];
    final rawBatch = db.batch();
    for (int i = 0; i < allShifts.length; i++) {
      final s = allShifts[i];
      final payloadJson = jsonEncode(s.toMap()..remove('id'));
      final hash = _deterministicHash(payloadJson);
      final record = RawImportRecord(
        rawImportId: '${importRunId}_shift_$i',
        importRunId: importRunId,
        restaurantId: DemoScope.restaurantId,
        sourceType: 'fixture',
        sourceEntityType: 'shift_record',
        sourceEntityId: '${s.weekId}_${s.dayLabel}_${s.daypart}',
        payloadHash: hash,
        businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel),
        receivedAt: now,
        status: 'applied',
        payloadJson: payloadJson,
      );
      rawBatch.insert('raw_import_records', record.toMap());
    }
    await rawBatch.commit(noResult: true);
  }

  static String _deterministicHash(String payload) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < payload.length; i++) {
      hash ^= payload.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _businessDateFromWeekDay(String weekId, String dayLabel) {
    const dayOffset = {
      'Mon': 0, 'Tue': 1, 'Wed': 2, 'Thu': 3,
      'Fri': 4, 'Sat': 5, 'Sun': 6,
    };
    final parts = weekId.split('-W');
    if (parts.length == 2) {
      final year = int.tryParse(parts[0]);
      final week = int.tryParse(parts[1]);
      if (year != null && week != null) {
        final jan4 = DateTime(year, 1, 4);
        final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
        final monday = week1Monday.add(Duration(days: (week - 1) * 7));
        final date = monday.add(Duration(days: dayOffset[dayLabel] ?? 0));
        return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      }
    }
    return '1970-01-01';
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
  }

  Future<void> _migrateToV10(Database db) async {
    await _dedupeConnectorConfigs(db);
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS ux_connector_configs_restaurant_source
      ON connector_configs(restaurant_id, source_type)
    ''');
  }

  Future<void> _migrateToV9(Database db) async {
    await _createTableIfNotExists(db, 'open_shift_snapshots', '''
      CREATE TABLE open_shift_snapshots (
        id                      INTEGER PRIMARY KEY AUTOINCREMENT,
        restaurant_id           TEXT NOT NULL,
        week_id                 TEXT NOT NULL,
        day_label               TEXT NOT NULL,
        daypart                 TEXT NOT NULL,
        status                  TEXT NOT NULL DEFAULT 'projected',
        business_date           TEXT NOT NULL,
        forecast_covers         INTEGER NOT NULL,
        current_covers          INTEGER NOT NULL,
        scheduled_foh_hours     INTEGER NOT NULL,
        scheduled_boh_hours     INTEGER NOT NULL,
        current_ppa             REAL NOT NULL,
        current_cplh            REAL NOT NULL,
        current_splh            REAL NOT NULL,
        blended_wage            REAL NOT NULL,
        time_label              TEXT NOT NULL DEFAULT '',
        service_elapsed_label   TEXT NOT NULL DEFAULT '',
        source_system           TEXT,
        source_shift_id         TEXT,
        last_event_at           TEXT,
        updated_at              TEXT NOT NULL,
        UNIQUE(restaurant_id, week_id, day_label, daypart)
      )
    ''');
  }

  Future<void> _migrateToV8(Database db) async {
    // ── 1. Create target profile tables ───────────────────────────────────
    await _createTableIfNotExists(db, 'active_target_profiles', '''
      CREATE TABLE active_target_profiles (
        restaurant_id              TEXT PRIMARY KEY NOT NULL,
        target_profile_id          TEXT NOT NULL,
        source_type                TEXT NOT NULL,
        target_cplh                REAL NOT NULL,
        target_splh                REAL NOT NULL,
        target_ppa                 REAL NOT NULL,
        foh_wage                   REAL NOT NULL,
        boh_wage                   REAL NOT NULL,
        opz_floor_cplh             REAL NOT NULL,
        opz_ceiling_cplh           REAL NOT NULL,
        theoretical_foh_labor_pct  REAL NOT NULL,
        theoretical_boh_labor_pct  REAL NOT NULL,
        theoretical_labor_pct      REAL NOT NULL,
        built_at                   TEXT NOT NULL
      )
    ''');

    await _createTableIfNotExists(db, 'target_profile_versions', '''
      CREATE TABLE target_profile_versions (
        target_profile_version_id  TEXT PRIMARY KEY NOT NULL,
        target_profile_id          TEXT NOT NULL,
        restaurant_id              TEXT NOT NULL,
        source_type                TEXT NOT NULL,
        target_cplh                REAL NOT NULL,
        target_splh                REAL NOT NULL,
        target_ppa                 REAL NOT NULL,
        foh_wage                   REAL NOT NULL,
        boh_wage                   REAL NOT NULL,
        opz_floor_cplh             REAL NOT NULL,
        opz_ceiling_cplh           REAL NOT NULL,
        theoretical_foh_labor_pct  REAL NOT NULL,
        theoretical_boh_labor_pct  REAL NOT NULL,
        theoretical_labor_pct      REAL NOT NULL,
        created_at                 TEXT NOT NULL
      )
    ''');

    // ── 2. Add locked-target columns to shift_records ─────────────────────
    final shiftCols = [
      'target_profile_id TEXT',
      'target_profile_version_id TEXT',
      'target_source_type TEXT',
      'target_cplh REAL',
      'target_splh REAL',
      'target_ppa REAL',
      'target_foh_wage REAL',
      'target_boh_wage REAL',
      'opz_floor_cplh REAL',
      'opz_ceiling_cplh REAL',
      'theoretical_foh_labor_pct REAL',
      'theoretical_boh_labor_pct REAL',
    ];
    for (final col in shiftCols) {
      final name = col.split(' ').first;
      if (!await _columnExists(db, 'shift_records', name)) {
        await db.execute('ALTER TABLE shift_records ADD COLUMN $col');
      }
    }

    // ── 3. Add locked-target columns to week_records ──────────────────────
    final weekCols = [
      'target_source_type TEXT',
      'target_cplh REAL',
      'target_splh REAL',
      'target_ppa REAL',
      'target_foh_wage REAL',
      'target_boh_wage REAL',
      'theoretical_foh_labor_pct REAL',
      'theoretical_boh_labor_pct REAL',
    ];
    for (final col in weekCols) {
      final name = col.split(' ').first;
      if (!await _columnExists(db, 'week_records', name)) {
        await db.execute('ALTER TABLE week_records ADD COLUMN $col');
      }
    }

    // ── 4. Seed active target profile if missing ──────────────────────────
    await _seedDemoActiveTargetProfile(db);

    // ── 5. Backfill legacy rows with current target state + provenance ─────
    final profile = buildActiveTargetProfileFromBaseline(DemoScope.restaurantId);
    final compatVersionId = 'compat_${DemoScope.restaurantId}_v8_backfill';

    // Ensure a compat target_profile_versions row exists
    await db.insert('target_profile_versions', {
      'target_profile_version_id': compatVersionId,
      'target_profile_id': profile.targetProfileId,
      'restaurant_id': DemoScope.restaurantId,
      'source_type': profile.sourceType,
      'target_cplh': profile.targetCPLH,
      'target_splh': profile.targetSPLH,
      'target_ppa': profile.targetPPA,
      'foh_wage': profile.fohWage,
      'boh_wage': profile.bohWage,
      'opz_floor_cplh': profile.opzFloorCPLH,
      'opz_ceiling_cplh': profile.opzCeilingCPLH,
      'theoretical_foh_labor_pct': profile.theoreticalFohLaborPct,
      'theoretical_boh_labor_pct': profile.theoreticalBohLaborPct,
      'theoretical_labor_pct': profile.theoreticalLaborPct,
      'created_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    await db.execute('''
      UPDATE shift_records SET
        target_profile_id = ?,
        target_profile_version_id = ?,
        target_source_type = ?,
        target_cplh = ?,
        target_splh = ?,
        target_ppa = ?,
        target_foh_wage = ?,
        target_boh_wage = ?,
        opz_floor_cplh = ?,
        opz_ceiling_cplh = ?,
        theoretical_foh_labor_pct = ?,
        theoretical_boh_labor_pct = ?
      WHERE target_cplh IS NULL AND restaurant_id = ?
    ''', [
      profile.targetProfileId,
      compatVersionId,
      profile.sourceType,
      profile.targetCPLH,
      profile.targetSPLH,
      profile.targetPPA,
      profile.fohWage,
      profile.bohWage,
      profile.opzFloorCPLH,
      profile.opzCeilingCPLH,
      profile.theoreticalFohLaborPct,
      profile.theoreticalBohLaborPct,
      DemoScope.restaurantId,
    ]);
    await db.execute('''
      UPDATE week_records SET
        target_source_type = ?,
        target_cplh = ?,
        target_splh = ?,
        target_ppa = ?,
        target_foh_wage = ?,
        target_boh_wage = ?,
        theoretical_foh_labor_pct = ?,
        theoretical_boh_labor_pct = ?
      WHERE target_cplh IS NULL AND restaurant_id = ?
    ''', [
      profile.sourceType,
      profile.targetCPLH,
      profile.targetSPLH,
      profile.targetPPA,
      profile.fohWage,
      profile.bohWage,
      profile.theoreticalFohLaborPct,
      profile.theoreticalBohLaborPct,
      DemoScope.restaurantId,
    ]);

    // ── 6. Provenance repair for partially migrated rows ─────────────────
    await db.execute('''
      UPDATE shift_records SET
        target_profile_id = ?,
        target_profile_version_id = ?
      WHERE restaurant_id = ?
        AND target_cplh IS NOT NULL
        AND (target_profile_id IS NULL OR target_profile_version_id IS NULL)
    ''', [
      profile.targetProfileId,
      compatVersionId,
      DemoScope.restaurantId,
    ]);
  }

  Future<void> _migrateToV7(Database db) async {
    await _createTableIfNotExists(db, 'restaurant_locations', '''
      CREATE TABLE restaurant_locations (
        restaurant_id TEXT PRIMARY KEY NOT NULL, display_name TEXT NOT NULL,
        business_timezone TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
    ''');
    await _createTableIfNotExists(db, 'connector_configs', '''
      CREATE TABLE connector_configs (
        connector_id TEXT PRIMARY KEY NOT NULL, restaurant_id TEXT NOT NULL,
        source_type TEXT NOT NULL, external_location_id TEXT NOT NULL,
        status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
    ''');
    await _createTableIfNotExists(db, 'import_runs', '''
      CREATE TABLE import_runs (
        import_run_id TEXT PRIMARY KEY NOT NULL, restaurant_id TEXT NOT NULL,
        mode TEXT NOT NULL, started_at TEXT NOT NULL, completed_at TEXT,
        status TEXT NOT NULL, cursor_json TEXT, error_summary TEXT)
    ''');
    await _createTableIfNotExists(db, 'raw_import_records', '''
      CREATE TABLE raw_import_records (
        raw_import_id TEXT PRIMARY KEY NOT NULL, import_run_id TEXT NOT NULL,
        restaurant_id TEXT NOT NULL, source_type TEXT NOT NULL,
        source_entity_type TEXT NOT NULL, source_entity_id TEXT NOT NULL,
        payload_hash TEXT NOT NULL, business_date TEXT NOT NULL,
        received_at TEXT NOT NULL, status TEXT NOT NULL,
        payload_json TEXT, error_summary TEXT)
    ''');
    await _createTableIfNotExists(db, 'sync_watermarks', '''
      CREATE TABLE sync_watermarks (
        restaurant_id TEXT NOT NULL, source_type TEXT NOT NULL,
        watermark_type TEXT NOT NULL, watermark_value TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (restaurant_id, source_type, watermark_type))
    ''');

    if (await _tableExists(db, 'shift_records')) {
      if (!await _columnExists(db, 'shift_records', 'restaurant_id')) {
        await db.execute(
          "ALTER TABLE shift_records ADD COLUMN restaurant_id TEXT NOT NULL DEFAULT '${DemoScope.restaurantId}'",
        );
      }
    }

    if (await _tableExists(db, 'week_records')) {
      await _rebuildWeekRecordsForScope(db);
    }

    if (await _tableExists(db, 'baseline_selected_records')) {
      if (!await _columnExists(db, 'baseline_selected_records', 'restaurant_id')) {
        final oldKeys = await db.query('baseline_selected_records');
        await db.execute('DROP TABLE baseline_selected_records');
        await db.execute('''
          CREATE TABLE baseline_selected_records (
            restaurant_id TEXT NOT NULL DEFAULT '${DemoScope.restaurantId}',
            record_key TEXT NOT NULL,
            PRIMARY KEY (restaurant_id, record_key))
        ''');
        for (final row in oldKeys) {
          await db.insert('baseline_selected_records', {
            'restaurant_id': DemoScope.restaurantId,
            'record_key': row['record_key'] as String,
          });
        }
      }
    }

    await _ensureDemoRestaurant(db);
  }

  Future<void> _rebuildWeekRecordsForScope(Database db) async {
    final oldRows = await db.query('week_records');
    await db.execute('DROP TABLE week_records');
    await db.execute('''
      CREATE TABLE week_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        restaurant_id TEXT NOT NULL DEFAULT '${DemoScope.restaurantId}',
        week_id TEXT NOT NULL, week_label TEXT NOT NULL,
        total_covers INTEGER NOT NULL, forecast_covers INTEGER NOT NULL,
        total_foh_hours INTEGER NOT NULL, total_boh_hours INTEGER NOT NULL,
        avg_ppa REAL NOT NULL, avg_cplh REAL NOT NULL,
        theoretical_labor_pct REAL NOT NULL, actual_labor_pct REAL NOT NULL,
        dollar_gap REAL NOT NULL, primary_lever_id TEXT NOT NULL,
        shifts_completed INTEGER NOT NULL DEFAULT 14,
        blended_foh_wage REAL NOT NULL DEFAULT 16.50,
        blended_boh_wage REAL NOT NULL DEFAULT 21.35,
        UNIQUE(restaurant_id, week_id))
    ''');
    for (final row in oldRows) {
      final map = Map<String, dynamic>.from(row);
      map.remove('id');
      map['restaurant_id'] =
          (map['restaurant_id'] as String?) ?? DemoScope.restaurantId;
      await db.insert('week_records', map);
    }
  }

  /// Exposed for testing.
  Future<void> migrateToV7ForTest(Database db) => _migrateToV7(db);
  Future<void> migrateToV8ForTest(Database db) => _migrateToV8(db);

  Future<void> _ensureDemoRestaurant(Database db) async {
    final existing = await db.query('restaurant_locations',
        where: 'restaurant_id = ?', whereArgs: [DemoScope.restaurantId]);
    if (existing.isEmpty) {
      await _seedDemoRestaurant(db);
    }
  }

  static Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]);
    return rows.isNotEmpty;
  }

  static Future<bool> _columnExists(
      Database db, String table, String column) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] == column);
  }

  static Future<void> _createTableIfNotExists(
      Database db, String table, String createSql) async {
    if (!await _tableExists(db, table)) {
      await db.execute(createSql);
    }
  }

  static Future<void> _dedupeConnectorConfigs(Database db) async {
    final duplicates = await db.rawQuery('''
      SELECT restaurant_id, source_type
      FROM connector_configs
      GROUP BY restaurant_id, source_type
      HAVING COUNT(*) > 1
    ''');

    for (final duplicate in duplicates) {
      final restaurantId = duplicate['restaurant_id'] as String;
      final sourceType = duplicate['source_type'] as String;
      final rows = await db.rawQuery('''
        SELECT connector_id
        FROM connector_configs
        WHERE restaurant_id = ? AND source_type = ?
        ORDER BY updated_at DESC, rowid DESC
      ''', [restaurantId, sourceType]);

      for (final row in rows.skip(1)) {
        await db.delete(
          'connector_configs',
          where: 'connector_id = ?',
          whereArgs: [row['connector_id']],
        );
      }
    }
  }

  // ── Reseed ──────────────────────────────────────────────────────────────

  Future<void> reseedDemo() async {
    final db = await database;
    await db.delete('shift_records');
    await db.delete('week_records');
    await db.delete('baseline_selected_records');
    await db.delete('import_runs');
    await db.delete('raw_import_records');
    await db.delete('sync_watermarks');
    await db.delete('target_profile_versions');
    await db.delete('open_shift_snapshots');

    final existing = await db.query('restaurant_locations',
        where: 'restaurant_id = ?', whereArgs: [DemoScope.restaurantId]);
    if (existing.isEmpty) {
      await _seedDemoRestaurant(db);
    }

    await _seedDemoActiveTargetProfile(db);
    await _seedDemoData(db);
    await _backfillLockedTargets(db);
    await _seedOpenShiftSnapshots(db);
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
    await db.delete('active_target_profiles');

    // Reset in-memory compatibility bridge
    BaselineData.clearHistoricalContext();
    BaselineData.clearManagerOverride();
  }
}
