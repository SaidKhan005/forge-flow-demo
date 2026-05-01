// Tests for `tool/postgres_import_lint.dart`. Three groups:
//
//   1. Real on-disk tree — current repo passes.
//   2. Synthetic violation under a temp-dir-style relative path
//      → exit non-zero (non-empty violations list).
//   3. Imports under exempt directories pass.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/postgres_import_lint.dart';

void main() {
  group('postgres_import_lint', () {
    test('clean against the real on-disk tree (lib/ + tool/ + test/)', () {
      final files = _walkRepoDartFiles();
      expect(
        files.isNotEmpty,
        isTrue,
        reason: 'tests must run from repository root',
      );
      final result = PostgresImportLintRunner(files: files).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'real tree should pass; violations: ${result.violations}',
      );
      expect(result.scannedFileCount, greaterThan(0));
      expect(result.exemptFileCount, greaterThan(0));
    });

    test('fails on a synthetic import under lib/ outside the allowed dir',
        () {
      const violator = '''
import 'package:postgres/postgres.dart' as pg;

void main() {}
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          'lib/services/leaky_service.dart': violator,
        },
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(1));
      expect(
        result.violations.single.filePath,
        'lib/services/leaky_service.dart',
      );
      expect(result.violations.single.lineNumber, 1);
    });

    test('clean fixture under lib/ — no postgres imports — passes', () {
      const cleanBody = '''
import 'package:flutter/material.dart';

class Widgety {}
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          'lib/services/clean_service.dart': cleanBody,
        },
      ).run();
      expect(result.isClean, isTrue);
      expect(result.scannedFileCount, 1);
    });

    test('imports under lib/infrastructure/persistence/postgres/ are exempt',
        () {
      const adapterBody = '''
import 'package:postgres/postgres.dart' as pg;

class Adapter {}
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          'lib/infrastructure/persistence/postgres/adapter.dart':
              adapterBody,
        },
      ).run();
      expect(result.isClean, isTrue);
      expect(result.exemptFileCount, 1);
    });

    test('imports under test/ are exempt by default', () {
      const body = '''
import 'package:postgres/postgres.dart' as pg;
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          'test/repository_binding_test.dart': body,
        },
      ).run();
      expect(result.isClean, isTrue);
      expect(result.exemptFileCount, 1);
    });

    test('tool/ is NOT exempt by default — Cloud Run workers must use '
        'the PostgresExecutor seam', () {
      const body = '''
import 'package:postgres/postgres.dart' as pg;
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          'tool/some_worker/main.dart': body,
        },
      ).run();
      expect(result.isClean, isFalse);
      expect(result.violations.single.filePath, 'tool/some_worker/main.dart');
    });

    test('does not flag postgres mentions inside doc comments', () {
      const docOnly = '''
/// Matches `import 'package:postgres/postgres.dart' as pg;`.
import 'package:flutter/material.dart';
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          'lib/services/explainer.dart': docOnly,
        },
      ).run();
      expect(result.isClean, isTrue);
    });

    test('uses forward-slash normalization for Windows-style paths', () {
      const violator = '''
import 'package:postgres/postgres.dart';
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          r'lib\services\leaky_service.dart': violator,
        },
      ).run();
      expect(result.isClean, isFalse);
      expect(
        result.violations.single.filePath,
        'lib/services/leaky_service.dart',
      );
    });

    test('reports the correct line number for a mid-file import', () {
      const violator = '''
// Header comment.
//
// Some prose.
import 'package:flutter/material.dart';
import 'package:postgres/postgres.dart' as pg;
''';
      final result = PostgresImportLintRunner(
        files: <String, String>{
          'lib/screens/leaky_screen.dart': violator,
        },
      ).run();
      expect(result.violations, hasLength(1));
      expect(result.violations.single.lineNumber, 5);
    });
  });
}

/// Walks `lib/`, `tool/`, and `test/` for `*.dart` files exactly the
/// way the production CLI does, but returns the in-memory map instead
/// of running the lint. Tests use this to drive the runner against the
/// real tree without forking a process.
Map<String, String> _walkRepoDartFiles() {
  const roots = <String>['lib', 'tool', 'test'];
  final files = <String, String>{};
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/');
      files[rel] = entity.readAsStringSync().replaceAll('\r\n', '\n');
    }
  }
  return files;
}
