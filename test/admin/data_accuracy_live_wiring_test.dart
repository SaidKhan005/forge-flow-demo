// Regression coverage for Phase 8 spine-bridge .C live admin wiring.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('admin live entrypoint injects Data Accuracy HTTP gateway', () {
    final source = File('lib/main_admin.dart').readAsStringSync();

    expect(source, contains('HttpDataAccuracyAdminGateway'));
    expect(source, contains('_resolveDataAccuracyAdminGateway'));
    expect(source, contains('dataAccuracyAdminGateway: dataAccuracyGateway'));
    expect(
      source,
      matches(
        RegExp(
          r'final dataAccuracyGateway = gateway == null\s*\?\s*null\s*:\s*_resolveDataAccuracyAdminGateway',
          multiLine: true,
        ),
      ),
    );
  });
}
