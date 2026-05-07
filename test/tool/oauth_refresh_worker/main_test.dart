// Phase 8 — oauth_refresh_worker tests.
//
// Covers the five scenarios called out in the slice prompt, against
// in-memory fakes (no live Postgres, no live vendor HTTP):
//
//   * happy refresh — claim → broker.refreshAccessToken called →
//     recordRefreshSuccess → success counter advances.
//   * SKIP LOCKED contention — two parallel ticks against a single
//     available row; only one claims it (the in-memory fake mirrors
//     the migration's `FOR UPDATE SKIP LOCKED` semantics).
//   * cap-and-disable — a row that fails 3 times trips
//     autoDisableConnection exactly once.
//   * vendor without refresh closure — the row is logged-and-skipped
//     (skippedNoCloser counter advances); no failure-count
//     increment, no autoDisable, no broker call.
//   * SIGTERM mid-tick — the loop's shouldStop hook fires between
//     rows so the second row in the same tick is not processed.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';

import '../../../tool/oauth_refresh_worker/main.dart';

const String _opIdA = '11111111-1111-4111-8111-111111111111';
const String _locIdA = '22222222-2222-4222-8222-222222222222';
const String _credIdA = '33333333-3333-4333-8333-333333333333';
const String _credIdB = '44444444-4444-4444-8444-444444444444';
const String _vendorWithCloser = 'lightspeed_lsk';
const String _vendorWithoutCloser = 'tock';

void main() {
  group('runWorkerTick', () {
    test(
      'happy path: claim → broker.refreshAccessToken → recordRefreshSuccess',
      () async {
        final gateway = _FakeGateway()
          ..addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdA,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: 0,
            ),
          );
        final broker = _RecordingBroker();
        final closure = _AlwaysSucceedClosure();

        final result = await runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: <String, RefreshClosure>{
            _vendorWithCloser: closure.call,
          },
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
        );

        expect(result.candidatesScanned, 1);
        expect(result.refreshSuccesses, 1);
        expect(result.refreshFailures, 0);
        expect(result.skippedNoCloser, 0);
        expect(result.autoDisabled, 0);
        expect(broker.refreshCalls, 1);
        expect(broker.lastRefreshArgs?.vendorId, _vendorWithCloser);
        expect(gateway.recordedSuccesses, hasLength(1));
        expect(gateway.recordedSuccesses.single.credentialId, _credIdA);
        expect(gateway.recordedFailures, isEmpty);
        expect(gateway.autoDisabledRows, isEmpty);
      },
    );

    test(
      'SKIP LOCKED: only one of two parallel ticks claims a single row',
      () async {
        // The fake gateway models `FOR UPDATE SKIP LOCKED`: each
        // enqueued row is handed out exactly once across all
        // concurrent claimers.
        final gateway = _FakeGateway()
          ..addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdA,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: 0,
            ),
          );
        final brokerA = _RecordingBroker();
        final brokerB = _RecordingBroker();
        final closureA = _AlwaysSucceedClosure();
        final closureB = _AlwaysSucceedClosure();

        final futures = <Future<WorkerTickResult>>[
          runWorkerTick(
            gateway: gateway,
            broker: brokerA,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closureA.call,
            },
            maxRowsPerTick: 50,
            maxConsecutiveFailures: 3,
            horizon: const Duration(minutes: 5),
          ),
          runWorkerTick(
            gateway: gateway,
            broker: brokerB,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closureB.call,
            },
            maxRowsPerTick: 50,
            maxConsecutiveFailures: 3,
            horizon: const Duration(minutes: 5),
          ),
        ];
        final results = await Future.wait(futures);

        final totalSuccesses = results.fold<int>(
          0,
          (acc, r) => acc + r.refreshSuccesses,
        );
        expect(
          totalSuccesses,
          1,
          reason:
              'SKIP LOCKED: a single available row must be refreshed exactly once '
              'across two concurrent worker ticks',
        );
        expect(brokerA.refreshCalls + brokerB.refreshCalls, 1);
      },
    );

    test(
      'cap-and-disable: 3 consecutive failures trips autoDisable once',
      () async {
        // Each tick claims the same single row whose failure count is
        // incremented by 1 per failure. We drive the gateway directly:
        // the worker's loop is called three times.
        final gateway = _FakeGateway();
        final broker = _AlwaysFailBroker();
        final closure = _AlwaysSucceedClosure();

        final config = _Config(
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
        );

        for (var i = 1; i <= 3; i += 1) {
          gateway.addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdA,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: i - 1,
            ),
          );
          await runWorkerTick(
            gateway: gateway,
            broker: broker,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closure.call,
            },
            maxRowsPerTick: config.maxRowsPerTick,
            maxConsecutiveFailures: config.maxConsecutiveFailures,
            horizon: config.horizon,
          );
        }

        expect(gateway.recordedFailures, hasLength(3));
        expect(
          gateway.autoDisabledRows,
          hasLength(1),
          reason:
              'autoDisable fires exactly once on the post-increment count >= '
              'threshold; subsequent ticks would no longer claim the row '
              'because is_active=false in the real schema',
        );
        final disabled = gateway.autoDisabledRows.single;
        expect(disabled.credentialId, _credIdA);
        expect(disabled.consecutiveFailures, 3);
        expect(disabled.errorMessage, contains('boom'));
      },
    );

    test(
      'vendor without refresh closure: row is logged-and-skipped',
      () async {
        // The fake gateway returns a row for `tock` (no closure). The
        // worker must NOT increment failures, NOT call broker, and
        // NOT auto-disable. The skippedNoCloser counter advances.
        final gateway = _FakeGateway()
          ..addClaimable(
            ClaimedCredentialRow(
              credentialId: _credIdB,
              operatorId: _opIdA,
              locationId: _locIdA,
              vendorId: _vendorWithoutCloser,
              consecutiveFailuresBefore: 0,
            ),
          );
        final broker = _RecordingBroker();

        final result = await runWorkerTick(
          gateway: gateway,
          broker: broker,
          // Empty registry — no closure for `tock`.
          refreshClosures: const <String, RefreshClosure>{},
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
        );

        expect(result.skippedNoCloser, 1);
        expect(result.refreshSuccesses, 0);
        expect(result.refreshFailures, 0);
        expect(result.autoDisabled, 0);
        expect(broker.refreshCalls, 0);
        expect(gateway.recordedSuccesses, isEmpty);
        expect(gateway.recordedFailures, isEmpty);
        expect(gateway.autoDisabledRows, isEmpty);
        expect(
          kVendorsWithoutRefreshClosure,
          contains(_vendorWithoutCloser),
          reason:
              'tock is in the documented coverage list of vendors without an '
              'OAuth refresh closure',
        );
      },
    );

    test('shouldStop fires between rows', () async {
      // Two rows in one tick. shouldStop returns true after the first
      // row is processed; the second row must not be touched.
      final gateway = _FakeGateway()
        ..addClaimable(
          ClaimedCredentialRow(
            credentialId: _credIdA,
            operatorId: _opIdA,
            locationId: _locIdA,
            vendorId: _vendorWithCloser,
            consecutiveFailuresBefore: 0,
          ),
        )
        ..addClaimable(
          ClaimedCredentialRow(
            credentialId: _credIdB,
            operatorId: _opIdA,
            locationId: _locIdA,
            vendorId: _vendorWithCloser,
            consecutiveFailuresBefore: 0,
          ),
        );
      final broker = _RecordingBroker();
      final closure = _AlwaysSucceedClosure();

      var brokerCallCount = 0;
      final result = await runWorkerTick(
        gateway: gateway,
        broker: _StopAfterFirstBroker(broker, () {
          brokerCallCount += 1;
        }),
        refreshClosures: <String, RefreshClosure>{
          _vendorWithCloser: closure.call,
        },
        maxRowsPerTick: 50,
        maxConsecutiveFailures: 3,
        horizon: const Duration(minutes: 5),
        shouldStop: () => brokerCallCount >= 1,
      );

      expect(result.candidatesScanned, 2);
      expect(
        result.refreshSuccesses,
        1,
        reason:
            'shouldStop fires after the first broker call; second row is left '
            'for the next tick',
      );
    });
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _Config {
  _Config({
    required this.maxRowsPerTick,
    required this.maxConsecutiveFailures,
    required this.horizon,
  });

  final int maxRowsPerTick;
  final int maxConsecutiveFailures;
  final Duration horizon;
}

class _FakeGateway implements OAuthRefreshWorkerGateway {
  final List<ClaimedCredentialRow> _claimable = <ClaimedCredentialRow>[];
  final List<_RecordedSuccess> recordedSuccesses = <_RecordedSuccess>[];
  final List<_RecordedFailure> recordedFailures = <_RecordedFailure>[];
  final List<_AutoDisabledRow> autoDisabledRows = <_AutoDisabledRow>[];

  void addClaimable(ClaimedCredentialRow row) {
    _claimable.add(row);
  }

  @override
  Future<List<ClaimedCredentialRow>> claimNearExpiryRows({
    required DateTime now,
    required Duration horizon,
    required int maxRows,
  }) async {
    if (_claimable.isEmpty) return const <ClaimedCredentialRow>[];
    final n = _claimable.length < maxRows ? _claimable.length : maxRows;
    final claimed = _claimable.sublist(0, n);
    _claimable.removeRange(0, n);
    return claimed;
  }

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    recordedFailures.add(_RecordedFailure(
      credentialId: credentialId,
      vendorId: vendorId,
      errorMessage: errorMessage,
    ));
    // Mirrors the production semantics: post-increment count =
    // pre-claim + 1.
    return recordedFailures
        .where((row) => row.credentialId == credentialId)
        .length;
  }

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    recordedSuccesses.add(_RecordedSuccess(
      credentialId: credentialId,
      vendorId: vendorId,
    ));
  }

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String errorMessage,
    required int consecutiveFailures,
  }) async {
    autoDisabledRows.add(_AutoDisabledRow(
      credentialId: credentialId,
      vendorId: vendorId,
      errorMessage: errorMessage,
      consecutiveFailures: consecutiveFailures,
    ));
  }
}

class _RecordedSuccess {
  _RecordedSuccess({required this.credentialId, required this.vendorId});
  final String credentialId;
  final String vendorId;
}

class _RecordedFailure {
  _RecordedFailure({
    required this.credentialId,
    required this.vendorId,
    required this.errorMessage,
  });
  final String credentialId;
  final String vendorId;
  final String errorMessage;
}

class _AutoDisabledRow {
  _AutoDisabledRow({
    required this.credentialId,
    required this.vendorId,
    required this.errorMessage,
    required this.consecutiveFailures,
  });
  final String credentialId;
  final String vendorId;
  final String errorMessage;
  final int consecutiveFailures;
}

/// Recording fake of [VendorCredentialBroker]. The production broker
/// extends OperatorScopedRepository which forces a TenantTransactionWrapper
/// in the constructor; we subclass it but override every method the
/// worker calls so the parent's tenant-transaction wiring is never
/// touched.
class _RecordingBroker extends VendorCredentialBroker {
  _RecordingBroker()
      : super(
          tenantWrapper: _buildUnusedTenantWrapper(),
          pgcryptoEnvelopeKey: 'test',
        );

  int refreshCalls = 0;
  _RefreshArgs? lastRefreshArgs;

  @override
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    refreshCalls += 1;
    lastRefreshArgs = _RefreshArgs(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
    return 'access-token-stub';
  }
}

class _StopAfterFirstBroker extends VendorCredentialBroker {
  _StopAfterFirstBroker(this._delegate, this._onCall)
      : super(
          tenantWrapper: _buildUnusedTenantWrapper(),
          pgcryptoEnvelopeKey: 'test',
        );

  final _RecordingBroker _delegate;
  final void Function() _onCall;

  @override
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    final result = await _delegate.refreshAccessToken(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      doRefresh: doRefresh,
    );
    _onCall();
    return result;
  }
}

class _AlwaysFailBroker extends VendorCredentialBroker {
  _AlwaysFailBroker()
      : super(
          tenantWrapper: _buildUnusedTenantWrapper(),
          pgcryptoEnvelopeKey: 'test',
        );

  @override
  Future<String> refreshAccessToken({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Future<TokenRefreshResult> Function(VendorCredentialBundle)
        doRefresh,
  }) async {
    throw const VendorRefreshFailed('boom: synthetic test failure');
  }
}

class _RefreshArgs {
  _RefreshArgs({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
  });
  final String operatorId;
  final String locationId;
  final String vendorId;
}

class _AlwaysSucceedClosure {
  Future<TokenRefreshResult> call(VendorCredentialBundle current) async {
    return TokenRefreshResult(
      accessToken: 'new-access-token',
      refreshToken: 'new-refresh-token',
      expiresAt: DateTime.utc(2026, 5, 7).add(const Duration(hours: 1)),
    );
  }
}

/// Minimal [PostgresPool] for satisfying [TenantTransactionWrapper]'s
/// constructor in tests. The broker subclasses below override
/// `refreshAccessToken` so this pool is never actually used; if a
/// path ever does invoke `beginTransaction` the test fails loud.
class _UnusedPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw StateError(
      '_UnusedPostgresPool.beginTransaction called; broker subclasses in '
      'this test must override every method the worker invokes',
    );
  }
}

TenantTransactionWrapper _buildUnusedTenantWrapper() {
  return TenantTransactionWrapper(_UnusedPostgresPool());
}
