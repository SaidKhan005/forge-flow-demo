// Lane C C-1 — SendGrid Event Webhook receiver.
//
// Route:
//   POST /v1/webhooks/sendgrid/events
//
// What this surface does:
//   * Reads the raw request body (bytes) BEFORE JSON decoding so the
//     ECDSA signature is verified against the exact bytes SendGrid
//     signed — common SendGrid integration pitfall is to decode +
//     re-serialise, which produces a different byte sequence and a
//     spurious signature mismatch.
//   * Loads the ECDSA P-256 public key from the env var
//     `SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM`. Per Hard Promise #7 the key
//     lives server-side only; clients never see it. Per slice prompt
//     V1 scope, env var is the ONLY source for the pubkey; the
//     deferred `email_credentials` column path is a future enhancement
//     (see Block 2 / slice prompt).
//   * If the env var is unset → 503 `pubkey_not_configured`. The
//     SendGrid retry policy (exponential backoff for 5xx) keeps the
//     event safely queued upstream while operators configure the
//     pubkey.
//   * Verifies the `X-Twilio-Email-Event-Webhook-Signature` header
//     against `timestamp + raw_body`, where `timestamp` is the
//     `X-Twilio-Email-Event-Webhook-Timestamp` header value. SendGrid
//     spec: ECDSA-SHA256 over the concatenation
//     `timestamp_header_value + raw_body_string`, signature is
//     base64-encoded DER-format ECDSA signature, pubkey is on the
//     secp256r1 (P-256) curve.
//   * On signature failure → 401 `bad_signature`. SendGrid retries
//     5xx and gives up after persistent 4xx, so a misconfigured
//     pubkey + valid traffic returns 401 (signaling "this proxy is
//     wired against the wrong key") rather than 5xx (signaling
//     "transient — retry"). Operator playbook step is to fix the
//     pubkey env var.
//   * On valid signature: decode JSON body; expect an array of event
//     objects. For each entry, [SendGridEvent.fromJson] + repository
//     insert with `ON CONFLICT (provider_event_id) DO NOTHING`. A
//     malformed entry (parser failure) collapses the entire batch
//     into 400 `malformed_event` so SendGrid is signalled to investigate
//     upstream rather than re-deliver a poison-pill body forever.
//   * On overall success: 204 No Content. Per SendGrid spec, the
//     webhook is fire-and-forget; the response body is ignored, so we
//     return 204 to keep proxy bytes-out minimal. The 204 fires even
//     when every event in the batch was a duplicate (`ON CONFLICT DO
//     NOTHING` is the success path).
//
// Auth posture:
//   * NO permission key. SendGrid is an external server-to-server
//     caller; no Firebase JWT and no `permission_keys.dart` gate
//     apply. The route is auth-gated by ECDSA signature verification
//     ONLY.
//   * Therefore the route is mounted as a pre-check in `main.dart`
//     BEFORE `routeRequest`, so the monolithic dispatcher's
//     auth/scope path never runs for this URL. The slice deliberately
//     keeps mounting OUT of `tool/advisor_proxy/advisor_proxy.dart`
//     to avoid bleed-stop monolith growth.
//
// Audit-row policy:
//   * NO audit_logs writes from this route. The `email_event` row IS
//     the audit trail for inbound provider events; emitting an
//     audit_logs row per event would be noise (and would inflate the
//     audit chain enormously — SendGrid emits ~3-5 events per send).
//   * Worker self-audit lens "Observability surfaces" calls this out
//     explicitly. The choice is documented here so a future audit
//     does not flag it as a regression.
//
// CLAUDE.md compliance:
//   * Hard Promise #4 (per-operator isolation): the receiver is
//     platform-internal — the inbound event has no operator scope
//     until it joins back to `email_outbox`. The repository's
//     `withSystem` discipline carries a stable audit reason so the
//     bypass is traceable.
//   * Hard Promise #7 (server-side keys): the ECDSA pubkey loads from
//     a server-side env var; clients never see it.
//   * Proxy & API Conventions — "every proxy write is idempotent":
//     idempotency is enforced server-side via the partial UNIQUE
//     INDEX. SendGrid does not supply an `Idempotency-Key` header;
//     `provider_event_id` (= `sg_event_id`) is the equivalent.
//   * Service-Layer Split: this file lives in `tool/advisor_proxy/`,
//     so `package:postgres` is allowed transitively through the
//     repository.
//
// Idempotency contract:
//   * `ON CONFLICT (provider_event_id) WHERE provider_event_id IS NOT
//     NULL DO NOTHING` against the partial UNIQUE INDEX
//     `email_event_provider_event_id_unique`. SendGrid replays a
//     batch on operator 5xx; replays land harmlessly.
//   * Within one batch, two events with the same `sg_event_id` would
//     collide on the second insert; the route is per-event so the
//     duplicate maps to `EmailEventInsertResult.duplicate` and the
//     batch continues.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/pointycastle.dart' as pc;

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/email_event_repository.dart';
import 'package:forge_and_flow/services/email/sendgrid_event_payload.dart';

import 'log.dart';

/// Path the SendGrid Event Webhook posts events to.
const String sendGridEventsWebhookPath = '/v1/webhooks/sendgrid/events';

/// SendGrid header carrying the ECDSA signature over
/// `timestamp + raw_body`. Base64-encoded DER ECDSA signature.
const String kSendGridSignatureHeader =
    'x-twilio-email-event-webhook-signature';

/// SendGrid header carrying the unix-seconds timestamp used as the
/// signature input prefix. The receiver concatenates this with the
/// raw body bytes before verifying.
const String kSendGridTimestampHeader =
    'x-twilio-email-event-webhook-timestamp';

/// Env var the receiver loads the ECDSA P-256 verifier pubkey from.
/// PEM-encoded `SubjectPublicKeyInfo` (or `PUBLIC KEY` block).
///
/// Per Hard Promise #7 — server-side only. The deployed Cloud Run
/// service consumes this via Secret Manager binding in production.
const String kSendGridPubKeyEnvVar = 'SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM';

/// Maximum raw-body byte length we admit. SendGrid documents the
/// webhook payload as "up to 30 events per request"; each event is
/// well under 4 KB, so 1 MB is a comfortable upper bound that still
/// rejects a malicious 100 MB body before any parsing.
const int kSendGridMaxBodyBytes = 1 * 1024 * 1024;

/// Production audit + logging hook seam so tests can swap in a
/// recording fake. In production the proxy logs structured errors;
/// tests can capture them.
abstract class SendGridEventsWebhookObserver {
  void onSignatureFailure({
    required String reason,
    required String? bodyShape,
  });

  void onParseFailure({
    required String field,
    required String message,
    required int eventIndex,
  });

  void onBatchProcessed({
    required int inserted,
    required int duplicates,
  });
}

/// No-op observer used when the proxy starts without a wired
/// observer. Production wires a logging observer in
/// `proxy_bootstrap.dart`.
class NoopSendGridEventsWebhookObserver
    implements SendGridEventsWebhookObserver {
  const NoopSendGridEventsWebhookObserver();

  @override
  void onSignatureFailure({
    required String reason,
    required String? bodyShape,
  }) {}

  @override
  void onParseFailure({
    required String field,
    required String message,
    required int eventIndex,
  }) {}

  @override
  void onBatchProcessed({
    required int inserted,
    required int duplicates,
  }) {}
}

/// Production observer — fans every notable event into the proxy's
/// structured logger. Mirrors the `proxy.auth_handoff_audit_failed`
/// shape used by `ProductionHandoffAuditSink`'s onError closure.
class LoggingSendGridEventsWebhookObserver
    implements SendGridEventsWebhookObserver {
  const LoggingSendGridEventsWebhookObserver();

  @override
  void onSignatureFailure({
    required String reason,
    required String? bodyShape,
  }) {
    log(
      LogSeverity.warning,
      'sendgrid_events_webhook.signature_failure',
      fields: <String, Object?>{
        'reason': reason,
        if (bodyShape != null) 'body_shape': bodyShape,
      },
    );
  }

  @override
  void onParseFailure({
    required String field,
    required String message,
    required int eventIndex,
  }) {
    log(
      LogSeverity.warning,
      'sendgrid_events_webhook.parse_failure',
      fields: <String, Object?>{
        'field': field,
        'message': message,
        'event_index': eventIndex,
      },
    );
  }

  @override
  void onBatchProcessed({
    required int inserted,
    required int duplicates,
  }) {
    log(
      LogSeverity.info,
      'sendgrid_events_webhook.batch_processed',
      fields: <String, Object?>{
        'inserted': inserted,
        'duplicates': duplicates,
      },
    );
  }
}

/// Loader closure for the ECDSA pubkey. The router calls this on
/// every request so a runtime pubkey rotation can take effect without
/// a proxy restart (production wires it to a memoizing Secret Manager
/// reader; tests wire it to a pinned literal).
typedef SendGridPubKeyLoader = String? Function();

/// Default loader — reads the env var. Returns null when unset / empty
/// so the route can return 503 `pubkey_not_configured`.
String? defaultSendGridPubKeyLoader() {
  final raw = Platform.environment[kSendGridPubKeyEnvVar];
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

/// ECDSA P-256 signature verifier seam. The production implementation
/// is backed by pointycastle (already in pubspec for the proxy's
/// existing RS256 JWT verifier); tests can swap a deterministic stub.
abstract class SendGridSignatureVerifier {
  /// Verify [signatureBase64] (DER ECDSA over P-256, base64-encoded)
  /// against the concatenation `timestamp + body`, given a PEM-
  /// encoded SubjectPublicKeyInfo pubkey. Returns true on a valid
  /// signature; false on any failure (bad input, wrong curve, bad
  /// signature, etc.).
  bool verify({
    required String pemPubKey,
    required String timestamp,
    required Uint8List body,
    required String signatureBase64,
  });
}

/// Production verifier — pointycastle-backed ECDSA over P-256 with
/// SHA-256 digest. Mirrors the structure of
/// `PointyCastleRs256SignatureValidator` in `advisor_proxy.dart`.
class PointyCastleSendGridSignatureVerifier
    implements SendGridSignatureVerifier {
  const PointyCastleSendGridSignatureVerifier();

  @override
  bool verify({
    required String pemPubKey,
    required String timestamp,
    required Uint8List body,
    required String signatureBase64,
  }) {
    try {
      final pubKey = _decodeP256PubKey(pemPubKey);
      final signatureBytes = base64Decode(signatureBase64);
      final ecSignature = _decodeDerEcdsaSignature(signatureBytes);
      if (ecSignature == null) return false;
      final signedInput = _concatTimestampAndBody(timestamp, body);
      final verifier = pc.Signer('SHA-256/ECDSA')
        ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pubKey));
      return verifier.verifySignature(signedInput, ecSignature);
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    } on Exception {
      // pointycastle ASN.1 parse errors / curve mismatches / etc.
      // Collapse everything that is not a programming-error into a
      // clean `false`. `Error`s such as RangeError still propagate
      // so we see real bugs in CI.
      return false;
    }
  }

  static Uint8List _concatTimestampAndBody(String timestamp, Uint8List body) {
    final ts = utf8.encode(timestamp);
    final builder = BytesBuilder(copy: false)
      ..add(ts)
      ..add(body);
    return builder.takeBytes();
  }

  static pc.ECPublicKey _decodeP256PubKey(String pem) {
    final block = _decodePemBlock(pem);
    if (block.label != 'PUBLIC KEY') {
      throw FormatException('SendGrid pubkey PEM must be a PUBLIC KEY block (was ${block.label})');
    }
    final parser = pc.ASN1Parser(block.bytes);
    final dynamic next = parser.nextObject();
    if (next is! pc.ASN1Sequence) {
      throw const FormatException(
          'SendGrid pubkey is not an ASN.1 SubjectPublicKeyInfo sequence');
    }
    final elements = next.elements;
    if (elements == null || elements.length < 2) {
      throw const FormatException(
          'SendGrid pubkey SubjectPublicKeyInfo missing algorithm or key');
    }
    final algorithm = elements[0];
    final bitString = elements[1];
    if (algorithm is! pc.ASN1Sequence) {
      throw const FormatException(
          'SendGrid pubkey algorithm field is not a sequence');
    }
    if (bitString is! pc.ASN1BitString) {
      throw const FormatException(
          'SendGrid pubkey body field is not a BIT STRING');
    }
    // The algorithm sequence is { OID id-ecPublicKey, OID namedCurve }.
    final algoElements = algorithm.elements;
    if (algoElements == null || algoElements.length < 2) {
      throw const FormatException(
          'SendGrid pubkey algorithm field is missing the named curve OID');
    }
    final ecPublicKeyOid = algoElements[0];
    final curveOid = algoElements[1];
    if (ecPublicKeyOid is! pc.ASN1ObjectIdentifier ||
        curveOid is! pc.ASN1ObjectIdentifier) {
      throw const FormatException(
          'SendGrid pubkey algorithm field has unexpected OID shape');
    }
    // id-ecPublicKey = 1.2.840.10045.2.1
    if (ecPublicKeyOid.objectIdentifierAsString != '1.2.840.10045.2.1') {
      throw FormatException(
          'SendGrid pubkey algorithm is not id-ecPublicKey (was ${ecPublicKeyOid.objectIdentifierAsString})');
    }
    // secp256r1 = 1.2.840.10045.3.1.7
    if (curveOid.objectIdentifierAsString != '1.2.840.10045.3.1.7') {
      throw FormatException(
          'SendGrid pubkey is not on secp256r1 / P-256 (was ${curveOid.objectIdentifierAsString})');
    }
    final domain = pc.ECDomainParameters('prime256v1');
    // The BIT STRING content for an EC public key is the uncompressed
    // point encoding: 0x04 || X || Y where X and Y are 32 bytes each.
    // pointycastle's ASN1BitString stores the contents in
    // `stringValues` (legacy) or `valueBytes()`; we use `stringValues`
    // since pubkey BIT STRING content uses 0 unused bits.
    final pointBytes = bitString.stringValues;
    if (pointBytes == null || pointBytes.isEmpty) {
      throw const FormatException(
          'SendGrid pubkey BIT STRING is empty');
    }
    final pointAsBytes = Uint8List.fromList(pointBytes);
    if (pointAsBytes.length != 65 || pointAsBytes[0] != 0x04) {
      throw FormatException(
          'SendGrid pubkey point is not an uncompressed P-256 encoding (got ${pointAsBytes.length} bytes, lead byte 0x${pointAsBytes.isNotEmpty ? pointAsBytes[0].toRadixString(16) : "??"})');
    }
    final q = domain.curve.decodePoint(pointAsBytes);
    if (q == null) {
      throw const FormatException(
          'SendGrid pubkey point failed P-256 decode');
    }
    return pc.ECPublicKey(q, domain);
  }

  static pc.ECSignature? _decodeDerEcdsaSignature(Uint8List der) {
    try {
      final parser = pc.ASN1Parser(der);
      final dynamic obj = parser.nextObject();
      if (obj is! pc.ASN1Sequence) return null;
      final elements = obj.elements;
      if (elements == null || elements.length != 2) return null;
      final rField = elements[0];
      final sField = elements[1];
      if (rField is! pc.ASN1Integer || sField is! pc.ASN1Integer) {
        return null;
      }
      final r = rField.integer;
      final s = sField.integer;
      if (r == null || s == null) return null;
      return pc.ECSignature(r, s);
    } on Exception {
      return null;
    }
  }

  static _PemBlock _decodePemBlock(String pem) {
    final lines = LineSplitter.split(pem)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    if (lines.length < 3 ||
        !lines.first.startsWith('-----BEGIN ') ||
        !lines.first.endsWith('-----') ||
        !lines.last.startsWith('-----END ') ||
        !lines.last.endsWith('-----')) {
      throw const FormatException('invalid PEM block');
    }
    final label = lines.first
        .substring('-----BEGIN '.length, lines.first.length - '-----'.length)
        .trim();
    final endLabel = lines.last
        .substring('-----END '.length, lines.last.length - '-----'.length)
        .trim();
    if (label != endLabel) {
      throw const FormatException('PEM begin/end labels do not match');
    }
    final body = lines.sublist(1, lines.length - 1).join();
    final bytes = Uint8List.fromList(base64Decode(body));
    return _PemBlock(label: label, bytes: bytes);
  }
}

class _PemBlock {
  const _PemBlock({required this.label, required this.bytes});
  final String label;
  final Uint8List bytes;
}

/// Router for the SendGrid Event Webhook receiver.
///
/// Production wiring (`proxy_bootstrap.dart`) constructs one of these
/// with the production [EmailEventRepository], the default pubkey
/// loader, and the pointycastle verifier. `main.dart` mounts the
/// router as a pre-check in the per-request IIFE so the monolithic
/// dispatcher never sees this URL.
class SendGridEventsWebhookRouter {
  SendGridEventsWebhookRouter({
    required this.repository,
    SendGridPubKeyLoader? pubKeyLoader,
    SendGridSignatureVerifier? signatureVerifier,
    SendGridEventsWebhookObserver? observer,
  })  : _pubKeyLoader = pubKeyLoader ?? defaultSendGridPubKeyLoader,
        _signatureVerifier =
            signatureVerifier ?? const PointyCastleSendGridSignatureVerifier(),
        _observer = observer ?? const NoopSendGridEventsWebhookObserver();

  final EmailEventRepository repository;
  final SendGridPubKeyLoader _pubKeyLoader;
  final SendGridSignatureVerifier _signatureVerifier;
  final SendGridEventsWebhookObserver _observer;

  /// Returns true when [path] / [method] matches the receiver route.
  /// Mirrors the discriminator the other proxy routers expose so the
  /// main.dart pre-check is uniform.
  static bool matches(String path, String method) {
    return method == 'POST' && path == sendGridEventsWebhookPath;
  }

  /// Pre-check handler. Returns true when the route matched and the
  /// response has been written + closed; returns false otherwise (so
  /// `main.dart` falls through to `routeRequest`).
  Future<bool> tryHandle(HttpRequest request) async {
    if (!matches(request.uri.path, request.method)) {
      return false;
    }
    final response = request.response;
    try {
      // Step 0: load pubkey. If unset → 503 so SendGrid retries while
      // operators wire the env var.
      final pem = _pubKeyLoader();
      if (pem == null || pem.isEmpty) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'pubkey_not_configured',
          'message':
              'SendGrid event webhook public key is not configured on this proxy instance.',
        });
        return true;
      }

      // Step 1: read raw body bytes BEFORE JSON decoding. The
      // signature is over the exact byte sequence.
      final body = await _readBody(request);
      if (body.length > kSendGridMaxBodyBytes) {
        _writeJson(response, 413, <String, Object?>{
          'error': 'body_too_large',
          'message':
              'request body exceeded the SendGrid webhook accept limit.',
        });
        return true;
      }

      // Step 2: pull the signature + timestamp headers. Either missing
      // is treated as bad_signature (401) — SendGrid always emits both
      // on a valid request, and we want a single uniform 401 envelope
      // for every signature-class failure so operators see one alert
      // rather than 4-5 distinct codes.
      final signature = _readHeader(request, kSendGridSignatureHeader);
      final timestamp = _readHeader(request, kSendGridTimestampHeader);
      if (signature == null || signature.isEmpty) {
        _observer.onSignatureFailure(
          reason: 'missing_signature_header',
          bodyShape: null,
        );
        _writeJson(response, 401, <String, Object?>{
          'error': 'bad_signature',
          'message':
              'request is missing a valid SendGrid event signature.',
        });
        return true;
      }
      if (timestamp == null || timestamp.isEmpty) {
        _observer.onSignatureFailure(
          reason: 'missing_timestamp_header',
          bodyShape: null,
        );
        _writeJson(response, 401, <String, Object?>{
          'error': 'bad_signature',
          'message':
              'request is missing a valid SendGrid event signature.',
        });
        return true;
      }

      // Step 3: verify signature against `timestamp || body`. The
      // verifier returns false on any failure (malformed signature,
      // wrong curve, mismatched bytes). We do NOT distinguish failure
      // sub-types to the caller; a probing attacker would otherwise
      // learn whether their pubkey-format guess was right.
      final passed = _signatureVerifier.verify(
        pemPubKey: pem,
        timestamp: timestamp,
        body: body,
        signatureBase64: signature,
      );
      if (!passed) {
        _observer.onSignatureFailure(
          reason: 'signature_verify_failed',
          bodyShape: 'body_bytes=${body.length}',
        );
        _writeJson(response, 401, <String, Object?>{
          'error': 'bad_signature',
          'message':
              'request is missing a valid SendGrid event signature.',
        });
        return true;
      }

      // Step 4: decode JSON only AFTER signature passes. A malformed
      // body that passed a signature check is upstream's problem;
      // operators should see 400 + log it.
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(body));
      } on FormatException {
        _writeJson(response, 400, <String, Object?>{
          'error': 'malformed_json',
          'message': 'request body is not valid JSON.',
        });
        return true;
      }
      if (decoded is! List) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'malformed_json',
          'message':
              'request body must be a JSON array of SendGrid event objects.',
        });
        return true;
      }

      // Step 5: parse + insert one row per event. Each insert uses
      // ON CONFLICT (provider_event_id) DO NOTHING so replays land
      // harmlessly. An empty array is a valid no-op (204).
      var inserted = 0;
      var duplicates = 0;
      for (var i = 0; i < decoded.length; i++) {
        final entry = decoded[i];
        if (entry is! Map) {
          _observer.onParseFailure(
            field: '[$i]',
            message: 'event entry must be a JSON object',
            eventIndex: i,
          );
          _writeJson(response, 400, <String, Object?>{
            'error': 'malformed_event',
            'message':
                'event at index $i is not a JSON object.',
          });
          return true;
        }
        final SendGridEvent event;
        try {
          event = SendGridEvent.fromJson(entry.cast<String, Object?>());
        } on SendGridEventParseException catch (parseFailure) {
          _observer.onParseFailure(
            field: parseFailure.field,
            message: parseFailure.message,
            eventIndex: i,
          );
          _writeJson(response, 400, <String, Object?>{
            'error': 'malformed_event',
            'message':
                'event at index $i is malformed: ${parseFailure.message}',
            'field': parseFailure.field,
          });
          return true;
        }
        final result = await repository.insertProviderEvent(event);
        switch (result) {
          case EmailEventInsertInserted():
            inserted += 1;
          case EmailEventInsertDuplicate():
            duplicates += 1;
        }
      }

      _observer.onBatchProcessed(
        inserted: inserted,
        duplicates: duplicates,
      );

      // 204 No Content: SendGrid documents the webhook as fire-and-
      // forget; the response body is ignored. We keep the response
      // empty so a busy proxy spends as few bytes as possible per
      // event.
      response.statusCode = 204;
      // intentionally no body
      return true;
    } catch (error, stack) {
      // Final safety net. A repository / pubkey-load exception
      // surfaces as 500 with no detail in the body (matches the
      // `email_test_unhandled_error` discipline at
      // admin_email_routes.dart).
      log(
        LogSeverity.error,
        'sendgrid_events_webhook.unhandled_error',
        fields: <String, Object?>{
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
      _writeJson(response, 500, <String, Object?>{
        'error': 'internal_server_error',
        'message': 'sendgrid events webhook failed to process the batch.',
      });
      return true;
    }
  }

  /// Pure-Dart dispatch used by unit tests so the suite can probe the
  /// router without spinning up an `HttpServer`. Returns the
  /// (statusCode, body) tuple the production handler writes.
  ///
  /// The route handler does NOT read query parameters — addendum A1
  /// generally; here the rule is degenerate (SendGrid is server-to-
  /// server) but the prohibition is uniform.
  Future<({int statusCode, Map<String, Object?>? body})> dispatch({
    required String method,
    required String path,
    required Uint8List body,
    required Map<String, String> headers,
  }) async {
    if (!matches(path, method)) {
      return (statusCode: 404, body: <String, Object?>{
        'error': 'not_found',
      });
    }
    final pem = _pubKeyLoader();
    if (pem == null || pem.isEmpty) {
      return (statusCode: 503, body: <String, Object?>{
        'error': 'pubkey_not_configured',
        'message':
            'SendGrid event webhook public key is not configured on this proxy instance.',
      });
    }
    if (body.length > kSendGridMaxBodyBytes) {
      return (statusCode: 413, body: <String, Object?>{
        'error': 'body_too_large',
        'message':
            'request body exceeded the SendGrid webhook accept limit.',
      });
    }
    final headerLower = <String, String>{
      for (final entry in headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final signature = headerLower[kSendGridSignatureHeader];
    final timestamp = headerLower[kSendGridTimestampHeader];
    if (signature == null || signature.isEmpty) {
      _observer.onSignatureFailure(
        reason: 'missing_signature_header',
        bodyShape: null,
      );
      return (statusCode: 401, body: <String, Object?>{
        'error': 'bad_signature',
        'message':
            'request is missing a valid SendGrid event signature.',
      });
    }
    if (timestamp == null || timestamp.isEmpty) {
      _observer.onSignatureFailure(
        reason: 'missing_timestamp_header',
        bodyShape: null,
      );
      return (statusCode: 401, body: <String, Object?>{
        'error': 'bad_signature',
        'message':
            'request is missing a valid SendGrid event signature.',
      });
    }
    final passed = _signatureVerifier.verify(
      pemPubKey: pem,
      timestamp: timestamp,
      body: body,
      signatureBase64: signature,
    );
    if (!passed) {
      _observer.onSignatureFailure(
        reason: 'signature_verify_failed',
        bodyShape: 'body_bytes=${body.length}',
      );
      return (statusCode: 401, body: <String, Object?>{
        'error': 'bad_signature',
        'message':
            'request is missing a valid SendGrid event signature.',
      });
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException {
      return (statusCode: 400, body: <String, Object?>{
        'error': 'malformed_json',
        'message': 'request body is not valid JSON.',
      });
    }
    if (decoded is! List) {
      return (statusCode: 400, body: <String, Object?>{
        'error': 'malformed_json',
        'message':
            'request body must be a JSON array of SendGrid event objects.',
      });
    }
    var inserted = 0;
    var duplicates = 0;
    for (var i = 0; i < decoded.length; i++) {
      final entry = decoded[i];
      if (entry is! Map) {
        _observer.onParseFailure(
          field: '[$i]',
          message: 'event entry must be a JSON object',
          eventIndex: i,
        );
        return (statusCode: 400, body: <String, Object?>{
          'error': 'malformed_event',
          'message':
              'event at index $i is not a JSON object.',
        });
      }
      final SendGridEvent event;
      try {
        event = SendGridEvent.fromJson(entry.cast<String, Object?>());
      } on SendGridEventParseException catch (parseFailure) {
        _observer.onParseFailure(
          field: parseFailure.field,
          message: parseFailure.message,
          eventIndex: i,
        );
        return (statusCode: 400, body: <String, Object?>{
          'error': 'malformed_event',
          'message':
              'event at index $i is malformed: ${parseFailure.message}',
          'field': parseFailure.field,
        });
      }
      final result = await repository.insertProviderEvent(event);
      switch (result) {
        case EmailEventInsertInserted():
          inserted += 1;
        case EmailEventInsertDuplicate():
          duplicates += 1;
      }
    }
    _observer.onBatchProcessed(
      inserted: inserted,
      duplicates: duplicates,
    );
    return (statusCode: 204, body: null);
  }

  String? _readHeader(HttpRequest request, String name) {
    final value = request.headers.value(name);
    return value?.trim();
  }

  Future<Uint8List> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > kSendGridMaxBodyBytes) {
        // Stop draining; the caller checks the size and writes 413.
        // We still need to drain the rest so the socket can close.
        builder.add(chunk);
      } else {
        builder.add(chunk);
      }
    }
    return builder.takeBytes();
  }

  void _writeJson(HttpResponse response, int status, Object body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }
}
