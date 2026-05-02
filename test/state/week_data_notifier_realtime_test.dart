// Phase 10a.0 — WeekDataNotifier realtime hook test.
//
// Pinned behavior:
//   * subscribeRealtime listens to the provided event stream
//   * a frame on `rollup.invalidate.variance_week` triggers refresh()
//   * other topics are ignored (refresh count stays put)
//   * a second subscribeRealtime call cancels the prior subscription
//     so callers can re-bind on tenant context change without leaking

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/shift_data_source.dart';
import 'package:forge_and_flow/state/week_data_notifier.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('WeekDataNotifier.subscribeRealtime', () {
    test(
      'frame on rollup.invalidate.variance_week triggers refresh; '
      'other topics are ignored',
      () async {
        final source = _CountingShiftDataSource();
        final notifier = WeekDataNotifier(source);
        // Wait for the constructor's _load to settle.
        await _drainMicrotasks();
        final initialFetches = source.fetchCount;

        final controller = StreamController<RealtimeEvent>.broadcast();
        notifier.subscribeRealtime(controller.stream);

        controller.add(_event(topic: 'auth.session.login'));
        await _drainMicrotasks();
        expect(
          source.fetchCount,
          initialFetches,
          reason: 'unrelated topic must not trigger a refresh',
        );

        controller.add(_event(topic: varianceWeekInvalidateTopic));
        await _drainMicrotasks();
        expect(
          source.fetchCount,
          initialFetches + 1,
          reason: 'variance_week invalidation must trigger refresh()',
        );

        controller.add(_event(topic: varianceWeekInvalidateTopic));
        await _drainMicrotasks();
        expect(source.fetchCount, initialFetches + 2);

        await controller.close();
        notifier.dispose();
      },
    );

    test(
      're-subscribing cancels the prior subscription so the old stream '
      'no longer triggers refresh()',
      () async {
        final source = _CountingShiftDataSource();
        final notifier = WeekDataNotifier(source);
        await _drainMicrotasks();
        final initialFetches = source.fetchCount;

        final firstStream = StreamController<RealtimeEvent>.broadcast();
        final secondStream = StreamController<RealtimeEvent>.broadcast();

        notifier.subscribeRealtime(firstStream.stream);
        notifier.subscribeRealtime(secondStream.stream);

        firstStream.add(_event(topic: varianceWeekInvalidateTopic));
        await _drainMicrotasks();
        expect(
          source.fetchCount,
          initialFetches,
          reason: 'first stream is no longer subscribed; its frame is ignored',
        );

        secondStream.add(_event(topic: varianceWeekInvalidateTopic));
        await _drainMicrotasks();
        expect(
          source.fetchCount,
          initialFetches + 1,
          reason: 'second stream drives the refresh',
        );

        await firstStream.close();
        await secondStream.close();
        notifier.dispose();
      },
    );
  });
}

RealtimeEvent _event({required String topic}) {
  return RealtimeEvent(
    eventId: 'evt-${topic.hashCode}',
    topic: topic,
    operatorId: _opA,
    occurredAt: DateTime.utc(2026, 5, 2, 12),
    payload: const <String, Object?>{},
  );
}

Future<void> _drainMicrotasks() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _CountingShiftDataSource implements ShiftDataSource {
  int fetchCount = 0;

  @override
  Future<WeekData?> getWeekToDate() async {
    fetchCount += 1;
    return null;
  }

  @override
  Future<List<WeekRecord>> getWeekHistory() async => const <WeekRecord>[];

  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async =>
      const <HistoryPatternRecord>[];

  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async =>
      const <ShiftRecord>[];

  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async =>
      const <ShiftRecord>[];
}
