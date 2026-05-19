import 'dart:convert';

import '../../../../services/integration/canonical_fact_projection_retry.dart';
import '../../../../services/integration/first_connection_backfill_job.dart';
import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class CanonicalFactProjectionRetryRepository extends OperatorScopedRepository
    implements CanonicalFactProjectionRetryJobStore {
  CanonicalFactProjectionRetryRepository(super.tenantWrapper);

  static const String _selectColumns =
      'job_id::text as job_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'restaurant_id, '
      'connection_id::text as connection_id, '
      'vendor_id, '
      'category, '
      'status, '
      'failure_stage, '
      'changed_periods::text as changed_periods, '
      'open_current_fact_maps::text as open_current_fact_maps, '
      'input_hash, '
      'fact_count, '
      'attempt_count, '
      'worker_id, '
      'claimed_at, '
      'next_attempt_at, '
      'last_error_class, '
      'last_error_message, '
      'stack_first_frame, '
      'user_id::text as user_id';

  @override
  Future<void> recordProjectionFailure(
    CanonicalFactProjectionRetryRecord record,
  ) {
    return _insertFailure(
      record,
      status: CanonicalFactProjectionRetryStatus.pending,
      deadLettered: false,
    );
  }

  @override
  Future<void> recordPreInputProjectionFailure(
    CanonicalFactProjectionPreInputFailureRecord record,
  ) {
    return _insertFailure(
      record.toDeadLetterRetryRecord(),
      status: CanonicalFactProjectionRetryStatus.deadLettered,
      deadLettered: true,
    );
  }

  Future<void> _insertFailure(
    CanonicalFactProjectionRetryRecord record, {
    required CanonicalFactProjectionRetryStatus status,
    required bool deadLettered,
  }) {
    final ctx = TenantContext(
      operatorId: record.operatorId,
      locationId: record.locationId,
      userId: record.userId,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.canonical_fact_projection_retry_jobs ('
        'operator_id, location_id, restaurant_id, connection_id, '
        'original_location_id, original_connection_id, '
        'vendor_id, category, status, failure_stage, changed_periods, '
        'open_current_fact_maps, input_hash, fact_count, '
        'last_error_class, last_error_message, stack_first_frame, user_id, '
        'dead_lettered_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @restaurant_id, '
        '@connection_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@vendor_id, @category, @status, @failure_stage, '
        '@changed_periods::jsonb, '
        '@open_current_fact_maps::jsonb, @input_hash, @fact_count, '
        '@last_error_class, @last_error_message, @stack_first_frame, '
        '@user_id::uuid, '
        'case when @dead_lettered then now() else null end)',
        parameters: <String, Object?>{
          'operator_id': record.operatorId,
          'location_id': record.locationId,
          'restaurant_id': record.restaurantId,
          'connection_id': record.connectionId,
          'vendor_id': record.vendorId,
          'category': record.integrationCategory.backfillWire,
          'status': status.wire,
          'failure_stage': record.failureStage.wire,
          'changed_periods': jsonEncode(record.changedPeriods),
          'open_current_fact_maps': jsonEncode(record.openCurrentFactMaps),
          'input_hash': record.inputHash,
          'fact_count': record.factCount,
          'last_error_class': record.errorClass,
          'last_error_message': record.errorMessage,
          'stack_first_frame': record.stackFirstFrame,
          'user_id': record.userId,
          'dead_lettered': deadLettered,
        },
      );
    });
  }

  @override
  Future<CanonicalFactProjectionRetryJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    Duration claimStaleAfter = const Duration(minutes: 15),
  }) {
    if (workerId.trim().isEmpty) {
      throw ArgumentError.value(workerId, 'workerId', 'must be non-blank');
    }
    if (claimStaleAfter <= Duration.zero) {
      throw ArgumentError.value(
        claimStaleAfter,
        'claimStaleAfter',
        'must be positive',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return withTenant<CanonicalFactProjectionRetryJob?>(ctx, (exec) async {
      final rows = await exec.query(
        'with claimed as ('
        '  select job_id '
        '  from public.canonical_fact_projection_retry_jobs '
        '  where operator_id = @operator_id::uuid '
        '    and location_id = @location_id::uuid '
        '    and location_id is not null '
        '    and connection_id is not null '
        "    and (status = 'pending' "
        "      or (status = 'running' "
        '        and (claimed_at is null '
        "          or claimed_at < now() - (@claim_stale_seconds * interval '1 second'))"
        '      )'
        '    ) '
        '    and next_attempt_at <= now() '
        '  order by next_attempt_at asc, created_at asc '
        '  for update skip locked '
        '  limit 1'
        '), updated as ('
        '  update public.canonical_fact_projection_retry_jobs jobs '
        "  set status = 'running', "
        '      claimed_at = now(), '
        '      worker_id = @worker_id, '
        '      attempt_count = attempt_count + 1, '
        '      updated_at = now() '
        '  from claimed '
        '  where jobs.job_id = claimed.job_id '
        '  returning $_selectColumns'
        ') '
        'select * from updated',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'worker_id': workerId,
          'claim_stale_seconds': claimStaleAfter.inSeconds,
        },
      );
      if (rows.isEmpty) return null;
      return _fromRow(rows.single);
    });
  }

  @override
  Future<void> markSucceeded(CanonicalFactProjectionRetryJob job) {
    final ctx = TenantContext(
      operatorId: job.operatorId,
      locationId: job.locationId,
      userId: job.userId,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'update public.canonical_fact_projection_retry_jobs '
        "set status = 'succeeded', "
        '    completed_at = now(), '
        '    worker_id = null, '
        '    claimed_at = null, '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and job_id = @job_id::uuid',
        parameters: <String, Object?>{
          'operator_id': job.operatorId,
          'location_id': job.locationId,
          'job_id': job.jobId,
        },
      );
    });
  }

  @override
  Future<void> markFailed({
    required CanonicalFactProjectionRetryJob job,
    required Object error,
    required StackTrace stackTrace,
    int maxAttempts = kCanonicalFactProjectionRetryMaxAttempts,
    Duration retryDelay = kCanonicalFactProjectionRetryDelay,
  }) {
    final deadLetter = job.attemptCount >= maxAttempts;
    final ctx = TenantContext(
      operatorId: job.operatorId,
      locationId: job.locationId,
      userId: job.userId,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'update public.canonical_fact_projection_retry_jobs '
        'set status = @status, '
        '    worker_id = null, '
        '    claimed_at = null, '
        '    next_attempt_at = case '
        "      when @dead_letter then next_attempt_at "
        "      else now() + (@retry_delay_seconds * interval '1 second') "
        '    end, '
        '    dead_lettered_at = case '
        '      when @dead_letter then coalesce(dead_lettered_at, now()) '
        '      else dead_lettered_at '
        '    end, '
        '    last_error_class = @last_error_class, '
        '    last_error_message = @last_error_message, '
        '    stack_first_frame = @stack_first_frame, '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and job_id = @job_id::uuid',
        parameters: <String, Object?>{
          'status': deadLetter
              ? CanonicalFactProjectionRetryStatus.deadLettered.wire
              : CanonicalFactProjectionRetryStatus.pending.wire,
          'dead_letter': deadLetter,
          'retry_delay_seconds': retryDelay.inSeconds,
          'last_error_class': error.runtimeType.toString(),
          'last_error_message': error.toString(),
          'stack_first_frame': _firstStackFrame(stackTrace),
          'operator_id': job.operatorId,
          'location_id': job.locationId,
          'job_id': job.jobId,
        },
      );
    });
  }

  static CanonicalFactProjectionRetryJob _fromRow(Map<String, Object?> row) {
    return CanonicalFactProjectionRetryJob(
      jobId: _requiredString(row, 'job_id'),
      status: CanonicalFactProjectionRetryStatus.fromWire(
        _requiredString(row, 'status'),
      ),
      attemptCount: _requiredInt(row, 'attempt_count'),
      nextAttemptAt: _requiredDateTime(row, 'next_attempt_at'),
      operatorId: _requiredString(row, 'operator_id'),
      locationId: _requiredString(row, 'location_id'),
      restaurantId: _requiredString(row, 'restaurant_id'),
      integrationCategory: FirstConnectionBackfillCategoryWire.fromWire(
        _requiredString(row, 'category'),
      ),
      vendorId: _requiredString(row, 'vendor_id'),
      connectionId: _requiredString(row, 'connection_id'),
      changedPeriods: _jsonObjectList(row['changed_periods']),
      openCurrentFactMaps: _jsonObjectList(row['open_current_fact_maps']),
      inputHash: _requiredString(row, 'input_hash'),
      factCount: _requiredInt(row, 'fact_count'),
      errorClass: _requiredString(row, 'last_error_class'),
      errorMessage: _requiredString(row, 'last_error_message'),
      stackFirstFrame: _optionalString(row['stack_first_frame']),
      failureStage: CanonicalFactProjectionRetryFailureStage.fromWire(
        _requiredString(row, 'failure_stage'),
      ),
      userId: _optionalString(row['user_id']),
      workerId: _optionalString(row['worker_id']),
      claimedAt: _optionalDateTime(row['claimed_at']),
    );
  }
}

List<Map<String, Object?>> _jsonObjectList(Object? raw) {
  final decoded = raw is String ? jsonDecode(raw) : raw;
  if (decoded is! List) {
    throw StateError('projection retry JSON payload must be a list');
  }
  return <Map<String, Object?>>[
    for (final item in decoded) Map<String, Object?>.from(item as Map),
  ];
}

String _requiredString(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw StateError('projection retry row missing non-blank $key');
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _requiredInt(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is int) return value;
  throw StateError('projection retry row missing integer $key');
}

DateTime _requiredDateTime(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is DateTime) return value;
  throw StateError('projection retry row missing timestamp $key');
}

DateTime? _optionalDateTime(Object? value) {
  return value is DateTime ? value : null;
}

String _firstStackFrame(StackTrace stackTrace) {
  final text = stackTrace.toString();
  if (text.isEmpty) return '';
  return text.split('\n').first;
}
