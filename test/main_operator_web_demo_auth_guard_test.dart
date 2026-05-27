// Focused test for the Operator Web release/profile demo-auth guard.
//
// The production entrypoint must use real runtime code, not only `assert`,
// because release artifacts strip assertions.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/main_operator_web.dart' as operator_web;

void main() {
  group('operatorWebDemoAuthBlockedInRelease', () {
    test('debug build is never blocked', () {
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: true,
          operatorWebDemoAuth: true,
        ),
        isFalse,
      );
    });

    test('release demo-auth build fails closed', () {
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: false,
          operatorWebDemoAuth: true,
        ),
        isTrue,
      );
    });

    test('release live build is unaffected', () {
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: false,
          operatorWebDemoAuth: false,
        ),
        isFalse,
      );
    });

    test('blocked message names the flag and public-endpoint danger', () {
      expect(
        operator_web.kOperatorWebDemoAuthBlockedMessage,
        contains('OPERATOR_WEB_DEMO_AUTH'),
      );
      expect(
        operator_web.kOperatorWebDemoAuthBlockedMessage,
        contains('must never ship on a public endpoint'),
      );
    });
  });
}
