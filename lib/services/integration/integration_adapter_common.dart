// Phase 8.0 — Shared command + result value objects for
// PosAdapter / LaborAdapter / ReservationAdapter.
//
// Pure-data, I/O-free. The repository / route layer constructs these
// from request parameters; the adapter implementation maps them to
// vendor-specific HTTP calls and writes canonical fact rows back
// through `OperatorScopedRepository.withTenant`.
//
// All timestamps in this file follow the "UTC source-truth instant"
// rule from `docs/contracts/phase_7_55_time_boundary_contract.md`
// Rule 11. Adapters convert vendor-shape timestamps via
// `iana_timezone_converter.dart` BEFORE deciding business date.

/// Stable category identifiers. Mirrors `connector_connection.category`.
enum IntegrationCategory { pos, labor, reservation }

/// Vendor capability profile — declares what an adapter supports so
/// the framework can drive the right connect-flow UX, webhook
/// auto-registration, multi-location grant pattern, covers degrade,
/// and partnership gating.
class VendorCapabilityProfile {
  const VendorCapabilityProfile({
    required this.vendorId,
    required this.displayName,
    required this.category,
    required this.authMode,
    required this.grantScope,
    required this.webhookSupport,
    required this.coversFieldExposed,
    required this.partnershipGated,
    this.modules = const <String>[],
    this.timestampPolicyDocId,
  });

  /// Stable vendor key matching `connector_connection.vendor_id`.
  final String vendorId;

  /// Operator-facing display name ("Lightspeed Restaurant K-Series").
  final String displayName;

  /// POS / labor / reservation classification.
  final IntegrationCategory category;

  /// OAuth (vendor sign-in flow) vs key-paste (legacy auth).
  final VendorAuthMode authMode;

  /// Per-location vs operator-wide OAuth grant scope. Drives the
  /// multi-location connect flow per
  /// `vendor_connections_admin_surface.md`.
  final VendorGrantScope grantScope;

  /// Does the vendor support inbound webhooks for live updates?
  final VendorWebhookSupport webhookSupport;

  /// Does the vendor expose a covers / number-of-guests field?
  /// Square / Clover do NOT — the adapter records
  /// `covers_source = forecast_fallback` per the documented degrade
  /// path.
  final bool coversFieldExposed;

  /// Does the vendor require a partnership-program approval before
  /// sandbox / production credentials can be issued? Toast / Aloha /
  /// Oracle MICROS do; Square / Lightspeed-self-serve do not.
  final bool partnershipGated;

  /// Pre-card module disambiguation list. Empty for most vendors;
  /// non-empty for ADP (Workforce Now / Workforce Manager / RUN) and
  /// QuickBooks (Time / Accounting / Payroll). The connect flow
  /// renders a sub-dialog when this is non-empty.
  final List<String> modules;

  /// Identifier of the per-vendor timestamp-policy document this
  /// adapter binds to. Used by Scenario E (ambiguous vendor
  /// timestamp). Implementations either declare a policy or set this
  /// to null and refuse ambiguous timestamps.
  final String? timestampPolicyDocId;
}

/// OAuth (vendor sign-in flow) vs key-paste (legacy auth).
enum VendorAuthMode { oauth, keyPaste, oauthOrKeyPaste }

/// How the vendor scopes a single auth grant.
enum VendorGrantScope {
  /// Each F&F location requires its own separate OAuth flow with
  /// the vendor (Toast, OpenTable).
  perLocation,

  /// A single OAuth grant covers all of the operator's locations on
  /// this vendor (7shifts, Square, QuickBooks Time, ADP Workforce Now).
  operatorWide,
}

/// Whether the vendor supports inbound webhooks.
enum VendorWebhookSupport {
  /// Vendor exposes a webhook subscription API. Auto-register on
  /// connect.
  autoRegister,

  /// Vendor supports webhooks but they must be manually pasted into
  /// the vendor portal (SevenRooms, Tock).
  manualPaste,

  /// Vendor does not document webhook support; adapter is poll-only
  /// (Oracle MICROS Simphony, Humanity v1, Agendrix, Push Operations).
  pollOnly,
}

// ─── Connect ────────────────────────────────────────────────────────

class ConnectCommand {
  const ConnectCommand({
    required this.operatorId,
    required this.locationId,
    required this.actorUserId,
    required this.vendorId,
    this.module,
    this.oauthState,
    this.keyPaste,
  });

  final String operatorId;
  final String locationId;
  final String actorUserId;
  final String vendorId;

  /// Required only when [VendorCapabilityProfile.modules] is non-empty.
  final String? module;

  /// Set on the OAuth callback round trip; the framework verifies
  /// the state token matches the value we issued at start.
  final String? oauthState;

  /// Set on the key-paste flow.
  final ConnectKeyPasteCredential? keyPaste;
}

class ConnectKeyPasteCredential {
  const ConnectKeyPasteCredential({required this.apiKey, this.username});

  final String apiKey;
  final String? username;
}

class ConnectResult {
  const ConnectResult({
    required this.connectionId,
    required this.status,
    required this.metadata,
    this.webhookUrl,
    this.firstBackfillStarted = false,
  });

  /// `connector_connection.connection_id` of the connected row.
  final String connectionId;

  final ConnectionStatus status;

  /// Vendor-side identity binding (Toast `restaurantGuid`, Lightspeed
  /// `business_id`, etc.). Stored in `connector_connection.metadata`.
  final Map<String, Object?> metadata;

  /// Webhook URL the operator can copy. Null when the vendor does
  /// not expose webhooks.
  final String? webhookUrl;

  /// Whether the framework should immediately enqueue a 60-day
  /// backfill. Most adapters return true; `8R.LB` may return false
  /// when the operator chooses to defer history backfill.
  final bool firstBackfillStarted;
}

/// 3-state machine per V1 lean cut. `connecting` and `degraded` are
/// explicit non-goals until monitoring justifies them
/// (`project_v1_lean_scope_cut.md`).
enum ConnectionStatus { connected, disconnected, error }

// ─── Test connection ────────────────────────────────────────────────

class TestConnectionCommand {
  const TestConnectionCommand({
    required this.operatorId,
    required this.locationId,
    required this.actorUserId,
    required this.vendorId,
  });

  final String operatorId;
  final String locationId;
  final String actorUserId;
  final String vendorId;
}

class TestConnectionResult {
  const TestConnectionResult({
    required this.authValid,
    required this.sample,
    required this.fieldMapping,
    required this.elapsedMs,
    this.note,
  });

  final bool authValid;

  /// One real sample entity (order / punch / reservation) the operator
  /// can eyeball to verify field mapping. Vendor-shape JSON; the
  /// admin surface formats it for display.
  final Map<String, Object?> sample;

  /// Canonical field mappings the adapter produced from [sample]
  /// (covers, opened_at, closed_at, etc.). Surfaced in the test
  /// modal so operators see field mapping is working, not just auth.
  final Map<String, Object?> fieldMapping;

  final int elapsedMs;

  /// Optional advisory note (e.g., "Square does not expose covers;
  /// the adapter will record covers_source = forecast_fallback").
  final String? note;
}

// ─── Backfill ───────────────────────────────────────────────────────

class BackfillCommand {
  const BackfillCommand({
    required this.operatorId,
    required this.locationId,
    required this.actorUserId,
    required this.vendorId,
    required this.windowStart,
    required this.windowEnd,
    this.resumeFromCursor,
  });

  final String operatorId;
  final String locationId;
  final String actorUserId;
  final String vendorId;

  /// Inclusive UTC instant marking the start of the backfill window.
  final DateTime windowStart;

  /// Inclusive UTC instant marking the end of the backfill window.
  final DateTime windowEnd;

  /// When set, resume from this vendor cursor instead of starting
  /// over. Honored for Cloud Run Job restart resilience —
  /// `connector_sync_watermark.cursor_token` persists per batch
  /// commit.
  final String? resumeFromCursor;
}

class BackfillResult {
  const BackfillResult({
    required this.batchesCommitted,
    required this.recordsWritten,
    required this.cursorToken,
    required this.lastModifiedSeen,
    this.completed = true,
  });

  final int batchesCommitted;
  final int recordsWritten;

  /// Vendor pagination cursor at the point the backfill stopped.
  /// Persists in `connector_sync_watermark.cursor_token`.
  final String cursorToken;

  /// Vendor "modified since" cursor at the point the backfill
  /// stopped. Persists in `connector_sync_watermark.last_modified_seen`.
  final DateTime lastModifiedSeen;

  /// True when the backfill walked the entire window.
  /// False when the worker stopped mid-window because the Cloud Run
  /// Job hit its execution-time budget. The next invocation resumes
  /// from `cursorToken`.
  final bool completed;
}

// ─── Poll incremental ───────────────────────────────────────────────

class PollIncrementalCommand {
  const PollIncrementalCommand({
    required this.operatorId,
    required this.locationId,
    required this.actorUserId,
    required this.vendorId,
    required this.lastModifiedSeen,
    this.cursorToken,
  });

  final String operatorId;
  final String locationId;
  final String actorUserId;
  final String vendorId;

  /// Vendor "modified since" cursor from the last successful poll.
  final DateTime lastModifiedSeen;

  /// Optional pagination cursor (when the prior poll did not finish
  /// the page chain).
  final String? cursorToken;
}

class PollIncrementalResult {
  const PollIncrementalResult({
    required this.recordsWritten,
    required this.newCursorToken,
    required this.newLastModifiedSeen,
  });

  final int recordsWritten;
  final String newCursorToken;
  final DateTime newLastModifiedSeen;
}

// ─── Webhook ────────────────────────────────────────────────────────

class HandleWebhookCommand {
  const HandleWebhookCommand({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.vendorEventId,
    required this.payload,
    required this.headers,
    required this.receivedAt,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;

  /// Stable vendor-issued event id (e.g. Toast `eventGuid`,
  /// Lightspeed `event_id`, Square `event_id`). The framework keys
  /// idempotency on `(vendor_id, operator_id, vendor_event_id)`.
  final String vendorEventId;

  /// Decoded JSON payload.
  final Map<String, Object?> payload;

  /// All inbound HTTP headers (signature, timestamp, vendor-specific
  /// metadata). Lower-cased keys.
  final Map<String, String> headers;

  /// UTC instant the proxy received the webhook. Used by the
  /// adapter to bucket `business_date` via the IANA converter.
  final DateTime receivedAt;
}

class HandleWebhookResult {
  const HandleWebhookResult({required this.recordsWritten});

  final int recordsWritten;

  // V1 lean cut 2: no parse_partial flag, no parse_warnings JSONB.
  // Malformed payloads are dropped at the adapter boundary and
  // logged via `connector_sync_log` / `inbound_webhook_dead_letter`,
  // not written as canonical facts with a flag.
}

// ─── Disconnect ─────────────────────────────────────────────────────

class DisconnectCommand {
  const DisconnectCommand({
    required this.operatorId,
    required this.locationId,
    required this.actorUserId,
    required this.vendorId,
    required this.reason,
  });

  final String operatorId;
  final String locationId;
  final String actorUserId;
  final String vendorId;

  final DisconnectReason reason;
}

/// Mirrors the `disconnect_reason` enum on `connector_connection`.
/// Operator-facing copy varies per reason (admin-surface UX writing
/// standard) so the operator knows what to do.
///
/// V1 lean cut 2: `autoDisable3Strike` removed. The OAuth refresh
/// cron flips `connector_connection.status = 'error'` on the third
/// consecutive failure with no separate enum value (operator-facing
/// copy is the same regardless of cause; the audit row carries the
/// precise trigger).
enum DisconnectReason {
  operatorAction,
  vendorRevoked,
  vendorEndpointDeprecated,
  oauthTimeout,
}

class DisconnectResult {
  const DisconnectResult({
    required this.credentialsWiped,
    required this.webhookUnregistered,
    required this.watermarkPreserved,
  });

  final bool credentialsWiped;
  final bool webhookUnregistered;
  final bool watermarkPreserved;
}
