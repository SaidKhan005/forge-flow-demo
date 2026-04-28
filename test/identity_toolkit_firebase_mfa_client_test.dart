// Phase 9 live-closeout - Identity Toolkit MFA REST adapter tests.
//
// Fully local: fake HttpClient. These tests catch REST field drift without
// touching Firebase.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/identity_toolkit_firebase_mfa_client.dart';

void main() {
  group('IdentityToolkitFirebaseMfaClient', () {
    test(
      'begin TOTP enrollment posts id token and parses session payload',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'totpSessionInfo': <String, Object?>{
              'sharedSecretKey': 'JBSWY3DPEHPK3PXP',
              'verificationCodeLength': 6,
              'hashingAlgorithm': 'SHA1',
              'periodSec': 30,
              'sessionInfo': 'enrollment-session-1',
            },
          }),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final setup = await client.beginTotpEnrollment(
          authorizationIdToken: 'user-id-token',
          userId: 'user-1',
          userEmail: 'owner@example.test',
          issuerName: 'Forge & Flow',
        );

        expect(setup.factorId, equals('enrollment-session-1'));
        expect(setup.secretBase32, equals('JBSWY3DPEHPK3PXP'));
        expect(setup.otpAuthUrl, startsWith('otpauth://totp/'));
        expect(setup.otpAuthUrl, contains('secret=JBSWY3DPEHPK3PXP'));
        expect(setup.otpAuthUrl, contains('issuer=Forge+%26+Flow'));

        // ignore: close_sinks - fake request was already closed by the client.
        final request = httpClient.requests.single;
        expect(request.url.path, equals('/v2/accounts/mfaEnrollment:start'));
        expect(request.url.queryParameters['key'], equals('public-api-key'));
        expect(request.headers.values[HttpHeaders.authorizationHeader], isNull);
        expect(request.jsonBody['idToken'], equals('user-id-token'));
        expect(
          request.jsonBody['totpEnrollmentInfo'],
          isA<Map<Object?, Object?>>(),
        );
      },
    );

    test(
      'confirm TOTP finalizes then looks up the enrolled factor id',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'idToken': 'updated-user-id-token',
            'refreshToken': 'updated-refresh-token',
            'totpAuthInfo': <String, Object?>{},
          }),
          const _FakeResponse(<String, Object?>{
            'users': <Object?>[
              <String, Object?>{
                'localId': 'user-1',
                'mfaInfo': <Object?>[
                  <String, Object?>{
                    'mfaEnrollmentId': 'older-factor',
                    'displayName': 'Forge & Flow',
                    'enrolledAt': '2026-04-28T11:59:00Z',
                    'totpInfo': <String, Object?>{},
                  },
                  <String, Object?>{
                    'mfaEnrollmentId': 'new-totp-factor',
                    'displayName': 'Forge & Flow',
                    'enrolledAt': '2026-04-28T12:01:00Z',
                    'totpInfo': <String, Object?>{},
                  },
                ],
              },
            ],
          }),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final outcome = await client.confirmTotpEnrollment(
          authorizationIdToken: 'user-id-token',
          factorId: 'enrollment-session-1',
          oneTimeCode: '123456',
          issuerName: 'Forge & Flow',
        );

        expect(outcome, isA<FirebaseMfaConfirmSucceeded>());
        final success = outcome as FirebaseMfaConfirmSucceeded;
        expect(
          success.factorMetadata['firebase_factor_uid'],
          equals('new-totp-factor'),
        );
        expect(
          success.factorMetadata['provider'],
          equals('identity_toolkit_rest'),
        );

        expect(
          httpClient.requests.map((request) => request.url.path),
          equals(<String>[
            '/v2/accounts/mfaEnrollment:finalize',
            '/v1/accounts:lookup',
          ]),
        );
        expect(
          httpClient.requests[0].jsonBody['totpVerificationInfo'],
          equals(<String, Object?>{
            'sessionInfo': 'enrollment-session-1',
            'verificationCode': '123456',
          }),
        );
        expect(
          httpClient.requests[0].url.queryParameters['key'],
          equals('public-api-key'),
        );
        expect(
          httpClient.requests[1].url.queryParameters['key'],
          equals('public-api-key'),
        );
        expect(
          httpClient.requests[1].jsonBody['idToken'],
          equals('updated-user-id-token'),
        );
      },
    );

    test('confirm provider rejection maps to safe failure copy', () async {
      final httpClient = _RecordingHttpClient(<_FakeResponse>[
        const _FakeResponse(<String, Object?>{
          'error': <String, Object?>{'message': 'INVALID_VERIFICATION_CODE'},
        }, statusCode: 400),
      ]);
      final client = IdentityToolkitFirebaseMfaClient(
        apiKey: 'public-api-key',
        httpClient: httpClient,
      );

      final outcome = await client.confirmTotpEnrollment(
        authorizationIdToken: 'user-id-token',
        factorId: 'enrollment-session-1',
        oneTimeCode: '000000',
      );

      expect(outcome, isA<FirebaseMfaConfirmFailed>());
      final failure = outcome as FirebaseMfaConfirmFailed;
      expect(failure.code, equals('invalid_verification_code'));
      expect(failure.message, equals('Code did not match. Try again.'));
    });
  });
}

class _FakeResponse {
  const _FakeResponse(this.body, {this.statusCode = 200});

  final Map<String, Object?> body;
  final int statusCode;
}

class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this._responses);

  final List<_FakeResponse> _responses;
  final List<_RecordingHttpClientRequest> requests =
      <_RecordingHttpClientRequest>[];

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    if (_responses.isEmpty) {
      throw StateError('unexpected HTTP request: $url');
    }
    final response = _responses.removeAt(0);
    final request = _RecordingHttpClientRequest(
      url: url,
      responseBody: response.body,
      statusCode: response.statusCode,
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
