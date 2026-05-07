// Phase 7.55o.6 — SQLite schema creation helpers.
//
// Part of sqlite_database.dart. Owns the initial-create table SQL
// (`_createAllTables`) and the schema helper `_createTableIfNotExists`.
// No schema text, column default, seed row, or index shape is changed
// from the pre-split file — this is a structural move.

part of 'sqlite_database.dart';

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
      business_timing_profile_id TEXT,
      business_timing_profile_version_id TEXT,
      service_period_key         TEXT,
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
      theoretical_boh_labor_pct  REAL,
      snapshot_blended_wage      REAL
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
      locked_required_foh_hours  INTEGER,
      locked_required_boh_hours  INTEGER,
      month_dollar_impact        REAL,
      sixty_day_dollar_impact    REAL,
      closed_at                  TEXT,
      target_calibration_window_start TEXT,
      target_calibration_window_end   TEXT,
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
      business_timing_profile_id TEXT,
      business_timing_profile_version_id TEXT,
      service_period_key      TEXT,
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

  // ── Wage generator layer ───────────────────────────────────────────────
  // Theme H#4 / H#5: server-truth fields mirrored from the proxy:
  //   - server_id mirrors public.wage_role_rows.wage_role_row_id (UUID)
  //   - job_code / vendor_id / vendor_role_id are vendor identifiers
  //   - source / is_active / effective_at / metadata / updated_by are
  //     emitted by the proxy on every wage-role-rows pull
  // server_id is nullable so legacy / locally-seeded rows still work.
  await db.execute('''
    CREATE TABLE wage_role_rows (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      server_id       TEXT,
      restaurant_id   TEXT NOT NULL,
      role_name       TEXT NOT NULL,
      labor_bucket    TEXT NOT NULL,
      hourly_rate     REAL NOT NULL,
      weighted_hours  REAL NOT NULL,
      job_code        TEXT,
      vendor_id       TEXT,
      vendor_role_id  TEXT,
      source          TEXT,
      is_active       INTEGER,
      effective_at    TEXT,
      metadata        TEXT,
      updated_by      TEXT,
      UNIQUE(restaurant_id, role_name)
    )
  ''');
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_wage_role_rows_server_id '
    'ON wage_role_rows (restaurant_id, server_id) '
    'WHERE server_id IS NOT NULL',
  );

  // ── Target cycle layer ────────────────────────────────────────────────
  await db.execute('''
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

  // ── Weekly plan snapshot layer ────────────────────────────────────────
  // Theme H#6: lifecycle fields mirrored from server truth so the
  // closed-truth `WeeklyPlanSnapshot` model can roundtrip the
  // `is_active`, `supersedes_snapshot_id`, `lock_reason`,
  // `locked_by_user_id`, and `metadata` columns the proxy already emits.
  // All five are nullable so legacy mobile-only snapshots stay valid.
  await db.execute('''
    CREATE TABLE weekly_plan_snapshots (
      snapshot_id                    TEXT PRIMARY KEY NOT NULL,
      restaurant_id                  TEXT NOT NULL,
      week_key                       TEXT NOT NULL,
      week_start_date                TEXT NOT NULL,
      week_end_date                  TEXT NOT NULL,
      target_cycle_id                TEXT NOT NULL,
      forecast_context_id            TEXT,
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
      forecast_context_json          TEXT,
      day_rows_json                  TEXT NOT NULL,
      is_active                      INTEGER,
      supersedes_snapshot_id         TEXT,
      lock_reason                    TEXT,
      locked_by_user_id              TEXT,
      metadata                       TEXT,
      UNIQUE(restaurant_id, week_key)
    )
  ''');

  // ── Benchmark selection summary layer (7.55l.8c) ─────────────────────
  await db.execute('''
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

  // ── Restaurant timing config layer (7.55n.1) ─────────────────────────
  await db.execute('''
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

  // ── Passive app notifications (7.55p.4d, +W2.A read tracking) ─────────
  // `read_at` is nullable: NULL means unread; a non-NULL ISO UTC value
  // is the moment the operator marked the notification (or all of them)
  // read. The bell badge counts rows WHERE read_at IS NULL.
  await db.execute('''
    CREATE TABLE app_notifications (
      notification_id  TEXT PRIMARY KEY NOT NULL,
      restaurant_id    TEXT NOT NULL,
      type             TEXT NOT NULL,
      event_key        TEXT NOT NULL,
      title            TEXT NOT NULL,
      body             TEXT NOT NULL,
      business_date    TEXT NOT NULL,
      created_at       TEXT NOT NULL,
      read_at          TEXT,
      UNIQUE(restaurant_id, event_key)
    )
  ''');

  // ── HARD-H — boundary monitor durable backlog ────────────────────────
  // Per-device backlog used by `CurrentStateBoundaryMonitor` /
  // `BoundaryMonitorSupervisor` so a foreground crash mid-fire does
  // not drop a business-date rollover. The Flutter app cannot reach
  // Postgres directly (Hard Promise #7 in CLAUDE.md), so this local
  // SQLite table is the client-side analogue of the server-side
  // `event_outbox` rollover topic. The monitor's purpose is local UI
  // refresh, so per-device durability is sufficient.
  //
  // `picked_up_at` mirrors the Postgres `event_outbox.picked_up_at`
  // claim marker. The drain stamps it inside a transaction so two
  // concurrent `drainBacklog` calls (e.g. the unawaited startup drain
  // racing the resume drain) never read the same row twice. A
  // claimant that crashes between claim + mark-delivered leaves a
  // stale `picked_up_at`; the reclaim window in
  // `SqliteBoundaryEventOutbox` lets the next drain re-claim it.
  await db.execute('''
    CREATE TABLE boundary_event_outbox (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      restaurant_id  TEXT NOT NULL,
      business_date  TEXT NOT NULL,
      created_at     TEXT NOT NULL,
      picked_up_at   TEXT,
      delivered_at   TEXT
    )
  ''');
  // Drain claim leads with delivered_at so the index probe skips
  // already-published rows; picked_up_at follows so the predicate
  // `delivered_at IS NULL AND (picked_up_at IS NULL OR picked_up_at < ?)`
  // can fold into the index walk; the trailing `(restaurant_id, id)`
  // keeps the oldest-first replay contract per location.
  await db.execute('''
    CREATE INDEX ix_boundary_event_outbox_pending
    ON boundary_event_outbox(delivered_at, picked_up_at, restaurant_id, id)
  ''');

  // ── Realtime subscription watermark (10a.5) ──────────────────────────
  // Per-device cache of the most recent `event_id` the realtime client
  // has surfaced on each `(operator_id, topic)` pair. The subscription
  // advances the row inside the same transaction that delivers the
  // event to the UI; on reconnect, the subscription picks the newest
  // watermark across topics and forwards it as `?last_event_id=...`
  // so the proxy route replays anything missed during the disconnect
  // window. V1 is per-device only — cross-device sync lands in 10b.
  await db.execute('''
    CREATE TABLE realtime_subscription_watermark (
      operator_id  TEXT NOT NULL,
      topic        TEXT NOT NULL,
      event_id     TEXT NOT NULL,
      occurred_at  TEXT NOT NULL,
      updated_at   TEXT NOT NULL,
      PRIMARY KEY (operator_id, topic)
    )
  ''');
  // Reconnect hydrate reads the newest watermark per operator first —
  // the trailing DESC on occurred_at lets the index serve that probe
  // without an extra sort.
  await db.execute('''
    CREATE INDEX ix_realtime_subscription_watermark_recent
    ON realtime_subscription_watermark(operator_id, occurred_at DESC)
  ''');

  // ── DAS service-period settings cache (Theme H#7) ────────────────────
  // Mirrors `public.data_accuracy_service_period_settings` keyed rows.
  // Previously kept only in volatile in-memory state on
  // PostgresShiftRecordToMobileSync; this cache lets app-start rehydrate
  // the most recent server pull so honest covers/wage source resolution
  // works before the first sweep completes.
  //
  // Composite key matches the proxy emit shape:
  //   (restaurant_id, service_period_key, effective_at_business_date)
  // — the lookup picks the most recent row at-or-before the business
  // date when resolving sources.
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

Future<void> _createTableIfNotExists(
  Database db,
  String table,
  String createSql,
) async {
  if (!await _tableExists(db, table)) {
    await db.execute(createSql);
  }
}
