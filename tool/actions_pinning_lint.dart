// HARD-E — GitHub Actions pinning lint.
//
// Public actions (`actions/checkout`, `subosito/flutter-action`,
// `docker/build-push-action`, etc.) MUST be referenced by commit
// SHA, not by floating tag. A tag like `@v4` can be moved by the
// upstream maintainer at any time; a SHA is content-addressable and
// immutable. Floating-tag refs to external orgs are a SLSA-3
// violation and the prerequisite for several supply-chain
// compromises (tj-actions/changed-files 2025, etc.).
//
// Rule: every `uses: <owner>/<repo>(/<sub>)?@<ref>` reference must
// satisfy ONE of:
//   * `<ref>` is a 40-char hex SHA (commit pin), OR
//   * the `owner` is on `_internalAllowList` and the `<ref>` is a
//     tag (internal/Anthropic-owned actions may stay on tags).
//
// Exposed surface:
//   * `ActionsPinningLintRunner` — testable façade. Construct with
//     `{filePath: yamlBody}` and call `run()` for a result.
//   * `main(List<String>)` — CLI entrypoint. Walks
//     `.github/workflows/*.yml` and exits 1 on any violation.

import 'dart:io';

/// Owners whose actions are exempt from SHA pinning. Internal /
/// Anthropic-owned actions may stay on tags because the trust
/// boundary is the same as the workflow itself.
const Set<String> _internalAllowList = <String>{
  // Reserved. Add only with explicit review — keep this list short
  // and obvious. Format: lowercase GitHub org/user name.
};

/// Owners whose actions live in this repo (relative refs like
/// `./.github/actions/foo` are not subject to the SHA-pinning rule;
/// they are governed by the repo's own commit history).
const Set<String> _localPathPrefixes = <String>{'.', './'};

/// One unpinned action reference.
class ActionsPinningViolation {
  const ActionsPinningViolation({
    required this.filePath,
    required this.lineNumber,
    required this.reference,
  });

  final String filePath;
  final int lineNumber;

  /// The full `<owner>/<repo>(/<sub>)?@<ref>` text that triggered
  /// the violation.
  final String reference;

  @override
  String toString() {
    return '$filePath:$lineNumber: $reference (use a 40-char commit '
        'SHA, e.g. `<owner>/<repo>@<sha>  # <tag>`)';
  }
}

class ActionsPinningLintResult {
  const ActionsPinningLintResult({
    required this.violations,
    required this.scannedFileCount,
    required this.referenceCount,
    required this.allowListedCount,
  });

  final List<ActionsPinningViolation> violations;
  final int scannedFileCount;
  final int referenceCount;
  final int allowListedCount;

  bool get isClean => violations.isEmpty;
}

class ActionsPinningLintRunner {
  ActionsPinningLintRunner({
    required this.files,
    Set<String>? allowList,
  }) : allowList = allowList ?? _internalAllowList;

  final Map<String, String> files;
  final Set<String> allowList;

  ActionsPinningLintResult run() {
    final violations = <ActionsPinningViolation>[];
    var refs = 0;
    var allowed = 0;
    for (final entry in files.entries) {
      final path = entry.key.replaceAll(r'\', '/');
      final lines = entry.value.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final match = _usesPattern.firstMatch(lines[i]);
        if (match == null) continue;
        final ref = match.group(1)!;
        // Skip Docker references (`uses: docker://...`) — those are
        // pulled at runtime and pinned via the image tag/digest in
        // the URI itself, not via SHA.
        if (ref.startsWith('docker://')) continue;
        // Skip local actions (`uses: ./.github/actions/foo`) —
        // governed by the repo's own commit history.
        if (_localPathPrefixes.any(ref.startsWith)) continue;
        refs++;
        final atIndex = ref.lastIndexOf('@');
        if (atIndex < 0) {
          violations.add(ActionsPinningViolation(
            filePath: path,
            lineNumber: i + 1,
            reference: ref,
          ));
          continue;
        }
        final owner = ref.substring(0, atIndex).split('/').first.toLowerCase();
        final atRef = ref.substring(atIndex + 1);
        final isSha = _shaPattern.hasMatch(atRef);
        if (isSha) continue;
        if (allowList.contains(owner)) {
          allowed++;
          continue;
        }
        violations.add(ActionsPinningViolation(
          filePath: path,
          lineNumber: i + 1,
          reference: ref,
        ));
      }
    }
    return ActionsPinningLintResult(
      violations: violations,
      scannedFileCount: files.length,
      referenceCount: refs,
      allowListedCount: allowed,
    );
  }
}

/// Captures `uses: <ref>` (single or double-quoted optional). The
/// captured group is the bare reference, with surrounding quotes
/// stripped.
final RegExp _usesPattern = RegExp(
  r'''^\s*-?\s*uses:\s*['"]?([^'"\s#]+)['"]?''',
);

/// 40-char hex SHA.
final RegExp _shaPattern = RegExp(r'^[a-fA-F0-9]{40}$');

Future<void> main(List<String> args) async {
  const root = '.github/workflows';
  final dir = Directory(root);
  if (!dir.existsSync()) {
    stderr.writeln(
      'actions_pinning_lint: $root not found '
      '(run from repository root).',
    );
    exitCode = 2;
    return;
  }

  final files = <String, String>{};
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) continue;
    final lower = entity.path.toLowerCase();
    if (!lower.endsWith('.yml') && !lower.endsWith('.yaml')) continue;
    files[entity.path.replaceAll(r'\', '/')] = entity.readAsStringSync();
  }

  final runner = ActionsPinningLintRunner(files: files);
  final result = runner.run();

  stdout.writeln(
    'actions_pinning_lint: scanned ${result.scannedFileCount} '
    'workflow file(s); ${result.referenceCount} third-party action '
    'reference(s); ${result.allowListedCount} allow-listed.',
  );
  if (result.isClean) {
    stdout.writeln(
      'actions_pinning_lint: clean — every public action is pinned '
      'to a commit SHA.',
    );
    return;
  }
  stderr.writeln(
    'actions_pinning_lint: '
    '${result.violations.length} unpinned reference(s):',
  );
  for (final v in result.violations) {
    stderr.writeln('  - $v');
  }
  stderr.writeln(
    'Fix: replace each floating-tag reference with a 40-char commit '
    'SHA. Look up the SHA with:\n'
    '  gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq \'.object.sha\'',
  );
  exitCode = 1;
}
