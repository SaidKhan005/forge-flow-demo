// Wave 2 U-FU-tier-email-wire — proves the tier-email router is
// mounted in `tool/advisor_proxy/main.dart`'s request loop.
//
// Two surfaces guard the wiring:
//
//   1. Source-grep assertions over `tool/advisor_proxy/main.dart`.
//      These prove the import, the router instantiation, the
//      auth resolver shape, the audit-sink reuse, the
//      `tryHandle` pre-check inside the dispatch chain, and the
//      startup log fields. Mirrors the source-grep pattern in
//      `main_bootstrap_test.dart` for the rest of `main.dart`'s
//      bindings; the actual `Future<void> main()` binds a socket
//      and a Postgres pool so we cannot drive it directly inside
//      a unit test.
//
//   2. End-to-end smoke against a real `HttpServer` that wires a
//      replica of `main.dart`'s pre-check chain (`tryHandle`
//      first, then a fallback 404). Auth resolver, audit sink,
//      and email provider are test doubles, but the router under
//      test is the production type from
//      `operator_tier_email_routes.dart`. A POST to the canonical
//      path returns a 200 envelope through the mounted router
//      rather than the fallback 404, which is the bug PR #713
//      would have left in production without this slice.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/email/email_provider.dart';

import '../../tool/advisor_proxy/operator_routes.dart';
import '../../tool/advisor_proxy/operator_tier_email_routes.dart';

void main() {
  group('operator_tier_email_routes — main.dart mount wiring', () {
    String readMainSource() =>
        File('tool/advisor_proxy/main.dart').readAsStringSync();

    test('imports the operator_tier_email_routes sibling file', () {
      expect(
        readMainSource(),
        contains("import 'operator_tier_email_routes.dart';"),
      );
    });

    test('instantiates OperatorTierEmailRouter once at startup', () {
      final source = readMainSource();
      expect(
        source,
        contains('final operatorTierEmailRouter = OperatorTierEmailRouter('),
      );
    });

    test('reuses the shared ProductionOperatorWriteAuditSink', () {
      // B6 reused this same sink so every operator-write surface
      // hash-chains through one audit_logs chain head per
      // operator. The tier-email mount must NOT introduce a
      // parallel audit-sink instance.
      final source = readMainSource();
      expect(
        source,
        contains(
          'auditSink: productionBindings.operatorBenchmarkOverridesAuditSink',
        ),
      );
    });

    test(
      'wires a SendGrid email provider with SENDGRID_API_KEY + sandbox mode',
      () {
        final source = readMainSource();
        expect(
          source,
          contains('operatorTierEmailSendGridProvider = SendGridEmailProvider'),
        );
        // API key + sandbox mode are read from env at the mount
        // site so a deployment can flip sandbox without code
        // changes (mirrors the email_outbox dispatcher block).
        final mountRegion = source.substring(
          source.indexOf('operatorTierEmailSendGridProvider'),
          source.indexOf('startup.operator_tier_email_router'),
        );
        expect(
          mountRegion,
          contains("Platform.environment['SENDGRID_API_KEY']"),
        );
        expect(
          mountRegion,
          contains("Platform.environment['SENDGRID_SANDBOX_MODE']"),
        );
      },
    );

    test('auth resolver closes over authGuard.requireOperatorContext', () {
      final source = readMainSource();
      final routerRegion = source.substring(
        source.indexOf('operatorTierEmailRouter = OperatorTierEmailRouter('),
        source.indexOf('startup.operator_tier_email_router'),
      );
      // The router does its own role gate; the mount only needs
      // to surface a verified OperatorContext so the in-router
      // `kOperatorWriteRoles` check fires against real claims.
      expect(routerRegion, contains('authGuard.requireOperatorContext'));
      expect(routerRegion, contains('OperatorTierEmailActor('));
      expect(routerRegion, contains('} on ProxyAuthError {'));
    });

    test('dispatch chain calls tryHandle as a pre-check', () {
      final source = readMainSource();
      // The pre-check must short-circuit the rest of routeRequest
      // when the router matches the path so we do not double-
      // dispatch through the monolith.
      expect(
        source,
        contains('if (await operatorTierEmailRouter.tryHandle(request)) {'),
      );
      // Mounted in the same region as the other operator-write
      // sibling routers (B6 / B8.b) so reviewers see one idiom
      // for every operator-scoped pre-check. We pin the ORDERING
      // among `tryHandle` calls — production sets the pre-check
      // chain as: auditLogHierarchy -> legacy benchmark override tombstone
      // -> operatorTierEmail -> operatorWebAuditLogHierarchy ->
      // routeRequest fallback.
      final preCheckIndex = source.indexOf(
        'operatorTierEmailRouter.tryHandle(request)',
      );
      final benchmarkTryHandleIndex = source.indexOf(
        'operatorBenchmarkOverridesRouter.tryHandle(request)',
      );
      // `operatorWebAuditLogHierarchyRouter` instantiation lives
      // higher in the file; we want the `.tryHandle(request)` call
      // site specifically. Indent-prefix `if (await ` makes the
      // match unambiguous against both occurrences without
      // depending on platform newlines.
      final auditLogHierarchyTryHandleIndex = source.indexOf(
        'if (await operatorWebAuditLogHierarchyRouter',
      );
      expect(preCheckIndex, greaterThan(benchmarkTryHandleIndex));
      // Tier email mount lands BEFORE the operator-web audit-log
      // hierarchy pre-check; either order is functionally
      // equivalent (paths are disjoint) but the test pins the
      // current shape so a future refactor does not silently
      // shuffle the chain into a confusing layout.
      expect(preCheckIndex, lessThan(auditLogHierarchyTryHandleIndex));
    });

    test('logs startup.operator_tier_email_router with the canonical path', () {
      final source = readMainSource();
      expect(source, contains("'startup.operator_tier_email_router'"));
      expect(
        source,
        contains("'path': operatorTierEmailDataFreshnessRequestPath"),
      );
      expect(source, contains("'sendgrid_api_key_loaded'"));
    });
  });

  group('operator_tier_email_routes — live HttpServer smoke', () {
    // Boots an HttpServer that wires the router with the same
    // `tryHandle`-first pattern `main.dart` uses, then POSTs a
    // real HTTP request and checks the envelope.

    late _RecordingEmailProvider emailProvider;
    late _RecordingAuditSink auditSink;
    late OperatorTierEmailRouter router;

    setUp(() {
      emailProvider = _RecordingEmailProvider();
      auditSink = _RecordingAuditSink();
      router = OperatorTierEmailRouter(
        emailProvider: emailProvider,
        auditSink: auditSink,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
        auditRowIdFactory: () => 'audit-mount-row',
        authResolver: (request) async {
          // Stand-in for the production resolver, which closes
          // over `authGuard.requireOperatorContext`. The smoke
          // only needs to prove the dispatch reaches the router;
          // the in-router gates (role + idempotency + body) are
          // exercised by `operator_tier_email_routes_test.dart`.
          if (request.headers.value('Authorization') != 'Bearer fake-token') {
            return null;
          }
          return OperatorTierEmailActor(
            userId: '11111111-1111-4111-8111-111111111111',
            operatorId: '22222222-2222-4222-8222-222222222222',
            locationId: '33333333-3333-4333-8333-333333333333',
            operatorName: 'Test Operator',
            roles: <String>{'operator_owner'},
            actorKind: 'operator_user',
          );
        },
      );
    });

    test(
      'POST to the canonical path reaches the mounted router (200)',
      () async {
        final result = await _captureRequest(
          router: router,
          method: 'POST',
          path: operatorTierEmailDataFreshnessRequestPath,
          headers: <String, String>{
            'Authorization': 'Bearer fake-token',
            'Idempotency-Key': 'smoke-idem-1',
          },
          body: const <String, Object?>{
            'current_tier': 'Standard',
            'requested_cadence': 'Faster than current tier',
            'business_reason': 'Mount smoke test',
          },
        );

        expect(
          result.handled,
          isTrue,
          reason: 'router.tryHandle must claim the canonical POST path',
        );
        expect(result.statusCode, 200);
        expect(result.bodyJson['ok'], true);
        expect(result.bodyJson['audit_row_id'], 'audit-mount-row');
        expect(emailProvider.sends, hasLength(1));
        expect(auditSink.events, hasLength(1));
        expect(
          auditSink.events.single['eventKind'],
          kOperatorTierEmailAuditEventKind,
        );
      },
    );

    test(
      'POST to a non-mounted path falls through to the dispatcher (404)',
      () async {
        // Proves the pre-check is a precise match, not a prefix
        // match — the fallback path must still 404 just like
        // production would route it through the monolith.
        final result = await _captureRequest(
          router: router,
          method: 'POST',
          path: '/v1/operator/tier-email/something-else',
          headers: <String, String>{
            'Authorization': 'Bearer fake-token',
            'Idempotency-Key': 'smoke-idem-2',
          },
          body: const <String, Object?>{},
        );

        expect(
          result.handled,
          isFalse,
          reason: 'router.tryHandle must NOT claim a near-miss path',
        );
        expect(result.statusCode, 404);
        expect(result.bodyJson['error'], 'not_found');
        // Routed past the router — neither audit nor email side
        // effects fired.
        expect(emailProvider.sends, isEmpty);
        expect(auditSink.events, isEmpty);
      },
    );

    test(
      'GET on the canonical path falls through (405-equivalent 404)',
      () async {
        // The router only matches `POST`; other methods on the same
        // path must NOT short-circuit, so the fallback dispatcher
        // owns the response shape.
        final result = await _captureRequest(
          router: router,
          method: 'GET',
          path: operatorTierEmailDataFreshnessRequestPath,
          headers: <String, String>{'Authorization': 'Bearer fake-token'},
        );

        expect(result.handled, isFalse);
        expect(result.statusCode, 404);
        expect(result.bodyJson['error'], 'not_found');
      },
    );

    test(
      'missing Authorization header is rejected by the router (401)',
      () async {
        // Confirms the mounted router's auth resolver is the one
        // running — not the fallback dispatcher.
        final result = await _captureRequest(
          router: router,
          method: 'POST',
          path: operatorTierEmailDataFreshnessRequestPath,
          headers: <String, String>{'Idempotency-Key': 'smoke-idem-3'},
          body: const <String, Object?>{
            'current_tier': 'Standard',
            'requested_cadence': 'Faster',
            'business_reason': 'No auth',
          },
        );

        expect(
          result.handled,
          isTrue,
          reason: 'router.tryHandle claims the path even when auth fails',
        );
        expect(result.statusCode, 401);
        expect(result.bodyJson['error'], 'unauthorized');
        // No side effects: audit + email both empty.
        expect(emailProvider.sends, isEmpty);
        expect(auditSink.events, isEmpty);
      },
    );
  });
}

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

class _CapturedResult {
  const _CapturedResult({
    required this.handled,
    required this.statusCode,
    required this.bodyText,
  });

  final bool handled;
  final int statusCode;
  final String bodyText;

  Map<String, Object?> get bodyJson {
    if (bodyText.isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(bodyText);
    if (decoded is Map) return decoded.cast<String, Object?>();
    return const <String, Object?>{};
  }
}

Future<_CapturedResult> _captureRequest({
  required OperatorTierEmailRouter router,
  required String method,
  required String path,
  Map<String, String> headers = const <String, String>{},
  Map<String, Object?>? body,
}) async {
  return _withRealHttp(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handledCompleter = Completer<bool>();
    // ignore: unawaited_futures
    server.listen((HttpRequest request) async {
      try {
        // Mirror `main.dart`'s pre-check chain shape: the router
        // gets first chance; on miss, fall through to a 404 that
        // stands in for `routeRequest`'s default handler.
        final handled = await router.tryHandle(request);
        if (!handledCompleter.isCompleted) {
          handledCompleter.complete(handled);
        }
        if (!handled) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object?>{
              'error': 'not_found',
              'message': 'fallback dispatcher',
            }),
          );
          await request.response.close();
        }
      } catch (_) {
        if (!handledCompleter.isCompleted) {
          handledCompleter.complete(false);
        }
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });

    final client = HttpClient();
    try {
      final clientRequest = await client.openUrl(
        method,
        Uri.parse('http://${server.address.host}:${server.port}$path'),
      );
      headers.forEach(clientRequest.headers.set);
      if (body != null) {
        clientRequest.headers.contentType = ContentType.json;
        final encoded = utf8.encode(jsonEncode(body));
        clientRequest.contentLength = encoded.length;
        clientRequest.add(encoded);
      }
      final response = await clientRequest.close();
      final responseBody = await utf8.decodeStream(response);
      final handled = await handledCompleter.future;
      return _CapturedResult(
        handled: handled,
        statusCode: response.statusCode,
        bodyText: responseBody,
      );
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });
}

class _RecordingEmailProvider implements EmailProvider {
  final List<EmailSendRequest> sends = <EmailSendRequest>[];

  @override
  String get providerId => 'fake-mount';

  @override
  Future<EmailSendResult> send(EmailSendRequest request) async {
    sends.add(request);
    return EmailSendResult(
      providerMessageId: 'fake-mount-msg-${sends.length}',
      acceptedAt: DateTime.utc(2026, 5, 14, 12, sends.length),
    );
  }

  @override
  Future<EmailDeliveryStatus> getDeliveryStatus(String providerMessageId) {
    throw UnimplementedError();
  }
}

class _RecordingAuditSink implements OperatorWriteAuditSink {
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    events.add(<String, Object?>{
      'operatorId': operatorId,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'eventKind': eventKind,
      'payload': payload,
      'occurredAt': occurredAt,
    });
  }
}
