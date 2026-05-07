// Phase 8.0 (V1 lean cut 2) — OAuth refresh cron tests.
//
// Drives [OAuthRefreshCronRunner] through the success / failure /
// 3-strike auto-disable branches with an in-memory gateway + stub
// refresher. V1 lean cut 2 changes from iter1:
//   * No `pg_advisory_lock` / `tryAcquireAdvisoryLock` /
//     `releaseAdvisoryLock` assertions.
//   * No `email_outbox` emit assertion. The cron writes audit_logs
//     and flips status to `error`; email wiring lands later.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/oauth_refresh_cron.dart';

void main() {
  group('OAuthRefreshCronRunner', () {
    late _FakeGateway gateway;
    late _StubRefresher refresher;
    late OAuthRefreshCronRunner runner;

    setUp(() {
      gateway = _FakeGateway();
      refresher = _StubRefresher(vendorId: 'lightspeed_lsk');
      runner = OAuthRefreshCronRunner(
        gateway: gateway,
        refreshers: <String, VendorOAuthRefresher>{
          refresher.vendorId: refresher,
        },
      );
    });

    test('successful refresh: persists envelope, resets failures', () async {
      gateway.candidates.add(_credRow(
        credentialId: 'cred-1',
        operatorId: '00000000-0000-4000-8000-000000000001',
        vendorId: 'lightspeed_lsk',
        consecutiveFailures: 0,
      ));
      refresher.outcomeQueue.add(VendorRefreshOutcome.success(
        newAccessTokenCiphertext: const <int>[1, 2, 3],
        newRefreshTokenCiphertext: const <int>[4, 5, 6],
        newExpiresAt: DateTime.utc(2026, 5, 5),
      ));

      final result = await runner.runOnce();
      expect(result.candidatesScanned, 1);
      expect(result.refreshSuccesses, 1);
      expect(result.refreshFailures, 0);
      expect(result.autoDisabled, 0);
      expect(gateway.successesRecorded.length, 1);
    });

    test('3-strike auto-disable on third consecutive failure '
        '(status flips to error; no email_outbox emit at V1)', () async {
      gateway.candidates.add(_credRow(
        credentialId: 'cred-1',
        operatorId: '00000000-0000-4000-8000-000000000001',
        vendorId: 'lightspeed_lsk',
        consecutiveFailures: 2,
      ));
      gateway.failureCountAfterIncrement = 3;
      refresher.outcomeQueue.add(
        const VendorRefreshOutcome.failure('vendor returned 401'),
      );

      final result = await runner.runOnce();
      expect(result.refreshFailures, 1);
      expect(result.autoDisabled, 1);
      expect(gateway.autoDisabledCalls.length, 1);
    });

    test('does NOT auto-disable when failure count < threshold', () async {
      gateway.candidates.add(_credRow(
        credentialId: 'cred-1',
        operatorId: '00000000-0000-4000-8000-000000000001',
        vendorId: 'lightspeed_lsk',
        consecutiveFailures: 1,
      ));
      gateway.failureCountAfterIncrement = 2;
      refresher.outcomeQueue.add(
        const VendorRefreshOutcome.failure('transient'),
      );

      final result = await runner.runOnce();
      expect(result.autoDisabled, 0);
      expect(gateway.autoDisabledCalls.length, 0);
    });
  });
}

VendorCredentialRefreshRow _credRow({
  required String credentialId,
  required String operatorId,
  required String vendorId,
  required int consecutiveFailures,
}) {
  return VendorCredentialRefreshRow(
    credentialId: credentialId,
    operatorId: operatorId,
    locationId: '00000000-0000-4000-8000-0000000000a1',
    vendorId: vendorId,
    module: null,
    refreshTokenCiphertext: const <int>[],
    tokenExpiresAt: DateTime.utc(2026, 5, 5),
    consecutiveFailures: consecutiveFailures,
  );
}

class _FakeGateway implements OAuthRefreshGateway {
  final List<VendorCredentialRefreshRow> candidates =
      <VendorCredentialRefreshRow>[];
  final List<Map<String, Object?>> successesRecorded =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> failuresRecorded =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> autoDisabledCalls =
      <Map<String, Object?>>[];
  int failureCountAfterIncrement = 1;

  @override
  Future<List<VendorCredentialRefreshRow>> findExpiringCredentials({
    required DateTime now,
    required Duration horizon,
  }) async =>
      candidates;

  @override
  Future<bool> acquireAdvisoryLockForRefresh({
    required String operatorId,
    required String vendorId,
  }) async =>
      true; // Always grant the lock (no contention at V1).

  @override
  Future<void> recordRefreshSuccess({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required List<int> newAccessTokenCiphertext,
    required List<int> newRefreshTokenCiphertext,
    required DateTime newExpiresAt,
  }) async {
    successesRecorded.add(<String, Object?>{'credential_id': credentialId});
  }

  @override
  Future<int> recordRefreshFailure({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    failuresRecorded.add(<String, Object?>{
      'credential_id': credentialId,
      'error_message': errorMessage,
    });
    return failureCountAfterIncrement;
  }

  @override
  Future<void> autoDisableConnection({
    required String credentialId,
    required String operatorId,
    String? locationId,
    required String vendorId,
    required String errorMessage,
  }) async {
    autoDisabledCalls.add(<String, Object?>{'credential_id': credentialId});
  }
}

class _StubRefresher implements VendorOAuthRefresher {
  _StubRefresher({required this.vendorId});

  @override
  final String vendorId;

  final List<VendorRefreshOutcome> outcomeQueue = <VendorRefreshOutcome>[];

  @override
  Future<VendorRefreshOutcome> refresh({
    required String operatorId,
    String? locationId,
    required List<int> refreshTokenCiphertext,
  }) async {
    if (outcomeQueue.isEmpty) {
      return const VendorRefreshOutcome.failure('test queue empty');
    }
    return outcomeQueue.removeAt(0);
  }
}
