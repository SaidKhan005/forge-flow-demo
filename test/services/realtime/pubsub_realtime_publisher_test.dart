// Phase 10a.1 - PubsubRealtimePublisher unit tests.
//
// Pinned behavior:
//   * Publisher implements the existing RealtimeEventPublisher seam
//     (interface conformance: a bridge worker that depends on the
//     interface can swap this in for InProcessRealtimePublisher
//     without compile changes).
//   * Constructor resolves every locked namespace from the contract's
//     "Topic Shape" set; a resolver that returns empty for any
//     namespace fails the boot path with ArgumentError.
//   * publish() translates the event's dotted topic to the locked
//     namespace prefix, looks up the resolved Pub/Sub topic name,
//     and hands body + attributes to the injected message publisher.
//   * publish() attaches operator_id, topic, and event_id as Pub/Sub
//     message attributes (operator scoping / dedupe carriers per the
//     contract Topic Shape + Payload Shape sections).
//   * Topics outside the locked namespace set are rejected with a
//     StateError (no invented topics).
//   * Successful publish increments publishedCount; failed publish
//     increments publishFailedCount and rethrows so the bridge's
//     lease-based retry kicks in.
//   * Custom topicNameResolver (e.g. project-prefixed Pub/Sub names)
//     wins over the default identity resolver.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/pubsub_realtime_publisher.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('PubsubRealtimePublisher - construction', () {
    test('resolves every locked namespace at construction (default resolver)',
        () {
      final publisher = PubsubRealtimePublisher(
        messagePublisher: _NoopMessagePublisher().publish,
      );
      // Default identity resolver returns the namespace verbatim.
      expect(
        publisher.resolvedTopics,
        equals(<String, String>{
          for (final namespace in defaultLockedNamespaces)
            namespace: namespace,
        }),
      );
      expect(publisher.lockedNamespaces, equals(defaultLockedNamespaces));
    });

    test('honors a custom topic-name resolver (project-prefixed names)', () {
      String resolver(String namespace) => 'forge.event.$namespace';
      final publisher = PubsubRealtimePublisher(
        messagePublisher: _NoopMessagePublisher().publish,
        topicNameResolver: resolver,
      );
      expect(
        publisher.resolvedTopics['rollup.invalidate'],
        'forge.event.rollup.invalidate',
      );
      expect(
        publisher.resolvedTopics['advisor.candidate'],
        'forge.event.advisor.candidate',
      );
      expect(
        publisher.resolvedTopics.length,
        defaultLockedNamespaces.length,
      );
    });

    test('throws ArgumentError when resolver returns empty for any namespace',
        () {
      String resolverWithGap(String namespace) {
        if (namespace == 'workflow.event') return '';
        return namespace;
      }
      expect(
        () => PubsubRealtimePublisher(
          messagePublisher: _NoopMessagePublisher().publish,
          topicNameResolver: resolverWithGap,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('workflow.event'),
          ),
        ),
        reason:
            'misconfiguration must fail the boot path; a missing namespace '
            'cannot silently drop events at runtime',
      );
    });

    test('throws ArgumentError when resolver throws for any namespace', () {
      String resolverThatThrows(String namespace) {
        if (namespace == 'auth.session') {
          throw const FormatException('topic config corrupt');
        }
        return namespace;
      }
      expect(
        () => PubsubRealtimePublisher(
          messagePublisher: _NoopMessagePublisher().publish,
          topicNameResolver: resolverThatThrows,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('auth.session'),
          ),
        ),
      );
    });

    test('locked namespace set matches the event_outbox contract', () {
      // Pinning the contract's "Topic Shape" locked list verbatim so
      // a future producer slip that adds a namespace without a paired
      // contract update fails this assertion.
      expect(
        defaultLockedNamespaces,
        equals(<String>{
          'auth.session',
          'auth.user',
          'usage.cap',
          'rollup.invalidate',
          'advisor.candidate',
          'workflow.event',
          'internal.health',
        }),
      );
    });
  });

  group('PubsubRealtimePublisher - publish', () {
    test('implements RealtimeEventPublisher (interface conformance)', () {
      final publisher = PubsubRealtimePublisher(
        messagePublisher: _NoopMessagePublisher().publish,
      );
      // The cast establishes interface conformance at compile time -
      // a regression in the public surface (e.g. a removed `publish`
      // method) would fail to compile here.
      final RealtimeEventPublisher seam = publisher;
      expect(seam, isA<RealtimeEventPublisher>());
    });

    test(
      'translates topic to locked namespace + hands body + attributes to the '
      'message publisher (default resolver)',
      () async {
        final recorder = _RecordingMessagePublisher();
        final publisher = PubsubRealtimePublisher(
          messagePublisher: recorder.publish,
        );
        final event = RealtimeEvent(
          eventId: 'evt-1',
          topic: 'rollup.invalidate.variance_week',
          operatorId: _opA,
          occurredAt: DateTime.utc(2026, 5, 3, 12),
          payload: const <String, Object?>{'event_id': 'evt-1'},
        );
        await publisher.publish(event);
        expect(recorder.messages, hasLength(1));
        final published = recorder.messages.single;
        expect(published.topicName, 'rollup.invalidate');
        expect(published.body, event.encode());
        expect(
          published.attributes,
          equals(<String, String>{
            'operator_id': _opA,
            'topic': 'rollup.invalidate.variance_week',
            'event_id': 'evt-1',
          }),
        );
      },
    );

    test('routes to the custom-resolved topic name when provided', () async {
      final recorder = _RecordingMessagePublisher();
      final publisher = PubsubRealtimePublisher(
        messagePublisher: recorder.publish,
        topicNameResolver: (ns) => 'forge.event.$ns',
      );
      await publisher.publish(
        RealtimeEvent(
          eventId: 'evt-2',
          topic: 'auth.session.login',
          operatorId: _opA,
          occurredAt: DateTime.utc(2026, 5, 3, 12),
          payload: const <String, Object?>{},
        ),
      );
      expect(recorder.messages.single.topicName, 'forge.event.auth.session');
    });

    test('rejects topics outside the locked namespace set with StateError',
        () async {
      final recorder = _RecordingMessagePublisher();
      final publisher = PubsubRealtimePublisher(
        messagePublisher: recorder.publish,
      );
      expect(
        () => publisher.publish(
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
      expect(
        recorder.messages,
        isEmpty,
        reason:
            'an invented-topic publish must NOT reach the message '
            'publisher - the locked namespace check is the gate',
      );
      expect(publisher.publishFailedCount, 1);
      expect(publisher.publishedCount, 0);
    });

    test(
      'rejects malformed (non-dotted) topics with FormatException AND '
      'updates failure counter + emits structured log (the bridge sees '
      'the same retry shape as a Pub/Sub ack failure)',
      () async {
        final logEvents = <PubsubRealtimePublisherLogEvent>[];
        final recorder = _RecordingMessagePublisher();
        final publisher = PubsubRealtimePublisher(
          messagePublisher: recorder.publish,
          logger: logEvents.add,
        );
        await expectLater(
          publisher.publish(
            RealtimeEvent(
              eventId: 'evt-bad',
              topic: 'no_namespace',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 3, 12),
              payload: const <String, Object?>{},
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          recorder.messages,
          isEmpty,
          reason:
              'malformed topic must NOT reach the message publisher - '
              'the namespace gate is the boundary',
        );
        expect(publisher.publishFailedCount, 1);
        expect(publisher.publishedCount, 0);
        expect(
          logEvents.map((e) => e.kind).toList(),
          <PubsubRealtimePublisherLogKind>[
            PubsubRealtimePublisherLogKind.publishFailed,
          ],
          reason:
              'a malformed topic must surface as publishFailed so the '
              'realtime metric path sees the same shape as a Pub/Sub '
              'failure (counter + structured log)',
        );
        expect(logEvents.single.error, isA<FormatException>());
        expect(logEvents.single.topic, 'no_namespace');
        expect(logEvents.single.eventId, 'evt-bad');
      },
    );

    test(
      'rejects namespace-only topics (no <kind> suffix) with the same '
      'failure shape - the contract locks every namespace as a wildcard '
      '(e.g. rollup.invalidate.*), so a topic of just "rollup.invalidate" '
      'is a malformed producer row',
      () async {
        final logEvents = <PubsubRealtimePublisherLogEvent>[];
        final recorder = _RecordingMessagePublisher();
        final publisher = PubsubRealtimePublisher(
          messagePublisher: recorder.publish,
          logger: logEvents.add,
        );
        // Walk every locked namespace - all of them must be rejected
        // when the producer drops a row with the namespace as the
        // entire topic (no `<kind>` suffix). Without this gate, a
        // bug in a producer site that elided the kind would route a
        // namespace-only event to Pub/Sub and bypass the failure
        // counter / structured-log path entirely.
        for (final namespace in defaultLockedNamespaces) {
          await expectLater(
            publisher.publish(
              RealtimeEvent(
                eventId: 'evt-bad-$namespace',
                topic: namespace,
                operatorId: _opA,
                occurredAt: DateTime.utc(2026, 5, 3, 12),
                payload: const <String, Object?>{},
              ),
            ),
            throwsA(isA<FormatException>()),
            reason:
                'namespace-only topic "$namespace" must be rejected; '
                'the contract requires a <kind> suffix',
          );
        }
        expect(
          recorder.messages,
          isEmpty,
          reason:
              'no namespace-only topic should reach the message '
              'publisher',
        );
        expect(publisher.publishFailedCount, defaultLockedNamespaces.length);
        expect(publisher.publishedCount, 0);
        expect(
          logEvents.map((e) => e.kind).toSet(),
          <PubsubRealtimePublisherLogKind>{
            PubsubRealtimePublisherLogKind.publishFailed,
          },
          reason:
              'every namespace-only rejection must surface as the '
              'publishFailed structured log event',
        );
        expect(logEvents, hasLength(defaultLockedNamespaces.length));
      },
    );

    test(
      'rejects topics with empty dotted segments (trailing dot, double '
      'dot, leading dot) with the same failure shape',
      () async {
        final publisher = PubsubRealtimePublisher(
          messagePublisher: _NoopMessagePublisher().publish,
        );
        // Trailing dot: namespace.kind missing the kind chars but
        // present syntactically.
        await expectLater(
          publisher.publish(
            RealtimeEvent(
              eventId: 'evt-bad-trail',
              topic: 'rollup.invalidate.',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 3, 12),
              payload: const <String, Object?>{},
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        // Double dot in the middle: a malformed namespace prefix.
        await expectLater(
          publisher.publish(
            RealtimeEvent(
              eventId: 'evt-bad-mid',
              topic: 'rollup..variance_week',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 3, 12),
              payload: const <String, Object?>{},
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        // Leading dot: empty first segment.
        await expectLater(
          publisher.publish(
            RealtimeEvent(
              eventId: 'evt-bad-lead',
              topic: '.rollup.invalidate.variance_week',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 3, 12),
              payload: const <String, Object?>{},
            ),
          ),
          throwsA(isA<FormatException>()),
        );
        expect(publisher.publishFailedCount, 3);
        expect(publisher.publishedCount, 0);
      },
    );

    test(
      'rejects non-lower-snake-case topics (uppercase, dashes, spaces, '
      'punctuation) with the same failure shape - the contract pins '
      '"Topics are dot-separated lower-snake-case strings"',
      () async {
        final logEvents = <PubsubRealtimePublisherLogEvent>[];
        final recorder = _RecordingMessagePublisher();
        final publisher = PubsubRealtimePublisher(
          messagePublisher: recorder.publish,
          logger: logEvents.add,
        );
        // Each of these has a valid 2-segment locked namespace prefix
        // (`rollup.invalidate`, `auth.session`) so a parser that only
        // checks segment count would let them through. The
        // lower-snake-case regex is the gate that catches them.
        const malformedTopics = <String>[
          'rollup.invalidate.VarianceWeek',     // uppercase in <kind>
          'rollup.invalidate.variance-week',    // dash in <kind>
          'rollup.invalidate.bad value',        // space in <kind>
          'rollup.invalidate.kind!',            // punctuation in <kind>
          'Rollup.invalidate.variance_week',    // uppercase in namespace1
          'rollup.Invalidate.variance_week',    // uppercase in namespace2
          'roll-up.invalidate.variance_week',   // dash in namespace1
          'rollup.invalidate.123_kind',         // leading digit (not snake_case start)
          'rollup.invalidate._leading_under',   // leading underscore (not snake_case start)
        ];
        for (final topic in malformedTopics) {
          await expectLater(
            publisher.publish(
              RealtimeEvent(
                eventId: 'evt-bad-${topic.hashCode}',
                topic: topic,
                operatorId: _opA,
                occurredAt: DateTime.utc(2026, 5, 3, 12),
                payload: const <String, Object?>{},
              ),
            ),
            throwsA(isA<FormatException>()),
            reason:
                'topic "$topic" violates lower-snake-case and must be '
                'rejected before reaching Pub/Sub',
          );
        }
        expect(
          recorder.messages,
          isEmpty,
          reason:
              'no non-snake-case topic should reach the message '
              'publisher',
        );
        expect(publisher.publishFailedCount, malformedTopics.length);
        expect(publisher.publishedCount, 0);
        expect(
          logEvents.length,
          malformedTopics.length,
          reason:
              'every shape rejection must surface as a publishFailed '
              'structured log event so the realtime metric path sees '
              'the same shape as a Pub/Sub failure',
        );
        for (final event in logEvents) {
          expect(event.kind, PubsubRealtimePublisherLogKind.publishFailed);
          expect(event.error, isA<FormatException>());
        }
      },
    );

    test(
      'accepts well-formed lower-snake-case topics including digits and '
      'underscores in the <kind> suffix',
      () async {
        final recorder = _RecordingMessagePublisher();
        final publisher = PubsubRealtimePublisher(
          messagePublisher: recorder.publish,
        );
        // Sanity check: the snake-case regex must not over-restrict.
        // These all match the contract's lower-snake-case rule.
        const validTopics = <String>[
          'rollup.invalidate.variance_week',
          'auth.session.login',
          'auth.session.refresh_v2',          // digit + underscore in <kind>
          'usage.cap.threshold_breach',
          'workflow.event.run_started',
          'advisor.candidate.turn_emitted_99', // digits in <kind>
        ];
        for (final topic in validTopics) {
          await publisher.publish(
            RealtimeEvent(
              eventId: 'evt-ok-${topic.hashCode}',
              topic: topic,
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 3, 12),
              payload: const <String, Object?>{},
            ),
          );
        }
        expect(recorder.messages, hasLength(validTopics.length));
        expect(publisher.publishedCount, validTopics.length);
        expect(publisher.publishFailedCount, 0);
      },
    );

    test('increments publishedCount on each successful publish', () async {
      final publisher = PubsubRealtimePublisher(
        messagePublisher: _NoopMessagePublisher().publish,
      );
      for (var i = 0; i < 3; i++) {
        await publisher.publish(
          RealtimeEvent(
            eventId: 'evt-$i',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 3, 12),
            payload: const <String, Object?>{},
          ),
        );
      }
      expect(publisher.publishedCount, 3);
      expect(publisher.publishFailedCount, 0);
    });

    test(
      'publish failure increments publishFailedCount and rethrows so the '
      'bridge can apply the lease-based retry',
      () async {
        final publisher = PubsubRealtimePublisher(
          messagePublisher: ({
            required String topicName,
            required String body,
            required Map<String, String> attributes,
          }) async {
            throw const _SimulatedPubsubFailure();
          },
        );
        await expectLater(
          publisher.publish(
            RealtimeEvent(
              eventId: 'evt-fail',
              topic: 'rollup.invalidate.variance_week',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 3, 12),
              payload: const <String, Object?>{},
            ),
          ),
          throwsA(isA<_SimulatedPubsubFailure>()),
        );
        expect(publisher.publishFailedCount, 1);
        expect(publisher.publishedCount, 0);
      },
    );

    test('emits structured log events for both success and failure paths',
        () async {
      final logEvents = <PubsubRealtimePublisherLogEvent>[];
      final publisher = PubsubRealtimePublisher(
        messagePublisher: ({
          required String topicName,
          required String body,
          required Map<String, String> attributes,
        }) async {
          if (attributes['event_id'] == 'evt-fail') {
            throw const _SimulatedPubsubFailure();
          }
        },
        logger: logEvents.add,
      );
      await publisher.publish(
        RealtimeEvent(
          eventId: 'evt-ok',
          topic: 'usage.cap.threshold_breach',
          operatorId: _opA,
          occurredAt: DateTime.utc(2026, 5, 3, 12),
          payload: const <String, Object?>{},
        ),
      );
      try {
        await publisher.publish(
          RealtimeEvent(
            eventId: 'evt-fail',
            topic: 'usage.cap.threshold_breach',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 3, 12),
            payload: const <String, Object?>{},
          ),
        );
      } catch (_) {
        // expected
      }
      expect(
        logEvents.map((e) => e.kind).toList(),
        <PubsubRealtimePublisherLogKind>[
          PubsubRealtimePublisherLogKind.published,
          PubsubRealtimePublisherLogKind.publishFailed,
        ],
      );
      // The published event carries the resolved topic name so the
      // log line can attribute fan-out cost to a specific Pub/Sub
      // topic without re-deriving it.
      expect(logEvents.first.topicName, 'usage.cap');
      expect(logEvents.first.eventId, 'evt-ok');
      expect(logEvents.last.error, isA<_SimulatedPubsubFailure>());
    });
  });
}

class _NoopMessagePublisher {
  Future<void> publish({
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

class _SimulatedPubsubFailure implements Exception {
  const _SimulatedPubsubFailure();
}
