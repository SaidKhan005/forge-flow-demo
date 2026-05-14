// Wave 2 U-FU-tier-email — Operator data freshness tier-email route.
//
// Route:
//   POST /v1/operator/tier-email/data-freshness-request
//
// Operator-scoped. Idempotency-Key required. Caller must hold
// `operator_owner` or `operator_admin` role (mirrors the existing
// `/v1/.../data_accuracy_settings` write gate; no new permission key
// is introduced — DO NOT widen permissions).
//
// Body:
//   {
//     "current_tier":      "Standard" | "Premium" | "Custom",
//     "requested_cadence": "<free-form operator ask>",
//     "business_reason":   "<free-form operator reason>"
//   }
//
// Handler flow:
//   1. Auth + role + tenant scope (operatorId off the JWT; never off
//      the body or URL).
//   2. Idempotency-Key replay through [OperatorWriteIdempotencyCache].
//   3. Write a hash-chained audit row via [OperatorWriteAuditSink].
//      `eventKind = operator_data_freshness_request_submitted`. The
//      audit row is the source of truth even when SendGrid fails.
//   4. Attempt the SendGrid send through the injected [EmailProvider].
//      Recipient locked to `support@forgeflow.org` (operator-approved
//      2026-05-14).
//   5. Response envelopes:
//        * 200 `{ ok: true, audit_row_id, provider_message_id }` on
//          full success.
//        * 502 `{ error: "email_send_failed", audit_row_id, ... }`
//          when the audit row landed but SendGrid rejected.
//        * 503 / 400 / 403 envelopes mirror sibling-router patterns.
//
// Why this lives in a SIBLING file: bleed-stop ceiling per
// `tool/advisor_proxy_size_lint.dart`; mirrors C-1 SendGrid + B6
// benchmark + B8 audit-log precedents.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/services/email/email_provider.dart';
import 'package:forge_and_flow/services/observability/dependency_timeout_exception.dart';

import 'operator_routes.dart';

const String operatorTierEmailDataFreshnessRequestPath =
    '/v1/operator/tier-email/data-freshness-request';

const String kOperatorTierEmailRecipient = 'support@forgeflow.org';

const String kOperatorTierEmailAuditEventKind =
    'operator_data_freshness_request_submitted';

class OperatorTierEmailActor {
  const OperatorTierEmailActor({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.operatorName,
    required this.roles,
    required this.actorKind,
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final String operatorName;
  final Set<String> roles;
  final String actorKind;
}

typedef OperatorTierEmailAuthResolver
    = Future<OperatorTierEmailActor?> Function(HttpRequest request);

typedef OperatorTierEmailUnhandledErrorLogger = void Function({
  required String method,
  required String path,
  required Object error,
  required StackTrace stackTrace,
});

typedef OperatorTierEmailSendErrorLogger = void Function({
  required String operatorId,
  required String actorUserId,
  required String auditRowId,
  required Object error,
});

class OperatorTierEmailRouter {
  OperatorTierEmailRouter({
    required this.emailProvider,
    required this.auditSink,
    required this.fromAddress,
    required this.fromDisplayName,
    OperatorWriteIdempotencyCache? idempotencyCache,
    DateTime Function()? now,
    OperatorTierEmailAuthResolver? authResolver,
    OperatorTierEmailUnhandledErrorLogger? unhandledErrorLogger,
    OperatorTierEmailSendErrorLogger? sendErrorLogger,
    String Function()? auditRowIdFactory,
    String recipient = kOperatorTierEmailRecipient,
  })  : _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache(),
        _now = now ?? DateTime.now,
        _authResolver = authResolver,
        _unhandledErrorLogger = unhandledErrorLogger,
        _sendErrorLogger = sendErrorLogger,
        _auditRowIdFactory = auditRowIdFactory ?? _defaultAuditRowIdFactory,
        _recipient = recipient;

  final EmailProvider emailProvider;
  final OperatorWriteAuditSink auditSink;
  final String fromAddress;
  final String fromDisplayName;
  final OperatorWriteIdempotencyCache _idempotencyCache;
  final DateTime Function() _now;
  final OperatorTierEmailAuthResolver? _authResolver;
  final OperatorTierEmailUnhandledErrorLogger? _unhandledErrorLogger;
  final OperatorTierEmailSendErrorLogger? _sendErrorLogger;
  final String Function() _auditRowIdFactory;
  final String _recipient;

  static bool matches(String path, String method) =>
      method == 'POST' && path == operatorTierEmailDataFreshnessRequestPath;

  Future<bool> tryHandle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    if (!matches(path, method)) return false;

    final response = request.response;

    if (_authResolver == null) {
      _writeJson(response, 503, <String, Object?>{
        'error': 'operator_tier_email_not_configured',
        'message':
            'route requires an OperatorTierEmailAuthResolver to be installed',
      });
      return true;
    }
    OperatorTierEmailActor? actor;
    try {
      actor = await _authResolver(request);
    } catch (_) {
      _writeJson(response, 401, <String, Object?>{
        'error': 'unauthorized',
        'message': 'verified bearer token required',
      });
      return true;
    }
    if (actor == null) {
      _writeJson(response, 401, <String, Object?>{
        'error': 'unauthorized',
        'message': 'verified bearer token required',
      });
      return true;
    }
    if (actor.operatorId.isEmpty || actor.locationId.isEmpty) {
      _writeJson(response, 403, <String, Object?>{
        'error': 'permission_denied',
        'message': 'data freshness requests require tenant scope',
      });
      return true;
    }
    if (!actor.roles.any(kOperatorWriteRoles.contains)) {
      _writeJson(response, 403, <String, Object?>{
        'error': 'forbidden',
        'message': 'operator owner or operator admin role is required',
        'required_roles': kOperatorWriteRoles.toList(),
      });
      return true;
    }

    final headerKey = request.headers.value('Idempotency-Key')?.trim();
    if (headerKey == null || headerKey.isEmpty) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'idempotency_key_missing',
        'message': 'Idempotency-Key header is required',
      });
      return true;
    }
    if (headerKey.length > 200) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'idempotency_key_too_long',
        'message': 'Idempotency-Key header must be 200 characters or fewer',
      });
      return true;
    }
    final bodyResult = await readOperatorJsonBody(request);
    if (bodyResult.errorStatus != null) {
      _writeJson(response, bodyResult.errorStatus!, bodyResult.errorBody!);
      return true;
    }

    try {
      final result = await handle(
        operatorId: actor.operatorId,
        operatorName: actor.operatorName,
        actorUserId: actor.userId,
        actorKind: actor.actorKind,
        idempotencyKey: headerKey,
        body: bodyResult.body!,
      );
      _writeJson(response, result.statusCode, result.body);
    } catch (error, stackTrace) {
      if (error is DependencyTimeoutException) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'dependency_timeout',
          'surface': error.surface,
          'operation': error.operation,
          'message': 'Upstream dependency timed out; please retry',
        });
        return true;
      }
      _unhandledErrorLogger?.call(
        method: method,
        path: path,
        error: error,
        stackTrace: stackTrace,
      );
      _writeJson(response, 503, <String, Object?>{
        'error': 'operator_tier_email_unavailable',
        'message': 'tier email is unavailable; please retry',
      });
    }
    return true;
  }

  Future<({int statusCode, Map<String, Object?> body})> handle({
    required String operatorId,
    required String operatorName,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    final bodyHash = hashOperatorRequestBody(body);
    const route = 'POST $operatorTierEmailDataFreshnessRequestPath';
    try {
      return await _idempotencyCache.runOrReplay(
        operatorId: operatorId,
        route: route,
        idempotencyKey: idempotencyKey,
        requestBodyHash: bodyHash,
        compute: () => _dispatch(
          operatorId: operatorId,
          operatorName: operatorName,
          actorUserId: actorUserId,
          actorKind: actorKind,
          body: body,
        ),
      );
    } on OperatorWriteRejected catch (rejected) {
      return (
        statusCode: rejected.statusCode,
        body: <String, Object?>{
          'error': rejected.code,
          'message': rejected.message,
          ...rejected.extras,
        },
      );
    }
  }

  Future<({int statusCode, Map<String, Object?> body})> _dispatch({
    required String operatorId,
    required String operatorName,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> body,
  }) async {
    final parsed = _parseBody(body);
    if (parsed.error != null) return parsed.error!;

    final auditRowId = _auditRowIdFactory();
    final occurredAt = _now().toUtc();
    final auditPayload = <String, Object?>{
      'audit_row_id': auditRowId,
      'current_tier': parsed.currentTier,
      'requested_cadence': parsed.requestedCadence,
      'business_reason': parsed.businessReason,
      'recipient': _recipient,
      'submitted_at': occurredAt.toIso8601String(),
    };
    await auditSink.record(
      operatorId: operatorId,
      actorUserId: actorUserId,
      actorKind: actorKind,
      eventKind: kOperatorTierEmailAuditEventKind,
      payload: auditPayload,
      occurredAt: occurredAt,
    );

    EmailSendResult? sendResult;
    String? emailFailureMessage;
    try {
      sendResult = await emailProvider.send(
        EmailSendRequest(
          to: const EmailRecipient(email: kOperatorTierEmailRecipient),
          subject: _buildSubject(
            operatorName: operatorName,
            operatorId: operatorId,
          ),
          textBody: _buildTextBody(
            operatorName: operatorName,
            operatorId: operatorId,
            currentTier: parsed.currentTier!,
            requestedCadence: parsed.requestedCadence!,
            businessReason: parsed.businessReason!,
            submittedAtIso: occurredAt.toIso8601String(),
            auditRowId: auditRowId,
          ),
          htmlBody: _buildHtmlBody(
            operatorName: operatorName,
            operatorId: operatorId,
            currentTier: parsed.currentTier!,
            requestedCadence: parsed.requestedCadence!,
            businessReason: parsed.businessReason!,
            submittedAtIso: occurredAt.toIso8601String(),
            auditRowId: auditRowId,
          ),
          fromAddress: fromAddress,
          fromDisplayName: fromDisplayName,
          replyToAddress: fromAddress,
          providerMetadata: <String, String>{
            'origin': 'operator_tier_email_data_freshness_request',
            'audit_row_id': auditRowId,
          },
        ),
      );
    } on EmailProviderException catch (error) {
      emailFailureMessage = error.message;
      _sendErrorLogger?.call(
        operatorId: operatorId,
        actorUserId: actorUserId,
        auditRowId: auditRowId,
        error: error,
      );
    } catch (error) {
      emailFailureMessage = error.toString();
      _sendErrorLogger?.call(
        operatorId: operatorId,
        actorUserId: actorUserId,
        auditRowId: auditRowId,
        error: error,
      );
    }

    if (sendResult != null) {
      return (
        statusCode: 200,
        body: <String, Object?>{
          'ok': true,
          'audit_row_id': auditRowId,
          'provider_message_id': sendResult.providerMessageId,
        },
      );
    }
    return (
      statusCode: 502,
      body: <String, Object?>{
        'error': 'email_send_failed',
        'message':
            'request was logged but the email could not be sent; F&F support will pick it up from the audit log',
        'audit_row_id': auditRowId,
        if (emailFailureMessage != null) 'detail': emailFailureMessage,
      },
    );
  }

  ({
    ({int statusCode, Map<String, Object?> body})? error,
    String? currentTier,
    String? requestedCadence,
    String? businessReason,
  }) _parseBody(Map<String, Object?> body) {
    final currentTier = _readNonEmpty(
      body['current_tier'] ?? body['currentTier'],
    );
    final requestedCadence = _readNonEmpty(
      body['requested_cadence'] ?? body['requestedCadence'],
    );
    final businessReason = _readNonEmpty(
      body['business_reason'] ?? body['businessReason'],
    );
    if (currentTier == null) {
      return _bodyError('missing_current_tier', 'current_tier is required');
    }
    if (requestedCadence == null) {
      return _bodyError(
        'missing_requested_cadence',
        'requested_cadence is required',
      );
    }
    if (businessReason == null) {
      return _bodyError(
        'missing_business_reason',
        'business_reason is required',
      );
    }
    if (currentTier.length > 200 ||
        requestedCadence.length > 500 ||
        businessReason.length > 4000) {
      return _bodyError(
        'field_too_long',
        'current_tier, requested_cadence, and business_reason are bounded',
      );
    }
    return (
      error: null,
      currentTier: currentTier,
      requestedCadence: requestedCadence,
      businessReason: businessReason,
    );
  }

  ({
    ({int statusCode, Map<String, Object?> body})? error,
    String? currentTier,
    String? requestedCadence,
    String? businessReason,
  }) _bodyError(String code, String message) {
    return (
      error: (
        statusCode: 400,
        body: <String, Object?>{'error': code, 'message': message},
      ),
      currentTier: null,
      requestedCadence: null,
      businessReason: null,
    );
  }

  static String? _readNonEmpty(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _buildSubject({
    required String operatorName,
    required String operatorId,
  }) {
    final displayName = operatorName.trim().isEmpty
        ? operatorId
        : '${operatorName.trim()} ($operatorId)';
    return 'F&F data freshness request from $displayName';
  }

  String _buildTextBody({
    required String operatorName,
    required String operatorId,
    required String currentTier,
    required String requestedCadence,
    required String businessReason,
    required String submittedAtIso,
    required String auditRowId,
  }) {
    final operatorDisplay = operatorName.trim().isEmpty
        ? operatorId
        : '${operatorName.trim()} (operator_id: $operatorId)';
    return <String>[
      'Operator: $operatorDisplay',
      'Current tier: $currentTier',
      'Requested cadence: $requestedCadence',
      'Business reason: $businessReason',
      'Request submitted at: $submittedAtIso',
      'Audit row id: $auditRowId',
    ].join('\n');
  }

  String _buildHtmlBody({
    required String operatorName,
    required String operatorId,
    required String currentTier,
    required String requestedCadence,
    required String businessReason,
    required String submittedAtIso,
    required String auditRowId,
  }) {
    final operatorDisplay = operatorName.trim().isEmpty
        ? operatorId
        : '${_escapeHtml(operatorName.trim())} (operator_id: $operatorId)';
    final reason = _escapeHtml(businessReason).replaceAll('\n', '<br>');
    return <String>[
      '<p><strong>Operator:</strong> $operatorDisplay</p>',
      '<p><strong>Current tier:</strong> ${_escapeHtml(currentTier)}</p>',
      '<p><strong>Requested cadence:</strong> ${_escapeHtml(requestedCadence)}</p>',
      '<p><strong>Business reason:</strong><br>$reason</p>',
      '<p><strong>Request submitted at:</strong> $submittedAtIso</p>',
      '<p><strong>Audit row id:</strong> $auditRowId</p>',
    ].join('\n');
  }

  static String _escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}

String _defaultAuditRowIdFactory() {
  final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
  return 'audit-${stamp.toRadixString(16)}';
}

void _writeJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  response.close();
}
