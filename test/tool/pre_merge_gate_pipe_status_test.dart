import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pre_merge_gate preserves analyze and test exit status through tee', () {
    final script = File('tool/pre_merge_gate.sh').readAsStringSync();

    expect(script, contains(r'ANALYZE_STATUS=${PIPESTATUS[0]}'));
    expect(script, contains(r'TEST_STATUS=${PIPESTATUS[0]}'));
    expect(script, contains(r'if [ "$ANALYZE_STATUS" -ne 0 ]'));
    expect(script, contains(r'if [ "$TEST_STATUS" -eq 0 ]'));
    expect(
      script,
      isNot(
        contains(
          r'if flutter test "${TESTS[@]}" --reporter expanded 2>&1 | tee',
        ),
      ),
    );
  });
}
