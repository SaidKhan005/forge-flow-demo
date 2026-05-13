// C-2-F — oauth_refresh_worker + auto-disabled email dispatcher
// integration test.
//
// Drives `runWorkerTick` with a fake gateway + fake dispatcher to
// confirm:
//
//   * On the 3rd consecutive failure (the cap trip), the worker calls
//     the dispatcher exactly ONCE per cap trip with the correct
//     arguments (operator + location + credential + vendor + strike
//     count + error message).
//   * The dispatcher is NOT called on the 1st or 2nd failure (those
//     do not trip the cap).
//   * The dispatcher is NOT called on successful refreshes.
//   * The dispatcher is NOT called on the unexpected-error branch
//     unless the cap is tripped (consecutiveFailures < max means no
//     auto-disable, no email).
//   * When the dispatcher is omitted (null), the worker still flips
//     status as today — no email enqueue, but no regression either.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';

import '../../tool/oauth_refresh_worker/main.dart';
import '../../tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart';

const String _opId = '11111111-1111-4111-8111-111111111111';
const String _locId = '22222222-2222-4222-8222-222222222222';
const String _credId = '33333333-3333-4333-8333-333333333333';
const String _vendorWithCloser = 'lightspeed_lsk';

void main() {
  group('runWorkerTick auto-disabled email dispatcher wiring', () {
    test(
      '3rd consecutive failure trips cap → dispatcher called exactly once',
      () async {
        final gateway = _FakeGateway();
        final broker = _AlwaysFailBroker();
        final closure = _AlwaysSucceedClosure();
        final dispatcher = _RecordingDispatcher();

        // Three ticks back-to-back. Each tick claims one row; the
        // gateway's recorded failures track the strike count.
        for (var i = 0; i < 3; i++) {
          gateway.addClaimable(
            ClaimedCredentialRow(
              credentialId: _credId,
              operatorId: _opId,
              locationId: _locId,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: i,
            ),
          );
          await runWorkerTick(
            gateway: gateway,
            broker: broker,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closure.call,
            },
            maxRowsPerTick: 50,
            maxConsecutiveFailures: 3,
            horizon: const Duration(minutes: 5),
            autoDisabledEmailDispatcher: dispatcher.dispatcher,
          );
        }

        expect(gateway.autoDisabledRows, hasLength(1));
        expect(dispatcher.calls, hasLength(1));
        final call = dispatcher.calls.single;
        expect(call.operatorId, _opId);
        expect(call.locationId, _locId);
        expect(call.credentialId, _credId);
        expect(call.vendorId, _vendorWithCloser);
        expect(call.consecutiveFailures, 3);
        expect(call.errorMessage, isNotEmpty);
      },
    );

    test('1st + 2nd failures → no dispatcher call', () async {
      final gateway = _FakeGateway();
      final broker = _AlwaysFailBroker();
      final closure = _AlwaysSucceedClosure();
      final dispatcher = _RecordingDispatcher();

      for (var i = 0; i < 2; i++) {
        gateway.addClaimable(
          ClaimedCredentialRow(
            credentialId: _credId,
            operatorId: _opId,
            locationId: _locId,
            vendorId: _vendorWithCloser,
            consecutiveFailuresBefore: i,
          ),
        );
        await runWorkerTick(
          gateway: gateway,
          broker: broker,
          refreshClosures: <String, RefreshClosure>{
            _vendorWithCloser: closure.call,
          },
          maxRowsPerTick: 50,
          maxConsecutiveFailures: 3,
          horizon: const Duration(minutes: 5),
          autoDisabledEmailDispatcher: dispatcher.dispatcher,
        );
      }

      expect(gateway.autoDisabledRows, isEmpty);
      expect(dispatcher.calls, isEmpty);
    });

    test('successful refresh → no dispatcher call', () async {
      final gateway = _FakeGateway()
        ..addClaimable(
          ClaimedCredentialRow(
            credentialId: _credId,
            operatorId: _opId,
            locationId: _locId,
            vendorId: _vendorWithCloser,
            consecutiveFailuresBefore: 0,
          ),
        );
      final broker = _SuccessBroker();
      final closure = _AlwaysSucceedClosure();
      final dispatcher = _RecordingDispatcher();

      final result = await runWorkerTick(
        gateway: gateway,
        broker: broker,
        refreshClosures: <String, RefreshClosure>{
          _vendorWithCloser: closure.call,
        },
        maxRowsPerTick: 50,
        maxConsecutiveFailures: 3,
        horizon: const Duration(minutes: 5),
        autoDisabledEmailDispatcher: dispatcher.dispatcher,
      );

      expect(result.refreshSuccesses, 1);
      expect(result.autoDisabled, 0);
      expect(dispatcher.calls, isEmpty);
    });

    test(
      'dispatcher null → worker still flips status (no regression)',
      () async {
        final gateway = _FakeGateway();
        final broker = _AlwaysFailBroker();
        final closure = _AlwaysSucceedClosure();

        for (var i = 0; i < 3; i++) {
          gateway.addClaimable(
            ClaimedCredentialRow(
              credentialId: _credId,
              operatorId: _opId,
              locationId: _locId,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: i,
            ),
          );
          await runWorkerTick(
            gateway: gateway,
            broker: broker,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closure.call,
            },
            maxRowsPerTick: 50,
            maxConsecutiveFailures: 3,
            horizon: const Duration(minutes: 5),
            // autoDisabledEmailDispatcher omitted (null).
          );
        }

        expect(gateway.autoDisabledRows, hasLength(1));
      },
    );

    test(
      'dispatcher throw is swallowed (cap trip path is not poisoned)',
      () async {
        // The dispatcher is documented as swallowing its own errors —
        // confirm a dispatcher that throws inside its own internals
        // does not propagate out of `runWorkerTick`.
        final gateway = _FakeGateway();
        final broker = _AlwaysFailBroker();
        final closure = _AlwaysSucceedClosure();
        // Build a real dispatcher with a throwing enqueue repository
        // to exercise the swallow path end-to-end.
        final throwingDispatcher = VendorConnectionAutoDisabledDispatcher(
          enqueueRepository: _ThrowingEnqueue(),
          recipientResolver: ({required String operatorId}) async =>
              const AutoDisabledRecipient(
                recipientEmail: 'owner@acme.test',
                businessName: 'Acme Bistro',
              ),
          now: () => DateTime.utc(2026, 5, 13, 14, 5),
        );

        for (var i = 0; i < 3; i++) {
          gateway.addClaimable(
            ClaimedCredentialRow(
              credentialId: _credId,
              operatorId: _opId,
              locationId: _locId,
              vendorId: _vendorWithCloser,
              consecutiveFailuresBefore: i,
            ),
          );
          // Must not throw.
          await runWorkerTick(
            gateway: gateway,
            broker: broker,
            refreshClosures: <String, RefreshClosure>{
              _vendorWithCloser: closure.call,
            },
            maxRowsPerTick: 50,
            maxConsecutiveFailures: 3,
            horizon: const Duration(minutes: 5),
            autoDisabledEmailDispatcher: throwingDispatcher,
          );
        }

        // The auto-disable cap was still tripped exactly once.
        expect(gateway.autoDisabledRows, hasLength(1));
      },
    );
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

class _FakeGateway implements OAuthRefreshWorkerGateway {
  final List<ClaimedCredentialRow> _claimable = <ClaimedCredentialRow>[];
  final Map<String, int> _failureCounts = <String, int>{};
  final List<String> autoDisabledRows = <String>[];

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
    final current = (_failureCounts[credentialId] ?? 0) + 1;
    _failureCounts[credentialId] = current;
    return current;
  }

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    _failureCounts.remove(credentialId);
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
    autoDisabledRows.add(credentialId);
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
    throw const VendorRefreshFailed('invalid_grant');
  }
}

class _SuccessBroker extends VendorCredentialBroker {
  _SuccessBroker()
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
    return 'access-token-stub';
  }
}

class _AlwaysSucceedClosure {
  Future<TokenRefreshResult> call(VendorCredentialBundle bundle) async {
    return TokenRefreshResult(
      accessToken: 'access-token-stub',
      refreshToken: 'refresh-token-stub',
      expiresAt: DateTime.utc(2030, 1, 1),
    );
  }
}

/// Build an unused TenantTransactionWrapper. The fake brokers we
/// subclass never reach the parent's transaction wiring, so the
/// wrapper is a placeholder that no real query runs through.
TenantTransactionWrapper _buildUnusedTenantWrapper() {
  return TenantTransactionWrapper(_UnusedPool());
}

class _UnusedPool implements PostgresPool {
  @override
  noSuchMethod(Invocation invocation) {
    throw StateError(
      '_UnusedPool reached: '
      'broker fakes were expected to override every method',
    );
  }
}

class _RecordingDispatcher {
  _RecordingDispatcher() {
    dispatcher = VendorConnectionAutoDisabledDispatcher(
      enqueueRepository: _RecordingEnqueue(_register),
      recipientResolver: ({required String operatorId}) async =>
          const AutoDisabledRecipient(
            recipientEmail: 'owner@acme.test',
            businessName: 'Acme Bistro',
          ),
      now: () => DateTime.utc(2026, 5, 13, 14, 5),
    );
  }

  late final VendorConnectionAutoDisabledDispatcher dispatcher;
  final List<_DispatcherCall> calls = <_DispatcherCall>[];

  void _register(_DispatcherCall call) => calls.add(call);
}

class _RecordingEnqueue implements AutoDisabledEmailEnqueueRepository {
  _RecordingEnqueue(this._register);

  final void Function(_DispatcherCall call) _register;
  int _counter = 0;

  @override
  Future<String?> enqueueAutoDisabledEmail({
    required String operatorId,
    required String locationId,
    required String credentialId,
    required String vendorId,
    required String templateId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required String idempotencyKey,
    required DateTime occurredAt,
    required int consecutiveFailures,
    required String errorMessage,
  }) async {
    _register(_DispatcherCall(
      operatorId: operatorId,
      locationId: locationId,
      credentialId: credentialId,
      vendorId: vendorId,
      consecutiveFailures: consecutiveFailures,
      errorMessage: errorMessage,
    ));
    _counter += 1;
    return 'email-$_counter';
  }
}

class _DispatcherCall {
  _DispatcherCall({
    required this.operatorId,
    required this.locationId,
    required this.credentialId,
    required this.vendorId,
    required this.consecutiveFailures,
    required this.errorMessage,
  });

  final String operatorId;
  final String locationId;
  final String credentialId;
  final String vendorId;
  final int consecutiveFailures;
  final String errorMessage;
}

class _ThrowingEnqueue implements AutoDisabledEmailEnqueueRepository {
  @override
  Future<String?> enqueueAutoDisabledEmail({
    required String operatorId,
    required String locationId,
    required String credentialId,
    required String vendorId,
    required String templateId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required String idempotencyKey,
    required DateTime occurredAt,
    required int consecutiveFailures,
    required String errorMessage,
  }) async {
    throw StateError('synthetic enqueue failure');
  }
}
