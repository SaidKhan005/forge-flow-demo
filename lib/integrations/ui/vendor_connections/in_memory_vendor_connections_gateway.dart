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

  static final List<VendorPickerEntry> vendorCatalog =
      List<VendorPickerEntry>.unmodifiable(<VendorPickerEntry>[
    VendorPickerEntry(
      vendorId: 'aloha_ncr_voyix',
      displayName: 'Aloha (NCR Voyix)',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
      apiKeyFieldLabel: 'Aloha API key',
      apiSecretFieldLabel: 'Site / restaurant ID',
      credentialsHelpText:
          'Find these in the NCR Voyix Developer Portal under your Aloha '
          'integration. The site ID identifies your restaurant; the API key '
          'authenticates Forge & Flow against Aloha cloud APIs.',
      credentialsPortalUrl: Uri.parse('https://developer.ncrvoyix.com/'),
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
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
      apiKeyFieldLabel: 'OAuth client ID',
      apiSecretFieldLabel: 'OAuth client secret',
      credentialsHelpText:
          'Generate an integration in the Lightspeed K-Series back office '
          '(Settings -> Integrations -> Create new). Copy the client ID and '
          'client secret here.',
      credentialsPortalUrl: Uri.parse('https://www.lightspeedhq.com/login/'),
    ),
    VendorPickerEntry(
      vendorId: 'oracle_micros_simphony',
      displayName: 'Oracle MICROS Simphony',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
      apiKeyFieldLabel: 'Simphony API key',
      apiSecretFieldLabel: 'Organisation short name',
      credentialsHelpText:
          'Open Oracle Simphony EMC -> Configuration -> Integrations and '
          'create a new API key for Forge & Flow. Pair it with your '
          'organisation short name (the tenant identifier shown on the '
          'Simphony login screen).',
      credentialsPortalUrl: Uri.parse('https://docs.oracle.com/en/industries/food-beverage/simphony.html'),
    ),
    VendorPickerEntry(
      vendorId: 'revel',
      displayName: 'Revel Systems',
      category: VendorCategory.pos,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
      apiKeyFieldLabel: 'Revel API key',
      apiSecretFieldLabel: 'Revel API secret',
      credentialsHelpText:
          'In the Revel Management Console, open Settings -> API '
          'Authentication and create a new key pair scoped to read access '
          'for orders, payments, and employees.',
      credentialsPortalUrl: Uri.parse('https://app.revelsystems.com/'),
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
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: true,
      requiresModule: false,
      apiKeyFieldLabel: 'Toast API auth token',
      apiSecretFieldLabel: 'Restaurant GUID',
      credentialsHelpText:
          'In Toast Web, open Integrations -> Restaurant API and request a '
          'partner integration. Toast will return an auth token; pair it '
          'with the restaurant GUID shown on the same page.',
      credentialsPortalUrl: Uri.parse('https://www.toasttab.com/login'),
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
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
      apiKeyFieldLabel: 'OpenTable client ID',
      apiSecretFieldLabel: 'OpenTable client secret',
      credentialsHelpText:
          'Open the OpenTable Restaurant Center, then go to '
          'Integrations -> Open API and copy the client ID + client secret '
          'OpenTable issued for your restaurant.',
      credentialsPortalUrl: Uri.parse('https://restaurant.opentable.com/'),
    ),
    VendorPickerEntry(
      vendorId: 'sevenrooms',
      displayName: 'SevenRooms',
      category: VendorCategory.reservation,
      authMode: VendorAuthMode.oauthOrKeyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
      apiKeyFieldLabel: 'SevenRooms API key',
      apiSecretFieldLabel: 'Venue ID',
      credentialsHelpText:
          'In the SevenRooms admin console, open Settings -> Integrations '
          'and create an API key with read access. Pair it with the venue '
          'ID for the location you are connecting.',
      credentialsPortalUrl: Uri.parse('https://www.sevenrooms.com/login/'),
    ),
    VendorPickerEntry(
      vendorId: 'tock',
      displayName: 'Tock',
      category: VendorCategory.reservation,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
      apiKeyFieldLabel: 'Tock API key',
      credentialsHelpText:
          'Tock issues partner API keys directly via your account manager. '
          'Once you have the key, paste it here. Forge & Flow uses it to '
          'read reservations and party sizes for this venue.',
      credentialsPortalUrl: Uri.parse('https://www.exploretock.com/'),
    ),
    VendorPickerEntry(
      vendorId: 'adp',
      displayName: 'ADP Workforce Now / Workforce Manager',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: true,
      modules: <String>['workforce_now', 'workforce_manager', 'run'],
      apiKeyFieldLabel: 'ADP client ID',
      apiSecretFieldLabel: 'ADP client secret',
      credentialsHelpText:
          'In the ADP Marketplace developer console, open the Forge & Flow '
          'integration listing and copy the client ID and client secret '
          'issued for your tenant.',
      credentialsPortalUrl: Uri.parse('https://developers.adp.com/'),
    ),
    VendorPickerEntry(
      vendorId: 'agendrix',
      displayName: 'Agendrix',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
      apiKeyFieldLabel: 'Agendrix API key',
      credentialsHelpText:
          'In Agendrix, open Account -> Integrations -> Public API and '
          'generate a new API token scoped to your account.',
      credentialsPortalUrl: Uri.parse('https://app.agendrix.com/'),
    ),
    VendorPickerEntry(
      vendorId: 'humanity',
      displayName: 'Humanity',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
      apiKeyFieldLabel: 'Humanity API key',
      credentialsHelpText:
          'In Humanity, go to Settings -> Account -> API access and '
          'generate a personal access token. Forge & Flow uses it to read '
          'shifts, time clocks, and employees.',
      credentialsPortalUrl: Uri.parse('https://www.humanity.com/app/'),
    ),
    VendorPickerEntry(
      vendorId: 'push_operations',
      displayName: 'Push Operations',
      category: VendorCategory.labor,
      authMode: VendorAuthMode.keyPaste,
      lifecycle: VendorLifecycle.documented,
      coversFieldExposed: false,
      requiresModule: false,
      apiKeyFieldLabel: 'Push Operations API key',
      credentialsHelpText:
          'Sign in to Push Operations as an admin, open Settings -> '
          'Developer / API and generate a new API key for Forge & Flow.',
      credentialsPortalUrl: Uri.parse('https://app.pushoperations.com/'),
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
  ]);

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
  Future<VendorApiKeyConnectResult> connectWithApiKey({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String apiKey,
    String? apiSecret,
    String? module,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw VendorConnectionsGatewayError(
        message: 'API key is required.',
        remediation: 'Paste the API key from the vendor portal and try again.',
      );
    }
    final entry = vendorCatalog.firstWhere(
      (candidate) => candidate.vendorId == vendorId,
      orElse: () => throw VendorConnectionsGatewayError(
        message: 'Unknown vendor: $vendorId',
        remediation: 'Pick a vendor from the connection dialog.',
      ),
    );
    final bundle = await loadBundle(
      operatorId: operatorId,
      locationId: locationId,
    );
    final connectedAt = DateTime.now().toUtc();
    final connection = VendorConnectionRow(
      connectionId: 'demo-conn-$vendorId',
      vendorId: vendorId,
      displayName: entry.displayName,
      category: entry.category,
      status: VendorConnectionStatus.connected,
      metadata: <String, Object?>{
        if (apiSecret != null && apiSecret.trim().isNotEmpty)
          'username': apiSecret.trim(),
      },
      module: module,
      lastSyncAt: connectedAt,
      webhookUrl: null,
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
    return VendorApiKeyConnectResult(
      connectionId: connection.connectionId,
      connectedAt: connectedAt,
      firstBackfillStarted: true,
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
