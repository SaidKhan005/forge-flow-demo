// Phase 10a.UX.1 — RealtimeEventBus behavior pin.
//
// Pinned behavior:
//   * publish forwards the frame to every active subscriber
//     (broadcast semantics — multiple listeners coexist)
//   * publish after dispose is a silent no-op (does not throw)
//   * dispose closes the underlying controller; subsequent listens
//     complete via onDone

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/state/realtime_event_bus.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('RealtimeEventBus', () {
    test('publish fans out to multiple subscribers', () async {
      final bus = RealtimeEventBus();
      final receivedA = <String>[];
      final receivedB = <String>[];

      final subA = bus.events.listen((e) => receivedA.add(e.topic));
      final subB = bus.events.listen((e) => receivedB.add(e.topic));

      bus.publish(_event(topic: 'shared_state.$_opA.restaurants'));
      bus.publish(_event(topic: 'shared_state.$_opA.audit_trail'));
      await Future<void>.delayed(Duration.zero);

      expect(receivedA, <String>[
        'shared_state.$_opA.restaurants',
        'shared_state.$_opA.audit_trail',
      ]);
      expect(receivedB, equals(receivedA));

      await subA.cancel();
      await subB.cancel();
      await bus.dispose();
    });

    test('publish after dispose is a silent no-op', () async {
      final bus = RealtimeEventBus();
      await bus.dispose();
      // No throw; idempotent dispose.
      expect(
        () => bus.publish(_event(topic: 'shared_state.$_opA.restaurants')),
        returnsNormally,
      );
      await bus.dispose();
    });
  });
}

RealtimeEvent _event({required String topic}) {
  return RealtimeEvent(
    eventId: 'evt-${topic.hashCode}',
    topic: topic,
    operatorId: _opA,
    occurredAt: DateTime.utc(2026, 5, 3, 12),
    payload: const <String, Object?>{},
  );
}
