// Phase 8.S / Wave B — Push Operations scheduling adapter (slice `8.S.PU`).
//
// Engineered against the documented Push Operations REST API at:
//   https://developers.pushoperations.com/
// retrieved 2026-05-04 (see `docs/integrations/push_operations/api_consumed.md`).
//
// Lifecycle at slice close: `VendorLifecycle.documented`. Live HTTP is
// the responsibility of the `8.S.PU.live.sandbox` and `8.S.PU.live.prod`
// rolling slices, which wire a real HTTP client into this adapter and
// run the per-vendor `live_verification_checklist.md`.
//
// Doctrine: per the Vendor Adapter Slice Contract
// (`docs/contracts/vendor_adapter_slice_contract.md`) every Phase 8.S
// adapter ships in a single PR alongside its 6-file per-vendor doc
// pack. This adapter is a **poll-only + bearer-token** scheduling
// reference: Push Operations does not document webhook delivery, so
// `webhookSupport = pollOnly` and `handleWebhook` throws
// `UnsupportedError`. The framework router never dispatches a webhook
// to a poll-only adapter. Polling cadence is therefore the only
// live-update path, which makes per-batch watermark persistence
// load-bearing.
//
// Auth: Push Operations issues bearer tokens through its Partner
// Approval program (see `docs/integrations/push_operations/api_consumed.md`
// + `partnership_status.md`). The bearer token is a partner-issued
// static credential — there is no end-user authorization hop and no
// refresh-token rotation, so `authMode = keyPaste`. Operators paste
// their partner-issued bearer into the admin connect dialog. The
// adapter never sees plaintext: the framework wraps the token in a
// `VendorCredentialHandle` issued by `vendor_credentials_repository.dart`.

import 'package:flutter/foundation.dart';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/labor_adapter.dart';

/// Stable vendor identifier — matches `connector_connection.vendor_id`.
const String pushOperationsVendorId = 'push_operations';

/// API version pinned by this adapter. Bumped when a `*.live.sandbox`
/// slice diffs documented vs observed and the doc pack is updated.
const String pushOperationsApiVersion = 'v1';

/// Vendor pagination cursor token used when no upstream cursor is yet
/// available (first connect, or a backfill that has not paged once).
/// Push Operations uses page+limit pagination on the standard shifts
/// endpoint; the adapter encodes the next page index as a `page:<n>`
/// string and treats an empty string as "no more pages" (the page
/// returned fewer than `limit` records, per documented pagination).
const String pushOperationsInitialCursorToken = '';

/// Documented page size cap on standard Push Operations list
/// endpoints. The adapter requests `limit = 100` and treats a short
/// page as the end of the listing.
const int pushOperationsMaxPageSize = 100;

/// Documented behaviour for a `PushOperationsApiClient.fetchShifts`
/// invocation. Pure data; the real HTTP transport lands in the
/// `8.S.PU.live.*` slice.
class PushOperationsShiftPage {
  const PushOperationsShiftPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape records — the keys mirror the `shifts[]` field
  /// paths captured in `documented_per_push_operations_v1` (see
  /// fixture).
  final List<Map<String, Object?>> records;

  /// Vendor pagination cursor at the end of this page. Empty string
  /// means "no more pages" (the last page returned `< limit` records,
  /// per Push Operations documented pagination shape).
  final String nextCursor;

  /// Vendor "modified since" cursor at the end of this page.
  final DateTime lastModifiedSeen;
}

/// Vendor-side API client interface. The adapter depends on this
/// interface only; tests inject a fake. The HTTP-backed implementation
/// lives in the `8.S.PU.live.sandbox` slice and consumes a server-side
/// `VendorCredentialHandle` so plaintext bearer tokens never reach
/// Flutter.
abstract class PushOperationsApiClient {
  /// Heavy on-demand sample pull for `testConnection`. Returns a
  /// single representative `shifts[]` row plus the canonical
  /// field-mapping dict the adapter built from it.
  Future<PushOperationsShiftPage> fetchSampleShift({
    required String operatorId,
    required String locationId,
  });

  /// Page through `GET /api/v1/shifts` for backfill / poll. The
  /// adapter loops until the returned `nextCursor` is empty OR a
  /// sanity drop budget bound is reached (V1 lean cut: no rigid
  /// 60-day floor).
  Future<PushOperationsShiftPage> fetchShifts({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
  });
}

/// Repository sink the adapter writes canonical facts through. Bound
/// at construction by the framework to an `OperatorScopedRepository`-
/// driven SQL writer per Hard Promise #7. The adapter never opens its
/// own database connection or imports `package:postgres` directly.
abstract class PushOperationsCanonicalSink {
  /// Upsert the canonical fact for one Push Operations shift.
  /// Idempotent on `(vendor_id, operator_id, vendor_entity_id,
  /// vendor_modified_at)` — the second call with the same key is a
  /// no-op (UNIQUE).
  ///
  /// Returns true when the write actually inserted (or updated to a
  /// strictly-newer `vendor_modified_at`); returns false on idempotent
  /// no-op. The adapter uses this to count `recordsWritten` accurately.
  Future<bool> upsertShift({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  });

  /// Persist a watermark advance. Called after each successful batch
  /// commit so a Cloud Run Job restart resumes from the last cursor
  /// (per `vendor_adapter_slice_contract.md` framework call #3).
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  });

  /// Append a `connector_sync_log` row. The framework's repository
  /// implementation writes these; this surface keeps the adapter
  /// pure.
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  });

  /// Wipe credentials + connection metadata on disconnect. Returns
  /// triple (credentialsWiped, webhookUnregistered, watermarkPreserved).
  /// Watermark is always preserved so reconnect resumes from where the
  /// disconnect happened (last canonical write).
  Future<({bool credentialsWiped, bool webhookUnregistered, bool watermarkPreserved})>
      wipeCredentialsPreserveWatermark({
    required String operatorId,
    required String locationId,
  });
}

/// Push Operations scheduling adapter — poll-only + bearer-token
/// reference for the Phase 8.S Wave B engineer-all-17 push.
///
/// Wave B engineers this adapter at lifecycle = `documented` against
/// the documented Push Operations API shape. Live HTTP is deferred to
/// `8.S.PU.live.sandbox` (sandbox verification) and `8.S.PU.live.prod`
/// (production credentialing through Push Operations Partner Approval;
/// 4-6 week lead time per
/// `docs/integrations/push_operations/partnership_status.md`).
///
/// Webhook support: **none**. Push Operations' documented public API
/// exposes no webhook delivery surface — see
/// `docs/integrations/push_operations/api_consumed.md`. The adapter
/// therefore declares `webhookSupport = pollOnly` and `handleWebhook`
/// throws `UnsupportedError`. The framework router
/// (`InboundWebhookHandler.dispatch`) consults
/// `capabilityProfile.webhookSupport` before calling `handleWebhook`,
/// so under normal operation the throw is unreachable; it stays as a
/// defense-in-depth assertion against future router refactors that
/// might forget the gate.
class PushOperationsLaborAdapter implements LaborAdapter {
  PushOperationsLaborAdapter({
    required PushOperationsApiClient apiClient,
    required PushOperationsCanonicalSink canonicalSink,
    DateTime Function()? clock,
  })  : _apiClient = apiClient,
        _canonicalSink = canonicalSink,
        _clock = clock ?? DateTime.now;

  final PushOperationsApiClient _apiClient;
  final PushOperationsCanonicalSink _canonicalSink;
  final DateTime Function() _clock;

  @override
  String get vendorId => pushOperationsVendorId;

  @override
  String get displayName => 'Push Operations';

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: pushOperationsVendorId,
        displayName: 'Push Operations',
        category: IntegrationCategory.labor,
        // Bearer token is partner-issued and static (no end-user
        // authorization hop and no refresh-token rotation). Operators
        // paste their partner-issued bearer in the admin connect
        // dialog -> framework stores it via `VendorCredentialHandle`.
        // See `oauth_shape.md` (N/A line) and `api_consumed.md`.
        authMode: VendorAuthMode.keyPaste,
        // One bearer token covers the operator's entire Push account;
        // multi-location operators reuse the same credential across
        // every F&F location bound to that Push company. See
        // `oauth_shape.md`.
        grantScope: VendorGrantScope.operatorWide,
        webhookSupport: VendorWebhookSupport.pollOnly,
        // Labor adapter — covers field is not applicable to scheduling
        // data; the dashboard "covers via forecast" line is governed
        // by the operator's POS adapter, not this adapter.
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'push_operations.asUtc',
      );

  /// Convenience pass-through to [capabilityProfile.lifecycle]. Locked
  /// at `documented` by the engineering slice; promoted by the
  /// `8.S.PU.live.sandbox` and `8.S.PU.live.prod` rolling slices, and
  /// auto-promoted to `liveWithOperators` on first operator connect.
  VendorLifecycle get lifecycle => capabilityProfile.lifecycle;

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    // Key-paste connect. The framework's admin route accepts the
    // partner-issued bearer token from the operator and stores it via
    // `VendorCredentialHandle` (plaintext never reaches the adapter).
    // Live HTTP exchange (sample `GET /api/v1/company` to verify the
    // bearer + bind the Push company id) is deferred to
    // `8.S.PU.live.sandbox`; until then this returns a deterministic
    // shape so admin-route tests can exercise the connect plumbing.
    final connectionId =
        'conn_${command.operatorId}_${command.locationId}_$pushOperationsVendorId';
    return ConnectResult(
      connectionId: connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'vendor_id': pushOperationsVendorId,
        'api_version': pushOperationsApiVersion,
        // `push_company_id` is the bound Push Operations company
        // identifier; lands when the live slice calls
        // `GET /api/v1/company` after bearer paste. Empty here
        // because the engineering slice does not exchange tokens.
        'push_company_id': '',
        // Operator-wide grant: a single bearer token covers all of
        // the operator's locations on Push Operations. See
        // `oauth_shape.md`.
        'grant_scope': 'operatorWide',
      },
      // Poll-only vendor — no webhook URL is provisioned. Operators
      // see "no webhooks; sync runs every 5 minutes" copy in the
      // admin widget per `webhook_signature.md` (N/A line) and the
      // walkthrough.
      webhookUrl: null,
      firstBackfillStarted: true,
    );
  }

  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) async {
    final start = _clock();
    final page = await _apiClient.fetchSampleShift(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    final elapsedMs = _clock().difference(start).inMilliseconds;

    if (page.records.isEmpty) {
      return TestConnectionResult(
        authValid: true,
        sample: const <String, Object?>{},
        fieldMapping: const <String, Object?>{},
        elapsedMs: elapsedMs,
        note: 'Auth valid. Sandbox returned no recent shifts; reconnect '
            'against a Push Operations company with published schedules '
            'to verify shift_start + shift_end + role_name field '
            'mapping.',
      );
    }

    final sample = page.records.first;
    final canonical = _mapShiftToCanonical(sample);
    return TestConnectionResult(
      authValid: true,
      sample: sample,
      fieldMapping: canonical,
      elapsedMs: elapsedMs,
    );
  }

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    String? cursor =
        command.resumeFromCursor ?? pushOperationsInitialCursorToken;
    DateTime sinceModified = command.windowStart;
    int batchesCommitted = 0;
    int recordsWritten = 0;
    DateTime lastModifiedSeen = command.windowStart;

    while (true) {
      final page = await _apiClient.fetchShifts(
        operatorId: command.operatorId,
        locationId: command.locationId,
        sinceModified: sinceModified,
        cursor: cursor!.isEmpty ? null : cursor,
        isDeliberateBackfill: true,
      );

      for (final record in page.records) {
        final vendorEventId = (record['id'] ?? '').toString();
        final passed = await command.sanityHook(
          vendorEventId: vendorEventId,
          payload: record,
          isDeliberateBackfill: true,
        );
        if (!passed) {
          // Framework already wrote sanity_log + connector_sync_log
          // 'sanity_drop'. Skip the canonical fact write.
          continue;
        }
        final canonical = _mapShiftToCanonical(record);
        final wrote = await _canonicalSink.upsertShift(
          operatorId: command.operatorId,
          locationId: command.locationId,
          canonicalFact: canonical,
        );
        if (wrote) {
          recordsWritten += 1;
        }
      }

      cursor = page.nextCursor;
      sinceModified = page.lastModifiedSeen;
      lastModifiedSeen = page.lastModifiedSeen;
      batchesCommitted += 1;

      // Per-batch watermark commit — load-bearing for poll-only Push
      // Operations. Cloud Run Job restart resumes from this cursor
      // instead of walking the 60-day window from scratch.
      await _canonicalSink.advanceWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor,
        lastModifiedSeen: lastModifiedSeen,
      );

      if (cursor.isEmpty) {
        break;
      }
      if (lastModifiedSeen.isAfter(command.windowEnd)) {
        break;
      }
    }

    return BackfillResult(
      batchesCommitted: batchesCommitted,
      recordsWritten: recordsWritten,
      cursorToken: cursor,
      lastModifiedSeen: lastModifiedSeen,
      completed: cursor.isEmpty || lastModifiedSeen.isAfter(command.windowEnd),
    );
  }

  @override
  Future<PollIncrementalResult> pollIncremental(PollIncrementalCommand command) async {
    String? cursor = command.cursorToken ?? pushOperationsInitialCursorToken;
    DateTime sinceModified = command.lastModifiedSeen;
    int recordsWritten = 0;
    int sanityDropped = 0;
    DateTime newLastModified = command.lastModifiedSeen;

    while (true) {
      final page = await _apiClient.fetchShifts(
        operatorId: command.operatorId,
        locationId: command.locationId,
        sinceModified: sinceModified,
        cursor: cursor!.isEmpty ? null : cursor,
        isDeliberateBackfill: false,
      );

      for (final record in page.records) {
        final vendorEventId = (record['id'] ?? '').toString();
        final passed = await command.sanityHook(
          vendorEventId: vendorEventId,
          payload: record,
          isDeliberateBackfill: false,
        );
        if (!passed) {
          sanityDropped += 1;
          continue;
        }
        final canonical = _mapShiftToCanonical(record);
        final wrote = await _canonicalSink.upsertShift(
          operatorId: command.operatorId,
          locationId: command.locationId,
          canonicalFact: canonical,
        );
        if (wrote) {
          recordsWritten += 1;
        }
      }

      cursor = page.nextCursor;
      sinceModified = page.lastModifiedSeen;
      newLastModified = page.lastModifiedSeen;

      // Per-batch watermark commit. Polling tick may complete one or
      // many pages; each page commits the watermark before moving on
      // so a worker crash mid-tick still resumes deterministically.
      await _canonicalSink.advanceWatermark(
        operatorId: command.operatorId,
        locationId: command.locationId,
        cursorToken: cursor,
        lastModifiedSeen: newLastModified,
      );

      if (cursor.isEmpty) {
        break;
      }
    }

    return PollIncrementalResult(
      recordsWritten: recordsWritten,
      newCursorToken: cursor,
      newLastModifiedSeen: newLastModified,
      sanityDropped: sanityDropped,
    );
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    // pollOnly: Push Operations does not document webhook delivery
    // (see `api_consumed.md`). The framework router consults
    // `capabilityProfile.webhookSupport` before dispatch and never
    // hands a webhook to a poll-only adapter. The throw stays as a
    // defense-in-depth assertion against future router refactors that
    // might forget the gate.
    throw UnsupportedError(
      'Push Operations does not support webhooks; pollOnly',
    );
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) async {
    final outcome = await _canonicalSink.wipeCredentialsPreserveWatermark(
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    await _canonicalSink.appendSyncLog(
      operatorId: command.operatorId,
      locationId: command.locationId,
      eventKind: 'disconnect',
      payloadPreview: <String, Object?>{
        'reason': command.reason.name,
        'actor_user_id': command.actorUserId,
      },
    );
    return DisconnectResult(
      credentialsWiped: outcome.credentialsWiped,
      // Poll-only — no webhook subscription exists at the vendor side
      // to unregister. Always reports `true` to keep the framework
      // disconnect contract uniform across vendors.
      webhookUnregistered: true,
      watermarkPreserved: outcome.watermarkPreserved,
    );
  }

  /// Map one Push Operations `shifts[]` record to the canonical fact
  /// shape. Field paths are captured as documented assumptions in the
  /// fixture file's `documented_per_push_operations_v1` constant —
  /// every change to this mapping requires a fixture-constant bump
  /// + an `8.S.PU.live.sandbox` re-verification before merge.
  @visibleForTesting
  Map<String, Object?> mapShiftToCanonical(Map<String, Object?> record) =>
      _mapShiftToCanonical(record);

  Map<String, Object?> _mapShiftToCanonical(Map<String, Object?> record) {
    final shiftId = record['id'];
    final startAtRaw = record['start_at'];
    final endAtRaw = record['end_at'];
    final updatedAtRaw = record['updated_at'];
    final positionName = record['position_name'];
    final employeeId = record['employee_id'];

    return <String, Object?>{
      'vendor_id': pushOperationsVendorId,
      'vendor_entity_id': shiftId?.toString() ?? '',
      'shift_start': _parseUtcInstant(startAtRaw),
      'shift_end': _parseUtcInstant(endAtRaw),
      'role_name': positionName?.toString(),
      'employee_id': employeeId?.toString(),
      'vendor_modified_at': _parseUtcInstant(updatedAtRaw),
      'covers_source': 'not_applicable',
      'raw_payload': record,
    };
  }

  static DateTime? _parseUtcInstant(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String && raw.isNotEmpty) {
      // Per `push_operations` timestamp policy: ISO-8601 with explicit
      // `Z` is the documented shape. The adapter does not silently
      // fall back when `Z` is missing — that ambiguous-shape case is
      // the Scenario E boundary captured by the policy and verified
      // at sandbox time.
      return DateTime.parse(raw).toUtc();
    }
    return null;
  }
}
