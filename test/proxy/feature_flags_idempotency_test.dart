// HARD-D — RepositoryFeatureFlagsAdminProxyGateway idempotency tests.
//
// Audit findings (2026-05-02) covered here:
//   1. In-flight cache entries must be pinned from LRU eviction
//      otherwise a burst of >maxEntries unique keys lets a retry of
//      an evicted-but-still-running key spawn a duplicate compute.
//   2. Toggle + audit must commit atomically; an audit failure must
//      roll back the flag mutation, not leave it unaudited.
//
// Covers the four envelope cases in
// `docs/contracts/hardening_feature_flag_idempotency_contract.md`:
//
//   1. Fresh call → 200 with toggle result + one audit row.
//   2. Same key + same payload → cached response, exactly one audit
//      row, no second DB toggle.
//   3. Same key + different payload → 422
//      `idempotency_payload_mismatch`, no mutation.
//   4. Same key + different `request_type` → 409
//      `idempotency_request_in_flight`.
//
// Plus the contract's header-validation envelopes via the route
// handler in `advisor_proxy.dart`:
//   * Missing `Idempotency-Key` → 400 `idempotency_key_missing`.
//   * `>200`-character key → 400 `idempotency_key_too_long`.
//
// Test posture per the user-confirmed B-option (in-memory only): no
// Postgres, no `proxy_requests` writes. The gateway's collaborators
// are subclassed against the `_unusedWrapper` pattern from
// `test/proxy/integration_admin_proxy_gateway_kms_revision_test.dart`
// so the repository methods are overridden completely without
// touching a Postgres pool.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/feature_flags_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('RepositoryFeatureFlagsAdminProxyGateway idempotency envelopes', () {
    test('first call returns toggle result and emits one audit row',
        () async {
      final flags = _RecordingFeatureFlagsRepository()
        ..nextRow = _row(flagId: 'flag-1', enabled: true);
      final audit = _RecordingAuditRepository();
      final gateway = RepositoryFeatureFlagsAdminProxyGateway(
        featureFlagsRepository: flags,
        auditRepository: audit,
      );

      final result = await gateway.toggleFlag(
        actorUserId: 'admin-uuid',
        flagId: 'flag-1',
        enabled: true,
        idempotencyKey: 'idem-success',
        adminReason: 'admin.test:enable_flag-1',
      );

      expect(result, isNotNull);
      expect(result!['flag_id'], equals('flag-1'));
      expect(result['enabled'], isTrue);
      expect(flags.toggleCalls, equals(1));
      expect(audit.events, hasLength(1));
      expect(audit.events.single.eventType,
          equals('admin.feature_flags.toggle'));
      expect(audit.events.single.payload['idempotency_key'],
          equals('idem-success'));
    });

    test(
      'replay with same key + same payload returns cached result; '
      'no second toggle, no second audit row',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        final first = await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-replay',
          adminReason: 'admin.test:enable_flag-1',
        );
        final second = await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-replay',
          adminReason: 'admin.test:enable_flag-1',
        );

        // Same Map instance — the cache replays the prior Future, so
        // the response body is byte-identical, not just equal.
        expect(identical(first, second), isTrue);
        expect(flags.toggleCalls, equals(1),
            reason: 'second call must replay the cache, not re-toggle');
        expect(audit.events, hasLength(1),
            reason: 'cached replay must NOT emit a second audit row');
      },
    );

    test(
      'replay with same key + different payload returns 422 '
      'idempotency_payload_mismatch and does NOT mutate',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-mismatch',
          adminReason: 'admin.test:enable_flag-1',
        );
        Object? thrown;
        try {
          await gateway.toggleFlag(
            actorUserId: 'admin-uuid',
            flagId: 'flag-1',
            // Different `enabled` → different payload hash.
            enabled: false,
            idempotencyKey: 'idem-mismatch',
            adminReason: 'admin.test:enable_flag-1',
          );
        } catch (e) {
          thrown = e;
        }

        expect(thrown, isA<FeatureFlagsAdminGatewayValidationError>());
        final err = thrown! as FeatureFlagsAdminGatewayValidationError;
        expect(err.statusCode, equals(422));
        expect(err.code, equals('idempotency_payload_mismatch'));
        // The first call's mutation stands; the conflicting retry
        // does not produce a second toggle or a second audit row.
        expect(flags.toggleCalls, equals(1));
        expect(audit.events, hasLength(1));
      },
    );

    test(
      'replay with same key + different request_type returns 409 '
      'idempotency_request_in_flight',
      () async {
        // Pre-seed the cache with a foreign request_type entry so the
        // toggle gateway, which always uses `admin.feature_flag_toggle`,
        // will trip the 409 envelope on first call. The toggle
        // gateway never has direct access to a different request_type
        // today (it is the only consumer of this cache); the test
        // exercises the envelope through the cache seam directly.
        final cache = FeatureFlagToggleIdempotencyCache();
        await cache.runOrReplay(
          requestType: 'admin.foreign_route',
          idempotencyKey: 'idem-shared',
          payloadHash: 'irrelevant-hash',
          compute: () async => <String, Object?>{'placeholder': true},
        );
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
          idempotencyCache: cache,
        );

        Object? thrown;
        try {
          await gateway.toggleFlag(
            actorUserId: 'admin-uuid',
            flagId: 'flag-1',
            enabled: true,
            idempotencyKey: 'idem-shared',
            adminReason: 'admin.test:enable_flag-1',
          );
        } catch (e) {
          thrown = e;
        }

        expect(thrown, isA<FeatureFlagsAdminGatewayValidationError>());
        final err = thrown! as FeatureFlagsAdminGatewayValidationError;
        expect(err.statusCode, equals(409));
        expect(err.code, equals('idempotency_request_in_flight'));
        // No mutation, no audit row — the conflict is detected
        // synchronously before any compute.
        expect(flags.toggleCalls, equals(0));
        expect(audit.events, isEmpty);
      },
    );

    test(
      'audit failure rolls back the toggle: no audit row + cache slot '
      'freed for a clean retry (audit finding 2026-05-02)',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository()
          ..insertThrows = StateError('audit_logs cutover offline');
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        Object? thrown;
        try {
          await gateway.toggleFlag(
            actorUserId: 'admin-uuid',
            flagId: 'flag-1',
            enabled: true,
            idempotencyKey: 'idem-atomic',
            adminReason: 'admin.test:enable_flag-1',
          );
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isA<StateError>());
        // The audit fake threw before recording; with the old
        // two-transaction shape the toggle would have committed
        // first and the unaudited state change would persist.
        expect(audit.events, isEmpty);

        // Cache slot was dropped on the failed compute; the next
        // clean call succeeds and produces both the toggle and the
        // audit row in one shot.
        audit.insertThrows = null;
        final result = await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-atomic',
          adminReason: 'admin.test:enable_flag-1',
        );
        expect(result, isNotNull);
        expect(audit.events, hasLength(1));
      },
    );

    test(
      'audit insert runs on the SAME executor as the toggle UPDATE '
      '(atomicity wiring)',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-wiring',
          adminReason: 'admin.test:enable_flag-1',
        );

        // The fake repo passes `_noopExec` to its onCommit callback;
        // the audit fake records the executor it was called with.
        // Identity check confirms the gateway routes the audit
        // through the toggle's transaction-scoped executor instead
        // of opening a fresh one via `insertSystemEvent`.
        expect(identical(audit.lastExec, _noopExec), isTrue,
            reason:
                'audit must run on the toggle transaction\'s executor');
      },
    );

    test(
      'compute failure removes the cache entry so a clean retry can '
      'succeed (Stripe-style idempotency)',
      () async {
        final flags = _RecordingFeatureFlagsRepository()
          ..throwOnNextCall = StateError('transient db blip')
          ..nextRow = _row(flagId: 'flag-1', enabled: true);
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        Object? firstError;
        try {
          await gateway.toggleFlag(
            actorUserId: 'admin-uuid',
            flagId: 'flag-1',
            enabled: true,
            idempotencyKey: 'idem-recover',
            adminReason: 'admin.test:enable_flag-1',
          );
        } catch (e) {
          firstError = e;
        }
        expect(firstError, isA<StateError>());

        // Same key, same payload — the entry was dropped on failure so
        // the retry runs fresh and succeeds.
        final result = await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-recover',
          adminReason: 'admin.test:enable_flag-1',
        );
        expect(result, isNotNull);
        expect(flags.toggleCalls, equals(2));
        expect(audit.events, hasLength(1));
      },
    );
  });

  group('FeatureFlagToggleIdempotencyCache LRU bound', () {
    test(
      'evicts the oldest entry when insertions exceed maxEntries',
      () async {
        final cache = FeatureFlagToggleIdempotencyCache(maxEntries: 2);
        Future<Map<String, Object?>?> ok(int n) async =>
            <String, Object?>{'n': n};

        await cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k1',
          payloadHash: 'h',
          compute: () => ok(1),
        );
        await cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k2',
          payloadHash: 'h',
          compute: () => ok(2),
        );
        // Third entry forces k1 (oldest) to evict.
        await cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k3',
          payloadHash: 'h',
          compute: () => ok(3),
        );
        expect(cache.length, equals(2));

        // k1 was evicted — re-running it computes fresh.
        var k1Calls = 0;
        await cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k1',
          payloadHash: 'h',
          compute: () async {
            k1Calls += 1;
            return ok(99);
          },
        );
        expect(k1Calls, equals(1));
      },
    );

    test(
      'in-flight entries are pinned from eviction; settled entries '
      'drain back to maxEntries without needing a fresh insert '
      '(audit findings 2026-05-02)',
      () async {
        final cache = FeatureFlagToggleIdempotencyCache(maxEntries: 1);
        final gate1 = Completer<Map<String, Object?>?>();
        final gate2 = Completer<Map<String, Object?>?>();

        // Two pending entries with maxEntries=1. The second insert
        // calls the trim helper which finds the oldest pending and
        // walks past it — so the cache temporarily holds both.
        final f1 = cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k1',
          payloadHash: 'h',
          compute: () => gate1.future,
        );
        final f2 = cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k2',
          payloadHash: 'h',
          compute: () => gate2.future,
        );
        expect(cache.length, equals(2),
            reason: 'pending entries are pinned from eviction');

        // A retry of k1 must hit the SAME pending Future. If the
        // first reviewer finding had not been fixed, k1 would have
        // been evicted on the second insert and this retry would
        // start a fresh compute — duplicate toggle, duplicate audit.
        var k1RecomputeCount = 0;
        final f1Retry = cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k1',
          payloadHash: 'h',
          compute: () async {
            k1RecomputeCount += 1;
            return <String, Object?>{'fresh_compute': true};
          },
        );
        expect(identical(f1, f1Retry), isTrue,
            reason:
                'pinned in-flight entry must replay the same Future on retry');
        expect(k1RecomputeCount, equals(0));

        // Release both pending. Each whenComplete microtask flips
        // isPending=false AND triggers a trim, so the cache drains
        // back to maxEntries without needing another insert. This
        // closes the second-pass audit gap: previously the cache
        // would stay oversize indefinitely after a settled burst.
        gate1.complete(<String, Object?>{'k': 'v1'});
        gate2.complete(<String, Object?>{'k': 'v2'});
        await f1;
        await f2;
        // Yield so both whenComplete microtasks run.
        await Future<void>.delayed(Duration.zero);
        expect(cache.length, equals(1),
            reason:
                'settled-entry whenComplete trim drains the cache back to '
                'maxEntries without a fresh insert');

        // A third insert lands on an already-bounded cache; trim is
        // a no-op (length stays 1 throughout: insert k3 → trim → 1).
        await cache.runOrReplay(
          requestType: 'r',
          idempotencyKey: 'k3',
          payloadHash: 'h',
          compute: () async => <String, Object?>{'k': 'v3'},
        );
        expect(cache.length, equals(1));
      },
    );

    test('cache hit promotes the entry under LRU eviction', () async {
      final cache = FeatureFlagToggleIdempotencyCache(maxEntries: 2);
      Future<Map<String, Object?>?> ok(int n) async =>
          <String, Object?>{'n': n};

      await cache.runOrReplay(
        requestType: 'r',
        idempotencyKey: 'k1',
        payloadHash: 'h',
        compute: () => ok(1),
      );
      await cache.runOrReplay(
        requestType: 'r',
        idempotencyKey: 'k2',
        payloadHash: 'h',
        compute: () => ok(2),
      );

      // Hit k1 — promotes it to most-recent.
      await cache.runOrReplay(
        requestType: 'r',
        idempotencyKey: 'k1',
        payloadHash: 'h',
        compute: () => ok(99),
      );

      // Insert k3 — k2 (now oldest) should evict, not k1.
      await cache.runOrReplay(
        requestType: 'r',
        idempotencyKey: 'k3',
        payloadHash: 'h',
        compute: () => ok(3),
      );

      // k1 still cached; k2 evicted.
      var k1Calls = 0;
      await cache.runOrReplay(
        requestType: 'r',
        idempotencyKey: 'k1',
        payloadHash: 'h',
        compute: () async {
          k1Calls += 1;
          return ok(100);
        },
      );
      expect(k1Calls, equals(0));

      var k2Calls = 0;
      await cache.runOrReplay(
        requestType: 'r',
        idempotencyKey: 'k2',
        payloadHash: 'h',
        compute: () async {
          k2Calls += 1;
          return ok(200);
        },
      );
      expect(k2Calls, equals(1));
    });
  });

  group('toggle route header validation', () {
    final clockNow = DateTime.utc(2026, 5, 2, 12);

    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    test(
      'POST /v1/admin/feature-flags/toggle returns 400 '
      'idempotency_key_missing without Idempotency-Key header',
      () async {
        await withRealHttp(() async {
          final ctx = await _spinUpToggleHarness(now: () => clockNow);
          try {
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'flag_id': 'flag-1',
                'enabled': true,
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('idempotency_key_missing'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST /v1/admin/feature-flags/toggle returns 400 '
      'idempotency_key_too_long for keys longer than 200 chars',
      () async {
        await withRealHttp(() async {
          final ctx = await _spinUpToggleHarness(now: () => clockNow);
          try {
            final oversized = 'x' * 201;
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
              authorization: 'Bearer fake.token',
              idempotencyKey: oversized,
              body: const <String, Object?>{
                'flag_id': 'flag-1',
                'enabled': true,
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('idempotency_key_too_long'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'POST toggle accepts a 200-character key (boundary)',
      () async {
        await withRealHttp(() async {
          final ctx = await _spinUpToggleHarness(now: () => clockNow);
          try {
            final atLimit = 'x' * 200;
            final response = await _httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminFeatureFlagsTogglePath),
              authorization: 'Bearer fake.token',
              idempotencyKey: atLimit,
              body: const <String, Object?>{
                'flag_id': 'flag-1',
                'enabled': true,
              },
            );
            expect(response.statusCode, equals(200));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

// ─── Test helpers ─────────────────────────────────────────────────

FeatureFlagRow _row({
  required String flagId,
  required bool enabled,
  String? operatorId,
  String? locationId,
}) {
  return FeatureFlagRow(
    flagId: flagId,
    flagName: 'feature_$flagId',
    operatorId: operatorId,
    locationId: locationId,
    enabled: enabled,
    kind: 'standard',
    description: null,
    updatedBy: 'admin-uuid',
    createdAt: DateTime.utc(2026, 5, 2, 10),
    updatedAt: DateTime.utc(2026, 5, 2, 12),
  );
}

class _UnusedPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnimplementedError(
      'fake repositories override every method, never touching the pool',
    );
  }
}

final TenantTransactionWrapper _unusedWrapper =
    TenantTransactionWrapper(_UnusedPool());

/// Stub executor handed to the [onCommit] callback in tests. The
/// fake repositories never actually issue SQL, so any call here is
/// a bug — fail loudly instead of silently swallowing.
class _NoopExecutor implements PostgresExecutor {
  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) {
    throw StateError(
      'fake repository onCommit handed _NoopExecutor.query a real call: $sql',
    );
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) {
    throw StateError(
      'fake repository onCommit handed _NoopExecutor.execute a real call: $sql',
    );
  }
}

final _NoopExecutor _noopExec = _NoopExecutor();

class _RecordingFeatureFlagsRepository extends FeatureFlagsRepository {
  _RecordingFeatureFlagsRepository() : super(_unusedWrapper);

  FeatureFlagRow? nextRow;
  Object? throwOnNextCall;
  Object? onCommitThrows;
  int toggleCalls = 0;

  @override
  Future<FeatureFlagRow?> toggleFlag({
    required String flagId,
    required bool enabled,
    required String actorUserId,
    required String adminReason,
    Future<void> Function(PostgresExecutor exec, FeatureFlagRow row)? onCommit,
  }) async {
    toggleCalls += 1;
    final raise = throwOnNextCall;
    if (raise != null) {
      throwOnNextCall = null;
      throw raise;
    }
    final row = nextRow;
    if (row == null) return null;
    if (onCommit != null) {
      try {
        await onCommit(_noopExec, row);
      } catch (e) {
        // Mimic the real repo: if onCommit throws, the transaction
        // rolls back — meaning the flag mutation is reverted. We
        // model this by NOT returning the row (caller's downstream
        // assertions on toggleCalls still see the increment, which
        // matches reality: the UPDATE ran but was rolled back).
        rethrow;
      }
    }
    final injected = onCommitThrows;
    if (injected != null) {
      onCommitThrows = null;
      throw injected;
    }
    return row;
  }
}

class _RecordingAuditRepository extends AuthEventsAuditRepository {
  _RecordingAuditRepository() : super(_unusedWrapper);

  final List<_RecordedAuditEvent> events = <_RecordedAuditEvent>[];
  Object? insertThrows;

  /// Captures the [PostgresExecutor] handed to the most recent
  /// `insertSystemEventOn` call. The atomicity-wiring test asserts
  /// this equals the executor the flag-fake gave to its onCommit
  /// callback — confirming the audit runs inside the toggle's
  /// transaction.
  PostgresExecutor? lastExec;

  @override
  Future<String> insertSystemEventOn(
    PostgresExecutor exec, {
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
  }) async {
    lastExec = exec;
    final raise = insertThrows;
    if (raise != null) {
      insertThrows = null;
      throw raise;
    }
    events.add(_RecordedAuditEvent(eventType: eventType, payload: payload));
    return 'event-${events.length}';
  }
}

class _RecordedAuditEvent {
  const _RecordedAuditEvent({
    required this.eventType,
    required this.payload,
  });
  final String eventType;
  final Map<String, Object?> payload;
}

// ─── HTTP harness for header-validation tests ─────────────────────

Future<({HttpServer server, HttpClient client, Uri baseUri})>
    _spinUpToggleHarness({
  required DateTime Function() now,
}) async {
  final flags = _RecordingFeatureFlagsRepository()
    ..nextRow = _row(flagId: 'flag-1', enabled: true);
  final audit = _RecordingAuditRepository();
  final gateway = RepositoryFeatureFlagsAdminProxyGateway(
    featureFlagsRepository: flags,
    auditRepository: audit,
  );
  const adminUuid = '11111111-1111-4111-8111-111111111111';
  final verifier = _ConstantVerifier(
    const ProxyJwtClaims(
      userId: adminUuid,
      firebaseUid: adminUuid,
      operatorId: null,
      locationId: null,
      roles: <String>['super_admin'],
    ),
  );
  final guard = ProxyRequestGuard(verifier: verifier);
  final resolver = _EchoActorResolver();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    try {
      await routeRequest(
        request,
        guard,
        featureFlagsAdminGateway: gateway,
        integrationAdminActorResolver: resolver,
        now: now,
      );
    } catch (_) {
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {}
    }
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

class _ConstantVerifier implements ProxyJwtVerifier {
  _ConstantVerifier(this.claims);
  final ProxyJwtClaims claims;
  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _EchoActorResolver implements IntegrationAdminActorResolver {
  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) async {
    return firebaseUid;
  }
}

class _HttpResponseSnapshot {
  _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  String? authorization,
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  } else {
    request.contentLength = 0;
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}

