// Phase 10a.5 — RealtimeReplayResolver unit tests.
//
// Pinned behavior:
//   * `lastEventId == null` → empty list, backlog NEVER consulted
//     (first-connect path).
//   * Cursor inside the backlog window → events strictly newer than
//     the cursor, ordered oldest → newest by `occurred_at`.
//   * Cursor unknown to the backlog OR older than the window →
//     `RealtimeReplayStaleSentinel.instance` (identity-checked).
//   * Replay events strictly precede live frames at the route layer
//     — the resolver itself answers a single batched query per
//     topic; the route's connection-wide closure folds them in
//     `occurred_at` ascending order.
//   * Ring-buffer overflow: when the cursor's id falls off the
//     in-process publisher's ring (capacity 256 by default), the
//     publisher returns the stale sentinel because the cursor is
//     unknown to the backlog after eviction.
//
// Authority:
//   * docs/contracts/event_outbox_contract.md — `event_id` for
//     dedupe, `occurred_at` for ordering.
//   * docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md
//     "WebSocket lifecycle" — replay window default 5 min.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';
import 'package:forge_and_flow/services/realtime/realtime_replay_resolver.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _topic = 'rollup.invalidate.variance_week';

void main() {
  group('RealtimeReplayResolver.resolveMissedSince', () {
    test(
      'first-connect path (lastEventId == null) returns an empty list and '
      'never consults the backlog',
      () async {
        final backlog = _RecordingBacklog();
        final resolver = RealtimeReplayResolver(backlog: backlog);

        final result = await resolver.resolveMissedSince(
          operatorId: _opA,
          topic: _topic,
          lastEventId: null,
          backlogWindow: kRealtimeReplayBacklogWindow,
        );

        expect(result, isEmpty);
        expect(
          backlog.invocations,
          isEmpty,
          reason: 'first-connect must short-circuit before the backlog query',
        );
      },
    );

    test(
      'happy-path replay returns 3 missed events in occurred_at ascending order',
      () async {
        final backlog = _StaticBacklog(
          fixed: <RealtimeEvent>[
            _event('e2', DateTime.utc(2026, 5, 5, 12, 0, 1)),
            _event('e3', DateTime.utc(2026, 5, 5, 12, 0, 2)),
            _event('e4', DateTime.utc(2026, 5, 5, 12, 0, 3)),
          ],
        );
        final resolver = RealtimeReplayResolver(backlog: backlog);

        final result = await resolver.resolveMissedSince(
          operatorId: _opA,
          topic: _topic,
          lastEventId: 'e1',
          backlogWindow: kRealtimeReplayBacklogWindow,
        );

        expect(
          result.map((e) => e.eventId).toList(),
          <String>['e2', 'e3', 'e4'],
          reason: 'replay must preserve oldest → newest order',
        );
        // Confirm occurred_at ascending across the slice — the route
        // sends them in this order to the wire so the client surfaces
        // them in producer order.
        for (var i = 0; i + 1 < result.length; i += 1) {
          expect(
            result[i].occurredAt.isBefore(result[i + 1].occurredAt),
            isTrue,
            reason: 'replay slice must be strictly ascending by occurred_at',
          );
        }
        expect(backlog.invocations, hasLength(1));
        expect(backlog.invocations.single.lastEventId, 'e1');
      },
    );

    test(
      'stale-watermark path returns RealtimeReplayStaleSentinel by identity',
      () async {
        final backlog = _StaticBacklog(stale: true);
        final resolver = RealtimeReplayResolver(backlog: backlog);

        final result = await resolver.resolveMissedSince(
          operatorId: _opA,
          topic: _topic,
          lastEventId: 'long-gone-cursor',
          backlogWindow: kRealtimeReplayBacklogWindow,
        );

        expect(
          identical(result, RealtimeReplayStaleSentinel.instance),
          isTrue,
          reason:
              'consumers distinguish stale from empty via identity — '
              'an empty list means "no missed events", stale means '
              '"refresh from Postgres"',
        );
        // The sentinel exposes List<RealtimeEvent> shape but is empty
        // and immutable; treating it as a normal list must NOT crash
        // a route that iterates it before checking the truncated flag.
        expect(result, isEmpty);
        expect(
          () => result.add(_event('x', DateTime.utc(2026, 5, 5, 12))),
          throwsUnsupportedError,
        );
      },
    );

    group('ring-buffer overflow path (in-process publisher)', () {
      test(
        'cursor evicted by ring overflow returns the stale sentinel',
        () async {
          // Tiny ring capacity makes the test deterministic — the
          // first event ("cursor") gets evicted on the third publish.
          final publisher = InProcessRealtimePublisher(ringBufferCapacity: 2);
          final base = DateTime.now().toUtc();
          await publisher.publish(_event('cursor', base));
          await publisher.publish(
            _event('e1', base.add(const Duration(milliseconds: 1))),
          );
          await publisher.publish(
            _event('e2', base.add(const Duration(milliseconds: 2))),
          );
          // Cursor's id has fallen off the ring; the only entries are
          // e1 and e2 (cap 2). The publisher cannot tell whether
          // "cursor" was ever seen on this instance — it conservatively
          // returns the stale sentinel.
          expect(publisher.ringLengthForTest(_opA, _topic), 2);

          final resolver = RealtimeReplayResolver(backlog: publisher);
          final result = await resolver.resolveMissedSince(
            operatorId: _opA,
            topic: _topic,
            lastEventId: 'cursor',
            backlogWindow: kRealtimeReplayBacklogWindow,
          );

          expect(
            identical(result, RealtimeReplayStaleSentinel.instance),
            isTrue,
            reason:
                'evicted cursor must trip the truncation control envelope, '
                'not a partial replay starting at the oldest surviving entry',
          );
          await publisher.close();
        },
      );

      test(
        'cursor still in the ring returns only events newer than the cursor '
        'and never includes the cursor itself',
        () async {
          final publisher = InProcessRealtimePublisher(ringBufferCapacity: 4);
          final base = DateTime.now().toUtc();
          await publisher.publish(_event('e1', base));
          await publisher.publish(
            _event('e2', base.add(const Duration(milliseconds: 1))),
          );
          await publisher.publish(
            _event('e3', base.add(const Duration(milliseconds: 2))),
          );

          final resolver = RealtimeReplayResolver(backlog: publisher);
          final result = await resolver.resolveMissedSince(
            operatorId: _opA,
            topic: _topic,
            lastEventId: 'e1',
            backlogWindow: kRealtimeReplayBacklogWindow,
          );

          expect(
            result.map((e) => e.eventId).toList(),
            <String>['e2', 'e3'],
            reason: 'cursor itself is excluded — client already saw it',
          );
          await publisher.close();
        },
      );

      test(
        'cursor inside the ring but older than backlogWindow returns sentinel',
        () async {
          final publisher = InProcessRealtimePublisher(ringBufferCapacity: 4);
          final now = DateTime.now().toUtc();
          // Cursor is 1 hour old → far outside the 5-minute window.
          final ancient = now.subtract(const Duration(hours: 1));
          await publisher.publish(_event('ancient', ancient));
          await publisher.publish(_event('recent', now));

          final resolver = RealtimeReplayResolver(backlog: publisher);
          final result = await resolver.resolveMissedSince(
            operatorId: _opA,
            topic: _topic,
            lastEventId: 'ancient',
            backlogWindow: kRealtimeReplayBacklogWindow,
          );

          expect(
            identical(result, RealtimeReplayStaleSentinel.instance),
            isTrue,
            reason:
                'cursor inside the ring but past the backlog window is the '
                'production retention semantic — Pub/Sub would have evicted '
                'it; the in-process ring matches that contract',
          );
          await publisher.close();
        },
      );

      test(
        'cross-topic resume: cursor on topic A correctly resumes a query on '
        'topic B (lookup is global; per-topic filter uses cursor.occurredAt)',
        () async {
          // event_id is globally unique per the event_outbox contract,
          // so a cursor lives only in its origin topic's ring. The
          // resolver must still answer "events on the OTHER topic
          // newer than the cursor" without reporting stale.
          final publisher = InProcessRealtimePublisher(ringBufferCapacity: 8);
          final base = DateTime.now().toUtc();
          const topicA = 'rollup.invalidate.variance_week';
          const topicB = 'auth.session.login';
          await publisher.publish(_event('a1', base, topic: topicA));
          await publisher.publish(
            _event(
              'b1',
              base.add(const Duration(milliseconds: 1)),
              topic: topicB,
            ),
          );
          await publisher.publish(
            _event(
              'a2',
              base.add(const Duration(milliseconds: 2)),
              topic: topicA,
            ),
          );
          await publisher.publish(
            _event(
              'b2',
              base.add(const Duration(milliseconds: 3)),
              topic: topicB,
            ),
          );

          final resolver = RealtimeReplayResolver(backlog: publisher);
          // Cursor "a1" lives in topic A's ring. Query topic B.
          final resultForB = await resolver.resolveMissedSince(
            operatorId: _opA,
            topic: topicB,
            lastEventId: 'a1',
            backlogWindow: kRealtimeReplayBacklogWindow,
          );

          expect(
            identical(resultForB, RealtimeReplayStaleSentinel.instance),
            isFalse,
            reason:
                'cursor lookup must be GLOBAL across the operator\'s rings; '
                'a per-topic lookup would falsely report stale and force '
                'truncation of topic B too',
          );
          expect(
            resultForB.map((e) => e.eventId).toList(),
            <String>['b1', 'b2'],
            reason: 'topic B events whose occurred_at is after a1.occurredAt',
          );
          await publisher.close();
        },
      );

      test(
        'pubsubBacklog wins over the in-process backlog when supplied (N5)',
        () async {
          // Two static backlogs; the resolver MUST query the pubsub
          // one when both are wired (production cross-pod replay path).
          // The local-fallback backlog is left wired so a future
          // resolver bug that drops the pubsub override silently falls
          // back to the in-process ring instead of an empty answer —
          // and this test catches that drift by asserting the local
          // backlog is never consulted while the pubsub backlog is.
          final localBacklog = _RecordingBacklog();
          final pubsubBacklog = _StaticBacklog(
            fixed: <RealtimeEvent>[
              _event('p1', DateTime.utc(2026, 5, 5, 12, 0, 1)),
              _event('p2', DateTime.utc(2026, 5, 5, 12, 0, 2)),
            ],
          );
          final resolver = RealtimeReplayResolver(
            backlog: localBacklog,
            pubsubBacklog: pubsubBacklog,
          );

          final result = await resolver.resolveMissedSince(
            operatorId: _opA,
            topic: _topic,
            lastEventId: 'cursor',
            backlogWindow: kRealtimeReplayBacklogWindow,
          );

          expect(result.map((e) => e.eventId).toList(), <String>['p1', 'p2']);
          expect(
            localBacklog.invocations,
            isEmpty,
            reason: 'pubsub override wins; local fallback is not consulted',
          );
          expect(pubsubBacklog.invocations, hasLength(1));
        },
      );

      test(
        'pubsubBacklog null falls back to the in-process backlog (N5)',
        () async {
          final localBacklog = _StaticBacklog(
            fixed: <RealtimeEvent>[
              _event('l1', DateTime.utc(2026, 5, 5, 12, 0, 1)),
            ],
          );
          final resolver = RealtimeReplayResolver(backlog: localBacklog);

          final result = await resolver.resolveMissedSince(
            operatorId: _opA,
            topic: _topic,
            lastEventId: 'cursor',
            backlogWindow: kRealtimeReplayBacklogWindow,
          );

          expect(result.map((e) => e.eventId).toList(), <String>['l1']);
          expect(localBacklog.invocations, hasLength(1));
        },
      );

      test(
        'cross-operator isolation: opA query never sees opB events',
        () async {
          final publisher = InProcessRealtimePublisher(ringBufferCapacity: 8);
          final base = DateTime.now().toUtc();
          await publisher.publish(
            _event('a1', base, operatorId: _opA),
          );
          await publisher.publish(
            _event(
              'b1',
              base.add(const Duration(milliseconds: 1)),
              operatorId: _opB,
            ),
          );
          await publisher.publish(
            _event(
              'a2',
              base.add(const Duration(milliseconds: 2)),
              operatorId: _opA,
            ),
          );

          final resolver = RealtimeReplayResolver(backlog: publisher);
          final resultForA = await resolver.resolveMissedSince(
            operatorId: _opA,
            topic: _topic,
            lastEventId: 'a1',
            backlogWindow: kRealtimeReplayBacklogWindow,
          );

          expect(
            resultForA.map((e) => e.eventId).toList(),
            <String>['a2'],
            reason: 'operator A query must NOT include operator B events',
          );
          await publisher.close();
        },
      );
    });
  });
}

RealtimeEvent _event(
  String eventId,
  DateTime occurredAt, {
  String operatorId = _opA,
  String topic = _topic,
}) {
  return RealtimeEvent(
    eventId: eventId,
    topic: topic,
    operatorId: operatorId,
    occurredAt: occurredAt,
    payload: const <String, Object?>{},
  );
}

class _BacklogInvocation {
  const _BacklogInvocation({
    required this.operatorId,
    required this.topic,
    required this.lastEventId,
    required this.window,
  });

  final String operatorId;
  final String topic;
  final String lastEventId;
  final Duration window;
}

class _RecordingBacklog implements RealtimeReplayBacklog {
  final List<_BacklogInvocation> invocations = <_BacklogInvocation>[];

  @override
  Future<List<RealtimeEvent>> replayMissed({
    required String operatorId,
    required String topic,
    required String lastEventId,
    required Duration window,
  }) async {
    invocations.add(
      _BacklogInvocation(
        operatorId: operatorId,
        topic: topic,
        lastEventId: lastEventId,
        window: window,
      ),
    );
    return const <RealtimeEvent>[];
  }
}

class _StaticBacklog implements RealtimeReplayBacklog {
  _StaticBacklog({this.fixed = const <RealtimeEvent>[], this.stale = false});

  final List<RealtimeEvent> fixed;
  final bool stale;
  final List<_BacklogInvocation> invocations = <_BacklogInvocation>[];

  @override
  Future<List<RealtimeEvent>> replayMissed({
    required String operatorId,
    required String topic,
    required String lastEventId,
    required Duration window,
  }) async {
    invocations.add(
      _BacklogInvocation(
        operatorId: operatorId,
        topic: topic,
        lastEventId: lastEventId,
        window: window,
      ),
    );
    if (stale) return RealtimeReplayStaleSentinel.instance;
    return List<RealtimeEvent>.unmodifiable(fixed);
  }
}
