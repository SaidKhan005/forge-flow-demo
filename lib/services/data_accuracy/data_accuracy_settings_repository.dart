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
//
// Per-Daypart V1 Slice R5 (Gap 27/36): the hardcoded
// `covers_source_lunch` / `_dinner` / `_late_night` columns are
// deprecated. Per-period covers source is now keyed by the
// operator-configured `service_period_key` in the existing
// `public.data_accuracy_service_period_settings` table (created by
// `db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql`).
// `_readRow` projects the effective keyed rows into a
// `covers_source_per_service_period` map so the model is resolver-keyed
// and an operator with any number of service periods works end to end.

import 'dart:convert';

import '../../domain/models/data_accuracy_settings.dart';
import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';

class DataAccuracySettingsRepository extends OperatorScopedRepository {
  DataAccuracySettingsRepository(super.tenantWrapper);

  // Projects the effective keyed covers-source rows for (operator,
  // location) into a `{service_period_key: covers_source}` jsonb under
  // the alias `covers_source_per_service_period`. "Effective" = the
  // most recent row at-or-before today's UTC date per service period
  // (the same at-or-before lookup the closed-shift aggregator uses).
  // `reservation_plus_walkin` is admitted by the keyed table and stays
  // lossless in the model so Operator Web, Admin, mobile, and closed-shift
  // aggregation agree on the same effective source.
  static const String _perPeriodSubquery =
      "coalesce((select jsonb_object_agg(k.service_period_key, k.covers_source) "
      'from (select distinct on (sp.service_period_key) '
      'sp.service_period_key, sp.covers_source '
      'from public.data_accuracy_service_period_settings sp '
      'where sp.operator_id = das.operator_id '
      'and sp.location_id = das.location_id '
      'and sp.effective_at_business_date <= (now() at time zone \'utc\')::date '
      'order by sp.service_period_key, sp.effective_at_business_date desc '
      ') k), \'{}\'::jsonb) as covers_source_per_service_period';

  /// Returns the (operator, location) row, creating a default row when
  /// none exists. Defaults match the SQL CHECK constraint defaults:
  /// per-period covers source absent (resolves to vendor via the
  /// model), wage_source = 'vendor', empty manual entries map.
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
  ///
  /// Per-period covers source ([DataAccuracySettings.coversSourcePerServicePeriod])
  /// is written to the keyed `data_accuracy_service_period_settings`
  /// table (one row per service period, effective today UTC), NOT to
  /// the deprecated legacy columns. [effectiveAtBusinessDateIso] lets
  /// the caller stage a forward-dated change; it defaults to today UTC.
  Future<DataAccuracySettings> upsert({
    required DataAccuracySettings settings,
    String? actorUserId,
    String? effectiveAtBusinessDateIso,
  }) {
    final ctx = TenantContext(
      operatorId: settings.operatorId,
      locationId: settings.locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracySettings>(ctx, (exec) async {
      await exec.execute(
        'insert into data_accuracy_settings ('
        'operator_id, location_id, '
        'covers_manual_entries, wage_source, '
        'walk_in_handling_mode, walk_in_manual_entries, updated_by) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, '
        '@manual_entries::jsonb, @wage_source, '
        '@walk_in_handling_mode, @walk_in_manual_entries::jsonb, '
        '@updated_by) '
        'on conflict (operator_id, location_id) do update set '
        'covers_manual_entries = excluded.covers_manual_entries, '
        'wage_source = excluded.wage_source, '
        'walk_in_handling_mode = excluded.walk_in_handling_mode, '
        'walk_in_manual_entries = excluded.walk_in_manual_entries, '
        'updated_at = now(), '
        'updated_by = excluded.updated_by',
        parameters: <String, Object?>{
          'operator_id': settings.operatorId,
          'location_id': settings.locationId,
          'manual_entries': jsonEncode(settings.coversManualEntries),
          'wage_source': settings.wageSource.wire,
          'walk_in_handling_mode': settings.walkInHandlingMode.wire,
          'walk_in_manual_entries': jsonEncode(settings.walkInManualEntries),
          'updated_by': actorUserId,
        },
      );
      final effectiveDate = effectiveAtBusinessDateIso ?? _todayUtcIso();
      for (final entry in settings.coversSourcePerServicePeriod.entries) {
        await _upsertKeyedCoversSource(
          exec,
          operatorId: settings.operatorId,
          locationId: settings.locationId,
          servicePeriodId: entry.key,
          source: entry.value,
          effectiveAtBusinessDateIso: effectiveDate,
          actorUserId: actorUserId,
        );
      }
      final saved = await _readRow(
        exec,
        settings.operatorId,
        settings.locationId,
      );
      if (saved == null) {
        throw StateError(
          'data_accuracy_settings upsert returned no row — RLS policy '
          'likely rejected the write for this tenant',
        );
      }
      return saved;
    });
  }

  /// Update a single service period's covers source and (optionally)
  /// the manual entry for one (business_date, service_period_id) pair.
  /// Per-period partial update — other service periods are NOT touched.
  ///
  /// The covers-source choice is written to the keyed
  /// `data_accuracy_service_period_settings` table (Gap 27/36); the
  /// legacy hardcoded columns are no longer written. When
  /// [setManualCovers] is non-null the `covers_manual_entries` jsonb on
  /// `data_accuracy_settings` is patched in place: the existing
  /// `business_date` map is preserved and the supplied period entry is
  /// upserted into it.
  Future<DataAccuracySettings> updateCoversSourceForServicePeriod({
    required String operatorId,
    required String locationId,
    required String servicePeriodId,
    required CoversSource source,
    String? actorUserId,
    String? businessDateIso,
    int? setManualCovers,
    String? effectiveAtBusinessDateIso,
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
          'data_accuracy_settings updateCoversSourceForServicePeriod called '
          'before readOrCreateDefault — no row for this (operator, location)',
        );
      }
      await _upsertKeyedCoversSource(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        servicePeriodId: servicePeriodId,
        source: source,
        effectiveAtBusinessDateIso:
            effectiveAtBusinessDateIso ?? _todayUtcIso(),
        actorUserId: actorUserId,
      );

      var manualEntries = current.coversManualEntries;
      if (businessDateIso != null && setManualCovers != null) {
        manualEntries = _patchManualEntry(
          manualEntries,
          businessDateIso,
          servicePeriodId,
          setManualCovers,
        );
      }
      return _writeAndReturn(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        manualEntries: manualEntries,
        wageSource: current.wageSource,
        walkInHandlingMode: current.walkInHandlingMode,
        walkInManualEntries: current.walkInManualEntries,
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
        manualEntries: current.coversManualEntries,
        wageSource: wageSource,
        walkInHandlingMode: current.walkInHandlingMode,
        walkInManualEntries: current.walkInManualEntries,
        actorUserId: actorUserId,
      );
    });
  }

  /// Update reservation demand / walk-in handling mode and optionally
  /// patch one business date's walk-in count. Other data accuracy
  /// fields remain untouched.
  Future<DataAccuracySettings> updateWalkInHandling({
    required String operatorId,
    required String locationId,
    required DataAccuracyWalkInHandlingMode mode,
    String? actorUserId,
    String? businessDateIso,
    int? setWalkInCount,
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
          'data_accuracy_settings updateWalkInHandling called before '
          'readOrCreateDefault - no row for this (operator, location)',
        );
      }
      var walkInEntries = current.walkInManualEntries;
      if (businessDateIso != null) {
        walkInEntries = _patchWalkInEntry(
          walkInEntries,
          businessDateIso,
          setWalkInCount,
        );
      }
      return _writeAndReturn(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        manualEntries: current.coversManualEntries,
        wageSource: current.wageSource,
        walkInHandlingMode: mode,
        walkInManualEntries: walkInEntries,
        actorUserId: actorUserId,
      );
    });
  }

  /// Bulk-seed historical manual covers entries. Used by the operator
  /// web Data Accuracy tab's 60-day historical seed flow when the
  /// operator switches a service period to `manual` and back-fills past
  /// dates in one shot.
  ///
  /// Semantics:
  ///   * Read current `covers_manual_entries` jsonb under the same
  ///     transaction as the write so concurrent edits collapse onto
  ///     the row visible at txn start.
  ///   * Deep-merge the supplied [entries] (date -> service_period_id
  ///     -> covers) into the current jsonb. Existing
  ///     date+service_period pairs are overwritten by the seed; pairs
  ///     the seed does not name are preserved untouched.
  ///   * Write the merged jsonb back. Other columns untouched.
  Future<DataAccuracySettings> applyHistoricalCoversSeed({
    required String operatorId,
    required String locationId,
    required Map<String, Map<String, int>> entries,
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
        manualEntries: merged,
        wageSource: current.wageSource,
        walkInHandlingMode: current.walkInHandlingMode,
        walkInManualEntries: current.walkInManualEntries,
        actorUserId: actorUserId,
      );
    });
  }

  // ── private helpers ────────────────────────────────────────────────

  static String _todayUtcIso() {
    final now = DateTime.now().toUtc();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Upsert one keyed covers-source row. `wage_source` defaults to the
  /// keyed table's own default (`vendor_per_employee`) on first insert
  /// and is preserved on update so this covers-source-only write never
  /// clobbers a per-period wage choice a future slice may set.
  Future<void> _upsertKeyedCoversSource(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String servicePeriodId,
    required CoversSource source,
    required String effectiveAtBusinessDateIso,
    String? actorUserId,
  }) async {
    await exec.execute(
      'insert into public.data_accuracy_service_period_settings ('
      'operator_id, location_id, service_period_key, '
      'covers_source, effective_at_business_date, updated_by) '
      'values ('
      '@operator_id::uuid, @location_id::uuid, @service_period_key, '
      '@covers_source, @effective_at::date, @updated_by) '
      'on conflict (operator_id, location_id, service_period_key, '
      'effective_at_business_date) do update set '
      'covers_source = excluded.covers_source, '
      'updated_at = now(), '
      'updated_by = excluded.updated_by',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'service_period_key': servicePeriodId,
        'covers_source': source.wire,
        'effective_at': effectiveAtBusinessDateIso,
        'updated_by': actorUserId,
      },
    );
  }

  Future<DataAccuracySettings?> _readRow(
    PostgresExecutor exec,
    String operatorId,
    String locationId,
  ) async {
    final rows = await exec.query(
      'select '
      'das.setting_id::text as setting_id, '
      'das.operator_id::text as operator_id, '
      'das.location_id::text as location_id, '
      '$_perPeriodSubquery, '
      'das.covers_manual_entries, das.wage_source, '
      'das.walk_in_handling_mode, das.walk_in_manual_entries, '
      'das.created_at, das.updated_at, das.updated_by '
      'from data_accuracy_settings das '
      'where das.operator_id = @operator_id::uuid '
      'and das.location_id = @location_id::uuid',
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
    required Map<String, Map<String, int>> manualEntries,
    required WageSource wageSource,
    required DataAccuracyWalkInHandlingMode walkInHandlingMode,
    required Map<String, int> walkInManualEntries,
    String? actorUserId,
  }) async {
    final updated = await exec.execute(
      'update data_accuracy_settings set '
      'covers_manual_entries = @manual_entries::jsonb, '
      'wage_source = @wage_source, '
      'walk_in_handling_mode = @walk_in_handling_mode, '
      'walk_in_manual_entries = @walk_in_manual_entries::jsonb, '
      'updated_at = now(), '
      'updated_by = @updated_by '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'manual_entries': jsonEncode(manualEntries),
        'wage_source': wageSource.wire,
        'walk_in_handling_mode': walkInHandlingMode.wire,
        'walk_in_manual_entries': jsonEncode(walkInManualEntries),
        'updated_by': actorUserId,
      },
    );
    if (updated == 0) {
      throw StateError(
        'data_accuracy_settings UPDATE matched no row — RLS policy '
        'likely rejected the write for this tenant',
      );
    }
    final saved = await _readRow(exec, operatorId, locationId);
    if (saved == null) {
      throw StateError(
        'data_accuracy_settings UPDATE landed but follow-up SELECT '
        'returned no row (RLS policy likely rejected the read)',
      );
    }
    return saved;
  }

  static Map<String, Map<String, int>> _patchManualEntry(
    Map<String, Map<String, int>> current,
    String businessDateIso,
    String servicePeriodId,
    int covers,
  ) {
    final out = <String, Map<String, int>>{};
    current.forEach((key, value) {
      out[key] = Map<String, int>.from(value);
    });
    final dayMap = out.putIfAbsent(businessDateIso, () => <String, int>{});
    dayMap[servicePeriodId] = covers;
    return out;
  }

  static Map<String, Map<String, int>> _deepMergeManualEntries(
    Map<String, Map<String, int>> current,
    Map<String, Map<String, int>> seed,
  ) {
    final out = <String, Map<String, int>>{};
    current.forEach((key, value) {
      out[key] = Map<String, int>.from(value);
    });
    seed.forEach((dateIso, dayMap) {
      final existing = out.putIfAbsent(dateIso, () => <String, int>{});
      dayMap.forEach((servicePeriodId, covers) {
        existing[servicePeriodId] = covers;
      });
    });
    return out;
  }

  static Map<String, int> _patchWalkInEntry(
    Map<String, int> current,
    String businessDateIso,
    int? walkInCount,
  ) {
    final out = Map<String, int>.from(current);
    if (walkInCount == null) {
      out.remove(businessDateIso);
    } else {
      out[businessDateIso] = walkInCount;
    }
    return out;
  }
}
