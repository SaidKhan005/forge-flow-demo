// Demo-data Slice E (part 2) — mobile-fold demo_mode_state source.
// Authority: the Slice E pt2 prompt; docs/_audits/per_daypart_v1/
// full_demo_data_spec.md §1.5 (line 70), §2f/§2g (lines 167-175),
// Slice E (lines 238-239), Gap G6 (line 188). CLAUDE.md HP #2 / #4.
//
// WHY THIS EXISTS
// Slice E pt1 (#800) built the canonical per-(operator, location,
// category) demo state in `DemoVendorIntegrationStateFixture` and wired
// it into operator-web (`resolver.demoFallback()`), but explicitly
// DEFERRED the mobile side: pt1's own header (lib/dev/
// demo_vendor_integration_state_fixture.dart lines 16-20, 34-41) states
// "the demo build is a WRITER swap ... the demo build resolves
// [DemoVendorIntegrationDemoModeStateGateway]" and "The mobile-fold
// seed hook ... is part 2, deferred". This file is that part-2 source.
//
// The mobile Settings → Integrations fold (`SettingsIntegrationsSection`)
// and the AppShell-mounted `DemoModeBanner` both read ONLY
// `DemoModeStateNotifier.snapshot`. That notifier is fed EXCLUSIVELY by
// an injected `SyncProxyClient.fetchDemoModeStates` (see
// lib/state/demo_mode_state_notifier.dart:215). The demo flavor
// (`main_forgeflow.dart` `_demoAuthEnabled` path) bootstraps WITHOUT a
// `syncProxyClient`, so in demo the notifier had no source and the fold
// + banner rendered nothing. pt2 supplies the missing demo source.
//
// HP #2 (CLAUDE.md → Demo Mode): this is a WRITER-side source swap, the
// `DemoModeStateNotifier` analogue of `MockReplayDataSourceProvider`
// (and of the contract-endorsed `DemoAuthLoginService` bootstrap
// source-swap). There is NO `kDemoMode` reader branch, NO new `demo_*`
// table, and NO reader-repository fork. Every reader
// (`DemoModeStateNotifier`, `DemoModeBanner`,
// `SettingsIntegrationsSection`) consumes the resulting records through
// the SAME code path it uses in production; the ONLY difference is
// which writer populated them (this demo source vs the Postgres-backed
// proxy). The demo source is armed solely by the demo seed
// (`_seedDemoVendorIntegrationModeStateSource` in
// sqlite_database_seed.dart, gated on the `kDemoMode` /
// `FORGE_FLOW_DEMO_MODE` writer-side switch); production never arms it,
// so the production read path is byte-unchanged.
//
// DETERMINISM (no RNG) + HP #4 (per-operator/location isolation): every
// record is derived purely from (operatorId, locationId, category) by
// delegating to `DemoVendorIntegrationStateFixture` — the SAME pt1
// source of truth operator-web derives from, so both consoles tell an
// identical story. Two reseeds are byte-identical. The fixture is keyed
// on the logical location only and threads the caller's `operatorId`
// onto every row, so a location never carries another location's state
// and a record never leaks across operators.
//
// This file does NOT import `sqlite_database.dart` (the demo location
// ids are passed in by the seed hook) so there is no library import
// cycle with the persistence layer.

import '../services/auth/demo_auth_login_service.dart'
    show kDemoOperatorOperatorId;
import '../services/integration/demo_mode_state.dart';
import '../services/sync/sync_proxy_client.dart';
import 'demo_vendor_integration_state_fixture.dart';

/// Demo `SyncProxyClient` whose ONLY implemented surface is
/// [fetchDemoModeStates], which delegates to the pt1
/// [DemoVendorIntegrationStateFixture]. Every other proxy method is
/// intentionally unsupported: the demo flavor wires NO operational sync
/// through this surface — `MobileOperationalSyncHost` still receives the
/// raw (null) bootstrap `syncProxyClient`, and only the demo
/// `DemoModeStateNotifier` binding resolves this source (see
/// `forge_flow_app.dart` `_resolveSyncProxyClient`). A regression that
/// routed other reads through here fails loudly instead of silently
/// returning empty — mirroring pt1's test `_FixtureSyncProxyClient`.
class DemoVendorIntegrationModeStateSyncProxyClient
    implements SyncProxyClient {
  const DemoVendorIntegrationModeStateSyncProxyClient();

  @override
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  }) async {
    return DemoVendorIntegrationStateFixture.demoModeRecords(
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
        'DemoVendorIntegrationModeStateSyncProxyClient only serves '
        'fetchDemoModeStates (the mobile demo_mode_state fold/banner '
        'source). The demo flavor wires no operational sync through this '
        'client: ${invocation.memberName}',
      );
}

/// Process-global, demo-only holder for the mobile-fold
/// `demo_mode_state` source.
///
/// The notifier-side analogue of `MockReplayDataSourceProvider`: the
/// demo seed ARMS this (writer side); the demo `DemoModeStateNotifier`
/// binding READS it via [maybeClient] as a fallback when the bootstrap
/// wired no real `SyncProxyClient` (i.e. the demo flavor). Production
/// never calls [armForDemoSeed] (the seed hook is gated on the
/// `kDemoMode` / `FORGE_FLOW_DEMO_MODE` writer-side switch), so
/// [maybeClient] stays `null` in production and the notifier resolves
/// exactly the bootstrap `SyncProxyClient` it always has — the read
/// path is byte-unchanged.
class DemoVendorIntegrationDemoModeSource {
  DemoVendorIntegrationDemoModeSource._();

  static const DemoVendorIntegrationModeStateSyncProxyClient _client =
      DemoVendorIntegrationModeStateSyncProxyClient();

  static bool _armed = false;

  /// Arm the demo source for [demoLocationIds] (the mobile
  /// `DemoScope.locations` restaurant ids, passed in by the seed hook
  /// so this file stays decoupled from the persistence layer). Called
  /// ONLY by `_seedDemoVendorIntegrationModeStateSource` under the
  /// `kDemoMode` / `FORGE_FLOW_DEMO_MODE` writer-side switch.
  ///
  /// Idempotent and deterministic: materializes the canonical
  /// per-(operator, location, category) records for every location ×
  /// {pos, labor, reservation} for the demo operator and asserts pt1's
  /// required mix on the seed path itself, so a fixture drift fails the
  /// seed loudly rather than silently shipping a wrong demo story.
  static void armForDemoSeed({required List<String> demoLocationIds}) {
    materializeAndValidate(demoLocationIds);
    _armed = true;
  }

  /// Pure, side-effect-free materialization + invariant check of the
  /// pt1 fixture for the demo operator across [demoLocationIds].
  /// Returns the per-location records so the acceptance test can assert
  /// byte-consistency with pt1 (#800) without mutating global state.
  static Map<String, List<DemoModeRecord>> materializeAndValidate(
    List<String> demoLocationIds,
  ) {
    final byLocation = <String, List<DemoModeRecord>>{};
    var anyHasDemo = false;
    var anyAllLive = false;

    for (final locationId in demoLocationIds) {
      final records = DemoVendorIntegrationStateFixture.demoModeRecords(
        operatorId: kDemoOperatorOperatorId,
        locationId: locationId,
      );

      // Exactly the 3 categories (pt1 §2f/§2g).
      assert(
        records.length == 3,
        'demo_mode_state seed: $locationId must have 3 category rows, '
        'got ${records.length}',
      );
      // HP #4: every row carries ONLY this location + the demo
      // operator — no cross-location / cross-operator leakage.
      assert(
        records.every(
          (r) =>
              r.locationId == locationId &&
              r.operatorId == kDemoOperatorOperatorId,
        ),
        'demo_mode_state seed: HP #4 isolation violated for $locationId',
      );

      anyHasDemo = anyHasDemo || records.any((r) => r.isDemo);
      anyAllLive = anyAllLive || records.every((r) => !r.isDemo);

      byLocation[locationId] = records;
    }

    // pt1 §2g: ≥1 location still demo, ≥1 location fully flipped live.
    assert(
      anyHasDemo,
      'demo_mode_state seed: expected ≥1 location with demo categories',
    );
    assert(
      anyAllLive,
      'demo_mode_state seed: expected ≥1 location fully flipped to live',
    );
    return byLocation;
  }

  /// The demo `SyncProxyClient` for the mobile `DemoModeStateNotifier`,
  /// or `null` when the demo seed has not armed it (production / widget
  /// tests without the demo seed). The `??`-fallback in
  /// `forge_flow_app.dart` `_resolveSyncProxyClient` consults this.
  static SyncProxyClient? maybeClient() => _armed ? _client : null;

  /// Test-only: drop the armed state so suites that exercise the
  /// production (unarmed) path start from a clean global.
  static void resetForTest() {
    _armed = false;
  }
}
