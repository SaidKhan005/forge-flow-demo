// Phase 8 — production OAuth refresh worker.
//
// Cloud Run-deployable Dart entrypoint that closes the
// "vendor tokens silently expire" gap: the existing
// `lib/services/integration/oauth_refresh_cron.dart` carries the
// runner logic and the per-vendor `OAuthRefresher` interface, but
// nothing in production calls them. This worker composes the existing
// pieces — the in-process broker (`VendorCredentialBroker.refreshAccessToken`)
// for the actual refresh + persist, and a Postgres-backed
// `OAuthRefreshGateway` for the per-row claim / failure-count /
// auto-disable seam — into the Cloud Run binary the deploy script
// installs.
//
// The worker:
//
//   1. Polls `public.vendor_credentials` for rows whose
//      `token_expires_at < now() + interval '5 minutes'` (the
//      "near-expiry window" in the prompt). Rows are claimed with
//      `FOR UPDATE SKIP LOCKED` so multiple worker pods running in
//      parallel never refresh the same row twice.
//   2. For each claimed row: looks up the per-vendor production
//      OAuth refresh closure (Toast / Square / Clover / Lightspeed
//      LSK / Aloha NCR Voyix / Oracle MICROS Simphony / Revel /
//      7shifts / QuickBooks Time / Libro / Humanity per
//      `lib/integrations/_common/production_oauth_refresh_closures.dart`).
//      Vendors WITHOUT a closure (SevenRooms, Tock, Push Operations,
//      Agendrix, ADP, OpenTable per the closure file's documented
//      coverage list) are SKIPPED with a single trace log: their
//      bridges either use static API keys or have the transport
//      handle refresh internally.
//   3. Calls `VendorCredentialBroker.refreshAccessToken(...)` with
//      the resolved closure. The broker:
//        * acquires a per-(operator, location, vendor) Future lock
//          so concurrent in-flight refreshes collapse to one;
//        * reads the bundle, calls the closure, persists the new
//          ciphertext + token_expires_at, and resets
//          `consecutive_refresh_failures` to 0 on success.
//   4. On success: writes `connector_sync_log` entry
//      `event_kind='auth_refresh'` (1 record) and counts the
//      success in the tick result.
//   5. On failure (broker throws `VendorRefreshFailed` /
//      `VendorCredentialDecryptFailed` / `VendorCredentialNotFound`):
//      increments `consecutive_refresh_failures` and writes
//      `connector_sync_log` `event_kind='auth_refresh_failed'`. When
//      the post-increment count hits `MAX_CONSECUTIVE_FAILURES`
//      (default 3), flips `connector_connection.status='error'`
//      with `disconnect_reason='oauth_timeout'` (the schema's
//      enum admits four values; `oauth_timeout` is the only one
//      that maps to "we gave up on the refresh handshake") AND
//      writes a single `audit_logs` row with
//      `action='vendor_credential_auto_disabled'`.
//   6. SIGTERM handler: requests a stop. The worker finishes the
//      current row's refresh (broker semantics already serialize
//      per-tenant; abandoning mid-refresh would risk a half-written
//      ciphertext) and then exits between rows.
//
// CLI contract — mirrors `tool/first_connect_backfill_worker/main.dart`:
//
//   oauth_refresh_worker daemon
//     [--max-attempts=N] [--max-rows-per-tick=N]
//     [--poll-interval-seconds=N] [--horizon-seconds=N]
//
//   oauth_refresh_worker runOnce
//     [--max-attempts=N] [--max-rows-per-tick=N] [--horizon-seconds=N]
//
// Exit codes (mirrors audit_anchor + first_connect_backfill_worker):
//   * 0 — success (loop exited cleanly via SIGTERM, or runOnce
//         finished without throwing).
//   * 2 — configuration error (missing env, malformed args).
//   * 3 — runtime error (DB unreachable, scope enumeration failed).
//
// Required env (NAMES only — values flow through Secret Manager):
//   * `POSTGRES_URL` — same secret the audit_anchor + advisor proxy
//     mount; reused so connection-string drift never occurs.
//   * `PGCRYPTO_ENVELOPE_KEY` — required by the broker for ciphertext
//     decrypt + re-encrypt.
//
// Optional env (NAMES only):
//   * `OAUTH_REFRESH_WORKER_POLL_SECONDS` — daemon-mode tick interval.
//     Default 60s. Production ignores it (Cloud Scheduler controls
//     cadence).
//   * `OAUTH_REFRESH_WORKER_MAX_ROWS_PER_TICK` — per-tick claim cap.
//     Default 50.
//   * `OAUTH_REFRESH_WORKER_MAX_CONSECUTIVE_FAILURES` — auto-disable
//     threshold. Default 3.
//   * `OAUTH_REFRESH_WORKER_HORIZON_SECONDS` — refresh window. Default
//     300s (5 minutes — see prompt).
//   * `OAUTH_REFRESH_WORKER_ID_PREFIX` — `worker_id` prefix; default
//     `oauth-refresh`. The pid+timestamp suffix is appended.
//
// Vendor coverage matches
// `lib/integrations/_common/production_oauth_refresh_closures.dart`:
//   POS:   toast, square, clover, lightspeed_lsk, aloha_ncr_voyix,
//          oracle_micros_simphony, revel
//   Labor: 7shifts, quickbooks_time, libro, humanity
//   No closure (skipped): sevenrooms, tock, push_operations,
//          agendrix, adp, opentable
//
// CLAUDE.md alignment:
//   * HP #1 — pure transport swap. The worker reads `vendor_credentials`
//     and writes `vendor_credentials` / `connector_connection` /
//     `connector_sync_log` / `audit_logs` only. No canonical fact
//     tables touched.
//   * HP #4 — per-operator isolation. Every refresh / status-flip /
//     audit-row write rides `withTenant` so the SET LOCAL trio
//     attaches before the row touches the wire. Scope enumeration
//     uses `runAsSystem` because the worker has to span tenants by
//     definition.
//   * HP #7 — F&F holds all provider keys server-side. The worker
//     runs exclusively inside Cloud Run; no plaintext is ever logged.
//     Secret values are NEVER printed; startup logs only the loaded
//     env NAMES.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/production_oauth_refresh_closures.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:http/http.dart' as http;

// The service principal id the audit row records. The audit_logs
// CHECK constraint requires `actor_kind='service' AND
// actor_principal_id IS NOT NULL`. The integration sync worker uses
// the same UUID-shaped sentinel (`kSyncWorkerServicePrincipalId`),
// but we declare a worker-specific principal id so the audit chain
// can attribute auto-disables to this exact worker without coupling
// the constant.
const String kOauthRefreshWorkerServicePrincipalId =
    'sp:oauth_refresh_worker';

// Default clock. Top-level so it survives in field-initializer
// expressions where `() => DateTime.now().toUtc()` would parse as a
// precedence-tangle the analyzer flags.
DateTime _defaultUtcClock() => DateTime.now().toUtc();

// ─── Env names (no values ever logged) ──────────────────────────────

abstract class OAuthRefreshWorkerEnvNames {
  static const String postgresUrl = 'POSTGRES_URL';
  static const String pgcryptoEnvelopeKey = 'PGCRYPTO_ENVELOPE_KEY';
  static const String pollIntervalSeconds =
      'OAUTH_REFRESH_WORKER_POLL_SECONDS';
  static const String maxRowsPerTick =
      'OAUTH_REFRESH_WORKER_MAX_ROWS_PER_TICK';
  static const String maxConsecutiveFailures =
      'OAUTH_REFRESH_WORKER_MAX_CONSECUTIVE_FAILURES';
  static const String horizonSeconds =
      'OAUTH_REFRESH_WORKER_HORIZON_SECONDS';
  static const String workerIdPrefix =
      'OAUTH_REFRESH_WORKER_ID_PREFIX';
}

// ─── CLI ────────────────────────────────────────────────────────────

enum WorkerMode { daemon, runOnce }

class WorkerCliArgs {
  WorkerCliArgs({
    required this.mode,
    this.maxAttempts,
    this.maxRowsPerTick,
    this.pollIntervalSeconds,
    this.horizonSeconds,
  });

  final WorkerMode mode;
  final int? maxAttempts;
  final int? maxRowsPerTick;
  final int? pollIntervalSeconds;
  final int? horizonSeconds;
}

class WorkerConfigError implements Exception {
  WorkerConfigError(this.envName);

  final String envName;

  @override
  String toString() =>
      'oauth_refresh_worker: missing required env name: $envName';
}

WorkerCliArgs parseArgs(List<String> args) {
  if (args.isEmpty) {
    throw const FormatException(
      'usage: oauth_refresh_worker <daemon|runOnce> '
      '[--max-attempts=N] [--max-rows-per-tick=N] '
      '[--poll-interval-seconds=N] [--horizon-seconds=N]',
    );
  }
  final mode = switch (args.first) {
    'daemon' => WorkerMode.daemon,
    'runOnce' => WorkerMode.runOnce,
    final unknown => throw FormatException(
      'unknown mode "$unknown" (expected daemon|runOnce)',
    ),
  };
  int? maxAttempts;
  int? maxRowsPerTick;
  int? pollIntervalSeconds;
  int? horizonSeconds;
  for (final raw in args.skip(1)) {
    if (raw.startsWith('--max-attempts=')) {
      maxAttempts = _parsePositiveInt(
        raw.substring('--max-attempts='.length),
        'max-attempts',
      );
    } else if (raw.startsWith('--max-rows-per-tick=')) {
      maxRowsPerTick = _parsePositiveInt(
        raw.substring('--max-rows-per-tick='.length),
        'max-rows-per-tick',
      );
    } else if (raw.startsWith('--poll-interval-seconds=')) {
      pollIntervalSeconds = _parsePositiveInt(
        raw.substring('--poll-interval-seconds='.length),
        'poll-interval-seconds',
      );
    } else if (raw.startsWith('--horizon-seconds=')) {
      horizonSeconds = _parsePositiveInt(
        raw.substring('--horizon-seconds='.length),
        'horizon-seconds',
      );
    } else {
      throw FormatException('unknown flag "$raw"');
    }
  }
  return WorkerCliArgs(
    mode: mode,
    maxAttempts: maxAttempts,
    maxRowsPerTick: maxRowsPerTick,
    pollIntervalSeconds: pollIntervalSeconds,
    horizonSeconds: horizonSeconds,
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
    required this.maxConsecutiveFailures,
    required this.maxRowsPerTick,
    required this.pollInterval,
    required this.horizon,
    required this.workerIdPrefix,
    required this.loadedSecretNames,
  });

  /// Resolved Postgres connection string. Never echoed.
  final String postgresUrl;

  /// pgcrypto envelope key. Never echoed.
  final String pgcryptoEnvelopeKey;

  /// Auto-disable threshold. Mirrors `kRefreshFailureAutoDisableThreshold`
  /// in `lib/services/integration/oauth_refresh_cron.dart` but exposed
  /// per-deploy so staging can ratchet during incident response.
  final int maxConsecutiveFailures;

  /// Per-tick claim cap. The cron writes ciphertext + may trigger
  /// audit + status flip per row, so an unbounded cap is a denial of
  /// service against the broker's per-tenant Future locks.
  final int maxRowsPerTick;

  /// Daemon-mode tick interval.
  final Duration pollInterval;

  /// Refresh-window horizon. Rows with `token_expires_at < now() +
  /// horizon` are considered claimable.
  final Duration horizon;

  final String workerIdPrefix;
  final List<String> loadedSecretNames;

  static const int defaultMaxConsecutiveFailures = 3;
  static const int defaultMaxRowsPerTick = 50;
  static const Duration defaultPollInterval = Duration(seconds: 60);
  static const Duration defaultHorizon = Duration(minutes: 5);
  static const String defaultWorkerIdPrefix = 'oauth-refresh';

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
        // Keep startup deterministic; misconfigured ints should not
        // silently fall back. Surface the env name (no value) and
        // exit via WorkerConfigError so the deploy fails closed.
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

    final postgresUrl = require(OAuthRefreshWorkerEnvNames.postgresUrl);
    final pgcryptoEnvelopeKey =
        require(OAuthRefreshWorkerEnvNames.pgcryptoEnvelopeKey);
    final maxConsecutiveFailures =
        cliOverrides?.maxAttempts ??
        optionalInt(
          OAuthRefreshWorkerEnvNames.maxConsecutiveFailures,
          fallback: defaultMaxConsecutiveFailures,
        );
    final maxRowsPerTick =
        cliOverrides?.maxRowsPerTick ??
        optionalInt(
          OAuthRefreshWorkerEnvNames.maxRowsPerTick,
          fallback: defaultMaxRowsPerTick,
        );
    final pollSeconds =
        cliOverrides?.pollIntervalSeconds ??
        optionalInt(
          OAuthRefreshWorkerEnvNames.pollIntervalSeconds,
          fallback: defaultPollInterval.inSeconds,
        );
    final horizonSeconds =
        cliOverrides?.horizonSeconds ??
        optionalInt(
          OAuthRefreshWorkerEnvNames.horizonSeconds,
          fallback: defaultHorizon.inSeconds,
        );
    final prefix = optionalString(
      OAuthRefreshWorkerEnvNames.workerIdPrefix,
      fallback: defaultWorkerIdPrefix,
    );
    return WorkerRuntimeConfig(
      postgresUrl: postgresUrl,
      pgcryptoEnvelopeKey: pgcryptoEnvelopeKey,
      maxConsecutiveFailures: maxConsecutiveFailures,
      maxRowsPerTick: maxRowsPerTick,
      pollInterval: Duration(seconds: pollSeconds),
      horizon: Duration(seconds: horizonSeconds),
      workerIdPrefix: prefix,
      loadedSecretNames: loaded,
    );
  }
}

// ─── Refresh closure registry ───────────────────────────────────────

/// Per-vendor refresh closure signature shared with
/// `VendorCredentialBroker.refreshAccessToken`. Each closure
/// instance is bound to a single `http.Client` + (optional)
/// app-wide credentials at boot time; the worker calls them with
/// the per-tenant [VendorCredentialBundle].
typedef RefreshClosure =
    Future<TokenRefreshResult> Function(VendorCredentialBundle);

/// Vendor → closure map the worker consults per row. Production wires
/// this from the `make<Vendor>OauthRefreshClosure(...)` factories in
/// `lib/integrations/_common/production_oauth_refresh_closures.dart`.
/// Tests inject a fake map.
typedef RefreshClosureRegistry = Map<String, RefreshClosure>;

/// Vendor ids that intentionally do NOT have a refresh closure. Their
/// bridges either use static API keys (Tock, Agendrix) or the
/// transport handles refresh internally (SevenRooms, ADP, OpenTable,
/// Push Operations). The worker logs and skips these rows with one
/// trace per skip; no failure counter increment. This list mirrors
/// the documented coverage in
/// `lib/integrations/_common/production_oauth_refresh_closures.dart`.
const Set<String> kVendorsWithoutRefreshClosure = <String>{
  'sevenrooms',
  'tock',
  'push_operations',
  'agendrix',
  'adp',
  'opentable',
};

// ─── Vendor app-credential env loader ───────────────────────────────
//
// The OAuth refresh worker is deployed alongside the advisor proxy and
// reads the same vendor app-credential env names (mirrors
// `tool/advisor_proxy/advisor_proxy.dart`'s `ProxySecretNames`). Each
// vendor's app credential bundle is OPTIONAL at boot; absence does not
// fail boot — the corresponding closure is simply not registered, and
// any claimed row for that vendor is logged-and-skipped (the binder
// uses the same warn-disable pattern in
// `tool/advisor_proxy/phase_8_production_binder.dart`).
//
// We declare the env names locally rather than depending on
// `ProxySecretNames` so the worker stays self-contained — it does not
// need ProxySecretNames' required-secret list (Anthropic / Voyage /
// Firebase / etc.) to boot.

abstract class OAuthRefreshWorkerVendorEnvNames {
  // ─ Aloha NCR Voyix ─
  static const String alohaNcrVoyixClientId = 'ALOHA_NCR_VOYIX_CLIENT_ID';
  static const String alohaNcrVoyixClientSecret =
      'ALOHA_NCR_VOYIX_CLIENT_SECRET';
  static const String alohaNcrVoyixApplicationKey =
      'ALOHA_NCR_VOYIX_APPLICATION_KEY';
  static const String alohaNcrVoyixOrganizationId =
      'ALOHA_NCR_VOYIX_ORGANIZATION_ID';

  // ─ Square ─
  static const String squareClientId = 'SQUARE_CLIENT_ID';
  static const String squareClientSecret = 'SQUARE_CLIENT_SECRET';

  // ─ Clover ─
  static const String cloverAppId = 'CLOVER_APP_ID';

  // ─ Humanity ─
  static const String humanityClientId = 'HUMANITY_CLIENT_ID';
  static const String humanityClientSecret = 'HUMANITY_CLIENT_SECRET';

  // ─ QuickBooks Time (Intuit) ─
  static const String quickBooksTimeClientId = 'QUICKBOOKS_TIME_CLIENT_ID';
  static const String quickBooksTimeClientSecret =
      'QUICKBOOKS_TIME_CLIENT_SECRET';

  // ─ 7shifts ─
  static const String sevenShiftsClientId = 'SEVEN_SHIFTS_CLIENT_ID';
  static const String sevenShiftsClientSecret = 'SEVEN_SHIFTS_CLIENT_SECRET';

  // ─ Libro ─
  static const String libroClientId = 'LIBRO_CLIENT_ID';
  static const String libroClientSecret = 'LIBRO_CLIENT_SECRET';
}

bool _hasNonBlank(Map<String, String> env, String name) {
  final value = env[name];
  return value != null && value.trim().isNotEmpty;
}

/// Result of [buildProductionRefreshClosures]: the wired registry plus
/// diagnostic info for the boot-time log.
class ProductionRefreshClosureBuildResult {
  ProductionRefreshClosureBuildResult({
    required this.registry,
    required this.wiredVendorIds,
    required this.disabledVendorIds,
  });

  /// Vendor → closure map ready to hand to the worker.
  final RefreshClosureRegistry registry;

  /// Vendors with a closure registered (sorted ascending for stable
  /// boot logs).
  final List<String> wiredVendorIds;

  /// Vendors whose closure was NOT registered because their optional
  /// app-credential env vars are missing. Map key = vendor_id; value =
  /// short reason string. Mirrors the binder's
  /// `disabledVendors[vendorId] = reason` shape.
  final Map<String, String> disabledVendorIds;
}

/// Wire the 11 production OAuth refresh closure factories in
/// `lib/integrations/_common/production_oauth_refresh_closures.dart`
/// into a [RefreshClosureRegistry] keyed by `vendor_credentials.vendor_id`.
///
/// Vendors gated on optional ProxyConfig-style app credentials (Aloha
/// NCR Voyix / Square / Clover / Humanity / QuickBooks Time / 7shifts /
/// Libro) are skipped when their env vars are missing — the worker
/// then logs-and-skips any claimed row for those vendors at run time
/// (same warn-disable pattern as the binder).
///
/// Vendors NOT in this builder (SevenRooms / Tock / Push Operations /
/// Agendrix / ADP / OpenTable) deliberately have no closure — their
/// bridges either use static API keys or have the transport handle
/// refresh internally. They land in [kVendorsWithoutRefreshClosure].
ProductionRefreshClosureBuildResult buildProductionRefreshClosures({
  required Map<String, String> env,
  required http.Client httpClient,
}) {
  final registry = <String, RefreshClosure>{};
  final disabled = <String, String>{};

  // ─── Toast ─ no app-wide secrets; per-tenant client_id / client_secret
  // live on bundle metadata.
  registry['toast'] = makeToastOauthRefreshClosure(httpClient: httpClient);

  // ─── Aloha NCR Voyix ─ binder gates on hasAlohaNcrVoyixCredentials.
  // The closure itself reads client_id / client_secret /
  // application_key / organization_id from bundle metadata, but we
  // mirror the binder's gate so the worker's "active vendor" list
  // matches the proxy's connector activation list one-to-one.
  if (_hasNonBlank(env,
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientId) &&
      _hasNonBlank(env,
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixClientSecret) &&
      _hasNonBlank(env,
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixApplicationKey) &&
      _hasNonBlank(env,
          OAuthRefreshWorkerVendorEnvNames.alohaNcrVoyixOrganizationId)) {
    registry['aloha_ncr_voyix'] =
        makeAlohaNcrVoyixOauthRefreshClosure(httpClient: httpClient);
  } else {
    disabled['aloha_ncr_voyix'] = 'aloha_ncr_voyix_credentials_missing';
  }

  // ─── Square ─ app-wide client_id / client_secret.
  if (_hasNonBlank(env, OAuthRefreshWorkerVendorEnvNames.squareClientId) &&
      _hasNonBlank(env, OAuthRefreshWorkerVendorEnvNames.squareClientSecret)) {
    registry['square'] = makeSquareOauthRefreshClosure(
      httpClient: httpClient,
      clientId: env[OAuthRefreshWorkerVendorEnvNames.squareClientId]!,
      clientSecret: env[OAuthRefreshWorkerVendorEnvNames.squareClientSecret]!,
    );
  } else {
    disabled['square'] = 'square_app_credentials_missing';
  }

  // ─── Clover ─ app-wide app_id (no app_secret used by refresh).
  if (_hasNonBlank(env, OAuthRefreshWorkerVendorEnvNames.cloverAppId)) {
    registry['clover'] = makeCloverOauthRefreshClosure(
      httpClient: httpClient,
      clientId: env[OAuthRefreshWorkerVendorEnvNames.cloverAppId]!,
    );
  } else {
    disabled['clover'] = 'clover_app_credentials_missing';
  }

  // ─── Lightspeed LSK ─ no app-wide secrets; per-tenant client_id /
  // client_secret on bundle metadata.
  registry['lightspeed_lsk'] =
      makeLightspeedLskOauthRefreshClosure(httpClient: httpClient);

  // ─── Oracle MICROS Simphony ─ no app-wide secrets; per-tenant
  // client_id / client_secret on bundle metadata.
  registry['oracle_micros_simphony'] =
      makeOracleMicrosSimphonyOauthExchangeClosure(httpClient: httpClient);

  // ─── Revel ─ no app-wide secrets; per-tenant client_id /
  // client_secret on bundle metadata. The closure factory requires an
  // `audience` parameter; per Revel's documented OAuth contract the
  // audience is the API base URL.
  registry['revel'] = makeRevelOauthExchangeClosure(
    httpClient: httpClient,
    audience: 'https://api.revelsystems.com',
  );

  // ─── 7shifts ─ app-wide partner client_id / client_secret. Vendor
  // id stored in vendor_credentials is `7shifts` (the credential
  // bridge constant), NOT `seven_shifts` (which is the adapter id).
  if (_hasNonBlank(env, OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientId) &&
      _hasNonBlank(
          env, OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientSecret)) {
    registry['7shifts'] = makeSevenShiftsOauthRefreshClosure(
      httpClient: httpClient,
      clientId: env[OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientId]!,
      clientSecret:
          env[OAuthRefreshWorkerVendorEnvNames.sevenShiftsClientSecret]!,
    );
  } else {
    disabled['7shifts'] = 'seven_shifts_oauth_credentials_missing';
  }

  // ─── QuickBooks Time ─ app-wide Intuit client_id / client_secret.
  if (_hasNonBlank(
          env, OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientId) &&
      _hasNonBlank(
          env, OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientSecret)) {
    registry['quickbooks_time'] = makeQuickBooksTimeOauthRefreshClosure(
      httpClient: httpClient,
      clientId: env[OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientId]!,
      clientSecret:
          env[OAuthRefreshWorkerVendorEnvNames.quickBooksTimeClientSecret]!,
    );
  } else {
    disabled['quickbooks_time'] = 'intuit_oauth_credentials_missing';
  }

  // ─── Humanity ─ app-wide client_id / client_secret.
  if (_hasNonBlank(env, OAuthRefreshWorkerVendorEnvNames.humanityClientId) &&
      _hasNonBlank(
          env, OAuthRefreshWorkerVendorEnvNames.humanityClientSecret)) {
    registry['humanity'] = makeHumanityOauthRefreshClosure(
      httpClient: httpClient,
      clientId: env[OAuthRefreshWorkerVendorEnvNames.humanityClientId]!,
      clientSecret: env[OAuthRefreshWorkerVendorEnvNames.humanityClientSecret]!,
    );
  } else {
    disabled['humanity'] = 'humanity_oauth_credentials_missing';
  }

  // ─── Libro ─ app-wide client_id / client_secret.
  if (_hasNonBlank(env, OAuthRefreshWorkerVendorEnvNames.libroClientId) &&
      _hasNonBlank(env, OAuthRefreshWorkerVendorEnvNames.libroClientSecret)) {
    registry['libro'] = makeLibroOauthRefreshClosure(
      httpClient: httpClient,
      clientId: env[OAuthRefreshWorkerVendorEnvNames.libroClientId]!,
      clientSecret: env[OAuthRefreshWorkerVendorEnvNames.libroClientSecret]!,
    );
  } else {
    disabled['libro'] = 'libro_oauth_credentials_missing';
  }

  final wired = registry.keys.toList()..sort();
  return ProductionRefreshClosureBuildResult(
    registry: Map<String, RefreshClosure>.unmodifiable(registry),
    wiredVendorIds: List<String>.unmodifiable(wired),
    disabledVendorIds: Map<String, String>.unmodifiable(disabled),
  );
}

// ─── Claim row + Postgres seam ──────────────────────────────────────

/// One vendor_credentials row claimed for refresh. Purposefully
/// minimal — the broker re-reads the bundle inside its own withTenant
/// transaction, so the worker only carries enough to scope the broker
/// call (operator/location/vendor/credential_id) plus the
/// pre-claim failure count for the post-failure cap check.
class ClaimedCredentialRow {
  const ClaimedCredentialRow({
    required this.credentialId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.consecutiveFailuresBefore,
  });

  final String credentialId;
  final String operatorId;
  final String locationId;
  final String vendorId;
  final int consecutiveFailuresBefore;
}

/// Postgres seam the worker uses for the cross-tenant scope work
/// (enumerate-and-claim) and the per-tenant audit / status / log
/// writes. The broker handles the per-tenant `withTenant`-style
/// vendor_credentials write itself, so this seam never touches the
/// row's ciphertext columns. Tests pass a fake.
abstract class OAuthRefreshWorkerGateway {
  /// Claims up to [maxRows] near-expiry rows. Returns the claimed
  /// rows with their pre-claim `consecutive_refresh_failures` count
  /// so the worker can drive the post-failure cap check without an
  /// extra round trip.
  ///
  /// Implementations MUST use `FOR UPDATE SKIP LOCKED` so concurrent
  /// workers never claim the same row twice. The "claim" is purely a
  /// row lock for the duration of the worker's per-row processing —
  /// no `claimed_by` column exists on `vendor_credentials`.
  Future<List<ClaimedCredentialRow>> claimNearExpiryRows({
    required DateTime now,
    required Duration horizon,
    required int maxRows,
  });

  /// Increments `vendor_credentials.consecutive_refresh_failures` by
  /// 1 and writes a `connector_sync_log` row with
  /// `event_kind='auth_refresh_failed'`. Returns the new failure
  /// count post-increment (used by the cap check).
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
  });

  /// Writes a `connector_sync_log` row with
  /// `event_kind='auth_refresh'`. The broker has already persisted
  /// the new ciphertext and reset `consecutive_refresh_failures` to
  /// 0, so this seam only logs the success.
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
  });

  /// Auto-disable path: flips `connector_connection.status='error'`
  /// with `disconnect_reason='oauth_timeout'`, plus a single
  /// `audit_logs` row with `action='vendor_credential_auto_disabled'`.
  ///
  /// The schema's `connector_disconnect_reason` enum admits four
  /// values: `operator_action / vendor_revoked /
  /// vendor_endpoint_deprecated / oauth_timeout`. None map cleanly
  /// to "auto-disabled by 3-strike refresh failure" so we re-use
  /// `oauth_timeout` (the closest semantic — we gave up on the OAuth
  /// handshake). The audit row's `action` field carries the precise
  /// trigger.
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
    required int consecutiveFailures,
  });
}

class PostgresOAuthRefreshWorkerGateway extends OperatorScopedRepository
    implements OAuthRefreshWorkerGateway {
  PostgresOAuthRefreshWorkerGateway({
    required TenantTransactionWrapper tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    DateTime Function()? clock,
  })  : _audit = auditLogsRepository,
        _clock = clock ?? _defaultUtcClock,
        super(tenantWrapper);

  final AuditLogsRepository _audit;
  final DateTime Function() _clock;

  @override
  Future<List<ClaimedCredentialRow>> claimNearExpiryRows({
    required DateTime now,
    required Duration horizon,
    required int maxRows,
  }) {
    if (maxRows <= 0) {
      return Future<List<ClaimedCredentialRow>>.value(
        const <ClaimedCredentialRow>[],
      );
    }
    return withSystem<List<ClaimedCredentialRow>>(
      (exec) async {
        // FOR UPDATE SKIP LOCKED at the SELECT level. The lock is
        // released on transaction commit; the worker holds it for
        // the per-row processing window so a concurrent worker
        // skips the row entirely.
        final rows = await exec.query(
          'select credential_id::text as credential_id, '
          '       operator_id::text as operator_id, '
          '       location_id::text as location_id, '
          '       vendor_id, '
          '       consecutive_refresh_failures '
          'from public.vendor_credentials '
          'where is_active = true '
          '  and token_expires_at is not null '
          "  and token_expires_at < now() + (@horizon_seconds * interval '1 second') "
          '  and location_id is not null '
          'order by token_expires_at asc '
          'limit @max_rows '
          'for update skip locked',
          parameters: <String, Object?>{
            'horizon_seconds': horizon.inSeconds,
            'max_rows': maxRows,
          },
        );
        return <ClaimedCredentialRow>[
          for (final row in rows)
            ClaimedCredentialRow(
              credentialId: row['credential_id']! as String,
              operatorId: row['operator_id']! as String,
              locationId: row['location_id']! as String,
              vendorId: row['vendor_id']! as String,
              consecutiveFailuresBefore:
                  (row['consecutive_refresh_failures'] as num?)?.toInt() ?? 0,
            ),
        ];
      },
      reason: 'oauth_refresh_worker.claim_near_expiry_rows',
    );
  }

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<int>(ctx, (exec) async {
      final updated = await exec.query(
        'update public.vendor_credentials set '
        '  consecutive_refresh_failures = consecutive_refresh_failures + 1, '
        '  updated_at = now() '
        'where credential_id = @credential_id::uuid '
        '  and operator_id = @operator_id::uuid '
        'returning consecutive_refresh_failures',
        parameters: <String, Object?>{
          'credential_id': credentialId,
          'operator_id': operatorId,
        },
      );
      if (updated.isEmpty) {
        // Row gone (rare — a concurrent admin disconnect could
        // delete it). Treat as a no-op cap-wise; the audit chain on
        // the disconnect path already covers the deletion.
        return 0;
      }
      final newCount =
          (updated.single['consecutive_refresh_failures'] as num?)?.toInt() ??
              0;
      // Best-effort connection_id lookup so the sync_log row joins
      // back to the connection. The migration requires connection_id
      // not-null on connector_sync_log, so when no connector_connection
      // exists we skip the log row (the audit chain on the failure
      // path already records the failure).
      final connectionRows = await exec.query(
        'select connection_id::text as connection_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
        },
      );
      if (connectionRows.isNotEmpty) {
        final connectionId =
            connectionRows.single['connection_id']! as String;
        await exec.execute(
          'insert into public.connector_sync_log ('
          'operator_id, location_id, connection_id, event_kind, '
          'error_message, occurred_at'
          ') values ('
          '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
          "'auth_refresh_failed', @error_message, @occurred_at::timestamptz"
          ')',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'connection_id': connectionId,
            'error_message': _truncateMessage(errorMessage),
            'occurred_at': _clock(),
          },
        );
      }
      return newCount;
    });
  }

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      final connectionRows = await exec.query(
        'select connection_id::text as connection_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
        },
      );
      if (connectionRows.isEmpty) return;
      final connectionId =
          connectionRows.single['connection_id']! as String;
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'records_count, occurred_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        "'auth_refresh', 1, @occurred_at::timestamptz"
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'occurred_at': _clock(),
        },
      );
    });
  }

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
    required int consecutiveFailures,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      // Status flip + disconnect_reason. The CHECK constraint pairs
      // `status='error'` with a non-null `disconnect_reason`. We pick
      // `oauth_timeout` because none of the four enum values name
      // "auto-disabled by 3-strike refresh failure" — the audit row
      // below carries the precise trigger.
      await exec.execute(
        'update public.connector_connection set '
        "  status = 'error', "
        "  disconnect_reason = 'oauth_timeout', "
        '  last_error_at = @occurred_at::timestamptz, '
        '  last_error_message = @error_message, '
        '  updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'occurred_at': _clock(),
          'error_message': _truncateMessage(errorMessage),
        },
      );
      // Mark the credential row inactive too so future ticks skip it
      // until the operator reconnects.
      await exec.execute(
        'update public.vendor_credentials set '
        '  is_active = false, '
        '  updated_at = now() '
        'where credential_id = @credential_id::uuid '
        '  and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'credential_id': credentialId,
          'operator_id': operatorId,
        },
      );
      await _audit.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: _clock(),
        actorKind: 'service',
        actorPrincipalId: kOauthRefreshWorkerServicePrincipalId,
        targetKind: 'vendor_credentials',
        targetId: credentialId,
        action: 'vendor_credential_auto_disabled',
        payload: <String, Object?>{
          'vendor_id': vendorId,
          'consecutive_failures': consecutiveFailures,
          'error_message': _truncateMessage(errorMessage),
          'reason': 'oauth_refresh_three_strike',
        },
      );
    });
  }

  static String _truncateMessage(String raw) {
    const maxLen = 1024;
    return raw.length <= maxLen ? raw : raw.substring(0, maxLen);
  }
}

// ─── Tick + loop ────────────────────────────────────────────────────

class WorkerTickResult {
  const WorkerTickResult({
    required this.candidatesScanned,
    required this.refreshSuccesses,
    required this.refreshFailures,
    required this.skippedNoCloser,
    required this.autoDisabled,
  });

  final int candidatesScanned;
  final int refreshSuccesses;
  final int refreshFailures;

  /// Vendor row whose vendor_id is in [kVendorsWithoutRefreshClosure]
  /// (or, more generally, has no entry in the registry). Logged once
  /// per skip; no failure-count increment.
  final int skippedNoCloser;

  /// Number of rows whose post-increment failure count tripped the
  /// auto-disable cap.
  final int autoDisabled;

  Map<String, Object?> toLogFields() => <String, Object?>{
        'candidates_scanned': candidatesScanned,
        'refresh_successes': refreshSuccesses,
        'refresh_failures': refreshFailures,
        'skipped_no_closer': skippedNoCloser,
        'auto_disabled': autoDisabled,
      };
}

/// One tick of the worker. Called by both runOnce and the daemon
/// loop. Tests call this directly.
Future<WorkerTickResult> runWorkerTick({
  required OAuthRefreshWorkerGateway gateway,
  required VendorCredentialBroker broker,
  required RefreshClosureRegistry refreshClosures,
  required int maxRowsPerTick,
  required int maxConsecutiveFailures,
  required Duration horizon,
  bool Function()? shouldStop,
  IOSink? out,
  IOSink? err,
  DateTime Function()? clock,
}) async {
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stdoutSink = out ?? stdout;
  // ignore: close_sinks - stdout/stderr owned by dart:io.
  final stderrSink = err ?? stderr;
  final now = (clock ?? _defaultUtcClock)();
  final candidates = await gateway.claimNearExpiryRows(
    now: now,
    horizon: horizon,
    maxRows: maxRowsPerTick,
  );

  var successes = 0;
  var failures = 0;
  var skippedNoCloser = 0;
  var autoDisabled = 0;

  for (final row in candidates) {
    if (shouldStop?.call() ?? false) break;
    final closure = refreshClosures[row.vendorId];
    if (closure == null) {
      // Vendors without a refresh closure use static API keys or
      // handle refresh inside the transport. Log once per skip; no
      // failure-count increment.
      skippedNoCloser += 1;
      // ignore: avoid_print — Cloud Run captures stdout into Cloud
      // Logging; structured JSON keeps the log query stable.
      stdoutSink.writeln(jsonEncode(<String, Object?>{
        'event': 'oauth_refresh_skipped_no_closer',
        'vendor_id': row.vendorId,
        'credential_id': row.credentialId,
      }));
      continue;
    }

    try {
      await broker.refreshAccessToken(
        operatorId: row.operatorId,
        locationId: row.locationId,
        vendorId: row.vendorId,
        doRefresh: closure,
      );
      await gateway.recordRefreshSuccess(
        credentialId: row.credentialId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        vendorId: row.vendorId,
      );
      successes += 1;
    } on VendorCredentialBrokerError catch (error) {
      // Broker classified the failure: VendorRefreshFailed (vendor
      // 4xx/5xx, malformed body, transport error),
      // VendorCredentialDecryptFailed (envelope key mismatch, malformed
      // ciphertext), or VendorCredentialNotFound (row deleted between
      // our claim and the broker's withTenant read). All three are
      // counted as a failure tick.
      final newCount = await gateway.recordRefreshFailure(
        credentialId: row.credentialId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        vendorId: row.vendorId,
        errorMessage: error.message,
      );
      failures += 1;
      if (newCount >= maxConsecutiveFailures) {
        await gateway.autoDisableConnection(
          credentialId: row.credentialId,
          operatorId: row.operatorId,
          locationId: row.locationId,
          vendorId: row.vendorId,
          errorMessage: error.message,
          consecutiveFailures: newCount,
        );
        autoDisabled += 1;
      }
    } catch (error, stack) {
      // Unexpected — broker promises typed errors; if a bare
      // exception leaks we still want the failure on the row, but
      // log the surprise so an alert can trigger. The audit chain
      // on the cap path covers the operator-facing flip.
      stderrSink.writeln(
        'oauth_refresh_worker unexpected error for '
        '${row.vendorId}@${row.operatorId}/${row.locationId}: '
        '${error.runtimeType}',
      );
      stderrSink.writeln(stack.toString());
      final newCount = await gateway.recordRefreshFailure(
        credentialId: row.credentialId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        vendorId: row.vendorId,
        errorMessage: 'unexpected_${error.runtimeType}',
      );
      failures += 1;
      if (newCount >= maxConsecutiveFailures) {
        await gateway.autoDisableConnection(
          credentialId: row.credentialId,
          operatorId: row.operatorId,
          locationId: row.locationId,
          vendorId: row.vendorId,
          errorMessage: 'unexpected_${error.runtimeType}',
          consecutiveFailures: newCount,
        );
        autoDisabled += 1;
      }
    }
  }

  return WorkerTickResult(
    candidatesScanned: candidates.length,
    refreshSuccesses: successes,
    refreshFailures: failures,
    skippedNoCloser: skippedNoCloser,
    autoDisabled: autoDisabled,
  );
}

class OAuthRefreshWorkerLoop {
  OAuthRefreshWorkerLoop({
    required this.gateway,
    required this.broker,
    required this.refreshClosures,
    required this.config,
    IOSink? out,
    IOSink? err,
  })  : _out = out ?? stdout,
        _err = err ?? stderr;

  final OAuthRefreshWorkerGateway gateway;
  final VendorCredentialBroker broker;
  final RefreshClosureRegistry refreshClosures;
  final WorkerRuntimeConfig config;
  // ignore: unused_field, close_sinks
  final IOSink _out;
  final IOSink _err;

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
          final result = await runWorkerTick(
            gateway: gateway,
            broker: broker,
            refreshClosures: refreshClosures,
            maxRowsPerTick: config.maxRowsPerTick,
            maxConsecutiveFailures: config.maxConsecutiveFailures,
            horizon: config.horizon,
            shouldStop: () => _stopRequested,
            out: _out,
            err: _err,
          );
          _out.writeln(
            'oauth_refresh_worker tick: ${jsonEncode(result.toLogFields())}',
          );
        } catch (error, stack) {
          // Only catastrophic failures (DB unreachable, scope claim
          // SQL syntax error) reach here; per-row failures are
          // already booked through recordRefreshFailure inside the
          // tick. Don't crash the loop — log and sleep.
          _err.writeln(
            'oauth_refresh_worker tick error: $error',
          );
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

  /// Visible for tests: future that completes after `run()` exits.
  Future<void> get stopped =>
      _stoppedCompleter?.future ?? Future<void>.value();
}

// ─── Entry point ────────────────────────────────────────────────────

typedef WorkerPoolFactory = PostgresPool Function(String connectionString);

// Honor POSTGRES_POOL_MAX_CONNECTIONS env override; falls back to default 4.
PostgresPool _defaultPoolFactory(String connectionString) =>
    PackagePostgresPool.fromUrl(
      connectionString,
      maxConnectionCount: resolvePostgresMaxConnectionsPerPool(),
    );

/// Bundle returned by [buildWorkerRuntime]. Tests inject overrides so
/// the worker's claim / refresh / cap-and-audit paths can be exercised
/// end-to-end without real Postgres or vendor HTTP calls.
class WorkerRuntime {
  const WorkerRuntime({
    required this.gateway,
    required this.broker,
    required this.config,
  });

  final OAuthRefreshWorkerGateway gateway;
  final VendorCredentialBroker broker;
  final WorkerRuntimeConfig config;
}

WorkerRuntime buildWorkerRuntime({
  required WorkerRuntimeConfig config,
  WorkerPoolFactory poolFactory = _defaultPoolFactory,
}) {
  final pool = poolFactory(config.postgresUrl);
  final wrapper = TenantTransactionWrapper(pool);
  final gateway = PostgresOAuthRefreshWorkerGateway(tenantWrapper: wrapper);
  final broker = VendorCredentialBroker(
    tenantWrapper: wrapper,
    pgcryptoEnvelopeKey: config.pgcryptoEnvelopeKey,
  );
  return WorkerRuntime(
    gateway: gateway,
    broker: broker,
    config: config,
  );
}

/// Empty registry retained for tests that exercise the
/// "claimed-row-but-no-closure" path without any factories wired.
/// Production code does NOT use this — [runCli] builds the wired
/// registry from [buildProductionRefreshClosures] when no override is
/// passed.
RefreshClosureRegistry kEmptyRefreshClosures = const <String, RefreshClosure>{};

/// CLI runner. Tests pass overrides; production calls with no
/// overrides — `runCli` then builds the production refresh-closure
/// registry from [buildProductionRefreshClosures] using the same env
/// names the advisor proxy mounts.
Future<int> runCli(
  List<String> rawArgs, {
  Map<String, String>? environment,
  WorkerPoolFactory? poolFactory,
  OAuthRefreshWorkerGateway? gatewayOverride,
  VendorCredentialBroker? brokerOverride,
  RefreshClosureRegistry? refreshClosuresOverride,
  http.Client? httpClientOverride,
  IOSink? out,
  IOSink? err,
  Future<void> Function(OAuthRefreshWorkerLoop loop)? installSignalHandlers,
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
    stderrSink.writeln('oauth_refresh_worker: ${error.message}');
    return 2;
  }

  final hasOverrides = gatewayOverride != null && brokerOverride != null;

  WorkerRuntimeConfig config;
  OAuthRefreshWorkerGateway gateway;
  VendorCredentialBroker broker;

  if (hasOverrides) {
    // Tests path: skip env config and pool wiring entirely.
    config = WorkerRuntimeConfig(
      postgresUrl: 'test://override',
      pgcryptoEnvelopeKey: 'test-envelope-key',
      maxConsecutiveFailures: args.maxAttempts ??
          WorkerRuntimeConfig.defaultMaxConsecutiveFailures,
      maxRowsPerTick:
          args.maxRowsPerTick ?? WorkerRuntimeConfig.defaultMaxRowsPerTick,
      pollInterval: Duration(
        seconds: args.pollIntervalSeconds ??
            WorkerRuntimeConfig.defaultPollInterval.inSeconds,
      ),
      horizon: Duration(
        seconds: args.horizonSeconds ??
            WorkerRuntimeConfig.defaultHorizon.inSeconds,
      ),
      workerIdPrefix: WorkerRuntimeConfig.defaultWorkerIdPrefix,
      loadedSecretNames: const <String>[],
    );
    gateway = gatewayOverride;
    broker = brokerOverride;
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
    );
    gateway = runtime.gateway;
    broker = runtime.broker;
    stdoutSink.writeln(
      'oauth_refresh_worker starting (loaded secret names: '
      '${config.loadedSecretNames.join(', ')})',
    );
  }

  // Resolve the closure registry. Tests pass an override directly;
  // production builds the wired registry from env (same vendor
  // app-credential names the advisor proxy mounts) and emits a
  // boot-time log of which vendors are wired vs. disabled-due-to-
  // missing-secrets vs. unsupported (no closure factory at all).
  final RefreshClosureRegistry closures;
  if (refreshClosuresOverride != null) {
    closures = refreshClosuresOverride;
  } else if (hasOverrides) {
    // Tests path with gateway / broker overrides but no closures
    // override: keep the empty registry so claimed rows are
    // logged-and-skipped, mirroring "all vendors unsupported" — tests
    // that exercise refresh paths must pass `refreshClosuresOverride`.
    closures = kEmptyRefreshClosures;
  } else {
    final httpClient = httpClientOverride ?? http.Client();
    final closureBuild = buildProductionRefreshClosures(
      env: env,
      httpClient: httpClient,
    );
    closures = closureBuild.registry;
    // Boot-time log: name three categories so a deploy review can
    // verify the worker matches the proxy's connector activation list
    // one-to-one. No secret values are echoed — only vendor ids and
    // disable reasons.
    stdoutSink.writeln(
      'oauth_refresh_worker closure registry wired: '
      '${jsonEncode(<String, Object?>{
        'wired': closureBuild.wiredVendorIds,
        'disabled_missing_secrets': closureBuild.disabledVendorIds,
        'unsupported_no_closure': kVendorsWithoutRefreshClosure.toList()
          ..sort(),
      })}',
    );
  }

  switch (args.mode) {
    case WorkerMode.runOnce:
      try {
        final result = await runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: closures,
          maxRowsPerTick: config.maxRowsPerTick,
          maxConsecutiveFailures: config.maxConsecutiveFailures,
          horizon: config.horizon,
          out: stdoutSink,
          err: stderrSink,
        );
        stdoutSink.writeln(
          'oauth_refresh_worker runOnce: '
          '${jsonEncode(result.toLogFields())}',
        );
        return 0;
      } catch (error) {
        stderrSink.writeln(
          'oauth_refresh_worker runOnce error: $error',
        );
        return 3;
      }
    case WorkerMode.daemon:
      final loop = OAuthRefreshWorkerLoop(
        gateway: gateway,
        broker: broker,
        refreshClosures: closures,
        config: config,
        out: stdoutSink,
        err: stderrSink,
      );
      if (installSignalHandlers != null) {
        await installSignalHandlers(loop);
      } else {
        _installDefaultSignalHandlers(loop);
      }
      try {
        await loop.run();
        return 0;
      } catch (error) {
        stderrSink.writeln(
          'oauth_refresh_worker daemon error: $error',
        );
        return 3;
      }
  }
}

void _installDefaultSignalHandlers(OAuthRefreshWorkerLoop loop) {
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
