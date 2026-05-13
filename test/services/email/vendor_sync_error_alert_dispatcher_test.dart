// Lane C C-2-D — VendorSyncErrorAlertDispatcher tests.
//
// Drives the dispatcher against in-memory fakes to assert:
//
//   * Happy path → email_outbox INSERT + audit_logs INSERT with the
//     vendor_sync_error_alert template id and stable idempotency key.
//   * Missing recipient → skipped, no enqueue, no audit row.
//   * Missing vendor metadata → skipped, no enqueue, no audit row.
//   * Outage-window idempotency key is stable across calls with the
//     same (operatorId, connectionId, outageStartedAt) triple.
//   * Error summary is clamped to 280 chars + ellipsised on overflow,
//     replaced with a friendly fallback when null/empty.
//   * Recipient salutation falls back to email local-part when no
//     display name supplied.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/email_template_renderer.dart';
import 'package:forge_and_flow/services/email/vendor_sync_error_alert_dispatcher.dart';

void main() {
  group('VendorSyncErrorAlertDispatcher.dispatch', () {
    test('happy path enqueues outbox row + audit row with stable key',
        () async {
      final outbox = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      final dispatcher = VendorSyncErrorAlertDispatcher(
        recipientLookup: _staticRecipient(
          operatorBusinessName: 'Acme Bistro',
          recipientEmail: 'admin@acme.test',
          recipientDisplayName: 'Pat Admin',
        ),
        vendorMetadataLookup: _staticVendor(
          vendorDisplayName: 'Toast',
          integrationConsoleUrl:
              'https://app.forgeflow.app/admin/integrations/conn-1',
        ),
        outboxWriter: outbox,
        auditWriter: audit.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 30),
      );

      final outcome = await dispatcher.dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: 'OAuth refresh token rejected',
      );

      expect(outcome, VendorSyncErrorAlertDispatchOutcome.enqueued);
      expect(outbox.enqueued, hasLength(1));
      final row = outbox.enqueued.single;
      expect(row.templateId, EmailTemplateIds.vendorSyncErrorAlert);
      expect(row.operatorId, 'op-1');
      expect(row.recipientEmail, 'admin@acme.test');
      expect(row.recipientDisplayName, 'Pat Admin');
      expect(row.templateData['vendorName'], 'Toast');
      expect(row.templateData['businessName'], 'Acme Bistro');
      expect(row.templateData['recipientName'], 'Pat Admin');
      expect(
        row.templateData['firstFailureHumanReadable'],
        '2026-05-13 09:50 UTC',
      );
      expect(
        row.templateData['errorSummary'],
        'OAuth refresh token rejected',
      );
      expect(
        row.templateData['integrationConsoleUrl'],
        'https://app.forgeflow.app/admin/integrations/conn-1',
      );
      expect(
        row.templateData['escalationWindowHumanReadable'],
        '2 hours',
      );
      // Idempotency key contract — stable per outage window.
      expect(
        row.templateData['outageWindowIdempotencyKey'],
        'vendor_sync_outage:op-1:conn-1:2026-05-13T09:50:00.000Z',
      );

      expect(audit.calls, hasLength(1));
      final auditRow = audit.calls.single;
      expect(auditRow.operatorId, 'op-1');
      expect(auditRow.locationId, 'loc-1');
      expect(
        auditRow.action,
        VendorSyncErrorAlertDispatcher.kAuditAction,
      );
      expect(auditRow.payload['connection_id'], 'conn-1');
      expect(
        auditRow.payload['outage_started_at'],
        '2026-05-13T09:50:00.000Z',
      );
      expect(auditRow.payload['recipient_email'], 'admin@acme.test');
      expect(auditRow.payload['vendor_display_name'], 'Toast');
    });

    test('missing recipient is a soft skip — no enqueue, no audit',
        () async {
      final outbox = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      final dispatcher = VendorSyncErrorAlertDispatcher(
        recipientLookup: ({required String operatorId}) async => null,
        vendorMetadataLookup: _staticVendor(
          vendorDisplayName: 'Toast',
          integrationConsoleUrl: 'https://example.test',
        ),
        outboxWriter: outbox,
        auditWriter: audit.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 30),
      );

      final outcome = await dispatcher.dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: 'token expired',
      );

      expect(
        outcome,
        VendorSyncErrorAlertDispatchOutcome.skippedNoRecipient,
      );
      expect(outbox.enqueued, isEmpty);
      expect(audit.calls, isEmpty);
    });

    test('missing vendor metadata is a soft skip — no enqueue, no audit',
        () async {
      final outbox = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      final dispatcher = VendorSyncErrorAlertDispatcher(
        recipientLookup: _staticRecipient(
          operatorBusinessName: 'Acme Bistro',
          recipientEmail: 'admin@acme.test',
        ),
        vendorMetadataLookup: ({
          required String operatorId,
          required String locationId,
          required String connectionId,
        }) async =>
            null,
        outboxWriter: outbox,
        auditWriter: audit.call,
        now: () => DateTime.utc(2026, 5, 13, 10, 30),
      );

      final outcome = await dispatcher.dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: 'token expired',
      );

      expect(
        outcome,
        VendorSyncErrorAlertDispatchOutcome.skippedNoVendorMetadata,
      );
      expect(outbox.enqueued, isEmpty);
      expect(audit.calls, isEmpty);
    });

    test('error summary clamps and ellipsises long input', () async {
      final outbox = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      final longError = 'x' * 500;
      final dispatcher = VendorSyncErrorAlertDispatcher(
        recipientLookup: _staticRecipient(
          operatorBusinessName: 'Acme',
          recipientEmail: 'a@b.test',
        ),
        vendorMetadataLookup: _staticVendor(
          vendorDisplayName: 'Toast',
          integrationConsoleUrl: 'https://example.test',
        ),
        outboxWriter: outbox,
        auditWriter: audit.call,
      );

      await dispatcher.dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: longError,
      );

      final summary = outbox.enqueued.single.templateData['errorSummary']!;
      expect(summary.length, lessThanOrEqualTo(281)); // 280 + ellipsis
      expect(summary.endsWith('…'), isTrue);
    });

    test('null error summary uses friendly fallback', () async {
      final outbox = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      final dispatcher = VendorSyncErrorAlertDispatcher(
        recipientLookup: _staticRecipient(
          operatorBusinessName: 'Acme',
          recipientEmail: 'a@b.test',
        ),
        vendorMetadataLookup: _staticVendor(
          vendorDisplayName: 'Toast',
          integrationConsoleUrl: 'https://example.test',
        ),
        outboxWriter: outbox,
        auditWriter: audit.call,
      );

      await dispatcher.dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: null,
      );

      expect(
        outbox.enqueued.single.templateData['errorSummary'],
        'The vendor did not respond as expected.',
      );
    });

    test(
        'recipient salutation falls back to email local-part when no '
        'display name', () async {
      final outbox = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      final dispatcher = VendorSyncErrorAlertDispatcher(
        recipientLookup: _staticRecipient(
          operatorBusinessName: 'Acme',
          recipientEmail: 'gm@acme.test',
        ),
        vendorMetadataLookup: _staticVendor(
          vendorDisplayName: 'Toast',
          integrationConsoleUrl: 'https://example.test',
        ),
        outboxWriter: outbox,
        auditWriter: audit.call,
      );

      await dispatcher.dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: 'something',
      );

      expect(
        outbox.enqueued.single.templateData['recipientName'],
        'gm',
      );
    });

    test('idempotency key stable across calls with same triple', () async {
      final outboxA = _FakeOutboxWriter();
      final outboxB = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      VendorSyncErrorAlertDispatcher dispatcherFor(
        VendorSyncErrorAlertOutboxWriter outbox,
      ) =>
          VendorSyncErrorAlertDispatcher(
            recipientLookup: _staticRecipient(
              operatorBusinessName: 'Acme',
              recipientEmail: 'a@b.test',
            ),
            vendorMetadataLookup: _staticVendor(
              vendorDisplayName: 'Toast',
              integrationConsoleUrl: 'https://example.test',
            ),
            outboxWriter: outbox,
            auditWriter: audit.call,
            now: () => DateTime.utc(2026, 5, 13, 10, 30),
          );

      await dispatcherFor(outboxA).dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: 'first call',
      );
      await dispatcherFor(outboxB).dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: 'second call',
      );

      expect(
        outboxA.enqueued.single.templateData['outageWindowIdempotencyKey'],
        outboxB.enqueued.single.templateData['outageWindowIdempotencyKey'],
      );
    });

    test('rendered template_data is consumable by the renderer', () async {
      // Smoke-check: every required template variable the
      // vendor_sync_error_alert.md template references is supplied
      // by the dispatcher's template_data map. We assert the keys
      // rather than render through the real renderer (the renderer's
      // own test suite owns the rendering contract).
      final outbox = _FakeOutboxWriter();
      final audit = _RecordingAuditWriter();
      final dispatcher = VendorSyncErrorAlertDispatcher(
        recipientLookup: _staticRecipient(
          operatorBusinessName: 'Acme',
          recipientEmail: 'a@b.test',
        ),
        vendorMetadataLookup: _staticVendor(
          vendorDisplayName: 'Toast',
          integrationConsoleUrl: 'https://example.test',
        ),
        outboxWriter: outbox,
        auditWriter: audit.call,
      );

      await dispatcher.dispatch(
        operatorId: 'op-1',
        locationId: 'loc-1',
        connectionId: 'conn-1',
        outageStartedAt: DateTime.utc(2026, 5, 13, 9, 50),
        errorSummary: 'token expired',
      );

      final keys = outbox.enqueued.single.templateData.keys.toSet();
      // Variables the on-disk template references.
      expect(keys, containsAll(<String>[
        'vendorName',
        'recipientName',
        'firstFailureHumanReadable',
        'errorSummary',
        'integrationConsoleUrl',
        'escalationWindowHumanReadable',
      ]));
    });
  });
}

// ─── In-memory fakes ───────────────────────────────────────────────

OperatorAdminEmailLookup _staticRecipient({
  required String operatorBusinessName,
  required String recipientEmail,
  String? recipientDisplayName,
}) =>
    ({required String operatorId}) async => OperatorAdminContact(
          operatorBusinessName: operatorBusinessName,
          recipientEmail: recipientEmail,
          recipientDisplayName: recipientDisplayName,
        );

VendorSyncAlertVendorMetadataLookup _staticVendor({
  required String vendorDisplayName,
  required String integrationConsoleUrl,
}) =>
    ({
      required String operatorId,
      required String locationId,
      required String connectionId,
    }) async =>
        VendorSyncAlertVendorMetadata(
          vendorDisplayName: vendorDisplayName,
          integrationConsoleUrl: integrationConsoleUrl,
        );

class _FakeOutboxWriter implements VendorSyncErrorAlertOutboxWriter {
  final List<_EnqueuedRow> enqueued = <_EnqueuedRow>[];

  @override
  Future<void> enqueue({
    required String operatorId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required String templateId,
    required Map<String, String> templateData,
  }) async {
    enqueued.add(_EnqueuedRow(
      operatorId: operatorId,
      recipientEmail: recipientEmail,
      recipientDisplayName: recipientDisplayName,
      templateId: templateId,
      templateData: Map<String, String>.unmodifiable(templateData),
    ));
  }
}

class _EnqueuedRow {
  _EnqueuedRow({
    required this.operatorId,
    required this.recipientEmail,
    required this.recipientDisplayName,
    required this.templateId,
    required this.templateData,
  });

  final String operatorId;
  final String recipientEmail;
  final String? recipientDisplayName;
  final String templateId;
  final Map<String, String> templateData;
}

class _RecordingAuditWriter {
  final List<_AuditCall> calls = <_AuditCall>[];

  Future<void> call({
    required String operatorId,
    required String locationId,
    required String action,
    required Map<String, Object?> payload,
  }) async {
    calls.add(_AuditCall(
      operatorId: operatorId,
      locationId: locationId,
      action: action,
      payload: Map<String, Object?>.unmodifiable(payload),
    ));
  }
}

class _AuditCall {
  _AuditCall({
    required this.operatorId,
    required this.locationId,
    required this.action,
    required this.payload,
  });

  final String operatorId;
  final String locationId;
  final String action;
  final Map<String, Object?> payload;
}
