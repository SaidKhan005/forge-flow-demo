// B10.1 - operator-web vendor applicability gateway.
//
// Read-only live adapter for:
//   GET /v1/operator/vendor-applicability?setting_kind=...
//
// Writes are intentionally admin-only at launch.

import 'dart:convert';

import 'package:http/http.dart' as http;

class WebVendorApplicabilityGatewayError implements Exception {
  const WebVendorApplicabilityGatewayError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'WebVendorApplicabilityGatewayError'
      '(code: $code, status: $statusCode, message: $message)';
}

class WebVendorApplicabilityRow {
  const WebVendorApplicabilityRow({
    required this.id,
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    required this.enabled,
    required this.metadata,
    required this.effectiveFrom,
    required this.effectiveUntil,
    required this.operatorId,
    required this.locationId,
    required this.createdAt,
    required this.createdBy,
  });

  final String id;
  final String? operatorId;
  final String? locationId;
  final String settingKind;
  final String settingKey;
  final String vendorSlug;
  final bool enabled;
  final Map<String, Object?> metadata;
  final DateTime effectiveFrom;
  final DateTime? effectiveUntil;
  final DateTime createdAt;
  final String createdBy;

  factory WebVendorApplicabilityRow.fromJson(Map<String, Object?> json) {
    final metadata = json['metadata'];
    if (metadata is! Map<String, Object?>) {
      throw const WebVendorApplicabilityGatewayError(
        code: 'malformed_response',
        message: 'row metadata was not an object',
      );
    }
    return WebVendorApplicabilityRow(
      id: _requireString(json, 'id'),
      operatorId: json['operator_id'] as String?,
      locationId: json['location_id'] as String?,
      settingKind: _requireString(json, 'setting_kind'),
      settingKey: _requireString(json, 'setting_key'),
      vendorSlug: _requireString(json, 'vendor_slug'),
      enabled: _requireBool(json, 'enabled'),
      metadata: Map<String, Object?>.unmodifiable(metadata),
      effectiveFrom: DateTime.parse(_requireString(json, 'effective_from')),
      effectiveUntil: _optionalDate(json, 'effective_until'),
      createdAt: DateTime.parse(_requireString(json, 'created_at')),
      createdBy: _requireString(json, 'created_by'),
    );
  }
}

abstract class WebVendorApplicabilityGateway {
  Future<List<WebVendorApplicabilityRow>> list({
    required String settingKind,
    String? settingKey,
  });
}

class HttpWebVendorApplicabilityGateway
    implements WebVendorApplicabilityGateway {
  HttpWebVendorApplicabilityGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? client,
  }) : _baseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _client = client ?? http.Client();

  static const String path = '/v1/operator/vendor-applicability';

  final Uri _baseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _client;

  @override
  Future<List<WebVendorApplicabilityRow>> list({
    required String settingKind,
    String? settingKey,
  }) async {
    final headers = await _authHeaders();
    final uri = _baseUri
        .resolve(path)
        .replace(
          queryParameters: <String, String>{
            'setting_kind': settingKind,
            if (settingKey != null && settingKey.trim().isNotEmpty)
              'setting_key': settingKey.trim(),
          },
        );
    final response = await _client.get(uri, headers: headers);
    final body = _decode(response);
    final rows = body['rows'];
    if (rows is! List) {
      throw WebVendorApplicabilityGatewayError(
        code: 'malformed_response',
        message: 'response missing `rows` array',
        statusCode: response.statusCode,
      );
    }
    return <WebVendorApplicabilityRow>[
      for (final row in rows)
        if (row is Map<String, Object?>)
          WebVendorApplicabilityRow.fromJson(row),
    ];
  }

  Future<Map<String, String>> _authHeaders() async {
    final token = await _idTokenProvider();
    if (token == null || token.isEmpty) {
      throw const WebVendorApplicabilityGatewayError(
        code: 'unauthenticated',
        message: 'Not signed in',
      );
    }
    return <String, String>{
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
    };
  }

  Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?> body;
    try {
      body = jsonDecode(response.body) as Map<String, Object?>;
    } catch (_) {
      throw WebVendorApplicabilityGatewayError(
        code: 'malformed_response',
        message: 'response body was not JSON',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      throw WebVendorApplicabilityGatewayError(
        code: (body['error'] as String?) ?? 'request_failed',
        message: (body['message'] as String?) ?? 'request failed',
        statusCode: response.statusCode,
      );
    }
    return body;
  }
}

String _requireString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw WebVendorApplicabilityGatewayError(
    code: 'malformed_response',
    message: 'row missing `$key`',
  );
}

bool _requireBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw WebVendorApplicabilityGatewayError(
    code: 'malformed_response',
    message: 'row missing `$key`',
  );
}

DateTime? _optionalDate(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return DateTime.parse(value);
  throw WebVendorApplicabilityGatewayError(
    code: 'malformed_response',
    message: 'row had invalid `$key`',
  );
}
