// Flake counter.
//
// Phase A (refactor-phase) test-integrity guardrail. A refactor is only
// safe to land on a STABLE baseline: a test that passes on one run and
// fails on the next ("flaky") makes every later red ambiguous — is it the
// refactor, or the flake? This tool runs a given test directory N times
// (default 3) via `flutter test <dir> --reporter json`, tallies each
// test's pass/fail across the N seeds, and FAILS (exit 1) listing any test
// that was not 100% consistent. A clean run (exit 0) is the green light to
// treat that directory's suite as a trustworthy baseline.
//
// The companion baseline doc
// (`docs/_audits/code_health/test_baseline_2026_05_22.md`) records the
// full-suite counts plus this tool's result for
// `test/operator_web/screens`.
//
// Usage:
//
//   dart run tool/flake_counter.dart <test-dir> [N]
//
//   <test-dir>  directory passed to `flutter test` (e.g.
//               `test/operator_web/screens`). Required.
//   [N]         number of runs (seeds). Optional; default 3.
//
// Memory posture
// --------------
// Each `flutter test --reporter json` run streams one JSON object per
// line. We read that stream LINE BY LINE (`stdout.transform(utf8).
// transform(LineSplitter())`) and parse each line independently — never
// buffering the whole output — so a multi-thousand-test suite stays
// bounded in memory. Non-JSON lines (Flutter tool banners, analyzer
// chatter, blank lines) are skipped defensively.
//
// JSON-lines protocol (subset we consume; see package:test reporter):
//   {"type":"testStart","test":{"id":N,"name":"...","url":"...",
//        "metadata":{"skip":bool,...},...}}
//   {"type":"testDone","testID":N,"result":"success|failure|error",
//        "skipped":bool,"hidden":bool,...}
//   {"type":"done","success":bool,...}
// Hidden tests (the synthetic "loading ..." entries) and skipped tests are
// excluded from the flake tally.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Default number of runs when N is not supplied on the command line.
const int kDefaultRunCount = 3;

/// Per-test outcome across all seeds.
class TestTally {
  TestTally(this.name);

  final String name;
  int passes = 0;
  int failures = 0;
  int errors = 0;

  /// Total runs in which this test produced a non-skipped, non-hidden
  /// outcome.
  int get observed => passes + failures + errors;

  /// True when every observed run produced the SAME outcome.
  bool get isConsistent =>
      (passes == observed && observed > 0) ||
      (failures == observed && observed > 0) ||
      (errors == observed && observed > 0) ||
      observed == 0;

  /// Dominant outcome label for the report.
  String get summary => 'pass=$passes fail=$failures error=$errors';
}

/// Result of one `flutter test` run: testID → outcome, plus run-level
/// success flag.
class SingleRunResult {
  SingleRunResult({
    required this.outcomes,
    required this.runSucceeded,
    required this.parsedLineCount,
  });

  /// Test display name → outcome string ('success' | 'failure' | 'error').
  final Map<String, String> outcomes;

  /// The reporter's run-level `done.success` flag (false on any failure).
  final bool runSucceeded;

  /// How many JSON objects we parsed (diagnostics).
  final int parsedLineCount;
}

/// Aggregates [SingleRunResult]s into per-test tallies.
class FlakeTally {
  final Map<String, TestTally> _byName = <String, TestTally>{};

  void addRun(SingleRunResult run) {
    for (final entry in run.outcomes.entries) {
      final tally = _byName.putIfAbsent(entry.key, () => TestTally(entry.key));
      switch (entry.value) {
        case 'success':
          tally.passes++;
        case 'failure':
          tally.failures++;
        case 'error':
          tally.errors++;
      }
    }
  }

  List<TestTally> get all => _byName.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  /// Tests that were NOT 100% consistent across the seeds in which they
  /// were observed. (A test observed in only some runs but always with the
  /// same outcome is still consistent; cross-run presence gaps are reported
  /// separately by [presenceGaps].)
  List<TestTally> get flaky =>
      all.where((t) => !t.isConsistent).toList();

  /// Tests observed in fewer runs than [expectedRuns] — they appeared in
  /// some seeds but not others, which is itself a stability smell.
  List<TestTally> presenceGaps(int expectedRuns) =>
      all.where((t) => t.observed > 0 && t.observed < expectedRuns).toList();
}

/// Parses one line of the reporter stream into a JSON map, or returns
/// `null` when the line is not a JSON object (banner text, blank, etc.).
Map<String, Object?>? parseReporterLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null; // defensive: malformed / partial line.
  }
}

/// Runs `flutter test <dir> --reporter json` once, streaming stdout
/// line-by-line, and returns the per-test outcomes. Memory stays bounded:
/// we hold a `testID → name` map and a `name → outcome` map, not the raw
/// output.
Future<SingleRunResult> runOnce({
  required String testDir,
  required int seedIndex,
}) async {
  final process = await Process.start(
    'flutter',
    <String>['test', testDir, '--reporter', 'json'],
    runInShell: true,
  );

  final idToName = <int, String>{};
  final idIsHidden = <int, bool>{};
  final idIsSkipped = <int, bool>{};
  final outcomes = <String, String>{};
  var parsedLines = 0;
  var doneSuccess = false;

  // Drain stderr so the process does not block on a full pipe; we do not
  // parse it (reporter output is on stdout).
  final stderrDrain =
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).drain<void>();

  final stdoutLines =
      process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  await for (final line in stdoutLines) {
    final obj = parseReporterLine(line);
    if (obj == null) continue;
    parsedLines++;
    final type = obj['type'];
    if (type == 'testStart') {
      final test = obj['test'];
      if (test is Map) {
        final id = (test['id'] as num?)?.toInt();
        final name = test['name'] as String?;
        if (id != null) {
          if (name != null) idToName[id] = name;
          // `name` is null/empty for synthetic loading suites; treat the
          // `url == null` (no source) entries as hidden.
          final url = test['url'];
          final meta = test['metadata'];
          final metaSkip =
              meta is Map ? (meta['skip'] == true) : false;
          idIsHidden[id] = url == null;
          idIsSkipped[id] = metaSkip;
        }
      }
    } else if (type == 'testDone') {
      final id = (obj['testID'] as num?)?.toInt();
      if (id == null) continue;
      final hidden = (obj['hidden'] == true) || (idIsHidden[id] ?? false);
      final skipped = (obj['skipped'] == true) || (idIsSkipped[id] ?? false);
      if (hidden || skipped) continue;
      final result = (obj['result'] as String?) ?? 'unknown';
      final name = idToName[id] ?? 'test#$id';
      outcomes[name] = result;
    } else if (type == 'done') {
      doneSuccess = obj['success'] == true;
    }
  }

  final exitCode = await process.exitCode;
  await stderrDrain;

  return SingleRunResult(
    outcomes: outcomes,
    runSucceeded: doneSuccess && exitCode == 0,
    parsedLineCount: parsedLines,
  );
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'flake_counter: usage: dart run tool/flake_counter.dart <test-dir> [N]',
    );
    exitCode = 2;
    return;
  }
  final testDir = args[0];
  final runCount = args.length >= 2 ? int.tryParse(args[1]) : kDefaultRunCount;
  if (runCount == null || runCount < 1) {
    stderr.writeln('flake_counter: N must be a positive integer; got ${args[1]}');
    exitCode = 2;
    return;
  }

  if (!Directory(testDir).existsSync() && !File(testDir).existsSync()) {
    stderr.writeln('flake_counter: test path not found: $testDir');
    exitCode = 2;
    return;
  }

  stdout.writeln(
    'flake_counter: running `flutter test $testDir --reporter json` '
    '$runCount time(s)...',
  );

  final tally = FlakeTally();
  final runSucceeded = <bool>[];
  for (var seed = 0; seed < runCount; seed++) {
    stdout.writeln('  run ${seed + 1}/$runCount ...');
    final result = await runOnce(testDir: testDir, seedIndex: seed);
    tally.addRun(result);
    runSucceeded.add(result.runSucceeded);
    stdout.writeln(
      '    parsed ${result.parsedLineCount} JSON event(s); '
      '${result.outcomes.length} test outcome(s); '
      'run ${result.runSucceeded ? "GREEN" : "RED"}.',
    );
  }

  final flaky = tally.flaky;
  final gaps = tally.presenceGaps(runCount);

  stdout.writeln('');
  stdout.writeln('flake_counter: per-test tally across $runCount run(s):');
  stdout.writeln('  total distinct tests observed: ${tally.all.length}');
  stdout.writeln('  consistent: ${tally.all.length - flaky.length}');
  stdout.writeln('  inconsistent (flaky): ${flaky.length}');
  stdout.writeln('  presence gaps (ran in some seeds only): ${gaps.length}');

  if (flaky.isEmpty && gaps.isEmpty) {
    stdout.writeln('');
    stdout.writeln(
      'flake_counter: STABLE — every test produced the same outcome across '
      'all $runCount run(s).',
    );
    return;
  }

  stdout.writeln('');
  if (flaky.isNotEmpty) {
    stdout.writeln('flake_counter: INCONSISTENT tests:');
    for (final t in flaky) {
      stdout.writeln('  FLAKY  ${t.name}  [${t.summary}]');
    }
  }
  if (gaps.isNotEmpty) {
    stdout.writeln('flake_counter: PRESENCE-GAP tests '
        '(observed in < $runCount run(s)):');
    for (final t in gaps) {
      stdout.writeln('  GAP    ${t.name}  [observed=${t.observed}/$runCount '
          '${t.summary}]');
    }
  }
  exitCode = 1;
}
