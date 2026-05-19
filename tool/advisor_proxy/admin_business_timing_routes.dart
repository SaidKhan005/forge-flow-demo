// Doc 1 timing web/admin live parity (2026-05-08) - Admin override
// routes for business-timing profiles.
//
// Closes the leftover from
// `docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md` -
// "Add or wire admin timing read/write override routes and require
// audit_reason for support writes."
//
// Routes (admin-scoped — caller must hold a super_admin or ff_support
// role; operator id is taken from the URL, not the JWT):
//
//   GET   /v1/admin/operators/:operatorId/business-timing-profiles
//   POST  /v1/admin/operators/:operatorId/business-timing-profiles
//   PATCH /v1/admin/operators/:operatorId/business-timing-profiles/:id
//
// Writes require:
//   * Idempotency-Key header (same envelope as operator-scoped writes).
//   * `admin_reason` (or camelCase `adminReason`) in the JSON body
//     (non-empty after trimming). Missing -> 400 missing_admin_reason.
//
// Audit semantics: every successful write fires through the same
// [OperatorWriteAuditSink] used by the operator-scoped router with the
// `admin_reason` recorded in the payload. The hash-chained audit log
// is the persistence layer.
//
// HP #3 / closed-shift safety: this router never touches
// `business_timing_profile_id`, `business_timing_profile_version_id`,
// or `service_period_key` provenance on closed `shift_records` rows.
// It only writes through the same effective-dated profile path the
// operator-scoped router uses.

import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';

import 'operator_routes.dart';

const String adminBusinessTimingProfilesPathPrefix = '/v1/admin/operators/';

/// Suffix on the admin path: everything after `/v1/admin/operators/`.
/// Format: `<operatorId>/business-timing-profiles[/<profileId>]`.
const String _kProfilesSegment = 'business-timing-profiles';

/// Fix #4 / S2 — admin/cross-tenant analogue of S1's
/// `GET /v1/operator/locations/:locationId/business-timing-resolution`.
/// Format:
/// `/v1/admin/operators/<operatorId>/locations/<locationId>/business-timing-resolution`.
/// GET only, read-only, `/v1/` versioned, no Idempotency-Key. Unlike
/// the operator-web route the `operatorId` is taken from the URL (not
/// a JWT) — that is the established admin cross-tenant convention
/// (same as the existing admin business-timing profile routes); the
/// dispatcher gates it to super_admin / ff_support before the handler
/// runs. Returns the FULL canonical candidate chain in `scope_depth`
/// order with scope ancestry + location timezone + full service-period
/// fields so the admin Flutter client runs the ONE pure
/// `BusinessTimingProfileResolver` (no server-side resolver fork —
/// identical to S1).
const String _kLocationsSegment = 'locations';
const String _kBusinessTimingResolutionSegment = 'business-timing-resolution';

/// Parsed `(operatorId, locationId)` for the admin business-timing
/// resolution route, or null when [path] is not that route.
({String operatorId, String locationId})? adminBusinessTimingResolutionScopeOf(
  String path,
) {
  if (!path.startsWith(adminBusinessTimingProfilesPathPrefix)) return null;
  final tail = path.substring(adminBusinessTimingProfilesPathPrefix.length);
  final parts = tail.split('/');
  // <operatorId>/locations/<locationId>/business-timing-resolution
  if (parts.length != 4) return null;
  if (parts[1] != _kLocationsSegment) return null;
  if (parts[3] != _kBusinessTimingResolutionSegment) return null;
  final operatorId = Uri.decodeComponent(parts[0]);
  final locationId = Uri.decodeComponent(parts[2]);
  if (operatorId.trim().isEmpty || locationId.trim().isEmpty) return null;
  return (operatorId: operatorId, locationId: locationId);
}

bool isAdminBusinessTimingResolutionPath(String path) =>
    adminBusinessTimingResolutionScopeOf(path) != null;

/// Roles permitted to mutate timing on behalf of an operator.
const Set<String> kAdminBusinessTimingRoles = <String>{
  'super_admin',
  'ff_support',
};

class AdminBusinessTimingRouter {
  AdminBusinessTimingRouter({
    required this.businessTimingGateway,
    required this.auditSink,
    OperatorWriteIdempotencyCache? idempotencyCache,
    DateTime Function()? now,
    OperatorBusinessTimingMutationListener? mutationListener,
  }) : _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache(),
       _now = now ?? DateTime.now,
       _mutationListener = mutationListener;

  final OperatorBusinessTimingWriteGateway businessTimingGateway;
  final OperatorWriteAuditSink auditSink;
  final OperatorWriteIdempotencyCache _idempotencyCache;
  final DateTime Function() _now;
  final OperatorBusinessTimingMutationListener? _mutationListener;

  static bool matches(String path, String method) {
    final parsed = _parse(path);
    if (parsed == null) return false;
    if (method == 'GET' && parsed.profileId == null) return true;
    if (method == 'POST' && parsed.profileId == null) return true;
    if (method == 'PATCH' && parsed.profileId != null) return true;
    return false;
  }

  static bool isReadOnly(String path, String method) =>
      method == 'GET' && _parse(path)?.profileId == null;

  Future<({int statusCode, Map<String, Object?> body})> handle({
    required String method,
    required String path,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    final parsed = _parse(path);
    if (parsed == null) {
      return (
        statusCode: 404,
        body: const <String, Object?>{
          'error': 'not_found',
          'message': 'admin business-timing route not found',
        },
      );
    }
    if (isReadOnly(path, method)) {
      return _list(operatorId: parsed.operatorId);
    }
    final reason =
        _readNonBlank(body['admin_reason']) ??
        _readNonBlank(body['adminReason']);
    if (reason == null) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'missing_admin_reason',
          'message':
              'admin_reason is required on every admin business-timing write',
        },
      );
    }
    final bodyHash = hashOperatorRequestBody(body);
    final route = '$method $path';
    try {
      return await _idempotencyCache.runOrReplay(
        operatorId: parsed.operatorId,
        route: route,
        idempotencyKey: idempotencyKey,
        requestBodyHash: bodyHash,
        compute: () async {
          if (method == 'POST' && parsed.profileId == null) {
            return _create(
              operatorId: parsed.operatorId,
              actorUserId: actorUserId,
              actorKind: actorKind,
              idempotencyKey: idempotencyKey,
              adminReason: reason,
              body: _stripAdminReason(body),
            );
          }
          if (method == 'PATCH' && parsed.profileId != null) {
            return _patch(
              operatorId: parsed.operatorId,
              profileId: parsed.profileId!,
              actorUserId: actorUserId,
              actorKind: actorKind,
              idempotencyKey: idempotencyKey,
              adminReason: reason,
              body: _stripAdminReason(body),
            );
          }
          return (
            statusCode: 405,
            body: const <String, Object?>{
              'error': 'method_not_allowed',
              'message':
                  'admin business-timing route does not allow this method',
            },
          );
        },
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

  /// Fix #4 / S2 — handles
  /// `GET /v1/admin/operators/:operatorId/locations/:locationId/business-timing-resolution`.
  /// [operatorId] and [locationId] come from the URL (the established
  /// admin cross-tenant convention); the dispatcher has already
  /// verified the actor holds a super_admin / ff_support role before
  /// this runs. Read-only: delegates straight to the gateway's
  /// `resolveForLocationAsSystem`, which calls the canonical
  /// `listCandidateProfilesForSystemLocation` over the sanctioned
  /// `runAsSystem` admin bypass. No resolver fork, no write, no
  /// idempotency surface. [reason] is the audit-attribution string
  /// stamped on the system-scope transaction.
  Future<({int statusCode, Map<String, Object?> body})> handleResolution({
    required String operatorId,
    required String locationId,
    String? businessDate,
  }) async {
    final effectiveDate = businessDate ?? _todayUtcDate();
    try {
      final result = await businessTimingGateway.resolveForLocationAsSystem(
        operatorId: operatorId,
        locationId: locationId,
        businessDate: effectiveDate,
        reason: 'admin.business_timing.resolution_read',
      );
      return (statusCode: 200, body: result.toJson());
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

  static String _todayUtcDate() {
    final now = DateTime.now().toUtc();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '${now.year}-$mm-$dd';
  }

  Future<({int statusCode, Map<String, Object?> body})> _list({
    required String operatorId,
  }) async {
    try {
      final records = await businessTimingGateway.listProfiles(
        operatorId: operatorId,
      );
      return (
        statusCode: 200,
        body: <String, Object?>{
          'profiles': <Map<String, Object?>>[
            for (final record in records) record.toJson(),
          ],
        },
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

  Future<({int statusCode, Map<String, Object?> body})> _create({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required String adminReason,
    required Map<String, Object?> body,
  }) async {
    final ValidatedBusinessTimingProfile validated;
    try {
      validated = validateNewBusinessTimingProfile(body);
    } on BusinessTimingValidationError catch (error) {
      return (statusCode: 400, body: error.toJson());
    }
    if (validated.scopeKind == 'operator' && validated.scopeId != operatorId) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'scope_id_mismatch',
          'message':
              'admin business-timing write must target the operator in the URL',
        },
      );
    }
    final record = await businessTimingGateway.createProfile(
      operatorId: operatorId,
      actorUserId: actorUserId,
      idempotencyKey: idempotencyKey,
      validated: validated,
      adminReason: adminReason,
    );
    await auditSink.record(
      operatorId: operatorId,
      actorUserId: actorUserId,
      actorKind: actorKind,
      eventKind: 'business_timing_profile_created',
      payload: <String, Object?>{
        'profile_id': record.profileId,
        'scope_kind': record.scopeKind,
        'scope_id': record.scopeId,
        'effective_at': record.effectiveAtBusinessDate,
        'admin_reason': adminReason,
        'admin_origin': 'admin_console',
      },
      occurredAt: _now().toUtc(),
    );
    final listener = _mutationListener;
    if (listener != null) {
      await listener.onTimingProfileMutated(
        operatorId: operatorId,
        profileId: record.profileId,
        scopeKind: record.scopeKind,
        scopeId: record.scopeId,
        eventKind: 'business_timing_profile_created',
        actorUserId: actorUserId,
        actorKind: actorKind,
        occurredAt: _now().toUtc(),
      );
    }
    return (statusCode: 201, body: record.toJson());
  }

  Future<({int statusCode, Map<String, Object?> body})> _patch({
    required String operatorId,
    required String profileId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required String adminReason,
    required Map<String, Object?> body,
  }) async {
    final existing = await businessTimingGateway.loadProfile(
      operatorId: operatorId,
      profileId: profileId,
    );
    if (existing == null) {
      return (
        statusCode: 404,
        body: const <String, Object?>{
          'error': 'profile_not_found',
          'message': 'business timing profile was not found for this operator',
        },
      );
    }
    final existingValidated = _toValidated(existing);
    final ValidatedBusinessTimingProfile merged;
    try {
      merged = validateProfilePatch(body: body, existing: existingValidated);
    } on BusinessTimingValidationError catch (error) {
      return (statusCode: 400, body: error.toJson());
    }
    if (merged.scopeKind == 'operator' && merged.scopeId != operatorId) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'scope_id_mismatch',
          'message':
              'admin business-timing write must target the operator in the URL',
        },
      );
    }
    final record = await businessTimingGateway.updateProfile(
      operatorId: operatorId,
      actorUserId: actorUserId,
      idempotencyKey: idempotencyKey,
      profileId: profileId,
      validated: merged,
      adminReason: adminReason,
    );
    await auditSink.record(
      operatorId: operatorId,
      actorUserId: actorUserId,
      actorKind: actorKind,
      eventKind: 'business_timing_profile_updated',
      payload: <String, Object?>{
        'profile_id': record.profileId,
        'fields_changed': body.keys.toList(),
        'admin_reason': adminReason,
        'admin_origin': 'admin_console',
      },
      occurredAt: _now().toUtc(),
    );
    final listener = _mutationListener;
    if (listener != null) {
      await listener.onTimingProfileMutated(
        operatorId: operatorId,
        profileId: record.profileId,
        scopeKind: record.scopeKind,
        scopeId: record.scopeId,
        eventKind: 'business_timing_profile_updated',
        actorUserId: actorUserId,
        actorKind: actorKind,
        occurredAt: _now().toUtc(),
      );
    }
    return (statusCode: 200, body: record.toJson());
  }

  static ValidatedBusinessTimingProfile _toValidated(
    OperatorBusinessTimingProfileRecord record,
  ) {
    return ValidatedBusinessTimingProfile(
      scopeKind: record.scopeKind,
      scopeId: record.scopeId,
      effectiveAtBusinessDate: record.effectiveAtBusinessDate,
      ianaTimezone: record.ianaTimezone,
      weekStartDay: record.weekStartDay,
      weekStartDayInt: _weekStartIntFromString(record.weekStartDay),
      businessDayStartLocal: record.businessDayStartLocal,
      servicePeriods: <ValidatedServicePeriod>[
        for (final p in record.servicePeriods)
          ValidatedServicePeriod(
            key: p.key,
            label: p.label,
            startLocal: p.startLocal,
            endLocal: p.endLocal,
            startMinute: _hhmmToMinute(p.startLocal),
            endMinute: _hhmmToMinute(p.endLocal),
            rollsPastMidnight: p.rollsPastMidnight,
            applicableDays: p.applicableDays,
            shortLabel: p.shortLabel,
            sortOrder: p.sortOrder,
          ),
      ],
    );
  }
}

({String operatorId, String? profileId})? _parse(String path) {
  if (!path.startsWith(adminBusinessTimingProfilesPathPrefix)) return null;
  final tail = path.substring(adminBusinessTimingProfilesPathPrefix.length);
  final parts = tail.split('/');
  if (parts.length < 2) return null;
  if (parts[1] != _kProfilesSegment) return null;
  final operatorId = Uri.decodeComponent(parts[0]);
  if (operatorId.trim().isEmpty) return null;
  if (parts.length == 2) {
    return (operatorId: operatorId, profileId: null);
  }
  if (parts.length == 3 && parts[2].trim().isNotEmpty) {
    return (operatorId: operatorId, profileId: Uri.decodeComponent(parts[2]));
  }
  return null;
}

String? _readNonBlank(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, Object?> _stripAdminReason(Map<String, Object?> body) {
  final copy = Map<String, Object?>.from(body);
  copy.remove('admin_reason');
  copy.remove('adminReason');
  return copy;
}

int _weekStartIntFromString(String weekStartDay) {
  switch (weekStartDay) {
    case 'monday':
      return 1;
    case 'tuesday':
      return 2;
    case 'wednesday':
      return 3;
    case 'thursday':
      return 4;
    case 'friday':
      return 5;
    case 'saturday':
      return 6;
    case 'sunday':
      return 7;
  }
  return 1;
}

int _hhmmToMinute(String hhmm) {
  final hour = int.parse(hhmm.substring(0, 2));
  final minute = int.parse(hhmm.substring(3, 5));
  return hour * 60 + minute;
}
