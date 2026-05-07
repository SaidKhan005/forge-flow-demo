// Phase 8 spine-bridge Lane .2 — server-side aggregator.
//
// Authority:
//   * docs/contracts/integration_spine_architecture_contract.md
//     "Sub-lane shape -> .2" (binding) — 5-way covers + 4-way wage
//     resolution, MultiplePosAdaptersException, daypart bucketing,
//     priorTargetProfileVersionId surface.
//   * docs/contracts/core_app_architecture.md Layers 1-12 (binding) —
//     canonical truth shape, Concern A "What never rewrites" rule,
//     metric provenance contract.
//   * docs/contracts/data_accuracy_settings_contract.md (binding) —
//     covers source per-daypart, wage source binary, manual-entry
//     jsonb shape.
//   * docs/contracts/metric_card_honesty_contract.md (binding) —
//     provenance string naming rule.
//
// What this lane does:
//
//   1. Walks operator-scoped Postgres `cover_facts` + `labor_punches`
//      + `reservation_facts` for `(operator_id, location_id,
//      business_date, daypart)`.
//   2. Reads `data_accuracy_settings` via inline SELECT under the same
//      tenant transaction (composing
//      `DataAccuracySettingsRepository.readOrCreateDefault` would open
//      a nested tenant transaction and double the SET LOCAL round-trip,
//      so the aggregator inlines a small read against the same
//      executor).
//   2a. Hardening Wave B1 — reads `data_accuracy_service_period_settings`
//       via inline SELECT under the same tenant transaction for
//       `(operator_id, location_id, service_period_key=daypart.wire,
//       business_date)`. The lookup picks the most recent row at-or-
//       before the closed shift's business date so historical closes
//       resolve under the setting in force on the day the shift
//       closed. When a keyed row exists its `covers_source` wins;
//       otherwise the legacy `covers_source_lunch` / `_dinner` /
//       `_late_night` column on `data_accuracy_settings` is read.
//       Manual covers VALUES still come from the legacy
//       `covers_manual_entries` jsonb (manual-entry storage migration
//       is a future slice).
//   3. Resolves covers via the 5-way decision per
//      `data_accuracy_settings_contract.md` (manual / vendor /
//      reservation+walk-in / forecast / unavailable) — stage 3
//      (reservation+walk-in Pattern A/B/C) is implemented from the
//      durable walk-in fields on `data_accuracy_settings`; explicit
//      [ReservationWalkInOverride] remains a test/backfill seam.
//   4. Resolves labor wage via the 4-way decision keyed by
//      `LaborWageSourceClass` (manual_mix override / per-employee
//      dollars / per-position rates / per-employee rates / hours-only
//      target wage substitution).
//   5. Reads the prior `shift_records.target_profile_version_id` at
//      slot — the writer reuses this verbatim on overwrite so vendor
//      corrections never re-grade closed history under a newer cycle
//      (Concern A binding rule).
//   6. Emits an [AggregatorResult] carrying the [ClosedShiftInput] (the
//      existing typed input to `ShiftFactBuilder.fromClosedShiftInput`)
//      plus an [AggregatorProvenanceContext] with the per-metric
//      provenance strings the writer attaches to ShiftRecord.
//
// I/O boundary: the only Postgres consumer in this file is
// `withTenant` from [OperatorScopedRepository]. No `package:postgres`
// import; tests inject a fake [PostgresPool].
//
// Tock-specific: the contract notes Tock exposes only
// `serviceDateTimestamp` (no `seated_at`). The aggregator buckets
// reservation rows by `reservation_at` (which the Tock adapter sets
// from `serviceDateTimestamp`) — never seated_at — so the absence of
// seated_at on Tock rows does not break daypart bucketing.

import 'dart:convert';

import '../../domain/models/aggregator_provenance_context.dart';
import '../../domain/models/closed_shift_input.dart';
import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/demand_forecast_context.dart';
import '../../domain/models/service_period_definition.dart';
import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import 'iana_timezone_converter.dart';
import 'labor_wage_source_class.dart';

/// Optional walk-in inputs the aggregator consumes when resolving
/// covers via the reservation+walk-in pattern. The operator-walk-in
/// count comes from the Data Accuracy seated+walk-in surface (Lane .B
/// Pattern A wiring is the sanctioned follow-up; `8.spine-bridge.2`
/// surfaces the seam so tests can drive Pattern A without introducing
/// the UI lane).
class ReservationWalkInOverride {
  const ReservationWalkInOverride({required this.operatorWalkInCount});

  /// Operator-supplied walk-in count for the slot. Combined with the
  /// summed seated `party_size` from `reservation_facts` to land the
  /// final covers value.
  final int operatorWalkInCount;
}

/// Aggregator return value when at least one resolution path produced
/// a covers value. When no path yields covers (the unavailable case),
/// `aggregate` returns `null` and no `ShiftRecord` is written — the
/// dashboard renders `MetricCardNotYetAvailable` per
/// `metric_card_honesty_contract.md`.
class AggregatorResult {
  const AggregatorResult({required this.input, required this.provenance});

  final ClosedShiftInput input;
  final AggregatorProvenanceContext provenance;
}

/// Thrown when more than one POS vendor wrote `cover_facts` rows for
/// the same `(operator_id, location_id, business_date, daypart)` slot.
/// V1 contract: one POS vendor per location at a time.
class MultiplePosAdaptersException implements Exception {
  MultiplePosAdaptersException({
    required this.operatorId,
    required this.locationId,
    required this.businessDate,
    required this.daypart,
    required this.vendorIds,
  });

  final String operatorId;
  final String locationId;
  final DateTime businessDate;
  final String daypart;
  final Set<String> vendorIds;

  @override
  String toString() =>
      'MultiplePosAdaptersException: '
      'multiple POS vendors wrote cover_facts at slot '
      '(operator=$operatorId, location=$locationId, '
      'business_date=$businessDate, daypart=$daypart): '
      '${vendorIds.toList()..sort()}';
}

class CanonicalFactToClosedShiftInputAggregator
    extends OperatorScopedRepository {
  CanonicalFactToClosedShiftInputAggregator(
    super.tenantWrapper, {
    IanaTimezoneConverter? timezoneConverter,
  }) : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared;

  final IanaTimezoneConverter _timezoneConverter;

  /// Walk canonical facts for `(operator_id, location_id, business_date,
  /// daypart)` and emit an [AggregatorResult] or null.
  ///
  /// Returns null only when no covers source resolves (5-way decision
  /// stage 5: unavailable). All other branches return a non-null
  /// result; the writer is the next consumer.
  Future<AggregatorResult?> aggregate({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required DateTime businessDate,
    required String weekId,
    required String dayLabel,
    required Daypart daypart,
    required ServicePeriodDefinition periodDefinition,
    String? businessTimingProfileId,
    String? businessTimingProfileVersionId,
    DemandForecastContext? forecastContext,
    ReservationWalkInOverride? walkInOverride,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<AggregatorResult?>(ctx, (exec) async {
      final settings = await _readDataAccuracySettings(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );

      // Hardening Wave B1 — prefer the keyed
      // `data_accuracy_service_period_settings` row for this
      // (operator, location, service_period_key, business_date).
      // Falls back to the legacy hardcoded `covers_source_*` columns
      // on `data_accuracy_settings` when no keyed row exists for this
      // service period at-or-before the closed shift's business date.
      final keyedServicePeriodSetting = await _readKeyedServicePeriodSetting(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        servicePeriodKey: daypart.wire,
        businessDate: businessDate,
      );

      final locationMeta = await _readLocationMeta(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );

      // ─── Walk POS cover_facts → buckets to this daypart ──────────
      final coverFacts = await _readCoverFactsForDaypart(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
        periodDefinition: periodDefinition,
        timezone: locationMeta.timezone,
      );

      final posVendorIds = coverFacts
          .map((row) => row['vendor_id'] as String? ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      if (posVendorIds.length > 1) {
        throw MultiplePosAdaptersException(
          operatorId: operatorId,
          locationId: locationId,
          businessDate: businessDate,
          daypart: daypart.wire,
          vendorIds: posVendorIds,
        );
      }
      final posVendorId = posVendorIds.isNotEmpty ? posVendorIds.first : null;

      // ─── Walk labor_punches for slot ─────────────────────────────
      final laborPunches = await _readLaborPunchesForDaypart(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
        periodDefinition: periodDefinition,
        timezone: locationMeta.timezone,
      );

      // ─── Walk reservation_facts for slot (Tock seated_at-free) ──
      final reservationFacts = await _readReservationFactsForDaypart(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
        periodDefinition: periodDefinition,
        timezone: locationMeta.timezone,
      );

      // ─── Read prior shift_records row → target + timing preservation
      final priorShift = await _readPriorShiftRecordProvenance(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
        daypart: daypart.wire,
      );

      // ─── 5-way covers resolution ─────────────────────────────────
      final coversResolution = _resolveCovers(
        settings: settings,
        keyedServicePeriodSetting: keyedServicePeriodSetting,
        businessDate: businessDate,
        daypart: daypart,
        coverFacts: coverFacts,
        posVendorId: posVendorId,
        reservationFacts: reservationFacts,
        forecastContext: forecastContext,
        periodDefinition: periodDefinition,
        walkInOverride: walkInOverride,
      );
      if (coversResolution == null) {
        // Stage 5: unavailable. Aggregator returns null per contract.
        return null;
      }

      // ─── 4-way wage resolution ───────────────────────────────────
      final laborResolution = _resolveLaborDollars(
        settings: settings,
        laborPunches: laborPunches,
      );

      // ─── Sales (POS-derived; sums actual_sales across cover_facts) ─
      final actualSales = coverFacts.fold<double>(0, (acc, row) {
        final raw = row['actual_sales'];
        if (raw is num) return acc + raw.toDouble();
        return acc;
      });

      // ─── Forecast covers — F&F-derived weekly forecast allocated
      // proportionally; the spine consumes the resolved value as a
      // signal and lets the renderer disambiguate by provenance.
      final forecastCovers = forecastContext?.resolvedWeeklyForecastCovers ?? 0;

      final input = ClosedShiftInput(
        restaurantId: restaurantId,
        businessDate: businessDate,
        weekId: weekId,
        dayLabel: dayLabel,
        daypart: daypart.wire,
        businessTimingProfileId: businessTimingProfileId,
        businessTimingProfileVersionId: businessTimingProfileId == null
            ? null
            : businessTimingProfileVersionId ?? businessTimingProfileId,
        servicePeriodKey: businessTimingProfileId == null
            ? null
            : periodDefinition.id,
        covers: coversResolution.covers,
        forecastCovers: forecastCovers,
        actualSales: actualSales,
        actualFohHours: laborResolution.fohHours,
        actualBohHours: laborResolution.bohHours,
        scheduledFohHours: null,
        scheduledBohHours: null,
        actualFohLaborDollars: laborResolution.fohDollars,
        actualBohLaborDollars: laborResolution.bohDollars,
        sourceSystem: coversResolution.sourceSystem,
        sourceShiftId: null,
      );

      return AggregatorResult(
        input: input,
        provenance: AggregatorProvenanceContext(
          coversProvenance: coversResolution.provenance,
          laborDollarsProvenance: laborResolution.provenance,
          priorTargetProfileVersionId: priorShift?.targetProfileVersionId,
          hasPriorShiftRecord: priorShift != null,
          priorBusinessTimingProfileId: priorShift?.businessTimingProfileId,
          priorBusinessTimingProfileVersionId:
              priorShift?.businessTimingProfileVersionId,
          priorServicePeriodKey: priorShift?.servicePeriodKey,
        ),
      );
    });
  }

  // ─── 5-way covers resolution ───────────────────────────────────────

  _CoversResolution? _resolveCovers({
    required DataAccuracySettings settings,
    required DataAccuracyServicePeriodSetting? keyedServicePeriodSetting,
    required DateTime businessDate,
    required Daypart daypart,
    required List<Map<String, Object?>> coverFacts,
    required String? posVendorId,
    required List<Map<String, Object?>> reservationFacts,
    required DemandForecastContext? forecastContext,
    required ServicePeriodDefinition periodDefinition,
    required ReservationWalkInOverride? walkInOverride,
  }) {
    // Hardening Wave B1 — prefer the keyed setting; legacy column is
    // the read-only fallback until every read path migrates and the
    // legacy column drop ships.
    final operatorPreference = _resolveOperatorCoversPreference(
      settings: settings,
      keyedServicePeriodSetting: keyedServicePeriodSetting,
      daypart: daypart,
    );
    final isoBusinessDate = _isoDate(businessDate);

    // Stage 1 — operator manual entry (overrides everything when
    // the operator picked manual + entered a value for the slot).
    if (operatorPreference == CoversSource.manual) {
      final manual = settings.manualCoversFor(isoBusinessDate, daypart);
      if (manual != null) {
        return _CoversResolution(
          covers: manual,
          provenance: 'operator_manual_entry_per_daypart',
          sourceSystem: 'operator_manual_entry',
        );
      }
      // Manual preferred but no value — fall through to vendor/forecast.
    }

    // Stage 2 — vendor-supplied covers (POS adapter declared
    // coversFieldExposed=true AND vendor fact populated covers).
    if (posVendorId != null) {
      final summed = coverFacts.fold<int>(0, (acc, row) {
        final raw = row['covers'];
        if (raw is int) return acc + raw;
        if (raw is num) return acc + raw.toInt();
        return acc;
      });
      if (summed > 0) {
        return _CoversResolution(
          covers: summed,
          provenance: 'vendor_$posVendorId',
          sourceSystem: posVendorId,
        );
      }
    }

    // Stage 3 — reservation+walk-in (Pattern A: seated_at sum +
    // operator walk-in count). Skips Tock when seated_at absent;
    // bucketing already filtered to slot via reservation_at.
    final resolvedWalkInOverride =
        walkInOverride ??
        _walkInOverrideFromSettings(settings, isoBusinessDate);
    if (reservationFacts.isNotEmpty && resolvedWalkInOverride != null) {
      final seatedSum = reservationFacts.fold<int>(0, (acc, row) {
        final raw = row['party_size'];
        if (raw is int) return acc + raw;
        if (raw is num) return acc + raw.toInt();
        return acc;
      });
      final reservationVendorId =
          reservationFacts.first['vendor_id'] as String? ?? '';
      if (seatedSum > 0 && reservationVendorId.isNotEmpty) {
        return _CoversResolution(
          covers: seatedSum + resolvedWalkInOverride.operatorWalkInCount,
          provenance:
              'vendor_${reservationVendorId}_seated_plus_operator_walk_in_count',
          sourceSystem: reservationVendorId,
        );
      }
    }

    // Stage 4 — forecast substitution (POS missing covers, forecast
    // available). Allocates the resolved weekly forecast across the
    // 7 days of the week; per the contract this is the F&F-derived
    // fallback, never vendor-supplied.
    final resolvedWeekly = forecastContext?.resolvedWeeklyForecastCovers;
    if (resolvedWeekly != null && resolvedWeekly > 0) {
      // Allocate weekly average proportionally to number of dayparts
      // per day (3) and 7 days; the daypart split rule lives in the
      // existing `daypart_plan_allocator.dart` consumer. The spine
      // ships the simple uniform split as the V1 fallback (the
      // dashboard pill flags it as forecast-substituted).
      final dailyShare = (resolvedWeekly / 7).round();
      final daypartShare = (dailyShare / 3).clamp(0, dailyShare).round();
      final vendorBase = posVendorId ?? 'unknown';
      return _CoversResolution(
        covers: daypartShare,
        provenance:
            'vendor_${vendorBase}_covers_unavailable_app_forecast_substituted',
        sourceSystem: posVendorId ?? 'app_forecast',
      );
    }

    // Stage 5 — unavailable.
    return null;
  }

  static ReservationWalkInOverride? _walkInOverrideFromSettings(
    DataAccuracySettings settings,
    String businessDateIso,
  ) {
    switch (settings.walkInHandlingMode) {
      case DataAccuracyWalkInHandlingMode.reservationsOnly:
      case DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately:
        return const ReservationWalkInOverride(operatorWalkInCount: 0);
      case DataAccuracyWalkInHandlingMode.walkInsAddedToReservations:
        final count = settings.walkInCountFor(businessDateIso);
        if (count == null) return null;
        return ReservationWalkInOverride(operatorWalkInCount: count);
    }
  }

  // ─── 4-way wage resolution ─────────────────────────────────────────

  _LaborResolution _resolveLaborDollars({
    required DataAccuracySettings settings,
    required List<Map<String, Object?>> laborPunches,
  }) {
    final fohHours = _sumHours(laborPunches, isFoh: true);
    final bohHours = _sumHours(laborPunches, isFoh: false);

    // Stage 1 — operator manual mix override (always wins).
    if (settings.wageSource == WageSource.manualMix) {
      // Target wage substitution defers to the writer (which has the
      // active TargetSnapshot). Aggregator emits null dollars so
      // ShiftFactBuilder takes the wage*hours fallback path; the
      // provenance string honors the metric honesty contract.
      return _LaborResolution(
        fohHours: fohHours,
        bohHours: bohHours,
        fohDollars: null,
        bohDollars: null,
        provenance: 'target_wage_substituted',
      );
    }

    if (laborPunches.isEmpty) {
      return _LaborResolution(
        fohHours: 0,
        bohHours: 0,
        fohDollars: null,
        bohDollars: null,
        provenance:
            'vendor_unknown_dollars_unavailable_target_wage_substituted',
      );
    }

    final laborVendorId =
        laborPunches.first['vendor_id'] as String? ?? 'unknown';
    final wageClass = laborWageSourceClassFor(laborVendorId);

    // Stage 2 — perEmployeeWithDollars (vendor sums per-shift dollars
    // directly). Currently no Wave B vendor in this class; future
    // 7shifts /reports/hours_and_wages upgrade lands here.
    if (wageClass == LaborWageSourceClass.perEmployeeWithDollars) {
      final fohDollars = _sumDollars(laborPunches, isFoh: true);
      final bohDollars = _sumDollars(laborPunches, isFoh: false);
      if (fohDollars != null || bohDollars != null) {
        return _LaborResolution(
          fohHours: fohHours,
          bohHours: bohHours,
          fohDollars: fohDollars,
          bohDollars: bohDollars,
          provenance: 'vendor_${laborVendorId}_per_employee_actual_dollars',
        );
      }
    }

    // Stage 3 — perPositionWithRates (Humanity, Agendrix). Maps 1:1 to
    // wage_role_rows; aggregator computes dollars via rate × hours
    // per role.
    if (wageClass == LaborWageSourceClass.perPositionWithRates) {
      final fohDollars = _computeRateTimesHours(laborPunches, isFoh: true);
      final bohDollars = _computeRateTimesHours(laborPunches, isFoh: false);
      if (fohDollars != null || bohDollars != null) {
        return _LaborResolution(
          fohHours: fohHours,
          bohHours: bohHours,
          fohDollars: fohDollars,
          bohDollars: bohDollars,
          provenance: 'vendor_${laborVendorId}_per_position_actual_dollars',
        );
      }
    }

    // Stage 4 — perEmployeeWithRates (QBT, 7shifts default). Compute
    // dollars via rate × duration per punch. Same formula as
    // perPositionWithRates but the qualifier suffix preserves the
    // distinction in provenance so the renderer can disambiguate.
    if (wageClass == LaborWageSourceClass.perEmployeeWithRates) {
      final fohDollars = _computeRateTimesHours(laborPunches, isFoh: true);
      final bohDollars = _computeRateTimesHours(laborPunches, isFoh: false);
      if (fohDollars != null || bohDollars != null) {
        return _LaborResolution(
          fohHours: fohHours,
          bohHours: bohHours,
          fohDollars: fohDollars,
          bohDollars: bohDollars,
          provenance:
              'vendor_${laborVendorId}_per_employee_actual_dollars_per_employee_rates',
        );
      }
    }

    // Stage 5 — hoursOnly OR unknown vendor OR rates absent. Fall back
    // to target wage × hours (writer / ShiftFactBuilder applies it).
    return _LaborResolution(
      fohHours: fohHours,
      bohHours: bohHours,
      fohDollars: null,
      bohDollars: null,
      provenance:
          'vendor_${laborVendorId}_dollars_unavailable_target_wage_substituted',
    );
  }

  // ─── Operator covers-source preference (keyed-first, legacy fallback) ─
  //
  // Hardening Wave B1: when a row exists in
  // `data_accuracy_service_period_settings` for this service period
  // at-or-before the closed shift's business date, that row's
  // `covers_source` wins. Otherwise the legacy hardcoded
  // `covers_source_lunch` / `_dinner` / `_late_night` column on
  // `data_accuracy_settings` is read. The legacy columns are
  // read-only fallback while migration of every read path lands; a
  // future migration drops them once the keyed table is the sole
  // source of truth.
  CoversSource _resolveOperatorCoversPreference({
    required DataAccuracySettings settings,
    required DataAccuracyServicePeriodSetting? keyedServicePeriodSetting,
    required Daypart daypart,
  }) {
    if (keyedServicePeriodSetting != null) {
      switch (keyedServicePeriodSetting.coversSource) {
        case ServicePeriodCoversSource.vendor:
          return CoversSource.vendor;
        case ServicePeriodCoversSource.forecast:
          return CoversSource.forecast;
        case ServicePeriodCoversSource.manual:
          return CoversSource.manual;
        case ServicePeriodCoversSource.reservationPlusWalkin:
          // The reservation+walk-in path runs at stage 3 of
          // `_resolveCovers` whenever reservation_facts are present
          // and a walk-in override is supplied. The legacy
          // CoversSource enum has no equivalent value, so we map
          // back to `vendor` (the default preference) and let the
          // existing stage 3 logic flow. A future slice will
          // promote `reservation_plus_walkin` to a first-class
          // operator preference at stage 3.
          return CoversSource.vendor;
      }
    }
    return settings.coversSourceFor(daypart);
  }

  // ─── DAS read (inline, same tenant transaction) ────────────────────

  Future<DataAccuracySettings> _readDataAccuracySettings(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    final rows = await exec.query(
      'select '
      'setting_id::text as setting_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'covers_source_lunch, covers_source_dinner, covers_source_late_night, '
      'covers_manual_entries, wage_source, '
      'walk_in_handling_mode, walk_in_manual_entries, '
      'created_at, updated_at, updated_by '
      'from data_accuracy_settings '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isNotEmpty) {
      return DataAccuracySettings.fromRow(rows.single);
    }
    // Default-row construction matches readOrCreateDefault semantics
    // without paying for the upsert round-trip when the aggregator is
    // running in a read-mostly poll-tick loop.
    return DataAccuracySettings(
      settingId: '',
      operatorId: operatorId,
      locationId: locationId,
      coversSourceLunch: CoversSource.vendor,
      coversSourceDinner: CoversSource.vendor,
      coversSourceLateNight: CoversSource.vendor,
      coversManualEntries: const <String, Map<String, int>>{},
      wageSource: WageSource.vendor,
      createdAt: DateTime.utc(1970, 1, 1),
      updatedAt: DateTime.utc(1970, 1, 1),
    );
  }

  // ─── Keyed service-period setting (inline, same tenant transaction) ─
  //
  // Hardening Wave B1: composing
  // `DataAccuracyServicePeriodSettingsRepository.readEffectiveAt`
  // would open a nested tenant transaction and double the SET LOCAL
  // round-trip; the aggregator inlines a small SELECT against the
  // same executor for the same reason `_readDataAccuracySettings`
  // does. Returns null when no row exists for this service period
  // at-or-before the supplied business date — caller falls back to
  // the legacy column.
  Future<DataAccuracyServicePeriodSetting?> _readKeyedServicePeriodSetting(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required DateTime businessDate,
  }) async {
    final rows = await exec.query(
      'select '
      'id::text as id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'service_period_key, '
      'covers_source, '
      'wage_source, '
      'effective_at_business_date, '
      'created_at, updated_at, updated_by '
      'from public.data_accuracy_service_period_settings '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and service_period_key = @service_period_key '
      'and effective_at_business_date <= @business_date::date '
      'order by effective_at_business_date desc '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'service_period_key': servicePeriodKey,
        'business_date': _isoDate(businessDate),
      },
    );
    if (rows.isEmpty) return null;
    return DataAccuracyServicePeriodSetting.fromRow(rows.single);
  }

  // ─── Location meta ─────────────────────────────────────────────────

  Future<_LocationMeta> _readLocationMeta(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    final rows = await exec.query(
      'select timezone, business_day_rollover_hour '
      'from public.locations '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isEmpty) {
      throw StateError(
        'aggregator: locations row not found for '
        '(operator_id=$operatorId, location_id=$locationId)',
      );
    }
    final row = rows.single;
    return _LocationMeta(
      timezone: (row['timezone'] as String?) ?? 'UTC',
      businessDayRolloverHour: (row['business_day_rollover_hour'] as int?) ?? 0,
    );
  }

  // ─── Canonical fact reads ──────────────────────────────────────────

  Future<List<Map<String, Object?>>> _readCoverFactsForDaypart(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime businessDate,
    required ServicePeriodDefinition periodDefinition,
    required String timezone,
  }) async {
    final rows = await exec.query(
      'select vendor_id, vendor_entity_id, vendor_modified_at, covers, '
      'covers_source, opened_at, closed_at, business_date, actual_sales '
      'from public.cover_facts '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and business_date = @business_date::date',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'business_date': _isoDate(businessDate),
      },
    );
    return rows
        .where(
          (row) => _bucketsToDaypart(
            instant: row['closed_at'],
            periodDefinition: periodDefinition,
            timezone: timezone,
          ),
        )
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _readLaborPunchesForDaypart(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime businessDate,
    required ServicePeriodDefinition periodDefinition,
    required String timezone,
  }) async {
    final rows = await exec.query(
      'select vendor_id, vendor_entity_id, employee_source_id, role_name, '
      'shift_start, shift_end, hours_worked, pay_rate, business_date '
      'from public.labor_punches '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and business_date = @business_date::date',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'business_date': _isoDate(businessDate),
      },
    );
    return rows
        .where(
          (row) => _bucketsToDaypart(
            instant: row['shift_start'],
            periodDefinition: periodDefinition,
            timezone: timezone,
          ),
        )
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _readReservationFactsForDaypart(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime businessDate,
    required ServicePeriodDefinition periodDefinition,
    required String timezone,
  }) async {
    final rows = await exec.query(
      'select vendor_id, vendor_entity_id, reservation_at, party_size, '
      'status, seated_at, business_date '
      'from public.reservation_facts '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and business_date = @business_date::date',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'business_date': _isoDate(businessDate),
      },
    );
    return rows
        .where((row) {
          // Tock reservations have no seated_at; bucket by
          // reservation_at (which Tock's adapter populates from
          // serviceDateTimestamp). Other reservation vendors are
          // bucketed the same way for V1 consistency.
          final status = row['status'];
          if (status is String &&
              status.toUpperCase() != 'SEATED' &&
              status.toUpperCase() != 'COMPLETED') {
            return false;
          }
          return _bucketsToDaypart(
            instant: row['reservation_at'],
            periodDefinition: periodDefinition,
            timezone: timezone,
          );
        })
        .toList(growable: false);
  }

  Future<_PriorShiftRecordProvenance?> _readPriorShiftRecordProvenance(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime businessDate,
    required String daypart,
  }) async {
    final rows = await exec.query(
      'select '
      'target_profile_version_id, '
      'business_timing_profile_id::text as business_timing_profile_id, '
      'business_timing_profile_version_id::text '
      'as business_timing_profile_version_id, '
      'service_period_key '
      'from public.shift_records '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and business_date = @business_date::date '
      'and daypart = @daypart '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'business_date': _isoDate(businessDate),
        'daypart': daypart,
      },
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return _PriorShiftRecordProvenance(
      targetProfileVersionId: _nonBlankString(row['target_profile_version_id']),
      businessTimingProfileId: _nonBlankString(
        row['business_timing_profile_id'],
      ),
      businessTimingProfileVersionId: _nonBlankString(
        row['business_timing_profile_version_id'],
      ),
      servicePeriodKey: _nonBlankString(row['service_period_key']),
    );
  }

  // ─── Daypart bucketing ─────────────────────────────────────────────

  bool _bucketsToDaypart({
    required Object? instant,
    required ServicePeriodDefinition periodDefinition,
    required String timezone,
  }) {
    final utcInstant = _coerceUtc(instant);
    if (utcInstant == null) return false;
    final local = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: timezone,
      instant: utcInstant,
    );
    final start = _parseHHmm(periodDefinition.startLocalTime);
    final end = _parseHHmm(periodDefinition.endLocalTime);
    final localMinutes = local.hour * 60 + local.minute;
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;
    if (periodDefinition.rollsPastMidnight) {
      // e.g. late_night 22:00 → 02:00 spans midnight.
      return localMinutes >= startMinutes || localMinutes < endMinutes;
    }
    return localMinutes >= startMinutes && localMinutes < endMinutes;
  }

  static ({int hour, int minute}) _parseHHmm(String hhmm) {
    final parts = hhmm.split(':');
    return (hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  // ─── Hours / dollars summing helpers ───────────────────────────────

  int _sumHours(List<Map<String, Object?>> punches, {required bool isFoh}) {
    var total = 0.0;
    for (final punch in punches) {
      if (_isFohPunch(punch) != isFoh) continue;
      final raw = punch['hours_worked'];
      if (raw is num) total += raw.toDouble();
    }
    return total.round();
  }

  double? _sumDollars(
    List<Map<String, Object?>> punches, {
    required bool isFoh,
  }) {
    double? total;
    for (final punch in punches) {
      if (_isFohPunch(punch) != isFoh) continue;
      final raw = punch['actual_dollars'];
      if (raw is num) {
        total = (total ?? 0) + raw.toDouble();
      }
    }
    return total;
  }

  double? _computeRateTimesHours(
    List<Map<String, Object?>> punches, {
    required bool isFoh,
  }) {
    double? total;
    for (final punch in punches) {
      if (_isFohPunch(punch) != isFoh) continue;
      final hours = punch['hours_worked'];
      final rate = punch['pay_rate'];
      if (hours is num && rate is num) {
        total = (total ?? 0) + hours.toDouble() * rate.toDouble();
      }
    }
    return total;
  }

  /// Stable role → bucket mapping. FOH = front-of-house (servers,
  /// hosts, bartenders, bussers, runners). BOH = back-of-house (cooks,
  /// dish, prep, kitchen managers).
  bool _isFohPunch(Map<String, Object?> punch) {
    final role = (punch['role_name'] as String? ?? '').toLowerCase();
    const fohRoles = <String>{
      'server',
      'host',
      'hostess',
      'bartender',
      'busser',
      'runner',
      'foh',
      'front_of_house',
      'front-of-house',
    };
    if (fohRoles.contains(role)) return true;
    if (role.contains('foh') ||
        role.contains('server') ||
        role.contains('host')) {
      return true;
    }
    return false;
  }

  // ─── Helpers ───────────────────────────────────────────────────────

  static DateTime? _coerceUtc(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.parse(raw).toUtc();
    }
    return null;
  }

  static String _isoDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String? _nonBlankString(Object? raw) {
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  // The aggregator does not currently emit a JSON structural payload;
  // jsonEncode kept here as a forward-compat helper for the writer's
  // raw-payload preservation rule when the spine gains a sibling
  // structural inspector. Tests exercise the import indirectly.
  // ignore: unused_element
  static String _encodeForensicShape(Object? value) =>
      value == null ? 'null' : jsonEncode(value);
}

// ─── Internal value classes ─────────────────────────────────────────

class _CoversResolution {
  const _CoversResolution({
    required this.covers,
    required this.provenance,
    required this.sourceSystem,
  });
  final int covers;
  final String provenance;
  final String sourceSystem;
}

class _LaborResolution {
  const _LaborResolution({
    required this.fohHours,
    required this.bohHours,
    required this.fohDollars,
    required this.bohDollars,
    required this.provenance,
  });
  final int fohHours;
  final int bohHours;
  final double? fohDollars;
  final double? bohDollars;
  final String provenance;
}

class _LocationMeta {
  const _LocationMeta({
    required this.timezone,
    required this.businessDayRolloverHour,
  });
  final String timezone;
  final int businessDayRolloverHour;
}

class _PriorShiftRecordProvenance {
  const _PriorShiftRecordProvenance({
    required this.targetProfileVersionId,
    required this.businessTimingProfileId,
    required this.businessTimingProfileVersionId,
    required this.servicePeriodKey,
  });

  final String? targetProfileVersionId;
  final String? businessTimingProfileId;
  final String? businessTimingProfileVersionId;
  final String? servicePeriodKey;
}
