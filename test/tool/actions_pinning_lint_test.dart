// Tests for `tool/actions_pinning_lint.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/actions_pinning_lint.dart';

void main() {
  group('actions_pinning_lint', () {
    test('clean against the real .github/workflows tree', () {
      final files = <String, String>{};
      final dir = Directory('.github/workflows');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'tests must run from repository root',
      );
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        if (!lower.endsWith('.yml') && !lower.endsWith('.yaml')) continue;
        files[entity.path.replaceAll(r'\', '/')] = entity.readAsStringSync();
      }
      final result = ActionsPinningLintRunner(files: files).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'real tree should pass; violations: ${result.violations}',
      );
      expect(result.referenceCount, greaterThan(0));
    });

    test('flags floating-tag refs', () {
      const yaml = '''
jobs:
  ci:
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(2));
    });

    test('passes 40-char SHA refs', () {
      const yaml = '''
jobs:
  ci:
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - uses: subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2  # v2
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.referenceCount, 2);
    });

    test('flags floating-major-version refs like @v1.2', () {
      const yaml = '''
steps:
  - uses: actions/cache@v3.0.11
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations.single.reference, 'actions/cache@v3.0.11');
    });

    test('flags refs missing the @ separator entirely', () {
      const yaml = '''
steps:
  - uses: actions/checkout
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isFalse);
    });

    test('exempts local action refs (`./.github/actions/...`)', () {
      const yaml = '''
steps:
  - uses: ./.github/actions/setup
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.referenceCount, 0);
    });

    test('exempts docker:// refs', () {
      const yaml = '''
steps:
  - uses: docker://ghcr.io/example/image:tag
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
    });

    test('exempts allow-listed owners with floating-tag refs', () {
      const yaml = '''
steps:
  - uses: anthropic-internal/foo@v1
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
        allowList: const <String>{'anthropic-internal'},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.allowListedCount, 1);
    });

    test('strips surrounding quotes around the reference', () {
      const yaml = '''
steps:
  - uses: "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5"
''';
      final result = ActionsPinningLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
    });
  });
}
