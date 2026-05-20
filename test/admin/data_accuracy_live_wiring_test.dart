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

  test('admin proxy row JSON carries Data Accuracy provenance labels', () {
    final source = File(
      'tool/advisor_proxy/proxy_bootstrap.dart',
    ).readAsStringSync();

    expect(
      's.covers_source_per_service_period_source'.allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
    expect(source, contains('s.wage_source_source'));
    expect(source, contains('s.walk_in_handling_mode_source'));
    expect(
      source,
      contains("'covers_source_per_service_period_source': _jsonMap("),
    );
    expect(source, contains("'covers_source_source':"));
    expect(source, contains("'wage_source_source': _jsonMap("));
    expect(source, contains("'walk_in_handling_mode_source': _jsonMap("));
  });
}
