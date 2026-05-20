// Phase 8 V1.E lane — VendorLifecyclePromotionRouter tests.
//
// Covers the proxy route contract that triggers the
// vendor-now-available email fan-out on lifecycle promotion to
// `production_credentialed`:
//
//   POST /v1/admin/vendors/:vendor_id/lifecycle-promotion-notification
//
// Asserts:
//
//   * Path / method matching (returns false for unrelated paths so
//     the existing dispatcher chain continues).
//   * Idempotency-Key header is required (400 without it).
//   * Idempotency replay short-circuits the fan-out (cached
//     response returned, dispatcher not re-invoked).
//   * 403 when the authorizer denies the request.
//   * Successful path returns 200 with the per-vendor outcome
//     envelope.
//   * 400 when new_lifecycle_state is missing.
//   * Body parse failure → 400 invalid_json_body.
//   * Vendor id segment is sanitised (returns false for paths with
//     embedded slashes or oversized segments).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart';
import '../../tool/advisor_proxy/email_dispatch/vendor_lifecycle_promotion_routes.dart';

void main() {
  group('VendorLifecyclePromotionRouter.tryHandle', () {
    test('returns false for unrelated path → falls through', () async {
      final router = _buildRouter();
      final request = await _captureRequest(
        router: router,
        method: 'GET',
        path: '/v1/admin/health',
        headers: <String, String>{},
        body: null,
      );

      expect(request.handled, isFalse);
    });

    test('400 when Idempotency-Key header is missing', () async {
      final router = _buildRouter();
      final request = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{},
        body: jsonEncode(<String, Object?>{
          'new_lifecycle_state': 'productionCredentialed',
        }),
      );

      expect(request.handled, isTrue);
      expect(request.statusCode, 400);
      expect(request.bodyJson['error'], 'idempotency_key_required');
    });

    test('403 when authorizer denies the request', () async {
      final dispatcher = _buildDispatcher();
      final router = VendorLifecyclePromotionRouter(
        dispatcher: dispatcher,
        authorizer: (_) async => false,
        idempotencyStore: _InMemoryIdempotencyStore(),
      );
      final request = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'test-key-1'},
        body: jsonEncode(<String, Object?>{
          'new_lifecycle_state': 'productionCredentialed',
        }),
      );

      expect(request.handled, isTrue);
      expect(request.statusCode, 403);
      expect(request.bodyJson['error'], 'permission_denied');
    });

    test('200 on the happy path with the dispatch outcome envelope', () async {
      final notifications = _SeededNotificationRepo()
        ..seed('op-1', 'toast', <String>['n-1', 'n-2']);
      final outbox = _RecordingOutbox();
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver:
            ({required String operatorId, required String vendorId}) async {
              return const VendorNotificationOperatorContext(
                operatorBusinessName: 'Acme Bistro',
                vendorDisplayName: 'Toast',
                integrationConsoleUrl: 'https://app.forgeflow.app',
              );
            },
      );
      final router = VendorLifecyclePromotionRouter(
        dispatcher: dispatcher,
        authorizer: (_) async => true,
        idempotencyStore: _InMemoryIdempotencyStore(),
        now: () => DateTime.utc(2026, 5, 6, 14, 0),
      );

      final request = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'test-key-happy-1'},
        body: jsonEncode(<String, Object?>{
          'new_lifecycle_state': 'productionCredentialed',
        }),
      );

      expect(request.handled, isTrue);
      expect(request.statusCode, 200);
      expect(request.bodyJson['vendor_id'], 'toast');
      expect(request.bodyJson['notifications_enqueued'], 2);
      expect(request.bodyJson['operators_touched'], 1);
      expect(request.bodyJson['notifications_skipped'], 0);
      expect(request.bodyJson['dispatched_at'], '2026-05-06T14:00:00.000Z');
      expect(outbox.recorded, hasLength(2));
    });

    test('idempotency replay short-circuits to cached response', () async {
      final notifications = _SeededNotificationRepo()
        ..seed('op-1', 'toast', <String>['n-1', 'n-2']);
      final outbox = _RecordingOutbox();
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver:
            ({required String operatorId, required String vendorId}) async {
              return const VendorNotificationOperatorContext(
                operatorBusinessName: 'Acme Bistro',
                vendorDisplayName: 'Toast',
                integrationConsoleUrl: 'https://app.forgeflow.app',
              );
            },
      );
      final store = _InMemoryIdempotencyStore();
      final router = VendorLifecyclePromotionRouter(
        dispatcher: dispatcher,
        authorizer: (_) async => true,
        idempotencyStore: store,
        now: () => DateTime.utc(2026, 5, 6, 14, 0),
      );

      final first = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'replay-key-1'},
        body: jsonEncode(<String, Object?>{
          'new_lifecycle_state': 'productionCredentialed',
        }),
      );
      final second = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'replay-key-1'},
        body: jsonEncode(<String, Object?>{
          'new_lifecycle_state': 'productionCredentialed',
        }),
      );

      expect(first.statusCode, 200);
      expect(second.statusCode, 200);
      // Cached response served verbatim.
      expect(second.bodyJson['notifications_enqueued'], 2);
      // Dispatcher only ran once.
      expect(outbox.recorded, hasLength(2));
    });

    test('same idempotency key with a different body returns 409', () async {
      final store = _InMemoryIdempotencyStore();
      final router = VendorLifecyclePromotionRouter(
        dispatcher: _buildDispatcher(),
        authorizer: (_) async => true,
        idempotencyStore: store,
      );

      final first = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'conflict-key-1'},
        body: jsonEncode(<String, Object?>{
          'new_lifecycle_state': 'productionCredentialed',
        }),
      );
      final second = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'conflict-key-1'},
        body: jsonEncode(<String, Object?>{
          'new_lifecycle_state': 'sandboxVerified',
        }),
      );

      expect(first.statusCode, 200);
      expect(second.statusCode, 409);
      expect(second.bodyJson['error'], 'idempotency_key_conflict');
    });

    test('400 when new_lifecycle_state is missing from the body', () async {
      final router = _buildRouter();
      final request = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'missing-state-1'},
        body: jsonEncode(<String, Object?>{}),
      );

      expect(request.handled, isTrue);
      expect(request.statusCode, 400);
      expect(request.bodyJson['error'], 'new_lifecycle_state_required');
    });

    test('400 when JSON body is malformed', () async {
      final router = _buildRouter();
      final request = await _captureRequest(
        router: router,
        method: 'POST',
        path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
        headers: <String, String>{'Idempotency-Key': 'bad-json-1'},
        body: '{not valid json',
      );

      expect(request.handled, isTrue);
      expect(request.statusCode, 400);
      expect(request.bodyJson['error'], 'invalid_json_body');
    });

    test(
      'returns false for path with extra segments after vendor id',
      () async {
        final router = _buildRouter();
        final request = await _captureRequest(
          router: router,
          method: 'POST',
          path:
              '/v1/admin/vendors/toast/extra/lifecycle-promotion-notification',
          headers: <String, String>{},
          body: null,
        );

        expect(request.handled, isFalse);
      },
    );

    test(
      'non-productionCredentialed state is a no-op (dispatcher decides)',
      () async {
        final notifications = _SeededNotificationRepo()
          ..seed('op-1', 'toast', <String>['n-1']);
        final outbox = _RecordingOutbox();
        final dispatcher = VendorLifecycleNotificationDispatcher(
          notificationRepository: notifications,
          outboxRepository: outbox,
          contextResolver:
              ({required String operatorId, required String vendorId}) async {
                return const VendorNotificationOperatorContext(
                  operatorBusinessName: 'Acme Bistro',
                  vendorDisplayName: 'Toast',
                  integrationConsoleUrl: 'https://app.forgeflow.app',
                );
              },
        );
        final router = VendorLifecyclePromotionRouter(
          dispatcher: dispatcher,
          authorizer: (_) async => true,
          idempotencyStore: _InMemoryIdempotencyStore(),
        );

        final request = await _captureRequest(
          router: router,
          method: 'POST',
          path: '/v1/admin/vendors/toast/lifecycle-promotion-notification',
          headers: <String, String>{'Idempotency-Key': 'sandbox-promote-1'},
          body: jsonEncode(<String, Object?>{
            'new_lifecycle_state': 'sandboxVerified',
          }),
        );

        expect(request.handled, isTrue);
        expect(request.statusCode, 200);
        expect(request.bodyJson['notifications_enqueued'], 0);
        expect(outbox.recorded, isEmpty);
      },
    );
  });
}

// ───────────────────────────────────────────────────────────────────
// Test scaffolding.
// ───────────────────────────────────────────────────────────────────

VendorLifecyclePromotionRouter _buildRouter() {
  final dispatcher = _buildDispatcher();
  return VendorLifecyclePromotionRouter(
    dispatcher: dispatcher,
    authorizer: (_) async => true,
    idempotencyStore: _InMemoryIdempotencyStore(),
  );
}

VendorLifecycleNotificationDispatcher _buildDispatcher() {
  return VendorLifecycleNotificationDispatcher(
    notificationRepository: _SeededNotificationRepo(),
    outboxRepository: _RecordingOutbox(),
    contextResolver:
        ({required String operatorId, required String vendorId}) async {
          return const VendorNotificationOperatorContext(
            operatorBusinessName: 'Acme Bistro',
            vendorDisplayName: 'Toast',
            integrationConsoleUrl: 'https://app.forgeflow.app',
          );
        },
  );
}

class _CapturedRequest {
  _CapturedRequest({
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

/// Wraps [body] in a real-HTTP context. `flutter_test` installs an
/// `HttpOverrides` that intercepts every dart:io HTTP call; without
/// this helper an `HttpClient` opened inside a test never reaches
/// the loopback `HttpServer` and the test hangs.
Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

/// Boots a tiny HttpServer, sends the request through it, and lets
/// the router handle it. This exercises the real dart:io plumbing
/// the production proxy depends on (header parsing, body reads,
/// response close) instead of mocking [HttpRequest].
Future<_CapturedRequest> _captureRequest({
  required VendorLifecyclePromotionRouter router,
  required String method,
  required String path,
  required Map<String, String> headers,
  required String? body,
}) async {
  return _withRealHttp(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handledCompleter = Completer<bool>();
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        final handled = await router.tryHandle(request);
        if (!handledCompleter.isCompleted) {
          handledCompleter.complete(handled);
        }
        if (!handled) {
          request.response.statusCode = 404;
          await request.response.close();
        }
      } catch (e) {
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
      clientRequest.persistentConnection = false;
      headers.forEach((key, value) {
        clientRequest.headers.set(key, value);
      });
      if (body != null) {
        clientRequest.headers.contentType = ContentType.json;
        clientRequest.write(body);
      } else {
        clientRequest.contentLength = 0;
      }
      final clientResponse = await clientRequest.close();
      final responseText = await clientResponse.transform(utf8.decoder).join();
      final handled = await handledCompleter.future;
      return _CapturedRequest(
        handled: handled,
        statusCode: clientResponse.statusCode,
        bodyText: responseText,
      );
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });
}

class _SeededNotificationRepo
    implements VendorLifecycleNotificationReadRepository {
  final Map<String, Map<String, List<_Pending>>> _rows =
      <String, Map<String, List<_Pending>>>{};

  void seed(String operatorId, String vendorId, List<String> notificationIds) {
    final byVendor = _rows.putIfAbsent(
      operatorId,
      () => <String, List<_Pending>>{},
    );
    final list = byVendor.putIfAbsent(vendorId, () => <_Pending>[]);
    for (final id in notificationIds) {
      list.add(_Pending(id: id, email: '$id@example.test'));
    }
  }

  @override
  Future<List<String>> pendingOperatorIdsForVendor({
    required String vendorId,
  }) async {
    return _rows.entries
        .where(
          (e) => (e.value[vendorId] ?? const <_Pending>[]).any(
            (row) => !row.notified,
          ),
        )
        .map((e) => e.key)
        .toList();
  }

  @override
  Future<List<PendingVendorNotification>> fetchPendingForVendor({
    required String operatorId,
    required String vendorId,
  }) async {
    final rows = _rows[operatorId]?[vendorId] ?? const <_Pending>[];
    return rows
        .where((row) => !row.notified)
        .map(
          (row) => PendingVendorNotification(
            notificationId: row.id,
            operatorId: operatorId,
            vendorId: vendorId,
            recipientEmail: row.email,
          ),
        )
        .toList(growable: false);
  }
}

class _Pending {
  _Pending({required this.id, required this.email});
  final String id;
  final String email;
  bool notified = false;
}

class _RecordingOutbox implements EmailOutboxEnqueueRepository {
  final List<Map<String, Object?>> recorded = <Map<String, Object?>>[];

  @override
  Future<bool> claimAndEnqueue({
    required PendingVendorNotification notification,
    required String templateId,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required DateTime stampedAt,
  }) async {
    recorded.add(<String, Object?>{
      'operator_id': notification.operatorId,
      'template_id': templateId,
      'recipient_email': notification.recipientEmail,
      'recipient_display_name': recipientDisplayName,
      'template_data': Map<String, String>.from(templateData),
    });
    return true;
  }
}

class _InMemoryIdempotencyStore
    implements VendorLifecyclePromotionIdempotencyStore {
  final Map<String, _IdempotencyEntry> _cache = <String, _IdempotencyEntry>{};

  @override
  Future<VendorLifecyclePromotionIdempotencyEntry?> lookup({
    required String idempotencyKey,
    required String requestType,
    required String requestBodyHash,
  }) async {
    final cached = _cache[idempotencyKey];
    if (cached == null) return null;
    if (cached.requestType != requestType ||
        cached.requestBodyHash != requestBodyHash) {
      throw const VendorLifecyclePromotionIdempotencyConflict(
        message: 'Idempotency-Key was already used for another request',
      );
    }
    return VendorLifecyclePromotionIdempotencyEntry(
      responseStatus: cached.responseStatus,
      responsePayload: cached.responsePayload == null
          ? null
          : Map<String, Object?>.from(cached.responsePayload!),
      expiresAt: null,
    );
  }

  @override
  Future<bool> reserve({
    required String idempotencyKey,
    required String requestType,
    required String? actorUserId,
    required String requestBodyHash,
  }) async {
    if (_cache.containsKey(idempotencyKey)) return false;
    _cache[idempotencyKey] = _IdempotencyEntry(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
    );
    return true;
  }

  @override
  Future<void> completeReservation({
    required String idempotencyKey,
    required int responseStatus,
    required Map<String, Object?> responsePayload,
  }) async {
    final entry = _cache[idempotencyKey];
    if (entry == null) return;
    entry.responseStatus = responseStatus;
    entry.responsePayload = Map<String, Object?>.from(responsePayload);
  }

  @override
  Future<bool> tryReclaimOrphan({required String idempotencyKey}) async {
    return false;
  }
}

class _IdempotencyEntry {
  _IdempotencyEntry({required this.requestType, required this.requestBodyHash});

  final String requestType;
  final String requestBodyHash;
  int? responseStatus;
  Map<String, Object?>? responsePayload;
}
