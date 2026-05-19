// Phase 9.8 — Postgres-backed [SendGridWebhookGateway].
//
// Lives under `tool/advisor_proxy/` (not `lib/`) because the gateway
// imports the `tenant_transaction.dart` admin wrapper that the proxy
// owns end-to-end. The wrapper itself abstracts the executor, so this
// file does not import `package:postgres` directly.
//
// One ingest = one transaction. Inside the transaction:
//
//   1. Resolve `email_outbox.email_id` from the event record. We
//      prefer the custom-arg `email_id` echoed back by SendGrid — the
//      provider sends it as the canonical join key — and fall back to
//      `provider_message_id` for events whose messages pre-date the
//      custom_arg producer (`sendgrid_email_provider.dart`
//      `_buildSendBody`). When neither matches, the event is still
//      recorded with `email_id IS NULL` so the audit log is
//      lossless even for orphaned events.
//
//   2. Upsert the event row keyed by `provider_event_id` (SendGrid's
//      `sg_event_id`). The 9.8 idempotency migration adds a partial
//      UNIQUE index; ON CONFLICT DO NOTHING converts a retried event
//      into a no-op and the gateway returns `inserted: false`.
//
//   3. If the event row is fresh AND the mapped kind is a terminal
//      failure (`bounced` or `complaint`), flip
//      `email_outbox.status` to the matching value — but only when
//      the row is not already in a terminal state. This keeps the
//      status from flapping when SendGrid sends both a `bounce` and a
//      later `dropped` event for the same message.

import 'dart:convert';

import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/email/sendgrid_event_payload_parser.dart';
import 'package:forge_and_flow/services/email/sendgrid_webhook_handler.dart';

/// Recognise a UUID without round-tripping through Postgres. The
/// gateway uses this to short-circuit the email_outbox lookup when
/// the custom-arg `email_id` is malformed (bad clients, manual
/// curl-ed test events, …) so the SQL error path stays clean.
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

class PostgresSendGridWebhookGateway implements SendGridWebhookGateway {
  PostgresSendGridWebhookGateway({
    required TenantTransactionWrapper adminWrapper,
  }) : _adminWrapper = adminWrapper;

  final TenantTransactionWrapper _adminWrapper;

  @override
  Future<SendGridEventIngestResult> ingest(SendGridEventRecord event) {
    return _adminWrapper.runAsSystem<SendGridEventIngestResult>(
      (exec) async {
        String? boundEmailId;

        final candidateEmailId = event.emailId;
        if (candidateEmailId != null &&
            _uuidPattern.hasMatch(candidateEmailId)) {
          final rows = await exec.query(
            'select email_id::text as email_id '
            'from public.email_outbox '
            'where email_id = @id::uuid',
            parameters: <String, Object?>{'id': candidateEmailId},
          );
          if (rows.isNotEmpty) {
            final value = rows.first['email_id'];
            if (value is String) boundEmailId = value;
          }
        }
        if (boundEmailId == null && event.providerMessageId != null) {
          final rows = await exec.query(
            'select email_id::text as email_id '
            'from public.email_outbox '
            'where provider_message_id = @pmid '
            'limit 1',
            parameters: <String, Object?>{'pmid': event.providerMessageId},
          );
          if (rows.isNotEmpty) {
            final value = rows.first['email_id'];
            if (value is String) boundEmailId = value;
          }
        }

        final inserted = await exec.query(
          'insert into public.email_event ('
          '  email_id, provider_message_id, provider_event_id, '
          '  event_kind, event_payload, occurred_at'
          ') values ('
          '  case when @email_id is null then null '
          '       else @email_id::uuid end, '
          '  @provider_message_id, '
          '  @provider_event_id, '
          '  @event_kind, '
          '  @event_payload::jsonb, '
          '  @occurred_at::timestamptz'
          ') '
          'on conflict (provider_event_id) do nothing '
          'returning event_id::text as event_id',
          parameters: <String, Object?>{
            'email_id': boundEmailId,
            'provider_message_id': event.providerMessageId,
            'provider_event_id': event.providerEventId,
            'event_kind': event.eventKind,
            'event_payload': jsonEncode(event.payload),
            'occurred_at': event.occurredAt.toUtc().toIso8601String(),
          },
        );
        final wasInserted = inserted.isNotEmpty;

        var outboxStatusUpdated = false;
        if (wasInserted && boundEmailId != null) {
          final newStatus = kSendGridOutboxTerminalStatuses[event.eventKind];
          if (newStatus != null) {
            final updated = await exec.query(
              'update public.email_outbox '
              'set status     = @new_status, '
              '    updated_at = now() '
              'where email_id = @id::uuid '
              "  and status not in ('bounced', 'complaint') "
              'returning email_id::text as email_id',
              parameters: <String, Object?>{
                'new_status': newStatus,
                'id': boundEmailId,
              },
            );
            outboxStatusUpdated = updated.isNotEmpty;
          }
        }

        return SendGridEventIngestResult(
          providerEventId: event.providerEventId,
          inserted: wasInserted,
          outboxStatusUpdated: outboxStatusUpdated,
          boundEmailId: boundEmailId,
        );
      },
      reason: 'email_event.ingest',
    );
  }
}
