// Phase 8.S.HM — Humanity (TCP) labor / scheduling adapter
// (lifecycle = documented).
//
// Humanity is the framework's first **key-paste, poll-only** vendor in
// Wave B. It exercises two seams that no prior adapter has touched:
//
//   1. `authMode = keyPaste` — Humanity v1 still uses legacy
//      username/password to mint a session token (no OAuth, no
//      partnership program). The connect flow accepts a
//      `ConnectKeyPasteCredential(apiKey: <password>, username: <username>)`
//      and posts to the legacy `/oauth2/token` endpoint with
//      `grant_type=password`. The plaintext credentials never reach
//      this adapter at runtime — the proxy does the POST, stashes the
//      issued bearer token in `vendor_credentials` (pgcrypto envelope),
//      and hands the adapter a [VendorCredentialHandle] that resolves
//      to the bearer server-side. The adapter operates against the
//      handle, not the password.
//   2. `webhookSupport = pollOnly` — Humanity's documented v1 API
//      exposes no webhook delivery surface. The adapter therefore
//      declares `webhookSupport = pollOnly` and `handleWebhook`
//      throws `UnsupportedError`. The framework router consults
//      `capabilityProfile.webhookSupport` before dispatch and never
//      hands a webhook to a poll-only adapter; the throw is a
//      defense-in-depth assertion against future router refactors.
//
// Engineered against the documented Humanity v1 API at
// `https://platform.humanity.com/v1.0` retrieved 2026-05-04 (see
// `docs/integrations/humanity/api_consumed.md`). Lifecycle at slice
// close: `VendorLifecycle.documented`. Live HTTP is the responsibility
// of `8.S.HM.live.sandbox` and `8.S.HM.live.prod` rolling slices.
//
// Doctrine: `docs/contracts/vendor_adapter_slice_contract.md` +
// `docs/contracts/per_vendor_doc_pack_contract.md`. The slice's
// banned-items grep test in
// `test/integrations/labor/humanity_labor_adapter_test.dart` pins
// every forbidden substring from V1 lean cut 2. Engineering inside
// this file refuses each one by construction: no key rotation
// surface, no advisory locks, no graceful-drain hook, no dead-letter
// UI, no sidecar raw-payload partitions, no 5-second test-connection
// SLA, no email auto-disable, no malformed-payload partial-write
// channel (the adapter either writes a clean canonical fact or
// refuses), no strict 5-minute webhook replay window (pollOnly so
// n/a here either way).

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/labor_adapter.dart';
import '../../services/integration/vendor_timestamp_policy.dart';

// ─── Vendor key + display name ──────────────────────────────────────

/// Stable vendor identifier matching `connector_connection.vendor_id`.
const String kHumanityVendorId = 'humanity';

/// Operator-facing display name (exact Humanity brand).
const String kHumanityDisplayName = 'Humanity';

/// API version pinned by this adapter. Bumped when the
/// `*.live.sandbox` slice diffs documented vs observed and the doc
/// pack is updated.
const String kHumanityApiVersion = 'v1.0';

// ─── Documented-per-Humanity field mapping (assumption snapshot) ────

/// Field-mapping reference captured at slice ship.
///
/// Mirrors `documentedPerHumanityV10FieldMappingFixture` in the test
/// fixture file; the test "field-mapping constant mirrors fixture"
/// pins the two in sync. The `*.live.sandbox` slice diffs observed
/// responses against this constant; mismatches become bounded fixes,
/// not slice rebuilds, per
/// `docs/contracts/vendor_adapter_slice_contract.md`.
///
/// Source: <https://platform.humanity.com/v1.0> retrieved 2026-05-04.
const Map<String, Object?> documentedPerHumanityV10FieldMapping =
    <String, Object?>{
  'api_version': 'v1.0',
  'source_doc_url': 'https://platform.humanity.com/v1.0',
  'retrieval_date': '2026-05-04',
  'shift_start': <String, Object?>{
    'path': 'shifts.in_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
  'shift_end': <String, Object?>{
    'path': 'shifts.out_time',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
  'role_name': <String, Object?>{
    'path': 'positions.name',
    'type': 'string',
    'transform': 'direct',
    'doc_url': 'https://platform.humanity.com/v1.0/positions',
  },
  'employee_id': <String, Object?>{
    'path': 'employees.id',
    'type': 'string_or_int',
    'transform': 'direct',
    'doc_url': 'https://platform.humanity.com/v1.0/employees',
  },
  'vendor_entity_id': <String, Object?>{
    'path': 'shifts.id',
    'type': 'string_or_int',
    'transform': 'direct',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
  'vendor_modified_at': <String, Object?>{
    'path': 'shifts.updated',
    'type': 'iso8601_utc',
    'transform': 'direct_utc',
    'doc_url': 'https://platform.humanity.com/v1.0/shifts',
  },
  // Covers source declared `not_applicable` per
  // `docs/integrations/humanity/field_mapping.md` — labor adapters do
  // not produce a covers signal; covers come from POS.
  'covers_source': 'not_applicable',
  // Forbidden — adapter MUST NOT persist these fields per privacy
  // policy.
  'forbidden_employee_email_path': 'employees.email',
  'forbidden_employee_phone_path': 'employees.phone',
  'forbidden_employee_full_name_path': 'employees.name',
  // Endpoints (documented):
  'auth_token_endpoint': '/oauth2/token',
  'auth_grant_type': 'password',
  'shifts_endpoint': '/shifts',
  'timeclocks_endpoint': '/timeclocks',
  'positions_endpoint': '/positions',
  'employees_endpoint': '/employees',
  'company_endpoint': '/company',
};

// ─── Local timestamp policy (deferred-merged into framework catalog) ──

/// Local Humanity timestamp policy. The framework's
/// `vendorTimestampPolicy` catalog is amended at the Wave B
/// integration commit. Until then the adapter exposes this directly
/// so downstream tests can assert the convention.
const TimestampPolicy humanityTimestampPolicy = TimestampPolicy(
  vendorId: kHumanityVendorId,
  ambiguousConvention: AmbiguousTimestampConvention.asUtc,
  documentationNote:
      'Humanity v1 shift timestamps (in_time / out_time / updated) are '
      'UTC ISO-8601. The trailing `Z` is consistently present in the '
      'documented response shape; the policy stays declarative so a '
      'future API change does not silently break business-date '
      'bucketing.',
);

// ─── Server-side credential handle ──────────────────────────────────

/// Opaque server-side credential reference. Wired to
/// `vendor_credentials_repository.dart` (Phase 8.0). Plaintext
/// passwords / bearer tokens never leave the proxy boundary; the
/// production HTTP client resolves the handle internally.
///
/// Defined locally for now (mirrors the pattern in
/// `lib/integrations/reservation/libro_reservation_adapter.dart`);
/// hoisted into a shared file at the framework integration commit.
class VendorCredentialHandle {
  const VendorCredentialHandle({required this.credentialId});
  final String credentialId;
}

// ─── Vendor-shape DTOs ──────────────────────────────────────────────

/// One Humanity shift row as returned by `/shifts`. Field names
/// mirror `documentedPerHumanityV10FieldMapping` in this file and the
/// fixture's `documentedPerHumanityV10FieldMappingFixture`.
class HumanityShiftDto {
  const HumanityShiftDto({
    required this.id,
    required this.employeeId,
    required this.positionName,
    required this.inTime,
    required this.outTime,
    required this.updated,
  });

  final String id;
  final String employeeId;
  final String positionName;
  final DateTime inTime;
  final DateTime outTime;
  final DateTime updated;

  /// Parse from raw JSON map. Returns null when the payload is
  /// missing required fields — the adapter drops the row at the
  /// boundary (no malformed-payload partial-write flag per V1 lean
  /// cut 2; the adapter either writes a clean canonical fact or
  /// refuses).
  static HumanityShiftDto? tryFromMap(Map<String, Object?> map) {
    final id = map['id'];
    if (id == null) return null;
    final entityId = id.toString();
    if (entityId.isEmpty) return null;

    final inRaw = map['in_time'];
    final outRaw = map['out_time'];
    final updRaw = map['updated'];
    if (inRaw is! String || outRaw is! String || updRaw is! String) {
      return null;
    }
    final inTime = DateTime.tryParse(inRaw)?.toUtc();
    final outTime = DateTime.tryParse(outRaw)?.toUtc();
    final updated = DateTime.tryParse(updRaw)?.toUtc();
    if (inTime == null || outTime == null || updated == null) return null;

    final empRaw = map['employee_id'] ?? map['employee'];
    if (empRaw == null) return null;
    final employeeId = empRaw.toString();
    if (employeeId.isEmpty) return null;

    final posRaw = map['position_name'] ?? map['position'];
    if (posRaw is! String || posRaw.isEmpty) return null;

    return HumanityShiftDto(
      id: entityId,
      employeeId: employeeId,
      positionName: posRaw,
      inTime: inTime,
      outTime: outTime,
      updated: updated,
    );
  }
}

/// One page of shifts returned by `/shifts`.
class HumanityShiftsPage {
  const HumanityShiftsPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape rows. Each is normalized into a canonical
  /// punch fact via [HumanityLaborAdapter._materialize].
  final List<Map<String, Object?>> records;

  /// Next-page cursor; null when the server reports no more pages.
  final String? nextCursor;

  /// `updated` of the latest record on this page (UTC). Stamped onto
  /// the watermark per batch.
  final DateTime lastModifiedSeen;
}

/// Token envelope returned by Humanity's legacy `/oauth2/token`
/// endpoint. The `password` grant type returns a bearer token and
/// (optionally) a refresh token. The proxy persists the bearer in
/// `vendor_credentials`; the adapter only ever sees the
/// [VendorCredentialHandle] that resolves to it server-side.
class HumanityTokenResponse {
  const HumanityTokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
}

// ─── HTTP / gateway seams (test-injectable) ─────────────────────────

/// HTTP transport seam. Production wires a Dart `package:http` /
/// `package:dio` implementation that resolves [VendorCredentialHandle]
/// to a bearer token server-side and pages through the documented
/// endpoints. Tests pass an in-memory stub that returns fixture
/// payloads — no network round-trip, no live HTTP.
abstract class HumanityHttpClient {
  /// `POST /oauth2/token` with `grant_type=password`,
  /// `username=<...>`, `password=<...>`. Called by the proxy on the
  /// connect flow; the issued bearer is stored in `vendor_credentials`
  /// and the adapter never sees the password again.
  ///
  /// Tests inject a fake that returns a deterministic
  /// [HumanityTokenResponse] without ever touching plaintext
  /// credentials in Dart memory.
  Future<HumanityTokenResponse> exchangeUsernamePassword({
    required String username,
    required String password,
  });

  /// `GET /shifts` with `last_modified=<since>` + cursor pagination.
  /// Used by both backfill and pollIncremental.
  Future<HumanityShiftsPage> listShifts({
    required VendorCredentialHandle credential,
    required DateTime modifiedSince,
    DateTime? modifiedUntil,
    String? cursor,
  });

  /// `GET /shifts/sample` — heavy-but-bounded sample probe used by
  /// [HumanityLaborAdapter.testConnection]. Returns a single
  /// representative shift row so the operator can eyeball the field
  /// mapping (shift_start, shift_end, role_name).
  Future<Map<String, Object?>?> fetchSampleShift({
    required VendorCredentialHandle credential,
  });

  /// `POST /oauth2/revoke` (best-effort) — called on operator-
  /// initiated disconnect. Vendor outage MUST NOT block disconnect.
  Future<void> revokeCredential({required VendorCredentialHandle credential});
}

/// Persistence surface the adapter depends on. Production wires an
/// `OperatorScopedRepository.withTenant`-backed implementation. Tests
/// inject fakes. The adapter NEVER opens its own database connection
/// or imports `package:postgres`; the banned-items grep test pins
/// this.
abstract class HumanityGateway {
  /// Persist the connection row inside an
  /// `OperatorScopedRepository.withTenant` block. The framework calls
  /// this from the proxy connect route AFTER the bearer is stashed in
  /// `vendor_credentials` — at adapter time we only know the handle.
  /// Returns the framework-issued connection id.
  Future<String> persistConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required VendorCredentialHandle credential,
    required Map<String, Object?> metadata,
  });

  /// Read the credential handle for `(operatorId, locationId)`.
  /// Returns null when no connection exists (the framework should
  /// have refused the request before reaching the adapter; a null
  /// here indicates a logic bug).
  Future<VendorCredentialHandle?> readCredential({
    required String operatorId,
    required String locationId,
  });

  /// Read the watermark for `(operatorId, locationId)`. Null when the
  /// connection has never run a backfill / poll.
  Future<HumanityWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  });

  /// Persist the watermark **after each successful batch commit** so
  /// a Cloud Run Job restart resumes from the last persisted cursor
  /// (per the framework contract — never end-of-backfill).
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required HumanityWatermarkRow row,
  });

  /// Upsert one canonical punch fact; returns `true` when a row was
  /// written, `false` when the upsert short-circuited on the
  /// idempotency UNIQUE
  /// (`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`).
  Future<bool> writeShiftFact(HumanityCanonicalShiftFact fact);

  /// Wipe the credential ciphertext on disconnect. Watermark and
  /// canonical facts are preserved so reconnect resumes from the
  /// last cursor (operator re-pastes credentials; the watermark
  /// survives).
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  });
}

/// Watermark row mirroring `connector_sync_watermark`.
class HumanityWatermarkRow {
  const HumanityWatermarkRow({
    required this.cursorToken,
    required this.lastModifiedSeen,
  });

  final String cursorToken;
  final DateTime lastModifiedSeen;
}

/// One canonical punch fact write request handed to the gateway. The
/// gateway is responsible for the upsert on
/// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
/// per `docs/contracts/vendor_adapter_slice_contract.md`.
class HumanityCanonicalShiftFact {
  const HumanityCanonicalShiftFact({
    required this.operatorId,
    required this.locationId,
    required this.vendorEntityId,
    required this.vendorModifiedAt,
    required this.employeeId,
    required this.positionName,
    required this.shiftStart,
    required this.shiftEnd,
    required this.rawPayload,
  });

  final String operatorId;
  final String locationId;
  final String vendorEntityId;
  final DateTime vendorModifiedAt;
  final String employeeId;
  final String positionName;
  final DateTime shiftStart;
  final DateTime shiftEnd;
  final Map<String, Object?> rawPayload;
}

// ─── Adapter ────────────────────────────────────────────────────────

/// Humanity (TCP) labor adapter — keyPaste + pollOnly reference
/// adapter (lifecycle = documented).
///
/// Wave B engineers this adapter at lifecycle = `documented` against
/// the documented Humanity v1 API shape. Live HTTP is deferred to
/// `8.S.HM.live.sandbox` (sandbox verification) and `8.S.HM.live.prod`
/// (production credentialing — Humanity has no partnership program;
/// any operator with an active Humanity account can paste their
/// credentials once the partner activation gate is removed in the
/// `*.live.*` slices).
class HumanityLaborAdapter implements LaborAdapter {
  HumanityLaborAdapter({
    required HumanityHttpClient httpClient,
    required HumanityGateway gateway,
    DateTime Function()? now,
  })  : _httpClient = httpClient,
        _gateway = gateway,
        _now = now ?? DateTime.now;

  final HumanityHttpClient _httpClient;
  final HumanityGateway _gateway;
  final DateTime Function() _now;

  /// Local timestamp policy (deferred-merged into framework catalog).
  TimestampPolicy get timestampPolicy => humanityTimestampPolicy;

  @override
  String get vendorId => kHumanityVendorId;

  @override
  String get displayName => kHumanityDisplayName;

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kHumanityVendorId,
        displayName: kHumanityDisplayName,
        category: IntegrationCategory.labor,
        // Humanity v1 still uses legacy username/password; flag for the
        // connect flow as the keyPaste path. Operator-facing copy in
        // the connect modal explains the credentials are stored
        // server-side and used only to read scheduling data.
        authMode: VendorAuthMode.keyPaste,
        // One Humanity account spans the operator's locations on the
        // company plan — single credential covers all.
        grantScope: VendorGrantScope.operatorWide,
        // Vendor does not document webhook delivery — see
        // `docs/integrations/humanity/api_consumed.md`.
        webhookSupport: VendorWebhookSupport.pollOnly,
        // Labor adapters do not expose covers; covers come from POS.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'docs/integrations/humanity/field_mapping.md',
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    if (command.vendorId != kHumanityVendorId) {
      throw StateError(
        'connect dispatched to HumanityLaborAdapter for non-Humanity '
        'vendor ${command.vendorId}',
      );
    }
    final keyPaste = command.keyPaste;
    if (keyPaste == null) {
      throw const FormatException(
        'Humanity connect requires a ConnectKeyPasteCredential with '
        'apiKey (password) + username (legacy auth path)',
      );
    }
    final username = keyPaste.username;
    if (username == null || username.isEmpty) {
      throw const FormatException(
        'Humanity connect requires the legacy username field on '
        'ConnectKeyPasteCredential (mirrors the vendor `password` '
        'grant_type which takes both username and password)',
      );
    }
    if (keyPaste.apiKey.isEmpty) {
      throw const FormatException(
        'Humanity connect requires the legacy password (carried on '
        'ConnectKeyPasteCredential.apiKey)',
      );
    }

    // Exchange username/password for a bearer token. The plaintext
    // credentials live in this command frame for the duration of this
    // call only; the proxy boundary encrypts the resulting bearer
    // into `vendor_credentials` immediately and the adapter never
    // sees plaintext again. The handle returned below is what the
    // backfill / poll / disconnect paths operate against.
    final tokenResponse = await _httpClient.exchangeUsernamePassword(
      username: username,
      password: keyPaste.apiKey,
    );
    // The proxy persists `tokenResponse.accessToken` into
    // `vendor_credentials` (pgcrypto envelope) and mints the handle
    // id used below. Tests inject a gateway whose `persistConnection`
    // returns a deterministic id without any plaintext storage.
    final credential =
        VendorCredentialHandle(credentialId: tokenResponse.accessToken);
    final connectionId = await _gateway.persistConnection(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      credential: credential,
      metadata: <String, Object?>{
        'auth_mode': 'keyPaste',
        'auth_method': 'legacy_username_password',
        'grant_type': 'password',
        if (tokenResponse.expiresAt != null)
          'token_expires_at': tokenResponse.expiresAt!.toIso8601String(),
        if (tokenResponse.refreshToken != null)
          'has_refresh_token': true,
      },
    );

    return ConnectResult(
      connectionId: connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'auth_mode': 'keyPaste',
        'auth_method': 'legacy_username_password',
      },
      // Poll-only vendor — no webhook URL is provisioned. Operators
      // see "Humanity does not support webhooks; we sync every 5
      // minutes" copy in the admin widget per `webhook_signature.md`
      // (N/A line) and the walkthrough.
      webhookUrl: null,
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(
    TestConnectionCommand command,
  ) async {
    final start = _now().toUtc();
    final credential = await _gateway.readCredential(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (credential == null) {
      final elapsed = _now().toUtc().difference(start);
      return TestConnectionResult(
        authValid: false,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note: 'No Humanity credential on file; reconnect required.',
      );
    }
    final sample = await _httpClient.fetchSampleShift(credential: credential);
    final elapsed = _now().toUtc().difference(start);
    if (sample == null || sample.isEmpty) {
      return TestConnectionResult(
        authValid: true,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note:
            'Auth valid. Humanity returned no recent shifts; reconnect '
            'against an active scheduling period to verify shift_start '
            '+ shift_end + role_name field mapping.',
      );
    }
    final dto = HumanityShiftDto.tryFromMap(sample);
    if (dto == null) {
      return TestConnectionResult(
        authValid: true,
        sample: sample,
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsed.inMilliseconds,
        note:
            'Sample present but field mapping incomplete; verify '
            'documented_per_humanity_v1_0 against this sample.',
      );
    }
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: <String, Object?>{
        'shift_start': dto.inTime.toIso8601String(),
        'shift_end': dto.outTime.toIso8601String(),
        'role_name': dto.positionName,
        'employee_id': dto.employeeId,
        'vendor_entity_id': dto.id,
        'vendor_modified_at': dto.updated.toIso8601String(),
      },
      elapsedMs: elapsed.inMilliseconds,
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    final credential = await _requireCredential(
      command.operatorId,
      command.locationId,
    );
    var batchesCommitted = 0;
    var recordsWritten = 0;
    String? cursor = command.resumeFromCursor;
    var lastModifiedSeen = command.windowStart.toUtc();

    while (true) {
      final page = await _httpClient.listShifts(
        credential: credential,
        modifiedSince: command.windowStart.toUtc(),
        modifiedUntil: command.windowEnd.toUtc(),
        cursor: cursor,
      );

      for (final record in page.records) {
        final dto = HumanityShiftDto.tryFromMap(record);
        if (dto == null) {
          // Malformed payload — drop at the adapter boundary per V1
          // lean cut 2 (no warning-flag channel; the adapter either
          // writes a clean canonical fact or refuses).
          continue;
        }
        final passed = await command.sanityHook(
          vendorEventId: dto.id,
          payload: <String, Object?>{
            'opened_at': dto.inTime.toIso8601String(),
            'closed_at': dto.outTime.toIso8601String(),
          },
          isDeliberateBackfill: true,
        );
        if (!passed) {
          // Framework already wrote sanity_log + connector_sync_log;
          // skip the canonical fact write.
          continue;
        }
        final fact = HumanityCanonicalShiftFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          vendorEntityId: dto.id,
          vendorModifiedAt: dto.updated,
          employeeId: dto.employeeId,
          positionName: dto.positionName,
          shiftStart: dto.inTime,
          shiftEnd: dto.outTime,
          rawPayload: record,
        );
        final wrote = await _gateway.writeShiftFact(fact);
        if (wrote) recordsWritten += 1;
        if (dto.updated.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = dto.updated;
        }
      }

      cursor = page.nextCursor ?? cursor;
      // Per-batch commit. Watermark persists after THIS page's writes,
      // not after the full backfill — Cloud Run Job restart resumes
      // from this cursor.
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: HumanityWatermarkRow(
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
    final credential = await _requireCredential(
      command.operatorId,
      command.locationId,
    );
    var recordsWritten = 0;
    var sanityDropped = 0;
    String? cursor = command.cursorToken;
    var lastModifiedSeen = command.lastModifiedSeen.toUtc();
    final tickEnd = _now().toUtc();

    while (true) {
      final page = await _httpClient.listShifts(
        credential: credential,
        modifiedSince: command.lastModifiedSeen.toUtc(),
        modifiedUntil: tickEnd,
        cursor: cursor,
      );

      for (final record in page.records) {
        final dto = HumanityShiftDto.tryFromMap(record);
        if (dto == null) continue;
        final passed = await command.sanityHook(
          vendorEventId: dto.id,
          payload: <String, Object?>{
            'opened_at': dto.inTime.toIso8601String(),
            'closed_at': dto.outTime.toIso8601String(),
          },
          isDeliberateBackfill: false,
        );
        if (!passed) {
          sanityDropped += 1;
          continue;
        }
        final fact = HumanityCanonicalShiftFact(
          operatorId: command.operatorId,
          locationId: command.locationId,
          vendorEntityId: dto.id,
          vendorModifiedAt: dto.updated,
          employeeId: dto.employeeId,
          positionName: dto.positionName,
          shiftStart: dto.inTime,
          shiftEnd: dto.outTime,
          rawPayload: record,
        );
        final wrote = await _gateway.writeShiftFact(fact);
        if (wrote) recordsWritten += 1;
        if (dto.updated.isAfter(lastModifiedSeen)) {
          lastModifiedSeen = dto.updated;
        }
      }

      cursor = page.nextCursor ?? cursor;
      await _gateway.writeWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        row: HumanityWatermarkRow(
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
    // pollOnly: Humanity's documented v1 API exposes no webhook
    // delivery surface (see `api_consumed.md`). The framework router
    // consults `capabilityProfile.webhookSupport` before dispatch and
    // never hands a webhook to a poll-only adapter; the throw stays
    // as a defense-in-depth assertion against future router refactors
    // that might forget the gate.
    throw UnsupportedError('Humanity does not support webhooks; pollOnly');
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    final credential = await _gateway.readCredential(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    if (credential == null) {
      // Already disconnected. Idempotent no-op.
      return const DisconnectResult(
        credentialsWiped: false,
        // pollOnly — no webhook subscription exists at the vendor
        // side to unregister. Reports `true` to keep the framework
        // disconnect contract uniform across vendors.
        webhookUnregistered: true,
        watermarkPreserved: true,
      );
    }
    try {
      await _httpClient.revokeCredential(credential: credential);
    } catch (_) {
      // Best-effort revoke; vendor outage shouldn't block disconnect.
    }
    await _gateway.wipeCredentials(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    return const DisconnectResult(
      credentialsWiped: true,
      // pollOnly — see comment above.
      webhookUnregistered: true,
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<VendorCredentialHandle> _requireCredential(
    String operatorId,
    String locationId,
  ) async {
    final credential = await _gateway.readCredential(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (credential == null) {
      throw StateError(
        'no Humanity credential on file for '
        '(operator=$operatorId, location=$locationId); the framework '
        'should have refused the request before reaching the adapter.',
      );
    }
    return credential;
  }
}
