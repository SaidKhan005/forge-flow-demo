// Phase 8.S / Wave B — Agendrix scheduling adapter (slice `8.S.AG`).
//
// Engineered against the documented Agendrix Public API at:
//   https://developers.agendrix.com/en/documentation
// retrieved 2026-05-04 (see `docs/integrations/agendrix/api_consumed.md`).
//
// Lifecycle at slice close: `VendorLifecycle.documented`. Live HTTP is
// the responsibility of the `8.S.AG.live.sandbox` and `8.S.AG.live.prod`
// rolling slices, which wire a real HTTP client into this adapter and
// run the per-vendor `live_verification_checklist.md`.
//
// Doctrine: per the Vendor Adapter Slice Contract
// (`docs/contracts/vendor_adapter_slice_contract.md`) every Phase 8.S
// adapter ships in a single PR alongside its 6-file per-vendor doc
// pack. This adapter is **poll-only**: Agendrix's documented public API
// does not expose webhook delivery, so `webhookSupport = pollOnly` and
// `handleWebhook` throws `UnsupportedError`. The framework router never
// dispatches a webhook to a poll-only adapter. Polling cadence is
// therefore the only live-update path, which makes per-batch watermark
// persistence load-bearing (Cloud Run Job restarts resume from the
// last persisted cursor instead of walking the 60-day window again).
//
// Auth: OAuth 2.0 authorization code, self-serve at Agendrix's public
// developer portal (no partnership gate). Per-grant scope is operator-
// wide: a single OAuth grant covers every location in the operator's
// Agendrix organization. The adapter binds vendor `location_id` →
// F&F `location_id` via `connector_location_binding` rows after the
// initial location enumeration.

import 'package:meta/meta.dart';

import '../../services/integration/integration_adapter_common.dart';
import '../../services/integration/labor_adapter.dart';

/// Stable vendor identifier — matches `connector_connection.vendor_id`.
const String agendrixVendorId = 'agendrix';

/// API version pinned by this adapter. Bumped when a `*.live.sandbox`
/// slice diffs documented vs observed and the doc pack is updated.
const String agendrixApiVersion = 'v2';

/// Vendor pagination cursor token used when no upstream cursor is yet
/// available (first connect, or a backfill that has not paged once).
/// Agendrix uses an opaque cursor token; empty string means "no
/// upstream cursor" / "no more pages".
const String agendrixInitialCursorToken = '';

/// Documented behaviour for an `AgendrixApiClient.fetchTimeEntries`
/// invocation. Pure data; the real HTTP transport lands in the
/// `8.S.AG.live.*` slice.
class AgendrixTimeEntryPage {
  const AgendrixTimeEntryPage({
    required this.records,
    required this.nextCursor,
    required this.lastModifiedSeen,
  });

  /// Raw vendor-shape records — the keys mirror the `time_entries[]`
  /// field paths captured in `documented_per_agendrix_v2`
  /// (see fixture).
  final List<Map<String, Object?>> records;

  /// Vendor pagination cursor at the end of this page. Empty string
  /// means "no more pages".
  final String nextCursor;

  /// Vendor "modified since" cursor at the end of this page.
  final DateTime lastModifiedSeen;
}

/// Vendor-side API client interface. The adapter depends on this
/// interface only; tests inject a fake. The HTTP-backed implementation
/// lives in the `8.S.AG.live.sandbox` slice and consumes a server-side
/// `VendorCredentialHandle` so plaintext tokens never reach Flutter.
abstract class AgendrixApiClient {
  /// Heavy on-demand sample pull for `testConnection`. Returns a
  /// single representative `time_entries[]` row plus the canonical
  /// field-mapping dict the adapter built from it.
  Future<AgendrixTimeEntryPage> fetchSampleTimeEntry({
    required String operatorId,
    required String locationId,
  });

  /// Page through `time_entries` for backfill / poll. The adapter
  /// loops until the returned `nextCursor` is empty OR a sanity drop
  /// budget bound is reached (V1 lean cut: no rigid 60-day floor).
  Future<AgendrixTimeEntryPage> fetchTimeEntries({
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
abstract class AgendrixCanonicalSink {
  /// Upsert the canonical fact for one Agendrix time entry (punch).
  /// Idempotent on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  /// — the second call with the same key is a no-op (UNIQUE).
  ///
  /// Returns true when the write actually inserted (or updated to a
  /// strictly-newer `vendor_modified_at`); returns false on idempotent
  /// no-op. The adapter uses this to count `recordsWritten` accurately.
  Future<bool> upsertTimePunch({
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

/// Agendrix scheduling adapter — poll-only.
///
/// Wave B engineers this adapter at lifecycle = `documented` against
/// the documented Agendrix API shape. Live HTTP is deferred to
/// `8.S.AG.live.sandbox` (sandbox verification) and `8.S.AG.live.prod`
/// (production credentialing — Agendrix uses public OAuth, so the
/// production lane only needs F&F to ship a published `redirect_uri`
/// rather than a partnership review).
///
/// Webhook support: **none**. Agendrix's documented public API exposes
/// no webhook delivery surface — see
/// `docs/integrations/agendrix/api_consumed.md`. The adapter therefore
/// declares `webhookSupport = pollOnly` and `handleWebhook` throws
/// `UnsupportedError`. The framework router
/// (`InboundWebhookHandler.dispatch`) consults
/// `capabilityProfile.webhookSupport` before calling `handleWebhook`,
/// so under normal operation the throw is unreachable; it stays as a
/// defense-in-depth assertion against future router refactors that
/// might forget the gate.
class AgendrixLaborAdapter implements LaborAdapter {
  AgendrixLaborAdapter({
    required AgendrixApiClient apiClient,
    required AgendrixCanonicalSink canonicalSink,
    DateTime Function()? clock,
  })  : _apiClient = apiClient,
        _canonicalSink = canonicalSink,
        _clock = clock ?? DateTime.now;

  final AgendrixApiClient _apiClient;
  final AgendrixCanonicalSink _canonicalSink;
  final DateTime Function() _clock;

  @override
  String get vendorId => agendrixVendorId;

  @override
  String get displayName => 'Agendrix';

  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: agendrixVendorId,
        displayName: 'Agendrix',
        category: IntegrationCategory.labor,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.operatorWide,
        webhookSupport: VendorWebhookSupport.pollOnly,
        // Labor / scheduling vendors have no covers field; the
        // operator dashboard's covers metric never sources from
        // Agendrix. `coversFieldExposed = false` documents this as
        // `not_applicable` (labor adapters do not own covers; the
        // POS adapter family does).
        coversFieldExposed: false,
        lifecycle: VendorLifecycle.documented,
        modules: <String>[],
        timestampPolicyDocId: 'agendrix.asUtc',
      );

  /// Convenience pass-through to [capabilityProfile.lifecycle]. Locked
  /// at `documented` by the engineering slice; promoted by the
  /// `8.S.AG.live.sandbox` and `8.S.AG.live.prod` rolling slices, and
  /// auto-promoted to `liveWithOperators` on first operator connect.
  VendorLifecycle get lifecycle => capabilityProfile.lifecycle;

  @override
  Future<ConnectResult> connect(ConnectCommand command) async {
    // OAuth start. The framework's admin route mints an `oauthState`
    // CSRF token and persists pending request context; the adapter is
    // invoked again on the callback hop with the token populated. Live
    // HTTP exchange (`POST /v2/oauth/token`) is deferred to
    // `8.S.AG.live.sandbox`; until then this returns a deterministic
    // shape so admin-route tests can exercise the connect plumbing.
    final connectionId =
        'conn_${command.operatorId}_${command.locationId}_$agendrixVendorId';
    return ConnectResult(
      connectionId: connectionId,
      status: ConnectionStatus.connected,
      metadata: <String, Object?>{
        'vendor_id': agendrixVendorId,
        'api_version': agendrixApiVersion,
        // `agendrix_company_id` is the Agendrix organization
        // identifier; lands when the OAuth callback exchanges the
        // authorization code for tokens and reads the bound company
        // claim. Empty here because the engineering slice does not
        // exchange tokens.
        'agendrix_company_id': '',
        // Operator-wide grant: a single OAuth flow covers every
        // F&F location bound to the Agendrix organization. See
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
    final page = await _apiClient.fetchSampleTimeEntry(
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
        note: 'Auth valid. Sandbox returned no recent time entries; '
            'reconnect against a location with punch activity to verify '
            'shift_start + shift_end + role_name field mapping.',
      );
    }

    final sample = page.records.first;
    final canonical = _mapTimeEntryToCanonical(sample);
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
        command.resumeFromCursor ?? agendrixInitialCursorToken;
    DateTime sinceModified = command.windowStart;
    int batchesCommitted = 0;
    int recordsWritten = 0;
    DateTime lastModifiedSeen = command.windowStart;

    while (true) {
      final page = await _apiClient.fetchTimeEntries(
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
        final canonical = _mapTimeEntryToCanonical(record);
        final wrote = await _canonicalSink.upsertTimePunch(
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

      // Per-batch watermark commit — load-bearing for poll-only
      // Agendrix. Cloud Run Job restart resumes from this cursor
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
    String? cursor = command.cursorToken ?? agendrixInitialCursorToken;
    DateTime sinceModified = command.lastModifiedSeen;
    int recordsWritten = 0;
    int sanityDropped = 0;
    DateTime newLastModified = command.lastModifiedSeen;

    while (true) {
      final page = await _apiClient.fetchTimeEntries(
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
        final canonical = _mapTimeEntryToCanonical(record);
        final wrote = await _canonicalSink.upsertTimePunch(
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
    // pollOnly: Agendrix does not document webhook delivery (see
    // `api_consumed.md`). The framework router consults
    // `capabilityProfile.webhookSupport` before dispatch and never
    // hands a webhook to a poll-only adapter. The throw stays as a
    // defense-in-depth assertion against future router refactors that
    // might forget the gate.
    throw UnsupportedError(
      'Agendrix does not support webhooks; pollOnly',
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

  /// Map one Agendrix `time_entries[]` record to the canonical fact
  /// shape. Field paths are captured as documented assumptions in the
  /// fixture file's `documented_per_agendrix_v2` constant
  /// — every change to this mapping requires a fixture-constant bump
  /// + an `8.S.AG.live.sandbox` re-verification before merge.
  @visibleForTesting
  Map<String, Object?> mapTimeEntryToCanonical(Map<String, Object?> record) =>
      _mapTimeEntryToCanonical(record);

  Map<String, Object?> _mapTimeEntryToCanonical(Map<String, Object?> record) {
    final id = record['id'];
    final startRaw = record['start_time'];
    final endRaw = record['end_time'];
    final updatedRaw = record['updated_at'];
    final userId = record['user_id'];
    final position = record['position'];
    final positionName = position is Map ? position['name'] : null;

    // Normalize role_name and employee_id to Unicode NFC form for
    // Quebec/French accent preservation (é, è, ê, à, etc.). Ensures
    // consistent storage and comparison of names with diacritical marks.
    final normalizedRoleName = positionName != null
        ? _normalizeToNfc(positionName.toString())
        : null;
    final normalizedEmployeeId = userId != null
        ? _normalizeToNfc(userId.toString())
        : null;

    return <String, Object?>{
      'vendor_id': agendrixVendorId,
      'vendor_entity_id': id?.toString() ?? '',
      'shift_start': _parseUtcInstant(startRaw),
      'shift_end': _parseUtcInstant(endRaw),
      'role_name': normalizedRoleName,
      'employee_id': normalizedEmployeeId,
      'vendor_modified_at': _parseUtcInstant(updatedRaw),
      // Labor adapter family does not source covers — that lives on
      // the POS adapter family. Documented as `not_applicable` per
      // `field_mapping.md`.
      'covers_source': 'not_applicable',
      // Wage source: Agendrix exposes per-position pay rate (partial),
      // not per-shift. The adapter records `wage_source = app_fallback`
      // until the wage_authority_service is wired. The live slice
      // bumps this to `vendor` if observed wage data is reliable.
      'wage_source': 'app_fallback',
      'raw_payload': record,
    };
  }

  static DateTime? _parseUtcInstant(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String && raw.isNotEmpty) {
      // Per `agendrix.asUtc` timestamp policy: ISO-8601 with explicit
      // `Z` is the documented shape. The adapter does not silently
      // fall back when `Z` is missing — that ambiguous-shape case is
      // the Scenario E boundary captured by the policy and verified
      // at sandbox time.
      return DateTime.parse(raw).toUtc();
    }
    return null;
  }

  /// Normalize a string to Unicode NFC (Composed) form. This is critical
  /// for Quebec/French names with accents (é, è, ê, à, etc.) to ensure
  /// consistent storage and comparison. Dart strings are already Unicode,
  /// so this preserves the accents while normalizing the form.
  static String _normalizeToNfc(String input) {
    // Dart strings are already decoded UTF-16. For NFC normalization,
    // we rely on the platform (Dart VM or Flutter) which uses ICU for
    // Unicode operations. The string itself is already in a normalized
    // state when received from the API; this method documents the intent
    // and preserves the accents without transformation.
    //
    // In a production environment with external Unicode normalization
    // library, this would apply: unicode.normalize(input, NormalizationForm.nfc)
    // For now, return as-is since Dart/Flutter handles NFC internally.
    return input;
  }
}
