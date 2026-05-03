// Forge & Flow — SendGrid concrete EmailProvider.
//
// Phase 9.8 email-provider slice. Concrete implementation of the
// [EmailProvider] seam against Twilio SendGrid's v3 Mail Send and
// Messages APIs. The HTTP gateway is injected so unit tests can
// substitute a [SendGridFakeGateway] backed by recorded sandbox
// fixtures.
//
// Endpoint contract (SendGrid v3):
//   * POST https://api.sendgrid.com/v3/mail/send
//       Authorization: Bearer <api_key>
//       Body: {personalizations:[{to:[{email,name}]}], from:{email,name},
//              subject, content:[{type:"text/plain"|"text/html",value}],
//              custom_args:{...}, mail_settings:{sandbox_mode:{enable:bool}}}
//       Success: 202 Accepted with `X-Message-Id` response header.
//   * GET https://api.sendgrid.com/v3/messages/<id>
//       Returns the most recent activity entry; we map status_label
//       into [EmailDeliveryStatusKind].
//
// Sandbox mode: when [sandboxMode] is true the request body sets
// `mail_settings.sandbox_mode.enable=true`. The provider returns
// 202 Accepted without actually delivering — used by integration
// tests and by the "Test connection" admin surface against the
// staging key. Production binds [sandboxMode] = false.
//
// Retry posture: the dispatcher (not this file) owns the 3-strike
// retry / dead-letter rule. This provider's job is to translate
// HTTP outcomes into [EmailProviderException] kinds:
//   * 202 → success, return [EmailSendResult].
//   * 429 → providerRateLimit, surface `Retry-After` header.
//   * 401 / 403 → providerAuth, surface an admin alert (bad key).
//   * 4xx other → providerBadRequest, dead-letter.
//   * 5xx → providerInternal, retryable.
//   * Network / TLS / timeout → network, retryable.

import 'dart:async';
import 'dart:convert';

import 'email_provider.dart';

const String _sendGridProviderId = 'sendgrid';
const String _sendGridDefaultBase = 'https://api.sendgrid.com';
const String _sendGridMailSendPath = '/v3/mail/send';
const String _sendGridMessagesPathPrefix = '/v3/messages/';

/// Minimal HTTP response envelope the provider needs. Keeping this
/// abstract instead of binding to `package:http` makes the unit
/// suite self-contained — tests inject a [SendGridHttpResponse]
/// directly without standing up a fake `http.Client`.
class SendGridHttpResponse {
  const SendGridHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}

/// Gateway signature for both POST `/v3/mail/send` and GET
/// `/v3/messages/<id>`. Concrete implementations use
/// `package:http` in production and a recorded-fixture stub in
/// tests; the provider does not import `package:http` directly.
typedef SendGridHttpGateway = Future<SendGridHttpResponse> Function({
  required String method,
  required Uri uri,
  required Map<String, String> headers,
  String? body,
});

/// Function signature the provider calls to pull the active
/// SendGrid API key per request. Production binds this to the
/// `email_credentials` repository; tests pin a fixed string. The
/// indirection keeps the plaintext out of long-lived caches per
/// the Hard Promise #7 rule (server-side keys only, never cached
/// past one request lifetime).
typedef SendGridApiKeyProvider = Future<String> Function();

class SendGridEmailProvider implements EmailProvider {
  SendGridEmailProvider({
    required SendGridHttpGateway httpGateway,
    required SendGridApiKeyProvider apiKeyProvider,
    Uri? baseUri,
    this.sandboxMode = false,
    DateTime Function()? now,
  })  : _httpGateway = httpGateway,
        _apiKeyProvider = apiKeyProvider,
        _baseUri = baseUri ?? Uri.parse(_sendGridDefaultBase),
        _now = now ?? DateTime.now;

  final SendGridHttpGateway _httpGateway;
  final SendGridApiKeyProvider _apiKeyProvider;
  final Uri _baseUri;

  /// When true, every request adds
  /// `mail_settings.sandbox_mode.enable=true`. Staging proxies bind
  /// this to true so the "Test connection" admin button does not
  /// burn real provider quota; production binds it to false.
  final bool sandboxMode;

  final DateTime Function() _now;

  @override
  String get providerId => _sendGridProviderId;

  @override
  Future<EmailSendResult> send(EmailSendRequest request) async {
    final apiKey = await _apiKeyProvider();
    if (apiKey.isEmpty) {
      throw const EmailProviderException(
        kind: EmailFailureKind.providerAuth,
        message: 'SendGrid API key is empty; rotate via 11A.4 admin console',
        statusCode: 401,
      );
    }
    final body = jsonEncode(_buildSendBody(request));
    final uri = _baseUri.resolve(_sendGridMailSendPath);
    SendGridHttpResponse response;
    try {
      response = await _httpGateway(
        method: 'POST',
        uri: uri,
        headers: <String, String>{
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: body,
      );
    } on TimeoutException catch (e) {
      throw EmailProviderException(
        kind: EmailFailureKind.network,
        message: 'SendGrid send timed out: ${e.message}',
      );
    } catch (error) {
      throw EmailProviderException(
        kind: EmailFailureKind.network,
        message: 'SendGrid send network error: $error',
      );
    }
    if (response.statusCode == 202) {
      final messageId = response.header('X-Message-Id') ??
          response.header('x-message-id');
      if (messageId == null || messageId.isEmpty) {
        throw const EmailProviderException(
          kind: EmailFailureKind.providerProtocol,
          message:
              'SendGrid returned 202 but no X-Message-Id header was present',
          statusCode: 202,
        );
      }
      return EmailSendResult(
        providerMessageId: messageId,
        acceptedAt: _now().toUtc(),
      );
    }
    throw _classifyFailure(response);
  }

  @override
  Future<EmailDeliveryStatus> getDeliveryStatus(
    String providerMessageId,
  ) async {
    final apiKey = await _apiKeyProvider();
    if (apiKey.isEmpty) {
      throw const EmailProviderException(
        kind: EmailFailureKind.providerAuth,
        message: 'SendGrid API key is empty; rotate via 11A.4 admin console',
        statusCode: 401,
      );
    }
    final uri = _baseUri.resolve('$_sendGridMessagesPathPrefix$providerMessageId');
    SendGridHttpResponse response;
    try {
      response = await _httpGateway(
        method: 'GET',
        uri: uri,
        headers: <String, String>{
          'Authorization': 'Bearer $apiKey',
          'Accept': 'application/json',
        },
      );
    } on TimeoutException catch (e) {
      throw EmailProviderException(
        kind: EmailFailureKind.network,
        message: 'SendGrid status lookup timed out: ${e.message}',
      );
    } catch (error) {
      throw EmailProviderException(
        kind: EmailFailureKind.network,
        message: 'SendGrid status lookup network error: $error',
      );
    }
    if (response.statusCode == 200) {
      return _parseStatus(providerMessageId, response.body);
    }
    if (response.statusCode == 404) {
      return EmailDeliveryStatus(
        providerMessageId: providerMessageId,
        statusKind: EmailDeliveryStatusKind.unknown,
        checkedAt: _now().toUtc(),
        detail: 'message id not present in SendGrid retention window',
      );
    }
    throw _classifyFailure(response);
  }

  Map<String, Object?> _buildSendBody(EmailSendRequest request) {
    final to = <String, Object?>{
      'email': request.to.email,
      if (request.to.displayName != null) 'name': request.to.displayName,
    };
    final from = <String, Object?>{
      'email': request.fromAddress,
      'name': request.fromDisplayName,
    };
    final mailSettings = <String, Object?>{
      if (sandboxMode) 'sandbox_mode': <String, Object?>{'enable': true},
    };
    return <String, Object?>{
      'personalizations': <Map<String, Object?>>[
        <String, Object?>{
          'to': <Map<String, Object?>>[to],
          if (request.providerMetadata.isNotEmpty)
            'custom_args': request.providerMetadata,
        },
      ],
      'from': from,
      if (request.replyToAddress != null)
        'reply_to': <String, Object?>{'email': request.replyToAddress},
      'subject': request.subject,
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text/plain', 'value': request.textBody},
        <String, Object?>{'type': 'text/html', 'value': request.htmlBody},
      ],
      if (mailSettings.isNotEmpty) 'mail_settings': mailSettings,
    };
  }

  EmailProviderException _classifyFailure(SendGridHttpResponse response) {
    final code = response.statusCode;
    String message = 'SendGrid returned $code';
    final body = response.body;
    if (body.isNotEmpty) {
      final excerpt = body.length > 500 ? '${body.substring(0, 500)}…' : body;
      message = '$message: $excerpt';
    }
    if (code == 401 || code == 403) {
      return EmailProviderException(
        kind: EmailFailureKind.providerAuth,
        message: message,
        statusCode: code,
      );
    }
    if (code == 429) {
      Duration? retryAfter;
      final raw = response.header('Retry-After');
      if (raw != null) {
        final secs = int.tryParse(raw.trim());
        if (secs != null && secs >= 0) {
          retryAfter = Duration(seconds: secs);
        }
      }
      return EmailProviderException(
        kind: EmailFailureKind.providerRateLimit,
        message: message,
        statusCode: code,
        retryAfter: retryAfter,
      );
    }
    if (code >= 400 && code < 500) {
      return EmailProviderException(
        kind: EmailFailureKind.providerBadRequest,
        message: message,
        statusCode: code,
      );
    }
    if (code >= 500 && code < 600) {
      return EmailProviderException(
        kind: EmailFailureKind.providerInternal,
        message: message,
        statusCode: code,
      );
    }
    return EmailProviderException(
      kind: EmailFailureKind.unknown,
      message: message,
      statusCode: code,
    );
  }

  EmailDeliveryStatus _parseStatus(String id, String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw EmailProviderException(
        kind: EmailFailureKind.providerProtocol,
        message:
            'SendGrid status response is not valid JSON for message $id',
        statusCode: 200,
      );
    }
    String? statusLabel;
    String? detail;
    if (decoded is Map) {
      // SendGrid v3 Messages API returns {"messages":[{"status":...}]}
      final messages = decoded['messages'];
      if (messages is List && messages.isNotEmpty) {
        final first = messages.first;
        if (first is Map) {
          statusLabel = first['status']?.toString();
          detail = first['reason']?.toString();
        }
      } else if (decoded['status'] is String) {
        statusLabel = decoded['status'] as String;
      }
    }
    return EmailDeliveryStatus(
      providerMessageId: id,
      statusKind: _mapSendGridStatus(statusLabel),
      checkedAt: _now().toUtc(),
      detail: detail,
    );
  }

  EmailDeliveryStatusKind _mapSendGridStatus(String? label) {
    switch (label) {
      case null:
        return EmailDeliveryStatusKind.unknown;
      case 'processed':
      case 'deferred':
        return EmailDeliveryStatusKind.accepted;
      case 'delivered':
        return EmailDeliveryStatusKind.delivered;
      case 'bounce':
      case 'blocked':
      case 'dropped':
        return EmailDeliveryStatusKind.bounced;
      case 'spam':
      case 'spamreport':
        return EmailDeliveryStatusKind.complaint;
      default:
        return EmailDeliveryStatusKind.unknown;
    }
  }
}
