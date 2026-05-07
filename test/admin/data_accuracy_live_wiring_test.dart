// Regression coverage for Phase 8 spine-bridge .C live admin wiring.
//
// ops-debt.demo-fallback-hardening: the pre-fix shape was
// `final dataAccuracyGateway = gateway == null ? null : _resolve...`,
// which encoded the silent demo fallback (a missing
// `ADMIN_PROXY_BASE_URI` made `gateway` null and then chained nulls
// across the other 10 gateways). The new shape calls each resolver
// unconditionally — every resolver now hard-fails on missing/malformed
// URI in live mode, so a chained-null pattern is structurally
// incorrect.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('admin live entrypoint injects Data Accuracy HTTP gateway', () {
    final source = File('lib/main_admin.dart').readAsStringSync();

    expect(source, contains('HttpDataAccuracyAdminGateway'));
    expect(source, contains('_resolveDataAccuracyAdminGateway'));
    expect(source, contains('dataAccuracyAdminGateway: dataAccuracyGateway'));
    // The data-accuracy resolver is invoked unconditionally (not
    // chained off `gateway == null`).
    expect(
      source,
      matches(
        RegExp(
          r'final dataAccuracyGateway = _resolveDataAccuracyAdminGateway\(',
          multiLine: true,
        ),
      ),
    );
  });
}
