import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('web password reset action page', () {
    late String html;
    late String firebaseConfig;

    setUpAll(() {
      html = File('web/auth/action/index.html').readAsStringSync();
      firebaseConfig = File('web/firebase-config.js').readAsStringSync();
    });

    test('posts confirm submissions to the proxy reset route', () {
      expect(html, contains('/v1/auth/password/reset/confirm'));
      expect(html, contains('method: "POST"'));
      expect(html, contains('Idempotency-Key'));
      expect(html, contains('oob_code'));
      expect(html, contains('new_password'));
      expect(html, isNot(contains(' : "/v1/auth/password/reset/confirm"')));
      expect(
        html,
        contains('This action page is missing its proxy configuration.'),
      );
    });

    test('Firebase hosting config points reset confirms at staging proxy', () {
      expect(firebaseConfig, contains('"proxyBaseUri"'));
      expect(firebaseConfig, contains('https://staging-api.feflow.org'));
    });

    test('keeps mobile handoff and web fallback aligned with app copy', () {
      expect(html, contains('forgeflow://reset-password'));
      expect(html, contains('Forgot password?'));
      expect(html, isNot(contains('Email me a reset link')));
      expect(html, contains('Password updated. Please sign in.'));
    });

    test('maps proxy policy rejections to friendly copy', () {
      expect(html, contains('pwned_in_breach'));
      expect(
        html,
        contains(
          'This password has appeared in known breaches; please choose another.',
        ),
      );
      expect(html, contains('reused_from_history'));
      expect(html, contains("You can't reuse a recent password."));
      expect(html, contains('violates_policy'));
    });
  });

  group('Firebase auth action callback configuration', () {
    test('script defaults to the hosted Forge & Flow action page', () {
      final script = File(
        'scripts/configure_firebase_auth_email_action_url.ps1',
      ).readAsStringSync();

      expect(script, contains('firebaseapp.com/auth/action'));
      expect(script, isNot(contains('firebaseapp.com/__/auth/action')));
    });
  });
}
