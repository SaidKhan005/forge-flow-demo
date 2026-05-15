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
      'confirm TOTP reads factor id from finalize response — no accounts:lookup',
      () async {
        // CODE_HEALTH L11 race fix: the finalize response itself carries
        // the freshly-enrolled factor. Reading from the response avoids the
        // parallel-enrollment race in `accounts:lookup` (which could return
        // a sibling factor's id when two enrollments race).
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'idToken': 'updated-user-id-token',
            'refreshToken': 'updated-refresh-token',
            'mfaInfo': <Object?>[
              <String, Object?>{
                'mfaEnrollmentId': 'new-totp-factor',
                'displayName': 'Forge & Flow',
                'enrolledAt': '2026-04-28T12:01:00Z',
                'totpInfo': <String, Object?>{},
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

        // Critical assertion for the race fix: NO accounts:lookup call.
        expect(
          httpClient.requests.map((request) => request.url.path),
          equals(<String>['/v2/accounts/mfaEnrollment:finalize']),
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
      },
    );

    test(
      'confirm TOTP falls back to accounts:lookup when finalize body omits factor',
      () async {
        // Defensive fallback path: REST shape drift / partial response that
        // does not carry the enrolled factor. Exactly ONE lookup call.
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

        // Exactly one fallback lookup.
        expect(
          httpClient.requests.map((request) => request.url.path),
          equals(<String>[
            '/v2/accounts/mfaEnrollment:finalize',
            '/v1/accounts:lookup',
          ]),
        );
        expect(
          httpClient.requests[1].jsonBody['idToken'],
          equals('updated-user-id-token'),
        );
      },
    );

    test(
      'confirm TOTP reads top-level mfaEnrollmentId when present',
      () async {
        // Some Identity Toolkit response variants surface the new factor id
        // at the top level rather than inside `mfaInfo`.
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'idToken': 'updated-user-id-token',
            'refreshToken': 'updated-refresh-token',
            'mfaEnrollmentId': 'top-level-factor',
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
        );

        expect(outcome, isA<FirebaseMfaConfirmSucceeded>());
        expect(
          (outcome as FirebaseMfaConfirmSucceeded)
              .factorMetadata['firebase_factor_uid'],
          equals('top-level-factor'),
        );
        // No fallback lookup.
        expect(httpClient.requests, hasLength(1));
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

    test(
      'begin enrollment 400 INVALID_ID_TOKEN propagates typed error verbatim',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'error': <String, Object?>{'message': 'INVALID_ID_TOKEN'},
          }, statusCode: 400),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final error = await _captureError(
          client.beginTotpEnrollment(
            authorizationIdToken: 'expired-id-token',
            userId: 'user-1',
            userEmail: 'owner@example.test',
            issuerName: 'Forge & Flow',
          ),
        );

        expect(error, isA<IdentityToolkitFirebaseMfaError>());
        final firebaseError = error! as IdentityToolkitFirebaseMfaError;
        expect(firebaseError.code, equals('invalid_id_token'));
        expect(firebaseError.statusCode, equals(400));
        expect(httpClient.requests, hasLength(1));
      },
    );

    test(
      'begin enrollment 500 makes a single HTTP attempt (no retry)',
      () async {
        // Only one fake response is queued; if the production adapter retried,
        // the second postUrl would throw StateError from _RecordingHttpClient.
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'error': <String, Object?>{'message': 'INTERNAL'},
          }, statusCode: 500),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final error = await _captureError(
          client.beginTotpEnrollment(
            authorizationIdToken: 'user-id-token',
            userId: 'user-1',
            userEmail: 'owner@example.test',
            issuerName: 'Forge & Flow',
          ),
        );

        expect(error, isA<IdentityToolkitFirebaseMfaError>());
        expect(
          (error! as IdentityToolkitFirebaseMfaError).statusCode,
          equals(500),
        );
        expect(httpClient.requests, hasLength(1));
      },
    );

    test(
      'begin enrollment empty error body falls back to generic code',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{}, statusCode: 503),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final error = await _captureError(
          client.beginTotpEnrollment(
            authorizationIdToken: 'user-id-token',
            userId: 'user-1',
            userEmail: 'owner@example.test',
            issuerName: 'Forge & Flow',
          ),
        );

        expect(error, isA<IdentityToolkitFirebaseMfaError>());
        final firebaseError = error! as IdentityToolkitFirebaseMfaError;
        expect(
          firebaseError.code,
          equals('identitytoolkit_mfa_request_failed'),
        );
        expect(firebaseError.statusCode, equals(503));
      },
    );

    test(
      'confirm enrollment 429 TOO_MANY_ATTEMPTS_TRY_LATER maps to stable code',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'error': <String, Object?>{
              'message': 'TOO_MANY_ATTEMPTS_TRY_LATER',
            },
          }, statusCode: 429),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final outcome = await client.confirmTotpEnrollment(
          authorizationIdToken: 'user-id-token',
          factorId: 'enrollment-session-1',
          oneTimeCode: '654321',
        );

        expect(outcome, isA<FirebaseMfaConfirmFailed>());
        final failure = outcome as FirebaseMfaConfirmFailed;
        expect(failure.code, equals('too_many_attempts_try_later'));
        expect(
          failure.message,
          equals('Two-factor sign-in setup failed. Please try again.'),
        );
      },
    );

    test(
      'confirm enrollment SECOND_FACTOR_EXISTS surfaces stable code path',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'error': <String, Object?>{'message': 'SECOND_FACTOR_EXISTS'},
          }, statusCode: 400),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final outcome = await client.confirmTotpEnrollment(
          authorizationIdToken: 'user-id-token',
          factorId: 'enrollment-session-1',
          oneTimeCode: '123456',
        );

        expect(outcome, isA<FirebaseMfaConfirmFailed>());
        expect(
          (outcome as FirebaseMfaConfirmFailed).code,
          equals('second_factor_exists'),
        );
      },
    );

    test(
      'confirm enrollment with missing idToken in finalize body returns safe failure',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{}),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final outcome = await client.confirmTotpEnrollment(
          authorizationIdToken: 'user-id-token',
          factorId: 'enrollment-session-1',
          oneTimeCode: '123456',
        );

        expect(outcome, isA<FirebaseMfaConfirmFailed>());
        final failure = outcome as FirebaseMfaConfirmFailed;
        expect(failure.code, equals('mfa_finalize_missing_id_token'));
        expect(
          failure.message,
          equals('Two-factor sign-in could not be verified. Please try again.'),
        );
        // Lookup must not run when finalize did not return a fresh idToken.
        expect(httpClient.requests, hasLength(1));
      },
    );

    test(
      'confirm enrollment with no TOTP in lookup returns mfa_lookup_missing_totp',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{'idToken': 'updated-token'}),
          const _FakeResponse(<String, Object?>{
            'users': <Object?>[
              <String, Object?>{
                'localId': 'user-1',
                'mfaInfo': <Object?>[
                  // SMS factor only — no totpInfo key.
                  <String, Object?>{
                    'mfaEnrollmentId': 'sms-1',
                    'enrolledAt': '2026-04-30T12:00:00Z',
                    'phoneInfo': <String, Object?>{},
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
        );

        expect(outcome, isA<FirebaseMfaConfirmFailed>());
        final failure = outcome as FirebaseMfaConfirmFailed;
        expect(failure.code, equals('mfa_lookup_missing_totp'));
      },
    );

    test('listTotpFactors filters non-TOTP factors and parses fields', () async {
      final httpClient = _RecordingHttpClient(<_FakeResponse>[
        const _FakeResponse(<String, Object?>{
          'users': <Object?>[
            <String, Object?>{
              'localId': 'user-1',
              'mfaInfo': <Object?>[
                <String, Object?>{
                  'mfaEnrollmentId': 'totp-1',
                  'displayName': 'Forge & Flow',
                  'enrolledAt': '2026-04-30T12:00:00Z',
                  'totpInfo': <String, Object?>{},
                },
                <String, Object?>{
                  'mfaEnrollmentId': 'sms-1',
                  'enrolledAt': '2026-04-29T12:00:00Z',
                  'phoneInfo': <String, Object?>{},
                },
                // Missing mfaEnrollmentId — dropped.
                <String, Object?>{'totpInfo': <String, Object?>{}},
                'not-a-map',
              ],
            },
          ],
        }),
      ]);
      final client = IdentityToolkitFirebaseMfaClient(
        apiKey: 'public-api-key',
        httpClient: httpClient,
      );

      final factors = await client.listTotpFactors(
        authorizationIdToken: 'user-id-token',
        userId: 'user-1',
      );

      expect(factors, hasLength(1));
      expect(factors.single.factorId, equals('totp-1'));
      expect(factors.single.displayName, equals('Forge & Flow'));
      expect(
        factors.single.enrolledAt.toIso8601String(),
        equals('2026-04-30T12:00:00.000Z'),
      );
      expect(
        () => factors.add(
          FirebaseMfaTotpFactor(
            factorId: 'mutated',
            enrolledAt: DateTime.utc(2026),
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        httpClient.requests.single.url.path,
        equals('/v1/accounts:lookup'),
      );
    });

    test('listTotpFactors with empty users returns empty list', () async {
      final httpClient = _RecordingHttpClient(<_FakeResponse>[
        const _FakeResponse(<String, Object?>{'users': <Object?>[]}),
      ]);
      final client = IdentityToolkitFirebaseMfaClient(
        apiKey: 'public-api-key',
        httpClient: httpClient,
      );

      final factors = await client.listTotpFactors(
        authorizationIdToken: 'user-id-token',
        userId: 'user-1',
      );

      expect(factors, isEmpty);
    });

    test('unenrollFactor posts mfaEnrollmentId and idToken verbatim', () async {
      final httpClient = _RecordingHttpClient(<_FakeResponse>[
        const _FakeResponse(<String, Object?>{}),
      ]);
      final client = IdentityToolkitFirebaseMfaClient(
        apiKey: 'public-api-key',
        httpClient: httpClient,
      );

      await client.unenrollFactor(
        authorizationIdToken: 'user-id-token',
        userId: 'user-1',
        factorId: 'totp-to-revoke',
      );

      // ignore: close_sinks - fake request was already closed by the client.
      final request = httpClient.requests.single;
      expect(
        request.url.path,
        equals('/v2/accounts/mfaEnrollment:withdraw'),
      );
      expect(
        request.url.queryParameters['key'],
        equals('public-api-key'),
      );
      expect(request.jsonBody['idToken'], equals('user-id-token'));
      expect(
        request.jsonBody['mfaEnrollmentId'],
        equals('totp-to-revoke'),
      );
      // No extra keys leaked into the request body.
      expect(request.jsonBody.length, equals(2));
    });

    test(
      'unenrollFactor 400 propagates IdentityToolkitFirebaseMfaError',
      () async {
        final httpClient = _RecordingHttpClient(<_FakeResponse>[
          const _FakeResponse(<String, Object?>{
            'error': <String, Object?>{'message': 'INVALID_ID_TOKEN'},
          }, statusCode: 400),
        ]);
        final client = IdentityToolkitFirebaseMfaClient(
          apiKey: 'public-api-key',
          httpClient: httpClient,
        );

        final error = await _captureError(
          client.unenrollFactor(
            authorizationIdToken: 'expired-id-token',
            userId: 'user-1',
            factorId: 'totp-to-revoke',
          ),
        );

        expect(error, isA<IdentityToolkitFirebaseMfaError>());
        final firebaseError = error! as IdentityToolkitFirebaseMfaError;
        expect(firebaseError.code, equals('invalid_id_token'));
        expect(firebaseError.statusCode, equals(400));
      },
    );

    test('every request sets Content-Type: application/json', () async {
      final httpClient = _RecordingHttpClient(<_FakeResponse>[
        const _FakeResponse(<String, Object?>{'users': <Object?>[]}),
      ]);
      final client = IdentityToolkitFirebaseMfaClient(
        apiKey: 'public-api-key',
        httpClient: httpClient,
      );

      await client.listTotpFactors(
        authorizationIdToken: 'user-id-token',
        userId: 'user-1',
      );

      final contentType = httpClient.requests.single.headers.contentType;
      expect(contentType, isNotNull);
      expect(contentType!.mimeType, equals('application/json'));
    });
  });
}

Future<Object?> _captureError(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
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
