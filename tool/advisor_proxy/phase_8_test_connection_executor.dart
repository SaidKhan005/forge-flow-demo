// Phase 8 framework — production [VendorTestConnectionExecutor].
//
// Wires the per-vendor `VendorApiKeyValidator` map (built by
// `buildPhase8OperatorOAuthWiring`) into the
// `RepositoryIntegrationRoutesGateway.testConnection` seam so the
// `POST /v1/integrations/{vendor}/test-connection` route returns 200
// with `{ok, message, latencyMs}` instead of 503
// `test_connection_executor_not_configured`.
//
// Spine reference:
//   * `lib/services/integration/repository_integration_routes_gateway.dart`
//     — declares the `VendorTestConnectionExecutor` abstract that
//     this class implements; the gateway calls `run(...)` after
//     decrypting the stored `vendor_credentials.access_token_ciphertext`
//     via `pgp_sym_decrypt`.
//   * `tool/advisor_proxy/integration_oauth_routes.dart` —
//     `Phase8OperatorOAuthWiring.apiKeyValidators` is the canonical
//     vendor → validator map. The same closures that gate api-key
//     connect upserts are reused here.
//
// CLAUDE.md alignment:
//
//   * Hard Promise #1 (transport-only). The executor never writes
//     canonical fact rows; it only invokes the vendor's authenticated
//     probe endpoint and reports the auth result.
//   * Hard Promise #4 (per-operator isolation). Validators inherit
//     the (operator, location, vendor) tuple from the gateway call
//     site — no cross-tenant lookup is possible.
//   * Hard Promise #7 (server-side keys). The plaintext token crosses
//     the seam exactly once between the gateway (which decrypted it
//     server-side) and the validator (which uses it as a Bearer
//     header against the vendor probe). It never lands in a log or
//     a response payload.

import 'dart:async';

import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart';

import 'integration_oauth_routes.dart';

/// Production [VendorTestConnectionExecutor].
///
/// For every `run(...)` call:
///
/// 1. Look up `apiKeyValidators[vendorId]`. Absent → return a failed
///    [TestConnectionResult] with `error_code: 'no_validator_for_vendor'`.
/// 2. Invoke the validator with `apiKey: accessTokenPlaintext`. For
///    api-key vendors the stored credential IS the api-key; for OAuth
///    vendors it is the OAuth access token, which the vendor's
///    authenticated probe accepts as a Bearer header.
/// 3. Translate `VendorApiKeyValidationResult` → `TestConnectionResult`:
///    `{authValid, sample, fieldMapping, elapsedMs, note}`. The route
///    layer maps `authValid` → top-level `ok` and surfaces
///    `error_code` via the `note` field for failed probes.
///
/// Failure handling:
///
///   * Validator throws → `authValid=false`, `note='validator_threw: …'`.
///     The exception text is captured in the note so on-call can
///     diagnose without parsing logs, but the secret never appears in
///     it (validators never echo the api key in their exceptions).
///   * Validator returns `valid=false` with an `errorMessage` →
///     `authValid=false`, `note=errorMessage`.
///   * Vendor not in the validator map → `authValid=false`,
///     `note='no_validator_for_vendor'`. This path is reachable in
///     demo mode (validator map is empty) and in deploys where a new
///     vendor row predates the validator wiring.
///
/// Latency is measured around the validator call only: the gateway's
/// own decrypt + sync-log write are not counted.
class Phase8IntegrationTestConnectionExecutor
    implements VendorTestConnectionExecutor {
  Phase8IntegrationTestConnectionExecutor({
    required this.apiKeyValidators,
    Stopwatch Function()? stopwatchFactory,
  }) : _stopwatchFactory = stopwatchFactory ?? Stopwatch.new;

  /// vendor_id → validator. The same map as
  /// `Phase8OperatorOAuthWiring.apiKeyValidators`. Keep the reference
  /// to the live map so the executor picks up vendors added after
  /// construction (production wires both at the same point in boot,
  /// but tests may inject after).
  final Map<String, VendorApiKeyValidator> apiKeyValidators;

  final Stopwatch Function() _stopwatchFactory;

  @override
  Future<TestConnectionResult> run({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String credentialId,
    required String accessTokenPlaintext,
  }) async {
    final validator = apiKeyValidators[vendorId];
    if (validator == null) {
      return const TestConnectionResult(
        authValid: false,
        sample: <String, Object?>{},
        fieldMapping: <String, Object?>{},
        elapsedMs: 0,
        note: 'no_validator_for_vendor',
      );
    }
    final stopwatch = _stopwatchFactory()..start();
    final VendorApiKeyValidationResult validation;
    try {
      validation = await validator(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        apiKey: accessTokenPlaintext,
      );
    } catch (error) {
      stopwatch.stop();
      return TestConnectionResult(
        authValid: false,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: stopwatch.elapsedMilliseconds,
        note: 'validator_threw: ${error.runtimeType}',
      );
    }
    stopwatch.stop();
    return TestConnectionResult(
      authValid: validation.valid,
      sample: const <String, Object?>{},
      fieldMapping: const <String, Object?>{},
      elapsedMs: stopwatch.elapsedMilliseconds,
      note: validation.valid
          ? null
          : (validation.errorMessage ?? 'auth_invalid'),
    );
  }
}
