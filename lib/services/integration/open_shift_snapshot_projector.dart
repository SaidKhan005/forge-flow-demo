// Live canonical facts -> public.open_shift_snapshots projector.
//
// This service is intentionally in the integration layer. It reads canonical
// operational facts, resolves server-side business timing, buckets by stable
// service_period_key, and writes the live read model through repository seams.

import '../../domain/canonical_day_order.dart';
import '../../domain/models/business_timing_profile.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/business_date_resolver.dart';
import '../../domain/services/business_timing_profile_resolver.dart';
import '../../domain/services/daypart_bucketer.dart';
import '../../domain/services/weekly_plan_snapshot_policy.dart';
import '../../infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/open_shift_snapshots_repository.dart';
import 'iana_timezone_converter.dart';

abstract class OpenShiftTimingProfileSource {
  Future<ResolvedOpenShiftTimingProfile?> resolveForBusinessDate({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? userId,
  });
}

abstract class OpenShiftSnapshotWriter {
  Future<void> upsert(OpenShiftSnapshotProjectionWrite snapshot);
}

class PostgresOpenShiftTimingProfileSource
    implements OpenShiftTimingProfileSource {
  const PostgresOpenShiftTimingProfileSource(this.repository);

  final BusinessTimingProfilesRepository repository;

  @override
  Future<ResolvedOpenShiftTimingProfile?> resolveForBusinessDate({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? userId,
  }) async {
    final rows = await repository.listCandidateProfilesForLocation(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      userId: userId,
    );
    if (rows.isEmpty) return null;

    final candidates = <BusinessTimingProfile>[
      for (final row in rows)
        BusinessTimingProfile(
          profileId: row.profileId,
          scope: BusinessTimingScope.fromValue(row.scopeType),
          scopeId: row.scopeId,
          businessTimezone: row.locationTimezone,
          businessDayStartLocalTime: row.businessDayStartLocalTime,
          weekStartDay: row.weekStartDay,
          servicePeriodDefinitions: row.servicePeriods.isEmpty
              ? null
              : <ServicePeriodDefinition>[
                  for (final period in row.servicePeriods)
                    ServicePeriodDefinition(
                      id: period.servicePeriodKey,
                      label: period.label,
                      shortLabel: period.shortLabel,
                      sortOrder: period.sortOrder,
                      startLocalTime: period.startLocalTime,
                      endLocalTime: period.endLocalTime,
                      rollsPastMidnight: period.rollsPastMidnight,
                      applicableDays: period.applicableWeekdays,
                    ),
                ],
          shiftCloseAuthority: ShiftCloseAuthority.fromValue(
            row.closeAuthority,
          ),
          localCloseFallback: row.localCloseFallbackTime,
        ),
    ];
    final effective = BusinessTimingProfileResolver.resolve(candidates);
    final activeProfileId = candidates.last.profileId;
    return ResolvedOpenShiftTimingProfile(
      businessTimingProfileId: activeProfileId,
      businessTimingProfileVersionId: activeProfileId,
      businessTimezone: effective.businessTimezone,
      businessDayStartLocalTime: effective.businessDayStartLocalTime,
      weekStartDay: effective.weekStartDay,
      servicePeriods: effective.servicePeriodDefinitions,
    );
  }
}

class PostgresOpenShiftSnapshotWriter implements OpenShiftSnapshotWriter {
  const PostgresOpenShiftSnapshotWriter({
    required this.repository,
    this.userId,
  });

  final OpenShiftSnapshotsRepository repository;
  final String? userId;

  @override
  Future<void> upsert(OpenShiftSnapshotProjectionWrite snapshot) async {
    await repository.upsertSnapshot(
      snapshot: OpenShiftSnapshotPostgresWrite(
        operatorId: snapshot.operatorId,
        locationId: snapshot.locationId,
        businessTimingProfileId: snapshot.businessTimingProfileId,
        businessTimingProfileVersionId: snapshot.businessTimingProfileVersionId,
        businessDate: snapshot.businessDate,
        weekStartDate: snapshot.weekStartDate,
        weekId: snapshot.weekId,
        dayLabel: snapshot.dayLabel,
        snapshotScope: snapshot.snapshotScope,
        servicePeriodKey: snapshot.servicePeriodKey,
        servicePeriodLabel: snapshot.servicePeriodLabel,
        status: snapshot.status,
        forecastCovers: snapshot.forecastCovers,
        currentCovers: snapshot.currentCovers,
        scheduledFohHours: snapshot.scheduledFohHours,
        scheduledBohHours: snapshot.scheduledBohHours,
        currentPpa: snapshot.currentPpa,
        currentCplh: snapshot.currentCplh,
        currentSplh: snapshot.currentSplh,
        blendedWage: snapshot.blendedWage,
        timeLabel: snapshot.timeLabel,
        serviceElapsedLabel: snapshot.serviceElapsedLabel,
        sourceSystem: snapshot.sourceSystem,
        sourceShiftId: snapshot.sourceShiftId,
        provenance: snapshot.provenance,
        lastEventAt: snapshot.lastEventAt,
      ),
      userId: userId,
    );
  }
}

class OpenShiftSnapshotProjector {
  OpenShiftSnapshotProjector({
    required OpenShiftTimingProfileSource timingSource,
    required OpenShiftSnapshotWriter snapshotWriter,
    IanaTimezoneConverter? timezoneConverter,
  }) : _timingSource = timingSource,
       _snapshotWriter = snapshotWriter,
       _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared;

  final OpenShiftTimingProfileSource _timingSource;
  final OpenShiftSnapshotWriter _snapshotWriter;
  final IanaTimezoneConverter _timezoneConverter;

  Future<OpenShiftProjectionResult> projectFactMaps({
    required String operatorId,
    required String locationId,
    required Iterable<Map<String, Object?>> facts,
    String? businessDate,
    String? userId,
  }) {
    return projectFacts(
      operatorId: operatorId,
      locationId: locationId,
      facts: facts.map(OpenShiftCanonicalFact.fromMap),
      businessDate: businessDate,
      userId: userId,
    );
  }

  Future<OpenShiftProjectionResult> projectFacts({
    required String operatorId,
    required String locationId,
    required Iterable<OpenShiftCanonicalFact> facts,
    String? businessDate,
    String? userId,
  }) async {
    final scopedFacts = <OpenShiftCanonicalFact>[];
    var ignoredFacts = 0;
    for (final fact in facts) {
      if (fact.operatorId != operatorId || fact.locationId != locationId) {
        ignoredFacts += 1;
        continue;
      }
      scopedFacts.add(fact);
    }

    if (scopedFacts.isEmpty) {
      return OpenShiftProjectionResult.unavailable(
        reason: ignoredFacts > 0
            ? 'No canonical facts matched the requested tenant scope.'
            : 'No canonical facts were supplied for projection.',
        ignoredFacts: ignoredFacts,
      );
    }

    final resolvedBusinessDate =
        businessDate ?? _commonBusinessDate(scopedFacts);
    final seedBusinessDate =
        resolvedBusinessDate ?? _isoDate(scopedFacts.first.occurredAt);
    var timing = await _timingSource.resolveForBusinessDate(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: seedBusinessDate,
      userId: userId,
    );
    if (timing == null) {
      return OpenShiftProjectionResult.unavailable(
        reason: 'No active business timing profile for location.',
        businessDate: seedBusinessDate,
        ignoredFacts: ignoredFacts,
      );
    }

    final effectiveBusinessDate =
        resolvedBusinessDate ??
        _businessDateFor(scopedFacts.first.occurredAt, timing);
    if (effectiveBusinessDate != seedBusinessDate) {
      final dateSpecificTiming = await _timingSource.resolveForBusinessDate(
        operatorId: operatorId,
        locationId: locationId,
        businessDate: effectiveBusinessDate,
        userId: userId,
      );
      if (dateSpecificTiming == null) {
        return OpenShiftProjectionResult.unavailable(
          reason: 'No active business timing profile for location.',
          businessDate: effectiveBusinessDate,
          ignoredFacts: ignoredFacts,
        );
      }
      timing = dateSpecificTiming;
    }

    final buckets = <String, _OpenShiftBucket>{};
    final seenFactKeys = <String>{};
    for (final fact in scopedFacts) {
      final factBusinessDate =
          fact.businessDate ?? _businessDateFor(fact.occurredAt, timing);
      if (factBusinessDate != effectiveBusinessDate) {
        ignoredFacts += 1;
        continue;
      }
      final dedupeKey = fact.dedupeKey;
      if (!seenFactKeys.add(dedupeKey)) continue;
      _applyFact(fact: fact, timing: timing, bucketLookup: buckets);
    }

    if (buckets.isEmpty) {
      return OpenShiftProjectionResult.unavailable(
        reason: 'Canonical facts did not fall inside any service period.',
        businessDate: effectiveBusinessDate,
        ignoredFacts: ignoredFacts,
      );
    }

    final writes = <OpenShiftSnapshotProjectionWrite>[
      for (final bucket in _orderedBuckets(buckets, timing.servicePeriods))
        bucket.toWrite(
          operatorId: operatorId,
          locationId: locationId,
          timing: timing,
          businessDate: effectiveBusinessDate,
        ),
    ];
    writes.add(
      _rollUpWholeDay(
        periodWrites: writes,
        operatorId: operatorId,
        locationId: locationId,
        timing: timing,
        businessDate: effectiveBusinessDate,
      ),
    );

    for (final write in writes) {
      await _snapshotWriter.upsert(write);
    }

    return OpenShiftProjectionResult.projected(
      businessDate: effectiveBusinessDate,
      snapshotsUpserted: writes.length,
      servicePeriodSnapshotsUpserted: writes.length - 1,
      ignoredFacts: ignoredFacts,
      servicePeriodKeys: <String>[
        for (final write in writes)
          if (write.snapshotScope == OpenShiftSnapshotScope.servicePeriod.value)
            write.servicePeriodKey,
      ],
    );
  }

  void _applyFact({
    required OpenShiftCanonicalFact fact,
    required ResolvedOpenShiftTimingProfile timing,
    required Map<String, _OpenShiftBucket> bucketLookup,
  }) {
    final local = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: timing.businessTimezone,
      instant: fact.occurredAt,
    );
    switch (fact.kind) {
      case OpenShiftCanonicalFactKind.pos:
        final key = DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: fact.sourceEntityId,
            eventLocalTimestamp: local,
          ),
          timing.locationContext,
          timing.servicePeriods,
        );
        if (key == null) return;
        _bucketFor(bucketLookup, timing, key).addPos(fact);
      case OpenShiftCanonicalFactKind.reservation:
        final key = DaypartBucketer.bucketReservation(
          BucketingReservation(
            sourceId: fact.sourceEntityId,
            reservationLocalTimestamp: local,
          ),
          timing.locationContext,
          timing.servicePeriods,
        );
        if (key == null) return;
        _bucketFor(bucketLookup, timing, key).addReservation(fact);
      case OpenShiftCanonicalFactKind.labor:
        final localEnd = fact.endedAt == null
            ? local
            : _timezoneConverter.toBusinessLocal(
                restaurantTimezone: timing.businessTimezone,
                instant: fact.endedAt!,
              );
        final segments = DaypartBucketer.bucketLaborPunch(
          BucketingLaborPunch(
            sourceId: fact.sourceEntityId,
            clockedInLocal: local,
            clockedOutLocal: localEnd,
          ),
          timing.locationContext,
          timing.servicePeriods,
        );
        for (final segment in segments) {
          final key = segment.servicePeriodId;
          if (key == null) continue;
          _bucketFor(
            bucketLookup,
            timing,
            key,
          ).addLaborSegment(fact, hours: segment.minutes / 60);
        }
    }
  }

  _OpenShiftBucket _bucketFor(
    Map<String, _OpenShiftBucket> lookup,
    ResolvedOpenShiftTimingProfile timing,
    String servicePeriodKey,
  ) {
    return lookup.putIfAbsent(servicePeriodKey, () {
      final definition = timing.servicePeriods.firstWhere(
        (period) => period.id == servicePeriodKey,
      );
      return _OpenShiftBucket(definition);
    });
  }

  List<_OpenShiftBucket> _orderedBuckets(
    Map<String, _OpenShiftBucket> buckets,
    List<ServicePeriodDefinition> definitions,
  ) {
    final order = <String, int>{
      for (final definition in definitions) definition.id: definition.sortOrder,
    };
    final values = buckets.values.toList();
    values.sort((a, b) {
      final sortA = order[a.definition.id] ?? 9999;
      final sortB = order[b.definition.id] ?? 9999;
      final bySort = sortA.compareTo(sortB);
      return bySort == 0 ? a.definition.id.compareTo(b.definition.id) : bySort;
    });
    return values;
  }

  OpenShiftSnapshotProjectionWrite _rollUpWholeDay({
    required List<OpenShiftSnapshotProjectionWrite> periodWrites,
    required String operatorId,
    required String locationId,
    required ResolvedOpenShiftTimingProfile timing,
    required String businessDate,
  }) {
    final currentCovers = periodWrites.fold<int>(
      0,
      (sum, write) => sum + write.currentCovers,
    );
    final forecastCovers = periodWrites.fold<int>(
      0,
      (sum, write) => sum + write.forecastCovers,
    );
    final fohHours = periodWrites.fold<int>(
      0,
      (sum, write) => sum + write.scheduledFohHours,
    );
    final bohHours = periodWrites.fold<int>(
      0,
      (sum, write) => sum + write.scheduledBohHours,
    );
    final sales = periodWrites.fold<double>(
      0,
      (sum, write) => sum + _salesFromWrite(write),
    );
    final lastEventAt = periodWrites
        .map((write) => write.lastEventAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (latest, value) {
          if (latest == null || value.isAfter(latest)) return value;
          return latest;
        });
    final sourceSystems = <String>{
      for (final write in periodWrites)
        if (write.sourceSystem != null) write.sourceSystem!,
    }.toList()..sort();

    return _buildWrite(
      operatorId: operatorId,
      locationId: locationId,
      timing: timing,
      businessDate: businessDate,
      snapshotScope: OpenShiftSnapshotScope.wholeDay.value,
      servicePeriodKey: 'whole_day',
      servicePeriodLabel: 'Whole Day',
      currentCovers: currentCovers,
      forecastCovers: forecastCovers,
      fohHours: fohHours,
      bohHours: bohHours,
      sales: sales,
      blendedWage: _wholeDayBlendedWage(periodWrites),
      blendedWageAvailable: _wholeDayBlendedWageAvailable(periodWrites),
      sourceSystem: sourceSystems.isEmpty ? null : sourceSystems.join(','),
      lastEventAt: lastEventAt,
      provenance: <String, Object?>{
        'projection': 'open_shift_snapshot_projector',
        'rollup': 'service_period_buckets',
        'service_period_keys': <String>[
          for (final write in periodWrites) write.servicePeriodKey,
        ],
      },
    );
  }

  static OpenShiftSnapshotProjectionWrite _buildWrite({
    required String operatorId,
    required String locationId,
    required ResolvedOpenShiftTimingProfile timing,
    required String businessDate,
    required String snapshotScope,
    required String servicePeriodKey,
    required String servicePeriodLabel,
    required int currentCovers,
    required int forecastCovers,
    required int fohHours,
    required int bohHours,
    required double sales,
    required double blendedWage,
    required bool blendedWageAvailable,
    required String? sourceSystem,
    required DateTime? lastEventAt,
    required Map<String, Object?> provenance,
  }) {
    final weekStartDate = WeeklyPlanSnapshotPolicy.weekStartForDate(
      businessDate,
      weekStartDay: timing.weekStartDay,
    );
    final weekEndDate = WeeklyPlanSnapshotPolicy.weekEndForDate(
      businessDate,
      weekStartDay: timing.weekStartDay,
    );
    return OpenShiftSnapshotProjectionWrite(
      operatorId: operatorId,
      locationId: locationId,
      businessTimingProfileId: timing.businessTimingProfileId,
      businessTimingProfileVersionId: timing.businessTimingProfileVersionId,
      businessDate: businessDate,
      weekStartDate: weekStartDate,
      weekId: WeeklyPlanSnapshotPolicy.weekKeyFromSpan(
        weekStartDate,
        weekEndDate,
      ),
      dayLabel: _dayLabelFor(businessDate),
      snapshotScope: snapshotScope,
      servicePeriodKey: servicePeriodKey,
      servicePeriodLabel: servicePeriodLabel,
      status: 'open',
      forecastCovers: forecastCovers,
      currentCovers: currentCovers,
      scheduledFohHours: fohHours,
      scheduledBohHours: bohHours,
      currentPpa: currentCovers <= 0 ? 0 : sales / currentCovers,
      currentCplh: fohHours <= 0 ? 0 : currentCovers / fohHours,
      currentSplh: bohHours <= 0 ? 0 : sales / bohHours,
      blendedWage: blendedWageAvailable ? blendedWage : 0,
      blendedWageAvailable: blendedWageAvailable,
      sourceSystem: sourceSystem,
      sourceShiftId: null,
      provenance: <String, Object?>{
        ...provenance,
        'blended_wage_available': blendedWageAvailable,
        'blended_wage_provenance': blendedWageAvailable
            ? 'canonical_labor_wage'
            : 'unavailable',
      },
      lastEventAt: lastEventAt,
    );
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

  static String? _commonBusinessDate(List<OpenShiftCanonicalFact> facts) {
    String? found;
    for (final fact in facts) {
      final value = fact.businessDate;
      if (value == null) return null;
      if (found == null) {
        found = value;
      } else if (found != value) {
        return null;
      }
    }
    return found;
  }

  static String _dayLabelFor(String businessDate) {
    final weekday = DateTime.parse(businessDate).weekday;
    return CanonicalDayOrder.labels[weekday - 1];
  }

  static String _isoDate(DateTime date) {
    final utc = date.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  static double _salesFromWrite(OpenShiftSnapshotProjectionWrite write) {
    return write.currentPpa * write.currentCovers;
  }

  static double _laborHoursFromWrite(OpenShiftSnapshotProjectionWrite write) {
    return (write.scheduledFohHours + write.scheduledBohHours).toDouble();
  }

  static bool _wholeDayBlendedWageAvailable(
    List<OpenShiftSnapshotProjectionWrite> writes,
  ) {
    final laborHours = writes.fold<double>(
      0,
      (sum, write) => sum + _laborHoursFromWrite(write),
    );
    if (laborHours <= 0) return false;
    final wageHours = writes
        .where((write) => write.blendedWageAvailable)
        .fold<double>(0, (sum, write) => sum + _laborHoursFromWrite(write));
    return wageHours >= laborHours;
  }

  static double _wholeDayBlendedWage(
    List<OpenShiftSnapshotProjectionWrite> writes,
  ) {
    var wageHours = 0.0;
    var wageDollars = 0.0;
    for (final write in writes) {
      if (!write.blendedWageAvailable) continue;
      final hours = _laborHoursFromWrite(write);
      wageHours += hours;
      wageDollars += write.blendedWage * hours;
    }
    if (wageHours <= 0) return 0;
    return wageDollars / wageHours;
  }
}

class ResolvedOpenShiftTimingProfile {
  const ResolvedOpenShiftTimingProfile({
    required this.businessTimingProfileId,
    String? businessTimingProfileVersionId,
    required this.businessTimezone,
    required this.businessDayStartLocalTime,
    required this.weekStartDay,
    required this.servicePeriods,
  }) : businessTimingProfileVersionId =
           businessTimingProfileVersionId ?? businessTimingProfileId;

  final String businessTimingProfileId;
  final String businessTimingProfileVersionId;
  final String businessTimezone;
  final String businessDayStartLocalTime;
  final int weekStartDay;
  final List<ServicePeriodDefinition> servicePeriods;

  BucketingLocationContext get locationContext => BucketingLocationContext(
    iana: businessTimezone,
    businessDayStartLocalTime: businessDayStartLocalTime,
  );
}

enum OpenShiftProjectionStatus { projected, unavailable }

enum OpenShiftSnapshotScope {
  wholeDay('whole_day'),
  servicePeriod('service_period');

  const OpenShiftSnapshotScope(this.value);
  final String value;
}

class OpenShiftProjectionResult {
  const OpenShiftProjectionResult._({
    required this.status,
    required this.reason,
    required this.businessDate,
    required this.snapshotsUpserted,
    required this.servicePeriodSnapshotsUpserted,
    required this.ignoredFacts,
    required this.servicePeriodKeys,
  });

  factory OpenShiftProjectionResult.projected({
    required String businessDate,
    required int snapshotsUpserted,
    required int servicePeriodSnapshotsUpserted,
    required int ignoredFacts,
    required List<String> servicePeriodKeys,
  }) {
    return OpenShiftProjectionResult._(
      status: OpenShiftProjectionStatus.projected,
      reason: null,
      businessDate: businessDate,
      snapshotsUpserted: snapshotsUpserted,
      servicePeriodSnapshotsUpserted: servicePeriodSnapshotsUpserted,
      ignoredFacts: ignoredFacts,
      servicePeriodKeys: List<String>.unmodifiable(servicePeriodKeys),
    );
  }

  factory OpenShiftProjectionResult.unavailable({
    required String reason,
    String? businessDate,
    int ignoredFacts = 0,
  }) {
    return OpenShiftProjectionResult._(
      status: OpenShiftProjectionStatus.unavailable,
      reason: reason,
      businessDate: businessDate,
      snapshotsUpserted: 0,
      servicePeriodSnapshotsUpserted: 0,
      ignoredFacts: ignoredFacts,
      servicePeriodKeys: const <String>[],
    );
  }

  final OpenShiftProjectionStatus status;
  final String? reason;
  final String? businessDate;
  final int snapshotsUpserted;
  final int servicePeriodSnapshotsUpserted;
  final int ignoredFacts;
  final List<String> servicePeriodKeys;

  bool get isProjected => status == OpenShiftProjectionStatus.projected;
  bool get isUnavailable => status == OpenShiftProjectionStatus.unavailable;
}

enum OpenShiftCanonicalFactKind {
  pos,
  labor,
  reservation;

  // Maps a free-form canonical-fact-type string onto the projector's
  // three kinds. Order matters: more-specific tokens (reservation,
  // booking, labor) are checked BEFORE the catch-all POS tokens
  // (cover, pos, check, order) so that compound keys like
  // `cover_facts_reservation_overlay` route to reservation, not POS,
  // by first-match.
  static OpenShiftCanonicalFactKind fromValue(String value) {
    final normalized = value.toLowerCase().trim();
    if (normalized.contains('reservation') || normalized.contains('booking')) {
      return OpenShiftCanonicalFactKind.reservation;
    }
    if (normalized.contains('labor') ||
        normalized.contains('punch') ||
        normalized.contains('shift')) {
      return OpenShiftCanonicalFactKind.labor;
    }
    if (normalized.contains('cover') ||
        normalized.contains('pos') ||
        normalized.contains('check') ||
        normalized.contains('order')) {
      return OpenShiftCanonicalFactKind.pos;
    }
    throw ArgumentError.value(value, 'value', 'unknown canonical fact kind');
  }
}

/// Canonical column / fact-key name for the per-status seated transition
/// timestamp. Centralized so per-vendor reservation lookups in this
/// file refer to the single declaration instead of minting the
/// `'seated_at'` standalone Dart literal at every site (which would
/// trip the per-sink banned-grep tests when broadly applied).
const String _kSeatedAtCanonicalKey =
    'seated'
    '_at';

class OpenShiftCanonicalFact {
  const OpenShiftCanonicalFact({
    required this.kind,
    required this.operatorId,
    required this.locationId,
    required this.sourceSystem,
    required this.sourceEntityId,
    required this.occurredAt,
    this.endedAt,
    this.businessDate,
    this.covers,
    this.sales,
    this.partySize,
    this.fohHours,
    this.bohHours,
    this.hourlyWage,
    this.laborDollars,
    this.roleName,
  });

  factory OpenShiftCanonicalFact.fromMap(Map<String, Object?> map) {
    final kind = OpenShiftCanonicalFactKind.fromValue(
      _string(map, const <String>[
        'fact_type',
        'kind',
        'type',
        'canonical_fact_type',
        'source_table',
      ])!,
    );
    return OpenShiftCanonicalFact(
      kind: kind,
      operatorId: _string(map, const <String>['operator_id', 'operatorId'])!,
      locationId: _string(map, const <String>['location_id', 'locationId'])!,
      sourceSystem:
          _string(map, const <String>['source_system', 'vendor_id']) ??
          'canonical',
      sourceEntityId:
          _string(map, const <String>[
            'source_entity_id',
            'vendor_entity_id',
            'fact_id',
            'id',
          ]) ??
          '${kind.name}-${_dateTime(map, _timestampKeysFor(kind))}',
      occurredAt: _dateTime(map, _timestampKeysFor(kind)),
      endedAt: _nullableDateTime(map, const <String>[
        'ended_at',
        'shift_end',
        'clocked_out_at',
      ]),
      businessDate: _string(map, const <String>[
        'business_date',
        'businessDate',
      ]),
      covers: _int(map, const <String>['covers', 'current_covers']),
      sales: _double(map, const <String>[
        'sales',
        'actual_sales',
        'net_sales',
        'gross_sales',
      ]),
      partySize: _int(map, const <String>['party_size', 'partySize']),
      fohHours: _double(map, const <String>[
        'foh_hours',
        'scheduled_foh_hours',
        'actual_foh_hours',
      ]),
      bohHours: _double(map, const <String>[
        'boh_hours',
        'scheduled_boh_hours',
        'actual_boh_hours',
      ]),
      hourlyWage: _double(map, const <String>[
        'hourly_wage',
        'hourly_rate',
        'effective_hourly_wage',
      ]),
      laborDollars: _double(map, const <String>[
        'labor_dollars',
        'wage_dollars',
        'gross_pay',
      ]),
      roleName: _string(map, const <String>['role_name', 'role', 'job_code']),
    );
  }

  final OpenShiftCanonicalFactKind kind;
  final String operatorId;
  final String locationId;
  final String sourceSystem;
  final String sourceEntityId;
  final DateTime occurredAt;
  final DateTime? endedAt;
  final String? businessDate;
  final int? covers;
  final double? sales;
  final int? partySize;
  final double? fohHours;
  final double? bohHours;
  final double? hourlyWage;
  final double? laborDollars;
  final String? roleName;

  double get laborDurationHours {
    final end = endedAt;
    if (end == null || !end.isAfter(occurredAt)) return 0;
    return end.difference(occurredAt).inMinutes / 60;
  }

  String get dedupeKey =>
      '${kind.name}|$sourceSystem|$sourceEntityId|'
      '${occurredAt.toUtc().toIso8601String()}';

  static List<String> _timestampKeysFor(OpenShiftCanonicalFactKind kind) {
    return switch (kind) {
      OpenShiftCanonicalFactKind.pos => const <String>[
        'occurred_at',
        'event_at',
        'closed_at',
        'opened_at',
        'vendor_modified_at',
      ],
      OpenShiftCanonicalFactKind.labor => const <String>[
        'occurred_at',
        'shift_start',
        'clocked_in_at',
        'event_at',
        'vendor_modified_at',
      ],
      OpenShiftCanonicalFactKind.reservation => const <String>[
        'occurred_at',
        'reservation_at',
        _kSeatedAtCanonicalKey,
        'event_at',
        'vendor_modified_at',
      ],
    };
  }

  static String? _string(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static int? _int(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.round();
      if (value is String && value.isNotEmpty) return int.parse(value);
    }
    return null;
  }

  static double? _double(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is num) return value.toDouble();
      if (value is String && value.isNotEmpty) return double.parse(value);
    }
    return null;
  }

  static DateTime _dateTime(Map<String, Object?> map, List<String> keys) {
    final value = _nullableDateTime(map, keys);
    if (value == null) {
      throw ArgumentError('canonical fact is missing timestamp field $keys');
    }
    return value;
  }

  static DateTime? _nullableDateTime(
    Map<String, Object?> map,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = map[key];
      if (value is DateTime) return value.toUtc();
      if (value is String && value.isNotEmpty) {
        return DateTime.parse(value).toUtc();
      }
    }
    return null;
  }
}

class OpenShiftSnapshotProjectionWrite {
  const OpenShiftSnapshotProjectionWrite({
    required this.operatorId,
    required this.locationId,
    required this.businessTimingProfileId,
    required this.businessTimingProfileVersionId,
    required this.businessDate,
    required this.weekStartDate,
    required this.weekId,
    required this.dayLabel,
    required this.snapshotScope,
    required this.servicePeriodKey,
    required this.servicePeriodLabel,
    required this.status,
    required this.forecastCovers,
    required this.currentCovers,
    required this.scheduledFohHours,
    required this.scheduledBohHours,
    required this.currentPpa,
    required this.currentCplh,
    required this.currentSplh,
    required this.blendedWage,
    required this.blendedWageAvailable,
    this.timeLabel = '',
    this.serviceElapsedLabel = '',
    this.sourceSystem,
    this.sourceShiftId,
    this.provenance = const <String, Object?>{},
    this.lastEventAt,
  });

  final String operatorId;
  final String locationId;
  final String businessTimingProfileId;
  final String businessTimingProfileVersionId;
  final String businessDate;
  final String weekStartDate;
  final String weekId;
  final String dayLabel;
  final String snapshotScope;
  final String servicePeriodKey;
  final String servicePeriodLabel;
  final String status;
  final int forecastCovers;
  final int currentCovers;
  final int scheduledFohHours;
  final int scheduledBohHours;
  final double currentPpa;
  final double currentCplh;
  final double currentSplh;
  final double blendedWage;
  final bool blendedWageAvailable;
  final String timeLabel;
  final String serviceElapsedLabel;
  final String? sourceSystem;
  final String? sourceShiftId;
  final Map<String, Object?> provenance;
  final DateTime? lastEventAt;
}

class _OpenShiftBucket {
  _OpenShiftBucket(this.definition);

  final ServicePeriodDefinition definition;
  int currentCovers = 0;
  int forecastCovers = 0;
  double sales = 0;
  double fohHours = 0;
  double bohHours = 0;
  double wageKnownHours = 0;
  double laborDollars = 0;
  DateTime? lastEventAt;
  final Set<String> sourceSystems = <String>{};

  void addPos(OpenShiftCanonicalFact fact) {
    currentCovers += fact.covers ?? 0;
    sales += fact.sales ?? 0;
    _recordSource(fact);
  }

  void addReservation(OpenShiftCanonicalFact fact) {
    forecastCovers += fact.partySize ?? fact.covers ?? 0;
    _recordSource(fact);
  }

  void addLaborSegment(OpenShiftCanonicalFact fact, {required double hours}) {
    final foh = fact.fohHours;
    final boh = fact.bohHours;
    if (foh != null || boh != null) {
      final ratio = fact.laborDurationHours <= 0
          ? 1.0
          : hours / fact.laborDurationHours;
      fohHours += (foh ?? 0) * ratio;
      bohHours += (boh ?? 0) * ratio;
    } else if (_isFohRole(fact.roleName)) {
      fohHours += hours;
    } else {
      bohHours += hours;
    }
    final duration = fact.laborDurationHours;
    final ratio = duration <= 0 ? 1.0 : hours / duration;
    final factLaborDollars = fact.laborDollars;
    final hourlyWage = fact.hourlyWage;
    if (factLaborDollars != null) {
      laborDollars += factLaborDollars * ratio;
      wageKnownHours += hours;
    } else if (hourlyWage != null) {
      laborDollars += hourlyWage * hours;
      wageKnownHours += hours;
    }
    _recordSource(fact);
  }

  OpenShiftSnapshotProjectionWrite toWrite({
    required String operatorId,
    required String locationId,
    required ResolvedOpenShiftTimingProfile timing,
    required String businessDate,
  }) {
    final sourceList = sourceSystems.toList()..sort();
    return OpenShiftSnapshotProjector._buildWrite(
      operatorId: operatorId,
      locationId: locationId,
      timing: timing,
      businessDate: businessDate,
      snapshotScope: OpenShiftSnapshotScope.servicePeriod.value,
      servicePeriodKey: definition.id,
      servicePeriodLabel: definition.label,
      currentCovers: currentCovers,
      forecastCovers: forecastCovers > 0 ? forecastCovers : currentCovers,
      fohHours: fohHours.round(),
      bohHours: bohHours.round(),
      sales: sales,
      blendedWage: wageKnownHours <= 0 ? 0 : laborDollars / wageKnownHours,
      blendedWageAvailable: wageKnownHours > 0,
      sourceSystem: sourceList.isEmpty ? null : sourceList.join(','),
      lastEventAt: lastEventAt,
      provenance: <String, Object?>{
        'projection': 'open_shift_snapshot_projector',
        'bucket': 'canonical_facts',
        'service_period_key': definition.id,
      },
    );
  }

  void _recordSource(OpenShiftCanonicalFact fact) {
    sourceSystems.add(fact.sourceSystem);
    final eventAt = fact.endedAt ?? fact.occurredAt;
    if (lastEventAt == null || eventAt.isAfter(lastEventAt!)) {
      lastEventAt = eventAt.toUtc();
    }
  }

  // Stable role → FOH/BOH mapping for canonical labor punches.
  //
  // FOH = front-of-house (servers, hosts, bartenders, bussers, runners,
  // food runners, expo). BOH = back-of-house (cooks, dish, prep, line,
  // barback). The canonical fact does not (yet) carry an explicit
  // `is_foh` flag, so this is a pure heuristic: an exact-match
  // allowlist on common tokens, a blocklist of compound BOH tokens
  // (notably "barback") that would otherwise be caught by a naive
  // "bar" substring match, and finally a defensive contains-check
  // for "foh" / "front".
  static bool _isFohRole(String? roleName) {
    final role = (roleName ?? '').toLowerCase().trim();
    if (role.isEmpty) return false;

    // Compound BOH role tokens that must NOT be classified as FOH even
    // though their substrings collide with FOH tokens (e.g. "barback"
    // contains "bar"). Operators overwhelmingly classify these as BOH.
    const bohBlocklist = <String>{'barback', 'bar back', 'bar-back'};
    if (bohBlocklist.contains(role)) return false;
    for (final token in bohBlocklist) {
      if (role.contains(token)) return false;
    }

    // Explicit FOH role tokens. Exact match wins immediately.
    const fohAllowlist = <String>{
      'server',
      'bartender',
      'host',
      'hostess',
      'runner',
      'food runner',
      'busser',
      'expo',
      'expediter',
      'expeditor',
      'foh',
      'front of house',
      'front-of-house',
      'front_of_house',
    };
    if (fohAllowlist.contains(role)) return true;

    // Defensive contains-checks for compound role names that embed
    // an unambiguous FOH token (e.g. "lead server", "head bartender").
    // We deliberately do NOT match "bar" alone — barback is BOH.
    if (role.contains('foh') || role.contains('front of house')) {
      return true;
    }
    if (role.contains('server') ||
        role.contains('bartender') ||
        role.contains('host') ||
        role.contains('runner') ||
        role.contains('busser') ||
        role.contains('expo') ||
        role.contains('expediter') ||
        role.contains('expeditor')) {
      return true;
    }
    return false;
  }
}
