// Slice C-4 - demo-mode master switch repository.
//
// Operator-scoped writes to public.demo_mode_state. The master switch is a
// one-way Demo -> Live transition; it never creates a demo row and never
// flips an existing live row back to demo.

import 'dart:convert';

import '../../../../services/integration/demo_mode_state.dart';
import '../../../../services/integration/integration_adapter_common.dart';
import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';
import 'audit_logs_repository.dart';

const String demoModeMasterSwitchAction = 'demo_mode.master_switch_to_live';

class DemoModeStateRepositoryRejected implements Exception {
  const DemoModeStateRepositoryRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;
}

class DemoModeMasterSwitchResult {
  const DemoModeMasterSwitchResult({
    required this.records,
    required this.flippedCount,
    this.idempotentReplay = false,
  });

  final List<DemoModeRecord> records;
  final int flippedCount;
  final bool idempotentReplay;

  bool get flippedAny => flippedCount > 0;
}

class DemoModeStateRepository extends OperatorScopedRepository {
  DemoModeStateRepository(
    super.tenantWrapper, {
    required AuditLogsRepository auditLogsRepository,
  }) : _auditLogsRepository = auditLogsRepository;

  final AuditLogsRepository _auditLogsRepository;

  Future<DemoModeMasterSwitchResult> flipAllDemoRowsToLive({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime flippedAt,
    required String idempotencyKey,
    required String requestBodyHash,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DemoModeMasterSwitchResult>(ctx, (exec) async {
      final requestType = _requestTypeFor(requestBodyHash);
      final replay = await _lookupIdempotency(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        idempotencyKey: idempotencyKey,
        requestType: requestType,
      );
      if (replay != null) return replay;

      final before = await _listForUpdate(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );
      final demoBefore = before.where((record) => record.isDemo).toList();
      if (demoBefore.isEmpty) {
        final racedReplay = await _lookupIdempotency(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          idempotencyKey: idempotencyKey,
          requestType: requestType,
        );
        if (racedReplay != null) return racedReplay;
        return DemoModeMasterSwitchResult(records: before, flippedCount: 0);
      }

      final reserved = await _reserveIdempotency(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        idempotencyKey: idempotencyKey,
        requestType: requestType,
      );
      if (!reserved) {
        final racedReplay = await _lookupIdempotency(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          idempotencyKey: idempotencyKey,
          requestType: requestType,
        );
        if (racedReplay != null) return racedReplay;
        throw const DemoModeStateRepositoryRejected(
          code: 'idempotency_request_in_flight',
          message: 'idempotent request is already in flight',
          statusCode: 409,
        );
      }

      final rows = await exec.query(
        'update public.demo_mode_state '
        'set is_demo = false, '
        'flipped_to_live_at = @flipped_at::timestamptz, '
        'flipped_by_connection_id = null, '
        'pending_inserts_count = 0, '
        'updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and is_demo = true '
        'returning $_selectColumns',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'flipped_at': flippedAt.toUtc().toIso8601String(),
        },
      );
      final flipped = rows.map(_recordFromRow).toList(growable: false);
      await _auditLogsRepository.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: flippedAt.toUtc(),
        actorKind: 'team_member',
        actorUserId: actorUserId,
        targetKind: 'demo_mode_state',
        targetId: locationId,
        action: demoModeMasterSwitchAction,
        payload: <String, Object?>{
          'categories_flipped': <String>[
            for (final record in flipped) record.category.name,
          ],
          'flipped_count': flipped.length,
          'operator_gate': 'operator_owner_or_operator_admin',
          'idempotency_key': idempotencyKey,
        },
      );

      final after = await _listForUpdate(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );
      final result = DemoModeMasterSwitchResult(
        records: after,
        flippedCount: flipped.length,
      );
      await _completeIdempotency(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        idempotencyKey: idempotencyKey,
        completedAt: flippedAt,
        payload: _resultPayload(result),
      );
      return result;
    });
  }

  static const String _selectColumns =
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'category, is_demo, '
      'flipped_to_live_at, '
      'flipped_by_connection_id::text as flipped_by_connection_id';

  static Future<List<DemoModeRecord>> _listForUpdate(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    final rows = await exec.query(
      'select $_selectColumns '
      'from public.demo_mode_state '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'order by category asc '
      'for update',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  static Future<DemoModeMasterSwitchResult?> _lookupIdempotency(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String requestType,
  }) async {
    final rows = await exec.query(
      '''
select request_type, response_payload
  from public.proxy_requests
 where operator_id = @operator_id::uuid
   and location_id = @location_id::uuid
   and idempotency_key = @idempotency_key
 limit 1
''',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'idempotency_key': idempotencyKey,
      },
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['request_type'] != requestType) {
      throw const DemoModeStateRepositoryRejected(
        code: 'idempotency_key_conflict',
        message: 'Idempotency-Key was already used for another request',
        statusCode: 409,
      );
    }
    final payload = _jsonObjectOrNull(row['response_payload']);
    if (payload == null) {
      throw const DemoModeStateRepositoryRejected(
        code: 'idempotency_request_in_flight',
        message: 'idempotent request is already in flight',
        statusCode: 409,
      );
    }
    return _resultFromPayload(payload);
  }

  static Future<bool> _reserveIdempotency(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String requestType,
  }) async {
    final rows = await exec.query(
      '''
insert into public.proxy_requests (
  idempotency_key,
  request_type,
  operator_id,
  location_id,
  usage_class,
  response_payload
) values (
  @idempotency_key,
  @request_type,
  @operator_id::uuid,
  @location_id::uuid,
  'demo_mode_master_switch',
  null
)
on conflict (operator_id, location_id, idempotency_key) do nothing
returning request_id
''',
      parameters: <String, Object?>{
        'idempotency_key': idempotencyKey,
        'request_type': requestType,
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    return rows.isNotEmpty;
  }

  static Future<void> _completeIdempotency(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required DateTime completedAt,
    required Map<String, Object?> payload,
  }) async {
    final affected = await exec.execute(
      '''
update public.proxy_requests
   set response_payload = @response_payload::jsonb,
       updated_at = @completed_at::timestamptz
 where operator_id = @operator_id::uuid
   and location_id = @location_id::uuid
   and idempotency_key = @idempotency_key
''',
      parameters: <String, Object?>{
        'response_payload': jsonEncode(payload),
        'completed_at': completedAt.toUtc().toIso8601String(),
        'operator_id': operatorId,
        'location_id': locationId,
        'idempotency_key': idempotencyKey,
      },
    );
    if (affected == 0) {
      throw const DemoModeStateRepositoryRejected(
        code: 'idempotency_completion_missing',
        message: 'idempotency reservation was not found',
        statusCode: 503,
      );
    }
  }

  static Map<String, Object?> _resultPayload(
    DemoModeMasterSwitchResult result,
  ) {
    return <String, Object?>{
      'demo_mode_states': <Map<String, Object?>>[
        for (final record in result.records) _recordJson(record),
      ],
      'flipped_count': result.flippedCount,
    };
  }

  static DemoModeMasterSwitchResult _resultFromPayload(
    Map<String, Object?> payload,
  ) {
    final records = payload['demo_mode_states'];
    final flippedCount = payload['flipped_count'];
    if (records is! List) {
      throw const DemoModeStateRepositoryRejected(
        code: 'idempotency_payload_malformed',
        message: 'stored idempotency response is malformed',
        statusCode: 503,
      );
    }
    return DemoModeMasterSwitchResult(
      records: <DemoModeRecord>[
        for (final record in records)
          _recordFromJson(Map<String, Object?>.from(record as Map)),
      ],
      flippedCount: flippedCount is int
          ? flippedCount
          : int.tryParse(flippedCount.toString()) ?? 0,
      idempotentReplay: true,
    );
  }

  static Map<String, Object?> _recordJson(DemoModeRecord record) {
    return <String, Object?>{
      'operator_id': record.operatorId,
      'location_id': record.locationId,
      'category': record.category.name,
      'is_demo': record.isDemo,
      if (record.flippedToLiveAt != null)
        'flipped_to_live_at': record.flippedToLiveAt!.toUtc().toIso8601String(),
      if (record.flippedByConnectionId != null)
        'flipped_by_connection_id': record.flippedByConnectionId,
    };
  }

  static DemoModeRecord _recordFromRow(PostgresRow row) {
    return DemoModeRecord(
      operatorId: row['operator_id'].toString(),
      locationId: row['location_id'].toString(),
      category: _categoryFromWire(row['category'].toString()),
      isDemo: row['is_demo'] == true,
      flippedToLiveAt: _dateTimeOrNull(row['flipped_to_live_at']),
      flippedByConnectionId: row['flipped_by_connection_id']?.toString(),
    );
  }

  static DemoModeRecord _recordFromJson(Map<String, Object?> row) {
    return DemoModeRecord(
      operatorId: row['operator_id'].toString(),
      locationId: row['location_id'].toString(),
      category: _categoryFromWire(row['category'].toString()),
      isDemo: row['is_demo'] == true,
      flippedToLiveAt: _dateTimeOrNull(row['flipped_to_live_at']),
      flippedByConnectionId: row['flipped_by_connection_id']?.toString(),
    );
  }

  static IntegrationCategory _categoryFromWire(String value) {
    for (final category in IntegrationCategory.values) {
      if (category.name == value) return category;
    }
    throw StateError('unknown demo_mode_state category "$value"');
  }

  static DateTime? _dateTimeOrNull(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }

  static Map<String, Object?>? _jsonObjectOrNull(Object? value) {
    if (value == null) return null;
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is Map) return Map<String, Object?>.from(decoded);
    return null;
  }

  static String _requestTypeFor(String requestBodyHash) =>
      '$demoModeMasterSwitchAction:$requestBodyHash';
}
