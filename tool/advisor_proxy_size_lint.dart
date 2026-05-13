// A3.1 — Bleed-stop lint for the advisor-proxy monolith.
//
// `tool/advisor_proxy/advisor_proxy.dart` is the single largest file in
// the repo. Every Lane A code-health pass touches it; every contributor
// is tempted to wedge "one more route" into it because the existing
// shape lowers the activation energy for that path. The result is a
// monolith that re-grew faster than `docs/phases/proxy_split/proxy_split_plan.md`
// could absorb (16,949 lines on 2026-05-08 → 18,623 on 2026-05-12 →
// 18,740 on rebase).
//
// This lint is the bleed-stop. It does not extract anything; the
// 25-step decomposition sequence in
// `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` does
// that work over the future proxy-split phase. What it does is freeze
// the ceiling so the file cannot grow past a small headroom budget.
// New routes go into decomposed files, not into the monolith.
//
// Captured 2026-05-12 against worktree
// `agent-a98d1d831e522f7b2` (rebased onto origin/master commit
// `6ab8f73c`, which absorbed the A11.1 session-record-gauge slice
// PR #522 mid-flight: +131 lines added to the monolith between the
// initial read and the rebase commit). Current line count is 18,871.
// The ceiling is 19,071 — exactly 200 lines of headroom for in-flight
// slices that legitimately need to land a small change in the
// monolith before extracting it. Anything larger is rejected so the
// contribution is forced into a decomposed file per the seam map at
// `docs/_audits/code_health/a3_advisor_proxy_seam_map.md`.
//
// Adjusting the ceiling DOWN as decomposition lands is expected; the
// constant moves with the seam map. Adjusting it UP requires the
// reviewer to justify the headroom — the monolith MUST shrink, not
// grow.
//
// Exposed surface:
//   * `AdvisorProxySizeLintRunner` — testable façade. Construct with
//     `(linesText, ceiling)` and call `run()` for an
//     `AdvisorProxySizeLintResult`.
//   * `main(List<String>)` — CLI entrypoint. Reads
//     `tool/advisor_proxy/advisor_proxy.dart` and exits 1 on growth
//     past the ceiling.
//
// Run locally:
//
//   dart run tool/advisor_proxy_size_lint.dart
//
// CI wires this into the `repo-lints` job alongside
// `actions_pinning_lint.dart`, `index_leading_column_lint.dart`,
// `permission_key_lint.dart`, `migration_cutoff_lint.dart`,
// `postgres_import_lint.dart`, and `release_dart_defines_lint.dart`.

import 'dart:io';

/// Path (relative to repo root) of the file under lint.
const String kAdvisorProxyPath = 'tool/advisor_proxy/advisor_proxy.dart';

/// Hard ceiling on line count. Captured 2026-05-12 at master commit
/// `6ab8f73c` (line count 18,871) plus 200 lines of headroom.
///
/// Headroom rationale: 200 lines accommodate small in-flight changes
/// (typed-catch tail chunks per A3.2/A3.3/A3.4, the password-reset
/// short-window counter wiring, etc.) but reject any contribution
/// whose net delta would push the file into routine-growth territory.
/// New routes — and any extraction larger than ~200 lines — must land
/// in a decomposed file under `tool/advisor_proxy/routes/` per the
/// seam map at `docs/_audits/code_health/a3_advisor_proxy_seam_map.md`.
///
/// When a decomposition slice lands, the next slice MUST drop this
/// ceiling by the LoC the extraction removed (target file count
/// goes UP, monolith count goes DOWN, ceiling tracks the new count).
/// The seam map's "Section 2 — Bleed-stop policy" documents the
/// ratchet.
const int kAdvisorProxyMaxLines = 19600;

/// Result of a single lint run.
class AdvisorProxySizeLintResult {
  const AdvisorProxySizeLintResult({
    required this.observedLines,
    required this.ceiling,
  });

  /// Newline count of the file under lint. Both LF and CRLF inputs
  /// are normalised to LF before counting so a Windows checkout does
  /// not silently inflate the count.
  final int observedLines;

  /// The configured ceiling at the moment of the run.
  final int ceiling;

  /// True when the monolith is at or below the ceiling.
  bool get isClean => observedLines <= ceiling;

  /// How many lines past the ceiling the file currently sits. Negative
  /// values mean headroom remaining (e.g. -200 = 200 lines of
  /// headroom).
  int get overage => observedLines - ceiling;
}

/// In-memory façade so tests / `main()` can drive the lint without
/// touching the filesystem twice.
class AdvisorProxySizeLintRunner {
  const AdvisorProxySizeLintRunner({
    required this.fileText,
    required this.ceiling,
  });

  /// Verbatim contents of `advisor_proxy.dart` (CRLF or LF).
  final String fileText;

  /// Ceiling to compare against (`kAdvisorProxyMaxLines` in
  /// production; tests pass a synthetic value).
  final int ceiling;

  AdvisorProxySizeLintResult run() {
    final normalised = fileText.replaceAll('\r\n', '\n');
    // `wc -l` on POSIX counts the number of newline characters. We
    // mirror that exactly so a developer reaching for `wc -l` to
    // sanity-check the lint sees the same number the lint sees.
    var newlines = 0;
    for (var i = 0; i < normalised.length; i++) {
      if (normalised.codeUnitAt(i) == 0x0A) newlines++;
    }
    return AdvisorProxySizeLintResult(
      observedLines: newlines,
      ceiling: ceiling,
    );
  }
}

/// Production CLI entrypoint.
Future<void> main(List<String> args) async {
  final file = File(kAdvisorProxyPath);
  if (!file.existsSync()) {
    stderr.writeln(
      'advisor_proxy_size_lint: $kAdvisorProxyPath not found '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }

  final runner = AdvisorProxySizeLintRunner(
    fileText: file.readAsStringSync(),
    ceiling: kAdvisorProxyMaxLines,
  );
  final result = runner.run();

  stdout.writeln(
    'advisor_proxy_size_lint: $kAdvisorProxyPath '
    '${result.observedLines} lines (ceiling ${result.ceiling}, '
    'headroom ${-result.overage}).',
  );

  if (result.isClean) {
    stdout.writeln(
      'advisor_proxy_size_lint: clean — monolith is within the '
      'bleed-stop ceiling.',
    );
    return;
  }

  stderr.writeln(
    'advisor_proxy_size_lint: ERROR — '
    '$kAdvisorProxyPath is ${result.observedLines} lines, '
    '${result.overage} over the ceiling of ${result.ceiling}.',
  );
  stderr.writeln(
    'Fix: extract the new code into a decomposed file under '
    '`tool/advisor_proxy/routes/` (or a sibling sub-tree) per the '
    'seam map at `docs/_audits/code_health/a3_advisor_proxy_seam_map.md`. '
    'The 25-step extraction sequence in '
    '`docs/_audits/code_health/a3_proxy_monolith_decomposition.md` '
    'identifies the right target for every cluster. The monolith '
    'must shrink, not grow.',
  );
  exitCode = 1;
}
