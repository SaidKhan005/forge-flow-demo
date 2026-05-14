// Forge & Flow advisor proxy — Postgres production bindings for
// [NotificationEventFanout].
//
// Wave 2 EN-3-FU: the four seam types the fanout takes
// (`NotificationOperatorUserDirectory`,
//  `NotificationPreferenceReadSeam`,
//  `NotificationPushDispatchSeam`,
//  `NotificationEmailDispatchSeam`) all had production-binding gaps
// before this file landed. EN-3 (PR #729) shipped the
// `notif_event_telemetry_hook.dart` mitigation that only emitted a
// structured warning. This file replaces the gap with real Postgres
// adapters built on top of primitives that already exist on master:
//
//   * `public.users` + `public.user_roles` + `public.roles` —
//     enumerate operator-scoped recipients with role keys.
//   * `public.notification_preferences` — per-user per-event toggle
//     state. The existing
//     `NotificationPreferencesRepository.listForUser` is per-user;
//     this file adds the cross-user `listForOperatorEvent` query the
//     fanout needs.
//   * `public.mobile_push_outbox` + the existing
//     `MobilePushOutboxRepository.enqueue` — push + inbox channel.
//     Per-(app_variant, app_environment) rows are enqueued by reading
//     the user's distinct device-registration pairs from
//     `public.mobile_push_tokens`. A user with no live token gets no
//     push row (fanout skips the push channel for that user).
//   * `public.email_outbox` — SELECT-then-INSERT dedupe on
//     `(operator_id, template_id, template_data->>'idempotency_key')`
//     mirrors the pattern in
//     `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart`
//     (the canonical existing idempotent email enqueue path).
//
// Operator-leading index posture: every cross-user enumeration runs
// through `TenantTransactionWrapper.runAsSystem` (cross-tenant by
// definition: a fanout call walks every user in the operator). The
// audit reason marker carries the per-event reason so log search can
// correlate the bypass with the trigger.
//
// HP #2 demo parity: an in-memory mirror of every seam lives in
// `in_memory_notification_fanout_bindings.dart` so the demo writer
// path can dispatch through the same fanout class without touching
// Postgres.

import 'dart:convert';

import 'package:forge_and_flow/domain/models/notification_preference.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/observability/log.dart';

import 'notification_event_fanout.dart';

/// Stable reason strings the per-seam `runAsSystem` calls pass through
/// so the `app.bypass_rls_audit` GUC names the trigger. Kept here (not
/// inline) so log search across deploys is consistent.
abstract class NotificationFanoutAuditReasons {
  static const String listOperatorUsers =
      'notification_event_fanout.list_operator_users';
  static const String listPreferencesForOperatorEvent =
      'notification_event_fanout.list_preferences_for_event';
  static const String resolveUserDevicePairs =
      'notification_event_fanout.resolve_user_device_pairs';
  static const String enqueueEmail = 'notification_event_fanout.enqueue_email';
}

/// Default `app_variant` the push seam falls back to when a user has
/// no live `mobile_push_tokens` row. Mirrors the canonical variant
/// the operator-web `mobile_push_notifications.dart` register path
/// expects (lower-case identifier, ASCII).
const String kFanoutDefaultAppVariant = 'forgeflow';

/// Default `app_environment` the push seam falls back to when a user
/// has no live `mobile_push_tokens` row. The FCM tick worker reads
/// the per-device `mobile_push_tokens` row at dispatch time to choose
/// the matching APNs/FCM credentials, so the outbox column is only a
/// per-row dedupe seed when no device exists yet.
const String kFanoutDefaultAppEnvironment = 'production';

/// Returns a [NotificationOperatorUserDirectory] backed by Postgres.
///
/// The closure runs through [TenantTransactionWrapper.runAsSystem]
/// because a single fanout invocation walks every user the operator
/// owns; the per-user RLS policy on `users` would otherwise force
/// one round-trip per user. Audit reason
/// `notification_event_fanout.list_operator_users` records the bypass.
///
/// Query shape:
///
///     SELECT u.user_id, u.email, u.display_name,
///            u.primary_location_id,
///            coalesce(array_agg(r.role_key) FILTER (
///              WHERE r.role_key IS NOT NULL), '{}') AS role_keys
///       FROM public.users u
///       LEFT JOIN public.user_roles ur
///              ON ur.user_id = u.user_id
///             AND ur.operator_id = @operator_id::uuid
///             AND ur.revoked_at IS NULL
///             AND ur.valid_from <= now()
///             AND (ur.valid_until IS NULL OR ur.valid_until > now())
///       LEFT JOIN public.roles r ON r.role_id = ur.role_id
///      WHERE EXISTS (
///              SELECT 1 FROM public.user_roles urs
///               WHERE urs.user_id = u.user_id
///                 AND urs.operator_id = @operator_id::uuid
///                 AND urs.revoked_at IS NULL
///            )
///        AND u.status IN ('active', 'invited')
///        AND u.deleted_at IS NULL
///   GROUP BY u.user_id;
///
/// `status IN ('active','invited')` keeps newly-invited users in
/// scope so the very first backfill-complete email reaches the
/// invitee. `deleted_at IS NULL` excludes soft-deleted users.
NotificationOperatorUserDirectory postgresNotificationOperatorUserDirectory({
  required TenantTransactionWrapper adminWrapper,
}) {
  return ({required String operatorId}) async {
    return adminWrapper.runAsSystem<List<FanoutUser>>(
      (exec) async {
        final rows = await exec.query(
          'select u.user_id::text as user_id, '
          '       u.email, '
          '       u.display_name, '
          '       u.primary_location_id::text as primary_location_id, '
          "       coalesce("
          '         array_agg(r.role_key) filter (where r.role_key is not null), '
          "         '{}'::text[]"
          '       ) as role_keys '
          '  from public.users u '
          '  left join public.user_roles ur '
          '         on ur.user_id = u.user_id '
          '        and ur.operator_id = @operator_id::uuid '
          '        and ur.revoked_at is null '
          '        and ur.valid_from <= now() '
          '        and (ur.valid_until is null or ur.valid_until > now()) '
          '  left join public.roles r on r.role_id = ur.role_id '
          ' where exists ('
          '         select 1 from public.user_roles urs '
          '          where urs.user_id = u.user_id '
          '            and urs.operator_id = @operator_id::uuid '
          '            and urs.revoked_at is null '
          '       ) '
          "   and u.status in ('active', 'invited') "
          '   and u.deleted_at is null '
          ' group by u.user_id, u.email, u.display_name, u.primary_location_id',
          parameters: <String, Object?>{'operator_id': operatorId},
        );
        return <FanoutUser>[
          for (final row in rows)
            FanoutUser(
              userId: row['user_id']! as String,
              locationId: (row['primary_location_id'] as String?) ?? '',
              email: row['email'] as String?,
              displayName: row['display_name'] as String?,
              roles: _decodeRoleKeys(row['role_keys']),
            ),
        ];
      },
      reason: NotificationFanoutAuditReasons.listOperatorUsers,
    );
  };
}

/// Postgres-backed [NotificationPreferenceReadSeam].
///
/// Production query (one operator + event at a time so the
/// `notification_preferences_operator_event_idx` operator-leading
/// composite stays engaged):
///
///     SELECT user_id, channel, scope_kind, scope_id, enabled
///       FROM public.notification_preferences
///      WHERE operator_id = @operator_id::uuid
///        AND event_key   = @event_key;
///
/// Runs through `runAsSystem` because the fanout walks every user;
/// per-user RLS would force one round-trip per user. Audit reason
/// `notification_event_fanout.list_preferences_for_event` records
/// the bypass.
class PostgresNotificationPreferenceReadSeam
    implements NotificationPreferenceReadSeam {
  PostgresNotificationPreferenceReadSeam({
    required TenantTransactionWrapper adminWrapper,
  }) : _adminWrapper = adminWrapper;

  final TenantTransactionWrapper _adminWrapper;

  @override
  Future<List<NotificationPreferenceRow>> listForOperatorEvent({
    required String operatorId,
    required String eventKey,
  }) {
    return _adminWrapper.runAsSystem<List<NotificationPreferenceRow>>(
      (exec) async {
        final rows = await exec.query(
          'select user_id::text as user_id, '
          '       channel, '
          '       scope_kind, '
          '       scope_id::text as scope_id, '
          '       enabled '
          '  from public.notification_preferences '
          ' where operator_id = @operator_id::uuid '
          '   and event_key   = @event_key '
          ' order by user_id, channel, scope_kind',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'event_key': eventKey,
          },
        );
        return <NotificationPreferenceRow>[
          for (final row in rows)
            NotificationPreferenceRow(
              userId: row['user_id']! as String,
              channel: NotificationChannelWire.fromWire(
                row['channel']! as String,
              ),
              scopeKind: NotificationScopeKindWire.fromWire(
                row['scope_kind']! as String,
              ),
              scopeId: row['scope_id'] is String &&
                      (row['scope_id'] as String).isNotEmpty
                  ? row['scope_id'] as String
                  : null,
              enabled: row['enabled']! as bool,
            ),
        ];
      },
      reason: NotificationFanoutAuditReasons.listPreferencesForOperatorEvent,
    );
  }
}

/// Returns a [NotificationPushDispatchSeam] backed by
/// [MobilePushOutboxRepository.enqueue].
///
/// For each user, the seam first reads the distinct
/// `(app_variant, app_environment)` pairs the user has live tokens
/// for in `public.mobile_push_tokens`. One outbox row is enqueued per
/// pair so an iOS+Android user gets one row per platform. When the
/// user has no live tokens, the seam falls back to one row at
/// `(kFanoutDefaultAppVariant, kFanoutDefaultAppEnvironment)` so the
/// outbox carries the message until a token registers; the FCM tick
/// worker tolerates unknown variants by no-oping the dispatch and
/// retrying once tokens land.
///
/// The dedupe key from the fanout is suffixed with `:<variant>:<env>`
/// per row so two-device users get two distinct outbox rows that
/// each collapse on retry via the existing
/// `mobile_push_outbox_dedupe_unq` `(operator_id, dedupe_key)` UNIQUE.
NotificationPushDispatchSeam postgresNotificationPushDispatchSeam({
  required TenantTransactionWrapper adminWrapper,
  required MobilePushOutboxRepository pushOutboxRepository,
  bool routesToInbox = false,
}) {
  return (FanoutPushPayload payload) async {
    final pairs = await _resolveUserAppPairs(
      adminWrapper: adminWrapper,
      operatorId: payload.operatorId,
      userId: payload.userId,
    );
    final effectivePairs = pairs.isNotEmpty
        ? pairs
        : const <_AppPair>[
            _AppPair(
              appVariant: kFanoutDefaultAppVariant,
              appEnvironment: kFanoutDefaultAppEnvironment,
            ),
          ];
    for (final pair in effectivePairs) {
      // Suffix the dedupe key with the variant + environment so a
      // user with two device platforms gets two distinct outbox rows
      // and the UNIQUE collapses retries per (user, variant, env).
      final perPairDedupeKey =
          '${payload.dedupeKey}:${pair.appVariant}:${pair.appEnvironment}';
      await pushOutboxRepository.enqueue(
        MobilePushOutboxEnqueue(
          operatorId: payload.operatorId,
          locationId: payload.locationId,
          userId: payload.userId,
          dedupeKey: perPairDedupeKey,
          appVariant: pair.appVariant,
          appEnvironment: pair.appEnvironment,
          title: payload.title,
          body: payload.body,
          data: <String, Object?>{
            ...payload.data,
            'routes_to_inbox': routesToInbox || payload.routesToInbox,
          },
          deeplink: payload.deeplink,
        ),
      );
    }
  };
}

/// Returns a [NotificationEmailDispatchSeam] backed by direct
/// `email_outbox` INSERT through the admin wrapper.
///
/// Idempotency: the fanout's
/// `<eventPrefix>:<userId>:email` dedupe key is written into
/// `template_data->>'idempotency_key'`. The seam runs a
/// SELECT-then-INSERT collapse inside one transaction; the existing
/// dispatcher (`PostgresEmailOutboxRepository.claimPending`) does
/// not need a UNIQUE index because every producer that enqueues an
/// `email_outbox` row uses the same idempotency-key text pattern
/// (matches the
/// `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart`
/// canonical enqueue path).
NotificationEmailDispatchSeam postgresNotificationEmailDispatchSeam({
  required TenantTransactionWrapper adminWrapper,
}) {
  return (FanoutEmailPayload payload) async {
    await adminWrapper.runAsSystem<void>(
      (exec) async {
        final existingRows = await exec.query(
          'select email_id::text as email_id '
          '  from public.email_outbox '
          ' where operator_id = @operator_id::uuid '
          '   and template_id = @template_id '
          "   and template_data ->> 'idempotency_key' = @idempotency_key "
          ' limit 1',
          parameters: <String, Object?>{
            'operator_id': payload.operatorId,
            'template_id': payload.templateId,
            'idempotency_key': payload.idempotencyKey,
          },
        );
        if (existingRows.isNotEmpty) {
          // Duplicate collapsed; the prior tick already enqueued an
          // email with the same idempotency key. Treated as a no-op
          // by the fanout (the outcome tally still counts the
          // dispatch as completed because the row exists).
          return;
        }
        await exec.execute(
          'insert into public.email_outbox ('
          '  operator_id, user_id, recipient_email, recipient_display_name, '
          '  template_id, template_data, scheduled_for, status, attempt_count'
          ') values ('
          '  @operator_id::uuid, @user_id::uuid, @recipient_email, '
          '  @recipient_display_name, @template_id, @template_data::jsonb, '
          "  now(), 'pending', 0"
          ')',
          parameters: <String, Object?>{
            'operator_id': payload.operatorId,
            'user_id': payload.userId,
            'recipient_email': payload.recipientEmail,
            'recipient_display_name': payload.recipientDisplayName,
            'template_id': payload.templateId,
            'template_data': jsonEncode(<String, Object?>{
              ...payload.templateData,
              'idempotency_key': payload.idempotencyKey,
            }),
          },
        );
      },
      reason: NotificationFanoutAuditReasons.enqueueEmail,
    );
  };
}

/// Bundles every seam the fanout needs into a single helper. Returns
/// a fully-constructed [NotificationEventFanout] using the four
/// Postgres adapters defined in this file.
///
/// The push and inbox seams share the same
/// [MobilePushOutboxRepository] instance; the inbox seam flips
/// `routes_to_inbox=true` on the payload so the mobile-side FCM
/// handler routes into `app_notifications` rather than firing a
/// system push (see [NotificationEventFanout] doc comment).
NotificationEventFanout buildPostgresNotificationEventFanout({
  required TenantTransactionWrapper adminWrapper,
  required MobilePushOutboxRepository pushOutboxRepository,
}) {
  return NotificationEventFanout(
    preferenceReadSeam: PostgresNotificationPreferenceReadSeam(
      adminWrapper: adminWrapper,
    ),
    userDirectory: postgresNotificationOperatorUserDirectory(
      adminWrapper: adminWrapper,
    ),
    pushDispatch: postgresNotificationPushDispatchSeam(
      adminWrapper: adminWrapper,
      pushOutboxRepository: pushOutboxRepository,
    ),
    inboxDispatch: postgresNotificationPushDispatchSeam(
      adminWrapper: adminWrapper,
      pushOutboxRepository: pushOutboxRepository,
      routesToInbox: true,
    ),
    emailDispatch: postgresNotificationEmailDispatchSeam(
      adminWrapper: adminWrapper,
    ),
  );
}

class _AppPair {
  const _AppPair({required this.appVariant, required this.appEnvironment});
  final String appVariant;
  final String appEnvironment;
}

Future<List<_AppPair>> _resolveUserAppPairs({
  required TenantTransactionWrapper adminWrapper,
  required String operatorId,
  required String userId,
}) {
  return adminWrapper.runAsSystem<List<_AppPair>>(
    (exec) async {
      try {
        final rows = await exec.query(
          'select distinct app_variant, app_environment '
          '  from public.mobile_push_tokens '
          ' where operator_id = @operator_id::uuid '
          '   and user_id = @user_id::uuid '
          '   and revoked_at is null '
          ' order by app_variant, app_environment',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'user_id': userId,
          },
        );
        return <_AppPair>[
          for (final row in rows)
            _AppPair(
              appVariant: row['app_variant']! as String,
              appEnvironment: row['app_environment']! as String,
            ),
        ];
      } catch (error, stack) {
        // Token table read should never block the push enqueue; the
        // fanout falls back to the default pair below so the outbox
        // row is at least created. The structured log line surfaces
        // any unexpected table-shape mismatch in Cloud Logging.
        log(
          LogSeverity.warning,
          'notification.fanout.push_token_lookup_failed',
          fields: <String, Object?>{
            'operator_id': operatorId,
            'user_id': userId,
            'error.runtimeType': error.runtimeType.toString(),
            'error_message': error.toString(),
            'stack_first_frame': firstStackFrame(stack),
          },
        );
        return const <_AppPair>[];
      }
    },
    reason: NotificationFanoutAuditReasons.resolveUserDevicePairs,
  );
}

Set<String> _decodeRoleKeys(Object? raw) {
  if (raw == null) return const <String>{};
  if (raw is List) {
    return <String>{
      for (final entry in raw)
        if (entry is String && entry.isNotEmpty) entry,
    };
  }
  if (raw is String) {
    // pg array literal fallback: '{role_a,role_b}'.
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == '{}') return const <String>{};
    final stripped = trimmed.startsWith('{') && trimmed.endsWith('}')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
    if (stripped.isEmpty) return const <String>{};
    return <String>{
      for (final part in stripped.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    };
  }
  return const <String>{};
}
