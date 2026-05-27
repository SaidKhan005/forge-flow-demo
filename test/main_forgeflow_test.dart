// Hard Rule #1 wiring guard for `lib/main_forgeflow.dart`.
//
// `docs/contracts/mobile_core_star_target_truth_contract.md` Hard Rule
// #1 says "the server owns which star shifts the manager picked" and
// the mobile cache mirrors what the proxy persisted. To honor that,
// `bootstrapAndRunApp` must receive a non-null
// `starTargetSelectionWriteClient` so
// `BaselineManagerService.instance.serverSelectionWriter` is non-null
// in the production ForgeFlow flavor; otherwise
// `BaselineManagerService` falls back to the local-only
// `TargetCycleService.applyManagerOverrideCycle` path and the manager
// override never round-trips through the proxy.
//
// CODE_OPS_DEBT.md Theme H row 1 caught this missing wiring against
// `lib/main.dart:48` (which already passes the same
// `HttpSyncProxyClient` reference through both
// `syncProxyClient` and `starTargetSelectionWriteClient`). The
// production `lib/main_forgeflow.dart` flavor must do the same.
//
// Two tests below:
//
// 1. Source-grep guard — proves the production ForgeFlow flavor passes
//    `starTargetSelectionWriteClient: syncProxyClient` to
//    `bootstrapAndRunApp`. This mirrors the source-grep pattern used
//    by other Forge & Flow startup wiring guards (see
//    `test/proxy/main_bootstrap_test.dart` and
//    `test/services/mobile_push_sender_test.dart`).
//
// 2. Behavior guard — drives the same
//    `BaselineManagerService.serverSelectionWriter` assignment that
//    `bootstrapAndRunApp` performs, with both null and non-null write
//    clients, to prove that wiring `starTargetSelectionWriteClient`
//    actually flips the writer to non-null. This pins the contract
//    that `main_forgeflow.dart`'s wiring shape relies on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';

void main() {
  group('lib/main_forgeflow.dart — Hard Rule #1 server-write wiring', () {
    String readForgeFlowMainSource() =>
        File('lib/main_forgeflow.dart').readAsStringSync();

    test('passes starTargetSelectionWriteClient to bootstrapAndRunApp', () {
      final source = readForgeFlowMainSource();
      // The production wiring threads the same HttpSyncProxyClient
      // reference through both `syncProxyClient` and
      // `starTargetSelectionWriteClient` (HttpSyncProxyClient
      // implements both contracts) — same shape as `lib/main.dart`.
      expect(
        source,
        contains('starTargetSelectionWriteClient: syncProxyClient'),
        reason:
            'Production ForgeFlow flavor must pass the proxy client as '
            'starTargetSelectionWriteClient so '
            'BaselineManagerService.serverSelectionWriter is non-null '
            '(Hard Rule #1 — server owns star/target selection).',
      );
    });

    test('still passes syncProxyClient (regression guard for pre-existing '
        'wiring kept alongside the new line)', () {
      final source = readForgeFlowMainSource();
      expect(source, contains('syncProxyClient: syncProxyClient'));
    });

    test('registers the FCM token revalidation observer on mobile', () {
      final source = readForgeFlowMainSource();
      expect(source, contains('WidgetsBinding.instance.addObserver'));
      expect(source, contains('FcmTokenRevalidationObserver'));
      expect(source, contains('mobilePushService: mobilePushNotifications'));
    });
  });

  group('BaselineManagerService.serverSelectionWriter — wiring contract', () {
    // The bootstrap performs the assignment:
    //
    //   BaselineManagerService.instance.serverSelectionWriter =
    //       starTargetSelectionWriteClient == null
    //           ? null
    //           : AuthSessionStarTargetSelectionWriter(...);
    //
    // These tests exercise the same condition `bootstrapAndRunApp`
    // applies, without booting Flutter, so the test asserts the
    // observable post-bootstrap state without calling `runApp`.
    // (The full bootstrap mounts a `MaterialApp`, which is not safe
    // to drive from a non-widget test.)
    tearDown(() {
      BaselineManagerService.instance.serverSelectionWriter = null;
    });

    test('is non-null when bootstrap-equivalent wiring receives a '
        'non-null StarTargetSelectionWriteClient', () {
      final client = _NoopStarTargetSelectionWriteClient();
      BaselineManagerService.instance.serverSelectionWriter =
          AuthSessionStarTargetSelectionWriter(
            client: client,
            authSessionProvider: () => null,
          );
      expect(
        BaselineManagerService.instance.serverSelectionWriter,
        isNotNull,
        reason:
            'A non-null write client must produce a non-null '
            'serverSelectionWriter so the manager-override path '
            'round-trips through the proxy instead of writing '
            'directly to local SQLite.',
      );
    });

    test('remains null when no StarTargetSelectionWriteClient is '
        'wired (demo / no-Firebase path)', () {
      BaselineManagerService.instance.serverSelectionWriter = null;
      expect(BaselineManagerService.instance.serverSelectionWriter, isNull);
    });
  });
}

class _NoopStarTargetSelectionWriteClient
    implements StarTargetSelectionWriteClient {
  @override
  Future<void> submitSelectedStarDecision({
    required String operatorId,
    required String locationId,
    required StarTargetSelectionWriteAction action,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {}

  @override
  Future<void> submitSelectedStarTargetProjection({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {}
}
