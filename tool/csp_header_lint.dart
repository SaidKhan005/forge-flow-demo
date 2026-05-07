// Security lint — Content-Security-Policy headers in Flutter Web entry points.
//
// Verifies that every HTML file under `web/` that ships as a browser
// entry point carries a well-formed CSP meta tag. Three invariants are
// checked per file:
//
//   1. A `<meta http-equiv="Content-Security-Policy"` tag is present.
//   2. `default-src 'self'` appears in the policy content.
//   3. `object-src 'none'` appears in the policy content.
//   4. `'unsafe-inline'` does NOT appear inside `script-src` (it is
//      acceptable only inside `style-src`).
//
// Run manually:
//
//   dart tool/csp_header_lint.dart
//
// Exit codes:
//   0 — all checks pass.
//   1 — one or more checks failed (details printed to stdout).

import 'dart:io';

// ignore_for_file: avoid_print — this is a CLI lint tool, not production code.

// ---------------------------------------------------------------------------
// Target files (relative to repo root, resolved at runtime).
// ---------------------------------------------------------------------------

const _targets = [
  'web/index.html',
  'web/operator/index.html',
  'web/auth/action/index.html',
];

// ---------------------------------------------------------------------------
// Runner (also callable from tests via CspHeaderLintRunner).
// ---------------------------------------------------------------------------

class CspHeaderLintResult {
  const CspHeaderLintResult({required this.failures});

  /// Each entry is a human-readable failure string.
  final List<String> failures;

  bool get passed => failures.isEmpty;
}

class CspHeaderLintRunner {
  /// Checks [htmlContent] (the full text of an HTML file) against the CSP
  /// invariants and returns a result describing any failures. [label] is used
  /// only in failure messages.
  CspHeaderLintResult check(String htmlContent, {required String label}) {
    final failures = <String>[];

    // 1. CSP meta tag present.
    if (!htmlContent.contains(
      '<meta http-equiv="Content-Security-Policy"',
    )) {
      failures.add('$label: missing <meta http-equiv="Content-Security-Policy"> tag');
      // Without the tag the remaining checks cannot run meaningfully.
      return CspHeaderLintResult(failures: failures);
    }

    // Extract the content="..." value from the CSP meta tag.
    // We look for the first occurrence of http-equiv="Content-Security-Policy"
    // then grab the nearest content="..." attribute value.
    final cspContent = _extractCspContent(htmlContent);
    if (cspContent == null) {
      failures.add('$label: CSP meta tag found but could not extract content="..." value');
      return CspHeaderLintResult(failures: failures);
    }

    // 2. default-src 'self'
    if (!cspContent.contains("default-src 'self'")) {
      failures.add("$label: CSP policy does not contain default-src 'self'");
    }

    // 3. object-src 'none'
    if (!cspContent.contains("object-src 'none'")) {
      failures.add("$label: CSP policy does not contain object-src 'none'");
    }

    // 4. 'unsafe-inline' must not appear in script-src.
    //    It may appear in style-src. We extract the script-src directive and
    //    check only that portion.
    final scriptSrcViolation = _unsafeInlineInScriptSrc(cspContent);
    if (scriptSrcViolation) {
      failures.add(
        "$label: CSP script-src contains 'unsafe-inline' — "
        "Flutter Web does not require it and it weakens XSS protection",
      );
    }

    return CspHeaderLintResult(failures: failures);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Extracts the value of the `content` attribute from the first CSP meta
  /// tag in [html]. Returns null if none can be extracted.
  String? _extractCspContent(String html) {
    // Find the CSP meta tag start.
    final tagStart = html.indexOf('<meta http-equiv="Content-Security-Policy"');
    if (tagStart == -1) return null;

    // Find the closing `>` of that tag.
    final tagEnd = html.indexOf('>', tagStart);
    if (tagEnd == -1) return null;

    final tagText = html.substring(tagStart, tagEnd + 1);

    // Extract content="..."
    final contentMatch =
        RegExp(r'content="([^"]*)"', dotAll: true).firstMatch(tagText);
    return contentMatch?.group(1);
  }

  /// Returns true if `'unsafe-inline'` appears inside the `script-src`
  /// directive of [policy].
  bool _unsafeInlineInScriptSrc(String policy) {
    // Directives are separated by `;`.
    final directives = policy.split(';');
    for (final directive in directives) {
      final trimmed = directive.trim();
      if (trimmed.startsWith('script-src')) {
        if (trimmed.contains("'unsafe-inline'")) {
          return true;
        }
      }
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// CLI entrypoint
// ---------------------------------------------------------------------------

void main(List<String> args) {
  // Resolve paths relative to the script's location (repo_root/tool/).
  final scriptDir = File(Platform.script.toFilePath()).parent;
  final repoRoot = scriptDir.parent;

  final runner = CspHeaderLintRunner();
  final allFailures = <String>[];

  for (final relativePath in _targets) {
    final file = File('${repoRoot.path}/$relativePath');
    if (!file.existsSync()) {
      allFailures.add('$relativePath: file not found at ${file.path}');
      continue;
    }
    final content = file.readAsStringSync();
    final result = runner.check(content, label: relativePath);
    allFailures.addAll(result.failures);
  }

  if (allFailures.isEmpty) {
    print('csp_header_lint: all ${_targets.length} files passed.');
    exit(0);
  } else {
    print('csp_header_lint: ${allFailures.length} failure(s):');
    for (final f in allFailures) {
      print('  FAIL  $f');
    }
    exit(1);
  }
}
