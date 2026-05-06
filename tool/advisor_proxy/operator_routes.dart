// Phase 11W.7 / Wave A2 - operator-scoped account + business-timing
// proxy write routes.
//
// Five routes, all operator-scoped, all role-gated to operator owner /
// operator admin, all idempotent by Idempotency-Key.
//
//   PATCH /v1/operator/account
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

export 'package:forge_and_flow/services/business_timing/operator_write_contracts.dart';

/// Route paths. Exported so the frontend gateway tests and the proxy
/// dispatcher reference one canonical set of strings.
const String operatorAccountPatchPath = '/v1/operator/account';
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

/// Encapsulates the dispatch + auth + idempotency + audit boilerplate
/// for the five operator write routes.
class OperatorWriteRouter {
  OperatorWriteRouter({
    required this.accountGateway,
    required this.businessTimingGateway,
    required this.auditSink,
    OperatorWriteIdempotencyCache? idempotencyCache,
    DateTime Function()? now,
  })  : _idempotencyCache = idempotencyCache ?? OperatorWriteIdempotencyCache(),
        _now = now ?? DateTime.now;

  final OperatorAccountWriteGateway accountGateway;
  final OperatorBusinessTimingWriteGateway businessTimingGateway;
  final OperatorWriteAuditSink auditSink;
  final OperatorWriteIdempotencyCache _idempotencyCache;
  final DateTime Function() _now;

  /// True when [path] / [method] match one of the five routes. The
  /// dispatcher uses this to short-circuit the catch-all 404 in the
  /// monolithic `routeRequest` without wiring 5 separate ifs.
  static bool matches(String path, String method) {
    if (method == 'PATCH' && path == operatorAccountPatchPath) return true;
    if (method == 'POST' && path == operatorBusinessTimingProfilesPath) {
      return true;
    }
    if (path.startsWith(operatorBusinessTimingProfilePrefix)) {
      if (method == 'PATCH' || method == 'POST') return true;
    }
    return false;
  }

  /// Handles one request once auth + role gate + Idempotency-Key
  /// header have been resolved by the caller.
  Future<({int statusCode, Map<String, Object?> body})> handle({
    required String method,
    required String path,
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
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
    if (method == 'PATCH' && path == operatorAccountPatchPath) {
      return _handleAccountPatch(
        operatorId: operatorId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        idempotencyKey: idempotencyKey,
        body: body,
      );
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
