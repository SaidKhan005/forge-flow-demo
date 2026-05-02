// Tests for `tool/release_dart_defines_lint.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_dart_defines_lint.dart';

void main() {
  group('release_dart_defines_lint', () {
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
      final result = ReleaseDartDefinesLintRunner(files: files).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'real tree should pass; violations: ${result.violations}',
      );
    });

    test('flags release `flutter build ipa` missing the dart-define', () {
      const yaml = '''
jobs:
  release:
    steps:
      - name: build
        run: flutter build ipa --flavor ForgeFlow -t lib/main_forgeflow.dart
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/release.yml': yaml},
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(1));
      expect(result.releaseBuildCount, 1);
      expect(
        result.violations.single.filePath,
        '.github/workflows/release.yml',
      );
    });

    test('passes release `flutter build ipa` that includes the dart-define',
        () {
      const yaml = '''
jobs:
  release:
    steps:
      - name: build
        run: flutter build ipa --flavor ForgeFlow --dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/release.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.releaseBuildCount, 1);
    });

    test('exempts `--debug --simulator` (debug build)', () {
      const yaml = '''
jobs:
  ci:
    steps:
      - name: build
        run: flutter build ios --simulator --debug --flavor ForgeFlow
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.releaseBuildCount, 0);
    });

    test('exempts `--profile` builds', () {
      const yaml = '''
jobs:
  perf:
    steps:
      - name: build
        run: flutter build ios --profile --flavor ForgeFlow
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/ci.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.releaseBuildCount, 0);
    });

    test('handles multi-line YAML folded scalars', () {
      const yaml = '''
jobs:
  release:
    steps:
      - name: build
        run: >
          flutter build ipa
          --flavor ForgeFlow
          -t lib/main_forgeflow.dart
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/release.yml': yaml},
      ).run();
      expect(result.isClean, isFalse, reason: 'missing dart-define');
      expect(result.releaseBuildCount, 1);
    });

    test('handles shell `\\` line continuations', () {
      const yaml = r'''
jobs:
  release:
    steps:
      - name: build
        run: |
          flutter build ipa --flavor ForgeFlow \
            --dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true \
            -t lib/main_forgeflow.dart
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/release.yml': yaml},
      ).run();
      expect(result.isClean, isTrue);
      expect(result.releaseBuildCount, 1);
    });

    test('treats `flutter build apk` as release by default', () {
      const yaml = '''
jobs:
  android:
    steps:
      - name: build
        run: flutter build apk --flavor barrio
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/android.yml': yaml},
      ).run();
      expect(result.isClean, isFalse);
      expect(result.releaseBuildCount, 1);
    });

    test('flags multiple release builds in one workflow', () {
      const yaml = '''
jobs:
  release:
    steps:
      - run: flutter build ipa --flavor ForgeFlow
      - run: flutter build apk --flavor barrio
''';
      final result = ReleaseDartDefinesLintRunner(
        files: <String, String>{'.github/workflows/release.yml': yaml},
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(2));
      expect(result.releaseBuildCount, 2);
    });
  });
}
