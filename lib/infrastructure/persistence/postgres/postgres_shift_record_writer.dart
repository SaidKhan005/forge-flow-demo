// Phase 8 spine-bridge Lane .2 — Postgres-backed ShiftRecord writer.
//
// Authority:
//   * docs/contracts/integration_spine_architecture_contract.md
//     "Sub-lane shape -> .2" (binding) — replace-for-slot semantics +
//     Concern A target_profile_version_id preservation rule.
//   * docs/contracts/core_app_architecture.md "What never rewrites"
//     non-negotiable — re-aggregation preserves the prior
//     target_profile_version_id verbatim; only first-time aggregations
//     mint a fresh version from the current ActiveTargetProfile.
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     — every write goes through OperatorScopedRepository.withTenant.
//
// What this lane does:
//
//   1. Persists a built [ShiftFact] (produced by
//      `ShiftFactBuilder.fromClosedShiftInput` from the aggregator's
//      [ClosedShiftInput]) into operator-scoped Postgres
//      `shift_records` via OperatorScopedRepository.withTenant.
//   2. Replace-for-slot semantics: ON CONFLICT
//      `(operator_id, location_id, business_date, daypart)` DO UPDATE
//      overwrites every editable column.
//   3. **Concern A binding** — preserves the prior
//      `target_profile_version_id` when the aggregator's
//      [AggregatorProvenanceContext.priorTargetProfileVersionId] is
//      non-null. Only first-time aggregations adopt the
//      [ShiftFact.targetSnapshot.targetProfileVersionId] from the
//      current ActiveTargetProfile.
//   4. `source_system` carries the dominant POS vendor id (or
//      `operator_manual_entry` when covers source = manual) — this is
//      the value the aggregator already placed on the
//      [ClosedShiftInput.sourceSystem] field.
//   5. Provenance strings (covers + labor dollars) are persisted on
//      `shift_records.covers_provenance` /
//      `shift_records.labor_dollars_provenance` so the read path can
//      surface them through the dashboard pill per
//      `metric_card_honesty_contract.md`.
//
// Hardening alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no banned items. Same per-file source grep applies as the .1.*
// sinks.

import '../../../domain/models/aggregator_provenance_context.dart';
import '../../../domain/models/shift_fact.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';

class PostgresShiftRecordWriter extends OperatorScopedRepository {
  PostgresShiftRecordWriter(super.tenantWrapper);

  /// Persist [shiftFact] for `(operator_id, location_id, business_date,
  /// daypart)`. Replace-for-slot. Concern A applied: when
  /// [provenance.priorTargetProfileVersionId] is non-null, the prior
  /// version id wins over the current ActiveTargetProfile snapshot's
  /// version id.
  Future<void> writeShiftRecord({
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      final resolvedTpv =
          provenance.hasPriorShiftRecord
          ? provenance.priorTargetProfileVersionId
          : shiftFact.targetSnapshot.targetProfileVersionId;
      final resolvedTiming = _resolvedTimingProvenance(
        shiftFact: shiftFact,
        provenance: provenance,
      );

      await _upsertShiftRecord(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        shiftFact: shiftFact,
        provenance: provenance,
        resolvedTargetProfileVersionId: resolvedTpv,
        resolvedTiming: resolvedTiming,
      );
    });
  }

  Future<void> _upsertShiftRecord({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
    required String? resolvedTargetProfileVersionId,
    required _ResolvedTimingProvenance resolvedTiming,
  }) async {
    final snap = shiftFact.targetSnapshot;
    await exec.execute(
      'insert into public.shift_records ('
      'operator_id, location_id, '
      'restaurant_id, week_id, day_label, daypart, status, '
      'business_date, '
      'covers, forecast_covers, '
      'actual_sales, ppa, cplh, splh, '
      'foh_hours, boh_hours, '
      'foh_labor_dollar, boh_labor_dollar, '
      'theoretical_labor_pct, primary_lever, '
      'target_profile_id, target_profile_version_id, '
      'target_source_type, target_cplh, target_splh, target_ppa, '
      'target_foh_wage, target_boh_wage, '
      'opz_floor_cplh, opz_ceiling_cplh, '
      'theoretical_foh_labor_pct, theoretical_boh_labor_pct, '
      'business_timing_profile_id, business_timing_profile_version_id, '
      'service_period_key, '
      // Per-Daypart V1 (Slice 1) — per-shift per-period locked target stamps.
      'daypart_target_cplh, daypart_target_splh, daypart_target_ppa, '
      'daypart_opz_floor_cplh, daypart_opz_ceiling_cplh, '
      'source_system, source_shift_id, '
      'covers_provenance, labor_dollars_provenance, '
      'created_at, updated_at'
      ') values ('
      '@operator_id::uuid, @location_id::uuid, '
      '@restaurant_id, @week_id, @day_label, @daypart, @status, '
      '@business_date::date, '
      '@covers, @forecast_covers, '
      '@actual_sales, @ppa, @cplh, @splh, '
      '@foh_hours, @boh_hours, '
      '@foh_labor_dollar, @boh_labor_dollar, '
      '@theoretical_labor_pct, @primary_lever, '
      '@target_profile_id, @target_profile_version_id, '
      '@target_source_type, @target_cplh, @target_splh, @target_ppa, '
      '@target_foh_wage, @target_boh_wage, '
      '@opz_floor_cplh, @opz_ceiling_cplh, '
      '@theoretical_foh_labor_pct, @theoretical_boh_labor_pct, '
      '@business_timing_profile_id::uuid, '
      '@business_timing_profile_version_id::uuid, '
      '@service_period_key, '
      '@daypart_target_cplh, @daypart_target_splh, @daypart_target_ppa, '
      '@daypart_opz_floor_cplh, @daypart_opz_ceiling_cplh, '
      '@source_system, @source_shift_id, '
      '@covers_provenance, @labor_dollars_provenance, '
      'now(), now()'
      ') '
      'on conflict (operator_id, location_id, business_date, daypart) '
      'do update set '
      'restaurant_id = excluded.restaurant_id, '
      'week_id = excluded.week_id, '
      'day_label = excluded.day_label, '
      'status = excluded.status, '
      'covers = excluded.covers, '
      'forecast_covers = excluded.forecast_covers, '
      'actual_sales = excluded.actual_sales, '
      'ppa = excluded.ppa, '
      'cplh = excluded.cplh, '
      'splh = excluded.splh, '
      'foh_hours = excluded.foh_hours, '
      'boh_hours = excluded.boh_hours, '
      'foh_labor_dollar = excluded.foh_labor_dollar, '
      'boh_labor_dollar = excluded.boh_labor_dollar, '
      'theoretical_labor_pct = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.theoretical_labor_pct '
      'else excluded.theoretical_labor_pct end, '
      'primary_lever = excluded.primary_lever, '
      // Concern A: corrected facts may update actuals, but a prior
      // closed row keeps its locked target/timing snapshot verbatim.
      'target_profile_version_id = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.target_profile_version_id '
      'else excluded.target_profile_version_id end, '
      'target_profile_id = case when @has_prior_shift_record::boolean '
      'then shift_records.target_profile_id '
      'else excluded.target_profile_id end, '
      'target_source_type = case when @has_prior_shift_record::boolean '
      'then shift_records.target_source_type '
      'else excluded.target_source_type end, '
      'target_cplh = case when @has_prior_shift_record::boolean '
      'then shift_records.target_cplh else excluded.target_cplh end, '
      'target_splh = case when @has_prior_shift_record::boolean '
      'then shift_records.target_splh else excluded.target_splh end, '
      'target_ppa = case when @has_prior_shift_record::boolean '
      'then shift_records.target_ppa else excluded.target_ppa end, '
      'target_foh_wage = case when @has_prior_shift_record::boolean '
      'then shift_records.target_foh_wage '
      'else excluded.target_foh_wage end, '
      'target_boh_wage = case when @has_prior_shift_record::boolean '
      'then shift_records.target_boh_wage '
      'else excluded.target_boh_wage end, '
      'opz_floor_cplh = case when @has_prior_shift_record::boolean '
      'then shift_records.opz_floor_cplh '
      'else excluded.opz_floor_cplh end, '
      'opz_ceiling_cplh = case when @has_prior_shift_record::boolean '
      'then shift_records.opz_ceiling_cplh '
      'else excluded.opz_ceiling_cplh end, '
      'theoretical_foh_labor_pct = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.theoretical_foh_labor_pct '
      'else excluded.theoretical_foh_labor_pct end, '
      'theoretical_boh_labor_pct = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.theoretical_boh_labor_pct '
      'else excluded.theoretical_boh_labor_pct end, '
      'business_timing_profile_id = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.business_timing_profile_id '
      'else excluded.business_timing_profile_id end, '
      'business_timing_profile_version_id = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.business_timing_profile_version_id '
      'else excluded.business_timing_profile_version_id end, '
      'service_period_key = case when @has_prior_shift_record::boolean '
      'then shift_records.service_period_key '
      'else excluded.service_period_key end, '
      // Per-period stamps are part of the locked target snapshot.
      'daypart_target_cplh = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.daypart_target_cplh '
      'else excluded.daypart_target_cplh end, '
      'daypart_target_splh = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.daypart_target_splh '
      'else excluded.daypart_target_splh end, '
      'daypart_target_ppa = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.daypart_target_ppa '
      'else excluded.daypart_target_ppa end, '
      'daypart_opz_floor_cplh = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.daypart_opz_floor_cplh '
      'else excluded.daypart_opz_floor_cplh end, '
      'daypart_opz_ceiling_cplh = case '
      'when @has_prior_shift_record::boolean '
      'then shift_records.daypart_opz_ceiling_cplh '
      'else excluded.daypart_opz_ceiling_cplh end, '
      'source_system = excluded.source_system, '
      'source_shift_id = excluded.source_shift_id, '
      'covers_provenance = excluded.covers_provenance, '
      'labor_dollars_provenance = excluded.labor_dollars_provenance, '
      'updated_at = now()',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'restaurant_id': shiftFact.restaurantId,
        'week_id': shiftFact.weekId,
        'day_label': shiftFact.dayLabel,
        'daypart': shiftFact.daypart,
        'status': 'closed',
        'business_date': _isoDate(shiftFact.businessDate),
        'covers': shiftFact.covers,
        'forecast_covers': shiftFact.forecastCovers,
        'actual_sales': shiftFact.actualSales,
        'ppa': shiftFact.ppa,
        'cplh': shiftFact.cplh,
        'splh': shiftFact.splh,
        'foh_hours': shiftFact.actualFohHours,
        'boh_hours': shiftFact.actualBohHours,
        'foh_labor_dollar': shiftFact.actualFohLaborDollars,
        'boh_labor_dollar': shiftFact.actualBohLaborDollars,
        'theoretical_labor_pct': snap.theoreticalLaborPct,
        'primary_lever': shiftFact.primaryLeverId,
        'target_profile_id': snap.targetProfileId,
        // Concern A: this is the resolved value — prior id when
        // re-aggregating, current id on first-time.
        'target_profile_version_id': resolvedTargetProfileVersionId,
        'target_source_type': snap.sourceType,
        'target_cplh': snap.targetCPLH,
        'target_splh': snap.targetSPLH,
        'target_ppa': snap.targetPPA,
        'target_foh_wage': snap.fohWage,
        'target_boh_wage': snap.bohWage,
        'opz_floor_cplh': snap.opzFloorCPLH,
        'opz_ceiling_cplh': snap.opzCeilingCPLH,
        'theoretical_foh_labor_pct': snap.theoreticalFohLaborPct,
        'theoretical_boh_labor_pct': snap.theoreticalBohLaborPct,
        'business_timing_profile_id': resolvedTiming.profileId,
        'business_timing_profile_version_id': resolvedTiming.versionId,
        'service_period_key': resolvedTiming.servicePeriodKey,
        // Per-Daypart V1 (Slice 1) — per-period stamps come from the
        // TargetSnapshot, which the builder populated from the active
        // profile's per-period row (when present at close time).
        'daypart_target_cplh': snap.daypartTargetCPLH,
        'daypart_target_splh': snap.daypartTargetSPLH,
        'daypart_target_ppa': snap.daypartTargetPPA,
        'daypart_opz_floor_cplh': snap.daypartOpzFloorCPLH,
        'daypart_opz_ceiling_cplh': snap.daypartOpzCeilingCPLH,
        'source_system': shiftFact.sourceSystem,
        'source_shift_id': shiftFact.sourceShiftId,
        'covers_provenance': provenance.coversProvenance,
        'labor_dollars_provenance': provenance.laborDollarsProvenance,
        'has_prior_shift_record': provenance.hasPriorShiftRecord,
      },
    );
  }

  _ResolvedTimingProvenance _resolvedTimingProvenance({
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  }) {
    if (provenance.hasPriorShiftRecord) {
      return _ResolvedTimingProvenance(
        profileId: provenance.priorBusinessTimingProfileId,
        versionId: provenance.priorBusinessTimingProfileVersionId,
        servicePeriodKey: provenance.priorServicePeriodKey,
      );
    }
    return _ResolvedTimingProvenance(
      profileId: shiftFact.businessTimingProfileId,
      versionId: shiftFact.businessTimingProfileVersionId,
      servicePeriodKey: shiftFact.servicePeriodKey,
    );
  }

  static String _isoDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _ResolvedTimingProvenance {
  const _ResolvedTimingProvenance({
    required this.profileId,
    required this.versionId,
    required this.servicePeriodKey,
  });

  final String? profileId;
  final String? versionId;
  final String? servicePeriodKey;
}
