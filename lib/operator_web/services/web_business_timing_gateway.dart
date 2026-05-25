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

/// Operator-scoped business-timing surface. Never produces an
/// `/admin/` path; cross-tenant timing overrides live behind the
/// F&F Ops Console (separate worktree).
abstract class WebBusinessTimingGateway {
  /// 11W.7 ops-debt — lists every timing profile owned by the
  /// caller's operator with full service-period sets.
  Future<List<BusinessTimingProfileWriteResult>> listProfiles();

  /// Fix #4 / S3 (G13) — the location-scoped, org-unit-ancestor
  /// resolved candidate chain for [locationId], in canonical resolver
  /// precedence order (operator default first, location override
  /// last), as returned by the S1 backend route
  /// `GET /v1/operator/locations/:locationId/business-timing-resolution`
  /// (PR #872). The client runs the ONE canonical pure
  /// `BusinessTimingProfileResolver` over these candidates — the proxy
  /// does NOT fork the resolver. Read-only.
  ///
  /// [businessDate] (optional, `YYYY-MM-DD`) selects which
  /// effective-dated rows are evaluated; when omitted the proxy
  /// defaults to UTC today, matching the existing resolved-timing
  /// caller's default.
  Future<BusinessTimingResolutionResult> resolveForLocation({
    required String locationId,
    String? businessDate,
  });

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
  }) : _client = client,
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

  /// Fix #4 / S3 — the S1 location-scoped resolution route
  /// (PR #872, `operator_routes.dart`
  /// `operatorLocationBusinessTimingResolutionPrefix` +
  /// `...Suffix`). Operator-scoped (NOT `/admin/`); the proxy takes
  /// the operator from the JWT and rejects a path location that does
  /// not match the signed-in tenant scope.
  static String operatorBusinessTimingResolutionPath(String locationId) =>
      '/v1/operator/locations/${Uri.encodeComponent(locationId)}'
      '/business-timing-resolution';

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async {
    _assertOperatorPath(operatorProfilesPath);
    final token = await _requireToken();
    final response = await _client.getJson(
      operatorProfilesPath,
      idToken: token,
    );
    final raw = response.body['profiles'];
    if (raw is! List) {
      throw const OperatorWebProxyException(
        code: 'malformed_business_timing_profile_list',
        message:
            'The proxy returned an incomplete business-timing profile list.',
      );
    }
    return <BusinessTimingProfileWriteResult>[
      for (final item in raw)
        if (item is Map<Object?, Object?>)
          BusinessTimingProfileWriteResult.fromJson(
            Map<String, Object?>.from(item),
          )
        else
          throw const OperatorWebProxyException(
            code: 'malformed_business_timing_profile_list',
            message: 'The proxy returned a malformed business-timing profile.',
          ),
    ];
  }

  @override
  Future<BusinessTimingResolutionResult> resolveForLocation({
    required String locationId,
    String? businessDate,
  }) async {
    final path = operatorBusinessTimingResolutionPath(locationId);
    // The S1 route is operator-scoped, NOT a business-timing-profiles
    // collection path, so use the looser non-admin assertion: the
    // gateway must still never produce an /admin/ URL (no silent
    // permission escalation), but it is allowed to leave the
    // /v1/operator/business-timing-profiles prefix.
    _assertNonAdminOperatorPath(path);
    final token = await _requireToken();
    final response = await _client.getJson(
      path,
      idToken: token,
      queryParameters: (businessDate != null && businessDate.trim().isNotEmpty)
          ? <String, String>{'business_date': businessDate.trim()}
          : null,
    );
    return BusinessTimingResolutionResult.fromJson(response.body);
  }

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async {
    _assertOperatorPath(operatorProfilesPath);
    final token = await _requireToken();
    final body = request.toJson();
    final response = await _client.postJson(
      operatorProfilesPath,
      idToken: token,
      body: body,
      // G60 — caller-STABLE key. The create payload uniquely
      // identifies this logical profile, so a retried "Save" reuses
      // the same key and the proxy `proxy_requests` UNIQUE guard
      // collapses the duplicate instead of inserting a SECOND timing
      // profile. A genuinely different profile gets a distinct key.
      extraHeaders: _stableKeyHeader('timing-profile-create', <Object?>[body]),
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
    final body = patch.toJson();
    final response = await _client.patchJson(
      path,
      idToken: token,
      body: body,
      // G60 — caller-stable key scoped to the profile id + payload.
      extraHeaders: _stableKeyHeader('timing-profile-update', <Object?>[
        profileId,
        body,
      ]),
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
    final body = period.toJson();
    final response = await _client.postJson(
      path,
      idToken: token,
      body: body,
      // G60 — caller-stable key scoped to the profile id + period
      // payload, so a retried add does NOT append a duplicate
      // service period.
      extraHeaders: _stableKeyHeader('timing-service-period-add', <Object?>[
        profileId,
        body,
      ]),
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
    final body = patch.toJson();
    final response = await _client.patchJson(
      path,
      idToken: token,
      body: body,
      // G60 — caller-stable key scoped to the profile id + period
      // key + payload.
      extraHeaders: _stableKeyHeader('timing-service-period-update', <Object?>[
        profileId,
        key,
        body,
      ]),
    );
    return BusinessTimingProfileWriteResult.fromJson(response.body);
  }

  /// G60 — builds the `Idempotency-Key` header carrying a
  /// caller-STABLE key derived from [action] + [parts]. Same logical
  /// write (same payload) on retry => same key (proxy
  /// `proxy_requests` UNIQUE guard collapses it); distinct actions /
  /// payloads => distinct keys. Mirrors the exemplar idempotency
  /// posture of `web_team_roles_gateway.dart`.
  static Map<String, String> _stableKeyHeader(
    String action,
    List<Object?> parts,
  ) {
    return <String, String>{
      'Idempotency-Key': OperatorWebProxyClient.stableIdempotencyKey(
        action,
        parts,
      ),
    };
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

  /// Fix #4 / S3 — looser guard for the operator-scoped resolution
  /// route, which is `/v1/operator/locations/:id/...` and therefore
  /// outside the business-timing-profiles collection prefix. Still
  /// loudly rejects any `/admin/` path so a misconfigured route can
  /// never escalate to the F&F Ops Console surface.
  static void _assertNonAdminOperatorPath(String path) {
    if (path.contains('/admin/')) {
      throw _OperatorPathViolation(path);
    }
    if (!path.startsWith('/v1/operator/')) {
      throw _OperatorPathViolation(path);
    }
  }
}

/// Service-period payload shared by create and read paths.
///
/// Per-Daypart Targets V1 / Slice 2.5 (Gap 28): the editor and gateway
/// carry three additional fields that mirror the canonical
/// `ServicePeriodDefinition` model so operators can express
/// day-restricted periods (e.g. "Weekend Brunch" Sat/Sun only):
///   - `applicableDays`  ISO weekdays the period runs on (1=Mon..7=Sun).
///   - `shortLabel`      compact label for tight UI surfaces (e.g. "L").
///   - `sortOrder`       display order; lower sorts first.
///
/// Backwards compatibility: when the server omits any of the three
/// fields, [fromJson] supplies safe defaults (`[1..7]`, `''`, `0`)
/// so older payloads do NOT throw `malformed_service_period`.
@immutable
class ServicePeriod {
  const ServicePeriod({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
    required this.rollsPastMidnight,
    this.applicableDays = const <int>[1, 2, 3, 4, 5, 6, 7],
    this.shortLabel = '',
    this.sortOrder = 0,
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;
  final bool rollsPastMidnight;
  final List<int> applicableDays;
  final String shortLabel;
  final int sortOrder;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'label': label,
    'startLocal': startLocal,
    'endLocal': endLocal,
    'rollsPastMidnight': rollsPastMidnight,
    'applicableDays': applicableDays,
    'shortLabel': shortLabel,
    'sortOrder': sortOrder,
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
      applicableDays: _readApplicableDays(json['applicableDays']),
      shortLabel: _readShortLabel(json['shortLabel']),
      sortOrder: _readSortOrder(json['sortOrder']),
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
    this.applicableDays = const <int>[1, 2, 3, 4, 5, 6, 7],
    this.shortLabel = '',
    this.sortOrder = 1,
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

@immutable
class ServicePeriodPatch {
  const ServicePeriodPatch({
    this.label,
    this.startLocal,
    this.endLocal,
    this.applicableDays,
    this.shortLabel,
    this.sortOrder,
  });

  final String? label;
  final String? startLocal;
  final String? endLocal;
  final List<int>? applicableDays;
  final String? shortLabel;
  final int? sortOrder;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    if (label != null) json['label'] = label;
    if (startLocal != null) json['startLocal'] = startLocal;
    if (endLocal != null) json['endLocal'] = endLocal;
    if (applicableDays != null) json['applicableDays'] = applicableDays;
    if (shortLabel != null) json['shortLabel'] = shortLabel;
    if (sortOrder != null) json['sortOrder'] = sortOrder;
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
    'servicePeriods': servicePeriods.map((period) => period.toJson()).toList(),
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
      json['servicePeriods'] = servicePeriods!
          .map((period) => period.toJson())
          .toList();
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
    final effectiveAtBusinessDate = _readString(
      json['effectiveAtBusinessDate'],
    );
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
          .map(
            (p) => p is Map<Object?, Object?>
                ? ServicePeriod.fromJson(Map<String, Object?>.from(p))
                : throw const OperatorWebProxyException(
                    code: 'malformed_business_timing_profile',
                    message: 'The proxy returned a malformed timing profile.',
                  ),
          )
          .toList(),
      createdAt: DateTime.parse(createdAtRaw).toUtc(),
      updatedAt: DateTime.parse(updatedAtRaw).toUtc(),
    );
  }
}

/// Fix #4 / S3 (G13) — one rung of the canonical business-timing
/// resolution chain as returned by the S1 route. Carries the raw
/// candidate fields plus the scope ancestry the wire previously
/// dropped (`scopeType` / `scopeId` / a non-blank `scopeLabel`) so the
/// client can run the one canonical pure resolver AND derive real
/// per-field provenance from the resolver's `inheritanceChain` — no
/// `:56` same-value heuristic.
@immutable
class BusinessTimingResolutionCandidate {
  const BusinessTimingResolutionCandidate({
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

  /// `operator` | `org_unit` | `location` — the canonical
  /// `business_timing_profiles.scope_type`.
  final String scopeType;
  final String scopeId;

  /// Human label for the rung (operator `display_name` when set, else
  /// a scope-kind fallback). Never blank — the inheritance chrome
  /// renders this verbatim instead of faking a string.
  final String scopeLabel;
  final int scopeDepthRank;

  final String ianaTimezone;
  final String effectiveAtBusinessDate;
  final String weekStartDay;
  final String businessDayStartLocal;
  final List<ServicePeriod> servicePeriods;

  static BusinessTimingResolutionCandidate fromJson(Map<String, Object?> json) {
    final profileId = _readString(json['profileId']);
    // The S1 record emits both `scopeType` and a back-compat
    // `scopeKind` alias; accept either so the consumer is decoupled
    // from which key the wire chose.
    final scopeType =
        _readString(json['scopeType']) ?? _readString(json['scopeKind']);
    final scopeId = _readString(json['scopeId']);
    final scopeLabel = _readString(json['scopeLabel']);
    final ianaTimezone = _readString(json['ianaTimezone']);
    final effectiveAtBusinessDate = _readString(
      json['effectiveAtBusinessDate'],
    );
    final weekStartDay = _readString(json['weekStartDay']);
    final businessDayStartLocal = _readString(json['businessDayStartLocal']);
    final periodsRaw = json['servicePeriods'];
    if (profileId == null ||
        scopeType == null ||
        scopeId == null ||
        scopeLabel == null ||
        ianaTimezone == null ||
        effectiveAtBusinessDate == null ||
        weekStartDay == null ||
        businessDayStartLocal == null ||
        periodsRaw is! List) {
      throw const OperatorWebProxyException(
        code: 'malformed_business_timing_candidate',
        message:
            'The proxy returned an incomplete business-timing resolution '
            'candidate.',
      );
    }
    final rank = json['scopeDepthRank'];
    return BusinessTimingResolutionCandidate(
      profileId: profileId,
      scopeType: scopeType,
      scopeId: scopeId,
      scopeLabel: scopeLabel,
      scopeDepthRank: rank is int ? rank : (rank is num ? rank.toInt() : 0),
      ianaTimezone: ianaTimezone,
      effectiveAtBusinessDate: effectiveAtBusinessDate,
      weekStartDay: weekStartDay,
      businessDayStartLocal: businessDayStartLocal,
      servicePeriods: periodsRaw
          .whereType<Map<Object?, Object?>>()
          .map((p) => ServicePeriod.fromJson(Map<String, Object?>.from(p)))
          .toList(),
    );
  }
}

/// Fix #4 / S3 (G13) — wire response of the S1 route
/// `GET /v1/operator/locations/:locationId/business-timing-resolution`.
/// The candidate list is already in canonical resolver precedence
/// order (operator default first, location override last).
@immutable
class BusinessTimingResolutionResult {
  const BusinessTimingResolutionResult({
    required this.operatorId,
    required this.locationId,
    required this.businessDate,
    required this.ianaTimezone,
    required this.candidates,
  });

  final String operatorId;
  final String locationId;
  final String businessDate;

  /// `locations.timezone` for the resolved location, surfaced once at
  /// the top level (the resolver needs a timezone even when no
  /// candidate overrides it). Null only when the location row is
  /// missing.
  final String? ianaTimezone;
  final List<BusinessTimingResolutionCandidate> candidates;

  static BusinessTimingResolutionResult fromJson(Map<String, Object?> json) {
    final operatorId = _readString(json['operatorId']);
    final locationId = _readString(json['locationId']);
    final businessDate = _readString(json['businessDate']);
    final candidatesRaw = json['candidates'];
    if (operatorId == null ||
        locationId == null ||
        businessDate == null ||
        candidatesRaw is! List) {
      throw const OperatorWebProxyException(
        code: 'malformed_business_timing_resolution',
        message:
            'The proxy returned an incomplete business-timing resolution '
            'response.',
      );
    }
    return BusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: _readString(json['ianaTimezone']),
      candidates: candidatesRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (c) => BusinessTimingResolutionCandidate.fromJson(
              Map<String, Object?>.from(c),
            ),
          )
          .toList(),
    );
  }
}

String? _readString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Default ISO weekday set used when older payloads omit
/// `applicableDays`. Mirrors the implicit pre-Slice-2.5 behavior where
/// every period was assumed to apply every day of the week.
const List<int> _kDefaultApplicableDays = <int>[1, 2, 3, 4, 5, 6, 7];

List<int> _readApplicableDays(Object? value) {
  if (value is! List) return _kDefaultApplicableDays;
  final days = <int>[];
  for (final item in value) {
    if (item is int) {
      days.add(item);
    } else if (item is num) {
      days.add(item.toInt());
    }
  }
  if (days.isEmpty) return _kDefaultApplicableDays;
  return List<int>.unmodifiable(days);
}

String _readShortLabel(Object? value) {
  if (value is String) return value;
  return '';
}

int _readSortOrder(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

class _OperatorPathViolation implements Exception {
  const _OperatorPathViolation(this.path);
  final String path;
  @override
  String toString() =>
      'WebBusinessTimingGateway resolved a non-operator path: $path';
}
