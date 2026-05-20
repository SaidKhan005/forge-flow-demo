// Phase 9.0Σ.f — audit_anchor CLI entry point.
//
// Three modes, mirroring the runbook:
//
//   * `sweep` — the daily Cloud Run scheduled-job entry point
//     (B43). Resolves the operator-id list via [OperatorIdReader]
//     (a `runAsSystem` read of `public.operators`) and then drives
//     the existing per-operator anchor logic for each. Takes no
//     `--operator-id` flag; the resolution happens inside the tool
//     so the deployed command shape is `audit_anchor sweep`. The
//     orchestrator's `runInTenantContext` posture is preserved
//     because operator enumeration is the seam, not the per-operator
//     work.
//
//   * `anchor` — sweeps every operator id provided via
//     `--operator-id` and anchors every unanchored completed chain
//     (chain_date < UTC today). One blob is written per chain via the
//     [AuditAnchorBlobClient] abstraction; one row is inserted into
//     `public.audit_chain_anchors`. Used for manual reruns when an
//     operator wants to anchor a specific subset (e.g. after a job
//     pod crash leaves the daily firing partial). Live Azure Blob
//     wiring is NOT enabled until the operator deploys the Cloud Run
//     job with the real client; until then, the production
//     [AuditAnchorBlobClient] binding is the
//     [ScaffoldRejectingAuditAnchorBlobClient] fail-closed scaffold
//     (matching `tool/advisor_proxy`'s scaffold-rejecter pattern).
//
//   * `verify` — verifies one `(operator_id, chain_date)` chain
//     against the in-DB row-by-row hash, the anchor row, and the
//     Blob evidence. Exit status communicates the outcome (0 ok,
//     1 violation, 2 config error, 3 runtime error).
//
// CLI contract:
//
//   audit_anchor sweep  [--as-of-utc=<YYYY-MM-DD>]
//   audit_anchor anchor --operator-id=<uuid> [--operator-id=<uuid> …]
//                       [--as-of-utc=<YYYY-MM-DD>]
//   audit_anchor verify --operator-id=<uuid> --chain-date=<YYYY-MM-DD>
//
// All env reads use *names only*; no values are echoed to stdout/
// stderr. The runbook (`runbooks/audit_chain_verify_runbook.md`) is
// authoritative for the env-name list and the Cloud Run job wiring.

import 'dart:async';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../advisor_proxy/email_dispatch/notification_event_fanout.dart';
import '../advisor_proxy/email_dispatch/notification_event_hooks.dart';
import '../advisor_proxy/email_dispatch/postgres_notification_fanout_bindings.dart';
import 'audit_anchor.dart';
import 'azure_blob_client.dart';

/// Returned by [parseArgs] so the CLI can dispatch on the mode without
/// scattering arg parsing across the entry point.
class AuditAnchorCliArgs {
  AuditAnchorCliArgs({
    required this.mode,
    required this.operatorIds,
    this.chainDateUtc,
    this.asOfUtc,
  });

  final AuditAnchorMode mode;
  final List<String> operatorIds;
  final DateTime? chainDateUtc;
  final DateTime? asOfUtc;
}

enum AuditAnchorMode { sweep, anchor, verify }

/// Parses the CLI arguments into [AuditAnchorCliArgs]. Throws
/// [FormatException] with a single-line, no-secrets message when the
/// arguments are malformed; the entry point maps that to exit code 2.
AuditAnchorCliArgs parseArgs(List<String> args) {
  if (args.isEmpty) {
    throw const FormatException(
      'usage: audit_anchor <sweep|anchor|verify> '
      '[--operator-id=<uuid>] [--chain-date=<YYYY-MM-DD>] '
      '[--as-of-utc=<YYYY-MM-DD>]',
    );
  }
  final mode = switch (args.first) {
    'sweep' => AuditAnchorMode.sweep,
    'anchor' => AuditAnchorMode.anchor,
    'verify' => AuditAnchorMode.verify,
    final unknown => throw FormatException(
        'unknown mode "$unknown" (expected sweep|anchor|verify)'),
  };
  final operatorIds = <String>[];
  DateTime? chainDate;
  DateTime? asOf;
  for (final raw in args.skip(1)) {
    if (raw.startsWith('--operator-id=')) {
      operatorIds.add(raw.substring('--operator-id='.length));
    } else if (raw.startsWith('--chain-date=')) {
      chainDate = _parseUtcDate(raw.substring('--chain-date='.length));
    } else if (raw.startsWith('--as-of-utc=')) {
      asOf = _parseUtcDate(raw.substring('--as-of-utc='.length));
    } else {
      throw FormatException('unknown flag "$raw"');
    }
  }
  switch (mode) {
    case AuditAnchorMode.sweep:
      if (operatorIds.isNotEmpty) {
        throw const FormatException(
          'sweep does not accept --operator-id; the tool resolves the '
          'operator list from public.operators',
        );
      }
      if (chainDate != null) {
        throw const FormatException(
          'sweep does not accept --chain-date',
        );
      }
    case AuditAnchorMode.anchor:
      if (operatorIds.isEmpty) {
        throw const FormatException(
          '--operator-id is required (one or more)',
        );
      }
    case AuditAnchorMode.verify:
      if (operatorIds.length != 1) {
        throw const FormatException(
          'verify requires exactly one --operator-id',
        );
      }
      if (chainDate == null) {
        throw const FormatException('verify requires --chain-date');
      }
  }
  return AuditAnchorCliArgs(
    mode: mode,
    operatorIds: operatorIds,
    chainDateUtc: chainDate,
    asOfUtc: asOf,
  );
}

DateTime _parseUtcDate(String text) {
  final parsed = DateTime.parse('${text}T00:00:00Z');
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// Reads required env vars and returns a configuration bundle. The
/// bundle holds the resolved secret *values* the production wiring
/// needs (e.g. the live Postgres connection string for
/// `PackagePostgresPool.fromUrl`); CLI / startup logging only ever
/// echoes [loadedSecretNames] (names, not values), matching the
/// `tool/advisor_proxy` posture. Throws [AuditAnchorConfigError] on
/// the first missing var; the entry point maps that to exit 2 and
/// prints only the var name.
class AuditAnchorRuntimeConfig {
  AuditAnchorRuntimeConfig({
    required this.containerName,
    required this.endpoint,
    required this.postgresUrl,
    required this.loadedSecretNames,
    this.azureAdTenantId,
    this.azureAdClientId,
  });

  final String containerName;
  final String endpoint;

  /// Resolved Postgres connection string. Passed to the pool factory
  /// (typically `PackagePostgresPool.fromUrl`). Never echoed to
  /// stdout/stderr.
  final String postgresUrl;
  final List<String> loadedSecretNames;

  /// Azure AD tenant ID. When BOTH this and [azureAdClientId] are set,
  /// the default blob-client factory builds a live
  /// `AzureBlobAuditAnchorBlobClient` against
  /// `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token`.
  /// Either-unset keeps the fail-closed scaffold rejecter.
  final String? azureAdTenantId;

  /// Azure AD app-registration client id for the federated identity.
  final String? azureAdClientId;

  /// True iff the live Azure Blob wiring is fully configured. The
  /// default blob-client factory uses this to decide between
  /// `AzureBlobAuditAnchorBlobClient` and the scaffold rejecter.
  bool get hasLiveAzureBlobWiring =>
      (azureAdTenantId?.isNotEmpty ?? false) &&
      (azureAdClientId?.isNotEmpty ?? false);

  static AuditAnchorRuntimeConfig fromEnvironment(Map<String, String> env) {
    final loaded = <String>[];
    String require(String name) {
      final value = env[name];
      if (value == null || value.isEmpty) {
        throw AuditAnchorConfigError(name);
      }
      loaded.add(name);
      return value;
    }

    String? optional(String name) {
      final value = env[name];
      if (value == null || value.isEmpty) return null;
      loaded.add(name);
      return value;
    }

    final container = require(AuditAnchorEnvNames.azureBlobContainer);
    final endpoint = require(AuditAnchorEnvNames.azureBlobEndpoint);
    final postgresUrl = require(AuditAnchorEnvNames.postgresUrl);
    final tenantId = optional(AuditAnchorEnvNames.azureAdTenantId);
    final clientId = optional(AuditAnchorEnvNames.azureAdClientId);
    return AuditAnchorRuntimeConfig(
      containerName: container,
      endpoint: endpoint,
      postgresUrl: postgresUrl,
      loadedSecretNames: loaded,
      azureAdTenantId: tenantId,
      azureAdClientId: clientId,
    );
  }
}

typedef AuditAnchorPoolFactory = PostgresPool Function(String connectionString);
typedef AuditAnchorBlobClientFactory = AuditAnchorBlobClient Function(
  AuditAnchorRuntimeConfig config,
);

/// Bundle returned by [buildAuditAnchorRuntime]: the orchestrator the
/// per-operator anchor/verify path drives, plus the operator-id
/// reader the daily `sweep` mode uses to enumerate operators, plus
/// the advisory-lock seam (sweep guard) and the lock-id reader
/// (constants table lookup) added in code-health lane L9. All four
/// share a single [TenantTransactionWrapper] so the production
/// runtime opens one Postgres pool, not multiple.
class AuditAnchorRuntime {
  const AuditAnchorRuntime({
    required this.orchestrator,
    required this.operatorIdReader,
    required this.sweepLockIdReader,
    required this.sweepAdvisoryLock,
    this.notificationEventFanout,
  });

  final AuditAnchorOrchestrator orchestrator;
  final OperatorIdReader operatorIdReader;
  final SweepLockIdReader sweepLockIdReader;
  final SweepAdvisoryLock sweepAdvisoryLock;

  /// Wave 2 EN-3-FU - production [NotificationEventFanout] wired
  /// against the four Postgres seam adapters in
  /// `tool/advisor_proxy/email_dispatch/postgres_notification_fanout_bindings.dart`.
  /// `main()` composes a fanout-backed `onAnchorFailure` hook from
  /// this instance via `emitAuditAnchorFailure`. Tests pass their
  /// own `onAnchorFailure` to `runCli` and bypass this entirely.
  final NotificationEventFanout? notificationEventFanout;
}

/// Default pool factory — wraps `PackagePostgresPool.fromUrl` so the
/// CLI builds a real Postgres pool against the live `POSTGRES_URL`
/// env value at deploy time. Identical posture to
/// `tool/advisor_proxy/proxy_bootstrap.dart`'s
/// `buildAuthSessionLedgerWriter` default.
// Honor POSTGRES_POOL_MAX_CONNECTIONS env override; falls back to default 20.
PostgresPool _defaultPoolFactory(String connectionString) =>
    PackagePostgresPool.fromUrl(
      connectionString,
      maxConnectionCount: resolvePostgresMaxConnectionsPerPool(),
    );

/// Default Blob client. When the runtime config carries both
/// [AuditAnchorRuntimeConfig.azureAdTenantId] and [azureAdClientId]
/// (i.e. `AZURE_AD_TENANT_ID` and `AZURE_AD_CLIENT_ID` are set), this
/// returns the live [AzureBlobAuditAnchorBlobClient] backed by
/// [WorkloadIdentityFederationTokenProvider]. Either-unset keeps the
/// fail-closed [ScaffoldRejectingAuditAnchorBlobClient] so dev /
/// local runs see a deterministic error rather than silently
/// no-op'ing.
AuditAnchorBlobClient _defaultBlobClientFactory(
  AuditAnchorRuntimeConfig config,
) {
  if (!config.hasLiveAzureBlobWiring) {
    return const ScaffoldRejectingAuditAnchorBlobClient();
  }
  final tokenProvider = WorkloadIdentityFederationTokenProvider(
    tenantId: config.azureAdTenantId!,
    clientId: config.azureAdClientId!,
  );
  return AzureBlobAuditAnchorBlobClient(
    endpoint: config.endpoint,
    tokenProvider: tokenProvider,
  );
}

/// Production wiring. Builds the orchestrator + operator-id reader
/// from env-derived config and the supplied factories. Both share a
/// single Postgres pool (one `TenantTransactionWrapper`) so the
/// daily `sweep` run opens exactly one connection factory, not two.
/// Tests inject [orchestrator] / [operatorIdReader] via
/// `runCli(orchestratorOverride: ..., operatorIdReaderOverride: ...)`.
AuditAnchorRuntime buildAuditAnchorRuntime(
  AuditAnchorRuntimeConfig config, {
  AuditAnchorPoolFactory poolFactory = _defaultPoolFactory,
  AuditAnchorBlobClientFactory blobClientFactory =
      _defaultBlobClientFactory,
  String defaultLocationId = '00000000-0000-0000-0000-000000000000',
  String defaultUserId = '00000000-0000-0000-0000-000000000000',
}) {
  // The factory takes the *resolved* connection string from
  // [AuditAnchorRuntimeConfig.postgresUrl]. The bundle is built from
  // env values (resolved once at startup); the CLI never echoes the
  // value back to stdout/stderr — only the env *name* appears in
  // the diagnostic line.
  final pool = poolFactory(config.postgresUrl);
  final wrapper = TenantTransactionWrapper(pool);
  final reader = PostgresAuditChainReader(
    wrapper: wrapper,
    defaultLocationId: defaultLocationId,
    defaultUserId: defaultUserId,
  );
  final writer = PostgresAuditChainAnchorWriter(
    wrapper: wrapper,
    defaultLocationId: defaultLocationId,
    defaultUserId: defaultUserId,
  );
  final orchestrator = AuditAnchorOrchestrator(
    reader: reader,
    anchorWriter: writer,
    blobClient: blobClientFactory(config),
    containerName: config.containerName,
  );
  final operatorIdReader =
      PostgresOperatorIdReader(wrapper: wrapper);
  final sweepLockIdReader = PostgresSweepLockIdReader(wrapper: wrapper);
  final sweepAdvisoryLock = PostgresSweepAdvisoryLock(wrapper: wrapper);
  // Wave 2 EN-3-FU - NotificationEventFanout production binding.
  // The audit_anchor CLI uses a single Postgres pool (deploy uses
  // a single Postgres role that holds both `service_role` and
  // `forge_admin`); the fanout's cross-user enumeration calls
  // `runAsSystem` to elevate per-transaction via SET LOCAL ROLE.
  final notificationEventFanout = buildPostgresNotificationEventFanout(
    adminWrapper: wrapper,
    pushOutboxRepository: MobilePushOutboxRepository(wrapper),
  );
  return AuditAnchorRuntime(
    orchestrator: orchestrator,
    operatorIdReader: operatorIdReader,
    sweepLockIdReader: sweepLockIdReader,
    sweepAdvisoryLock: sweepAdvisoryLock,
    notificationEventFanout: notificationEventFanout,
  );
}

/// Back-compat shim. Existing callers / tests that only need the
/// orchestrator (anchor/verify, no sweep) keep their signature.
/// Internally delegates to [buildAuditAnchorRuntime] so both paths
/// share the same wiring.
AuditAnchorOrchestrator buildOrchestrator(
  AuditAnchorRuntimeConfig config, {
  AuditAnchorPoolFactory poolFactory = _defaultPoolFactory,
  AuditAnchorBlobClientFactory blobClientFactory =
      _defaultBlobClientFactory,
  String defaultLocationId = '00000000-0000-0000-0000-000000000000',
  String defaultUserId = '00000000-0000-0000-0000-000000000000',
}) {
  return buildAuditAnchorRuntime(
    config,
    poolFactory: poolFactory,
    blobClientFactory: blobClientFactory,
    defaultLocationId: defaultLocationId,
    defaultUserId: defaultUserId,
  ).orchestrator;
}

/// CLI entry point. Exit codes:
///
///   * 0 — success (no violations).
///   * 1 — anchor produced or verify reported a chain/anchor/blob
///         violation.
///   * 2 — configuration error (missing env, malformed args).
///   * 3 — runtime error (DB unreachable, Blob unavailable, operator
///         enumeration failed). The message identifies the failing
///         component but never echoes secret values.
/// Optional hook fired when an audit anchor outcome surfaces a
/// failure (chain hash mismatch, blob unavailable, runtime error,
/// recovered-failed). Phase 8 W2.B wires this to the
/// `notif.audit.anchor_failure` fanout helper in
/// `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart`.
///
/// Hooks are best-effort -- the audit_anchor CLI swallows
/// exceptions from the hook so a notification-side failure never
/// changes the anchor exit code.
typedef AuditAnchorFailureHook = Future<void> Function({
  required String operatorId,
  required String chainDateIso,
  required String reason,
});

Future<int> runCli(
  List<String> rawArgs, {
  Map<String, String>? environment,
  AuditAnchorPoolFactory? poolFactory,
  AuditAnchorBlobClientFactory? blobClientFactory,
  AuditAnchorOrchestrator? orchestratorOverride,
  OperatorIdReader? operatorIdReaderOverride,
  SweepLockIdReader? sweepLockIdReaderOverride,
  SweepAdvisoryLock? sweepAdvisoryLockOverride,
  ShutdownSignals? shutdownSignals,
  AuditAnchorFailureHook? onAnchorFailure,
  DateTime Function()? clock,
  IOSink? out,
  IOSink? err,
}) async {
  // ignore: close_sinks - stdout/stderr are owned by dart:io, not us.
  final stdoutSink = out ?? stdout;
  // ignore: close_sinks - stdout/stderr are owned by dart:io, not us.
  final stderrSink = err ?? stderr;
  final env = environment ?? Platform.environment;
  final now = (clock ?? () => DateTime.now().toUtc())();

  AuditAnchorCliArgs args;
  try {
    args = parseArgs(rawArgs);
  } on FormatException catch (error) {
    stderrSink.writeln('audit_anchor: ${error.message}');
    return 2;
  }

  AuditAnchorOrchestrator orchestrator;
  OperatorIdReader operatorIdReader;
  SweepLockIdReader sweepLockIdReader;
  SweepAdvisoryLock sweepAdvisoryLock;
  // Wave 2 EN-3-FU - production fanout binding. Tests pass their own
  // `onAnchorFailure` and bypass this path. In production, when the
  // caller passed `null`, the binding falls back to:
  //   1. The fanout-backed hook composed from `runtime.notificationEventFanout`,
  //      which dispatches `notif.audit.anchor_failure` envelopes through
  //      the four Postgres seam adapters.
  //   2. If the runtime did not produce a fanout (test path / degraded
  //      boot), the EN-3 telemetry hook in
  //      `notif_event_telemetry_hook.dart` so the failure still surfaces
  //      as a structured Cloud Logging line.
  NotificationEventFanout? productionFanout;
  // Default operator-id / lock-id reader / advisory lock for non-
  // sweep modes that never call them. The sweep dispatch builds the
  // production reader (or accepts the test override) below.
  if (orchestratorOverride != null) {
    orchestrator = orchestratorOverride;
    operatorIdReader = operatorIdReaderOverride ??
        const _UnusedOperatorIdReader();
    sweepLockIdReader =
        sweepLockIdReaderOverride ?? const _UnusedSweepLockIdReader();
    sweepAdvisoryLock =
        sweepAdvisoryLockOverride ?? const _PassthroughSweepAdvisoryLock();
  } else {
    AuditAnchorRuntimeConfig config;
    try {
      config = AuditAnchorRuntimeConfig.fromEnvironment(env);
    } on AuditAnchorConfigError catch (error) {
      stderrSink.writeln(error.toString());
      return 2;
    }
    // Defaults: PackagePostgresPool.fromUrl for the pool and the
    // scaffold-rejecting Blob client until live Azure wiring lands.
    // Tests pass overrides; production callers do not need to.
    final runtime = buildAuditAnchorRuntime(
      config,
      poolFactory: poolFactory ?? _defaultPoolFactory,
      blobClientFactory:
          blobClientFactory ?? _defaultBlobClientFactory,
    );
    orchestrator = runtime.orchestrator;
    operatorIdReader = operatorIdReaderOverride ?? runtime.operatorIdReader;
    sweepLockIdReader =
        sweepLockIdReaderOverride ?? runtime.sweepLockIdReader;
    sweepAdvisoryLock =
        sweepAdvisoryLockOverride ?? runtime.sweepAdvisoryLock;
    productionFanout = runtime.notificationEventFanout;
    stdoutSink.writeln(
      'audit_anchor starting (loaded secret names: '
      '${config.loadedSecretNames.join(', ')})',
    );
  }

  final AuditAnchorFailureHook? resolvedOnAnchorFailure;
  if (onAnchorFailure != null) {
    // Explicit caller-supplied hook (tests, or `main()` if it wants
    // to keep the EN-3 telemetry fallback). Wins regardless of fanout
    // availability so the test contract stays simple.
    resolvedOnAnchorFailure = onAnchorFailure;
  } else if (productionFanout != null) {
    // Production path: dispatch the failure through the fanout so
    // real push + email rows land. EN-3's telemetry hook becomes the
    // observed-via-logging side channel rather than the primary
    // dispatch path; callers that want the warn alongside should
    // explicitly compose the two via the
    // `_composeAnchorFailureHooks` helper below.
    resolvedOnAnchorFailure = _buildFanoutBackedAnchorFailureHook(
      productionFanout,
    );
  } else {
    resolvedOnAnchorFailure = null;
  }

  // L9: SIGTERM/SIGINT cooperative shutdown. Each long-running mode
  // observes [ShutdownSignals.isShuttingDown] between unit-of-work
  // boundaries (per-operator, per-chain). The default attaches real
  // signal handlers on `dart:io`'s [ProcessSignal]; tests pass a fake
  // so they can assert post-signal behaviour without sending real
  // signals to the test isolate.
  final shutdown = shutdownSignals ?? ShutdownSignals.fromProcessSignals();

  try {
    switch (args.mode) {
      case AuditAnchorMode.sweep:
        return await _runSweepMode(
          orchestrator: orchestrator,
          operatorIdReader: operatorIdReader,
          sweepLockIdReader: sweepLockIdReader,
          sweepAdvisoryLock: sweepAdvisoryLock,
          shutdown: shutdown,
          asOfUtc: args.asOfUtc ?? _utcDate(now),
          nowUtc: now,
          out: stdoutSink,
          err: stderrSink,
        );
      case AuditAnchorMode.anchor:
        return await _runAnchorMode(
          orchestrator: orchestrator,
          operatorIds: args.operatorIds,
          asOfUtc: args.asOfUtc ?? _utcDate(now),
          nowUtc: now,
          shutdown: shutdown,
          out: stdoutSink,
          err: stderrSink,
          onAnchorFailure: resolvedOnAnchorFailure,
        );
      case AuditAnchorMode.verify:
        return await _runVerifyMode(
          orchestrator: orchestrator,
          operatorId: args.operatorIds.single,
          chainDate: args.chainDateUtc!,
          out: stdoutSink,
          err: stderrSink,
          onAnchorFailure: resolvedOnAnchorFailure,
        );
    }
  } finally {
    await shutdown.dispose();
  }
}

/// Sentinel reader for non-sweep modes: should never be called. If a
/// future code path triggers it, the explicit error surfaces faster
/// than a null-deref would.
class _UnusedOperatorIdReader implements OperatorIdReader {
  const _UnusedOperatorIdReader();

  @override
  Future<List<String>> listOperatorIds() {
    throw StateError(
      'OperatorIdReader called outside sweep mode; '
      'orchestratorOverride was supplied without an operator-id '
      'reader override',
    );
  }
}

/// Sentinel reader for non-sweep modes that never read the sweep
/// advisory-lock id. Mirrors [_UnusedOperatorIdReader].
class _UnusedSweepLockIdReader implements SweepLockIdReader {
  const _UnusedSweepLockIdReader();

  @override
  Future<int> readSweepLockId() {
    throw StateError(
      'SweepLockIdReader called outside sweep mode; '
      'orchestratorOverride was supplied without a sweep-lock-id '
      'reader override',
    );
  }
}

/// Pass-through advisory lock for non-sweep modes — runs the body
/// without acquiring or releasing any lock. Anchor / verify modes
/// drive a single operator at a time and do not need to serialize
/// against other invocations.
class _PassthroughSweepAdvisoryLock implements SweepAdvisoryLock {
  const _PassthroughSweepAdvisoryLock();

  @override
  Future<R> withSweepLock<R>({
    required int lockId,
    required Future<R> Function() body,
  }) =>
      body();
}

/// L9: cooperative-shutdown signal source. Production wiring listens
/// on `dart:io` [ProcessSignal.sigterm] / [ProcessSignal.sigint] and
/// flips [isShuttingDown] on first delivery. Tests construct the
/// fake-signal variant via [ShutdownSignals.test] and call
/// [signalShutdown] directly so they can assert post-signal
/// behaviour without sending real signals to the test isolate.
///
/// Cloud Run revision rollover sends SIGTERM 10 seconds before
/// SIGKILL — anchor/recovery workers observe [isShuttingDown] at
/// per-operator boundaries so an in-flight blob write completes
/// (the anchor write is the durable evidence) but the next operator
/// is skipped, leaving a clean handoff to the replacement instance.
class ShutdownSignals {
  ShutdownSignals._({
    required this.subscriptions,
  });

  /// Production wiring: subscribe to SIGTERM and SIGINT. On Windows,
  /// SIGTERM is not delivered to the Dart isolate; SIGINT (Ctrl+C)
  /// is. Both subscriptions are cancelled by [dispose].
  factory ShutdownSignals.fromProcessSignals() {
    final signals = <StreamSubscription<ProcessSignal>>[];
    final wrapper = ShutdownSignals._(subscriptions: signals);
    void onSignal(ProcessSignal signal) {
      wrapper._signalShutdown(signal.toString());
    }

    // SIGTERM is not deliverable to Dart isolates on Windows; the
    // `_StreamImpl.listen` call raises SignalException synchronously
    // there. `Platform.isWindows` is a static check that lets the CLI
    // be runnable from a Windows dev machine while staying production-
    // equivalent on Linux (Cloud Run).
    if (!Platform.isWindows) {
      try {
        signals.add(ProcessSignal.sigterm.watch().listen(onSignal));
      } catch (_) {
        // SIGTERM may still be unsupported on other unusual hosts.
      }
    }
    try {
      signals.add(ProcessSignal.sigint.watch().listen(onSignal));
    } catch (_) {
      // SIGINT.watch() is supported everywhere `dart:io` ships, but
      // catch defensively to keep the CLI runnable in unusual hosts.
    }
    return wrapper;
  }

  /// Test wiring: no real signals; tests call [signalShutdown]
  /// directly to flip the flag.
  factory ShutdownSignals.test() =>
      ShutdownSignals._(subscriptions: <StreamSubscription<ProcessSignal>>[]);

  final List<StreamSubscription<ProcessSignal>> subscriptions;
  bool _shuttingDown = false;
  String? _reason;

  bool get isShuttingDown => _shuttingDown;
  String? get reason => _reason;

  /// Test seam — flips the flag without sending a real signal. Idempotent.
  void signalShutdown([String reason = 'test']) =>
      _signalShutdown(reason);

  void _signalShutdown(String reason) {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _reason = reason;
  }

  /// Cancels every signal subscription. Production callers invoke this
  /// in a `finally` block after [runCli] returns so a long-lived
  /// host process does not leak signal listeners.
  Future<void> dispose() async {
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    subscriptions.clear();
  }
}

Future<int> _runSweepMode({
  required AuditAnchorOrchestrator orchestrator,
  required OperatorIdReader operatorIdReader,
  required SweepLockIdReader sweepLockIdReader,
  required SweepAdvisoryLock sweepAdvisoryLock,
  required ShutdownSignals shutdown,
  required DateTime asOfUtc,
  required DateTime nowUtc,
  required IOSink out,
  required IOSink err,
}) async {
  // L9: resolve the advisory-lock id from the constants table
  // BEFORE acquiring any lock. The id is read once at boot — never
  // hard-coded — so DBAs can rotate the live id without redeploying.
  int lockId;
  try {
    lockId = await sweepLockIdReader.readSweepLockId();
  } on SweepLockUnavailable catch (error) {
    err.writeln('audit_anchor: sweep lock unavailable: $error');
    return 3;
  } catch (error) {
    err.writeln(
      'audit_anchor: sweep lock id lookup failed: $error',
    );
    return 3;
  }
  out.writeln(
    'audit_anchor: sweep advisory-lock id resolved (lock_kind='
    'audit_anchor_sweep)',
  );
  // L9: serialize concurrent sweep invocations across pods/regions.
  // pg_advisory_lock blocks until the holder releases — Cloud
  // Scheduler retry storms thus do not produce a thundering herd;
  // the second invocation waits for the first, then runs against an
  // already-anchored set (no work) and exits cleanly.
  return sweepAdvisoryLock.withSweepLock<int>(
    lockId: lockId,
    body: () async {
      List<String> operatorIds;
      try {
        operatorIds = await operatorIdReader.listOperatorIds();
      } catch (error) {
        err.writeln(
          'audit_anchor: operator-id resolution failed: $error',
        );
        return 3;
      }
      if (operatorIds.isEmpty) {
        out.writeln(
          'audit_anchor: sweep found 0 operators in public.operators '
          '(no chains to anchor); see '
          'runbooks/audit_chain_verify_runbook.md',
        );
        return 0;
      }
      out.writeln(
        'audit_anchor: sweep resolved ${operatorIds.length} '
        'operator(s) from public.operators',
      );
      // L9 sub-task (a): startup crash-recovery sweep BEFORE the
      // forward anchor pass. Detects orphan blobs (a previous run
      // wrote the immutable evidence but crashed before inserting
      // the audit_chain_anchors row) and either commits (recovered)
      // or fails (refused to insert) deterministically. Both
      // outcomes are reported per-operator below.
      var hadFailure = false;
      for (final operatorId in operatorIds) {
        if (shutdown.isShuttingDown) {
          out.writeln(
            'audit_anchor: SIGTERM/SIGINT received; aborting '
            'recovery sweep before $operatorId',
          );
          return hadFailure ? 1 : 0;
        }
        try {
          final results = await orchestrator.runStartupRecovery(
            operatorId: operatorId,
            asOfUtc: asOfUtc,
          );
          for (final result in results) {
            hadFailure |= _logRecoveryResult(
              result: result,
              operatorId: operatorId,
              out: out,
              err: err,
            );
          }
        } on AuditAnchorBlobUnavailable catch (error) {
          err.writeln(
            'audit_anchor: recovery probe blob unavailable for '
            '$operatorId: ${error.reason}',
          );
          hadFailure = true;
        } catch (error) {
          err.writeln(
            'audit_anchor: recovery error for $operatorId: $error',
          );
          hadFailure = true;
        }
      }
      // Forward anchor pass: now that any orphan blobs are either
      // recovered or surfaced as failures, anchor every still-
      // unanchored completed chain.
      final anchorExitCode = await _runAnchorMode(
        orchestrator: orchestrator,
        operatorIds: operatorIds,
        asOfUtc: asOfUtc,
        nowUtc: nowUtc,
        shutdown: shutdown,
        out: out,
        err: err,
      );
      return (hadFailure || anchorExitCode != 0) ? 1 : 0;
    },
  );
}

/// Logs one recovery [AnchorRunResult] and returns `true` when the
/// outcome is a recovery failure (so the caller can flip its
/// `hadFailure` flag). recoveredCommitted is treated as success.
bool _logRecoveryResult({
  required AnchorRunResult result,
  required String operatorId,
  required IOSink out,
  required IOSink err,
}) {
  switch (result.outcome) {
    case AnchorOutcome.recoveredCommitted:
      out.writeln(
        'audit_anchor: recovery committed $operatorId / '
        '${_formatChainDate(result.chainDate)} — ${result.message ?? ''}',
      );
      return false;
    case AnchorOutcome.recoveredFailed:
      err.writeln(
        'audit_anchor: recovery FAILED $operatorId / '
        '${_formatChainDate(result.chainDate)} — '
        '${result.message ?? '(no detail)'}; see '
        'runbooks/audit_chain_verify_runbook.md',
      );
      return true;
    // Defensive: runStartupRecovery only emits the two recovery
    // outcomes today, but the enum carries the regular anchor
    // outcomes too. Treat anything unexpected as a non-failure log.
    case AnchorOutcome.anchored:
    case AnchorOutcome.alreadyAnchored:
    case AnchorOutcome.empty:
    case AnchorOutcome.chainHashMismatch:
      out.writeln(
        'audit_anchor: recovery returned ${result.outcome.name} for '
        '$operatorId / ${_formatChainDate(result.chainDate)}',
      );
      return false;
  }
}

Future<int> _runAnchorMode({
  required AuditAnchorOrchestrator orchestrator,
  required List<String> operatorIds,
  required DateTime asOfUtc,
  required DateTime nowUtc,
  required ShutdownSignals shutdown,
  required IOSink out,
  required IOSink err,
  AuditAnchorFailureHook? onAnchorFailure,
}) async {
  var hadFailure = false;
  for (final operatorId in operatorIds) {
    if (shutdown.isShuttingDown) {
      out.writeln(
        'audit_anchor: SIGTERM/SIGINT received; aborting before '
        '$operatorId',
      );
      break;
    }
    List<AnchorRunResult> results;
    try {
      results = await orchestrator.runAnchor(
        operatorId: operatorId,
        asOfUtc: asOfUtc,
        nowUtc: nowUtc,
      );
    } on AuditAnchorBlobUnavailable catch (error) {
      err.writeln('audit_anchor: blob client unavailable for '
          '$operatorId: ${error.reason}');
      hadFailure = true;
      await _fireAnchorFailureHook(
        onAnchorFailure: onAnchorFailure,
        operatorId: operatorId,
        chainDateIso: _formatChainDate(asOfUtc),
        reason: 'blob_unavailable: ${error.reason}',
      );
      continue;
    } catch (error) {
      err.writeln('audit_anchor: runtime error for $operatorId: $error');
      hadFailure = true;
      await _fireAnchorFailureHook(
        onAnchorFailure: onAnchorFailure,
        operatorId: operatorId,
        chainDateIso: _formatChainDate(asOfUtc),
        reason: 'runtime_error: $error',
      );
      continue;
    }
    if (results.isEmpty) {
      out.writeln(
        'audit_anchor: no unanchored completed chains for $operatorId',
      );
      continue;
    }
    for (final result in results) {
      switch (result.outcome) {
        case AnchorOutcome.anchored:
          out.writeln('audit_anchor: anchored $operatorId / '
              '${_formatChainDate(result.chainDate)}');
        case AnchorOutcome.alreadyAnchored:
          out.writeln('audit_anchor: already anchored $operatorId / '
              '${_formatChainDate(result.chainDate)}');
        case AnchorOutcome.empty:
          out.writeln('audit_anchor: empty chain $operatorId / '
              '${_formatChainDate(result.chainDate)}');
        case AnchorOutcome.chainHashMismatch:
          err.writeln('audit_anchor: chain hash mismatch '
              '$operatorId / ${_formatChainDate(result.chainDate)} '
              '(${result.violations.length} violation(s); see '
              'runbooks/audit_chain_verify_runbook.md)');
          hadFailure = true;
          await _fireAnchorFailureHook(
            onAnchorFailure: onAnchorFailure,
            operatorId: operatorId,
            chainDateIso: _formatChainDate(result.chainDate),
            reason:
                'chain_hash_mismatch: ${result.violations.length} '
                'violation(s)',
          );
        case AnchorOutcome.recoveredCommitted:
        case AnchorOutcome.recoveredFailed:
          // runAnchor never emits recovery outcomes today; if a
          // future change does, log it without flipping failure.
          out.writeln(
            'audit_anchor: ${result.outcome.name} $operatorId / '
            '${_formatChainDate(result.chainDate)}',
          );
          if (result.outcome == AnchorOutcome.recoveredFailed) {
            await _fireAnchorFailureHook(
              onAnchorFailure: onAnchorFailure,
              operatorId: operatorId,
              chainDateIso: _formatChainDate(result.chainDate),
              reason: 'recovered_failed: ${result.message ?? ''}',
            );
          }
      }
    }
  }
  return hadFailure ? 1 : 0;
}

/// Best-effort wrapper around the optional anchor-failure hook.
/// Catches every exception so a notification-side issue never
/// changes the audit_anchor exit code.
Future<void> _fireAnchorFailureHook({
  required AuditAnchorFailureHook? onAnchorFailure,
  required String operatorId,
  required String chainDateIso,
  required String reason,
}) async {
  if (onAnchorFailure == null) return;
  try {
    await onAnchorFailure(
      operatorId: operatorId,
      chainDateIso: chainDateIso,
      reason: reason,
    );
  } catch (_) {
    // Swallow.
  }
}

Future<int> _runVerifyMode({
  required AuditAnchorOrchestrator orchestrator,
  required String operatorId,
  required DateTime chainDate,
  required IOSink out,
  required IOSink err,
  AuditAnchorFailureHook? onAnchorFailure,
}) async {
  VerifyRunResult result;
  try {
    result = await orchestrator.runVerify(
      operatorId: operatorId,
      chainDate: chainDate,
    );
  } on AuditAnchorBlobUnavailable catch (error) {
    err.writeln('audit_anchor: blob client unavailable for $operatorId / '
        '${_formatChainDate(chainDate)}: ${error.reason}');
    await _fireAnchorFailureHook(
      onAnchorFailure: onAnchorFailure,
      operatorId: operatorId,
      chainDateIso: _formatChainDate(chainDate),
      reason: 'verify_blob_unavailable: ${error.reason}',
    );
    return 3;
  } catch (error) {
    err.writeln('audit_anchor: runtime error for $operatorId / '
        '${_formatChainDate(chainDate)}: $error');
    await _fireAnchorFailureHook(
      onAnchorFailure: onAnchorFailure,
      operatorId: operatorId,
      chainDateIso: _formatChainDate(chainDate),
      reason: 'verify_runtime_error: $error',
    );
    return 3;
  }
  switch (result.outcome) {
    case VerifyOutcome.ok:
      out.writeln('audit_anchor: ok $operatorId / '
          '${_formatChainDate(chainDate)}');
      return 0;
    case VerifyOutcome.chainHashMismatch:
    case VerifyOutcome.anchorMissing:
    case VerifyOutcome.anchorTerminalMismatch:
    case VerifyOutcome.blobEvidenceMismatch:
      err.writeln('audit_anchor: ${result.outcome.name} $operatorId / '
          '${_formatChainDate(chainDate)} — ${result.message ?? '(no detail)'}'
          '; see runbooks/audit_chain_verify_runbook.md');
      await _fireAnchorFailureHook(
        onAnchorFailure: onAnchorFailure,
        operatorId: operatorId,
        chainDateIso: _formatChainDate(chainDate),
        reason: 'verify_${result.outcome.name}: ${result.message ?? ''}',
      );
      return 1;
    case VerifyOutcome.blobUnavailable:
      err.writeln('audit_anchor: blob unavailable $operatorId / '
          '${_formatChainDate(chainDate)} — ${result.message ?? '(no detail)'}');
      await _fireAnchorFailureHook(
        onAnchorFailure: onAnchorFailure,
        operatorId: operatorId,
        chainDateIso: _formatChainDate(chainDate),
        reason: 'verify_blob_unavailable: ${result.message ?? ''}',
      );
      return 3;
  }
}

DateTime _utcDate(DateTime now) {
  final utc = now.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day);
}

String _formatChainDate(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

/// Wave 2 EN-3-FU - builds an [AuditAnchorFailureHook] that dispatches
/// `notif.audit.anchor_failure` through the production
/// [NotificationEventFanout] via the existing envelope-builder helper
/// in `notification_event_hooks.dart`. The helper internally swallows
/// fanout exceptions so the audit_anchor exit code is never changed
/// by a notification-side failure (matching the doc-string contract on
/// [AuditAnchorFailureHook]).
AuditAnchorFailureHook _buildFanoutBackedAnchorFailureHook(
  NotificationEventFanout fanout,
) {
  return ({
    required String operatorId,
    required String chainDateIso,
    required String reason,
  }) async {
    await emitAuditAnchorFailure(
      fanout: fanout.fanOut,
      operatorId: operatorId,
      chainDateIso: chainDateIso,
      reason: reason,
    );
  };
}

Future<void> main(List<String> args) async {
  // Wave 2 EN-3-FU - production NotificationEventFanout binding.
  // `runCli` resolves `onAnchorFailure` to a fanout-backed hook when
  // the production runtime produced a [NotificationEventFanout] (the
  // normal Cloud Run path). When `buildAuditAnchorRuntime` could not
  // produce a fanout (degraded boot, future test-time deploy with no
  // Postgres), we leave `onAnchorFailure` null so the structured
  // telemetry warning in `notif_event_telemetry_hook.dart` becomes
  // the side-channel until the fanout binds.
  //
  // EN-3's `buildAuditAnchorFailureTelemetryHook` is intentionally
  // NOT passed here: the fanout dispatches the real envelope, and
  // tests inject their own `onAnchorFailure` via `runCli`'s named
  // parameter. The telemetry helper is preserved for one release
  // cycle as a fallback path but is not the primary dispatch
  // surface any more.
  exitCode = await runCli(args);
}
