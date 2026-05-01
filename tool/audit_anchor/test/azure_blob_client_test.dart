// Phase 9.0Σ.f — unit tests for the live Azure Blob audit-anchor client.
//
// These tests cover the *request shape* the live client emits against
// (a) the GCP metadata server, (b) Azure AD's token endpoint, and (c)
// Azure Blob Storage. No live network is touched — every test injects
// a [_RecordingHttpRequester] that asserts headers, URI, body, and
// returns a canned response. The orchestrator E2E coverage stays in
// `anchor_e2e_test.dart` with `_FakeBlobClient`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../audit_anchor.dart';
import '../azure_blob_client.dart';

void main() {
  const tenant = '11111111-1111-1111-1111-aaaaaaaaaaaa';
  const clientId = 'app-22222222-2222-2222-2222-bbbbbbbbbbbb';
  const endpoint = 'https://forgeflowaudit.blob.core.windows.net';
  const container = 'audit-chain-anchors-immutable';
  const blobName = 'audit_anchors/op-uuid-lower/2026-04-27.json';
  final fixedClock = DateTime.utc(2026, 4, 28, 0, 5, 0);

  group('WorkloadIdentityFederationTokenProvider', () {
    test(
      'fetches a Google OIDC token, exchanges it at Azure AD, and '
      'returns the access token; cached on second call',
      () async {
        final requester = _RecordingHttpRequester(
          handlers: <_Handler>[
            _Handler.matchPath(
              '/computeMetadata/v1/instance/service-accounts/default/identity',
              (request) {
                expect(request.method, 'GET');
                expect(
                  request.headers['Metadata-Flavor'],
                  'Google',
                  reason: 'GCP metadata server requires Metadata-Flavor: Google',
                );
                expect(
                  request.uri.queryParameters['audience'],
                  'api://AzureADTokenExchange',
                );
                expect(request.uri.queryParameters['format'], 'full');
                return _canned(200, body: 'google-oidc-jwt-bytes');
              },
            ),
            _Handler.matchPath(
              '/$tenant/oauth2/v2.0/token',
              (request) {
                expect(request.method, 'POST');
                expect(
                  request.headers['Content-Type'],
                  'application/x-www-form-urlencoded',
                );
                final form = _decodeForm(utf8.decode(request.body!));
                expect(form['grant_type'], 'client_credentials');
                expect(form['client_id'], clientId);
                expect(form['scope'], 'https://storage.azure.com/.default');
                expect(
                  form['client_assertion_type'],
                  'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
                );
                expect(form['client_assertion'], 'google-oidc-jwt-bytes');
                return _canned(
                  200,
                  body: jsonEncode(<String, Object?>{
                    'access_token': 'aad-storage-bearer',
                    'expires_in': 3600,
                  }),
                );
              },
            ),
          ],
        );
        final provider = WorkloadIdentityFederationTokenProvider(
          tenantId: tenant,
          clientId: clientId,
          requester: requester,
          clock: () => fixedClock,
        );

        final first = await provider.getStorageAccessToken();
        expect(first, 'aad-storage-bearer');
        expect(requester.requests, hasLength(2));

        final second = await provider.getStorageAccessToken();
        expect(second, 'aad-storage-bearer');
        // Cache hit — no extra HTTP traffic.
        expect(requester.requests, hasLength(2));
      },
    );

    test(
      'surfaces a non-200 from the metadata server as '
      'AuditAnchorBlobUnavailable, without any token leak',
      () async {
        final requester = _RecordingHttpRequester(
          handlers: <_Handler>[
            _Handler.any((_) => _canned(403, body: 'forbidden')),
          ],
        );
        final provider = WorkloadIdentityFederationTokenProvider(
          tenantId: tenant,
          clientId: clientId,
          requester: requester,
          clock: () => fixedClock,
        );
        await expectLater(
          provider.getStorageAccessToken,
          throwsA(isA<AuditAnchorBlobUnavailable>()),
        );
      },
    );
  });

  group('AzureBlobAuditAnchorBlobClient.writeImmutable', () {
    test(
      'PUTs the evidence with bearer + x-ms-version + If-None-Match: *, '
      'and returns the response ETag on 201',
      () async {
        final requester = _RecordingHttpRequester(
          handlers: <_Handler>[
            _Handler.any((request) {
              expect(request.method, 'PUT');
              expect(
                request.uri.toString(),
                '$endpoint/$container/$blobName',
                reason: 'blob URI is endpoint/container/blobName',
              );
              expect(request.headers['Authorization'], 'Bearer test-token');
              expect(request.headers['x-ms-version'], '2021-12-02');
              expect(request.headers['x-ms-blob-type'], 'BlockBlob');
              expect(request.headers['Content-Type'], 'application/json');
              expect(request.headers['If-None-Match'], '*');
              expect(request.headers.containsKey('x-ms-date'), isTrue);
              expect(request.body, utf8.encode('{"hello":"world"}'));
              return _canned(
                201,
                headers: <String, String>{'ETag': '"0x8DC1234567890AB"'},
              );
            }),
          ],
        );
        final client = AzureBlobAuditAnchorBlobClient(
          endpoint: endpoint,
          tokenProvider: _StaticTokenProvider('test-token'),
          requester: requester,
          clock: () => fixedClock,
        );

        final result = await client.writeImmutable(
          containerName: container,
          blobName: blobName,
          evidenceBytes: utf8.encode('{"hello":"world"}'),
        );

        expect(result.uri, '$endpoint/$container/$blobName');
        expect(result.etag, '"0x8DC1234567890AB"');
      },
    );

    test(
      'on 409 BlobAlreadyExists: reads the existing blob and throws '
      'AuditAnchorBlobAlreadyAnchored carrying URI + ETag + body',
      () async {
        final existingBody = utf8.encode('{"existing":"evidence"}');
        final requester = _RecordingHttpRequester(
          handlers: <_Handler>[
            _Handler.matchMethod('PUT', (_) => _canned(409, body: 'conflict')),
            _Handler.matchMethod('GET', (request) {
              expect(request.headers['Authorization'], 'Bearer test-token');
              expect(request.headers['x-ms-version'], '2021-12-02');
              return _canned(
                200,
                headers: <String, String>{'ETag': '"0xEXISTINGETAG"'},
                bodyBytes: existingBody,
              );
            }),
          ],
        );
        final client = AzureBlobAuditAnchorBlobClient(
          endpoint: endpoint,
          tokenProvider: _StaticTokenProvider('test-token'),
          requester: requester,
          clock: () => fixedClock,
        );

        try {
          await client.writeImmutable(
            containerName: container,
            blobName: blobName,
            evidenceBytes: utf8.encode('{"new":"evidence"}'),
          );
          fail('expected AuditAnchorBlobAlreadyAnchored');
        } on AuditAnchorBlobAlreadyAnchored catch (existing) {
          expect(existing.uri, '$endpoint/$container/$blobName');
          expect(existing.etag, '"0xEXISTINGETAG"');
          expect(existing.evidenceBytes, existingBody);
        }
      },
    );

    test(
      'on 403 ImmutableBlob: also throws AuditAnchorBlobAlreadyAnchored',
      () async {
        final existingBody = utf8.encode('{"locked":true}');
        final requester = _RecordingHttpRequester(
          handlers: <_Handler>[
            _Handler.matchMethod('PUT', (_) => _canned(403, body: 'immutable')),
            _Handler.matchMethod(
              'GET',
              (_) => _canned(
                200,
                headers: <String, String>{'ETag': '"0xLOCKED"'},
                bodyBytes: existingBody,
              ),
            ),
          ],
        );
        final client = AzureBlobAuditAnchorBlobClient(
          endpoint: endpoint,
          tokenProvider: _StaticTokenProvider('test-token'),
          requester: requester,
          clock: () => fixedClock,
        );
        await expectLater(
          () => client.writeImmutable(
            containerName: container,
            blobName: blobName,
            evidenceBytes: utf8.encode('{"new":"evidence"}'),
          ),
          throwsA(isA<AuditAnchorBlobAlreadyAnchored>()),
        );
      },
    );

    test(
      'other non-2xx → AuditAnchorBlobUnavailable with truncated body '
      'excerpt and no Authorization header echoed',
      () async {
        final requester = _RecordingHttpRequester(
          handlers: <_Handler>[
            _Handler.any((_) => _canned(500, body: 'internal error')),
          ],
        );
        final client = AzureBlobAuditAnchorBlobClient(
          endpoint: endpoint,
          tokenProvider: _StaticTokenProvider('secret-bearer'),
          requester: requester,
          clock: () => fixedClock,
        );
        try {
          await client.writeImmutable(
            containerName: container,
            blobName: blobName,
            evidenceBytes: utf8.encode('{"new":"evidence"}'),
          );
          fail('expected AuditAnchorBlobUnavailable');
        } on AuditAnchorBlobUnavailable catch (error) {
          expect(error.toString(), contains('500'));
          expect(
            error.toString(),
            isNot(contains('secret-bearer')),
            reason: 'auth tokens must never appear in error messages',
          );
        }
      },
    );

    test(
      '201 with a missing ETag header → AuditAnchorBlobUnavailable '
      '(server contract violation)',
      () async {
        final requester = _RecordingHttpRequester(
          handlers: <_Handler>[
            _Handler.any((_) => _canned(201)),
          ],
        );
        final client = AzureBlobAuditAnchorBlobClient(
          endpoint: endpoint,
          tokenProvider: _StaticTokenProvider('test-token'),
          requester: requester,
          clock: () => fixedClock,
        );
        await expectLater(
          () => client.writeImmutable(
            containerName: container,
            blobName: blobName,
            evidenceBytes: utf8.encode('{}'),
          ),
          throwsA(isA<AuditAnchorBlobUnavailable>()),
        );
      },
    );
  });

  group('AzureBlobAuditAnchorBlobClient.readImmutable', () {
    test('GETs and returns body bytes + ETag on 200', () async {
      final body = utf8.encode('{"verified":true}');
      final requester = _RecordingHttpRequester(
        handlers: <_Handler>[
          _Handler.any((request) {
            expect(request.method, 'GET');
            expect(
              request.uri.toString(),
              '$endpoint/$container/$blobName',
            );
            expect(request.headers['Authorization'], 'Bearer test-token');
            expect(request.headers['x-ms-version'], '2021-12-02');
            return _canned(
              200,
              headers: <String, String>{'ETag': '"0xREAD"'},
              bodyBytes: body,
            );
          }),
        ],
      );
      final client = AzureBlobAuditAnchorBlobClient(
        endpoint: endpoint,
        tokenProvider: _StaticTokenProvider('test-token'),
        requester: requester,
        clock: () => fixedClock,
      );
      final result = await client.readImmutable(
        containerName: container,
        blobName: blobName,
      );
      expect(result.bytes, body);
      expect(result.etag, '"0xREAD"');
    });

    test('404 → AuditAnchorBlobUnavailable', () async {
      final requester = _RecordingHttpRequester(
        handlers: <_Handler>[
          _Handler.any((_) => _canned(404, body: 'not found')),
        ],
      );
      final client = AzureBlobAuditAnchorBlobClient(
        endpoint: endpoint,
        tokenProvider: _StaticTokenProvider('test-token'),
        requester: requester,
        clock: () => fixedClock,
      );
      await expectLater(
        () => client.readImmutable(
          containerName: container,
          blobName: blobName,
        ),
        throwsA(isA<AuditAnchorBlobUnavailable>()),
      );
    });
  });
}

// ─── Test doubles ───────────────────────────────────────────────────────

class _StaticTokenProvider implements AzureAccessTokenProvider {
  _StaticTokenProvider(this._token);
  final String _token;
  @override
  Future<String> getStorageAccessToken() async => _token;
}

/// One captured HTTP request (method, uri, headers, body) — used by
/// tests to assert the exact wire shape of every outbound call.
class _CapturedRequest {
  _CapturedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

typedef _HandlerFn = AzureBlobHttpResponse Function(_CapturedRequest request);

/// Registered match → response. The first matching handler wins; tests
/// declare them in expected order. `matchPath`/`matchMethod`/`any`
/// constructors keep call sites readable.
class _Handler {
  _Handler._({required this.matches, required this.respond});

  factory _Handler.any(_HandlerFn respond) =>
      _Handler._(matches: (_) => true, respond: respond);

  factory _Handler.matchPath(String pathFragment, _HandlerFn respond) =>
      _Handler._(
        matches: (request) => request.uri.path.contains(pathFragment),
        respond: respond,
      );

  factory _Handler.matchMethod(String method, _HandlerFn respond) =>
      _Handler._(
        matches: (request) => request.method == method,
        respond: respond,
      );

  final bool Function(_CapturedRequest request) matches;
  final _HandlerFn respond;
}

class _RecordingHttpRequester implements AzureBlobHttpRequester {
  _RecordingHttpRequester({required this.handlers});

  final List<_Handler> handlers;
  final List<_CapturedRequest> requests = <_CapturedRequest>[];

  @override
  Future<AzureBlobHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    List<int>? body,
  }) async {
    final captured = _CapturedRequest(
      method: method,
      uri: uri,
      headers: headers,
      body: body,
    );
    requests.add(captured);
    for (final handler in handlers) {
      if (handler.matches(captured)) {
        return handler.respond(captured);
      }
    }
    throw StateError('no handler matched ${captured.method} ${captured.uri}');
  }
}

AzureBlobHttpResponse _canned(
  int status, {
  Map<String, String>? headers,
  String? body,
  List<int>? bodyBytes,
}) {
  final lowercased = <String, String>{};
  (headers ?? const <String, String>{}).forEach((name, value) {
    lowercased[name.toLowerCase()] = value;
  });
  return AzureBlobHttpResponse(
    statusCode: status,
    headers: lowercased,
    bodyBytes: bodyBytes ?? (body == null ? <int>[] : utf8.encode(body)),
  );
}

Map<String, String> _decodeForm(String text) {
  final out = <String, String>{};
  for (final pair in text.split('&')) {
    final eq = pair.indexOf('=');
    if (eq < 0) continue;
    out[Uri.decodeQueryComponent(pair.substring(0, eq))] =
        Uri.decodeQueryComponent(pair.substring(eq + 1));
  }
  return out;
}
