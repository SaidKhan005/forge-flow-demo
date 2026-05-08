import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/inbound_webhook_handler.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart'
    as integration;

import '../../tool/advisor_proxy/admin_integrations_routes.dart';

const String _op = '11111111-1111-4111-8111-111111111111';
const String _loc = '22222222-2222-4222-8222-222222222222';
const String _user = '33333333-3333-4333-8333-333333333333';
const String _connection = '44444444-4444-4444-8444-444444444444';
final DateTime _connectedAt = DateTime.utc(2026, 5, 6, 12);

void main() {
  group('Phase80IntegrationRoutes first backfill enqueue', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<
      ({
        HttpServer server,
        HttpClient client,
        Uri baseUri,
        _FakeIntegrationRoutesGateway gateway,
        _FakeFirstBackfillEnqueuer enqueuer,
      })
    >
    spinUp({
      Map<String, Object?>? keyPasteResult,
      Map<String, Object?>? oauthCallbackResult,
      bool permitted = true,
    }) async {
      final gateway = _FakeIntegrationRoutesGateway(
        keyPasteResult: keyPasteResult,
        oauthCallbackResult: oauthCallbackResult,
        permitted: permitted,
      );
      final enqueuer = _FakeFirstBackfillEnqueuer();
      final router = Phase80IntegrationRoutes(
        gateway: gateway,
        actorResolver: (_) async => const AdminActorContext(
          operatorId: _op,
          locationId: _loc,
          userId: _user,
        ),
        webhookHandler: InboundWebhookHandler(
          gateway: _FakeInboundWebhookGateway(),
          posAdapterFactories: const <String, PosAdapterFactory>{},
          laborAdapterFactories: const <String, LaborAdapterFactory>{},
          reservationAdapterFactories:
              const <String, ReservationAdapterFactory>{},
          signatureVerifiers: const <String, VendorWebhookSignatureVerifier>{},
          bindingExtractor: WebhookBindingExtractor(),
        ),
        firstBackfillEnqueueGateway: enqueuer,
        integrationCategoryResolver: (_, _) =>
            integration.IntegrationCategory.pos,
        now: () => _connectedAt,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        final handled = await router.tryHandle(request);
        if (!handled) {
          request.response.statusCode = 404;
          await request.response.close();
        }
      });
      final client = HttpClient();
      final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        gateway: gateway,
        enqueuer: enqueuer,
      );
    }

    test('key-paste connect enqueues one bounded first-backfill job', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(keyPasteResult: _connectedResult());
        try {
          final response = await _postJson(
            ctx.client,
            ctx.baseUri.resolve('/v1/admin/integrations/toast/connect-key'),
            const <String, Object?>{
              'operator_id': _op,
              'location_id': _loc,
              'api_key': 'test-key',
            },
            idempotencyKey: 'idem-key-paste-1',
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['first_backfill_status'], equals('enqueued'));
          final firstBackfill = body['first_backfill'] as Map<String, Object?>;
          final job = firstBackfill['job'] as Map<String, Object?>;
          expect(job['job_id'], equals('job-1'));
          expect(ctx.gateway.keyPasteCalls, equals(1));
          expect(ctx.enqueuer.createdJobs, hasLength(1));
          expect(ctx.enqueuer.createdJobs.single.windowEnd, _connectedAt);
          expect(
            ctx.enqueuer.createdJobs.single.windowStart,
            _connectedAt.subtract(kFirstConnectionBackfillMaxWindow),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'OAuth callback enqueues after adapter reports first backfill started',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            oauthCallbackResult: _camelConnectedResult(),
          );
          try {
            final response = await _getJson(
              ctx.client,
              ctx.baseUri.resolve(
                '/v1/admin/integrations/oauth/toast/callback?code=x&state=y',
              ),
            );

            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['first_backfill_status'], equals('enqueued'));
            expect(ctx.gateway.oauthCallbackCalls, equals(1));
            expect(ctx.enqueuer.createdJobs, hasLength(1));
            expect(ctx.enqueuer.createdJobs.single.vendorId, equals('toast'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('retrying connect reuses the existing active job', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(keyPasteResult: _connectedResult());
        try {
          final uri = ctx.baseUri.resolve(
            '/v1/admin/integrations/toast/connect-key',
          );
          // Distinct Idempotency-Keys so each request reaches the
          // gateway. Same-key dedup is covered by
          // `admin_integrations_idempotency_test.dart`. This test
          // verifies the *gateway-level* job reuse: both reaches the
          // gateway, gateway returns the same active job.
          final first = await _postJson(
            ctx.client,
            uri,
            _connectBody(),
            idempotencyKey: 'idem-retry-1',
          );
          final second = await _postJson(
            ctx.client,
            uri,
            _connectBody(),
            idempotencyKey: 'idem-retry-2',
          );

          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          final firstBody = jsonDecode(first.body) as Map<String, Object?>;
          final secondBody = jsonDecode(second.body) as Map<String, Object?>;
          expect(_jobId(firstBody), equals('job-1'));
          expect(_jobId(secondBody), equals('job-1'));
          expect(ctx.gateway.keyPasteCalls, equals(2));
          expect(ctx.enqueuer.calls, hasLength(2));
          expect(ctx.enqueuer.createdJobs, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('adapter firstBackfillStarted false does not enqueue', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          keyPasteResult: <String, Object?>{
            ..._connectedResult(),
            'firstBackfillStarted': false,
          },
        );
        try {
          final response = await _postJson(
            ctx.client,
            ctx.baseUri.resolve('/v1/admin/integrations/toast/connect-key'),
            _connectBody(),
            idempotencyKey: 'idem-not-enqueued',
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['first_backfill_status'], equals('not_enqueued'));
          final firstBackfill = body['first_backfill'] as Map<String, Object?>;
          expect(
            firstBackfill['reason'],
            equals('adapter_reported_first_backfill_not_started'),
          );
          expect(ctx.enqueuer.calls, isEmpty);
          expect(ctx.enqueuer.createdJobs, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('permission denial does not persist connect or enqueue', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          keyPasteResult: _connectedResult(),
          permitted: false,
        );
        try {
          final response = await _postJson(
            ctx.client,
            ctx.baseUri.resolve('/v1/admin/integrations/toast/connect-key'),
            _connectBody(),
          );

          expect(response.statusCode, equals(403));
          expect(ctx.gateway.keyPasteCalls, equals(0));
          expect(ctx.enqueuer.calls, isEmpty);
          expect(ctx.enqueuer.createdJobs, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

Map<String, Object?> _connectedResult() => <String, Object?>{
  'operator_id': _op,
  'location_id': _loc,
  'connection_id': _connection,
  'status': 'connected',
  'firstBackfillStarted': true,
  'connected_at': _connectedAt.toIso8601String(),
};

Map<String, Object?> _camelConnectedResult() => <String, Object?>{
  'operatorId': _op,
  'locationId': _loc,
  'connectionId': _connection,
  'status': 'connected',
  'firstBackfillStarted': true,
  'connectedAt': _connectedAt.toIso8601String(),
};

Map<String, Object?> _connectBody() => const <String, Object?>{
  'operator_id': _op,
  'location_id': _loc,
  'api_key': 'test-key',
};

String? _jobId(Map<String, Object?> body) {
  final firstBackfill = body['first_backfill'] as Map<String, Object?>;
  final job = firstBackfill['job'] as Map<String, Object?>;
  return job['job_id'] as String?;
}

Future<_HttpResponseBody> _postJson(
  HttpClient client,
  Uri uri,
  Map<String, Object?> body, {
  String? idempotencyKey,
}) async {
  final request = await client.postUrl(uri);
  request.headers.contentType = ContentType.json;
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();
  return _readResponse(response);
}

Future<_HttpResponseBody> _getJson(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  return _readResponse(response);
}

Future<_HttpResponseBody> _readResponse(HttpClientResponse response) async {
  final body = await utf8.decodeStream(response);
  return _HttpResponseBody(statusCode: response.statusCode, body: body);
}

class _HttpResponseBody {
  const _HttpResponseBody({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class _FakeIntegrationRoutesGateway implements IntegrationRoutesGateway {
  _FakeIntegrationRoutesGateway({
    Map<String, Object?>? keyPasteResult,
    Map<String, Object?>? oauthCallbackResult,
    this.permitted = true,
  }) : keyPasteResult = keyPasteResult ?? _connectedResult(),
       oauthCallbackResult = oauthCallbackResult ?? _connectedResult();

  final Map<String, Object?> keyPasteResult;
  final Map<String, Object?> oauthCallbackResult;
  final bool permitted;
  int keyPasteCalls = 0;
  int oauthCallbackCalls = 0;

  @override
  Future<bool> hasIntegrationsConfigurePermission({
    required String operatorId,
    required String userId,
  }) async => permitted;

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
    keyPasteCalls++;
    return keyPasteResult;
  }

  @override
  Future<Map<String, Object?>> handleOAuthCallback({
    required String vendorId,
    required Map<String, String> queryParameters,
  }) async {
    oauthCallbackCalls++;
    return oauthCallbackResult;
  }

  @override
  Future<Map<String, Object?>> disconnect({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String reason,
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

  @override
  Future<Map<String, Object?>> startOAuth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    String? module,
  }) async => throw UnimplementedError();

  @override
  Future<Map<String, Object?>> testConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
  }) async => throw UnimplementedError();
}

class _BackfillCall {
  const _BackfillCall({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.vendorId,
    required this.category,
    required this.windowStart,
    required this.windowEnd,
    required this.actorUserId,
  });

  final String operatorId;
  final String locationId;
  final String connectionId;
  final String vendorId;
  final integration.IntegrationCategory category;
  final DateTime windowStart;
  final DateTime windowEnd;
  final String? actorUserId;
}

class _FakeFirstBackfillEnqueuer
    implements FirstConnectionBackfillEnqueueGateway {
  final Map<String, FirstConnectionBackfillJob> _jobsByKey =
      <String, FirstConnectionBackfillJob>{};
  final List<_BackfillCall> calls = <_BackfillCall>[];
  final List<FirstConnectionBackfillJob> createdJobs =
      <FirstConnectionBackfillJob>[];

  @override
  Future<FirstConnectionBackfillJob> enqueueFirstBackfill({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorId,
    required integration.IntegrationCategory category,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? actorUserId,
  }) async {
    calls.add(
      _BackfillCall(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        vendorId: vendorId,
        category: category,
        windowStart: windowStart.toUtc(),
        windowEnd: windowEnd.toUtc(),
        actorUserId: actorUserId,
      ),
    );
    final key = <String>[
      operatorId,
      locationId,
      connectionId,
      category.backfillWire,
      windowStart.toUtc().toIso8601String(),
      windowEnd.toUtc().toIso8601String(),
    ].join('|');
    final existing = _jobsByKey[key];
    if (existing != null) return existing;
    final job = FirstConnectionBackfillJob(
      jobId: 'job-${createdJobs.length + 1}',
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: category,
      windowStart: windowStart,
      windowEnd: windowEnd,
      status: FirstConnectionBackfillJobStatus.pending,
      attemptCount: 0,
      createdAt: _connectedAt,
      updatedAt: _connectedAt,
    );
    _jobsByKey[key] = job;
    createdJobs.add(job);
    return job;
  }
}

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
  }) async {}

  @override
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  }) async => throw UnimplementedError();

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
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async => null;

  @override
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async => null;

  @override
  Future<void> markProcessed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
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
  Future<void> recordSanityDrop({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  }) async {}
}
