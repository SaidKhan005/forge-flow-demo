// Web-safety guard.
//
// On the web (dart2js / DDC), JavaScript bitwise operators are 32-bit,
// so `1 << 32` overflows to 0. `Random.nextInt(1 << 32)` therefore
// throws `RangeError: max must be in range 0 < max <= 2^32, was 0` in
// the browser, while the Dart VM (tests) treats `1 << 32` as a valid
// 2^32 and never reproduces it. This bit the admin My account
// "Set up authenticator" / password / recovery / sessions / identity
// idempotency-key mints (web crash), so this guard keeps the web
// consoles (admin + operator-web) free of the 32-bit-overflowing shift.
//
// Fix pattern: use a web-safe bound such as `nextInt(0x7fffffff)`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web console code uses no 32-bit-overflowing left shift (1 << 32)', () {
    const roots = <String>['lib/admin', 'lib/operator_web'];
    final offenders = <String>[];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.contains('1 << 32') || line.contains('1<<32')) {
            offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'On the web, `1 << 32` overflows to 0 (JS bitwise is 32-bit), so '
          'Random.nextInt(1 << 32) throws RangeError. Use a web-safe bound '
          'such as nextInt(0x7fffffff). Offenders:\n${offenders.join('\n')}',
    );
  });
}
