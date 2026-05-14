// Wave 2 EN-3 — notif_event_telemetry_hook tests.
//
// Wave 2 EN-3-FU: the helpers in `notif_event_telemetry_hook.dart`
// are now deprecated fallbacks (the production dispatch path uses
// `NotificationEventFanout` via `buildPostgresNotificationEventFanout`).
// Each fire still emits the original `notif.event.unwired` warning so
// the EN-3 contract holds, AND an additional
// `notif.event.telemetry_fallback` warning so log search can surface
// "fanout did not run; telemetry path fired instead" without operator
// intervention. Tests inject a recording log seam; production binds
// to the proxy's [log] function.
//
// ignore_for_file: deprecated_member_use_from_same_package

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
      // EN-3-FU: two log lines per fire — the original
      // `notif.event.unwired` warning AND the deprecation-trip
      // `notif.event.telemetry_fallback` warning.
      expect(recorder.records, hasLength(2));
      final rec = recorder.records.first;
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
      // Deprecation-trip warning.
      final fallback = recorder.records.last;
      expect(fallback.event, 'notif.event.telemetry_fallback');
      expect(fallback.severity, LogSeverity.warning);
      expect(fallback.fields['event_kind'], 'notif.backfill.complete');
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
      // EN-3-FU: two log lines per fire (see succeeded test above).
      expect(recorder.records, hasLength(2));
      final rec = recorder.records.first;
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
      // EN-3-FU: two log lines per fire (see succeeded test above).
      expect(recorder.records, hasLength(2));
      final rec = recorder.records.first;
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
      // Deprecation-trip warning.
      final fallback = recorder.records.last;
      expect(fallback.event, 'notif.event.telemetry_fallback');
      expect(fallback.severity, LogSeverity.warning);
    });

    test('two failures emit two unwired + two fallback log lines',
        () async {
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
      // EN-3-FU: 2 fires x 2 log lines each.
      expect(recorder.records, hasLength(4));
      final unwired = recorder.records
          .where((r) => r.event == 'notif.event.unwired')
          .toList();
      expect(unwired, hasLength(2));
      expect(unwired[0].fields['operator_id'], 'op-2');
      expect(unwired[1].fields['operator_id'], 'op-3');
      final fallback = recorder.records
          .where((r) => r.event == 'notif.event.telemetry_fallback')
          .toList();
      expect(fallback, hasLength(2));
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
