// Fix #4 / S2 — Admin business-timing resolution read gateway.
//
// Admin-side analogue of the operator-web business-timing read
// gateway. Thin HTTP client over the S2 admin route:
//
//   GET /v1/admin/operators/:operatorId/locations/:locationId/
//       business-timing-resolution[?business_date=YYYY-MM-DD]
//
// READ-ONLY. The admin Flutter client never holds a Postgres
// connection string and never reaches the database directly — every
// read flows through the F&F admin proxy with the signed-in admin's
// bearer token. operatorId AND locationId are URL path segments (the
// established admin cross-tenant convention); the proxy gates the
// route to super_admin / ff_support and reaches the sanctioned
// `runAsSystem` admin bypass server-side. No write path, no
// idempotency surface.
//
// The proxy returns the FULL canonical candidate chain in
// `scope_depth` order with scope ancestry + location timezone + full
// service-period fields. This gateway only parses + carries that
// shape; the caller (S4 admin timing surfaces) runs the ONE pure
// `BusinessTimingProfileResolver` over the candidates — there is no
// server-side resolver fork and this gateway adds none.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'admin_http_timeout.dart';

/// Source for the bearer token attached to every proxy call.
/// Production binds this to the admin Firebase ID-token stream; tests
/// pin a synthetic value.
typedef AdminBearerTokenProvider = Future<String> Function();

/// Top-level error type for resolution reads. Carries an HTTP-style
/// status code + machine-readable error code so the admin screen can
/// branch on `permission_denied` / `invalid_business_date` etc.
/// without parsing `message`.
class AdminBusinessTimingResolutionGatewayError implements Exception {
  const AdminBusinessTimingResolutionGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() => 'AdminBusinessTimingResolutionGatewayError('
      '$statusCode/$errorCode): $message';
}

/// One service period on a resolution candidate. Mirrors the wire
/// fields the proxy emits (`OperatorBusinessTimingServicePeriodRecord`),
/// including the `shortLabel` / `sortOrder` / `applicableDays` the
/// pre-S1 wire dropped.
class AdminResolutionServicePeriod {
  const AdminResolutionServicePeriod({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
    required this.rollsPastMidnight,
    required this.shortLabel,
    required this.sortOrder,
    required this.applicableDays,
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;
  final bool rollsPastMidnight;
  final String shortLabel;
  final int sortOrder;
  final List<int> applicableDays;

  static AdminResolutionServicePeriod fromJson(Map<String, Object?> json) {
    return AdminResolutionServicePeriod(
      key: (json['key'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      startLocal: (json['startLocal'] as String?) ?? '',
      endLocal: (json['endLocal'] as String?) ?? '',
      rollsPastMidnight: (json['rollsPastMidnight'] as bool?) ?? false,
      shortLabel: (json['shortLabel'] as String?) ?? '',
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      applicableDays: <int>[
        for (final d in (json['applicableDays'] as List?) ?? const <Object?>[])
          (d as num).toInt(),
      ],
    );
  }
}

/// One candidate in the location-scoped resolution chain, in canonical
/// resolver precedence order (operator default first, location
/// override last). Carries the scope ancestry the wire previously
/// dropped (`scopeType`, `scopeId`, a non-blank `scopeLabel`,
/// `scopeDepthRank`) plus the location timezone the resolver needs.
class AdminResolutionCandidate {
  const AdminResolutionCandidate({
    required this.profileId,
    required this.scopeType,
    required this.scopeId,
    required this.scopeLabel,
    required this.scopeDepthRank,
    required this.ianaTimezone,
    required this.effectiveAtBusinessDate,
    required this.weekStartDay,
    required this.businessDayStartLocal,
    required this.servicePeriods,
  });

  final String profileId;
  final String scopeType;
  final String scopeId;
  final String scopeLabel;
  final int scopeDepthRank;
  final String ianaTimezone;
  final String effectiveAtBusinessDate;
  final String weekStartDay;
  final String businessDayStartLocal;
  final List<AdminResolutionServicePeriod> servicePeriods;

  static AdminResolutionCandidate fromJson(Map<String, Object?> json) {
    return AdminResolutionCandidate(
      profileId: (json['profileId'] as String?) ?? '',
      scopeType: (json['scopeType'] as String?) ?? '',
      scopeId: (json['scopeId'] as String?) ?? '',
      scopeLabel: (json['scopeLabel'] as String?) ?? '',
      scopeDepthRank: (json['scopeDepthRank'] as num?)?.toInt() ?? 0,
      ianaTimezone: (json['ianaTimezone'] as String?) ?? 'UTC',
      effectiveAtBusinessDate:
          (json['effectiveAtBusinessDate'] as String?) ?? '',
      weekStartDay: (json['weekStartDay'] as String?) ?? '',
      businessDayStartLocal: (json['businessDayStartLocal'] as String?) ?? '',
      servicePeriods: <AdminResolutionServicePeriod>[
        for (final p
            in (json['servicePeriods'] as List?) ?? const <Object?>[])
          AdminResolutionServicePeriod.fromJson(
            (p as Map).cast<String, Object?>(),
          ),
      ],
    );
  }
}

/// Parsed response of the admin business-timing resolution route.
class AdminBusinessTimingResolution {
  const AdminBusinessTimingResolution({
    required this.operatorId,
    required this.locationId,
    required this.businessDate,
    required this.ianaTimezone,
    required this.candidates,
  });

  final String operatorId;
  final String locationId;
  final String businessDate;

  /// `locations.timezone` for the resolved location. Null only when
  /// the location row is missing (empty candidate list).
  final String? ianaTimezone;
  final List<AdminResolutionCandidate> candidates;

  static AdminBusinessTimingResolution fromJson(Map<String, Object?> json) {
    return AdminBusinessTimingResolution(
      operatorId: (json['operatorId'] as String?) ?? '',
      locationId: (json['locationId'] as String?) ?? '',
      businessDate: (json['businessDate'] as String?) ?? '',
      ianaTimezone: json['ianaTimezone'] as String?,
      candidates: <AdminResolutionCandidate>[
        for (final c in (json['candidates'] as List?) ?? const <Object?>[])
          AdminResolutionCandidate.fromJson(
            (c as Map).cast<String, Object?>(),
          ),
      ],
    );
  }
}

abstract class AdminBusinessTimingResolutionGateway {
  /// Reads the canonical location-scoped business-timing candidate
  /// chain for [operatorId] / [locationId] on [businessDate] (defaults
  /// to UTC-today server-side when null). READ-ONLY.
  Future<AdminBusinessTimingResolution> resolve({
    required String operatorId,
    required String locationId,
    String? businessDate,
  });
}

class HttpAdminBusinessTimingResolutionGateway
    implements AdminBusinessTimingResolutionGateway {
  HttpAdminBusinessTimingResolutionGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`).
  final Uri baseUri;
  final AdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<AdminBusinessTimingResolution> resolve({
    required String operatorId,
    required String locationId,
    String? businessDate,
  }) async {
    final path = '/v1/admin/operators/${Uri.encodeComponent(operatorId)}'
        '/locations/${Uri.encodeComponent(locationId)}'
        '/business-timing-resolution';
    var uri = baseUri.resolve(path);
    if (businessDate != null && businessDate.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{'business_date': businessDate},
      );
    }
    final token = await bearerTokenProvider();
    final request = http.Request('GET', uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    final response = await sendAdminHttpRequest(
      _httpClient,
      request,
      timeout: _timeout,
    );
    final Map<String, Object?> body;
    if (response.body.isEmpty) {
      body = const <String, Object?>{};
    } else {
      final decoded = jsonDecode(response.body);
      body = decoded is Map
          ? decoded.cast<String, Object?>()
          : const <String, Object?>{};
    }
    if (response.statusCode != 200) {
      throw AdminBusinessTimingResolutionGatewayError(
        statusCode: response.statusCode,
        errorCode: (body['error'] as String?) ?? 'request_failed',
        message: (body['message'] as String?) ??
            'admin business-timing resolution read failed',
      );
    }
    return AdminBusinessTimingResolution.fromJson(body);
  }
}
