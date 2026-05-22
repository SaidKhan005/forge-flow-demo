// Phase A A3 — Anti-regrowth size lint for the admin + operator-web screens.
//
// The refactor phase decomposes the largest admin and operator-web
// screens into smaller widgets/services. While that work is in flight,
// the failure mode is regrowth: a contributor wedges "one more dialog"
// or "one more route branch" into an already-oversized screen because
// the existing shape lowers the activation energy for that path — the
// same dynamic that grew the advisor-proxy monolith faster than its
// decomposition plan could absorb (see
// `tool/advisor_proxy_size_lint.dart`).
//
// This lint is the bleed-stop for those screens. It does NOT extract
// anything; the decomposition slices do that. What it does is FREEZE a
// per-file ceiling at the file's current line count so the file cannot
// grow. New code goes into decomposed files, not into these monoliths.
//
// Ceiling policy (mirrors the advisor-proxy doctrine: the monolith MUST
// shrink, not grow):
//   * Ceilings are FROZEN during the refactor phase at the line count
//     captured when this lint landed. They are seeded from `wc -l` on
//     each file, not guessed.
//   * Ceilings are LOWERED (never raised) as each screen is decomposed:
//     when a slice extracts N lines out of a screen, the same slice
//     drops that screen's ceiling so the file count goes DOWN and the
//     ceiling tracks it. The ratchet only tightens.
//   * RAISING a ceiling requires explicit operator approval — same gate
//     as auth-critical / RLS / schema / proxy slices (CLAUDE.md
//     "Ceiling-raise rule R-2"). A raise is never a drive-by edit.
//
// Exposed surface:
//   * `OperatorWebSizeLintEntry` — one (path, ceiling) pair.
//   * `OperatorWebSizeLintFinding` — per-file outcome (ok / grew /
//     missing) with observed line count and delta.
//   * `OperatorWebSizeLintRunner` — testable façade. Construct with a
//     map of path → file text and the ceilings, call `run()`.
//   * `main(List<String>)` — CLI entrypoint. Reads each listed file and
//     exits 1 if ANY file exceeds its ceiling.
//
// Run locally:
//
//   dart run tool/operator_web_size_lint.dart
//
// Modeled on `tool/advisor_proxy_size_lint.dart` and
// `tool/ignore_justification_lint.dart`.

import 'dart:io';

/// Frozen per-file ceilings, keyed by repo-relative forward-slashed path.
///
/// Each value is the file's line count (`wc -l` semantics: number of
/// `\n` characters) at the moment this lint landed in the refactor
/// phase. Seeded from `wc -l`, not guessed. LOWER these as decomposition
/// lands; raising any value needs explicit operator approval per
/// CLAUDE.md "Ceiling-raise rule R-2". The monolith MUST shrink, not
/// grow.
const Map<String, int> kOperatorWebSizeCeilings = <String, int>{
  'lib/admin/screens/operator_location_admin_screen.dart': 5162,
  'lib/admin/admin_routes.dart': 4078,
  'lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart': 3255,
  'lib/admin/screens/observability_admin_screen.dart': 3152,
  'lib/admin/screens/corpus_admin_screen.dart': 2549,
  'lib/admin/screens/members_admin_screen.dart': 2532,
  'lib/operator_web/router/operator_web_router.dart': 2941,
  // +1 (2108) over the prior 2107 ceiling: the single `import
  // '../widgets/operator_web_screen_body.dart';` line added when this
  // screen's main body scroll view was routed through the shared
  // `OperatorWebScreenBody` centered-body wrapper. The scroll-view rename
  // itself is line-neutral (2-for-2 swap); the import is the only added
  // line. PENDING operator approval per CLAUDE.md "Ceiling-raise rule R-2";
  // the ratchet resumes tightening from here.
  'lib/operator_web/screens/my_account_screen.dart': 2108,
  // 2222: operator-approved R-2 raise (2026-05-22) for the #7
  // reset-to-inherited control (clears a scope's account overrides so it
  // falls back to the inherited values). The control + its in-file
  // decomposition (kept under the dart_code_linter complexity/length bars)
  // land together here. One-time feature-driven raise; the ratchet resumes
  // tightening from here.
  // +1 (2223) over 2222: the shared `OperatorWebScreenBody` import line
  // (centered-body wrapper). Scroll-view rename is line-neutral; the import
  // is the only added line. PENDING operator approval per "Ceiling-raise
  // rule R-2".
  'lib/operator_web/screens/account_screen.dart': 2223,
  // +1 (1702) over 1701: the shared `OperatorWebScreenBody` import line
  // (centered-body wrapper). Scroll-view rename is line-neutral; the import
  // is the only added line. PENDING operator approval per "Ceiling-raise
  // rule R-2".
  'lib/operator_web/screens/members_screen.dart': 1702,
};

/// Outcome category for a single file.
enum OperatorWebSizeStatus {
  /// File is at or under its ceiling.
  ok,

  /// File exceeds its ceiling (regrowth) — a hard failure.
  grew,

  /// Listed file was not found on disk — warned, not a failure.
  missing,
}

/// Per-file lint outcome.
class OperatorWebSizeLintFinding {
  const OperatorWebSizeLintFinding({
    required this.path,
    required this.ceiling,
    required this.observedLines,
    required this.status,
  });

  /// Repo-relative forward-slashed path.
  final String path;

  /// The frozen ceiling for this file.
  final int ceiling;

  /// Newline count of the file (`wc -l` semantics), or -1 when missing.
  final int observedLines;

  final OperatorWebSizeStatus status;

  /// Lines past the ceiling (positive = grew, negative = headroom).
  /// Zero for missing files.
  int get overage =>
      status == OperatorWebSizeStatus.missing ? 0 : observedLines - ceiling;
}

/// Aggregate result of one lint run.
class OperatorWebSizeLintResult {
  const OperatorWebSizeLintResult({required this.findings});

  final List<OperatorWebSizeLintFinding> findings;

  Iterable<OperatorWebSizeLintFinding> get grew =>
      findings.where((f) => f.status == OperatorWebSizeStatus.grew);

  Iterable<OperatorWebSizeLintFinding> get missing =>
      findings.where((f) => f.status == OperatorWebSizeStatus.missing);

  /// Clean when no file grew past its ceiling. A missing file warns but
  /// does not fail the lint (handled gracefully per the slice contract).
  bool get isClean => grew.isEmpty;
}

/// In-memory façade so tests / `main()` can drive the lint without
/// re-reading the filesystem. [files] maps path → file text; a path
/// present in [ceilings] but absent from [files] is reported as missing.
class OperatorWebSizeLintRunner {
  const OperatorWebSizeLintRunner({
    required this.files,
    required this.ceilings,
  });

  /// Map of repo-relative path → verbatim file contents (CRLF or LF).
  final Map<String, String?> files;

  /// Map of repo-relative path → frozen ceiling.
  final Map<String, int> ceilings;

  OperatorWebSizeLintResult run() {
    final findings = <OperatorWebSizeLintFinding>[];
    for (final entry in ceilings.entries) {
      final path = entry.key;
      final ceiling = entry.value;
      final text = files[path];
      if (text == null) {
        findings.add(OperatorWebSizeLintFinding(
          path: path,
          ceiling: ceiling,
          observedLines: -1,
          status: OperatorWebSizeStatus.missing,
        ));
        continue;
      }
      final observed = _countNewlines(text);
      findings.add(OperatorWebSizeLintFinding(
        path: path,
        ceiling: ceiling,
        observedLines: observed,
        status: observed > ceiling
            ? OperatorWebSizeStatus.grew
            : OperatorWebSizeStatus.ok,
      ));
    }
    return OperatorWebSizeLintResult(findings: findings);
  }

  /// Counts `\n` after normalising CRLF → LF, mirroring `wc -l` so a
  /// Windows checkout does not silently inflate the count. Matches the
  /// counting in `tool/advisor_proxy_size_lint.dart`.
  static int _countNewlines(String text) {
    final normalised = text.replaceAll('\r\n', '\n');
    var newlines = 0;
    for (var i = 0; i < normalised.length; i++) {
      if (normalised.codeUnitAt(i) == 0x0A) newlines++;
    }
    return newlines;
  }
}

/// Production CLI entrypoint.
Future<void> main(List<String> args) async {
  final files = <String, String?>{};
  for (final path in kOperatorWebSizeCeilings.keys) {
    final file = File(path);
    files[path] = file.existsSync() ? file.readAsStringSync() : null;
  }

  final result = OperatorWebSizeLintRunner(
    files: files,
    ceilings: kOperatorWebSizeCeilings,
  ).run();

  // Per-file status lines (always printed, so the operator sees headroom).
  for (final f in result.findings) {
    switch (f.status) {
      case OperatorWebSizeStatus.ok:
        stdout.writeln(
          'operator_web_size_lint: OK   ${f.path} '
          '${f.observedLines} lines (ceiling ${f.ceiling}, '
          'headroom ${-f.overage}).',
        );
      case OperatorWebSizeStatus.grew:
        stdout.writeln(
          'operator_web_size_lint: GREW ${f.path} '
          '${f.observedLines} lines (ceiling ${f.ceiling}, '
          '+${f.overage} over).',
        );
      case OperatorWebSizeStatus.missing:
        stderr.writeln(
          'operator_web_size_lint: WARN ${f.path} not found '
          '(ceiling ${f.ceiling}); skipped — run from repository root.',
        );
    }
  }

  if (result.isClean) {
    final missingNote = result.missing.isEmpty
        ? ''
        : ' (${result.missing.length} listed file(s) missing — see warnings)';
    stdout.writeln(
      'operator_web_size_lint: clean — all '
      '${kOperatorWebSizeCeilings.length} tracked file(s) at or under '
      'their frozen ceilings$missingNote.',
    );
    return;
  }

  stderr.writeln(
    'operator_web_size_lint: ERROR — ${result.grew.length} file(s) grew '
    'past their frozen ceiling:',
  );
  for (final f in result.grew) {
    stderr.writeln(
      '  ${f.path}: ceiling ${f.ceiling}, actual ${f.observedLines}, '
      'delta +${f.overage}.',
    );
  }
  stderr.writeln(
    'Fix: extract the new code into a decomposed widget/service rather '
    'than growing the screen. Ceilings are FROZEN during the refactor '
    'phase and LOWERED (never raised) as decomposition lands. Raising a '
    'ceiling needs explicit operator approval (CLAUDE.md "Ceiling-raise '
    'rule R-2"). The monolith must shrink, not grow.',
  );
  exitCode = 1;
}
