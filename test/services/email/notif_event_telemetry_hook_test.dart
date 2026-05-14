// Wave 2 EN-3 — notif_event_telemetry_hook tests.
//
// Pins the production behaviour the EN-3 mitigation guarantees: each
// terminal backfill outcome + every audit-anchor failure emits one
// structured `notif.event.unwired` warning so the silent-drop noted
// in debug.md:315-316 is visible in Cloud Logging. Tests inject a
// recording log seam; production binds to the proxy's [log]
// function.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/observability/log.dart';

import '../../../tool/advisor_proxy/email_dispatch/notif_event_telemetry_hook.dart';
import '../../../tool/integration_sync_worker/backfill_dispatch.dart';

void main() {
  group('buildBackfillTerminalTelemetryHook', () {
    test('emits notif.event.unwired with notif.backfill.complete on succeeded',
        () async {
      final recorder = _RecordingLogSeam();
      final hook = buildBackfillTerminalTelemetryHook(logSeam: recorder.seam);
      await hook(
        job: _job(),
        outcome: BackfillDispatchOutcome.succeeded,
      );
      expect(recorder.records, hasLength(1));
      final rec = recorder.records.single;
      expect(rec.event, 'notif.event.unwired');
      expect(rec.severity, LogSeverity.warning);
      expect(rec.fields['event_kind'], 'notif.backfill.complete');
      expect(rec.fields['template_id'], 'backfill_complete');
      expect(rec.fields['operator_id'], 'op-1');
      expect(rec.fields['location_id'], 'loc-1');
      expect(rec.fields['connection_id'], 'conn-1');
      expect(rec.fields['vendor_id'], 'toast');
      expect(rec.fields['job_id'], 'job-7');
      expect(rec.fields['reason'], 'fanout_not_bound_in_production');
      expect(
        rec.fields['recipient_address_for_review'],
        'support@forgeflow.org',
      );
      // Success path: no error_message field.
      expect(rec.fields.containsKey('error_message'), isFalse);
    });

    test('emits notif.event.unwired with notif.backfill.failed on failed + '
        'carries error_message', () async {
      final recorder = _RecordingLogSeam();
      final hook = buildBackfillTerminalTelemetryHook(logSeam: recorder.seam);
      await hook(
        job: _job(),
        outcome: BackfillDispatchOutcome.failed,
        errorMessage: 'cap_reached:network_timeout',
      );
      expect(recorder.records, hasLength(1));
      final rec = recorder.records.single;
      expect(rec.event, 'notif.event.unwired');
      expect(rec.fields['event_kind'], 'notif.backfill.failed');
      expect(rec.fields['template_id'], 'backfill_failed');
      expect(rec.fields['error_message'], 'cap_reached:network_timeout');
    });

    test('resumable + noJob outcomes do NOT emit', () async {
      final recorder = _RecordingLogSeam();
      final hook = buildBackfillTerminalTelemetryHook(logSeam: recorder.seam);
      await hook(job: _job(), outcome: BackfillDispatchOutcome.resumable);
      await hook(job: _job(), outcome: BackfillDispatchOutcome.noJob);
      expect(recorder.records, isEmpty);
    });
  });

  group('buildAuditAnchorFailureTelemetryHook', () {
    test('emits notif.event.unwired with notif.audit.anchor_failure',
        () async {
      final recorder = _RecordingLogSeam();
      final hook =
          buildAuditAnchorFailureTelemetryHook(logSeam: recorder.seam);
      await hook(
        operatorId: 'op-2',
        chainDateIso: '2026-05-13',
        reason: 'verify_chain_hash_mismatch: row 7',
      );
      expect(recorder.records, hasLength(1));
      final rec = recorder.records.single;
      expect(rec.event, 'notif.event.unwired');
      expect(rec.severity, LogSeverity.warning);
      expect(rec.fields['event_kind'], 'notif.audit.anchor_failure');
      expect(rec.fields['template_id'], 'audit_anchor_failure');
      expect(rec.fields['operator_id'], 'op-2');
      expect(rec.fields['chain_date'], '2026-05-13');
      expect(rec.fields['reason'], 'verify_chain_hash_mismatch: row 7');
      expect(rec.fields['fanout_status'], 'not_bound_in_production');
      expect(
        rec.fields['recipient_address_for_review'],
        'support@forgeflow.org',
      );
    });

    test('two failures emit two log lines', () async {
      final recorder = _RecordingLogSeam();
      final hook =
          buildAuditAnchorFailureTelemetryHook(logSeam: recorder.seam);
      await hook(
        operatorId: 'op-2',
        chainDateIso: '2026-05-13',
        reason: 'first',
      );
      await hook(
        operatorId: 'op-3',
        chainDateIso: '2026-05-13',
        reason: 'second',
      );
      expect(recorder.records, hasLength(2));
      expect(recorder.records[0].fields['operator_id'], 'op-2');
      expect(recorder.records[1].fields['operator_id'], 'op-3');
    });
  });
}

FirstConnectionBackfillJob _job() {
  final now = DateTime.utc(2026, 5, 14);
  return FirstConnectionBackfillJob(
    jobId: 'job-7',
    operatorId: 'op-1',
    locationId: 'loc-1',
    connectionId: 'conn-1',
    vendorId: 'toast',
    category: IntegrationCategory.pos,
    windowStart: now.subtract(const Duration(days: 60)),
    windowEnd: now,
    status: FirstConnectionBackfillJobStatus.succeeded,
    attemptCount: 1,
    createdAt: now,
    updatedAt: now,
  );
}

class _RecordingLogSeam {
  final List<_Record> records = <_Record>[];

  void seam(
    LogSeverity severity,
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    records.add(_Record(
      severity: severity,
      event: event,
      fields: Map<String, Object?>.from(fields),
    ));
  }
}

class _Record {
  _Record({
    required this.severity,
    required this.event,
    required this.fields,
  });

  final LogSeverity severity;
  final String event;
  final Map<String, Object?> fields;
}
