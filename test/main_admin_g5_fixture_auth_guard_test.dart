// G5 (cross-surface parity audit) — focused test for the real runtime,
// release-mode fail-closed guard added to `lib/main_admin.dart`.
//
// The guard's decision lives in the pure, `@visibleForTesting`
// `adminFixtureAuthBlockedInRelease(...)` so the full four-way matrix
// is testable without flipping `bool.fromEnvironment` compile-time
// constants:
//
//   * debug                                  -> never blocked
//   * release + share-preview, no opt-in     -> BLOCKED (fail closed)
//   * release + demo,          no opt-in     -> BLOCKED (fail closed)
//   * release + fixture + explicit opt-in    -> allowed
//   * release + normal live path             -> never blocked
//
// `main()` calls this exact function with the real constants, so a
// green matrix here proves the runtime behavior.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/main_admin.dart' as admin_entrypoint;

void main() {
  group('G5 adminFixtureAuthBlockedInRelease', () {
    test('debug build is never blocked, even with fixture flags', () {
      // Local dev / `flutter test` keep working untouched.
      expect(
        admin_entrypoint.adminFixtureAuthBlockedInRelease(
          isDebugMode: true,
          adminDemoAuth: true,
          adminSharePreview: true,
          adminAllowPublicFixtureAuth: false,
        ),
        isFalse,
      );
    });

    test(
      'release + share-preview WITHOUT explicit opt-in => fail closed',
      () {
        // The G5 gap: a share-preview build (including the dangerous
        // ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN full-write fixture) must
        // refuse to proceed on a public endpoint.
        expect(
          admin_entrypoint.adminFixtureAuthBlockedInRelease(
            isDebugMode: false,
            adminDemoAuth: false,
            adminSharePreview: true,
            adminAllowPublicFixtureAuth: false,
          ),
          isTrue,
        );
      },
    );

    test('release + demo-auth WITHOUT explicit opt-in => fail closed', () {
      expect(
        admin_entrypoint.adminFixtureAuthBlockedInRelease(
          isDebugMode: false,
          adminDemoAuth: true,
          adminSharePreview: false,
          adminAllowPublicFixtureAuth: false,
        ),
        isTrue,
      );
    });

    test(
      'release + fixture WITH explicit ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH '
      '=> allowed',
      () {
        // Intentional internal preview keeps working via the explicit,
        // unmistakable opt-in.
        expect(
          admin_entrypoint.adminFixtureAuthBlockedInRelease(
            isDebugMode: false,
            adminDemoAuth: false,
            adminSharePreview: true,
            adminAllowPublicFixtureAuth: true,
          ),
          isFalse,
        );
        expect(
          admin_entrypoint.adminFixtureAuthBlockedInRelease(
            isDebugMode: false,
            adminDemoAuth: true,
            adminSharePreview: false,
            adminAllowPublicFixtureAuth: true,
          ),
          isFalse,
        );
      },
    );

    test('release + normal live path (no fixture flags) => unaffected', () {
      // The default production build: no fixture flags at all. The
      // guard must NOT interfere with live Firebase auth, opt-in or not.
      expect(
        admin_entrypoint.adminFixtureAuthBlockedInRelease(
          isDebugMode: false,
          adminDemoAuth: false,
          adminSharePreview: false,
          adminAllowPublicFixtureAuth: false,
        ),
        isFalse,
      );
      expect(
        admin_entrypoint.adminFixtureAuthBlockedInRelease(
          isDebugMode: false,
          adminDemoAuth: false,
          adminSharePreview: false,
          adminAllowPublicFixtureAuth: true,
        ),
        isFalse,
      );
    });

    test('blocked-surface message names the opt-in and the danger', () {
      // The calm fail-closed surface must tell the operator exactly
      // which flag to pass for an intentional preview.
      expect(
        admin_entrypoint.kAdminFixtureAuthBlockedMessage,
        contains('ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH'),
      );
      expect(
        admin_entrypoint.kAdminFixtureAuthBlockedMessage,
        contains('must never ship on a public endpoint'),
      );
    });
  });
}
