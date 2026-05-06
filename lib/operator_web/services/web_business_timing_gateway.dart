// Phase 11W.7 / Wave A2 - Operator-scoped business timing write gateway.
//
// Thin HTTP client over the four operator-scoped business-timing
// write routes. The BusinessTimingEditorScreen calls this gateway to
// create a profile, update a profile, add a service period, or
// update a service period in place.
//
// Route contract (operator-scoped, NOT /v1/admin/*):
//   POST   /v1/operator/business-timing-profiles
//   PATCH  /v1/operator/business-timing-profiles/:id
//   POST   /v1/operator/business-timing-profiles/:id/service-periods
//   PATCH  /v1/operator/business-timing-profiles/:id/service-periods/:key
//
// Lane 0 / A0 decision (db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql):
// `business_timing_profiles.profile_id` doubles as `version_id` at V1.
// The response model exposes both keys so callers do not need to know
// the equivalence; downstream lanes (when a dedicated versions table
// arrives) only need to start populating a distinct version_id.

import 'package:flutter/foundation.dart';

import 'operator_web_proxy_client.dart';

/// Operator-scoped business-timing write surface. Never produces an
/// `/admin/` path; cross-tenant timing overrides live behind the
/// F&F Ops Console (separate worktree).
abstract class WebBusinessTimingGateway {
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  );

  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  });

  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  });

  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  });
}

class HttpWebBusinessTimingGateway implements WebBusinessTimingGateway {
  HttpWebBusinessTimingGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
  })  : _client = client,
        _idTokenProvider = idTokenProvider;

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  /// Operator-scoped collection. Path constants surface so unit tests
  /// can grep them and assert no `/admin/` prefix is ever produced.
  static const String operatorProfilesPath =
      '/v1/operator/business-timing-profiles';

  static String operatorProfilePath(String profileId) =>
      '$operatorProfilesPath/${Uri.encodeComponent(profileId)}';

  static String operatorServicePeriodsPath(String profileId) =>
      '${operatorProfilePath(profileId)}/service-periods';

  static String operatorServicePeriodPath(String profileId, String key) =>
      '${operatorServicePeriodsPath(profileId)}/${Uri.encodeComponent(key)}';

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async {
    _assertOperatorPath(operatorProfilesPath);
    final token = await _requireToken();
    final response = await _client.postJson(
      operatorProfilesPath,
      idToken: token,
      body: request.toJson(),
    );
    return BusinessTimingProfileWriteResult.fromJson(response.body);
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  }) async {
    final path = operatorProfilePath(profileId);
    _assertOperatorPath(path);
    final token = await _requireToken();
    final response = await _client.patchJson(
      path,
      idToken: token,
      body: patch.toJson(),
    );
    return BusinessTimingProfileWriteResult.fromJson(response.body);
  }

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async {
    final path = operatorServicePeriodsPath(profileId);
    _assertOperatorPath(path);
    final token = await _requireToken();
    final response = await _client.postJson(
      path,
      idToken: token,
      body: period.toJson(),
    );
    return BusinessTimingProfileWriteResult.fromJson(response.body);
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async {
    final path = operatorServicePeriodPath(profileId, key);
    _assertOperatorPath(path);
    final token = await _requireToken();
    final response = await _client.patchJson(
      path,
      idToken: token,
      body: patch.toJson(),
    );
    return BusinessTimingProfileWriteResult.fromJson(response.body);
  }

  Future<String> _requireToken() async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebProxyException(
        code: 'unauthenticated',
        message: 'Sign in again to edit business timing.',
      );
    }
    return token;
  }

  /// Belt and suspenders: the gateway must never produce an /admin/
  /// URL. Any drift surfaces as a loud test failure rather than a
  /// silent permissions escalation.
  static void _assertOperatorPath(String path) {
    if (path.contains('/admin/')) {
      throw _OperatorPathViolation(path);
    }
    if (!path.startsWith('/v1/operator/business-timing-profiles')) {
      throw _OperatorPathViolation(path);
    }
  }
}

/// Service-period payload shared by create and read paths.
@immutable
class ServicePeriod {
  const ServicePeriod({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
    required this.rollsPastMidnight,
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;
  final bool rollsPastMidnight;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'label': label,
        'startLocal': startLocal,
        'endLocal': endLocal,
        'rollsPastMidnight': rollsPastMidnight,
      };

  static ServicePeriod fromJson(Map<String, Object?> json) {
    final key = _readString(json['key']);
    final label = _readString(json['label']);
    final startLocal = _readString(json['startLocal']);
    final endLocal = _readString(json['endLocal']);
    if (key == null ||
        label == null ||
        startLocal == null ||
        endLocal == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_service_period',
        message: 'The proxy returned an incomplete service period.',
      );
    }
    return ServicePeriod(
      key: key,
      label: label,
      startLocal: startLocal,
      endLocal: endLocal,
      rollsPastMidnight: json['rollsPastMidnight'] == true,
    );
  }
}

@immutable
class ServicePeriodCreate {
  const ServicePeriodCreate({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'label': label,
        'startLocal': startLocal,
        'endLocal': endLocal,
      };
}

@immutable
class ServicePeriodPatch {
  const ServicePeriodPatch({this.label, this.startLocal, this.endLocal});

  final String? label;
  final String? startLocal;
  final String? endLocal;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (label != null) json['label'] = label;
    if (startLocal != null) json['startLocal'] = startLocal;
    if (endLocal != null) json['endLocal'] = endLocal;
    return json;
  }
}

@immutable
class BusinessTimingProfileCreate {
  const BusinessTimingProfileCreate({
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
  final List<ServicePeriodCreate> servicePeriods;

  Map<String, Object?> toJson() => <String, Object?>{
        'scopeKind': scopeKind,
        'scopeId': scopeId,
        'effectiveAtBusinessDate': effectiveAtBusinessDate,
        'ianaTimezone': ianaTimezone,
        'weekStartDay': weekStartDay,
        'businessDayStartLocal': businessDayStartLocal,
        'servicePeriods':
            servicePeriods.map((period) => period.toJson()).toList(),
      };
}

@immutable
class BusinessTimingProfilePatch {
  const BusinessTimingProfilePatch({
    this.scopeKind,
    this.scopeId,
    this.effectiveAtBusinessDate,
    this.ianaTimezone,
    this.weekStartDay,
    this.businessDayStartLocal,
    this.servicePeriods,
  });

  final String? scopeKind;
  final String? scopeId;
  final String? effectiveAtBusinessDate;
  final String? ianaTimezone;
  final String? weekStartDay;
  final String? businessDayStartLocal;

  /// When non-null, REPLACES the entire service-period set on the
  /// server. This matches business_timing_live_plan.md's whole-set
  /// semantics: a non-empty set on a lower-scope profile fully
  /// overrides any inherited periods.
  final List<ServicePeriodCreate>? servicePeriods;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (scopeKind != null) json['scopeKind'] = scopeKind;
    if (scopeId != null) json['scopeId'] = scopeId;
    if (effectiveAtBusinessDate != null) {
      json['effectiveAtBusinessDate'] = effectiveAtBusinessDate;
    }
    if (ianaTimezone != null) json['ianaTimezone'] = ianaTimezone;
    if (weekStartDay != null) json['weekStartDay'] = weekStartDay;
    if (businessDayStartLocal != null) {
      json['businessDayStartLocal'] = businessDayStartLocal;
    }
    if (servicePeriods != null) {
      json['servicePeriods'] =
          servicePeriods!.map((period) => period.toJson()).toList();
    }
    return json;
  }
}

@immutable
class BusinessTimingProfileWriteResult {
  const BusinessTimingProfileWriteResult({
    required this.profileId,
    required this.versionId,
    required this.scopeKind,
    required this.scopeId,
    required this.effectiveAtBusinessDate,
    required this.ianaTimezone,
    required this.weekStartDay,
    required this.businessDayStartLocal,
    required this.servicePeriods,
    required this.createdAt,
    required this.updatedAt,
  });

  final String profileId;
  final String versionId;
  final String scopeKind;
  final String scopeId;
  final String effectiveAtBusinessDate;
  final String ianaTimezone;
  final String weekStartDay;
  final String businessDayStartLocal;
  final List<ServicePeriod> servicePeriods;
  final DateTime createdAt;
  final DateTime updatedAt;

  static BusinessTimingProfileWriteResult fromJson(Map<String, Object?> json) {
    final profileId = _readString(json['profileId']);
    final versionId = _readString(json['versionId']);
    final scopeKind = _readString(json['scopeKind']);
    final scopeId = _readString(json['scopeId']);
    final effectiveAtBusinessDate =
        _readString(json['effectiveAtBusinessDate']);
    final ianaTimezone = _readString(json['ianaTimezone']);
    final weekStartDay = _readString(json['weekStartDay']);
    final businessDayStartLocal = _readString(json['businessDayStartLocal']);
    final createdAtRaw = _readString(json['createdAt']);
    final updatedAtRaw = _readString(json['updatedAt']);
    final periodsRaw = json['servicePeriods'];
    if (profileId == null ||
        versionId == null ||
        scopeKind == null ||
        scopeId == null ||
        effectiveAtBusinessDate == null ||
        ianaTimezone == null ||
        weekStartDay == null ||
        businessDayStartLocal == null ||
        createdAtRaw == null ||
        updatedAtRaw == null ||
        periodsRaw is! List) {
      throw const OperatorWebProxyException(
        code: 'malformed_business_timing_profile',
        message: 'The proxy returned an incomplete timing profile.',
      );
    }
    return BusinessTimingProfileWriteResult(
      profileId: profileId,
      versionId: versionId,
      scopeKind: scopeKind,
      scopeId: scopeId,
      effectiveAtBusinessDate: effectiveAtBusinessDate,
      ianaTimezone: ianaTimezone,
      weekStartDay: weekStartDay,
      businessDayStartLocal: businessDayStartLocal,
      servicePeriods: periodsRaw
          .whereType<Map<Object?, Object?>>()
          .map((p) => ServicePeriod.fromJson(Map<String, Object?>.from(p)))
          .toList(),
      createdAt: DateTime.parse(createdAtRaw).toUtc(),
      updatedAt: DateTime.parse(updatedAtRaw).toUtc(),
    );
  }
}

String? _readString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

class _OperatorPathViolation implements Exception {
  const _OperatorPathViolation(this.path);
  final String path;
  @override
  String toString() =>
      'WebBusinessTimingGateway resolved a non-operator path: $path';
}
