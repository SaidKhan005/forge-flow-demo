// Tests for `tool/ux_em_dash_lint.dart`.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/ux_em_dash_lint.dart';

void main() {
  group('findUxEmDashViolations', () {
    test('flags an em dash used as prose punctuation', () {
      const src = "const a = 'Volume is below plan — pull hours.';";
      final v = findUxEmDashViolations('a.dart', src);
      expect(v, hasLength(1));
      expect(v.single.literal, 'Volume is below plan — pull hours.');
      expect(v.single.lineNumber, 1);
    });

    test('flags an em dash used as a label/value separator', () {
      const src = "const a = 'Barrio Legado — North Loop';";
      expect(findUxEmDashViolations('a.dart', src), hasLength(1));
    });

    test('passes the colon-separated replacement', () {
      const src = "const a = 'Barrio Legado: North Loop';";
      expect(findUxEmDashViolations('a.dart', src), isEmpty);
    });

    test('exempts the standalone empty-state sentinel glyph', () {
      const src = '''
const a = '—';
const b = ' — ';
const c = '—  ';
''';
      expect(findUxEmDashViolations('a.dart', src), isEmpty);
    });

    test('skips line comments', () {
      const src = '// long names like "Barrio Legado — North Loop"\n'
          "const a = 'clean';";
      expect(findUxEmDashViolations('a.dart', src), isEmpty);
    });

    test('skips doc and nested block comments', () {
      const src = '''
/// Renders "Brand — Branch" /* inner — still comment */ pill.
/* outer — /* nested — */ still comment */
const a = 'clean';
''';
      expect(findUxEmDashViolations('a.dart', src), isEmpty);
    });

    test('scans raw strings too (the law ignores the r prefix)', () {
      const src = r"""
const a = r'raw copy — still flagged';
const b = 'normal copy — flagged';
""";
      final v = findUxEmDashViolations('a.dart', src);
      expect(v, hasLength(2));
      expect(v.map((e) => e.literal), everyElement(contains('—')));
    });

    test('handles interpolation braces containing quotes', () {
      const src =
          "var a = 'Editing \${m[\"k\"]} — \${n.name}'; var b = 'after';";
      final v = findUxEmDashViolations('a.dart', src);
      expect(v, hasLength(1));
      expect(v.single.literal, contains('Editing'));
    });

    test('flags an em dash inside a triple-quoted string', () {
      const src = '''
const a = """
multi line — copy
""";
''';
      expect(findUxEmDashViolations('a.dart', src), hasLength(1));
    });
  });

  group('UxEmDashLintRunner', () {
    test('aggregates violations across files and normalizes separators', () {
      final runner = UxEmDashLintRunner(files: {
        r'lib\screens\a.dart': "const a = 'A — B';",
        'lib/widgets/b.dart': "const b = 'clean';",
      });
      final result = runner.run();
      expect(result.scannedFileCount, 2);
      expect(result.isClean, isFalse);
      expect(result.violations.single.filePath, 'lib/screens/a.dart');
    });

    test('clean when no operator-facing string carries an em dash', () {
      final runner = UxEmDashLintRunner(files: {
        'lib/screens/a.dart': "const a = 'A: B'; const b = '—';",
      });
      expect(runner.run().isClean, isTrue);
    });
  });
}
