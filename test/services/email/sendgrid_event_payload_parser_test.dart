// Phase 9.8 — SendGrid event-payload parser tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/sendgrid_event_payload_parser.dart';

void main() {
  group('parseSendGridEventPayload', () {
    test('rejects non-list root with shape failure at index -1', () {
      final batch = parseSendGridEventPayload(<String, Object?>{'foo': 1});
      expect(batch.records, isEmpty);
      expect(batch.failures, hasLength(1));
      expect(batch.failures.first.index, -1);
    });

    test('maps known event kinds and copies custom_args', () {
      final batch = parseSendGridEventPayload(<Map<String, Object?>>[
        <String, Object?>{
          'event': 'delivered',
          'sg_event_id': 'evt-1',
          'sg_message_id': 'sg-msg-1',
          'timestamp': 1700000000,
          'email': 'a@example.com',
          'email_id': '11111111-2222-3333-4444-555555555555',
          'template_id': 'operator_invite_first_admin',
          'operator_id': 'op-1',
        },
        <String, Object?>{
          'event': 'open',
          'sg_event_id': 'evt-2',
          'sg_message_id': 'sg-msg-1',
          'timestamp': 1700000005,
        },
        <String, Object?>{
          'event': 'click',
          'sg_event_id': 'evt-3',
          'timestamp': 1700000010,
        },
        <String, Object?>{
          'event': 'bounce',
          'sg_event_id': 'evt-4',
          'sg_message_id': 'sg-msg-2',
          'timestamp': 1700000020,
        },
        <String, Object?>{
          'event': 'spamreport',
          'sg_event_id': 'evt-5',
          'sg_message_id': 'sg-msg-3',
          'timestamp': 1700000030,
        },
      ]);
      expect(batch.failures, isEmpty);
      expect(batch.records, hasLength(5));
      expect(batch.records[0].eventKind, 'delivered');
      expect(batch.records[0].emailId,
          '11111111-2222-3333-4444-555555555555');
      expect(batch.records[0].providerMessageId, 'sg-msg-1');
      expect(batch.records[1].eventKind, 'opened');
      expect(batch.records[2].eventKind, 'clicked');
      expect(batch.records[3].eventKind, 'bounced');
      expect(batch.records[4].eventKind, 'complaint');
    });

    test('group_unsubscribe maps to unsubscribed', () {
      final batch = parseSendGridEventPayload(<Map<String, Object?>>[
        <String, Object?>{
          'event': 'group_unsubscribe',
          'sg_event_id': 'evt-x',
          'timestamp': 1700000100,
        },
      ]);
      expect(batch.records.single.eventKind, 'unsubscribed');
    });

    test('unknown event types map to "unknown" but still parse', () {
      final batch = parseSendGridEventPayload(<Map<String, Object?>>[
        <String, Object?>{
          'event': 'aliens',
          'sg_event_id': 'evt-9',
          'timestamp': 1700000200,
        },
      ]);
      expect(batch.records.single.eventKind, 'unknown');
      expect(batch.records.single.providerEventKindRaw, 'aliens');
    });

    test('missing sg_event_id -> failure', () {
      final batch = parseSendGridEventPayload(<Map<String, Object?>>[
        <String, Object?>{
          'event': 'delivered',
          'timestamp': 1700000000,
        },
      ]);
      expect(batch.records, isEmpty);
      expect(batch.failures.single.reason, contains('sg_event_id'));
    });

    test('missing timestamp -> failure but other events still ingest', () {
      final batch = parseSendGridEventPayload(<Map<String, Object?>>[
        <String, Object?>{
          'event': 'delivered',
          'sg_event_id': 'evt-good',
          'timestamp': 1700000000,
        },
        <String, Object?>{
          'event': 'delivered',
          'sg_event_id': 'evt-bad',
          // no timestamp
        },
      ]);
      expect(batch.records, hasLength(1));
      expect(batch.records.single.providerEventId, 'evt-good');
      expect(batch.failures, hasLength(1));
      expect(batch.failures.single.providerEventId, 'evt-bad');
    });

    test('non-object array element -> per-element failure', () {
      final batch = parseSendGridEventPayload(<Object?>['not-a-map']);
      expect(batch.records, isEmpty);
      expect(batch.failures.single.reason, contains('not a JSON object'));
    });

    test('terminal-status map covers bounced + complaint only', () {
      expect(kSendGridOutboxTerminalStatuses['bounced'], 'bounced');
      expect(kSendGridOutboxTerminalStatuses['complaint'], 'complaint');
      expect(kSendGridOutboxTerminalStatuses['delivered'], isNull);
      expect(kSendGridOutboxTerminalStatuses['opened'], isNull);
    });
  });
}
