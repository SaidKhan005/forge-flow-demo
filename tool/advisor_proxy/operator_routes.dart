// Phase 11W.7 / Wave A2 - operator-scoped account + business-timing
// proxy routes.
//
// Seven routes, all operator-scoped, all role-gated to operator owner /
// operator admin. Writes are idempotent by Idempotency-Key. Reads
// (GETs) skip the Idempotency-Key check.
//
//   GET   /v1/operator/account                       (11W.7 ops-debt)
//   PATCH /v1/operator/account
//   GET   /v1/operator/business-timing-profiles      (11W.7 ops-debt)
//   POST  /v1/operator/business-timing-profiles
//   PATCH /v1/operator/business-timing-profiles/:id
//   POST  /v1/operator/business-timing-profiles/:id/service-periods
//   PATCH /v1/operator/business-timing-profiles/:id/service-periods/:key
//
// Route shapes are pinned by docs/phases/phase_business_timing_live/
// business_timing_live_plan.md and the lane-coordination contract in
// the A2 prompt - the frontend gateway tests are pinned to these
// exact responses.
//
// Auth:
//   * Bearer token resolves to OperatorContext (operatorId required).
//   * Caller must hold operator_owner or operator_admin role.
//
// Idempotency:
//   * Idempotency-Key header is required on every write. Missing /
//     blank / >200 chars -> 400 idempotency_key_missing /
//     idempotency_key_too_long.
//   * Same key + same body within TTL -> replay (status 200, not 201).
//   * Same key + different body -> 409 idempotency_key_conflict.
//
// Audit:
//   * Every successful write enqueues an audit row through the
//     injected `OperatorWriteAuditSink`. Production wires this to the
//     hash-chained audit_logs repository; tests wire a recording sink.
//
// CLAUDE.md compliance:
//   * No em-dashes (U+2014) in any error message or audit string.
//   * Operator-scoped: every route resolves operatorId from the JWT,
//     never from the URL or body.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';
import 'package:forge_and_flow/services/business_timing/operator_write_contracts.dart';

import 'business_logo_upload_routes.dart';
import 'operator_location_account_overrides_routes.dart';
import 'operator_location_timezone_routes.dart';

export 'package:forge_and_flow/services/business_timing/operator_write_contracts.dart';
export 'business_logo_upload_routes.dart'
    show
        BusinessLogoBlobUploader,
        BusinessLogoUploadHandler,
        BusinessLogoUploadResult,
        AzureBlobBusinessLogoUploader,
        BusinessLogoEnvNames,
        LogoUploadDecode,
        kBusinessLogoMaxBytes,
        kPngMagic,
        operatorBusinessLogoUploadPath,
        decodeBusinessLogoUploadBody;
export 'operator_location_timezone_routes.dart'
    show
        LocationTimezoneDecode,
        LocationTimezoneRecord,
        LocationTimezoneUpdateOutcome,
        LocationTimezoneUpdateOutcomeKind,
        OperatorLocationTimezoneHandler,
        OperatorLocationTimezoneWriteGateway,
        decodeLocationTimezoneBody,
        operatorLocationTimezonePath;
export 'operator_location_account_overrides_routes.dart'
    show
        LocationAccountOverridesDecode,
        LocationAccountOverridesFieldSet,
        LocationAccountOverridesOutcome,
        LocationAccountOverridesOutcomeKind,
        LocationAccountOverridesRecord,
        LocationAccountOverridesWriteGateway,
        OperatorLocationAccountOverridesHandler,
        ValidatedLocationAccountOverridesPatch,
        decodeLocationAccountOverridesPatchBody,
        isLocationAccountOverridesUuid,
        isOperatorLocationAccountOverridesPath,
        operatorLocationAccountOverridesIdOf,
        operatorLocationAccountOverridesPathPrefix;

/// Route paths. Exported so the frontend gateway tests and the proxy
/// dispatcher reference one canonical set of strings. The PATCH +
/// GET share the same path; the dispatcher branches by method.
const String operatorAccountPath = '/v1/operator/account';

/// Backward-compatible alias for the PATCH-only route name. Existing
/// tests + frontend gateway tests grep on this constant.
const String operatorAccountPatchPath = operatorAccountPath;

const String operatorBusinessTimingProfilesPath =
    '/v1/operator/business-timing-profiles';
const String operatorBusinessTimingProfilePrefix =
    '$operatorBusinessTimingProfilesPath/';

/// Operator role allow-list. Two strings: operator_owner is the
/// seat-zero role, operator_admin is the delegated equivalent.
const Set<String> kOperatorWriteRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// In-memory replay cache for operator-scoped writes. Keyed by
/// `(operatorId, route, idempotencyKey)`; bounded so a malicious or
/// runaway client cannot OOM the proxy. Entries cache the full HTTP
/// response (status + body) and the body hash; a same-key, different-
/// body retry returns 409 idempotency_key_conflict.
class OperatorWriteIdempotencyCache {
  OperatorWriteIdempotencyCache({
    this.ttl = const Duration(hours: 1),
    this.maxEntries = 5000,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;

  final Map<String, _CacheEntry> _store = <String, _CacheEntry>{};

  /// Run [compute] once per `(operatorId, route, idempotencyKey)` +
  /// matching body hash. Same body hash within TTL returns the cached
  /// response. Different body hash within TTL throws
  /// [OperatorWriteRejected] with code idempotency_key_conflict.
  Future<({int statusCode, Map<String, Object?> body})> runOrReplay({
    required String operatorId,
    required String route,
    required String idempotencyKey,
    required String requestBodyHash,
    required Future<({int statusCode, Map<String, Object?> body})> Function()
        compute,
  }) async {
    _gc();
    final key = '$operatorId|$route|$idempotencyKey';
    final cached = _store[key];
    if (cached != null) {
      if (cached.bodyHash != requestBodyHash) {
        throw const OperatorWriteRejected(
          code: 'idempotency_key_conflict',
          message: 'Idempotency-Key was reused with a different body',
          statusCode: 409,
        );
      }
      return (statusCode: cached.statusCode, body: cached.body);
    }
    final result = await compute();
    if (result.statusCode >= 200 &&
        result.statusCode < 500 &&
        result.statusCode != 429) {
      _store[key] = _CacheEntry(
        statusCode: result.statusCode,
        body: result.body,
        bodyHash: requestBodyHash,
        expiresAt: _now().add(ttl),
      );
      _evictOverflow();
    }
    return result;
  }

  void _gc() {
    final cutoff = _now();
    _store.removeWhere((_, entry) => entry.expiresAt.isBefore(cutoff));
  }

  void _evictOverflow() {
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first);
    }
  }
}

class _CacheEntry {
  _CacheEntry({
    required this.statusCode,
    required this.body,
    required this.bodyHash,
    required this.expiresAt,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final String bodyHash;
  final DateTime expiresAt;
}

/// Stable hash of the request body. Sorting keys before encoding
/// ensures `{a:1, b:2}` and `{b:2, a:1}` hash to the same value so a
/// JSON re-encoding does not break replay.
String hashOperatorRequestBody(Map<String, Object?> body) {
  final canonical = _canonicalJson(body);
  return sha256.convert(utf8.encode(canonical)).toString();
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final entries = <String>[
      for (final k in keys) '${jsonEncode(k)}:${_canonicalJson(value[k])}',
    ];
    return '{${entries.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

/// Doc 1 timing web/admin live parity (2026-05-08) - hook fired after
/// every successful business-timing mutation. Production wires this to
/// the mobile sync outbox so a write surfaces immediately as an
/// invalidation pulse to subscribed devices. Tests pass a recording
/// listener so the contract is provable.
abstract class OperatorBusinessTimingMutationListener {
  Future<void> onTimingProfileMutated({
    required String operatorId,
    required String profileId,
    required String scopeKind,
    required String scopeId,
    required String eventKind,
    required String actorUserId,
    required String actorKind,
    required DateTime occurredAt,
  });
}

/// Encapsulates the dispatch + auth + idempotency + audit boilerplate
/// for the five operator write routes.
class OperatorWriteRouter {
  OperatorWriteRouter({
    required this.accountGateway,
    required this.businessTimingGateway,
    required this.auditSink,
    OperatorWriteIdempotencyCache? idempotencyCache,
    DateTime Function()? now,
    OperatorBusinessTimingMutationListener? mutationListener,
    BusinessLogoUploadHandler? businessLogoUploadHandler,
    OperatorLocationTimezoneHandler? locationTimezoneHandler,
    OperatorLocationAccountOverridesHandler?
        locationAccountOverridesHandler,
  })  : _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache(),
        _now = now ?? DateTime.now,
        _mutationListener = mutationListener,
        _businessLogoUploadHandler = businessLogoUploadHandler,
        _locationTimezoneHandler = locationTimezoneHandler,
        _locationAccountOverridesHandler = locationAccountOverridesHandler;

  final OperatorAccountWriteGateway accountGateway;
  final OperatorBusinessTimingWriteGateway businessTimingGateway;
  final OperatorWriteAuditSink auditSink;
  final OperatorWriteIdempotencyCache _idempotencyCache;
  final DateTime Function() _now;
  final OperatorBusinessTimingMutationListener? _mutationListener;

  /// Wave 2 W-5 — optional logo upload handler. When null the
  /// `/v1/operator/business/logo` route resolves to a calm 503
  /// instead of a 404, mirroring the rest of the operator-write
  /// surface's "not configured" behaviour.
  final BusinessLogoUploadHandler? _businessLogoUploadHandler;

  /// Wave 2 W-6 backend — optional primary-location timezone handler.
  /// When null the `/v1/operator/location-timezone` route resolves
  /// to a calm 503 instead of a 404, matching the rest of the
  /// operator-write surface's "not configured" posture.
  final OperatorLocationTimezoneHandler? _locationTimezoneHandler;

  /// Wave 2 U-FU-hp11-account — optional per-location account
  /// overrides handler. When null the
  /// `/v1/operator/location-account-overrides/{location_id}` routes
  /// resolve to a calm 503 (matching the rest of the operator-write
  /// surface's "not configured" posture).
  final OperatorLocationAccountOverridesHandler?
      _locationAccountOverridesHandler;

  Future<void> _notifyTimingMutation({
    required String operatorId,
    required String profileId,
    required String scopeKind,
    required String scopeId,
    required String eventKind,
    required String actorUserId,
    required String actorKind,
  }) async {
    final listener = _mutationListener;
    if (listener == null) return;
    await listener.onTimingProfileMutated(
      operatorId: operatorId,
      profileId: profileId,
      scopeKind: scopeKind,
      scopeId: scopeId,
      eventKind: eventKind,
      actorUserId: actorUserId,
      actorKind: actorKind,
      occurredAt: _now().toUtc(),
    );
  }

  /// True when [path] / [method] match one of the seven routes. The
  /// dispatcher uses this to short-circuit the catch-all 404 in the
  /// monolithic `routeRequest` without wiring 7 separate ifs.
  ///
  /// 11W.7 ops-debt — GETs added for `/v1/operator/account` and
  /// `/v1/operator/business-timing-profiles`. The dispatcher honours
  /// these without an Idempotency-Key header (writes still require
  /// one).
  static bool matches(String path, String method) {
    if (method == 'GET' && path == operatorAccountPath) return true;
    if (method == 'PATCH' && path == operatorAccountPath) return true;
    if (method == 'GET' && path == operatorBusinessTimingProfilesPath) {
      return true;
    }
    if (method == 'POST' && path == operatorBusinessTimingProfilesPath) {
      return true;
    }
    if (path.startsWith(operatorBusinessTimingProfilePrefix)) {
      if (method == 'PATCH' || method == 'POST') return true;
    }
    // Wave 2 W-5 — POST /v1/operator/business/logo. Multipart-ish
    // upload (JSON envelope carrying base64 PNG bytes); see
    // `business_logo_upload_routes.dart` for the wire shape.
    if (method == 'POST' && path == operatorBusinessLogoUploadPath) {
      return true;
    }
    // Wave 2 W-6 backend — PATCH /v1/operator/location-timezone.
    // Operator-scoped primary-location timezone editor (HP #11
    // location-scoped) wired into the existing operator-write
    // dispatch path so it inherits auth + role gate + Idempotency-
    // Key + per-operator isolation for free.
    if (method == 'PATCH' && path == operatorLocationTimezonePath) {
      return true;
    }
    // Wave 2 U-FU-hp11-account — GET/PATCH
    // /v1/operator/location-account-overrides/{location_id}. HP #11
    // per-location overrides for the three AccountScreen settings
    // cards (region + business-day + identity contact email + phone).
    // Reuses the same dispatch path so it inherits auth + role gate
    // + Idempotency-Key + per-operator isolation for free.
    if ((method == 'GET' || method == 'PATCH') &&
        isOperatorLocationAccountOverridesPath(path)) {
      return true;
    }
    return false;
  }

  /// True when the route is a read-only GET that should bypass the
  /// Idempotency-Key requirement at the dispatch layer.
  static bool isReadOnly(String path, String method) {
    if (method != 'GET') return false;
    if (path == operatorAccountPath) return true;
    if (path == operatorBusinessTimingProfilesPath) return true;
    if (isOperatorLocationAccountOverridesPath(path)) return true;
    return false;
  }

  /// Handles one request once auth + role gate + Idempotency-Key
  /// header have been resolved by the caller. 11W.7 ops-debt: GETs
  /// bypass the idempotency cache (the dispatcher passes an empty
  /// key for read-only methods).
  Future<({int statusCode, Map<String, Object?> body})> handle({
    required String method,
    required String path,
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    if (isReadOnly(path, method)) {
      try {
        return await _dispatch(
          method: method,
          path: path,
          operatorId: operatorId,
          actorUserId: actorUserId,
          actorKind: actorKind,
          idempotencyKey: idempotencyKey,
          body: body,
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
    final bodyHash = hashOperatorRequestBody(body);
    final route = '$method $path';
    try {
      return await _idempotencyCache.runOrReplay(
        operatorId: operatorId,
        route: route,
        idempotencyKey: idempotencyKey,
        requestBodyHash: bodyHash,
        compute: () => _dispatch(
          method: method,
          path: path,
          operatorId: operatorId,
          actorUserId: actorUserId,
          actorKind: actorKind,
          idempotencyKey: idempotencyKey,
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
    required String method,
    required String path,
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    if (method == 'GET' && path == operatorAccountPath) {
      return _handleAccountGet(operatorId: operatorId);
    }
    if (method == 'PATCH' && path == operatorAccountPath) {
      return _handleAccountPatch(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        idempotencyKey: idempotencyKey,
        body: body,
      );
    }
    if (method == 'GET' && path == operatorBusinessTimingProfilesPath) {
      return _handleBusinessTimingList(operatorId: operatorId);
    }
    if (method == 'POST' && path == operatorBusinessTimingProfilesPath) {
      return _handleProfileCreate(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        idempotencyKey: idempotencyKey,
        body: body,
      );
    }
    if (method == 'POST' && path == operatorBusinessLogoUploadPath) {
      return _handleBusinessLogoUpload(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        body: body,
      );
    }
    if (method == 'PATCH' && path == operatorLocationTimezonePath) {
      return _handleLocationTimezonePatch(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        body: body,
      );
    }
    if (isOperatorLocationAccountOverridesPath(path) &&
        (method == 'GET' || method == 'PATCH')) {
      final locationId = operatorLocationAccountOverridesIdOf(path)!;
      if (method == 'GET') {
        return _handleLocationAccountOverridesGet(
          operatorId: operatorId,
          actorUserId: actorUserId,
          locationId: locationId,
        );
      }
      return _handleLocationAccountOverridesPatch(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        locationId: locationId,
        body: body,
      );
    }
    if (path.startsWith(operatorBusinessTimingProfilePrefix)) {
      final suffix = path.substring(operatorBusinessTimingProfilePrefix.length);
      final parts = suffix.split('/');
      if (parts.length == 1 && parts[0].isNotEmpty) {
        if (method == 'PATCH') {
          return _handleProfilePatch(
            operatorId: operatorId,
            actorUserId: actorUserId,
            actorKind: actorKind,
            idempotencyKey: idempotencyKey,
            profileId: Uri.decodeComponent(parts[0]),
            body: body,
          );
        }
      } else if (parts.length == 2 &&
          parts[0].isNotEmpty &&
          parts[1] == 'service-periods') {
        if (method == 'POST') {
          return _handleServicePeriodAdd(
            operatorId: operatorId,
            actorUserId: actorUserId,
            actorKind: actorKind,
            idempotencyKey: idempotencyKey,
            profileId: Uri.decodeComponent(parts[0]),
            body: body,
          );
        }
      } else if (parts.length == 3 &&
          parts[0].isNotEmpty &&
          parts[1] == 'service-periods' &&
          parts[2].isNotEmpty) {
        if (method == 'PATCH') {
          return _handleServicePeriodPatch(
            operatorId: operatorId,
            actorUserId: actorUserId,
            actorKind: actorKind,
            idempotencyKey: idempotencyKey,
            profileId: Uri.decodeComponent(parts[0]),
            servicePeriodKey: Uri.decodeComponent(parts[2]),
            body: body,
          );
        }
      }
    }
    return (
      statusCode: 404,
      body: const <String, Object?>{
        'error': 'not_found',
        'message': 'route not found',
      },
    );
  }

  Future<({int statusCode, Map<String, Object?> body})> _handleAccountGet({
    required String operatorId,
  }) async {
    try {
      final record = await accountGateway.loadAccount(operatorId: operatorId);
      if (record == null) {
        return (
          statusCode: 404,
          body: const <String, Object?>{
            'error': 'operator_not_found',
            'message': 'operator row was not found',
          },
        );
      }
      return (statusCode: 200, body: record.toJson());
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

  Future<({int statusCode, Map<String, Object?> body})>
      _handleBusinessTimingList({
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

  Future<({int statusCode, Map<String, Object?> body})> _handleAccountPatch({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    final ValidatedOperatorAccountPatch patch;
    try {
      patch = validateOperatorAccountPatch(body);
    } on BusinessTimingValidationError catch (error) {
      return (statusCode: 400, body: error.toJson());
    }
    if (patch.changedFieldNames.isEmpty) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'no_fields_to_update',
          'message': 'request body must include at least one editable field',
        },
      );
    }
    try {
      final record = await accountGateway.patchAccount(
        operatorId: operatorId,
        actorUserId: actorUserId,
        idempotencyKey: idempotencyKey,
        patch: patch,
        adminReason: 'operator.account.patch:$actorUserId',
      );
      await auditSink.record(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventKind: 'operator_account_updated',
        payload: <String, Object?>{
          'fields_changed': patch.changedFieldNames,
        },
        occurredAt: _now().toUtc(),
      );
      return (statusCode: 200, body: record.toJson());
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

  Future<({int statusCode, Map<String, Object?> body})> _handleProfileCreate({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    final ValidatedBusinessTimingProfile validated;
    try {
      validated = validateNewBusinessTimingProfile(body);
    } on BusinessTimingValidationError catch (error) {
      return (statusCode: 400, body: error.toJson());
    }
    final scopeError = _checkScopeAgainstOperator(
      validated.scopeKind,
      validated.scopeId,
      operatorId,
    );
    if (scopeError != null) return scopeError;
    try {
      final record = await businessTimingGateway.createProfile(
        operatorId: operatorId,
        actorUserId: actorUserId,
        idempotencyKey: idempotencyKey,
        validated: validated,
        adminReason: 'operator.business_timing_profiles.create:$actorUserId',
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
        },
        occurredAt: _now().toUtc(),
      );
      await _notifyTimingMutation(
        operatorId: operatorId,
        profileId: record.profileId,
        scopeKind: record.scopeKind,
        scopeId: record.scopeId,
        eventKind: 'business_timing_profile_created',
        actorUserId: actorUserId,
        actorKind: actorKind,
      );
      return (statusCode: 201, body: record.toJson());
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

  Future<({int statusCode, Map<String, Object?> body})> _handleProfilePatch({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required String profileId,
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
    final scopeError = _checkScopeAgainstOperator(
      merged.scopeKind,
      merged.scopeId,
      operatorId,
    );
    if (scopeError != null) return scopeError;
    try {
      final record = await businessTimingGateway.updateProfile(
        operatorId: operatorId,
        actorUserId: actorUserId,
        idempotencyKey: idempotencyKey,
        profileId: profileId,
        validated: merged,
        adminReason: 'operator.business_timing_profiles.update:$actorUserId',
      );
      await auditSink.record(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventKind: 'business_timing_profile_updated',
        payload: <String, Object?>{
          'profile_id': record.profileId,
          'fields_changed': body.keys.toList(),
        },
        occurredAt: _now().toUtc(),
      );
      await _notifyTimingMutation(
        operatorId: operatorId,
        profileId: record.profileId,
        scopeKind: record.scopeKind,
        scopeId: record.scopeId,
        eventKind: 'business_timing_profile_updated',
        actorUserId: actorUserId,
        actorKind: actorKind,
      );
      return (statusCode: 200, body: record.toJson());
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

  Future<({int statusCode, Map<String, Object?> body})>
      _handleServicePeriodAdd({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required String profileId,
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
    final ({
      ValidatedServicePeriod added,
      List<ValidatedServicePeriod> merged
    }) outcome;
    try {
      outcome = validateAddServicePeriod(
        body: body,
        existing: existingValidated,
      );
    } on BusinessTimingValidationError catch (error) {
      return (statusCode: 400, body: error.toJson());
    }
    try {
      final record = await businessTimingGateway.replaceServicePeriodSet(
        operatorId: operatorId,
        actorUserId: actorUserId,
        idempotencyKey: idempotencyKey,
        profileId: profileId,
        mergedSet: outcome.merged,
        eventKind: 'business_timing_service_period_added',
        auditPayload: <String, Object?>{
          'profile_id': profileId,
          'key': outcome.added.key,
        },
        adminReason:
            'operator.business_timing_profiles.add_period:$actorUserId',
      );
      await auditSink.record(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventKind: 'business_timing_service_period_added',
        payload: <String, Object?>{
          'profile_id': profileId,
          'key': outcome.added.key,
        },
        occurredAt: _now().toUtc(),
      );
      await _notifyTimingMutation(
        operatorId: operatorId,
        profileId: record.profileId,
        scopeKind: record.scopeKind,
        scopeId: record.scopeId,
        eventKind: 'business_timing_service_period_added',
        actorUserId: actorUserId,
        actorKind: actorKind,
      );
      return (statusCode: 201, body: record.toJson());
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

  Future<({int statusCode, Map<String, Object?> body})>
      _handleServicePeriodPatch({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required String profileId,
    required String servicePeriodKey,
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
    final List<ValidatedServicePeriod> merged;
    try {
      merged = validateUpdateServicePeriod(
        body: body,
        urlKey: servicePeriodKey,
        existing: existingValidated,
      );
    } on BusinessTimingValidationError catch (error) {
      // service_period_not_found maps to 404 per contract; everything
      // else is 400.
      final statusCode =
          error.code == 'service_period_not_found' ? 404 : 400;
      return (statusCode: statusCode, body: error.toJson());
    }
    try {
      final record = await businessTimingGateway.replaceServicePeriodSet(
        operatorId: operatorId,
        actorUserId: actorUserId,
        idempotencyKey: idempotencyKey,
        profileId: profileId,
        mergedSet: merged,
        eventKind: 'business_timing_service_period_updated',
        auditPayload: <String, Object?>{
          'profile_id': profileId,
          'key': servicePeriodKey,
          'fields_changed': body.keys.toList(),
        },
        adminReason:
            'operator.business_timing_profiles.update_period:$actorUserId',
      );
      await auditSink.record(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventKind: 'business_timing_service_period_updated',
        payload: <String, Object?>{
          'profile_id': profileId,
          'key': servicePeriodKey,
          'fields_changed': body.keys.toList(),
        },
        occurredAt: _now().toUtc(),
      );
      await _notifyTimingMutation(
        operatorId: operatorId,
        profileId: record.profileId,
        scopeKind: record.scopeKind,
        scopeId: record.scopeId,
        eventKind: 'business_timing_service_period_updated',
        actorUserId: actorUserId,
        actorKind: actorKind,
      );
      return (statusCode: 200, body: record.toJson());
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

  /// Wave 2 W-5 — POST /v1/operator/business/logo. Delegates to the
  /// injected [BusinessLogoUploadHandler]; emits an audit row on
  /// success so the operator's audit log captures every replacement.
  /// Returns 503 when the handler is not wired (build without an
  /// Azure Blob env binding).
  Future<({int statusCode, Map<String, Object?> body})>
      _handleBusinessLogoUpload({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> body,
  }) async {
    final handler = _businessLogoUploadHandler;
    if (handler == null) {
      return (
        statusCode: 503,
        body: const <String, Object?>{
          'error': 'business_logo_uploader_not_configured',
          'message':
              'logo upload is not available on this build; '
              'paste an https URL instead',
        },
      );
    }
    final result = await handler.handleUpload(
      operatorId: operatorId,
      body: body,
    );
    if (result.statusCode == 200) {
      // Capture the upload in the operator's audit log even before the
      // resulting URL is persisted to `public.operators.logo_url` via
      // the existing PATCH route. The two writes are intentionally
      // split: the upload commits in Azure Blob first; the operator-
      // web client then issues PATCH /v1/operator/account `logoUrl`
      // with the returned URL. Without this audit row, a successful
      // upload + later PATCH failure would leave the blob in storage
      // with no trace in the operator's logs.
      await auditSink.record(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventKind: 'operator_business_logo_uploaded',
        payload: <String, Object?>{
          'logo_url': result.body['logoUrl'],
          'size_bytes': result.body['sizeBytes'],
        },
        occurredAt: _now().toUtc(),
      );
    }
    return result;
  }

  /// Wave 2 W-6 backend — PATCH /v1/operator/location-timezone.
  /// Delegates to the injected [OperatorLocationTimezoneHandler];
  /// emits an audit row capturing the before/after IANA tz pair on
  /// success so the operator's audit log reflects every primary-
  /// location timezone change. Returns 503 when the handler is not
  /// wired (build without a Postgres binding).
  Future<({int statusCode, Map<String, Object?> body})>
      _handleLocationTimezonePatch({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required Map<String, Object?> body,
  }) async {
    final handler = _locationTimezoneHandler;
    if (handler == null) {
      return (
        statusCode: 503,
        body: const <String, Object?>{
          'error': 'operator_location_timezone_not_configured',
          'message':
              'location timezone editing is not available on this '
              'build; please retry later.',
        },
      );
    }
    final result = await handler.handlePatch(
      operatorId: operatorId,
      actorUserId: actorUserId,
      body: body,
    );
    if (result.statusCode == 200) {
      await auditSink.record(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventKind: 'operator_location_timezone_updated',
        payload: <String, Object?>{
          'location_id': result.body['locationId'],
          'previous_tz': result.body['previousIanaTimezone'],
          'new_tz': result.body['ianaTimezone'],
        },
        occurredAt: _now().toUtc(),
      );
    }
    return result;
  }

  /// Wave 2 U-FU-hp11-account — GET
  /// /v1/operator/location-account-overrides/{location_id}. Read-only
  /// resolver; the dispatcher already routes through `isReadOnly` so
  /// the call bypasses the idempotency cache + Idempotency-Key
  /// requirement. Returns 503 when the handler is not wired.
  Future<({int statusCode, Map<String, Object?> body})>
      _handleLocationAccountOverridesGet({
    required String operatorId,
    required String actorUserId,
    required String locationId,
  }) async {
    final handler = _locationAccountOverridesHandler;
    if (handler == null) {
      return (
        statusCode: 503,
        body: const <String, Object?>{
          'error': 'operator_location_account_overrides_not_configured',
          'message':
              'per-location account overrides are not available on '
                  'this build; please retry later.',
        },
      );
    }
    return handler.handleGet(
      operatorId: operatorId,
      actorUserId: actorUserId,
      locationId: locationId,
    );
  }

  /// Wave 2 U-FU-hp11-account — PATCH
  /// /v1/operator/location-account-overrides/{location_id}. Emits an
  /// audit row capturing the previous + new field values on success
  /// so the operator's audit log reflects every per-location override
  /// change. Returns 503 when the handler is not wired.
  Future<({int statusCode, Map<String, Object?> body})>
      _handleLocationAccountOverridesPatch({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    final handler = _locationAccountOverridesHandler;
    if (handler == null) {
      return (
        statusCode: 503,
        body: const <String, Object?>{
          'error': 'operator_location_account_overrides_not_configured',
          'message':
              'per-location account overrides are not available on '
                  'this build; please retry later.',
        },
      );
    }
    final result = await handler.handlePatch(
      operatorId: operatorId,
      actorUserId: actorUserId,
      locationId: locationId,
      body: body,
    );
    if (result.statusCode == 200) {
      // The handler returns the full effective/override/businessDefault
      // triple; the audit payload captures the override + business
      // default so reviewers can reconstruct both the prior and new
      // effective values from the audit row alone (the previous
      // override row's state is the prior effective via business
      // default merge; the new effective is the audited override+
      // businessDefault merge).
      final override =
          (result.body['override'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{};
      final businessDefault =
          (result.body['businessDefault'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{};
      final effective =
          (result.body['effective'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{};
      await auditSink.record(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        eventKind: 'operator_location_account_overrides_updated',
        payload: <String, Object?>{
          'location_id': result.body['locationId'],
          'override': override,
          'business_default': businessDefault,
          'effective': effective,
        },
        occurredAt: _now().toUtc(),
      );
    }
    return result;
  }

  ValidatedBusinessTimingProfile _toValidated(
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
          ),
      ],
    );
  }

  ({int statusCode, Map<String, Object?> body})? _checkScopeAgainstOperator(
    String scopeKind,
    String scopeId,
    String operatorId,
  ) {
    if (scopeKind == 'operator' && scopeId != operatorId) {
      return (
        statusCode: 403,
        body: const <String, Object?>{
          'error': 'forbidden',
          'message':
              'operator-scoped business timing profile must target the '
              'caller operator',
        },
      );
    }
    return null;
  }
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

/// Reads the JSON body, allowing empty bodies (mapped to {}) so an
/// empty PATCH does not crash. Returns null on parse failure with the
/// status/body the caller should write.
Future<({Map<String, Object?>? body, int? errorStatus, Map<String, Object?>? errorBody})>
    readOperatorJsonBody(HttpRequest request) async {
  final raw = await utf8.decodeStream(request);
  if (raw.isEmpty) {
    return (
      body: <String, Object?>{},
      errorStatus: null,
      errorBody: null,
    );
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (error) {
    return (
      body: null,
      errorStatus: 400,
      errorBody: <String, Object?>{
        'error': 'malformed_json_body',
        'message': 'JSON parse failed: ${error.message}',
      },
    );
  }
  if (decoded is! Map) {
    return (
      body: null,
      errorStatus: 400,
      errorBody: <String, Object?>{
        'error': 'malformed_json_body',
        'message': 'JSON body must be an object',
      },
    );
  }
  return (
    body: Map<String, Object?>.from(decoded),
    errorStatus: null,
    errorBody: null,
  );
}
