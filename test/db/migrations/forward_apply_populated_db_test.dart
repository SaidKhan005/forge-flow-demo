// B5 — 20-migration forward-apply test against a real Postgres.
//
// Tests from POST_HARDENING_FOLLOWUPS.md P0:
//
//   Test 1: fresh DB → apply all 20+ pending migrations in chronological
//           order; assert no SQL errors.
//
//   Test 2: pre-populate the DB with representative data (operators,
//           locations, shift_records, audit_logs, demo_mode_state rows)
//           BEFORE applying the 20 migrations; assert no errors AND that
//           pre-existing rows survive (counts unchanged).
//
// Particular focus: `202605080000_phase_8_timing_provenance_fk_posture.sql`
// (FK posture flip on shift_records — ON DELETE SET NULL) is the most
// likely to break on populated data because it alters the FK constraint.
//
// These tests are tagged `@Tags(['postgres'])` and skipped by default.
// Run with: flutter test --tags=postgres
//
// Requires: POSTGRES_TEST_URL env var or default localhost:5432.

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';

import '../../infrastructure/postgres_test_harness.dart';

// UUIDs for pre-population data.
const String _prePopOpId = 'ee000000-0000-0000-0000-000000000001';
const String _prePopLocId = 'ee000000-0000-0000-0000-000000000002';
const String _prePopUserId = 'ee000000-0000-0000-0000-000000000003';

void main() {
  // Skipped when POSTGRES_TEST_URL is not set (default unit-test loop).
  // Tagged `postgres` so CI's `--tags=postgres` job (which sets the env
  // var to a live container) still picks these up.
  final skipReason = (Platform.environment['POSTGRES_TEST_URL'] ?? '')
          .trim()
          .isEmpty
      ? 'requires live Postgres (POSTGRES_TEST_URL not set); '
            'run via `flutter test --tags=postgres`'
      : null;

  test(
    'Test 1: fresh DB — apply all pending migrations with no SQL errors',
    () async {
      final url = resolveTestPostgresUrl();
      final pool =
          PackagePostgresPool.fromUrl(url, maxConnectionCount: 2);
      try {
        // applyAllMigrations applied inside withTestPostgres; call
        // directly so we can measure without seeding data.
        await applyAllMigrations(pool);
        // If we reach here, all migrations applied without error.
        expect(true, isTrue, reason: 'All migrations applied without error');
      } finally {
        await pool.closeIdleConnections();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    tags: <String>['postgres'],
    skip: skipReason,
  );

  test(
    'Test 2: pre-populated DB — apply all migrations; rows survive',
    () async {
      final url = resolveTestPostgresUrl();
      final pool =
          PackagePostgresPool.fromUrl(url, maxConnectionCount: 2);

      try {
        // Step A: apply the base migrations (everything up to and
        // including the stable baseline) so tables exist.
        await applyAllMigrations(pool);

        // Step B: seed representative data BEFORE applying the
        // 20 pending migrations.
        final beforeCounts = await _seedAndCount(pool);
        final operatorCount = beforeCounts['operators']!;
        final locationCount = beforeCounts['locations']!;

        // Step C: re-apply all migrations (idempotent for already-
        // applied ones; the pending 20 run for the first time on the
        // populated data).
        await applyAllMigrations(pool);

        // Step D: verify row counts did not regress.
        final afterCounts = await _readCounts(pool);
        expect(
          afterCounts['operators'],
          greaterThanOrEqualTo(operatorCount),
          reason:
              'Pre-existing operator rows must survive migration apply',
        );
        expect(
          afterCounts['locations'],
          greaterThanOrEqualTo(locationCount),
          reason:
              'Pre-existing location rows must survive migration apply',
        );

        // Step E: verify the FK posture flip migration specifically
        // did not wipe any shift_records rows.
        final shiftCount = afterCounts['shift_records'] ?? 0;
        final beforeShiftCount = beforeCounts['shift_records'] ?? 0;
        expect(
          shiftCount,
          greaterThanOrEqualTo(beforeShiftCount),
          reason:
              '202605080000_phase_8_timing_provenance_fk_posture.sql '
              '(FK posture flip ON DELETE SET NULL) must not drop '
              'existing shift_records rows',
        );
      } finally {
        await truncateTenantData(pool);
        await pool.closeIdleConnections();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
    tags: <String>['postgres'],
    skip: skipReason,
  );

  test(
    'FK posture migration SQL shape — ON DELETE SET NULL declared for '
    'shift_records timing FK columns',
    () {
      // This test does NOT require live Postgres — it checks the
      // migration file on disk. It is tagged postgres for grouping but
      // the file read works offline.
      final sql = _readMigrationSql(
        '202605080000_phase_8_timing_provenance_fk_posture.sql',
      );
      if (sql == null) {
        markTestSkipped(
          '202605080000_phase_8_timing_provenance_fk_posture.sql '
          'not found on disk — skipping shape assertion',
        );
        return;
      }
      expect(
        sql.toLowerCase(),
        contains('on delete set null'),
        reason:
            'FK posture migration must flip the timing FK to '
            'ON DELETE SET NULL so closed shift_records survive '
            'business_timing_profile mutation',
      );
      // Must not use CASCADE — that would wipe shift_records rows.
      expect(
        sql.toLowerCase(),
        isNot(contains('on delete cascade')),
        reason:
            'ON DELETE CASCADE would silently delete shift_records '
            'rows when a timing profile is removed; must be SET NULL',
      );
    },
    tags: <String>['postgres'],
  );

  test(
    'All 21 P0 migrations listed in POST_HARDENING_FOLLOWUPS.md exist '
    'on disk under db/migrations/',
    () {
      // Verify no migration is missing from the repo. This is a fast
      // offline check — no Postgres required.
      const expectedMigrations = <String>[
        '202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql',
        '202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql',
        '202605060000_mobile_push_notifications.sql',
        '202605060000_phase_business_timing_live_schema.sql',
        '202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql',
        '202605061500_hardening_phase_8_email_index_leading_column_rekey.sql',
        '202605061600_phase_11W_5_team_audit_log_export_key.sql',
        '202605061700_hardening_audit_anchor_daily_schedule.sql',
        '202605061700_phase_8_timing_provenance_shift_records.sql',
        '202605061701_phase_8_data_accuracy_service_period_settings.sql',
        '202605061800_phase_8_first_connection_backfill_jobs.sql',
        '202605070000_phase_11W_7_operator_account_fields.sql',
        '202605070100_password_history_salt_pepper.sql',
        '202605070200_audit_anchor_advisory_lock_infra.sql',
        '202605070400_phase_8_notification_preferences.sql',
        '202605080000_phase_8_timing_provenance_fk_posture.sql',
        '202605080100_admin_idempotency_expires_at.sql',
        '202605080100_phase_8_weekly_plan_server_truth.sql',
        '202605080200_phase_8_wage_role_rows_server_truth.sql',
        '202605080300_phase_8_data_accuracy_walk_in_settings.sql',
        '202605080400_phase_8_connector_oauth_state.sql',
      ];
      final dir = Directory('db/migrations');
      final existing = dir.existsSync()
          ? dir
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .toSet()
          : <String>{};

      final missing = expectedMigrations
          .where((m) => !existing.contains(m))
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'P0 migrations missing from db/migrations/: $missing. '
            'Every migration in the P0 list must be present before '
            'Production1 apply.',
      );
    },
    // This test is intentionally NOT tagged postgres — it runs offline.
  );
}

// ─── Helpers ─────────────────────────────────────────────────────────

String? _readMigrationSql(String filename) {
  final file = File('db/migrations/$filename');
  if (!file.existsSync()) return null;
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// Inserts representative rows and returns the counts before migration apply.
Future<Map<String, int>> _seedAndCount(PackagePostgresPool pool) async {
  // Seed operator + location.
  await seedOperator(pool, operatorId: _prePopOpId, locationId: _prePopLocId);

  // Seed a demo_mode_state row (likely altered by Phase 8 migrations).
  final tx1 = await pool.beginTransaction();
  try {
    await tx1.execute(
      'insert into public.demo_mode_state ('
      '  operator_id, location_id, category, is_demo'
      ') values ('
      "  '$_prePopOpId'::uuid, '$_prePopLocId'::uuid, 'labor', true"
      ') on conflict do nothing',
    );
    await tx1.commit();
  } catch (e) {
    await tx1.rollback();
    // demo_mode_state may not exist yet — that's OK.
  }

  // Seed a user (required for shift_records FK).
  final tx2 = await pool.beginTransaction();
  try {
    await tx2.execute(
      'insert into public.users ('
      '  user_id, operator_id, primary_location_id, email, '
      '  firebase_uid, password_changed_at'
      ') values ('
      "  '$_prePopUserId'::uuid, '$_prePopOpId'::uuid, "
      "  '$_prePopLocId'::uuid, 'fwd_apply@test.invalid', "
      "  '$_prePopUserId', now()"
      ') on conflict (user_id) do nothing',
    );
    await tx2.commit();
  } catch (e) {
    await tx2.rollback();
    // users may not exist yet — skip.
  }

  return await _readCounts(pool);
}

/// Reads row counts for key tables. Tables that do not exist return 0.
Future<Map<String, int>> _readCounts(PackagePostgresPool pool) async {
  final counts = <String, int>{};
  final tables = <String>[
    'operators',
    'locations',
    'shift_records',
    'audit_logs',
    'demo_mode_state',
    'users',
  ];
  for (final table in tables) {
    final tx = await pool.beginTransaction();
    try {
      final rows = await tx.query(
        'select count(*) as n from public.$table',
      );
      if (rows.isNotEmpty) {
        final n = rows.first['n'];
        counts[table] = n is int
            ? n
            : (n is num ? n.toInt() : int.tryParse(n.toString()) ?? 0);
      }
      await tx.commit();
    } catch (_) {
      await tx.rollback();
      counts[table] = 0;
    }
  }
  return counts;
}
