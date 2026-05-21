// Part of sqlite_database.dart. Locked-target backfill + the honest-empty location predicate.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

/// True when a demo location's vendor fixture has ZERO connected
/// categories ("none connected / awaiting first connection" — spec
/// §D.2/§D.3; today exactly Harbour, `DemoScope.harbourRestaurantId`).
///
/// SEED-ONLY honest-EMPTY (Metric Honesty, operator decision
/// 2026-05-16): a location with nothing connected must render the
/// existing "awaiting first connection" empty states — NOT fabricated
/// numbers. The lowest-risk fix is to NOT write that location's
/// operational/historical cohort (shift/week/snapshot/plan/cycle/
/// import/notification rows) so every reader honest-degrades to its
/// existing empty UI with NO production reader/formula change. The
/// location's `restaurant_locations` row (scope drawer) and its
/// `demo_mode_state` / vendor-fixture rows (demo banners) are still
/// seeded — only the operational/historical data is suppressed.
///
/// Generalized off [DemoVendorIntegrationStateFixture] connection state,
/// NOT a hardcoded "if harbour": any demo location whose fixture has
/// zero connected categories is honest-empty (Riverside is all-3
/// connected→live, North Loop POS-only, Downtown all-3 mixed, so today
/// only Harbour matches).
///
/// HP #2: writer/seed-side only. No `demo_*` table, no `kDemoMode`
/// reader branch — the readers are byte-unchanged and resolve demo and
/// prod identically; they simply find no rows for this scope.
bool _isNoneConnectedDemoLocation(String restaurantId) =>
    DemoVendorIntegrationStateFixture.isNoneConnected(restaurantId);

/// Backfills locked-target columns on shift_records and week_records
/// that lack them, using the current active target profile.
/// Also ensures target-profile provenance and a compat version row.
Future<void> _backfillLockedTargets(
  Database db, {
  required String businessDate,
}) async {
  final cycle = await _ensureDemoSeedCycle(db, businessDate: businessDate);
  final profile = await _loadSeedAuthorityProfile(
    db,
    businessDate: businessDate,
  );
  final compatVersionId = 'compat_${DemoScope.restaurantId}_v8_backfill';

  // Ensure a compat target_profile_versions row exists
  await db.insert('target_profile_versions', {
    'target_profile_version_id': compatVersionId,
    'target_profile_id': profile.targetProfileId,
    'restaurant_id': DemoScope.restaurantId,
    'target_cycle_id': cycle.cycleId,
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

  // ── Provenance-only repair for partially migrated rows ──────────────────
  // Rows that already have numeric locked targets but lack identity fields.
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

  await db.execute(
    '''
    UPDATE week_records SET
      target_calibration_window_start = ?,
      target_calibration_window_end = ?
    WHERE restaurant_id = ?
      AND (
        target_calibration_window_start IS NULL OR
        target_calibration_window_end IS NULL
      )
  ''',
    [
      cycle.calibrationWindowStart,
      cycle.calibrationWindowEnd,
      DemoScope.restaurantId,
    ],
  );
}
