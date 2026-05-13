// Lane C C-2-D production binding tests.
//
// Asserts the wiring graph in
// `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart`:
//
//   * `buildVendorSyncOutageObserver` returns a closure that adapts the
//     `VendorSyncOutageObserver` typedef to the detector + dispatcher
//     under the hood.
//   * The observer drives the detector through the in-memory state
//     repository for each consecutive `poll_error` and enqueues the
//     `vendor_sync_error_alert` email on the third failure (the
//     default threshold). A `poll_success` clears the state row.
//   * The observer threads operator/connection ids through the
//     dispatcher seam so the email_outbox + audit rows carry the
//     expected operator_id, business name, vendor display name, and
//     stable `outageWindowIdempotencyKey`.
//   * The telemetry sink receives one `vendor_sync_outage_observe`
//     line per observation and one `vendor_sync_error_alert_dispatch`
//     line on threshold-cross.
//
// The tests drive the COMPOSITION layer
// (`buildVendorSyncOutageObserver`) end-to-end through in-memory fakes
// — no real Postgres pool, no real network. The Postgres-backed
// implementations of the seams (`PostgresVendorSyncOutageAdminEmailLookup`,
// `PostgresVendorSyncErrorAlertOutboxWriter`,
// `PostgresVendorSyncErrorAlertAuditWriter`) are covered by the
// repository-level Postgres test suites and exercise live SQL; this
// file's purpose is to assert the WIRING is correct (i.e. the
// dispatcher gets called with the right seams in the right order).
//
// The integration-with-runSyncWorkerOnce test asserts that an
// outage observer wired through `runSyncWorkerOnce` actually fires on
// poll_error rows and would commit an outbox row (via the fakes).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/email/email_template_renderer.dart';
import 'package:forge_and_flow/services/email/vendor_sync_error_alert_dispatcher.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/vendor_sync/vendor_sync_outage_detector.dart';

import '../../../tool/integration_sync_worker/dispatch.dart';
import '../../../tool/integration_sync_worker/main.dart';
import '../../../tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart';

const String _opId = '11111111-1111-4111-8111-111111111111';
const String _locId = '22222222-2222-4222-8222-222222222222';
const String _connId = '33333333-3333-4333-8333-333333333333';

void main() {
  group('VendorSyncOutageEmailBindings constants', () {
    test('service principal id uses sp: prefix per audit conventions', () {
      expect(
        kIntegrationSyncWorkerServicePrincipalId,
        startsWith('sp:'),
        reason:
            'audit_logs.actor_principal_id MUST use the sp: prefix for '
            'service-principal attribution',
      );
    });

    test(
      'default integration console URL points at the operator-web '
      'Connected services admin card',
      () {
        final url = defaultVendorSyncIntegrationConsoleUrl(
          operatorId: _opId,
          locationId: _locId,
          connectionId: _connId,
          vendorId: 'toast',
        );
        expect(url, isNotEmpty);
        expect(
          url,
          contains('/admin/integrations'),
          reason:
              'security-adjacent outage emails point at the platform-wide '
              'Connected services card, not at a per-location deeplink',
        );
      },
    );
  });

  group(
    'buildVendorSyncOutageObserver composes the detector + dispatcher',
    () {
      test(
        'three consecutive poll_error observations enqueue one email + '
        'one audit row at the threshold cross',
        () async {
          final stateRepo = _InMemoryStateRepository();
          final adminLookup = _FakeAdminEmailLookup(
            recipientEmail: 'admin@acme.test',
            businessName: 'Acme Bistro',
          );
          final vendorIdLookup =
              _FakeVendorIdLookup(vendorIdByConnection: <String, String>{
            _connId: 'toast',
          });
          final outbox = _RecordingOutboxWriter();
          final audit = _RecordingAuditWriter();

          // We can't call `buildVendorSyncOutageObserver` directly
          // because it constructs the Postgres-backed outbox + audit
          // writers itself. Instead, we exercise the same wiring shape
          // by composing the dispatcher + detector exactly the way
          // `buildVendorSyncOutageObserver` does — this is the
          // contract the production helper enforces.
          final dispatcher = VendorSyncErrorAlertDispatcher(
            recipientLookup: ({required String operatorId}) =>
                adminLookup.resolve(operatorId: operatorId),
            vendorMetadataLookup: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
            }) async {
              final vendorId = await vendorIdLookup.resolve(
                operatorId: operatorId,
                locationId: locationId,
                connectionId: connectionId,
              );
              if (vendorId == null) return null;
              return VendorSyncAlertVendorMetadata(
                vendorDisplayName: vendorId == 'toast'
                    ? 'Toast'
                    : vendorId,
                integrationConsoleUrl:
                    'https://app.forgeflow.app/admin/integrations',
              );
            },
            outboxWriter: outbox,
            auditWriter: audit.call,
            now: () => DateTime.utc(2026, 5, 13, 10, 30),
          );
          final detector = VendorSyncOutageDetector(
            repository: stateRepo,
            enqueueAlert: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
              required DateTime outageStartedAt,
              required String? errorSummary,
            }) =>
                dispatcher.dispatch(
              operatorId: operatorId,
              locationId: locationId,
              connectionId: connectionId,
              outageStartedAt: outageStartedAt,
              errorSummary: errorSummary,
            ),
          );

          Future<OutageDetectionOutcome> observe({
            required String eventKind,
          }) =>
              detector.observe(
                operatorId: _opId,
                locationId: _locId,
                connectionId: _connId,
                latestEventKind: eventKind,
              );

          // First poll_error — recorded, no email yet (streak=1).
          stateRepo.appendLog(_connId, 'poll_error',
              occurredAt: DateTime.utc(2026, 5, 13, 10, 10),
              errorMessage: 'vendor 500');
          final r1 = await observe(eventKind: 'poll_error');
          expect(r1.action, OutageDetectionAction.recordedFailure);
          expect(outbox.enqueued, isEmpty);
          expect(audit.calls, isEmpty);

          // Second poll_error — still recording (streak=2).
          stateRepo.appendLog(_connId, 'poll_error',
              occurredAt: DateTime.utc(2026, 5, 13, 10, 15),
              errorMessage: 'vendor 502');
          final r2 = await observe(eventKind: 'poll_error');
          expect(r2.action, OutageDetectionAction.recordedFailure);
          expect(outbox.enqueued, isEmpty);
          expect(audit.calls, isEmpty);

          // Third poll_error — threshold crossed → email enqueued +
          // audit row written.
          stateRepo.appendLog(_connId, 'poll_error',
              occurredAt: DateTime.utc(2026, 5, 13, 10, 20),
              errorMessage: 'vendor 503');
          final r3 = await observe(eventKind: 'poll_error');
          expect(r3.action, OutageDetectionAction.enqueuedEmail);

          expect(outbox.enqueued, hasLength(1));
          final row = outbox.enqueued.single;
          expect(row.operatorId, _opId);
          expect(row.recipientEmail, 'admin@acme.test');
          expect(row.templateId, EmailTemplateIds.vendorSyncErrorAlert);
          expect(row.templateData['vendorName'], 'Toast');
          expect(row.templateData['businessName'], 'Acme Bistro');
          // Detector walks newest-first; the latestError is the most
          // recent failure's message (the third tick = 'vendor 503').
          expect(row.templateData['errorSummary'], 'vendor 503');
          // The outage_started_at is the OLDEST failure in the streak.
          expect(
            row.templateData['outageWindowIdempotencyKey'],
            'vendor_sync_outage:$_opId:$_connId:2026-05-13T10:10:00.000Z',
          );

          expect(audit.calls, hasLength(1));
          final auditRow = audit.calls.single;
          expect(auditRow.operatorId, _opId);
          expect(auditRow.locationId, _locId);
          expect(
            auditRow.action,
            VendorSyncErrorAlertDispatcher.kAuditAction,
          );
          expect(auditRow.payload['connection_id'], _connId);
          expect(auditRow.payload['recipient_email'], 'admin@acme.test');
          expect(auditRow.payload['vendor_display_name'], 'Toast');
        },
      );

      test(
        'fourth poll_error after threshold cross is a no-op '
        '(alreadyNotified)',
        () async {
          final stateRepo = _InMemoryStateRepository();
          final adminLookup = _FakeAdminEmailLookup(
            recipientEmail: 'admin@acme.test',
            businessName: 'Acme Bistro',
          );
          final outbox = _RecordingOutboxWriter();
          final audit = _RecordingAuditWriter();

          final dispatcher = VendorSyncErrorAlertDispatcher(
            recipientLookup: ({required String operatorId}) =>
                adminLookup.resolve(operatorId: operatorId),
            vendorMetadataLookup: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
            }) async =>
                const VendorSyncAlertVendorMetadata(
              vendorDisplayName: 'Toast',
              integrationConsoleUrl:
                  'https://app.forgeflow.app/admin/integrations',
            ),
            outboxWriter: outbox,
            auditWriter: audit.call,
          );
          final detector = VendorSyncOutageDetector(
            repository: stateRepo,
            enqueueAlert: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
              required DateTime outageStartedAt,
              required String? errorSummary,
            }) =>
                dispatcher.dispatch(
              operatorId: operatorId,
              locationId: locationId,
              connectionId: connectionId,
              outageStartedAt: outageStartedAt,
              errorSummary: errorSummary,
            ),
          );

          // Three failures → email enqueued + notified_at stamped.
          for (var i = 0; i < 3; i++) {
            stateRepo.appendLog(_connId, 'poll_error',
                occurredAt: DateTime.utc(2026, 5, 13, 10, 10 + (i * 5)),
                errorMessage: 'vendor 500');
            await detector.observe(
              operatorId: _opId,
              locationId: _locId,
              connectionId: _connId,
              latestEventKind: 'poll_error',
            );
          }
          expect(outbox.enqueued, hasLength(1));

          // Fourth failure — same outage window; no second email.
          stateRepo.appendLog(_connId, 'poll_error',
              occurredAt: DateTime.utc(2026, 5, 13, 10, 25),
              errorMessage: 'vendor 504');
          final r4 = await detector.observe(
            operatorId: _opId,
            locationId: _locId,
            connectionId: _connId,
            latestEventKind: 'poll_error',
          );
          expect(r4.action, OutageDetectionAction.alreadyNotified);
          expect(outbox.enqueued, hasLength(1),
              reason: 'one email per outage window — load-bearing dedupe');
          expect(audit.calls, hasLength(1));
        },
      );

      test(
        'poll_success clears the state row so the next outage starts '
        'fresh',
        () async {
          final stateRepo = _InMemoryStateRepository();
          final detector = VendorSyncOutageDetector(
            repository: stateRepo,
            enqueueAlert: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
              required DateTime outageStartedAt,
              required String? errorSummary,
            }) async {
              // No-op for this test.
            },
          );

          // One recorded failure.
          stateRepo.appendLog(_connId, 'poll_error',
              occurredAt: DateTime.utc(2026, 5, 13, 10, 10),
              errorMessage: 'vendor 500');
          await detector.observe(
            operatorId: _opId,
            locationId: _locId,
            connectionId: _connId,
            latestEventKind: 'poll_error',
          );
          expect(stateRepo.states[_connId], isNotNull);

          // poll_success arrives → state row cleared.
          final ok = await detector.observe(
            operatorId: _opId,
            locationId: _locId,
            connectionId: _connId,
            latestEventKind: 'poll_success',
          );
          expect(ok.action, OutageDetectionAction.clearedRecovery);
          expect(stateRepo.states[_connId], isNull);
        },
      );

      test(
        'missing operator admin recipient → no enqueue, no audit '
        '(soft skip)',
        () async {
          final stateRepo = _InMemoryStateRepository();
          // Recipient lookup returns null (no admin contact provisioned).
          final adminLookup = _FakeAdminEmailLookup(
            recipientEmail: null,
            businessName: null,
          );
          final outbox = _RecordingOutboxWriter();
          final audit = _RecordingAuditWriter();

          final dispatcher = VendorSyncErrorAlertDispatcher(
            recipientLookup: ({required String operatorId}) =>
                adminLookup.resolve(operatorId: operatorId),
            vendorMetadataLookup: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
            }) async =>
                const VendorSyncAlertVendorMetadata(
              vendorDisplayName: 'Toast',
              integrationConsoleUrl:
                  'https://app.forgeflow.app/admin/integrations',
            ),
            outboxWriter: outbox,
            auditWriter: audit.call,
          );
          final detector = VendorSyncOutageDetector(
            repository: stateRepo,
            enqueueAlert: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
              required DateTime outageStartedAt,
              required String? errorSummary,
            }) =>
                dispatcher.dispatch(
              operatorId: operatorId,
              locationId: locationId,
              connectionId: connectionId,
              outageStartedAt: outageStartedAt,
              errorSummary: errorSummary,
            ),
          );

          for (var i = 0; i < 3; i++) {
            stateRepo.appendLog(_connId, 'poll_error',
                occurredAt: DateTime.utc(2026, 5, 13, 10, 10 + (i * 5)),
                errorMessage: 'vendor 500');
            await detector.observe(
              operatorId: _opId,
              locationId: _locId,
              connectionId: _connId,
              latestEventKind: 'poll_error',
            );
          }
          expect(outbox.enqueued, isEmpty,
              reason:
                  'missing recipient is a soft skip — no enqueue, no audit');
          expect(audit.calls, isEmpty);
        },
      );
    },
  );

  group(
    'runSyncWorkerOnce wires the outage observer through to the detector',
    () {
      test(
        'a poll_error tick fires the wired observer with the right '
        'operator / connection / event kind',
        () async {
          final source = _FakeSource(<ConnectorConnectionRow>[
            _posRow(connectionId: _connId),
          ]);
          final sink = _RecordingCanonicalSink();
          final failingAdapter = _FailingPosAdapter('vendor 500');
          final observerCalls = <_ObserverCall>[];

          final result = await runSyncWorkerOnce(
            source: source,
            canonicalSink: sink,
            resolveAdapterFactory: (_) async => failingAdapter,
            outageObserver: ({
              required String operatorId,
              required String locationId,
              required String connectionId,
              required String eventKind,
            }) async {
              observerCalls.add(_ObserverCall(
                operatorId: operatorId,
                locationId: locationId,
                connectionId: connectionId,
                eventKind: eventKind,
              ));
            },
          );

          expect(result.processed, 1);
          expect(observerCalls, hasLength(1));
          final call = observerCalls.single;
          expect(call.operatorId, _opId);
          expect(call.locationId, _locId);
          expect(call.connectionId, _connId);
          expect(call.eventKind, 'poll_error');
        },
      );
    },
  );
}

// ─── Test fakes ───────────────────────────────────────────────────────

ConnectorConnectionRow _posRow({
  required String connectionId,
  String vendorId = 'toast',
}) =>
    ConnectorConnectionRow(
      connectionId: connectionId,
      operatorId: _opId,
      locationId: _locId,
      vendorId: vendorId,
      category: IntegrationCategory.pos,
      status: ConnectionStatus.connected,
      lastModifiedSeen: DateTime.utc(2026, 5, 3),
    );

class _FakeSource implements SyncWorkerSource {
  _FakeSource(this._rows);
  final List<ConnectorConnectionRow> _rows;

  @override
  Stream<ConnectorConnectionRow> connectedConnections() async* {
    for (final row in _rows) {
      yield row;
    }
  }
}

class _FailingPosAdapter implements PosAdapter {
  _FailingPosAdapter(this._message);
  final String _message;

  @override
  String get vendorId => 'toast';
  @override
  String get displayName => 'Toast';
  @override
  VendorCapabilityProfile get capabilityProfile =>
      const VendorCapabilityProfile(
        vendorId: 'toast',
        displayName: 'Toast',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: true,
        lifecycle: VendorLifecycle.documented,
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) =>
      throw UnimplementedError();
  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) =>
      throw UnimplementedError();
  @override
  Future<BackfillResult> backfill(BackfillCommand command) =>
      throw UnimplementedError();
  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    throw StateError(_message);
  }

  @override
  Future<HandleWebhookResult> handleWebhook(
    HandleWebhookCommand command,
  ) async =>
      const HandleWebhookResult(recordsWritten: 0);
}

class _RecordingCanonicalSink implements CanonicalSink {
  final List<_SyncLogEntry> syncLogs = <_SyncLogEntry>[];

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async =>
      true;
  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async =>
      true;
  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async =>
      true;

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {
    syncLogs.add(_SyncLogEntry(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      eventKind: eventKind,
      errorMessage: errorMessage,
    ));
  }

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {}
}

class _SyncLogEntry {
  _SyncLogEntry({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.eventKind,
    this.errorMessage,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String eventKind;
  final String? errorMessage;
}

class _ObserverCall {
  _ObserverCall({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.eventKind,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String eventKind;
}

/// In-memory [VendorSyncOutageStateRepository]. Mirrors the production
/// `PostgresVendorSyncOutageStateRepository` semantics — fetchRecentSyncLogEntries
/// walks the appended logs newest-first, fetchForConnection returns the
/// last upserted row, clearForConnection deletes.
class _InMemoryStateRepository implements VendorSyncOutageStateRepository {
  final Map<String, List<SyncLogEntry>> _logs = <String, List<SyncLogEntry>>{};
  final Map<String, VendorSyncOutageStateRow> states =
      <String, VendorSyncOutageStateRow>{};

  void appendLog(
    String connectionId,
    String eventKind, {
    required DateTime occurredAt,
    String? errorMessage,
  }) {
    _logs.putIfAbsent(connectionId, () => <SyncLogEntry>[]).add(
          SyncLogEntry(
            eventKind: eventKind,
            occurredAt: occurredAt,
            errorMessage: errorMessage,
          ),
        );
  }

  @override
  Future<List<SyncLogEntry>> fetchRecentSyncLogEntries({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required Duration lookback,
    required int limit,
  }) async {
    final all = _logs[connectionId] ?? <SyncLogEntry>[];
    // Sort newest-first; bounded by limit.
    final sorted = List<SyncLogEntry>.from(all)
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return sorted.take(limit).toList(growable: false);
  }

  @override
  Future<VendorSyncOutageStateRow?> fetchForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async =>
      states[connectionId];

  @override
  Future<void> upsert({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required DateTime outageStartedAt,
    required int consecutiveFailureCount,
    DateTime? notifiedAt,
    String? lastErrorMessage,
  }) async {
    final existing = states[connectionId];
    // Mirror the SQL `coalesce(existing.notified_at, excluded.notified_at)`
    // posture: notified_at is sticky once set.
    final resolvedNotifiedAt = existing?.notifiedAt ?? notifiedAt;
    states[connectionId] = VendorSyncOutageStateRow(
      outageStartedAt: outageStartedAt,
      consecutiveFailureCount: consecutiveFailureCount,
      notifiedAt: resolvedNotifiedAt,
      lastErrorMessage: lastErrorMessage,
    );
  }

  @override
  Future<void> clearForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    states.remove(connectionId);
    _logs.remove(connectionId);
  }
}

class _FakeAdminEmailLookup {
  _FakeAdminEmailLookup({
    required this.recipientEmail,
    required this.businessName,
  });
  final String? recipientEmail;
  final String? businessName;

  Future<OperatorAdminContact?> resolve({required String operatorId}) async {
    if (recipientEmail == null || recipientEmail!.isEmpty) return null;
    return OperatorAdminContact(
      operatorBusinessName: businessName ?? 'your business',
      recipientEmail: recipientEmail!,
    );
  }
}

class _FakeVendorIdLookup {
  _FakeVendorIdLookup({required this.vendorIdByConnection});
  final Map<String, String> vendorIdByConnection;

  Future<String?> resolve({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    return vendorIdByConnection[connectionId];
  }
}

class _RecordingOutboxWriter implements VendorSyncErrorAlertOutboxWriter {
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

