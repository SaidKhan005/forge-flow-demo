// Phase 11W.3 - Operator Web team hierarchy gateway (live).
//
// Re-implementation of the team org-hierarchy surface of
// `AuthOperationsGateway` against `package:http`, so the operator-web
// build can call the existing Phase 9 + 11A.1 proxy routes without
// dragging in `dart:io`. Mirrors the 11W.1 Members gateway pattern:
// narrow interface + `package:http` impl, no `dart:io`, no `sqflite`,
// no extension of the mobile `proxy_*.dart` gateway.
//
// Routes (already shipped by Phase 9 + 11A.1; no new backend surface
// added by 11W.3):
//
//   * GET   /v1/auth/team/org-units
//   * POST  /v1/auth/team/org-units
//   * PATCH /v1/auth/team/locations/{location_id}/org-unit
//
// The proxy route handlers gate POST + PATCH on `team.roles.assign`
// (per `tool/advisor_proxy/advisor_proxy.dart` § auth-operations) and
// GET on `team.users.view` per the parity contract § Permission gate
// cheat sheet (Hierarchy row).
//
// Idempotency posture: every write carries an `Idempotency-Key`
// request header. The screen layer mints one key per user action and
// threads it through the dialog -> gateway path, matching the parity
// contract § Idempotency keys rule. The gateway does NOT mint keys
// internally (doing so would double-mint and break replay).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/auth/auth_operations_gateway.dart';

/// Narrow interface the Hierarchy screen reads + writes against.
/// Mirrors the team org-hierarchy slice of the existing
/// `AuthOperationsGateway` interface so 11W slices that need adjacent
/// surfaces can ship their own gateways under the same naming
/// pattern.
abstract class WebTeamHierarchyGateway {
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  );

  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command, {
    required String idempotencyKey,
  });

  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command, {
    required String idempotencyKey,
  });
}

/// Live wire shape returned by the proxy. Mirrors the response
/// envelope `proxy_auth_operations_gateway.dart` already consumes.
class WebTeamHierarchyResponse {
  const WebTeamHierarchyResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Thrown when the proxy returns a non-2xx for a hierarchy call, or
/// when the response body cannot be parsed.
class WebTeamHierarchyError implements Exception {
  const WebTeamHierarchyError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'WebTeamHierarchyError(code: $code, status: $statusCode, message: $message)';
}

/// Path constants used by both the gateway and its tests. Public so
/// the HTTP wire test can pin the exact routes the gateway calls.
class WebTeamHierarchyPaths {
  const WebTeamHierarchyPaths._();

  static const String orgUnits = '/v1/auth/team/org-units';
  static const String locationsPrefix = '/v1/auth/team/locations/';

  static String locationOrgUnit(String locationId) =>
      '$locationsPrefix${Uri.encodeComponent(locationId)}/org-unit';
}

/// Live `package:http` implementation. Reads the Firebase ID token
/// from the supplied provider on every call so refreshed tokens land
/// on the next request.
class WebTeamHierarchyGatewayLive implements WebTeamHierarchyGateway {
  WebTeamHierarchyGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  }) : _idTokenProvider = idTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    final response = await _send(
      method: 'GET',
      path: WebTeamHierarchyPaths.orgUnits,
    );
    _expectStatus(response, 200);
    final rawOrgUnits = response.body['org_units'];
    final rawLocations = response.body['locations'];
    if (rawOrgUnits is! List || rawLocations is! List) {
      throw _malformed(response, 'org hierarchy response was incomplete');
    }
    return TeamOrgHierarchyListed(
      orgUnits: List<TeamOrgUnitEntry>.unmodifiable(
        rawOrgUnits.map((raw) => _orgUnitFromJson(response, raw)),
      ),
      locations: List<TeamOrgLocationEntry>.unmodifiable(
        rawLocations.map((raw) => _orgLocationFromJson(response, raw)),
      ),
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamHierarchyPaths.orgUnits,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'parent_org_unit_id': command.parentOrgUnitId,
        'unit_type': command.unitType,
        'label': command.label,
        'name': command.name,
      },
    );
    _expectStatus(response, 201);
    final orgUnitId = _readNonBlankString(response.body['org_unit_id']);
    if (orgUnitId == null) {
      throw _malformed(response, 'org unit create response was incomplete');
    }
    return TeamOrgUnitCreated(orgUnitId: orgUnitId);
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'PATCH',
      path: WebTeamHierarchyPaths.locationOrgUnit(command.targetLocationId),
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{'parent_org_unit_id': command.parentOrgUnitId},
    );
    _expectStatus(response, 200);
    final moved = response.body['moved'];
    if (moved is! bool) {
      throw _malformed(response, 'org unit move response was incomplete');
    }
    return TeamLocationOrgUnitMoved(moved: moved);
  }

  Future<WebTeamHierarchyResponse> _send({
    required String method,
    required String path,
    String? idempotencyKey,
    Map<String, Object?>? body,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WebTeamHierarchyError(
        code: 'no_id_token',
        message:
            'team-hierarchy gateway has no live Firebase ID token to attach '
            'to the request.',
      );
    }
    final headers = <String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer ${token.trim()}',
      if (body != null) 'content-type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final url = proxyBaseUri.resolve(path);
    final request = http.Request(method, url);
    request.headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const WebTeamHierarchyError(
        code: 'transport_timeout',
        message:
            'team-hierarchy gateway request timed out before reaching the '
            'proxy.',
      );
    } catch (error) {
      throw WebTeamHierarchyError(
        code: 'transport_error',
        message:
            'team-hierarchy gateway request failed before reaching the '
            'proxy ($error).',
      );
    }
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    Object? decoded;
    if (raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = const <String, Object?>{};
      }
    }
    final responseBody = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
    return WebTeamHierarchyResponse(
      statusCode: streamed.statusCode,
      body: responseBody,
    );
  }

  void _expectStatus(WebTeamHierarchyResponse response, int expected) {
    if (response.statusCode == expected) return;
    throw WebTeamHierarchyError(
      code:
          _readNonBlankString(response.body['error']) ??
          'team_hierarchy_failed',
      message:
          _readNonBlankString(response.body['message']) ??
          'proxy returned status ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  WebTeamHierarchyError _malformed(
    WebTeamHierarchyResponse response,
    String message,
  ) {
    return WebTeamHierarchyError(
      code: 'malformed_response',
      message: message,
      statusCode: response.statusCode,
    );
  }

  TeamOrgUnitEntry _orgUnitFromJson(
    WebTeamHierarchyResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'org unit payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final orgUnitId = _readNonBlankString(json['org_unit_id']);
    final unitType = _readNonBlankString(json['unit_type']);
    final path = _readNonBlankString(json['path']);
    final label = _readNonBlankString(json['label']);
    if (orgUnitId == null ||
        unitType == null ||
        path == null ||
        label == null) {
      throw _malformed(response, 'org unit payload was incomplete');
    }
    return TeamOrgUnitEntry(
      orgUnitId: orgUnitId,
      parentOrgUnitId: _readNonBlankString(json['parent_org_unit_id']),
      unitType: unitType,
      path: path,
      label: label,
    );
  }

  TeamOrgLocationEntry _orgLocationFromJson(
    WebTeamHierarchyResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'org location payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final locationId = _readNonBlankString(json['location_id']);
    final parentOrgUnitId = _readNonBlankString(json['parent_org_unit_id']);
    final orgUnitPath = _readNonBlankString(json['org_unit_path']);
    final label = _readNonBlankString(json['label']);
    if (locationId == null ||
        parentOrgUnitId == null ||
        orgUnitPath == null ||
        label == null) {
      throw _malformed(response, 'org location payload was incomplete');
    }
    return TeamOrgLocationEntry(
      locationId: locationId,
      parentOrgUnitId: parentOrgUnitId,
      orgUnitPath: orgUnitPath,
      label: label,
    );
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
