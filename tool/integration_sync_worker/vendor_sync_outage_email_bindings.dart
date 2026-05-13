// Lane C C-2-D production binding — Postgres-backed seams for
// `VendorSyncOutageDetector` + `VendorSyncErrorAlertDispatcher`.
//
// C-2-D (PR #631) shipped the detector, dispatcher, repository, and
// migration but deliberately deferred the production runtime binding.
// The `runSyncWorkerOnce(... outageObserver: ...)` parameter defaults
// to null, so in production the email path is unreachable until a
// follow-up wires the dispatcher through `buildWorkerRuntime`. This
// file is that follow-up.
//
// Shape: mirrors `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart`
// (the C-2-F production binding precedent, PR #628):
//
//   * `PostgresVendorSyncOutageAdminEmailLookup` — cross-tenant
//     `withSystem` read on `public.operators.owner_email + business_name`.
//     Mirrors `PostgresAutoDisabledRecipientResolver`.
//   * `PostgresVendorSyncErrorAlertOutboxWriter` — per-tenant `withTenant`
//     INSERT into `public.email_outbox`. Mirrors the OAuth refresh
//     worker's `PostgresAutoDisabledEmailEnqueueRepository` but splits
//     the audit row write into the separate `auditWriter` seam the
//     C-2-D dispatcher already exposes (so the dispatcher remains the
//     orchestrator of "email + audit together").
//   * `PostgresVendorSyncErrorAlertAuditWriter` — per-tenant `withTenant`
//     `AuditLogsRepository.writeRow` invocation with `actor_kind =
//     'service'` and `actor_principal_id =
//     kIntegrationSyncWorkerServicePrincipalId`.
//   * `buildVendorSyncOutageObserver` — composes all of the above into
//     a `VendorSyncOutageObserver` closure suitable for passing to
//     `runSyncWorkerOnce` and `IntegrationSyncWorkerLoop`.
//   * Vendor metadata lookup — reads `public.connector_connection` by
//     `(operator_id, location_id, connection_id)` for the `vendor_id`,
//     then resolves the display name via
//     `lookupVendorCapability(vendorId).displayName` (the same vendor
//     catalog the proxy's lifecycle fan-out uses; importing it from the
//     worker is fine because the worker already imports the broader
//     `tool/advisor_proxy/phase_8_vendor_integration_factories.dart`).
//   * `defaultVendorSyncIntegrationConsoleUrl` — the operator-web
//     deeplink template. Production points operators at the platform-
//     wide Connected services admin URL (mirrors the OAuth refresh
//     worker's `defaultAutoDisabledConsoleUrl` posture — security-
//     adjacent emails point at the canonical Connected services card,
//     not at a per-location deeplink that hierarchy scopes may not
//     grant the primary admin).
//
// Tenant isolation:
//   * Recipient lookup is cross-tenant (the polling worker walks
//     `connector_connection` across all operators), so the resolver
//     uses `withSystem` with the constant reason
//     `'integration_sync_worker.outage_alert_recipient_lookup'`.
//   * Email outbox INSERT + audit row INSERT use `withTenant`, so
//     `SET LOCAL app.operator_id / location_id` engages the per-tenant
//     RLS index on `email_outbox` and the `audit_logs_actor_shape_check`
//     constraint.
//
// Failure posture:
//   * The observer is best-effort. The polling tick has already
//     committed the `connector_sync_log` row before the observer runs;
//     any error inside the detector / dispatcher / Postgres path is
//     swallowed by `_CountingCanonicalSink` (the existing observer
//     try/catch in `main.dart`) so a flaky email path never poisons
//     the polling-tier write. Telemetry log lines (see
//     `_logVendorSyncObserverEvent`) record the dispatch outcome per
//     observation.
//
// CLAUDE.md alignment:
//   * Hard Promise #4 (per-operator isolation): cross-tenant operator
//     lookup uses `withSystem` with an explicit reason string; per-tenant
//     writes use `withTenant`.
//   * Hard Promise #6 (Advisor recommends, never acts): the outage
//     email is an operator-courtesy alert; it does not act on the
//     operator's behalf.
//   * Proxy & API Conventions: audit row uses
//     `actor_kind = 'service'` + `actor_principal_id =
//     kIntegrationSyncWorkerServicePrincipalId` ('sp:'-prefixed JWT
//     posture). Audit attribution is never NULL.
//   * Banned items: no `tool/advisor_proxy/advisor_proxy.dart` touch,
//     no `lib/auth/**` touch, no `db/migrations/**` touch (table
//     already exists from C-2-D), no `pubspec.yaml` touch.

import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/vendor_sync_outage_state_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/email/vendor_sync_error_alert_dispatcher.dart';
import 'package:forge_and_flow/services/vendor_sync/vendor_sync_outage_detector.dart';

import '../advisor_proxy/vendor_capability_index.dart' show lookupVendorCapability;
import 'main.dart' show VendorSyncOutageObserver;

/// Audit attribution for every row this binding writes. Same `sp:`
/// prefix posture the OAuth refresh worker uses. Stable string so a
/// post-incident review can correlate the email_outbox INSERT, the
/// audit_logs row, and the `connector_sync_log` row that triggered
/// the detector.
const String kIntegrationSyncWorkerServicePrincipalId =
    'sp:integration_sync_worker';

/// Default operator-web deeplink for the `{{integrationConsoleUrl}}`
/// template variable. Mirrors `defaultAutoDisabledConsoleUrl` in the
/// OAuth refresh worker — outage emails are security-adjacent system
/// notices and point at the platform-wide Connected services card
/// rather than at a per-location deeplink that hierarchy scopes may
/// not grant the primary admin.
String defaultVendorSyncIntegrationConsoleUrl({
  required String operatorId,
  required String locationId,
  required String connectionId,
  required String vendorId,
}) {
  return 'https://app.forgeflow.app/admin/integrations';
}

/// Builder seam over the operator-web deeplink so tests can pin a
/// fixed URL.
typedef VendorSyncIntegrationConsoleUrlBuilder = String Function({
  required String operatorId,
  required String locationId,
  required String connectionId,
  required String vendorId,
});

/// Vendor-id resolver: reads `public.connector_connection` by
/// `(operator_id, location_id, connection_id)` to get the `vendor_id`.
/// Production binds this to a Postgres-backed lookup; tests pin a
/// fixed map. Returns `null` when the row has been deleted between
/// the polling write and the observer firing (rare — same transaction
/// race the OAuth refresh worker's resolver tolerates).
typedef VendorSyncOutageVendorIdLookup = Future<String?> Function({
  required String operatorId,
  required String locationId,
  required String connectionId,
});

/// Postgres-backed [VendorSyncOutageVendorIdLookup]. Reads
/// `connector_connection.vendor_id` inside the per-tenant transaction
/// (RLS engaged) so the lookup matches the tenant scope the observer
/// is running under.
class PostgresVendorSyncOutageVendorIdLookup
    extends OperatorScopedRepository {
  PostgresVendorSyncOutageVendorIdLookup({
    required TenantTransactionWrapper tenantWrapper,
  }) : super(tenantWrapper);

  Future<String?> resolve({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select vendor_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        'and connection_id = @connection_id::uuid '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'connection_id': connectionId,
        },
      );
      if (rows.isEmpty) return null;
      final vendorId = rows.single['vendor_id'];
      if (vendorId is! String || vendorId.isEmpty) return null;
      return vendorId;
    });
  }
}

/// Cross-tenant operator-admin lookup. The recurring polling worker
/// walks `connector_connection` across all operators, so the recipient
/// lookup is cross-tenant scope work and rides `withSystem` (same
/// posture as `PostgresAutoDisabledRecipientResolver` in the OAuth
/// refresh worker).
class PostgresVendorSyncOutageAdminEmailLookup
    extends OperatorScopedRepository {
  PostgresVendorSyncOutageAdminEmailLookup({
    required TenantTransactionWrapper tenantWrapper,
  }) : super(tenantWrapper);

  /// Stable reason string for `withSystem`. Log search uses this to
  /// correlate the cross-tenant `operators` read with the detector
  /// trigger.
  static const String kLookupReason =
      'integration_sync_worker.outage_alert_recipient_lookup';

  Future<OperatorAdminContact?> resolve({
    required String operatorId,
  }) {
    return withSystem<OperatorAdminContact?>(
      (exec) async {
        final rows = await exec.query(
          'select owner_email, business_name '
          'from public.operators '
          'where operator_id = @operator_id::uuid '
          'limit 1',
          parameters: <String, Object?>{
            'operator_id': operatorId,
          },
        );
        if (rows.isEmpty) return null;
        final ownerEmail = rows.single['owner_email'];
        final businessName = rows.single['business_name'];
        if (ownerEmail is! String || ownerEmail.isEmpty) return null;
        final resolvedBusinessName =
            (businessName is String && businessName.isNotEmpty)
                ? businessName
                : 'your business';
        return OperatorAdminContact(
          operatorBusinessName: resolvedBusinessName,
          recipientEmail: ownerEmail,
          // `operators` does not carry a separate admin display name
          // column at this layer; the dispatcher falls back to the
          // email local-part for the salutation (same posture the
          // OAuth refresh worker's auto-disabled email uses).
        );
      },
      reason: kLookupReason,
    );
  }
}

/// Postgres-backed [VendorSyncErrorAlertOutboxWriter]. Inserts one
/// `public.email_outbox` row inside the caller-supplied tenant
/// transaction so the email enqueue rides on the same `SET LOCAL
/// app.operator_id / location_id` the detector's state-row write
/// already established.
class PostgresVendorSyncErrorAlertOutboxWriter
    extends OperatorScopedRepository
    implements VendorSyncErrorAlertOutboxWriter {
  PostgresVendorSyncErrorAlertOutboxWriter({
    required TenantTransactionWrapper tenantWrapper,
    required String locationId,
  })  : _locationId = locationId,
        super(tenantWrapper);

  /// Captured at construction time so the writer can engage RLS via
  /// `withTenant`. The detector observer feeds one writer instance
  /// per observation (constructed inside the observer closure with
  /// the current `(operatorId, locationId)`); the dispatcher's
  /// `enqueue` method does not carry `locationId` because the
  /// abstract seam is connection-agnostic.
  final String _locationId;

  @override
  Future<void> enqueue({
    required String operatorId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required String templateId,
    required Map<String, String> templateData,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: _locationId,
      userId: null,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.email_outbox ('
        '  operator_id, recipient_email, recipient_display_name, '
        '  template_id, template_data, scheduled_for, status, '
        '  attempt_count'
        ') values ('
        '  @operator_id::uuid, @recipient_email, @recipient_display_name, '
        '  @template_id, @template_data::jsonb, now(), '
        "  'pending', 0"
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'recipient_email': recipientEmail,
          'recipient_display_name': recipientDisplayName,
          'template_id': templateId,
          'template_data': jsonEncode(templateData),
        },
      );
    });
  }
}

/// Postgres-backed audit writer. Rides `withTenant` so the audit row
/// commits inside the same per-tenant transaction the email enqueue
/// established — `audit_logs.writeRow` would otherwise refuse the
/// row via its `_assertTenantContextMatches` guard. Records
/// `actor_kind = 'service'` + `actor_principal_id =
/// kIntegrationSyncWorkerServicePrincipalId`.
class PostgresVendorSyncErrorAlertAuditWriter
    extends OperatorScopedRepository {
  PostgresVendorSyncErrorAlertAuditWriter({
    required TenantTransactionWrapper tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
  })  : _audit = auditLogsRepository,
        super(tenantWrapper);

  final AuditLogsRepository _audit;

  /// Closure adapter matching the dispatcher's
  /// [VendorSyncErrorAlertAuditWriter] typedef.
  Future<void> write({
    required String operatorId,
    required String locationId,
    required String action,
    required Map<String, Object?> payload,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return withTenant<void>(ctx, (exec) async {
      // `target_id` mirrors the dispatcher's payload contract — the
      // connection_id is the load-bearing per-outage identifier, so
      // pinning it as `target_id` lets log search correlate the audit
      // row with the matching `connector_sync_log` rows.
      final targetId = payload['connection_id'];
      await _audit.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        actorKind: 'service',
        actorPrincipalId: kIntegrationSyncWorkerServicePrincipalId,
        targetKind: 'connector_connection',
        targetId: targetId is String ? targetId : null,
        action: action,
        payload: payload,
      );
    });
  }
}

/// Bundle of all the Postgres-backed seams the observer closure
/// composes. Held by `WorkerRuntime` so tests can introspect the
/// wiring without re-deriving the construction graph.
class VendorSyncOutageEmailBindings {
  const VendorSyncOutageEmailBindings({
    required this.stateRepository,
    required this.adminEmailLookup,
    required this.vendorIdLookup,
    required this.consoleUrlBuilder,
    required this.failureThreshold,
    required this.lookbackWindow,
  });

  final PostgresVendorSyncOutageStateRepository stateRepository;
  final PostgresVendorSyncOutageAdminEmailLookup adminEmailLookup;
  final PostgresVendorSyncOutageVendorIdLookup vendorIdLookup;
  final VendorSyncIntegrationConsoleUrlBuilder consoleUrlBuilder;
  final int failureThreshold;
  final Duration lookbackWindow;
}

/// Compose all of the Postgres-backed seams into a
/// `VendorSyncOutageObserver` closure suitable for passing to
/// `runSyncWorkerOnce` and `IntegrationSyncWorkerLoop`.
///
/// The closure builds a fresh `VendorSyncErrorAlertDispatcher` and
/// `VendorSyncOutageDetector` per observation. The construction cost
/// is dominated by the underlying Postgres reads / writes the
/// detector + dispatcher drive — instantiating the orchestrator
/// objects is a handful of field assignments and incurs no I/O.
/// Keeping the construction per-observation avoids stashing
/// `locationId`-bound writers in long-lived state (the outbox writer
/// captures `locationId` so it can engage RLS via `withTenant`).
VendorSyncOutageObserver buildVendorSyncOutageObserver({
  required TenantTransactionWrapper tenantWrapper,
  required VendorSyncOutageEmailBindings bindings,
  IOSink? errSink,
}) {
  return ({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
  }) async {
    // Build the per-observation outbox writer + audit writer that
    // ride the same `(operatorId, locationId)` `withTenant` scope as
    // the detector's state-row write. The dispatcher accepts the
    // audit writer as a typedef closure; the recipient lookup +
    // vendor metadata lookup are similarly closures.
    final outboxWriter = PostgresVendorSyncErrorAlertOutboxWriter(
      tenantWrapper: tenantWrapper,
      locationId: locationId,
    );
    final auditWriter = PostgresVendorSyncErrorAlertAuditWriter(
      tenantWrapper: tenantWrapper,
    );

    final dispatcher = VendorSyncErrorAlertDispatcher(
      recipientLookup: ({required String operatorId}) =>
          bindings.adminEmailLookup.resolve(operatorId: operatorId),
      vendorMetadataLookup: ({
        required String operatorId,
        required String locationId,
        required String connectionId,
      }) async {
        final vendorId = await bindings.vendorIdLookup.resolve(
          operatorId: operatorId,
          locationId: locationId,
          connectionId: connectionId,
        );
        if (vendorId == null) return null;
        final capability = lookupVendorCapability(vendorId);
        // Fall back to the raw vendor id when the catalog miss is
        // genuine (a vendor connected without a registered profile —
        // production catches this earlier but defence in depth).
        final displayName = capability?.displayName ?? vendorId;
        final consoleUrl = bindings.consoleUrlBuilder(
          operatorId: operatorId,
          locationId: locationId,
          connectionId: connectionId,
          vendorId: vendorId,
        );
        return VendorSyncAlertVendorMetadata(
          vendorDisplayName: displayName,
          integrationConsoleUrl: consoleUrl,
        );
      },
      outboxWriter: outboxWriter,
      auditWriter: auditWriter.write,
    );

    // Adapt the detector's `enqueueAlert` seam to the dispatcher.
    final detector = VendorSyncOutageDetector(
      repository: bindings.stateRepository,
      enqueueAlert: ({
        required String operatorId,
        required String locationId,
        required String connectionId,
        required DateTime outageStartedAt,
        required String? errorSummary,
      }) async {
        final outcome = await dispatcher.dispatch(
          operatorId: operatorId,
          locationId: locationId,
          connectionId: connectionId,
          outageStartedAt: outageStartedAt,
          errorSummary: errorSummary,
        );
        // Telemetry: surface the dispatcher's per-call outcome so a
        // post-incident review can match detector decisions to email
        // outbox rows. Mirrors the `oauth_refresh_auto_disabled_email`
        // log line shape the OAuth refresh worker emits.
        _logVendorSyncObserverEvent(
          errSink: errSink,
          event: 'vendor_sync_error_alert_dispatch',
          operatorId: operatorId,
          locationId: locationId,
          connectionId: connectionId,
          extra: <String, Object?>{
            'outcome': outcome.name,
            'outage_started_at': outageStartedAt.toUtc().toIso8601String(),
          },
        );
      },
      failureThreshold: bindings.failureThreshold,
      lookbackWindow: bindings.lookbackWindow,
    );

    final outcome = await detector.observe(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      latestEventKind: eventKind,
    );
    // Telemetry: detector-level outcome (no-op, recorded, enqueued,
    // already-notified, cleared). The dispatch-event log above fires
    // ONLY on threshold crossings; this fires every observation so
    // the polling tier's outage state machine is observable.
    _logVendorSyncObserverEvent(
      errSink: errSink,
      event: 'vendor_sync_outage_observe',
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      extra: <String, Object?>{
        'event_kind': eventKind,
        'action': outcome.action.name,
        if (outcome.consecutiveFailureCount != null)
          'consecutive_failures': outcome.consecutiveFailureCount,
      },
    );
  };
}

/// Telemetry helper. Emits one structured JSON line per observation
/// so log search can correlate detector decisions with the
/// `connector_sync_log` rows that triggered them. Failures swallowed
/// — telemetry is best-effort.
void _logVendorSyncObserverEvent({
  required IOSink? errSink,
  required String event,
  required String operatorId,
  required String locationId,
  required String connectionId,
  Map<String, Object?>? extra,
}) {
  if (errSink == null) return;
  try {
    errSink.writeln(jsonEncode(<String, Object?>{
      'event': event,
      'operator_id': operatorId,
      'location_id': locationId,
      'connection_id': connectionId,
      if (extra != null) ...extra,
    }));
  } catch (_) {
    // Sink may have been closed if the worker is shutting down; do
    // not throw from telemetry.
  }
}
