// P0 fix (2026-05-09 webhook-signature triage Section 5.F.3) —
// admin-integrations response sanitization tests.
//
// Drives the `_handleWebhook` path through a gateway that throws a
// Postgres-shaped exception (`relation "public.vendor_credentials"
// does not exist (42P01)`) and asserts:
//
//   * The response body JSON does NOT contain any of the leak
//     markers from the triage doc (SQLSTATE codes, internal
//     relation/column names, vendor exception class names, severity
//     labels, stack frame markers).
//   * The response body JSON DOES contain a non-empty `error_id`
//     field so operators can correlate the failure with the
//     structured-log breadcrumb.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

import '../../../tool/advisor_proxy/admin_integrations_routes.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';
const String _userId = '33333333-3333-4333-8333-333333333333';

Phase80IntegrationRoutes _buildRoutes(
  _ThrowingInboundWebhookGateway gateway,
) {
  final webhookHandler = InboundWebhookHandler(
    gateway: gateway,
    posAdapterFactories: <String, PosAdapterFactory>{
      'lightspeed_lsk':
          ({required operatorId, required locationId}) async =>
              _NoopPosAdapter(),
    },
    laborAdapterFactories: const <String, LaborAdapterFactory>{},
    reservationAdapterFactories:
        const <String, ReservationAdapterFactory>{},
    signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{
      'lightspeed_lsk': _NoopVerifier(),
    },
    bindingExtractor: WebhookBindingExtractor(),
  );
  return Phase80IntegrationRoutes(
    gateway: _UnusedRoutesGateway(),
    actorResolver: (_) async => const AdminActorContext(
      operatorId: _operatorId,
      locationId: _locationId,
      userId: _userId,
    ),
    webhookHandler: webhookHandler,
  );
}

void main() {
  group('Phase80IntegrationRoutes — response sanitization', () {
    late _ThrowingInboundWebhookGateway gateway;
    late Phase80IntegrationRoutes routes;

    setUp(() {
      gateway = _ThrowingInboundWebhookGateway(
        throwOnLookupSigningSecret: const _PostgresShapedException(
          'relation "public.vendor_credentials" does not exist',
          'Severity.error',
          '42P01',
        ),
      );
      routes = _buildRoutes(gateway);
    });

    test(
      'webhook 500 path: response body redacts internal exception '
      'details and includes error_id',
      () async {

        final request = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/webhooks/lightspeed_lsk/$_operatorId/$_locationId',
          ),
          bodyJson: const <String, Object?>{
            'event_id': 'evt-sanitize',
            'business_id': 'lsk-biz-7c2f',
          },
          headers: const <String, String>{},
        );

        final handled = await routes.tryHandle(request);
        expect(handled, isTrue);
        expect(request.response.statusCode, 500,
            reason:
                'gateway throw must surface as a sanitized 500 from '
                'the webhook dispatch wrapper');

        final bodyText = request.response.bodyText;
        // The leak markers from the triage Section 5.F.3 list MUST
        // NOT appear anywhere in the response body.
        const forbiddenMarkers = <String>[
          '42P01', // relation_does_not_exist
          '42703', // column_does_not_exist
          'DependencyTimeoutException',
          'StackTrace',
          'Severity.',
          'relation "public.',
          'column op.',
        ];
        for (final marker in forbiddenMarkers) {
          expect(
            bodyText.contains(marker),
            isFalse,
            reason: 'response body must not leak "$marker" '
                '(triage doc Section 5.F.3 forbidden markers list); '
                'body was: $bodyText',
          );
        }

        // The error_id field must be present and non-empty so the
        // operator can correlate the failure with the structured log.
        final body = jsonDecode(bodyText) as Map<String, Object?>;
        expect(body.containsKey('error_id'), isTrue,
            reason: 'sanitized error envelope must include error_id');
        final errorId = body['error_id'];
        expect(errorId, isA<String>());
        expect((errorId! as String).length, greaterThan(8),
            reason: 'error_id must be a non-trivial correlation token');
        expect(body['message'], 'internal_server_error',
            reason: 'message field must be a generic placeholder, '
                'never the underlying exception text');
      },
    );

    test(
      'webhook 500 path: returns adapterError outcome label for '
      'the dispatch wrapper catch',
      () async {
        final request = _StubHttpRequest(
          method: 'POST',
          uri: Uri.parse(
            'http://localhost/v1/webhooks/lightspeed_lsk/$_operatorId/$_locationId',
          ),
          bodyJson: const <String, Object?>{
            'event_id': 'evt-sanitize-2',
          },
          headers: const <String, String>{},
        );
        await routes.tryHandle(request);
        expect(request.response.statusCode, 500);
        final body =
            jsonDecode(request.response.bodyText) as Map<String, Object?>;
        expect(body['outcome'], 'adapterError',
            reason:
                'dispatch wrapper sanitized 500 must mirror '
                'WebhookOutcome.adapterError per triage Section 5.D');
        expect(body['records_written'], 0);
      },
    );
  });
}

/// Postgres-shaped synthetic exception. `toString()` mirrors the
/// surface that a real `package:postgres` server-error would expose
/// (severity, code, message) so the assertions match production
/// shapes.
class _PostgresShapedException implements Exception {
  const _PostgresShapedException(this.message, this.severity, this.code);

  final String message;
  final String severity;
  final String code;

  @override
  String toString() =>
      'ServerException ($severity, $code): $message';
}

class _NoopVerifier implements VendorWebhookSignatureVerifier {
  const _NoopVerifier();

  @override
  String get vendorId => 'lightspeed_lsk';

  @override
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  }) {
    return const WebhookSignatureVerification(valid: true);
  }
}

class _NoopPosAdapter implements PosAdapter {
  @override
  String get vendorId => 'lightspeed_lsk';

  @override
  noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _ThrowingInboundWebhookGateway implements InboundWebhookGateway {
  _ThrowingInboundWebhookGateway({required this.throwOnLookupSigningSecret});

  final Object throwOnLookupSigningSecret;

  @override
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    throw throwOnLookupSigningSecret;
  }

  @override
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async => null;

  @override
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async => IdempotencyOutcome.firstTime;

  @override
  Future<void> markProcessed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async {}

  @override
  Future<void> recordSanityDrop({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  }) async {}

  @override
  Future<int> recordFailedAttempt({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String failureMessage,
    required DateTime receivedAt,
  }) async => 1;

  @override
  Future<void> deadLetter({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payloadPreview,
    required InboundWebhookFailureKind failureKind,
    required String failureMessage,
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {}
}

class _UnusedRoutesGateway implements IntegrationRoutesGateway {
  @override
  noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ─── Stub HttpRequest / HttpResponse (lifted from
// admin_integrations_idempotency_test.dart so this file stays self-
// contained). ───────────────────────────────────────────────────────

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
  noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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

  // Mirrors `dart:io` `HttpHeaders.forEach((String, List<String>) => void)`.
  // The dispatch wrapper sanitization path iterates request headers
  // when building its structured-log breadcrumb, so the stub must
  // satisfy the real typedef (was previously routed through
  // noSuchMethod, which threw NoSuchMethodError once Dart began
  // checking the closure signature).
  @override
  void forEach(void Function(String name, List<String> values) action) {
    for (final entry in _values.entries) {
      action(entry.key.toLowerCase(), <String>[entry.value]);
    }
  }

  @override
  noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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
  noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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
  noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
