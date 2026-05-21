// PERF baseline ratchet — skeleton.
//
// Lane E (wave 2) bleed-stop for the "no perf-baseline file" tooling gap
// called out in `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
// §3 dimension 2 + §7 backlog item #5 + §8. P50/P95/P99 numbers are
// emitted per-harness in JSONL today but are never compared against a
// committed baseline, so a 20% performance regression ships silently.
//
// This tool gives us three things, in skeleton form (initial baselines
// are `null` because we lack a live cloud run to capture from):
//
//   * `--capture <metric> <value>`  — writes a new baseline value into
//     `docs/PERF_BASELINES.json`. Refuses unknown metrics (typos creating
//     ghost keys is the easiest way to make a ratchet useless).
//   * `--check <metric> <measured>` (default mode if a `--capture` arg
//     isn't passed) — compares `<measured>` against the stored baseline,
//     fails with exit 1 if `measured > baseline * regression_factor`.
//     Skips silently if the baseline is `null` (not yet captured).
//   * `--list` — prints the baseline JSON as a simple table.
//
// NOT wired into the pre-push hook on purpose — per-push perf checks are
// too expensive and would bog down every PR. The orchestrator runs this
// explicitly in pressure-PR audits (see
// `runbooks/perf_baseline_capture_runbook.md`).
//
// Run locally:
//
//   dart run tool/perf_baseline_check.dart --list
//   dart run tool/perf_baseline_check.dart --capture soak_p99_request_ms 124.5
//   dart run tool/perf_baseline_check.dart --check soak_p99_request_ms 130.0
//
// Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
// §3 + §8.

import 'dart:convert';
import 'dart:io';

/// Path (relative to repo root) of the baseline file.
const String kPerfBaselinesPath = 'docs/PERF_BASELINES.json';

/// Outcome of a single `--check` invocation. Used so the CLI and any
/// future test harness can share the same decision shape.
enum PerfCheckOutcome {
  /// Measured value is within `baseline * regression_factor`.
  ok,

  /// Measured value exceeds the regression threshold.
  regression,

  /// Baseline value is `null` (not yet captured); treated as a pass.
  skipped,
}

/// Result of a single `--check` invocation.
class PerfCheckResult {
  const PerfCheckResult({
    required this.metric,
    required this.measured,
    required this.baseline,
    required this.regressionFactor,
    required this.outcome,
  });

  final String metric;
  final num measured;
  final num? baseline;
  final num regressionFactor;
  final PerfCheckOutcome outcome;

  /// Computed regression threshold; null when baseline is null.
  num? get threshold =>
      baseline == null ? null : baseline! * regressionFactor;
}

/// Read + parse `docs/PERF_BASELINES.json`. Returns the decoded map.
Map<String, dynamic> _readBaselinesFile(File file) {
  if (!file.existsSync()) {
    stderr.writeln(
      'perf_baseline_check: $kPerfBaselinesPath not found '
      '(run from repository root).',
    );
    exit(2);
  }
  final raw = file.readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln(
      'perf_baseline_check: $kPerfBaselinesPath is not a JSON object.',
    );
    exit(2);
  }
  return decoded;
}

/// Pretty-printed JSON write — 2-space indent, trailing newline, so the
/// file diff stays readable when `--capture` mutates a single value.
void _writeBaselinesFile(File file, Map<String, dynamic> data) {
  const encoder = JsonEncoder.withIndent('  ');
  file.writeAsStringSync('${encoder.convert(data)}\n');
}

/// Run `--check` against an in-memory baseline map. Pure function so
/// future tests can drive it without the filesystem.
PerfCheckResult runCheck({
  required Map<String, dynamic> baselines,
  required num regressionFactor,
  required String metric,
  required num measured,
}) {
  if (!baselines.containsKey(metric)) {
    stderr.writeln(
      'perf_baseline_check: unknown metric "$metric". '
      'Known metrics: ${baselines.keys.join(", ")}.',
    );
    exit(2);
  }
  final raw = baselines[metric];
  if (raw == null) {
    return PerfCheckResult(
      metric: metric,
      measured: measured,
      baseline: null,
      regressionFactor: regressionFactor,
      outcome: PerfCheckOutcome.skipped,
    );
  }
  if (raw is! num) {
    stderr.writeln(
      'perf_baseline_check: baseline for "$metric" is not numeric '
      '(got ${raw.runtimeType}).',
    );
    exit(2);
  }
  final threshold = raw * regressionFactor;
  final outcome = measured > threshold
      ? PerfCheckOutcome.regression
      : PerfCheckOutcome.ok;
  return PerfCheckResult(
    metric: metric,
    measured: measured,
    baseline: raw,
    regressionFactor: regressionFactor,
    outcome: outcome,
  );
}

/// Format `--list` output as a simple table. One row per baseline key.
String formatList(Map<String, dynamic> data) {
  final baselines = data['baselines'];
  if (baselines is! Map) {
    return 'perf_baseline_check: no `baselines` object in file.';
  }
  final capturedAt = data['captured_at'] ?? '(unknown)';
  final capturedBy = data['captured_by'] ?? '(unknown)';
  final factor = data['regression_factor'] ?? '(unknown)';
  final schema = data['schema_version'] ?? '(unknown)';

  final keyColWidth = baselines.keys
      .map((k) => k.toString().length)
      .fold<int>(6, (acc, len) => len > acc ? len : acc);

  final buffer = StringBuffer();
  buffer.writeln('perf_baseline_check: $kPerfBaselinesPath');
  buffer.writeln('  schema_version    : $schema');
  buffer.writeln('  captured_at       : $capturedAt');
  buffer.writeln('  captured_by       : $capturedBy');
  buffer.writeln('  regression_factor : $factor');
  buffer.writeln('');
  buffer.writeln('  ${'metric'.padRight(keyColWidth)}  value');
  buffer.writeln('  ${'-' * keyColWidth}  -----');
  final keys = baselines.keys.map((k) => k.toString()).toList()..sort();
  for (final key in keys) {
    final value = baselines[key];
    final shown = value == null ? '(not yet captured)' : value.toString();
    buffer.writeln('  ${key.padRight(keyColWidth)}  $shown');
  }
  return buffer.toString();
}

/// Today's date in `YYYY-MM-DD` form for the `captured_at` stamp.
String _todayIso() {
  final now = DateTime.now().toUtc();
  final y = now.year.toString().padLeft(4, '0');
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Parse a numeric string as either int or double. Tightly scoped to
/// CLI argument parsing — we keep `num` so `--check`/`--capture` accept
/// both integer counts (`100`) and decimal latencies (`124.5`).
num _parseNumber(String raw, String argName) {
  final asInt = int.tryParse(raw);
  if (asInt != null) return asInt;
  final asDouble = double.tryParse(raw);
  if (asDouble != null) return asDouble;
  stderr.writeln(
    'perf_baseline_check: $argName must be numeric (got "$raw").',
  );
  exit(2);
}

/// Print usage. Always to stdout — argparse-style "what arguments do I
/// take" output goes to stdout, not stderr, so `--help | less` works.
void _printUsage() {
  stdout.writeln(
    'Usage:\n'
    '  dart run tool/perf_baseline_check.dart --list\n'
    '  dart run tool/perf_baseline_check.dart --capture <metric> <value>\n'
    '  dart run tool/perf_baseline_check.dart --check <metric> <measured>\n'
    '\n'
    'Default mode is --check. See '
    '`runbooks/perf_baseline_capture_runbook.md` for when to capture '
    'and how the orchestrator wires --check into pressure-PR audits.',
  );
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    _printUsage();
    return;
  }

  final file = File(kPerfBaselinesPath);
  final data = _readBaselinesFile(file);
  final baselinesRaw = data['baselines'];
  if (baselinesRaw is! Map<String, dynamic>) {
    stderr.writeln(
      'perf_baseline_check: $kPerfBaselinesPath has no `baselines` '
      'object.',
    );
    exitCode = 2;
    return;
  }
  final regressionFactor = data['regression_factor'];
  if (regressionFactor is! num) {
    stderr.writeln(
      'perf_baseline_check: `regression_factor` must be numeric '
      '(got ${regressionFactor.runtimeType}).',
    );
    exitCode = 2;
    return;
  }

  // --list -----------------------------------------------------------------
  if (args.first == '--list') {
    stdout.write(formatList(data));
    return;
  }

  // --capture <metric> <value> --------------------------------------------
  if (args.first == '--capture') {
    if (args.length != 3) {
      stderr.writeln(
        'perf_baseline_check: --capture takes exactly two args '
        '(metric and value).',
      );
      _printUsage();
      exitCode = 2;
      return;
    }
    final metric = args[1];
    if (!baselinesRaw.containsKey(metric)) {
      stderr.writeln(
        'perf_baseline_check: unknown metric "$metric". '
        'Known metrics: ${baselinesRaw.keys.join(", ")}.',
      );
      stderr.writeln(
        'Refusing to write — schema typos create ghost keys.',
      );
      exitCode = 2;
      return;
    }
    final value = _parseNumber(args[2], 'value');
    baselinesRaw[metric] = value;
    data['captured_at'] = _todayIso();
    _writeBaselinesFile(file, data);
    stdout.writeln(
      'perf_baseline_check: captured $metric = $value '
      '(captured_at -> ${data['captured_at']}).',
    );
    return;
  }

  // --check <metric> <measured> (default) ---------------------------------
  List<String> checkArgs;
  if (args.first == '--check') {
    checkArgs = args.sublist(1);
  } else {
    checkArgs = args;
  }
  if (checkArgs.length != 2) {
    stderr.writeln(
      'perf_baseline_check: --check takes exactly two args '
      '(metric and measured).',
    );
    _printUsage();
    exitCode = 2;
    return;
  }
  final metric = checkArgs[0];
  final measured = _parseNumber(checkArgs[1], 'measured');
  final result = runCheck(
    baselines: baselinesRaw,
    regressionFactor: regressionFactor,
    metric: metric,
    measured: measured,
  );

  switch (result.outcome) {
    case PerfCheckOutcome.skipped:
      stdout.writeln(
        'perf_baseline_check: ${result.metric} '
        'baseline not captured yet — SKIPPED.',
      );
      return;
    case PerfCheckOutcome.ok:
      stdout.writeln(
        'perf_baseline_check: ${result.metric} = ${result.measured} '
        'within x${result.regressionFactor} of baseline '
        '${result.baseline} — OK.',
      );
      return;
    case PerfCheckOutcome.regression:
      stderr.writeln(
        'perf_baseline_check: ${result.metric} = ${result.measured} '
        '(baseline ${result.baseline}, threshold ${result.threshold}) '
        '— REGRESSION.',
      );
      exitCode = 1;
      return;
  }
}
