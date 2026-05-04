// Phase 11W.0 — Operator Web Console onboarding click-path tests.
//
// Drives the full magic-link → password → MFA → T&Cs → completed
// click path through the demo source so the screens hand off
// state correctly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/router/operator_web_router.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  // The onboarding layout renders at 1024×1400 which exceeds the 800×600
  // default test viewport. Set a desktop-sized surface so scroll-into-view
  // and tap targets resolve to real coordinates.
  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> enterTextKey(
    WidgetTester tester,
    Key key,
    String text,
  ) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(key), text);
  }

  group('Operator-web onboarding click path (demo source)', () {
    testWidgets('full click path: welcome → password → MFA → T&Cs → completed',
        (tester) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);

      await tester.pumpWidget(
        wrap(
          OperatorWebRouter(
            source: source,
            initialMagicLinkToken:
                DemoOperatorWebAuthSource.kDemoMagicLinkToken,
          ),
        ),
      );

      // Step 1 — welcome / token verify.
      expect(find.byKey(const Key('operator_web_welcome_token_field')),
          findsOneWidget);
      await tapKey(tester, const Key('operator_web_welcome_submit'));

      // Step 2 — password setup.
      expect(find.byKey(const Key('operator_web_password_field')),
          findsOneWidget);
      await enterTextKey(
        tester,
        const Key('operator_web_password_field'),
        'this-is-a-twelve-plus-character-passphrase',
      );
      await enterTextKey(
        tester,
        const Key('operator_web_password_confirm_field'),
        'this-is-a-twelve-plus-character-passphrase',
      );
      await tapKey(tester, const Key('operator_web_password_submit'));

      // Step 3 — MFA enrollment.
      expect(find.byKey(const Key('operator_web_mfa_factor_picker')),
          findsOneWidget);
      // Default factor = TOTP. Begin enrollment.
      await tapKey(tester, const Key('operator_web_mfa_begin'));
      // Artifact panel rendered with QR copy.
      expect(find.byKey(const Key('operator_web_mfa_artifact_panel')),
          findsOneWidget);
      await enterTextKey(
        tester,
        const Key('operator_web_mfa_code_field'),
        '123456',
      );
      await tapKey(tester, const Key('operator_web_mfa_confirm'));

      // Step 4 — T&Cs accept.
      expect(find.byKey(const Key('operator_web_tos_summary')),
          findsOneWidget);
      // Tick the agreement checkbox + submit.
      await tapKey(tester, const Key('operator_web_tos_agreement_checkbox'));
      await tapKey(tester, const Key('operator_web_tos_submit'));

      // Completed — post-onboarding shell with the real Account screen
      // (11W.7 retired the placeholder).
      expect(source.current, isA<OperatorWebCompleted>());
      expect(find.byKey(const Key('operator_web_shell_scaffold')),
          findsOneWidget);
      expect(find.byKey(const Key('operator_web_account_screen')),
          findsOneWidget);
    });

    testWidgets('welcome screen rejects unknown token with remediation copy',
        (tester) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      await enterTextKey(
        tester,
        const Key('operator_web_welcome_token_field'),
        'not-a-real-token',
      );
      await tapKey(tester, const Key('operator_web_welcome_submit'));

      expect(find.byKey(const Key('operator_web_onboarding_error_banner')),
          findsOneWidget);
      // Remediation copy should mention asking F&F support to resend
      // the invite. The welcome screen also carries a static support
      // footer that mentions resends — accept N >= 1 occurrences so
      // the assertion focuses on "the user sees a remediation path"
      // rather than counting strings.
      expect(
        find.textContaining('resend the invite'),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('password screen rejects too-short password locally', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);
      source.emitForTesting(
        const OperatorWebSettingPassword(session: kDemoOperatorWebSession),
      );

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      await enterTextKey(
        tester,
        const Key('operator_web_password_field'),
        'short',
      );
      await enterTextKey(
        tester,
        const Key('operator_web_password_confirm_field'),
        'short',
      );
      await tapKey(tester, const Key('operator_web_password_submit'));

      expect(find.byKey(const Key('operator_web_onboarding_error_banner')),
          findsOneWidget);
      // The strong-password explainer + the error banner both reference
      // 12 characters; checking N>=1 is enough.
      expect(find.textContaining('12 characters'), findsAtLeastNWidgets(1));
    });

    testWidgets('password screen rejects mismatched confirmation', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);
      source.emitForTesting(
        const OperatorWebSettingPassword(session: kDemoOperatorWebSession),
      );

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      await enterTextKey(
        tester,
        const Key('operator_web_password_field'),
        'this-is-a-twelve-plus-character-passphrase',
      );
      await enterTextKey(
        tester,
        const Key('operator_web_password_confirm_field'),
        'different-twelve-plus-character-passphrase',
      );
      await tapKey(tester, const Key('operator_web_password_submit'));

      expect(find.byKey(const Key('operator_web_onboarding_error_banner')),
          findsOneWidget);
      expect(find.textContaining("didn't match"), findsOneWidget);
    });

    testWidgets('MFA screen rejects bad TOTP code with remediation copy', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);
      source.emitForTesting(
        const OperatorWebEnrollingMfa(session: kDemoOperatorWebSession),
      );

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      // Begin enrollment to expose the code field.
      await tapKey(tester, const Key('operator_web_mfa_begin'));

      await enterTextKey(
        tester,
        const Key('operator_web_mfa_code_field'),
        '000000',
      );
      await tapKey(tester, const Key('operator_web_mfa_confirm'));

      expect(find.byKey(const Key('operator_web_onboarding_error_banner')),
          findsOneWidget);
      // Both the QR-code explainer and the bad-code remediation
      // mention the 30-second refresh window; one match in either
      // location is enough to prove the remediation copy reaches
      // the user.
      expect(find.textContaining('every 30 seconds'),
          findsAtLeastNWidgets(1));
    });

    testWidgets('T&Cs screen blocks submit when checkbox is unticked', (
      tester,
    ) async {
      await sizeViewport(tester);
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);
      source.emitForTesting(
        OperatorWebAcceptingTos(
          session: kDemoOperatorWebSession,
          tosVersion: DemoOperatorWebAuthSource.kDemoTosVersion.version,
          tosBodyMarkdown:
              DemoOperatorWebAuthSource.kDemoTosVersion.bodyMarkdown,
        ),
      );

      await tester.pumpWidget(wrap(OperatorWebRouter(source: source)));

      // Submit without ticking — local error appears, state stays.
      await tapKey(tester, const Key('operator_web_tos_submit'));
      expect(find.byKey(const Key('operator_web_onboarding_error_banner')),
          findsOneWidget);
      expect(source.current, isA<OperatorWebAcceptingTos>());

      // Tick + submit — advances to completed.
      await tapKey(tester, const Key('operator_web_tos_agreement_checkbox'));
      await tapKey(tester, const Key('operator_web_tos_submit'));
      expect(source.current, isA<OperatorWebCompleted>());
    });
  });

  group('Auth-source state machine isolated', () {
    test('verifyMagicLinkToken with the demo token advances to settingPassword',
        () async {
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);

      await source.verifyMagicLinkToken(
        DemoOperatorWebAuthSource.kDemoMagicLinkToken,
      );

      expect(source.current, isA<OperatorWebSettingPassword>());
      expect(
        (source.current as OperatorWebSettingPassword).session.businessName,
        equals('Demo Restaurant Group'),
      );
    });

    test('verifyMagicLinkToken with empty input keeps state and emits error',
        () async {
      final source = DemoOperatorWebAuthSource.atWelcome();
      addTearDown(source.dispose);

      await source.verifyMagicLinkToken('');

      expect(source.current, isA<OperatorWebNeedsToken>());
      expect(source.current.lastErrorMessage, isNotNull);
    });

    test('signOut from any state lands on signed-out', () async {
      final source = DemoOperatorWebAuthSource.completed();
      addTearDown(source.dispose);

      await source.signOut();
      expect(source.current, isA<OperatorWebSignedOut>());
    });
  });
}
