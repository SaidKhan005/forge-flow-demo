// Phase 10a.1 - Bridge swap selector tests.
//
// Pinned behavior (Hard Promise #2: demo-mode persists post-launch -
// the in-process binding stays the local/demo default; production
// deploys flip the env flag to swap in the Pub/Sub adapter):
//   * Default env (no flag set) -> in-process publisher.
//   * PUBSUB_REALTIME_ENABLED=false / 0 / no -> in-process publisher.
//   * PUBSUB_REALTIME_ENABLED=true / 1 / yes (case-insensitive) ->
//     Pub/Sub publisher (PubsubRealtimePublisher) with locked
//     namespaces resolved at construction.
//   * The Pub/Sub publisher returned by the selector publishes
//     end-to-end through the injected message publisher (proves the
//     swap actually replaces the implementation behind the seam).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/pubsub_realtime_publisher.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';

import '../../../tool/advisor_proxy/realtime_bridge.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('selectRealtimePublisher - default off (in-process binding)', () {
    test('returns the in-process publisher when env flag is unset', () {
      final inProcess = InProcessRealtimePublisher();
      final selected = selectRealtimePublisher(
        environment: const <String, String>{},
        inProcessPublisher: inProcess,
        pubsubMessagePublisher: _UnreachableMessagePublisher.publish,
      );
      expect(identical(selected, inProcess), isTrue);
    });

    test('returns the in-process publisher when env flag is "false"', () {
      final inProcess = InProcessRealtimePublisher();
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: 'false',
        },
        inProcessPublisher: inProcess,
        pubsubMessagePublisher: _UnreachableMessagePublisher.publish,
      );
      expect(identical(selected, inProcess), isTrue);
    });

    test('returns the in-process publisher when env flag is "0"', () {
      final inProcess = InProcessRealtimePublisher();
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: '0',
        },
        inProcessPublisher: inProcess,
        pubsubMessagePublisher: _UnreachableMessagePublisher.publish,
      );
      expect(identical(selected, inProcess), isTrue);
    });

    test('returns the in-process publisher when env flag is "no"', () {
      final inProcess = InProcessRealtimePublisher();
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: 'no',
        },
        inProcessPublisher: inProcess,
        pubsubMessagePublisher: _UnreachableMessagePublisher.publish,
      );
      expect(identical(selected, inProcess), isTrue);
    });

    test('returns the in-process publisher for any unrecognized value', () {
      final inProcess = InProcessRealtimePublisher();
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: 'maybe',
        },
        inProcessPublisher: inProcess,
        pubsubMessagePublisher: _UnreachableMessagePublisher.publish,
      );
      expect(
        identical(selected, inProcess),
        isTrue,
        reason:
            'unrecognized values must NOT enable Pub/Sub - the swap is '
            'fail-closed so a typo cannot accidentally route fan-out to '
            'a non-existent Pub/Sub project.',
      );
    });
  });

  group('selectRealtimePublisher - flag on (Pub/Sub adapter)', () {
    test('returns PubsubRealtimePublisher when env flag is "true"', () {
      final inProcess = InProcessRealtimePublisher();
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: 'true',
        },
        inProcessPublisher: inProcess,
        pubsubMessagePublisher: _NoopMessagePublisher.publish,
      );
      expect(selected, isA<PubsubRealtimePublisher>());
      expect(identical(selected, inProcess), isFalse);
    });

    test('returns PubsubRealtimePublisher when env flag is "1"', () {
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: '1',
        },
        inProcessPublisher: InProcessRealtimePublisher(),
        pubsubMessagePublisher: _NoopMessagePublisher.publish,
      );
      expect(selected, isA<PubsubRealtimePublisher>());
    });

    test('returns PubsubRealtimePublisher when env flag is "yes"', () {
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: 'yes',
        },
        inProcessPublisher: InProcessRealtimePublisher(),
        pubsubMessagePublisher: _NoopMessagePublisher.publish,
      );
      expect(selected, isA<PubsubRealtimePublisher>());
    });

    test('flag value is case-insensitive ("TRUE", "True")', () {
      for (final raw in const <String>['TRUE', 'True', 'tRuE']) {
        final selected = selectRealtimePublisher(
          environment: <String, String>{pubsubRealtimeEnabledEnvVar: raw},
          inProcessPublisher: InProcessRealtimePublisher(),
          pubsubMessagePublisher: _NoopMessagePublisher.publish,
        );
        expect(
          selected,
          isA<PubsubRealtimePublisher>(),
          reason: 'flag value "$raw" must be recognized as enabled',
        );
      }
    });

    test('whitespace around flag value is tolerated', () {
      final selected = selectRealtimePublisher(
        environment: const <String, String>{
          pubsubRealtimeEnabledEnvVar: '  true  ',
        },
        inProcessPublisher: InProcessRealtimePublisher(),
        pubsubMessagePublisher: _NoopMessagePublisher.publish,
      );
      expect(selected, isA<PubsubRealtimePublisher>());
    });

    test(
      'selected Pub/Sub publisher routes events through the injected message '
      'publisher (the swap actually replaces the implementation behind the '
      'seam, not just the type)',
      () async {
        final recorder = _RecordingMessagePublisher();
        final selected = selectRealtimePublisher(
          environment: const <String, String>{
            pubsubRealtimeEnabledEnvVar: 'true',
          },
          inProcessPublisher: InProcessRealtimePublisher(),
          pubsubMessagePublisher: recorder.publish,
          topicNameResolver: (ns) => 'forge.event.$ns',
        );
        await selected.publish(
          RealtimeEvent(
            eventId: 'evt-1',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 3, 12),
            payload: const <String, Object?>{},
          ),
        );
        expect(recorder.messages, hasLength(1));
        expect(
          recorder.messages.single.topicName,
          'forge.event.rollup.invalidate',
        );
        expect(recorder.messages.single.attributes['operator_id'], _opA);
      },
    );

    test(
      'selected Pub/Sub publisher honors the locked namespace check; '
      'invented topics still throw',
      () async {
        final selected = selectRealtimePublisher(
          environment: const <String, String>{
            pubsubRealtimeEnabledEnvVar: 'true',
          },
          inProcessPublisher: InProcessRealtimePublisher(),
          pubsubMessagePublisher: _NoopMessagePublisher.publish,
        );
        expect(
          () => selected.publish(
            RealtimeEvent(
              eventId: 'evt-bad',
              topic: 'invented.namespace.kind',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 3, 12),
              payload: const <String, Object?>{},
            ),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}

class _UnreachableMessagePublisher {
  static Future<void> publish({
    required String topicName,
    required String body,
    required Map<String, String> attributes,
  }) async {
    throw StateError(
      'message publisher invoked while flag is off - the in-process '
      'binding should have short-circuited the Pub/Sub path',
    );
  }
}

class _NoopMessagePublisher {
  static Future<void> publish({
    required String topicName,
    required String body,
    required Map<String, String> attributes,
  }) async {}
}

class _PublishedMessage {
  const _PublishedMessage({
    required this.topicName,
    required this.body,
    required this.attributes,
  });

  final String topicName;
  final String body;
  final Map<String, String> attributes;
}

class _RecordingMessagePublisher {
  final List<_PublishedMessage> messages = <_PublishedMessage>[];

  Future<void> publish({
    required String topicName,
    required String body,
    required Map<String, String> attributes,
  }) async {
    messages.add(
      _PublishedMessage(
        topicName: topicName,
        body: body,
        attributes: Map<String, String>.unmodifiable(attributes),
      ),
    );
  }
}
