// Lane C C-1 — SendGridEvent payload parser tests.
//
// Pins the parsing contract that the SendGrid webhook receiver
// depends on. Pure-Dart; no Postgres / no proxy plumbing.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/sendgrid_event_payload.dart';

void main() {
  group('SendGridEvent.fromJson', () {
    test('parses a happy-path delivered event', () {
      final event = SendGridEvent.fromJson(<String, Object?>{
        'email': 'alice@example.com',
        'timestamp': 1718000000,
        'event': 'delivered',
        'sg_event_id': 'rbtnWrG1DVDGGGFHFQun8A',
        'sg_message_id': '14c5d75ce93.filter0001.5258.5',
        'smtp-id': '<abc@example.com>',
      });
      expect(event.providerEventId, 'rbtnWrG1DVDGGGFHFQun8A');
      expect(event.eventKind, 'delivered');
      expect(event.recipientEmail, 'alice@example.com');
      expect(event.providerMessageId, '14c5d75ce93.filter0001.5258.5');
      expect(event.occurredAt.isUtc, isTrue);
      expect(event.occurredAt.millisecondsSinceEpoch, 1718000000 * 1000);
      // Raw payload is preserved (and immutable).
      expect(event.rawPayload['smtp-id'], '<abc@example.com>');
      expect(
        () => event.rawPayload['smtp-id'] = '<x>',
        throwsUnsupportedError,
      );
    });

    test('normalises an unknown event kind to "unknown"', () {
      final event = SendGridEvent.fromJson(<String, Object?>{
        'email': 'bob@example.com',
        'timestamp': 1718000000,
        'event': 'beamed_to_orbit',
        'sg_event_id': 'event-id-xyz',
      });
      expect(event.eventKind, kSendGridEventKindUnknown);
    });

    test('rejects missing sg_event_id', () {
      expect(
        () => SendGridEvent.fromJson(<String, Object?>{
          'email': 'alice@example.com',
          'timestamp': 1718000000,
          'event': 'delivered',
        }),
        throwsA(
          isA<SendGridEventParseException>()
              .having((e) => e.field, 'field', 'sg_event_id'),
        ),
      );
    });

    test('rejects missing recipient email', () {
      expect(
        () => SendGridEvent.fromJson(<String, Object?>{
          'timestamp': 1718000000,
          'event': 'delivered',
          'sg_event_id': 'event-id-xyz',
        }),
        throwsA(
          isA<SendGridEventParseException>()
              .having((e) => e.field, 'field', 'email'),
        ),
      );
    });

    test('rejects a non-integer timestamp', () {
      expect(
        () => SendGridEvent.fromJson(<String, Object?>{
          'email': 'alice@example.com',
          'timestamp': 'not-a-number',
          'event': 'delivered',
          'sg_event_id': 'event-id-xyz',
        }),
        throwsA(
          isA<SendGridEventParseException>()
              .having((e) => e.field, 'field', 'timestamp'),
        ),
      );
    });

    test('rejects an oversized sg_event_id', () {
      final huge = 'a' * (kSendGridProviderEventIdMaxLength + 1);
      expect(
        () => SendGridEvent.fromJson(<String, Object?>{
          'email': 'alice@example.com',
          'timestamp': 1718000000,
          'event': 'delivered',
          'sg_event_id': huge,
        }),
        throwsA(
          isA<SendGridEventParseException>()
              .having((e) => e.field, 'field', 'sg_event_id'),
        ),
      );
    });

    test('treats omitted sg_message_id as nullable', () {
      final event = SendGridEvent.fromJson(<String, Object?>{
        'email': 'alice@example.com',
        'timestamp': 1718000000,
        'event': 'delivered',
        'sg_event_id': 'event-id-xyz',
      });
      expect(event.providerMessageId, isNull);
    });

    test('accepts every catalogued SendGrid event kind verbatim', () {
      for (final kind in kSendGridEventKinds) {
        final event = SendGridEvent.fromJson(<String, Object?>{
          'email': 'alice@example.com',
          'timestamp': 1718000000,
          'event': kind,
          'sg_event_id': 'event-id-$kind',
        });
        expect(event.eventKind, kind, reason: 'expected verbatim $kind');
      }
    });

    test('produces a deterministic compact JSON', () {
      final event = SendGridEvent.fromJson(<String, Object?>{
        'email': 'alice@example.com',
        'timestamp': 1718000000,
        'event': 'opened',
        'sg_event_id': 'event-id-1',
        'sg_message_id': 'msg-1',
      });
      expect(
        event.toCompactJson(),
        contains('"provider_event_id":"event-id-1"'),
      );
      expect(event.toCompactJson(), contains('"event_kind":"opened"'));
    });
  });
}
