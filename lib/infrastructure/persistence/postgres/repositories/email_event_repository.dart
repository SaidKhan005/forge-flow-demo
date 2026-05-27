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
//   * docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md row C-1 (line 83).
//   * docs/archive/_execution/lane_c_parity/03_execution_slices.md "Slice C-1
//     — SendGrid Event Webhook receiver" (line 9-29).
//   * db/migrations/202605131700_c_1a_email_event_provider_id.sql.
//   * db/migrations/202605040200_phase_9_8_email_provider.sql lines
//     301-344 (email_event table).
//   * lib/services/email/postgres_email_outbox_repository.dart —
//     precedent for `runAsSystem` discipline on the email pipeline.

import 'dart:convert';

import '../../../../services/email/sendgrid_event_payload.dart';
import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

/// Outcome of an [EmailEventRepository.insertProviderEvent] call.
sealed class EmailEventInsertResult {
  const EmailEventInsertResult();

  /// The INSERT committed a fresh row. [eventId] is the surrogate
  /// `email_event.event_id` UUID that the route handler can log if
  /// observability needs to correlate this insert with downstream
  /// reads. [flipOutcome] records whether the same transaction also
  /// flipped the matching `email_outbox` row to a terminal status —
  /// `null` when the event was non-terminal (e.g. `delivered`,
  /// `opened`) or lacked a `provider_message_id`; otherwise one of
  /// the [EmailOutboxTerminalFlipResult] cases. The webhook does not
  /// branch on this value (204 either way) — it is exposed for
  /// observability + tests.
  const factory EmailEventInsertResult.inserted(
    String eventId, {
    EmailOutboxTerminalFlipResult? flipOutcome,
  }) = EmailEventInsertInserted;

  /// The INSERT was a no-op because a row with the same
  /// `provider_event_id` already exists (idempotent replay). The
  /// route handler treats this as success (204) — the duplicate
  /// is exactly the behavior the partial UNIQUE INDEX is meant to
  /// produce.
  ///
  /// Duplicates SKIP the `email_outbox` flip. The first delivery
  /// already performed the flip (or correctly skipped it); replays
  /// must not re-execute the side effect or they would (a) re-stamp
  /// `updated_at` on the outbox row uselessly, and (b) risk flapping
  /// the status when SendGrid emits both a `bounce` and a later
  /// `dropped` for the same email (the partial UNIQUE INDEX catches
  /// the second event, but only because we skip the flip here).
  const factory EmailEventInsertResult.duplicate() =
      EmailEventInsertDuplicate;
}

class EmailEventInsertInserted extends EmailEventInsertResult {
  const EmailEventInsertInserted(
    this.eventId, {
    this.flipOutcome,
  });
  final String eventId;

  /// Outcome of the same-transaction `email_outbox.status` flip, when
  /// the event kind was terminal and a `provider_message_id` was
  /// present; `null` otherwise. Exposed for observability + tests.
  final EmailOutboxTerminalFlipResult? flipOutcome;
}

class EmailEventInsertDuplicate extends EmailEventInsertResult {
  const EmailEventInsertDuplicate();
}

/// Outcome of an `email_outbox.status` terminal flip attempt. The
/// SendGrid webhook owns `bounced` / `complaint` transitions (see
/// `lib/services/email/email_outbox_dispatcher.dart:8-15`); this
/// value type lets the webhook insert + flip in the same transaction
/// while still surfacing which of the three branches the flip took
/// for observability + tests.
sealed class EmailOutboxTerminalFlipResult {
  const EmailOutboxTerminalFlipResult();

  /// The UPDATE flipped a row from a non-terminal state
  /// (`pending` / `sending` / `sent`) to the terminal status named
  /// by the inbound event (`bounced` or `complaint`).
  static const EmailOutboxTerminalFlipResult flipped =
      _EmailOutboxTerminalFlipFlipped();

  /// The UPDATE matched an `email_outbox` row but the existing
  /// `status` was already in the terminal set
  /// `{'bounced', 'complaint', 'failed'}`, so the guard
  /// (`status not in (...)` predicate) left it alone. Prevents
  /// (a) `'failed'` from the dispatcher's max-attempts path being
  /// overwritten, and (b) flapping when SendGrid emits both a
  /// `bounce` and a later `complaint` for the same email — first
  /// terminal wins.
  static const EmailOutboxTerminalFlipResult alreadyTerminal =
      _EmailOutboxTerminalFlipAlreadyTerminal();

  /// No `email_outbox` row matched the inbound
  /// `provider_message_id`. SendGrid sometimes emits events for
  /// outbound messages we never wrote (older provider state, or a
  /// platform-internal send the proxy did not record); per
  /// `email_event.email_id` being nullable, the audit row still
  /// lands but no flip happens.
  static const EmailOutboxTerminalFlipResult outboxNotFound =
      _EmailOutboxTerminalFlipOutboxNotFound();
}

class _EmailOutboxTerminalFlipFlipped extends EmailOutboxTerminalFlipResult {
  const _EmailOutboxTerminalFlipFlipped();
}

class _EmailOutboxTerminalFlipAlreadyTerminal
    extends EmailOutboxTerminalFlipResult {
  const _EmailOutboxTerminalFlipAlreadyTerminal();
}

class _EmailOutboxTerminalFlipOutboxNotFound
    extends EmailOutboxTerminalFlipResult {
  const _EmailOutboxTerminalFlipOutboxNotFound();
}

/// The set of `email_outbox.status` values considered terminal by the
/// flip guard. Exposed for tests + callers that want to reason about
/// the guard without re-encoding the constant.
const Set<String> kEmailOutboxTerminalStatuses = <String>{
  'bounced',
  'complaint',
  'failed',
};

/// Row returned by [EmailEventRepository.findEventsByProviderMessageId].
/// Subset of `email_event` columns the Q-2a email soak harness probe
/// route surfaces; deliberately narrow so the probe cannot exfiltrate
/// the full `event_payload` JSONB to an admin caller.
class EmailEventSummary {
  const EmailEventSummary({
    required this.eventId,
    required this.eventKind,
    required this.occurredAt,
    required this.receivedAt,
    required this.providerEventId,
    required this.providerMessageId,
  });

  final String eventId;
  final String eventKind;
  final DateTime occurredAt;
  final DateTime receivedAt;
  final String? providerEventId;
  final String? providerMessageId;
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

  /// Audit-attribution reason string used by the Q-2a email soak
  /// probe route. Stays distinct from the insert reason so log search
  /// can tell read-side probe activity apart from inbound webhook
  /// processing.
  static const String kFindByMessageIdReason =
      'email_event.email_soak_probe_find_by_message_id';

  /// INSERT one SendGrid event with `ON CONFLICT (provider_event_id)
  /// DO NOTHING` against the partial UNIQUE INDEX, AND in the same
  /// transaction flip the matching `email_outbox.status` to the
  /// terminal kind (`bounced` / `complaint`) when:
  ///
  ///   * the inserted row was a FRESH insert (NOT a duplicate replay), AND
  ///   * the event kind is terminal (`bounced` / `complaint`), AND
  ///   * the inbound event carried a non-empty `provider_message_id`
  ///     (so the FK to `email_outbox.email_id` can resolve).
  ///
  /// Returns [EmailEventInsertResult.inserted] on a fresh insert
  /// (with the same-transaction flip outcome attached as
  /// `flipOutcome`), or [EmailEventInsertResult.duplicate] when the
  /// row was a replay. Duplicates skip the flip (idempotent on
  /// SendGrid replays — the first delivery either flipped or
  /// correctly skipped).
  ///
  /// **Contract anchor.** `lib/services/email/email_outbox_dispatcher.
  /// dart:8-15` states:
  ///
  /// > The `bounced` / `complaint` transitions are owned by the
  /// > SendGrid webhook handler — the dispatcher itself only advances
  /// > pending → sending → sent / failed.
  ///
  /// This method is the implementation of that contract: the
  /// dispatcher only writes `'sent'` / `'failed'`; this code path
  /// (called via the SendGrid webhook receiver) is the only writer of
  /// `'bounced'` / `'complaint'`. Both the event audit row and the
  /// outbox flip land or roll back together because they share the
  /// single `runAsSystem` transaction opened here.
  ///
  /// The repository does NOT resolve `email_id` from `provider_message
  /// _id`; that is a downstream concern. The `email_event.email_id`
  /// column is left NULL on insert and may be backfilled by a future
  /// reconciliation step. The RLS policy tolerates NULL `email_id`
  /// (the policy's EXISTS join returns no rows for
  /// `email_id IS NULL`, which is the intended posture — platform-
  /// internal events stay reachable only through `forge_admin` until
  /// they are reconciled).
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
          // treats this as success (204). SKIP the outbox flip:
          // the first delivery already performed it (or correctly
          // skipped) and re-running the UPDATE would (a) bump
          // `updated_at` for no behavioural reason, and (b) risk
          // re-attempting a flip after a later event already wrote
          // a different terminal (e.g. `complaint` arriving after
          // `bounced`).
          return const EmailEventInsertResult.duplicate();
        }
        final eventId = rows.single['event_id'];
        if (eventId is! String || eventId.isEmpty) {
          throw StateError(
            'email_event insert returned a malformed event_id',
          );
        }
        final flipOutcome = await _flipOutboxStatusForTerminalEvent(exec, event);
        return EmailEventInsertResult.inserted(
          eventId,
          flipOutcome: flipOutcome,
        );
      },
      reason: kInsertProviderEventReason,
    );
  }

  /// Standalone entry point for flipping `email_outbox.status` to the
  /// terminal kind named by a SendGrid event. Opens its own
  /// `runAsSystem` transaction (admin pool, same per-tenant boundary
  /// the receiver uses).
  ///
  /// Returns `null` when the flip was a no-op because the event was
  /// non-terminal or carried no `provider_message_id`; otherwise one
  /// of [EmailOutboxTerminalFlipResult.flipped] /
  /// [EmailOutboxTerminalFlipResult.alreadyTerminal] /
  /// [EmailOutboxTerminalFlipResult.outboxNotFound].
  ///
  /// Production callers go through [insertProviderEvent] so the event
  /// row and the flip share one transaction. This standalone variant
  /// exists for (a) targeted reconciliation jobs that need to flip
  /// without re-inserting the audit row, and (b) testability of the
  /// flip logic in isolation.
  Future<EmailOutboxTerminalFlipResult?> flipOutboxStatusForTerminalEvent(
    SendGridEvent event,
  ) {
    return withSystem<EmailOutboxTerminalFlipResult?>(
      (exec) => _flipOutboxStatusForTerminalEvent(exec, event),
      reason: kInsertProviderEventReason,
    );
  }

  /// Inner flip helper that takes a [PostgresExecutor] so callers
  /// can share an existing transaction (the `insertProviderEvent`
  /// orchestration relies on this for the same-transaction
  /// guarantee). Returns `null` when the flip is a no-op:
  ///   * event kind is non-terminal (`delivered`, `opened`,
  ///     `clicked`, `dropped`, `deferred`, `processed`, `unknown`,
  ///     `unsubscribed`); OR
  ///   * `provider_message_id` is null / empty (the FK cannot
  ///     resolve so no outbox row could match).
  ///
  /// Otherwise issues a single UPDATE guarded by
  /// `status not in {'bounced','complaint','failed'}` so an already-
  /// terminal row is never overwritten — the dispatcher's `'failed'`
  /// state wins over a later inbound `bounce`, and the first
  /// terminal event wins over any later terminal event.
  Future<EmailOutboxTerminalFlipResult?> _flipOutboxStatusForTerminalEvent(
    PostgresExecutor exec,
    SendGridEvent event,
  ) async {
    final terminalStatus = _terminalOutboxStatusFor(event.eventKind);
    final providerMessageId = event.providerMessageId?.trim();
    if (terminalStatus == null) {
      // Non-terminal kind — leave the outbox status untouched.
      return null;
    }
    if (providerMessageId == null || providerMessageId.isEmpty) {
      // No FK to resolve; the audit row still landed but no flip is
      // possible. SendGrid will occasionally emit unsolicited events
      // (e.g. from older un-tracked sends); the receiver tolerates
      // this by leaving `email_id` NULL and skipping the flip here.
      return null;
    }
    // Pull the current status under the same transaction so we can
    // disambiguate `outbox_not_found` from `already_terminal`. Two
    // round-trips are acceptable here — the UPDATE alone could not
    // tell us which of the three branches applied (returning no
    // RETURNING rows is ambiguous between "no row" and "row but
    // guarded"). The SELECT runs first; the UPDATE only fires when
    // the row exists AND its current status is non-terminal.
    final existing = await exec.query(
      'select status::text as status '
      'from public.email_outbox '
      'where provider_message_id = @provider_message_id '
      'limit 1',
      parameters: <String, Object?>{
        'provider_message_id': providerMessageId,
      },
    );
    if (existing.isEmpty) {
      return EmailOutboxTerminalFlipResult.outboxNotFound;
    }
    final currentStatus = existing.single['status'];
    if (currentStatus is String &&
        kEmailOutboxTerminalStatuses.contains(currentStatus)) {
      return EmailOutboxTerminalFlipResult.alreadyTerminal;
    }
    await exec.query(
      'update public.email_outbox '
      'set status = @status, '
      '    updated_at = now() '
      'where provider_message_id = @provider_message_id '
      '  and status not in (@terminal_bounced, @terminal_complaint, @terminal_failed) '
      'returning email_id::text as email_id',
      parameters: <String, Object?>{
        'status': terminalStatus,
        'provider_message_id': providerMessageId,
        'terminal_bounced': 'bounced',
        'terminal_complaint': 'complaint',
        'terminal_failed': 'failed',
      },
    );
    return EmailOutboxTerminalFlipResult.flipped;
  }

  /// Maps a normalised SendGrid event kind (the parser's output;
  /// see `kSendGridEventKinds` in `sendgrid_event_payload.dart`) to
  /// the `email_outbox.status` value the flip should write, or null
  /// when the kind is non-terminal.
  ///
  /// The mapping is intentionally narrow:
  ///   * `bounced` → `'bounced'`
  ///   * `complaint` → `'complaint'`
  ///   * everything else → null (no flip)
  ///
  /// SendGrid's wire `spamreport` is treated as `'complaint'` in
  /// future-parser work (`kSendGridEventKinds` does not yet include
  /// it; the parser collapses unknown kinds to `'unknown'`), so it
  /// reaches this helper as `'unknown'` and stays a no-op until the
  /// parser is widened. That widening is out of scope for this
  /// follow-up — the flip behaviour for parsed `complaint` events is
  /// the contract this slice owns.
  String? _terminalOutboxStatusFor(String eventKind) {
    switch (eventKind) {
      case 'bounced':
        return 'bounced';
      case 'complaint':
        return 'complaint';
      default:
        return null;
    }
  }

  /// Q-2a email soak harness read seam.
  ///
  /// Returns the subset of `email_event` rows whose `provider_message_id`
  /// matches [providerMessageId] AND that arrived at or after [since]
  /// (when [since] is non-null). [kindFilter] further narrows to a
  /// specific SendGrid event kind (e.g. `'delivered'`); pass `null` to
  /// return every kind. Results are ordered by `received_at ASC` so the
  /// harness sees the earliest event first (the relevant signal for an
  /// end-to-end latency budget).
  ///
  /// Runs under `withSystem` because the inbound `email_event` rows
  /// have no operator scope until the FK to `email_outbox.email_id` is
  /// resolved (the harness driver writes through the admin test send
  /// surface, which uses a system-side dispatch path). Audit reason is
  /// `kFindByMessageIdReason` so log search can isolate probe-driven
  /// reads from inbound webhook processing.
  ///
  /// LIMIT defaults to 25 so a misbehaving probe cannot scan the whole
  /// table; SendGrid typically emits at most 5-6 events per send (one
  /// per lifecycle stage), so the cap is comfortable for the soak
  /// harness's per-path verification.
  Future<List<EmailEventSummary>> findEventsByProviderMessageId({
    required String providerMessageId,
    DateTime? since,
    String? kindFilter,
    int limit = 25,
  }) {
    return withSystem<List<EmailEventSummary>>(
      (exec) async {
        final clauses = <String>[
          'provider_message_id = @provider_message_id',
        ];
        final params = <String, Object?>{
          'provider_message_id': providerMessageId,
          'limit': limit.clamp(1, 200),
        };
        if (since != null) {
          clauses.add('received_at >= @since::timestamptz');
          params['since'] = since.toUtc().toIso8601String();
        }
        if (kindFilter != null && kindFilter.isNotEmpty) {
          clauses.add('event_kind = @kind');
          params['kind'] = kindFilter;
        }
        final where = clauses.join(' AND ');
        final rows = await exec.query(
          'select '
          '  event_id::text as event_id, '
          '  event_kind, '
          '  occurred_at, '
          '  received_at, '
          '  provider_event_id, '
          '  provider_message_id '
          'from public.email_event '
          'where $where '
          'order by received_at asc '
          'limit @limit',
          parameters: params,
        );
        return rows
            .map<EmailEventSummary>(
              (row) => EmailEventSummary(
                eventId: row['event_id'] as String,
                eventKind: row['event_kind'] as String,
                occurredAt: _readUtcTimestamp(row['occurred_at']),
                receivedAt: _readUtcTimestamp(row['received_at']),
                providerEventId: row['provider_event_id'] as String?,
                providerMessageId: row['provider_message_id'] as String?,
              ),
            )
            .toList(growable: false);
      },
      reason: kFindByMessageIdReason,
    );
  }
}

/// Normalize a Postgres timestamp column to UTC `DateTime`. The
/// `package:postgres` binding may return either a `DateTime` or a
/// `String` depending on column type + codec; the helper accepts both
/// shapes so a future codec swap does not silently break the probe.
DateTime _readUtcTimestamp(Object? raw) {
  if (raw is DateTime) return raw.toUtc();
  if (raw is String) return DateTime.parse(raw).toUtc();
  throw StateError(
    'email_event timestamp column returned unexpected type: '
    '${raw.runtimeType}',
  );
}
