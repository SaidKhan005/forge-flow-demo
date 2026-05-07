import '../../../../services/integration/first_connection_backfill_job.dart';
import '../../../../services/integration/integration_adapter_common.dart';
import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class ConnectorBackfillJobRepository extends OperatorScopedRepository {
  ConnectorBackfillJobRepository(super.tenantWrapper);

  static const Duration defaultClaimStaleAfter = Duration(minutes: 15);

  static const String _selectColumns =
      'job_id::text as job_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'connection_id::text as connection_id, '
      'vendor_id, '
      'category, '
      'window_start, '
      'window_end, '
      'status, '
      'cursor_token, '
      'last_modified_seen, '
      'attempt_count, '
      'worker_id, '
      'claimed_at, '
      'completed_at, '
      'last_error, '
      'created_at, '
      'updated_at';

  Future<FirstConnectionBackfillJob> enqueueFirstBackfill({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorId,
    required IntegrationCategory category,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? actorUserId,
  }) {
    final window = FirstConnectionBackfillWindow(
      windowStart: windowStart,
      windowEnd: windowEnd,
    );
    _requireNonBlank('connectionId', connectionId);
    _requireNonBlank('vendorId', vendorId);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<FirstConnectionBackfillJob>(ctx, (exec) async {
      final rows = await exec.query(
        'with existing as ('
        '  select $_selectColumns '
        '  from public.connector_backfill_jobs '
        '  where operator_id = @operator_id::uuid '
        '    and location_id = @location_id::uuid '
        '    and connection_id = @connection_id::uuid '
        '    and category = @category '
        '    and mode = @mode '
        '    and window_start = @window_start::timestamptz '
        '    and window_end = @window_end::timestamptz '
        "    and status in ('pending', 'running') "
        '  order by created_at asc '
        '  limit 1'
        '), inserted as ('
        '  insert into public.connector_backfill_jobs ('
        '    operator_id, location_id, connection_id, vendor_id, category, '
        '    mode, status, window_start, window_end, created_by, updated_by'
        '  ) '
        '  select '
        '    @operator_id::uuid, @location_id::uuid, '
        '    @connection_id::uuid, @vendor_id, @category, @mode, '
        "    'pending', @window_start::timestamptz, "
        '    @window_end::timestamptz, @actor_user_id, @actor_user_id '
        '  where not exists (select 1 from existing) '
        '  on conflict do nothing '
        '  returning $_selectColumns'
        ') '
        'select * from inserted '
        'union all '
        'select * from existing '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'vendor_id': vendorId,
          'category': category.backfillWire,
          'mode': 'first_backfill',
          'window_start': window.windowStart,
          'window_end': window.windowEnd,
          'actor_user_id': actorUserId,
        },
      );
      final row = await _rowOrRaceFallback(
        rows,
        exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        category: category,
        windowStart: window.windowStart,
        windowEnd: window.windowEnd,
      );
      return FirstConnectionBackfillJob.fromRow(row);
    });
  }

  /// Returns the latest backfill job per connection for
  /// (operatorId, locationId). When [connectionId] is non-null the
  /// result is at most one row for that connection. Used by the
  /// operator-web `connector-backfill-jobs` read route to render
  /// per-connection progress on the Vendor Connections screen.
  Future<List<FirstConnectionBackfillJob>> listLatestPerConnection({
    required String operatorId,
    required String locationId,
    String? connectionId,
    String? actorUserId,
  }) {
    if (connectionId != null) _requireNonBlank('connectionId', connectionId);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<FirstConnectionBackfillJob>>(ctx, (exec) async {
      final params = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      };
      final connectionFilter = connectionId == null
          ? ''
          : 'and connection_id = @connection_id::uuid ';
      if (connectionId != null) {
        params['connection_id'] = connectionId;
      }
      final rows = await exec.query(
        'with ranked as ('
        '  select $_selectColumns, '
        '    row_number() over ('
        '      partition by connection_id '
        '      order by '
        "        case when status in ('pending', 'running') then 0 "
        "             when status = 'failed' then 1 "
        '             else 2 end, '
        '        updated_at desc '
        '    ) as rn '
        '  from public.connector_backfill_jobs '
        '  where operator_id = @operator_id::uuid '
        '    and location_id = @location_id::uuid '
        "    and mode = 'first_backfill' "
        '$connectionFilter'
        ') '
        'select * from ranked where rn = 1 '
        'order by updated_at desc',
        parameters: params,
      );
      return <FirstConnectionBackfillJob>[
        for (final row in rows) FirstConnectionBackfillJob.fromRow(row),
      ];
    });
  }

  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter = defaultClaimStaleAfter,
  }) {
    _requireNonBlank('workerId', workerId);
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
      userId: actorUserId,
    );
    return withTenant<FirstConnectionBackfillJob?>(ctx, (exec) async {
      final rows = await exec.query(
        'with claimed as ('
        '  select job_id '
        '  from public.connector_backfill_jobs '
        '  where operator_id = @operator_id::uuid '
        '    and location_id = @location_id::uuid '
        "    and mode = 'first_backfill' "
        "    and (status = 'pending' "
        "      or (status = 'running' "
        '        and (claimed_at is null '
        "          or claimed_at < now() - (@claim_stale_seconds * interval '1 second'))"
        '      )'
        '    ) '
        '  order by created_at asc '
        '  for update skip locked '
        '  limit 1'
        '), updated as ('
        '  update public.connector_backfill_jobs jobs '
        "  set status = 'running', "
        '      claimed_at = now(), '
        '      completed_at = null, '
        '      worker_id = @worker_id, '
        '      attempt_count = attempt_count + 1, '
        '      updated_at = now(), '
        '      updated_by = @actor_user_id '
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
          'actor_user_id': actorUserId,
        },
      );
      if (rows.isEmpty) return null;
      return FirstConnectionBackfillJob.fromRow(rows.single);
    });
  }

  Future<FirstConnectionBackfillJob?> markRunning({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String workerId,
    String? actorUserId,
  }) {
    _requireNonBlank('jobId', jobId);
    _requireNonBlank('workerId', workerId);
    return _updateOne(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      sql:
          'update public.connector_backfill_jobs set '
          "status = 'running', "
          'claimed_at = now(), '
          'completed_at = null, '
          'worker_id = @worker_id, '
          'attempt_count = attempt_count + 1, '
          'updated_at = now(), '
          'updated_by = @actor_user_id '
          'where operator_id = @operator_id::uuid '
          'and location_id = @location_id::uuid '
          'and job_id = @job_id::uuid '
          "and status in ('pending', 'running') "
          'returning $_selectColumns',
      parameters: <String, Object?>{'job_id': jobId, 'worker_id': workerId},
    );
  }

  Future<FirstConnectionBackfillJob?> markSucceeded({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? actorUserId,
  }) {
    _requireNonBlank('jobId', jobId);
    _requireNonBlank('cursorToken', cursorToken);
    return _updateOne(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      sql:
          'update public.connector_backfill_jobs set '
          "status = 'succeeded', "
          'cursor_token = @cursor_token, '
          'last_modified_seen = @last_modified_seen::timestamptz, '
          'completed_at = now(), '
          'last_error = null, '
          'updated_at = now(), '
          'updated_by = @actor_user_id '
          'where operator_id = @operator_id::uuid '
          'and location_id = @location_id::uuid '
          'and job_id = @job_id::uuid '
          "and status = 'running' "
          'returning $_selectColumns',
      parameters: <String, Object?>{
        'job_id': jobId,
        'cursor_token': cursorToken,
        'last_modified_seen': lastModifiedSeen.toUtc(),
      },
    );
  }

  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) {
    _requireNonBlank('jobId', jobId);
    _requireNonBlank('errorMessage', errorMessage);
    return _updateOne(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      sql:
          'update public.connector_backfill_jobs set '
          "status = 'failed', "
          'completed_at = now(), '
          'last_error = @error_message, '
          'updated_at = now(), '
          'updated_by = @actor_user_id '
          'where operator_id = @operator_id::uuid '
          'and location_id = @location_id::uuid '
          'and job_id = @job_id::uuid '
          "and status = 'running' "
          'returning $_selectColumns',
      parameters: <String, Object?>{
        'job_id': jobId,
        'error_message': errorMessage,
      },
    );
  }

  Future<FirstConnectionBackfillJob?> releaseForResume({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? errorMessage,
    String? actorUserId,
  }) {
    _requireNonBlank('jobId', jobId);
    _requireNonBlank('cursorToken', cursorToken);
    if (errorMessage != null) _requireNonBlank('errorMessage', errorMessage);
    return _updateOne(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      sql:
          'update public.connector_backfill_jobs set '
          "status = 'pending', "
          'cursor_token = @cursor_token, '
          'last_modified_seen = @last_modified_seen::timestamptz, '
          'claimed_at = null, '
          'completed_at = null, '
          'worker_id = null, '
          'last_error = @error_message, '
          'updated_at = now(), '
          'updated_by = @actor_user_id '
          'where operator_id = @operator_id::uuid '
          'and location_id = @location_id::uuid '
          'and job_id = @job_id::uuid '
          "and status = 'running' "
          'returning $_selectColumns',
      parameters: <String, Object?>{
        'job_id': jobId,
        'cursor_token': cursorToken,
        'last_modified_seen': lastModifiedSeen.toUtc(),
        'error_message': errorMessage,
      },
    );
  }

  Future<FirstConnectionBackfillJob?> _updateOne({
    required String operatorId,
    required String locationId,
    required String? actorUserId,
    required String sql,
    required Map<String, Object?> parameters,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<FirstConnectionBackfillJob?>(ctx, (exec) async {
      final rows = await exec.query(
        sql,
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'actor_user_id': actorUserId,
          ...parameters,
        },
      );
      if (rows.isEmpty) return null;
      return FirstConnectionBackfillJob.fromRow(rows.single);
    });
  }

  Future<Map<String, Object?>> _rowOrRaceFallback(
    List<Map<String, Object?>> rows,
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String connectionId,
    required IntegrationCategory category,
    required DateTime windowStart,
    required DateTime windowEnd,
  }) async {
    if (rows.isNotEmpty) return rows.single;
    final fallbackRows = await exec.query(
      'select $_selectColumns '
      'from public.connector_backfill_jobs '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and connection_id = @connection_id::uuid '
      'and category = @category '
      "and mode = 'first_backfill' "
      'and window_start = @window_start::timestamptz '
      'and window_end = @window_end::timestamptz '
      "and status in ('pending', 'running') "
      'order by created_at asc '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'category': category.backfillWire,
        'window_start': windowStart,
        'window_end': windowEnd,
      },
    );
    if (fallbackRows.isEmpty) {
      throw StateError(
        'connector_backfill_jobs enqueue returned no row; RLS likely '
        'blocked the write or the active job vanished during retry',
      );
    }
    return fallbackRows.single;
  }

  void _requireNonBlank(String name, String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, 'must be non-blank');
    }
  }
}
