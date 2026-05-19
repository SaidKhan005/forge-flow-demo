import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/models/demand_forecast_context.dart';
import '../../domain/models/service_period_definition.dart';
import 'canonical_fact_post_commit_projector.dart';
import 'canonical_fact_to_closed_shift_input.dart';
import 'first_connection_backfill_job.dart';
import 'integration_adapter_common.dart';

const int kCanonicalFactProjectionRetryMaxAttempts = 5;
const Duration kCanonicalFactProjectionRetryDelay = Duration(minutes: 15);

abstract interface class CanonicalFactProjectionRetryRecorder {
  Future<void> recordProjectionFailure(
    CanonicalFactProjectionRetryRecord record,
  );

  Future<void> recordPreInputProjectionFailure(
    CanonicalFactProjectionPreInputFailureRecord record,
  );
}

abstract interface class CanonicalFactProjectionRetryJobStore
    implements CanonicalFactProjectionRetryRecorder {
  Future<CanonicalFactProjectionRetryJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    Duration claimStaleAfter = const Duration(minutes: 15),
  });

  Future<void> markSucceeded(CanonicalFactProjectionRetryJob job);

  Future<void> markFailed({
    required CanonicalFactProjectionRetryJob job,
    required Object error,
    required StackTrace stackTrace,
    int maxAttempts = kCanonicalFactProjectionRetryMaxAttempts,
    Duration retryDelay = kCanonicalFactProjectionRetryDelay,
  });
}

class CanonicalFactProjectionRetryRecord {
  CanonicalFactProjectionRetryRecord({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.integrationCategory,
    required this.vendorId,
    required this.connectionId,
    required this.changedPeriods,
    required this.openCurrentFactMaps,
    required this.inputHash,
    required this.factCount,
    required this.errorClass,
    required this.errorMessage,
    required this.stackFirstFrame,
    required this.failureStage,
    this.userId,
  });

  factory CanonicalFactProjectionRetryRecord.fromFailure({
    required CanonicalFactPostCommitInput input,
    required int factCount,
    required Object error,
    required String? stackFirstFrame,
  }) {
    final changedPeriods = <Map<String, Object?>>[
      for (final period in input.changedPeriods) _periodToJson(period),
    ];
    final openCurrentFactMaps = <Map<String, Object?>>[
      for (final fact in input.openCurrentFactMaps)
        Map<String, Object?>.from(fact),
    ];
    final hash = _inputHash(
      operatorId: input.operatorId,
      locationId: input.locationId,
      restaurantId: input.restaurantId,
      integrationCategory: input.integrationCategory,
      vendorId: input.vendorId,
      connectionId: input.connectionId,
      changedPeriods: changedPeriods,
      openCurrentFactMaps: openCurrentFactMaps,
      userId: input.userId,
    );
    return CanonicalFactProjectionRetryRecord(
      operatorId: input.operatorId,
      locationId: input.locationId,
      restaurantId: input.restaurantId,
      integrationCategory: input.integrationCategory,
      vendorId: input.vendorId,
      connectionId: input.connectionId,
      changedPeriods: changedPeriods,
      openCurrentFactMaps: openCurrentFactMaps,
      inputHash: hash,
      factCount: factCount,
      errorClass: error.runtimeType.toString(),
      errorMessage: error.toString(),
      stackFirstFrame: stackFirstFrame,
      failureStage: CanonicalFactProjectionRetryFailureStage.postInput,
      userId: input.userId,
    );
  }

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final IntegrationCategory integrationCategory;
  final String vendorId;
  final String connectionId;
  final List<Map<String, Object?>> changedPeriods;
  final List<Map<String, Object?>> openCurrentFactMaps;
  final String inputHash;
  final int factCount;
  final String errorClass;
  final String errorMessage;
  final String? stackFirstFrame;
  final CanonicalFactProjectionRetryFailureStage failureStage;
  final String? userId;

  CanonicalFactPostCommitInput toInput() {
    return CanonicalFactPostCommitInput(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      integrationCategory: integrationCategory,
      vendorId: vendorId,
      connectionId: connectionId,
      changedPeriods: <CanonicalFactCommittedPeriod>[
        for (final period in changedPeriods) _periodFromJson(period),
      ],
      openCurrentFactMaps: <Map<String, Object?>>[
        for (final fact in openCurrentFactMaps) Map<String, Object?>.from(fact),
      ],
      userId: userId,
    );
  }
}

class CanonicalFactProjectionPreInputFailureRecord {
  CanonicalFactProjectionPreInputFailureRecord({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.integrationCategory,
    required this.vendorId,
    required this.connectionId,
    required this.canonicalFactMaps,
    required this.inputHash,
    required this.factCount,
    required this.errorClass,
    required this.errorMessage,
    required this.stackFirstFrame,
    this.userId,
  });

  factory CanonicalFactProjectionPreInputFailureRecord.fromFailure({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required IntegrationCategory integrationCategory,
    required String vendorId,
    required String connectionId,
    required Iterable<Map<String, Object?>> canonicalFactMaps,
    required Object error,
    required String? stackFirstFrame,
    String? userId,
  }) {
    final factMaps = _jsonSafeFactMaps(canonicalFactMaps);
    final hash = _preInputHash(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      integrationCategory: integrationCategory,
      vendorId: vendorId,
      connectionId: connectionId,
      canonicalFactMaps: factMaps,
      userId: userId,
    );
    return CanonicalFactProjectionPreInputFailureRecord(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      integrationCategory: integrationCategory,
      vendorId: vendorId,
      connectionId: connectionId,
      canonicalFactMaps: factMaps,
      inputHash: hash,
      factCount: factMaps.length,
      errorClass: error.runtimeType.toString(),
      errorMessage: error.toString(),
      stackFirstFrame: stackFirstFrame,
      userId: userId,
    );
  }

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final IntegrationCategory integrationCategory;
  final String vendorId;
  final String connectionId;
  final List<Map<String, Object?>> canonicalFactMaps;
  final String inputHash;
  final int factCount;
  final String errorClass;
  final String errorMessage;
  final String? stackFirstFrame;
  final String? userId;

  /// The existing ledger has no separate pre-input payload column. Store the
  /// raw fact maps in the JSON payload field and leave `changedPeriods` empty
  /// so current replay code cannot mistake this for a complete input.
  CanonicalFactProjectionRetryRecord toDeadLetterRetryRecord() {
    return CanonicalFactProjectionRetryRecord(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      integrationCategory: integrationCategory,
      vendorId: vendorId,
      connectionId: connectionId,
      changedPeriods: const <Map<String, Object?>>[],
      openCurrentFactMaps: canonicalFactMaps,
      inputHash: inputHash,
      factCount: factCount,
      errorClass: errorClass,
      errorMessage: errorMessage,
      stackFirstFrame: stackFirstFrame,
      failureStage: CanonicalFactProjectionRetryFailureStage.preInput,
      userId: userId,
    );
  }
}

enum CanonicalFactProjectionRetryFailureStage {
  postInput('post_input'),
  preInput('pre_input');

  const CanonicalFactProjectionRetryFailureStage(this.wire);
  final String wire;

  static CanonicalFactProjectionRetryFailureStage fromWire(String value) {
    for (final stage in CanonicalFactProjectionRetryFailureStage.values) {
      if (stage.wire == value) return stage;
    }
    throw ArgumentError.value(value, 'value', 'unknown retry failure stage');
  }
}

class CanonicalFactProjectionRetryJob
    extends CanonicalFactProjectionRetryRecord {
  CanonicalFactProjectionRetryJob({
    required this.jobId,
    required this.status,
    required this.attemptCount,
    required this.nextAttemptAt,
    required super.operatorId,
    required super.locationId,
    required super.restaurantId,
    required super.integrationCategory,
    required super.vendorId,
    required super.connectionId,
    required super.changedPeriods,
    required super.openCurrentFactMaps,
    required super.inputHash,
    required super.factCount,
    required super.errorClass,
    required super.errorMessage,
    required super.stackFirstFrame,
    required super.failureStage,
    super.userId,
    this.workerId,
    this.claimedAt,
  });

  final String jobId;
  final CanonicalFactProjectionRetryStatus status;
  final int attemptCount;
  final DateTime nextAttemptAt;
  final String? workerId;
  final DateTime? claimedAt;
}

enum CanonicalFactProjectionRetryStatus {
  pending('pending'),
  running('running'),
  succeeded('succeeded'),
  deadLettered('dead_lettered');

  const CanonicalFactProjectionRetryStatus(this.wire);
  final String wire;

  static CanonicalFactProjectionRetryStatus fromWire(String value) {
    for (final status in CanonicalFactProjectionRetryStatus.values) {
      if (status.wire == value) return status;
    }
    throw ArgumentError.value(
      value,
      'value',
      'unknown projection retry status',
    );
  }
}

class CanonicalFactProjectionRetryDispatcher {
  const CanonicalFactProjectionRetryDispatcher({
    required CanonicalFactProjectionRetryJobStore jobStore,
    required CanonicalFactPostCommitProjector projector,
  }) : _jobStore = jobStore,
       _projector = projector;

  final CanonicalFactProjectionRetryJobStore _jobStore;
  final CanonicalFactPostCommitProjector _projector;

  Future<CanonicalFactProjectionRetryDispatchResult> dispatchNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    int maxAttempts = kCanonicalFactProjectionRetryMaxAttempts,
    Duration retryDelay = kCanonicalFactProjectionRetryDelay,
  }) async {
    final job = await _jobStore.claimNext(
      operatorId: operatorId,
      locationId: locationId,
      workerId: workerId,
    );
    if (job == null) {
      return const CanonicalFactProjectionRetryDispatchResult(
        outcome: CanonicalFactProjectionRetryDispatchOutcome.noJob,
      );
    }
    try {
      await _projector.project(job.toInput());
      await _jobStore.markSucceeded(job);
      return CanonicalFactProjectionRetryDispatchResult(
        outcome: CanonicalFactProjectionRetryDispatchOutcome.succeeded,
        jobId: job.jobId,
      );
    } catch (error, stack) {
      await _jobStore.markFailed(
        job: job,
        error: error,
        stackTrace: stack,
        maxAttempts: maxAttempts,
        retryDelay: retryDelay,
      );
      return CanonicalFactProjectionRetryDispatchResult(
        outcome: job.attemptCount >= maxAttempts
            ? CanonicalFactProjectionRetryDispatchOutcome.deadLettered
            : CanonicalFactProjectionRetryDispatchOutcome.failed,
        jobId: job.jobId,
      );
    }
  }
}

class CanonicalFactProjectionRetryDispatchResult {
  const CanonicalFactProjectionRetryDispatchResult({
    required this.outcome,
    this.jobId,
  });

  final CanonicalFactProjectionRetryDispatchOutcome outcome;
  final String? jobId;
}

enum CanonicalFactProjectionRetryDispatchOutcome {
  noJob,
  succeeded,
  failed,
  deadLettered,
}

Map<String, Object?> _periodToJson(CanonicalFactCommittedPeriod period) {
  return <String, Object?>{
    'operator_id': period.operatorId,
    'location_id': period.locationId,
    'restaurant_id': period.restaurantId,
    'business_date': period.businessDate,
    'week_id': period.weekId,
    'day_label': period.dayLabel,
    'service_period_key': period.servicePeriodKey,
    'service_period_definition': period.servicePeriodDefinition.toMap(),
    'state': period.state.wire,
    'business_timing_profile_id': period.businessTimingProfileId,
    'business_timing_profile_version_id': period.businessTimingProfileVersionId,
    'forecast_context': period.forecastContext?.toMap(),
    'walk_in_override': period.walkInOverride == null
        ? null
        : <String, Object?>{
            'operator_walk_in_count':
                period.walkInOverride!.operatorWalkInCount,
          },
  };
}

CanonicalFactCommittedPeriod _periodFromJson(Map<String, Object?> json) {
  final definitionRaw = json['service_period_definition'];
  final forecastRaw = json['forecast_context'];
  final walkInRaw = json['walk_in_override'];
  return CanonicalFactCommittedPeriod(
    operatorId: _requiredString(json, 'operator_id'),
    locationId: _requiredString(json, 'location_id'),
    restaurantId: _requiredString(json, 'restaurant_id'),
    businessDate: _requiredString(json, 'business_date'),
    weekId: _requiredString(json, 'week_id'),
    dayLabel: _requiredString(json, 'day_label'),
    servicePeriodKey: _requiredString(json, 'service_period_key'),
    servicePeriodDefinition: ServicePeriodDefinition.fromMap(
      Map<String, dynamic>.from(definitionRaw! as Map),
    ),
    state: _periodStateFromWire(_requiredString(json, 'state')),
    businessTimingProfileId: _optionalString(
      json['business_timing_profile_id'],
    ),
    businessTimingProfileVersionId: _optionalString(
      json['business_timing_profile_version_id'],
    ),
    forecastContext: forecastRaw is Map
        ? DemandForecastContext.fromMap(Map<String, dynamic>.from(forecastRaw))
        : null,
    walkInOverride: walkInRaw is Map
        ? ReservationWalkInOverride(
            operatorWalkInCount: _requiredInt(
              Map<String, Object?>.from(walkInRaw),
              'operator_walk_in_count',
            ),
          )
        : null,
  );
}

CanonicalFactPeriodState _periodStateFromWire(String value) {
  for (final state in CanonicalFactPeriodState.values) {
    if (state.wire == value) return state;
  }
  throw ArgumentError.value(value, 'value', 'unknown committed period state');
}

String _inputHash({
  required String operatorId,
  required String locationId,
  required String restaurantId,
  required IntegrationCategory integrationCategory,
  required String vendorId,
  required String connectionId,
  required List<Map<String, Object?>> changedPeriods,
  required List<Map<String, Object?>> openCurrentFactMaps,
  required String? userId,
}) {
  final canonical = jsonEncode(<String, Object?>{
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'integration_category': integrationCategory.backfillWire,
    'vendor_id': vendorId,
    'connection_id': connectionId,
    'changed_periods': changedPeriods,
    'open_current_fact_maps': openCurrentFactMaps,
    'user_id': userId,
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

String _preInputHash({
  required String operatorId,
  required String locationId,
  required String restaurantId,
  required IntegrationCategory integrationCategory,
  required String vendorId,
  required String connectionId,
  required List<Map<String, Object?>> canonicalFactMaps,
  required String? userId,
}) {
  final canonical = jsonEncode(<String, Object?>{
    'failure_stage': 'pre_input',
    'operator_id': operatorId,
    'location_id': locationId,
    'restaurant_id': restaurantId,
    'integration_category': integrationCategory.backfillWire,
    'vendor_id': vendorId,
    'connection_id': connectionId,
    'canonical_fact_maps': canonicalFactMaps,
    'user_id': userId,
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

List<Map<String, Object?>> _jsonSafeFactMaps(
  Iterable<Map<String, Object?>> canonicalFactMaps,
) {
  return List<Map<String, Object?>>.unmodifiable(<Map<String, Object?>>[
    for (final fact in canonicalFactMaps)
      Map<String, Object?>.unmodifiable(<String, Object?>{
        for (final entry in fact.entries)
          entry.key: _jsonSafeValue(entry.value),
      }),
  ]);
}

Object? _jsonSafeValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is DateTime) {
    return value.toUtc().toIso8601String();
  }
  if (value is Iterable) {
    return <Object?>[for (final item in value) _jsonSafeValue(item)];
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _jsonSafeValue(entry.value),
    };
  }
  return value.toString();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw StateError('projection retry payload missing non-blank $key');
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw StateError('projection retry payload missing integer $key');
}
