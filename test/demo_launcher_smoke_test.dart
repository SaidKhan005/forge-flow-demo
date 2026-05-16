// Smoke tests that guard the demo launcher contracts.
//
// Catches the three categories of silent regression that surfaced while
// re-running every README demo command end-to-end (PRs #809, #818):
//
//   1. A future Dart rename of a demo-flag constant
//      (`kDemoMode`, `FORGE_FLOW_DEMO_MODE`, `OPERATOR_WEB_DEMO_AUTH`,
//      `ADMIN_SHARE_PREVIEW`, `ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN`,
//      `ADMIN_DEMO_AUTH`) without updating the launcher script that
//      passes it via `--dart-define`. The script emits the old name,
//      Dart silently reads the default (false), demo bypass disappears.
//
//   2. A future gateway-resolver function added to `lib/main_admin.dart`
//      that bypasses for `_kAdminDemoAuth` but NOT `_kAdminSharePreview`
//      — the same bug PR #818 fixed across 15 sites. A 16th regression
//      would crash share-preview demos with `Bad state: live admin auth
//      client is required outside demo mode`.
//
//   3. A future `web/index.html` restructure that breaks the dev-CSP
//      swap regex in `scripts/_dev_csp_swap.ps1`. The swap would fail
//      closed; Flutter Web's DDC dev compiler would hit a CSP violation;
//      operator would be stuck on splash.
//
// These tests read source files as text — no PowerShell, no `flutter
// run`, no platform dependency. Runs on any host `flutter test` runs on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Demo launcher dart-defines stay aligned with Dart-side flag names', () {
    test(
      'run_flutter_dev.ps1 demo emits kDemoMode + FORGE_FLOW_DEMO_MODE; '
      'main_forgeflow + login_screen still read both',
      () {
        final script = _read('scripts/run_flutter_dev.ps1');
        expect(
          script,
          contains("--dart-define=kDemoMode=true"),
          reason:
              'Mobile demo launcher must emit kDemoMode=true. If you rename '
              'the flag, update both lib/main_forgeflow.dart (and login_screen) '
              'AND this script.',
        );
        expect(
          script,
          contains("--dart-define=FORGE_FLOW_DEMO_MODE=true"),
          reason:
              'Mobile demo launcher must also emit FORGE_FLOW_DEMO_MODE=true '
              '(login_screen.dart reads both names).',
        );

        final loginScreen = _read('lib/screens/auth/login_screen.dart');
        expect(
          loginScreen,
          contains("bool.fromEnvironment('kDemoMode')"),
          reason:
              'lib/screens/auth/login_screen.dart no longer reads '
              'kDemoMode. Update the launcher to pass the new flag name '
              'or restore the reader.',
        );
        expect(
          loginScreen,
          contains("bool.fromEnvironment('FORGE_FLOW_DEMO_MODE')"),
          reason:
              'lib/screens/auth/login_screen.dart no longer reads '
              'FORGE_FLOW_DEMO_MODE. Both names should be honored so '
              'demo lands on the additive "Use demo operator" button.',
        );
      },
    );

    test(
      'run_operator_web_dev.ps1 demo emits OPERATOR_WEB_DEMO_AUTH + scenario; '
      'main_operator_web still reads both',
      () {
        final script = _read('scripts/run_operator_web_dev.ps1');
        expect(
          script,
          contains("--dart-define=OPERATOR_WEB_DEMO_AUTH=true"),
          reason:
              'Operator-web demo launcher must emit '
              'OPERATOR_WEB_DEMO_AUTH=true.',
        );
        expect(
          script,
          contains("--dart-define=OPERATOR_WEB_DEMO_SCENARIO="),
          reason:
              'Operator-web demo launcher must emit '
              'OPERATOR_WEB_DEMO_SCENARIO so the demo lands on the '
              'configured scenario (default owner-location-completed = '
              'signed in, post-onboarding).',
        );

        final mainOperatorWeb = _read('lib/main_operator_web.dart');
        // Use regex with `\s*` so newline style (LF vs CRLF) and any
        // formatter-driven whitespace changes don't trip the test.
        expect(
          mainOperatorWeb,
          matches(RegExp(r"bool\.fromEnvironment\(\s*'OPERATOR_WEB_DEMO_AUTH'")),
          reason:
              'lib/main_operator_web.dart no longer reads '
              'OPERATOR_WEB_DEMO_AUTH. Update the launcher or restore '
              'the reader.',
        );
        expect(
          mainOperatorWeb,
          matches(RegExp(r"String\.fromEnvironment\(\s*'OPERATOR_WEB_DEMO_SCENARIO'")),
          reason:
              'lib/main_operator_web.dart no longer reads '
              'OPERATOR_WEB_DEMO_SCENARIO.',
        );
      },
    );

    test(
      'run_admin_console_dev.ps1 demo emits ADMIN_SHARE_PREVIEW + '
      'ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN; main_admin reads both',
      () {
        final script = _read('scripts/run_admin_console_dev.ps1');
        expect(
          script,
          contains("--dart-define=ADMIN_SHARE_PREVIEW=true"),
          reason:
              'Admin demo launcher must emit ADMIN_SHARE_PREVIEW=true '
              '(default = no-login path).',
        );
        expect(
          script,
          contains("--dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true"),
          reason:
              'Admin demo launcher must also emit '
              'ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true so the local '
              'walkthrough lands as super-admin (full write), not '
              'read-only support. Read-only support is preserved for '
              'the share-preview deploy by NOT passing this flag.',
        );
        expect(
          script,
          contains("--dart-define=ADMIN_DEMO_AUTH=true"),
          reason:
              'Admin demo launcher must support the -DemoFixtureLogin '
              'opt-in by emitting ADMIN_DEMO_AUTH=true. Removing this '
              'breaks the fixture-login picker walkthrough.',
        );

        final mainAdmin = _read('lib/main_admin.dart');
        expect(
          mainAdmin,
          matches(RegExp(r"bool\.fromEnvironment\(\s*'ADMIN_SHARE_PREVIEW'\s*\)")),
          reason:
              'lib/main_admin.dart no longer reads ADMIN_SHARE_PREVIEW.',
        );
        expect(
          mainAdmin,
          matches(RegExp(r"bool\.fromEnvironment\(\s*'ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN'")),
          reason:
              'lib/main_admin.dart no longer reads '
              'ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN. The role-toggle '
              'introduced in PR #818 would silently regress demo to '
              'read-only F&F support.',
        );
        expect(
          mainAdmin,
          matches(RegExp(r"bool\.fromEnvironment\(\s*'ADMIN_DEMO_AUTH'\s*\)")),
          reason:
              'lib/main_admin.dart no longer reads ADMIN_DEMO_AUTH '
              '(the fixture-login picker source).',
        );
      },
    );
  });

  group('Admin gateway resolvers honor share-preview', () {
    test(
      'every `if (_kAdminDemoAuth) return null;` site in lib/main_admin.dart '
      'has the `|| _kAdminSharePreview` bypass',
      () {
        final mainAdmin = _read('lib/main_admin.dart');

        // A regression would re-introduce the bare check.
        final bareMatches = RegExp(
          r'if\s*\(\s*_kAdminDemoAuth\s*\)\s*return\s+null\s*;',
        ).allMatches(mainAdmin).length;
        expect(
          bareMatches,
          0,
          reason:
              'A gateway resolver helper in lib/main_admin.dart bypasses '
              'only for _kAdminDemoAuth without also honoring '
              '_kAdminSharePreview. Share-preview demos will throw '
              '`Bad state: live admin auth client is required outside '
              'demo mode`. Replace each bare check with: '
              '`if (_kAdminDemoAuth || _kAdminSharePreview) return null;` '
              '(PR #818 fixed 15 such sites).',
        );

        // Make sure we still have the dual-check pattern (so the file
        // didn't drop the bypass entirely).
        final dualMatches = RegExp(
          r'if\s*\(\s*_kAdminDemoAuth\s*\|\|\s*_kAdminSharePreview\s*\)\s*return\s+null\s*;',
        ).allMatches(mainAdmin).length;
        expect(
          dualMatches,
          greaterThanOrEqualTo(15),
          reason:
              'Expected at least 15 gateway resolver helpers to bypass '
              'for `_kAdminDemoAuth || _kAdminSharePreview` (the count '
              'when PR #818 landed). If a resolver was removed, lower '
              'this guard; if more were added without the bypass, fix '
              'them.',
        );
      },
    );
  });

  group('Shared dev-CSP swap helper stays compatible with web/index.html', () {
    test(
      "the regex in scripts/_dev_csp_swap.ps1 still matches the CSP <meta> "
      'block in web/index.html',
      () {
        final indexHtml = _read('web/index.html');
        // The same regex literal the PowerShell helper uses (translated
        // to Dart syntax: PowerShell `(?s)` -> Dart `dotAll: true`).
        final cspMetaPattern = RegExp(
          r'<meta\s+http-equiv="Content-Security-Policy".*?">',
          dotAll: true,
        );
        final match = cspMetaPattern.firstMatch(indexHtml);
        expect(
          match,
          isNotNull,
          reason:
              'web/index.html no longer contains a `<meta '
              'http-equiv="Content-Security-Policy" ...>` block that the '
              'shared CSP-swap helper at scripts/_dev_csp_swap.ps1 can '
              'find. Both web console demos will hit a CSP violation in '
              'dev mode and the operator will be stuck on splash. If you '
              'restructured the CSP (e.g. moved it to an HTTP header), '
              'update both the helper regex and this test.',
        );

        // Sanity: the matched block should still allow at least the
        // strict prod baseline directives. If someone deletes the CSP
        // entirely or drops `script-src`, the swap is meaningless.
        expect(
          match!.group(0),
          contains("script-src"),
          reason:
              'The matched <meta http-equiv="Content-Security-Policy"> '
              'block lacks a `script-src` directive. The swap target is '
              'wrong or the file is malformed.',
        );
      },
    );

    test(
      "the dev CSP heredoc in scripts/_dev_csp_swap.ps1 keeps Flutter's "
      'DDC requirements (unsafe-inline + unsafe-eval) in script-src',
      () {
        final swapHelper = _read('scripts/_dev_csp_swap.ps1');
        // The dev CSP must allow `'unsafe-inline'` and `'unsafe-eval'`
        // in script-src for DDC to work. Without these, the swap is
        // pointless and Flutter Web won't paint in dev mode.
        expect(
          swapHelper,
          contains(
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' "
            "'wasm-unsafe-eval'",
          ),
          reason:
              'scripts/_dev_csp_swap.ps1 dev CSP heredoc no longer '
              "allows 'unsafe-inline' or 'unsafe-eval' in script-src. "
              "Flutter Web's DDC dev compiler injects inline scripts "
              "and uses eval(). Without both keywords, dev runs hit a "
              "CSP violation and Flutter never paints.",
        );
      },
    );
  });

  group('Web console launchers default to -Device chrome (auto-spawn)', () {
    test(
      'run_operator_web_dev.ps1 default -Device is chrome (auto-launches Chrome)',
      () {
        final script = _read('scripts/run_operator_web_dev.ps1');
        // Guard the default flipped in the operator-web-chrome PR. Web-server
        // is still selectable explicitly; the test fails if someone reverts
        // the default back to `web-server` (would re-introduce the
        // "script runs but no browser opens" UX regression).
        expect(
          script,
          matches(
            RegExp(
              r"\[string\]\s+\$Device\s*=\s*'chrome'",
              multiLine: true,
            ),
          ),
          reason:
              "scripts/run_operator_web_dev.ps1's `-Device` parameter no "
              "longer defaults to 'chrome'. The README assumes Chrome "
              "auto-opens when an operator runs the script. If you need "
              "headless behavior, pass `-Device web-server` explicitly "
              "(that's what scripts/run_all_demo.ps1 does).",
        );
      },
    );

    test(
      'run_admin_console_dev.ps1 default -Device is chrome',
      () {
        final script = _read('scripts/run_admin_console_dev.ps1');
        expect(
          script,
          matches(
            RegExp(
              r"\[string\]\s+\$Device\s*=\s*'chrome'",
              multiLine: true,
            ),
          ),
          reason:
              "scripts/run_admin_console_dev.ps1's `-Device` parameter no "
              "longer defaults to 'chrome'. Both web console launchers "
              "should auto-spawn Chrome for the README single-surface "
              "demo path.",
        );
      },
    );

    test(
      'run_all_demo.ps1 forces operator-web to -Device web-server (parallel safe)',
      () {
        final script = _read('scripts/run_all_demo.ps1');
        // Without the explicit override, the parallel launcher would
        // spawn a fresh Chrome window per surface (because operator-web
        // now defaults to chrome) — wrong for the multi-launch use case.
        // Test passes if `-Device, 'web-server'` appears in the operator
        // launch Args array.
        expect(
          script,
          contains("'-Device', 'web-server'"),
          reason:
              'scripts/run_all_demo.ps1 no longer passes `-Device '
              "web-server` to operator-web. With operator-web's default "
              'now being `chrome`, the parallel launcher would spawn a '
              'fresh Chrome window per surface instead of binding the '
              'headless dev server on 8181. Re-add the explicit '
              "`-Device web-server` flag to the operator-web launch "
              'Args.',
        );
      },
    );
  });

  group('Production-gate refusal without -IUnderstand', () {
    test(
      'all three launchers contain the BLOCKED: -Mode production '
      'targets message',
      () {
        for (final script in <String>[
          'scripts/run_flutter_dev.ps1',
          'scripts/run_operator_web_dev.ps1',
          'scripts/run_admin_console_dev.ps1',
        ]) {
          final body = _read(script);
          expect(
            body,
            contains('BLOCKED: -Mode production targets'),
            reason:
                '$script no longer prints the production-gate refusal '
                'message. -Mode production must fail closed without '
                '-IUnderstand so a forgotten flag does not silently '
                'point local dev at the live proxy.',
          );
          expect(
            body,
            contains(r'$IUnderstand'),
            reason:
                '$script no longer declares the -IUnderstand switch. '
                'Production mode must require explicit confirmation.',
          );
        }
      },
    );
  });

  group('Splash-removal fallback (PR #809)', () {
    test(
      'forge_flow_web_bootstrap.js installs a MutationObserver that calls '
      'removeSplashFromWeb on flt-glass-pane mount',
      () {
        final bootstrap = _read('web/forge_flow_web_bootstrap.js');
        // PR #809 fix: dev-mode Flutter never auto-removes the splash
        // because flutter_native_splash only injects the call into the
        // production-built flutter_bootstrap.js. Without this observer,
        // every dev launch hangs on splash.
        expect(
          bootstrap,
          allOf(
            contains('MutationObserver'),
            contains('flt-glass-pane'),
            contains('removeSplashFromWeb'),
          ),
          reason:
              'web/forge_flow_web_bootstrap.js no longer installs the '
              'splash-removal MutationObserver that watches for '
              '`flt-glass-pane` and calls `window.removeSplashFromWeb()`. '
              'Without it, `flutter run` web demos hang on the splash '
              'forever (production builds are unaffected because the '
              'flutter_native_splash plugin auto-injects the same call '
              'into the built `flutter_bootstrap.js`).',
        );
      },
    );
  });

  group('README master matrix points at the live launcher scripts', () {
    test(
      'README contains the README master matrix demo commands',
      () {
        final readme = _read('README.md');
        // The four canonical demo commands.
        for (final cmd in <String>[
          r'scripts\run_operator_web_dev.ps1 -Mode demo',
          r'scripts\run_admin_console_dev.ps1 -Mode demo',
          r'scripts\run_flutter_dev.ps1 -App forgeflow -Mode demo',
          r'scripts\run_flutter_dev.ps1 -App barrio -Mode demo',
        ]) {
          expect(
            readme,
            contains(cmd),
            reason:
                'README.md no longer documents `$cmd`. Either the launcher '
                'was renamed (update the README) or the README matrix was '
                'dropped (restore it — operators copy-paste from here).',
          );
        }
      },
    );
  });
}

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    throw StateError(
      'Expected $relativePath to exist (running `flutter test` from '
      'the repo root). Either the file was moved or the test is '
      'invoked from the wrong directory.',
    );
  }
  return file.readAsStringSync();
}
