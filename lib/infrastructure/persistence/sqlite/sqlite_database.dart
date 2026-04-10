// SQLite bootstrap layer — owns database lifecycle, schema, and migrations.
//
// DatabaseHelper delegates to this for open/init. DAOs and repositories
// operate on the Database instance this class provides.

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite_mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../data/legacy_fixture_data.dart';
import '../../../data/mock_integration_replay_seed.dart';
import '../../../domain/models/active_target_profile.dart';
import '../../../domain/models/import_run.dart';
import '../../../domain/models/open_shift_snapshot.dart';
import '../../../domain/models/raw_import_record.dart';
import '../../../domain/models/reservation_book_snapshot.dart';

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
  static const int schemaVersion = 13;

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

    // Persist default mock replay business date
    await db.insert('mock_replay_state', {
      'restaurant_id': DemoScope.restaurantId,
      'current_business_date': MockIntegrationReplaySeed.defaultBusinessDate,
    });

    final replay = MockIntegrationReplaySeed.output;
    await _seedDemoDataFromReplay(db, replay);
    await _backfillLockedTargets(db);
    await _seedOpenShiftSnapshotsFromReplay(db, replay);
    await _seedReservationBookSnapshotsFromReplay(db, replay);
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
        business_date              TEXT,
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

    await db.execute('''
      CREATE TABLE reservation_book_snapshots (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        restaurant_id         TEXT NOT NULL,
        business_date         TEXT NOT NULL,
        daypart               TEXT NOT NULL,
        unseated_covers       INTEGER NOT NULL,
        unseated_party_count  INTEGER NOT NULL,
        source_system         TEXT,
        source_service_id     TEXT,
        last_event_at         TEXT,
        updated_at            TEXT NOT NULL,
        UNIQUE(restaurant_id, business_date, daypart)
      )
    ''');

    await db.execute('''
      CREATE TABLE mock_replay_state (
        restaurant_id         TEXT PRIMARY KEY NOT NULL,
        current_business_date TEXT NOT NULL
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

  /// Seeds open/projected shift snapshots for the current week from replay output.
  ///
  /// The open shift is determined by [replay.scenario], not hardcoded to
  /// Friday dinner. Closed same-day dayparts and projected future dayparts
  /// are derived from the scenario.
  Future<void> _seedOpenShiftSnapshotsFromReplay(
      Database db, MockReplayOutput replay) async {
    final now = DateTime.now().toIso8601String();
    final scenario = replay.scenario;
    final projectedShifts =
        replay.currentWeekShifts.where((s) => s.isProjected).toList();

    final snapshots = <OpenShiftSnapshot>[];

    for (final s in projectedShifts) {
      // Skip the open-shift slot — we'll insert the open snapshot for it
      if (s.dayLabel == scenario.openShiftDayLabel &&
          s.daypart == scenario.openShiftDaypart) {
        continue;
      }

      snapshots.add(OpenShiftSnapshot(
        restaurantId: DemoScope.restaurantId,
        weekId: s.weekId,
        dayLabel: s.dayLabel,
        daypart: s.daypart,
        status: 'projected',
        businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
        forecastCovers: s.forecastCovers,
        currentCovers: s.covers,
        scheduledFohHours: s.scheduledFohHours ?? s.fohHours,
        scheduledBohHours: s.scheduledBohHours ?? s.bohHours,
        currentPPA: s.ppa,
        currentCPLH: s.cplh,
        currentSPLH: s.splh,
        blendedWage: s.blendedWage,
        sourceSystem: s.sourceSystem ?? MockIntegrationReplaySeed.sourceSystem,
        sourceShiftId: MockIntegrationReplaySeed.snapshotSourceShiftId(
          weekId: s.weekId,
          dayLabel: s.dayLabel,
          daypart: s.daypart,
          status: 'projected',
        ),
        updatedAt: now,
      ));
    }

    // One current open shift from the scenario.
    // In-progress values simulate ~63% through service.
    final openShiftPlan = replay.currentWeekShifts.firstWhere(
      (s) =>
          s.dayLabel == scenario.openShiftDayLabel &&
          s.daypart == scenario.openShiftDaypart,
    );
    final openCovers = (openShiftPlan.forecastCovers *
            MockIntegrationReplaySeed.openProgressFraction)
        .round();
    final openPPA = openShiftPlan.ppa;
    final openSales = openCovers * openPPA;
    final openCPLH = openShiftPlan.fohHours > 0
        ? openCovers / openShiftPlan.fohHours
        : 0.0;
    final openSPLH = openShiftPlan.bohHours > 0
        ? openSales / openShiftPlan.bohHours
        : 0.0;

    snapshots.add(OpenShiftSnapshot(
      restaurantId: DemoScope.restaurantId,
      weekId: scenario.currentWeekId,
      dayLabel: scenario.openShiftDayLabel,
      daypart: scenario.openShiftDaypart,
      status: 'open',
      businessDate: scenario.currentBusinessDate,
      forecastCovers: openShiftPlan.forecastCovers,
      currentCovers: openCovers,
      scheduledFohHours: openShiftPlan.fohHours,
      scheduledBohHours: openShiftPlan.bohHours,
      currentPPA: openPPA,
      currentCPLH: double.parse(openCPLH.toStringAsFixed(2)),
      currentSPLH: double.parse(openSPLH.toStringAsFixed(2)),
      blendedWage: double.parse(openShiftPlan.blendedWage.toStringAsFixed(2)),
      timeLabel: MockIntegrationReplaySeed.openShiftTimeLabel,
      serviceElapsedLabel:
          MockIntegrationReplaySeed.openShiftServiceElapsedLabel,
      sourceSystem: MockIntegrationReplaySeed.sourceSystem,
      sourceShiftId:
          MockIntegrationReplaySeed.openShiftSourceShiftIdFor(scenario),
      updatedAt: now,
    ));

    // Seed closed dayparts for the open shift's day (whole-day aggregation).
    final currentDayClosed = replay.currentWeekShifts
        .where((s) =>
            s.dayLabel == scenario.openShiftDayLabel && s.status == 'closed')
        .toList();
    for (final s in currentDayClosed) {
      snapshots.add(OpenShiftSnapshot(
        restaurantId: DemoScope.restaurantId,
        weekId: s.weekId,
        dayLabel: s.dayLabel,
        daypart: s.daypart,
        status: 'closed',
        businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
        forecastCovers: s.forecastCovers,
        currentCovers: s.covers,
        scheduledFohHours: s.scheduledFohHours ?? s.fohHours,
        scheduledBohHours: s.scheduledBohHours ?? s.bohHours,
        currentPPA: s.ppa,
        currentCPLH: s.cplh,
        currentSPLH: s.splh,
        blendedWage: s.blendedWage,
        sourceSystem: s.sourceSystem ?? MockIntegrationReplaySeed.sourceSystem,
        sourceShiftId: MockIntegrationReplaySeed.snapshotSourceShiftId(
          weekId: s.weekId,
          dayLabel: s.dayLabel,
          daypart: s.daypart,
          status: 'closed',
        ),
        updatedAt: now,
      ));
    }

    final batch = db.batch();
    for (final snap in snapshots) {
      batch.insert('open_shift_snapshots', snap.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Seeds a reservation book snapshot for the scenario's open shift.
  ///
  /// Unseated covers scale deterministically with the day's base cover volume.
  Future<void> _seedReservationBookSnapshotsFromReplay(
      Database db, MockReplayOutput replay) async {
    final now = DateTime.now().toIso8601String();
    final scenario = replay.scenario;

    // Scale unseated covers from Friday baseline (72) by day-volume ratio.
    const fridayBaseCovers = 220;
    const fridayUnseatedCovers = 72;
    const fridayUnseatedParties = 18;
    const dayBaseCovers = {
      'Mon': 140, 'Tue': 150, 'Wed': 160, 'Thu': 190,
      'Fri': 220, 'Sat': 230, 'Sun': 110,
    };
    final dayCovers = dayBaseCovers[scenario.openShiftDayLabel] ?? fridayBaseCovers;
    final coverRatio = dayCovers / fridayBaseCovers;
    final unseatedCovers = (fridayUnseatedCovers * coverRatio).round();
    final unseatedParties = (fridayUnseatedParties * coverRatio).round();

    final snapshot = ReservationBookSnapshot(
      restaurantId: DemoScope.restaurantId,
      businessDate: scenario.currentBusinessDate,
      daypart: scenario.openShiftDaypart,
      unseatedCovers: unseatedCovers,
      unseatedPartyCount: unseatedParties,
      sourceSystem: 'demo_reservations',
      sourceServiceId:
          'demo_res_${scenario.openShiftDayLabel.toLowerCase()}_${scenario.openShiftDaypart}',
      updatedAt: now,
    );
    await db.insert('reservation_book_snapshots', snapshot.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
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

  Future<void> _seedDemoDataFromReplay(Database db, MockReplayOutput replay) async {
    final now = DateTime.now().toIso8601String();
    final importRunId = 'mock_replay_seed_${now.replaceAll(RegExp(r'[^0-9]'), '')}';

    final batch = db.batch();

    for (final s in replay.currentWeekShifts) {
      final map = s.toMap()..remove('id');
      map['restaurant_id'] = DemoScope.restaurantId;
      batch.insert('shift_records', map);
    }
    for (final s in replay.historicalClosedShifts) {
      final map = s.toMap()..remove('id');
      map['restaurant_id'] = DemoScope.restaurantId;
      batch.insert('shift_records', map);
    }
    for (final w in replay.weekRecords) {
      final map = w.toMap()..remove('id');
      map['restaurant_id'] = DemoScope.restaurantId;
      batch.insert('week_records', map,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);

    // Record a mock_pos_labor_replay import run
    final importRun = ImportRun(
      importRunId: importRunId,
      restaurantId: DemoScope.restaurantId,
      mode: 'mock_pos_labor_replay',
      startedAt: now,
      completedAt: now,
      status: 'completed',
    );
    await db.insert('import_runs', importRun.toMap());

    // Insert raw import records for seeded shifts
    final allShifts = [
      ...replay.currentWeekShifts,
      ...replay.historicalClosedShifts,
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
        sourceType: 'mock_pos_labor_replay',
        sourceEntityType: 'shift_record',
        sourceEntityId: '${s.weekId}_${s.dayLabel}_${s.daypart}',
        payloadHash: hash,
        businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
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

  /// Strict YYYY-W## weekId + known dayLabel → ISO date, or null.
  static final _weekIdPattern = RegExp(r'^\d{4}-W\d{2}$');

  static String? _businessDateFromWeekDay(String weekId, String dayLabel) {
    const dayOffset = {
      'Mon': 0, 'Tue': 1, 'Wed': 2, 'Thu': 3,
      'Fri': 4, 'Sat': 5, 'Sun': 6,
    };
    if (!dayOffset.containsKey(dayLabel)) return null;
    if (!_weekIdPattern.hasMatch(weekId)) return null;
    final parts = weekId.split('-W');
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return null;
    final jan4 = DateTime(year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    final monday = week1Monday.add(Duration(days: (week - 1) * 7));
    final date = monday.add(Duration(days: dayOffset[dayLabel]!));
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
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
  }

  Future<void> _migrateToV10(Database db) async {
    await _dedupeConnectorConfigs(db);
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS ux_connector_configs_restaurant_source
      ON connector_configs(restaurant_id, source_type)
    ''');
  }

  Future<void> _migrateToV11(Database db) async {
    await _createTableIfNotExists(db, 'reservation_book_snapshots', '''
      CREATE TABLE reservation_book_snapshots (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        restaurant_id         TEXT NOT NULL,
        business_date         TEXT NOT NULL,
        daypart               TEXT NOT NULL,
        unseated_covers       INTEGER NOT NULL,
        unseated_party_count  INTEGER NOT NULL,
        source_system         TEXT,
        source_service_id     TEXT,
        last_event_at         TEXT,
        updated_at            TEXT NOT NULL,
        UNIQUE(restaurant_id, business_date, daypart)
      )
    ''');
    await _seedReservationBookSnapshotsFromReplay(
        db, MockIntegrationReplaySeed.output);
  }

  Future<void> _migrateToV12(Database db) async {
    // Add business_date column to shift_records if missing.
    if (!await _columnExists(db, 'shift_records', 'business_date')) {
      await db.execute(
        'ALTER TABLE shift_records ADD COLUMN business_date TEXT',
      );
    }
    // Backfill null business_date from existing week_id + day_label.
    final nullRows = await db.rawQuery(
      'SELECT id, week_id, day_label FROM shift_records WHERE business_date IS NULL',
    );
    if (nullRows.isNotEmpty) {
      final batch = db.batch();
      for (final row in nullRows) {
        final weekId = row['week_id'] as String;
        final dayLabel = row['day_label'] as String;
        final date = _businessDateFromWeekDay(weekId, dayLabel);
        if (date == null) continue; // malformed legacy rows stay null
        batch.rawUpdate(
          'UPDATE shift_records SET business_date = ? WHERE id = ?',
          [date, row['id']],
        );
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> _migrateToV13(Database db) async {
    await _createTableIfNotExists(db, 'mock_replay_state', '''
      CREATE TABLE mock_replay_state (
        restaurant_id         TEXT PRIMARY KEY NOT NULL,
        current_business_date TEXT NOT NULL
      )
    ''');
    // Seed default mock replay date for existing installations
    await db.insert('mock_replay_state', {
      'restaurant_id': DemoScope.restaurantId,
      'current_business_date': MockIntegrationReplaySeed.defaultBusinessDate,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
  Future<void> migrateToV12ForTest(Database db) => _migrateToV12(db);

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
  Future<void> reseedDemo() async {
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

    // Clear operational tables
    await db.delete('shift_records');
    await db.delete('week_records');
    await db.delete('baseline_selected_records');
    await db.delete('import_runs');
    await db.delete('raw_import_records');
    await db.delete('sync_watermarks');
    await db.delete('target_profile_versions');
    await db.delete('open_shift_snapshots');
    await db.delete('reservation_book_snapshots');

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

    await _seedDemoActiveTargetProfile(db);
    await _seedDemoDataFromReplay(db, replay);
    await _backfillLockedTargets(db);
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

    // Reset in-memory compatibility bridge
    BaselineData.clearHistoricalContext();
    BaselineData.clearManagerOverride();
  }
}
