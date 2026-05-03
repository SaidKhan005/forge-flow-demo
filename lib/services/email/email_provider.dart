// Forge & Flow — EmailProvider interface.
//
// Phase 9.8 email-provider slice. Server-side transactional email
// abstraction; mirrors the LLMProvider / EmbeddingProvider shape
// locked by Hard Promise #8 in CLAUDE.md so a future Postmark / SES
// swap is purely additive (drop in a new concrete adapter that
// implements [EmailProvider], rebind in the proxy bootstrap, no
// caller changes).
//
// Provider decision: SendGrid (see
// `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md`).
//
// Send semantics:
//   * The proxy hands a [EmailSendRequest] to the provider with
//     fully-rendered subject + HTML + text. Template rendering lives
//     in [EmailTemplateRenderer] so the provider never sees template
//     IDs or raw Markdown — exchanging providers does not change the
//     template surface.
//   * The provider returns [EmailSendResult] carrying the provider's
//     own message id (SendGrid `X-Message-Id`) plus status. The
//     `email_outbox.provider_message_id` column persists the value so
//     follow-up status checks and webhook events can join back to the
//     row.
//   * The provider classifies failures via [EmailProviderException]
//     so the dispatcher can decide retry vs. dead-letter without
//     pattern-matching HTTP error strings.
//
// Hard constraints:
//   * Plaintext API keys NEVER live in this seam. The dispatcher
//     fetches the active key from `email_credentials` (pgcrypto
//     envelope on staging; KMS on production once 8.0's KMS rollout
//     lands) and hands the resolved string to the provider per call.
//     Concrete adapters MUST NOT cache the key longer than one
//     request lifetime.
//   * Per Hard Promise #7 (server-side keys only), this seam is
//     proxy-only. No Flutter client ever constructs an EmailProvider.

import 'dart:async';

/// Locked recipient kind. Today the dispatcher always sends a
/// single-recipient transactional email; bulk / marketing fan-out
/// is V2 scope.
class EmailRecipient {
  const EmailRecipient({
    required this.email,
    this.displayName,
  });

  /// Recipient email address. Validated by the dispatcher (RFC 5322
  /// pragmatic subset) before reaching the provider.
  final String email;

  /// Optional display name. When present the provider renders
  /// `Display Name <email@example.com>` in the `To:` header; when
  /// null the bare address is used.
  final String? displayName;

  @override
  String toString() => displayName == null ? email : '$displayName <$email>';
}

/// One transactional email send request. Subject + HTML + text are
/// already rendered — see [EmailTemplateRenderer] for the
/// Markdown→HTML pipeline. The provider's job is solely transport.
class EmailSendRequest {
  const EmailSendRequest({
    required this.to,
    required this.subject,
    required this.htmlBody,
    required this.textBody,
    required this.fromAddress,
    required this.fromDisplayName,
    this.replyToAddress,
    this.providerMetadata = const <String, String>{},
  });

  final EmailRecipient to;
  final String subject;
  final String htmlBody;

  /// Plaintext fallback body. Required so spam filters and clients
  /// that disable HTML still see the message; SendGrid additionally
  /// uses this for the auto-generated preview snippet.
  final String textBody;

  /// Verified sender address. Production binds this to
  /// `noreply@mail.forgeflow.app`; staging may use the SendGrid
  /// sandbox sender.
  final String fromAddress;
  final String fromDisplayName;

  /// Optional `Reply-To`. Default is the from address.
  final String? replyToAddress;

  /// Provider-specific tagging (e.g. SendGrid custom args). Carries
  /// our internal `email_id` and `template_id` so webhook events can
  /// be joined back to `email_outbox` without parsing the message id.
  final Map<String, String> providerMetadata;
}

/// Successful send envelope. Status is always `accepted` from the
/// HTTP response — actual delivery comes asynchronously through the
/// SendGrid event webhook and lands in `email_event`.
class EmailSendResult {
  const EmailSendResult({
    required this.providerMessageId,
    required this.acceptedAt,
  });

  /// SendGrid `X-Message-Id` (or equivalent) returned on a 202
  /// Accepted response. Persisted in
  /// `email_outbox.provider_message_id` so the webhook handler can
  /// join inbound delivery events to the queued row.
  final String providerMessageId;

  /// Server-side timestamp the dispatcher recorded when the provider
  /// returned 2xx. Used for the `email_outbox.last_attempt_at`
  /// stamp.
  final DateTime acceptedAt;
}

/// Status of one previously-sent message, polled on demand. Webhook
/// delivery is the durable path; this method exists so the admin
/// "test connection" surface can confirm acceptance without waiting
/// for the webhook round trip.
class EmailDeliveryStatus {
  const EmailDeliveryStatus({
    required this.providerMessageId,
    required this.statusKind,
    required this.checkedAt,
    this.detail,
  });

  final String providerMessageId;
  final EmailDeliveryStatusKind statusKind;
  final DateTime checkedAt;
  final String? detail;
}

enum EmailDeliveryStatusKind {
  /// Provider acknowledged the request but has not yet attempted
  /// delivery. Default state right after [EmailProvider.send].
  accepted,

  /// Provider successfully handed the message to the recipient MTA.
  /// Surfaces in webhook events; [EmailProvider.getDeliveryStatus]
  /// returns this when a polled check sees it.
  delivered,

  /// Recipient's MTA bounced. Final state.
  bounced,

  /// Recipient flagged as spam / complaint. Final state.
  complaint,

  /// Provider does not have telemetry for this message id (e.g. the
  /// id has aged out of the provider's retention window). The
  /// dispatcher treats this as `unknown`, not `failed`.
  unknown,
}

/// Failure taxonomy. The dispatcher decides retry vs. dead-letter
/// based on [EmailFailureKind].
enum EmailFailureKind {
  /// Connection / DNS / TLS error before the request reached the
  /// provider. Always retryable; counts toward the 3-strike retry
  /// limit.
  network,

  /// Provider returned 5xx. Retryable; counts toward the limit.
  providerInternal,

  /// Provider returned 429 (rate limit). Retryable with backoff;
  /// the dispatcher honours the `Retry-After` header when present.
  providerRateLimit,

  /// Provider returned 4xx (other than 429). Not retryable —
  /// usually a malformed request or rejected sender. Dispatcher
  /// dead-letters immediately.
  providerBadRequest,

  /// Provider returned 401/403 (auth). Not retryable. Surfaces an
  /// admin alert because a bad credential needs rotation, not retry.
  providerAuth,

  /// Provider response could not be parsed. Not retryable; dispatcher
  /// dead-letters and the unparseable body lands in
  /// `email_outbox.last_error`.
  providerProtocol,

  /// Catch-all for unknown shapes. Counts toward the retry limit so
  /// transient unrecognised failures do not strand emails.
  unknown,
}

/// Exception thrown by concrete [EmailProvider] adapters when a send
/// or status call fails. Wraps HTTP / network errors in a typed
/// shape so the dispatcher can branch on [kind] without parsing
/// strings.
class EmailProviderException implements Exception {
  const EmailProviderException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.retryAfter,
  });

  final EmailFailureKind kind;
  final String message;
  final int? statusCode;

  /// Honoured by the dispatcher's backoff schedule when the provider
  /// returns a 429 with `Retry-After`. Null when not applicable.
  final Duration? retryAfter;

  @override
  String toString() =>
      'EmailProviderException(${kind.name}, status=$statusCode): $message';
}

/// Server-side transactional email seam. Concrete adapters live
/// alongside this file (`sendgrid_email_provider.dart`); the proxy
/// bootstrap binds exactly one at startup.
abstract class EmailProvider {
  /// Stable provider id (e.g. `sendgrid`). Used for telemetry and
  /// for cross-checks against the active credential's
  /// `provider_kind`.
  String get providerId;

  /// Send one transactional email through the provider. Returns the
  /// provider's own message id on 2xx. Throws
  /// [EmailProviderException] on failure with a typed [EmailFailureKind].
  Future<EmailSendResult> send(EmailSendRequest request);

  /// Look up the delivery status for a previously-sent message. The
  /// proxy's "Test connection" surface uses this to confirm provider
  /// reachability without waiting for the webhook round trip.
  Future<EmailDeliveryStatus> getDeliveryStatus(String providerMessageId);
}

/// Map a thrown error to an [EmailFailureKind] for dispatcher
/// retry / dead-letter accounting. Unknown shapes count toward the
/// retry limit so transient unrecognised failures do not strand
/// emails.
EmailFailureKind classifyEmailFailure(Object error) {
  if (error is EmailProviderException) {
    return error.kind;
  }
  if (error is TimeoutException) {
    return EmailFailureKind.network;
  }
  return EmailFailureKind.unknown;
}
