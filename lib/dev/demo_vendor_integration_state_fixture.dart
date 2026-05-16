// Demo-data Slice E (part 1) — vendor integration demo state fixture
// (kDemoMode only). Authority: docs/_audits/per_daypart_v1/
// full_demo_data_spec.md §1.5 (line 70), §2f/§2g (lines 167-175),
// Slice E (lines 238-239), Gap G6 (line 188).
//
// WHY THIS EXISTS
// Operator-visible defect (spec Gap G6, §1 finding 4): vendor
// integration demo state was invisible — no per-(operator, location,
// category) `demo_mode_state` rows existed, so the operator-web Vendor
// Connections surface, the mobile Integrations fold, and
// `DemoModeBanner` had nothing to render.
//
// HP #2 (CLAUDE.md → Demo Mode): this is FIXTURE DATA into the EXISTING
// `DemoModeStateGateway` surface. There is no `kDemoMode` reader branch,
// no new `demo_*` table, and no reader-repository fork. The demo build
// is a WRITER swap: instead of a Postgres-backed gateway, the demo
// build resolves [DemoVendorIntegrationDemoModeStateGateway], which
// returns these fixture rows. Readers (the notifier, the banner, the
// Demo→Live switch) are unchanged and resolve through the same code
// path either way.
//
// DETERMINISM
// Every value is derived from (locationId, category) via a static
// lookup table — NO RNG, NO `DateTime.now()`. Two reads of the same
// (operator, location, category) return byte-identical records, which
// the acceptance tests pin.
//
// PER-OPERATOR ISOLATION (HP #4)
// The fixture is keyed on the LOGICAL location only; the caller's
// `operatorId` is threaded through onto every returned record so the
// rows carry the demo operator id correctly and never leak across
// operators.
//
// SCOPE NOTE (part 1 of 2)
// This file is the non-seed half of Slice E: the canonical fixture +
// the demo `DemoModeStateGateway` implementation, plus the operator-web
// consistency contract proven by tests. The mobile-fold seed hook in
// `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` is
// part 2, deferred — that file is owned by the in-flight Slice B
// worker. Until part 2 wires the demo build to resolve this gateway,
// the fixture is exercised by the acceptance tests.

import '../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../services/integration/demo_mode_state.dart';
import '../services/integration/integration_adapter_common.dart';

/// The four §2c demo locations, identified by their LOGICAL handle so
/// the mobile console (SQLite `restaurant_id`s) and the operator-web
/// console (`demo-loc-*` ids) resolve to the same per-category state.
enum DemoVendorIntegrationLocation { downtown, northLoop, riverside, harbour }

/// One demo vendor's per-category state. The single source of truth the
/// mobile [DemoModeRecord]s, the operator-web `demoFlags`, and the
/// operator-web [VendorConnectionRow] statuses are all derived from, so
/// both surfaces tell the same story (spec §2f/§2g).
class DemoVendorCategoryState {
  const DemoVendorCategoryState({
    required this.isDemo,
    required this.connectionStatus,
    required this.vendorId,
    required this.vendorDisplayName,
    this.lastErrorMessage,
  });

  /// `demo_mode_state.is_demo` for this (location, category).
  final bool isDemo;

  /// The vendor connection's status on the operator-web surface.
  /// `connected` with [isDemo] still `true` models "connected but the
  /// first backfill has not committed yet, so the master Demo→Live
  /// switch must not flip" (spec §2f Downtown). `connected` with
  /// [isDemo] `false` models "already flipped to live" (Riverside).
  /// `disconnected` means no vendor row renders (clean demo).
  final ConnectionStatus connectionStatus;

  final String vendorId;
  final String vendorDisplayName;

  /// Populated only for the `error`/needs-reauth category so the
  /// operator-web card renders a meaningful remediation line.
  final String? lastErrorMessage;
}

/// Canonical, deterministic per-(location, category) demo state.
///
/// Coverage proven by the acceptance tests:
///   * Downtown: POS + Labor `connected` & `is_demo=true`, Reservation
///     `error`/needs-reauth & `is_demo=true` → mixed state, master
///     Demo→Live switch visible (carve-out #4), banner renders.
///   * North Loop: POS `connected` & `is_demo=true`, Labor + Reservation
///     `disconnected` & `is_demo=true` → still demo.
///   * Riverside: every category `connected` & `is_demo=false`
///     (already flipped to live) → switch shows already-live, the
///     Live→Demo refusal is demonstrable.
///   * Harbour: every category `disconnected` & `is_demo=true` → clean
///     demo state.
///
/// `hasDemoCategories` is therefore TRUE for Downtown / North Loop /
/// Harbour and FALSE for Riverside (spec §2g requires ≥1 of each).
class DemoVendorIntegrationStateFixture {
  const DemoVendorIntegrationStateFixture._();

  /// Mobile SQLite `restaurant_id` → logical location. Mirrors
  /// `DemoScope.{downtown,northLoop,riverside,harbour}RestaurantId`
  /// (`lib/infrastructure/persistence/sqlite/sqlite_database.dart`);
  /// kept as literals so this fixture stays dependency-light (no
  /// `sqflite` pull into pure unit tests). A test asserts these equal
  /// the `DemoScope` constants so drift fails loudly.
  static const Map<String, DemoVendorIntegrationLocation> _mobileLocationIds =
      <String, DemoVendorIntegrationLocation>{
    'demo_restaurant_001': DemoVendorIntegrationLocation.downtown,
    'demo_restaurant_north_loop': DemoVendorIntegrationLocation.northLoop,
    'demo_restaurant_riverside': DemoVendorIntegrationLocation.riverside,
    'demo_restaurant_harbour': DemoVendorIntegrationLocation.harbour,
  };

  /// Operator-web `demo-loc-*` ids → logical location. Mirrors
  /// `kDemoTeamLocationsFixture`
  /// (`lib/operator_web/services/demo_team_fixtures.dart`); a test
  /// asserts equality so drift fails loudly.
  static const Map<String, DemoVendorIntegrationLocation>
      _operatorWebLocationIds = <String, DemoVendorIntegrationLocation>{
    'demo-loc-downtown': DemoVendorIntegrationLocation.downtown,
    'demo-loc-north-loop': DemoVendorIntegrationLocation.northLoop,
    'demo-loc-riverside': DemoVendorIntegrationLocation.riverside,
    'demo-loc-harbour': DemoVendorIntegrationLocation.harbour,
  };

  // Vendor identities reused from `InMemoryVendorConnectionsGateway`'s
  // catalog so the operator-web card chrome (display name, picker
  // alignment) stays faithful.
  static const String _posVendorId = 'toast';
  static const String _posVendorName = 'Toast';
  static const String _laborVendorId = 'humanity';
  static const String _laborVendorName = 'Humanity';
  static const String _reservationVendorId = 'opentable';
  static const String _reservationVendorName = 'OpenTable';

  static const String _reservationReauthMessage =
      'Reauthorize OpenTable — the saved access token expired. '
      'Reconnect from this card to resume reservation sync.';

  /// The canonical state table. Order within each location follows
  /// [IntegrationCategory.values] (pos, labor, reservation).
  static const Map<DemoVendorIntegrationLocation,
          Map<IntegrationCategory, DemoVendorCategoryState>> _states =
      <DemoVendorIntegrationLocation,
          Map<IntegrationCategory, DemoVendorCategoryState>>{
    DemoVendorIntegrationLocation.downtown:
        <IntegrationCategory, DemoVendorCategoryState>{
      IntegrationCategory.pos: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.connected,
        vendorId: _posVendorId,
        vendorDisplayName: _posVendorName,
      ),
      IntegrationCategory.labor: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.connected,
        vendorId: _laborVendorId,
        vendorDisplayName: _laborVendorName,
      ),
      IntegrationCategory.reservation: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.error,
        vendorId: _reservationVendorId,
        vendorDisplayName: _reservationVendorName,
        lastErrorMessage: _reservationReauthMessage,
      ),
    },
    DemoVendorIntegrationLocation.northLoop:
        <IntegrationCategory, DemoVendorCategoryState>{
      IntegrationCategory.pos: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.connected,
        vendorId: _posVendorId,
        vendorDisplayName: _posVendorName,
      ),
      IntegrationCategory.labor: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.disconnected,
        vendorId: _laborVendorId,
        vendorDisplayName: _laborVendorName,
      ),
      IntegrationCategory.reservation: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.disconnected,
        vendorId: _reservationVendorId,
        vendorDisplayName: _reservationVendorName,
      ),
    },
    DemoVendorIntegrationLocation.riverside:
        <IntegrationCategory, DemoVendorCategoryState>{
      IntegrationCategory.pos: DemoVendorCategoryState(
        isDemo: false,
        connectionStatus: ConnectionStatus.connected,
        vendorId: _posVendorId,
        vendorDisplayName: _posVendorName,
      ),
      IntegrationCategory.labor: DemoVendorCategoryState(
        isDemo: false,
        connectionStatus: ConnectionStatus.connected,
        vendorId: _laborVendorId,
        vendorDisplayName: _laborVendorName,
      ),
      IntegrationCategory.reservation: DemoVendorCategoryState(
        isDemo: false,
        connectionStatus: ConnectionStatus.connected,
        vendorId: _reservationVendorId,
        vendorDisplayName: _reservationVendorName,
      ),
    },
    DemoVendorIntegrationLocation.harbour:
        <IntegrationCategory, DemoVendorCategoryState>{
      IntegrationCategory.pos: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.disconnected,
        vendorId: _posVendorId,
        vendorDisplayName: _posVendorName,
      ),
      IntegrationCategory.labor: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.disconnected,
        vendorId: _laborVendorId,
        vendorDisplayName: _laborVendorName,
      ),
      IntegrationCategory.reservation: DemoVendorCategoryState(
        isDemo: true,
        connectionStatus: ConnectionStatus.disconnected,
        vendorId: _reservationVendorId,
        vendorDisplayName: _reservationVendorName,
      ),
    },
  };

  // Deterministic flip metadata for the already-live (Riverside) rows.
  // Fixed epoch + per-category offset — never `DateTime.now()`.
  static final DateTime _flipEpoch = DateTime.utc(2026, 4, 1, 14, 30);

  /// True when [locationId] resolves to a known demo location on either
  /// console. Unknown ids fall back to a deterministic clean-demo
  /// default (all `is_demo=true`, all disconnected) so a stray scope
  /// never crashes the notifier.
  static bool knowsLocation(String locationId) =>
      _resolve(locationId) != null;

  static DemoVendorIntegrationLocation? _resolve(String locationId) =>
      _mobileLocationIds[locationId] ?? _operatorWebLocationIds[locationId];

  static Map<IntegrationCategory, DemoVendorCategoryState> _statesFor(
    String locationId,
  ) {
    final location = _resolve(locationId);
    if (location == null) {
      // Clean-demo default for an unrecognized scope: keeps the
      // notifier non-empty and deterministic without inventing a fake
      // connected vendor.
      return const <IntegrationCategory, DemoVendorCategoryState>{
        IntegrationCategory.pos: DemoVendorCategoryState(
          isDemo: true,
          connectionStatus: ConnectionStatus.disconnected,
          vendorId: _posVendorId,
          vendorDisplayName: _posVendorName,
        ),
        IntegrationCategory.labor: DemoVendorCategoryState(
          isDemo: true,
          connectionStatus: ConnectionStatus.disconnected,
          vendorId: _laborVendorId,
          vendorDisplayName: _laborVendorName,
        ),
        IntegrationCategory.reservation: DemoVendorCategoryState(
          isDemo: true,
          connectionStatus: ConnectionStatus.disconnected,
          vendorId: _reservationVendorId,
          vendorDisplayName: _reservationVendorName,
        ),
      };
    }
    return _states[location]!;
  }

  /// The per-category state for a (location, category). Public so the
  /// operator-web consistency test can assert both surfaces agree.
  static DemoVendorCategoryState stateFor({
    required String locationId,
    required IntegrationCategory category,
  }) =>
      _statesFor(locationId)[category]!;

  /// How many of this location's three categories have a vendor
  /// connection that renders a row — i.e. `connected` OR `error`
  /// (`error`/needs-reauth still models an EXISTING connection that has
  /// backfilled data; only `disconnected` means "nothing connected").
  /// Mirrors `_connectionRow`'s render rule exactly (a `disconnected`
  /// category returns no [VendorConnectionRow]).
  static int connectedCategoryCount(String locationId) {
    final states = _statesFor(locationId);
    var count = 0;
    for (final state in states.values) {
      if (state.connectionStatus != ConnectionStatus.disconnected) {
        count++;
      }
    }
    return count;
  }

  /// True when this location's demo vendor fixture has ZERO connected
  /// categories (every category `disconnected`) — the "none connected /
  /// awaiting first connection" state (spec §D.2 / §D.3: today exactly
  /// Harbour). The demo seeder consults this to keep such a location
  /// honest-EMPTY: no operational/historical rows are written for it, so
  /// the existing honest-degrade UI renders "awaiting first connection"
  /// instead of fabricated numbers (Metric Honesty). The
  /// `restaurant_locations` row + the `demo_mode_state` / vendor-fixture
  /// rows are still seeded, so the location stays in the scope drawer and
  /// the demo banners still render. Generalized off the fixture's
  /// connection state — NOT a hardcoded "if harbour".
  static bool isNoneConnected(String locationId) =>
      connectedCategoryCount(locationId) == 0;

  /// The three `demo_mode_state` rows for this (operator, location),
  /// in [IntegrationCategory.values] order. Fed to the mobile
  /// [DemoModeStateGateway] demo impl and, through the demo proxy
  /// surface, to `DemoModeStateNotifier`.
  static List<DemoModeRecord> demoModeRecords({
    required String operatorId,
    required String locationId,
  }) {
    final states = _statesFor(locationId);
    return <DemoModeRecord>[
      for (final category in IntegrationCategory.values)
        _recordFor(
          operatorId: operatorId,
          locationId: locationId,
          category: category,
          state: states[category]!,
        ),
    ];
  }

  static DemoModeRecord _recordFor({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required DemoVendorCategoryState state,
  }) {
    if (state.isDemo) {
      return DemoModeRecord(
        operatorId: operatorId,
        locationId: locationId,
        category: category,
        isDemo: true,
      );
    }
    // Already flipped to live — deterministic flip metadata.
    final offset = IntegrationCategory.values.indexOf(category);
    return DemoModeRecord(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      isDemo: false,
      flippedToLiveAt: _flipEpoch.add(Duration(minutes: offset)),
      flippedByConnectionId: _connectionId(locationId, state),
    );
  }

  static String _connectionId(
    String locationId,
    DemoVendorCategoryState state,
  ) =>
      'demo-conn-${state.vendorId}-$locationId';

  /// The operator-web [VendorConnectionsBundle] for this (operator,
  /// location). `demoFlags` is the SAME per-category `is_demo` as
  /// [demoModeRecords], and a vendor row renders only when the category
  /// is `connected` or `error` (a `disconnected` category renders no
  /// row — clean demo). This is what makes both surfaces consistent.
  static VendorConnectionsBundle vendorConnectionsBundle({
    required String operatorId,
    required String locationId,
    required String locationName,
  }) {
    final states = _statesFor(locationId);
    VendorConnectionRow? rowFor(IntegrationCategory category) =>
        _connectionRow(
          locationId: locationId,
          category: category,
          state: states[category]!,
        );
    return VendorConnectionsBundle(
      operatorId: operatorId,
      locationId: locationId,
      locationName: locationName,
      posConnection: rowFor(IntegrationCategory.pos),
      laborConnection: rowFor(IntegrationCategory.labor),
      reservationConnection: rowFor(IntegrationCategory.reservation),
      demoFlags: <VendorCategory, bool>{
        VendorCategory.pos: states[IntegrationCategory.pos]!.isDemo,
        VendorCategory.labor: states[IntegrationCategory.labor]!.isDemo,
        VendorCategory.reservation:
            states[IntegrationCategory.reservation]!.isDemo,
      },
    );
  }

  static VendorConnectionRow? _connectionRow({
    required String locationId,
    required IntegrationCategory category,
    required DemoVendorCategoryState state,
  }) {
    if (state.connectionStatus == ConnectionStatus.disconnected) {
      // No vendor connected for this category — clean demo, no row.
      return null;
    }
    final vendorCategory = _vendorCategory(category);
    final connected = state.connectionStatus == ConnectionStatus.connected;
    return VendorConnectionRow(
      connectionId: _connectionId(locationId, state),
      vendorId: state.vendorId,
      displayName: state.vendorDisplayName,
      category: vendorCategory,
      status: connected
          ? VendorConnectionStatus.connected
          : VendorConnectionStatus.error,
      metadata: const <String, Object?>{},
      lastSyncAt: connected ? _flipEpoch : null,
      lastErrorMessage: state.lastErrorMessage,
      recordsLast24h: connected ? 0 : null,
      errorsLast24h: connected ? 0 : null,
      firstBackfill: connected
          ? VendorConnectionFirstBackfill(
              // `is_demo=true` + connected ⇒ first backfill still
              // running (why the row hasn't flipped). `is_demo=false`
              // ⇒ backfill already succeeded (flipped to live).
              status: state.isDemo
                  ? VendorConnectionFirstBackfillStatus.running
                  : VendorConnectionFirstBackfillStatus.succeeded,
              startedAt: _flipEpoch,
              completedAt: state.isDemo
                  ? null
                  : _flipEpoch.add(const Duration(minutes: 24)),
              processedDays: state.isDemo ? 18 : 60,
              totalDays: 60,
            )
          : null,
    );
  }

  static VendorCategory _vendorCategory(IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return VendorCategory.pos;
      case IntegrationCategory.labor:
        return VendorCategory.labor;
      case IntegrationCategory.reservation:
        return VendorCategory.reservation;
    }
  }

  /// Seed map for `InMemoryVendorConnectionsGateway(seed: ...)` keyed
  /// `operatorId/locationId` (its internal key shape) for every
  /// operator-web demo location.
  static Map<String, VendorConnectionsBundle> vendorConnectionsSeed({
    required String operatorId,
    required Map<String, String> locationNamesById,
  }) {
    final seed = <String, VendorConnectionsBundle>{};
    for (final entry in _operatorWebLocationIds.entries) {
      final locationId = entry.key;
      seed['$operatorId/$locationId'] = vendorConnectionsBundle(
        operatorId: operatorId,
        locationId: locationId,
        locationName: locationNamesById[locationId] ?? 'Location $locationId',
      );
    }
    return seed;
  }
}

/// Demo `DemoModeStateGateway` implementation (the writer swap, HP #2).
///
/// Returns [DemoVendorIntegrationStateFixture] rows from
/// [readOrCreateDefault]. [flipToLive] honors the production one-way
/// Demo→Live semantics: a row already `is_demo=false` is returned
/// unchanged (idempotent / never auto-revert); a demo row is returned
/// flipped with the supplied connection id + timestamp. The gateway is
/// read-fixture (no persistence) — the demo build never mutates Postgres
/// — so a subsequent [readOrCreateDefault] still reflects the fixture,
/// which matches "demo data is reproducible per launch".
class DemoVendorIntegrationDemoModeStateGateway
    implements DemoModeStateGateway {
  const DemoVendorIntegrationDemoModeStateGateway({required this.operatorId});

  /// The active demo operator id, threaded onto every returned record
  /// so per-operator isolation (HP #4) holds.
  final String operatorId;

  @override
  Future<DemoModeRecord> readOrCreateDefault({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
  }) async {
    final state = DemoVendorIntegrationStateFixture.stateFor(
      locationId: locationId,
      category: category,
    );
    final records = DemoVendorIntegrationStateFixture.demoModeRecords(
      operatorId: operatorId,
      locationId: locationId,
    );
    return records.firstWhere(
      (r) => r.category == category,
      orElse: () => DemoModeRecord(
        operatorId: operatorId,
        locationId: locationId,
        category: category,
        isDemo: state.isDemo,
      ),
    );
  }

  @override
  Future<DemoModeRecord> flipToLive({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required String connectionId,
    required DateTime flippedAt,
  }) async {
    final current = await readOrCreateDefault(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
    );
    if (!current.isDemo) {
      // Idempotent: already live, never re-stamp / auto-revert.
      return current;
    }
    return DemoModeRecord(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      isDemo: false,
      flippedToLiveAt: flippedAt.toUtc(),
      flippedByConnectionId: connectionId,
    );
  }
}
