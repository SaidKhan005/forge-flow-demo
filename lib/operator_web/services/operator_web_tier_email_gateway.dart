// Wave 2 U-FU-tier-email — Operator Web data freshness tier-email gateway.
//
// Wires the "Request faster data freshness" dialog on the Operator Web
// Console Data Accuracy screen to a server-side SendGrid send. Two
// concrete implementations:
//
//   * [OperatorWebHttpTierEmailGateway] — production. POSTs to
//     `/v1/operator/tier-email/data-freshness-request` through
//     [OperatorWebProxyClient]. The proxy emits a hash-chained audit
//     row (source of truth) and attempts a SendGrid send to
//     `support@forgeflow.org`.
//   * [InMemoryOperatorWebTierEmailGateway] — demo / widget tests. No
//     network call. Returns a synthetic success envelope so the
//     kDemoMode walkthrough exercises the same UI path without
//     touching SendGrid (Hard Promise #2 parity).
//
// Failure posture:
//   * 200 + `{ ok: true, ... }` → email queued + audit row written.
//     Dialog shows the green "submitted and emailed" toast.
//   * 502 `email_send_failed` → audit row written, SendGrid rejected
//     or errored. Dialog shows the muted "submitted to F&F support"
//     toast (request is still durable; F&F support picks it up off
//     the audit log).
//   * Any other non-2xx → dialog shows the muted toast but treats it
//     as a non-fatal error so the operator never sees a red banner
//     on a best-effort surface.

import 'operator_web_proxy_client.dart';

class OperatorTierEmailRequest {
  const OperatorTierEmailRequest({
    required this.currentTier,
    required this.requestedCadence,
    required this.businessReason,
  });

  final String currentTier;
  final String requestedCadence;
  final String businessReason;

  Map<String, Object?> toJson() => <String, Object?>{
        'current_tier': currentTier,
        'requested_cadence': requestedCadence,
        'business_reason': businessReason,
      };
}

class OperatorTierEmailResult {
  const OperatorTierEmailResult({
    required this.kind,
    this.providerMessageId,
    this.errorMessage,
  });

  final OperatorTierEmailResultKind kind;
  final String? providerMessageId;
  final String? errorMessage;
}

enum OperatorTierEmailResultKind {
  /// Audit row written + SendGrid accepted the message.
  emailSent,

  /// Audit row written, SendGrid rejected / errored.
  emailFailed,

  /// The proxy could not write the audit row OR the network never
  /// reached the proxy.
  submitFailed,
}

abstract class OperatorWebTierEmailGateway {
  Future<OperatorTierEmailResult> submitDataFreshnessRequest({
    required OperatorTierEmailRequest request,
    required String idempotencyKey,
  });
}

class OperatorWebHttpTierEmailGateway implements OperatorWebTierEmailGateway {
  OperatorWebHttpTierEmailGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
  })  : _client = client,
        _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  static const String dataFreshnessRequestPath =
      '/v1/operator/tier-email/data-freshness-request';

  @override
  Future<OperatorTierEmailResult> submitDataFreshnessRequest({
    required OperatorTierEmailRequest request,
    required String idempotencyKey,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.isEmpty) {
      return const OperatorTierEmailResult(
        kind: OperatorTierEmailResultKind.submitFailed,
        errorMessage: 'missing_id_token',
      );
    }
    try {
      final response = await _client.postJson(
        dataFreshnessRequestPath,
        idToken: token,
        body: request.toJson(),
        extraHeaders: <String, String>{'Idempotency-Key': idempotencyKey},
      );
      final body = response.body;
      if (body['ok'] == true) {
        final providerMessageId = body['provider_message_id'];
        return OperatorTierEmailResult(
          kind: OperatorTierEmailResultKind.emailSent,
          providerMessageId:
              providerMessageId is String ? providerMessageId : null,
        );
      }
      return OperatorTierEmailResult(
        kind: OperatorTierEmailResultKind.emailFailed,
        errorMessage: body['message']?.toString() ?? 'unexpected_envelope',
      );
    } on OperatorWebProxyException catch (error) {
      if (error.code == 'email_send_failed') {
        return OperatorTierEmailResult(
          kind: OperatorTierEmailResultKind.emailFailed,
          errorMessage: error.message,
        );
      }
      return OperatorTierEmailResult(
        kind: OperatorTierEmailResultKind.submitFailed,
        errorMessage: '${error.code}: ${error.message}',
      );
    } catch (error) {
      return OperatorTierEmailResult(
        kind: OperatorTierEmailResultKind.submitFailed,
        errorMessage: error.toString(),
      );
    }
  }
}

class InMemoryOperatorWebTierEmailGateway
    implements OperatorWebTierEmailGateway {
  InMemoryOperatorWebTierEmailGateway({
    OperatorTierEmailResultKind defaultKind =
        OperatorTierEmailResultKind.emailSent,
    String defaultProviderMessageId = 'demo-message-id',
  })  : _defaultKind = defaultKind,
        _defaultProviderMessageId = defaultProviderMessageId;

  final OperatorTierEmailResultKind _defaultKind;
  final String _defaultProviderMessageId;

  final List<OperatorTierEmailRequest> submissions =
      <OperatorTierEmailRequest>[];
  final List<String> idempotencyKeys = <String>[];

  @override
  Future<OperatorTierEmailResult> submitDataFreshnessRequest({
    required OperatorTierEmailRequest request,
    required String idempotencyKey,
  }) async {
    submissions.add(request);
    idempotencyKeys.add(idempotencyKey);
    return OperatorTierEmailResult(
      kind: _defaultKind,
      providerMessageId: _defaultKind == OperatorTierEmailResultKind.emailSent
          ? _defaultProviderMessageId
          : null,
    );
  }
}
