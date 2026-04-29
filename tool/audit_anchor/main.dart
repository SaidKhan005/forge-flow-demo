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

import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import 'audit_anchor.dart';

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
  });

  final String containerName;
  final String endpoint;

  /// Resolved Postgres connection string. Passed to the pool factory
  /// (typically `PackagePostgresPool.fromUrl`). Never echoed to
  /// stdout/stderr.
  final String postgresUrl;
  final List<String> loadedSecretNames;

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

    final container = require(AuditAnchorEnvNames.azureBlobContainer);
    final endpoint = require(AuditAnchorEnvNames.azureBlobEndpoint);
    final postgresUrl = require(AuditAnchorEnvNames.postgresUrl);
    return AuditAnchorRuntimeConfig(
      containerName: container,
      endpoint: endpoint,
      postgresUrl: postgresUrl,
      loadedSecretNames: loaded,
    );
  }
}

typedef AuditAnchorPoolFactory = PostgresPool Function(String connectionString);
typedef AuditAnchorBlobClientFactory = AuditAnchorBlobClient Function(
  AuditAnchorRuntimeConfig config,
);

/// Bundle returned by [buildAuditAnchorRuntime]: the orchestrator the
/// per-operator anchor/verify path drives, plus the operator-id
/// reader the daily `sweep` mode uses to enumerate operators. Both
/// share a single [TenantTransactionWrapper] so the production
/// runtime opens one Postgres pool, not two.
class AuditAnchorRuntime {
  const AuditAnchorRuntime({
    required this.orchestrator,
    required this.operatorIdReader,
  });

  final AuditAnchorOrchestrator orchestrator;
  final OperatorIdReader operatorIdReader;
}

/// Default pool factory — wraps `PackagePostgresPool.fromUrl` so the
/// CLI builds a real Postgres pool against the live `POSTGRES_URL`
/// env value at deploy time. Identical posture to
/// `tool/advisor_proxy/proxy_bootstrap.dart`'s
/// `buildAuthSessionLedgerWriter` default.
PostgresPool _defaultPoolFactory(String connectionString) =>
    PackagePostgresPool.fromUrl(connectionString);

/// Default Blob client — scaffold-rejecting until live Azure Blob
/// wiring lands (operators deploying this job before the live client
/// exists see a deterministic error pointing at the runbook).
AuditAnchorBlobClient _defaultBlobClientFactory(
  AuditAnchorRuntimeConfig config,
) {
  return const ScaffoldRejectingAuditAnchorBlobClient();
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
  return AuditAnchorRuntime(
    orchestrator: orchestrator,
    operatorIdReader: operatorIdReader,
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
Future<int> runCli(
  List<String> rawArgs, {
  Map<String, String>? environment,
  AuditAnchorPoolFactory? poolFactory,
  AuditAnchorBlobClientFactory? blobClientFactory,
  AuditAnchorOrchestrator? orchestratorOverride,
  OperatorIdReader? operatorIdReaderOverride,
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
  // Default operator-id reader for non-sweep modes that never call
  // it. The sweep dispatch builds the production reader (or accepts
  // the test override) below.
  if (orchestratorOverride != null) {
    orchestrator = orchestratorOverride;
    operatorIdReader = operatorIdReaderOverride ??
        const _UnusedOperatorIdReader();
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
    stdoutSink.writeln(
      'audit_anchor starting (loaded secret names: '
      '${config.loadedSecretNames.join(', ')})',
    );
  }

  switch (args.mode) {
    case AuditAnchorMode.sweep:
      return _runSweepMode(
        orchestrator: orchestrator,
        operatorIdReader: operatorIdReader,
        asOfUtc: args.asOfUtc ?? _utcDate(now),
        nowUtc: now,
        out: stdoutSink,
        err: stderrSink,
      );
    case AuditAnchorMode.anchor:
      return _runAnchorMode(
        orchestrator: orchestrator,
        operatorIds: args.operatorIds,
        asOfUtc: args.asOfUtc ?? _utcDate(now),
        nowUtc: now,
        out: stdoutSink,
        err: stderrSink,
      );
    case AuditAnchorMode.verify:
      return _runVerifyMode(
        orchestrator: orchestrator,
        operatorId: args.operatorIds.single,
        chainDate: args.chainDateUtc!,
        out: stdoutSink,
        err: stderrSink,
      );
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

Future<int> _runSweepMode({
  required AuditAnchorOrchestrator orchestrator,
  required OperatorIdReader operatorIdReader,
  required DateTime asOfUtc,
  required DateTime nowUtc,
  required IOSink out,
  required IOSink err,
}) async {
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
    'audit_anchor: sweep resolved ${operatorIds.length} operator(s) '
    'from public.operators',
  );
  return _runAnchorMode(
    orchestrator: orchestrator,
    operatorIds: operatorIds,
    asOfUtc: asOfUtc,
    nowUtc: nowUtc,
    out: out,
    err: err,
  );
}

Future<int> _runAnchorMode({
  required AuditAnchorOrchestrator orchestrator,
  required List<String> operatorIds,
  required DateTime asOfUtc,
  required DateTime nowUtc,
  required IOSink out,
  required IOSink err,
}) async {
  var hadFailure = false;
  for (final operatorId in operatorIds) {
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
      continue;
    } catch (error) {
      err.writeln('audit_anchor: runtime error for $operatorId: $error');
      hadFailure = true;
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
      }
    }
  }
  return hadFailure ? 1 : 0;
}

Future<int> _runVerifyMode({
  required AuditAnchorOrchestrator orchestrator,
  required String operatorId,
  required DateTime chainDate,
  required IOSink out,
  required IOSink err,
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
    return 3;
  } catch (error) {
    err.writeln('audit_anchor: runtime error for $operatorId / '
        '${_formatChainDate(chainDate)}: $error');
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
      return 1;
    case VerifyOutcome.blobUnavailable:
      err.writeln('audit_anchor: blob unavailable $operatorId / '
          '${_formatChainDate(chainDate)} — ${result.message ?? '(no detail)'}');
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

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
