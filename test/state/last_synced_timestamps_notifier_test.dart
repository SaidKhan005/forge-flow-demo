// Phase 10a.UX.1 — LastSyncedTimestampsNotifier behavior pin.
//
// Pinned behavior:
//   * `subscribeRealtime` listens to the provided event stream
//   * a frame on `shared_state.<op>.<table>` whose payload carries a
//     matching `table` field stamps that table (Lock 9 canonical)
//   * a frame on `shared_state.<op>.<table>` whose payload omits the
//     field stamps the table parsed from the topic last segment
//     (Lock 9 fallback)
//   * frames on non-`shared_state.*` topics are IGNORED, even when
//     they carry a `table` payload field — preventing false-positive
//     stamps from `auth.*`/`rollup.invalidate.*`/etc.
//   * a second `subscribeRealtime` call cancels the prior subscription
//     so callers can re-bind on tenant context change without leaking

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/state/last_synced_timestamps_notifier.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('LastSyncedTimestampsNotifier', () {
    test(
      'shared_state frames with payload[\'table\'] stamp the table; '
      'non-shared topics with a payload table are IGNORED',
      () async {
        var clockTick = 0;
        final clock = <DateTime>[
          DateTime.utc(2026, 5, 3, 12, 0, 0),
          DateTime.utc(2026, 5, 3, 12, 0, 5),
        ];
        final notifier = LastSyncedTimestampsNotifier(
          now: () => clock[clockTick++],
        );
        var notifyCount = 0;
        notifier.addListener(() => notifyCount++);

        final controller = StreamController<RealtimeEvent>.broadcast();
        notifier.subscribeRealtime(controller.stream);

        // P2 false-positive guard: a non-`shared_state.*` topic with a
        // `table` payload field MUST NOT stamp freshness.
        controller.add(
          _event(
            topic: 'auth.session.login',
            payload: const <String, Object?>{'table': 'restaurants'},
          ),
        );
        await _drainMicrotasks();
        expect(
          notifier.timestamps,
          isEmpty,
          reason:
              'auth.* with payload table is not a shared-state push '
              '(Lock 9) — must be ignored',
        );
        expect(notifyCount, 0);

        // Same false-positive guard for rollup.invalidate.*.
        controller.add(
          _event(
            topic: 'rollup.invalidate.variance_week',
            payload: const <String, Object?>{
              'table': 'weekly_plan_snapshots',
            },
          ),
        );
        await _drainMicrotasks();
        expect(notifier.timestamps, isEmpty);
        expect(notifyCount, 0);

        // A genuine shared_state frame with payload table stamps.
        controller.add(
          _event(
            topic: 'shared_state.$_opA.restaurants',
            payload: const <String, Object?>{'table': 'restaurants'},
          ),
        );
        await _drainMicrotasks();
        expect(notifier.lastSyncedAt('restaurants'), clock[0]);
        expect(notifyCount, 1);

        controller.add(
          _event(
            topic: 'shared_state.$_opA.weekly_plan_snapshots',
            payload: const <String, Object?>{'table': 'weekly_plan_snapshots'},
          ),
        );
        await _drainMicrotasks();
        expect(
          notifier.lastSyncedAt('weekly_plan_snapshots'),
          clock[1],
        );
        expect(notifyCount, 2);

        await controller.close();
        notifier.dispose();
      },
    );

    test(
      'topic shared_state.<op>.<table> stamps the table when payload '
      'lacks the field (Lock 9 fallback path)',
      () async {
        final fixed = DateTime.utc(2026, 5, 3, 12, 30);
        final notifier = LastSyncedTimestampsNotifier(now: () => fixed);
        final controller = StreamController<RealtimeEvent>.broadcast();
        notifier.subscribeRealtime(controller.stream);

        controller.add(
          _event(
            topic: 'shared_state.$_opA.benchmark_overrides',
            payload: const <String, Object?>{},
          ),
        );
        await _drainMicrotasks();
        expect(notifier.lastSyncedAt('benchmark_overrides'), fixed);

        await controller.close();
        notifier.dispose();
      },
    );

    test(
      'clear() drops every per-table timestamp and notifies; a '
      'second clear() on an empty map is a silent no-op',
      () async {
        final fixed = DateTime.utc(2026, 5, 3, 12, 30);
        final notifier = LastSyncedTimestampsNotifier(now: () => fixed);
        var notifyCount = 0;
        notifier.addListener(() => notifyCount++);

        notifier.ingest(
          _event(
            topic: 'shared_state.$_opA.restaurants',
            payload: const <String, Object?>{'table': 'restaurants'},
          ),
        );
        notifier.ingest(
          _event(
            topic: 'shared_state.$_opA.audit_trail',
            payload: const <String, Object?>{'table': 'audit_trail'},
          ),
        );
        expect(notifyCount, 2);
        expect(notifier.timestamps, isNotEmpty);

        notifier.clear();
        expect(notifier.timestamps, isEmpty);
        expect(
          notifyCount,
          3,
          reason: 'clear() must notifyListeners exactly once',
        );

        notifier.clear();
        expect(
          notifyCount,
          3,
          reason:
              'clear() on an already-empty map must be a silent '
              'no-op so a sign-out clear does not trigger a '
              'pointless rebuild',
        );

        notifier.dispose();
      },
    );

    test(
      're-subscribing cancels the prior subscription so the old stream '
      'no longer stamps timestamps',
      () async {
        var clockTick = 0;
        final clock = <DateTime>[
          DateTime.utc(2026, 5, 3, 12, 0, 0),
          DateTime.utc(2026, 5, 3, 12, 0, 5),
        ];
        final notifier = LastSyncedTimestampsNotifier(
          now: () => clock[clockTick++],
        );

        final firstStream = StreamController<RealtimeEvent>.broadcast();
        final secondStream = StreamController<RealtimeEvent>.broadcast();
        notifier.subscribeRealtime(firstStream.stream);
        notifier.subscribeRealtime(secondStream.stream);

        firstStream.add(
          _event(
            topic: 'shared_state.$_opA.restaurants',
            payload: const <String, Object?>{'table': 'restaurants'},
          ),
        );
        await _drainMicrotasks();
        expect(
          notifier.lastSyncedAt('restaurants'),
          isNull,
          reason:
              'first stream is no longer subscribed; its frame is ignored',
        );

        secondStream.add(
          _event(
            topic: 'shared_state.$_opA.restaurants',
            payload: const <String, Object?>{'table': 'restaurants'},
          ),
        );
        await _drainMicrotasks();
        expect(notifier.lastSyncedAt('restaurants'), clock[0]);

        await firstStream.close();
        await secondStream.close();
        notifier.dispose();
      },
    );
  });
}

RealtimeEvent _event({
  required String topic,
  required Map<String, Object?> payload,
}) {
  return RealtimeEvent(
    eventId: 'evt-${topic.hashCode}-${payload['table'] ?? 'none'}',
    topic: topic,
    operatorId: _opA,
    occurredAt: DateTime.utc(2026, 5, 3, 12),
    payload: payload,
  );
}

Future<void> _drainMicrotasks() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
