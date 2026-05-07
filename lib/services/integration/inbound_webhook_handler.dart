// Phase 8.0 — Inbound webhook handler (V1 lean cut 2).
//
// One handler per request flow. Sequence:
//
//   1. Per-vendor signature verification using constant-time HMAC
//      compare. Vendors that include a timestamp in the signature
//      header trigger replay defense (24-hour tolerance — the strict
//      5-minute window from iter1 was deleted per V1 lean cut 2;
//      vendor retry windows commonly exceed 5 minutes and the
//      idempotency UNIQUE on (vendor_id, operator_id, vendor_event_id)
//      already prevents double-write of legitimate retries).
//   2. Binding cross-check. After signature verification passes, the
//      handler compares the payload's claimed vendor-location id
//      (Toast `restaurantGuid`, Libro venue id, 7shifts `location_id`)
//      against `connector_connection.metadata` for the (operator_id,
//      location_id) resolved from the URL path. Mismatch returns 403
//      with an audit row and NO canonical-fact write.
//   3. Idempotency upsert keyed on
//      `(vendor_id, operator_id, vendor_event_id)` in
//      `inbound_webhook_idempotency`.
//   4. Vendor timestamp sanity guard
//      (`lib/services/integration/vendor_timestamp_sanity.dart`).
//      Future-dated, out-of-order, or suspiciously-old events are
//      dropped with a `sanity_log` row + `connector_sync_log`
//      'sanity_drop' entry. No canonical fact is written.
//   5. Adapter dispatch (PosAdapter / LaborAdapter / ReservationAdapter
//      `handleWebhook`). Malformed-payload defense wraps the call in
//      try-catch; bad payloads land in `connector_sync_log` and are
//      dropped at the boundary. V1 lean cut 2 removes the
//      `parse_warnings` + `parse_partial` channel — the adapter
//      either writes a clean canonical fact or refuses.
//   6. Dead-letter on the third consecutive failure.
//
// This module is pure logic — it depends on the adapter map and the
// Postgres-backed gateway (a separate file injected at construction).
// Tests drive the handler with a fake gateway to exercise every
// rejection branch without a live database.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'integration_adapter_common.dart';
import 'labor_adapter.dart';
import 'pos_adapter.dart';
import 'reservation_adapter.dart';
import 'vendor_timestamp_sanity.dart';

/// Replay defense ceiling: signatures whose embedded timestamp is
/// more than this old are rejected as replays. V1 lean cut 2 set this
/// to 24 hours — the strict 5-minute Stripe-style window from iter1
/// was deleted because vendor retry windows commonly exceed 5 minutes
/// and a legitimate retry would be misclassified as a replay. The
/// idempotency UNIQUE on
/// `inbound_webhook_idempotency(vendor_id, operator_id, vendor_event_id)`
/// already prevents the double-write that strict replay was
/// defending against; this ceiling now functions as a bound on
/// catastrophically stale signatures (e.g., a webhook delayed for
/// days because the vendor or our proxy was down).
const Duration kInboundWebhookReplayCeiling = Duration(hours: 24);

/// Maximum total processing attempts before a vendor event is
/// dead-lettered. Three matches the framework spec.
const int kInboundWebhookMaxAttempts = 3;

/// Dispatch result returned to the caller (proxy route handler). The
/// route maps each `outcome` to a response code — see the table in
/// [WebhookOutcome] doc.
class WebhookDispatchResult {
  const WebhookDispatchResult({
    required this.outcome,
    required this.statusCode,
    this.message,
    this.recordsWritten = 0,
  });

  final WebhookOutcome outcome;
  final int statusCode;
  final String? message;
  final int recordsWritten;

  Map<String, Object?> toJson() => <String, Object?>{
        'outcome': outcome.name,
        'records_written': recordsWritten,
        if (message != null) 'message': message,
      };
}

/// Handler outcome enum. Each value carries the wire-level mapping.
///
///   * [accepted] → 200 (canonical fact written).
///   * [duplicate] → 200 (idempotent no-op; same vendor_event_id).
///   * [signatureInvalid] → 403 (audit + dead-letter at attempt 3).
///   * [replayTooOld] → 403 (audit + dead-letter at attempt 3).
///   * [bindingMismatch] → 403 (audit + dead-letter at attempt 3).
///   * [sanityDropped] → 200 (timestamp sanity guard dropped the
///                              event; sanity_log row written).
///   * [adapterError] → 500 (vendor retries; dead-letter at attempt 3).
///   * [unknownVendor] → 404 (operator-facing 404 — adapter not
///                              registered).
enum WebhookOutcome {
  accepted,
  duplicate,
  signatureInvalid,
  replayTooOld,
  bindingMismatch,
  sanityDropped,
  adapterError,
  unknownVendor,
}

/// One vendor's HMAC verification policy. Adapter-side detail lives
/// in the per-vendor file; here we keep the abstraction so tests can
/// drive verification without mocking concrete vendor APIs.
abstract class VendorWebhookSignatureVerifier {
  String get vendorId;

  /// Returns the verification result. Implementations MUST use
  /// [constantTimeBytesEquals] to avoid timing oracles.
  WebhookSignatureVerification verify({
    required Uint8List rawBody,
    required Map<String, String> headers,
    required String signingSecret,
    required DateTime now,
  });
}

class WebhookSignatureVerification {
  const WebhookSignatureVerification({
    required this.valid,
    this.timestamp,
    this.failureReason,
  });

  final bool valid;
  final DateTime? timestamp;
  final String? failureReason;
}

/// Storage interface the handler depends on. Production wires a
/// Postgres-backed implementation that encapsulates the
/// `connector_connection.metadata` cross-check, idempotency upsert,
/// dead-letter insert, and audit log row. Tests pass an in-memory
/// fake.
abstract class InboundWebhookGateway {
  /// Returns the binding metadata for `(operator_id, location_id,
  /// vendor_id)` so the handler can cross-check against the payload's
  /// claimed vendor-location id. Returns null when no connection
  /// exists (operator-facing 404).
  Future<ConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
    required String vendorId,
  });

  /// The signing secret for HMAC verification. Decrypted server-side
  /// from `vendor_credentials.metadata` (pgcrypto envelope at V1).
  Future<String?> lookupSigningSecret({
    required String operatorId,
    required String locationId,
    required String vendorId,
  });

  /// Upsert the idempotency row. Returns `true` when this is the
  /// first time the event has been seen (proceed to adapter), `false`
  /// when the row already existed and was processed (duplicate).
  Future<IdempotencyOutcome> claimIdempotency({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  });

  /// Mark the idempotency row as fully processed.
  Future<void> markProcessed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
  });

  /// V1 lean cut 2 — adapter-boundary sanity drop. Writes a row into
  /// `sanity_log` and a `connector_sync_log` entry of kind
  /// `sanity_drop`. No canonical fact is written.
  Future<void> recordSanityDrop({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  });

  /// Increment the attempt counter and capture the most recent
  /// failure message. Returns the new attempt count.
  Future<int> recordFailedAttempt({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String failureMessage,
    required DateTime receivedAt,
  });

  /// Move an event to the dead-letter table after [kInboundWebhookMaxAttempts]
  /// failed attempts.
  Future<void> deadLetter({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payloadPreview,
    required InboundWebhookFailureKind failureKind,
    required String failureMessage,
  });

  /// Append a `connector_sync_log` row for surfacing in the "View
  /// logs" admin modal.
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  });
}

class ConnectionBinding {
  const ConnectionBinding({
    required this.connectionId,
    required this.metadata,
    required this.status,
  });

  final String connectionId;
  final Map<String, Object?> metadata;
  final ConnectionStatus status;
}

enum IdempotencyOutcome { firstTime, duplicate }

enum InboundWebhookFailureKind {
  signatureInvalid,
  replayTooOld,
  bindingMismatch,
  parseError,
  adapterError,
  idempotencyConflict,
  sanityDrop,
}

extension InboundWebhookFailureKindExt on InboundWebhookFailureKind {
  String get sqlValue {
    switch (this) {
      case InboundWebhookFailureKind.signatureInvalid:
        return 'signature_invalid';
      case InboundWebhookFailureKind.replayTooOld:
        return 'replay_too_old';
      case InboundWebhookFailureKind.bindingMismatch:
        return 'binding_mismatch';
      case InboundWebhookFailureKind.parseError:
        return 'parse_error';
      case InboundWebhookFailureKind.adapterError:
        return 'adapter_error';
      case InboundWebhookFailureKind.idempotencyConflict:
        return 'idempotency_conflict';
      case InboundWebhookFailureKind.sanityDrop:
        return 'sanity_drop';
    }
  }
}

/// Per-tenant adapter factory typedefs.
///
/// Vendor credential bridges (e.g., `ToastBrokerAccessTokenResolver`)
/// hardcode `(operatorId, locationId)` at construction. A single
/// global adapter map can therefore only ever serve one tenant. The
/// factory-per-vendor model lets the framework materialise the
/// right-tenant adapter for each inbound webhook, mirroring the
/// `AdapterFactory` pattern at
/// `tool/integration_sync_worker/dispatch.dart`.
///
/// Each factory is a closure that closes over the per-vendor deps
/// record built at boot (transports, gateways, credential bridges,
/// sinks) and returns a fully-wired adapter for the requested
/// `(operatorId, locationId)`.
typedef PosAdapterFactory = PosAdapter Function({
  required String operatorId,
  required String locationId,
});

typedef LaborAdapterFactory = LaborAdapter Function({
  required String operatorId,
  required String locationId,
});

typedef ReservationAdapterFactory = ReservationAdapter Function({
  required String operatorId,
  required String locationId,
});

/// Inbound webhook handler. Holds per-vendor adapter factories +
/// gateway as dependencies; no per-request state beyond what the
/// dispatch scope contains. Each webhook delivery materialises the
/// adapter for its `(operatorId, locationId)` via the registered
/// factory so per-tenant credential bridges resolve correctly.
class InboundWebhookHandler {
  InboundWebhookHandler({
    required this.gateway,
    required this.posAdapterFactories,
    required this.laborAdapterFactories,
    required this.reservationAdapterFactories,
    required this.signatureVerifiers,
    required this.bindingExtractor,
    VendorTimestampSanity? sanityChecker,
    DateTime Function()? now,
  })  : sanityChecker = sanityChecker ?? const VendorTimestampSanity(),
        _now = now ?? DateTime.now;

  final InboundWebhookGateway gateway;
  final Map<String, PosAdapterFactory> posAdapterFactories;
  final Map<String, LaborAdapterFactory> laborAdapterFactories;
  final Map<String, ReservationAdapterFactory> reservationAdapterFactories;
  final Map<String, VendorWebhookSignatureVerifier> signatureVerifiers;
  final WebhookBindingExtractor bindingExtractor;
  final VendorTimestampSanity sanityChecker;
  final DateTime Function() _now;

  /// Dispatch one inbound webhook. The route handler hands us the
  /// raw body bytes (preserved for HMAC verification — JSON
  /// re-serialization breaks vendor signatures), the parsed payload
  /// (for binding cross-check + adapter dispatch), and the URL-path
  /// `(operator_id, location_id, vendor_id)` triple.
  Future<WebhookDispatchResult> dispatch({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required Uint8List rawBody,
    required Map<String, Object?> payload,
    required Map<String, String> headers,
  }) async {
    final receivedAt = _now().toUtc();

    // Step 0: vendor adapter must be registered. Avoid leaking that
    // we know nothing about this vendor by returning a generic 404.
    // The factory is invoked with the URL-resolved tenant tuple so
    // per-(operator, location) credential bridges materialise
    // correctly — a single global adapter cannot serve multiple
    // tenants.
    final adapterDispatch = _resolveAdapter(
      vendorId: vendorId,
      operatorId: operatorId,
      locationId: locationId,
    );
    if (adapterDispatch == null) {
      return const WebhookDispatchResult(
        outcome: WebhookOutcome.unknownVendor,
        statusCode: 404,
        message: 'unknown vendor',
      );
    }

    // Step 1: signature verification. The route handler enforces a
    // body-cap before reaching us; here we trust [rawBody].
    final verifier = signatureVerifiers[vendorId];
    if (verifier == null) {
      // No verifier registered = vendor not yet wired to the
      // signature-verification surface. Refuse with 403 to fail
      // closed; admin slice surfaces the missing config.
      return const WebhookDispatchResult(
        outcome: WebhookOutcome.signatureInvalid,
        statusCode: 403,
        message: 'no signature verifier registered for vendor',
      );
    }
    final signingSecret = await gateway.lookupSigningSecret(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
    if (signingSecret == null) {
      return const WebhookDispatchResult(
        outcome: WebhookOutcome.signatureInvalid,
        statusCode: 403,
        message: 'no signing secret on file',
      );
    }
    final verification = verifier.verify(
      rawBody: rawBody,
      headers: headers,
      signingSecret: signingSecret,
      now: receivedAt,
    );
    if (!verification.valid) {
      return _failed(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        vendorEventId: _vendorEventIdOrSyntheticFromHeaders(
          payload: payload,
          headers: headers,
        ),
        receivedAt: receivedAt,
        kind: InboundWebhookFailureKind.signatureInvalid,
        statusCode: 403,
        message: verification.failureReason ?? 'signature invalid',
        payload: payload,
      );
    }

    // Replay defense — only when the verifier extracted a timestamp
    // from the signature header.
    final ts = verification.timestamp;
    if (ts != null) {
      final age = receivedAt.difference(ts);
      if (age.isNegative || age > kInboundWebhookReplayCeiling) {
        return _failed(
          operatorId: operatorId,
          locationId: locationId,
          vendorId: vendorId,
          vendorEventId: _vendorEventIdOrSyntheticFromHeaders(
            payload: payload,
            headers: headers,
          ),
          receivedAt: receivedAt,
          kind: InboundWebhookFailureKind.replayTooOld,
          statusCode: 403,
          message:
              'signature timestamp outside replay window (age=${age.inSeconds}s)',
          payload: payload,
        );
      }
    }

    // Step 2: binding cross-check. The proxy URL path resolves to
    // (operator, location); the payload claims its own vendor-side
    // location id. Mismatch = potential cross-tenant leak.
    final binding = await gateway.lookupBinding(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
    if (binding == null) {
      return const WebhookDispatchResult(
        outcome: WebhookOutcome.unknownVendor,
        statusCode: 404,
        message: 'no connector connection for this (operator, location, vendor)',
      );
    }

    final claimed = bindingExtractor.extract(vendorId: vendorId, payload: payload);
    if (claimed != null && !bindingExtractor.matches(
      vendorId: vendorId,
      claimed: claimed,
      stored: binding.metadata,
    )) {
      return _failed(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        vendorEventId: _vendorEventIdOrSynthetic(payload),
        receivedAt: receivedAt,
        kind: InboundWebhookFailureKind.bindingMismatch,
        statusCode: 403,
        message:
            'payload claimed vendor-location id does not match connector_connection.metadata',
        payload: payload,
      );
    }

    // Step 3: idempotency upsert. The vendor_event_id comes from
    // [bindingExtractor] (vendor-shape id) or a hash of the raw body
    // when the vendor does not expose one (rare).
    final vendorEventId = _vendorEventIdOrSynthetic(payload);
    final idempotency = await gateway.claimIdempotency(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      vendorEventId: vendorEventId,
      receivedAt: receivedAt,
    );
    if (idempotency == IdempotencyOutcome.duplicate) {
      return const WebhookDispatchResult(
        outcome: WebhookOutcome.duplicate,
        statusCode: 200,
        message: 'duplicate event short-circuited to no-op',
      );
    }

    // Step 4: vendor timestamp sanity guard (V1 lean cut 2). Drops
    // future-dated, out-of-order, or suspiciously-old events BEFORE
    // any canonical-fact write. Logged via sanity_log + a
    // connector_sync_log 'sanity_drop' entry on the connection.
    final sanityCheck = sanityChecker.evaluate(
      payload: payload,
      now: receivedAt,
      isDeliberateBackfill: false,
    );
    if (sanityCheck.failed) {
      await gateway.recordSanityDrop(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        vendorEventId: vendorEventId,
        rule: sanityCheck.rule!.sqlValue,
        payloadSummary: sanityCheck.payloadSummary,
      );
      await gateway.appendSyncLog(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: binding.connectionId,
        eventKind: 'sanity_drop',
        errorMessage: sanityCheck.message,
      );
      return WebhookDispatchResult(
        outcome: WebhookOutcome.sanityDropped,
        statusCode: 200,
        message: sanityCheck.message,
      );
    }

    // Step 5: adapter dispatch with malformed-payload defense.
    HandleWebhookResult result;
    try {
      result = await adapterDispatch(
        HandleWebhookCommand(
          operatorId: operatorId,
          locationId: locationId,
          vendorId: vendorId,
          vendorEventId: vendorEventId,
          payload: payload,
          headers: headers,
          receivedAt: receivedAt,
        ),
      );
    } catch (error) {
      return _failed(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        vendorEventId: vendorEventId,
        receivedAt: receivedAt,
        kind: InboundWebhookFailureKind.adapterError,
        statusCode: 500,
        message: 'adapter error: $error',
        payload: payload,
      );
    }

    await gateway.markProcessed(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      vendorEventId: vendorEventId,
      receivedAt: receivedAt,
    );
    await gateway.appendSyncLog(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: binding.connectionId,
      eventKind: 'webhook_received',
      recordsCount: result.recordsWritten,
    );

    return WebhookDispatchResult(
      outcome: WebhookOutcome.accepted,
      statusCode: 200,
      recordsWritten: result.recordsWritten,
    );
  }

  /// Type-safe dispatcher resolved from the per-category adapter
  /// factory maps. Returns null when no factory is registered for
  /// [vendorId]. The returned closure forwards directly to the
  /// adapter's `handleWebhook`. The factory is invoked exactly once
  /// per webhook delivery; the resulting adapter is short-lived and
  /// closes over the per-tenant credential bridges.
  Future<HandleWebhookResult> Function(HandleWebhookCommand)? _resolveAdapter({
    required String vendorId,
    required String operatorId,
    required String locationId,
  }) {
    final posFactory = posAdapterFactories[vendorId];
    if (posFactory != null) {
      return posFactory(operatorId: operatorId, locationId: locationId)
          .handleWebhook;
    }
    final laborFactory = laborAdapterFactories[vendorId];
    if (laborFactory != null) {
      return laborFactory(operatorId: operatorId, locationId: locationId)
          .handleWebhook;
    }
    final reservationFactory = reservationAdapterFactories[vendorId];
    if (reservationFactory != null) {
      return reservationFactory(operatorId: operatorId, locationId: locationId)
          .handleWebhook;
    }
    return null;
  }

  String _vendorEventIdOrSynthetic(Map<String, Object?> payload) {
    final candidate = payload['event_id'] ??
        payload['eventId'] ??
        payload['eventGuid'] ??
        payload['id'];
    if (candidate is String && candidate.trim().isNotEmpty) {
      return candidate.trim();
    }
    // No vendor-issued id — hash the canonical payload to keep the
    // idempotency check deterministic. Rare path; usually triggers
    // a follow-up to add a vendor field to the extractor.
    final canonical = const JsonEncoder().convert(_sortKeys(payload));
    final digest = sha256.convert(utf8.encode(canonical));
    return 'sha256:${digest.toString()}';
  }

  String _vendorEventIdOrSyntheticFromHeaders({
    required Map<String, Object?> payload,
    required Map<String, String> headers,
  }) {
    final headerCandidate = headers['x-vendor-event-id'];
    if (headerCandidate != null && headerCandidate.trim().isNotEmpty) {
      return headerCandidate.trim();
    }
    return _vendorEventIdOrSynthetic(payload);
  }

  Object? _sortKeys(Object? node) {
    if (node is Map) {
      final entries = node.entries
          .map((e) => MapEntry<String, Object?>(e.key.toString(), _sortKeys(e.value)))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return Map<String, Object?>.fromEntries(entries);
    }
    if (node is List) {
      return node.map(_sortKeys).toList();
    }
    return node;
  }

  /// Strict-typed wrapper for [_sortKeys] when the caller knows the
  /// node is a top-level object — avoids the `as Map<String, Object?>`
  /// downcast at the call site.
  Map<String, Object?> _sortedPayloadAsMap(Map<String, Object?> payload) {
    final sorted = _sortKeys(payload);
    if (sorted is Map<String, Object?>) return sorted;
    return payload;
  }

  /// Failure path: record the attempt, dead-letter on the third one.
  Future<WebhookDispatchResult> _failed({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required DateTime receivedAt,
    required InboundWebhookFailureKind kind,
    required int statusCode,
    required String message,
    required Map<String, Object?> payload,
  }) async {
    final attempts = await gateway.recordFailedAttempt(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      vendorEventId: vendorEventId,
      failureMessage: message,
      receivedAt: receivedAt,
    );
    if (attempts >= kInboundWebhookMaxAttempts) {
      await gateway.deadLetter(
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
        vendorEventId: vendorEventId,
        payloadPreview: _sortedPayloadAsMap(payload),
        failureKind: kind,
        failureMessage: message,
      );
    }
    return WebhookDispatchResult(
      outcome: _failureOutcome(kind),
      statusCode: statusCode,
      message: message,
    );
  }

  WebhookOutcome _failureOutcome(InboundWebhookFailureKind kind) {
    switch (kind) {
      case InboundWebhookFailureKind.signatureInvalid:
        return WebhookOutcome.signatureInvalid;
      case InboundWebhookFailureKind.replayTooOld:
        return WebhookOutcome.replayTooOld;
      case InboundWebhookFailureKind.bindingMismatch:
        return WebhookOutcome.bindingMismatch;
      case InboundWebhookFailureKind.parseError:
        // V1 lean cut 2: parse errors land in connector_sync_log +
        // dead-letter; wire-level outcome reuses the existing
        // adapter-error path.
        return WebhookOutcome.adapterError;
      case InboundWebhookFailureKind.sanityDrop:
        return WebhookOutcome.sanityDropped;
      case InboundWebhookFailureKind.adapterError:
        return WebhookOutcome.adapterError;
      case InboundWebhookFailureKind.idempotencyConflict:
        return WebhookOutcome.duplicate;
    }
  }
}

/// Adapter union tag — exists to satisfy the strong-mode static
/// resolver in [_resolveAdapter] without leaking a concrete type into
/// the dispatch return.
typedef Adapter = Object;

/// Vendor-side identity binding extractor. Each vendor has its own
/// payload shape (Toast `restaurantGuid`, Libro `venue_id`, 7shifts
/// `location_id`); this surface lets the framework register one
/// extractor per vendor without coupling the handler to vendor SDKs.
class WebhookBindingExtractor {
  WebhookBindingExtractor({Map<String, BindingFieldSpec>? specs})
      : _specs = Map<String, BindingFieldSpec>.unmodifiable(
          specs ?? _defaultSpecs,
        );

  final Map<String, BindingFieldSpec> _specs;

  /// Extract the vendor's claimed location identifier from [payload].
  /// Returns null when the spec for [vendorId] is unknown — the
  /// handler treats null as "skip the check" so a vendor with no
  /// declared binding does not break ingestion.
  Object? extract({
    required String vendorId,
    required Map<String, Object?> payload,
  }) {
    final spec = _specs[vendorId];
    if (spec == null) return null;
    return spec.read(payload);
  }

  /// Compare the [claimed] vendor id against the stored binding
  /// metadata. The spec declares which key inside [stored] (the
  /// `connector_connection.metadata` JSONB) carries the canonical
  /// id.
  bool matches({
    required String vendorId,
    required Object? claimed,
    required Map<String, Object?> stored,
  }) {
    final spec = _specs[vendorId];
    if (spec == null) return true;
    final canonical = stored[spec.metadataKey];
    if (claimed == null || canonical == null) return false;
    return claimed.toString() == canonical.toString();
  }

  static final Map<String, BindingFieldSpec> _defaultSpecs =
      <String, BindingFieldSpec>{
    'lightspeed_lsk': BindingFieldSpec(
      payloadPath: <String>['business_id'],
      metadataKey: 'business_id',
    ),
    'libro': BindingFieldSpec(
      payloadPath: <String>['venue_id'],
      metadataKey: 'venue_id',
    ),
    'quickbooks_time': BindingFieldSpec(
      payloadPath: <String>['realm_id'],
      metadataKey: 'realm_id',
    ),
  };
}

/// Per-vendor declaration of where the binding id lives in the
/// payload + which key in `connector_connection.metadata` it must
/// match.
class BindingFieldSpec {
  const BindingFieldSpec({
    required this.payloadPath,
    required this.metadataKey,
  });

  /// Dot-walk path inside the payload (e.g., `['data', 'business_id']`).
  final List<String> payloadPath;

  /// Key inside `connector_connection.metadata` JSONB.
  final String metadataKey;

  Object? read(Map<String, Object?> payload) {
    Object? cursor = payload;
    for (final segment in payloadPath) {
      if (cursor is Map<String, Object?>) {
        cursor = cursor[segment];
      } else if (cursor is Map) {
        cursor = cursor[segment];
      } else {
        return null;
      }
    }
    return cursor;
  }
}

/// Constant-time byte comparison. Returns `false` immediately when
/// the lengths differ; otherwise XOR-accumulates so total time
/// depends only on length, not on content.
bool constantTimeBytesEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
