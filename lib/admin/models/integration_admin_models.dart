// Phase 11A.4 - Integration management value objects.
//
// Value objects backing the F&F Operations Console "Integrations"
// surface: provider key rotation (Anthropic, Voyage, Azure DB) plus
// status placeholders for vendor connectors (Phase 8), the FX-rate
// source, and the email provider (Phase 9.8). Every shape mirrors
// the proxy contract in `tool/advisor_proxy/advisor_proxy.dart` 11A.4
// route handlers; the Flutter admin client never reaches Postgres
// directly.
//
// Hard constraint: plaintext keys are NEVER stored in any of these
// shapes. Every list/refresh response returns only [maskedValue].
// The plaintext field on a rotation response (`plaintext_value`) is
// surfaced ONCE through the dedicated [RotateKeyResult]; subsequent
// reads return the masked-only [ProviderKeyRow].

import 'package:flutter/foundation.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_models.dart'
    show VendorCategory;

/// Stable string identifying one of the rotatable provider lanes.
/// Mirrors the database `key_kind` CHECK constraint and the proxy's
/// validation set.
enum ProviderKeyKind {
  anthropic('anthropic', 'Anthropic API'),
  voyage('voyage', 'Voyage embeddings'),
  azureDb('azure_db', 'Azure DB superuser'),
  gemini('gemini', 'Gemini API'),
  // Phase 9.8 - SendGrid joins the rotatable provider lanes alongside
  // Anthropic / Voyage / Azure DB / Gemini. The wire name + display
  // name follow the established pattern; the ledger is backed by
  // public.email_credentials (separate table because the SendGrid
  // key is platform-wide and the rotation contract is identical to
  // provider_credentials but kept distinct so a future Postmark / SES
  // swap is purely additive).
  sendgrid('sendgrid', 'SendGrid email');

  const ProviderKeyKind(this.wireName, this.displayName);

  final String wireName;
  final String displayName;

  static ProviderKeyKind fromWire(String wire) {
    for (final k in ProviderKeyKind.values) {
      if (k.wireName == wire) return k;
    }
    throw ArgumentError('unknown provider key kind: $wire');
  }
}

/// One row of the masked-display ledger. Carries audit metadata
/// (`createdBy` + `rotatedAt`) so the admin console can show which
/// F&F operator rotated the key and when. Plaintext is intentionally
/// absent from this shape.
@immutable
class ProviderKeyRow {
  const ProviderKeyRow({
    required this.credentialId,
    required this.keyKind,
    required this.maskedValue,
    required this.kmsSecretName,
    required this.createdBy,
    required this.updatedBy,
    required this.rotatedAt,
  });

  final String credentialId;
  final ProviderKeyKind keyKind;
  final String maskedValue;

  /// Opaque KMS pointer (e.g. `kms://stub/<uuid>`). The admin
  /// console renders this as a debug-only tag - the operator never
  /// uses it directly.
  final String kmsSecretName;

  final String? createdBy;
  final String? updatedBy;
  final DateTime rotatedAt;

  /// Convenience alias used in widget keys / fixtures.
  String get keyKindWire => keyKind.wireName;

  static ProviderKeyRow fromJson(Map<String, Object?> json) {
    return ProviderKeyRow(
      credentialId: json['credential_id']! as String,
      keyKind: ProviderKeyKind.fromWire(json['key_kind']! as String),
      maskedValue: json['masked_value']! as String,
      kmsSecretName: json['kms_secret_name']! as String,
      createdBy: json['created_by'] as String?,
      updatedBy: json['updated_by'] as String?,
      rotatedAt: DateTime.parse(json['rotated_at']! as String),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'credential_id': credentialId,
    'key_kind': keyKind.wireName,
    'masked_value': maskedValue,
    'kms_secret_name': kmsSecretName,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'rotated_at': rotatedAt.toUtc().toIso8601String(),
  };
}

/// Status row for a non-rotatable integration (vendor connectors,
/// FX-rate source, email provider). Drives the placeholder rows on
/// the Integrations screen.
@immutable
class VendorConnectorStatus {
  const VendorConnectorStatus({
    required this.id,
    required this.displayName,
    required this.statusLabel,
    required this.detailMessage,
    this.category,
    this.apiReachable,
    this.healthSourceLabel,
    this.unlockLabel,
  });

  final String id;
  final String displayName;
  final String statusLabel;
  final String detailMessage;

  /// POS / labor / reservation grouping for vendor connector rows.
  /// Null for non-vendor shared services such as FX rates and email.
  final VendorCategory? category;

  /// Whether the live setup API is reachable for this vendor. Null
  /// means the payload did not expose a reachability signal and the
  /// gateway should derive the display conservatively from the legacy
  /// status label.
  final bool? apiReachable;

  /// Plain-English source for [apiReachable], for example a live API
  /// probe, a mocked gateway seam, or a lifecycle projection.
  final String? healthSourceLabel;

  /// Plain-English setup availability derived from API reachability.
  final String? unlockLabel;
}

/// Convenience alias for FX-rate / email provider status placeholders.
typedef FxRateSourceStatus = VendorConnectorStatus;

/// One bundled response shape returned by `GET /v1/admin/integrations`.
/// Carries every row the screen renders in a single payload.
@immutable
class IntegrationBundle {
  const IntegrationBundle({
    required this.providerKeys,
    required this.vendorConnectors,
    required this.fxRateSource,
    required this.emailProvider,
  });

  final List<ProviderKeyRow> providerKeys;
  final List<VendorConnectorStatus> vendorConnectors;
  final FxRateSourceStatus fxRateSource;
  final VendorConnectorStatus emailProvider;
}

/// Mirror of `provider_keys` masked rows used in `IntegrationBundle`
/// when callers want a tighter type than `List<ProviderKeyRow>`. The
/// 11A.4 prompt explicitly names this in Block 3 alongside
/// `ProviderKeyRow`; carrying the alias keeps callers (gateway
/// implementations, tests) free to type the same value either way.
typedef KeyMaskedRow = ProviderKeyRow;

/// Rotate one provider lane. Carries the plaintext value the F&F
/// admin pasted into the rotation modal. The gateway hands plaintext
/// to the proxy over TLS; the proxy hands plaintext to the KMS
/// provider, persists only the masked display + KMS pointer, and
/// returns the plaintext ONCE through the rotation response so the
/// admin can verify it before closing the reveal modal.
@immutable
class RotateKeyCommand {
  const RotateKeyCommand({
    required this.keyKind,
    required this.plaintextValue,
    required this.idempotencyKey,
  });

  final ProviderKeyKind keyKind;
  final String plaintextValue;

  /// Per-action idempotency key. The proxy stores it in
  /// `admin_request_idempotency` so a retried POST collapses to one
  /// KMS write + one audit row instead of stamping a duplicate
  /// rotation.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'plaintext_value': plaintextValue,
  };
}

/// Result of a successful rotation. The admin console renders
/// [plaintextValue] ONCE inside a modal that cannot be reopened; the
/// list grid only ever shows [row.maskedValue].
@immutable
class RotateKeyResult {
  const RotateKeyResult({required this.row, required this.plaintextValue});

  final ProviderKeyRow row;

  /// One-time plaintext echo. Empty string when the proxy returned
  /// only a masked row (defensive - the proxy contract requires
  /// plaintext on a rotate response, but we treat the absence as a
  /// hard failure rather than silently surfacing nothing).
  final String plaintextValue;

  static RotateKeyResult fromJson(Map<String, Object?> json) {
    final row = ProviderKeyRow.fromJson(
      (json['row'] as Map).cast<String, Object?>(),
    );
    final plaintext = json['plaintext_value'] as String?;
    return RotateKeyResult(row: row, plaintextValue: plaintext ?? '');
  }
}
