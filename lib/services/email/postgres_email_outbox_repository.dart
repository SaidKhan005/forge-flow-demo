// Phase 9.8 — Postgres-backed [EmailOutboxRepository] for the
// [EmailOutboxDispatcher].
//
// Producers enqueue rows into `public.email_outbox` in the same
// transaction as the business write; the dispatcher's per-minute
// LISTEN consumer wakes on `email_outbox_tick` and calls
// [EmailOutboxRepository.claimPending] to take a batch under
// `SELECT … FOR UPDATE SKIP LOCKED`. The dispatcher then walks the
// state machine and writes the result back via [recordOutcome].
//
// Both methods run through [TenantTransactionWrapper.runAsSystem]
// because:
//
//   * The `email_outbox` table holds operator-scoped AND
//     F&F-platform-internal rows (`operator_id IS NULL` for the
//     onboarding-invite + vendor-sync alerts that ship before any
//     operator exists). The dispatcher walks both classes uniformly,
//     and the operator-leading partial index admits the system index
//     when `operator_id IS NULL`.
//   * Per-tenant RLS WITH CHECK fences cross-tenant writes inside
//     normal traffic; for the dispatcher we DELIBERATELY want
//     cross-tenant claim — the dispatcher is platform-internal
//     bookkeeping, not an operator surface.
//
// Audit trail: each `runAsSystem` call carries a non-empty `reason`
// so the `app.bypass_rls_audit` GUC names the caller. The reason
// strings are stable so log search can correlate dispatcher activity
// with rows in `auth_events_audit`.

import 'dart:convert';

import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_transaction.dart';
import 'email_outbox_dispatcher.dart';

/// Postgres-backed implementation of [EmailOutboxRepository] used by
/// the proxy's startup-wired email dispatcher.
class PostgresEmailOutboxRepository implements EmailOutboxRepository {
  PostgresEmailOutboxRepository({
    required TenantTransactionWrapper adminWrapper,
  }) : _adminWrapper = adminWrapper;

  final TenantTransactionWrapper _adminWrapper;

  static const String _selectColumns =
      'email_id::text         as email_id, '
      'operator_id::text      as operator_id, '
      'recipient_email, '
      'recipient_display_name, '
      'template_id, '
      'template_data, '
      'attempt_count';

  @override
  Future<List<EmailOutboxRow>> claimPending({required int batchSize}) {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
    }
    return _adminWrapper.runAsSystem<List<EmailOutboxRow>>(
      (exec) async {
        // Single transactional CTE: claim the next batch of pending
        // rows, flip them to `sending` (so a concurrent claim from
        // another Cloud Run instance skips them), and return the
        // post-update projection.
        final rows = await exec.query(
          'with claimed as ('
          '  select email_id from public.email_outbox '
          "  where status = 'pending' "
          '    and scheduled_for <= now() '
          '  order by scheduled_for, email_id '
          '  for update skip locked '
          '  limit @batch_size'
          '), updated as ('
          '  update public.email_outbox q '
          "     set status = 'sending', "
          '         updated_at = now() '
          '    from claimed '
          '   where q.email_id = claimed.email_id '
          '  returning $_selectColumns'
          ') '
          'select $_selectColumns from updated order by email_id',
          parameters: <String, Object?>{
            'batch_size': batchSize,
          },
        );
        return rows.map(_rowFromMap).toList(growable: false);
      },
      reason: 'email_outbox.claim_pending',
    );
  }

  @override
  Future<void> recordOutcome(EmailDispatchOutcome outcome) {
    final statusLiteral = _statusLiteralFor(outcome.statusKind);
    return _adminWrapper.runAsSystem<void>(
      (exec) async {
        await exec.execute(
          'update public.email_outbox '
          'set status              = @status, '
          '    attempt_count       = @attempt_count, '
          '    provider_message_id = coalesce(@provider_message_id, '
          '                                   provider_message_id), '
          '    last_error          = @last_error, '
          '    last_attempt_at     = coalesce(@last_attempt_at::timestamptz, '
          '                                   last_attempt_at), '
          '    updated_at          = now() '
          'where email_id = @email_id::uuid',
          parameters: <String, Object?>{
            'status': statusLiteral,
            'attempt_count': outcome.attemptCount,
            'provider_message_id': outcome.providerMessageId,
            'last_error': outcome.lastError,
            'last_attempt_at': outcome.lastAttemptAt?.toUtc().toIso8601String(),
            'email_id': outcome.emailId,
          },
        );
      },
      reason: 'email_outbox.record_outcome',
    );
  }

  String _statusLiteralFor(EmailDispatchStatusKind kind) {
    switch (kind) {
      case EmailDispatchStatusKind.sent:
        return 'sent';
      case EmailDispatchStatusKind.pendingRetry:
        return 'pending';
      case EmailDispatchStatusKind.failed:
        return 'failed';
    }
  }

  EmailOutboxRow _rowFromMap(PostgresRow row) {
    final emailId = row['email_id'];
    final templateId = row['template_id'];
    final recipientEmail = row['recipient_email'];
    final attemptCount = row['attempt_count'];
    if (emailId is! String ||
        templateId is! String ||
        recipientEmail is! String ||
        attemptCount is! int) {
      throw StateError(
        'email_outbox row had an unexpected shape: $row',
      );
    }
    return EmailOutboxRow(
      emailId: emailId,
      templateId: templateId,
      recipientEmail: recipientEmail,
      recipientDisplayName: row['recipient_display_name'] is String
          ? row['recipient_display_name'] as String
          : null,
      templateData: _decodeTemplateData(row['template_data']),
      attemptCount: attemptCount,
      operatorId: row['operator_id'] is String
          ? row['operator_id'] as String
          : null,
    );
  }

  Map<String, String> _decodeTemplateData(Object? raw) {
    if (raw == null) return const <String, String>{};
    Map<String, dynamic> decoded;
    if (raw is Map<String, dynamic>) {
      decoded = raw;
    } else if (raw is Map) {
      decoded = raw.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    } else if (raw is String) {
      if (raw.isEmpty) return const <String, String>{};
      final parsed = jsonDecode(raw);
      if (parsed is! Map) {
        throw StateError(
          'email_outbox.template_data was not a JSON object',
        );
      }
      decoded = parsed.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    } else {
      throw StateError(
        'email_outbox.template_data had an unexpected shape: $raw',
      );
    }
    return decoded.map(
      (key, value) =>
          MapEntry(key, value == null ? '' : value.toString()),
    );
  }
}
