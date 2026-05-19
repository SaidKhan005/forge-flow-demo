// Shared Phase 8 production projector wiring.
//
// The proxy webhook binder, recurring sync worker, and first-connect
// backfill worker all create vendor adapter factories. This helper owns
// the production post-commit projector triple so each path attaches the
// same projection taps after canonical fact writes.

import 'package:forge_and_flow/domain/canonical_day_order.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/domain/services/business_date_resolver.dart';
import 'package:forge_and_flow/domain/services/daypart_bucketer.dart';
import 'package:forge_and_flow/domain/services/target_snapshot_builder.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_shift_record_writer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/canonical_fact_projection_retry_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/open_shift_snapshots_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_projection_retry.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';
import 'package:forge_and_flow/services/integration/iana_timezone_converter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/open_shift_snapshot_projector.dart';
import 'package:forge_and_flow/services/integration/projecting_canonical_sink.dart';

Phase8ProjectorWiring buildDefaultPhase8ProjectorWiring(
  TenantTransactionWrapper tenantWrapper,
) {
  final timingRepository = BusinessTimingProfilesRepository(tenantWrapper);
  final timingSource = PostgresOpenShiftTimingProfileSource(timingRepository);
  final periodResolver = _ProductionCanonicalFactPeriodResolver(
    timingSource: timingSource,
  );
  final projector = CanonicalFactPostCommitProjector(
    closedAggregator: ExistingClosedShiftPostCommitAggregator(
      CanonicalFactToClosedShiftInputAggregator(tenantWrapper),
    ),
    targetSnapshotResolver: _ActiveTargetClosedShiftTargetSnapshotResolver(
      ActiveTargetProfileRepository(tenantWrapper),
    ),
    closedWriter: ExistingClosedShiftPostCommitWriter(
      PostgresShiftRecordWriter(tenantWrapper),
    ),
    openProjector: ExistingOpenShiftPostCommitProjector(
      OpenShiftSnapshotProjector(
        timingSource: timingSource,
        snapshotWriter: PostgresOpenShiftSnapshotWriter(
          repository: OpenShiftSnapshotsRepository(tenantWrapper),
        ),
      ),
    ),
  );
  return Phase8ProjectorWiring.active(
    source: 'production_default',
    projector: projector,
    periodResolver: periodResolver.resolve,
    restaurantIdResolver: _locationIdAsRestaurantId,
    retryRecorder: CanonicalFactProjectionRetryRepository(tenantWrapper),
  );
}

String _locationIdAsRestaurantId({
  required String operatorId,
  required String locationId,
}) => locationId;

class Phase8ProjectorWiring {
  const Phase8ProjectorWiring.inactive({required this.source})
    : projector = null,
      periodResolver = null,
      restaurantIdResolver = null,
      retryRecorder = null;

  const Phase8ProjectorWiring.active({
    required this.source,
    required this.projector,
    required this.periodResolver,
    required this.restaurantIdResolver,
    this.retryRecorder,
  });

  final String source;
  final CanonicalFactPostCommitProjector? projector;
  final CanonicalFactPeriodResolver? periodResolver;
  final CanonicalRestaurantIdResolver? restaurantIdResolver;
  final CanonicalFactProjectionRetryRecorder? retryRecorder;

  bool get isActive =>
      projector != null &&
      periodResolver != null &&
      restaurantIdResolver != null;
}

class _ProductionCanonicalFactPeriodResolver {
  _ProductionCanonicalFactPeriodResolver({
    required OpenShiftTimingProfileSource timingSource,
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? clock,
  }) : _timingSource = timingSource,
       _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
       _clock = clock ?? DateTime.now;

  final OpenShiftTimingProfileSource _timingSource;
  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _clock;

  Future<CanonicalFactCommittedPeriod?> resolve({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required String vendorId,
    required String connectionId,
    required Map<String, Object?> canonicalFact,
  }) async {
    final fact = _parseOpenShiftFact(canonicalFact);
    if (fact == null) return null;
    final explicitBusinessDate = _stringFromFact(canonicalFact, const <String>[
      'business_date',
      'businessDate',
    ]);
    final seedBusinessDate = explicitBusinessDate ?? _isoDate(fact.occurredAt);
    var timing = await _timingSource.resolveForBusinessDate(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: seedBusinessDate,
    );
    if (timing == null) return null;

    final businessDate =
        explicitBusinessDate ?? _businessDateFor(fact.occurredAt, timing);
    if (businessDate != seedBusinessDate) {
      final dateSpecificTiming = await _timingSource.resolveForBusinessDate(
        operatorId: operatorId,
        locationId: locationId,
        businessDate: businessDate,
      );
      if (dateSpecificTiming == null) return null;
      timing = dateSpecificTiming;
    }

    final servicePeriodDefinition = _resolveServicePeriod(
      fact: fact,
      canonicalFact: canonicalFact,
      timing: timing,
    );
    if (servicePeriodDefinition == null) return null;
    final weekStartDate = WeeklyPlanSnapshotPolicy.weekStartForDate(
      businessDate,
      weekStartDay: timing.weekStartDay,
    );
    final weekEndDate = WeeklyPlanSnapshotPolicy.weekEndForDate(
      businessDate,
      weekStartDay: timing.weekStartDay,
    );

    return CanonicalFactCommittedPeriod(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: locationId,
      businessDate: businessDate,
      weekId: WeeklyPlanSnapshotPolicy.weekKeyFromSpan(
        weekStartDate,
        weekEndDate,
      ),
      dayLabel: _dayLabelFor(businessDate),
      servicePeriodKey: servicePeriodDefinition.id,
      servicePeriodDefinition: servicePeriodDefinition,
      state: _stateFor(
        businessDate: businessDate,
        definition: servicePeriodDefinition,
        timing: timing,
      ),
      businessTimingProfileId: timing.businessTimingProfileId,
      businessTimingProfileVersionId: timing.businessTimingProfileVersionId,
    );
  }

  OpenShiftCanonicalFact? _parseOpenShiftFact(
    Map<String, Object?> canonicalFact,
  ) {
    try {
      return OpenShiftCanonicalFact.fromMap(canonicalFact);
    } on Object {
      return null;
    }
  }

  ServicePeriodDefinition? _resolveServicePeriod({
    required OpenShiftCanonicalFact fact,
    required Map<String, Object?> canonicalFact,
    required ResolvedOpenShiftTimingProfile timing,
  }) {
    final explicitKey = _stringFromFact(canonicalFact, const <String>[
      'service_period_key',
      'servicePeriodKey',
      'daypart',
    ]);
    if (explicitKey != null) {
      return _definitionByKey(timing.servicePeriods, explicitKey);
    }
    final bucketKey = _bucketKeyForFact(fact, timing);
    if (bucketKey == null) return null;
    return _definitionByKey(timing.servicePeriods, bucketKey);
  }

  String? _bucketKeyForFact(
    OpenShiftCanonicalFact fact,
    ResolvedOpenShiftTimingProfile timing,
  ) {
    final localStart = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: timing.businessTimezone,
      instant: fact.occurredAt,
    );
    return switch (fact.kind) {
      OpenShiftCanonicalFactKind.pos => DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: fact.sourceEntityId,
          eventLocalTimestamp: localStart,
        ),
        timing.locationContext,
        timing.servicePeriods,
      ),
      OpenShiftCanonicalFactKind.reservation =>
        DaypartBucketer.bucketReservation(
          BucketingReservation(
            sourceId: fact.sourceEntityId,
            reservationLocalTimestamp: localStart,
          ),
          timing.locationContext,
          timing.servicePeriods,
        ),
      OpenShiftCanonicalFactKind.labor => _firstLaborBucket(
        fact,
        timing,
        localStart,
      ),
    };
  }

  String? _firstLaborBucket(
    OpenShiftCanonicalFact fact,
    ResolvedOpenShiftTimingProfile timing,
    DateTime localStart,
  ) {
    final localEnd = fact.endedAt == null
        ? localStart
        : _timezoneConverter.toBusinessLocal(
            restaurantTimezone: timing.businessTimezone,
            instant: fact.endedAt!,
          );
    final segments = DaypartBucketer.bucketLaborPunch(
      BucketingLaborPunch(
        sourceId: fact.sourceEntityId,
        clockedInLocal: localStart,
        clockedOutLocal: localEnd,
      ),
      timing.locationContext,
      timing.servicePeriods,
    );
    for (final segment in segments) {
      final key = segment.servicePeriodId;
      if (key != null) return key;
    }
    return null;
  }

  CanonicalFactPeriodState _stateFor({
    required String businessDate,
    required ServicePeriodDefinition definition,
    required ResolvedOpenShiftTimingProfile timing,
  }) {
    final nowLocal = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: timing.businessTimezone,
      instant: _clock().toUtc(),
    );
    final periodEnd = _localBoundary(
      businessDate: businessDate,
      localTime: definition.endLocalTime,
      addDay: definition.rollsPastMidnight,
    );
    return nowLocal.isBefore(periodEnd)
        ? CanonicalFactPeriodState.openCurrent
        : CanonicalFactPeriodState.completed;
  }

  String _businessDateFor(
    DateTime instant,
    ResolvedOpenShiftTimingProfile timing,
  ) {
    return BusinessDateResolver.resolve(
      localTimestamp: _timezoneConverter.toBusinessLocal(
        restaurantTimezone: timing.businessTimezone,
        instant: instant,
      ),
      businessDayStartLocalTime: timing.businessDayStartLocalTime,
    );
  }

  static ServicePeriodDefinition? _definitionByKey(
    List<ServicePeriodDefinition> definitions,
    String key,
  ) {
    for (final definition in definitions) {
      if (definition.id == key) return definition;
    }
    return null;
  }
}

class _ActiveTargetClosedShiftTargetSnapshotResolver
    implements ClosedShiftTargetSnapshotResolver {
  const _ActiveTargetClosedShiftTargetSnapshotResolver(this._repository);

  final ActiveTargetProfileRepository _repository;

  @override
  Future<TargetSnapshot> resolveTargetSnapshot({
    required CanonicalFactPostCommitInput input,
    required CanonicalFactCommittedPeriod period,
    required AggregatorResult aggregateResult,
  }) async {
    final row = await _repository.loadActiveProfile(
      operatorId: input.operatorId,
      locationId: input.locationId,
      restaurantId: input.restaurantId,
      userId: input.userId,
    );
    if (row == null) {
      throw StateError(
        'active target profile missing for '
        '${input.operatorId}/${input.locationId}/${input.restaurantId}',
      );
    }
    final profile = _activeTargetProfileFromRow(row);
    return TargetSnapshotBuilder.fromActiveTargetProfile(
      profile,
      targetProfileVersionId: row.targetProfileVersionId,
      servicePeriodId: period.servicePeriodKey,
    );
  }
}

ActiveTargetProfile _activeTargetProfileFromRow(
  ActiveTargetProfilePostgresRow row,
) {
  return ActiveTargetProfile(
    targetProfileId: row.targetProfileId,
    restaurantId: row.restaurantId,
    targetCycleId: row.targetCycleId,
    targetProfileVersionId: row.targetProfileVersionId,
    sourceType: row.sourceType,
    targetCPLH: row.targetCplh,
    targetSPLH: row.targetSplh,
    targetPPA: row.targetPpa,
    fohWage: row.fohWage,
    bohWage: row.bohWage,
    opzFloorCPLH: row.opzFloorCplh,
    opzCeilingCPLH: row.opzCeilingCplh,
    theoreticalFohLaborPct: row.theoreticalFohLaborPct,
    theoreticalBohLaborPct: row.theoreticalBohLaborPct,
    theoreticalLaborPct: row.theoreticalLaborPct,
    builtAt: row.builtAt.toUtc().toIso8601String(),
    dayparts: <ActiveTargetProfileDaypart>[
      for (final daypart in row.dayparts)
        ActiveTargetProfileDaypart(
          servicePeriodId: daypart.servicePeriodId,
          daypartTargetCPLH: daypart.daypartTargetCplh,
          daypartTargetSPLH: daypart.daypartTargetSplh,
          daypartTargetPPA: daypart.daypartTargetPpa,
          daypartOpzFloorCPLH: daypart.daypartOpzFloorCplh,
          daypartOpzCeilingCPLH: daypart.daypartOpzCeilingCplh,
          verdict: daypart.verdict,
          verdictReason: daypart.verdictReason,
        ),
    ],
  );
}

String? _stringFromFact(Map<String, Object?> fact, List<String> keys) {
  for (final key in keys) {
    final value = fact[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

String _isoDate(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

String _dayLabelFor(String businessDate) {
  final weekday = DateTime.parse(businessDate).weekday;
  return CanonicalDayOrder.labels[weekday - 1];
}

DateTime _localBoundary({
  required String businessDate,
  required String localTime,
  required bool addDay,
}) {
  final date = DateTime.parse(businessDate);
  final parts = localTime.split(':');
  final hour = parts.isEmpty ? 0 : int.parse(parts[0]);
  final minute = parts.length < 2 ? 0 : int.parse(parts[1]);
  return DateTime(
    date.year,
    date.month,
    date.day,
    hour,
    minute,
  ).add(addDay ? const Duration(days: 1) : Duration.zero);
}
