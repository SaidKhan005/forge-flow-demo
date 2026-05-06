// Phase 10a.1 - Cloud Pub/Sub realtime publisher adapter.
//
// Implements the existing [RealtimeEventPublisher] seam from 10a.0.
// The bridge worker hands claimed `event_outbox` rows to a publisher;
// 10a.0 shipped only the in-process binding ([InProcessRealtimePublisher])
// for single-instance fan-out, with the explicit follow-up to swap in a
// Cloud Pub/Sub adapter once topics are provisioned. This file is that
// adapter.
//
// Why a seam swap and nothing else: the WebSocket route, the bridge
// worker, and the client `RealtimeSubscription` are all unchanged. The
// only difference between in-process and Pub/Sub is what the bridge
// hands `publish(event)` to. That keeps the swap a pure transport
// change - no app logic moves with it (Hard Promise #1: Phase 8 / 10a
// fan-out swaps stay pure transport).
//
// What this file does NOT do:
//   * Bind a real Pub/Sub SDK. The actual publish call is injected as
//     a `PubsubMessagePublisher` callback so the publisher can be unit
//     tested without a live Pub/Sub project. Wiring the production
//     callback (Application Default Credentials, project + region from
//     config) is a deploy-side concern outside this slice.
//   * Subscribe. The `/v1/realtime` WebSocket route is the consumer
//     side; in the multi-instance topology a Pub/Sub -> in-process
//     fan-out consumer is layered on top of the existing route in a
//     follow-up. That layering is downstream of this slice.
//
// Hard contract reminders honored here (see
// `docs/contracts/event_outbox_contract.md` "Topic Shape"):
//   * Locked namespace set is enumerated in [defaultLockedNamespaces].
//     Adding a topic namespace requires editing the contract AND this
//     constant in lockstep.
//   * Constructor asserts every locked namespace resolves to a
//     non-empty Pub/Sub topic name. Misconfiguration fails at boot
//     instead of silently dropping events whose namespace is missing
//     from the resolver.
//   * `publish(event)` rejects topics outside the locked namespace set
//     with a `StateError` so a stray producer cannot mint a
//     namespace by accident.
//   * Publish failures throw - the bridge worker's lease-based retry
//     in `tool/advisor_proxy/realtime_bridge.dart` depends on the
//     throw to re-NULL `picked_up_at` via the lease window.

import 'dart:async';
import 'dart:collection';

import 'realtime_event.dart';
import 'realtime_event_publisher.dart';
import 'realtime_replay_resolver.dart';

/// Resolves a Pub/Sub topic name from a locked namespace prefix
/// (e.g. `rollup.invalidate`). The resolver is invoked once per
/// namespace at construction so misconfiguration fails the boot path.
/// Production deploys override this to apply a project-prefix
/// convention (e.g. `(namespace) => 'forge.event.$namespace'`); the
/// default returns the namespace verbatim because the prefix decision
/// is a deploy-side concern that is not yet locked in this contract.
typedef PubsubTopicNameResolver = String Function(String namespace);

/// Publishes a single Pub/Sub message. Injected so the publisher can
/// be unit-tested without binding a live Pub/Sub SDK. Production wires
/// this to the Pub/Sub client (e.g. `gcloud_pubsub` or REST against
/// the project's topic). The callback MUST throw on graceful failure;
/// the publisher rethrows so the bridge's lease retry kicks in.
typedef PubsubMessagePublisher =
    Future<void> Function({
      required String topicName,
      required String body,
      required Map<String, String> attributes,
    });

/// Locked namespace set from `docs/contracts/event_outbox_contract.md`
/// "Topic Shape". Keep this in lockstep with the contract; adding a
/// namespace requires a paired contract update plus this constant.
const Set<String> defaultLockedNamespaces = <String>{
  'auth.session',
  'auth.user',
  'usage.cap',
  'rollup.invalidate',
  'advisor.candidate',
  'workflow.event',
  'internal.health',
};

/// Cloud Pub/Sub adapter for [RealtimeEventPublisher]. The bridge
/// worker hands claimed `event_outbox` rows here; this publisher
/// resolves the row's topic to a locked-namespace Pub/Sub topic and
/// publishes a single message with operator scoping carried as message
/// attributes.
///
/// **Operator scoping.** Per the contract, operator scoping for the
/// Pub/Sub leg is enforced by injecting `operator_id` into the
/// subscription filter; subscribers never see cross-operator events.
/// This publisher attaches `operator_id`, `topic`, and `event_id` as
/// Pub/Sub message attributes so the subscription filter can match on
/// them without parsing the body.
class PubsubRealtimePublisher
    implements RealtimeEventPublisher, RealtimeReplayBacklog {
  PubsubRealtimePublisher({
    required PubsubMessagePublisher messagePublisher,
    PubsubTopicNameResolver? topicNameResolver,
    Set<String> lockedNamespaces = defaultLockedNamespaces,
    void Function(PubsubRealtimePublisherLogEvent)? logger,
    int ringBufferCapacity = kRealtimeReplayRingBufferCapacity,
  }) : _messagePublisher = messagePublisher,
       _topicNameResolver = topicNameResolver ?? _defaultTopicNameResolver,
       _lockedNamespaces = Set<String>.unmodifiable(lockedNamespaces),
       _logger = logger ?? _noopLogger,
       _ringBufferCapacity = ringBufferCapacity {
    if (ringBufferCapacity <= 0) {
      throw ArgumentError.value(
        ringBufferCapacity,
        'ringBufferCapacity',
        'ring buffer capacity must be positive; replay would otherwise '
            'be a no-op for every reconnect',
      );
    }
    // Resolve every locked namespace once at construction. A resolver
    // that returns an empty string (or throws) means a namespace is
    // not wired to a Pub/Sub topic in this deploy - boot must fail so
    // the bridge does not silently drop events for the affected
    // namespace. Resolved names are memoized so [publish] never has
    // to re-invoke the resolver on the hot path.
    for (final namespace in _lockedNamespaces) {
      final String resolved;
      try {
        resolved = _topicNameResolver(namespace);
      } catch (error, stack) {
        throw ArgumentError(
          'PubsubRealtimePublisher: topicNameResolver threw for locked '
          'namespace "$namespace": $error\n$stack',
        );
      }
      if (resolved.isEmpty) {
        throw ArgumentError(
          'PubsubRealtimePublisher: topicNameResolver returned an empty '
          'name for locked namespace "$namespace"; every locked '
          'namespace MUST resolve to a Pub/Sub topic at construction.',
        );
      }
      _resolvedTopics[namespace] = resolved;
    }
  }

  final PubsubMessagePublisher _messagePublisher;
  final PubsubTopicNameResolver _topicNameResolver;
  final Set<String> _lockedNamespaces;
  final void Function(PubsubRealtimePublisherLogEvent) _logger;
  final Map<String, String> _resolvedTopics = <String, String>{};

  /// Phase 10a.5 — recent-events ring buffer keyed by
  /// `(operator_id, topic)` so [replayMissed] can answer reconnect
  /// queries without a Pub/Sub round-trip in single-instance demo
  /// mode. Production swaps this for a Cloud Pub/Sub backlog query
  /// behind the same [RealtimeReplayBacklog] seam.
  ///
  /// Per-key capacity is fixed at construction; the oldest entry is
  /// evicted when a publish would push the buffer past the cap.
  final Map<_RingKey, Queue<RealtimeEvent>> _ringBuffers =
      <_RingKey, Queue<RealtimeEvent>>{};
  final int _ringBufferCapacity;

  int _publishedCount = 0;
  int _publishFailedCount = 0;

  /// Locked namespaces this publisher accepts. Topics outside this set
  /// are rejected at [publish] time.
  Set<String> get lockedNamespaces => _lockedNamespaces;

  /// Snapshot of the namespace -> Pub/Sub topic-name map resolved at
  /// construction. Returned as an unmodifiable view so callers can
  /// inspect the wiring (for diagnostics / health surfaces) without
  /// mutating it.
  Map<String, String> get resolvedTopics =>
      Map<String, String>.unmodifiable(_resolvedTopics);

  /// Number of events the publisher successfully handed off to the
  /// underlying Pub/Sub message publisher. Read by the existing
  /// realtime metric path (structured logs + 11A.6 admin tile);
  /// no new health producer is added in this slice.
  int get publishedCount => _publishedCount;

  /// Number of events that failed to publish. Increments before the
  /// throw rethrows so callers can read the counter even after a
  /// failure path completes.
  int get publishFailedCount => _publishFailedCount;

  @override
  Future<void> publish(RealtimeEvent event) async {
    // _namespaceOf throws FormatException for non-dotted topics. Run
    // it under the same accounting + structured-log path as every
    // other publish failure so the counter and the publisher's log
    // surface a malformed topic the same way they surface a Pub/Sub
    // ack failure - the bridge's lease retry never sees a difference.
    final String namespace;
    try {
      namespace = _namespaceOf(event.topic);
    } catch (error, stack) {
      _publishFailedCount += 1;
      _logger(
        PubsubRealtimePublisherLogEvent.publishFailed(
          topic: event.topic,
          operatorId: event.operatorId,
          eventId: event.eventId,
          error: error,
          stack: stack,
        ),
      );
      rethrow;
    }
    final topicName = _resolvedTopics[namespace];
    if (topicName == null) {
      _publishFailedCount += 1;
      final error = StateError(
        'PubsubRealtimePublisher: topic "${event.topic}" is outside the '
        'locked namespace set ${_lockedNamespaces.toList()..sort()}; '
        'producers MUST NOT invent topics. See '
        'docs/contracts/event_outbox_contract.md "Topic Shape".',
      );
      _logger(
        PubsubRealtimePublisherLogEvent.publishFailed(
          topic: event.topic,
          operatorId: event.operatorId,
          eventId: event.eventId,
          error: error,
          stack: StackTrace.current,
        ),
      );
      throw error;
    }
    final attributes = <String, String>{
      'operator_id': event.operatorId,
      'topic': event.topic,
      'event_id': event.eventId,
    };
    try {
      await _messagePublisher(
        topicName: topicName,
        body: event.encode(),
        attributes: attributes,
      );
    } catch (error, stack) {
      _publishFailedCount += 1;
      _logger(
        PubsubRealtimePublisherLogEvent.publishFailed(
          topic: event.topic,
          operatorId: event.operatorId,
          eventId: event.eventId,
          topicName: topicName,
          error: error,
          stack: stack,
        ),
      );
      // Rethrow so the bridge worker's lease-based retry path picks
      // up the row again after `claimReclaimAfter`. The publisher MUST
      // NOT swallow failures - that would mark the row delivered
      // without the consumer actually getting the event.
      rethrow;
    }
    _publishedCount += 1;
    _appendToRingBuffer(event);
    _logger(
      PubsubRealtimePublisherLogEvent.published(
        topic: event.topic,
        operatorId: event.operatorId,
        eventId: event.eventId,
        topicName: topicName,
      ),
    );
  }

  /// Phase 10a.5 — RealtimeReplayBacklog implementation.
  ///
  /// Contract: "events with `occurred_at > lookup(lastEventId).occurred_at`"
  /// (slice prompt). The cursor lookup is GLOBAL across the operator's
  /// rings because `event_id` is globally unique per the
  /// `event_outbox` contract — a cursor observed on topic A lives
  /// only in topic A's ring, and a per-topic lookup against topic B
  /// would otherwise falsely report "cursor unknown" and force the
  /// route to truncate every topic the cursor was not originally on.
  /// Cross-operator isolation still holds because the lookup only
  /// inspects rings keyed to the supplied `operatorId`.
  ///
  /// Returns:
  ///   * [RealtimeReplayStaleSentinel.instance] — cursor not in any
  ///     of the operator's rings (evicted by ring overflow, or never
  ///     seen on this proxy instance), OR cursor is in a ring but
  ///     its `occurred_at` is older than `window` (production
  ///     Pub/Sub would have evicted it by retention).
  ///   * Empty list — cursor known and inside `window`, but the
  ///     queried `topic` has no events newer than the cursor.
  ///   * Non-empty list — events on the queried topic with
  ///     `occurred_at > cursor.occurredAt`, ordered oldest → newest.
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
      // Cursor known, but no events were ever published on this
      // (operator, topic) pair on this proxy instance — return empty
      // (no missed events on this topic), NOT sentinel.
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

  /// Search every ring belonging to [operatorId] for the supplied
  /// [eventId] and return its `occurred_at`, or null if not found.
  /// Cross-operator isolation: rings keyed to a different
  /// `operatorId` are skipped before the inner scan.
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

  void _appendToRingBuffer(RealtimeEvent event) {
    final key = _RingKey(event.operatorId, event.topic);
    final ring = _ringBuffers.putIfAbsent(key, () => Queue<RealtimeEvent>());
    ring.addLast(event);
    while (ring.length > _ringBufferCapacity) {
      ring.removeFirst();
    }
  }

  /// Visible for tests — current ring length for (operator, topic).
  /// Returns 0 when no events have been published for the pair.
  int ringLengthForTest(String operatorId, String topic) {
    final ring = _ringBuffers[_RingKey(operatorId, topic)];
    return ring?.length ?? 0;
  }

  /// Phase 10a.5 — topics the publisher has seen frames on for the
  /// supplied operator. Used by the proxy WebSocket route's replay
  /// fetcher closure to iterate the resolver per topic without
  /// having to enumerate every dotted suffix in the locked-namespace
  /// set. The result is a snapshot — concurrent publishes after the
  /// call returns are not reflected, which is fine because the route
  /// drains live frames into a buffer while the replay query is in
  /// flight.
  List<String> topicsForOperator(String operatorId) {
    final topics = <String>[];
    for (final key in _ringBuffers.keys) {
      if (key.operatorId == operatorId) {
        topics.add(key.topic);
      }
    }
    return List<String>.unmodifiable(topics);
  }

  /// Per-segment shape required by
  /// `docs/contracts/event_outbox_contract.md` "Topic Shape":
  /// "Topics are dot-separated lower-snake-case strings." A segment
  /// must start with a lowercase letter and may then contain
  /// lowercase letters, digits, and underscores. This rejects
  /// uppercase (`VarianceWeek`), dashes (`variance-week`), spaces,
  /// and any other punctuation that a malformed producer row could
  /// slip past a 2-segment namespace prefix check.
  static final RegExp _topicSegmentPattern = RegExp(r'^[a-z][a-z0-9_]*$');

  /// Extract the locked-namespace prefix from a dotted topic. Per
  /// `docs/contracts/event_outbox_contract.md` "Topic Shape", every
  /// locked namespace is a wildcard (`auth.session.*`,
  /// `rollup.invalidate.*`, ...), so every topic MUST carry a
  /// `<kind>` suffix beyond the 2-segment namespace prefix AND every
  /// segment must be lower-snake-case. The minimum valid form is
  /// three lower-snake-case dotted segments
  /// (`<namespace1>.<namespace2>.<kind>`); the following are all
  /// malformed producer rows that must NOT reach Pub/Sub:
  ///   * namespace-only:    `rollup.invalidate`
  ///   * empty segment:     `rollup.invalidate.`, `rollup..x`, `.r.i.x`
  ///   * non-snake-case:    `rollup.invalidate.VarianceWeek`,
  ///                        `rollup.invalidate.variance-week`,
  ///                        `rollup.invalidate.bad value`
  static String _namespaceOf(String topic) {
    final parts = topic.split('.');
    if (parts.length < 3 ||
        parts.any((p) => !_topicSegmentPattern.hasMatch(p))) {
      throw FormatException(
        'PubsubRealtimePublisher: topic "$topic" must have at least '
        'three dot-separated lower-snake-case segments '
        '(<namespace1>.<namespace2>.<kind>, e.g. '
        '"rollup.invalidate.variance_week"). Each segment must match '
        '[a-z][a-z0-9_]* (lowercase letter followed by lowercase '
        'letters, digits, or underscores). See '
        'docs/contracts/event_outbox_contract.md "Topic Shape".',
      );
    }
    return '${parts[0]}.${parts[1]}';
  }

  static String _defaultTopicNameResolver(String namespace) => namespace;
}

/// Structured log event emitted by [PubsubRealtimePublisher]. The
/// proxy entrypoint funnels this into the canonical `log()` helper
/// (see `lib/services/observability/log.dart`); tests inspect the
/// event list directly. Mirrors the shape of [RealtimeBridgeLogEvent]
/// so the existing realtime metric path can absorb both without a new
/// log envelope shape.
class PubsubRealtimePublisherLogEvent {
  const PubsubRealtimePublisherLogEvent._({
    required this.kind,
    this.topic,
    this.operatorId,
    this.eventId,
    this.topicName,
    this.error,
    this.stack,
  });

  factory PubsubRealtimePublisherLogEvent.published({
    required String topic,
    required String operatorId,
    required String eventId,
    required String topicName,
  }) => PubsubRealtimePublisherLogEvent._(
    kind: PubsubRealtimePublisherLogKind.published,
    topic: topic,
    operatorId: operatorId,
    eventId: eventId,
    topicName: topicName,
  );

  factory PubsubRealtimePublisherLogEvent.publishFailed({
    required String topic,
    required String operatorId,
    required String eventId,
    String? topicName,
    required Object error,
    required StackTrace stack,
  }) => PubsubRealtimePublisherLogEvent._(
    kind: PubsubRealtimePublisherLogKind.publishFailed,
    topic: topic,
    operatorId: operatorId,
    eventId: eventId,
    topicName: topicName,
    error: error,
    stack: stack,
  );

  final PubsubRealtimePublisherLogKind kind;
  final String? topic;
  final String? operatorId;
  final String? eventId;
  final String? topicName;
  final Object? error;
  final StackTrace? stack;
}

enum PubsubRealtimePublisherLogKind { published, publishFailed }

void _noopLogger(PubsubRealtimePublisherLogEvent event) {}

/// Phase 10a.5 — composite ring-buffer key. `(operator_id, topic)` is
/// the per-tenant slice that the route's defense-in-depth check
/// matches against the connecting JWT. Two separate strings instead
/// of an interpolated `$op|$topic` so a topic literal that happens to
/// contain `|` cannot collide with another operator's slice.
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
