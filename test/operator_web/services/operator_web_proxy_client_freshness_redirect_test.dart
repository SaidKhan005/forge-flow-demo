// CODE_OPS_DEBT carry-over #1 — operator-web proxy client detects
// the proxy's `mfa_freshness_required` 403, dispatches to the
// registered [MfaFreshnessRedirectListener], and surfaces the
// `redirect_uri` on the thrown [OperatorWebProxyException] so screen
// catch-blocks can branch on `isMfaFreshnessRedirect`.
//
// The shell-level wiring (sign-out + state emit) is tested via the
// `FirebaseOperatorWebAuthSource` integration; this file tests the
// transport seam only.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/auth/mfa_freshness_redirect_listener.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';

void main() {
  group('OperatorWebProxyClient mfa_freshness_required handling', () {
    test(
      '403 mfa_freshness_required → listener dispatched + exception carries redirectUri',
      () async {
        final listener = RecordingMfaFreshnessRedirectListener();
        final mock = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'mfa_freshness_required',
              'message': 'fresh authentication is required',
              'refresh_after': '2026-05-08T12:30:00.000Z',
              'redirect_uri':
                  '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
            }),
            403,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        });
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          mfaFreshnessRedirectListener: listener,
        );

        OperatorWebProxyException? caught;
        try {
          await client.getJson(
            '/v1/auth/account',
            idToken: 'tok',
          );
        } on OperatorWebProxyException catch (e) {
          caught = e;
        }

        expect(caught, isNotNull);
        expect(caught!.statusCode, 403);
        expect(caught.code, 'mfa_freshness_required');
        expect(
          caught.redirectUri,
          '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
        );
        expect(caught.isMfaFreshnessRedirect, isTrue);
        expect(listener.events, hasLength(1));
        expect(
          listener.events.single.redirectUri,
          '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
        );
      },
    );

    test(
      '403 with a different error code does NOT dispatch + exception has no redirectUri',
      () async {
        final listener = RecordingMfaFreshnessRedirectListener();
        final mock = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'permission_denied',
              'message': 'permission denied',
            }),
            403,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        });
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
          mfaFreshnessRedirectListener: listener,
        );

        OperatorWebProxyException? caught;
        try {
          await client.getJson(
            '/v1/auth/account',
            idToken: 'tok',
          );
        } on OperatorWebProxyException catch (e) {
          caught = e;
        }

        expect(caught, isNotNull);
        expect(caught!.statusCode, 403);
        expect(caught.code, 'permission_denied');
        expect(caught.redirectUri, isNull);
        expect(caught.isMfaFreshnessRedirect, isFalse);
        expect(listener.events, isEmpty);
      },
    );

    test('200 response leaves listener untouched', () async {
      final listener = RecordingMfaFreshnessRedirectListener();
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{'ok': true}),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final client = OperatorWebProxyClient(
        baseUri: Uri.parse('https://proxy.test/'),
        httpClient: mock,
        mfaFreshnessRedirectListener: listener,
      );

      await client.getJson('/v1/auth/account', idToken: 'tok');
      expect(listener.events, isEmpty);
    });

    test(
      'late-bound listener via setter receives subsequent 403 dispatches',
      () async {
        final listener = RecordingMfaFreshnessRedirectListener();
        final mock = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'mfa_freshness_required',
              'redirect_uri': '/auth/login?reason=fresh_mfa_required',
            }),
            403,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        });
        // No listener at construction.
        final client = OperatorWebProxyClient(
          baseUri: Uri.parse('https://proxy.test/'),
          httpClient: mock,
        );
        // Late-bind via setter (mirrors how the auth source wires
        // itself up after the proxy client is built).
        client.mfaFreshnessRedirectListener = listener;

        try {
          await client.getJson('/v1/auth/account', idToken: 'tok');
        } on OperatorWebProxyException {
          // expected
        }

        expect(listener.events, hasLength(1));
      },
    );
  });
}
