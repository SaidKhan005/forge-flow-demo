// Theme D — per-pod Cloud Pub/Sub subscriber + replay backlog.
//
// Cross-pod realtime replay (see `CODE_OPS_DEBT.md` Theme D, P0): a
// reconnect after a Cloud Run pod restart cannot read the in-process
// 256-entry ring buffer of the pod that originally received the event.
// Closing the gap requires a backlog query that lives outside any
// single pod's memory.
//
// Strategy (matches operator's "simplicity / functionality" constraint):
//   * Each pod creates its OWN subscription on startup (so every pod
//     sees every message — same fan-out semantics the in-process
//     publisher provides today).
//   * The subscription has TTL = 1h via `expirationPolicy.ttl` so a
//     crashed pod's leftover subscription auto-cleans.
//   * Message retention defaults to 5 min — matches the
//     `kRealtimeReplayBacklogWindow` floor and the in-process ring
//     buffer's effective lookback. No 24h "in case we need it"
//     retention; that would be over-engineering and inflates cost.
//   * A small in-memory `(operator_id, topic) → ring` is filled by
//     a background pull loop that calls Pub/Sub `subscriptions.pull`.
//     This ring is the [RealtimeReplayBacklog] implementation — at
//     replay time we use the same lookup logic as
//     `InProcessRealtimePublisher.replayMissed`. The ring is filled
//     across pods (every pod sees every message), so a reconnect to
//     any pod can answer the replay.
//
// Why pull instead of push: push requires the proxy to host an
// HTTPS endpoint Pub/Sub can hit, plus VPC routing rules. Pull is a
// single REST call that works from any pod with ADC. The cost
// difference is negligible at expected message rates.
//
// Cost note (operator constraint: simplicity + cost control):
//   Pub/Sub charges $40 / TiB throughput (negligible for our message
//   volume) plus subscription seat cost which only kicks in past
//   10 GB/month. At ~1000 msg/day per pod with sub-1KB payloads
//   (typical realtime fan-out), per-pod cost lands well below $1/mo
//   per pod. With `PUBSUB_REALTIME_ENABLED=false` (default), zero
//   cost.
//
// Hard contract reminders:
//   * Subscription names follow the pattern
//     `forge-realtime-<sanitized-revision>-<sanitized-host>-<random4>`
//     so they are unique per pod and auto-cleanup when the pod retires.
//   * Subscription `expiration_policy.ttl` = 1h: if a pod doesn't
//     ack within 1h (crash, eviction), Pub/Sub deletes the
//     subscription automatically. No human-tended cleanup runbook.
//   * `ack_deadline_seconds = 60` per slice spec.
//   * Operator scoping is enforced by [_appendToRing] keying on the
//     message's `operator_id` attribute; the proxy WebSocket route
//     filters to the connected operator's id when delivering.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../auth/firebase_admin_auth_client.dart' show OAuthAccessTokenProvider;
import 'google_cloud_pubsub_message_publisher.dart' show kGoogleCloudPubsubHost;
import 'realtime_event.dart';
import 'realtime_replay_resolver.dart';

/// Default subscription TTL — Pub/Sub auto-deletes a subscription that
/// has not been touched within this window. 1h covers the common
/// "Cloud Run pod crashed mid-replay" case without leaving dangling
/// subscriptions on a controlled scale-down.
const Duration kPubsubSubscriptionDefaultTtl = Duration(hours: 1);

/// Default ack deadline for pull responses. 60s gives the pull loop
/// generous slack to enqueue and ack each batch.
const Duration kPubsubSubscriptionDefaultAckDeadline = Duration(seconds: 60);

/// Default retention for the per-pod subscription's backlog. 5 min
/// matches `kRealtimeReplayBacklogWindow` and the existing in-process
/// ring buffer's effective lookback.
const Duration kPubsubSubscriptionDefaultMessageRetention =
    Duration(minutes: 5);

/// Pub/Sub-compatible subscription name. Constraints:
///   * 3-255 characters
///   * `[a-zA-Z][a-zA-Z0-9_\-.~+%]*`
///   * MUST NOT start with `goog`
class PubsubSubscriptionName {
  PubsubSubscriptionName._(this.value);

  final String value;

  /// Build a per-pod subscription name. The result is sanitized to
  /// satisfy Pub/Sub's name regex even when the Cloud Run revision /
  /// hostname includes characters Pub/Sub rejects.
  factory PubsubSubscriptionName.forPod({
    required String revision,
    required String hostname,
    Random? random,
  }) {
    final sanitizedRevision = _sanitize(revision, 'rev');
    final sanitizedHostname = _sanitize(hostname, 'pod');
    final r = random ?? Random.secure();
    final suffix = (r.nextInt(0xFFFF) | 0x1000).toRadixString(16);
    final composed =
        'forge-realtime-$sanitizedRevision-$sanitizedHostname-$suffix';
    // Pub/Sub max length 255 — truncate in the middle (preserve prefix
    // + suffix) if the composed name overflows.
    final clamped = composed.length > 255
        ? '${composed.substring(0, 251)}-${suffix}'
        : composed;
    return PubsubSubscriptionName._(clamped);
  }

  static String _sanitize(String raw, String fallback) {
    final cleaned = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_\-.]+'), '-');
    final trimmed = cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
    if (trimmed.isEmpty) return fallback;
    if (RegExp(r'^[a-zA-Z]').hasMatch(trimmed)) return trimmed.toLowerCase();
    return '$fallback-${trimmed.toLowerCase()}';
  }
}

/// Per-pod Cloud Pub/Sub subscriber. Responsibilities:
///   * Create a per-pod subscription against the configured topic on
///     [start]. Subscription has 1h TTL and 5min message retention by
///     default — matches the `kRealtimeReplayBacklogWindow` floor.
///   * Pull messages in a background loop and append to a per-(operator,
///     topic) ring buffer that backs [replayMissed].
///   * Delete the subscription on [stop] (called from the SIGTERM
///     handler). If [stop] doesn't run (crash), Pub/Sub's
///     `expirationPolicy.ttl` cleans up.
///
/// The class is intentionally tiny — it does NOT fan messages to
/// per-operator broadcast streams (the live fan-out is the existing
/// `PubsubRealtimePublisher` write path). It only fills the
/// replay-backlog ring. Live messages reach connected WebSocket
/// clients via the in-process publisher's broadcast streams in the
/// route, while the ring captures Pub/Sub's authoritative recent
/// history for cross-pod replay.
class GoogleCloudPubsubSubscriber implements RealtimeReplayBacklog {
  GoogleCloudPubsubSubscriber({
    required this.projectId,
    required this.topicName,
    required this.subscriptionName,
    required OAuthAccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
    Duration ttl = kPubsubSubscriptionDefaultTtl,
    Duration ackDeadline = kPubsubSubscriptionDefaultAckDeadline,
    Duration messageRetention = kPubsubSubscriptionDefaultMessageRetention,
    Duration pullInterval = const Duration(seconds: 1),
    int pullMaxMessages = 100,
    int ringBufferCapacity = kRealtimeReplayRingBufferCapacity,
    Duration timeout = const Duration(seconds: 10),
    void Function(GoogleCloudPubsubSubscriberLogEvent)? logger,
  })  : _accessTokenProvider = accessTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _ttl = ttl,
        _ackDeadline = ackDeadline,
        _messageRetention = messageRetention,
        _pullInterval = pullInterval,
        _pullMaxMessages = pullMaxMessages,
        _ringBufferCapacity = ringBufferCapacity,
        _timeout = timeout,
        _logger = logger ?? _noopLogger {
    if (ringBufferCapacity <= 0) {
      throw ArgumentError.value(
        ringBufferCapacity,
        'ringBufferCapacity',
        'must be positive',
      );
    }
  }

  final String projectId;
  final String topicName;
  final PubsubSubscriptionName subscriptionName;
  final OAuthAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;
  final Duration _ttl;
  final Duration _ackDeadline;
  final Duration _messageRetention;
  final Duration _pullInterval;
  final int _pullMaxMessages;
  final int _ringBufferCapacity;
  final Duration _timeout;
  final void Function(GoogleCloudPubsubSubscriberLogEvent) _logger;

  // (operator_id, topic) → ring buffer. Same shape as the in-process
  // publisher's ring; same lookup contract for replayMissed.
  final Map<_RingKey, List<RealtimeEvent>> _ringBuffers = {};

  Timer? _pullTimer;
  bool _pullInFlight = false;
  bool _started = false;
  bool _stopped = false;

  String get _subscriptionPath =>
      'projects/$projectId/subscriptions/${subscriptionName.value}';

  String get _topicPath => 'projects/$projectId/topics/$topicName';

  /// Provision the per-pod subscription against [topicName]. Idempotent:
  /// re-running against an existing name returns 200/409 and the loop
  /// proceeds. Throws on any other non-2xx so startup fails loud.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final token = await _accessTokenProvider.accessToken().timeout(_timeout);
    final uri = Uri.https(
      kGoogleCloudPubsubHost,
      '/v1/$_subscriptionPath',
    );
    final response = await _httpClient
        .put(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'topic': _topicPath,
            'ackDeadlineSeconds': _ackDeadline.inSeconds,
            'messageRetentionDuration':
                '${_messageRetention.inSeconds}s',
            'expirationPolicy': <String, Object?>{
              'ttl': '${_ttl.inSeconds}s',
            },
            'enableMessageOrdering': false,
            'retainAckedMessages': false,
          }),
        )
        .timeout(_timeout);
    if (response.statusCode == 200 || response.statusCode == 201) {
      _logger(
        GoogleCloudPubsubSubscriberLogEvent.subscriptionCreated(
          subscriptionName: subscriptionName.value,
          topicName: topicName,
        ),
      );
    } else if (response.statusCode == 409) {
      _logger(
        GoogleCloudPubsubSubscriberLogEvent.subscriptionAlreadyExists(
          subscriptionName: subscriptionName.value,
        ),
      );
    } else {
      throw StateError(
        'GoogleCloudPubsubSubscriber: failed to create subscription '
        '${subscriptionName.value} (status=${response.statusCode}): '
        '${_safeErrorSummary(response.body)}',
      );
    }
    _pullTimer = Timer.periodic(_pullInterval, (_) {
      if (_pullInFlight || _stopped) return;
      _pullInFlight = true;
      Future<void>.microtask(() async {
        try {
          await _pullOnce();
        } catch (error, stack) {
          _logger(
            GoogleCloudPubsubSubscriberLogEvent.pullFailed(
              subscriptionName: subscriptionName.value,
              error: error,
              stack: stack,
            ),
          );
        } finally {
          _pullInFlight = false;
        }
      });
    });
  }

  /// Delete the per-pod subscription. Best-effort: if the call fails
  /// (network error, GCP transient), the TTL on the subscription
  /// guarantees Pub/Sub will reap it within an hour. We log and move on.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _pullTimer?.cancel();
    _pullTimer = null;
    try {
      final token = await _accessTokenProvider.accessToken().timeout(_timeout);
      final uri = Uri.https(
        kGoogleCloudPubsubHost,
        '/v1/$_subscriptionPath',
      );
      final response = await _httpClient
          .delete(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _logger(
          GoogleCloudPubsubSubscriberLogEvent.subscriptionDeleted(
            subscriptionName: subscriptionName.value,
          ),
        );
      } else if (response.statusCode == 404) {
        _logger(
          GoogleCloudPubsubSubscriberLogEvent.subscriptionAlreadyGone(
            subscriptionName: subscriptionName.value,
          ),
        );
      } else {
        _logger(
          GoogleCloudPubsubSubscriberLogEvent.deleteFailed(
            subscriptionName: subscriptionName.value,
            statusCode: response.statusCode,
            body: _safeErrorSummary(response.body),
          ),
        );
      }
    } catch (error, stack) {
      _logger(
        GoogleCloudPubsubSubscriberLogEvent.pullFailed(
          subscriptionName: subscriptionName.value,
          error: error,
          stack: stack,
        ),
      );
    }
  }

  /// One pull tick. Calls `subscriptions.pull`, decodes each Pub/Sub
  /// message into a `RealtimeEvent`, appends to the per-(operator,
  /// topic) ring, then acks the batch. Acking failed-decode messages
  /// is the right move: a malformed message would just resurface every
  /// pull tick otherwise.
  Future<void> _pullOnce() async {
    if (_stopped) return;
    final token = await _accessTokenProvider.accessToken().timeout(_timeout);
    final pullUri = Uri.https(
      kGoogleCloudPubsubHost,
      '/v1/$_subscriptionPath:pull',
    );
    final pullResponse = await _httpClient
        .post(
          pullUri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'maxMessages': _pullMaxMessages,
            'returnImmediately': true,
          }),
        )
        .timeout(_timeout);
    if (pullResponse.statusCode != 200) {
      throw StateError(
        'GoogleCloudPubsubSubscriber: pull non-200 '
        '(status=${pullResponse.statusCode}): '
        '${_safeErrorSummary(pullResponse.body)}',
      );
    }
    final decoded = jsonDecode(pullResponse.body);
    if (decoded is! Map) return;
    final messagesRaw = decoded['receivedMessages'];
    if (messagesRaw is! List || messagesRaw.isEmpty) return;
    final ackIds = <String>[];
    for (final received in messagesRaw) {
      if (received is! Map) continue;
      final ackId = received['ackId'];
      if (ackId is String) ackIds.add(ackId);
      final message = received['message'];
      if (message is! Map) continue;
      final data = message['data'];
      if (data is! String || data.isEmpty) continue;
      try {
        final body = utf8.decode(base64Decode(data));
        final json = jsonDecode(body);
        if (json is! Map<String, Object?>) continue;
        final event = RealtimeEvent.fromJson(json);
        _appendToRing(event);
      } catch (error, stack) {
        _logger(
          GoogleCloudPubsubSubscriberLogEvent.messageDecodeFailed(
            subscriptionName: subscriptionName.value,
            error: error,
            stack: stack,
          ),
        );
        // continue — we still ack so the bad message doesn't stick.
      }
    }
    if (ackIds.isEmpty) return;
    final ackUri = Uri.https(
      kGoogleCloudPubsubHost,
      '/v1/$_subscriptionPath:acknowledge',
    );
    final ackResponse = await _httpClient
        .post(
          ackUri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{'ackIds': ackIds}),
        )
        .timeout(_timeout);
    if (ackResponse.statusCode != 200 && ackResponse.statusCode != 204) {
      throw StateError(
        'GoogleCloudPubsubSubscriber: ack non-2xx '
        '(status=${ackResponse.statusCode}): '
        '${_safeErrorSummary(ackResponse.body)}',
      );
    }
  }

  void _appendToRing(RealtimeEvent event) {
    final key = _RingKey(event.operatorId, event.topic);
    final ring = _ringBuffers.putIfAbsent(key, () => <RealtimeEvent>[]);
    // De-dupe by event_id — Pub/Sub at-least-once + per-pod
    // subscription means we must tolerate redeliveries showing up in
    // the same pull batch on rare occasion.
    final exists = ring.any((e) => e.eventId == event.eventId);
    if (exists) return;
    ring.add(event);
    while (ring.length > _ringBufferCapacity) {
      ring.removeAt(0);
    }
  }

  /// [RealtimeReplayBacklog] implementation. Same lookup contract as
  /// `InProcessRealtimePublisher.replayMissed` and
  /// `PubsubRealtimePublisher.replayMissed` — see those for the full
  /// contract. The cursor lookup is GLOBAL across the operator's
  /// rings (event_id is globally unique).
  @override
  Future<List<RealtimeEvent>> replayMissed({
    required String operatorId,
    required String topic,
    required String lastEventId,
    required Duration window,
  }) async {
    final cursorOccurredAt = _lookupCursorOccurredAt(operatorId, lastEventId);
    if (cursorOccurredAt == null) {
      return RealtimeReplayStaleSentinel.instance;
    }
    final cutoff = DateTime.now().toUtc().subtract(window);
    if (cursorOccurredAt.toUtc().isBefore(cutoff)) {
      return RealtimeReplayStaleSentinel.instance;
    }
    final ring = _ringBuffers[_RingKey(operatorId, topic)];
    if (ring == null || ring.isEmpty) {
      return const <RealtimeEvent>[];
    }
    final missed = <RealtimeEvent>[];
    for (final entry in ring) {
      if (entry.occurredAt.isAfter(cursorOccurredAt)) {
        missed.add(entry);
      }
    }
    return List<RealtimeEvent>.unmodifiable(missed);
  }

  DateTime? _lookupCursorOccurredAt(String operatorId, String eventId) {
    for (final key in _ringBuffers.keys) {
      if (key.operatorId != operatorId) continue;
      final ring = _ringBuffers[key]!;
      for (final entry in ring) {
        if (entry.eventId == eventId) return entry.occurredAt;
      }
    }
    return null;
  }

  /// Visible for tests.
  int ringLengthForTest(String operatorId, String topic) {
    final ring = _ringBuffers[_RingKey(operatorId, topic)];
    return ring?.length ?? 0;
  }

  /// Visible for tests — drive one pull tick synchronously.
  Future<void> pullOnceForTest() => _pullOnce();

  /// Visible for tests — set the started flag without provisioning.
  void markStartedForTest() {
    _started = true;
  }

  String _safeErrorSummary(String body) {
    if (body.isEmpty) return 'empty_body';
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return 'non_json_body';
      final error = decoded['error'];
      if (error is! Map) return 'no_error_envelope';
      final parts = <String>[];
      final code = error['code'];
      if (code is num) parts.add('code=${code.toInt()}');
      final status = error['status'];
      if (status is String && status.isNotEmpty) parts.add('status=$status');
      return parts.isEmpty ? 'no_error_fields' : parts.join(',');
    } catch (_) {
      return 'malformed_json_body';
    }
  }
}

class GoogleCloudPubsubSubscriberLogEvent {
  const GoogleCloudPubsubSubscriberLogEvent._({
    required this.kind,
    this.subscriptionName,
    this.topicName,
    this.statusCode,
    this.body,
    this.error,
    this.stack,
  });

  factory GoogleCloudPubsubSubscriberLogEvent.subscriptionCreated({
    required String subscriptionName,
    required String topicName,
  }) =>
      GoogleCloudPubsubSubscriberLogEvent._(
        kind: GoogleCloudPubsubSubscriberLogKind.subscriptionCreated,
        subscriptionName: subscriptionName,
        topicName: topicName,
      );

  factory GoogleCloudPubsubSubscriberLogEvent.subscriptionAlreadyExists({
    required String subscriptionName,
  }) =>
      GoogleCloudPubsubSubscriberLogEvent._(
        kind: GoogleCloudPubsubSubscriberLogKind.subscriptionAlreadyExists,
        subscriptionName: subscriptionName,
      );

  factory GoogleCloudPubsubSubscriberLogEvent.subscriptionDeleted({
    required String subscriptionName,
  }) =>
      GoogleCloudPubsubSubscriberLogEvent._(
        kind: GoogleCloudPubsubSubscriberLogKind.subscriptionDeleted,
        subscriptionName: subscriptionName,
      );

  factory GoogleCloudPubsubSubscriberLogEvent.subscriptionAlreadyGone({
    required String subscriptionName,
  }) =>
      GoogleCloudPubsubSubscriberLogEvent._(
        kind: GoogleCloudPubsubSubscriberLogKind.subscriptionAlreadyGone,
        subscriptionName: subscriptionName,
      );

  factory GoogleCloudPubsubSubscriberLogEvent.deleteFailed({
    required String subscriptionName,
    required int statusCode,
    required String body,
  }) =>
      GoogleCloudPubsubSubscriberLogEvent._(
        kind: GoogleCloudPubsubSubscriberLogKind.deleteFailed,
        subscriptionName: subscriptionName,
        statusCode: statusCode,
        body: body,
      );

  factory GoogleCloudPubsubSubscriberLogEvent.pullFailed({
    required String subscriptionName,
    required Object error,
    required StackTrace stack,
  }) =>
      GoogleCloudPubsubSubscriberLogEvent._(
        kind: GoogleCloudPubsubSubscriberLogKind.pullFailed,
        subscriptionName: subscriptionName,
        error: error,
        stack: stack,
      );

  factory GoogleCloudPubsubSubscriberLogEvent.messageDecodeFailed({
    required String subscriptionName,
    required Object error,
    required StackTrace stack,
  }) =>
      GoogleCloudPubsubSubscriberLogEvent._(
        kind: GoogleCloudPubsubSubscriberLogKind.messageDecodeFailed,
        subscriptionName: subscriptionName,
        error: error,
        stack: stack,
      );

  final GoogleCloudPubsubSubscriberLogKind kind;
  final String? subscriptionName;
  final String? topicName;
  final int? statusCode;
  final String? body;
  final Object? error;
  final StackTrace? stack;
}

enum GoogleCloudPubsubSubscriberLogKind {
  subscriptionCreated,
  subscriptionAlreadyExists,
  subscriptionDeleted,
  subscriptionAlreadyGone,
  deleteFailed,
  pullFailed,
  messageDecodeFailed,
}

void _noopLogger(GoogleCloudPubsubSubscriberLogEvent _) {}

class _RingKey {
  const _RingKey(this.operatorId, this.topic);

  final String operatorId;
  final String topic;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _RingKey &&
          other.operatorId == operatorId &&
          other.topic == topic);

  @override
  int get hashCode => Object.hash(operatorId, topic);
}
