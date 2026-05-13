// Lane C C-1 — EmailEventRepository.
//
// Persistence layer for `public.email_event`. The SendGrid Event
// Webhook receiver writes through this repository; replays land
// harmlessly via `ON CONFLICT (provider_event_id) DO NOTHING` against
// the partial UNIQUE INDEX `email_event_provider_event_id_unique`
// (migration `202605131700_c_1a_email_event_provider_id.sql`).
//
// Pool choice: admin pool (`runAsSystem` / `withSystem`) via
// [OperatorScopedRepository]. Rationale:
//
//   * Inbound SendGrid events identify the email via `sg_message_id`
//     (column `email_event.provider_message_id`), NOT directly via
//     `email_id`. Resolving the FK back to a specific operator
//     requires a join against `email_outbox.provider_message_id` —
//     which is set by the dispatcher AFTER the provider accepts the
//     send. There is no reliable way to bind a tenant context at the
//     moment the event arrives (the operator that owns the email may
//     not be resolvable until after the dispatcher's `recordOutcome`
//     updates the outbox row). The webhook is therefore platform-
//     internal bookkeeping, not an operator surface.
//   * The existing `email_event` RLS policy `email_event_per_tenant_
//     select` (migration `202605040200_phase_9_8_email_provider.sql`
//     line 326) filters via EXISTS join through
//     `email_outbox.operator_id`, so READS for operator surfaces are
//     already RLS-protected. The INSERT path uses `forge_admin`
//     (BYPASSRLS) because the inbound event row's `email_id` may be
//     NULL on arrival.
//   * Audit attribution: every `withSystem` call carries a
//     non-blank `reason` (`'email_event.insert_provider_event'`) so
//     the `app.bypass_rls_audit` GUC names the caller in the audit
//     trail, mirroring `PostgresEmailOutboxRepository`.
//
// Idempotency contract: the INSERT statement is
//
//   INSERT INTO public.email_event (
//     provider_event_id, event_kind, event_payload,
//     occurred_at, received_at, provider_message_id
//   ) VALUES (..., @event_kind, @event_payload::jsonb, ...)
//   ON CONFLICT (provider_event_id)
//     WHERE provider_event_id IS NOT NULL
//   DO NOTHING
//   RETURNING event_id::text
//
// The `WHERE provider_event_id IS NOT NULL` predicate on the ON
// CONFLICT clause matches the partial UNIQUE INDEX's predicate; the
// receiver only inserts rows with `provider_event_id` non-null
// (the parser rejects events that omit `sg_event_id`), so the predicate
// always evaluates true for the inserted row. The combination is the
// Postgres-supported way to reference a partial unique index from an
// ON CONFLICT clause when the index predicate is non-trivial.
// Reference: Postgres docs §7.8 "INSERT … ON CONFLICT".
//
// If the partial index already holds a row with the same
// `provider_event_id`, Postgres returns no row from the INSERT
// statement (because no actual insert happened); we map that to
// `EmailEventInsertResult.duplicate`. On a fresh insert, the
// RETURNING clause yields the surrogate `event_id` UUID.
//
// Authority:
//   * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-1 (line 83).
//   * docs/_execution/lane_c_parity/03_execution_slices.md "Slice C-1
//     — SendGrid Event Webhook receiver" (line 9-29).
//   * db/migrations/202605131700_c_1a_email_event_provider_id.sql.
//   * db/migrations/202605040200_phase_9_8_email_provider.sql lines
//     301-344 (email_event table).
//   * lib/services/email/postgres_email_outbox_repository.dart —
//     precedent for `runAsSystem` discipline on the email pipeline.

import 'dart:convert';

import '../../../../services/email/sendgrid_event_payload.dart';
import '../operator_scoped_repository.dart';

/// Outcome of an [EmailEventRepository.insertProviderEvent] call.
sealed class EmailEventInsertResult {
  const EmailEventInsertResult();

  /// The INSERT committed a fresh row. [eventId] is the surrogate
  /// `email_event.event_id` UUID that the route handler can log if
  /// observability needs to correlate this insert with downstream
  /// reads.
  const factory EmailEventInsertResult.inserted(String eventId) =
      EmailEventInsertInserted;

  /// The INSERT was a no-op because a row with the same
  /// `provider_event_id` already exists (idempotent replay). The
  /// route handler treats this as success (204) — the duplicate
  /// is exactly the behavior the partial UNIQUE INDEX is meant to
  /// produce.
  const factory EmailEventInsertResult.duplicate() =
      EmailEventInsertDuplicate;
}

class EmailEventInsertInserted extends EmailEventInsertResult {
  const EmailEventInsertInserted(this.eventId);
  final String eventId;
}

class EmailEventInsertDuplicate extends EmailEventInsertResult {
  const EmailEventInsertDuplicate();
}

class EmailEventRepository extends OperatorScopedRepository {
  EmailEventRepository(super.tenantWrapper);

  /// Audit-attribution reason string used by every `withSystem` call
  /// originating from the SendGrid webhook receiver. Mirrors the
  /// stable-string discipline used by `PostgresEmailOutboxRepository`
  /// (`'email_outbox.claim_pending'`, `'email_outbox.record_outcome'`)
  /// so log search can correlate webhook activity with the
  /// `app.bypass_rls_audit` GUC.
  static const String kInsertProviderEventReason =
      'email_event.insert_provider_event';

  /// INSERT one SendGrid event with `ON CONFLICT (provider_event_id)
  /// DO NOTHING` against the partial UNIQUE INDEX. Returns
  /// [EmailEventInsertResult.inserted] on a fresh insert, or
  /// [EmailEventInsertResult.duplicate] when the row was a replay.
  ///
  /// The repository does NOT resolve `email_id` from `provider_message_
  /// id`; that is a downstream concern (and may not yet be possible at
  /// the moment the event arrives — the email_outbox row may be in
  /// `pending` state without a `provider_message_id` yet). The
  /// `email_event.email_id` column is left NULL on insert and may be
  /// backfilled by a future reconciliation step. The RLS policy
  /// tolerates NULL `email_id` (the policy's EXISTS join returns no
  /// rows for `email_id IS NULL`, which is the intended posture —
  /// platform-internal events stay reachable only through
  /// `forge_admin` until they are reconciled).
  Future<EmailEventInsertResult> insertProviderEvent(
    SendGridEvent event, {
    DateTime Function()? now,
  }) {
    final clock = now ?? DateTime.now;
    return withSystem<EmailEventInsertResult>(
      (exec) async {
        // event_payload is jsonb; pass canonical JSON of the raw
        // payload map so audit / replay downstream can read every
        // field SendGrid sent. The cast `::jsonb` lets Postgres
        // validate the string is well-formed JSON; the parser
        // already produced this map from valid JSON so the cast
        // is defensive belt.
        final payloadJson = jsonEncode(event.rawPayload);
        final rows = await exec.query(
          'insert into public.email_event ('
          '  provider_event_id, '
          '  event_kind, '
          '  event_payload, '
          '  occurred_at, '
          '  received_at, '
          '  provider_message_id'
          ') values ('
          '  @provider_event_id, '
          '  @event_kind, '
          '  @event_payload::jsonb, '
          '  @occurred_at::timestamptz, '
          '  @received_at::timestamptz, '
          '  @provider_message_id'
          ') '
          'on conflict (provider_event_id) '
          '  where provider_event_id is not null '
          'do nothing '
          'returning event_id::text as event_id',
          parameters: <String, Object?>{
            'provider_event_id': event.providerEventId,
            'event_kind': event.eventKind,
            'event_payload': payloadJson,
            'occurred_at': event.occurredAt.toUtc().toIso8601String(),
            'received_at': clock().toUtc().toIso8601String(),
            'provider_message_id': event.providerMessageId,
          },
        );
        if (rows.isEmpty) {
          // Duplicate by partial-index predicate. ON CONFLICT DO
          // NOTHING returns zero rows in RETURNING; the route layer
          // treats this as success (204).
          return const EmailEventInsertResult.duplicate();
        }
        final eventId = rows.single['event_id'];
        if (eventId is! String || eventId.isEmpty) {
          throw StateError(
            'email_event insert returned a malformed event_id',
          );
        }
        return EmailEventInsertResult.inserted(eventId);
      },
      reason: kInsertProviderEventReason,
    );
  }
}
