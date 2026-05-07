// fix(M2.pepper-runtime): proxy routes for pepper retrieval.
//
// Mounts two read-only endpoints so the app can fetch peppers at
// runtime instead of reading them from a compile-time dart-define:
//
//   GET /v1/auth/peppers/active   — active pepper (id + bytes)
//   GET /v1/auth/peppers/:id      — specific pepper by id
//
// Auth posture:
//   * Requires a valid `forge_admin` (super_admin/ff_support) OR
//     `forge_app` (service-principal, actorKind='service') JWT.
//   * No operator scope is required: the pepper store is platform-wide
//     and there is no per-tenant pepper today.
//
// Audit-log:
//   Every pepper read is logged as a structured JSON event with
//   actor_kind, actor_id (userId or servicePrincipalId), and pepper_id.
//   No pepper bytes appear in the log.
//
// Returns:
//   200  { "pepper_id": "sha256:...", "pepper_b64": "<base64>" }
//   401  unauthorized
//   404  { "error": "pepper_not_found", "pepper_id": "..." }
//   500  { "error": "pepper_store_error", "message": "..." }

import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/services/auth/kms_pepper_store.dart';

import 'advisor_proxy.dart' show ProxyRequestGuard;
import 'log.dart';

const String _pepperActivePath = '/v1/auth/peppers/active';
const String _pepperByIdPrefix = '/v1/auth/peppers/';

/// Roles allowed to fetch peppers. `super_admin` and `ff_support` cover
/// forge-admin actors; service principals carry `actorKind='service'`
/// and are admitted via [_isServicePrincipalClaims].
const Set<String> _pepperReadRoles = <String>{'super_admin', 'ff_support'};

/// Router for the two pepper endpoints. The marked region in main.dart
/// mounts this before delegating to the monolithic dispatcher so the
/// pepper surface stays isolated.
class PepperRouter {
  PepperRouter({
    required EnvKmsPepperStore store,
    required ProxyRequestGuard authGuard,
    LogSink? logSink,
  }) : _store = store,
       _authGuard = authGuard,
       _logSink = logSink ?? _defaultLogSink;

  final EnvKmsPepperStore _store;
  final ProxyRequestGuard _authGuard;
  final LogSink _logSink;

  /// Returns `true` when the request was handled (caller must not
  /// delegate to the main dispatcher). Returns `false` on path miss.
  Future<bool> tryHandle(HttpRequest request) async {
    final path = request.uri.path;
    final isPepperPath =
        path == _pepperActivePath ||
        (path.startsWith(_pepperByIdPrefix) &&
            path.length > _pepperByIdPrefix.length);
    if (!isPepperPath) return false;
    if (request.method != 'GET') {
      _writeJson(request.response, 405, <String, Object?>{
        'error': 'method_not_allowed',
        'allowed': 'GET',
      });
      return true;
    }
    try {
      await _handle(request, path);
    } catch (error, stack) {
      _writeJson(request.response, 500, <String, Object?>{
        'error': 'pepper_route_error',
        'message': error.toString(),
        'stack_first_frame': _firstFrame(stack),
      });
    }
    return true;
  }

  Future<void> _handle(HttpRequest request, String path) async {
    // Auth: require a verified JWT with one of the allowed roles OR a
    // service principal (actorKind='service').
    final _PepperActor? actor;
    try {
      actor = await _resolveActor(request);
    } on _PepperAuthException catch (e) {
      _writeJson(request.response, e.statusCode, <String, Object?>{
        'error': 'unauthorized',
        'message': e.message,
      });
      return;
    }

    if (path == _pepperActivePath) {
      await _handleActive(request, actor);
    } else {
      // /v1/auth/peppers/:id
      final rawId = path.substring(_pepperByIdPrefix.length);
      final pepperId = Uri.decodeComponent(rawId);
      await _handleById(request, actor, pepperId);
    }
  }

  Future<void> _handleActive(
    HttpRequest request,
    _PepperActor actor,
  ) async {
    final String b64;
    final String id;
    try {
      id = _store.activeId;
      b64 = _store.activePepperB64();
    } on KmsPepperStoreException catch (e) {
      _writeJson(request.response, 500, <String, Object?>{
        'error': 'pepper_store_error',
        'message': e.message,
      });
      return;
    }
    _auditLog(actor: actor, pepperId: id, route: 'active');
    _writeJson(request.response, 200, <String, Object?>{
      'pepper_id': id,
      'pepper_b64': b64,
    });
  }

  Future<void> _handleById(
    HttpRequest request,
    _PepperActor actor,
    String pepperId,
  ) async {
    final b64 = _store.pepperB64ForId(pepperId);
    if (b64 == null || b64.isEmpty) {
      _writeJson(request.response, 404, <String, Object?>{
        'error': 'pepper_not_found',
        'pepper_id': pepperId,
      });
      return;
    }
    _auditLog(actor: actor, pepperId: pepperId, route: 'by_id');
    _writeJson(request.response, 200, <String, Object?>{
      'pepper_id': pepperId,
      'pepper_b64': b64,
    });
  }

  Future<_PepperActor> _resolveActor(HttpRequest request) async {
    final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
    final _PepperActor actor;
    try {
      final claims = await _authGuard.requireVerifiedClaims(
        authorizationHeader: authHeader,
      );
      final actorKind = claims.actorKind;
      final isServicePrincipal = actorKind == 'service';
      final hasRole = claims.roles.any(
        (r) => _pepperReadRoles.contains(r),
      );
      if (!isServicePrincipal && !hasRole) {
        throw _PepperAuthException(
          'caller lacks required role (super_admin, ff_support) or '
          'service-principal actor kind',
          403,
        );
      }
      actor = _PepperActor(
        actorKind: actorKind,
        actorId: claims.userId.isNotEmpty
            ? claims.userId
            : claims.servicePrincipalId ?? 'unknown',
        roles: claims.roles,
      );
    } on _PepperAuthException {
      rethrow;
    } catch (e) {
      throw _PepperAuthException(e.toString(), 401);
    }
    return actor;
  }

  void _auditLog({
    required _PepperActor actor,
    required String pepperId,
    required String route,
  }) {
    _logSink(
      LogSeverity.info,
      'pepper.read',
      <String, Object?>{
        'actor_kind': actor.actorKind,
        'actor_id': actor.actorId,
        'pepper_id': pepperId,
        'route': route,
        // Explicit: no pepper bytes in the audit log.
      },
    );
  }

  static void _writeJson(HttpResponse response, int status, Object? body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    response.close();
  }

  static String _firstFrame(StackTrace stack) {
    final s = stack.toString();
    final newline = s.indexOf('\n');
    return newline < 0 ? s : s.substring(0, newline);
  }
}

/// Minimal actor record for pepper routes.
class _PepperActor {
  const _PepperActor({
    required this.actorKind,
    required this.actorId,
    required this.roles,
  });

  final String actorKind;
  final String actorId;
  final List<String> roles;
}

class _PepperAuthException implements Exception {
  const _PepperAuthException(this.message, this.statusCode);
  final String message;
  final int statusCode;
}

/// Log sink typedef mirrors the [log] helper signature from log.dart.
typedef LogSink = void Function(
  LogSeverity severity,
  String event,
  Map<String, Object?> fields,
);

void _defaultLogSink(
  LogSeverity severity,
  String event,
  Map<String, Object?> fields,
) =>
    log(severity, event, fields: fields);
