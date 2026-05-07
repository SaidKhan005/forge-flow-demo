// B1.A5 — Release-build demo-auth flag lint tests.
//
// Verifies that the lint runner correctly identifies workflow steps that
// pass ADMIN_DEMO_AUTH=true or OPERATOR_WEB_DEMO_AUTH=true in release builds,
// and that it does not flag debug or profile builds.

import 'package:flutter_test/flutter_test.dart';

// The lint runner is in the tool directory. Import it via a relative
// path; the test runner is invoked from the repository root.
import '../../../tool/release_build_demo_flag_lint.dart';

void main() {
  group('ReleaseBuildDemoFlagLintRunner', () {
    ReleaseBuildDemoFlagLintResult runWith(String yamlBody) {
      return ReleaseBuildDemoFlagLintRunner(
        files: <String, String>{'test.yml': yamlBody},
      ).run();
    }

    test('clean when no flutter build commands', () {
      final result = runWith('run: echo hello\n');
      expect(result.isClean, isTrue);
      expect(result.violations, isEmpty);
    });

    test('flags ADMIN_DEMO_AUTH=true in a release build', () {
      const yaml = '''
      - name: Build admin console
        run: flutter build web --dart-define=ADMIN_DEMO_AUTH=true
''';
      final result = runWith(yaml);
      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(1));
      expect(result.violations.first.flag, contains('ADMIN_DEMO_AUTH'));
    });

    test('flags OPERATOR_WEB_DEMO_AUTH=true in a release build', () {
      const yaml = '''
      - name: Build operator web
        run: flutter build web --dart-define=OPERATOR_WEB_DEMO_AUTH=true
''';
      final result = runWith(yaml);
      expect(result.isClean, isFalse);
      expect(result.violations.first.flag, contains('OPERATOR_WEB_DEMO_AUTH'));
    });

    test('does NOT flag --debug builds with demo flag', () {
      const yaml = '''
      - name: Dev build
        run: flutter build web --debug --dart-define=ADMIN_DEMO_AUTH=true
''';
      final result = runWith(yaml);
      expect(result.isClean, isTrue);
    });

    test('does NOT flag --profile builds with demo flag', () {
      const yaml = '''
      - name: Profile build
        run: flutter build web --profile --dart-define=OPERATOR_WEB_DEMO_AUTH=true
''';
      final result = runWith(yaml);
      expect(result.isClean, isTrue);
    });

    test('does NOT flag release builds without demo flags', () {
      const yaml = '''
      - name: Release build
        run: flutter build web --dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true
''';
      final result = runWith(yaml);
      expect(result.isClean, isTrue);
    });

    test('scanned file count and release build count are correct', () {
      const yaml = '''
      - run: flutter build web --dart-define=ADMIN_DEMO_AUTH=true
      - run: flutter build web --debug --dart-define=ADMIN_DEMO_AUTH=true
      - run: echo skipped
''';
      final result = runWith(yaml);
      // One release build step (the second is debug).
      expect(result.releaseBuildCount, equals(1));
      expect(result.violations, hasLength(1));
    });

    test('handles multi-file inputs and counts all violations', () {
      const yaml1 = '''
      - run: flutter build web --dart-define=ADMIN_DEMO_AUTH=true
''';
      const yaml2 = '''
      - run: flutter build web --dart-define=OPERATOR_WEB_DEMO_AUTH=true
''';
      final result = ReleaseBuildDemoFlagLintRunner(
        files: <String, String>{
          'workflow1.yml': yaml1,
          'workflow2.yml': yaml2,
        },
      ).run();
      expect(result.violations, hasLength(2));
      expect(result.scannedFileCount, equals(2));
    });
  });
}
