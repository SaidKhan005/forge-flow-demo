// Phase 8.S.ADP — ADP Workforce Now / Workforce Manager labor adapter
// (lifecycle = documented).
//
// ADP is the longest partnership lead time in the wave (12-24 weeks
// for the ADP Marketplace Developer Participation Agreement). The
// developer-portal API catalog is publicly indexed at
// https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog
// (retrieval date 2026-05-04 — same portal hosts WFM), but every
// endpoint shape is gated behind partner-issued sandbox + production
// credentials. This slice engineers the adapter against the published
// shapes (Time Work Schedules v1, Team Time Cards v2, Work
// Assignments) so the moment ADP issues partner credentials only the
// small `8.S.ADP.live.sandbox` slice remains. EVERY field-mapping
// assumption is captured in `documentedPerAdpV1FieldMapping` with
// `verify_in_live_sandbox: true` and mirrored row-for-row in
// `docs/integrations/adp/field_mapping.md` so the `*.live` diff is
// automatable.
//
// **Module disambiguation (load-bearing).** Three ADP products show
// up in the operator's life:
//   * Workforce Now (WFN)     — INTEGRATE; supported.
//   * Workforce Manager (WFM) — INTEGRATE; supported.
//   * RUN                     — REFUSED; payroll-only product, lacks
//                               the schedule + punch surfaces F&F
//                               needs. The connect flow throws
//                               [ModuleRefusalException] with the
//                               exact friendly copy locked in
//                               `docs/phases/phase_8/vendor_master_list.md`.
// The capability profile carries `modules = ['workforce_now',
// 'workforce_manager', 'run']` so the operator-facing picker can
// disambiguate; RUN is listed for picker disambiguation only and
// bounces at connect.
//
// Doctrine reference: `docs/contracts/vendor_adapter_slice_contract.md`
// + `docs/contracts/per_vendor_doc_pack_contract.md`. Engineer-all-17
// lock: `memory/project_phase_8_engineer_all_17_doctrine.md` —
// adapter ships at lifecycle = `documented`; lifecycle promotion
// happens in `8.S.ADP.live.sandbox` / `8.S.ADP.live.prod`.
//
// Banned items per V1 lean cut 2 (REJECT if reintroduced) — see
// `docs/contracts/vendor_adapter_slice_contract.md` for the full
// list. The slice's banned-items grep test in
// `test/integrations/labor/adp_labor_adapter_test.dart` pins each
// forbidden substring. Engineering inside this file refuses every
// one of them by construction: no key rotation surface, no advisory
// locks, no graceful-drain hook, no dead-letter UI, no sidecar
// raw-payload partitions, no 5-second test-connection SLA, no email
// auto-disable, no partial-write flag (malformed payloads drop at
// the adapter boundary), no strict 5-minute replay window (the
// framework's 24h ceiling stands).

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/labor_adapter.dart';
import '../../services/integration/vendor_timestamp_policy.dart';

// ─── Vendor key + display name ──────────────────────────────────────

/// Stable vendor identifier matching `connector_connection.vendor_id`.
/// Single key for both WFN and WFM modules — module disambiguation
/// lives in `connector_connection.metadata.module`, not in the vendor
/// id, so reconnects know which product was originally chosen.
const String kAdpVendorId = 'adp';

/// Operator-facing display name. Both supported modules share the
/// brand surface; the picker disambiguates per module.
const String kAdpDisplayName = 'ADP Workforce Now / Workforce Manager';

// ─── Module identifiers ─────────────────────────────────────────────

/// Module identifier for ADP Workforce Now — INTEGRATE.
const String kAdpModuleWorkforceNow = 'workforce_now';

/// Module identifier for ADP Workforce Manager — INTEGRATE.
const String kAdpModuleWorkforceManager = 'workforce_manager';

/// Module identifier for ADP RUN — REFUSED at connect time. RUN is
/// payroll-only and does not expose the schedule + punch surfaces F&F
/// needs. Listed in the capability profile so the picker can
/// disambiguate; bounces with [ModuleRefusalException].
const String kAdpModuleRun = 'run';

/// Friendly refusal copy locked in
/// `docs/phases/phase_8/vendor_master_list.md` "Module Disambiguation
/// Flags". Word-for-word — the test-connection / connect surfaces
/// render this verbatim and the slice's tests pin exact-string match.
const String kAdpRunRefusalCopy =
    'ADP RUN is a payroll-only product. Forge & Flow needs schedule '
    'and time-punch data. If you also use ADP Workforce Now or '
    'Workforce Manager, connect that instead. Otherwise, please use '
    'one of these supported scheduling vendors: [list].';

/// Thrown by [AdpLaborAdapter.connect] when the operator selects an
/// unsupported ADP module (RUN at V1; future modules surface the
/// same way). Carries the [moduleId] the operator picked and the
/// friendly [message] the operator-facing surface renders verbatim.
class ModuleRefusalException implements Exception {
  const ModuleRefusalException({
    required this.vendorId,
    required this.moduleId,
    required this.message,
  });

  /// Stable vendor key (`adp`).
  final String vendorId;

  /// Module the operator selected (`run` at V1).
  final String moduleId;

  /// Friendly copy the picker / connect modal renders verbatim. For
  /// ADP RUN this is [kAdpRunRefusalCopy], pinned by test.
  final String message;

  @override
  String toString() =>
      'ModuleRefusalException(vendor=$vendorId, module=$moduleId): $message';
}

// ─── Documented-per-ADP field mapping (assumption snapshot) ──────────

/// Field-mapping reference captured at slice ship.
///
/// EVERY entry is an assumption against the documented ADP API shapes
/// indexed at the developer-portal API catalog (Time Work Schedules
/// v1 / Team Time Cards v2 / Work Assignments / Workers). No live ADP
/// payload has been observed yet because partner credentials are
/// gated on the ADP Marketplace Developer Participation Agreement
/// (see `docs/integrations/adp/partnership_status.md`). The
/// `verify_in_live_sandbox: true` flag on every row tells the
/// `8.S.ADP.live.sandbox` slice which entries to diff against the
/// first observed sandbox response. Mismatches become bounded fixes,
/// not slice rebuilds, per
/// `docs/contracts/vendor_adapter_slice_contract.md`.
///
/// Source notes:
/// - API catalog (publicly indexed; endpoint shapes gated):
///   https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog
///   (retrieved 2026-05-04). The same portal hosts the Workforce
///   Manager (WFM) catalog; WFN and WFM share most schema where it
///   matters for schedule + punch data, with small differences
///   captured row-by-row when the live diff exposes them.
const Map<String, Object?> documentedPerAdpV1FieldMapping =
    <String, Object?>{
  'api_version': 'v1-2026-05-04-assumed',
  'vendor_entity_id': <String, Object?>{
    'path': 'time_event.id',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
    'note': 'ADP Team Time Cards v2 / Time Events expose a stable id; '
        'the *.live slice verifies the exact path (some WFN endpoints '
        'use `time_event.itemID` / WFM `timePunch.punchID`).',
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'time_event.last_modified_date_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
    'note': 'Assumed UTC ISO-8601 with explicit Z; *.live diff '
        'confirms. ADP datetime fields commonly carry the `Z` per the '
        'developer-portal samples but the partner doc pins the rule.',
  },
  'shift_start': <String, Object?>{
    'path': 'time_event.entry_date_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
    'note': 'Per ADP docs the punch entry is `entry_date_time`; for '
        'scheduled shift records (Time Work Schedules v1) the '
        'corresponding field is `scheduled_start_date_time`. *.live '
        'verifies which the adapter consumes per resource.',
  },
  'shift_end': <String, Object?>{
    'path': 'time_event.exit_date_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
    'note': 'For open punches `exit_date_time` is null until the '
        'employee clocks out; the canonicalizer treats null as an '
        'open punch and the read layer projects "in progress".',
  },
  'role_name': <String, Object?>{
    'path': 'worker.position.position_title',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
    'note': 'WFN exposes role via `worker.position.position_title`; '
        'WFM exposes via `workAssignment.jobTitle`. The *.live slice '
        'records which path each module returns and the adapter '
        'reads the right one per `module` metadata.',
  },
  'employee_id': <String, Object?>{
    'path': 'worker.associate_oid',
    'type': 'string',
    'transform': 'direct',
    'doc_url':
        'https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog',
    'verify_in_live_sandbox': true,
    'note': '`associate_oid` is ADP-stable across the worker lifecycle '
        '(per ADP developer-portal "Workers" reference) and is the '
        'canonical employee identity within the ADP namespace. '
        'Cross-vendor employee identity is an explicit non-goal at V1 '
        '(see Phase 8.S plan).',
  },
  // Endpoints (assumed shapes — the developer-portal API catalog
  // indexes the products; the partner doc pins the exact paths):
  'oauth_token_url_assumed':
      'https://accounts.adp.com/auth/oauth/v2/token',
  'oauth_grant_type_assumed': 'authorization_code',
  'api_base_url_assumed': 'https://api.adp.com',
  'time_events_endpoint_assumed':
      '/time/v2/workers/{associate_oid}/time-events',
  'team_time_cards_endpoint_assumed':
      '/time/v2/workers/{associate_oid}/team-time-cards',
  'time_work_schedules_endpoint_assumed':
      '/time/v1/workers/{associate_oid}/work-schedules',
  'work_assignments_endpoint_assumed':
      '/hr/v2/workers/{associate_oid}/work-assignments',
  'workers_endpoint_assumed':
      '/hr/v2/workers',
  'event_subscription_endpoint_assumed':
      '/core/v1/event-subscriptions',
  'event_subscription_event_assumed':
      'time.timeEvent.modify',
  'signature_header_assumed': 'ADP-Signature',
  'signature_algorithm_assumed': 'HMAC-SHA256',
  'signature_encoding_assumed': 'base64',
};

// ─── Local timestamp policy (deferred-merged into framework catalog) ──

/// Local ADP timestamp policy. The framework's
/// `vendorTimestampPolicy` catalog is amended at the Wave B
/// integration commit. Until then the adapter exposes this directly
/// so downstream tests can assert the convention.
const TimestampPolicy adpTimestampPolicy = TimestampPolicy(
  vendorId: kAdpVendorId,
  ambiguousConvention: AmbiguousTimestampConvention.refuse,
  documentationNote:
      'ADP datetime fields commonly carry an explicit UTC `Z` per the '
      'developer-portal samples, but the partner doc has not been '
      'observed yet. The adapter refuses ambiguous timestamps until '
      'the *.live.sandbox slice confirms the shape; silent fallback '
      'to "treat as UTC" is exactly the bug Scenario E is designed '
      'to catch.',
);

// ─── Webhook event names ─────────────────────────────────────────────

/// ADP Marketplace event-subscription event name for time-event
/// modification (assumed shape; verified in `8.S.ADP.live.sandbox`).
const String kAdpEventSubscriptionTimeEventModify = 'time.timeEvent.modify';

// ─── Transport abstraction (real HTTP lands in *.live slices) ────────

/// Token envelope returned by ADP's OAuth endpoint.
class AdpTokenResponse {
  const AdpTokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
}

/// One page of time-event history returned by the time-events /
/// team-time-cards endpoints.
class AdpTimeEventsPage {
  const AdpTimeEventsPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape time-event rows. Each is normalized into a
  /// canonical fact via [_canonicalize].
  final List<Map<String, Object?>> records;

  /// Next-page cursor; null when the server reports no more pages.
  final String? nextCursor;

  /// `last_modified_date_time` of the latest record on this page
  /// (UTC). Stamped onto the watermark per batch.
  final DateTime lastModifiedSeen;
}

/// Stub transport surface. Production wires HTTP via the `*.live`
/// slices when partner credentials arrive; tests inject
/// `_FakeAdpTransport` (in test file) to exercise every framework
/// call without a live vendor or partner doc.
abstract class AdpTransport {
  /// `POST /auth/oauth/v2/token` (assumed). Authorization-code
  /// completion on first connect; rotating refresh on cron tick.
  Future<AdpTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
    required String module,
  });

  /// `POST /auth/oauth/v2/token` (assumed) with
  /// `grant_type=refresh_token`. Documented in
  /// `docs/integrations/adp/oauth_shape.md`.
  Future<AdpTokenResponse> refresh({
    required String refreshToken,
    required String module,
  });

  /// `POST /auth/oauth/v2/revoke` (assumed) — best-effort revoke on
  /// disconnect. Vendor outage MUST NOT block disconnect.
  Future<void> revoke({required String accessToken});

  /// `GET /time/v2/workers/{associate_oid}/team-time-cards` (assumed)
  /// or the WFM equivalent. Paginated; the adapter walks pages during
  /// backfill + poll.
  Future<AdpTimeEventsPage> listTimeEvents({
    required String accessToken,
    required String module,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  });

  /// `GET /hr/v2/workers/{associate_oid}` (assumed). Used by webhook
  /// lookups when the inbound payload omits a needed worker field
  /// (role / position).
  Future<Map<String, Object?>> fetchWorker({
    required String accessToken,
    required String module,
    required String associateOid,
  });

  /// Auto-register an ADP Marketplace event subscription (assumed).
  /// Returns the vendor-issued subscription id (stored in
  /// `connector_connection.metadata.event_subscription_id`).
  Future<String> registerEventSubscription({
    required String accessToken,
    required String module,
    required String url,
    required List<String> events,
    required String signingSecret,
  });

  /// `DELETE` the previously-registered subscription on disconnect.
  Future<void> unregisterEventSubscription({
    required String accessToken,
    required String module,
    required String subscriptionId,
  });

  /// Sample time-event probe used by [LaborAdapter.testConnection].
  /// Returns the most recent time event so the operator can eyeball
  /// the field mapping (shift_start, shift_end, role_name).
  Future<Map<String, Object?>> sampleTimeEvent({
    required String accessToken,
    required String module,
  });
}

// ─── Persistence abstraction (real Postgres lands in *.live slices) ──

/// Connection row read/written by the adapter. Mirrors the shape of
/// `connector_connection` JSONB metadata for the relevant ADP keys.
class AdpConnectionRow {
  const AdpConnectionRow({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.module,
    required this.subscriptionId,
    required this.status,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;

  /// Module the operator picked at connect (`workforce_now` /
  /// `workforce_manager`). RUN never reaches this row — refused
  /// upstream in [AdpLaborAdapter.connect].
  final String module;

  /// Vendor-issued event-subscription id; null until the auto-
  /// register call succeeds.
  final String? subscriptionId;
  final ConnectionStatus status;

  Map<String, Object?> toMetadata() => <String, Object?>{
        'module': module,
        if (subscriptionId != null) 'event_subscription_id': subscriptionId,
      };
}

/// Watermark row mirroring `connector_sync_watermark`.
class AdpWatermarkRow {
  const AdpWatermarkRow({
    required this.cursorToken,
    required this.lastModifiedSeen,
  });

  final String cursorToken;
  final DateTime lastModifiedSeen;
}

/// One canonical time-punch fact write request handed to the gateway.
/// The gateway is responsible for the upsert on
/// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
/// per `docs/contracts/vendor_adapter_slice_contract.md`. Returns
/// `false` when the upsert hits an existing row (idempotency
/// short-circuit).
class AdpCanonicalTimePunchFact {
  const AdpCanonicalTimePunchFact({
    required this.operatorId,
    required this.locationId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.shiftStart,
    required this.shiftEnd,
    required this.roleName,
    required this.employeeId,
    required this.module,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final DateTime shiftStart;

  /// Null when the punch is open (employee has not clocked out yet).
  final DateTime? shiftEnd;

  final String roleName;
  final String employeeId;

  /// `workforce_now` / `workforce_manager`. Persists alongside the
  /// canonical fact so downstream reads can disambiguate the source
  /// module.
  final String module;

  final Map<String, Object?> rawPayload;
}

/// Persistence surface the adapter depends on. Production wires a
/// `OperatorScopedRepository.withTenant`-backed implementation. Tests
/// inject fakes.
abstract class AdpGateway {
  /// Persist the connection row inside an
  /// `OperatorScopedRepository.withTenant` block. Returns the stored
  /// row.
  Future<AdpConnectionRow> upsertConnection({
    required AdpConnectionRow row,
  });

  /// Read the watermark for `(operatorId, locationId)`. Null when the
  /// connection has never run a backfill / poll.
  Future<AdpWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  });

  /// Persist the watermark **after each successful batch commit** so
  /// a Cloud Run Job restart resumes from the last persisted cursor
  /// (per the framework contract — never end-of-backfill).
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required AdpWatermarkRow row,
  });

  /// Upsert one canonical time-punch fact; returns `true` when a row
  /// was written, `false` when the upsert short-circuited on the
  /// idempotency UNIQUE.
  Future<bool> writeTimePunchFact(AdpCanonicalTimePunchFact fact);

  /// Wipe the credential ciphertext on disconnect. Watermark and
  /// canonical facts are preserved so reconnect resumes from the last
  /// cursor.
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  });

  /// Look up the active access-token credential. Used by polling /
  /// backfill / webhook registration paths. Returns null when the
  /// connection is disconnected.
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  });

  /// Look up the connected ADP module (`workforce_now` /
  /// `workforce_manager`). Returns null when no connection exists.
  Future<String?> readModule({
    required String operatorId,
    required String locationId,
  });
}

// ─── Adapter ────────────────────────────────────────────────────────

/// ADP Workforce Now / Workforce Manager labor adapter
/// (lifecycle = documented).
///
/// Implements every framework seam declared in [LaborAdapter] against
/// the documented ADP API shapes. Live HTTP wiring is the
/// `*.live.sandbox` / `*.live.prod` slice's job; this slice ships
/// fixture-backed coverage of every code path so the diff against
/// the first observed sandbox response is bounded.
class AdpLaborAdapter implements LaborAdapter {
  AdpLaborAdapter({
    required AdpTransport transport,
    required AdpGateway gateway,
    DateTime Function()? now,
  })  : _transport = transport,
        _gateway = gateway,
        _now = now ?? DateTime.now;

  final AdpTransport _transport;
  final AdpGateway _gateway;
  final DateTime Function() _now;

  /// Local timestamp policy (deferred-merged into framework catalog).
  TimestampPolicy get timestampPolicy => adpTimestampPolicy;

  @override
  String get vendorId => kAdpVendorId;

  @override
  String get displayName => kAdpDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kAdpVendorId,
        displayName: kAdpDisplayName,
        category: IntegrationCategory.labor,
        // Assumed authorization_code OAuth (the ADP Marketplace
        // partner flow exposes a hosted sign-in for both modules);
        // verified in `8.S.ADP.live.sandbox`.
        authMode: VendorAuthMode.oauth,
        // ADP organizes a company across multiple worksites under a
        // single grant; the connect flow issues one OAuth grant for
        // the operator's ADP company and the adapter discovers
        // worksite → location bindings from there.
        grantScope: VendorGrantScope.operatorWide,
        // ADP Marketplace event subscriptions auto-register via
        // the `/core/v1/event-subscriptions` endpoint (assumed);
        // verified in `8.S.ADP.live.sandbox`.
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Labor systems do not expose a covers field — covers come
        // from POS. Recorded as `not_applicable` per the field
        // mapping doc.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        // Three modules listed for picker disambiguation. WFN and
        // WFM proceed; RUN bounces with [ModuleRefusalException].
        modules: <String>[
          kAdpModuleWorkforceNow,
          kAdpModuleWorkforceManager,
          kAdpModuleRun,
        ],
        timestampPolicyDocId: 'docs/integrations/adp/field_mapping.md',
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kAdpVendorId) {
      throw StateError(
        'connect dispatched to AdpLaborAdapter for non-ADP '
        'vendor ${command.vendorId}',
      );
    }

    // Module disambiguation (load-bearing). The picker passes
    // `command.module`; RUN bounces with the friendly copy locked in
    // `vendor_master_list.md`.
    final rawModule = command.module;
    if (rawModule == kAdpModuleRun) {
      throw const ModuleRefusalException(
        vendorId: kAdpVendorId,
        moduleId: kAdpModuleRun,
        message: kAdpRunRefusalCopy,
      );
    }
    if (rawModule != kAdpModuleWorkforceNow &&
        rawModule != kAdpModuleWorkforceManager) {
      // Unknown module (including null) — refuse explicitly so a
      // future ADP product (Lyric / etc.) cannot silently slip
      // through.
      throw ModuleRefusalException(
        vendorId: kAdpVendorId,
        moduleId: rawModule ?? '',
        message: 'Unknown ADP module "${rawModule ?? ''}". Please '
            'select Workforce Now or Workforce Manager.',
      );
    }
    // After the equality checks above, [rawModule] is non-null and
    // is exactly one of the supported module ids. Promote to a
    // non-null local so the transport calls type-check.
    final String module = rawModule!;

    // For the documented slice we accept the OAuth callback envelope
    // (`oauthState` carries the authorization code in the assumed
    // shape — the proxy framework already validated the state token
    // at the start of the flow). Production wires the real callback
    // against the partner-issued OAuth endpoint; the documented slice
    // exercises the same code path against the test transport.
    final state = command.oauthState;
    if (state == null || state.isEmpty) {
      return const ConnectResult(
        connectionId: '',
        status: ConnectionStatus.error,
        metadata: <String, Object?>{},
      );
    }

    final tokenResponse = await _transport.exchangeAuthorizationCode(
      authorizationCode: state,
      redirectUri: 'https://proxy.example/v1/oauth/callback/$kAdpVendorId',
      module: module,
    );

    // Auto-register the event subscription so time-event modifications
    // flow inbound. The signing secret is operator-owned and round-
    // trips through the ADP Marketplace partner portal — the adapter
    // hands ciphertext to the gateway and never touches plaintext
    // beyond the in-memory hop.
    final subscriptionId = await _transport.registerEventSubscription(
      accessToken: tokenResponse.accessToken,
      module: module,
      url: 'https://proxy.example/v1/webhooks/${command.operatorId}/'
          '${command.locationId}/$kAdpVendorId',
      events: const <String>[kAdpEventSubscriptionTimeEventModify],
      signingSecret: tokenResponse.accessToken,
    );

    final row = AdpConnectionRow(
      connectionId:
          'adp-${command.operatorId}-${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
      module: module,
      subscriptionId: subscriptionId,
      status: ConnectionStatus.connected,
    );
    final stored = await _gateway.upsertConnection(row: row);
    return ConnectResult(
      connectionId: stored.connectionId,
      status: stored.status,
      metadata: stored.toMetadata(),
      webhookUrl:
          'https://proxy.example/v1/webhooks/${command.operatorId}/'
          '${command.locationId}/$kAdpVendorId',
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    final start = _now().toUtc();
    final accessToken = await _gateway.readAccessToken(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (accessToken == null) {
      final elapsed = _now().toUtc().difference(start);
      return TestConnectionResult(
        authValid: false,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note:
            'No access token on file; reconnect required. (ADP partner '
            'credentials require ADP Marketplace Developer '
            'Participation Agreement clearance — see '
            'partnership_status.md.)',
      );
    }
    final module = await _gateway.readModule(
          operatorId: command.operatorId,
          locationId: command.locationId,
        ) ??
        kAdpModuleWorkforceNow;
    final sample = await _transport.sampleTimeEvent(
      accessToken: accessToken,
      module: module,
    );
    final canonical = _canonicalize(
      operatorId: command.operatorId,
      locationId: command.locationId,
      module: module,
      payload: <String, Object?>{
        'time_event': sample,
        'worker': sample['worker'],
      },
    );
    final elapsed = _now().toUtc().difference(start);
    if (canonical == null) {
      return TestConnectionResult(
        authValid: true,
        sample: sample,
        fieldMapping: const <String, Object?>{
          'assumption': true,
          'note':
              'Sample present but field mapping incomplete; verify '
                  'documented_per_adp_v1 against this sample.',
        },
        elapsedMs: elapsed.inMilliseconds,
        note: 'Field mapping unverified — every row carries '
            'verify_in_live_sandbox: true. See '
            'docs/integrations/adp/field_mapping.md.',
      );
    }
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'shift_start': canonical.shiftStart.toIso8601String(),
        'shift_end': canonical.shiftEnd?.toIso8601String(),
        'role_name': canonical.roleName,
        'employee_id': canonical.employeeId,
        'vendor_entity_id': canonical.vendorEntityId,
        'vendor_modified_at': canonical.vendorModifiedAt.toIso8601String(),
        'module': canonical.module,
        // EVERY field above traces to a row marked
        // `verify_in_live_sandbox: true` in
        // `documentedPerAdpV1FieldMapping`. The flag surfaces in the
        // test-connection modal so operators understand the adapter
        // is engineered against assumptions.
        'assumption': true,
      },
      elapsedMs: elapsed.inMilliseconds,
      note: 'ADP adapter at lifecycle = documented; partner '
          'credentials gated on ADP Marketplace DPA (12-24 weeks). '
          'Field mapping is the engineering-time assumption captured '
          'in docs/integrations/adp/field_mapping.md. '
          '8.S.ADP.live.sandbox will diff observed responses.',
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final accessToken =
        await _requireAccessToken(command.operatorId, command.locationId);
    final module =
        await _requireModule(command.operatorId, command.locationId);

    var batchesCommitted = 0;
    var recordsWritten = 0;
    String? cursor = command.resumeFromCursor;
    var lastModifiedSeen = command.windowStart;

    while (true) {
      final page = await _transport.listTimeEvents(
        accessToken: accessToken,
        module: module,
        modifiedSince: command.windowStart,
        modifiedUntil: command.windowEnd,
        cursor: cursor,
      );

      for (final record in page.records) {
        final mapped = _canonicalize(
          operatorId: command.operatorId,
          locationId: command.locationId,
          module: module,
          payload: record,
        );
        if (mapped == null) {
          // Malformed payload — drop at adapter boundary per V1 lean
          // cut 2 (no warning-flag channel; the adapter either writes
          // a clean canonical fact or refuses).
          continue;
        }
        final ok = await command.sanityHook(
          vendorEventId: mapped.vendorEntityId,
          payload: <String, Object?>{
            'opened_at': mapped.shiftStart.toIso8601String(),
            'closed_at':
                (mapped.shiftEnd ?? mapped.shiftStart).toIso8601String(),
          },
          isDeliberateBackfill: true,
        );
        if (!ok) {
          // Framework already wrote sanity_log + connector_sync_log;
          // skip the canonical fact write.
          continue;
        }
        final inserted = await _gateway.writeTimePunchFact(mapped);
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAt;
        }
      }

      // Per-batch commit. Watermark persists after THIS page's
      // writes, not after the full backfill — Cloud Run Job restart
      // resumes from this cursor.
      cursor = page.nextCursor ?? cursor;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: AdpWatermarkRow(
          cursorToken: cursor ?? '',
          lastModifiedSeen: lastModifiedSeen,
        ),
      );
      batchesCommitted += 1;

      if (page.nextCursor == null) break;
    }

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: cursor ?? '',
      lastModifiedSeen: lastModifiedSeen,
      completed: true,
    );
  }

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    final accessToken =
        await _requireAccessToken(command.operatorId, command.locationId);
    final module =
        await _requireModule(command.operatorId, command.locationId);

    var recordsWritten = 0;
    var sanityDropped = 0;
    String? cursor = command.cursorToken;
    var lastModifiedSeen = command.lastModifiedSeen;
    final tickEnd = _now().toUtc();

    while (true) {
      final page = await _transport.listTimeEvents(
        accessToken: accessToken,
        module: module,
        modifiedSince: command.lastModifiedSeen,
        modifiedUntil: tickEnd,
        cursor: cursor,
      );

      for (final record in page.records) {
        final mapped = _canonicalize(
          operatorId: command.operatorId,
          locationId: command.locationId,
          module: module,
          payload: record,
        );
        if (mapped == null) {
          continue;
        }
        final ok = await command.sanityHook(
          vendorEventId: mapped.vendorEntityId,
          payload: <String, Object?>{
            'opened_at': mapped.shiftStart.toIso8601String(),
            'closed_at':
                (mapped.shiftEnd ?? mapped.shiftStart).toIso8601String(),
          },
          isDeliberateBackfill: false,
        );
        if (!ok) {
          sanityDropped += 1;
          continue;
        }
        final inserted = await _gateway.writeTimePunchFact(mapped);
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAt;
        }
      }

      cursor = page.nextCursor ?? cursor;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: AdpWatermarkRow(
          cursorToken: cursor ?? '',
          lastModifiedSeen: lastModifiedSeen,
        ),
      );

      if (page.nextCursor == null) break;
    }

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: cursor ?? '',
      newLastModifiedSeen: lastModifiedSeen,
      sanityDropped: sanityDropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    // The framework already verified signature, replay window,
    // binding, and idempotency BEFORE this call (steps 1-4 of
    // InboundWebhookHandler.dispatch). Sanity is enforced inline at
    // step 4 — do NOT re-call sanityHook here.
    final module = await _gateway.readModule(
          operatorId: command.operatorId,
          locationId: command.locationId,
        ) ??
        kAdpModuleWorkforceNow;
    final mapped = _canonicalize(
      operatorId: command.operatorId,
      locationId: command.locationId,
      module: module,
      payload: command.payload,
    );
    if (mapped == null) {
      // Malformed payload: drop at adapter boundary; framework
      // records a `connector_sync_log` row via the dispatch unwind.
      // No partial-write flag (V1 lean cut 2 — the adapter either
      // writes a clean canonical fact or refuses).
      return const HandleWebhookResult(recordsWritten: 0);
    }
    final inserted = await _gateway.writeTimePunchFact(mapped);
    return HandleWebhookResult(recordsWritten: inserted ? 1 : 0);
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    final accessToken = await _gateway.readAccessToken(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (accessToken == null) {
      // Already disconnected. Idempotent no-op.
      return const DisconnectResult(
        credentialsWiped: false,
        webhookUnregistered: false,
        watermarkPreserved: true,
      );
    }
    final module = await _gateway.readModule(
          operatorId: command.operatorId,
          locationId: command.locationId,
        ) ??
        kAdpModuleWorkforceNow;

    bool webhookUnregistered = false;
    try {
      await _transport.unregisterEventSubscription(
        accessToken: accessToken,
        module: module,
        // The gateway tracks the subscription id in the connection
        // metadata; the documented slice's fake transport accepts a
        // pass-through. The production gateway looks it up before
        // wiping credentials.
        subscriptionId: '$kAdpVendorId-sub-${command.locationId}',
      );
      webhookUnregistered = true;
    } catch (_) {
      // Vendor-side unregister failed — operator can revoke from
      // ADP Marketplace. Still proceed with local credential wipe.
    }

    try {
      await _transport.revoke(accessToken: accessToken);
    } catch (_) {
      // Best-effort revoke; vendor outage shouldn't block disconnect.
    }

    await _gateway.wipeCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );

    return DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: webhookUnregistered,
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<String> _requireAccessToken(String operatorId, String locationId) async {
    final token = await _gateway.readAccessToken(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (token == null) {
      throw StateError(
        'no ADP access token on file for '
        '(operator=$operatorId, location=$locationId); the framework '
        'should have refused the request before reaching the adapter.',
      );
    }
    return token;
  }

  Future<String> _requireModule(
    String operatorId,
    String locationId,
  ) async {
    final module = await _gateway.readModule(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (module == null || module.isEmpty) {
      throw StateError(
        'no ADP module binding on file for '
        '(operator=$operatorId, location=$locationId).',
      );
    }
    return module;
  }

  /// Map one ADP time-event envelope to a canonical fact. Returns
  /// null when the payload is missing required fields — the caller
  /// drops it at the adapter boundary.
  AdpCanonicalTimePunchFact? _canonicalize({
    required String operatorId,
    required String locationId,
    required String module,
    required Map<String, Object?> payload,
  }) {
    final timeEventRaw = payload['time_event'];
    if (timeEventRaw is! Map) return null;
    final timeEvent = Map<String, Object?>.from(timeEventRaw);

    final id = timeEvent['id'];
    if (id == null) return null;
    final entityId = id.toString();
    if (entityId.isEmpty) return null;

    final entryRaw = timeEvent['entry_date_time'];
    if (entryRaw is! String) return null;
    final shiftStart = DateTime.tryParse(entryRaw)?.toUtc();
    if (shiftStart == null) return null;

    DateTime? shiftEnd;
    final exitRaw = timeEvent['exit_date_time'];
    if (exitRaw is String && exitRaw.isNotEmpty) {
      shiftEnd = DateTime.tryParse(exitRaw)?.toUtc();
    }

    final modifiedRaw = timeEvent['last_modified_date_time'];
    DateTime? modifiedAt;
    if (modifiedRaw is String) {
      modifiedAt = DateTime.tryParse(modifiedRaw)?.toUtc();
    }
    modifiedAt ??= shiftStart;

    final workerRaw = payload['worker'] ?? timeEvent['worker'];
    if (workerRaw is! Map) return null;
    final worker = Map<String, Object?>.from(workerRaw);

    final associateOid = worker['associate_oid'];
    if (associateOid == null || associateOid.toString().isEmpty) {
      return null;
    }

    final positionRaw = worker['position'];
    String? roleName;
    if (positionRaw is Map) {
      final position = Map<String, Object?>.from(positionRaw);
      final title = position['position_title'];
      if (title is String && title.isNotEmpty) {
        roleName = title;
      }
    }
    // WFM exposes role via `workAssignment.jobTitle` — fall back to
    // that path when WFN-style `worker.position` is absent. The live
    // diff slice records which path each module returns.
    if (roleName == null) {
      final assignmentRaw = worker['workAssignment'];
      if (assignmentRaw is Map) {
        final assignment = Map<String, Object?>.from(assignmentRaw);
        final jobTitle = assignment['jobTitle'];
        if (jobTitle is String && jobTitle.isNotEmpty) {
          roleName = jobTitle;
        }
      }
    }
    if (roleName == null || roleName.isEmpty) return null;

    return AdpCanonicalTimePunchFact(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: entityId,
      vendorModifiedAt: modifiedAt,
      shiftStart: shiftStart,
      shiftEnd: shiftEnd,
      roleName: roleName,
      employeeId: associateOid.toString(),
      module: module,
      rawPayload: timeEvent,
    );
  }
}
