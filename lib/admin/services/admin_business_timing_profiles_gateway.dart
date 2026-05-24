// Admin business-timing PROFILE write gateway (timing-editable parity).
//
// Thin HTTP client over the admin business-timing PROFILE CRUD routes
// (distinct from the READ-ONLY resolution gateway in
// `admin_business_timing_resolution_gateway.dart`):
//
//   GET   /v1/admin/operators/:operatorId/business-timing-profiles
//         (list; super_admin | ff_support)
//   POST  /v1/admin/operators/:operatorId/business-timing-profiles
//         (create; super_admin only)
//   PATCH /v1/admin/operators/:operatorId/business-timing-profiles/:profileId
//         (update; super_admin only)
//
// Writes require an `Idempotency-Key` header and a non-empty
// `admin_reason` in the JSON body (the server returns
// `400 missing_admin_reason` otherwise). Every successful write is
// audited server-side (hash-chained audit log) and is closed-shift safe
// (HP#3). Server contract:
// `tool/advisor_proxy/admin_business_timing_routes.dart`
// (`AdminBusinessTimingRouter`). The request/result shapes mirror the
// operator-web `WebBusinessTimingGateway` so the ported editor speaks
// the same model on both surfaces; the only admin-side additions are the
// URL `operatorId` (cross-tenant convention) and the `admin_reason`.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'admin_business_timing_resolution_gateway.dart'
    show AdminBearerTokenProvider, AdminResolutionServicePeriod;
import 'admin_http_timeout.dart';

/// Error type for admin business-timing profile reads/writes. Carries an
/// HTTP-style status code + machine-readable error code so the admin
/// editor can branch on `missing_admin_reason` / `permission_denied` /
/// validation codes without parsing `message`.
class AdminBusinessTimingProfileGatewayError implements Exception {
  const AdminBusinessTimingProfileGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() => 'AdminBusinessTimingProfileGatewayError('
      '$statusCode/$errorCode): $message';
}

/// Service-period payload for create/update. Mirrors the operator-web
/// `ServicePeriodCreate` shape (no `rollsPastMidnight` — the server
/// derives it). `applicableDays` are ISO weekdays (1=Mon..7=Sun).
class AdminServicePeriodWrite {
  const AdminServicePeriodWrite({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
    this.applicableDays = const <int>[1, 2, 3, 4, 5, 6, 7],
    this.shortLabel = '',
    this.sortOrder = 0,
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;
  final List<int> applicableDays;
  final String shortLabel;
  final int sortOrder;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'label': label,
        'startLocal': startLocal,
        'endLocal': endLocal,
        'applicableDays': applicableDays,
        'shortLabel': shortLabel,
        'sortOrder': sortOrder,
      };
}

/// Full create payload for `POST .../business-timing-profiles`. Mirrors
/// operator-web `BusinessTimingProfileCreate`. `admin_reason` is NOT part
/// of this object — the gateway method takes it separately and injects it
/// so the editor never forgets the server-required reason.
class AdminBusinessTimingProfileCreate {
  const AdminBusinessTimingProfileCreate({
    required this.scopeKind,
    required this.scopeId,
    required this.effectiveAtBusinessDate,
    required this.ianaTimezone,
    required this.weekStartDay,
    required this.businessDayStartLocal,
    required this.servicePeriods,
  });

  final String scopeKind;
  final String scopeId;
  final String effectiveAtBusinessDate;
  final String ianaTimezone;
  final String weekStartDay;
  final String businessDayStartLocal;
  final List<AdminServicePeriodWrite> servicePeriods;

  Map<String, Object?> toJson() => <String, Object?>{
        'scopeKind': scopeKind,
        'scopeId': scopeId,
        'effectiveAtBusinessDate': effectiveAtBusinessDate,
        'ianaTimezone': ianaTimezone,
        'weekStartDay': weekStartDay,
        'businessDayStartLocal': businessDayStartLocal,
        'servicePeriods': <Map<String, Object?>>[
          for (final period in servicePeriods) period.toJson(),
        ],
      };
}

/// Partial update payload for `PATCH .../business-timing-profiles/:id`.
/// All fields optional; only non-null fields are sent. Mirrors
/// operator-web `BusinessTimingProfilePatch` so the same server validator
/// (`validateProfilePatch` + immutable-field guard) applies identically.
/// A non-null [servicePeriods] REPLACES the whole set (whole-set
/// override semantics).
class AdminBusinessTimingProfilePatch {
  const AdminBusinessTimingProfilePatch({
    this.effectiveAtBusinessDate,
    this.ianaTimezone,
    this.weekStartDay,
    this.businessDayStartLocal,
    this.servicePeriods,
  });

  final String? effectiveAtBusinessDate;
  final String? ianaTimezone;
  final String? weekStartDay;
  final String? businessDayStartLocal;
  final List<AdminServicePeriodWrite>? servicePeriods;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (effectiveAtBusinessDate != null) {
      json['effectiveAtBusinessDate'] = effectiveAtBusinessDate;
    }
    if (ianaTimezone != null) json['ianaTimezone'] = ianaTimezone;
    if (weekStartDay != null) json['weekStartDay'] = weekStartDay;
    if (businessDayStartLocal != null) {
      json['businessDayStartLocal'] = businessDayStartLocal;
    }
    if (servicePeriods != null) {
      json['servicePeriods'] = <Map<String, Object?>>[
        for (final period in servicePeriods!) period.toJson(),
      ];
    }
    return json;
  }
}

/// Parsed profile record returned by list/create/update. Mirrors the
/// operator-web `BusinessTimingProfileWriteResult`; service periods reuse
/// the read gateway's [AdminResolutionServicePeriod] (identical wire
/// shape, including the server-derived `rollsPastMidnight`).
class AdminBusinessTimingProfileRecord {
  const AdminBusinessTimingProfileRecord({
    required this.profileId,
    required this.versionId,
    required this.scopeKind,
    required this.scopeId,
    required this.effectiveAtBusinessDate,
    required this.ianaTimezone,
    required this.weekStartDay,
    required this.businessDayStartLocal,
    required this.servicePeriods,
  });

  final String profileId;
  final String versionId;
  final String scopeKind;
  final String scopeId;
  final String effectiveAtBusinessDate;
  final String ianaTimezone;
  final String weekStartDay;
  final String businessDayStartLocal;
  final List<AdminResolutionServicePeriod> servicePeriods;

  static AdminBusinessTimingProfileRecord fromJson(Map<String, Object?> json) {
    final profileId = (json['profileId'] as String?) ?? '';
    return AdminBusinessTimingProfileRecord(
      profileId: profileId,
      // V1: profile_id doubles as version_id; accept either key.
      versionId: (json['versionId'] as String?) ?? profileId,
      scopeKind:
          (json['scopeKind'] as String?) ?? (json['scopeType'] as String?) ?? '',
      scopeId: (json['scopeId'] as String?) ?? '',
      effectiveAtBusinessDate:
          (json['effectiveAtBusinessDate'] as String?) ?? '',
      ianaTimezone: (json['ianaTimezone'] as String?) ?? 'UTC',
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

abstract class AdminBusinessTimingProfilesGateway {
  /// Lists every business-timing profile owned by [operatorId].
  Future<List<AdminBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  });

  /// Creates a new profile for [operatorId]. Requires a non-empty
  /// [adminReason] and a caller-minted [idempotencyKey].
  Future<AdminBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required AdminBusinessTimingProfileCreate profile,
    required String adminReason,
    required String idempotencyKey,
  });

  /// Patches an existing profile. Requires a non-empty [adminReason] and a
  /// caller-minted [idempotencyKey].
  Future<AdminBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String profileId,
    required AdminBusinessTimingProfilePatch patch,
    required String adminReason,
    required String idempotencyKey,
  });
}

class HttpAdminBusinessTimingProfilesGateway
    implements AdminBusinessTimingProfilesGateway {
  HttpAdminBusinessTimingProfilesGateway({
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

  static String profilesPath(String operatorId) =>
      '/v1/admin/operators/${Uri.encodeComponent(operatorId)}'
      '/business-timing-profiles';

  static String profilePath(String operatorId, String profileId) =>
      '${profilesPath(operatorId)}/${Uri.encodeComponent(profileId)}';

  @override
  Future<List<AdminBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  }) async {
    final uri = baseUri.resolve(profilesPath(operatorId));
    final request = http.Request('GET', uri)
      ..headers['authorization'] = 'Bearer ${await bearerTokenProvider()}'
      ..headers['accept'] = 'application/json';
    final body = await _send(request, expected: 200);
    final raw = body['profiles'];
    if (raw is! List) {
      throw const AdminBusinessTimingProfileGatewayError(
        statusCode: 502,
        errorCode: 'malformed_profile_list',
        message: 'The proxy returned an incomplete timing profile list.',
      );
    }
    return <AdminBusinessTimingProfileRecord>[
      for (final item in raw)
        if (item is Map)
          AdminBusinessTimingProfileRecord.fromJson(
            item.cast<String, Object?>(),
          ),
    ];
  }

  @override
  Future<AdminBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required AdminBusinessTimingProfileCreate profile,
    required String adminReason,
    required String idempotencyKey,
  }) async {
    final uri = baseUri.resolve(profilesPath(operatorId));
    final payload = <String, Object?>{
      ...profile.toJson(),
      'admin_reason': adminReason,
    };
    final request = _jsonWrite('POST', uri, payload, idempotencyKey,
        await bearerTokenProvider());
    final body = await _send(request, expected: 201);
    return AdminBusinessTimingProfileRecord.fromJson(body);
  }

  @override
  Future<AdminBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String profileId,
    required AdminBusinessTimingProfilePatch patch,
    required String adminReason,
    required String idempotencyKey,
  }) async {
    final uri = baseUri.resolve(profilePath(operatorId, profileId));
    final payload = <String, Object?>{
      ...patch.toJson(),
      'admin_reason': adminReason,
    };
    final request = _jsonWrite('PATCH', uri, payload, idempotencyKey,
        await bearerTokenProvider());
    final body = await _send(request, expected: 200);
    return AdminBusinessTimingProfileRecord.fromJson(body);
  }

  http.Request _jsonWrite(
    String method,
    Uri uri,
    Map<String, Object?> payload,
    String idempotencyKey,
    String token,
  ) {
    return http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json'
      ..headers['content-type'] = 'application/json'
      ..headers['idempotency-key'] = idempotencyKey
      ..body = jsonEncode(payload);
  }

  Future<Map<String, Object?>> _send(
    http.Request request, {
    required int expected,
  }) async {
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
    if (response.statusCode != expected) {
      throw AdminBusinessTimingProfileGatewayError(
        statusCode: response.statusCode,
        errorCode: (body['error'] as String?) ?? 'request_failed',
        message: (body['message'] as String?) ??
            'admin business-timing profile write failed',
      );
    }
    return body;
  }
}
