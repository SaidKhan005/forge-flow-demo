// CODE_HEALTH L4 — admin idempotency orphan-reclaim tests.
//
// Verifies that `_runAdminIdempotent` (exposed via the
// `runAdminIdempotentForTesting` test seam) reclaims an in-flight row
// whose `expires_at` has passed and proceeds with a fresh attempt
// instead of returning 409 forever.
//
// Reclaim predicate (matches the M1 migration —
// `db/migrations/202605080100_admin_idempotency_expires_at.sql` —
// and the `admin_idempotency_sweep` pg_cron job exactly):
//   `response_status IS NULL AND completed_at IS NULL AND
//    expires_at < now()`
//
// The HARD-H table has NO `status` column. "In-flight" is the pair
// `(response_status IS NULL AND completed_at IS NULL)`. These tests
// drive an in-memory fake of [AdminRequestIdempotencyStore] and
// assert:
//   1. An in-flight row whose expires_at < now() is treated as
//      orphan: tryReclaimOrphan deletes it, fresh reserve runs the
//      compute callback, response is the fresh body.
//   2. An in-flight row whose expires_at > now() still 409s.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';

/// In-memory fake. Mirrors the
/// `(response_status IS NULL AND completed_at IS NULL)` in-flight
/// signal exactly — no `status` column, by design.
class _FakeIdempotencyStore implements AdminRequestIdempotencyStore {
  final Map<String, _Entry> rows = <String, _Entry>{};
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
      throw const AdminIdempotencyKeyConflict(
        message: 'request_type mismatch',
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
    rows[idempotencyKey] = _Entry(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
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
      completedAt: DateTime.now(),
    );
  }

  @override
  Future<bool> tryReclaimOrphan({required String idempotencyKey}) async {
    reclaimCalls += 1;
    final row = rows[idempotencyKey];
    if (row == null) return false;
    // Mirror the migration / pg_cron predicate exactly: in-flight =
    // (response_status IS NULL AND completed_at IS NULL).
    if (row.responseStatus != null || row.completedAt != null) {
      return false;
    }
    final expiresAt = row.expiresAt;
    if (expiresAt == null || !expiresAt.isBefore(DateTime.now())) {
      return false;
    }
    rows.remove(idempotencyKey);
    return true;
  }

  @override
  Future<int> sweepExpiredOrphans() async {
    sweepCalls += 1;
    final now = DateTime.now();
    final keys = <String>[];
    rows.forEach((key, row) {
      if (row.responseStatus == null &&
          row.completedAt == null &&
          row.expiresAt != null &&
          row.expiresAt!.isBefore(now)) {
        keys.add(key);
      }
    });
    for (final key in keys) {
      rows.remove(key);
    }
    return keys.length;
  }
}

class _Entry {
  _Entry({
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

  _Entry copyWith({
    int? responseStatus,
    Map<String, Object?>? responsePayload,
    DateTime? completedAt,
  }) {
    return _Entry(
      requestType: requestType,
      requestBodyHash: requestBodyHash,
      expiresAt: expiresAt,
      responseStatus: responseStatus ?? this.responseStatus,
      responsePayload: responsePayload ?? this.responsePayload,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}

/// Spins up a single-shot HTTP server that calls
/// [runAdminIdempotentForTesting] for every request. The closures
/// driven by each test override how the helper is invoked.
class _Harness {
  late HttpServer server;
  late HttpClient client;
  late Uri uri;
  late Future<void> Function(HttpRequest) _handler;

  Future<void> start({
    required Future<void> Function(HttpRequest) handler,
  }) async {
    _handler = handler;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        await _handler(request);
      } catch (e) {
        request.response.statusCode = 500;
        request.response.write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      }
    });
    client = HttpClient();
    uri = Uri.parse('http://${server.address.host}:${server.port}/');
  }

  Future<void> stop() async {
    client.close(force: true);
    await server.close(force: true);
  }

  Future<({int statusCode, Map<String, Object?> body})> postJson(
    Map<String, Object?> body, {
    required String idempotencyKey,
  }) async {
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.headers.set('Idempotency-Key', idempotencyKey);
    final encoded = utf8.encode(jsonEncode(body));
    req.headers.contentLength = encoded.length;
    req.add(encoded);
    final resp = await req.close();
    final raw = await resp.transform(utf8.decoder).join();
    final decoded = raw.isEmpty
        ? <String, Object?>{}
        : (jsonDecode(raw) as Map<String, Object?>);
    return (statusCode: resp.statusCode, body: decoded);
  }
}

void main() {
  group('runAdminIdempotent — orphan reclaim', () {
    test(
        'in-flight row whose expires_at < now() is reclaimed; '
        'fresh request proceeds',
        () async {
      final store = _FakeIdempotencyStore();
      const key = 'orphan-1';
      const requestType = 'unit_test_action';
      // Seed an in-flight row whose TTL has already elapsed.
      store.rows[key] = _Entry(
        requestType: requestType,
        // Empty-body hash — the helper canonicalizes the body before
        // hashing, so we use the same canonicalization.
        requestBodyHash: _emptyBodyHash,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      var computeCalls = 0;
      final harness = _Harness();
      await harness.start(handler: (request) async {
        await runAdminIdempotentForTesting(
          response: request.response,
          store: store,
          idempotencyKey: key,
          requestType: requestType,
          actorUserId: null,
          requestBody: const <String, Object?>{},
          compute: () async {
            computeCalls += 1;
            return (
              statusCode: 200,
              payload: <String, Object?>{'result': 'fresh'},
            );
          },
        );
      });

      try {
        final response = await harness.postJson(
          const <String, Object?>{},
          idempotencyKey: key,
        );
        expect(response.statusCode, equals(200));
        expect(response.body['result'], equals('fresh'));
        expect(computeCalls, equals(1),
            reason: 'compute must run exactly once after reclaim');
        expect(store.reclaimCalls, equals(1),
            reason: 'tryReclaimOrphan must be called exactly once');
        expect(store.reserveCalls, equals(1),
            reason: 'reserve must be called once after reclaim');
        // After reclaim → reserve → completeReservation, the row is
        // a normal completed entry with the fresh response stamped.
        expect(store.rows[key]!.responseStatus, equals(200));
        expect(store.rows[key]!.completedAt, isNotNull);
      } finally {
        await harness.stop();
      }
    });

    test(
        'in-flight row whose expires_at > now() still 409s',
        () async {
      final store = _FakeIdempotencyStore();
      const key = 'in-flight-1';
      const requestType = 'unit_test_action';
      // Seed an in-flight row whose TTL is still in the future.
      store.rows[key] = _Entry(
        requestType: requestType,
        requestBodyHash: _emptyBodyHash,
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );

      var computeCalls = 0;
      final harness = _Harness();
      await harness.start(handler: (request) async {
        await runAdminIdempotentForTesting(
          response: request.response,
          store: store,
          idempotencyKey: key,
          requestType: requestType,
          actorUserId: null,
          requestBody: const <String, Object?>{},
          compute: () async {
            computeCalls += 1;
            return (
              statusCode: 200,
              payload: <String, Object?>{'result': 'should-not-run'},
            );
          },
        );
      });

      try {
        final response = await harness.postJson(
          const <String, Object?>{},
          idempotencyKey: key,
        );
        expect(response.statusCode, equals(409));
        expect(response.body['error'], equals('idempotency_request_in_flight'));
        expect(computeCalls, equals(0),
            reason: 'compute must NOT run while reservation is live');
        expect(store.reclaimCalls, equals(0),
            reason: 'reclaim must NOT be attempted on a live reservation');
        expect(store.reserveCalls, equals(0));
        // Row remains in-flight.
        expect(store.rows[key]!.responseStatus, isNull);
        expect(store.rows[key]!.completedAt, isNull);
      } finally {
        await harness.stop();
      }
    });

    test(
        'sweepExpiredOrphans removes only rows that match the '
        'predicate (in-flight AND expired)',
        () async {
      final store = _FakeIdempotencyStore();
      // Live in-flight reservation: must NOT be swept.
      store.rows['live'] = _Entry(
        requestType: 'a',
        requestBodyHash: 'h',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      // Expired in-flight reservation: must be swept.
      store.rows['orphan'] = _Entry(
        requestType: 'a',
        requestBodyHash: 'h',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      // Completed row whose expires_at has passed: NOT in-flight, must
      // NOT be swept.
      store.rows['done'] = _Entry(
        requestType: 'a',
        requestBodyHash: 'h',
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        responseStatus: 200,
        responsePayload: const <String, Object?>{},
        completedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      final removed = await store.sweepExpiredOrphans();
      expect(removed, equals(1));
      expect(store.rows.containsKey('live'), isTrue);
      expect(store.rows.containsKey('orphan'), isFalse);
      expect(store.rows.containsKey('done'), isTrue);
    });
  });
}

/// SHA-256 of the canonicalized empty JSON object `{}`. Mirrors the
/// canonicalization in `_hashRequestBody` so the fake store's body-
/// hash check round-trips exactly when the test request body is `{}`.
final String _emptyBodyHash = () {
  // Computed once at top-level so the test does not depend on `crypto`
  // directly. We reproduce the helper's canonicalization here.
  // Empty map → keys sorted (none) → '{}'.
  // sha256('{}') hex:
  return '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a';
}();
