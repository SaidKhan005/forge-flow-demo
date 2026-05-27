// Forge & Flow advisor proxy - NotificationEventFanout.
//
// Phase 8 W2.B fanout worker. Generic multi-channel notification
// dispatcher that reads `notification_preferences` and routes each
// catalog event to the matching set of (push / email / inbox)
// channels for every user in the operator who satisfies the event's
// role gate.
//
// The fanout is the runtime half of the Phase 8 W2.B notification
// surface: the operator-web Settings -> Notifications screen lets
// operators toggle preferences (PR #310 shipped that), and this
// class is the worker that honours those toggles when an event
// fires. The catalog is the durable contract: every event_key plus
// its default channels and role gate live in
// `lib/domain/models/notification_event_catalog.dart`.
//
// Resolution order for a given (user, event_key, channel):
//
//   1. `notification_preferences` row with matching scope (location
//      first, then operator) -- explicit opt-in / opt-out wins.
//   2. Catalog `defaultChannels` -- "out of the box" channels.
//   3. Otherwise the channel is skipped for this user.
//
// Role gating: the event catalog declares a [NotificationRoleGate]
// (`any` / `adminOnly` / `managerOnly`). Users whose roles do not
// satisfy the gate are excluded from the fanout entirely (no push,
// no email, no inbox). The `notification_preferences` UI itself
// hides ungated events; the fanout enforces the same boundary in
// case a stale preference row predates a role change.
//
// Idempotency: each `fanOut` invocation provides a stable
// `dedupeKeyPrefix` (per-event semantics; e.g. the connector
// backfill job id, the audit chain date, the vendor id). The
// fanout composes a per-channel dedupe key as
// `<prefix>:<userId>:<channel>` and forwards it to the channel
// dispatch seam:
//
//   * Push -- `mobile_push_outbox` already has a UNIQUE
//     `(operator_id, dedupe_key)` index so a retried fanout call
//     for the same event collapses to the same row.
//   * Email -- the seam wraps a per-row `idempotency_key` write so
//     the existing `email_outbox` UNIQUE on
//     `(operator_id, idempotency_key)` (when present) collapses
//     duplicates. Otherwise the seam falls back to "skip if a row
//     already exists with that key" via a follow-up table noted
//     below.
//   * Inbox -- mirrors the push path so the mobile FCM handler
//     routes the message into the existing `app_notifications`
//     inbox; same `mobile_push_outbox` UNIQUE handles dedupe.
//
// Forge & Flow CLAUDE.md compliance:
//   * No raw `package:postgres` import here -- repository seams
//     keep this file SQLite-and-Postgres-agnostic.
//   * Every seam is operator-scoped on the way in. The fanout walks
//     one operator at a time so the operator-leading index pattern
//     stays engaged.
//   * Operator-facing copy lives in the per-channel templates; this
//     class only builds `Map<String, Object?>` payloads and dispatches.
//   * The class never invokes `firebase_mobile_push_runtime.dart` or
//     `mobile_push_notification_service.dart` directly; it writes to
//     the existing `mobile_push_outbox` (via the push dispatch seam)
//     and the FCM tick worker drains it.

import 'package:forge_and_flow/domain/models/notification_event_catalog.dart';
import 'package:forge_and_flow/domain/models/notification_preference.dart';
import 'package:forge_and_flow/services/observability/log.dart';

/// Roles a user holds within an operator. Mirrors the strings used
/// in `notification_event_catalog.dart`'s [roleSatisfiesGate].
class FanoutUser {
  const FanoutUser({
    required this.userId,
    required this.locationId,
    required this.roles,
    this.email,
    this.displayName,
  });

  /// `public.users.user_id` for the recipient.
  final String userId;

  /// Location associated with this user's session. Single value to
  /// keep the seam aligned with [TenantContext]; production resolves
  /// to the user's primary or active location.
  final String locationId;

  /// User's v2 role keys (e.g. `operator_owner`,
  /// `operator_general_manager`, `location_manager`, `supervisor`).
  /// Retired v1 keys such as `operator_admin` and `operator_manager`
  /// do not satisfy notification gates.
  final Set<String> roles;

  /// Optional email address for the email channel. When absent the
  /// email channel is skipped for this user even when preferences
  /// or defaults would have admitted it.
  final String? email;

  /// Optional display name for the salutation.
  final String? displayName;
}

/// Reads the directory of users in an operator. Production binds
/// this to a Postgres query joining `users` + `user_roles` filtered
/// to active grants for the operator; tests pin a fixed list.
typedef NotificationOperatorUserDirectory =
    Future<List<FanoutUser>> Function({required String operatorId});

/// Reads `notification_preferences` rows for an operator + event.
/// Returns every row regardless of `enabled`; the fanout applies
/// the resolution algorithm itself so callers don't need to repeat
/// the catalog-default fallback.
abstract class NotificationPreferenceReadSeam {
  /// Lists every `notification_preferences` row for
  /// `(operatorId, eventKey)`. Production query (one operator at a
  /// time, operator-leading index stays engaged):
  ///
  ///     SELECT user_id, channel, scope_kind, scope_id, enabled
  ///       FROM public.notification_preferences
  ///      WHERE operator_id = @operator_id::uuid
  ///        AND event_key   = @event_key
  ///      ORDER BY user_id, channel, scope_kind;
  Future<List<NotificationPreferenceRow>> listForOperatorEvent({
    required String operatorId,
    required String eventKey,
  });
}

/// Narrow projection of `notification_preferences` carrying only
/// the columns the fanout needs to apply the resolution algorithm.
class NotificationPreferenceRow {
  const NotificationPreferenceRow({
    required this.userId,
    required this.channel,
    required this.scopeKind,
    required this.scopeId,
    required this.enabled,
  });

  final String userId;
  final NotificationChannel channel;
  final NotificationScopeKind scopeKind;
  final String? scopeId;
  final bool enabled;
}

/// One push (or push-routed inbox) row to enqueue. The fanout fills
/// every field; the seam only persists.
class FanoutPushPayload {
  const FanoutPushPayload({
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.dedupeKey,
    required this.title,
    required this.body,
    required this.data,
    required this.routesToInbox,
    this.deeplink,
  });

  final String operatorId;
  final String locationId;
  final String userId;
  final String dedupeKey;
  final String title;
  final String body;

  /// Free-form data block forwarded to FCM. Mobile-side handlers
  /// branch on `data['inbox']` to decide whether to write the
  /// message into the persistent `app_notifications` inbox.
  final Map<String, Object?> data;

  /// True when this payload is the inbox-routed copy (channel ==
  /// `inbox`). The fanout sets this so the seam can stamp a distinct
  /// `dedupe_key` from the push channel (so an event subscribed to
  /// both `push` and `inbox` produces two rows, not one).
  final bool routesToInbox;
  final String? deeplink;
}

/// One email row to enqueue. Mirrors the existing
/// `vendor_lifecycle_notification_dispatcher.dart` shape so the V1.E
/// dispatcher can keep delegating into the same seam without
/// rebinding tests.
class FanoutEmailPayload {
  const FanoutEmailPayload({
    required this.operatorId,
    required this.userId,
    required this.idempotencyKey,
    required this.recipientEmail,
    required this.recipientDisplayName,
    required this.templateId,
    required this.templateData,
  });

  final String operatorId;
  final String userId;
  final String idempotencyKey;
  final String recipientEmail;
  final String? recipientDisplayName;
  final String templateId;
  final Map<String, String> templateData;
}

/// Push dispatch seam. Production binds this to
/// `MobilePushOutboxRepository.enqueue` (which has the
/// `(operator_id, dedupe_key)` UNIQUE so the fanout stays
/// idempotent on retry). Tests pass an in-memory fake.
typedef NotificationPushDispatchSeam =
    Future<void> Function(FanoutPushPayload payload);

/// Email dispatch seam. Production binds this to a Postgres INSERT
/// against `email_outbox`. Tests pass an in-memory fake.
typedef NotificationEmailDispatchSeam =
    Future<void> Function(FanoutEmailPayload payload);

/// Structured-log emitter seam for the fanout's per-channel failure
/// path. Production binds this to the proxy's [log] function so
/// failures land as one JSON envelope per stdout line in Cloud
/// Logging; tests pass a recording closure that captures every
/// call without touching stdout.
///
/// The signature mirrors [log] exactly so the production binding is
/// the one-liner `(severity, event, {fields}) => log(severity, event,
/// fields: fields)`. The seam exists (rather than calling [log]
/// directly) so the B3 hot-fix test plan can assert the swallow site
/// fires a structured log line on every email-side dispatch failure.
typedef NotificationFanoutLogSeam =
    void Function(
      LogSeverity severity,
      String event, {
      Map<String, Object?> fields,
    });

/// Default [NotificationFanoutLogSeam] - emits via the proxy's
/// structured [log] function. Production callers may omit the seam
/// in the constructor and inherit this binding; tests inject a
/// recording closure.
void defaultNotificationFanoutLogSeam(
  LogSeverity severity,
  String event, {
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  log(severity, event, fields: fields);
}

/// Per-event payload contributed by the trigger site. Carries the
/// `templateData` map for email rendering plus the `title` / `body`
/// strings used by push and inbox.
class NotificationEventEnvelope {
  const NotificationEventEnvelope({
    required this.eventKey,
    required this.dedupeKeyPrefix,
    required this.pushTitle,
    required this.pushBody,
    required this.emailTemplateId,
    required this.emailTemplateData,
    this.deeplink,
    this.pushData = const <String, Object?>{},
    this.suppressedChannels = const <NotificationChannel>{},
  });

  /// Catalog event_key (e.g. `notif.backfill.complete`).
  final String eventKey;

  /// Stable per-event prefix used to compose the per-(user, channel)
  /// dedupe key. The fanout appends `:<userId>:<channel>` so retries
  /// collapse on the channel-side UNIQUE indexes.
  final String dedupeKeyPrefix;

  /// Push notification title (operator-facing copy; no jargon).
  final String pushTitle;

  /// Push notification body (operator-facing copy; no jargon).
  final String pushBody;

  /// Email template id from `EmailTemplateIds`. The seam binds the
  /// id to the on-disk Markdown template at render time.
  final String emailTemplateId;

  /// Per-event template variables. The fanout extends this map with
  /// the recipient's salutation when it dispatches the row.
  final Map<String, String> emailTemplateData;

  /// Optional deeplink mobile clients open when tapping the push.
  final String? deeplink;

  /// Free-form data block surfaced on the push payload. Mobile-side
  /// handlers branch on these keys (e.g. `data['inbox'] = 'true'`
  /// for the inbox-routed copy).
  final Map<String, Object?> pushData;

  /// Channels this trigger intentionally owns somewhere else. The
  /// vendor availability trigger uses this to keep the legacy
  /// "Notify me" pending-row table as the only email source while
  /// still letting the generic fanout handle push/inbox delivery.
  final Set<NotificationChannel> suppressedChannels;
}

/// Outcome shape returned by [NotificationEventFanout.fanOut]. The
/// trigger sites use this for their structured log lines so the
/// fanout's per-event work is auditable in Cloud Run logs without
/// re-querying the channel tables.
class NotificationFanoutOutcome {
  const NotificationFanoutOutcome({
    required this.eventKey,
    required this.usersConsidered,
    required this.usersGated,
    required this.pushDispatched,
    required this.emailDispatched,
    required this.inboxDispatched,
    required this.skipped,
  });

  final String eventKey;

  /// Users in the operator directory the fanout walked.
  final int usersConsidered;

  /// Users excluded by the catalog role gate.
  final int usersGated;

  final int pushDispatched;
  final int emailDispatched;
  final int inboxDispatched;

  /// Per-(user, channel) tuples skipped because the seam threw.
  /// Skipped rows do not stamp any preferences; a retried call
  /// re-dispatches the missed channel.
  final int skipped;

  Map<String, Object?> toJson() => <String, Object?>{
    'event_key': eventKey,
    'users_considered': usersConsidered,
    'users_gated': usersGated,
    'push_dispatched': pushDispatched,
    'email_dispatched': emailDispatched,
    'inbox_dispatched': inboxDispatched,
    'skipped': skipped,
  };
}

/// Generic multi-channel notification fanout. Pure orchestrator;
/// every external dependency is dependency-injected so tests pass
/// fakes without touching disk or Postgres.
class NotificationEventFanout {
  NotificationEventFanout({
    required NotificationPreferenceReadSeam preferenceReadSeam,
    required NotificationOperatorUserDirectory userDirectory,
    required NotificationPushDispatchSeam pushDispatch,
    required NotificationEmailDispatchSeam emailDispatch,
    NotificationPushDispatchSeam? inboxDispatch,
    NotificationFanoutLogSeam logSeam = defaultNotificationFanoutLogSeam,
    List<NotificationCatalogEntry> catalog = kNotificationCatalog,
  }) : _preferenceReadSeam = preferenceReadSeam,
       _userDirectory = userDirectory,
       _pushDispatch = pushDispatch,
       _emailDispatch = emailDispatch,
       // Inbox dispatch reuses the push seam by default. Production
       // binds both to the same `MobilePushOutboxRepository.enqueue`;
       // the fanout sets `routesToInbox = true` on the inbox payload
       // so the mobile-side FCM handler can route into
       // `app_notifications` rather than firing a system push.
       _inboxDispatch = inboxDispatch ?? pushDispatch,
       _logSeam = logSeam,
       _catalogByKey = <String, NotificationCatalogEntry>{
         for (final entry in catalog) entry.eventKey: entry,
       };

  final NotificationPreferenceReadSeam _preferenceReadSeam;
  final NotificationOperatorUserDirectory _userDirectory;
  final NotificationPushDispatchSeam _pushDispatch;
  final NotificationEmailDispatchSeam _emailDispatch;
  final NotificationPushDispatchSeam _inboxDispatch;
  final NotificationFanoutLogSeam _logSeam;
  final Map<String, NotificationCatalogEntry> _catalogByKey;

  /// Catalog entry for [eventKey], or null when the event is not
  /// registered. Exposed for caller-side guards (e.g. trigger sites
  /// that want to short-circuit before building the envelope).
  NotificationCatalogEntry? catalogEntryFor(String eventKey) =>
      _catalogByKey[eventKey];

  /// Fan an event out to every (user, channel) tuple whose
  /// preference + catalog default matrix admits a delivery. Returns
  /// the per-channel tally for log lines.
  ///
  /// The fanout is operator-scoped: callers walk one operator at a
  /// time. The user directory seam returns the users in that
  /// operator (with their roles + locations), and the preference
  /// seam returns the operator's preference rows for the event.
  Future<NotificationFanoutOutcome> fanOut({
    required String operatorId,
    required NotificationEventEnvelope envelope,
  }) async {
    final entry = _catalogByKey[envelope.eventKey];
    if (entry == null) {
      // Unknown event_key. Skip silently rather than throwing so a
      // rolling deploy that introduces a new event without the
      // catalog catches up cleanly. B3 hot-fix: surface the skip
      // as a structured log line so a stale catalog deploy is at
      // least visible in Cloud Logging.
      _logSeam(
        LogSeverity.warning,
        'notification.fanout.unknown_event_key',
        fields: <String, Object?>{
          'event_kind': envelope.eventKey,
          'template_id': envelope.emailTemplateId,
          'operator_id': operatorId,
        },
      );
      return NotificationFanoutOutcome(
        eventKey: envelope.eventKey,
        usersConsidered: 0,
        usersGated: 0,
        pushDispatched: 0,
        emailDispatched: 0,
        inboxDispatched: 0,
        skipped: 0,
      );
    }

    final users = await _userDirectory(operatorId: operatorId);
    if (users.isEmpty) {
      return NotificationFanoutOutcome(
        eventKey: envelope.eventKey,
        usersConsidered: 0,
        usersGated: 0,
        pushDispatched: 0,
        emailDispatched: 0,
        inboxDispatched: 0,
        skipped: 0,
      );
    }

    final preferenceRows = await _preferenceReadSeam.listForOperatorEvent(
      operatorId: operatorId,
      eventKey: envelope.eventKey,
    );
    final preferencesByUser = _indexPreferencesByUser(preferenceRows);

    var pushDispatched = 0;
    var emailDispatched = 0;
    var inboxDispatched = 0;
    var skipped = 0;
    var gated = 0;

    for (final user in users) {
      if (!roleSatisfiesGate(entry.roleGate, user.roles)) {
        gated += 1;
        continue;
      }

      final userPrefs =
          preferencesByUser[user.userId] ?? const <_PrefKey, bool>{};
      final channels = _resolveEnabledChannelsForUser(
        catalog: entry,
        userPrefs: userPrefs,
        userLocationId: user.locationId,
      );

      for (final channel in channels) {
        if (envelope.suppressedChannels.contains(channel)) {
          continue;
        }
        try {
          switch (channel) {
            case NotificationChannel.push:
              await _dispatchPush(
                user: user,
                envelope: envelope,
                operatorId: operatorId,
                routesToInbox: false,
              );
              pushDispatched += 1;
            case NotificationChannel.email:
              if (user.email == null || user.email!.trim().isEmpty) {
                // Email channel admitted but the user has no email
                // on file -- skip without counting as a hard error.
                skipped += 1;
                continue;
              }
              await _dispatchEmail(
                user: user,
                envelope: envelope,
                operatorId: operatorId,
              );
              emailDispatched += 1;
            case NotificationChannel.inbox:
              await _dispatchInbox(
                user: user,
                envelope: envelope,
                operatorId: operatorId,
              );
              inboxDispatched += 1;
          }
        } catch (e, st) {
          // B3 hot-fix (see
          // `docs/archive/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`
          // Block B, B3 and `c_email_notification_scenario_inventory.md`
          // "Hook-only with missing templates"): the previous
          // `catch (_)` swallowed every per-channel dispatch error
          // silently, including the renderer's
          // `ArgumentError: Unknown templateId` thrown when the
          // email channel referenced a template id not in
          // `EmailTemplateIds.all`. Operators never received the
          // backfill / audit emails and the failure left no trace.
          //
          // Rebroadcast as a structured log line so future template
          // misses (or any other seam failure) surface in Cloud
          // Logging. We deliberately do NOT rethrow: push + inbox
          // still need to flow for users whose preferences admit
          // them, and the channel-side UNIQUE indexes mean a
          // retried fanout call collapses to the same row.
          skipped += 1;
          _logSeam(
            LogSeverity.error,
            channel == NotificationChannel.email
                ? 'notification.fanout.email_render_failed'
                : 'notification.fanout.channel_dispatch_failed',
            fields: <String, Object?>{
              'event_kind': envelope.eventKey,
              'template_id': envelope.emailTemplateId,
              'operator_id': operatorId,
              'user_id': user.userId,
              'channel': channel.wire,
              'error.runtimeType': e.runtimeType.toString(),
              'error_message': e.toString(),
              'stack_first_frame': firstStackFrame(st),
            },
          );
        }
      }
    }

    return NotificationFanoutOutcome(
      eventKey: envelope.eventKey,
      usersConsidered: users.length,
      usersGated: gated,
      pushDispatched: pushDispatched,
      emailDispatched: emailDispatched,
      inboxDispatched: inboxDispatched,
      skipped: skipped,
    );
  }

  Future<void> _dispatchPush({
    required FanoutUser user,
    required NotificationEventEnvelope envelope,
    required String operatorId,
    required bool routesToInbox,
  }) {
    final dedupeKey = _composeDedupeKey(
      prefix: envelope.dedupeKeyPrefix,
      userId: user.userId,
      channelWire: NotificationChannel.push.wire,
    );
    final payload = FanoutPushPayload(
      operatorId: operatorId,
      locationId: user.locationId,
      userId: user.userId,
      dedupeKey: dedupeKey,
      title: envelope.pushTitle,
      body: envelope.pushBody,
      data: <String, Object?>{
        ...envelope.pushData,
        'event_key': envelope.eventKey,
        'inbox': false,
      },
      routesToInbox: routesToInbox,
      deeplink: envelope.deeplink,
    );
    return _pushDispatch(payload);
  }

  Future<void> _dispatchInbox({
    required FanoutUser user,
    required NotificationEventEnvelope envelope,
    required String operatorId,
  }) {
    final dedupeKey = _composeDedupeKey(
      prefix: envelope.dedupeKeyPrefix,
      userId: user.userId,
      channelWire: NotificationChannel.inbox.wire,
    );
    final payload = FanoutPushPayload(
      operatorId: operatorId,
      locationId: user.locationId,
      userId: user.userId,
      dedupeKey: dedupeKey,
      title: envelope.pushTitle,
      body: envelope.pushBody,
      data: <String, Object?>{
        ...envelope.pushData,
        'event_key': envelope.eventKey,
        'inbox': true,
      },
      routesToInbox: true,
      deeplink: envelope.deeplink,
    );
    return _inboxDispatch(payload);
  }

  Future<void> _dispatchEmail({
    required FanoutUser user,
    required NotificationEventEnvelope envelope,
    required String operatorId,
  }) {
    final idempotencyKey = _composeDedupeKey(
      prefix: envelope.dedupeKeyPrefix,
      userId: user.userId,
      channelWire: NotificationChannel.email.wire,
    );
    final salutation = _resolveSalutation(user);
    final templateData = <String, String>{
      ...envelope.emailTemplateData,
      'recipientName': salutation,
    };
    final payload = FanoutEmailPayload(
      operatorId: operatorId,
      userId: user.userId,
      idempotencyKey: idempotencyKey,
      recipientEmail: user.email!,
      recipientDisplayName: user.displayName,
      templateId: envelope.emailTemplateId,
      templateData: templateData,
    );
    return _emailDispatch(payload);
  }

  /// Resolves the channels enabled for one user. Algorithm:
  ///
  ///   * Walk every channel in [kNotificationChannelOrder].
  ///   * Look for a `notification_preferences` row that matches the
  ///     channel. Location-scoped rows take priority over operator-
  ///     scoped rows (more specific scope wins). An explicit row
  ///     whose `enabled = false` opts the user out of the channel.
  ///   * When no row exists for the channel, fall back to the
  ///     catalog `defaultChannels` set.
  List<NotificationChannel> _resolveEnabledChannelsForUser({
    required NotificationCatalogEntry catalog,
    required Map<_PrefKey, bool> userPrefs,
    required String userLocationId,
  }) {
    final enabled = <NotificationChannel>[];
    for (final wire in kNotificationChannelOrder) {
      final channel = NotificationChannelWire.fromWire(wire);
      // Location-scoped row first.
      final locationKey = _PrefKey(
        channel: channel,
        scopeKind: NotificationScopeKind.location,
        scopeId: userLocationId,
      );
      // Then operator-scoped row (scope_id NULL).
      const operatorKey = _PrefKey(
        channel: null, // placeholder, replaced below
        scopeKind: NotificationScopeKind.operator,
        scopeId: null,
      );
      final operatorKeyForChannel = _PrefKey(
        channel: channel,
        scopeKind: NotificationScopeKind.operator,
        scopeId: null,
      );
      assert(operatorKey != operatorKeyForChannel);
      bool? explicit = userPrefs[locationKey];
      explicit ??= userPrefs[operatorKeyForChannel];
      if (explicit != null) {
        if (explicit) enabled.add(channel);
        continue;
      }
      // No explicit row - fall back to catalog default.
      if (catalog.defaultChannels.contains(wire)) {
        enabled.add(channel);
      }
    }
    return enabled;
  }

  /// Indexes preference rows by `(userId)` -> `(channel, scope, scopeId) -> enabled`.
  Map<String, Map<_PrefKey, bool>> _indexPreferencesByUser(
    List<NotificationPreferenceRow> rows,
  ) {
    final out = <String, Map<_PrefKey, bool>>{};
    for (final row in rows) {
      final byKey = out.putIfAbsent(row.userId, () => <_PrefKey, bool>{});
      byKey[_PrefKey(
            channel: row.channel,
            scopeKind: row.scopeKind,
            scopeId: row.scopeId,
          )] =
          row.enabled;
    }
    return out;
  }

  /// Composes the per-(prefix, user, channel) dedupe key the fanout
  /// passes through to the channel seams. The shape is stable so
  /// retries collapse on the channel-side UNIQUE indexes.
  static String _composeDedupeKey({
    required String prefix,
    required String userId,
    required String channelWire,
  }) {
    return '$prefix:$userId:$channelWire';
  }

  String _resolveSalutation(FanoutUser user) {
    final name = user.displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final email = user.email;
    if (email == null) return 'there';
    final atIndex = email.indexOf('@');
    final localPart = atIndex > 0 ? email.substring(0, atIndex) : email;
    if (localPart.isEmpty) return 'there';
    return localPart;
  }
}

/// Composite key for the per-user preference index. `channel` may be
/// null only as a placeholder during construction; real entries
/// always carry a channel.
class _PrefKey {
  const _PrefKey({
    required this.channel,
    required this.scopeKind,
    required this.scopeId,
  });

  final NotificationChannel? channel;
  final NotificationScopeKind scopeKind;
  final String? scopeId;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _PrefKey) return false;
    return channel == other.channel &&
        scopeKind == other.scopeKind &&
        scopeId == other.scopeId;
  }

  @override
  int get hashCode => Object.hash(channel, scopeKind, scopeId);
}

// ---------------------------------------------------------------
// Future hooks
//
// FOLLOW-UP: hook from open-shift staleness detector when shipped.
//   Event: notif.shift.stale
//   Trigger: live shift snapshot exceeds staleness threshold without
//   fresh covers/labor. Owning phase: 10b (open-shift live snapshot).
//
// FOLLOW-UP: hook from manager-override write path when shipped.
//   Event: notif.star.override
//   Trigger: an operator commits a manager override on a Star
//   recommendation. Owning phase: 11b advisor override surface.
//
// FOLLOW-UP: hook from weekly-plan locker when shipped.
//   Event: notif.plan.updated
//   Trigger: a new WeeklyPlanSnapshot row is locked in. Owning
//   phase: 7.55 weekly plan + 11W weekly planner.
//
// All three events are admitted by the catalog and the fanout
// resolution algorithm; their per-event envelopes are built at the
// trigger site so this fanout class needs no further changes when
// the hooks land.
