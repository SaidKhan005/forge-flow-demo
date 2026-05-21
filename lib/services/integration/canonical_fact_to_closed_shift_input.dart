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
//   2a. Reads `effective_data_accuracy_settings_v` as the effective
//       hierarchy answer for Covers source values and source metadata.
//       When the effective source metadata says the winning value is
//       the location keyed base row, the aggregator performs a second,
//       date-aware lookup against `data_accuracy_service_period_settings`
//       so historical closed shifts resolve under the keyed setting in
//       force on the closed shift's business date. Scoped overrides
//       from the effective hierarchy answer remain authoritative.
//       Manual covers VALUES still come from the legacy
//       `covers_manual_entries` jsonb (manual-entry storage migration
//       is a future slice).
//   3. Resolves covers via the decision chain per
//      `data_accuracy_settings_contract.md` (manual / vendor /
//      reservation+walk-in / manual-pos-fallback / forecast /
//      unavailable). Stage 3 (reservation+walk-in Pattern A/B/C) is
//      implemented from the durable walk-in fields on
//      `data_accuracy_settings`; explicit [ReservationWalkInOverride]
//      remains a test/backfill seam. Stage 3.5 (Wave 2 MO-2-FU,
//      Option A — fallback-only) projects operator manual covers into
//      the model ONLY when the active POS does NOT expose covers; POS
//      remains the source of truth for vendors with
//      `VendorCapabilityProfile.coversFieldExposed=true` (Toast, Aloha,
//      Lightspeed K-Series, Oracle MICROS Simphony, Revel).
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
import '../../domain/models/business_timing_profile.dart';
import '../../domain/models/closed_shift_input.dart';
import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/demand_forecast_context.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/schedule_distribution_weights.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/business_timing_profile_resolver.dart';
import '../../domain/services/daypart_bucketer.dart';
import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../daypart_plan_allocator.dart';
import 'close_authority_capability.dart';
import 'iana_timezone_converter.dart';
import 'labor_wage_source_class.dart';
import 'pos_covers_capability.dart';

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
  static const String _fallbackBusinessDayStartLocalTime = '04:00';

  static const String _timingProfileColumns =
      'p.profile_id::text as profile_id, '
      'p.operator_id::text as operator_id, '
      'p.scope_type, '
      'p.scope_id::text as scope_id, '
      'p.display_name, '
      'p.business_day_start_local_time::text as business_day_start_local_time, '
      'p.week_start_day, '
      'p.close_authority, '
      'p.local_close_fallback_time::text as local_close_fallback_time, '
      'p.effective_from_business_date::text '
      'as effective_from_business_date, '
      'p.effective_until_business_date::text '
      'as effective_until_business_date, '
      'p.supersedes_profile_id::text as supersedes_profile_id, '
      'p.created_by::text as created_by, '
      'p.updated_by::text as updated_by, '
      'p.created_at, '
      'p.updated_at';

  static const String _timingPeriodJson =
      "coalesce(jsonb_agg(jsonb_build_object("
      "'service_period_id', sp.service_period_id::text, "
      "'operator_id', sp.operator_id::text, "
      "'profile_id', sp.profile_id::text, "
      "'service_period_key', sp.service_period_key, "
      "'label', sp.label, "
      "'short_label', sp.short_label, "
      "'sort_order', sp.sort_order, "
      "'start_local_time', sp.start_local_time::text, "
      "'end_local_time', sp.end_local_time::text, "
      "'rolls_past_midnight', sp.rolls_past_midnight, "
      "'applicable_weekdays', sp.applicable_weekdays"
      ") order by sp.sort_order) filter "
      "(where sp.service_period_id is not null), '[]'::jsonb) "
      'as service_periods';

  static const String _timingCandidateChainSql =
      'with selected_location as ('
      '  select '
      '    loc.location_id, '
      '    loc.timezone as location_timezone, '
      '    loc.org_unit_path '
      '  from public.locations loc '
      '  where loc.operator_id = @operator_id::uuid '
      '    and loc.location_id = @location_id::uuid'
      '), candidate_scopes as ('
      "  select 'operator'::text as scope_type, "
      '         @operator_id::uuid as scope_id, '
      '         0::integer as scope_depth '
      '  union all '
      "  select 'org_unit'::text as scope_type, "
      '         ou.id as scope_id, '
      '         nlevel(ou.path)::integer as scope_depth '
      '  from public.org_units ou '
      '  join selected_location loc on ou.path @> loc.org_unit_path '
      '  where ou.operator_id = @operator_id::uuid '
      '  union all '
      "  select 'location'::text as scope_type, "
      '         loc.location_id as scope_id, '
      '         100000::integer as scope_depth '
      '  from selected_location loc'
      ') '
      'select $_timingProfileColumns, '
      '       loc.location_timezone, '
      '       $_timingPeriodJson '
      'from public.business_timing_profiles p '
      'join candidate_scopes scope '
      '  on scope.scope_type = p.scope_type '
      ' and scope.scope_id = p.scope_id '
      'cross join selected_location loc '
      'left join public.business_timing_service_periods sp '
      '  on sp.operator_id = p.operator_id '
      ' and sp.profile_id = p.profile_id '
      'where p.operator_id = @operator_id::uuid '
      '  and p.effective_from_business_date <= @business_date::date '
      '  and ('
      '    p.effective_until_business_date is null '
      '    or @business_date::date < p.effective_until_business_date'
      '  ) '
      'group by '
      '  p.profile_id, p.operator_id, p.scope_type, p.scope_id, '
      '  p.display_name, p.business_day_start_local_time, '
      '  p.week_start_day, p.close_authority, '
      '  p.local_close_fallback_time, '
      '  p.effective_from_business_date, '
      '  p.effective_until_business_date, '
      '  p.supersedes_profile_id, p.created_by, p.updated_by, '
      '  p.created_at, p.updated_at, loc.location_timezone, '
      '  scope.scope_depth '
      'order by scope.scope_depth asc, '
      '         p.effective_from_business_date asc, '
      '         p.created_at asc';

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
  ///
  /// Per-Daypart V1 — Slice 1.5 (Gaps 20, 21, 25, 26):
  ///   * POS / reservation rows are filtered through [DaypartBucketer]
  ///     so the closed-shift aggregator uses the same boundary-inclusive
  ///     semantics as the live read.
  ///   * Labor punches are read over a 3-day business-date window and
  ///     split into per-period segments via
  ///     [DaypartBucketer.bucketLaborPunch] so cross-period and
  ///     cross-(business-date) punches contribute the correct minutes
  ///     to each (business_date, service_period_id) slot.
  ///   * The stage-4 forecast-covers fallback now uses
  ///     `DaypartPlanAllocator` with the operator's full
  ///     [allServicePeriodDefinitions] list and optional
  ///     [distributionWeights]; the legacy "uniform / 3" divide is
  ///     gone.
  ///
  /// [allServicePeriodDefinitions] is the operator's full configured
  /// list of service periods (lunch, dinner, late_night, brunch, etc.).
  /// When omitted, the aggregator falls back to `[periodDefinition]`
  /// only — this preserves backward compatibility with callers that
  /// haven't been upgraded yet, but the forecast-fallback covers split
  /// will degrade to whole-day allocation.
  Future<AggregatorResult?> aggregate({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required DateTime businessDate,
    required String weekId,
    required String dayLabel,
    required String servicePeriodId,
    required ServicePeriodDefinition periodDefinition,
    List<ServicePeriodDefinition>? allServicePeriodDefinitions,
    ScheduleDistributionWeights? distributionWeights,
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

      final useDateAwareKeyedBase = _effectiveCoversSourceIsKeyedBase(
        settings,
        servicePeriodId,
      );
      final keyedServicePeriodSetting = useDateAwareKeyedBase
          ? await _readDateAwareKeyedServicePeriodSetting(
              exec,
              operatorId: operatorId,
              locationId: locationId,
              servicePeriodKey: servicePeriodId,
              businessDate: businessDate,
            )
          : null;

      final locationMeta = await _readLocationMeta(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
      );

      // Per-Daypart V1 Slice 1.5: every fact-bucketing call goes
      // through the canonical [DaypartBucketer] so the closed-shift
      // aggregator and the live `OpenShiftSnapshotProjector` share
      // boundary-inclusivity, applicableDays handling, and
      // cross-(business-date) splits.
      final bucketingContext = BucketingLocationContext(
        iana: locationMeta.timezone,
        businessDayStartLocalTime: locationMeta.businessDayStartLocalTime,
      );
      final periodDefinitions = allServicePeriodDefinitions == null
          ? <ServicePeriodDefinition>[periodDefinition]
          : List<ServicePeriodDefinition>.unmodifiable(
              allServicePeriodDefinitions,
            );

      // ─── Walk POS cover_facts → buckets to this daypart ──────────
      final coverFacts = await _readCoverFactsForDaypart(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
        periodDefinition: periodDefinition,
        periodDefinitions: periodDefinitions,
        bucketingContext: bucketingContext,
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
          daypart: servicePeriodId,
          vendorIds: posVendorIds,
        );
      }
      final posVendorId = posVendorIds.isNotEmpty ? posVendorIds.first : null;

      // ─── Walk labor_punches → per-period interval split ─────────
      //
      // Per-Daypart V1 Slice 1.5 (Gap 21, Promise 3): an 8-hour FOH
      // punch crossing lunch→dinner is split into the minutes that
      // overlap each period via [DaypartBucketer.bucketLaborPunch],
      // not attributed wholesale to the period containing the punch's
      // start instant. Cross-(business-date) handling (Gap 26) reads
      // punches whose stored `business_date` is the day before or the
      // day after [businessDate], then keeps only the segments whose
      // anchored period belongs to [businessDate].
      final laborPunches = await _readLaborPunchesForBusinessDate(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
      );
      final laborSplit = _splitLaborPunchesByPeriod(
        punches: laborPunches,
        bucketingContext: bucketingContext,
        periodDefinitions: periodDefinitions,
        targetServicePeriodId: periodDefinition.id,
        targetBusinessDateIso: _isoDate(businessDate),
        timezone: locationMeta.timezone,
      );

      // ─── Walk reservation_facts for slot (Tock seated_at-free) ──
      final reservationFacts = await _readReservationFactsForDaypart(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
        periodDefinition: periodDefinition,
        periodDefinitions: periodDefinitions,
        bucketingContext: bucketingContext,
      );

      // ─── Read prior shift_records row → target + timing preservation
      final priorShift = await _readPriorShiftRecordProvenance(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
        daypart: servicePeriodId,
      );

      // ─── 5-way covers resolution ─────────────────────────────────
      final coversResolution = _resolveCovers(
        settings: settings,
        keyedServicePeriodSetting: keyedServicePeriodSetting,
        useDateAwareKeyedBase: useDateAwareKeyedBase,
        businessDate: businessDate,
        dayLabel: dayLabel,
        servicePeriodId: servicePeriodId,
        coverFacts: coverFacts,
        posVendorId: posVendorId,
        reservationFacts: reservationFacts,
        forecastContext: forecastContext,
        periodDefinition: periodDefinition,
        periodDefinitions: periodDefinitions,
        distributionWeights: distributionWeights,
        walkInOverride: walkInOverride,
      );
      if (coversResolution == null) {
        // Stage 5: unavailable. Aggregator returns null per contract.
        return null;
      }

      // ─── 4-way wage resolution ───────────────────────────────────
      final laborResolution = _resolveLaborDollars(
        settings: settings,
        laborPunches: laborSplit.punchesForPeriod,
        fohHoursOverride: laborSplit.fohHoursInPeriod,
        bohHoursOverride: laborSplit.bohHoursInPeriod,
        perPunchHoursInPeriod: laborSplit.perPunchHoursInPeriod,
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
        daypart: servicePeriodId,
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

      // Per-Daypart V1 Slice 1.5 — auto-derive close-authority
      // provenance from the POS vendor's capability. No operator
      // setting input — the choice is per-vendor + business-day-start
      // fallback (operator decision 2026-05-15).
      final closeAuthorityProvenance = _closeAuthorityProvenance(
        posVendorId: posVendorId,
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
          closeAuthorityProvenance: closeAuthorityProvenance,
        ),
      );
    });
  }

  /// Per-Daypart V1 Slice 1.5 — close-authority provenance string.
  /// Reads the per-vendor capability from
  /// [closeAuthorityCapabilityFor] and stamps the wire shape consumed
  /// by downstream finalization-eligibility checks.
  static String _closeAuthorityProvenance({required String? posVendorId}) {
    if (posVendorId == null || posVendorId.isEmpty) {
      return 'no_pos_vendor_business_day_start_fallback';
    }
    final capability = resolveCloseAuthorityCapability(posVendorId);
    switch (capability) {
      case CloseAuthorityCapability.vendorReliableFinalization:
        return 'vendor_${posVendorId}_reliable_finalization';
      case CloseAuthorityCapability.unreliableFallbackToBusinessDayStart:
        return 'vendor_${posVendorId}_unreliable_finalization_'
            'business_day_start_fallback';
    }
  }

  // ─── 5-way covers resolution ───────────────────────────────────────

  _CoversResolution? _resolveCovers({
    required DataAccuracySettings settings,
    required DataAccuracyServicePeriodSetting? keyedServicePeriodSetting,
    required bool useDateAwareKeyedBase,
    required DateTime businessDate,
    required String dayLabel,
    required String servicePeriodId,
    required List<Map<String, Object?>> coverFacts,
    required String? posVendorId,
    required List<Map<String, Object?>> reservationFacts,
    required DemandForecastContext? forecastContext,
    required ServicePeriodDefinition periodDefinition,
    required List<ServicePeriodDefinition> periodDefinitions,
    required ScheduleDistributionWeights? distributionWeights,
    required ReservationWalkInOverride? walkInOverride,
  }) {
    final operatorPreference = _resolveOperatorCoversPreference(
      settings: settings,
      keyedServicePeriodSetting: keyedServicePeriodSetting,
      useDateAwareKeyedBase: useDateAwareKeyedBase,
      servicePeriodId: servicePeriodId,
    );
    final isoBusinessDate = _isoDate(businessDate);

    // Stage 1 — operator manual entry (overrides everything when
    // the operator picked manual + entered a value for the slot).
    if (operatorPreference == _OperatorCoversPreference.manual) {
      final manual = settings.manualCoversFor(isoBusinessDate, servicePeriodId);
      if (manual != null) {
        return _CoversResolution(
          covers: manual,
          provenance: 'operator_manual_entry_per_daypart',
          sourceSystem: 'operator_manual_entry',
        );
      }
      return null;
    }

    if (operatorPreference == _OperatorCoversPreference.forecast) {
      return _resolveForecastCovers(
        dayLabel: dayLabel,
        posVendorId: posVendorId,
        forecastContext: forecastContext,
        periodDefinition: periodDefinition,
        periodDefinitions: periodDefinitions,
        distributionWeights: distributionWeights,
        explicitOperatorForecast: true,
      );
    }

    // Stage 2: vendor-supplied covers (POS adapter declared
    // coversFieldExposed=true AND vendor fact populated covers).
    if (operatorPreference == _OperatorCoversPreference.vendor &&
        posVendorId != null &&
        posVendorExposesCovers(posVendorId) == true) {
      var hasVendorCovers = false;
      final summed = coverFacts.fold<int>(0, (acc, row) {
        final raw = row['covers'];
        if (raw is int) {
          hasVendorCovers = true;
          return acc + raw;
        }
        if (raw is num) {
          hasVendorCovers = true;
          return acc + raw.toInt();
        }
        return acc;
      });
      if (hasVendorCovers) {
        return _CoversResolution(
          covers: summed,
          provenance: 'vendor_$posVendorId',
          sourceSystem: posVendorId,
        );
      }
    }

    // Stage 3 — reservation+walk-in (Pattern A: seated party_size +
    // operator walk-in count). Bucketing already filtered to this slot
    // via reservation_at / seated_at according to vendor availability.
    if (operatorPreference == _OperatorCoversPreference.reservationPlusWalkin) {
      final resolvedWalkInOverride =
          walkInOverride ??
          _walkInOverrideFromSettings(
            settings,
            isoBusinessDate,
            dayLabel: dayLabel,
            servicePeriodId: servicePeriodId,
            periodDefinition: periodDefinition,
            periodDefinitions: periodDefinitions,
            distributionWeights: distributionWeights,
          );
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
      return null;
    }

    // Stage 3.5 — Wave 2 MO-2-FU (Option A, fallback-only) — operator
    // manual entries fall back into the projection ONLY when the active
    // POS does NOT expose a covers field on its canonical sales rows
    // (e.g. Square, Clover, or an unknown vendor F&F cannot classify).
    //
    // When POS DOES expose covers (Toast, Aloha, Lightspeed K-Series,
    // Oracle MICROS Simphony, Revel — see
    // `lib/services/integration/pos_covers_capability.dart`), the POS
    // feed is the source of truth and manual entries are ignored at
    // this stage (stage 2 already returned above). The Settings ->
    // Setup form may still surface historical manual entries for the
    // operator, but they do NOT contribute to the model.
    //
    // This matches `docs/contracts/data_accuracy_settings_contract.md`
    // "vendor-fallback" framing: manual is the primary path when POS
    // cannot supply covers, and the forecast substitution (stage 4
    // below) is the secondary fallback when neither vendor nor manual
    // values are available.
    //
    // Provenance string differs from stage 1's
    // `operator_manual_entry_per_daypart` so the renderer can
    // disambiguate: stage 1 is the operator-elected manual path
    // (operator picked `CoversSource.manual` in Data Accuracy);
    // stage 3.5 is the automatic POS-capability fallback.
    if (_posLacksCoversCapability(posVendorId)) {
      final manual = settings.manualCoversFor(isoBusinessDate, servicePeriodId);
      if (manual != null) {
        return _CoversResolution(
          covers: manual,
          provenance: 'operator_manual_entry_fallback_pos_not_exposed',
          sourceSystem: 'operator_manual_entry',
        );
      }
    }

    // Stage 4 — forecast substitution (POS missing covers, forecast
    // available). Per-Daypart V1 Slice 1.5 (Gap 25): the previous
    // `dailyShare / 3` hardcode is replaced by
    // [DaypartPlanAllocator.allocate] so the per-period split honors
    // the operator's full configured period list + optional
    // distribution weights, instead of pretending every restaurant
    // has exactly three uniformly-weighted dayparts.
    return _resolveForecastCovers(
      dayLabel: dayLabel,
      posVendorId: posVendorId,
      forecastContext: forecastContext,
      periodDefinition: periodDefinition,
      periodDefinitions: periodDefinitions,
      distributionWeights: distributionWeights,
      explicitOperatorForecast: false,
    );
  }

  _CoversResolution? _resolveForecastCovers({
    required String dayLabel,
    required String? posVendorId,
    required DemandForecastContext? forecastContext,
    required ServicePeriodDefinition periodDefinition,
    required List<ServicePeriodDefinition> periodDefinitions,
    required ScheduleDistributionWeights? distributionWeights,
    required bool explicitOperatorForecast,
  }) {
    final resolvedWeekly = forecastContext?.resolvedWeeklyForecastCovers;
    if (resolvedWeekly != null && resolvedWeekly > 0) {
      final dailyShare = (resolvedWeekly / 7).round();
      // Legacy/Gap-42 empty-dayDayparts fallback path is the one
      // carve-out the DaypartPlanAllocator deprecation explicitly
      // preserves (per Per-Daypart V1 Slice 3/5 deprecation note on
      // the class).
      // ignore: deprecated_member_use_from_same_package
      final allocations = DaypartPlanAllocator.allocate(
        day: dayLabel,
        dayCovers: dailyShare,
        // Sales / hours don't affect the cover split; pass through
        // safe zero values that won't influence the largest-remainder
        // math.
        daySales: 0,
        dayFohHours: 0,
        dayBohHours: 0,
        definitions: periodDefinitions,
        distributionWeights: distributionWeights,
      );
      final allocation = allocations.firstWhere(
        (a) => a.daypartId == periodDefinition.id,
        orElse: () => const DaypartAllocation(
          daypartId: '',
          label: '',
          forecastCovers: 0,
          forecastSales: 0,
          requiredFohHours: 0,
          requiredBohHours: 0,
        ),
      );
      final daypartShare = allocation.forecastCovers;
      if (explicitOperatorForecast) {
        return _CoversResolution(
          covers: daypartShare,
          provenance: 'app_forecast_60_day_avg',
          sourceSystem: 'app_forecast',
        );
      }
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

  /// Wave 2 MO-2-FU — POS-capability fallback predicate.
  ///
  /// Returns true when the active POS vendor is known to NOT expose a
  /// covers field on its canonical sales rows (Square, Clover today),
  /// OR when there is no active POS at all / the vendor is unknown to
  /// F&F's capability mirror. The mirror lives in
  /// `lib/services/integration/pos_covers_capability.dart` and is
  /// kept in sync with the per-adapter `VendorCapabilityProfile`
  /// declarations (one entry per Wave B POS adapter; a contract test
  /// pins the mirror to adapter truth).
  ///
  /// "Unknown" vendors are treated as "lacks coverage" because the
  /// safer assumption when F&F cannot classify the vendor is that POS
  /// covers cannot be trusted; manual entries (if any) take the
  /// fallback slot ahead of forecast substitution.
  static bool _posLacksCoversCapability(String? posVendorId) {
    return posVendorExposesCovers(posVendorId) != true;
  }

  static ReservationWalkInOverride? _walkInOverrideFromSettings(
    DataAccuracySettings settings,
    String businessDateIso, {
    required String dayLabel,
    required String servicePeriodId,
    required ServicePeriodDefinition periodDefinition,
    required List<ServicePeriodDefinition> periodDefinitions,
    required ScheduleDistributionWeights? distributionWeights,
  }) {
    switch (settings.walkInHandlingMode) {
      case DataAccuracyWalkInHandlingMode.reservationsOnly:
      case DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately:
        return const ReservationWalkInOverride(operatorWalkInCount: 0);
      case DataAccuracyWalkInHandlingMode.walkInsAddedToReservations:
        final periodCount = settings.perServicePeriodWalkInCountFor(
          businessDateIso,
          servicePeriodId,
        );
        if (periodCount != null) {
          return ReservationWalkInOverride(operatorWalkInCount: periodCount);
        }
        final dailyCount = settings.dailyWalkInCountFor(businessDateIso);
        if (dailyCount == null) return null;
        if (dailyCount <= 0) {
          return const ReservationWalkInOverride(operatorWalkInCount: 0);
        }
        // Legacy daily walk-in totals are now split with the same
        // service-period allocation seam as forecast covers. That
        // keeps old payloads working without cloning the whole daily
        // number into every reservation+walk-in period.
        // ignore: deprecated_member_use_from_same_package
        final allocations = DaypartPlanAllocator.allocate(
          day: dayLabel,
          dayCovers: dailyCount,
          daySales: 0,
          dayFohHours: 0,
          dayBohHours: 0,
          definitions: periodDefinitions,
          distributionWeights: distributionWeights,
        );
        final allocation = allocations.firstWhere(
          (a) => a.daypartId == periodDefinition.id,
          orElse: () => const DaypartAllocation(
            daypartId: '',
            label: '',
            forecastCovers: 0,
            forecastSales: 0,
            requiredFohHours: 0,
            requiredBohHours: 0,
          ),
        );
        return ReservationWalkInOverride(
          operatorWalkInCount: allocation.forecastCovers,
        );
    }
  }

  // ─── 4-way wage resolution ─────────────────────────────────────────

  _LaborResolution _resolveLaborDollars({
    required DataAccuracySettings settings,
    required List<Map<String, Object?>> laborPunches,
    int? fohHoursOverride,
    int? bohHoursOverride,
    Map<Map<String, Object?>, double>? perPunchHoursInPeriod,
  }) {
    // Per-Daypart V1 Slice 1.5 (Gap 21): hours come from
    // `DaypartBucketer.bucketLaborPunch` per-period segments, not from
    // summing punch-level `hours_worked` (which would over-attribute
    // cross-period punches). [perPunchHoursInPeriod] (when present)
    // carries the per-punch minutes-in-period the splitter computed,
    // letting the rate × hours stages compute dollars from the
    // exact per-period overlap rather than the punch's full duration.
    final fohHours = fohHoursOverride ?? _sumHours(laborPunches, isFoh: true);
    final bohHours = bohHoursOverride ?? _sumHours(laborPunches, isFoh: false);

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
    //
    // Per-period scaling: dollars per row are multiplied by
    // `minutesInPeriod / punchDurationMinutes` so a punch spanning
    // lunch + dinner contributes the correct slice of its `actual_dollars`
    // to each period.
    if (wageClass == LaborWageSourceClass.perEmployeeWithDollars) {
      final fohDollars = _sumDollars(
        laborPunches,
        isFoh: true,
        perPunchHoursInPeriod: perPunchHoursInPeriod,
      );
      final bohDollars = _sumDollars(
        laborPunches,
        isFoh: false,
        perPunchHoursInPeriod: perPunchHoursInPeriod,
      );
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
      final fohDollars = _computeRateTimesHours(
        laborPunches,
        isFoh: true,
        perPunchHoursInPeriod: perPunchHoursInPeriod,
      );
      final bohDollars = _computeRateTimesHours(
        laborPunches,
        isFoh: false,
        perPunchHoursInPeriod: perPunchHoursInPeriod,
      );
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
      final fohDollars = _computeRateTimesHours(
        laborPunches,
        isFoh: true,
        perPunchHoursInPeriod: perPunchHoursInPeriod,
      );
      final bohDollars = _computeRateTimesHours(
        laborPunches,
        isFoh: false,
        perPunchHoursInPeriod: perPunchHoursInPeriod,
      );
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

  // ─── Operator covers-source preference (keyed by service period) ─
  //
  // The effective hierarchy answer is authoritative. Raw keyed rows
  // are only considered when the effective view's source metadata says
  // this service period is sourced from the keyed base row. In that
  // case, the raw lookup is used only to preserve the closed shift's
  // historical business-date semantics; a keyed row that was not yet
  // effective on the closed date resolves back to the vendor default.
  _OperatorCoversPreference _resolveOperatorCoversPreference({
    required DataAccuracySettings settings,
    required DataAccuracyServicePeriodSetting? keyedServicePeriodSetting,
    required bool useDateAwareKeyedBase,
    required String servicePeriodId,
  }) {
    if (useDateAwareKeyedBase) {
      if (keyedServicePeriodSetting == null) {
        return _OperatorCoversPreference.vendor;
      }
      switch (keyedServicePeriodSetting.coversSource) {
        case ServicePeriodCoversSource.vendor:
          return _OperatorCoversPreference.vendor;
        case ServicePeriodCoversSource.forecast:
          return _OperatorCoversPreference.forecast;
        case ServicePeriodCoversSource.manual:
          return _OperatorCoversPreference.manual;
        case ServicePeriodCoversSource.reservationPlusWalkin:
          return _OperatorCoversPreference.reservationPlusWalkin;
      }
    }
    switch (settings.coversSourceFor(servicePeriodId)) {
      case CoversSource.vendor:
        return _OperatorCoversPreference.vendor;
      case CoversSource.forecast:
        return _OperatorCoversPreference.forecast;
      case CoversSource.manual:
        return _OperatorCoversPreference.manual;
      case CoversSource.reservationPlusWalkin:
        return _OperatorCoversPreference.reservationPlusWalkin;
    }
  }

  static bool _effectiveCoversSourceIsKeyedBase(
    DataAccuracySettings settings,
    String servicePeriodId,
  ) {
    final source = settings.coversSourceSourceFor(servicePeriodId);
    return source?.sourceKind == 'service_period_setting';
  }

  // ─── DAS read (inline, same tenant transaction) ────────────────────

  Future<DataAccuracySettings> _readDataAccuracySettings(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    // R7f: the hierarchy view is the source of truth for effective
    // Covers values and source metadata. Date-aware raw keyed rows are
    // read separately only when this effective answer says the keyed
    // base row is the winning source for the requested service period.
    final rows = await exec.query(
      'select '
      'setting_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'covers_source_per_service_period, '
      'covers_source_per_service_period_source, '
      'covers_manual_entries, '
      'wage_source, '
      'wage_source_source, '
      'walk_in_handling_mode, '
      'walk_in_handling_mode_source, '
      'walk_in_manual_entries, '
      'created_at, updated_at, updated_by '
      'from public.effective_data_accuracy_settings_v '
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
    // running in a read-mostly poll-tick loop. An empty per-period map
    // resolves every period to the `vendor` default via
    // [DataAccuracySettings.coversSourceFor].
    return DataAccuracySettings(
      settingId: '',
      operatorId: operatorId,
      locationId: locationId,
      coversSourcePerServicePeriod: const <String, CoversSource>{},
      coversManualEntries: const <String, Map<String, int>>{},
      wageSource: WageSource.vendor,
      createdAt: DateTime.utc(1970, 1, 1),
      updatedAt: DateTime.utc(1970, 1, 1),
    );
  }

  // ─── Keyed service-period setting (inline, same tenant transaction) ─
  //
  // R7f date-aware base preservation: composing
  // `DataAccuracyServicePeriodSettingsRepository.readEffectiveAt`
  // would open a nested tenant transaction and double the SET LOCAL
  // round-trip; the aggregator inlines a small SELECT against the
  // same executor for the same reason `_readDataAccuracySettings`
  // does. This is only called after the effective hierarchy view says
  // the service period's winning source is the keyed base row. Returns
  // null when no raw keyed row exists at-or-before the closed shift's
  // business date.
  Future<DataAccuracyServicePeriodSetting?>
  _readDateAwareKeyedServicePeriodSetting(
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
    required DateTime businessDate,
  }) async {
    final candidates = await _readBusinessTimingProfilesForLocation(
      exec,
      operatorId: operatorId,
      locationId: locationId,
      businessDate: _isoDate(businessDate),
    );
    if (candidates.isNotEmpty) {
      final effective = BusinessTimingProfileResolver.resolve(candidates);
      return _LocationMeta(
        timezone: effective.businessTimezone,
        businessDayStartLocalTime: effective.businessDayStartLocalTime,
      );
    }

    final timezone = await _readLocationTimezone(
      exec,
      operatorId: operatorId,
      locationId: locationId,
    );
    return _LocationMeta(
      timezone: timezone,
      businessDayStartLocalTime: _fallbackBusinessDayStartLocalTime,
    );
  }

  Future<List<BusinessTimingProfile>> _readBusinessTimingProfilesForLocation(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String businessDate,
  }) async {
    final rows = await exec.query(
      _timingCandidateChainSql,
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'business_date': businessDate,
      },
    );
    return <BusinessTimingProfile>[
      for (final row in rows) _businessTimingProfileFromRow(row),
    ];
  }

  Future<String> _readLocationTimezone(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    final rows = await exec.query(
      'select timezone '
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
    final timezone = (row['timezone'] as String?)?.trim();
    return timezone == null || timezone.isEmpty ? 'UTC' : timezone;
  }

  BusinessTimingProfile _businessTimingProfileFromRow(PostgresRow row) {
    final servicePeriods = _timingServicePeriodsFromValue(
      row['service_periods'],
    );
    return BusinessTimingProfile(
      profileId: row['profile_id']! as String,
      scope: BusinessTimingScope.fromValue(row['scope_type']! as String),
      scopeId: row['scope_id']! as String,
      businessTimezone: row['location_timezone'] as String?,
      businessDayStartLocalTime: _trimTimingTime(
        row['business_day_start_local_time'],
      ),
      weekStartDay: row['week_start_day']! as int,
      servicePeriodDefinitions: servicePeriods.isEmpty
          ? null
          : List<ServicePeriodDefinition>.unmodifiable(servicePeriods),
      shiftCloseAuthority: ShiftCloseAuthority.fromValue(
        row['close_authority']! as String,
      ),
      localCloseFallback: _trimNullableTimingTime(
        row['local_close_fallback_time'],
      ),
    );
  }

  List<ServicePeriodDefinition> _timingServicePeriodsFromValue(Object? value) {
    if (value == null) return const <ServicePeriodDefinition>[];
    final dynamic decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! List<dynamic>) {
      throw StateError('service_periods JSON was not a list');
    }
    return <ServicePeriodDefinition>[
      for (final item in decoded)
        _timingServicePeriodFromJson(_jsonObjectFromValue(item)),
    ];
  }

  ServicePeriodDefinition _timingServicePeriodFromJson(
    Map<String, Object?> json,
  ) {
    return ServicePeriodDefinition(
      id: json['service_period_key']! as String,
      label: json['label']! as String,
      shortLabel: json['short_label'] as String? ?? '',
      sortOrder: json['sort_order']! as int,
      startLocalTime: _trimTimingTime(json['start_local_time']),
      endLocalTime: _trimTimingTime(json['end_local_time']),
      rollsPastMidnight: json['rolls_past_midnight'] as bool? ?? false,
      applicableDays: _intListFromValue(json['applicable_weekdays']),
    );
  }

  static Map<String, Object?> _jsonObjectFromValue(Object? value) {
    final dynamic decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! Map<dynamic, dynamic>) {
      throw StateError('JSON value was not an object');
    }
    return <String, Object?>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
  }

  static List<int> _intListFromValue(Object? value) {
    if (value is List<int>) return value;
    if (value is List<dynamic>) {
      return <int>[for (final item in value) (item as num).toInt()];
    }
    throw StateError('integer array value was not a list');
  }

  static String _trimTimingTime(Object? value) {
    final text = value as String;
    return text.length >= 5 ? text.substring(0, 5) : text;
  }

  static String? _trimNullableTimingTime(Object? value) {
    if (value == null) return null;
    final text = value as String;
    return text.length >= 5 ? text.substring(0, 5) : text;
  }

  // ─── Canonical fact reads ──────────────────────────────────────────

  Future<List<Map<String, Object?>>> _readCoverFactsForDaypart(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime businessDate,
    required ServicePeriodDefinition periodDefinition,
    required List<ServicePeriodDefinition> periodDefinitions,
    required BucketingLocationContext bucketingContext,
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
          (row) => _posInstantInPeriod(
            instant: row['closed_at'],
            bucketingContext: bucketingContext,
            periodDefinitions: periodDefinitions,
            targetServicePeriodId: periodDefinition.id,
          ),
        )
        .toList(growable: false);
  }

  /// Per-Daypart V1 Slice 1.5 (Gaps 21, 26): read every punch row whose
  /// stored `business_date` is within ±1 day of [businessDate]. The
  /// caller then runs `DaypartBucketer.bucketLaborPunch` per row and
  /// keeps only the per-period segments whose anchored business date
  /// matches [businessDate]. The 3-day window is the minimum that
  /// captures (a) a punch starting before [businessDate]'s rollover
  /// whose tail bleeds into [businessDate]'s lunch, and (b) a punch
  /// starting before [businessDate]'s late-night that bleeds past
  /// [businessDate]'s next-day rollover.
  Future<List<Map<String, Object?>>> _readLaborPunchesForBusinessDate(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime businessDate,
  }) async {
    final priorDate = businessDate.subtract(const Duration(days: 1));
    final nextDate = businessDate.add(const Duration(days: 1));
    final rows = await exec.query(
      'select vendor_id, vendor_entity_id, employee_source_id, role_name, '
      'shift_start, shift_end, hours_worked, pay_rate, business_date '
      'from public.labor_punches '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and business_date between @prior_business_date::date '
      'and @next_business_date::date',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'prior_business_date': _isoDate(priorDate),
        'next_business_date': _isoDate(nextDate),
      },
    );
    return rows.toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _readReservationFactsForDaypart(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime businessDate,
    required ServicePeriodDefinition periodDefinition,
    required List<ServicePeriodDefinition> periodDefinitions,
    required BucketingLocationContext bucketingContext,
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
          return _posInstantInPeriod(
            instant: row['reservation_at'],
            bucketingContext: bucketingContext,
            periodDefinitions: periodDefinitions,
            targetServicePeriodId: periodDefinition.id,
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

  // ─── Daypart bucketing (Per-Daypart V1 Slice 1.5) ──────────────────
  //
  // Every bucketing decision now flows through the canonical
  // [DaypartBucketer]. The closed-shift aggregator and the live read
  // (`OpenShiftSnapshotProjector`) MUST share boundary inclusivity so
  // the audit pool-consistency check is honest — a POS check closing
  // exactly at 15:00:00 belongs to Lunch in both paths, not just one.

  /// Returns true when [instant] (a UTC `DateTime` or ISO string) buckets
  /// to [targetServicePeriodId] via [DaypartBucketer.bucketPosLine]. Used
  /// for point-in-time facts (POS lines, reservations).
  bool _posInstantInPeriod({
    required Object? instant,
    required BucketingLocationContext bucketingContext,
    required List<ServicePeriodDefinition> periodDefinitions,
    required String targetServicePeriodId,
  }) {
    final utcInstant = _coerceUtc(instant);
    if (utcInstant == null) return false;
    final local = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: bucketingContext.iana,
      instant: utcInstant,
    );
    final bucketed = DaypartBucketer.bucketPosLine(
      BucketingPosLine(sourceId: '', eventLocalTimestamp: local),
      bucketingContext,
      periodDefinitions,
    );
    return bucketed == targetServicePeriodId;
  }

  /// Per-Daypart V1 Slice 1.5 (Gaps 21, 26) — per-period labor split.
  ///
  /// For each labor punch row in [punches], walks segments returned by
  /// [DaypartBucketer.bucketLaborPunch] and sums minutes whose
  /// `servicePeriodId == targetServicePeriodId` AND whose anchored
  /// business date equals [targetBusinessDateIso]. Cross-(business-date)
  /// punches contribute only the minutes that fall inside this slot.
  ///
  /// Also returns a filtered list of the original punch rows that
  /// contributed any non-zero minutes — used by the wage-resolution
  /// path to scope the rate × hours math to the punches that actually
  /// touched this period.
  _LaborPunchSplit _splitLaborPunchesByPeriod({
    required List<Map<String, Object?>> punches,
    required BucketingLocationContext bucketingContext,
    required List<ServicePeriodDefinition> periodDefinitions,
    required String targetServicePeriodId,
    required String targetBusinessDateIso,
    required String timezone,
  }) {
    var fohMinutes = 0;
    var bohMinutes = 0;
    final touchedRows = <Map<String, Object?>>[];
    final perPunchHoursInPeriod = <Map<String, Object?>, double>{};

    for (final row in punches) {
      final startUtc = _coerceUtc(row['shift_start']);
      final endUtc = _coerceUtc(row['shift_end']);
      if (startUtc == null || endUtc == null) continue;
      if (!endUtc.isAfter(startUtc)) continue;

      final startLocal = _timezoneConverter.toBusinessLocal(
        restaurantTimezone: timezone,
        instant: startUtc,
      );
      final endLocal = _timezoneConverter.toBusinessLocal(
        restaurantTimezone: timezone,
        instant: endUtc,
      );

      final segments = DaypartBucketer.bucketLaborPunch(
        BucketingLaborPunch(
          sourceId: '',
          clockedInLocal: startLocal,
          clockedOutLocal: endLocal,
        ),
        bucketingContext,
        periodDefinitions,
      );

      var minutesInPeriod = 0;
      for (final seg in segments) {
        if (seg.servicePeriodId != targetServicePeriodId) continue;
        // Cross-(business-date) gate: the segment may belong to the
        // period under a different business_date (e.g. a late_night
        // segment on Friday vs Saturday). Resolve the segment's
        // anchored business date and keep only segments matching the
        // call's target.
        final segBusinessDate = _businessDateForLocalTime(
          local: seg.startLocal,
          businessDayStartLocalTime: bucketingContext.businessDayStartLocalTime,
        );
        if (segBusinessDate != targetBusinessDateIso) continue;
        minutesInPeriod += seg.minutes;
      }
      if (minutesInPeriod == 0) continue;

      touchedRows.add(row);
      perPunchHoursInPeriod[row] = minutesInPeriod / 60.0;
      if (_isFohPunch(row)) {
        fohMinutes += minutesInPeriod;
      } else {
        bohMinutes += minutesInPeriod;
      }
    }

    return _LaborPunchSplit(
      punchesForPeriod: touchedRows,
      perPunchHoursInPeriod: perPunchHoursInPeriod,
      fohHoursInPeriod: (fohMinutes / 60).round(),
      bohHoursInPeriod: (bohMinutes / 60).round(),
    );
  }

  /// Same business-date rule as `DaypartBucketer._classifyInstant`: an
  /// instant whose local time is before [businessDayStartLocalTime]
  /// belongs to the prior calendar date's business day; an instant at
  /// or after rolls into the current calendar date's business day.
  static String _businessDateForLocalTime({
    required DateTime local,
    required String businessDayStartLocalTime,
  }) {
    final parts = businessDayStartLocalTime.split(':');
    final cutoffMinutes = int.parse(parts[0]) * 60 + int.parse(parts[1]);
    final localMinutes = local.hour * 60 + local.minute;
    final base = DateTime(local.year, local.month, local.day);
    final anchorDay = localMinutes < cutoffMinutes
        ? base.subtract(const Duration(days: 1))
        : base;
    return '${anchorDay.year.toString().padLeft(4, '0')}-'
        '${anchorDay.month.toString().padLeft(2, '0')}-'
        '${anchorDay.day.toString().padLeft(2, '0')}';
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

  /// Per-punch dollar share scaled by `(hoursInPeriod / fullPunchHours)`
  /// when [perPunchHoursInPeriod] is supplied (Per-Daypart V1 Slice
  /// 1.5). When omitted, behavior matches the pre-1.5 implementation
  /// (whole-punch dollars).
  double? _sumDollars(
    List<Map<String, Object?>> punches, {
    required bool isFoh,
    Map<Map<String, Object?>, double>? perPunchHoursInPeriod,
  }) {
    double? total;
    for (final punch in punches) {
      if (_isFohPunch(punch) != isFoh) continue;
      final raw = punch['actual_dollars'];
      if (raw is num) {
        final scaled = _scaleByPeriodFraction(
          value: raw.toDouble(),
          punch: punch,
          perPunchHoursInPeriod: perPunchHoursInPeriod,
        );
        total = (total ?? 0) + scaled;
      }
    }
    return total;
  }

  /// Rate × hours per punch. When [perPunchHoursInPeriod] is supplied,
  /// uses the per-period overlap minutes (Per-Daypart V1 Slice 1.5);
  /// otherwise falls back to the punch's `hours_worked` field.
  double? _computeRateTimesHours(
    List<Map<String, Object?>> punches, {
    required bool isFoh,
    Map<Map<String, Object?>, double>? perPunchHoursInPeriod,
  }) {
    double? total;
    for (final punch in punches) {
      if (_isFohPunch(punch) != isFoh) continue;
      final rate = punch['pay_rate'];
      if (rate is! num) continue;
      final hoursInPeriod = perPunchHoursInPeriod?[punch];
      final double hours;
      if (hoursInPeriod != null) {
        hours = hoursInPeriod;
      } else {
        final raw = punch['hours_worked'];
        if (raw is! num) continue;
        hours = raw.toDouble();
      }
      total = (total ?? 0) + hours * rate.toDouble();
    }
    return total;
  }

  static double _scaleByPeriodFraction({
    required double value,
    required Map<String, Object?> punch,
    required Map<Map<String, Object?>, double>? perPunchHoursInPeriod,
  }) {
    if (perPunchHoursInPeriod == null) return value;
    final hoursInPeriod = perPunchHoursInPeriod[punch];
    final raw = punch['hours_worked'];
    if (hoursInPeriod == null || raw is! num) return value;
    final fullHours = raw.toDouble();
    if (fullHours <= 0) return value;
    final fraction = (hoursInPeriod / fullHours).clamp(0.0, 1.0);
    return value * fraction;
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

enum _OperatorCoversPreference {
  vendor,
  forecast,
  manual,
  reservationPlusWalkin,
}

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
    required this.businessDayStartLocalTime,
  });
  final String timezone;
  final String businessDayStartLocalTime;
}

/// Per-Daypart V1 Slice 1.5 — result of bucketing labor punches into a
/// single (business_date, service_period_id) slot.
class _LaborPunchSplit {
  const _LaborPunchSplit({
    required this.punchesForPeriod,
    required this.perPunchHoursInPeriod,
    required this.fohHoursInPeriod,
    required this.bohHoursInPeriod,
  });

  /// Subset of the input punch rows that contributed any non-zero
  /// minutes to this slot.
  final List<Map<String, Object?>> punchesForPeriod;

  /// For each retained punch, the fractional hours that fell inside
  /// the target service period × target business date.
  final Map<Map<String, Object?>, double> perPunchHoursInPeriod;

  /// Aggregate FOH/BOH minutes-in-period (rounded to integer hours
  /// matching the pre-1.5 `_sumHours` return shape).
  final int fohHoursInPeriod;
  final int bohHoursInPeriod;
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
