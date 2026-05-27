// Focused test for the Operator Web release demo-auth guard.
//
// The production entrypoint must use real runtime code, not only `assert`,
// because release artifacts strip assertions. But the guard must also let
// `--profile` builds through, because the operator-web QA runbook builds
// with `--profile` to bypass the DDC debug client — that local-QA build is
// never the deploy artifact. See
// `docs/_audits/operator_web_demo_boot_2026_05_27.md` for the
// (debug-only-aware) regression that motivated extending the predicate.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/main_operator_web.dart' as operator_web;

void main() {
  group('operatorWebDemoAuthBlockedInRelease', () {
    test('debug build is never blocked', () {
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: true,
          isProfileMode: false,
          operatorWebDemoAuth: true,
        ),
        isFalse,
      );
    });

    test('profile build is never blocked (runbook QA build)', () {
      // Regression guard for the 2026-05-27 operator-web demo boot
      // breakage: a `--profile` build is what the QA runbook uses to
      // bypass the DDC debug client (see
      // `runbooks/operator_web_qa_runbook.md` lines 12-14). It is a
      // local-only QA build, never the Cloud Run deploy artifact, so it
      // must boot into the demo console rather than the init-failed
      // screen. Triage: `docs/_audits/operator_web_demo_boot_2026_05_27.md`.
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: false,
          isProfileMode: true,
          operatorWebDemoAuth: true,
        ),
        isFalse,
      );
    });

    test('release demo-auth build fails closed', () {
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: false,
          isProfileMode: false,
          operatorWebDemoAuth: true,
        ),
        isTrue,
      );
    });

    test('release live build is unaffected', () {
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: false,
          isProfileMode: false,
          operatorWebDemoAuth: false,
        ),
        isFalse,
      );
    });

    test('profile live build is unaffected', () {
      expect(
        operator_web.operatorWebDemoAuthBlockedInRelease(
          isDebugMode: false,
          isProfileMode: true,
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
