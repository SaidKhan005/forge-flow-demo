// Phase 8 framework — production_oauth_refresh_closures_test.
//
// Coverage map (per closure shipped, per the slice prompt):
//   1. Happy refresh — fake http.Client returns 200 + token JSON; the
//      closure parses the bundle and returns a [TokenRefreshResult].
//   2. 401 — closure throws [VendorRefreshFailed] with an auth
//      diagnostic so the broker surfaces a reconnect prompt.
//   3. 5xx — closure throws [VendorRefreshFailed] with a transient
//      retry hint so the caller can defer to the next tick.
//   4. Malformed JSON — closure throws [VendorRefreshFailed] with a
//      parse diagnostic so the failure is actionable.
//
// Closures covered (11 total):
//   POS:    Toast, Square, Clover, Lightspeed LSK, Aloha NCR Voyix,
//           Oracle MICROS Simphony, Revel
//   Labor:  7shifts, QuickBooks Time, Humanity
//   Resv.:  Libro
//
// Vendors NOT covered here (their bridges do not accept an OAuth
// refresh closure — handled in the file's doc comment):
//   SevenRooms, Tock, Push Operations, Agendrix, ADP, OpenTable.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/_common/production_oauth_refresh_closures.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import '../../../tool/oauth_refresh_worker/main.dart' as worker;

VendorCredentialBundle _bundle({
  String accessToken = 'old-bearer',
  String? refreshToken = 'refresh-1',
  String? clientId = 'client-id',
  String? clientSecret = 'client-secret',
  Map<String, Object?> metadata = const <String, Object?>{},
  Map<String, Object?> connectionMetadata = const <String, Object?>{},
}) {
  return VendorCredentialBundle(
    operatorId: '11111111-2222-3333-4444-555555555555',
    locationId: '66666666-7777-8888-9999-aaaaaaaaaaaa',
    vendorId: 'test-vendor',
    accessToken: accessToken,
    refreshToken: refreshToken,
    clientId: clientId,
    clientSecret: clientSecret,
    metadata: metadata,
    connectionMetadata: connectionMetadata,
  );
}

http.Client _staticClient(http.Response response) {
  return http_testing.MockClient((http.Request _) async => response);
}

http.Client _capturedClient({
  required http.Response response,
  required void Function(http.Request) onRequest,
}) {
  return http_testing.MockClient((http.Request request) async {
    onRequest(request);
    return response;
  });
}

void main() {
  group('Toast — makeToastOauthRefreshClosure', () {
    test('happy refresh parses { token: { accessToken, expiresIn } }',
        () async {
      late http.Request seen;
      final closure = makeToastOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'token': <String, Object?>{
                'accessToken': 'fresh-toast-bearer',
                'tokenType': 'Bearer',
                'expiresIn': 3600,
              },
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        oauthBaseUri: Uri.parse('https://ws-api.toasttab.com'),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'fresh-toast-bearer');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 13));
      expect(seen.method, 'POST');
      expect(seen.url.path, '/authentication/v1/authentication/login');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['clientId'], 'client-id');
      expect(body['clientSecret'], 'client-secret');
      expect(body['userAccessType'], 'TOAST_MACHINE_CLIENT');
    });

    test('401 surfaces VendorRefreshFailed with auth diagnostic', () async {
      final closure = makeToastOauthRefreshClosure(
        httpClient: _staticClient(
          http.Response('{"message":"invalid client"}', 401),
        ),
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(
          isA<VendorRefreshFailed>().having(
            (e) => e.message,
            'message',
            allOf(contains('vendor=toast'), contains('auth_rejected')),
          ),
        ),
      );
    });

    test('5xx surfaces VendorRefreshFailed with retry hint', () async {
      final closure = makeToastOauthRefreshClosure(
        httpClient: _staticClient(http.Response('boom', 502)),
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(
          isA<VendorRefreshFailed>().having(
            (e) => e.message,
            'message',
            allOf(contains('vendor=toast'), contains('vendor_5xx')),
          ),
        ),
      );
    });

    test('malformed JSON surfaces VendorRefreshFailed with parse diag',
        () async {
      final closure = makeToastOauthRefreshClosure(
        httpClient: _staticClient(http.Response('not-json', 200)),
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(
          isA<VendorRefreshFailed>().having(
            (e) => e.message,
            'message',
            allOf(contains('vendor=toast'), contains('malformed_json')),
          ),
        ),
      );
    });
  });

  group('Square — makeSquareOauthRefreshClosure', () {
    test('happy refresh threads new refresh_token + expires_at + merchant_id',
        () async {
      late http.Request seen;
      final closure = makeSquareOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'sq-access',
              'refresh_token': 'sq-refresh-2',
              'expires_at': '2026-12-31T23:59:59Z',
              'merchant_id': 'mch_42',
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clientId: 'square-client-id',
        clientSecret: 'square-client-secret',
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'sq-access');
      expect(result.refreshToken, 'sq-refresh-2');
      expect(result.expiresAt, DateTime.utc(2026, 12, 31, 23, 59, 59));
      expect(result.metadataPatch?['merchant_id'], 'mch_42');
      expect(seen.url.path, '/oauth2/token');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'refresh-1');
      expect(body['client_id'], 'square-client-id');
      expect(body['client_secret'], 'square-client-secret');
    });

    test('401 surfaces VendorRefreshFailed', () async {
      final closure = makeSquareOauthRefreshClosure(
        httpClient: _staticClient(http.Response('unauth', 401)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          allOf(contains('vendor=square'), contains('auth_rejected')),
        )),
      );
    });

    test('500 surfaces VendorRefreshFailed', () async {
      final closure = makeSquareOauthRefreshClosure(
        httpClient: _staticClient(http.Response('oops', 500)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
    });

    test('malformed JSON', () async {
      final closure = makeSquareOauthRefreshClosure(
        httpClient: _staticClient(http.Response('<<<', 200)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group('Clover — makeCloverOauthRefreshClosure', () {
    test('happy refresh', () async {
      late http.Request seen;
      final closure = makeCloverOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'clover-access',
              'refresh_token': 'clover-refresh-2',
              'access_token_expiration': '2026-12-31T23:59:59Z',
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clientId: 'CLOVER_APP_ID',
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'clover-access');
      expect(result.refreshToken, 'clover-refresh-2');
      expect(result.expiresAt, DateTime.utc(2026, 12, 31, 23, 59, 59));
      expect(seen.url.path, '/oauth/v2/refresh');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['client_id'], 'CLOVER_APP_ID');
      expect(body['refresh_token'], 'refresh-1');
    });

    test('401 / 5xx / malformed surface VendorRefreshFailed', () async {
      final c401 = makeCloverOauthRefreshClosure(
        httpClient: _staticClient(http.Response('no', 401)),
        clientId: 'cid',
      );
      await expectLater(
        () => c401(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeCloverOauthRefreshClosure(
        httpClient: _staticClient(http.Response('boom', 503)),
        clientId: 'cid',
      );
      await expectLater(
        () => c5xx(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeCloverOauthRefreshClosure(
        httpClient: _staticClient(http.Response('not-json', 200)),
        clientId: 'cid',
      );
      await expectLater(
        () => cBad(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });

    test('missing refresh token — actionable diagnostic', () async {
      final closure = makeCloverOauthRefreshClosure(
        httpClient: _staticClient(http.Response('ok', 200)),
        clientId: 'cid',
      );
      await expectLater(
        () => closure(_bundle(refreshToken: null)),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('missing_refresh_token'),
        )),
      );
    });
  });

  group('Lightspeed LSK — makeLightspeedLskOauthRefreshClosure', () {
    test('happy refresh emits form body and parses expires_in', () async {
      late http.Request seen;
      final closure = makeLightspeedLskOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'lsk-access',
              'refresh_token': 'lsk-refresh-2',
              'expires_in': 1800,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'lsk-access');
      expect(result.refreshToken, 'lsk-refresh-2');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 12, 30));
      expect(seen.url.path, '/oauth/token');
      expect(seen.headers['content-type'],
          contains('application/x-www-form-urlencoded'));
      // Form bodies are urlencoded; validate the key tokens are present.
      expect(seen.body, contains('grant_type=refresh_token'));
      expect(seen.body, contains('refresh_token=refresh-1'));
      expect(seen.body, contains('client_id=client-id'));
    });

    test('401', () async {
      final closure = makeLightspeedLskOauthRefreshClosure(
        httpClient: _staticClient(http.Response('no', 401)),
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
    });

    test('5xx', () async {
      final closure = makeLightspeedLskOauthRefreshClosure(
        httpClient: _staticClient(http.Response('oops', 502)),
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
    });

    test('malformed JSON', () async {
      final closure = makeLightspeedLskOauthRefreshClosure(
        httpClient: _staticClient(http.Response('}', 200)),
      );
      await expectLater(
        () => closure(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group('Aloha NCR Voyix — makeAlohaNcrVoyixOauthRefreshClosure', () {
    test('happy refresh sets Basic auth + nep headers', () async {
      late http.Request seen;
      final closure = makeAlohaNcrVoyixOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'aloha-access',
              'expires_in': 3600,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        scope: 'pos.orders',
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle(metadata: <String, Object?>{
        'application_key': 'nep-app-key-1',
        'organization_id': 'nep-org-1',
      }));
      expect(result.accessToken, 'aloha-access');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 13));
      expect(seen.url.path, '/security/v1/oauth/token');
      expect(seen.headers['authorization'], startsWith('Basic '));
      expect(seen.headers['nep-application-key'], 'nep-app-key-1');
      expect(seen.headers['nep-organization'], 'nep-org-1');
      expect(seen.body, contains('grant_type=client_credentials'));
      expect(seen.body, contains('scope=pos.orders'));
    });

    test('missing application_key surfaces actionable diagnostic',
        () async {
      final closure = makeAlohaNcrVoyixOauthRefreshClosure(
        httpClient: _staticClient(http.Response('ok', 200)),
      );
      await expectLater(
        () => closure(_bundle(metadata: const <String, Object?>{
          'organization_id': 'nep-org-1',
        })),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('application_key'),
        )),
      );
    });

    test('401 / 5xx / malformed', () async {
      final c401 = makeAlohaNcrVoyixOauthRefreshClosure(
        httpClient: _staticClient(http.Response('nope', 401)),
      );
      final bad = _bundle(metadata: const <String, Object?>{
        'application_key': 'k',
        'organization_id': 'o',
      });
      await expectLater(
        () => c401(bad),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeAlohaNcrVoyixOauthRefreshClosure(
        httpClient: _staticClient(http.Response('boom', 503)),
      );
      await expectLater(
        () => c5xx(bad),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeAlohaNcrVoyixOauthRefreshClosure(
        httpClient: _staticClient(http.Response('not-json', 200)),
      );
      await expectLater(
        () => cBad(bad),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group(
      'Oracle MICROS Simphony — makeOracleMicrosSimphonyOauthExchangeClosure',
      () {
    test('happy refresh', () async {
      late http.Request seen;
      final closure = makeOracleMicrosSimphonyOauthExchangeClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'sim-access',
              'expires_in': 3600,
              'token_type': 'Bearer',
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'sim-access');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 13));
      expect(seen.url.path, '/sim/api/v2/oauth/token');
      expect(seen.headers['authorization'], startsWith('Basic '));
      expect(seen.body, contains('grant_type=client_credentials'));
    });

    test('401 / 5xx / malformed', () async {
      final c401 = makeOracleMicrosSimphonyOauthExchangeClosure(
        httpClient: _staticClient(http.Response('no', 401)),
      );
      await expectLater(
        () => c401(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeOracleMicrosSimphonyOauthExchangeClosure(
        httpClient: _staticClient(http.Response('oops', 500)),
      );
      await expectLater(
        () => c5xx(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeOracleMicrosSimphonyOauthExchangeClosure(
        httpClient: _staticClient(http.Response('}', 200)),
      );
      await expectLater(
        () => cBad(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group('Revel — makeRevelOauthExchangeClosure', () {
    test('happy refresh', () async {
      late http.Request seen;
      final closure = makeRevelOauthExchangeClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'revel-jwt',
              'expires_in': 86400,
              'token_type': 'Bearer',
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        audience: 'https://api.revelup.com',
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'revel-jwt');
      expect(result.expiresAt, DateTime.utc(2026, 5, 7, 12));
      expect(seen.url.toString(),
          'https://authentication.revelup.com/oauth/token');
      expect(seen.body, contains('audience=https'));
      expect(seen.body, contains('grant_type=client_credentials'));
    });

    test('401 / 5xx / malformed', () async {
      final c401 = makeRevelOauthExchangeClosure(
        httpClient: _staticClient(http.Response('no', 401)),
        audience: 'aud',
      );
      await expectLater(
        () => c401(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeRevelOauthExchangeClosure(
        httpClient: _staticClient(http.Response('boom', 502)),
        audience: 'aud',
      );
      await expectLater(
        () => c5xx(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeRevelOauthExchangeClosure(
        httpClient: _staticClient(http.Response('}', 200)),
        audience: 'aud',
      );
      await expectLater(
        () => cBad(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group('7shifts — makeSevenShiftsOauthRefreshClosure', () {
    test('happy refresh threads rotated refresh_token', () async {
      late http.Request seen;
      final closure = makeSevenShiftsOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': '7s-access',
              'refresh_token': '7s-refresh-2',
              'expires_in': 7200,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clientId: 'sevenshifts-client',
        clientSecret: 'sevenshifts-secret',
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, '7s-access');
      expect(result.refreshToken, '7s-refresh-2');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 14));
      expect(seen.url.toString(), 'https://api.7shifts.com/v2/oauth/token');
    });

    test('401 / 5xx / malformed', () async {
      final c401 = makeSevenShiftsOauthRefreshClosure(
        httpClient: _staticClient(http.Response('no', 401)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c401(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeSevenShiftsOauthRefreshClosure(
        httpClient: _staticClient(http.Response('boom', 503)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c5xx(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeSevenShiftsOauthRefreshClosure(
        httpClient: _staticClient(http.Response('}', 200)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => cBad(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group('QuickBooks Time — makeQuickBooksTimeOauthRefreshClosure', () {
    test('happy refresh sets Basic auth on Intuit endpoint', () async {
      late http.Request seen;
      final closure = makeQuickBooksTimeOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'intuit-access',
              'refresh_token': 'intuit-refresh-2',
              'expires_in': 3600,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clientId: 'intuit-client',
        clientSecret: 'intuit-secret',
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'intuit-access');
      expect(result.refreshToken, 'intuit-refresh-2');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 13));
      expect(seen.url.host, 'oauth.platform.intuit.com');
      expect(seen.headers['authorization'], startsWith('Basic '));
      expect(seen.body, contains('grant_type=refresh_token'));
      expect(seen.body, contains('refresh_token=refresh-1'));
    });

    test('401 / 5xx / malformed', () async {
      final c401 = makeQuickBooksTimeOauthRefreshClosure(
        httpClient: _staticClient(http.Response('no', 401)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c401(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeQuickBooksTimeOauthRefreshClosure(
        httpClient: _staticClient(http.Response('oops', 500)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c5xx(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeQuickBooksTimeOauthRefreshClosure(
        httpClient: _staticClient(http.Response('}', 200)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => cBad(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group('Libro — makeLibroOauthRefreshClosure', () {
    test('happy refresh posts JSON body to /v1/oauth/refresh', () async {
      late http.Request seen;
      final closure = makeLibroOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'libro-access',
              'refresh_token': 'libro-refresh-2',
              'expires_in': 1800,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clientId: 'libro-client',
        clientSecret: 'libro-secret',
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'libro-access');
      expect(result.refreshToken, 'libro-refresh-2');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 12, 30));
      expect(seen.url.path, '/v1/oauth/refresh');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'refresh-1');
      expect(body['client_id'], 'libro-client');
      expect(body['client_secret'], 'libro-secret');
    });

    test('401 / 5xx / malformed', () async {
      final c401 = makeLibroOauthRefreshClosure(
        httpClient: _staticClient(http.Response('no', 401)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c401(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeLibroOauthRefreshClosure(
        httpClient: _staticClient(http.Response('boom', 504)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c5xx(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeLibroOauthRefreshClosure(
        httpClient: _staticClient(http.Response('not-json', 200)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => cBad(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  group('Humanity — makeHumanityOauthRefreshClosure', () {
    test('happy refresh', () async {
      late http.Request seen;
      final closure = makeHumanityOauthRefreshClosure(
        httpClient: _capturedClient(
          response: http.Response(
            jsonEncode(<String, Object?>{
              'access_token': 'humanity-access',
              'refresh_token': 'humanity-refresh-2',
              'expires_in': 3600,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          ),
          onRequest: (request) => seen = request,
        ),
        clientId: 'humanity-client',
        clientSecret: 'humanity-secret',
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final result = await closure(_bundle());
      expect(result.accessToken, 'humanity-access');
      expect(result.refreshToken, 'humanity-refresh-2');
      expect(result.expiresAt, DateTime.utc(2026, 5, 6, 13));
      expect(seen.url.host, 'platform.humanity.com');
      expect(seen.body, contains('grant_type=refresh_token'));
    });

    test('401 / 5xx / malformed', () async {
      final c401 = makeHumanityOauthRefreshClosure(
        httpClient: _staticClient(http.Response('no', 401)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c401(_bundle()),
        throwsA(isA<VendorRefreshFailed>()),
      );
      final c5xx = makeHumanityOauthRefreshClosure(
        httpClient: _staticClient(http.Response('oops', 502)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => c5xx(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('vendor_5xx'),
        )),
      );
      final cBad = makeHumanityOauthRefreshClosure(
        httpClient: _staticClient(http.Response('not-json', 200)),
        clientId: 'cid',
        clientSecret: 'csec',
      );
      await expectLater(
        () => cBad(_bundle()),
        throwsA(isA<VendorRefreshFailed>().having(
          (e) => e.message,
          'message',
          contains('malformed_json'),
        )),
      );
    });
  });

  // ─── Closure registry / no-closure delegation ───────────────────────
  //
  // Phase 5 pressure-preview findings (P1) called out four mismatches
  // in the vendor closure registry:
  //
  //   * ADP — adapter declares `oauth`; rotation actually happens via
  //     ADP partner-ops mTLS out-of-band. No broker closure was wired.
  //   * OpenTable — adapter declares `oauth`; rotation happens
  //     INTERNALLY via `OpenTableTransport.refresh` (the production-api
  //     -client's transport class owns the rotation). No broker closure
  //     was wired.
  //   * SevenRooms — adapter declares `oauthOrKeyPaste`; rotation
  //     happens via a transport-layer cron at hour:05. No broker
  //     closure was wired.
  //   * Humanity — adapter declares `keyPaste`; a closure existed in
  //     the worker registry but the adapter doesn't drive a
  //     broker-refresh path. Inverse mismatch.
  //
  // Resolution per the slice: ADP, OpenTable, SevenRooms, and Humanity
  // each land on `kVendorsWithoutRefreshClosureReason` with a
  // documented delegation reason. Agendrix likewise gets a reason
  // entry to reflect that its OAuth sliding-refresh closure factory is
  // not yet wired (no parallel stack — re-wire when the closure
  // factory ships).
  group('closure registry: documented delegation surfaces', () {
    test(
      'ADP / OpenTable / SevenRooms / Humanity each carry a documented '
      'delegation reason and are NOT in the production registry',
      () {
        final result = worker.buildProductionRefreshClosures(
          env: const <String, String>{},
          httpClient: _NoopRegistryHttpClient(),
        );
        const expectedDelegations = <String, String>{
          'adp': 'adp_partner_ops_mtls_out_of_band',
          'opentable': 'opentable_transport_internal_refresh',
          'sevenrooms': 'sevenrooms_transport_cron_hour05',
          'humanity': 'humanity_keypaste_password_grant_no_broker_refresh',
          'agendrix': 'agendrix_oauth_sliding_refresh_not_yet_wired',
          'tock': 'tock_static_api_key',
          'push_operations': 'push_operations_partner_issued_bearer',
        };
        for (final entry in expectedDelegations.entries) {
          expect(
            worker.kVendorsWithoutRefreshClosureReason[entry.key],
            equals(entry.value),
            reason:
                '${entry.key} must declare reason "${entry.value}" so the '
                'boot log + per-row skip log surface a stable, '
                'queryable label',
          );
          expect(
            result.registry.containsKey(entry.key),
            isFalse,
            reason:
                '${entry.key} must NOT be in the production registry — '
                'rotation is delegated to the surface named by the reason',
          );
          expect(
            worker.kVendorsWithoutRefreshClosure.contains(entry.key),
            isTrue,
            reason: '${entry.key} must be in kVendorsWithoutRefreshClosure',
          );
        }
      },
    );

    test(
      'Humanity factory remains exported for future re-wiring even '
      'though the registry no longer mounts it',
      () {
        // The factory is still importable + invocable so the closure-
        // shape unit tests (above) keep coverage. If Humanity ships an
        // OAuth v2 program the registry can re-wire without an API
        // change.
        final closure = makeHumanityOauthRefreshClosure(
          httpClient: _NoopRegistryHttpClient(),
          clientId: 'cid',
          clientSecret: 'csec',
        );
        expect(closure, isNotNull);
        // But Humanity is decisively excluded from the wired registry.
        final result = worker.buildProductionRefreshClosures(
          env: const <String, String>{
            // Even with secrets present, Humanity must NOT register —
            // the registry no longer reads HUMANITY_CLIENT_ID /
            // HUMANITY_CLIENT_SECRET.
            'HUMANITY_CLIENT_ID': 'hum-id',
            'HUMANITY_CLIENT_SECRET': 'hum-secret',
          },
          httpClient: _NoopRegistryHttpClient(),
        );
        expect(result.registry.containsKey('humanity'), isFalse);
        expect(result.disabledVendorIds.containsKey('humanity'), isFalse,
            reason:
                'Humanity must not appear on the disabled-missing-secrets '
                'list — it is unconditionally excluded, not gated');
      },
    );
  });
}

/// Minimal [http.Client] stub for registry-shape tests. The closure
/// factories construct closures (deferred network calls) at build
/// time; the stubbed Client is never actually invoked.
class _NoopRegistryHttpClient implements http.Client {
  @override
  void close() {}

  @override
  noSuchMethod(Invocation invocation) {
    throw StateError(
      '_NoopRegistryHttpClient.${invocation.memberName} called; closure '
      'builders should not perform live HTTP requests during registry-shape '
      'tests',
    );
  }
}
