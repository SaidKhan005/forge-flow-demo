// CODE_OPS_DEBT carry-over #1 — admin HTTP layer dispatches to the
// process-wide [MfaFreshnessRedirectListener] when a 403 carries the
// proxy's `mfa_freshness_required` payload.
//
// This test pins the integration shape — every admin gateway funnels
// through `sendAdminHttpRequest`, which parses the 403 body and calls
// the registered listener BEFORE returning the response. The
// gateway's own status-code branch then throws as it always has, so
// existing error UI is unchanged.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:forge_and_flow/admin/services/admin_http_timeout.dart';
import 'package:forge_and_flow/auth/mfa_freshness_redirect_listener.dart';

void main() {
  tearDown(AdminHttpFreshnessRedirectDispatcher.resetForTesting);

  test(
    '403 mfa_freshness_required → dispatcher fires before response returns',
    () async {
      final listener = RecordingMfaFreshnessRedirectListener();
      AdminHttpFreshnessRedirectDispatcher.listener = listener;

      final response = await sendAdminHttpRequest(
        _StubClient(
          statusCode: 403,
          body: jsonEncode(<String, Object?>{
            'error': 'mfa_freshness_required',
            'message': 'fresh authentication is required',
            'refresh_after': '2026-05-08T12:30:00.000Z',
            'redirect_uri':
                '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
          }),
        ),
        http.Request('GET', Uri.parse('https://proxy.test/admin/audit/export')),
      );

      expect(response.statusCode, 403);
      expect(listener.events, hasLength(1));
      expect(
        listener.events.single.redirectUri,
        '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
      );
      expect(
        listener.events.single.message,
        'fresh authentication is required',
      );
      expect(listener.events.single.refreshAfter, isNotNull);
    },
  );

  test(
    '403 with a different error code does NOT dispatch the redirect listener',
    () async {
      final listener = RecordingMfaFreshnessRedirectListener();
      AdminHttpFreshnessRedirectDispatcher.listener = listener;

      final response = await sendAdminHttpRequest(
        _StubClient(
          statusCode: 403,
          body: jsonEncode(<String, Object?>{
            'error': 'permission_denied',
            'message': 'permission denied',
            'permission_key': 'admin.audit.export',
          }),
        ),
        http.Request('GET', Uri.parse('https://proxy.test/admin/audit/export')),
      );

      expect(response.statusCode, 403);
      expect(listener.events, isEmpty);
    },
  );

  test('200 response does NOT dispatch the redirect listener', () async {
    final listener = RecordingMfaFreshnessRedirectListener();
    AdminHttpFreshnessRedirectDispatcher.listener = listener;

    final response = await sendAdminHttpRequest(
      _StubClient(statusCode: 200, body: '{}'),
      http.Request('GET', Uri.parse('https://proxy.test/admin/users')),
    );

    expect(response.statusCode, 200);
    expect(listener.events, isEmpty);
  });

  test('malformed JSON 403 body does NOT throw — gateway sees the 403', () async {
    final listener = RecordingMfaFreshnessRedirectListener();
    AdminHttpFreshnessRedirectDispatcher.listener = listener;

    final response = await sendAdminHttpRequest(
      _StubClient(statusCode: 403, body: '<html>not json</html>'),
      http.Request('GET', Uri.parse('https://proxy.test/admin/users')),
    );

    expect(response.statusCode, 403);
    expect(listener.events, isEmpty);
  });

  test('default listener is a no-op (resetForTesting restores it)', () {
    AdminHttpFreshnessRedirectDispatcher.listener =
        RecordingMfaFreshnessRedirectListener();
    AdminHttpFreshnessRedirectDispatcher.resetForTesting();
    expect(
      AdminHttpFreshnessRedirectDispatcher.listener,
      isA<NoopMfaFreshnessRedirectListener>(),
    );
  });
}

class _StubClient extends http.BaseClient {
  _StubClient({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[bytes]),
      statusCode,
      contentLength: bytes.length,
      request: request,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );
  }
}
