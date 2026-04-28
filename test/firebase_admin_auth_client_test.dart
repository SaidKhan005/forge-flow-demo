// Phase 9 live-closeout - Firebase Admin REST seam tests.
//
// These tests stay fully local: the concrete client is driven with a fake
// HttpClient so route-field drift in Identity Platform requests is caught
// without touching Firebase.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';

void main() {
  group('IdentityToolkitFirebaseAdminAuthClient', () {
    test(
      'setDisabled sends disableUser for accounts:update, not disabled',
      () async {
        final httpClient = _RecordingHttpClient(
          responseBody: const <String, Object?>{'localId': 'user-1'},
        );
        final client = IdentityToolkitFirebaseAdminAuthClient(
          projectId: 'forge-flow-staging',
          apiKey: 'public-api-key',
          accessTokenProvider: const _StaticAccessTokenProvider('oauth-token'),
          httpClient: httpClient,
        );

        await client.setDisabled(uid: 'user-1', disabled: true);

        // ignore: close_sinks - fake request was already closed by the client.
        final request = httpClient.requests.single;
        expect(
          request.url.path,
          equals('/v1/projects/forge-flow-staging/accounts:update'),
        );
        expect(
          request.headers.values[HttpHeaders.authorizationHeader],
          equals('Bearer oauth-token'),
        );
        expect(request.jsonBody['localId'], equals('user-1'));
        expect(request.jsonBody['disableUser'], isTrue);
        expect(request.jsonBody.containsKey('disabled'), isFalse);
      },
    );
  });
}

class _StaticAccessTokenProvider implements OAuthAccessTokenProvider {
  const _StaticAccessTokenProvider(this.token);

  final String token;

  @override
  Future<String> accessToken() async => token;
}

class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient({required this.responseBody});

  final Map<String, Object?> responseBody;
  final List<_RecordingHttpClientRequest> requests =
      <_RecordingHttpClientRequest>[];

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final request = _RecordingHttpClientRequest(
      url: url,
      responseBody: responseBody,
      statusCode: 200,
    );
    requests.add(request);
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingHttpClientRequest implements HttpClientRequest {
  _RecordingHttpClientRequest({
    required this.url,
    required this.responseBody,
    required this.statusCode,
  });

  final Uri url;
  final Map<String, Object?> responseBody;
  final int statusCode;
  @override
  final _RecordingHttpHeaders headers = _RecordingHttpHeaders();
  final List<int> _body = <int>[];

  Map<String, Object?> get jsonBody =>
      Map<String, Object?>.from(jsonDecode(utf8.decode(_body)) as Map);

  @override
  int contentLength = -1;

  @override
  void add(List<int> data) {
    _body.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() async {
    return _RecordingHttpClientResponse(
      statusCode: statusCode,
      body: jsonEncode(responseBody),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingHttpHeaders implements HttpHeaders {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _RecordingHttpClientResponse({required this.statusCode, required String body})
    : _chunks = <List<int>>[utf8.encode(body)];

  final List<List<int>> _chunks;

  @override
  final int statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(_chunks).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
