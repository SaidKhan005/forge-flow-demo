// Wave 2 Q-1-FU-sink — production heap-snapshot capture audit sink
// tests.
//
// Pins the contract for [ProductionHeapSnapshotCaptureAuditSink]:
//   * `record` writes one event through the admin-pool
//     [AuthEventsAuditRepository] `insertSystemEvent` API — which
//     itself fans out into the hash-chained `public.audit_logs` table
//     per `audit_logs_cutover_enabled` and the operator-id-present
//     gate. The heap-snapshot surface has NO operator scope (HP #4
//     platform diagnostic), so the chain write is omitted by the
//     same gate every other no-operator F&F-internal event hits;
//     this test pins the `auth_events_audit` write shape.
//   * Actor mapping:
//     - bearer-token `actor_kind = 'user'` is remapped to
//       canonical `'forge_admin'` so the audit_logs_actor_shape_check
//       constraint accepts the row (matches B2.1 catalog publish
//       posture).
//     - `actor_kind = 'service_principal'` lands as-is with the
//       actor_user_id routed to `actor_service_principal_id`.
//   * Payload carries Q-1-FU's spec fields (pod_id, pod_hostname,
//     snapshot_bytes, blob_url, capture_timestamp, outcome) plus the
//     sink-injected `event_kind` + `occurred_at` markers.
//   * `admin_reason` is set so the (future / operator-scoped) chain
//     fan-out's forge_admin admin_reason requirement is satisfied;
//     value pins the pod_id.
//   * Audit-write failures are swallowed and forwarded to the
//     `onError` hook, matching the ProductionHandoffAuditSink /
//     _ProductionWageRoleRowsAuditSink / ProductionDefaultRoleCatalogAuditSink
//     discipline (a downstream observability outage MUST NOT 5xx a
//     successful capture whose blob upload already committed).
//   * Pod-rate warn events (`admin.heap_snapshot.pod_rate_high`)
//     flow through the same sink path so the support-side log keeps
//     one entry per heuristic breach.
//
// Authority:
//   * tool/advisor_proxy/proxy_bootstrap.dart
//   * tool/advisor_proxy/heap_snapshot_capture_routes.dart
//   * Q-1-FU PR #723 (router shape).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart';

const String _kPodId = 'soak-pod-1';
const String _kPodHostname = 'soak-runner-1.cluster.local';
const String _kBlobUrl =
    'https://example.blob.core.windows.net/soak-snapshots/heap-snapshots/test/'
    'soak-pod-1/heap-2026_05_14T12_00_00_000Z.heapsnapshot';
const int _kSnapshotBytes = 12345;
final DateTime _kCaptureTimestamp = DateTime.utc(2026, 5, 14, 12);
final DateTime _kOccurredAt = DateTime.utc(2026, 5, 14, 12, 0, 1);

void main() {
  group('ProductionHeapSnapshotCaptureAuditSink.record (capture)', () {
    test(
      'writes one admin.heap_snapshot_captured row with '
      'actor_kind=forge_admin, target_kind=heap_snapshot_capture, and '
      'the spec payload',
      () async {
        final audit = _RecordingSystemAuditRepository();
        final sink = ProductionHeapSnapshotCaptureAuditSink(
          auditRepository: audit,
        );

        await sink.record(
          eventKind: 'admin.heap_snapshot_captured',
          actorUserId: '22222222-2222-4222-8222-222222222222',
          actorKind: 'user',
          occurredAt: _kOccurredAt,
          payload: <String, Object?>{
            'outcome': 'ok',
            'pod_id': _kPodId,
            'pod_hostname': _kPodHostname,
            'snapshot_bytes': _kSnapshotBytes,
            'blob_url': _kBlobUrl,
            'capture_timestamp':
                _kCaptureTimestamp.toUtc().toIso8601String(),
          },
        );

        expect(audit.events, hasLength(1));
        final event = audit.events.single;
        expect(event.eventType, equals('admin.heap_snapshot_captured'));
        // Bearer-token 'user' actor remapped to canonical 'forge_admin'
        // for the chain write (no operator scope; matches the B2.1
        // default-role-catalog publish posture).
        expect(event.actorKind, equals('forge_admin'));
        expect(
          event.actorUserId,
          equals('22222222-2222-4222-8222-222222222222'),
        );
        expect(event.actorServicePrincipalId, isNull);
        expect(
          event.targetKind,
          equals(ProductionHeapSnapshotCaptureAuditSink.kTargetKind),
        );
        expect(event.targetKind, equals('heap_snapshot_capture'));
        // target_id pins the platform-diagnostic pod identifier.
        expect(event.targetId, equals(_kPodId));
        // adminReason carries the pod_id so the chain row's
        // forge_admin admin_reason requirement is satisfied when an
        // operator scope ever attaches.
        expect(
          event.adminReason,
          equals('admin.heap_snapshot_capture:$_kPodId'),
        );
        // operator scope is intentionally null — HP #4 platform
        // diagnostic. `_fanOutToAuditLogs` skips the chain write
        // under this gate; the auth_events_audit row persists.
        expect(event.operatorId, isNull);
        expect(event.locationId, isNull);

        // Payload preserves Q-1-FU's spec fields verbatim and adds
        // the sink-injected event_kind + occurred_at markers.
        expect(event.payload['outcome'], equals('ok'));
        expect(event.payload['pod_id'], equals(_kPodId));
        expect(event.payload['pod_hostname'], equals(_kPodHostname));
        expect(event.payload['snapshot_bytes'], equals(_kSnapshotBytes));
        expect(event.payload['blob_url'], equals(_kBlobUrl));
        expect(
          event.payload['capture_timestamp'],
          equals(_kCaptureTimestamp.toUtc().toIso8601String()),
        );
        expect(
          event.payload['event_kind'],
          equals('admin.heap_snapshot_captured'),
        );
        expect(
          event.payload['occurred_at'],
          equals(_kOccurredAt.toUtc().toIso8601String()),
        );
      },
    );

    test(
      'service_principal actor lands as actor_service_principal_id; '
      'actor_user_id is null so the audit_logs_actor_shape_check holds',
      () async {
        final audit = _RecordingSystemAuditRepository();
        final sink = ProductionHeapSnapshotCaptureAuditSink(
          auditRepository: audit,
        );

        await sink.record(
          eventKind: 'admin.heap_snapshot_captured',
          actorUserId: 'sp-deadbeef',
          actorKind: 'service_principal',
          occurredAt: _kOccurredAt,
          payload: <String, Object?>{
            'outcome': 'ok',
            'pod_id': _kPodId,
            'pod_hostname': _kPodHostname,
            'snapshot_bytes': _kSnapshotBytes,
            'blob_url': _kBlobUrl,
            'capture_timestamp':
                _kCaptureTimestamp.toUtc().toIso8601String(),
          },
        );

        expect(audit.events, hasLength(1));
        final event = audit.events.single;
        expect(event.actorKind, equals('service_principal'));
        expect(event.actorUserId, isNull);
        expect(event.actorServicePrincipalId, equals('sp-deadbeef'));
      },
    );

    test(
      'azure_blob_write_failed outcome still records one row (the '
      'capture failed but the audit row preserves the diagnostic '
      'trace from Q-1-FU)',
      () async {
        final audit = _RecordingSystemAuditRepository();
        final sink = ProductionHeapSnapshotCaptureAuditSink(
          auditRepository: audit,
        );

        await sink.record(
          eventKind: 'admin.heap_snapshot_captured',
          actorUserId: '22222222-2222-4222-8222-222222222222',
          actorKind: 'user',
          occurredAt: _kOccurredAt,
          payload: <String, Object?>{
            'outcome': 'failed',
            'pod_id': _kPodId,
            'pod_hostname': _kPodHostname,
            'snapshot_bytes': _kSnapshotBytes,
            'advisory_snapshot_bytes': _kSnapshotBytes,
            'capture_timestamp':
                _kCaptureTimestamp.toUtc().toIso8601String(),
            'error_kind': 'azure_blob_write_failed',
          },
        );

        expect(audit.events, hasLength(1));
        final event = audit.events.single;
        expect(event.payload['outcome'], equals('failed'));
        expect(
          event.payload['error_kind'],
          equals('azure_blob_write_failed'),
        );
      },
    );
  });

  group(
    'ProductionHeapSnapshotCaptureAuditSink.record (pod_rate_high)',
    () {
      test(
        'writes one admin.heap_snapshot.pod_rate_high row through the '
        'same sink path as the capture event',
        () async {
          final audit = _RecordingSystemAuditRepository();
          final sink = ProductionHeapSnapshotCaptureAuditSink(
            auditRepository: audit,
          );

          await sink.record(
            eventKind: 'admin.heap_snapshot.pod_rate_high',
            actorUserId: '22222222-2222-4222-8222-222222222222',
            actorKind: 'user',
            occurredAt: _kOccurredAt,
            payload: <String, Object?>{
              'pod_id': _kPodId,
              'pod_hostname': _kPodHostname,
              'captures_in_window': 13,
              'window_minutes': 60,
              'threshold': 12,
            },
          );

          expect(audit.events, hasLength(1));
          final event = audit.events.single;
          expect(
            event.eventType,
            equals('admin.heap_snapshot.pod_rate_high'),
          );
          expect(event.actorKind, equals('forge_admin'));
          expect(event.targetId, equals(_kPodId));
          expect(event.payload['captures_in_window'], equals(13));
          expect(event.payload['threshold'], equals(12));
        },
      );
    },
  );

  group(
    'ProductionHeapSnapshotCaptureAuditSink.record (failure handling)',
    () {
      test(
        'swallows audit-write failures and forwards them to the '
        'onError hook so a successful capture never 5xxs on '
        'observability errors',
        () async {
          final audit = _ThrowingSystemAuditRepository();
          Object? capturedError;
          StackTrace? capturedStack;
          final sink = ProductionHeapSnapshotCaptureAuditSink(
            auditRepository: audit,
            onError: (error, stackTrace) {
              capturedError = error;
              capturedStack = stackTrace;
            },
          );

          // No throw — same posture as ProductionHandoffAuditSink /
          // ProductionDefaultRoleCatalogAuditSink.
          await sink.record(
            eventKind: 'admin.heap_snapshot_captured',
            actorUserId: '22222222-2222-4222-8222-222222222222',
            actorKind: 'user',
            occurredAt: _kOccurredAt,
            payload: <String, Object?>{
              'pod_id': _kPodId,
              'pod_hostname': _kPodHostname,
              'snapshot_bytes': _kSnapshotBytes,
              'blob_url': _kBlobUrl,
              'capture_timestamp':
                  _kCaptureTimestamp.toUtc().toIso8601String(),
              'outcome': 'ok',
            },
          );

          expect(capturedError, isA<StateError>());
          expect(capturedStack, isNotNull);
        },
      );

      test(
        'omitted onError hook also swallows failures — the call '
        'returns without throwing',
        () async {
          final audit = _ThrowingSystemAuditRepository();
          final sink = ProductionHeapSnapshotCaptureAuditSink(
            auditRepository: audit,
          );

          // No throw expected.
          await sink.record(
            eventKind: 'admin.heap_snapshot_captured',
            actorUserId: '22222222-2222-4222-8222-222222222222',
            actorKind: 'user',
            occurredAt: _kOccurredAt,
            payload: <String, Object?>{
              'pod_id': _kPodId,
              'pod_hostname': _kPodHostname,
              'snapshot_bytes': _kSnapshotBytes,
              'blob_url': _kBlobUrl,
              'capture_timestamp':
                  _kCaptureTimestamp.toUtc().toIso8601String(),
              'outcome': 'ok',
            },
          );
        },
      );

      test(
        'missing pod_id in payload falls back to unknown_pod in the '
        'admin_reason so the row still satisfies the forge_admin '
        'non-empty admin_reason gate',
        () async {
          final audit = _RecordingSystemAuditRepository();
          final sink = ProductionHeapSnapshotCaptureAuditSink(
            auditRepository: audit,
          );

          await sink.record(
            eventKind: 'admin.heap_snapshot_captured',
            actorUserId: '22222222-2222-4222-8222-222222222222',
            actorKind: 'user',
            occurredAt: _kOccurredAt,
            payload: const <String, Object?>{
              'outcome': 'ok',
            },
          );

          expect(audit.events, hasLength(1));
          final event = audit.events.single;
          expect(event.targetId, isNull);
          expect(
            event.adminReason,
            equals('admin.heap_snapshot_capture:unknown_pod'),
          );
        },
      );
    },
  );

  group('ProductionHeapSnapshotCaptureAuditSink constants', () {
    test('kTargetKind pins the canonical heap_snapshot_capture value', () {
      expect(
        ProductionHeapSnapshotCaptureAuditSink.kTargetKind,
        equals('heap_snapshot_capture'),
      );
    });
  });
}

// ─── Recording fakes ─────────────────────────────────────────────────────────

class _RecordedSystemEvent {
  _RecordedSystemEvent({
    required this.eventType,
    required this.actorKind,
    required this.actorUserId,
    required this.actorServicePrincipalId,
    required this.operatorId,
    required this.locationId,
    required this.targetKind,
    required this.targetId,
    required this.payload,
    required this.adminReason,
  });

  final String eventType;
  final String actorKind;
  final String? actorUserId;
  final String? actorServicePrincipalId;
  final String? operatorId;
  final String? locationId;
  final String? targetKind;
  final String? targetId;
  final Map<String, Object?> payload;
  final String adminReason;
}

class _RecordingSystemAuditRepository extends AuthEventsAuditRepository {
  _RecordingSystemAuditRepository() : super(_unusedWrapper);

  final List<_RecordedSystemEvent> events = <_RecordedSystemEvent>[];

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    events.add(
      _RecordedSystemEvent(
        eventType: eventType,
        actorKind: actorKind,
        actorUserId: actorUserId,
        actorServicePrincipalId: actorServicePrincipalId,
        operatorId: operatorId,
        locationId: locationId,
        targetKind: targetKind,
        targetId: targetId,
        payload: Map<String, Object?>.from(payload),
        adminReason: adminReason,
      ),
    );
    return 'event-${events.length}';
  }
}

class _ThrowingSystemAuditRepository extends AuthEventsAuditRepository {
  _ThrowingSystemAuditRepository() : super(_unusedWrapper);

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    throw StateError(
      'audit pipeline unavailable (simulated downstream outage)',
    );
  }
}

final TenantTransactionWrapper _unusedWrapper =
    TenantTransactionWrapper(_NoopPool());

class _NoopPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnsupportedError(
      'recording sink tests must not open a Postgres transaction',
    );
  }
}
