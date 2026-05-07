// Phase 8 W2.B - notification_event_hooks tests.
//
// Asserts the per-event hook helpers compose envelopes with the
// correct event_key, dedupe prefix, and push/email shapes. Each
// hook is exercised against a recording fanout closure so the
// trigger sites can import the helpers without re-asserting the
// envelope shape in every trigger-site test.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/email_dispatch/notification_event_fanout.dart';
import '../../../tool/advisor_proxy/email_dispatch/notification_event_hooks.dart';

void main() {
  group('notification_event_hooks', () {
    test('emitBackfillComplete fires fanout with notif.backfill.complete',
        () async {
      final recorder = _Recorder();
      await emitBackfillComplete(
        fanout: recorder.fanout,
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        vendorId: 'toast',
        jobId: 'job-7',
      );
      expect(recorder.calls, hasLength(1));
      expect(
        recorder.calls.single.envelope.eventKey,
        kNotifBackfillCompleteKey,
      );
      expect(
        recorder.calls.single.envelope.dedupeKeyPrefix,
        '$kNotifBackfillCompleteKey:op-1:job-7',
      );
      expect(
        recorder.calls.single.envelope.emailTemplateData['vendorId'],
        'toast',
      );
      expect(
        recorder.calls.single.envelope.pushData['vendor_id'],
        'toast',
      );
    });

    test('emitBackfillFailed fires fanout with notif.backfill.failed',
        () async {
      final recorder = _Recorder();
      await emitBackfillFailed(
        fanout: recorder.fanout,
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        vendorId: 'toast',
        jobId: 'job-9',
        reason: 'cap_reached:network_timeout',
      );
      expect(recorder.calls, hasLength(1));
      expect(
        recorder.calls.single.envelope.eventKey,
        kNotifBackfillFailedKey,
      );
      expect(
        recorder.calls.single.envelope.dedupeKeyPrefix,
        '$kNotifBackfillFailedKey:op-1:job-9',
      );
      expect(
        recorder.calls.single.envelope.emailTemplateData['reason'],
        'cap_reached:network_timeout',
      );
    });

    test(
        'emitAuditAnchorFailure fires fanout with notif.audit.anchor_failure',
        () async {
      final recorder = _Recorder();
      await emitAuditAnchorFailure(
        fanout: recorder.fanout,
        operatorId: 'op-1',
        chainDateIso: '2026-05-06',
        reason: 'chain_hash_mismatch: 1 violation(s)',
      );
      expect(recorder.calls, hasLength(1));
      expect(
        recorder.calls.single.envelope.eventKey,
        kNotifAuditAnchorFailureKey,
      );
      expect(
        recorder.calls.single.envelope.dedupeKeyPrefix,
        '$kNotifAuditAnchorFailureKey:op-1:2026-05-06',
      );
      expect(
        recorder.calls.single.envelope.emailTemplateData['chainDate'],
        '2026-05-06',
      );
    });

    test('hook tolerates fanout exceptions silently', () async {
      // No throw escapes the helper even when fanout fails.
      Future<NotificationFanoutOutcome> throwing({
        required String operatorId,
        required NotificationEventEnvelope envelope,
      }) async {
        throw StateError('seeded fanout failure');
      }

      // Reaching here means no rethrow.
      await emitBackfillComplete(
        fanout: throwing,
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        vendorId: 'toast',
        jobId: 'job-1',
      );
      await emitBackfillFailed(
        fanout: throwing,
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        vendorId: 'toast',
        jobId: 'job-1',
        reason: 'x',
      );
      await emitAuditAnchorFailure(
        fanout: throwing,
        operatorId: 'op-1',
        chainDateIso: '2026-05-06',
        reason: 'x',
      );
      expect(true, isTrue);
    });
  });
}

class _RecordingCall {
  _RecordingCall({required this.operatorId, required this.envelope});
  final String operatorId;
  final NotificationEventEnvelope envelope;
}

class _Recorder {
  final List<_RecordingCall> calls = <_RecordingCall>[];

  Future<NotificationFanoutOutcome> fanout({
    required String operatorId,
    required NotificationEventEnvelope envelope,
  }) async {
    calls.add(_RecordingCall(operatorId: operatorId, envelope: envelope));
    return NotificationFanoutOutcome(
      eventKey: envelope.eventKey,
      usersConsidered: 0,
      usersGated: 0,
      pushDispatched: 0,
      emailDispatched: 0,
      inboxDispatched: 0,
      skipped: 0,
    );
  }
}
