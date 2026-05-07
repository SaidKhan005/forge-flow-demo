// `cutover.0` pre-flight smoke harness.
//
// Codifies the operator-readable pre-flight checklist from
// `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`
// (`cutover.0` section) as an executable Dart tool. The harness is
// strictly read-only against the target Production1 database
// (apart from a single fixture INSERT inside a `BEGIN; … ROLLBACK`
// transaction in the RLS isolation check) and produces a JSON
// report whose layout mirrors
// `tool/perf_gate/staging_console_probe.dart` so existing CI
// patterns can consume it.
//
// Design posture (mirrors `staging_console_probe.dart`):
//
//   * Plan-only by default. The harness prints the planned check
//     list and exits 0 unless `--run` is passed. This prevents an
//     accidental invocation against Production1 from happening
//     just because the operator forgot a flag.
//   * Mandatory `--connection-string` only when `--run` is set.
//   * `--report-out=<path>` writes a machine-readable JSON report
//     to disk. CLI also emits a human table to stdout when
//     `--json` is not set.
//   * `--require-all` flips yellow checks (firewall skipped,
//     secrets skipped) from non-blocking to blocking. Default is
//     "any red is blocking, yellow is informational" so a
//     workstation-only run can still report green.
//
// Exit codes:
//
//   0 — green (or `--run` not set / `--help`)
//   1 — red verdict; one or more checks failed
//   2 — usage error (missing flag, malformed value)
//
// Red verdicts also carry a stable `cutover_preflight_red_<reason>`
// token in the human stdout so the operator can grep the runbook
// directly to the escalation row.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import 'checks/check_result.dart';
import 'checks/dns_resolution.dart';
import 'checks/firewall_reachability.dart';
import 'checks/rls_isolation.dart';
import 'checks/schema_presence.dart';
import 'checks/secret_manager_reachability.dart';

const String _cutoverHarnessSchemaVersion = '1';

class UsageException implements Exception {
  const UsageException(this.message);
  final String message;
}

class PreflightConfig {
  const PreflightConfig({
    required this.run,
    required this.showHelp,
    required this.jsonOnly,
    required this.requireAll,
    required this.includeRlsIsolation,
    required this.includeFirewallProbe,
    required this.skipFirewall,
    required this.skipSecrets,
    this.connectionString,
    this.reportOutPath,
    this.label,
    this.allowlistedSubnetCidr,
    this.expectedTables,
    this.fixtureTable,
    this.operatorAUuid,
    this.operatorBUuid,
    this.locationAUuid,
    this.locationBUuid,
    this.dnsHostnames = const <String>[],
    this.requiredSecrets = const <String>[],
  });

  final bool run;
  final bool showHelp;
  final bool jsonOnly;
  final bool requireAll;
  final bool includeRlsIsolation;
  final bool includeFirewallProbe;
  final bool skipFirewall;
  final bool skipSecrets;
  final String? connectionString;
  final String? reportOutPath;
  final String? label;
  final String? allowlistedSubnetCidr;
  final Set<String>? expectedTables;
  final String? fixtureTable;
  final String? operatorAUuid;
  final String? operatorBUuid;
  final String? locationAUuid;
  final String? locationBUuid;
  final List<String> dnsHostnames;
  final List<String> requiredSecrets;

  static PreflightConfig parse(List<String> args) {
    var run = false;
    var showHelp = false;
    var jsonOnly = false;
    var requireAll = false;
    var includeRlsIsolation = false;
    var includeFirewallProbe = false;
    var skipFirewall = false;
    var skipSecrets = false;
    String? connectionString;
    String? reportOutPath;
    String? label;
    String? allowlistedSubnetCidr;
    Set<String>? expectedTables;
    String? fixtureTable;
    String? operatorAUuid;
    String? operatorBUuid;
    String? locationAUuid;
    String? locationBUuid;
    final dnsHostnames = <String>[];
    final requiredSecrets = <String>[];

    for (final arg in args) {
      if (arg == '--run') {
        run = true;
      } else if (arg == '--help' || arg == '-h') {
        showHelp = true;
      } else if (arg == '--json') {
        jsonOnly = true;
      } else if (arg == '--require-all') {
        requireAll = true;
      } else if (arg == '--include-rls-isolation') {
        includeRlsIsolation = true;
      } else if (arg == '--include-firewall-probe') {
        includeFirewallProbe = true;
      } else if (arg == '--skip-firewall') {
        skipFirewall = true;
      } else if (arg == '--skip-secrets') {
        skipSecrets = true;
      } else if (arg.startsWith('--connection-string=')) {
        connectionString = _value('connection-string', arg);
      } else if (arg.startsWith('--report-out=')) {
        reportOutPath = _value('report-out', arg);
      } else if (arg.startsWith('--label=')) {
        label = _value('label', arg);
      } else if (arg.startsWith('--allowlisted-subnet-cidr=')) {
        allowlistedSubnetCidr = _value('allowlisted-subnet-cidr', arg);
      } else if (arg.startsWith('--expect-table=')) {
        expectedTables ??= <String>{};
        expectedTables.add(_value('expect-table', arg));
      } else if (arg.startsWith('--rls-fixture-table=')) {
        fixtureTable = _value('rls-fixture-table', arg);
      } else if (arg.startsWith('--rls-operator-a=')) {
        operatorAUuid = _value('rls-operator-a', arg);
      } else if (arg.startsWith('--rls-operator-b=')) {
        operatorBUuid = _value('rls-operator-b', arg);
      } else if (arg.startsWith('--rls-location-a=')) {
        locationAUuid = _value('rls-location-a', arg);
      } else if (arg.startsWith('--rls-location-b=')) {
        locationBUuid = _value('rls-location-b', arg);
      } else if (arg.startsWith('--dns-hostname=')) {
        dnsHostnames.add(_value('dns-hostname', arg));
      } else if (arg.startsWith('--required-secret=')) {
        requiredSecrets.add(_value('required-secret', arg));
      } else {
        throw UsageException('unknown argument: $arg');
      }
    }

    if (showHelp) {
      return PreflightConfig(
        run: run,
        showHelp: showHelp,
        jsonOnly: jsonOnly,
        requireAll: requireAll,
        includeRlsIsolation: includeRlsIsolation,
        includeFirewallProbe: includeFirewallProbe,
        skipFirewall: skipFirewall,
        skipSecrets: skipSecrets,
      );
    }

    if (run && (connectionString == null || connectionString.isEmpty)) {
      throw const UsageException(
        '--connection-string is required with --run',
      );
    }
    if (includeRlsIsolation && run) {
      if (operatorAUuid == null ||
          operatorBUuid == null ||
          locationAUuid == null ||
          locationBUuid == null) {
        throw const UsageException(
          '--include-rls-isolation requires '
          '--rls-operator-a / --rls-operator-b / '
          '--rls-location-a / --rls-location-b',
        );
      }
    }

    return PreflightConfig(
      run: run,
      showHelp: showHelp,
      jsonOnly: jsonOnly,
      requireAll: requireAll,
      includeRlsIsolation: includeRlsIsolation,
      includeFirewallProbe: includeFirewallProbe,
      skipFirewall: skipFirewall,
      skipSecrets: skipSecrets,
      connectionString: connectionString,
      reportOutPath: reportOutPath,
      label: label,
      allowlistedSubnetCidr: allowlistedSubnetCidr,
      expectedTables: expectedTables,
      fixtureTable: fixtureTable,
      operatorAUuid: operatorAUuid,
      operatorBUuid: operatorBUuid,
      locationAUuid: locationAUuid,
      locationBUuid: locationBUuid,
      dnsHostnames: List.unmodifiable(dnsHostnames),
      requiredSecrets: List.unmodifiable(requiredSecrets),
    );
  }

  static String _value(String name, String arg) {
    final prefix = '--$name=';
    final value = arg.substring(prefix.length).trim();
    if (value.isEmpty) {
      throw UsageException('--$name cannot be empty');
    }
    return value;
  }
}

class PreflightReport {
  const PreflightReport({
    required this.testedAt,
    required this.label,
    required this.requireAll,
    required this.checks,
  });

  final DateTime testedAt;
  final String? label;
  final bool requireAll;
  final List<CheckResult> checks;

  bool get overallGreen {
    final hasRed = checks.any((c) => c.status == CheckStatus.red);
    if (hasRed) return false;
    if (requireAll && checks.any((c) => c.status == CheckStatus.yellow)) {
      return false;
    }
    return true;
  }

  CheckStatus get overall {
    if (checks.any((c) => c.status == CheckStatus.red)) return CheckStatus.red;
    if (checks.any((c) => c.status == CheckStatus.yellow)) {
      return CheckStatus.yellow;
    }
    return CheckStatus.green;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': _cutoverHarnessSchemaVersion,
    'tested_at': testedAt.toIso8601String(),
    if (label != null) 'label': label,
    'require_all': requireAll,
    'overall_status': overall.toJsonString(),
    'overall_green': overallGreen,
    'checks': checks.map((c) => c.toJson()).toList(),
  };
}

/// Aggregator. Visible for tests so they can drive the
/// orchestration without going through `main()`.
Future<PreflightReport> runPreflight({
  required PreflightConfig config,
  required SchemaPresenceCheck schemaPresenceCheck,
  RlsIsolationCheck? rlsIsolationCheck,
  FirewallReachabilityCheck? firewallCheck,
  SecretManagerReachabilityCheck? secretsCheck,
  DnsResolutionCheck? dnsCheck,
}) async {
  final results = <CheckResult>[];

  // Schema presence is mandatory.
  results.add(await schemaPresenceCheck.run());

  if (config.includeRlsIsolation && rlsIsolationCheck != null) {
    results.add(await rlsIsolationCheck.run());
  }
  if (config.includeFirewallProbe && firewallCheck != null) {
    results.add(await firewallCheck.run());
  }
  if (secretsCheck != null) {
    results.add(await secretsCheck.run());
  }
  if (dnsCheck != null) {
    results.add(await dnsCheck.run());
  }

  return PreflightReport(
    testedAt: DateTime.now().toUtc(),
    label: config.label,
    requireAll: config.requireAll,
    checks: results,
  );
}

String formatPlan(PreflightConfig config) {
  final buffer = StringBuffer()
    ..writeln('cutover.0 pre-flight smoke is in plan-only mode.')
    ..writeln('')
    ..writeln('What it checks:')
    ..writeln('  - schema_presence — required tables, RLS posture, indexes')
    ..writeln(
      '  - rls_isolation (optional, --include-rls-isolation) — '
      'fixture write under operator A, read under B; expect zero rows',
    )
    ..writeln(
      '  - firewall_reachability (optional, --include-firewall-probe) '
      '— TCP probe to Postgres host',
    )
    ..writeln(
      '  - secret_manager_reachability — every named production '
      'secret is readable; --skip-secrets makes it yellow',
    )
    ..writeln(
      '  - dns_resolution — every named hostname resolves; pass via '
      '--dns-hostname=<host> repeatedly',
    )
    ..writeln('')
    ..writeln('Safety posture:')
    ..writeln('  - read-only on Production1 except for a single fixture')
    ..writeln('    INSERT inside a transaction that ROLLBACKS at end of')
    ..writeln('    the rls_isolation check')
    ..writeln('  - default is plan-only; --run is required to execute')
    ..writeln('  - exit 1 on any red check; exit 0 when overall green')
    ..writeln('')
    ..writeln('Run example:')
    ..writeln('  dart run tool/cutover/preflight_smoke.dart \\')
    ..writeln('    --run \\')
    ..writeln(r'    --connection-string=postgres://user:****@host/db \\')
    ..writeln('    --report-out=build/cutover/preflight_smoke.json \\')
    ..writeln('    --include-rls-isolation \\')
    ..writeln(
      '    --rls-operator-a=11111111-1111-1111-1111-111111111111 \\',
    )
    ..writeln(
      '    --rls-operator-b=22222222-2222-2222-2222-222222222222 \\',
    )
    ..writeln(
      '    --rls-location-a=33333333-3333-3333-3333-333333333333 \\',
    )
    ..writeln(
      '    --rls-location-b=44444444-4444-4444-4444-444444444444 \\',
    )
    ..writeln('    --dns-hostname=app.forgeflow.app \\')
    ..writeln('    --skip-secrets');
  return buffer.toString();
}

String formatReport(PreflightReport report) {
  final buffer = StringBuffer()
    ..writeln('cutover.0 pre-flight smoke')
    ..writeln('tested_at: ${report.testedAt.toIso8601String()}');
  if (report.label != null) buffer.writeln('label: ${report.label}');
  buffer
    ..writeln('require_all: ${report.requireAll}')
    ..writeln('overall: ${report.overall.toJsonString()} '
        '(green=${report.overallGreen})')
    ..writeln('')
    ..writeln(
      'check                              status   ms      message',
    )
    ..writeln(
      '----------------------------------- -------- ------- -------------------',
    );
  for (final check in report.checks) {
    final ms = check.elapsedMs == null
        ? '-'
        : check.elapsedMs!.toStringAsFixed(1);
    buffer.writeln(
      '${check.name.padRight(35)} '
      '${check.status.toJsonString().padRight(8)} '
      '${ms.padRight(7)} '
      '${check.message}',
    );
  }
  return buffer.toString();
}

const String usageText = '''
Usage: dart run tool/cutover/preflight_smoke.dart [flags]

Default is plan-only. Required to execute:
  --run
  --connection-string=<full Postgres DSN>

Optional:
  --report-out=<json path>
  --label=<short tag>
  --json                  emit JSON only on stdout (suppress table)
  --require-all           treat yellow as red (any non-green is blocking)

Check toggles:
  --include-rls-isolation         require RLS-isolation check; needs:
                                    --rls-operator-a=<uuid>
                                    --rls-operator-b=<uuid>
                                    --rls-location-a=<uuid>
                                    --rls-location-b=<uuid>
                                    --rls-fixture-table=<table>
  --include-firewall-probe        run TCP reachability probe
  --skip-firewall                 force firewall_reachability to yellow
  --skip-secrets                  force secret_manager_reachability to
                                    yellow (workstation runs)

Schema presence overrides:
  --expect-table=<name>           extend the expected-table set; may
                                    repeat
  --allowlisted-subnet-cidr=<v>   echo the operator-stated allowlist
                                    CIDR into the report

DNS / secrets enumeration:
  --dns-hostname=<host>           may repeat; runs DNS resolution
                                    check for each
  --required-secret=<name>        may repeat; overrides default secret
                                    list
''';

// Honor POSTGRES_POOL_MAX_CONNECTIONS env override; falls back to default 4.
PostgresPool _defaultPoolFactory(String connectionString) =>
    PackagePostgresPool.fromUrl(
      connectionString,
      maxConnectionCount: resolvePostgresMaxConnectionsPerPool(),
    );

Future<void> main(List<String> args) async {
  await runMain(args, defaultPoolFactory: _defaultPoolFactory);
}

/// Visible for tests: same as [main] but with the production pool
/// factory injected. Test bypasses the real `package:postgres`
/// connection by passing a fake.
Future<void> runMain(
  List<String> args, {
  required PostgresPool Function(String connectionString) defaultPoolFactory,
}) async {
  final PreflightConfig config;
  try {
    config = PreflightConfig.parse(args);
  } on UsageException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('');
    stderr.writeln(usageText);
    exitCode = 2;
    return;
  }

  if (config.showHelp) {
    stdout.writeln(usageText);
    return;
  }
  if (!config.run) {
    stdout.writeln(formatPlan(config));
    return;
  }

  final pool = defaultPoolFactory(config.connectionString!);

  final schemaPresenceCheck = SchemaPresenceCheck(
    pool: pool,
    expectedTables: config.expectedTables,
  );
  RlsIsolationCheck? rlsIsolationCheck;
  if (config.includeRlsIsolation) {
    rlsIsolationCheck = RlsIsolationCheck(
      pool: pool,
      operatorAUuid: config.operatorAUuid!,
      operatorBUuid: config.operatorBUuid!,
      locationAUuid: config.locationAUuid!,
      locationBUuid: config.locationBUuid!,
      fixtureTable: config.fixtureTable ?? kDefaultRlsFixtureTable,
    );
  }
  FirewallReachabilityCheck? firewallCheck;
  if (config.includeFirewallProbe && !config.skipFirewall) {
    firewallCheck = FirewallReachabilityCheck(
      connectivityProbe: () => _connectivityProbe(pool),
      allowlistedSubnetCidr: config.allowlistedSubnetCidr,
    );
  }
  // If both --include-firewall-probe and --skip-firewall are set,
  // skip wins; we never construct the check, so it is silently
  // omitted from the report (the operator chose to skip).
  final secretsCheck = SecretManagerReachabilityCheck(
    secretRead: _defaultSecretRead,
    skipped: config.skipSecrets,
    skipReason: config.skipSecrets ? 'workstation_run' : null,
    requiredSecrets: config.requiredSecrets.isEmpty
        ? kDefaultRequiredProductionSecrets
        : config.requiredSecrets,
  );
  DnsResolutionCheck? dnsCheck;
  if (config.dnsHostnames.isNotEmpty) {
    dnsCheck = DnsResolutionCheck(
      resolver: _defaultDnsResolver,
      hostnames: config.dnsHostnames,
    );
  }

  final report = await runPreflight(
    config: config,
    schemaPresenceCheck: schemaPresenceCheck,
    rlsIsolationCheck: rlsIsolationCheck,
    firewallCheck: firewallCheck,
    secretsCheck: secretsCheck,
    dnsCheck: dnsCheck,
  );

  final encoded = const JsonEncoder.withIndent('  ').convert(report.toJson());
  if (config.reportOutPath != null) {
    final file = File(config.reportOutPath!);
    await file.parent.create(recursive: true);
    await file.writeAsString('$encoded\n');
  }
  if (config.jsonOnly) {
    stdout.writeln(encoded);
  } else {
    stdout.writeln(formatReport(report));
    if (config.reportOutPath != null) {
      stdout.writeln('');
      stdout.writeln('JSON written: ${config.reportOutPath}');
    }
  }

  if (!report.overallGreen) {
    exitCode = 1;
  }
}

/// Real connectivity probe. Opens a transaction, runs `select 1`,
/// rolls back, returns true on success.
Future<bool> _connectivityProbe(PostgresPool pool) async {
  final tx = await pool.beginTransaction();
  try {
    final rows = await tx.query('select 1 as ok');
    return rows.isNotEmpty && rows.first['ok'] != null;
  } finally {
    await tx.rollback();
  }
}

/// Default secret-read probe — returns false until a real
/// implementation lands. The harness ships code-ready, but reading a
/// production GCP Secret Manager secret requires the gcloud SDK or
/// a service-account key on the local environment, neither of which
/// can be assumed at run time. The runbook tells the operator to
/// pass `--skip-secrets` from a workstation. When the lane to wire
/// in a real GCP SDK call lands (post-cutover infra, not blocking
/// V1), this stub flips to a real call.
Future<bool> _defaultSecretRead(String secretName) async {
  // Returning false would emit a red verdict for every secret on a
  // workstation run, which is noise. We instead throw — the caller
  // surfaces a clear "skip with --skip-secrets" hint via the yellow
  // path. This means a fresh `--run` without `--skip-secrets` will
  // be red on the secrets check, naming the right escalation in
  // the runbook.
  throw StateError(
    'secret read probe is not yet wired to a live GCP Secret Manager '
    'client; pass --skip-secrets when running from a workstation, '
    'or run from the production deploy account once the SDK call '
    'lands',
  );
}

/// Default DNS resolver — wraps `InternetAddress.lookup`.
Future<List<String>> _defaultDnsResolver(String hostname) async {
  final addresses = await InternetAddress.lookup(hostname);
  return addresses.map((a) => a.address).toList();
}
