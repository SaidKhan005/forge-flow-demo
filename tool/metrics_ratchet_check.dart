// Phase A A4 — dart_code_linter metrics violation-count ratchet.
//
// `runbooks/dart_code_metrics_runbook.md` captures a per-metric baseline
// of how many functions violate four engineering bars (function length,
// cyclomatic complexity, nesting depth, parameter count). Those metrics
// are ADVISORY today (the analyzer plugin is intentionally off; see the
// runbook's "Advisory posture"). The refactor phase reduces those
// counts; the failure mode is silent regrowth — a new long/complex
// function landing while nobody is watching the aggregate count.
//
// This tool is the ratchet. It runs the metrics CLI, counts the
// `warning`/`alarm` functions per metric, and compares each count to a
// committed baseline (`tool/metrics_ratchet_baseline.json`). It FAILS
// if any metric's count GREW past its baseline. When a count DROPPED,
// it prints a note that the baseline can be lowered (a deliberate
// ratchet step), but it does NOT auto-rewrite the baseline — tightening
// the bar is a deliberate, reviewed act (CLAUDE.md "Ceiling-raise rule
// R-2": the ratchet only tightens on purpose, never silently).
//
// CRITICAL parsing gotcha (verified 2026-05-22): the metrics CLI writes
// progress-spinner text to stdout BEFORE the JSON document. Everything
// before the first literal `{"formatVersion` is stripped before parsing.
// The JSON root is an object with keys formatVersion / records /
// summary / timestamp; each `.records[]` carries a `.functions` map
// whose values have a `.metrics[]` list of {metricsId, value, level}.
//
// Exposed surface:
//   * `kRatchetMetricIds` — the four tracked metric ids.
//   * `extractMetricsJson` — strips the pre-JSON spinner junk.
//   * `countViolations` — pure counter over a parsed report.
//   * `MetricsRatchetResult` — per-metric baseline-vs-current outcome.
//   * `compareToBaseline` — pure comparison.
//   * `main(List<String>)` — CLI entrypoint; exits 1 if any count grew.
//
// Run locally (from repository root):
//
//   dart run tool/metrics_ratchet_check.dart
//
// Modeled on `tool/advisor_proxy_size_lint.dart` and
// `tool/ignore_justification_lint.dart`.

import 'dart:convert';
import 'dart:io';

/// Repo-relative path of the committed baseline counts.
const String kBaselinePath = 'tool/metrics_ratchet_baseline.json';

/// The four engineering-bar metrics tracked by the ratchet, in report
/// order. Ids match `dart_code_linter`'s `metricsId` values and the
/// `dart_code_linter:` block in `analysis_options.yaml`.
const List<String> kRatchetMetricIds = <String>[
  'source-lines-of-code',
  'cyclomatic-complexity',
  'maximum-nesting-level',
  'number-of-parameters',
];

/// The literal that marks the start of the JSON document inside the
/// CLI's stdout (which is prefixed by progress-spinner text).
const String kJsonStartMarker = '{"formatVersion';

/// The command the CLI ratchet shells out to. `lib/` scope + JSON
/// reporter, exactly as documented in
/// `runbooks/dart_code_metrics_runbook.md`.
const List<String> kMetricsCommand = <String>[
  'run',
  'dart_code_linter:metrics',
  'analyze',
  'lib/',
  '--reporter=json',
];

/// Strips everything before the first `{"formatVersion` so the
/// progress-spinner text the CLI writes to stdout does not break
/// `jsonDecode`. Throws [FormatException] if the marker is absent.
String extractMetricsJson(String rawStdout) {
  final idx = rawStdout.indexOf(kJsonStartMarker);
  if (idx < 0) {
    throw const FormatException(
      'metrics_ratchet_check: no "$kJsonStartMarker" marker in CLI '
      'output — the metrics reporter produced no JSON document.',
    );
  }
  return rawStdout.substring(idx);
}

/// Counts, per tracked metric id, the number of functions whose `level`
/// is `warning` or `alarm`. [report] is the decoded JSON root object.
Map<String, int> countViolations(Map<String, dynamic> report) {
  final counts = <String, int>{for (final id in kRatchetMetricIds) id: 0};

  final records = report['records'];
  if (records is! List) return counts;

  for (final record in records) {
    if (record is! Map) continue;
    final functions = record['functions'];
    if (functions is! Map) continue;
    for (final fn in functions.values) {
      if (fn is! Map) continue;
      final metrics = fn['metrics'];
      if (metrics is! List) continue;
      for (final metric in metrics) {
        if (metric is! Map) continue;
        final id = metric['metricsId'];
        final level = metric['level'];
        if (id is String &&
            counts.containsKey(id) &&
            (level == 'warning' || level == 'alarm')) {
          counts[id] = counts[id]! + 1;
        }
      }
    }
  }
  return counts;
}

/// Per-metric comparison outcome.
class MetricRatchetRow {
  const MetricRatchetRow({
    required this.metricId,
    required this.baseline,
    required this.current,
  });

  final String metricId;
  final int baseline;
  final int current;

  /// Positive when the count grew (a violation), negative when it
  /// dropped (a candidate baseline-lowering ratchet step).
  int get delta => current - baseline;

  bool get grew => current > baseline;
  bool get dropped => current < baseline;
}

/// Aggregate comparison result.
class MetricsRatchetResult {
  const MetricsRatchetResult({required this.rows});

  final List<MetricRatchetRow> rows;

  Iterable<MetricRatchetRow> get grewRows => rows.where((r) => r.grew);
  Iterable<MetricRatchetRow> get droppedRows => rows.where((r) => r.dropped);

  /// Clean when no metric's count grew past its baseline.
  bool get isClean => grewRows.isEmpty;
}

/// Pure comparison of [current] counts against [baseline] counts over
/// the tracked metric ids.
MetricsRatchetResult compareToBaseline(
  Map<String, int> baseline,
  Map<String, int> current,
) {
  final rows = <MetricRatchetRow>[];
  for (final id in kRatchetMetricIds) {
    rows.add(MetricRatchetRow(
      metricId: id,
      baseline: baseline[id] ?? 0,
      current: current[id] ?? 0,
    ));
  }
  return MetricsRatchetResult(rows: rows);
}

/// Production CLI entrypoint.
Future<void> main(List<String> args) async {
  final baselineFile = File(kBaselinePath);
  if (!baselineFile.existsSync()) {
    stderr.writeln(
      'metrics_ratchet_check: baseline $kBaselinePath not found '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }

  final Map<String, int> baseline;
  try {
    final decoded = jsonDecode(baselineFile.readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException('baseline root is not a JSON object');
    }
    baseline = <String, int>{
      for (final id in kRatchetMetricIds)
        id: (decoded[id] as num?)?.toInt() ?? 0,
    };
  } on FormatException catch (e) {
    stderr.writeln('metrics_ratchet_check: malformed baseline — $e');
    exitCode = 2;
    return;
  }

  stdout.writeln(
    'metrics_ratchet_check: running '
    'dart ${kMetricsCommand.join(' ')} (this can take ~1 minute)...',
  );

  final ProcessResult proc;
  try {
    proc = await Process.run(
      'dart',
      kMetricsCommand,
      runInShell: true,
    );
  } on ProcessException catch (e) {
    stderr.writeln(
      'metrics_ratchet_check: failed to launch the metrics CLI — $e',
    );
    exitCode = 2;
    return;
  }

  final rawStdout = proc.stdout is String
      ? proc.stdout as String
      : utf8.decode(proc.stdout as List<int>, allowMalformed: true);

  final String jsonText;
  try {
    jsonText = extractMetricsJson(rawStdout);
  } on FormatException catch (e) {
    stderr.writeln('metrics_ratchet_check: $e');
    if (proc.exitCode != 0) {
      stderr.writeln(
        'metrics_ratchet_check: the CLI exited ${proc.exitCode}; '
        'stderr tail:',
      );
      final err = proc.stderr is String
          ? proc.stderr as String
          : utf8.decode(proc.stderr as List<int>, allowMalformed: true);
      stderr.writeln(err);
    }
    exitCode = 2;
    return;
  }

  final Map<String, dynamic> report;
  try {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON root is not an object');
    }
    report = decoded;
  } on FormatException catch (e) {
    stderr.writeln('metrics_ratchet_check: could not parse metrics JSON — $e');
    exitCode = 2;
    return;
  }

  final current = countViolations(report);
  final result = compareToBaseline(baseline, current);

  stdout.writeln('metrics_ratchet_check: per-metric baseline vs current');
  for (final row in result.rows) {
    final tag = row.grew
        ? 'GREW +${row.delta}'
        : row.dropped
            ? 'dropped ${row.delta}'
            : 'same';
    stdout.writeln(
      '  ${row.metricId.padRight(24)} baseline ${row.baseline} '
      'current ${row.current}  [$tag]',
    );
  }

  if (result.droppedRows.isNotEmpty) {
    stdout.writeln(
      'metrics_ratchet_check: note — ${result.droppedRows.length} '
      'metric(s) dropped below baseline. The baseline in $kBaselinePath '
      'CAN be lowered to lock in the gain (a deliberate ratchet step), '
      'but this tool does NOT auto-rewrite it — lower it in a reviewed '
      'commit. Metrics that dropped:',
    );
    for (final row in result.droppedRows) {
      stdout.writeln(
        '  ${row.metricId}: baseline ${row.baseline} -> '
        'could be ${row.current}.',
      );
    }
  }

  if (result.isClean) {
    stdout.writeln(
      'metrics_ratchet_check: clean — no metric grew past its baseline.',
    );
    return;
  }

  stderr.writeln(
    'metrics_ratchet_check: ERROR — ${result.grewRows.length} metric(s) '
    'grew past baseline:',
  );
  for (final row in result.grewRows) {
    stderr.writeln(
      '  ${row.metricId}: baseline ${row.baseline}, current '
      '${row.current} (+${row.delta}).',
    );
  }
  stderr.writeln(
    'Fix: the new/changed code added function(s) that violate an '
    'engineering bar. Decompose the offending function(s) so the count '
    'returns to baseline rather than raising the baseline. The ratchet '
    'only tightens; raising a baseline needs explicit operator approval '
    '(CLAUDE.md "Ceiling-raise rule R-2"). See '
    'runbooks/dart_code_metrics_runbook.md.',
  );
  exitCode = 1;
}
