// Forge & Flow — graceful refusal payload for breaker-open requests.
//
// Lock 7 tertiary fallback. Returned at HTTP 200 with a `degraded`
// envelope so clients can render the cached answer (when present) plus
// a "service degraded" banner without triggering generic 5xx error UX.
// Mirrors the 402 cap-status pattern at `advisor_proxy.dart:5223-5229`.
//
// Block 2 v1: do not edit `gracefulRefusalMessage` without a Lock-7
// amend. The fallback_chain_test asserts byte-equality.

const String gracefulRefusalMessage =
    'Service is temporarily degraded. Please try again shortly. '
    'If a recent cached answer is available it will be returned in the '
    "'cached_answer' field below.";

class GracefulRefusalResponse {
  const GracefulRefusalResponse({
    required this.cachedAnswer,
    required this.providerId,
    required this.circuitState,
    this.retryAfterSeconds = 30,
  });

  final String? cachedAnswer;
  final String providerId;
  final String circuitState;
  final int retryAfterSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'error': 'service_degraded',
    'message': gracefulRefusalMessage,
    'degraded': <String, Object?>{
      'provider_id': providerId,
      'circuit_state': circuitState,
      'cached_answer': cachedAnswer,
      'retry_after_seconds': retryAfterSeconds,
    },
  };
}
