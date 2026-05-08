// CODE_OPS_DEBT carry-over #1 — unit tests for the
// `mfa_freshness_required` 403 redirect contract parser.
//
// Companion files:
//   * `lib/auth/mfa_freshness_redirect_listener.dart` (parser + seam)
//   * `lib/auth/fresh_mfa_resolver.dart` (PR #384 — the proxy emits
//     this 403 when the resolver says stale)
//   * `tool/advisor_proxy/advisor_proxy.dart`
//     (`_requireAdminPermissionOrWrite` — emission site, payload
//     shape pinned by these tests)

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/mfa_freshness_redirect_listener.dart';

void main() {
  group('MfaFreshnessRedirectPayload.tryParse', () {
    test('parses the canonical proxy 403 payload', () {
      final payload = MfaFreshnessRedirectPayload.tryParse(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'mfa_freshness_required',
          'message': 'fresh authentication is required',
          'refresh_after': '2026-05-08T12:30:00.000Z',
          'redirect_uri':
              '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
        },
      );
      expect(payload, isNotNull);
      expect(
        payload!.redirectUri,
        '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
      );
      expect(payload.message, 'fresh authentication is required');
      expect(payload.refreshAfter, DateTime.utc(2026, 5, 8, 12, 30));
    });

    test('returns null when status is not 403', () {
      final payload = MfaFreshnessRedirectPayload.tryParse(
        statusCode: 401,
        body: <String, Object?>{
          'error': 'mfa_freshness_required',
          'redirect_uri': '/auth/login',
        },
      );
      expect(payload, isNull);
    });

    test('returns null when error code is not the freshness sentinel', () {
      final payload = MfaFreshnessRedirectPayload.tryParse(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'permission_denied',
          'redirect_uri': '/auth/login',
        },
      );
      expect(payload, isNull);
    });

    test('returns null when redirect_uri is missing', () {
      final payload = MfaFreshnessRedirectPayload.tryParse(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'mfa_freshness_required',
          'message': 'fresh authentication is required',
        },
      );
      expect(payload, isNull);
    });

    test('returns null when redirect_uri is empty', () {
      final payload = MfaFreshnessRedirectPayload.tryParse(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'mfa_freshness_required',
          'redirect_uri': '   ',
        },
      );
      expect(payload, isNull);
    });

    test('returns null when redirect_uri is not a string', () {
      final payload = MfaFreshnessRedirectPayload.tryParse(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'mfa_freshness_required',
          'redirect_uri': 42,
        },
      );
      expect(payload, isNull);
    });

    test('tolerates a malformed refresh_after timestamp', () {
      final payload = MfaFreshnessRedirectPayload.tryParse(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'mfa_freshness_required',
          'message': 'fresh authentication is required',
          'refresh_after': 'not-a-real-timestamp',
          'redirect_uri': '/auth/login',
        },
      );
      expect(payload, isNotNull);
      expect(payload!.redirectUri, '/auth/login');
      expect(payload.refreshAfter, isNull);
    });

    test('errorCode constant matches the proxy emission sentinel', () {
      expect(
        MfaFreshnessRedirectPayload.errorCode,
        'mfa_freshness_required',
      );
    });
  });

  group('RecordingMfaFreshnessRedirectListener', () {
    test('captures every dispatch in order', () {
      final listener = RecordingMfaFreshnessRedirectListener();
      const a = MfaFreshnessRedirectPayload(redirectUri: '/auth/login?a=1');
      const b = MfaFreshnessRedirectPayload(redirectUri: '/auth/login?b=2');
      listener.onMfaFreshnessRedirect(a);
      listener.onMfaFreshnessRedirect(b);
      expect(listener.events, hasLength(2));
      expect(listener.events.first.redirectUri, '/auth/login?a=1');
      expect(listener.events.last.redirectUri, '/auth/login?b=2');
    });
  });

  group('NoopMfaFreshnessRedirectListener', () {
    test('absorbs dispatches without throwing', () {
      const listener = NoopMfaFreshnessRedirectListener();
      const payload = MfaFreshnessRedirectPayload(
        redirectUri: '/auth/login?reason=fresh_mfa_required',
      );
      // Should not throw.
      listener.onMfaFreshnessRedirect(payload);
    });
  });
}
