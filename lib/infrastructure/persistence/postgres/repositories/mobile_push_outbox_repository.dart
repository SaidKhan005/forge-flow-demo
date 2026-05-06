import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class MobilePushOutboxEnqueue {
  const MobilePushOutboxEnqueue({
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.dedupeKey,
    required this.appVariant,
    required this.appEnvironment,
    required this.title,
    required this.body,
    this.sourceOutboxId,
    this.sourceTopic,
    this.deeplink,
    this.data = const <String, Object?>{},
    this.scheduledFor,
  });

  final String operatorId;
  final String locationId;
  final String userId;
  final String dedupeKey;
  final String appVariant;
  final String appEnvironment;
  final String title;
  final String body;
  final String? sourceOutboxId;
  final String? sourceTopic;
  final String? deeplink;
  final Map<String, Object?> data;
  final DateTime? scheduledFor;
}

class MobilePushOutboxMessage {
  const MobilePushOutboxMessage({
    required this.messageId,
    required this.operatorId,
    required this.userId,
    required this.dedupeKey,
    required this.appVariant,
    required this.appEnvironment,
    required this.title,
    required this.body,
    required this.data,
    required this.status,
    required this.attemptCount,
    this.sourceOutboxId,
    this.sourceTopic,
    this.deeplink,
  });

  final String messageId;
  final String operatorId;
  final String userId;
  final String dedupeKey;
  final String appVariant;
  final String appEnvironment;
  final String title;
  final String body;
  final Map<String, Object?> data;
  final String status;
  final int attemptCount;
  final String? sourceOutboxId;
  final String? sourceTopic;
  final String? deeplink;
}

class MobilePushOutboxRepository extends OperatorScopedRepository {
  MobilePushOutboxRepository(super.tenantWrapper);

  static const String _selectColumns =
      'message_id::text as message_id, '
      'operator_id::text as operator_id, '
      'user_id::text as user_id, '
      'source_outbox_id::text as source_outbox_id, '
      'source_topic, '
      'dedupe_key, '
      'app_variant, '
      'app_environment, '
      'title, '
      'body, '
      'deeplink, '
      'data, '
      'status, '
      'attempt_count';

  Future<MobilePushOutboxMessage> enqueue(MobilePushOutboxEnqueue command) {
    final ctx = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.userId,
    );
    return withTenant<MobilePushOutboxMessage>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.mobile_push_outbox ('
        'operator_id, user_id, source_outbox_id, source_topic, dedupe_key, '
        'app_variant, app_environment, title, body, deeplink, data, '
        'scheduled_for'
        ') values ('
        '@operator_id::uuid, @user_id::uuid, @source_outbox_id::bigint, '
        '@source_topic, @dedupe_key, @app_variant, @app_environment, '
        '@title, @body, @deeplink, @data::jsonb, '
        'coalesce(@scheduled_for::timestamptz, now())'
        ') on conflict (operator_id, dedupe_key) do update set '
        'source_outbox_id = coalesce('
        'excluded.source_outbox_id, public.mobile_push_outbox.source_outbox_id), '
        'source_topic = coalesce('
        'excluded.source_topic, public.mobile_push_outbox.source_topic), '
        'app_variant = excluded.app_variant, '
        'app_environment = excluded.app_environment, '
        'title = excluded.title, '
        'body = excluded.body, '
        'deeplink = excluded.deeplink, '
        'data = excluded.data, '
        'scheduled_for = excluded.scheduled_for, '
        "status = case when public.mobile_push_outbox.status = 'sent' "
        "then 'sent' else 'pending' end, "
        'last_error = null, '
        'updated_at = now() '
        'returning $_selectColumns',
        parameters: <String, Object?>{
          'operator_id': command.operatorId,
          'user_id': command.userId,
          'source_outbox_id': command.sourceOutboxId,
          'source_topic': command.sourceTopic,
          'dedupe_key': command.dedupeKey,
          'app_variant': command.appVariant,
          'app_environment': command.appEnvironment,
          'title': command.title,
          'body': command.body,
          'deeplink': command.deeplink,
          'data': jsonEncode(command.data),
          'scheduled_for': command.scheduledFor?.toUtc().toIso8601String(),
        },
      );
      if (rows.isEmpty) {
        throw StateError('mobile push outbox enqueue returned no rows');
      }
      return _messageFromMap(rows.single);
    });
  }

  Future<List<MobilePushOutboxMessage>> claimBatch({
    required String operatorId,
    required String locationId,
    required int batchSize,
    String? userId,
  }) {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<MobilePushOutboxMessage>>(ctx, (exec) async {
      final rows = await exec.query(
        'with claimed as ('
        '  select message_id from public.mobile_push_outbox '
        '  where operator_id = @operator_id::uuid '
        "    and status in ('pending', 'partial_failed') "
        '    and scheduled_for <= now() '
        '  order by scheduled_for, message_id '
        '  for update skip locked '
        '  limit @batch_size'
        '), updated as ('
        '  update public.mobile_push_outbox q '
        "     set status = 'sending', "
        '         claimed_at = now(), '
        '         attempt_count = attempt_count + 1, '
        '         last_error = null '
        '    from claimed '
        '   where q.message_id = claimed.message_id '
        '  returning $_selectColumns'
        ') '
        'select $_selectColumns from updated order by message_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'batch_size': batchSize,
        },
      );
      return rows.map(_messageFromMap).toList(growable: false);
    });
  }

  Future<int> markResult({
    required String operatorId,
    required String locationId,
    required String userId,
    required String messageId,
    required int targetCount,
    required int sentCount,
    required int failedCount,
    String? lastError,
  }) {
    final status = failedCount == 0
        ? 'sent'
        : sentCount == 0
        ? 'failed'
        : 'partial_failed';
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update public.mobile_push_outbox '
        'set status = @status, '
        '    target_count = @target_count, '
        '    sent_count = @sent_count, '
        '    failed_count = @failed_count, '
        '    sent_at = case when @status = @sent_status then now() else sent_at end, '
        '    failed_at = case when @status <> @sent_status then now() else null end, '
        '    last_error = @last_error, '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and user_id = @user_id::uuid '
        '  and message_id = @message_id::uuid',
        parameters: <String, Object?>{
          'status': status,
          'sent_status': 'sent',
          'target_count': targetCount,
          'sent_count': sentCount,
          'failed_count': failedCount,
          'last_error': lastError,
          'operator_id': operatorId,
          'user_id': userId,
          'message_id': messageId,
        },
      );
    });
  }
}

MobilePushOutboxMessage _messageFromMap(PostgresRow row) {
  return MobilePushOutboxMessage(
    messageId: row['message_id']! as String,
    operatorId: row['operator_id']! as String,
    userId: row['user_id']! as String,
    sourceOutboxId: row['source_outbox_id'] as String?,
    sourceTopic: row['source_topic'] as String?,
    dedupeKey: row['dedupe_key']! as String,
    appVariant: row['app_variant']! as String,
    appEnvironment: row['app_environment']! as String,
    title: row['title']! as String,
    body: row['body']! as String,
    deeplink: row['deeplink'] as String?,
    data: _decodeMap(row['data']),
    status: row['status']! as String,
    attemptCount: row['attempt_count']! as int,
  );
}

Map<String, Object?> _decodeMap(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  if (raw is String) {
    if (raw.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  }
  throw StateError('mobile push outbox row returned malformed data');
}
