// Lane B B11.2.b — clock-skew fix for _requireFreshMfaToken.
//
// Pins the deep-audit P1 fix: `_requireFreshMfaToken` rejected any
// `auth_time > now` with zero skew tolerance, which fired spuriously
// on legitimate clock drift (browser clock a few seconds ahead of the
// proxy). After the fix the rejection only fires when auth_time is
// MORE than 60s in the future — the standard JWT skew window (RFC
// 7519 §4.1.4 leeway).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/web_account_gateway.dart';

void main() {
  group('_requireFreshMfaToken clock-skew window', () {
    test('exposes the ±60s skew constant', () {
      expect(
        HttpWebAccountGateway.freshMfaClockSkewWindow,
        equals(const Duration(seconds: 60)),
      );
    });

    // The freshness check fires inside `signOutOtherSessions`. The
    // tests below build an ID token with a tunable `auth_time` claim,
    // set the gateway clock to a fixed `now`, and assert which calls
    // succeed vs. throw AccountSessionFreshMfaRequiredException.
    final fixedNow = DateTime.utc(2026, 5, 13, 10);

    HttpWebAccountGateway gatewayWithToken({required DateTime authTime}) {
      final token = _makeIdToken(authTime: authTime);
      final mock = MockClient((request) async {
        // Underlying revoke route — irrelevant for this test set.
        return http.Response(
          jsonEncode(<String, Object?>{'revoked': true}),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = OperatorWebProxyClient(
        baseUri: Uri.parse('https://proxy.test/'),
        httpClient: mock,
        idempotencyKeyFactory: () => 'idem-key-fixture',
      );
      return HttpWebAccountGateway(
        client: client,
        idTokenProvider: () async => token,
        now: () => fixedNow,
      );
    }

    test(
      'accepts auth_time 0s in the future (no skew) when within the freshness '
      'window',
      () async {
        final gateway = gatewayWithToken(authTime: fixedNow);
        // signOutOtherSessions delegates to _revokeOnceWithStepUp;
        // a successful return means the fresh-mfa guard did NOT
        // throw.
        await expectLater(
          gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
          completes,
        );
      },
    );

    test('accepts auth_time +30s skew (within ±60s window)', () async {
      final gateway = gatewayWithToken(
        authTime: fixedNow.add(const Duration(seconds: 30)),
      );
      await expectLater(
        gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
        completes,
      );
    });

    test('accepts auth_time +59s skew (boundary — within ±60s)', () async {
      final gateway = gatewayWithToken(
        authTime: fixedNow.add(const Duration(seconds: 59)),
      );
      await expectLater(
        gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
        completes,
      );
    });

    test('accepts auth_time exactly +60s skew (inclusive boundary)',
        () async {
      final gateway = gatewayWithToken(
        authTime: fixedNow.add(const Duration(seconds: 60)),
      );
      await expectLater(
        gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
        completes,
      );
    });

    test('rejects auth_time +61s skew (outside ±60s window)', () async {
      final gateway = gatewayWithToken(
        authTime: fixedNow.add(const Duration(seconds: 61)),
      );
      await expectLater(
        gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
        throwsA(isA<AccountSessionFreshMfaRequiredException>()),
      );
    });

    test('rejects auth_time +5 minutes in the future', () async {
      final gateway = gatewayWithToken(
        authTime: fixedNow.add(const Duration(minutes: 5)),
      );
      await expectLater(
        gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
        throwsA(isA<AccountSessionFreshMfaRequiredException>()),
      );
    });

    test('accepts recent past auth_time (well within freshness window)',
        () async {
      final gateway = gatewayWithToken(
        authTime: fixedNow.subtract(const Duration(minutes: 5)),
      );
      await expectLater(
        gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
        completes,
      );
    });

    test('rejects auth_time outside the 1-hour freshness window', () async {
      final gateway = gatewayWithToken(
        authTime: fixedNow.subtract(const Duration(hours: 2)),
      );
      await expectLater(
        gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
        throwsA(isA<AccountSessionFreshMfaRequiredException>()),
      );
    });

    test(
      'past-direction freshness window is NOT stretched by the skew '
      '(an early-by-skew client cannot bypass the 1-hour rule)',
      () async {
        // auth_time = 1 hour ago + 30s skew. The past-direction check
        // uses `now - auth_time > 1 hour` which is FALSE here (the
        // diff is 1h - 30s = ~3570s). So this should be accepted —
        // we're still within the freshness window.
        final gateway = gatewayWithToken(
          authTime: fixedNow.subtract(
            const Duration(hours: 1) - const Duration(seconds: 30),
          ),
        );
        await expectLater(
          gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
          completes,
        );
      },
    );

    test(
      'past-direction at exactly 1 hour stale is rejected (window edge)',
      () async {
        final gateway = gatewayWithToken(
          authTime: fixedNow.subtract(
            const Duration(hours: 1) + const Duration(seconds: 1),
          ),
        );
        await expectLater(
          gateway.signOutOtherSessions(sessionIds: const <String>['s1']),
          throwsA(isA<AccountSessionFreshMfaRequiredException>()),
        );
      },
    );
  });
}

/// Builds a minimal JWT-shaped string with the `auth_time` claim set
/// to [authTime].seconds. The gateway only decodes the payload, never
/// verifies the signature, so a placeholder header + signature is
/// sufficient.
String _makeIdToken({required DateTime authTime}) {
  final headerJson = base64UrlEncode(utf8.encode(jsonEncode(<String, Object?>{
    'alg': 'RS256',
    'typ': 'JWT',
  }))).replaceAll('=', '');
  final payloadJson = base64UrlEncode(utf8.encode(jsonEncode(<String, Object?>{
    'sub': 'user-1',
    'iat': authTime.toUtc().millisecondsSinceEpoch ~/ 1000,
    'auth_time': authTime.toUtc().millisecondsSinceEpoch ~/ 1000,
  }))).replaceAll('=', '');
  return '$headerJson.$payloadJson.signature-placeholder';
}
