// Audit P1 (POST_HARDENING_FOLLOWUPS.md "Audit additions — 2026-05-08")
// — covers the four admin write routes wired to the
// `admin_request_idempotency` ledger:
//
//   * POST /v1/admin/integrations/oauth/{vendor}/start
//   * POST /v1/admin/integrations/{vendor}/connect-key
//   * POST /v1/admin/integrations/{vendor}/test-connection
//   * POST /v1/admin/integrations/{vendor}/disconnect
//
// Verifies:
//   1. Missing `Idempotency-Key` → 400 `missing_idempotency_key`.
//   2. Duplicate key (with completed prior response) → cached replay,
//      gateway invoked exactly once.
//   3. Distinct keys → gateway invoked once per call.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';

import '../../../tool/advisor_proxy/admin_integrations_routes.dart';
import '../../../tool/advisor_proxy/advisor_proxy.dart'
    show
        AdminIdempotencyKeyConflict,
        AdminRequestIdempotencyEntry,
        AdminRequestIdempotencyStore;

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';
const String _userId = '33333333-3333-4333-8333-333333333333';

void main() {
  group('Phase80IntegrationRoutes — Idempotency-Key guard', () {
    late _RecordingGateway gateway;
    late _FakeAdminRequestIdempotencyStore store;
    late Phase80IntegrationRoutes routes;

    setUp(() {
      gateway = _RecordingGateway();
      store = _FakeAdminRequestIdempotencyStore();
      routes = Phase80IntegrationRoutes(
        gateway: gateway,
        actorResolver: (_) async => const AdminActorContext(
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
        ),
        // Webhook handler is unused — only admin paths are exercised
        // here. Empty factories are sufficient.
        webhookHandler: InboundWebhookHandler(
          gateway: _FakeInboundWebhookGateway(),
          posAdapterFactories: const <String, PosAdapterFactory>{},
          laborAdapterFactories: const <String, LaborAdapterFactory>{},
          reservationAdapterFactories:
              const <String, ReservationAdapterFactory>{},
          signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{},
          bindingExtractor: WebhookBindingExtractor(),
        ),
        adminRequestIdempotencyStore: store,
      );
    });

    test(
      'connect-key without Idempotency-Key → 400 missing_idempotency_key; '
      'gateway never invoked',
      () async {
        final request = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/connect-key',
          ),
          bodyJson: const <String, Object?>{
            'operator_id': _operatorId,
            'location_id': _locationId,
            'api_key': 'k',
          },
          headers: const <String, String>{},
        );

        final handled = await routes.tryHandle(request);
        expect(handled, isTrue);
        expect(request.response.statusCode, 400);
        final body =
            jsonDecode(request.response.bodyText) as Map<String, Object?>;
        expect(body['error'], 'missing_idempotency_key');
        expect(gateway.connectKeyCalls, 0);
        expect(store.reserveCalls, 0);
      },
    );

    test(
      'oauth/start without Idempotency-Key → 400 missing_idempotency_key',
      () async {
        final request = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/oauth/toast/start',
          ),
          bodyJson: const <String, Object?>{
            'operator_id': _operatorId,
            'location_id': _locationId,
          },
          headers: const <String, String>{},
        );

        await routes.tryHandle(request);
        expect(request.response.statusCode, 400);
        final body =
            jsonDecode(request.response.bodyText) as Map<String, Object?>;
        expect(body['error'], 'missing_idempotency_key');
        expect(gateway.startOAuthCalls, 0);
      },
    );

    test(
      'test-connection without Idempotency-Key → 400 missing_idempotency_key',
      () async {
        final request = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/test-connection',
          ),
          bodyJson: const <String, Object?>{
            'operator_id': _operatorId,
            'location_id': _locationId,
          },
          headers: const <String, String>{},
        );

        await routes.tryHandle(request);
        expect(request.response.statusCode, 400);
        expect(gateway.testConnectionCalls, 0);
      },
    );

    test(
      'disconnect without Idempotency-Key → 400 missing_idempotency_key',
      () async {
        final request = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/disconnect',
          ),
          bodyJson: const <String, Object?>{
            'operator_id': _operatorId,
            'location_id': _locationId,
            'reason': 'qa',
          },
          headers: const <String, String>{},
        );

        await routes.tryHandle(request);
        expect(request.response.statusCode, 400);
        expect(gateway.disconnectCalls, 0);
      },
    );

    test(
      'connect-key duplicate Idempotency-Key replays cached response; '
      'gateway invoked exactly once',
      () async {
        final body = const <String, Object?>{
          'operator_id': _operatorId,
          'location_id': _locationId,
          'api_key': 'k',
        };

        final firstRequest = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/connect-key',
          ),
          bodyJson: body,
          headers: const <String, String>{'Idempotency-Key': 'idem-1'},
        );
        await routes.tryHandle(firstRequest);
        expect(firstRequest.response.statusCode, 200);
        final firstBody =
            jsonDecode(firstRequest.response.bodyText) as Map<String, Object?>;
        expect(firstBody['status'], 'connected');
        expect(gateway.connectKeyCalls, 1);
        expect(store.reserveCalls, 1);

        // Second request, same key + same body → cached replay.
        final secondRequest = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/connect-key',
          ),
          bodyJson: body,
          headers: const <String, String>{'Idempotency-Key': 'idem-1'},
        );
        await routes.tryHandle(secondRequest);
        expect(secondRequest.response.statusCode, 200);
        final secondBody =
            jsonDecode(secondRequest.response.bodyText) as Map<String, Object?>;
        expect(secondBody, equals(firstBody));
        expect(
          gateway.connectKeyCalls,
          1,
          reason: 'gateway must NOT be invoked again on cached replay',
        );
        expect(
          store.reserveCalls,
          1,
          reason: 'reserve must NOT be called again on cached replay',
        );
      },
    );

    test(
      'distinct Idempotency-Keys both reach the gateway',
      () async {
        final body = const <String, Object?>{
          'operator_id': _operatorId,
          'location_id': _locationId,
          'api_key': 'k',
        };

        final r1 = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/connect-key',
          ),
          bodyJson: body,
          headers: const <String, String>{'Idempotency-Key': 'idem-1'},
        );
        await routes.tryHandle(r1);
        expect(r1.response.statusCode, 200);

        final r2 = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/connect-key',
          ),
          bodyJson: body,
          headers: const <String, String>{'Idempotency-Key': 'idem-2'},
        );
        await routes.tryHandle(r2);
        expect(r2.response.statusCode, 200);

        expect(gateway.connectKeyCalls, 2);
        expect(store.reserveCalls, 2);
      },
    );

    test(
      'duplicate key with mismatched body → 409 idempotency_key_conflict',
      () async {
        final firstRequest = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/connect-key',
          ),
          bodyJson: const <String, Object?>{
            'operator_id': _operatorId,
            'location_id': _locationId,
            'api_key': 'k1',
          },
          headers: const <String, String>{'Idempotency-Key': 'idem-1'},
        );
        await routes.tryHandle(firstRequest);
        expect(firstRequest.response.statusCode, 200);

        final secondRequest = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/admin/integrations/toast/connect-key',
          ),
          bodyJson: const <String, Object?>{
            'operator_id': _operatorId,
            'location_id': _locationId,
            'api_key': 'k2',
          },
          headers: const <String, String>{'Idempotency-Key': 'idem-1'},
        );
        await routes.tryHandle(secondRequest);
        expect(secondRequest.response.statusCode, 409);
        final body =
            jsonDecode(secondRequest.response.bodyText) as Map<String, Object?>;
        expect(body['error'], 'idempotency_key_conflict');
      },
    );
  });
}

// ─── Test fakes ────────────────────────────────────────────────────────

class _RecordingGateway implements IntegrationRoutesGateway {
  int connectKeyCalls = 0;
  int startOAuthCalls = 0;
  int testConnectionCalls = 0;
  int disconnectCalls = 0;

  @override
  Future<bool> hasIntegrationsConfigurePermission({
    required String operatorId,
    required String userId,
  }) async => true;

  @override
  Future<Map<String, Object?>> connectViaKeyPaste({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String apiKey,
    String? username,
    String? module,
  }) async {
    connectKeyCalls += 1;
    return <String, Object?>{
      'operator_id': operatorId,
      'location_id': locationId,
      'connection_id': 'conn-${connectKeyCalls}',
      'status': 'connected',
      // Force `_withFirstBackfillStatus` into the unavailable branch
      // so the test does not need an enqueue gateway.
      'firstBackfillStarted': false,
    };
  }

  @override
  Future<Map<String, Object?>> startOAuth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    String? module,
  }) async {
    startOAuthCalls += 1;
    return <String, Object?>{
      'redirect_url': 'https://vendor.example/oauth?n=$startOAuthCalls',
    };
  }

  @override
  Future<Map<String, Object?>> testConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
  }) async {
    testConnectionCalls += 1;
    return <String, Object?>{'ok': true, 'attempt': testConnectionCalls};
  }

  @override
  Future<Map<String, Object?>> disconnect({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String reason,
  }) async {
    disconnectCalls += 1;
    return <String, Object?>{'disconnected': true};
  }

  @override
  Future<Map<String, Object?>> handleOAuthCallback({
    required String vendorId,
    required Map<String, String> queryParameters,
  }) async => throw UnimplementedError();

  @override
  Future<Map<String, Object?>> listForLocation({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async => throw UnimplementedError();

  @override
  Future<List<Map<String, Object?>>> listSyncLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async => throw UnimplementedError();
}

class _FakeAdminRequestIdempotencyStore
    implements AdminRequestIdempotencyStore {
  final Map<String, _Row> rows = <String, _Row>{};
  int reserveCalls = 0;
  int reclaimCalls = 0;
  int sweepCalls = 0;

  @override
  Future<AdminRequestIdempotencyEntry?> lookup({
    required String idempotencyKey,
    required String requestType,
    required String requestBodyHash,
  }) async {
    final row = rows[idempotencyKey];
    if (row == null) return null;
    if (row.requestType != requestType) {
      throw AdminIdempotencyKeyConflict(
        message: 'request_type mismatch: '
            'stored=${row.requestType} requested=$requestType',
      );
    }
    if (row.requestBodyHash != requestBodyHash) {
      throw const AdminIdempotencyKeyConflict(
        message: 'request_body_hash mismatch',
      );
    }
    return AdminRequestIdempotencyEntry(
      idempotencyKey: idempotencyKey,
      requestType: row.requestType,
      responseStatus: row.responseStatus,
      responsePayload: row.responsePayload,
      completedAt: row.completedAt,
      expiresAt: row.expiresAt,
    );
  }

  @override
  Future<bool> reserve({
    required String idempotencyKey,
    required String requestType,
    required String? actorUserId,
    required String requestBodyHash,
  }) async {
    reserveCalls += 1;
    if (rows.containsKey(idempotencyKey)) return false;
    rows[idempotencyKey] = _Row(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
    );
    return true;
  }

  @override
  Future<void> completeReservation({
    required String idempotencyKey,
    required int responseStatus,
    required Map<String, Object?> responsePayload,
  }) async {
    final row = rows[idempotencyKey];
    if (row == null) return;
    rows[idempotencyKey] = row.copyWith(
      responseStatus: responseStatus,
      responsePayload: responsePayload,
      completedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<bool> tryReclaimOrphan({required String idempotencyKey}) async {
    reclaimCalls += 1;
    return false;
  }

  @override
  Future<int> sweepExpiredOrphans() async {
    sweepCalls += 1;
    return 0;
  }
}

class _Row {
  _Row({
    required this.requestType,
    required this.requestBodyHash,
    required this.expiresAt,
    this.responseStatus,
    this.responsePayload,
    this.completedAt,
  });

  final String requestType;
  final String requestBodyHash;
  final DateTime? expiresAt;
  final int? responseStatus;
  final Map<String, Object?>? responsePayload;
  final DateTime? completedAt;

  _Row copyWith({
    int? responseStatus,
    Map<String, Object?>? responsePayload,
    DateTime? completedAt,
  }) {
    return _Row(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: expiresAt,
      responseStatus: responseStatus ?? this.responseStatus,
      responsePayload: responsePayload ?? this.responsePayload,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}

/// Stub gateway. Admin paths never hit it; any method call would
/// indicate a routing bug.
class _FakeInboundWebhookGateway implements InboundWebhookGateway {
  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async => throw StateError('webhook gateway must not be invoked');

  @override
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async => throw StateError('webhook gateway must not be invoked');

  @override
  Future<void> deadLetter({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payloadPreview,
    required InboundWebhookFailureKind failureKind,
    required String failureMessage,
  }) async => throw StateError('webhook gateway must not be invoked');

  @override
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async => throw StateError('webhook gateway must not be invoked');

  @override
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async => throw StateError('webhook gateway must not be invoked');

  @override
  Future<void> markProcessed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async => throw StateError('webhook gateway must not be invoked');

  @override
  Future<int> recordFailedAttempt({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String failureMessage,
    required DateTime receivedAt,
  }) async => throw StateError('webhook gateway must not be invoked');

  @override
  Future<void> recordSanityDrop({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  }) async => throw StateError('webhook gateway must not be invoked');
}

// ─── Stub HttpRequest / HttpResponse (mirrors integration_oauth_routes_test.dart)

class _StubHttpRequest extends Stream<Uint8List> implements HttpRequest {
  _StubHttpRequest({
    required this.method,
    required Uri uri,
    Map<String, Object?>? bodyJson,
    Map<String, String> headers = const <String, String>{},
  })  : _uri = uri,
        _headers = _StubHttpHeaders(headers),
        _body = bodyJson == null
            ? Uint8List(0)
            : Uint8List.fromList(utf8.encode(jsonEncode(bodyJson))),
        response = _StubHttpResponse();

  final Uri _uri;
  final HttpHeaders _headers;
  final Uint8List _body;

  @override
  final String method;

  @override
  final _StubHttpResponse response;

  @override
  HttpHeaders get headers => _headers;

  @override
  Uri get uri => _uri;

  @override
  Uri get requestedUri => _uri;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<Uint8List>.value(_body).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _StubHttpHeaders implements HttpHeaders {
  _StubHttpHeaders(this._values);
  final Map<String, String> _values;

  @override
  String? value(String name) {
    final lower = name.toLowerCase();
    for (final entry in _values.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _StubHttpResponse implements HttpResponse {
  @override
  int statusCode = 200;
  final StringBuffer _body = StringBuffer();
  final _StubResponseHeaders _headers = _StubResponseHeaders();
  String get bodyText => _body.toString();

  @override
  void write(Object? object) {
    _body.write(object);
  }

  @override
  Future<void> close() async {}

  @override
  HttpHeaders get headers => _headers;

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _StubResponseHeaders implements HttpHeaders {
  final Map<String, String> _values = <String, String>{};
  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) {
    _contentType = value;
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
