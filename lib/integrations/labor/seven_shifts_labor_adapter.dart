// Phase 8.S.7S — 7shifts labor adapter (lifecycle = documented).
//
// 7shifts is the only scheduling vendor F&F has audited that supports
// real webhooks (Gourmet plan only) for schedule + punch changes plus
// the load-bearing `payroll_period.closed` event. The `approved`
// boolean on each time punch and the `payroll_period_closed_at`
// instant are the two source-truth fields the Phase 7.58 Primary
// Driver audit binds against; both are first-class rows in
// `documentedPerSevenShiftsV2FieldMapping` and asserted in the
// fixtures.
//
// Per the engineer-all-17 doctrine
// (`memory/project_phase_8_engineer_all_17_doctrine.md`) this slice
// ships at lifecycle = `documented`. Live HTTP wiring is the
// responsibility of `8.S.7S.live.sandbox` /
// `8.S.7S.live.prod` (Wave D); the adapter binds to a pluggable
// transport so those slices only swap the production HTTP client in.
// Every documented field-mapping row is flagged
// `verify_in_live_sandbox: true` so the live diff is automatable.
//
// Source documentation (online API check completed 2026-05-04):
// - https://developers.7shifts.com (developer portal home)
// - https://developers.7shifts.com/reference/getting-started
// - https://developers.7shifts.com/reference/listtimepunches
// - https://developers.7shifts.com/reference/listshifts
// - https://developers.7shifts.com/reference/payrollperiods
// - https://developers.7shifts.com/reference/createwebhook
// - https://developers.7shifts.com/reference/oauth
//
// Webhook gating: 7shifts exposes the `POST /v2/company/{id}/webhooks`
// auto-registration endpoint only on the Gourmet pricing tier
// (https://www.7shifts.com/pricing). The capability profile declares
// `autoRegister` (the maximum capability the adapter offers); the
// `connect()` runtime detects the operator's plan tier via
// `fetchCompanyInfo()` and falls back to polling-only with an explicit
// `TestConnectionResult.note` when the operator is not on Gourmet.
// The fallback is logged via the existing `connector_sync_log`
// machinery — no new rotation surface, no new alert path.
//
// Doctrine reference: `docs/contracts/vendor_adapter_slice_contract.md`
// + `docs/contracts/per_vendor_doc_pack_contract.md`. Banned items
// per V1 lean cut 2 (REJECT if reintroduced) — see
// `docs/contracts/vendor_adapter_slice_contract.md` for the full list.
// The slice's banned-items grep test in
// `test/integrations/labor/seven_shifts_labor_adapter_test.dart` pins
// each forbidden substring. Engineering inside this file refuses every
// one of them by construction: no key rotation surface, no advisory
// locks, no graceful-drain hook, no dead-letter UI, no sidecar
// raw-payload partitions, no 5-second test-connection SLA, no email
// auto-disable.

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/labor_adapter.dart';
import '../../services/integration/vendor_timestamp_policy.dart';

// ─── Vendor key + display name ──────────────────────────────────────

/// Stable vendor identifier matching `connector_connection.vendor_id`.
const String kSevenShiftsVendorId = 'seven_shifts';

/// Operator-facing display name (exact 7shifts brand).
const String kSevenShiftsDisplayName = '7shifts';

/// 7shifts pricing tier name that gates the webhook auto-registration
/// endpoint per https://www.7shifts.com/pricing. Lower tiers (Entree,
/// Appetizer, The Works) are polling-only.
const String kSevenShiftsGourmetPlanTier = 'gourmet';

/// Operator-facing copy surfaced via `TestConnectionResult.note` and
/// the connect result when the operator's plan tier does not unlock
/// webhooks. Phrased per the UX writing standard
/// (`memory/project_ux_writing_standard.md`) — explains the trade-off
/// in plain English, no engineering jargon.
const String kSevenShiftsNonGourmetNote =
    'Webhooks require Gourmet plan; falling back to polling-only.';

// ─── Documented-per-7shifts field mapping (assumption snapshot) ──────

/// Field-mapping reference captured at slice ship.
///
/// Every entry binds the adapter's canonical-fact write to a 7shifts
/// vendor field documented at https://developers.7shifts.com (retrieved
/// 2026-05-04). The `verify_in_live_sandbox: true` flag on each row
/// tells the `8.S.7S.live.sandbox` slice which entries to diff against
/// the first observed sandbox payload. Mismatches become bounded fixes
/// per `docs/contracts/vendor_adapter_slice_contract.md`.
///
/// Two rows are load-bearing for the Phase 7.58 Primary Driver audit:
/// `is_approved` (per-punch `approved` boolean) and
/// `payroll_period_closed_at` (`payroll_period.closed` event). The
/// adapter MUST persist both; tests assert both round-trip from
/// `time_punches` polling AND the inbound `payroll_period.closed`
/// webhook.
const Map<String, Object?> documentedPerSevenShiftsV2FieldMapping =
    <String, Object?>{
  'api_version': 'v2-2026-05-04',
  // Canonical time-punch fields ────────────────────────────────────
  'vendor_entity_id': <String, Object?>{
    'path': 'time_punch.id',
    'type': 'int',
    'transform': 'to_string',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
    'note':
        '7shifts time-punch ids are integer in the API response; the '
            'canonical fact stores them as strings to match the '
            '(vendor_id, operator_id, vendor_entity_id, vendor_modified_at) '
            'idempotency UNIQUE shape used by every adapter.',
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'time_punch.modified',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
    'note': '7shifts modified timestamps include explicit Z; the '
        'adapter refuses ambiguous timestamps until *.live.sandbox '
        'confirms the shape (Scenario E protection).',
  },
  'shift_start': <String, Object?>{
    'path': 'time_punch.clocked_in',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
  },
  'shift_end': <String, Object?>{
    'path': 'time_punch.clocked_out',
    'type': 'iso8601_utc_or_null',
    'transform': 'direct_utc_when_not_null',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
    'note': 'Open punches (shift in progress) report null clocked_out; '
        'the canonical fact stores null and the polling tick re-emits '
        'the row when the punch closes.',
  },
  'role_name': <String, Object?>{
    'path': 'time_punch.role.name',
    'type': 'string',
    'transform': 'lowercase',
    'doc_url': 'https://developers.7shifts.com/reference/listroles',
    'verify_in_live_sandbox': true,
    'note': 'Role hierarchy is normalized in the connect flow; the '
        'adapter persists the lowercase role name and the operator '
        'maps each role to FOH / BOH / manager / excluded once.',
  },
  'employee_id': <String, Object?>{
    'path': 'time_punch.user_id',
    'type': 'int',
    'transform': 'to_string',
    'doc_url': 'https://developers.7shifts.com/reference/listusers',
    'verify_in_live_sandbox': true,
    'note': 'Per-vendor employee namespace; cross-vendor identity '
        'reconciliation is an explicit non-goal at V1 per Phase 8.S '
        'plan.',
  },
  // Load-bearing for Phase 7.58 Primary Driver audit ──────────────
  'is_approved': <String, Object?>{
    'path': 'time_punch.approved',
    'type': 'bool',
    'transform': 'direct',
    'doc_url': 'https://developers.7shifts.com/reference/listtimepunches',
    'verify_in_live_sandbox': true,
    'note': 'Best-in-class scheduling-vendor finalization signal; '
        'binds to the Phase 7.58 Primary Driver audit per '
        'docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md '
        '(8.S.7S row, "approved boolean").',
  },
  'payroll_period_closed_at': <String, Object?>{
    'path': 'payroll_period.closed_at',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url':
        'https://developers.7shifts.com/reference/listpayrollperiods',
    'verify_in_live_sandbox': true,
    'note': 'Load-bearing for Phase 7.58 Primary Driver audit. '
        'Sourced from BOTH the `GET /payroll_periods` poll AND the '
        '`payroll_period.closed` webhook so finalization is captured '
        'whether the operator is on Gourmet (webhook) or a lower tier '
        '(poll).',
  },
  // Forbidden — read these but do NOT persist ─────────────────────
  'forbidden_employee_email_path': 'user.email',
  'forbidden_employee_phone_path': 'user.phone',
  'forbidden_employee_dob_path': 'user.dob',
  // Endpoints ────────────────────────────────────────────────────
  'oauth_token_url': 'https://api.7shifts.com/v2/oauth/token',
  'oauth_grant_type': 'authorization_code',
  'api_base_url': 'https://api.7shifts.com',
  'list_time_punches_endpoint':
      '/v2/company/{company_id}/time_punches',
  'list_shifts_endpoint': '/v2/company/{company_id}/shifts',
  'list_users_endpoint': '/v2/company/{company_id}/users',
  'list_roles_endpoint': '/v2/company/{company_id}/roles',
  'list_locations_endpoint': '/v2/company/{company_id}/locations',
  'list_payroll_periods_endpoint':
      '/v2/company/{company_id}/payroll_periods',
  'company_info_endpoint': '/v2/company/{company_id}',
  'webhook_register_endpoint': '/v2/company/{company_id}/webhooks',
  'webhook_unregister_endpoint':
      '/v2/company/{company_id}/webhooks/{webhook_id}',
  'webhook_event_time_punch_created': 'time_punch.created',
  'webhook_event_time_punch_edited': 'time_punch.edited',
  'webhook_event_time_punch_deleted': 'time_punch.deleted',
  'webhook_event_shift_created': 'shift.created',
  'webhook_event_shift_updated': 'shift.updated',
  'webhook_event_shift_deleted': 'shift.deleted',
  'webhook_event_payroll_period_closed': 'payroll_period.closed',
  'signature_header': 'X-7Shifts-Hmac-SHA256',
  'signature_algorithm': 'HMAC-SHA256',
  'signature_encoding': 'base64',
};

// ─── Subscribed webhook events ──────────────────────────────────────

/// Every webhook event the adapter subscribes to on Gourmet-plan
/// connections. The Phase 7.58 Primary Driver audit binds against
/// `payroll_period.closed`; the punch / shift events keep the
/// canonical facts fresh between polling ticks.
const List<String> kSevenShiftsSubscribedWebhookEvents = <String>[
  'time_punch.created',
  'time_punch.edited',
  'time_punch.deleted',
  'shift.created',
  'shift.updated',
  'shift.deleted',
  'payroll_period.closed',
];

// ─── Local timestamp policy (deferred-merged into framework catalog) ──

/// Local 7shifts timestamp policy. The framework's
/// `vendorTimestampPolicy` catalog will add this entry at the Wave B
/// integration commit; until then the adapter exposes it directly so
/// downstream tests can assert the convention.
const TimestampPolicy sevenShiftsTimestampPolicy = TimestampPolicy(
  vendorId: kSevenShiftsVendorId,
  ambiguousConvention: AmbiguousTimestampConvention.refuse,
  documentationNote:
      '7shifts API v2 timestamps include explicit `Z` per the developer '
      'reference. The adapter refuses ambiguous shapes until '
      '8.S.7S.live.sandbox confirms the convention; silent fallback to '
      '"treat as UTC" is exactly the bug Scenario E is designed to '
      'catch. Once observed sandbox responses match documented shape '
      'the policy re-binds to asUtc.',
);

// ─── Transport abstraction (real HTTP lands in *.live slices) ────────

/// Token envelope returned by 7shifts' OAuth endpoint.
class SevenShiftsTokenResponse {
  const SevenShiftsTokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
}

/// Company info needed to bind a single OAuth grant to its 7shifts
/// `company_id` and detect the pricing tier that gates webhook
/// auto-registration.
class SevenShiftsCompanyInfo {
  const SevenShiftsCompanyInfo({
    required this.companyId,
    required this.planTier,
  });

  /// 7shifts `company_id` (operator-wide grant scope; one OAuth covers
  /// every location under this company).
  final String companyId;

  /// Lower-cased pricing tier name. `kSevenShiftsGourmetPlanTier`
  /// unlocks webhook auto-registration; everything else routes through
  /// polling-only with the explicit operator-facing note.
  final String planTier;

  bool get supportsWebhooks => planTier == kSevenShiftsGourmetPlanTier;
}

/// One page of time-punch history returned by the 7shifts list
/// endpoint. The adapter walks pages during backfill + poll.
class SevenShiftsTimePunchPage {
  const SevenShiftsTimePunchPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape time-punch rows. Each is normalized into a
  /// canonical fact via [_canonicalizePunch].
  final List<Map<String, Object?>> records;

  /// Next-page cursor; null when the server reports no more pages.
  final String? nextCursor;

  /// `modified` of the latest record on this page (UTC). Stamped onto
  /// the watermark per batch.
  final DateTime lastModifiedSeen;
}

/// Stub transport surface. Production wires HTTP via `8.S.7S.live.*`
/// slices; tests inject `_FakeSevenShiftsTransport` (in test file) to
/// exercise every framework call without a live vendor.
abstract class SevenShiftsTransport {
  /// `POST /v2/oauth/token` with `grant_type=authorization_code` —
  /// completes the OAuth callback round trip on first connect.
  Future<SevenShiftsTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  });

  /// `POST /v2/oauth/token` with `grant_type=refresh_token` — invoked
  /// by the framework's OAuth refresh cron.
  Future<SevenShiftsTokenResponse> refresh({required String refreshToken});

  /// Best-effort revoke on disconnect. 7shifts' v2 OAuth does not
  /// document a `/revoke` endpoint; this method is a no-op on the
  /// real transport but kept for parity with other adapters.
  Future<void> revoke({required String accessToken});

  /// `GET /v2/company/{company_id}` (or `/v2/companies/me` per the
  /// developer reference). Returns the operator's company id +
  /// pricing tier so the connect flow can decide whether to register
  /// webhooks.
  Future<SevenShiftsCompanyInfo> fetchCompanyInfo({
    required String accessToken,
  });

  /// `GET /v2/company/{company_id}/time_punches` — paginated; the
  /// adapter walks pages during backfill + poll using the `modified`
  /// cursor.
  Future<SevenShiftsTimePunchPage> listTimePunches({
    required String accessToken,
    required String companyId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  });

  /// `GET /v2/company/{company_id}/payroll_periods?status=closed` —
  /// returns the most recently closed payroll period so the canonical
  /// `payroll_period_closed_at` row is fresh on every poll, even on
  /// non-Gourmet plans where the webhook is unavailable.
  Future<DateTime?> fetchLatestPayrollPeriodClosedAt({
    required String accessToken,
    required String companyId,
  });

  /// `POST /v2/company/{company_id}/webhooks` (Gourmet plan only).
  /// Auto-registers the F&F inbound URL for every event in
  /// `kSevenShiftsSubscribedWebhookEvents`. Returns the vendor-issued
  /// webhook id stored in `connector_connection.metadata`.
  Future<String> registerWebhook({
    required String accessToken,
    required String companyId,
    required String url,
    required List<String> events,
    required String signingSecret,
  });

  /// `DELETE /v2/company/{company_id}/webhooks/{webhook_id}` on
  /// disconnect. No-op when the connection never registered (lower
  /// plan tier).
  Future<void> unregisterWebhook({
    required String accessToken,
    required String companyId,
    required String webhookId,
  });

  /// Sample punch probe used by [LaborAdapter.testConnection]. Returns
  /// the most recent time punch so the operator can eyeball the field
  /// mapping (shift_start, shift_end, role_name, is_approved). Bare
  /// time-punch row; the canonicalizer wraps it.
  Future<Map<String, Object?>> samplePunch({
    required String accessToken,
    required String companyId,
  });
}

// ─── Persistence abstraction (real Postgres lands in *.live slices) ──

/// Connection row read/written by the adapter. Mirrors the shape of
/// `connector_connection` JSONB metadata for the relevant 7shifts
/// keys.
class SevenShiftsConnectionRow {
  const SevenShiftsConnectionRow({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.companyId,
    required this.planTier,
    required this.webhookId,
    required this.status,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;

  /// 7shifts `company_id` — operatorWide grant scope. The binding
  /// cross-check on inbound webhooks compares this against
  /// `connector_connection.metadata.company_id`.
  final String companyId;

  /// Lower-cased plan tier captured at connect time. Surfaced in the
  /// admin widget as a degradation note when not Gourmet.
  final String planTier;

  /// 7shifts-issued webhook id; null when the operator is not on
  /// Gourmet (no auto-registration).
  final String? webhookId;
  final ConnectionStatus status;

  Map<String, Object?> toMetadata() => <String, Object?>{
        'company_id': companyId,
        'plan_tier': planTier,
        if (webhookId != null) 'webhook_id': webhookId,
      };
}

/// Watermark row mirroring `connector_sync_watermark`.
class SevenShiftsWatermarkRow {
  const SevenShiftsWatermarkRow({
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
class SevenShiftsCanonicalTimePunchFact {
  const SevenShiftsCanonicalTimePunchFact({
    required this.operatorId,
    required this.locationId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.employeeId,
    required this.roleName,
    required this.shiftStart,
    required this.shiftEnd,
    required this.isApproved,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final String employeeId;
  final String roleName;
  final DateTime shiftStart;

  /// Null when the punch is open (shift in progress); see
  /// `documentedPerSevenShiftsV2FieldMapping[shift_end].note`.
  final DateTime? shiftEnd;

  /// 7shifts `approved` boolean. Load-bearing for Phase 7.58 Primary
  /// Driver audit per
  /// `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md`.
  final bool isApproved;

  final Map<String, Object?> rawPayload;
}

/// Canonical fact row for the latest closed payroll period. Sourced
/// from BOTH the polling endpoint and the `payroll_period.closed`
/// webhook so finalization lands whether the operator is on Gourmet
/// (webhook) or a lower plan tier (poll).
class SevenShiftsCanonicalPayrollPeriodClosedFact {
  const SevenShiftsCanonicalPayrollPeriodClosedFact({
    required this.operatorId,
    required this.locationId,
    required this.payrollPeriodClosedAt,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;

  /// The instant the operator's payroll cycle closed. Phase 7.58
  /// Primary Driver audit reads this to decide whether the cycle is
  /// finalized or still in flight.
  final DateTime payrollPeriodClosedAt;

  final Map<String, Object?> rawPayload;
}

/// Persistence surface the adapter depends on. Production wires a
/// `OperatorScopedRepository.withTenant`-backed implementation. Tests
/// inject fakes.
abstract class SevenShiftsGateway {
  /// Persist the connection row inside an
  /// `OperatorScopedRepository.withTenant` block. Returns the stored
  /// row.
  Future<SevenShiftsConnectionRow> upsertConnection({
    required SevenShiftsConnectionRow row,
  });

  /// Read the watermark for `(operatorId, locationId)`. Null when the
  /// connection has never run a backfill / poll.
  Future<SevenShiftsWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  });

  /// Persist the watermark **after each successful batch commit** so a
  /// Cloud Run Job restart resumes from the last persisted cursor (per
  /// the framework contract — never end-of-backfill).
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required SevenShiftsWatermarkRow row,
  });

  /// Upsert one canonical time-punch fact; returns `true` when a row
  /// was written, `false` when the upsert short-circuited on the
  /// idempotency UNIQUE.
  Future<bool> writeTimePunchFact(SevenShiftsCanonicalTimePunchFact fact);

  /// Upsert the most recent closed payroll period for
  /// `(operatorId, locationId)`. Idempotent: writing the same
  /// `payroll_period_closed_at` value twice is a no-op. Returns `true`
  /// when the value advanced, `false` on the no-op path.
  Future<bool> writePayrollPeriodClosedFact(
    SevenShiftsCanonicalPayrollPeriodClosedFact fact,
  );

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

  /// Look up the bound 7shifts company id. Returns null when no
  /// connection exists.
  Future<String?> readCompanyId({
    required String operatorId,
    required String locationId,
  });
}

// ─── Adapter ────────────────────────────────────────────────────────

/// 7shifts labor adapter (lifecycle = documented).
///
/// Implements every framework seam declared in [LaborAdapter] against
/// the documented 7shifts v2 API shape (developers.7shifts.com,
/// retrieved 2026-05-04). Live HTTP wiring is the `*.live.sandbox` /
/// `*.live.prod` slice's job; this slice ships fixture-backed coverage
/// of every code path so the diff against the first observed sandbox
/// response is bounded.
class SevenShiftsLaborAdapter implements LaborAdapter {
  SevenShiftsLaborAdapter({
    required SevenShiftsTransport transport,
    required SevenShiftsGateway gateway,
    DateTime Function()? now,
  })  : _transport = transport,
        _gateway = gateway,
        _now = now ?? DateTime.now;

  final SevenShiftsTransport _transport;
  final SevenShiftsGateway _gateway;
  final DateTime Function() _now;

  /// Local timestamp policy (deferred-merged into framework catalog).
  TimestampPolicy get timestampPolicy => sevenShiftsTimestampPolicy;

  @override
  String get vendorId => kSevenShiftsVendorId;

  @override
  String get displayName => kSevenShiftsDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile =>
      const VendorCapabilityProfile(
        vendorId: kSevenShiftsVendorId,
        displayName: kSevenShiftsDisplayName,
        category: IntegrationCategory.labor,
        // OAuth 2.0 authorization_code per 7shifts developer portal.
        authMode: VendorAuthMode.oauth,
        // One OAuth grant covers every location under the operator's
        // 7shifts company per developers.7shifts.com.
        grantScope: VendorGrantScope.operatorWide,
        // Profile declares the maximum capability the adapter can
        // offer (autoRegister) — connect-time plan-tier detection
        // routes non-Gourmet operators to polling-only with an
        // explicit note. Documented in webhook_signature.md +
        // oauth_shape.md.
        webhookSupport: VendorWebhookSupport.autoRegister,
        // Labor adapters do not source covers; classification is
        // `not_applicable` per field_mapping.md.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId:
            'docs/integrations/seven_shifts/field_mapping.md',
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kSevenShiftsVendorId) {
      throw StateError(
        'connect dispatched to SevenShiftsLaborAdapter for non-7shifts '
        'vendor ${command.vendorId}',
      );
    }
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
      redirectUri:
          'https://proxy.example/v1/oauth/callback/$kSevenShiftsVendorId',
    );

    final companyInfo = await _transport.fetchCompanyInfo(
      accessToken: tokenResponse.accessToken,
    );

    String? webhookId;
    if (companyInfo.supportsWebhooks) {
      // Gourmet plan — auto-register the webhook subscription so
      // schedule + punch + payroll-period events flow inbound.
      webhookId = await _transport.registerWebhook(
        accessToken: tokenResponse.accessToken,
        companyId: companyInfo.companyId,
        url: 'https://proxy.example/v1/webhooks/${command.operatorId}/'
            '${command.locationId}/$kSevenShiftsVendorId',
        events: kSevenShiftsSubscribedWebhookEvents,
        signingSecret: tokenResponse.accessToken,
      );
    }

    final row = SevenShiftsConnectionRow(
      connectionId:
          'seven_shifts-${command.operatorId}-${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
      companyId: companyInfo.companyId,
      planTier: companyInfo.planTier,
      webhookId: webhookId,
      status: ConnectionStatus.connected,
    );
    final stored = await _gateway.upsertConnection(row: row);
    return ConnectResult(
      connectionId: stored.connectionId,
      status: stored.status,
      metadata: stored.toMetadata(),
      webhookUrl: companyInfo.supportsWebhooks
          ? 'https://proxy.example/v1/webhooks/${command.operatorId}/'
              '${command.locationId}/$kSevenShiftsVendorId'
          : null,
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
        note: 'No access token on file; reconnect required.',
      );
    }
    final companyId = await _gateway.readCompanyId(
          operatorId: command.operatorId,
          locationId: command.locationId,
        ) ??
        '';
    final sample = await _transport.samplePunch(
      accessToken: accessToken,
      companyId: companyId,
    );
    final canonical = _canonicalizePunch(
      operatorId: command.operatorId,
      locationId: command.locationId,
      payload: <String, Object?>{'time_punch': sample},
    );
    final companyInfo = await _transport.fetchCompanyInfo(
      accessToken: accessToken,
    );
    final note = companyInfo.supportsWebhooks ? null : kSevenShiftsNonGourmetNote;
    final elapsed = _now().toUtc().difference(start);
    if (canonical == null) {
      return TestConnectionResult(
        authValid: true,
        sample: sample,
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note: note,
      );
    }
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'shift_start': canonical.shiftStart.toIso8601String(),
        if (canonical.shiftEnd != null)
          'shift_end': canonical.shiftEnd!.toIso8601String(),
        'role_name': canonical.roleName,
        'is_approved': canonical.isApproved,
        'employee_id': canonical.employeeId,
        'vendor_entity_id': canonical.vendorEntityId,
        'vendor_modified_at': canonical.vendorModifiedAt.toIso8601String(),
      },
      elapsedMs: elapsed.inMilliseconds,
      note: note,
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final accessToken =
        await _requireAccessToken(command.operatorId, command.locationId);
    final companyId =
        await _requireCompanyId(command.operatorId, command.locationId);

    var batchesCommitted = 0;
    var recordsWritten = 0;
    String? cursor = command.resumeFromCursor;
    var lastModifiedSeen = command.windowStart;

    while (true) {
      final page = await _transport.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: command.windowStart,
        modifiedUntil: command.windowEnd,
        cursor: cursor,
      );

      for (final record in page.records) {
        final mapped = _canonicalizePunch(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payload: <String, Object?>{'time_punch': record},
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
          isDeliberateBackfill: true,
        );
        if (!ok) {
          continue;
        }
        final inserted = await _gateway.writeTimePunchFact(mapped);
        if (inserted) recordsWritten += 1;
        if (mapped.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = mapped.vendorModifiedAt;
        }
      }

      // Per-batch commit. Watermark persists after THIS page's writes,
      // not after the full backfill.
      cursor = page.nextCursor ?? cursor;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: SevenShiftsWatermarkRow(
          cursorToken: cursor ?? '',
          lastModifiedSeen: lastModifiedSeen,
        ),
      );
      batchesCommitted += 1;

      if (page.nextCursor == null) break;
    }

    // Backfill also pulls the latest closed payroll period so the
    // Phase 7.58 Primary Driver audit binds against fresh
    // finalization data even on lower plan tiers (no webhook).
    final closedAt = await _transport.fetchLatestPayrollPeriodClosedAt(
      accessToken: accessToken,
      companyId: companyId,
    );
    if (closedAt != null) {
      await _gateway.writePayrollPeriodClosedFact(
        SevenShiftsCanonicalPayrollPeriodClosedFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payrollPeriodClosedAt: closedAt,
          rawPayload: <String, Object?>{
            'source': 'backfill_payroll_period_poll',
          },
        ),
      );
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
    final companyId =
        await _requireCompanyId(command.operatorId, command.locationId);

    var recordsWritten = 0;
    var sanityDropped = 0;
    String? cursor = command.cursorToken;
    var lastModifiedSeen = command.lastModifiedSeen;
    final tickEnd = _now().toUtc();

    while (true) {
      final page = await _transport.listTimePunches(
        accessToken: accessToken,
        companyId: companyId,
        modifiedSince: command.lastModifiedSeen,
        modifiedUntil: tickEnd,
        cursor: cursor,
      );

      for (final record in page.records) {
        final mapped = _canonicalizePunch(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payload: <String, Object?>{'time_punch': record},
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
        row: SevenShiftsWatermarkRow(
          cursorToken: cursor ?? '',
          lastModifiedSeen: lastModifiedSeen,
        ),
      );

      if (page.nextCursor == null) break;
    }

    // Pull the latest closed payroll period on every tick so
    // non-Gourmet (poll-only) operators still see Primary Driver
    // finalization land in canonical facts.
    final closedAt = await _transport.fetchLatestPayrollPeriodClosedAt(
      accessToken: accessToken,
      companyId: companyId,
    );
    if (closedAt != null) {
      await _gateway.writePayrollPeriodClosedFact(
        SevenShiftsCanonicalPayrollPeriodClosedFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payrollPeriodClosedAt: closedAt,
          rawPayload: <String, Object?>{
            'source': 'poll_payroll_period_poll',
          },
        ),
      );
    }

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: cursor ?? '',
      newLastModifiedSeen: lastModifiedSeen,
      sanityDropped: sanityDropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(
    HandleWebhookCommand command,
  ) async {
    // Framework already verified signature, replay window, binding,
    // idempotency, and timestamp sanity BEFORE this call. Adapter MUST
    // NOT re-call sanityHook here.
    final eventType = (command.payload['event_type'] ??
            command.payload['type'] ??
            command.payload['event'])
        ?.toString();

    if (eventType == 'payroll_period.closed') {
      final closedAt = _parsePayrollPeriodClosedAt(command.payload);
      if (closedAt == null) {
        return const HandleWebhookResult(recordsWritten: 0);
      }
      final inserted = await _gateway.writePayrollPeriodClosedFact(
        SevenShiftsCanonicalPayrollPeriodClosedFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          payrollPeriodClosedAt: closedAt,
          rawPayload: command.payload,
        ),
      );
      return HandleWebhookResult(recordsWritten: inserted ? 1 : 0);
    }

    final mapped = _canonicalizePunch(
      operatorId: command.operatorId,
      locationId: command.locationId,
      payload: command.payload,
    );
    if (mapped == null) {
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
      return const DisconnectResult(
        credentialsWiped: false,
        webhookUnregistered: false,
        watermarkPreserved: true,
      );
    }
    final companyId = await _gateway.readCompanyId(
          operatorId: command.operatorId,
          locationId: command.locationId,
        ) ??
        '';

    bool webhookUnregistered = false;
    try {
      await _transport.unregisterWebhook(
        accessToken: accessToken,
        companyId: companyId,
        webhookId: '$kSevenShiftsVendorId-webhook-$companyId',
      );
      webhookUnregistered = true;
    } catch (_) {
      // Vendor-side unregister failed — operator can revoke from the
      // 7shifts portal. Still proceed with local credential wipe.
    }

    try {
      await _transport.revoke(accessToken: accessToken);
    } catch (_) {
      // 7shifts v2 OAuth does not document a revoke endpoint; the
      // call is a no-op on the real transport.
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

  Future<String> _requireAccessToken(
    String operatorId,
    String locationId,
  ) async {
    final token = await _gateway.readAccessToken(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (token == null) {
      throw StateError(
        'no 7shifts access token on file for '
        '(operator=$operatorId, location=$locationId); the framework '
        'should have refused the request before reaching the adapter.',
      );
    }
    return token;
  }

  Future<String> _requireCompanyId(
    String operatorId,
    String locationId,
  ) async {
    final companyId = await _gateway.readCompanyId(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (companyId == null || companyId.isEmpty) {
      throw StateError(
        'no 7shifts company_id binding on file for '
        '(operator=$operatorId, location=$locationId).',
      );
    }
    return companyId;
  }

  /// Map one 7shifts time-punch envelope to a canonical fact. Returns
  /// null when the payload is missing required fields — the caller
  /// drops it at the adapter boundary.
  SevenShiftsCanonicalTimePunchFact? _canonicalizePunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> payload,
  }) {
    final punchRaw = payload['time_punch'];
    if (punchRaw is! Map) return null;
    final punch = Map<String, Object?>.from(punchRaw);

    final id = punch['id'];
    if (id == null) return null;
    final entityId = id.toString();
    if (entityId.isEmpty) return null;

    final clockedInRaw = punch['clocked_in'];
    if (clockedInRaw is! String) return null;
    final shiftStart = DateTime.tryParse(clockedInRaw)?.toUtc();
    if (shiftStart == null) return null;

    DateTime? shiftEnd;
    final clockedOutRaw = punch['clocked_out'];
    if (clockedOutRaw is String && clockedOutRaw.isNotEmpty) {
      shiftEnd = DateTime.tryParse(clockedOutRaw)?.toUtc();
    }

    final modifiedRaw = punch['modified'];
    DateTime? modifiedAt;
    if (modifiedRaw is String) {
      modifiedAt = DateTime.tryParse(modifiedRaw)?.toUtc();
    }
    modifiedAt ??= shiftStart;

    final userIdRaw = punch['user_id'];
    if (userIdRaw == null) return null;
    final employeeId = userIdRaw.toString();
    if (employeeId.isEmpty) return null;

    String roleName = '';
    final roleRaw = punch['role'];
    if (roleRaw is Map) {
      final name = roleRaw['name'];
      if (name is String) roleName = name.toLowerCase();
    }

    final approvedRaw = punch['approved'];
    final isApproved = approvedRaw is bool ? approvedRaw : false;

    return SevenShiftsCanonicalTimePunchFact(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: entityId,
      vendorModifiedAt: modifiedAt,
      employeeId: employeeId,
      roleName: roleName,
      shiftStart: shiftStart,
      shiftEnd: shiftEnd,
      isApproved: isApproved,
      rawPayload: punch,
    );
  }

  /// Pull the closed instant out of an inbound `payroll_period.closed`
  /// webhook envelope. The 7shifts v2 webhook nests the period under a
  /// `payroll_period` key per the documented event shape.
  DateTime? _parsePayrollPeriodClosedAt(Map<String, Object?> payload) {
    final periodRaw = payload['payroll_period'] ?? payload['data'];
    if (periodRaw is! Map) return null;
    final period = Map<String, Object?>.from(periodRaw);
    final closedAtRaw = period['closed_at'] ??
        period['closedAt'] ??
        period['closed'];
    if (closedAtRaw is! String) return null;
    return DateTime.tryParse(closedAtRaw)?.toUtc();
  }
}
