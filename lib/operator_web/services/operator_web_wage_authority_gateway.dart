// Phase 8 W5.A.2 - Operator Web Wage authority gateway.
//
// Web parity for the mobile `WageAuthoritySection`. The mobile section
// was collapsed to view-only by W3.A; this gateway is the read + write
// seam the operator-web Wage authority screen calls.
//
// Three operations:
//
//   * [list]   - GET /v1/operators/:operatorId/locations/:locationId/
//                wage_role_rows
//                Returns the per-tenant active wage rows. The proxy's
//                read seam (mobile sync route) returns
//                `{ "wage_role_rows": [...], "next_cursor": ... }`
//                where each row mirrors `WageRoleRowRecord.toJson`.
//
//   * [upsert] - POST /v1/operator/wage-role-rows
//                Required `Idempotency-Key`. Body = the upsert payload
//                from the editor. Server upserts on the natural-key
//                4-tuple `(operator_id, location_id, restaurant_id,
//                role_name)` so a same-payload retry is idempotent.
//
//   * [delete] - DELETE /v1/operator/wage-role-rows/:wage_role_row_id
//                Required `Idempotency-Key`. Server soft-deletes
//                (`is_active = false`); the row stays in the table but
//                stops appearing in the list response.
//
// Web-safe: pure-Dart over `package:http`. No `dart:io`, no sqflite.
//
// Provider seam pattern: the live HTTP gateway is mixed into the live
// `FirebaseOperatorWebAuthSource` via
// [OperatorWebWageAuthorityGatewayProvider]; demo / fixture sources
// mix in the in-memory [OperatorWebDemoWageAuthorityGateway] so the
// walkthrough renders + edits end-to-end without a live proxy.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/wage_role_row_record.dart';

/// Wire path constants. The write paths mirror
/// [wageRoleRowsPath] / [wageRoleRowsPrefix] in
/// `tool/advisor_proxy/wage_role_rows_routes.dart`; the read path
/// mirrors the mobile sync route in
/// `tool/advisor_proxy/advisor_proxy.dart` (`_mobileOperationalPath`
/// → `wage_role_rows`).
const String kOperatorWebWageRoleRowsWritePath =
    '/v1/operator/wage-role-rows';
const String kOperatorWebWageRoleRowsWritePrefix =
    '$kOperatorWebWageRoleRowsWritePath/';

String operatorWebWageRoleRowsReadPath({
  required String operatorId,
  required String locationId,
}) =>
    '/v1/operators/${Uri.encodeComponent(operatorId)}/locations/'
    '${Uri.encodeComponent(locationId)}/wage_role_rows';

/// Editor-side request payload sent to [OperatorWebWageAuthorityGateway.upsert].
/// Mirrors the body the proxy `_handleUpsert` validates.
class WageRoleRowUpsert {
  const WageRoleRowUpsert({
    required this.restaurantId,
    required this.roleName,
    required this.laborBucket,
    required this.hourlyRate,
    required this.weightedHours,
    this.jobCode,
    this.vendorId,
    this.vendorRoleId,
    this.source,
    this.metadata = const <String, Object?>{},
  });

  final String restaurantId;
  final String roleName;

  /// `'foh' | 'boh' | 'manager'` — matches the migration CHECK.
  final String laborBucket;
  final double hourlyRate;
  final double weightedHours;
  final String? jobCode;
  final String? vendorId;
  final String? vendorRoleId;

  /// Optional override of `source`; defaults server-side to
  /// `operator_manual` when omitted.
  final WageRoleRowSource? source;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
        'restaurant_id': restaurantId,
        'role_name': roleName,
        'labor_bucket': laborBucket,
        'hourly_rate': hourlyRate,
        'weighted_hours': weightedHours,
        if (jobCode != null) 'job_code': jobCode,
        if (vendorId != null) 'vendor_id': vendorId,
        if (vendorRoleId != null) 'vendor_role_id': vendorRoleId,
        if (source != null) 'source': source!.wire,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };
}

/// Thrown when the proxy returns a non-2xx response or the body cannot
/// be parsed. The screen renders a plain-English snackbar off
/// [message]; [code] / [statusCode] are diagnostic only.
class WageAuthorityGatewayException implements Exception {
  const WageAuthorityGatewayException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'WageAuthorityGatewayException(code: $code, status: $statusCode)';
}

/// Gateway interface the screen calls. Both demo and live impls live
/// in this file so the operator-web build picks one based on the auth
/// source.
abstract class OperatorWebWageAuthorityGateway {
  Future<List<WageRoleRowRecord>> list({
    required String operatorId,
    required String locationId,
  });

  Future<WageRoleRowRecord> upsert({
    required WageRoleRowUpsert request,
    required String idempotencyKey,
  });

  /// Returns true when the row was found + soft-deleted, false when it
  /// was already inactive (or never existed under this tenant).
  Future<bool> delete({
    required String wageRoleRowId,
    required String idempotencyKey,
  });
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply an [OperatorWebWageAuthorityGateway] for the Wage
/// authority surface. Live wiring (Firebase source + proxy) implements
/// this; demo / fixture sources may fall back to the in-memory demo
/// gateway exposed via the same sentinel.
abstract class OperatorWebWageAuthorityGatewayProvider {
  OperatorWebWageAuthorityGateway get wageAuthorityGateway;
}

/// Live HTTP gateway. Reaches the proxy directly with a Bearer token
/// from [idTokenProvider] on every call.
class OperatorWebHttpWageAuthorityGateway
    implements OperatorWebWageAuthorityGateway {
  OperatorWebHttpWageAuthorityGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? client,
  })  : _baseUri = proxyBaseUri,
        _idTokenProvider = idTokenProvider,
        _client = client ?? http.Client();

  final Uri _baseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _client;

  Future<Map<String, String>> _authHeaders({String? idempotencyKey}) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WageAuthorityGatewayException(
        code: 'unauthenticated',
        message: 'Sign in again to manage wage rows.',
        statusCode: 401,
      );
    }
    return <String, String>{
      'authorization': 'Bearer ${token.trim()}',
      'accept': 'application/json',
      'content-type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
  }

  Uri _resolve(String path) => _baseUri.resolve(path);

  @override
  Future<List<WageRoleRowRecord>> list({
    required String operatorId,
    required String locationId,
  }) async {
    final headers = await _authHeaders();
    final response = await _client.get(
      _resolve(operatorWebWageRoleRowsReadPath(
        operatorId: operatorId,
        locationId: locationId,
      )),
      headers: headers,
    );
    final body = _decode(response);
    final raw = body['wage_role_rows'];
    if (raw is! List) {
      throw const WageAuthorityGatewayException(
        code: 'malformed_response',
        message: "We couldn't read your wage rows. Try again in a minute.",
      );
    }
    return <WageRoleRowRecord>[
      for (final entry in raw)
        if (entry is Map) _wageRoleRowRecordFromJson(
            Map<String, Object?>.from(entry)),
    ];
  }

  @override
  Future<WageRoleRowRecord> upsert({
    required WageRoleRowUpsert request,
    required String idempotencyKey,
  }) async {
    final headers = await _authHeaders(idempotencyKey: idempotencyKey);
    final response = await _client.post(
      _resolve(kOperatorWebWageRoleRowsWritePath),
      headers: headers,
      body: jsonEncode(request.toJson()),
    );
    final body = _decode(response);
    return _wageRoleRowRecordFromJson(body);
  }

  @override
  Future<bool> delete({
    required String wageRoleRowId,
    required String idempotencyKey,
  }) async {
    final headers = await _authHeaders(idempotencyKey: idempotencyKey);
    final response = await _client.delete(
      _resolve(
        '$kOperatorWebWageRoleRowsWritePrefix${Uri.encodeComponent(wageRoleRowId)}',
      ),
      headers: headers,
    );
    final body = _decode(response);
    final removed = body['removed'];
    return removed is bool ? removed : true;
  }

  Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?> body;
    try {
      final decoded = response.body.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(response.body);
      body = decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
    } catch (_) {
      throw WageAuthorityGatewayException(
        code: 'malformed_response',
        message: "We couldn't read the response from Forge & Flow. "
            "Try again in a minute.",
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      throw WageAuthorityGatewayException(
        code: (body['error'] as String?) ?? 'request_failed',
        message: (body['message'] as String?) ??
            "Couldn't save - try again.",
        statusCode: response.statusCode,
      );
    }
    return body;
  }
}

/// Demo-data Slice F (§2c / Gap G10) — operator-web mirror of the
/// mobile HP #11 wage scope story so both consoles tell the same
/// inheritance tale. The mobile seed
/// (`_seedDemoScopeOverrideWageRows`) realizes the §2c wage scope as
/// per-`restaurant_id` `wage_role_rows`; this fixture is its
/// operator-web analogue, keyed by the demo team location ids
/// (`kDemoTeamLocationsFixture`) + operator `demo-operator`:
///
///   * Downtown (`demo-loc-downtown`) — business default
///     FOH 14.50 / 18.50, BOH 19.35 / 23.35 (blend 16.50 / 21.35).
///   * Riverside (`demo-loc-riverside`) — LOCATION override, location
///     wins over the business default: FOH 15.50 / 19.50,
///     BOH 20.35 / 24.35 (blend 17.50 / 22.35).
///   * Harbour (`demo-loc-harbour`) + North Loop (`demo-loc-north-loop`)
///     — NO override; their rows equal the business default, so the
///     Wage authority screen, switched to either, renders the inherited
///     business-default effective wage.
///
/// HP #11 note: the inherited-SOURCE pill on the Wage authority screen
/// is Gap 32 (the screen's scope is hardcoded to
/// `HierarchyScopeLevel.location` per spec §1.7) — that is
/// gated/incomplete UI, not an affordance this slice removes. This
/// fixture only shapes the DATA so the effective values are correct
/// (Riverside differs; Harbour/North Loop equal the business default)
/// the moment that pill lands. No `demo_*` construct, no reader branch
/// (HP #2): it is fixture data into the existing in-memory demo
/// gateway, contract §"Acceptable patterns". Deterministic: all values
/// are literals; timestamps are a fixed instant (never
/// `DateTime.now()`).
final List<WageRoleRowRecord> kDemoWageRoleRowScopeFixture =
    _buildDemoWageRoleRowScopeFixture();

List<WageRoleRowRecord> _buildDemoWageRoleRowScopeFixture() {
  final ts = DateTime.utc(2026, 5, 15);
  WageRoleRowRecord row({
    required String locationId,
    required String restaurantId,
    required String roleName,
    required String laborBucket,
    required double hourlyRate,
  }) =>
      WageRoleRowRecord(
        wageRoleRowId: 'demo-wage-$locationId-'
            '${roleName.toLowerCase().replaceAll(' ', '-')}',
        operatorId: 'demo-operator',
        locationId: locationId,
        restaurantId: restaurantId,
        roleName: roleName,
        laborBucket: laborBucket,
        hourlyRate: hourlyRate,
        weightedHours: 500.0,
        source: WageRoleRowSource.adminSeed,
        isActive: true,
        effectiveAt: ts,
        metadata: const <String, Object?>{},
        createdAt: ts,
        updatedAt: ts,
      );
  // (locationId, restaurantId, fohA, fohB, bohA, bohB)
  const cohorts = <List<Object>>[
    // Business default — Downtown.
    ['demo-loc-downtown', 'demo_restaurant_001', 14.50, 18.50, 19.35, 23.35],
    // Location override — Riverside (location wins, blend 17.50 / 22.35).
    [
      'demo-loc-riverside',
      'demo_restaurant_riverside',
      15.50,
      19.50,
      20.35,
      24.35,
    ],
    // Inherits the business default — Harbour.
    ['demo-loc-harbour', 'demo_restaurant_harbour', 14.50, 18.50, 19.35, 23.35],
    // Inherits the business default — North Loop (its HP #11 override
    // is timing/data-accuracy, not wage).
    [
      'demo-loc-north-loop',
      'demo_restaurant_north_loop',
      14.50,
      18.50,
      19.35,
      23.35,
    ],
  ];
  final out = <WageRoleRowRecord>[];
  for (final c in cohorts) {
    final loc = c[0] as String;
    final rid = c[1] as String;
    out.add(row(
        locationId: loc,
        restaurantId: rid,
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: c[2] as double));
    out.add(row(
        locationId: loc,
        restaurantId: rid,
        roleName: 'Bartender',
        laborBucket: 'foh',
        hourlyRate: c[3] as double));
    out.add(row(
        locationId: loc,
        restaurantId: rid,
        roleName: 'Prep Cook',
        laborBucket: 'boh',
        hourlyRate: c[4] as double));
    out.add(row(
        locationId: loc,
        restaurantId: rid,
        roleName: 'Line Cook',
        laborBucket: 'boh',
        hourlyRate: c[5] as double));
  }
  return out;
}

/// In-memory demo gateway. Mirrors the demo-pattern used by
/// `DemoWebNotificationPreferencesGateway` so the walkthrough renders
/// + edits end-to-end without a live proxy.
class OperatorWebDemoWageAuthorityGateway
    implements OperatorWebWageAuthorityGateway {
  /// [initial] defaults (when null / omitted) to
  /// [kDemoWageRoleRowScopeFixture] so the router-owned
  /// `OperatorWebDemoWageAuthorityGateway()` (operator_web_router.dart)
  /// renders the §2c HP #11 wage scope story. Pass an explicit list
  /// (including `const []`) to override the seed.
  OperatorWebDemoWageAuthorityGateway({
    Iterable<WageRoleRowRecord>? initial,
    DateTime Function()? now,
  })  : _store = <String, WageRoleRowRecord>{
          for (final r in (initial ?? kDemoWageRoleRowScopeFixture))
            r.wageRoleRowId: r,
        },
        _now = now ?? DateTime.now;

  final Map<String, WageRoleRowRecord> _store;
  final DateTime Function() _now;
  int _idCounter = 0;

  String _mintId() {
    _idCounter += 1;
    final n = _idCounter.toString().padLeft(12, '0');
    return 'demo0000-0000-0000-0000-$n';
  }

  @override
  Future<List<WageRoleRowRecord>> list({
    required String operatorId,
    required String locationId,
  }) async {
    final list = _store.values
        .where((r) =>
            r.operatorId == operatorId &&
            r.locationId == locationId &&
            r.isActive)
        .toList()
      ..sort((a, b) {
        final byBucket = a.laborBucket.compareTo(b.laborBucket);
        if (byBucket != 0) return byBucket;
        return a.roleName.compareTo(b.roleName);
      });
    return list;
  }

  @override
  Future<WageRoleRowRecord> upsert({
    required WageRoleRowUpsert request,
    required String idempotencyKey,
  }) async {
    // Match server-side natural-key conflict resolution.
    final existing = _store.values.firstWhere(
      (r) =>
          r.restaurantId == request.restaurantId &&
          r.roleName == request.roleName,
      orElse: () => WageRoleRowRecord(
        wageRoleRowId: '',
        operatorId: '',
        locationId: '',
        restaurantId: '',
        roleName: '',
        laborBucket: '',
        hourlyRate: 0,
        weightedHours: 0,
        source: WageRoleRowSource.operatorManual,
        isActive: true,
        effectiveAt: _now().toUtc(),
        metadata: const <String, Object?>{},
        createdAt: _now().toUtc(),
        updatedAt: _now().toUtc(),
      ),
    );
    final isNew = existing.wageRoleRowId.isEmpty;
    final id = isNew ? _mintId() : existing.wageRoleRowId;
    final now = _now().toUtc();
    final record = WageRoleRowRecord(
      wageRoleRowId: id,
      operatorId: existing.operatorId.isEmpty
          ? _resolvedOperatorId(existing)
          : existing.operatorId,
      locationId: existing.locationId.isEmpty
          ? _resolvedLocationId(existing)
          : existing.locationId,
      restaurantId: request.restaurantId,
      roleName: request.roleName,
      laborBucket: request.laborBucket,
      hourlyRate: request.hourlyRate,
      weightedHours: request.weightedHours,
      jobCode: request.jobCode,
      vendorId: request.vendorId,
      vendorRoleId: request.vendorRoleId,
      source: request.source ?? WageRoleRowSource.operatorManual,
      isActive: true,
      effectiveAt: existing.wageRoleRowId.isEmpty
          ? now
          : existing.effectiveAt,
      metadata: request.metadata,
      createdAt: existing.wageRoleRowId.isEmpty
          ? now
          : existing.createdAt,
      updatedAt: now,
    );
    _store[id] = record;
    return record;
  }

  @override
  Future<bool> delete({
    required String wageRoleRowId,
    required String idempotencyKey,
  }) async {
    final existing = _store[wageRoleRowId];
    if (existing == null || !existing.isActive) return false;
    _store[wageRoleRowId] = WageRoleRowRecord(
      wageRoleRowId: existing.wageRoleRowId,
      operatorId: existing.operatorId,
      locationId: existing.locationId,
      restaurantId: existing.restaurantId,
      roleName: existing.roleName,
      laborBucket: existing.laborBucket,
      hourlyRate: existing.hourlyRate,
      weightedHours: existing.weightedHours,
      jobCode: existing.jobCode,
      vendorId: existing.vendorId,
      vendorRoleId: existing.vendorRoleId,
      source: existing.source,
      isActive: false,
      effectiveAt: existing.effectiveAt,
      metadata: existing.metadata,
      createdAt: existing.createdAt,
      updatedAt: _now().toUtc(),
      updatedBy: existing.updatedBy,
    );
    return true;
  }

  // Demo-only fallbacks when an upsert lands before any seed row pinned
  // an operator/location identity. The walkthrough seeds a fixture
  // (see `kDemoOperatorWebSession`) so these only fire if the test
  // exercises a green-field upsert.
  String _resolvedOperatorId(WageRoleRowRecord existing) {
    if (existing.operatorId.isNotEmpty) return existing.operatorId;
    for (final r in _store.values) {
      if (r.operatorId.isNotEmpty) return r.operatorId;
    }
    return 'demo-operator';
  }

  String _resolvedLocationId(WageRoleRowRecord existing) {
    if (existing.locationId.isNotEmpty) return existing.locationId;
    for (final r in _store.values) {
      if (r.locationId.isNotEmpty) return r.locationId;
    }
    return 'demo-location';
  }
}

/// Parse one row out of the proxy's `_wageRoleRowJson` shape. The read
/// route uses `server_id` for the UUID and string-formatted timestamps;
/// `WageRoleRowRecord.fromRow` expects DateTime objects, so we
/// normalise here.
WageRoleRowRecord _wageRoleRowRecordFromJson(Map<String, Object?> json) {
  final id = (json['server_id'] ?? json['wage_role_row_id']) as String?;
  if (id == null || id.isEmpty) {
    throw const WageAuthorityGatewayException(
      code: 'malformed_wage_role_row',
      message: "We couldn't read your wage rows. Try again in a minute.",
    );
  }
  final operatorId = json['operator_id'] as String? ?? '';
  final locationId = json['location_id'] as String? ?? '';
  final restaurantId = json['restaurant_id'] as String? ?? '';
  final roleName = json['role_name'] as String? ?? '';
  final laborBucket = json['labor_bucket'] as String? ?? '';
  final hourlyRate = _coerceDouble(json['hourly_rate']) ?? 0.0;
  final weightedHours = _coerceDouble(json['weighted_hours']) ?? 0.0;
  final jobCode = _readNullableString(json['job_code']);
  final vendorId = _readNullableString(json['vendor_id']);
  final vendorRoleId = _readNullableString(json['vendor_role_id']);
  final source = json['source'] is String
      ? WageRoleRowSourceWire.fromWire(json['source'] as String)
      : WageRoleRowSource.operatorManual;
  final isActive = json['is_active'] is bool ? json['is_active'] as bool : true;
  final effectiveAt = _coerceDateTime(json['effective_at']);
  final metadataRaw = json['metadata'];
  final metadata = metadataRaw is Map
      ? Map<String, Object?>.from(metadataRaw)
      : <String, Object?>{};
  final createdAt = _coerceDateTime(json['created_at']);
  final updatedAt = _coerceDateTime(json['updated_at']);
  final updatedBy = _readNullableString(json['updated_by']);

  return WageRoleRowRecord(
    wageRoleRowId: id,
    operatorId: operatorId,
    locationId: locationId,
    restaurantId: restaurantId,
    roleName: roleName,
    laborBucket: laborBucket,
    hourlyRate: hourlyRate,
    weightedHours: weightedHours,
    jobCode: jobCode,
    vendorId: vendorId,
    vendorRoleId: vendorRoleId,
    source: source,
    isActive: isActive,
    effectiveAt: effectiveAt,
    metadata: metadata,
    createdAt: createdAt,
    updatedAt: updatedAt,
    updatedBy: updatedBy,
  );
}

double? _coerceDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is double) return raw;
  if (raw is int) return raw.toDouble();
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed != null) return parsed;
  }
  return null;
}

DateTime _coerceDateTime(Object? raw) {
  if (raw is DateTime) return raw.toUtc();
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      return DateTime.parse(raw).toUtc();
    } catch (_) {
      return DateTime.utc(1970);
    }
  }
  return DateTime.utc(1970);
}

String? _readNullableString(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
