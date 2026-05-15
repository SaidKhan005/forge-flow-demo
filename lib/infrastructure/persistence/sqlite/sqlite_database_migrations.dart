// Phase 7.55o.6 — SQLite migration helpers (V7..V24).
//
// Part of sqlite_database.dart. Owns every `_migrateToVxx` helper,
// the cross-migration `_rebuildWeekRecordsForScope` rebuild, and the
// migration utilities `_tableExists`, `_columnExists`, and
// `_dedupeConnectorConfigs`. Migration order is still dispatched by
// `SqliteDatabase._onUpgrade` in the shell; this file only holds
// the bodies. No SQL, default, or order change.

part of 'sqlite_database.dart';

/// Strict YYYY-W## weekId + known dayLabel → ISO date, or null.
final _weekIdPattern = RegExp(r'^\d{4}-W\d{2}$');

String? _businessDateFromWeekDay(String weekId, String dayLabel) {
  const dayOffset = {
    'Mon': 0,
    'Tue': 1,
    'Wed': 2,
    'Thu': 3,
    'Fri': 4,
    'Sat': 5,
    'Sun': 6,
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

Future<void> _migrateToV21(Database db) async {
  if (!await _columnExists(db, 'week_records', 'locked_required_foh_hours')) {
    await db.execute(
      'ALTER TABLE week_records ADD COLUMN locked_required_foh_hours INTEGER',
    );
  }
  if (!await _columnExists(db, 'week_records', 'locked_required_boh_hours')) {
    await db.execute(
      'ALTER TABLE week_records ADD COLUMN locked_required_boh_hours INTEGER',
    );
  }
}

Future<void> _migrateToV22(Database db) async {
  if (!await _columnExists(db, 'week_records', 'month_dollar_impact')) {
    await db.execute(
      'ALTER TABLE week_records ADD COLUMN month_dollar_impact REAL',
    );
  }
  if (!await _columnExists(db, 'week_records', 'sixty_day_dollar_impact')) {
    await db.execute(
      'ALTER TABLE week_records ADD COLUMN sixty_day_dollar_impact REAL',
    );
  }
  if (!await _columnExists(db, 'week_records', 'closed_at')) {
    await db.execute('ALTER TABLE week_records ADD COLUMN closed_at TEXT');
  }
}

Future<void> _migrateToV23(Database db) async {
  if (!await _columnExists(
    db,
    'week_records',
    'target_calibration_window_start',
  )) {
    await db.execute(
      'ALTER TABLE week_records ADD COLUMN target_calibration_window_start TEXT',
    );
  }
  if (!await _columnExists(
    db,
    'week_records',
    'target_calibration_window_end',
  )) {
    await db.execute(
      'ALTER TABLE week_records ADD COLUMN target_calibration_window_end TEXT',
    );
  }

  // Demo/backfill safety net: older seeded History rows may already carry
  // locked target numbers but pre-date the calibration-window fields.
  // When an active demo cycle exists, backfill the new display metadata from
  // that preserved cycle so upgraded demo DBs show the same range contract
  // after restart. This is intentionally scoped to the demo restaurant.
  await db.execute(
    '''
    UPDATE week_records
    SET
      target_calibration_window_start = (
        SELECT calibration_window_start
        FROM target_cycles
        WHERE restaurant_id = ? AND deactivated_at IS NULL
        ORDER BY created_at DESC
        LIMIT 1
      ),
      target_calibration_window_end = (
        SELECT calibration_window_end
        FROM target_cycles
        WHERE restaurant_id = ? AND deactivated_at IS NULL
        ORDER BY created_at DESC
        LIMIT 1
      )
    WHERE restaurant_id = ?
      AND (
        target_calibration_window_start IS NULL OR
        target_calibration_window_end IS NULL
      )
  ''',
    [DemoScope.restaurantId, DemoScope.restaurantId, DemoScope.restaurantId],
  );
}

/// HARD-H — boundary monitor durable backlog.
///
/// Adds the per-device `boundary_event_outbox` table so a foreground
/// crash mid-fire does not drop a business-date rollover. The Flutter
/// app cannot reach Postgres directly (Hard Promise #7), so this is
/// the client-side analogue of the server-side `event_outbox` rollover
/// topic. The boundary monitor's purpose is local UI refresh, so
/// per-device durability is sufficient.
///
/// `picked_up_at` mirrors the server-side claim marker so concurrent
/// drains cannot double-fire — `SqliteBoundaryEventOutbox.claimPending`
/// runs a transactional select + update that stamps `picked_up_at` on
/// the rows it returns.
Future<void> _migrateToV25(Database db) async {
  await _createTableIfNotExists(db, 'boundary_event_outbox', '''
    CREATE TABLE boundary_event_outbox (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      restaurant_id  TEXT NOT NULL,
      business_date  TEXT NOT NULL,
      created_at     TEXT NOT NULL,
      picked_up_at   TEXT,
      delivered_at   TEXT
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS ix_boundary_event_outbox_pending
    ON boundary_event_outbox(delivered_at, picked_up_at, restaurant_id, id)
  ''');
}

/// Phase 10a.5 — `realtime_subscription_watermark` per-device cache.
///
/// Holds the most recent `event_id` the client has seen on each
/// `(operator_id, topic)` pair. The realtime subscription advances the
/// row inside the same transaction that surfaces the event to the UI;
/// on reconnect, the subscription picks the newest watermark across
/// topics and forwards it as `?last_event_id=...` so the proxy route
/// replays anything missed during the disconnect window. V1 watermark
/// is per-device only — cross-device sync lands in Phase 10b.
Future<void> _migrateToV26(Database db) async {
  await _createTableIfNotExists(db, 'realtime_subscription_watermark', '''
    CREATE TABLE realtime_subscription_watermark (
      operator_id  TEXT NOT NULL,
      topic        TEXT NOT NULL,
      event_id     TEXT NOT NULL,
      occurred_at  TEXT NOT NULL,
      updated_at   TEXT NOT NULL,
      PRIMARY KEY (operator_id, topic)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS ix_realtime_subscription_watermark_recent
    ON realtime_subscription_watermark(operator_id, occurred_at DESC)
  ''');
}

Future<void> _migrateToV27(Database db) async {
  for (final column in <String>[
    'business_timing_profile_id TEXT',
    'business_timing_profile_version_id TEXT',
    'service_period_key TEXT',
  ]) {
    final name = column.split(' ').first;
    if (!await _columnExists(db, 'shift_records', name)) {
      await db.execute('ALTER TABLE shift_records ADD COLUMN $column');
    }
    if (!await _columnExists(db, 'open_shift_snapshots', name)) {
      await db.execute('ALTER TABLE open_shift_snapshots ADD COLUMN $column');
    }
  }
}

Future<void> _migrateToV28(Database db) async {
  await _createTableIfNotExists(db, 'active_business_scopes', '''
    CREATE TABLE active_business_scopes (
      user_id            TEXT PRIMARY KEY NOT NULL,
      scope_id           TEXT NOT NULL,
      scope_type         TEXT NOT NULL,
      operator_id        TEXT NOT NULL,
      location_id        TEXT,
      parent_scope_id    TEXT,
      label              TEXT NOT NULL,
      business_timezone  TEXT,
      sort_path          TEXT,
      updated_at         TEXT NOT NULL
    )
  ''');
}

/// W2.A — push-extended inbox tracks read state per notification.
///
/// Adds the `read_at` column to `app_notifications` so the bell badge
/// can count unread rows, the inbox can render read/unread visual
/// treatment, and the "Mark all as read" action has a place to land
/// the timestamp. Nullable + additive: legacy rows surface as unread
/// and the existing emit + dedupe path is unchanged.
Future<void> _migrateToV30(Database db) async {
  if (!await _columnExists(db, 'app_notifications', 'read_at')) {
    await db.execute(
      'ALTER TABLE app_notifications ADD COLUMN read_at TEXT',
    );
  }
}

/// Theme H#4 / H#5 — wage_role_rows server-truth columns.
///
/// Adds the 9 columns the proxy already emits but the SQLite DAO was
/// dropping on the floor. `server_id` mirrors
/// `public.wage_role_rows.wage_role_row_id` (UUID) so per-row writes can
/// roundtrip without colliding with the legacy autoincrement `id`. The
/// trailing UNIQUE index on `(restaurant_id, server_id) WHERE server_id
/// IS NOT NULL` lets local-only seeded rows (server_id=NULL) coexist
/// with mirrored rows.
Future<void> _migrateToV31(Database db) async {
  if (!await _columnExists(db, 'wage_role_rows', 'server_id')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN server_id TEXT',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'job_code')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN job_code TEXT',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'vendor_id')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN vendor_id TEXT',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'vendor_role_id')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN vendor_role_id TEXT',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'source')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN source TEXT',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'is_active')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN is_active INTEGER',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'effective_at')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN effective_at TEXT',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'metadata')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN metadata TEXT',
    );
  }
  if (!await _columnExists(db, 'wage_role_rows', 'updated_by')) {
    await db.execute(
      'ALTER TABLE wage_role_rows ADD COLUMN updated_by TEXT',
    );
  }
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_wage_role_rows_server_id '
    'ON wage_role_rows (restaurant_id, server_id) '
    'WHERE server_id IS NOT NULL',
  );
}

/// Wave 2 MO-2 — mobile-side `manual_cover_entries` overlay.
///
/// Backs the mobile Covers Setup section on the Settings → Setup tab.
/// Each row is one operator-entered cover count for a specific
/// (restaurant, business date, daypart). Mirrors the daypart shape of
/// `public.data_accuracy_settings.covers_manual_entries` (jsonb) so a
/// follow-up write-through slice can fan rows into the canonical
/// settings payload without re-keying.
///
/// Additive only — legacy rows in other tables are untouched.
Future<void> _migrateToV34(Database db) async {
  if (!await _tableExists(db, 'manual_cover_entries')) {
    await db.execute('''
      CREATE TABLE manual_cover_entries (
        restaurant_id  TEXT NOT NULL,
        business_date  TEXT NOT NULL,
        daypart        TEXT NOT NULL,
        covers         INTEGER NOT NULL,
        recorded_at    TEXT NOT NULL,
        PRIMARY KEY (restaurant_id, business_date, daypart)
      )
    ''');
    await db.execute('''
      CREATE INDEX ix_manual_cover_entries_recent
      ON manual_cover_entries(restaurant_id, business_date DESC)
    ''');
  }
}

/// Per-Daypart V1 Slice 1 — per-period data layer foundation.
///
/// Adds the two new child tables, the `wage_at_lock_time_json` column
/// on `weekly_plan_snapshots`, and the five per-shift per-period target
/// stamp columns on `shift_records`. All additions are additive +
/// nullable for backward compatibility with legacy rows; demo reseed
/// regenerates closed shifts under the new schema with the stamps
/// populated.
///
/// Schema:
/// - `target_cycle_dayparts(cycle_id, service_period_id, ...)` — one row
///   per (cycle, period). Carries target CPLH/SPLH/PPA + OPZ floor/ceiling +
///   `cover_count` (per-period candidate cover total at compute time, used
///   for cover-weighted whole-day pool rollup).
/// - `weekly_plan_snapshot_day_dayparts(snapshot_id, business_date,
///   service_period_id, ...)` — one row per (snapshot, day, period).
///   Carries forecast covers/sales + required FOH/BOH hours + theoretical
///   FOH/BOH dollars (wages stay whole-day per Design Rule 5).
/// - `weekly_plan_snapshots.wage_at_lock_time_json` — JSON stamp of
///   `{"foh_wage", "boh_wage", "blended_wage"}` at lock time. Audit
///   checks compare locked dollars against THIS column, not against
///   `ActiveTargetProfile` current wages (Design Rule 8).
/// - `shift_records.daypart_target_*` — per-shift per-period target
///   stamps at close time. Demo reseed populates them uniformly;
///   production behavior is "closed truth retains the stamp from its
///   close time" per Promise 2.
Future<void> _migrateToV36(Database db) async {
  // target_cycle_dayparts ----------------------------------------------------
  if (!await _tableExists(db, 'target_cycle_dayparts')) {
    await db.execute('''
      CREATE TABLE target_cycle_dayparts (
        cycle_id           TEXT NOT NULL,
        service_period_id  TEXT NOT NULL,
        target_cplh        REAL NOT NULL,
        target_splh        REAL NOT NULL,
        target_ppa         REAL NOT NULL,
        opz_floor_cplh     REAL NOT NULL,
        opz_ceiling_cplh   REAL NOT NULL,
        cover_count        INTEGER NOT NULL,
        created_at         TEXT NOT NULL,
        PRIMARY KEY (cycle_id, service_period_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX ix_target_cycle_dayparts_cycle
      ON target_cycle_dayparts(cycle_id)
    ''');
  }

  // weekly_plan_snapshot_day_dayparts ---------------------------------------
  if (!await _tableExists(db, 'weekly_plan_snapshot_day_dayparts')) {
    await db.execute('''
      CREATE TABLE weekly_plan_snapshot_day_dayparts (
        snapshot_id              TEXT NOT NULL,
        business_date            TEXT NOT NULL,
        service_period_id        TEXT NOT NULL,
        forecast_covers          INTEGER NOT NULL,
        forecast_sales           REAL NOT NULL,
        required_foh_hours       REAL NOT NULL,
        required_boh_hours       REAL NOT NULL,
        theoretical_foh_dollars  REAL NOT NULL,
        theoretical_boh_dollars  REAL NOT NULL,
        created_at               TEXT NOT NULL,
        PRIMARY KEY (snapshot_id, business_date, service_period_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX ix_weekly_plan_snapshot_day_dayparts_snapshot
      ON weekly_plan_snapshot_day_dayparts(snapshot_id)
    ''');
  }

  // weekly_plan_snapshots.wage_at_lock_time_json ----------------------------
  if (!await _columnExists(
    db,
    'weekly_plan_snapshots',
    'wage_at_lock_time_json',
  )) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots '
      'ADD COLUMN wage_at_lock_time_json TEXT',
    );
  }

  // shift_records per-shift per-period target stamps -------------------------
  // All five additive + nullable; demo reseed populates them.
  const perShiftColumns = [
    'daypart_target_cplh',
    'daypart_target_splh',
    'daypart_target_ppa',
    'daypart_opz_floor_cplh',
    'daypart_opz_ceiling_cplh',
  ];
  for (final col in perShiftColumns) {
    if (!await _columnExists(db, 'shift_records', col)) {
      await db.execute('ALTER TABLE shift_records ADD COLUMN $col REAL');
    }
  }
}

/// Per-Daypart V1 Slice 1.5 — drop the `shift_close_authority` +
/// `local_close_fallback` columns from `restaurant_timing_configs`.
///
/// Operator decision 2026-05-15: the close-authority toggle is now
/// auto-derived per shift from the per-vendor `CloseAuthorityCapability`
/// lookup + the operator's `business_day_start_local_time` fallback.
/// There is no operator-facing setting any more.
///
/// SQLite supports `ALTER TABLE … DROP COLUMN` from 3.35 onward. The
/// sqflite_common_ffi bundle used in the demo desktop build is well
/// past that. Guard each `DROP COLUMN` with a `_columnExists` check so
/// the migration is idempotent on partially-upgraded demo DBs.
Future<void> _migrateToV35(Database db) async {
  if (await _columnExists(
    db,
    'restaurant_timing_configs',
    'shift_close_authority',
  )) {
    await db.execute(
      'ALTER TABLE restaurant_timing_configs '
      'DROP COLUMN shift_close_authority',
    );
  }
  if (await _columnExists(
    db,
    'restaurant_timing_configs',
    'local_close_fallback',
  )) {
    await db.execute(
      'ALTER TABLE restaurant_timing_configs '
      'DROP COLUMN local_close_fallback',
    );
  }
}

/// Theme H#6 — weekly_plan_snapshots lifecycle columns.
///
/// Adds the 5 server-truth fields the proxy emits but the SQLite model
/// previously dropped: `is_active`, `supersedes_snapshot_id`,
/// `lock_reason`, `locked_by_user_id`, `metadata`. All nullable so
/// legacy mobile-only snapshots remain valid.
Future<void> _migrateToV33(Database db) async {
  if (!await _columnExists(db, 'weekly_plan_snapshots', 'is_active')) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots ADD COLUMN is_active INTEGER',
    );
  }
  if (!await _columnExists(
    db,
    'weekly_plan_snapshots',
    'supersedes_snapshot_id',
  )) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots '
      'ADD COLUMN supersedes_snapshot_id TEXT',
    );
  }
  if (!await _columnExists(db, 'weekly_plan_snapshots', 'lock_reason')) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots ADD COLUMN lock_reason TEXT',
    );
  }
  if (!await _columnExists(
    db,
    'weekly_plan_snapshots',
    'locked_by_user_id',
  )) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots ADD COLUMN locked_by_user_id TEXT',
    );
  }
  if (!await _columnExists(db, 'weekly_plan_snapshots', 'metadata')) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots ADD COLUMN metadata TEXT',
    );
  }
}

/// Theme H#7 — DAS service-period settings persistent cache.
///
/// Previously the proxy's `data_accuracy_service_period_settings` rows
/// only lived in volatile in-memory state on
/// `PostgresShiftRecordToMobileSync`. This migration adds a persistent
/// SQLite mirror keyed `(restaurant_id, service_period_key,
/// effective_at_business_date)` so app-start can rehydrate honest
/// per-period covers/wage source resolution before the first sweep.
Future<void> _migrateToV32(Database db) async {
  if (!await _tableExists(
    db,
    'data_accuracy_service_period_settings_cache',
  )) {
    await db.execute('''
      CREATE TABLE data_accuracy_service_period_settings_cache (
        restaurant_id              TEXT NOT NULL,
        service_period_key         TEXT NOT NULL,
        effective_at_business_date TEXT NOT NULL,
        id                         TEXT NOT NULL,
        operator_id                TEXT NOT NULL,
        location_id                TEXT NOT NULL,
        covers_source              TEXT NOT NULL,
        wage_source                TEXT NOT NULL,
        created_at                 TEXT NOT NULL,
        updated_at                 TEXT NOT NULL,
        updated_by                 TEXT,
        cached_at                  TEXT NOT NULL,
        PRIMARY KEY (
          restaurant_id,
          service_period_key,
          effective_at_business_date
        )
      )
    ''');
    await db.execute('''
      CREATE INDEX ix_das_service_period_settings_cache_lookup
      ON data_accuracy_service_period_settings_cache (
        restaurant_id,
        service_period_key,
        effective_at_business_date DESC
      )
    ''');
  }
}

Future<void> _migrateToV29(Database db) async {
  if (!await _columnExists(
    db,
    'weekly_plan_snapshots',
    'forecast_context_id',
  )) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots ADD COLUMN forecast_context_id TEXT',
    );
  }
  if (!await _columnExists(
    db,
    'weekly_plan_snapshots',
    'forecast_context_json',
  )) {
    await db.execute(
      'ALTER TABLE weekly_plan_snapshots ADD COLUMN forecast_context_json TEXT',
    );
  }
}

Future<void> _migrateToV24(Database db) async {
  await db.execute(
    '''
    UPDATE week_records
    SET
      target_calibration_window_start = (
        SELECT calibration_window_start
        FROM target_cycles
        WHERE restaurant_id = ? AND deactivated_at IS NULL
        ORDER BY created_at DESC
        LIMIT 1
      ),
      target_calibration_window_end = (
        SELECT calibration_window_end
        FROM target_cycles
        WHERE restaurant_id = ? AND deactivated_at IS NULL
        ORDER BY created_at DESC
        LIMIT 1
      )
    WHERE restaurant_id = ?
      AND (
        target_calibration_window_start IS NULL OR
        target_calibration_window_end IS NULL
      )
  ''',
    [DemoScope.restaurantId, DemoScope.restaurantId, DemoScope.restaurantId],
  );
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
    db,
    MockIntegrationReplaySeed.output,
  );
}

Future<void> _migrateToV12(Database db) async {
  // Add business_date column to shift_records if missing.
  if (!await _columnExists(db, 'shift_records', 'business_date')) {
    await db.execute('ALTER TABLE shift_records ADD COLUMN business_date TEXT');
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

Future<void> _migrateToV14(Database db) async {
  await _createTableIfNotExists(db, 'wage_role_rows', '''
    CREATE TABLE wage_role_rows (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      restaurant_id   TEXT NOT NULL,
      role_name       TEXT NOT NULL,
      labor_bucket    TEXT NOT NULL,
      hourly_rate     REAL NOT NULL,
      weighted_hours  REAL NOT NULL,
      UNIQUE(restaurant_id, role_name)
    )
  ''');
}

Future<void> _migrateToV15(Database db) async {
  await _createTableIfNotExists(db, 'target_cycles', '''
    CREATE TABLE target_cycles (
      cycle_id                 TEXT PRIMARY KEY NOT NULL,
      restaurant_id            TEXT NOT NULL,
      source                   TEXT NOT NULL,
      effective_start          TEXT NOT NULL,
      effective_end            TEXT NOT NULL,
      calibration_window_start TEXT NOT NULL,
      calibration_window_end   TEXT NOT NULL,
      target_cplh              REAL NOT NULL,
      target_splh              REAL NOT NULL,
      target_ppa               REAL NOT NULL,
      foh_wage                 REAL NOT NULL,
      boh_wage                 REAL NOT NULL,
      opz_floor_cplh           REAL NOT NULL,
      opz_ceiling_cplh         REAL NOT NULL,
      manager_override_used    INTEGER NOT NULL DEFAULT 0,
      manager_override_at      TEXT,
      admin_replaced_at        TEXT,
      created_at               TEXT NOT NULL,
      deactivated_at           TEXT
    )
  ''');
}

Future<void> _migrateToV16(Database db) async {
  await _createTableIfNotExists(db, 'weekly_plan_snapshots', '''
    CREATE TABLE weekly_plan_snapshots (
      snapshot_id                    TEXT PRIMARY KEY NOT NULL,
      restaurant_id                  TEXT NOT NULL,
      week_key                       TEXT NOT NULL,
      week_start_date                TEXT NOT NULL,
      week_end_date                  TEXT NOT NULL,
      target_cycle_id                TEXT NOT NULL,
      forecast_covers                INTEGER NOT NULL,
      forecast_sales                 REAL NOT NULL,
      required_foh_hours             INTEGER NOT NULL,
      required_boh_hours             INTEGER NOT NULL,
      theoretical_foh_labor_dollars  REAL NOT NULL,
      theoretical_boh_labor_dollars  REAL NOT NULL,
      theoretical_labor_pct          REAL NOT NULL,
      target_blended_wage            REAL NOT NULL,
      covers_source                  TEXT NOT NULL,
      sales_source                   TEXT NOT NULL,
      generated_at                   TEXT NOT NULL,
      locked_at                      TEXT NOT NULL,
      day_rows_json                  TEXT NOT NULL,
      UNIQUE(restaurant_id, week_key)
    )
  ''');
}

Future<void> _migrateToV17(Database db) async {
  await _createTableIfNotExists(db, 'benchmark_selection_summaries', '''
    CREATE TABLE benchmark_selection_summaries (
      summary_id           TEXT PRIMARY KEY NOT NULL,
      restaurant_id        TEXT NOT NULL,
      target_cycle_id      TEXT NOT NULL,
      source_type          TEXT NOT NULL,
      selected_shift_count INTEGER NOT NULL,
      range_quality_label  TEXT NOT NULL,
      range_quality_message TEXT NOT NULL,
      created_at           TEXT NOT NULL,
      UNIQUE(target_cycle_id)
    )
  ''');
}

Future<void> _migrateToV18(Database db) async {
  await _createTableIfNotExists(db, 'restaurant_timing_configs', '''
    CREATE TABLE restaurant_timing_configs (
      restaurant_id                    TEXT PRIMARY KEY NOT NULL,
      business_day_start_local_time    TEXT NOT NULL,
      week_start_day                   INTEGER NOT NULL,
      service_period_definitions_json  TEXT NOT NULL,
      shift_close_authority            TEXT NOT NULL,
      local_close_fallback             TEXT,
      created_at                       TEXT NOT NULL,
      updated_at                       TEXT NOT NULL
    )
  ''');
  // Backfill demo timing config if restaurant exists but timing row doesn't.
  final existing = await db.query(
    'restaurant_timing_configs',
    where: 'restaurant_id = ?',
    whereArgs: [DemoScope.restaurantId],
  );
  if (existing.isEmpty) {
    final restaurants = await db.query(
      'restaurant_locations',
      where: 'restaurant_id = ?',
      whereArgs: [DemoScope.restaurantId],
    );
    if (restaurants.isNotEmpty) {
      final now = nowIsoUtc();
      final demoServicePeriods = [
        {
          'id': 'lunch',
          'label': 'Lunch',
          'short_label': 'L',
          'sort_order': 1,
          'start_local_time': '11:00',
          'end_local_time': '15:00',
          'rolls_past_midnight': false,
          'applicable_days': [1, 2, 3, 4, 5],
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
      await db.insert('restaurant_timing_configs', {
        'restaurant_id': DemoScope.restaurantId,
        'business_day_start_local_time': '04:00',
        'week_start_day': DateTime.monday,
        'service_period_definitions_json': jsonEncode(demoServicePeriods),
        'shift_close_authority': 'app_local_cutoff_fallback',
        'local_close_fallback': '04:00',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
}

Future<void> _migrateToV19(Database db) async {
  await _createTableIfNotExists(db, 'app_notifications', '''
    CREATE TABLE app_notifications (
      notification_id  TEXT PRIMARY KEY NOT NULL,
      restaurant_id    TEXT NOT NULL,
      type             TEXT NOT NULL,
      event_key        TEXT NOT NULL,
      title            TEXT NOT NULL,
      body             TEXT NOT NULL,
      business_date    TEXT NOT NULL,
      created_at       TEXT NOT NULL,
      UNIQUE(restaurant_id, event_key)
    )
  ''');
}

Future<void> _migrateToV20(Database db) async {
  if (!await _columnExists(db, 'shift_records', 'snapshot_blended_wage')) {
    await db.execute(
      'ALTER TABLE shift_records ADD COLUMN snapshot_blended_wage REAL',
    );
  }
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
  await _seedDemoActiveTargetProfile(
    db,
    businessDate: MockIntegrationReplaySeed.defaultBusinessDate,
  );

  // ── 5. Backfill legacy rows with current target state + provenance ─────
  final profile = await _loadSeedAuthorityProfile(
    db,
    businessDate: MockIntegrationReplaySeed.defaultBusinessDate,
  );
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
    'created_at': nowIsoUtc(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  await db.execute(
    '''
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
  ''',
    [
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
    ],
  );
  await db.execute(
    '''
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
  ''',
    [
      profile.sourceType,
      profile.targetCPLH,
      profile.targetSPLH,
      profile.targetPPA,
      profile.fohWage,
      profile.bohWage,
      profile.theoreticalFohLaborPct,
      profile.theoreticalBohLaborPct,
      DemoScope.restaurantId,
    ],
  );

  // ── 6. Provenance repair for partially migrated rows ─────────────────
  await db.execute(
    '''
    UPDATE shift_records SET
      target_profile_id = ?,
      target_profile_version_id = ?
    WHERE restaurant_id = ?
      AND target_cplh IS NOT NULL
      AND (target_profile_id IS NULL OR target_profile_version_id IS NULL)
  ''',
    [profile.targetProfileId, compatVersionId, DemoScope.restaurantId],
  );
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
    if (!await _columnExists(
      db,
      'baseline_selected_records',
      'restaurant_id',
    )) {
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

Future<bool> _tableExists(Database db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [table],
  );
  return rows.isNotEmpty;
}

Future<bool> _columnExists(Database db, String table, String column) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.any((r) => r['name'] == column);
}

Future<void> _dedupeConnectorConfigs(Database db) async {
  final duplicates = await db.rawQuery('''
    SELECT restaurant_id, source_type
    FROM connector_configs
    GROUP BY restaurant_id, source_type
    HAVING COUNT(*) > 1
  ''');

  for (final duplicate in duplicates) {
    final restaurantId = duplicate['restaurant_id'] as String;
    final sourceType = duplicate['source_type'] as String;
    final rows = await db.rawQuery(
      '''
      SELECT connector_id
      FROM connector_configs
      WHERE restaurant_id = ? AND source_type = ?
      ORDER BY updated_at DESC, rowid DESC
    ''',
      [restaurantId, sourceType],
    );

    for (final row in rows.skip(1)) {
      await db.delete(
        'connector_configs',
        where: 'connector_id = ?',
        whereArgs: [row['connector_id']],
      );
    }
  }
}
