// Safe staging-console performance probe.
//
// This is the small guardrail companion to `tier_m_runner.dart`.
// It measures the browser-served admin console and the deployed
// staging proxy with bounded, low-concurrency HTTP probes. It does
// not authenticate, mutate data, click console actions, or flood the
// backend.
//
// Default mode is plan-only so an accidental invocation cannot load
// staging. Use `--run` to execute the safe profile:
//
//   dart run tool/perf_gate/staging_console_probe.dart \
//     --run \
//     --admin-url=https://forge-flow-admin-console-rf7nosnoka-pd.a.run.app \
//     --proxy-url=https://forge-flow-staging-proxy-rf7nosnoka-pd.a.run.app \
//     --admin-revision=forge-flow-admin-console-00003-shn \
//     --proxy-revision=forge-flow-staging-proxy-00051-7x5 \
//     --write-json=build/perf_gate/staging_console_probe.json
//
// Add `--include-health` only when the operator deliberately wants to
// exercise `/health`; the previous staging audit showed `/health`
// can be slow/unhealthy for real producer-state reasons, so the
// default profile limits itself to static console delivery and
// `/readyz`. Add `--enforce-budgets` in CI or release checks to fail
// the run when the current starting guardrails regress.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const int _defaultTimeoutSeconds = 30;
const int _defaultHealthTotal = 3;
const int _defaultHealthConcurrency = 1;
const int _maxHealthTotal = 6;
const int _maxHealthConcurrency = 2;

const Map<String, ProbeBudget> _defaultBudgets = <String, ProbeBudget>{
  'admin_index_c1': ProbeBudget(maxP95Ms: 750, maxErrorRate: 0),
  'admin_index_c4': ProbeBudget(maxP95Ms: 750, maxErrorRate: 0),
  'admin_mainjs_gzip_c4': ProbeBudget(
    maxP95Ms: 1500,
    maxErrorRate: 0,
    maxBytes: 1250000,
  ),
  'proxy_readyz_c1': ProbeBudget(maxP95Ms: 500, maxErrorRate: 0),
  'proxy_readyz_c4': ProbeBudget(maxP95Ms: 500, maxErrorRate: 0),
};

Future<void> main(List<String> args) async {
  try {
    final config = StagingProbeConfig.parse(args);
    if (config.showHelp) {
      stdout.writeln(usageText);
      return;
    }
    if (!config.run) {
      stdout.writeln(buildPlanText(config));
      return;
    }

    final report = await runStagingProbe(config);
    final encoded = const JsonEncoder.withIndent('  ').convert(report.toJson());
    if (config.writeJsonPath != null) {
      final file = File(config.writeJsonPath!);
      await file.parent.create(recursive: true);
      await file.writeAsString('$encoded\n');
    }
    if (config.jsonOnly) {
      stdout.writeln(encoded);
    } else {
      stdout.writeln(formatReport(report));
      if (config.writeJsonPath != null) {
        stdout.writeln('');
        stdout.writeln('JSON written: ${config.writeJsonPath}');
      }
    }

    if (report.allProbesFailed || report.hasBudgetFailures) {
      exitCode = 1;
    }
  } on UsageException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('');
    stderr.writeln(usageText);
    exitCode = 64;
  }
}

class UsageException implements Exception {
  const UsageException(this.message);

  final String message;
}

class StagingProbeConfig {
  const StagingProbeConfig({
    required this.run,
    required this.showHelp,
    required this.jsonOnly,
    required this.enforceBudgets,
    required this.includeHealth,
    required this.healthTotal,
    required this.healthConcurrency,
    required this.timeout,
    this.adminUrl,
    this.proxyUrl,
    this.adminRevision,
    this.proxyRevision,
    this.label,
    this.writeJsonPath,
  });

  final bool run;
  final bool showHelp;
  final bool jsonOnly;
  final bool enforceBudgets;
  final bool includeHealth;
  final int healthTotal;
  final int healthConcurrency;
  final Duration timeout;
  final Uri? adminUrl;
  final Uri? proxyUrl;
  final String? adminRevision;
  final String? proxyRevision;
  final String? label;
  final String? writeJsonPath;

  static StagingProbeConfig parse(List<String> args) {
    var run = false;
    var showHelp = false;
    var jsonOnly = false;
    var enforceBudgets = false;
    var includeHealth = false;
    var healthTotal = _defaultHealthTotal;
    var healthConcurrency = _defaultHealthConcurrency;
    var timeoutSeconds = _defaultTimeoutSeconds;
    Uri? adminUrl;
    Uri? proxyUrl;
    String? adminRevision;
    String? proxyRevision;
    String? label;
    String? writeJsonPath;

    for (final arg in args) {
      if (arg == '--run') {
        run = true;
      } else if (arg == '--help' || arg == '-h') {
        showHelp = true;
      } else if (arg == '--json') {
        jsonOnly = true;
      } else if (arg == '--enforce-budgets') {
        enforceBudgets = true;
      } else if (arg == '--include-health') {
        includeHealth = true;
      } else if (arg.startsWith('--admin-url=')) {
        adminUrl = _parseUriFlag('admin-url', arg);
      } else if (arg.startsWith('--proxy-url=')) {
        proxyUrl = _parseUriFlag('proxy-url', arg);
      } else if (arg.startsWith('--admin-revision=')) {
        adminRevision = _parseStringFlag('admin-revision', arg);
      } else if (arg.startsWith('--proxy-revision=')) {
        proxyRevision = _parseStringFlag('proxy-revision', arg);
      } else if (arg.startsWith('--label=')) {
        label = _parseStringFlag('label', arg);
      } else if (arg.startsWith('--write-json=')) {
        writeJsonPath = _parseStringFlag('write-json', arg);
      } else if (arg.startsWith('--timeout-seconds=')) {
        timeoutSeconds = _parsePositiveIntFlag('timeout-seconds', arg);
      } else if (arg.startsWith('--health-total=')) {
        healthTotal = _parsePositiveIntFlag('health-total', arg);
      } else if (arg.startsWith('--health-concurrency=')) {
        healthConcurrency = _parsePositiveIntFlag('health-concurrency', arg);
      } else {
        throw UsageException('unknown argument: $arg');
      }
    }

    if (showHelp) {
      return StagingProbeConfig(
        run: run,
        showHelp: showHelp,
        jsonOnly: jsonOnly,
        enforceBudgets: enforceBudgets,
        includeHealth: includeHealth,
        healthTotal: healthTotal,
        healthConcurrency: healthConcurrency,
        timeout: Duration(seconds: timeoutSeconds),
        adminUrl: adminUrl,
        proxyUrl: proxyUrl,
        adminRevision: adminRevision,
        proxyRevision: proxyRevision,
        label: label,
        writeJsonPath: writeJsonPath,
      );
    }

    if (healthTotal > _maxHealthTotal) {
      throw UsageException(
        '--health-total is capped at $_maxHealthTotal for staging safety',
      );
    }
    if (healthConcurrency > _maxHealthConcurrency) {
      throw UsageException(
        '--health-concurrency is capped at $_maxHealthConcurrency '
        'for staging safety',
      );
    }
    if (timeoutSeconds > 120) {
      throw const UsageException(
        '--timeout-seconds is capped at 120 for bounded staging probes',
      );
    }
    if (run && adminUrl == null) {
      throw const UsageException('--admin-url is required with --run');
    }
    if (run && proxyUrl == null) {
      throw const UsageException('--proxy-url is required with --run');
    }

    return StagingProbeConfig(
      run: run,
      showHelp: showHelp,
      jsonOnly: jsonOnly,
      enforceBudgets: enforceBudgets,
      includeHealth: includeHealth,
      healthTotal: healthTotal,
      healthConcurrency: healthConcurrency,
      timeout: Duration(seconds: timeoutSeconds),
      adminUrl: adminUrl,
      proxyUrl: proxyUrl,
      adminRevision: adminRevision,
      proxyRevision: proxyRevision,
      label: label,
      writeJsonPath: writeJsonPath,
    );
  }

  static Uri _parseUriFlag(String name, String arg) {
    final value = _parseStringFlag(name, arg);
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw UsageException('--$name must be an absolute http(s) URL');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw UsageException('--$name must use http or https');
    }
    return uri;
  }

  static String _parseStringFlag(String name, String arg) {
    final prefix = '--$name=';
    final value = arg.substring(prefix.length).trim();
    if (value.isEmpty) {
      throw UsageException('--$name cannot be empty');
    }
    return value;
  }

  static int _parsePositiveIntFlag(String name, String arg) {
    final value = int.tryParse(_parseStringFlag(name, arg));
    if (value == null || value <= 0) {
      throw UsageException('--$name must be a positive integer');
    }
    return value;
  }
}

class ProbeBudget {
  const ProbeBudget({
    required this.maxP95Ms,
    required this.maxErrorRate,
    this.maxBytes,
  });

  final double maxP95Ms;
  final double maxErrorRate;
  final int? maxBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'p95_ms_max': maxP95Ms,
    'error_rate_max': maxErrorRate,
    if (maxBytes != null) 'bytes_max': maxBytes,
  };
}

class ProbeSpec {
  const ProbeSpec({
    required this.name,
    required this.uri,
    required this.totalRequests,
    required this.concurrency,
    required this.timeout,
    this.headers = const <String, String>{},
    this.note,
  });

  final String name;
  final Uri uri;
  final int totalRequests;
  final int concurrency;
  final Duration timeout;
  final Map<String, String> headers;
  final String? note;
}

class ProbeSample {
  const ProbeSample({
    required this.statusCode,
    required this.latencyMs,
    required this.bytes,
    this.error,
    this.contentEncoding,
  });

  final int statusCode;
  final double latencyMs;
  final int bytes;
  final String? error;
  final String? contentEncoding;

  bool get ok => statusCode >= 200 && statusCode < 400;

  Map<String, Object?> toJson() => <String, Object?>{
    'status_code': statusCode,
    'latency_ms': _round(latencyMs),
    'bytes': bytes,
    if (contentEncoding != null) 'content_encoding': contentEncoding,
    if (error != null) 'error': error,
  };
}

class ProbeResult {
  ProbeResult({required this.spec, required this.samples});

  final ProbeSpec spec;
  final List<ProbeSample> samples;

  int get successCount => samples.where((sample) => sample.ok).length;

  int get errorCount => samples.length - successCount;

  double get errorRate => samples.isEmpty ? 1 : errorCount / samples.length;

  Map<int, int> get statusCounts {
    final counts = SplayTreeMap<int, int>();
    for (final sample in samples) {
      counts[sample.statusCode] = (counts[sample.statusCode] ?? 0) + 1;
    }
    return counts;
  }

  double get p50Ms => percentile(samples.map((s) => s.latencyMs), 50);

  double get p95Ms => percentile(samples.map((s) => s.latencyMs), 95);

  double get p99Ms => percentile(samples.map((s) => s.latencyMs), 99);

  int get minBytes {
    if (samples.isEmpty) return 0;
    return samples.map((sample) => sample.bytes).reduce(math.min);
  }

  int get maxBytes {
    if (samples.isEmpty) return 0;
    return samples.map((sample) => sample.bytes).reduce(math.max);
  }

  ProbeBudget? get budget => _defaultBudgets[spec.name];

  List<String> get budgetFailures {
    final activeBudget = budget;
    if (activeBudget == null) return const <String>[];
    final failures = <String>[];
    if (p95Ms > activeBudget.maxP95Ms) {
      failures.add(
        'p95 ${_round(p95Ms).toStringAsFixed(1)}ms > '
        '${activeBudget.maxP95Ms.toStringAsFixed(1)}ms',
      );
    }
    if (errorRate > activeBudget.maxErrorRate) {
      failures.add(
        'error rate ${(errorRate * 100).toStringAsFixed(1)}% > '
        '${(activeBudget.maxErrorRate * 100).toStringAsFixed(1)}%',
      );
    }
    final byteBudget = activeBudget.maxBytes;
    if (byteBudget != null && maxBytes > byteBudget) {
      failures.add('bytes $maxBytes > $byteBudget');
    }
    return failures;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': spec.name,
    'url': spec.uri.toString(),
    'total_requests': spec.totalRequests,
    'concurrency': spec.concurrency,
    'timeout_ms': spec.timeout.inMilliseconds,
    if (spec.note != null) 'note': spec.note,
    'status_counts': statusCounts.map(
      (status, count) => MapEntry(status.toString(), count),
    ),
    'success_count': successCount,
    'error_count': errorCount,
    'error_rate': _round(errorRate),
    'latency_ms': <String, Object?>{
      'p50': _round(p50Ms),
      'p95': _round(p95Ms),
      'p99': _round(p99Ms),
    },
    'bytes': <String, Object?>{'min': minBytes, 'max': maxBytes},
    if (budget != null) 'budget': budget!.toJson(),
    if (budgetFailures.isNotEmpty) 'budget_failures': budgetFailures,
    'samples': samples.map((sample) => sample.toJson()).toList(),
  };
}

class StagingProbeReport {
  const StagingProbeReport({
    required this.testedAt,
    required this.adminUrl,
    required this.proxyUrl,
    required this.gitBranch,
    required this.gitCommit,
    required this.enforceBudgets,
    required this.results,
    this.adminRevision,
    this.proxyRevision,
    this.label,
  });

  final DateTime testedAt;
  final Uri adminUrl;
  final Uri proxyUrl;
  final String gitBranch;
  final String gitCommit;
  final bool enforceBudgets;
  final String? adminRevision;
  final String? proxyRevision;
  final String? label;
  final List<ProbeResult> results;

  bool get allProbesFailed =>
      results.every((result) => result.successCount == 0);

  bool get hasBudgetFailures =>
      enforceBudgets &&
      results.any((result) => result.budgetFailures.isNotEmpty);

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': 1,
    'tested_at': testedAt.toIso8601String(),
    if (label != null) 'label': label,
    'admin_url': adminUrl.toString(),
    'proxy_url': proxyUrl.toString(),
    'git_branch': gitBranch,
    'git_commit': gitCommit,
    'enforce_budgets': enforceBudgets,
    if (adminRevision != null) 'admin_revision': adminRevision,
    if (proxyRevision != null) 'proxy_revision': proxyRevision,
    'probes': results.map((result) => result.toJson()).toList(),
  };
}

Future<StagingProbeReport> runStagingProbe(StagingProbeConfig config) async {
  final adminUrl = config.adminUrl;
  final proxyUrl = config.proxyUrl;
  if (adminUrl == null || proxyUrl == null) {
    throw const UsageException('--admin-url and --proxy-url are required');
  }

  final specs = buildProbePlan(config);
  final results = <ProbeResult>[];
  for (final spec in specs) {
    results.add(await runProbe(spec));
  }

  return StagingProbeReport(
    testedAt: DateTime.now().toUtc(),
    label: config.label,
    adminUrl: adminUrl,
    proxyUrl: proxyUrl,
    adminRevision: config.adminRevision,
    proxyRevision: config.proxyRevision,
    gitBranch: await _gitValue(<String>['rev-parse', '--abbrev-ref', 'HEAD']),
    gitCommit: await _gitValue(<String>['rev-parse', '--short', 'HEAD']),
    enforceBudgets: config.enforceBudgets,
    results: results,
  );
}

List<ProbeSpec> buildProbePlan(StagingProbeConfig config) {
  final adminUrl = config.adminUrl;
  final proxyUrl = config.proxyUrl;
  if (adminUrl == null || proxyUrl == null) {
    return const <ProbeSpec>[];
  }
  final adminMainJs = _origin(adminUrl).resolve('/main.dart.js');
  final proxyReadyz = _origin(proxyUrl).resolve('/readyz');
  final proxyHealth = _origin(proxyUrl).resolve('/health');

  return <ProbeSpec>[
    ProbeSpec(
      name: 'admin_index_c1',
      uri: adminUrl,
      totalRequests: 10,
      concurrency: 1,
      timeout: config.timeout,
    ),
    ProbeSpec(
      name: 'admin_index_c4',
      uri: adminUrl,
      totalRequests: 20,
      concurrency: 4,
      timeout: config.timeout,
    ),
    ProbeSpec(
      name: 'admin_mainjs_gzip_c4',
      uri: adminMainJs,
      totalRequests: 20,
      concurrency: 4,
      timeout: config.timeout,
      headers: const <String, String>{'Accept-Encoding': 'gzip'},
      note: 'auto-uncompress disabled; bytes are transfer bytes',
    ),
    ProbeSpec(
      name: 'proxy_readyz_c1',
      uri: proxyReadyz,
      totalRequests: 10,
      concurrency: 1,
      timeout: config.timeout,
    ),
    ProbeSpec(
      name: 'proxy_readyz_c4',
      uri: proxyReadyz,
      totalRequests: 20,
      concurrency: 4,
      timeout: config.timeout,
    ),
    if (config.includeHealth)
      ProbeSpec(
        name: 'proxy_health_c${config.healthConcurrency}_safe',
        uri: proxyHealth,
        totalRequests: config.healthTotal,
        concurrency: config.healthConcurrency,
        timeout: config.timeout,
        note: 'bounded /health probe; do not hide real producer failures',
      ),
  ];
}

Future<ProbeResult> runProbe(ProbeSpec spec) async {
  final client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = spec.timeout
    ..maxConnectionsPerHost = spec.concurrency;
  final samples = <ProbeSample>[];
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final index = nextIndex;
      nextIndex += 1;
      if (index >= spec.totalRequests) return;
      samples.add(await _fetch(client, spec));
    }
  }

  try {
    await Future.wait(
      List<Future<void>>.generate(spec.concurrency, (_) => worker()),
    );
  } finally {
    client.close(force: true);
  }

  return ProbeResult(spec: spec, samples: samples);
}

Future<ProbeSample> _fetch(HttpClient client, ProbeSpec spec) async {
  final stopwatch = Stopwatch()..start();
  try {
    return await (() async {
      final request = await client.getUrl(spec.uri);
      spec.headers.forEach(request.headers.set);
      final response = await request.close();
      var bytes = 0;
      await for (final chunk in response) {
        bytes += chunk.length;
      }
      stopwatch.stop();
      return ProbeSample(
        statusCode: response.statusCode,
        latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
        bytes: bytes,
        contentEncoding: response.headers.value(
          HttpHeaders.contentEncodingHeader,
        ),
      );
    })().timeout(spec.timeout);
  } catch (error) {
    stopwatch.stop();
    return ProbeSample(
      statusCode: 0,
      latencyMs: stopwatch.elapsedMicroseconds / 1000.0,
      bytes: 0,
      error: error.toString(),
    );
  }
}

double percentile(Iterable<double> values, int percentile) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return 0;
  final rank = (percentile / 100.0) * sorted.length;
  final index = math.max(0, rank.ceil() - 1);
  return sorted[index.clamp(0, sorted.length - 1)];
}

String buildPlanText(StagingProbeConfig config) {
  final buffer = StringBuffer()
    ..writeln('Staging console probe is in plan-only mode.')
    ..writeln('')
    ..writeln('What it measures:')
    ..writeln('  - admin index response at concurrency 1 and 4')
    ..writeln('  - admin main.dart.js gzip transfer at concurrency 4')
    ..writeln('  - staging proxy /readyz at concurrency 1 and 4')
    ..writeln('  - optional bounded /health probe only with --include-health')
    ..writeln('')
    ..writeln('Safety posture:')
    ..writeln('  - no auth, writes, mutations, browser clicks, or flood tests')
    ..writeln(
      '  - /health defaults off because unhealthy producer state is real',
    )
    ..writeln(
      '  - /health is capped at $_maxHealthConcurrency concurrency / '
      '$_maxHealthTotal total requests',
    )
    ..writeln(
      '  - --enforce-budgets turns current starting budgets into a '
      'failing gate',
    )
    ..writeln('')
    ..writeln('Run example:')
    ..writeln('  dart run tool/perf_gate/staging_console_probe.dart \\')
    ..writeln('    --run \\')
    ..writeln('    --admin-url=<admin console URL> \\')
    ..writeln('    --proxy-url=<staging proxy URL> \\')
    ..writeln('    --admin-revision=<admin Cloud Run revision> \\')
    ..writeln('    --proxy-revision=<proxy Cloud Run revision> \\')
    ..writeln('    --write-json=build/perf_gate/staging_console_probe.json');

  if (config.adminUrl != null || config.proxyUrl != null) {
    buffer
      ..writeln('')
      ..writeln('Configured endpoints:');
    if (config.adminUrl != null) {
      buffer.writeln('  admin: ${config.adminUrl}');
    }
    if (config.proxyUrl != null) {
      buffer.writeln('  proxy: ${config.proxyUrl}');
    }
  }
  return buffer.toString();
}

String formatReport(StagingProbeReport report) {
  final buffer = StringBuffer()
    ..writeln('Staging Console Performance Probe')
    ..writeln('tested_at: ${report.testedAt.toIso8601String()}')
    ..writeln('git: ${report.gitBranch} @ ${report.gitCommit}')
    ..writeln('admin_url: ${report.adminUrl}')
    ..writeln('proxy_url: ${report.proxyUrl}');
  if (report.label != null) buffer.writeln('label: ${report.label}');
  if (report.adminRevision != null) {
    buffer.writeln('admin_revision: ${report.adminRevision}');
  }
  if (report.proxyRevision != null) {
    buffer.writeln('proxy_revision: ${report.proxyRevision}');
  }
  buffer.writeln('enforce_budgets: ${report.enforceBudgets}');
  buffer
    ..writeln('')
    ..writeln(
      'probe                          status          err%   p50     p95     p99     bytes',
    )
    ..writeln(
      '------------------------------ --------------- ------ ------- ------- ------- --------',
    );
  for (final result in report.results) {
    final status = result.statusCounts.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(',');
    final err = (result.errorRate * 100).toStringAsFixed(1).padLeft(5);
    final p50 = _round(result.p50Ms).toStringAsFixed(1).padLeft(7);
    final p95 = _round(result.p95Ms).toStringAsFixed(1).padLeft(7);
    final p99 = _round(result.p99Ms).toStringAsFixed(1).padLeft(7);
    final bytes = result.minBytes == result.maxBytes
        ? '${result.maxBytes}'
        : '${result.minBytes}-${result.maxBytes}';
    buffer.writeln(
      '${result.spec.name.padRight(30)} '
      '${status.padRight(15)} '
      '$err '
      '$p50 '
      '$p95 '
      '$p99 '
      '$bytes',
    );
  }

  final warnings = report.results.where((result) => result.errorRate > 0);
  if (warnings.isNotEmpty) {
    buffer
      ..writeln('')
      ..writeln('Warnings:');
    for (final result in warnings) {
      buffer.writeln(
        '  - ${result.spec.name}: '
        '${(result.errorRate * 100).toStringAsFixed(1)}% non-2xx/3xx',
      );
    }
  }
  final budgetFailures = report.results.where(
    (result) => result.budgetFailures.isNotEmpty,
  );
  if (budgetFailures.isNotEmpty) {
    buffer
      ..writeln('')
      ..writeln(
        report.enforceBudgets ? 'Budget failures:' : 'Budget warnings:',
      );
    for (final result in budgetFailures) {
      buffer.writeln(
        '  - ${result.spec.name}: ${result.budgetFailures.join('; ')}',
      );
    }
  }
  if (!report.enforceBudgets) {
    buffer
      ..writeln('')
      ..writeln(
        'Budgets are informational; add --enforce-budgets to fail '
        'on regressions.',
      );
  }
  return buffer.toString();
}

Uri _origin(Uri uri) => uri.replace(path: '/', query: null, fragment: null);

Future<String> _gitValue(List<String> args) async {
  try {
    final result = await Process.run('git', args);
    if (result.exitCode != 0) return 'unknown';
    final value = result.stdout.toString().trim();
    return value.isEmpty ? 'unknown' : value;
  } catch (_) {
    return 'unknown';
  }
}

double _round(double value) => (value * 10).roundToDouble() / 10.0;

const String usageText = '''
Usage: dart run tool/perf_gate/staging_console_probe.dart [flags]

Default is plan-only. Required to execute:
  --run
  --admin-url=<absolute admin console URL>
  --proxy-url=<absolute staging proxy URL>

Optional metadata:
  --admin-revision=<Cloud Run admin revision>
  --proxy-revision=<Cloud Run proxy revision>
  --label=<short run label>
  --write-json=<path>
  --json
  --enforce-budgets

Optional safe /health probe:
  --include-health
  --health-total=<1-6, default 3>
  --health-concurrency=<1-2, default 1>

Other:
  --timeout-seconds=<1-120, default 30>
  --help
''';
