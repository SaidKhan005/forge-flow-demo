// Phase 8 — Phase8IntegrationTestConnectionExecutor tests.
//
// Validates the wrapper that translates the per-vendor
// `VendorApiKeyValidator` map (built by `buildPhase8OperatorOAuthWiring`)
// into a `VendorTestConnectionExecutor` for the
// `RepositoryIntegrationRoutesGateway.testConnection` seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/advisor_proxy/integration_oauth_routes.dart';
import '../../../tool/advisor_proxy/phase_8_test_connection_executor.dart';

void main() {
  const operatorId = 'op_a';
  const locationId = 'loc_a';
  const credentialId = 'cred_x';

  group('Phase8IntegrationTestConnectionExecutor', () {
    test('valid validator -> ok=true with auth_valid=true', () async {
      final captured = <_ValidatorCall>[];
      final executor = Phase8IntegrationTestConnectionExecutor(
        apiKeyValidators: <String, VendorApiKeyValidator>{
          'toast': ({
            required String operatorId,
            required String locationId,
            required String vendorId,
            required String apiKey,
            String? apiSecret,
          }) async {
            captured.add(_ValidatorCall(
              operatorId: operatorId,
              locationId: locationId,
              vendorId: vendorId,
              apiKey: apiKey,
            ));
            return const VendorApiKeyValidationResult(
              valid: true,
              category: IntegrationCategory.pos,
            );
          },
        },
        stopwatchFactory: () => _FakeStopwatch(elapsed: 42),
      );

      final result = await executor.run(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        credentialId: credentialId,
        accessTokenPlaintext: 'plaintext-token-abc',
      );

      expect(result.authValid, isTrue);
      expect(result.note, isNull);
      expect(result.elapsedMs, 42);
      expect(captured, hasLength(1));
      expect(captured.single.apiKey, 'plaintext-token-abc');
      expect(captured.single.vendorId, 'toast');
      expect(captured.single.operatorId, operatorId);
      expect(captured.single.locationId, locationId);
    });

    test('invalid validator -> ok=false with errorMessage in note', () async {
      final executor = Phase8IntegrationTestConnectionExecutor(
        apiKeyValidators: <String, VendorApiKeyValidator>{
          'toast': ({
            required String operatorId,
            required String locationId,
            required String vendorId,
            required String apiKey,
            String? apiSecret,
          }) async {
            return const VendorApiKeyValidationResult(
              valid: false,
              category: IntegrationCategory.pos,
              errorMessage: 'vendor_returned_401',
            );
          },
        },
        stopwatchFactory: () => _FakeStopwatch(elapsed: 17),
      );

      final result = await executor.run(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        credentialId: credentialId,
        accessTokenPlaintext: 'tok',
      );

      expect(result.authValid, isFalse);
      expect(result.note, 'vendor_returned_401');
      expect(result.elapsedMs, 17);
    });

    test('invalid validator with no errorMessage -> note=auth_invalid',
        () async {
      final executor = Phase8IntegrationTestConnectionExecutor(
        apiKeyValidators: <String, VendorApiKeyValidator>{
          'toast': ({
            required String operatorId,
            required String locationId,
            required String vendorId,
            required String apiKey,
            String? apiSecret,
          }) async {
            return const VendorApiKeyValidationResult(
              valid: false,
              category: IntegrationCategory.pos,
            );
          },
        },
        stopwatchFactory: () => _FakeStopwatch(elapsed: 5),
      );

      final result = await executor.run(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        credentialId: credentialId,
        accessTokenPlaintext: 'tok',
      );

      expect(result.authValid, isFalse);
      expect(result.note, 'auth_invalid');
    });

    test('validator throws -> note=validator_threw: <type>', () async {
      final executor = Phase8IntegrationTestConnectionExecutor(
        apiKeyValidators: <String, VendorApiKeyValidator>{
          'toast': ({
            required String operatorId,
            required String locationId,
            required String vendorId,
            required String apiKey,
            String? apiSecret,
          }) async {
            throw const FormatException('bad-response');
          },
        },
        stopwatchFactory: () => _FakeStopwatch(elapsed: 99),
      );

      final result = await executor.run(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        credentialId: credentialId,
        accessTokenPlaintext: 'tok',
      );

      expect(result.authValid, isFalse);
      expect(result.note, 'validator_threw: FormatException');
      expect(result.elapsedMs, 99);
    });

    test('unknown vendor -> note=no_validator_for_vendor with elapsedMs=0',
        () async {
      final executor = Phase8IntegrationTestConnectionExecutor(
        apiKeyValidators: <String, VendorApiKeyValidator>{},
      );

      final result = await executor.run(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'mystery_vendor',
        credentialId: credentialId,
        accessTokenPlaintext: 'tok',
      );

      expect(result.authValid, isFalse);
      expect(result.note, 'no_validator_for_vendor');
      expect(result.elapsedMs, 0);
      expect(result.sample, isEmpty);
      expect(result.fieldMapping, isEmpty);
    });

    test('latency reflects validator duration via real Stopwatch', () async {
      // Use the real Stopwatch (default factory) and a validator that
      // sleeps to confirm the executor measures time around the call,
      // not just returns a constant 0.
      final executor = Phase8IntegrationTestConnectionExecutor(
        apiKeyValidators: <String, VendorApiKeyValidator>{
          'toast': ({
            required String operatorId,
            required String locationId,
            required String vendorId,
            required String apiKey,
            String? apiSecret,
          }) async {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            return const VendorApiKeyValidationResult(
              valid: true,
              category: IntegrationCategory.pos,
            );
          },
        },
      );

      final result = await executor.run(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: 'toast',
        credentialId: credentialId,
        accessTokenPlaintext: 'tok',
      );

      expect(result.authValid, isTrue);
      // Lower bound only — flaky upper bound on slow CI machines.
      expect(result.elapsedMs, greaterThanOrEqualTo(20));
    });
  });
}

class _ValidatorCall {
  const _ValidatorCall({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.apiKey,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;
  final String apiKey;
}

/// Tiny fake Stopwatch that returns a fixed elapsed reading so the
/// executor's latency reporting can be asserted deterministically.
class _FakeStopwatch implements Stopwatch {
  _FakeStopwatch({required int elapsed}) : _elapsedMs = elapsed;

  final int _elapsedMs;
  bool _running = false;

  @override
  void start() {
    _running = true;
  }

  @override
  void stop() {
    _running = false;
  }

  @override
  void reset() {}

  @override
  int get elapsedMilliseconds => _elapsedMs;

  @override
  int get elapsedMicroseconds => _elapsedMs * 1000;

  @override
  int get elapsedTicks => _elapsedMs;

  @override
  Duration get elapsed => Duration(milliseconds: _elapsedMs);

  @override
  int get frequency => 1000;

  @override
  bool get isRunning => _running;
}
