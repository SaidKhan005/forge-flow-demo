// Phase 8 spine-bridge Lane .A — DataAccuracySettingsRepository.
//
// Persistence layer for `public.data_accuracy_settings`. Every read /
// write goes through `OperatorScopedRepository.withTenant` so the
// per-tenant RLS policy admits the row.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md.
//
// Consumed by Lanes .0a (polling cadence resolver), .2 (aggregator
// covers + wage resolution), .B (operator web Data Accuracy tab),
// .C (F&F Ops Console per-location admin).
//
// Per the F&F-controlled tier model (REVERSED 2026-05-05), this
// repository carries NO polling-cadence surface. Cadence lives on
// `forge_flow_polling_tier_assignment` — see
// [ForgeFlowPollingTierRepository].

import 'dart:convert';

import '../../domain/models/data_accuracy_settings.dart';
import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';

class DataAccuracySettingsRepository extends OperatorScopedRepository {
  DataAccuracySettingsRepository(super.tenantWrapper);

  /// Returns the (operator, location) row, creating a default row when
  /// none exists. Defaults match the SQL CHECK constraint defaults:
  /// covers_source_* = 'vendor', wage_source = 'vendor', empty
  /// manual entries map.
  ///
  /// Single transaction: SELECT first, INSERT-RETURNING when the SELECT
  /// is empty. Idempotent — concurrent first-creates collapse onto the
  /// row inserted by whichever transaction wins the unique index race
  /// (ON CONFLICT DO NOTHING + a second SELECT).
  Future<DataAccuracySettings> readOrCreateDefault({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracySettings>(ctx, (exec) async {
      final existing = await _readRow(exec, operatorId, locationId);
      if (existing != null) return existing;
      // INSERT defaults; ON CONFLICT DO NOTHING covers a concurrent
      // first-create. Then SELECT to read whichever row landed.
      await exec.execute(
        'insert into data_accuracy_settings ('
        'operator_id, location_id, updated_by) '
        'values (@operator_id::uuid, @location_id::uuid, @updated_by) '
        'on conflict (operator_id, location_id) do nothing',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'updated_by': actorUserId,
        },
      );
      final created = await _readRow(exec, operatorId, locationId);
      if (created == null) {
        throw StateError(
          'data_accuracy_settings readOrCreateDefault failed — '
          'INSERT landed but follow-up SELECT returned no row '
          '(RLS policy likely rejected the read for this tenant)',
        );
      }
      return created;
    });
  }

  /// Full-row upsert. Used by the operator web tab when the operator
  /// hits Save after editing multiple fields. ON CONFLICT
  /// (operator_id, location_id) DO UPDATE re-binds every editable
  /// column from the supplied [settings].
  Future<DataAccuracySettings> upsert({
    required DataAccuracySettings settings,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: settings.operatorId,
      locationId: settings.locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracySettings>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into data_accuracy_settings ('
        'operator_id, location_id, '
        'covers_source_lunch, covers_source_dinner, covers_source_late_night, '
        'covers_manual_entries, wage_source, updated_by) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, '
        '@covers_lunch, @covers_dinner, @covers_late_night, '
        '@manual_entries::jsonb, @wage_source, @updated_by) '
        'on conflict (operator_id, location_id) do update set '
        'covers_source_lunch = excluded.covers_source_lunch, '
        'covers_source_dinner = excluded.covers_source_dinner, '
        'covers_source_late_night = excluded.covers_source_late_night, '
        'covers_manual_entries = excluded.covers_manual_entries, '
        'wage_source = excluded.wage_source, '
        'updated_at = now(), '
        'updated_by = excluded.updated_by '
        'returning '
        'setting_id::text as setting_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'covers_source_lunch, covers_source_dinner, covers_source_late_night, '
        'covers_manual_entries, wage_source, '
        'created_at, updated_at, updated_by',
        parameters: <String, Object?>{
          'operator_id': settings.operatorId,
          'location_id': settings.locationId,
          'covers_lunch': settings.coversSourceLunch.wire,
          'covers_dinner': settings.coversSourceDinner.wire,
          'covers_late_night': settings.coversSourceLateNight.wire,
          'manual_entries': jsonEncode(settings.coversManualEntries),
          'wage_source': settings.wageSource.wire,
          'updated_by': actorUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'data_accuracy_settings upsert returned no row — RLS policy '
          'likely rejected the write for this tenant',
        );
      }
      return DataAccuracySettings.fromRow(rows.single);
    });
  }

  /// Update a single daypart's covers source and (optionally) the
  /// manual entry for one (business_date, daypart) pair. Per-daypart
  /// partial update — other daypart columns are NOT touched.
  ///
  /// When [setManualCovers] is non-null and [source] == manual, the
  /// jsonb is patched in place: the existing `business_date` map is
  /// preserved and the supplied daypart entry is upserted into it.
  Future<DataAccuracySettings> updateCoversSourceForDaypart({
    required String operatorId,
    required String locationId,
    required Daypart daypart,
    required CoversSource source,
    String? actorUserId,
    String? businessDateIso,
    int? setManualCovers,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracySettings>(ctx, (exec) async {
      final current = await _readRow(exec, operatorId, locationId);
      if (current == null) {
        throw StateError(
          'data_accuracy_settings updateCoversSourceForDaypart called '
          'before readOrCreateDefault — no row for this (operator, location)',
        );
      }
      final coversLunch = daypart == Daypart.lunch
          ? source
          : current.coversSourceLunch;
      final coversDinner = daypart == Daypart.dinner
          ? source
          : current.coversSourceDinner;
      final coversLateNight = daypart == Daypart.lateNight
          ? source
          : current.coversSourceLateNight;

      var manualEntries = current.coversManualEntries;
      if (businessDateIso != null && setManualCovers != null) {
        manualEntries = _patchManualEntry(
          manualEntries,
          businessDateIso,
          daypart,
          setManualCovers,
        );
      }
      return _writeAndReturn(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        coversLunch: coversLunch,
        coversDinner: coversDinner,
        coversLateNight: coversLateNight,
        manualEntries: manualEntries,
        wageSource: current.wageSource,
        actorUserId: actorUserId,
      );
    });
  }

  /// Toggle the wage source binary. Other fields untouched.
  Future<DataAccuracySettings> updateWageSource({
    required String operatorId,
    required String locationId,
    required WageSource wageSource,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracySettings>(ctx, (exec) async {
      final current = await _readRow(exec, operatorId, locationId);
      if (current == null) {
        throw StateError(
          'data_accuracy_settings updateWageSource called before '
          'readOrCreateDefault — no row for this (operator, location)',
        );
      }
      return _writeAndReturn(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        coversLunch: current.coversSourceLunch,
        coversDinner: current.coversSourceDinner,
        coversLateNight: current.coversSourceLateNight,
        manualEntries: current.coversManualEntries,
        wageSource: wageSource,
        actorUserId: actorUserId,
      );
    });
  }

  /// Bulk-seed historical manual covers entries. Used by the operator
  /// web Data Accuracy tab's 60-day historical seed flow when the
  /// operator switches a daypart to `manual` and back-fills past dates
  /// in one shot.
  ///
  /// Semantics:
  ///   * Read current `covers_manual_entries` jsonb under the same
  ///     transaction as the write so concurrent edits collapse onto
  ///     the row visible at txn start.
  ///   * Deep-merge the supplied [entries] (date -> daypart -> covers)
  ///     into the current jsonb. Existing date+daypart pairs are
  ///     overwritten by the seed; pairs the seed does not name are
  ///     preserved untouched.
  ///   * Write the merged jsonb back. Other columns untouched.
  Future<DataAccuracySettings> applyHistoricalCoversSeed({
    required String operatorId,
    required String locationId,
    required Map<String, Map<Daypart, int>> entries,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracySettings>(ctx, (exec) async {
      final current = await _readRow(exec, operatorId, locationId);
      if (current == null) {
        throw StateError(
          'data_accuracy_settings applyHistoricalCoversSeed called '
          'before readOrCreateDefault — no row for this (operator, location)',
        );
      }
      final merged = _deepMergeManualEntries(
        current.coversManualEntries,
        entries,
      );
      return _writeAndReturn(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        coversLunch: current.coversSourceLunch,
        coversDinner: current.coversSourceDinner,
        coversLateNight: current.coversSourceLateNight,
        manualEntries: merged,
        wageSource: current.wageSource,
        actorUserId: actorUserId,
      );
    });
  }

  // ── private helpers ────────────────────────────────────────────────

  Future<DataAccuracySettings?> _readRow(
    PostgresExecutor exec,
    String operatorId,
    String locationId,
  ) async {
    final rows = await exec.query(
      'select '
      'setting_id::text as setting_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'covers_source_lunch, covers_source_dinner, covers_source_late_night, '
      'covers_manual_entries, wage_source, '
      'created_at, updated_at, updated_by '
      'from data_accuracy_settings '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isEmpty) return null;
    return DataAccuracySettings.fromRow(rows.single);
  }

  Future<DataAccuracySettings> _writeAndReturn({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required CoversSource coversLunch,
    required CoversSource coversDinner,
    required CoversSource coversLateNight,
    required Map<String, Map<String, int>> manualEntries,
    required WageSource wageSource,
    String? actorUserId,
  }) async {
    final rows = await exec.query(
      'update data_accuracy_settings set '
      'covers_source_lunch = @covers_lunch, '
      'covers_source_dinner = @covers_dinner, '
      'covers_source_late_night = @covers_late_night, '
      'covers_manual_entries = @manual_entries::jsonb, '
      'wage_source = @wage_source, '
      'updated_at = now(), '
      'updated_by = @updated_by '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'returning '
      'setting_id::text as setting_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'covers_source_lunch, covers_source_dinner, covers_source_late_night, '
      'covers_manual_entries, wage_source, '
      'created_at, updated_at, updated_by',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'covers_lunch': coversLunch.wire,
        'covers_dinner': coversDinner.wire,
        'covers_late_night': coversLateNight.wire,
        'manual_entries': jsonEncode(manualEntries),
        'wage_source': wageSource.wire,
        'updated_by': actorUserId,
      },
    );
    if (rows.isEmpty) {
      throw StateError(
        'data_accuracy_settings UPDATE returned no row — RLS policy '
        'likely rejected the write for this tenant',
      );
    }
    return DataAccuracySettings.fromRow(rows.single);
  }

  static Map<String, Map<String, int>> _patchManualEntry(
    Map<String, Map<String, int>> current,
    String businessDateIso,
    Daypart daypart,
    int covers,
  ) {
    final out = <String, Map<String, int>>{};
    current.forEach((key, value) {
      out[key] = Map<String, int>.from(value);
    });
    final dayMap = out.putIfAbsent(businessDateIso, () => <String, int>{});
    dayMap[daypart.wire] = covers;
    return out;
  }

  static Map<String, Map<String, int>> _deepMergeManualEntries(
    Map<String, Map<String, int>> current,
    Map<String, Map<Daypart, int>> seed,
  ) {
    final out = <String, Map<String, int>>{};
    current.forEach((key, value) {
      out[key] = Map<String, int>.from(value);
    });
    seed.forEach((dateIso, dayMap) {
      final existing = out.putIfAbsent(dateIso, () => <String, int>{});
      dayMap.forEach((daypart, covers) {
        existing[daypart.wire] = covers;
      });
    });
    return out;
  }
}
