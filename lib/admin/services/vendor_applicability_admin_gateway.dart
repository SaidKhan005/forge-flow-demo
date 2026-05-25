// B10.1 - Admin gateway for /v1/admin/vendor-applicability.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'admin_http_timeout.dart';

typedef VendorApplicabilityAdminBearerTokenProvider = Future<String> Function();

class VendorApplicabilityAdminGatewayError implements Exception {
  const VendorApplicabilityAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'VendorApplicabilityAdminGatewayError($statusCode/$errorCode): $message';
}

class VendorApplicabilityAdminFilter {
  const VendorApplicabilityAdminFilter({
    this.operatorId,
    this.locationId,
    this.settingKind,
    this.settingKey,
    this.vendorSlug,
    this.currentOnly = true,
  });

  final String? operatorId;

  /// Optional location narrowing. A location filter only makes sense
  /// alongside an operator filter (a location-scoped row always has an
  /// operator); the server still treats it as additive.
  final String? locationId;
  final String? settingKind;
  final String? settingKey;
  final String? vendorSlug;
  final bool currentOnly;

  Map<String, String> toQueryParameters() => <String, String>{
    if (operatorId != null && operatorId!.isNotEmpty)
      'operator_id': operatorId!,
    if (locationId != null && locationId!.isNotEmpty)
      'location_id': locationId!,
    if (settingKind != null && settingKind!.isNotEmpty)
      'setting_kind': settingKind!,
    if (settingKey != null && settingKey!.isNotEmpty)
      'setting_key': settingKey!,
    if (vendorSlug != null && vendorSlug!.isNotEmpty)
      'vendor_slug': vendorSlug!,
    'current_only': currentOnly.toString(),
  };
}

class VendorApplicabilityUpsertCommand {
  const VendorApplicabilityUpsertCommand({
    this.operatorId,
    this.locationId,
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    required this.enabled,
    this.metadata = const <String, Object?>{},
    this.effectiveFrom,
    required this.adminReason,
    this.reasonNote,
    required this.idempotencyKey,
  });

  final String? operatorId;

  /// Optional location narrowing. NULL = operator-level (when
  /// [operatorId] is set) or global (when [operatorId] is null). A
  /// non-null value scopes the rule to one location and requires
  /// [operatorId] (mirrors the DB CHECK + proxy validation).
  final String? locationId;
  final String settingKind;
  final String settingKey;
  final String vendorSlug;
  final bool enabled;
  final Map<String, Object?> metadata;
  final DateTime? effectiveFrom;
  final String adminReason;
  final String? reasonNote;
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    if (operatorId != null && operatorId!.isNotEmpty) 'operator_id': operatorId,
    if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId,
    'setting_kind': settingKind,
    'setting_key': settingKey,
    'vendor_slug': vendorSlug,
    'enabled': enabled,
    'metadata': metadata,
    if (effectiveFrom != null)
      'effective_from': effectiveFrom!.toUtc().toIso8601String(),
    'admin_reason': adminReason,
    if (reasonNote != null && reasonNote!.isNotEmpty) 'reason_note': reasonNote,
  };
}

class VendorApplicabilityEndCommand {
  const VendorApplicabilityEndCommand({
    this.operatorId,
    this.locationId,
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    this.effectiveUntil,
    required this.adminReason,
    this.reasonNote,
    required this.idempotencyKey,
  });

  final String? operatorId;

  /// Optional location narrowing, matching the row being ended. NULL
  /// closes the operator-level (or global) row; a non-null value closes
  /// exactly the location-scoped row and requires [operatorId].
  final String? locationId;
  final String settingKind;
  final String settingKey;
  final String vendorSlug;
  final DateTime? effectiveUntil;
  final String adminReason;
  final String? reasonNote;
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'action': 'end',
    if (operatorId != null && operatorId!.isNotEmpty) 'operator_id': operatorId,
    if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId,
    'setting_kind': settingKind,
    'setting_key': settingKey,
    'vendor_slug': vendorSlug,
    if (effectiveUntil != null)
      'effective_until': effectiveUntil!.toUtc().toIso8601String(),
    'admin_reason': adminReason,
    if (reasonNote != null && reasonNote!.isNotEmpty) 'reason_note': reasonNote,
  };
}

class VendorApplicabilityAdminRow {
  const VendorApplicabilityAdminRow({
    required this.id,
    required this.operatorId,
    this.locationId,
    required this.settingKind,
    required this.settingKey,
    required this.vendorSlug,
    required this.enabled,
    required this.metadata,
    required this.effectiveFrom,
    required this.effectiveUntil,
    required this.createdAt,
    required this.createdBy,
  });

  final String id;
  final String? operatorId;

  /// Optional location narrowing. NULL = operator-level (when
  /// [operatorId] is set) or global (when [operatorId] is null); a
  /// non-null value scopes the row to one location.
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

  static VendorApplicabilityAdminRow fromJson(Map<String, Object?> json) {
    return VendorApplicabilityAdminRow(
      id: _string(json, 'id'),
      operatorId: _optionalString(json, 'operator_id'),
      locationId: _optionalString(json, 'location_id'),
      settingKind: _string(json, 'setting_kind'),
      settingKey: _string(json, 'setting_key'),
      vendorSlug: _string(json, 'vendor_slug'),
      enabled: json['enabled'] == true,
      metadata: _map(json['metadata']),
      effectiveFrom: DateTime.parse(_string(json, 'effective_from')).toUtc(),
      effectiveUntil: _dateOrNull(json['effective_until']),
      createdAt: DateTime.parse(_string(json, 'created_at')).toUtc(),
      createdBy: _string(json, 'created_by'),
    );
  }
}

abstract class VendorApplicabilityAdminGateway {
  Future<List<VendorApplicabilityAdminRow>> list({
    VendorApplicabilityAdminFilter filter =
        const VendorApplicabilityAdminFilter(),
  });

  Future<VendorApplicabilityAdminRow> upsert(
    VendorApplicabilityUpsertCommand command,
  );

  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  );
}

class HttpVendorApplicabilityAdminGateway
    implements VendorApplicabilityAdminGateway {
  HttpVendorApplicabilityAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri baseUri;
  final VendorApplicabilityAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String path = '/v1/admin/vendor-applicability';

  @override
  Future<List<VendorApplicabilityAdminRow>> list({
    VendorApplicabilityAdminFilter filter =
        const VendorApplicabilityAdminFilter(),
  }) async {
    final body = await _send(
      method: 'GET',
      path: path,
      queryParameters: filter.toQueryParameters(),
    );
    final rows = (body['rows'] as List?) ?? const [];
    return <VendorApplicabilityAdminRow>[
      for (final row in rows)
        VendorApplicabilityAdminRow.fromJson(
          (row as Map).cast<String, Object?>(),
        ),
    ];
  }

  @override
  Future<VendorApplicabilityAdminRow> upsert(
    VendorApplicabilityUpsertCommand command,
  ) async {
    final body = await _send(
      method: 'POST',
      path: path,
      jsonBody: command.toJson(),
      idempotencyKey: command.idempotencyKey,
    );
    return VendorApplicabilityAdminRow.fromJson(
      (body['row'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) async {
    final body = await _send(
      method: 'PATCH',
      path: path,
      jsonBody: command.toJson(),
      idempotencyKey: command.idempotencyKey,
    );
    final row = body['row'];
    if (row is! Map) return null;
    return VendorApplicabilityAdminRow.fromJson(row.cast<String, Object?>());
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path).replace(queryParameters: queryParameters);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }

    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw VendorApplicabilityAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin vendor applicability proxy timed out after '
            '${_timeout.inSeconds}s',
      );
    }

    final parsed = _parseBody(response.bodyBytes);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    throw VendorApplicabilityAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: _optionalString(parsed, 'error') ?? 'request_failed',
      message:
          _optionalString(parsed, 'message') ??
          'vendor applicability request failed',
    );
  }
}

Map<String, Object?> _parseBody(List<int> bytes) {
  final raw = utf8.decode(bytes);
  if (raw.isEmpty) return const <String, Object?>{};
  final decoded = jsonDecode(raw);
  if (decoded is Map) return decoded.cast<String, Object?>();
  return const <String, Object?>{};
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('missing $key');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  return null;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  return const <String, Object?>{};
}

DateTime? _dateOrNull(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.parse(value).toUtc();
}
