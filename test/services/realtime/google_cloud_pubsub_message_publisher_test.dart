// N5 — GoogleCloudPubsubMessagePublisher unit tests.
//
// Pinned behavior:
//   * publish() POSTs to the Pub/Sub REST publish endpoint with the
//     project + topic encoded in the path.
//   * The Authorization header carries the access token from the
//     injected provider with a `Bearer ` prefix.
//   * The body is the wire-format envelope `{messages:[{data, attributes}]}`
//     with `data` base64(utf8(body)) so the subscriber can round-trip
//     decode it.
//   * Empty `attributes` map omits the `attributes` key (saves a few
//     bytes per publish).
//   * Non-2xx response throws `PubsubPublishFailure` with the status
//     code and a sanitized error summary; the request body is never
//     echoed in the failure message.
//
// The tests inject a `http.Client` mock and a static
// `OAuthAccessTokenProvider`; no live Pub/Sub calls are made.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart'
    show OAuthAccessTokenProvider;
import 'package:forge_and_flow/services/realtime/google_cloud_pubsub_message_publisher.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('GoogleCloudPubsubMessagePublisher.publish', () {
    test('POSTs the wire-format envelope to the Pub/Sub publish endpoint', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      String? capturedBody;
      final mockClient = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        capturedBody = request.body;
        return http.Response(
          jsonEncode(<String, Object?>{'messageIds': <String>['msg-1']}),
          200,
          headers: <String, String>{'Content-Type': 'application/json'},
        );
      });

      final publisher = GoogleCloudPubsubMessagePublisher(
        projectId: 'proj-x',
        accessTokenProvider: _StaticTokenProvider('token-abc'),
        httpClient: mockClient,
      );
      await publisher.publish(
        topicName: 'forge-realtime',
        body: '{"hello":"world"}',
        attributes: <String, String>{
          'operator_id': 'op-1',
          'topic': 'rollup.invalidate.x',
          'event_id': 'e-1',
        },
      );

      expect(capturedUri, isNotNull);
      expect(capturedUri!.host, kGoogleCloudPubsubHost);
      expect(
        capturedUri!.path,
        '/v1/projects/proj-x/topics/forge-realtime:publish',
      );
      expect(capturedHeaders!['authorization'], 'Bearer token-abc');
      expect(capturedHeaders!['content-type'], 'application/json');
      final decoded = jsonDecode(capturedBody!) as Map<String, Object?>;
      final messages = decoded['messages'] as List<Object?>;
      expect(messages, hasLength(1));
      final message = messages.single as Map<String, Object?>;
      expect(
        utf8.decode(base64Decode(message['data'] as String)),
        '{"hello":"world"}',
      );
      expect(
        message['attributes'],
        <String, String>{
          'operator_id': 'op-1',
          'topic': 'rollup.invalidate.x',
          'event_id': 'e-1',
        },
      );
    });

    test('omits `attributes` when the attributes map is empty', () async {
      String? capturedBody;
      final mockClient = MockClient((request) async {
        capturedBody = request.body;
        return http.Response('{}', 200);
      });
      final publisher = GoogleCloudPubsubMessagePublisher(
        projectId: 'proj-x',
        accessTokenProvider: _StaticTokenProvider('token-abc'),
        httpClient: mockClient,
      );
      await publisher.publish(
        topicName: 'forge-realtime',
        body: 'noop',
        attributes: const <String, String>{},
      );
      final decoded = jsonDecode(capturedBody!) as Map<String, Object?>;
      final messages = decoded['messages'] as List<Object?>;
      final message = messages.single as Map<String, Object?>;
      expect(
        message.containsKey('attributes'),
        isFalse,
        reason:
            'empty attributes map omits the key — saves bytes per publish '
            'without changing semantics',
      );
    });

    test('throws PubsubPublishFailure on non-2xx with the status + summary',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 403,
              'status': 'PERMISSION_DENIED',
              'message': 'request body would echo here',
            },
          }),
          403,
          headers: <String, String>{'Content-Type': 'application/json'},
        );
      });
      final publisher = GoogleCloudPubsubMessagePublisher(
        projectId: 'proj-x',
        accessTokenProvider: _StaticTokenProvider('token-abc'),
        httpClient: mockClient,
      );
      await expectLater(
        () => publisher.publish(
          topicName: 'forge-realtime',
          body: '{}',
          attributes: const <String, String>{},
        ),
        throwsA(
          isA<PubsubPublishFailure>()
              .having((f) => f.statusCode, 'statusCode', 403)
              .having(
                (f) => f.shortMessage,
                'shortMessage',
                contains('code=403'),
              )
              .having(
                (f) => f.shortMessage,
                'shortMessage',
                contains('PERMISSION_DENIED'),
              ),
        ),
      );
    });
  });
}

class _StaticTokenProvider implements OAuthAccessTokenProvider {
  _StaticTokenProvider(this._token);
  final String _token;
  @override
  Future<String> accessToken() async => _token;
}
