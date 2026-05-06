// Phase 8.0 — In-memory Vendor Connections gateway.
//
// Used by the kDemoMode walkthrough and widget tests. Seeds the full
// implemented adapter catalog so setup surfaces can show every vendor
// without a live proxy or vendor sandbox.
//
// The stub adapter responses mirror the docs/phases/phase_8/
// wave_1_vendor_profiles.md + vendor_master_list.md spec exactly so
// the surface is provably faithful — operator-facing copy and field
// mapping match the docs verbatim.

import 'vendor_connections_gateway.dart';
import 'vendor_connections_models.dart';

class InMemoryVendorConnectionsGateway implements VendorConnectionsGateway {
  InMemoryVendorConnectionsGateway({Map<String, VendorConnectionsBundle>? seed})
    : _bundles = seed != null
          ? Map<String, VendorConnectionsBundle>.from(seed)
          : <String, VendorConnectionsBundle>{};

  final Map<String, VendorConnectionsBundle> _bundles;

  static const List<VendorPickerEntry> vendorCatalog = <VendorPickerEntry>[
    VendorPickerEntry(
      vendorId: 'aloha_ncr_voyix',
      displayName: 'Aloha (NCR Voyix)',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'clover',
      displayName: 'Clover',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'lightspeed_lsk',
      displayName: 'Lightspeed Restaurant K-Series',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'oracle_micros_simphony',
      displayName: 'Oracle MICROS Simphony',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'revel',
      displayName: 'Revel Systems',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'square',
      displayName: 'Square',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'toast',
      displayName: 'Toast',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'libro',
      displayName: 'Libro Reserve',
      category: VendorCategory.reservation,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'opentable',
      displayName: 'OpenTable',
      category: VendorCategory.reservation,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'sevenrooms',
      displayName: 'SevenRooms',
      category: VendorCategory.reservation,
      authMode: VendorAuthMode.oauthOrKeyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'tock',
      displayName: 'Tock',
      category: VendorCategory.reservation,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'adp',
      displayName: 'ADP Workforce Now / Workforce Manager',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: true,
      modules: <String>['workforce_now', 'workforce_manager', 'run'],
    ),
    VendorPickerEntry(
      vendorId: 'agendrix',
      displayName: 'Agendrix',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'humanity',
      displayName: 'Humanity',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'push_operations',
      displayName: 'Push Operations',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
    VendorPickerEntry(
      vendorId: 'quickbooks_time',
      displayName: 'QuickBooks Time',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: true,
      modules: <String>['time', 'accounting', 'payroll'],
    ),
    VendorPickerEntry(
      vendorId: 'seven_shifts',
      displayName: '7shifts',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.oauth,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
    ),
  ];

  String _key(String operatorId, String locationId) =>
      '$operatorId/$locationId';

  @override
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  }) async {
    return _bundles[_key(operatorId, locationId)] ??
        VendorConnectionsBundle(
          operatorId: operatorId,
          locationId: locationId,
          locationName: 'Location $locationId',
          posConnection: null,
          laborConnection: null,
          reservationConnection: null,
          demoFlags: const <VendorCategory, bool>{
            VendorCategory.pos: true,
            VendorCategory.labor: true,
            VendorCategory.reservation: true,
          },
        );
  }

  @override
  Future<List<VendorPickerEntry>> listAvailableVendors({
    required VendorCategory category,
  }) async {
    return vendorCatalog
        .where((entry) => entry.category == category)
        .toList(growable: false);
  }

  @override
  Future<VendorConnectFlowStart> startConnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    String? module,
  }) async {
    // Stub: pretend the operator clicked through the OAuth flow and
    // returned successfully. Update the bundle with a "connected"
    // row, return a redirect URL the test harness can ignore.
    final bundle = await loadBundle(
      operatorId: operatorId,
      locationId: locationId,
    );
    final entry = vendorCatalog.firstWhere((e) => e.vendorId == vendorId);
    final connection = VendorConnectionRow(
      connectionId: 'demo-conn-$vendorId',
      vendorId: vendorId,
      displayName: entry.displayName,
      category: entry.category,
      status: VendorConnectionStatus.connected,
      metadata: _stubMetadata(vendorId),
      module: module,
      lastSyncAt: DateTime.now().toUtc(),
      webhookUrl:
          'https://api.forgeflow.app/v1/webhooks/$vendorId/$operatorId/$locationId',
      recordsLast24h: 0,
      errorsLast24h: 0,
    );
    final updated = VendorConnectionsBundle(
      operatorId: operatorId,
      locationId: locationId,
      locationName: bundle.locationName,
      posConnection: entry.category == VendorCategory.pos
          ? connection
          : bundle.posConnection,
      laborConnection: entry.category == VendorCategory.labor
          ? connection
          : bundle.laborConnection,
      reservationConnection: entry.category == VendorCategory.reservation
          ? connection
          : bundle.reservationConnection,
      // Demo flag does NOT flip on connect alone in V1; the writer-side
      // policy requires a backfill commit. The walkthrough simulates
      // that subsequently via a separate test step.
      demoFlags: bundle.demoFlags,
    );
    _bundles[_key(operatorId, locationId)] = updated;
    return VendorConnectFlowStart(
      redirectUrl: 'https://demo.example.com/oauth/$vendorId/start',
      flowKind: VendorConnectFlowKind.oauthRedirect,
    );
  }

  @override
  Future<VendorTestConnectionResult> testConnection({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    switch (vendorId) {
      case 'lightspeed_lsk':
        return const VendorTestConnectionResult(
          authValid: true,
          elapsedMs: 1200,
          sampleSummary: 'Order #12345 - 2026-05-02 - \$42.50 - covers: 3',
          fieldMapping: <String, String>{
            'covers': '3',
            'opened_at': '2026-05-02 18:45',
            'closed_at': '2026-05-02 19:42',
          },
        );
      case 'libro':
        return const VendorTestConnectionResult(
          authValid: true,
          elapsedMs: 800,
          sampleSummary: 'Reservation #R-9011 - 2026-05-02 19:30 - party of 4',
          fieldMapping: <String, String>{
            'covers': '4',
            'arrival_at': '2026-05-02 19:30',
            'depart_at': '2026-05-02 21:15',
          },
        );
      case 'quickbooks_time':
        return const VendorTestConnectionResult(
          authValid: true,
          elapsedMs: 1500,
          sampleSummary: 'Punch #P-7733 - 2026-05-02 - 6.5 hrs - role: Server',
          fieldMapping: <String, String>{
            'duration_hours': '6.5',
            'clock_in_at': '2026-05-02 11:30',
            'clock_out_at': '2026-05-02 18:00',
            'role': 'Server',
          },
          note:
              'Wage source: Vendor (QuickBooks Time records hourly_rate '
              'on the timecard).',
        );
      default:
        throw VendorConnectionsGatewayError(
          message: 'unknown demo vendor: $vendorId',
          remediation:
              'Pick one of: Lightspeed Restaurant K-Series, Libro Reserve, '
              'QuickBooks Time.',
          statusCode: 404,
        );
    }
  }

  @override
  Future<void> disconnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String reason,
  }) async {
    final bundle = await loadBundle(
      operatorId: operatorId,
      locationId: locationId,
    );
    final updated = VendorConnectionsBundle(
      operatorId: operatorId,
      locationId: locationId,
      locationName: bundle.locationName,
      posConnection: _matchesVendor(bundle.posConnection, vendorId)
          ? null
          : bundle.posConnection,
      laborConnection: _matchesVendor(bundle.laborConnection, vendorId)
          ? null
          : bundle.laborConnection,
      reservationConnection:
          _matchesVendor(bundle.reservationConnection, vendorId)
          ? null
          : bundle.reservationConnection,
      demoFlags: bundle.demoFlags,
    );
    _bundles[_key(operatorId, locationId)] = updated;
  }

  bool _matchesVendor(VendorConnectionRow? row, String vendorId) {
    return row != null && row.vendorId == vendorId;
  }

  @override
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async {
    final base = DateTime.now().toUtc();
    return <VendorSyncLogEntry>[
      VendorSyncLogEntry(
        occurredAt: base.subtract(const Duration(minutes: 2)),
        eventKind: 'poll_success',
        recordsCount: 3,
      ),
      VendorSyncLogEntry(
        occurredAt: base.subtract(const Duration(minutes: 7)),
        eventKind: 'poll_success',
        recordsCount: 5,
      ),
      VendorSyncLogEntry(
        occurredAt: base.subtract(const Duration(minutes: 12)),
        eventKind: 'rate_limit_retry',
        errorMessage: 'rate-limit retry (1/3)',
      ),
      VendorSyncLogEntry(
        occurredAt: base.subtract(const Duration(minutes: 12, seconds: 1)),
        eventKind: 'poll_success',
        recordsCount: 2,
      ),
    ];
  }

  Map<String, Object?> _stubMetadata(String vendorId) {
    switch (vendorId) {
      case 'lightspeed_lsk':
        return const <String, Object?>{'business_id': 'demo-lsk-business-7c2f'};
      case 'libro':
        return const <String, Object?>{'venue_id': 'demo-libro-venue-8821'};
      case 'quickbooks_time':
        return const <String, Object?>{'realm_id': 'demo-qbt-realm-44102'};
      default:
        return const <String, Object?>{};
    }
  }
}
