// Phase 8.S / Wave B — QuickBooks Time labor adapter (slice `8.S.QBT`).
//
// Reference scheduling adapter. Engineered against the documented
// QuickBooks Time (formerly TSheets) developer API at:
//   https://tsheetsteam.github.io/api_docs/
// retrieved 2026-05-04 (see
// `docs/integrations/quickbooks_time/api_consumed.md`).
//
// Lifecycle at slice close: `VendorLifecycle.documented`. Live HTTP is
// the responsibility of `8.S.QBT.live.sandbox` and
// `8.S.QBT.live.prod` rolling slices, which wire a real HTTP client
// and run the per-vendor `live_verification_checklist.md`. QuickBooks
// Time uses public Intuit OAuth (no partnership gate), so the live
// rollout sequence depends only on credential issuance, not commercial
// negotiation.
//
// Doctrine: per the Vendor Adapter Slice Contract
// (`docs/contracts/vendor_adapter_slice_contract.md`) every Phase 8 /
// 8R / 8.S adapter ships in a single PR alongside its 6-file per-vendor
// doc pack. This adapter is the **reference scheduling adapter** plus
// the **module disambiguation reference** (alongside
// `8.S.ADP`): `connect` accepts QuickBooks Time only and refuses
// QuickBooks Online (Accounting — outbound integration) and QuickBooks
// Payroll with friendly module-aware messages.
//
// Webhook support: **none**. F&F's documented review of the QuickBooks
// Time API exposes no webhook delivery surface usable for schedule /
// punch changes — see
// `docs/integrations/quickbooks_time/api_consumed.md`. The adapter
// therefore declares `webhookSupport = pollOnly` and `handleWebhook`
// throws `UnsupportedError`. The framework router consults
// `capabilityProfile.webhookSupport` before calling `handleWebhook`,
// so under normal operation the throw is unreachable; it stays as a
// defense-in-depth assertion against future router refactors.
//
// Banned items per V1 lean cut 2 (REJECT if reintroduced) — see
// `docs/contracts/vendor_adapter_slice_contract.md` for the full list.
// The slice's banned-items grep test pins each forbidden substring;
// engineering inside this file refuses every one of them by
// construction (no key rotation surface, no advisory locks, no
// graceful-drain hook, no dead-letter UI, no sidecar raw-payload
// partitions, no 5-second test-connection SLA, no email auto-disable).

import 'package:meta/meta.dart';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/labor_adapter.dart';
import '../../services/integration/vendor_timestamp_policy.dart';

// ─── Vendor key + display name + module identifiers ─────────────────

/// Stable vendor identifier — matches `connector_connection.vendor_id`
/// and `VendorCapabilityProfile.vendorId`.
const String kQuickBooksTimeVendorId = 'quickbooks_time';

/// Operator-facing display name (exact Intuit brand: "QuickBooks Time"
/// — formerly "TSheets" until Intuit rebranded; the brand is documented
/// at the QBT developer portal landing page).
const String kQuickBooksTimeDisplayName = 'QuickBooks Time';

/// API version pinned by this adapter. Bumped when a `*.live.sandbox`
/// slice diffs documented vs observed and the doc pack is updated.
const String kQuickBooksTimeApiVersion = 'v1';

/// Module identifier for QuickBooks Time (the only QuickBooks module
/// this adapter accepts).
const String kQuickBooksModuleTime = 'time';

/// Module identifier for QuickBooks Online (Accounting). Refused by
/// `connect` with a redirect message — Accounting is an outbound
/// integration handled separately.
const String kQuickBooksModuleAccounting = 'accounting';

/// Module identifier for QuickBooks Payroll. Refused by `connect` with
/// a friendly refusal — F&F does not support standalone Payroll
/// connectors.
const String kQuickBooksModulePayroll = 'payroll';

// ─── Module refusal exception ───────────────────────────────────────

/// Raised by [QuickBooksTimeLaborAdapter.connect] when the operator
/// (or the OAuth callback's module hint) selects a QuickBooks module
/// the adapter does not support. The message carries the operator-
/// facing copy the admin surface renders verbatim — the UX writing
/// standard (`memory/project_ux_writing_standard.md`) requires plain
/// English in every refusal path.
///
/// Two refusal modes:
/// 1. `accounting` — redirect copy ("connect from the Outbound
///    Integrations section"). QuickBooks Online (Accounting) lives at
///    Phase 8.5; the dialog should link the operator over.
/// 2. `payroll` — refusal copy. Standalone Payroll is not supported.
///
/// The exception is surfaced in the connect dialog by the framework
/// (see `lib/services/integration/integrations_repository.dart` —
/// admin route swallows the throw, surfaces the message in a friendly
/// dialog, and aborts the flow without persisting credentials).
class ModuleRefusalException implements Exception {
  const ModuleRefusalException({
    required this.module,
    required this.message,
  });

  /// The QuickBooks module the operator picked (one of
  /// [kQuickBooksModuleAccounting], [kQuickBooksModulePayroll]).
  final String module;

  /// Operator-facing copy. Plain English, no engineering jargon, no
  /// stack-trace references.
  final String message;

  @override
  String toString() => 'ModuleRefusalException($module): $message';
}

// ─── Documented-per-quickbooks_time field mapping (assumption snapshot) ──

/// Field-mapping reference captured at slice ship.
///
/// Every entry is an assumption against the documented QuickBooks Time
/// developer API shape (https://tsheetsteam.github.io/api_docs/) as of
/// 2026-05-04. The `verify_in_live_sandbox: true` flag tells the
/// `8.S.QBT.live.sandbox` slice which entries to diff against the first
/// observed sandbox response. Mismatches become bounded fixes, not
/// slice rebuilds, per
/// `docs/contracts/vendor_adapter_slice_contract.md`.
///
/// The constant follows the
/// `documented_per_<vendor>_<api_version>` naming shape mandated by
/// `docs/contracts/per_vendor_doc_pack_contract.md`; the lint
/// directive below suppresses the lowerCamelCase rule for this
/// contract-bound name only.
// ignore: constant_identifier_names
const Map<String, Object?> documented_per_quickbooks_time_v1 =
    <String, Object?>{
  'api_version': 'v1 (QuickBooks Time / TSheets developer API; '
      'Intuit-rebranded brand)',
  'shift_start_path': 'timesheets[].start',
  'shift_start_type': 'ISO 8601 with explicit Z (UTC)',
  'shift_end_path': 'timesheets[].end',
  'shift_end_type': 'ISO 8601 with explicit Z (UTC); empty string '
      'when timesheet is open (employee still clocked in)',
  'role_name_path': 'jobcodes[].name (joined to timesheets[].jobcode_id)',
  'role_name_type': 'string',
  'employee_id_path': 'users[].id (joined to timesheets[].user_id)',
  'employee_id_type': 'int (stringified at canonical write)',
  'vendor_entity_id_path': 'timesheets[].id',
  'vendor_entity_id_type': 'int (stringified at canonical write)',
  'vendor_modified_at_path': 'timesheets[].last_modified',
  'vendor_modified_at_type': 'ISO 8601 with explicit Z (UTC)',
  'pay_rate_path': 'users[].pay_rate (when exposed by vendor; per '
      '`oauth_shape.md` requires pay-rate scope)',
  'pay_rate_type': 'decimal string (USD/local currency per user prefs)',
  'covers_source_classification': 'not_applicable',
  'pagination_shape': 'page-numbered (?page=N) with `more` boolean '
      'flag in `results.more`',
  'rate_limit': '~20 requests/sec per account (vendor-documented '
      'soft cap)',
  'webhook_support': 'pollOnly (F&F doctrine: vendor docs do not '
      'expose a webhook delivery surface usable for schedule/punch '
      'changes; adapter polls every 5 minutes per phase 8.S plan)',
  'auth_mode': 'oauth (authorization_code grant via Intuit OAuth 2.0; '
      'public self-serve at developer.intuit.com)',
  'grant_scope': 'operatorWide (one Intuit OAuth realm covers all of '
      'the operator\'s QBT locations; F&F maps each vendor location to '
      'one F&F location_id at connect time)',
  'partnership_program': 'n/a — public Intuit OAuth, no partnership '
      'required',
  'partnership_lead_time': 'n/a',
  // Forbidden — read these but do NOT persist (privacy + scope):
  'forbidden_employee_ssn_path': 'users[].ssn (vendor exposes; F&F '
      'never reads or persists)',
  'forbidden_employee_full_address_path': 'users[].address (location '
      'home address — privacy)',
  'forbidden_employee_phone_path': 'users[].mobile_number',
  // Module disambiguation: the OAuth callback returns a token whose
  // realm/scope identifies the QuickBooks module the operator picked.
  // The adapter detects module from the operator-supplied module hint
  // (preferred) or from the token scope (fallback). Documented in
  // `oauth_shape.md` "Module disambiguation" section.
  'module_disambiguation_supported': 'time | accounting | payroll',
  'module_supported_by_this_adapter': 'time',
  'module_accounting_redirect_to': 'Phase 8.5 outbound integrations '
      '(QuickBooks Online Accounting)',
  'module_payroll_action': 'refused (standalone Payroll not supported)',
};

// ─── Transport abstraction (real HTTP lands in *.live slices) ───────

/// Token envelope returned by Intuit's OAuth endpoint after
/// authorization_code exchange or refresh.
class QuickBooksTimeTokenResponse {
  const QuickBooksTimeTokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scope,
    this.realmId,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// Space-separated OAuth scopes granted by the user. Used for module
  /// disambiguation when the operator omits an explicit module hint —
  /// `com.intuit.quickbooks.payroll.time.access` (or similar) implies
  /// `time` module.
  final String scope;

  /// Intuit realm id (operator-wide). Stored on
  /// `connector_connection.metadata.intuit_realm_id`.
  final String? realmId;
}

/// One page of timesheet history returned by the timesheets endpoint.
class QuickBooksTimeTimesheetsPage {
  const QuickBooksTimeTimesheetsPage({
    required this.records,
    required this.nextPage,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape timesheet rows. Each is normalized into a
  /// canonical fact via [QuickBooksTimeLaborAdapter.mapTimesheetToCanonical].
  final List<Map<String, Object?>> records;

  /// Next page number (1-indexed); null when the server reports
  /// `results.more = false`.
  final int? nextPage;

  /// `last_modified` of the latest record on this page (UTC). Stamped
  /// onto the watermark per batch.
  final DateTime lastModifiedSeen;
}

/// Stub transport surface. Production wires real HTTP via the `*.live`
/// slices when public OAuth credentials and a sandbox realm land;
/// tests inject a fake to exercise every framework call without a live
/// vendor.
abstract class QuickBooksTimeTransport {
  /// `POST https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer`
  /// — authorization_code completion on first connect; rotating
  /// refresh on cron tick. Documented in
  /// `docs/integrations/quickbooks_time/oauth_shape.md`.
  Future<QuickBooksTimeTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  });

  /// `POST https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer`
  /// with `grant_type=refresh_token`. Rotating refresh tokens.
  Future<QuickBooksTimeTokenResponse> refresh({
    required String refreshToken,
  });

  /// `POST https://developer.api.intuit.com/v2/oauth2/tokens/revoke`
  /// — best-effort revoke on disconnect. Vendor outage MUST NOT block
  /// disconnect.
  Future<void> revoke({required String refreshToken});

  /// `GET https://rest.tsheets.com/api/v1/timesheets` — paginated;
  /// the adapter walks pages during backfill + poll. `modified_since`
  /// drives incremental deltas.
  Future<QuickBooksTimeTimesheetsPage> listTimesheets({
    required String accessToken,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    int? page,
  });

  /// `GET https://rest.tsheets.com/api/v1/timesheets/{id}` — used by
  /// reconciliation lookups when a polling page omits a needed field.
  Future<Map<String, Object?>> fetchTimesheet({
    required String accessToken,
    required String timesheetId,
  });

  /// `GET https://rest.tsheets.com/api/v1/jobcodes` — role catalog.
  /// Joined to `timesheets[].jobcode_id` for `role_name`.
  Future<Map<String, Map<String, Object?>>> fetchJobcodes({
    required String accessToken,
  });

  /// `GET https://rest.tsheets.com/api/v1/users` — employee + group
  /// catalog. Drives FOH/BOH classification mapping at admin-surface
  /// onboarding.
  Future<Map<String, Map<String, Object?>>> fetchUsers({
    required String accessToken,
  });

  /// Sample timesheet probe used by [LaborAdapter.testConnection].
  /// Returns the most recent timesheet so the operator can eyeball the
  /// field mapping (shift_start, shift_end, role_name).
  Future<Map<String, Object?>> sampleTimesheet({required String accessToken});
}

// ─── Persistence abstraction (real Postgres lands in *.live slices) ─

/// Connection row mirroring the shape of `connector_connection`
/// JSONB metadata for the relevant QuickBooks Time keys.
class QuickBooksTimeConnectionRow {
  const QuickBooksTimeConnectionRow({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.intuitRealmId,
    required this.module,
    required this.status,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;

  /// Intuit operator-wide realm id (stored in
  /// `connector_connection.metadata.intuit_realm_id`).
  final String intuitRealmId;

  /// Module the operator picked at connect time. Always
  /// [kQuickBooksModuleTime] for this adapter; persisted so reconnect
  /// flows know which module was originally chosen.
  final String module;
  final ConnectionStatus status;

  Map<String, Object?> toMetadata() => <String, Object?>{
        'intuit_realm_id': intuitRealmId,
        'module': module,
        'grant_scope': 'operatorWide',
      };
}

/// Watermark row mirroring `connector_sync_watermark`.
class QuickBooksTimeWatermarkRow {
  const QuickBooksTimeWatermarkRow({
    required this.cursorToken,
    required this.lastModifiedSeen,
  });

  /// Vendor pagination cursor at the point the backfill / poll
  /// stopped. For QBT this is the page number serialized as a
  /// string (e.g., `'3'`); empty string means "no more pages".
  final String cursorToken;
  final DateTime lastModifiedSeen;
}

/// One canonical labor fact write request handed to the gateway. The
/// gateway is responsible for the upsert on
/// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
/// per `docs/contracts/vendor_adapter_slice_contract.md`. Returns
/// `false` when the upsert hits an existing row (idempotency
/// short-circuit).
class QuickBooksTimeCanonicalPunchFact {
  const QuickBooksTimeCanonicalPunchFact({
    required this.operatorId,
    required this.locationId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.shiftStart,
    required this.shiftEnd,
    required this.roleName,
    required this.employeeId,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final DateTime shiftStart;

  /// Null when the timesheet is still open (employee clocked in but
  /// not out yet). Polling re-emits the row when `end` populates.
  final DateTime? shiftEnd;

  final String roleName;
  final String employeeId;
  final Map<String, Object?> rawPayload;
}

/// Persistence surface the adapter depends on. Production wires an
/// `OperatorScopedRepository.withTenant`-backed implementation. Tests
/// inject fakes.
abstract class QuickBooksTimeGateway {
  /// Persist the connection row inside an
  /// `OperatorScopedRepository.withTenant` block. Returns the stored
  /// row.
  Future<QuickBooksTimeConnectionRow> upsertConnection({
    required QuickBooksTimeConnectionRow row,
  });

  /// Read the watermark for `(operatorId, locationId)`. Null when the
  /// connection has never run a backfill / poll.
  Future<QuickBooksTimeWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  });

  /// Persist the watermark **after each successful batch commit** so a
  /// Cloud Run Job restart resumes from the last persisted cursor (per
  /// the framework contract — never end-of-backfill).
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required QuickBooksTimeWatermarkRow row,
  });

  /// Upsert one canonical punch fact; returns `true` when a row was
  /// written, `false` when the upsert short-circuited on the
  /// idempotency UNIQUE.
  Future<bool> writePunchFact(QuickBooksTimeCanonicalPunchFact fact);

  /// Wipe the credential ciphertext on disconnect. Watermark and
  /// canonical facts are preserved so reconnect resumes from the last
  /// cursor.
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  });

  /// Look up the active access-token credential. Used by polling /
  /// backfill paths. Returns null when the connection is disconnected.
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  });

  /// Look up the connected Intuit realm id (binding context). Returns
  /// null when no connection exists.
  Future<String?> readIntuitRealmId({
    required String operatorId,
    required String locationId,
  });
}

// ─── Adapter ────────────────────────────────────────────────────────

/// QuickBooks Time labor adapter (lifecycle = `documented`).
///
/// Reference scheduling adapter for Phase 8.S. Implements every
/// framework seam declared in [LaborAdapter] against the documented
/// QuickBooks Time API shape, plus the module disambiguation pattern
/// the framework requires for QuickBooks-branded vendors. Live HTTP
/// wiring is the `*.live.sandbox` / `*.live.prod` slice's job; this
/// slice ships fixture-backed coverage of every code path so the diff
/// against the first observed sandbox response is bounded.
class QuickBooksTimeLaborAdapter implements LaborAdapter {
  QuickBooksTimeLaborAdapter({
    required QuickBooksTimeTransport transport,
    required QuickBooksTimeGateway gateway,
    DateTime Function()? clock,
  })  : _transport = transport,
        _gateway = gateway,
        _clock = clock ?? DateTime.now;

  final QuickBooksTimeTransport _transport;
  final QuickBooksTimeGateway _gateway;
  final DateTime Function() _clock;

  /// Local timestamp policy declared in
  /// `lib/services/integration/vendor_timestamp_policy.dart`. Surfaced
  /// here for tests.
  TimestampPolicy get timestampPolicy =>
      vendorTimestampPolicy[kQuickBooksTimeVendorId]!;

  @override
  String get vendorId => kQuickBooksTimeVendorId;

  @override
  String get displayName => kQuickBooksTimeDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile =>
      const VendorCapabilityProfile(
        vendorId: kQuickBooksTimeVendorId,
        displayName: kQuickBooksTimeDisplayName,
        category: IntegrationCategory.labor,
        // Public Intuit OAuth (authorization_code grant) — self-serve
        // at developer.intuit.com.
        authMode: VendorAuthMode.oauth,
        // One Intuit realm covers all of the operator's QBT locations;
        // F&F maps each vendor location to one F&F location_id at
        // connect time.
        grantScope: VendorGrantScope.operatorWide,
        // Vendor docs do not expose a webhook delivery surface usable
        // for schedule/punch changes (see api_consumed.md). Adapter is
        // poll-only.
        webhookSupport: VendorWebhookSupport.pollOnly,
        // Labor systems do not expose a covers field — covers come
        // from POS. Recorded as `not_applicable` per field_mapping.md.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        // Module disambiguation: this adapter binds to QuickBooks
        // Time only. Accounting + Payroll trigger ModuleRefusalException
        // at connect time. The non-empty `modules` list tells the
        // admin surface to render the pre-card module sub-dialog
        // (`docs/phases/phase_8/vendor_connections_admin_surface.md`).
        modules: <String>[kQuickBooksModuleTime],
        timestampPolicyDocId: 'quickbooks_time.asUtc',
      );

  /// Convenience pass-through to [capabilityProfile.lifecycle]. Locked
  /// at `documented` by the engineering slice; promoted by the
  /// `8.S.QBT.live.sandbox` and `8.S.QBT.live.prod` rolling slices,
  /// and auto-promoted to `liveWithOperators` on first operator
  /// connect.
  VendorLifecycle get lifecycle => capabilityProfile.lifecycle;

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kQuickBooksTimeVendorId) {
      throw StateError(
        'connect dispatched to QuickBooksTimeLaborAdapter for non-QBT '
        'vendor ${command.vendorId}',
      );
    }

    // Module disambiguation. The admin surface's pre-card sub-dialog
    // captures the operator's module pick and passes it as
    // `command.module`. The two refusal paths short-circuit BEFORE any
    // OAuth exchange so credentials never round-trip for an
    // unsupported module.
    final module = command.module ?? kQuickBooksModuleTime;
    if (module == kQuickBooksModuleAccounting) {
      throw const ModuleRefusalException(
        module: kQuickBooksModuleAccounting,
        message:
            'QuickBooks Online (Accounting) is an outbound integration. '
            'Please connect it from the Outbound Integrations section.',
      );
    }
    if (module == kQuickBooksModulePayroll) {
      throw const ModuleRefusalException(
        module: kQuickBooksModulePayroll,
        message:
            'QuickBooks Payroll is not supported as a standalone '
            'connector. Connect QuickBooks Time for scheduling and '
            'punches; payroll runs separately.',
      );
    }
    if (module != kQuickBooksModuleTime) {
      throw StateError(
        'unrecognized QuickBooks module "$module"; expected one of '
        'time / accounting / payroll',
      );
    }

    // OAuth callback completion. The proxy framework already validated
    // the state token at start; `oauthState` carries the authorization
    // code in the documented shape. Production wires the real callback
    // against Intuit's OAuth endpoint; the documented slice exercises
    // the same code path against the test transport.
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
          'https://proxy.example/v1/oauth/callback/$kQuickBooksTimeVendorId',
    );

    final realmId = tokenResponse.realmId ?? '';

    final row = QuickBooksTimeConnectionRow(
      connectionId:
          'quickbooks_time-${command.operatorId}-${command.locationId}',
      operatorId: command.operatorId,
      locationId: command.locationId,
      intuitRealmId: realmId,
      module: kQuickBooksModuleTime,
      status: ConnectionStatus.connected,
    );
    final stored = await _gateway.upsertConnection(row: row);
    return ConnectResult(
      connectionId: stored.connectionId,
      status: stored.status,
      metadata: stored.toMetadata(),
      // Poll-only vendor — no webhook URL is provisioned. Operators
      // see "no webhooks; sync runs every 5 minutes" copy in the
      // admin widget per `webhook_signature.md` (N/A line) and the
      // walkthrough.
      webhookUrl: null,
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    final start = _clock().toUtc();
    final accessToken = await _gateway.readAccessToken(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (accessToken == null) {
      final elapsed = _clock().toUtc().difference(start);
      return TestConnectionResult(
        authValid: false,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note: 'No access token on file; reconnect required.',
      );
    }

    final sample = await _transport.sampleTimesheet(accessToken: accessToken);
    final canonical = mapTimesheetToCanonical(
      operatorId: command.operatorId,
      locationId: command.locationId,
      record: sample,
    );
    final elapsed = _clock().toUtc().difference(start);
    if (canonical == null) {
      return TestConnectionResult(
        authValid: true,
        sample: sample,
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note: 'Sample present but field mapping incomplete; verify '
            'documented_per_quickbooks_time_v1 against this sample.',
      );
    }
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'shift_start': canonical.shiftStart.toIso8601String(),
        'shift_end': canonical.shiftEnd?.toIso8601String() ?? '',
        'role_name': canonical.roleName,
        'employee_id': canonical.employeeId,
        'vendor_entity_id': canonical.vendorEntityId,
        'vendor_modified_at': canonical.vendorModifiedAt.toIso8601String(),
        'covers_source': 'not_applicable',
      },
      elapsedMs: elapsed.inMilliseconds,
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final accessToken =
        await _requireAccessToken(command.operatorId, command.locationId);

    var batchesCommitted = 0;
    var recordsWritten = 0;
    int? page = _decodePage(command.resumeFromCursor);
    var lastModifiedSeen = command.windowStart;

    while (true) {
      final response = await _transport.listTimesheets(
        accessToken: accessToken,
        modifiedSince: command.windowStart,
        modifiedUntil: command.windowEnd,
        page: page,
      );

      for (final record in response.records) {
        final canonical = mapTimesheetToCanonical(
          operatorId: command.operatorId,
          locationId: command.locationId,
          record: record,
        );
        if (canonical == null) {
          // Malformed payload — drop at adapter boundary per V1 lean
          // cut 2 (no warning-flag channel; the adapter either writes
          // a clean canonical fact or refuses).
          continue;
        }
        final passed = await command.sanityHook(
          vendorEventId: canonical.vendorEntityId,
          payload: <String, Object?>{
            'shift_start': canonical.shiftStart.toIso8601String(),
            if (canonical.shiftEnd != null)
              'shift_end': canonical.shiftEnd!.toIso8601String(),
          },
          isDeliberateBackfill: true,
        );
        if (!passed) {
          // Framework already wrote sanity_log + connector_sync_log
          // 'sanity_drop'. Skip the canonical fact write.
          continue;
        }
        final inserted = await _gateway.writePunchFact(canonical);
        if (inserted) recordsWritten += 1;
        if (canonical.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = canonical.vendorModifiedAt;
        }
      }

      // Per-batch commit. Watermark persists after THIS page's writes,
      // not after the full backfill — Cloud Run Job restart resumes
      // from this cursor.
      page = response.nextPage;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: QuickBooksTimeWatermarkRow(
          cursorToken: page == null ? '' : page.toString(),
          lastModifiedSeen: lastModifiedSeen,
        ),
      );
      batchesCommitted += 1;

      if (response.nextPage == null) break;
    }

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: page == null ? '' : page.toString(),
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

    var recordsWritten = 0;
    var sanityDropped = 0;
    int? page = _decodePage(command.cursorToken);
    var lastModifiedSeen = command.lastModifiedSeen;
    final tickEnd = _clock().toUtc();

    while (true) {
      final response = await _transport.listTimesheets(
        accessToken: accessToken,
        modifiedSince: command.lastModifiedSeen,
        modifiedUntil: tickEnd,
        page: page,
      );

      for (final record in response.records) {
        final canonical = mapTimesheetToCanonical(
          operatorId: command.operatorId,
          locationId: command.locationId,
          record: record,
        );
        if (canonical == null) {
          continue;
        }
        final passed = await command.sanityHook(
          vendorEventId: canonical.vendorEntityId,
          payload: <String, Object?>{
            'shift_start': canonical.shiftStart.toIso8601String(),
            if (canonical.shiftEnd != null)
              'shift_end': canonical.shiftEnd!.toIso8601String(),
          },
          isDeliberateBackfill: false,
        );
        if (!passed) {
          sanityDropped += 1;
          continue;
        }
        final inserted = await _gateway.writePunchFact(canonical);
        if (inserted) recordsWritten += 1;
        if (canonical.vendorModifiedAt.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = canonical.vendorModifiedAt;
        }
      }

      page = response.nextPage;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: QuickBooksTimeWatermarkRow(
          cursorToken: page == null ? '' : page.toString(),
          lastModifiedSeen: lastModifiedSeen,
        ),
      );

      if (response.nextPage == null) break;
    }

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: page == null ? '' : page.toString(),
      newLastModifiedSeen: lastModifiedSeen,
      sanityDropped: sanityDropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(
    HandleWebhookCommand command,
  ) async {
    // pollOnly: F&F's documented review of QuickBooks Time exposes no
    // webhook delivery surface usable for schedule/punch changes (see
    // `api_consumed.md`). The framework router consults
    // `capabilityProfile.webhookSupport` before dispatch and never
    // hands a webhook to a poll-only adapter. The throw stays as a
    // defense-in-depth assertion against future router refactors.
    throw UnsupportedError(
      'QuickBooks Time does not support webhooks; pollOnly',
    );
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
        // Poll-only vendor — no webhook subscription was ever
        // registered, so the unregister step is vacuously true.
        webhookUnregistered: true,
        watermarkPreserved: true,
      );
    }

    try {
      // Best-effort revoke. Vendor outage MUST NOT block disconnect.
      // QBT/Intuit's revoke endpoint takes the refresh token; the
      // adapter passes the access token here as a placeholder so the
      // documented slice's fake transport accepts a uniform argument.
      // Production swaps in `vendor_credentials.refresh_token`.
      await _transport.revoke(refreshToken: accessToken);
    } catch (_) {
      // Best-effort revoke; vendor outage shouldn't block disconnect.
    }

    await _gateway.wipeCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );

    return const DisconnectResult(
      credentialsWiped: true,
      webhookUnregistered: true,
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
        'no QuickBooks Time access token on file for '
        '(operator=$operatorId, location=$locationId); the framework '
        'should have refused the request before reaching the adapter.',
      );
    }
    return token;
  }

  /// Decode a page-number cursor string. Empty / null / unparsable
  /// strings start the listing at page 1 (the QBT default).
  int? _decodePage(String? cursor) {
    if (cursor == null || cursor.isEmpty) return null;
    return int.tryParse(cursor);
  }

  /// Map one QBT `timesheets[]` record to a canonical punch fact.
  /// Returns null when the payload is missing required fields — the
  /// caller drops it at the adapter boundary.
  ///
  /// Field paths are captured as documented assumptions in the fixture
  /// file's `documented_per_quickbooks_time_v1` constant. Every change
  /// to this mapping requires a fixture-constant bump + an
  /// `8.S.QBT.live.sandbox` re-verification before merge.
  @visibleForTesting
  QuickBooksTimeCanonicalPunchFact? mapTimesheetToCanonical({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> record,
  }) {
    final id = record['id'];
    if (id == null) return null;
    final entityId = id.toString();
    if (entityId.isEmpty) return null;

    final startRaw = record['start'];
    final shiftStart = _parseUtcInstant(startRaw);
    if (shiftStart == null) return null;

    final endRaw = record['end'];
    final shiftEnd = _parseUtcInstant(endRaw);

    final lastModifiedRaw = record['last_modified'];
    final modifiedAt = _parseUtcInstant(lastModifiedRaw) ?? shiftStart;

    final roleNameRaw = record['role_name'] ?? record['jobcode_name'];
    final roleName =
        (roleNameRaw is String && roleNameRaw.isNotEmpty) ? roleNameRaw : '';

    final userIdRaw = record['user_id'];
    final employeeId = userIdRaw == null ? '' : userIdRaw.toString();

    return QuickBooksTimeCanonicalPunchFact(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: entityId,
      vendorModifiedAt: modifiedAt,
      shiftStart: shiftStart,
      shiftEnd: shiftEnd,
      roleName: roleName,
      employeeId: employeeId,
      rawPayload: record,
    );
  }

  static DateTime? _parseUtcInstant(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String && raw.isNotEmpty) {
      // Per `quickbooks_time` timestamp policy: ISO-8601 with explicit
      // `Z` is the documented shape. The adapter does not silently
      // fall back when `Z` is missing — that ambiguous-shape case is
      // the Scenario E boundary captured by the policy and verified
      // at sandbox time.
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
  }
}
