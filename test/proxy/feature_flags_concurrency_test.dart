// HARD-D — concurrent-retry idempotency test for the feature flag
// toggle gateway.
//
// The contract requires that two same-key retries arriving before
// either has finished collapse to one DB toggle and one audit row.
// Dart is single-threaded, so `concurrent` here means "second call
// fires while the first is still awaiting its compute". The cache's
// synchronous prefix (lookup + reservation before any await) is what
// makes the second arrival find the first arrival's pending Future
// instead of opening a second compute path.
//
// The fake repository uses a Completer the test controls so the test
// can land both calls in the cache before either resolves, then
// release the underlying toggle, then assert exactly one DB call +
// one audit row + identical response bodies.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/feature_flags_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('toggleFlag concurrent same-key retries', () {
    test(
      'two simultaneous calls collapse to one DB toggle + one audit row',
      () async {
        final flags = _GatedFeatureFlagsRepository(
          row: _row(flagId: 'flag-1', enabled: true),
        );
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        // Fire both calls before either has resolved. The first call
        // enters the cache's sync prefix, inserts a pending Future,
        // then awaits the gated repo. The second call enters the
        // cache's sync prefix, finds the pending Future, and awaits
        // the same one.
        final fut1 = gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-concurrent',
          adminReason: 'admin.test:enable_flag-1',
        );
        final fut2 = gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-concurrent',
          adminReason: 'admin.test:enable_flag-1',
        );

        // Confirm the second call is sharing the first call's Future.
        // `identical` is the right check here — `runOrReplay` returns
        // the same Future object on a hit, not just an equal value.
        expect(identical(fut1, fut2), isTrue,
            reason: 'cache must hand both arrivals the same Future');

        // Now let the underlying toggle resolve and await both.
        flags.release();
        final r1 = await fut1;
        final r2 = await fut2;

        expect(identical(r1, r2), isTrue);
        expect(r1, isNotNull);
        expect(r1!['flag_id'], equals('flag-1'));
        expect(flags.toggleCalls, equals(1),
            reason: 'concurrent retry must NOT trigger a second DB toggle');
        expect(audit.events, hasLength(1),
            reason: 'concurrent retry must NOT emit a second audit row');
      },
    );

    test(
      'three same-key calls during in-flight first call all share one '
      'compute',
      () async {
        final flags = _GatedFeatureFlagsRepository(
          row: _row(flagId: 'flag-1', enabled: true),
        );
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        Future<Map<String, Object?>?> fire() => gateway.toggleFlag(
              actorUserId: 'admin-uuid',
              flagId: 'flag-1',
              enabled: true,
              idempotencyKey: 'idem-fanout',
              adminReason: 'admin.test:enable_flag-1',
            );

        final futures = <Future<Map<String, Object?>?>>[
          fire(),
          fire(),
          fire(),
        ];

        flags.release();
        final results = await Future.wait(futures);
        expect(results, hasLength(3));
        expect(identical(results[0], results[1]), isTrue);
        expect(identical(results[1], results[2]), isTrue);
        expect(flags.toggleCalls, equals(1));
        expect(audit.events, hasLength(1));
      },
    );

    test(
      'compute failure on the in-flight call propagates to all '
      'concurrent retries and frees the cache slot',
      () async {
        final flags = _GatedFeatureFlagsRepository(
          row: _row(flagId: 'flag-1', enabled: true),
        )..failureOnRelease = StateError('transient db blip');
        final audit = _RecordingAuditRepository();
        final gateway = RepositoryFeatureFlagsAdminProxyGateway(
          featureFlagsRepository: flags,
          auditRepository: audit,
        );

        final fut1 = gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-fail',
          adminReason: 'admin.test:enable_flag-1',
        );
        final fut2 = gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-fail',
          adminReason: 'admin.test:enable_flag-1',
        );

        flags.release();

        Object? err1;
        Object? err2;
        try {
          await fut1;
        } catch (e) {
          err1 = e;
        }
        try {
          await fut2;
        } catch (e) {
          err2 = e;
        }
        expect(err1, isA<StateError>());
        expect(err2, isA<StateError>());
        // Single compute even on failure — both arrivals share the same
        // failed Future.
        expect(flags.toggleCalls, equals(1));
        expect(audit.events, isEmpty);

        // The cache entry was dropped on failure; a clean retry now
        // succeeds.
        flags
          ..failureOnRelease = null
          ..reset();
        final retry = await gateway.toggleFlag(
          actorUserId: 'admin-uuid',
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'idem-fail',
          adminReason: 'admin.test:enable_flag-1',
        );
        expect(retry, isNotNull);
        expect(flags.toggleCalls, equals(1),
            reason: 'reset() zeroed the counter; one fresh toggle ran');
        expect(audit.events, hasLength(1));
      },
    );
  });
}

// ─── Test helpers ─────────────────────────────────────────────────

FeatureFlagRow _row({
  required String flagId,
  required bool enabled,
}) {
  return FeatureFlagRow(
    flagId: flagId,
    flagName: 'feature_$flagId',
    operatorId: null,
    locationId: null,
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

/// Repository that defers `toggleFlag` resolution until [release] is
/// called, so two test-side calls can both land in the cache before
/// either resolves. This is what lets us assert "concurrent retries
/// collapse to one DB call" — without the gate, Dart's microtask
/// scheduling would resolve the first toggle before the second call
/// got a chance to enter the cache.
class _GatedFeatureFlagsRepository extends FeatureFlagsRepository {
  _GatedFeatureFlagsRepository({required this.row}) : super(_unusedWrapper);

  final FeatureFlagRow row;
  Object? failureOnRelease;
  int toggleCalls = 0;
  Completer<void>? _gate = Completer<void>();

  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  /// Re-arms the gate so a second test scenario can run on the same
  /// repository instance. Resets the call counter too.
  void reset() {
    toggleCalls = 0;
    _gate = Completer<void>();
    // Auto-release the new gate on the next microtask so a single
    // post-failure retry doesn't block waiting for an explicit
    // release() the test would otherwise have to remember to call.
    scheduleMicrotask(() => release());
  }

  @override
  Future<FeatureFlagRow?> toggleFlag({
    required String flagId,
    required bool enabled,
    required String actorUserId,
    required String adminReason,
    Future<void> Function(PostgresExecutor exec, FeatureFlagRow row)? onCommit,
  }) async {
    toggleCalls += 1;
    await _gate?.future;
    final raise = failureOnRelease;
    if (raise != null) throw raise;
    if (onCommit != null) {
      await onCommit(_noopExec, row);
    }
    return row;
  }
}

class _RecordingAuditRepository extends AuthEventsAuditRepository {
  _RecordingAuditRepository() : super(_unusedWrapper);

  final List<String> events = <String>[];

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
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    String? adminReason,
  }) async {
    events.add(eventType);
    return 'event-${events.length}';
  }
}
