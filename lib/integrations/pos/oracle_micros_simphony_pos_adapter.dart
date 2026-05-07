// Phase 8 / Wave B — Oracle MICROS Simphony POS adapter (slice `8.OR`).
//
// Engineered against the documented Simphony Transaction Services Gen 2
// (STSGen2) Cloud API at:
//   https://docs.oracle.com/en/industries/food-beverage/simphony/
// retrieved 2026-05-04 (see `docs/integrations/oracle_micros_simphony/
// api_consumed.md`).
//
// Lifecycle at slice close: `VendorLifecycle.documented`. Live HTTP is
// the responsibility of the `8.OR.live.sandbox` and `8.OR.live.prod`
// rolling slices, which wire a real HTTP client into this adapter and
// run the per-vendor `live_verification_checklist.md`.
//
// Doctrine: per the Vendor Adapter Slice Contract
// (`docs/contracts/vendor_adapter_slice_contract.md`) every Phase 8
// adapter ships in a single PR alongside its 6-file per-vendor doc
// pack. This adapter is the **poll-only** reference: Oracle MICROS
// Simphony does not document webhook delivery, so `webhookSupport =
// pollOnly` and `handleWebhook` throws `UnsupportedError`. The
// framework router never dispatches a webhook to a poll-only adapter.
// Polling cadence is therefore the only live-update path, which makes
// per-batch watermark persistence load-bearing.

import 'package:meta/meta.dart';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/pos_adapter.dart';

/// Stable vendor identifier — matches `connector_connection.vendor_id`.
const String oracleMicrosSimphonyVendorId = 'oracle_micros_simphony';

/// API version pinned by this adapter. Bumped when a `*.live.sandbox`
/// slice diffs documented vs observed and the doc pack is updated.
const String oracleMicrosSimphonyApiVersion = 'v2';

/// Vendor pagination cursor token used when no upstream cursor is yet
/// available (first connect, or a backfill that has not paged once).
const String oracleMicrosSimphonyInitialCursorToken = '';

/// Documented behaviour for an `OracleMicrosSimphonyApiClient.fetchGuestChecks`
/// invocation. Pure data; the real HTTP transport lands in the
/// `8.OR.live.*` slice.
class SimphonyGuestCheckPage {
  const SimphonyGuestCheckPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape records — each record is one element of the Gen2
  /// `items[]` array. Documented field paths under `items[].header.*`
  /// (chkNum, guestCount, opnUTC, cmplOrClsdUTC, lastUpdatedUTC,
  /// subTtlCents) are mirrored in
  /// `documented_per_oracle_micros_simphony_v2` (see fixture).
  final List<Map<String, Object?>> records;

  /// Vendor pagination cursor at the end of this page. Empty string
  /// means "no more pages".
  final String nextCursor;

  /// Vendor "modified since" cursor at the end of this page.
  final DateTime lastModifiedSeen;
}

/// Vendor-side API client interface. The adapter depends on this
/// interface only; tests inject a fake. The HTTP-backed implementation
/// lives in the `8.OR.live.sandbox` slice and consumes a server-side
/// `VendorCredentialHandle` so plaintext tokens never reach Flutter.
abstract class OracleMicrosSimphonyApiClient {
  /// Heavy on-demand sample pull for `testConnection`. Returns a
  /// single representative `guestChecks[]` row plus the canonical
  /// field-mapping dict the adapter built from it.
  Future<SimphonyGuestCheckPage> fetchSampleGuestCheck({
    required String operatorId,
    required String locationId,
  });

  /// Page through `getGuestChecks` for backfill / poll. The adapter
  /// loops until the returned `nextCursor` is empty OR a sanity drop
  /// budget bound is reached (V1 lean cut: no rigid 60-day floor).
  Future<SimphonyGuestCheckPage> fetchGuestChecks({
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
abstract class OracleMicrosSimphonyCanonicalSink {
  /// Upsert the canonical fact for one Simphony guest check. Idempotent
  /// on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  /// — the second call with the same key is a no-op (UNIQUE).
  ///
  /// Returns true when the write actually inserted (or updated to a
  /// strictly-newer `vendor_modified_at`); returns false on idempotent
  /// no-op. The adapter uses this to count `recordsWritten` accurately.
  Future<bool> upsertGuestCheck({
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

/// Oracle MICROS Simphony POS adapter — poll-only reference adapter.
///
/// Wave B engineers this adapter at lifecycle = `documented` against
/// the documented Simphony API shape. Live HTTP is deferred to
/// `8.OR.live.sandbox` (sandbox verification) and `8.OR.live.prod`
/// (production credentialing through the Simphony Partner Integration
/// Program; 8-16 week lead time per
/// `docs/integrations/oracle_micros_simphony/partnership_status.md`).
///
/// Webhook support: **none**. Oracle MICROS Simphony's documented
/// public API exposes no webhook delivery surface — see
/// `docs/integrations/oracle_micros_simphony/api_consumed.md`. The
/// adapter therefore declares `webhookSupport = pollOnly` and
/// `handleWebhook` throws `UnsupportedError`. The framework router
/// (`InboundWebhookHandler.dispatch`) consults
/// `capabilityProfile.webhookSupport` before calling `handleWebhook`,
/// so under normal operation the throw is unreachable; it stays as a
/// defense-in-depth assertion against future router refactors that
/// might forget the gate.
class OracleMicrosSimphonyPosAdapter implements PosAdapter {
  OracleMicrosSimphonyPosAdapter({
    required OracleMicrosSimphonyApiClient apiClient,
    required OracleMicrosSimphonyCanonicalSink canonicalSink,
    DateTime Function()? clock,
  })  : _apiClient = apiClient,
        _canonicalSink = canonicalSink,
        _clock = clock ?? DateTime.now;

  final OracleMicrosSimphonyApiClient _apiClient;
  final OracleMicrosSimphonyCanonicalSink _canonicalSink;
  final DateTime Function() _clock;

  @override
  String get vendorId => oracleMicrosSimphonyVendorId;

  @override
  String get displayName => 'Oracle MICROS Simphony';

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: oracleMicrosSimphonyVendorId,
        displayName: 'Oracle MICROS Simphony',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.pollOnly,
        coversFieldExposed: true,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'oracle_micros_simphony.asUtc',
      );

  /// Convenience pass-through to [capabilityProfile.lifecycle]. Locked
  /// at `documented` by the engineering slice; promoted by the
  /// `8.OR.live.sandbox` and `8.OR.live.prod` rolling slices, and
  /// auto-promoted to `liveWithOperators` on first operator connect.
  VendorLifecycle get lifecycle => capabilityProfile.lifecycle;

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    // OAuth start. The framework's admin route mints an `oauthState`
    // CSRF token and persists pending request context; the adapter is
    // invoked again on the callback hop with the token populated. Live
    // HTTP exchange (`POST /sim/api/v2/oauth/token`) is deferred to
    // `8.OR.live.sandbox`; until then this returns a deterministic
    // shape so admin-route tests can exercise the connect plumbing.
    final connectionId =
        'conn_${command.operatorId}_${command.locationId}_$oracleMicrosSimphonyVendorId';
    return ConnectResult(
      connectionId: connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'vendor_id': oracleMicrosSimphonyVendorId,
        'api_version': oracleMicrosSimphonyApiVersion,
        // `locRef` is the Simphony location reference; lands when the
        // OAuth callback returns the bound vendor location. Empty here
        // because the engineering slice does not exchange tokens.
        'simphony_loc_ref': '',
        // Per-location grant: each F&F location requires its own OAuth
        // flow with Simphony. See `oauth_shape.md`.
        'grant_scope': 'perLocation',
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
    final page = await _apiClient.fetchSampleGuestCheck(
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
        note: 'Auth valid. Sandbox returned no recent guest checks; '
            'reconnect against a location with sales activity to verify '
            'covers + opened_at + closed_at field mapping.',
      );
    }

    final sample = page.records.first;
    final canonical = _mapGuestCheckToCanonical(sample);
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
        command.resumeFromCursor ?? oracleMicrosSimphonyInitialCursorToken;
    DateTime sinceModified = command.windowStart;
    int batchesCommitted = 0;
    int recordsWritten = 0;
    DateTime lastModifiedSeen = command.windowStart;

    while (true) {
      final page = await _apiClient.fetchGuestChecks(
        operatorId: command.operatorId,
        locationId: command.locationId,
        sinceModified: sinceModified,
        cursor: cursor!.isEmpty ? null : cursor,
        isDeliberateBackfill: true,
      );

      for (final record in page.records) {
        final header = record['header'] is Map<String, Object?>
            ? record['header']! as Map<String, Object?>
            : const <String, Object?>{};
        final vendorEventId = (header['chkNum'] ?? '').toString();
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
        final canonical = _mapGuestCheckToCanonical(record);
        final wrote = await _canonicalSink.upsertGuestCheck(
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

      // Per-batch watermark commit — load-bearing for poll-only Simphony.
      // Cloud Run Job restart resumes from this cursor instead of
      // walking the 60-day window from scratch.
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
    String? cursor = command.cursorToken ?? oracleMicrosSimphonyInitialCursorToken;
    DateTime sinceModified = command.lastModifiedSeen;
    int recordsWritten = 0;
    int sanityDropped = 0;
    DateTime newLastModified = command.lastModifiedSeen;

    while (true) {
      final page = await _apiClient.fetchGuestChecks(
        operatorId: command.operatorId,
        locationId: command.locationId,
        sinceModified: sinceModified,
        cursor: cursor!.isEmpty ? null : cursor,
        isDeliberateBackfill: false,
      );

      for (final record in page.records) {
        final header = record['header'] is Map<String, Object?>
            ? record['header']! as Map<String, Object?>
            : const <String, Object?>{};
        final vendorEventId = (header['chkNum'] ?? '').toString();
        final passed = await command.sanityHook(
          vendorEventId: vendorEventId,
          payload: record,
          isDeliberateBackfill: false,
        );
        if (!passed) {
          sanityDropped += 1;
          continue;
        }
        final canonical = _mapGuestCheckToCanonical(record);
        final wrote = await _canonicalSink.upsertGuestCheck(
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
    // pollOnly: Simphony does not document webhook delivery (see
    // `api_consumed.md`). The framework router consults
    // `capabilityProfile.webhookSupport` before dispatch and never
    // hands a webhook to a poll-only adapter. The throw stays as a
    // defense-in-depth assertion against future router refactors that
    // might forget the gate.
    throw UnsupportedError(
      'Oracle MICROS Simphony does not support webhooks; pollOnly',
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

  /// Map one Simphony `items[]` record to the canonical fact shape.
  /// Field paths under `items[].header.*` are captured as documented
  /// assumptions in the fixture file's
  /// `documented_per_oracle_micros_simphony_v2` constant — every change
  /// to this mapping requires a fixture-constant bump + an
  /// `8.OR.live.sandbox` re-verification before merge.
  @visibleForTesting
  Map<String, Object?> mapGuestCheckToCanonical(Map<String, Object?> record) =>
      _mapGuestCheckToCanonical(record);

  Map<String, Object?> _mapGuestCheckToCanonical(Map<String, Object?> record) {
    final header = record['header'] is Map<String, Object?>
        ? record['header']! as Map<String, Object?>
        : const <String, Object?>{};
    final chkNum = header['chkNum'];
    final guestCount = header['guestCount'];
    final opnUtcRaw = header['opnUTC'];
    final cmplOrClsdUtcRaw = header['cmplOrClsdUTC'];
    final lastUpdatedRaw = header['lastUpdatedUTC'];
    final subTtlCents = header['subTtlCents'];

    return <String, Object?>{
      'vendor_id': oracleMicrosSimphonyVendorId,
      'vendor_entity_id': chkNum?.toString() ?? '',
      'covers': guestCount is int
          ? guestCount
          : int.tryParse('${guestCount ?? ''}'),
      'opened_at': _parseUtcInstant(opnUtcRaw),
      'closed_at': _parseUtcInstant(cmplOrClsdUtcRaw),
      'actual_sales': _centsToDollars(subTtlCents),
      'vendor_modified_at': _parseUtcInstant(lastUpdatedRaw),
      'covers_source': 'direct',
      'raw_payload': record,
    };
  }

  static DateTime? _parseUtcInstant(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String && raw.isNotEmpty) {
      // Per `oracle_micros_simphony` timestamp policy: ISO-8601 with
      // explicit `Z` is the documented shape. The adapter does not
      // silently fall back when `Z` is missing — that ambiguous-shape
      // case is the Scenario E boundary captured by the policy and
      // verified at sandbox time.
      return DateTime.parse(raw).toUtc();
    }
    return null;
  }

  static double? _centsToDollars(Object? raw) {
    if (raw is int) {
      return raw / 100.0;
    }
    if (raw is num) {
      return raw.toDouble() / 100.0;
    }
    if (raw is String && raw.isNotEmpty) {
      final parsed = int.tryParse(raw) ?? double.tryParse(raw);
      if (parsed != null) {
        return parsed.toDouble() / 100.0;
      }
    }
    return null;
  }
}
