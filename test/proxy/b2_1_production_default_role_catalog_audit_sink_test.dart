// Lane B B2.1 — production default Role catalog audit sink tests.
//
// Pins the contract for [ProductionDefaultRoleCatalogAuditSink]:
//   * `recordPublished` writes one `auth.default_role_catalog.published`
//     row through the admin-pool [AuthEventsAuditRepository]
//     `insertSystemEvent` API — which itself fans out into the
//     hash-chained `public.audit_logs` table per
//     `audit_logs_cutover_enabled`.
//   * `actor_kind = 'forge_admin'` (mirrors the B1.b / B1.c idiom; the
//     2026-05-13 `admin_audit_log_actor_reason_contract` migration
//     permits this value and pairs it with the mandatory
//     `admin_reason`).
//   * Payload carries the slice-spec fields: `version_id`,
//     `version_number`, `payload_sha256`, `published_by_user_id`,
//     `blast_radius_operator_count`, optional `notes`, `occurred_at`.
//   * `target_kind = 'default_role_catalog_version'`,
//     `target_id = versionId`.
//   * No UPDATE on `audit_logs` (the lint enforces this for the
//     repository; the sink only INSERTs via `insertSystemEvent`).
//   * Audit-write failures are swallowed and surfaced via the
//     caller-supplied `onError` hook, matching the
//     `ProductionHandoffAuditSink` / `_ProductionWageRoleRowsAuditSink`
//     discipline (a downstream observability outage MUST NOT 5xx a
//     successful publish whose catalog row already committed).
//
// Authority:
//   * tool/advisor_proxy/admin_default_role_catalog_routes.dart
//   * docs/_execution/lane_b_features/03_execution_slices.md (B2.1)

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kVersionId = '11111111-1111-4111-8111-111111111111';
const int _kVersionNumber = 7;
const String _kPayloadSha256 =
    'abc1230000000000000000000000000000000000000000000000000000000000';
const String _kPublishedByUserId = '22222222-2222-4222-8222-222222222222';
const String _kNotes = 'rollout of manager role rename';
final DateTime _kOccurredAt = DateTime.utc(2026, 5, 13, 10, 30);

void main() {
  group('ProductionDefaultRoleCatalogAuditSink.recordPublished', () {
    test(
      'writes one auth.default_role_catalog.published row with '
      'actor_kind=forge_admin and the slice-spec payload',
      () async {
        final audit = _RecordingSystemAuditRepository();
        final sink = ProductionDefaultRoleCatalogAuditSink(
          auditRepository: audit,
        );

        await sink.recordPublished(
          versionId: _kVersionId,
          versionNumber: _kVersionNumber,
          payloadSha256: _kPayloadSha256,
          publishedByUserId: _kPublishedByUserId,
          blastRadiusOperatorCount: 12,
          notes: _kNotes,
          occurredAt: _kOccurredAt,
        );

        expect(audit.events, hasLength(1));
        final event = audit.events.single;
        expect(
          event.eventType,
          equals('auth.default_role_catalog.published'),
        );
        expect(event.actorKind, equals('forge_admin'));
        expect(event.actorUserId, equals(_kPublishedByUserId));
        expect(event.targetKind, equals('default_role_catalog_version'));
        expect(event.targetId, equals(_kVersionId));
        expect(
          event.adminReason,
          equals(
            'auth.default_role_catalog.publish:version_$_kVersionNumber',
          ),
        );
        expect(event.payload['version_id'], equals(_kVersionId));
        expect(event.payload['version_number'], equals(_kVersionNumber));
        expect(event.payload['payload_sha256'], equals(_kPayloadSha256));
        expect(
          event.payload['published_by_user_id'],
          equals(_kPublishedByUserId),
        );
        expect(event.payload['blast_radius_operator_count'], equals(12));
        expect(event.payload['notes'], equals(_kNotes));
        expect(
          event.payload['occurred_at'],
          equals(_kOccurredAt.toIso8601String()),
        );
      },
    );

    test(
      'omits notes from the audit payload entirely when null',
      () async {
        final audit = _RecordingSystemAuditRepository();
        final sink = ProductionDefaultRoleCatalogAuditSink(
          auditRepository: audit,
        );

        await sink.recordPublished(
          versionId: _kVersionId,
          versionNumber: _kVersionNumber,
          payloadSha256: _kPayloadSha256,
          publishedByUserId: _kPublishedByUserId,
          blastRadiusOperatorCount: 0,
          notes: null,
          occurredAt: _kOccurredAt,
        );

        expect(audit.events, hasLength(1));
        expect(audit.events.single.payload.containsKey('notes'), isFalse);
        // Genesis publish: zero blast radius is still recorded.
        expect(
          audit.events.single.payload['blast_radius_operator_count'],
          equals(0),
        );
      },
    );

    test(
      'normalises occurred_at to UTC before stamping the payload',
      () async {
        final audit = _RecordingSystemAuditRepository();
        final sink = ProductionDefaultRoleCatalogAuditSink(
          auditRepository: audit,
        );

        // Pass a wall-clock local DateTime; the sink must convert to UTC
        // so the audit row is consistent regardless of the proxy host
        // timezone. The Cloud Run runtime is UTC, but unit tests run on
        // dev machines that may not be.
        final local = DateTime(2026, 5, 13, 12, 0);
        await sink.recordPublished(
          versionId: _kVersionId,
          versionNumber: 1,
          payloadSha256: _kPayloadSha256,
          publishedByUserId: _kPublishedByUserId,
          blastRadiusOperatorCount: 0,
          notes: null,
          occurredAt: local,
        );

        final stamped = audit.events.single.payload['occurred_at'] as String;
        expect(stamped, endsWith('Z'));
        expect(DateTime.parse(stamped).isUtc, isTrue);
      },
    );

    test(
      'swallows audit-write failures and forwards them to the onError '
      'hook so a successful publish never 5xxs on observability errors',
      () async {
        final audit = _ThrowingSystemAuditRepository();
        Object? capturedError;
        StackTrace? capturedStack;
        final sink = ProductionDefaultRoleCatalogAuditSink(
          auditRepository: audit,
          onError: (error, stackTrace) {
            capturedError = error;
            capturedStack = stackTrace;
          },
        );

        // No throw — same posture as ProductionHandoffAuditSink.
        await sink.recordPublished(
          versionId: _kVersionId,
          versionNumber: _kVersionNumber,
          payloadSha256: _kPayloadSha256,
          publishedByUserId: _kPublishedByUserId,
          blastRadiusOperatorCount: 0,
          notes: null,
          occurredAt: _kOccurredAt,
        );

        expect(capturedError, isA<StateError>());
        expect(capturedStack, isNotNull);
      },
    );

    test(
      'static event_type + target_kind constants pin the slice-spec '
      'wording so future renames break this test loudly',
      () {
        expect(
          ProductionDefaultRoleCatalogAuditSink.kEventType,
          equals('auth.default_role_catalog.published'),
        );
        expect(
          ProductionDefaultRoleCatalogAuditSink.kTargetKind,
          equals('default_role_catalog_version'),
        );
      },
    );
  });
}

// ─── Recording fakes ─────────────────────────────────────────────────────────

class _RecordedSystemEvent {
  _RecordedSystemEvent({
    required this.eventType,
    required this.actorKind,
    required this.actorUserId,
    required this.targetKind,
    required this.targetId,
    required this.payload,
    required this.adminReason,
  });

  final String eventType;
  final String actorKind;
  final String? actorUserId;
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
