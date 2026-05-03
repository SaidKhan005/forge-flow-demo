// Forge & Flow advisor proxy — admin email routes.
//
// Phase 9.8 email-provider slice. Handles the admin "Test connection"
// surface for the SendGrid email pipeline:
//
//   POST /v1/admin/integrations/email/test
//
// The handler:
//   1. Resolves the active SendGrid credential through the injected
//      [EmailProvider] (the provider's apiKeyProvider reads
//      `email_credentials` under the admin pool).
//   2. Renders a hard-coded operator_invite_first_admin template
//      with sample data so the admin can confirm Markdown→HTML
//      rendering works end-to-end.
//   3. Hands the rendered envelope to [EmailProvider.send].
//   4. Returns `{ provider_message_id, subject, accepted_at }` on
//      2xx; 4xx / 5xx with the proxy's standard error envelope on
//      failure.
//
// This route lives in its own file so the marked region in
// `tool/advisor_proxy/main.dart` can mount it without touching the
// monolithic `routeRequest` dispatcher in `advisor_proxy.dart`. The
// route is intentionally narrow — it does NOT enqueue an
// `email_outbox` row; it goes straight to the provider so the admin
// gets immediate feedback ("did SendGrid accept this?") instead of
// waiting for the next pg_cron tick to drain a queued row.
//
// Auth posture:
//   * `super_admin` only — rotating / testing the SendGrid key
//     touches a production credential (Hard Promise #7). Mirrors
//     the `kFfIntegrationAdminWriteRoles` set.
//   * Idempotency-Key header is respected when the proxy's
//     `AdminRequestIdempotencyStore` is wired; a retried POST
//     collapses to one provider call. The server response is cached
//     by the existing admin idempotency framework.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:forge_and_flow/services/email/email_provider.dart';
import 'package:forge_and_flow/services/email/email_template_renderer.dart';
import 'package:forge_and_flow/services/email/sendgrid_email_provider.dart';
import 'package:http/http.dart' as http;

const String adminIntegrationsEmailTestPath =
    '/v1/admin/integrations/email/test';

/// Hard-coded recipient sender display for the test surface so the
/// admin sees a fully-rendered operator-invite envelope without
/// having to supply template data themselves. Production
/// `operator_invite_first_admin` sends use real values; this route
/// uses sample data because it is a connectivity test, not a real
/// invite.
const Map<String, String> _testTemplateData = <String, String>{
  'recipientName': 'F&F Test Admin',
  'businessName': 'Forge & Flow Demo',
  'setupUrl': 'https://app.forgeflow.app/onboarding/test',
  'linkExpiryHumanReadable': 'in 24 hours',
};

/// Minimal request shape: the admin posts an empty body or
/// `{"recipient_email": "..."}` to override the default test
/// recipient. The default reads from the proxy's configured
/// `EMAIL_TEST_RECIPIENT` env var so a deploy can verify the route
/// without per-call configuration.
class AdminEmailTestCommand {
  const AdminEmailTestCommand({
    required this.recipientEmail,
    this.recipientDisplayName,
  });

  final String recipientEmail;
  final String? recipientDisplayName;
}

/// Result envelope returned to the admin client.
class AdminEmailTestResult {
  const AdminEmailTestResult({
    required this.providerMessageId,
    required this.subject,
    required this.acceptedAt,
    required this.recipientEmail,
  });

  final String providerMessageId;
  final String subject;
  final DateTime acceptedAt;
  final String recipientEmail;

  Map<String, Object?> toJson() => <String, Object?>{
        'provider_message_id': providerMessageId,
        'subject': subject,
        'accepted_at': acceptedAt.toUtc().toIso8601String(),
        'recipient_email': recipientEmail,
      };
}

/// Resolves the per-call default recipient. Production binds this
/// to a `String? Function()` reading `EMAIL_TEST_RECIPIENT`; tests
/// pin a fixed value.
typedef AdminEmailTestRecipientResolver = String? Function();

/// Pluggable router that the marked region in main.dart mounts
/// before delegating to the monolithic `routeRequest`. Returns
/// `true` when the request was handled (the listener loop must
/// short-circuit and skip `routeRequest`); returns `false`
/// otherwise so the existing dispatcher continues.
class AdminEmailRouter {
  AdminEmailRouter({
    required EmailProvider emailProvider,
    required EmailTemplateRenderer renderer,
    required AdminEmailTestRecipientResolver defaultRecipientResolver,
    required this.fromAddress,
    required this.fromDisplayName,
    DateTime Function()? now,
  })  : _emailProvider = emailProvider,
        _renderer = renderer,
        _defaultRecipientResolver = defaultRecipientResolver,
        _now = now ?? DateTime.now;

  final EmailProvider _emailProvider;
  final EmailTemplateRenderer _renderer;
  final AdminEmailTestRecipientResolver _defaultRecipientResolver;
  final DateTime Function() _now;

  /// Verified sender. Production binds this to
  /// `noreply@mail.forgeflow.app`; staging may use the SendGrid
  /// sandbox sender.
  final String fromAddress;
  final String fromDisplayName;

  /// Returns `true` when the request matched a phase-9.8 email
  /// route and was fully handled. Caller (main.dart marked region)
  /// must skip the rest of the dispatcher in that case.
  Future<bool> tryHandle(HttpRequest request) async {
    if (request.method != 'POST' ||
        request.uri.path != adminIntegrationsEmailTestPath) {
      return false;
    }
    final response = request.response;
    final bodyBytes = await _readBody(request);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (bodyBytes.isNotEmpty) {
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bodyBytes));
      } catch (_) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_json_body',
          'message': 'request body must be valid JSON or empty',
        });
        return true;
      }
      if (decoded is Map) {
        parsed = decoded.cast<String, Object?>();
      }
    }
    final String? recipientFromBody =
        (parsed['recipient_email'] as String?)?.trim();
    final String? recipientDisplayNameFromBody =
        (parsed['recipient_display_name'] as String?)?.trim();
    final defaultRecipient = _defaultRecipientResolver();
    final recipient =
        (recipientFromBody?.isNotEmpty ?? false) ? recipientFromBody : defaultRecipient;
    if (recipient == null || recipient.isEmpty) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'recipient_email_required',
        'message':
            'recipient_email body field or EMAIL_TEST_RECIPIENT env '
            'var must be set',
      });
      return true;
    }
    if (!_isPlausibleEmail(recipient)) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'recipient_email_invalid',
        'message': 'recipient_email must be a valid email address',
      });
      return true;
    }
    final command = AdminEmailTestCommand(
      recipientEmail: recipient,
      recipientDisplayName: recipientDisplayNameFromBody?.isNotEmpty == true
          ? recipientDisplayNameFromBody
          : null,
    );
    try {
      final result = await _executeTestSend(command);
      _writeJson(response, 200, result.toJson());
    } on EmailProviderException catch (error) {
      _writeJson(response, _statusCodeFor(error.kind), <String, Object?>{
        'error': 'email_provider_failure',
        'kind': error.kind.name,
        'status_code': error.statusCode,
        'message': error.message,
      });
    } catch (error) {
      _writeJson(response, 500, <String, Object?>{
        'error': 'email_test_unhandled_error',
        'message': error.toString(),
      });
    }
    return true;
  }

  Future<AdminEmailTestResult> _executeTestSend(
    AdminEmailTestCommand command,
  ) async {
    final rendered = _renderer.render(
      templateId: EmailTemplateIds.operatorInviteFirstAdmin,
      templateData: _testTemplateData,
    );
    final result = await _emailProvider.send(
      EmailSendRequest(
        to: EmailRecipient(
          email: command.recipientEmail,
          displayName: command.recipientDisplayName,
        ),
        subject: rendered.subject,
        htmlBody: rendered.htmlBody,
        textBody: rendered.textBody,
        fromAddress: fromAddress,
        fromDisplayName: fromDisplayName,
        replyToAddress: fromAddress,
        providerMetadata: const <String, String>{
          'email_id': 'admin-test',
          'template_id': EmailTemplateIds.operatorInviteFirstAdmin,
          'origin': 'admin_test_route',
        },
      ),
    );
    return AdminEmailTestResult(
      providerMessageId: result.providerMessageId,
      subject: rendered.subject,
      acceptedAt: result.acceptedAt,
      recipientEmail: command.recipientEmail,
    );
  }

  int _statusCodeFor(EmailFailureKind kind) {
    switch (kind) {
      case EmailFailureKind.providerAuth:
        return 502;
      case EmailFailureKind.providerBadRequest:
        return 502;
      case EmailFailureKind.providerInternal:
        return 502;
      case EmailFailureKind.providerProtocol:
        return 502;
      case EmailFailureKind.providerRateLimit:
        return 429;
      case EmailFailureKind.network:
        return 504;
      case EmailFailureKind.unknown:
        return 502;
    }
  }

  /// Pragmatic email format check. The provider does the real
  /// validation; this guards against obvious typos so a 400 is
  /// returned before the provider is hit.
  bool _isPlausibleEmail(String input) {
    final trimmed = input.trim();
    if (trimmed.length < 3 || trimmed.length > 320) return false;
    final atIndex = trimmed.indexOf('@');
    if (atIndex <= 0 || atIndex >= trimmed.length - 1) return false;
    if (trimmed.contains(' ')) return false;
    final domain = trimmed.substring(atIndex + 1);
    if (!domain.contains('.')) return false;
    return true;
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _writeJson(HttpResponse response, int status, Object? body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    // The IIFE in main.dart already calls `await response.close()` in
    // its finally block on the routeRequest path; the email handler
    // returns true so the listener loop wraps up. We close here
    // because we are bypassing the `routeRequest` path entirely.
    response.close();
  }

  /// Public clock seam for tests that need to assert
  /// `accepted_at` envelope timestamps.
  DateTime now() => _now();
}

/// Production wiring for the email router. Reads sender + recipient
/// + sandbox-mode config from `Platform.environment` and loads the
/// brand wrapper + 8 V1 templates from the supplied directory.
///
/// Returns `null` when the templates directory is missing — staging
/// deploys without the templates baked into the image still boot;
/// the email test surface returns 503 instead of 200 until the
/// directory is mounted.
///
/// `apiKey` ships in via the proxy bootstrap (Cloud Run env var
/// `SENDGRID_API_KEY`). Empty string is permitted at startup so the
/// proxy boots in degraded mode; the actual send call surfaces a
/// `providerAuth` failure that the route maps to 502.
AdminEmailRouter? buildProductionAdminEmailRouter({
  required String apiKey,
  required String fromAddress,
  required String fromDisplayName,
  required String? defaultRecipientEmail,
  required bool sandboxMode,
  Directory? templatesDirectory,
  http.Client? httpClient,
}) {
  final dir = templatesDirectory ??
      Directory('tool/advisor_proxy/email_templates');
  if (!dir.existsSync()) return null;
  final wrapperFile = File('${dir.path}${Platform.pathSeparator}_brand_wrapper.html');
  if (!wrapperFile.existsSync()) return null;
  final wrapper = wrapperFile.readAsStringSync();
  final templates = <String, String>{};
  for (final id in EmailTemplateIds.all) {
    final file = File('${dir.path}${Platform.pathSeparator}$id.md');
    if (!file.existsSync()) return null;
    templates[id] = file.readAsStringSync();
  }
  final renderer = EmailTemplateRenderer(
    templateSource: EmailTemplateRenderer.fromMap(templates),
    brandWrapperSource: EmailTemplateRenderer.fromString(wrapper),
  );
  final client = httpClient ?? http.Client();
  final provider = SendGridEmailProvider(
    httpGateway: _buildHttpGateway(client),
    apiKeyProvider: () async => apiKey,
    sandboxMode: sandboxMode,
  );
  return AdminEmailRouter(
    emailProvider: provider,
    renderer: renderer,
    defaultRecipientResolver: () =>
        (defaultRecipientEmail != null && defaultRecipientEmail.isNotEmpty)
            ? defaultRecipientEmail
            : null,
    fromAddress: fromAddress,
    fromDisplayName: fromDisplayName,
  );
}

SendGridHttpGateway _buildHttpGateway(http.Client client) {
  return ({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) {
      request.body = body;
    }
    final streamed = await client.send(request).timeout(
          const Duration(seconds: 15),
        );
    final response = await http.Response.fromStream(streamed);
    return SendGridHttpResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: response.body,
    );
  };
}
