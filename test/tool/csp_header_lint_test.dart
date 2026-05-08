// Tests for `tool/csp_header_lint.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/csp_header_lint.dart';

void main() {
  group('CspHeaderLintRunner — synthetic inputs', () {
    final runner = CspHeaderLintRunner();

    const goodCsp = '''
<!DOCTYPE html><html><head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="
    default-src 'self';
    script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com;
    style-src 'self' 'unsafe-inline';
    img-src 'self' data: blob: https:;
    font-src 'self' data:;
    connect-src 'self' https://*.googleapis.com;
    frame-src 'self' https://*.firebaseapp.com;
    object-src 'none';
    base-uri 'self';
    form-action 'self';
    upgrade-insecure-requests;
  ">
</head></html>''';

    test('passes a well-formed CSP block', () {
      final result = runner.check(goodCsp, label: 'good.html');
      expect(result.passed, isTrue, reason: 'failures: ${result.failures}');
    });

    test('fails when CSP meta tag is absent', () {
      const html = '<!DOCTYPE html><html><head><meta charset="UTF-8"></head></html>';
      final result = runner.check(html, label: 'no-csp.html');
      expect(result.passed, isFalse);
      expect(
        result.failures.any((f) => f.contains('missing')),
        isTrue,
      );
    });

    test("fails when default-src 'self' is absent", () {
      const html = '''
<meta http-equiv="Content-Security-Policy" content="
  default-src https://example.com;
  object-src 'none';
">''';
      final result = runner.check(html, label: 'bad-default-src.html');
      expect(result.passed, isFalse);
      expect(
        result.failures.any((f) => f.contains('default-src')),
        isTrue,
      );
    });

    test("fails when object-src 'none' is absent", () {
      const html = '''
<meta http-equiv="Content-Security-Policy" content="
  default-src 'self';
  object-src 'self';
">''';
      final result = runner.check(html, label: 'bad-object-src.html');
      expect(result.passed, isFalse);
      expect(
        result.failures.any((f) => f.contains('object-src')),
        isTrue,
      );
    });

    test("fails when script-src contains 'unsafe-inline'", () {
      const html = '''
<meta http-equiv="Content-Security-Policy" content="
  default-src 'self';
  script-src 'self' 'unsafe-inline';
  object-src 'none';
">''';
      final result = runner.check(html, label: 'bad-script-src.html');
      expect(result.passed, isFalse);
      expect(
        result.failures.any((f) => f.contains('script-src')),
        isTrue,
      );
    });

    test("'unsafe-inline' in style-src only does not trigger script-src check",
        () {
      const html = '''
<meta http-equiv="Content-Security-Policy" content="
  default-src 'self';
  script-src 'self' 'wasm-unsafe-eval';
  style-src 'self' 'unsafe-inline';
  object-src 'none';
">''';
      final result = runner.check(html, label: 'style-unsafe-ok.html');
      expect(result.passed, isTrue, reason: 'failures: ${result.failures}');
    });
  });

  group('CspHeaderLintRunner — real web entry-point files', () {
    final runner = CspHeaderLintRunner();

    const targets = [
      'web/index.html',
      'web/operator/index.html',
      'web/auth/action/index.html',
    ];

    for (final path in targets) {
      test('$path passes all CSP invariants', () {
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'tests must run from repository root; $path not found',
        );
        final content = file.readAsStringSync();
        final result = runner.check(content, label: path);
        expect(
          result.passed,
          isTrue,
          reason: 'CSP failures in $path: ${result.failures}',
        );
      });
    }

    test('operator web shell permits Flutter web font fetches', () {
      final content = File('web/operator/index.html').readAsStringSync();
      expect(
        content,
        contains('font-src \'self\' data: https://fonts.gstatic.com;'),
      );
      expect(
        content,
        contains('connect-src \'self\' https://fonts.gstatic.com'),
      );
    });
  });
}
