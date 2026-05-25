// Slice A4-ENC — proxy-side concrete resolver for the advisor
// conversation CMK (gated-inert, ENCRYPTION-FIRST).
//
// Bridges `ProxyConfig` (which holds the optional
// `ADVISOR_CONVERSATION_CMK` secret) to the app-library
// `AdvisorConversationCmkResolver` abstraction so the encryptor in
// `lib/infrastructure/crypto/advisor_conversation_envelope.dart` has
// no dependency on the proxy. The encryptor stays in the app library;
// only the secret-reading glue lives here.
//
// Gated-inert / fail-closed: this resolver is constructed ONLY when
// the optional secret is provisioned (see [tryCreate]). When the
// secret is absent the factory returns `null` and the answer endpoint
// (A4.2) declines to build the encryptor — there is no path that
// encrypts (or persists) an advisor turn without a key. The proxy
// boots either way because the secret is OPTIONAL, not required.
//
// Hard Promise #7: the base64-decoded key bytes live only inside
// `resolve()` for the duration of one encrypt call. They are never
// stored on a field of this resolver, never logged, and never placed
// in an exception message or `toString()`. This object holds only the
// `ProxyConfig` handle (which itself guards its secrets behind
// `secretFor` and never echoes them) and the stable key reference
// string.

import 'dart:convert';

import 'package:forge_and_flow/infrastructure/crypto/advisor_conversation_envelope.dart';

import 'advisor_proxy.dart' show ProxyConfig, ProxySecretNames;

/// Stable `content_key_ref` recorded on every row this CMK encrypts.
/// Versioned so a future key rotation lands as `.../cmk/v2` without
/// rewriting historical rows (matches the contract example referenced
/// in `advisor_conversation_log_repository.dart`).
const String advisorConversationCmkKeyRef = 'kv://forge-flow/cmk/v1';

/// Reads the optional `ADVISOR_CONVERSATION_CMK` secret (a base64
/// encoding of the 32-byte AES-256 key) from [ProxyConfig] and exposes
/// it through the app-library [AdvisorConversationCmkResolver]
/// abstraction.
///
/// Construct via [tryCreate], which returns `null` when the secret is
/// not provisioned — so the gated-inert wiring never builds an
/// encryptor it cannot key.
class ProxyAdvisorConversationCmkResolver
    implements AdvisorConversationCmkResolver {
  ProxyAdvisorConversationCmkResolver._(this._config);

  /// Returns a resolver when `ADVISOR_CONVERSATION_CMK` is present,
  /// otherwise `null`. Presence is checked with
  /// [ProxyConfig.hasSecretFor] so a missing secret is NOT a startup
  /// error — the proxy keeps booting and the answer endpoint simply
  /// fails closed (no key → no encryptor → no answer).
  static ProxyAdvisorConversationCmkResolver? tryCreate(ProxyConfig config) {
    if (!config.hasSecretFor(ProxySecretNames.advisorConversationCmk)) {
      return null;
    }
    return ProxyAdvisorConversationCmkResolver._(config);
  }

  final ProxyConfig _config;

  /// Base64-decodes the secret to the live 32-byte key and pairs it
  /// with the stable key reference. The key bytes are produced fresh
  /// on each call and are never retained on this instance; the
  /// envelope encryptor consumes them for one encrypt and drops them.
  ///
  /// Length validation lives in the encryptor
  /// ([AdvisorConversationEnvelope] throws a typed,
  /// byte-omitting error if the decoded key is not 32 bytes), so this
  /// method does not duplicate or echo the key material.
  @override
  ({List<int> keyBytes, String keyRef}) resolve() {
    final base64Key = _config.secretFor(
      ProxySecretNames.advisorConversationCmk,
    );
    final keyBytes = base64.decode(base64Key);
    return (keyBytes: keyBytes, keyRef: advisorConversationCmkKeyRef);
  }

  // toString stays the default "Instance of '...'" — we deliberately
  // do NOT echo the config, the secret, or the key reference so a
  // resolver that lands in a log line cannot disclose anything.
}
