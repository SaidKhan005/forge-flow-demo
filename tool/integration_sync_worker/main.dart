// Phase 8 Wave B `8.spine-bridge.0` integration sync worker entrypoint.
//
// Cloud Run Job entry. Drains every connected vendor on every tick:
// the recurring poll loop covers vendors that don't push reliable
// webhooks (Oracle MICROS Simphony, Humanity, Agendrix, Push
// Operations, QuickBooks Time) AND catch-up sweeps for vendors that
// push webhooks but may drop one (Toast, Square, Lightspeed LSK,
// 7shifts, etc.). Both paths flow through the same
// [IntegrationSyncWorkerDispatch].
//
// Pieces this file composes (each landed in earlier slices):
//
//   * `tool/integration_sync_worker/dispatch.dart`
//     [IntegrationSyncWorkerDispatch]: pure-logic per-row dispatcher.
//     Owns the registry-lookup / sanity-hook / watermark-advance /
//     sync-log writeback contract. Untouched by this slice.
//   * `tool/integration_sync_worker/postgres_sync_worker_source.dart`
//     [PostgresSyncWorkerSource]: cross-tenant SELECT over
//     `public.connector_connection` joined against
//     `public.connector_sync_watermark`. Returns one
//     [ConnectorConnectionRow] per connected vendor connection.
//   * `tool/advisor_proxy/phase_8_vendor_integration_factories.dart`
//     [buildPhase8VendorIntegrationFactoriesFromCredentials]: the
//     binder builder the proxy already uses. Same per-vendor adapter
//     factory map gets reused here so a per-tenant credential bridge
//     never drifts between proxy webhooks and the recurring poll.
//
// CLI contract (mirrors `tool/oauth_refresh_worker/main.dart`):
//
//   integration_sync_worker daemon
//     [--max-rows-per-tick=N] [--poll-interval-seconds=N]
//
//   integration_sync_worker runOnce
//     [--max-rows-per-tick=N]
//
// Exit codes:
//   * 0 — success.
//   * 2 — configuration error (missing env, malformed args).
//   * 3 — runtime error (DB unreachable, scope enumeration failed).
//
// Required env (NAMES only — values flow through Secret Manager):
//   * `POSTGRES_URL` — same secret the audit_anchor + advisor proxy
//     mount.
//   * `PGCRYPTO_ENVELOPE_KEY` — the broker decrypts vendor credentials
//     before each poll tick.
//
// Optional env (NAMES only):
//   * `INTEGRATION_SYNC_WORKER_POLL_SECONDS` — daemon-mode tick
//     interval. Default 300s. Production deploys as a Cloud Run Job
//     fired by Cloud Scheduler so this is ignored.
//   * `INTEGRATION_SYNC_WORKER_MAX_ROWS_PER_TICK` — per-tick row cap.
//     Default 1000.
//   * Vendor app credentials (mirror the first-connect backfill
//     worker's optional bundle env vars).
//
// V1 hardening alignment:
//   * V1 lean cut #2: NO custom SIGTERM graceful-drain handler.
//     Cloud Run's default drain plus the per-batch watermark commit
//     contract is what makes the worker restart-resilient.
//   * Lean-cut ledger absent from this file's executable code; the
//     per-file source grep in
//     `test/services/integration/canonical_sink_contract_test.dart`
//     enforces it.
//
// CLAUDE.md alignment:
//   * Hard Promise #1 (transport-only). The dispatcher writes
//     `connector_sync_watermark` and `connector_sync_log` only;
//     per-vendor canonical fact tables are written by adapter-side
//     sinks composed inside the binder builder.
//   * Hard Promise #4 (per-operator isolation). Cross-tenant SELECT
//     uses `runAsSystem`; per-row dispatch flows through the
//     vendor-side broker / sink under the dispatcher's hood, and the
//     command stamps a `sp:` service-principal id so audit
//     attribution stays clean.
//   * Hard Promise #7 (server-side keys). Secret values are NEVER
//     printed; startup logs only env NAMES.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/vendor_sync_outage_state_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_production_api_client.dart'
    show AlohaNcrVoyixOauthClientCredentials;
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/per_tenant_location_config_resolver.dart';
import 'package:forge_and_flow/services/integration/projecting_canonical_sink.dart';
import 'package:forge_and_flow/services/vendor_sync/vendor_sync_outage_detector.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../advisor_proxy/advisor_proxy.dart'
    show CloverAppCredentials, SquareAppCredentials;
// Pull the per-vendor adapter factory builder directly from the
// dedicated file (not through `phase_8_production_binder.dart`) so the
// worker compile graph stays clear of `proxy_bootstrap.dart`'s
// admin-pool / Firebase / LLM machinery.
import '../advisor_proxy/phase_8_projector_wiring.dart';
import '../advisor_proxy/phase_8_vendor_integration_factories.dart'
    show
        Phase8VendorIntegrationFactories,
        buildPhase8VendorIntegrationFactoriesFromCredentials,
        kPhase8DefaultWebhookPublicBaseUri,
        kPhase8WebhookPublicBaseUriEnvName;
import 'dispatch.dart';
import 'postgres_sync_worker_source.dart';
import 'vendor_sync_outage_email_bindings.dart';

// ─── Service principal / clock ──────────────────────────────────────

DateTime _defaultUtcClock() => DateTime.now().toUtc();

// ─── SyncWorkerSource interface ─────────────────────────────────────

/// Source the worker pulls work from. Production impl
/// ([PostgresSyncWorkerSource]) SELECTs every `connector_connection`
/// row with `status = 'connected'`; tests inject an in-memory list.
abstract class SyncWorkerSource {
  /// Yields one row per connection ready for a poll tick.
  Stream<ConnectorConnectionRow> connectedConnections();
}

/// Resolves the per-row adapter at dispatch time. Production wires the
/// binder-backed factory whose closure consults the per-vendor map
/// from [buildPhase8VendorIntegrationFactoriesFromCredentials]; tests
/// inject a synchronous closure that returns a fixture adapter.
///
/// Returns `Future<Object>` because the production per-vendor factory
/// is async (it resolves per-tenant credentials before constructing
/// the adapter). The runner awaits the future and hands the resolved
/// instance to [IntegrationSyncWorkerDispatch.dispatchPollTick].
typedef AdapterFactoryResolver =
    Future<Object> Function(ConnectorConnectionRow row);

// ─── Env names ──────────────────────────────────────────────────────

abstract class IntegrationSyncWorkerEnvNames {
  static const String postgresUrl = 'POSTGRES_URL';
  static const String pgcryptoEnvelopeKey = 'PGCRYPTO_ENVELOPE_KEY';
  static const String pollIntervalSeconds =
      'INTEGRATION_SYNC_WORKER_POLL_SECONDS';
  static const String maxRowsPerTick =
      'INTEGRATION_SYNC_WORKER_MAX_ROWS_PER_TICK';
  static const String workerIdPrefix = 'INTEGRATION_SYNC_WORKER_ID_PREFIX';

  // ─── Optional vendor app-credential bundle names ───────────────────
  // Mirrors `tool/first_connect_backfill_worker/main.dart`. Each
  // bundle is OPTIONAL at boot; absence does NOT fail boot — the
  // matching vendor lands on the binder's `disabledVendors` warn list,
  // and any connected row for that vendor surfaces a clean
  // `vendor_not_registered`-style failure path on dispatch.
  static const String alohaNcrVoyixClientId = 'ALOHA_NCR_VOYIX_CLIENT_ID';
  static const String alohaNcrVoyixClientSecret =
      'ALOHA_NCR_VOYIX_CLIENT_SECRET';
  static const String alohaNcrVoyixApplicationKey =
      'ALOHA_NCR_VOYIX_APPLICATION_KEY';
  static const String alohaNcrVoyixOrganizationId =
      'ALOHA_NCR_VOYIX_ORGANIZATION_ID';
  static const String squareClientId = 'SQUARE_CLIENT_ID';
  static const String squareClientSecret = 'SQUARE_CLIENT_SECRET';
  static const String squareNotificationUrlHost =
      'SQUARE_NOTIFICATION_URL_HOST';
  static const String cloverAppToken = 'CLOVER_APP_TOKEN';
  static const String cloverAppId = 'CLOVER_APP_ID';
}

// ─── CLI ────────────────────────────────────────────────────────────

enum WorkerMode { daemon, runOnce }

class WorkerCliArgs {
  WorkerCliArgs({
    required this.mode,
    this.maxRowsPerTick,
    this.pollIntervalSeconds,
  });

  final WorkerMode mode;
  final int? maxRowsPerTick;
  final int? pollIntervalSeconds;
}

class WorkerConfigError implements Exception {
  WorkerConfigError(this.envName);

  final String envName;

  @override
  String toString() =>
      'integration_sync_worker: missing required env name: $envName';
}

WorkerCliArgs parseArgs(List<String> args) {
  if (args.isEmpty) {
    throw const FormatException(
      'usage: integration_sync_worker <daemon|runOnce> '
      '[--max-rows-per-tick=N] [--poll-interval-seconds=N]',
    );
  }
  final mode = switch (args.first) {
    'daemon' => WorkerMode.daemon,
    'runOnce' => WorkerMode.runOnce,
    final unknown => throw FormatException(
      'unknown mode "$unknown" (expected daemon|runOnce)',
    ),
  };
  int? maxRowsPerTick;
  int? pollIntervalSeconds;
  for (final raw in args.skip(1)) {
    if (raw.startsWith('--max-rows-per-tick=')) {
      maxRowsPerTick = _parsePositiveInt(
        raw.substring('--max-rows-per-tick='.length),
        'max-rows-per-tick',
      );
    } else if (raw.startsWith('--poll-interval-seconds=')) {
      pollIntervalSeconds = _parsePositiveInt(
        raw.substring('--poll-interval-seconds='.length),
        'poll-interval-seconds',
      );
    } else {
      throw FormatException('unknown flag "$raw"');
    }
  }
  return WorkerCliArgs(
    mode: mode,
    maxRowsPerTick: maxRowsPerTick,
    pollIntervalSeconds: pollIntervalSeconds,
  );
}

int _parsePositiveInt(String raw, String label) {
  final n = int.tryParse(raw);
  if (n == null || n <= 0) {
    throw FormatException('--$label expects a positive integer; got "$raw"');
  }
  return n;
}

// ─── Runtime config ─────────────────────────────────────────────────

class WorkerRuntimeConfig {
  WorkerRuntimeConfig({
    required this.postgresUrl,
    required this.pgcryptoEnvelopeKey,
    required this.webhookPublicBaseUri,
    required this.maxRowsPerTick,
    required this.pollInterval,
    required this.workerIdPrefix,
    required this.loadedSecretNames,
    required this.environment,
    this.alohaNcrVoyixCredentials,
    this.squareAppCredentials,
    this.cloverAppCredentials,
  });

  /// Resolved Postgres connection string. Never echoed.
  final String postgresUrl;

  /// pgcrypto symmetric envelope key the broker passes into
  /// `pgp_sym_encrypt`/`pgp_sym_decrypt`. Never echoed.
  final String pgcryptoEnvelopeKey;

  /// Public webhook base URI passed through to factories that compose
  /// callback URLs (Clover, Square, Lightspeed LSK, SevenRooms). The
  /// recurring sync never fires webhook callbacks but the binder
  /// builder requires the value at construction time.
  final Uri webhookPublicBaseUri;

  /// Per-tick row cap. Soft cap — the dispatcher still drains every
  /// row the source emits up to this limit per tick.
  final int maxRowsPerTick;

  /// Daemon-mode tick interval. Production ignores it (Cloud Scheduler
  /// drives the cadence).
  final Duration pollInterval;

  final String workerIdPrefix;
  final List<String> loadedSecretNames;

  /// Captured environment map. Threaded into the binder builder so the
  /// per-vendor branches can read staging-shape OAuth env vars without
  /// re-resolving Platform.environment.
  final Map<String, String> environment;

  /// Optional Aloha NCR Voyix static app credentials. Null when any of
  /// the four secret names is unloaded.
  final AlohaNcrVoyixOauthClientCredentials? alohaNcrVoyixCredentials;

  /// Optional Square static app credentials. Null when any of the
  /// three secret names is unloaded.
  final SquareAppCredentials? squareAppCredentials;

  /// Optional Clover static app credentials. Null when either secret
  /// name is unloaded.
  final CloverAppCredentials? cloverAppCredentials;

  static const int defaultMaxRowsPerTick = 1000;
  static const Duration defaultPollInterval = Duration(seconds: 300);
  static const String defaultWorkerIdPrefix = 'integration-sync';

  static WorkerRuntimeConfig fromEnvironment(
    Map<String, String> env, {
    WorkerCliArgs? cliOverrides,
  }) {
    final loaded = <String>[];
    String require(String name) {
      final value = env[name];
      if (value == null || value.isEmpty) throw WorkerConfigError(name);
      loaded.add(name);
      return value;
    }

    int optionalInt(String name, {required int fallback}) {
      final value = env[name];
      if (value == null || value.isEmpty) return fallback;
      final parsed = int.tryParse(value);
      if (parsed == null || parsed <= 0) {
        // Misconfigured ints fail closed; the deploy fails at boot
        // rather than silently falling back.
        throw WorkerConfigError(name);
      }
      loaded.add(name);
      return parsed;
    }

    String optionalString(String name, {required String fallback}) {
      final value = env[name];
      if (value == null || value.isEmpty) return fallback;
      loaded.add(name);
      return value;
    }

    String? optionalSecret(String name) {
      final value = env[name];
      if (value == null || value.isEmpty) return null;
      loaded.add(name);
      return value;
    }

    final postgresUrl = require(IntegrationSyncWorkerEnvNames.postgresUrl);
    final pgcryptoEnvelopeKey = require(
      IntegrationSyncWorkerEnvNames.pgcryptoEnvelopeKey,
    );
    final webhookBase = optionalString(
      kPhase8WebhookPublicBaseUriEnvName,
      fallback: kPhase8DefaultWebhookPublicBaseUri,
    );
    final maxRowsPerTick =
        cliOverrides?.maxRowsPerTick ??
        optionalInt(
          IntegrationSyncWorkerEnvNames.maxRowsPerTick,
          fallback: defaultMaxRowsPerTick,
        );
    final pollSeconds =
        cliOverrides?.pollIntervalSeconds ??
        optionalInt(
          IntegrationSyncWorkerEnvNames.pollIntervalSeconds,
          fallback: defaultPollInterval.inSeconds,
        );
    final prefix = optionalString(
      IntegrationSyncWorkerEnvNames.workerIdPrefix,
      fallback: defaultWorkerIdPrefix,
    );

    final alohaClientId = optionalSecret(
      IntegrationSyncWorkerEnvNames.alohaNcrVoyixClientId,
    );
    final alohaClientSecret = optionalSecret(
      IntegrationSyncWorkerEnvNames.alohaNcrVoyixClientSecret,
    );
    final alohaApplicationKey = optionalSecret(
      IntegrationSyncWorkerEnvNames.alohaNcrVoyixApplicationKey,
    );
    final alohaOrganizationId = optionalSecret(
      IntegrationSyncWorkerEnvNames.alohaNcrVoyixOrganizationId,
    );
    final AlohaNcrVoyixOauthClientCredentials? alohaCreds =
        (alohaClientId != null &&
            alohaClientSecret != null &&
            alohaApplicationKey != null &&
            alohaOrganizationId != null)
        ? AlohaNcrVoyixOauthClientCredentials(
            clientId: alohaClientId,
            clientSecret: alohaClientSecret,
            applicationKey: alohaApplicationKey,
            organizationId: alohaOrganizationId,
          )
        : null;

    final squareClientId = optionalSecret(
      IntegrationSyncWorkerEnvNames.squareClientId,
    );
    final squareClientSecret = optionalSecret(
      IntegrationSyncWorkerEnvNames.squareClientSecret,
    );
    final squareNotificationUrlHost = optionalSecret(
      IntegrationSyncWorkerEnvNames.squareNotificationUrlHost,
    );
    final SquareAppCredentials? squareCreds =
        (squareClientId != null &&
            squareClientSecret != null &&
            squareNotificationUrlHost != null)
        ? SquareAppCredentials(
            clientId: squareClientId,
            clientSecret: squareClientSecret,
            notificationUrlHost: squareNotificationUrlHost,
          )
        : null;

    final cloverAppToken = optionalSecret(
      IntegrationSyncWorkerEnvNames.cloverAppToken,
    );
    final cloverAppId = optionalSecret(
      IntegrationSyncWorkerEnvNames.cloverAppId,
    );
    final CloverAppCredentials? cloverCreds =
        (cloverAppToken != null && cloverAppId != null)
        ? CloverAppCredentials(appToken: cloverAppToken, appId: cloverAppId)
        : null;

    return WorkerRuntimeConfig(
      postgresUrl: postgresUrl,
      pgcryptoEnvelopeKey: pgcryptoEnvelopeKey,
      webhookPublicBaseUri: Uri.parse(webhookBase),
      maxRowsPerTick: maxRowsPerTick,
      pollInterval: Duration(seconds: pollSeconds),
      workerIdPrefix: prefix,
      loadedSecretNames: loaded,
      environment: Map<String, String>.unmodifiable(env),
      alohaNcrVoyixCredentials: alohaCreds,
      squareAppCredentials: squareCreds,
      cloverAppCredentials: cloverCreds,
    );
  }
}

// ─── Worker-side CanonicalSink ──────────────────────────────────────

/// Vendor-agnostic [CanonicalSink] used by the dispatcher's
/// `advanceWatermark` / `appendSyncLog` writes during the recurring
/// poll. Per-vendor adapters write canonical fact rows through THEIR
/// OWN bespoke sinks during `adapter.pollIncremental(command)`, so the
/// `upsert*` methods on this sink fail loud — reaching them indicates
/// a wiring bug that pointed a fact write at the framework sink
/// instead of the per-vendor sink.
class IntegrationSyncCanonicalSink implements CanonicalSink {
  IntegrationSyncCanonicalSink({
    required this.tenantWrapper,
    DateTime Function()? clock,
  }) : _clock = clock ?? _defaultUtcClock;

  final TenantTransactionWrapper tenantWrapper;
  final DateTime Function() _clock;

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    throw StateError(
      'IntegrationSyncCanonicalSink.upsertCoverFact called; per-vendor '
      'sinks own canonical fact writes during adapter.pollIncremental — '
      'the worker sink covers only watermark / sync log writes',
    );
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) {
    throw StateError(
      'IntegrationSyncCanonicalSink.upsertLaborPunch called; see '
      'upsertCoverFact',
    );
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) {
    throw StateError(
      'IntegrationSyncCanonicalSink.upsertReservationFact called; see '
      'upsertCoverFact',
    );
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return tenantWrapper.runInTenantContext(ctx, (exec) async {
      // Mirror the per-resource upsert shape from the first-connect
      // backfill worker's sink. The recurring sync writes its cursor
      // under `resource='poll'` so it never collides with the
      // backfill worker's `resource='first_backfill'` row for the
      // same connection.
      await exec.execute(
        'insert into public.connector_sync_watermark ('
        'operator_id, location_id, connection_id, resource, '
        'last_synced_at, last_modified_seen, cursor_token'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        "'poll', "
        '@last_synced_at::timestamptz, '
        '@last_modified_seen::timestamptz, @cursor_token'
        ') on conflict (connection_id, resource) do update set '
        'last_synced_at = excluded.last_synced_at, '
        'last_modified_seen = excluded.last_modified_seen, '
        'cursor_token = excluded.cursor_token, '
        'updated_at = now() '
        'where excluded.last_synced_at >= '
        'public.connector_sync_watermark.last_synced_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'last_synced_at': _clock(),
          'last_modified_seen': lastModifiedSeen.toUtc(),
          'cursor_token': cursorToken,
        },
      );
    });
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return tenantWrapper.runInTenantContext(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'records_count, error_message, payload_preview, occurred_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@event_kind, @records_count, @error_message, '
        '@payload_preview::jsonb, @occurred_at::timestamptz'
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview': payloadPreview == null
              ? null
              : jsonEncode(payloadPreview),
          'occurred_at': _clock(),
        },
      );
    });
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
  }) async {
    // The recurring sync never evaluates demo flips — that decision
    // happens once on the first-connect backfill path. Implement as a
    // no-op so a future caller misroute does not silently double-flip.
  }
}

// ─── Binder-backed adapter resolver ─────────────────────────────────

/// Resolves the per-row adapter using the same per-vendor factory map
/// the proxy installs into `Phase80IntegrationRoutes.globalBindings`.
/// The factories are async (they resolve per-tenant credentials before
/// constructing the adapter), so this resolver returns
/// `Future<Object>`; the runner awaits the future and hands the
/// resolved instance to [IntegrationSyncWorkerDispatch.dispatchPollTick].
class BinderBackedSyncAdapterResolver {
  BinderBackedSyncAdapterResolver({required this.factories});

  final Phase8VendorIntegrationFactories factories;

  /// Resolver entry point. Matches the [AdapterFactoryResolver]
  /// typedef.
  Future<Object> call(ConnectorConnectionRow row) async {
    final disabledReason = factories.disabledVendors[row.vendorId];
    switch (row.category) {
      case IntegrationCategory.pos:
        final factory = factories.posAdapterFactories[row.vendorId];
        if (factory != null) {
          return factory(
            operatorId: row.operatorId,
            locationId: row.locationId,
          );
        }
        if (disabledReason != null) {
          throw SyncWorkerVendorDisabledException(
            vendorId: row.vendorId,
            category: row.category,
            reason: disabledReason,
          );
        }
        throw SyncWorkerVendorNotWiredException(
          vendorId: row.vendorId,
          category: row.category,
        );
      case IntegrationCategory.labor:
        final factory = factories.laborAdapterFactories[row.vendorId];
        if (factory != null) {
          return factory(
            operatorId: row.operatorId,
            locationId: row.locationId,
          );
        }
        if (disabledReason != null) {
          throw SyncWorkerVendorDisabledException(
            vendorId: row.vendorId,
            category: row.category,
            reason: disabledReason,
          );
        }
        throw SyncWorkerVendorNotWiredException(
          vendorId: row.vendorId,
          category: row.category,
        );
      case IntegrationCategory.reservation:
        final factory = factories.reservationAdapterFactories[row.vendorId];
        if (factory != null) {
          return factory(
            operatorId: row.operatorId,
            locationId: row.locationId,
          );
        }
        if (disabledReason != null) {
          throw SyncWorkerVendorDisabledException(
            vendorId: row.vendorId,
            category: row.category,
            reason: disabledReason,
          );
        }
        throw SyncWorkerVendorNotWiredException(
          vendorId: row.vendorId,
          category: row.category,
        );
    }
  }
}

class SyncWorkerVendorDisabledException implements Exception {
  const SyncWorkerVendorDisabledException({
    required this.vendorId,
    required this.category,
    required this.reason,
  });

  final String vendorId;
  final IntegrationCategory category;
  final String reason;

  @override
  String toString() =>
      'vendor "$vendorId" not active in binder; missing app credentials '
      '(reason=$reason, category=${category.name})';
}

class SyncWorkerVendorNotWiredException implements Exception {
  const SyncWorkerVendorNotWiredException({
    required this.vendorId,
    required this.category,
  });

  final String vendorId;
  final IntegrationCategory category;

  @override
  String toString() =>
      'vendor "$vendorId" is not wired in the Phase 8 binder builder for '
      'category=${category.name}; add a per-vendor branch in '
      'tool/advisor_proxy/phase_8_vendor_integration_factories.dart';
}

// ─── Tick result ─────────────────────────────────────────────────────

class WorkerTickResult {
  const WorkerTickResult({
    required this.processed,
    required this.succeeded,
    required this.failed,
    required this.watermarkAdvanced,
    required this.skipped,
  });

  /// Total rows the source yielded that the worker attempted to
  /// dispatch (post-cap).
  final int processed;

  /// Rows whose dispatch produced a `poll_success` log.
  final int succeeded;

  /// Rows whose dispatch produced a `poll_error` log (adapter
  /// exception or vendor-side failure).
  final int failed;

  /// Rows whose dispatch produced an `advanceWatermark` write. Equal
  /// to [succeeded] under the dispatcher's contract; tracked
  /// separately so a future contract change shows up in the tick log.
  final int watermarkAdvanced;

  /// Rows skipped before dispatch — vendor not registered in the
  /// category registry, factory returned wrong category, or vendor in
  /// the binder's `disabledVendors` warn list.
  final int skipped;

  Map<String, Object?> toLogFields() => <String, Object?>{
    'processed': processed,
    'succeeded': succeeded,
    'failed': failed,
    'watermark_advanced': watermarkAdvanced,
    'skipped': skipped,
  };
}

// ─── Run-once orchestration ─────────────────────────────────────────

/// Run one walk over every connected connection. Returns a tally of
/// the work the worker drove. Each row dispatch is wrapped in
/// try/catch so one row's failure does not stop the walk; the
/// dispatcher already wrote the `poll_error` sync log row before the
/// exception bubbles, so the failure is durable.
///
/// The runner:
///
///   1. Iterates `source.connectedConnections()` up to
///      [maxRowsPerTick]. Excess rows are dropped silently — the next
///      tick picks them up.
///   2. For each row, awaits [resolveAdapterFactory] to materialise
///      the adapter, then synthesises the synchronous
///      [AdapterFactory] the dispatcher's interface expects.
///   3. Calls `dispatcher.dispatchPollTick(...)`. The dispatcher
///      writes the watermark + sync log on success, sync log only on
///      failure. Both are durable.
///   4. Counts succeeded / failed / skipped via the recording sink
///      facade declared inside this function.
///
/// V1 lean cut #2 — no SIGTERM hooks. The `shouldStop` parameter
/// exists only for the daemon loop's between-row interrupt so the
/// loop can exit between ticks without a custom drain handler.
/// C-2-D outage observer callback. Invoked after every
/// `appendSyncLog` write so the
/// `VendorSyncOutageDetector` can decide whether to enqueue a
/// `vendor_sync_error_alert` email. Signature is intentionally
/// narrow so this file stays decoupled from
/// `lib/services/vendor_sync` (production wires the detector
/// via a closure in the runtime bootstrap; tests skip the
/// observer entirely by leaving it null).
typedef VendorSyncOutageObserver =
    Future<void> Function({
      required String operatorId,
      required String locationId,
      required String connectionId,
      required String eventKind,
    });

Future<WorkerTickResult> runSyncWorkerOnce({
  required SyncWorkerSource source,
  required CanonicalSink canonicalSink,
  required AdapterFactoryResolver resolveAdapterFactory,
  IntegrationSyncWorkerDispatch? dispatcher,
  int maxRowsPerTick = 1000,
  bool Function()? shouldStop,
  IOSink? out,
  IOSink? err,
  VendorSyncOutageObserver? outageObserver,
  CanonicalFactProjectionCommitDrainer? projectionCommitDrainer,
}) async {
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stdoutSink = out ?? stdout;
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stderrSink = err ?? stderr;
  final dispatch = dispatcher ?? IntegrationSyncWorkerDispatch();
  // The runner wraps the supplied sink so it can count successes /
  // failures without forcing the dispatcher's contract to grow a
  // tally surface. C-2-D also threads an optional outage observer
  // through so the `VendorSyncOutageDetector` runs after each
  // `appendSyncLog` write without coupling this file to
  // `lib/services/vendor_sync`.
  final tally = _TickTally();
  final wrappedSink = _CountingCanonicalSink(
    canonicalSink,
    tally,
    outageObserver: outageObserver,
    errSink: stderrSink,
  );

  var processed = 0;
  await for (final row in source.connectedConnections()) {
    if (shouldStop?.call() ?? false) break;
    if (processed >= maxRowsPerTick) break;
    processed += 1;

    Object adapter;
    try {
      adapter = await resolveAdapterFactory(row);
    } on SyncWorkerVendorDisabledException catch (error) {
      tally.skipped += 1;
      // Surface a durable poll_error so the operator-facing audit
      // timeline carries the disabled reason (the dispatcher would
      // have produced a `vendor_not_registered` row, but the binder's
      // disable-warn semantics produce a different surface — same
      // outcome, clearer reason).
      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'poll_error',
        errorMessage: error.toString(),
      );
      stderrSink.writeln(
        jsonEncode(<String, Object?>{
          'event': 'integration_sync_vendor_disabled',
          'vendor_id': row.vendorId,
          'connection_id': row.connectionId,
          'reason': error.reason,
        }),
      );
      continue;
    } on SyncWorkerVendorNotWiredException catch (error) {
      tally.skipped += 1;
      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'vendor_not_registered',
        errorMessage: error.toString(),
      );
      stderrSink.writeln(
        jsonEncode(<String, Object?>{
          'event': 'integration_sync_vendor_not_wired',
          'vendor_id': row.vendorId,
          'connection_id': row.connectionId,
        }),
      );
      continue;
    } catch (error) {
      // Unexpected resolver failure (broker decrypt error, async
      // location-config lookup failed, etc.). Write a poll_error so
      // the audit log carries the reason; the next tick retries.
      tally.failed += 1;
      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'poll_error',
        errorMessage: error.toString(),
      );
      stderrSink.writeln(
        jsonEncode(<String, Object?>{
          'event': 'integration_sync_resolver_error',
          'vendor_id': row.vendorId,
          'connection_id': row.connectionId,
          'error': error.toString(),
        }),
      );
      continue;
    }

    try {
      await dispatch.dispatchPollTick(
        connectorConnectionRow: row,
        // Synchronous closure required by the dispatcher's typedef.
        // The async resolution happened above; here we just return
        // the resolved instance.
        adapterFactory: (_) => adapter,
        canonicalSink: wrappedSink,
        projectionCommitDrainer: projectionCommitDrainer,
      );
    } on StateError {
      // "vendor not registered" or "factory returned wrong category"
      // surfaces here. The dispatcher already wrote the durable
      // sync_log row before throwing; we count it and continue.
      tally.skipped += 1;
      stdoutSink.writeln(
        jsonEncode(<String, Object?>{
          'event': 'integration_sync_dispatch_state_error',
          'vendor_id': row.vendorId,
          'connection_id': row.connectionId,
        }),
      );
      continue;
    } catch (error) {
      // Adapter-thrown errors are caught inside the dispatcher and
      // logged as `poll_error`; reaching this branch means the
      // dispatcher itself surfaced something unusual. Count it as a
      // failure but do not stop the tick.
      tally.failed += 1;
      stderrSink.writeln(
        jsonEncode(<String, Object?>{
          'event': 'integration_sync_dispatch_error',
          'vendor_id': row.vendorId,
          'connection_id': row.connectionId,
          'error': error.toString(),
        }),
      );
    }
  }

  return WorkerTickResult(
    processed: processed,
    succeeded: tally.succeeded,
    failed: tally.failed + tally.dispatchFailed,
    watermarkAdvanced: tally.watermarkAdvanced,
    skipped: tally.skipped,
  );
}

class _TickTally {
  int succeeded = 0;
  int dispatchFailed = 0;
  int watermarkAdvanced = 0;
  int failed = 0;
  int skipped = 0;
}

/// Canonical sink decorator that counts watermark advances + sync log
/// outcomes from the dispatcher. The dispatcher writes exactly one of
/// `poll_success` / `poll_error` / `vendor_not_registered` per row, so
/// the tally lines up with the row count under normal operation.
class _CountingCanonicalSink implements CanonicalSink {
  _CountingCanonicalSink(
    this._delegate,
    this._tally, {
    VendorSyncOutageObserver? outageObserver,
    IOSink? errSink,
  }) : _outageObserver = outageObserver,
       _errSink = errSink;

  final CanonicalSink _delegate;
  final _TickTally _tally;
  final VendorSyncOutageObserver? _outageObserver;
  final IOSink? _errSink;

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) => _delegate.upsertCoverFact(
    operatorId: operatorId,
    locationId: locationId,
    canonicalFact: canonicalFact,
  );

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) => _delegate.upsertLaborPunch(
    operatorId: operatorId,
    locationId: locationId,
    canonicalPunch: canonicalPunch,
  );

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) => _delegate.upsertReservationFact(
    operatorId: operatorId,
    locationId: locationId,
    canonicalReservation: canonicalReservation,
  );

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    await _delegate.advanceWatermark(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    );
    _tally.watermarkAdvanced += 1;
  }

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
    await _delegate.appendSyncLog(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      eventKind: eventKind,
      errorMessage: errorMessage,
      recordsCount: recordsCount,
      payloadPreview: payloadPreview,
    );
    switch (eventKind) {
      case 'poll_success':
        _tally.succeeded += 1;
      case 'poll_error':
        _tally.dispatchFailed += 1;
      case 'vendor_not_registered':
        _tally.skipped += 1;
      default:
        // Cadence-resolver / sanity log rows are non-terminal; leave
        // tallies unchanged.
        break;
    }
    // C-2-D: feed the outage detector AFTER the sync-log row has
    // been durable. The detector reads `connector_sync_log` to
    // compute the consecutive-failure streak so it needs the row
    // already committed; failures are logged but never crash the
    // tick (the email path is operator-courtesy, not load-bearing).
    final observer = _outageObserver;
    if (observer != null) {
      try {
        await observer(
          operatorId: operatorId,
          locationId: locationId,
          connectionId: connectionId,
          eventKind: eventKind,
        );
      } catch (error, stack) {
        _errSink?.writeln(
          jsonEncode(<String, Object?>{
            'event': 'vendor_sync_outage_observer_error',
            'operator_id': operatorId,
            'connection_id': connectionId,
            'event_kind': eventKind,
            'error': error.toString(),
            'stack_first_frame': stack.toString().split('\n').first,
          }),
        );
      }
    }
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
  }) => _delegate.evaluateDemoFlip(
    operatorId: operatorId,
    locationId: locationId,
    category: category,
    connectionStatus: connectionStatus,
    firstBackfillCommitted: firstBackfillCommitted,
    backfillRecordsWritten: backfillRecordsWritten,
    connectionId: connectionId,
  );
}

// ─── Daemon loop ─────────────────────────────────────────────────────

class IntegrationSyncWorkerLoop {
  IntegrationSyncWorkerLoop({
    required this.source,
    required this.canonicalSink,
    required this.resolveAdapterFactory,
    required this.config,
    IntegrationSyncWorkerDispatch? dispatcher,
    IOSink? out,
    IOSink? err,
    VendorSyncOutageObserver? outageObserver,
    CanonicalFactProjectionCommitDrainer? projectionCommitDrainer,
  }) : _dispatcher = dispatcher ?? IntegrationSyncWorkerDispatch(),
       _out = out ?? stdout,
       _err = err ?? stderr,
       _outageObserver = outageObserver,
       _projectionCommitDrainer = projectionCommitDrainer;

  final SyncWorkerSource source;
  final CanonicalSink canonicalSink;
  final AdapterFactoryResolver resolveAdapterFactory;
  final WorkerRuntimeConfig config;
  final IntegrationSyncWorkerDispatch _dispatcher;
  // ignore: unused_field, close_sinks
  final IOSink _out;
  final IOSink _err;
  final VendorSyncOutageObserver? _outageObserver;
  final CanonicalFactProjectionCommitDrainer? _projectionCommitDrainer;

  bool _stopRequested = false;
  Completer<void>? _stoppedCompleter;

  void requestStop() {
    _stopRequested = true;
  }

  bool get isStopRequested => _stopRequested;

  Future<void> run() async {
    _stoppedCompleter = Completer<void>();
    try {
      while (!_stopRequested) {
        try {
          final result = await runSyncWorkerOnce(
            source: source,
            canonicalSink: canonicalSink,
            resolveAdapterFactory: resolveAdapterFactory,
            dispatcher: _dispatcher,
            maxRowsPerTick: config.maxRowsPerTick,
            shouldStop: () => _stopRequested,
            out: _out,
            err: _err,
            outageObserver: _outageObserver,
            projectionCommitDrainer: _projectionCommitDrainer,
          );
          _out.writeln(
            'integration_sync_worker tick: '
            '${jsonEncode(result.toLogFields())}',
          );
        } catch (error, stack) {
          // Catastrophic-only path: per-row failures are already
          // booked through `_CountingCanonicalSink` and the
          // dispatcher's poll_error log. Reaching here means the
          // source SELECT itself failed (DB unreachable, role-elevate
          // refused, etc.). Don't crash the loop — log + sleep.
          _err.writeln('integration_sync_worker tick error: $error');
          _err.writeln(stack.toString());
        }
        if (_stopRequested) break;
        await _sleepInterruptible(config.pollInterval);
      }
    } finally {
      _stoppedCompleter!.complete();
    }
  }

  /// Sleep that wakes immediately if `requestStop` fired.
  Future<void> _sleepInterruptible(Duration total) async {
    const tick = Duration(milliseconds: 200);
    var slept = Duration.zero;
    while (slept < total && !_stopRequested) {
      final remaining = total - slept;
      await Future<void>.delayed(remaining < tick ? remaining : tick);
      slept += tick;
    }
  }

  Future<void> get stopped => _stoppedCompleter?.future ?? Future<void>.value();
}

// ─── Entry point ────────────────────────────────────────────────────

typedef WorkerPoolFactory = PostgresPool Function(String connectionString);

// Honor POSTGRES_POOL_MAX_CONNECTIONS env override; falls back to default 20.
PostgresPool _defaultPoolFactory(String connectionString) =>
    PackagePostgresPool.fromUrl(
      connectionString,
      maxConnectionCount: resolvePostgresMaxConnectionsPerPool(),
    );

/// Test seam over the env-aware pool factory. Production calls
/// [_defaultPoolFactory] (no env arg → reads `Platform.environment`).
/// Tests pass a synthetic `environment` map to assert the
/// `POSTGRES_POOL_MAX_CONNECTIONS` override flows through to
/// `PackagePostgresPool.maxConnectionCount`.
@visibleForTesting
int integrationSyncWorkerResolvedPoolMaxConnections({
  Map<String, String>? environment,
}) => resolvePostgresMaxConnectionsPerPool(environment: environment);

/// Bundle returned by [buildWorkerRuntime]. Tests inject overrides so
/// the worker's source / sink / resolver paths can be exercised
/// end-to-end without real Postgres or vendor HTTP calls.
class WorkerRuntime {
  const WorkerRuntime({
    required this.source,
    required this.canonicalSink,
    required this.resolveAdapterFactory,
    required this.config,
    required this.disabledVendors,
    required this.wiredVendorIds,
    this.projectionCommitDrainer,
    this.outageObserver,
    this.outageEmailBindings,
  });

  final SyncWorkerSource source;
  final CanonicalSink canonicalSink;
  final AdapterFactoryResolver resolveAdapterFactory;
  final WorkerRuntimeConfig config;

  /// Vendor → reason map mirroring the binder's disabled-warn list.
  /// Surfaced for the boot-time JSON log so a deploy review can verify
  /// the worker activates the same vendors as the proxy one-to-one.
  final Map<String, String> disabledVendors;

  /// Vendor ids whose adapter factory is wired (sorted ascending for
  /// stable boot logs).
  final List<String> wiredVendorIds;

  /// Drains direct adapter fact-write taps after successful worker
  /// commit logs.
  final CanonicalFactProjectionCommitDrainer? projectionCommitDrainer;

  /// C-2-D production binding: vendor sync outage observer wired
  /// through `buildWorkerRuntime`. Non-null when the runtime is built
  /// from real Postgres seams; null on the test override path where
  /// the caller supplies its own source / sink / resolver. The
  /// observer fires after every `appendSyncLog` write so the
  /// `VendorSyncOutageDetector` can enqueue the
  /// `vendor_sync_error_alert` email on the first failure of an
  /// outage.
  final VendorSyncOutageObserver? outageObserver;

  /// The detector + dispatcher seam bundle the observer composes.
  /// Surfaced for tests / introspection only; production callers
  /// should pass `outageObserver` (the observer is the loop-facing
  /// closure that wires through to the detector + dispatcher under
  /// the hood).
  final VendorSyncOutageEmailBindings? outageEmailBindings;
}

WorkerRuntime buildWorkerRuntime({
  required WorkerRuntimeConfig config,
  WorkerPoolFactory poolFactory = _defaultPoolFactory,
  http.Client? httpClient,
  IOSink? observerTelemetrySink,
}) {
  final pool = poolFactory(config.postgresUrl);
  final wrapper = TenantTransactionWrapper(pool);

  final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);
  final canonicalSink = IntegrationSyncCanonicalSink(tenantWrapper: wrapper);

  final sharedHttpClient = httpClient ?? http.Client();
  final broker = VendorCredentialBroker(
    tenantWrapper: wrapper,
    pgcryptoEnvelopeKey: config.pgcryptoEnvelopeKey,
  );
  final locationConfigResolver = PerTenantLocationConfigResolver(
    wrapper,
    webhookPublicBaseUri: config.webhookPublicBaseUri,
  );
  final projectorWiring = buildDefaultPhase8ProjectorWiring(wrapper);
  final factories = buildPhase8VendorIntegrationFactoriesFromCredentials(
    tenantTransactionWrapper: wrapper,
    broker: broker,
    locationConfigResolver: locationConfigResolver,
    sharedHttpClient: sharedHttpClient,
    webhookPublicBaseUri: config.webhookPublicBaseUri,
    alohaNcrVoyixCredentials: config.alohaNcrVoyixCredentials,
    squareAppCredentials: config.squareAppCredentials,
    cloverAppCredentials: config.cloverAppCredentials,
    canonicalFactPostCommitProjector: projectorWiring.projector,
    canonicalFactPeriodResolver: projectorWiring.periodResolver,
    canonicalRestaurantIdResolver: projectorWiring.restaurantIdResolver,
  );
  final projectionCommitDrainer = CanonicalFactProjectionCommitDrainer(
    tapsByVendor: Map<String, CanonicalFactProjectionTap>.unmodifiable(
      factories.projectionTapsByVendor,
    ),
  );
  final resolver = BinderBackedSyncAdapterResolver(factories: factories);

  final wired = <String>{
    ...factories.posAdapterFactories.keys,
    ...factories.laborAdapterFactories.keys,
    ...factories.reservationAdapterFactories.keys,
  }.toList()..sort();

  // C-2-D production binding: compose the detector + dispatcher seams
  // off the same tenant wrapper so RLS / SET LOCAL discipline matches
  // the polling tier's `connector_sync_log` writes. Mirrors
  // `buildWorkerRuntime` in `tool/oauth_refresh_worker/main.dart`
  // (PR #628 C-2-F precedent): recipient resolution rides
  // `withSystem` (cross-tenant; the worker walks all operators); the
  // outbox INSERT + audit row write ride `withTenant` (per-tenant
  // RLS engaged).
  final outageStateRepository = PostgresVendorSyncOutageStateRepository(
    wrapper,
  );
  final outageAdminEmailLookup = PostgresVendorSyncOutageAdminEmailLookup(
    tenantWrapper: wrapper,
  );
  final outageVendorIdLookup = PostgresVendorSyncOutageVendorIdLookup(
    tenantWrapper: wrapper,
  );
  final outageEmailBindings = VendorSyncOutageEmailBindings(
    stateRepository: outageStateRepository,
    adminEmailLookup: outageAdminEmailLookup,
    vendorIdLookup: outageVendorIdLookup,
    consoleUrlBuilder: defaultVendorSyncIntegrationConsoleUrl,
    failureThreshold: VendorSyncOutageDetector.kDefaultFailureThreshold,
    lookbackWindow: VendorSyncOutageDetector.kDefaultLookbackWindow,
  );
  final outageObserver = buildVendorSyncOutageObserver(
    tenantWrapper: wrapper,
    bindings: outageEmailBindings,
    errSink: observerTelemetrySink ?? stderr,
  );

  return WorkerRuntime(
    source: source,
    canonicalSink: canonicalSink,
    resolveAdapterFactory: resolver.call,
    config: config,
    disabledVendors: Map<String, String>.unmodifiable(
      factories.disabledVendors,
    ),
    wiredVendorIds: List<String>.unmodifiable(wired),
    projectionCommitDrainer: projectionCommitDrainer,
    outageObserver: outageObserver,
    outageEmailBindings: outageEmailBindings,
  );
}

/// CLI runner. Tests pass overrides; production calls with no
/// overrides.
Future<int> runCli(
  List<String> rawArgs, {
  Map<String, String>? environment,
  WorkerPoolFactory? poolFactory,
  SyncWorkerSource? sourceOverride,
  CanonicalSink? canonicalSinkOverride,
  AdapterFactoryResolver? resolveAdapterFactoryOverride,
  IntegrationSyncWorkerDispatch? dispatcherOverride,
  VendorSyncOutageObserver? outageObserverOverride,
  IOSink? out,
  IOSink? err,
  Future<void> Function(IntegrationSyncWorkerLoop loop)? installSignalHandlers,
}) async {
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stdoutSink = out ?? stdout;
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stderrSink = err ?? stderr;
  final env = environment ?? Platform.environment;

  WorkerCliArgs args;
  try {
    args = parseArgs(rawArgs);
  } on FormatException catch (error) {
    stderrSink.writeln('integration_sync_worker: ${error.message}');
    return 2;
  }

  final hasOverrides =
      sourceOverride != null &&
      canonicalSinkOverride != null &&
      resolveAdapterFactoryOverride != null;

  WorkerRuntimeConfig config;
  SyncWorkerSource source;
  CanonicalSink canonicalSink;
  AdapterFactoryResolver resolveAdapterFactory;
  Map<String, String> disabledVendors = const <String, String>{};
  List<String> wiredVendorIds = const <String>[];
  // C-2-D production binding: outage observer wired by
  // `buildWorkerRuntime` on the production path; tests using the
  // override path pass `outageObserverOverride` (or leave it null —
  // existing observer-related tests already exercise the null path).
  VendorSyncOutageObserver? outageObserver;
  CanonicalFactProjectionCommitDrainer? projectionCommitDrainer;

  if (hasOverrides) {
    config = WorkerRuntimeConfig(
      postgresUrl: 'test://override',
      pgcryptoEnvelopeKey: 'test-pgcrypto-key',
      webhookPublicBaseUri: Uri.parse(kPhase8DefaultWebhookPublicBaseUri),
      maxRowsPerTick:
          args.maxRowsPerTick ?? WorkerRuntimeConfig.defaultMaxRowsPerTick,
      pollInterval: Duration(
        seconds:
            args.pollIntervalSeconds ??
            WorkerRuntimeConfig.defaultPollInterval.inSeconds,
      ),
      workerIdPrefix: WorkerRuntimeConfig.defaultWorkerIdPrefix,
      loadedSecretNames: const <String>[],
      environment: env,
    );
    source = sourceOverride;
    canonicalSink = canonicalSinkOverride;
    resolveAdapterFactory = resolveAdapterFactoryOverride;
    // Test path: only wire the observer when the caller explicitly
    // injects one. Leaving it null preserves the existing "no email"
    // contract for tests that don't exercise the C-2-D path.
    outageObserver = outageObserverOverride;
  } else {
    try {
      config = WorkerRuntimeConfig.fromEnvironment(env, cliOverrides: args);
    } on WorkerConfigError catch (error) {
      stderrSink.writeln(error.toString());
      return 2;
    }
    final runtime = buildWorkerRuntime(
      config: config,
      poolFactory: poolFactory ?? _defaultPoolFactory,
      observerTelemetrySink: stderrSink,
    );
    source = runtime.source;
    canonicalSink = runtime.canonicalSink;
    resolveAdapterFactory = runtime.resolveAdapterFactory;
    disabledVendors = runtime.disabledVendors;
    wiredVendorIds = runtime.wiredVendorIds;
    projectionCommitDrainer = runtime.projectionCommitDrainer;
    outageObserver = outageObserverOverride ?? runtime.outageObserver;
    // Boot-time JSON log: name three categories so a deploy review can
    // verify the worker matches the proxy's connector activation list
    // one-to-one. Secret values are NEVER echoed — only env names.
    stdoutSink.writeln(
      'integration_sync_worker boot: ${jsonEncode(<String, Object?>{
        'event': 'boot',
        'mode': args.mode.name,
        'loaded_secret_names': config.loadedSecretNames,
        'wired_vendors': wiredVendorIds,
        'disabled_vendors': disabledVendors,
        'max_rows_per_tick': config.maxRowsPerTick,
        'poll_interval_seconds': config.pollInterval.inSeconds,
        // C-2-D production binding disclosure: an explicit boolean in
        // the boot log lets a deploy review confirm the email path is
        // reachable (i.e. the observer was wired through). False only
        // on the test override path.
        'vendor_sync_outage_observer_wired': outageObserver != null,
      })}',
    );
  }

  switch (args.mode) {
    case WorkerMode.runOnce:
      try {
        final result = await runSyncWorkerOnce(
          source: source,
          canonicalSink: canonicalSink,
          resolveAdapterFactory: resolveAdapterFactory,
          dispatcher: dispatcherOverride,
          maxRowsPerTick: config.maxRowsPerTick,
          out: stdoutSink,
          err: stderrSink,
          outageObserver: outageObserver,
          projectionCommitDrainer: projectionCommitDrainer,
        );
        stdoutSink.writeln(
          'integration_sync_worker exit: ${jsonEncode(<String, Object?>{'event': 'exit', 'mode': 'runOnce', ...result.toLogFields()})}',
        );
        return 0;
      } catch (error) {
        stderrSink.writeln('integration_sync_worker runOnce error: $error');
        return 3;
      }
    case WorkerMode.daemon:
      final loop = IntegrationSyncWorkerLoop(
        source: source,
        canonicalSink: canonicalSink,
        resolveAdapterFactory: resolveAdapterFactory,
        config: config,
        dispatcher: dispatcherOverride,
        out: stdoutSink,
        err: stderrSink,
        outageObserver: outageObserver,
        projectionCommitDrainer: projectionCommitDrainer,
      );
      if (installSignalHandlers != null) {
        await installSignalHandlers(loop);
      } else {
        _installDefaultSignalHandlers(loop);
      }
      try {
        await loop.run();
        stdoutSink.writeln(
          'integration_sync_worker exit: ${jsonEncode(<String, Object?>{'event': 'exit', 'mode': 'daemon'})}',
        );
        return 0;
      } catch (error) {
        stderrSink.writeln('integration_sync_worker daemon error: $error');
        return 3;
      }
  }
}

void _installDefaultSignalHandlers(IntegrationSyncWorkerLoop loop) {
  // V1 lean cut #2 — Cloud Run's default drain is what handles
  // production SIGTERM. The handler here is purely for local dev
  // (Ctrl+C / SIGINT in `flutter pub run ... daemon`); it sets the
  // stop flag so the loop exits between ticks. There is no per-row
  // graceful drain — the watermark-per-batch contract makes restart
  // resilient.
  ProcessSignal.sigterm.watch().listen((_) {
    loop.requestStop();
  });
  ProcessSignal.sigint.watch().listen((_) {
    loop.requestStop();
  });
}

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
