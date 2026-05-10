// Forge & Flow advisor proxy — vendor lifecycle promotion routes.
//
// Phase 8 V1.E lane (vendor-now-available fan-out). Hosts the admin
// route that triggers the email fan-out when a vendor lifecycle
// promotes to `production_credentialed`:
//
//   POST /v1/admin/vendors/:vendor_id/lifecycle-promotion-notification
//
// Body shape:
//
//   { "new_lifecycle_state": "productionCredentialed" }
//
// Handler flow:
//
//   1. Verify the path matches a vendor id ("vendor_id" segment of
//      the URL is sanitised against the locked path pattern below).
//   2. Read the `Idempotency-Key` header. The handler uses it to
//      collapse retried POSTs to a single fan-out via the injected
//      [VendorLifecyclePromotionIdempotencyStore]; production binds
//      this to the proxy's `proxy_requests` table.
//   3. Verify the actor has the `super_admin` role gate. The route
//      mutates lifecycle-derived audit state (one outbox row per
//      pending notification) so the admin write-roles set guards it.
//   4. Hand off to [VendorLifecycleNotificationDispatcher.dispatchForVendor]
//      and return the per-vendor fan-out summary.
//
// The route is intentionally additive: the existing
// `routeRequest` dispatcher in `advisor_proxy.dart` is untouched.
// Mounting follows the same pattern as `AdminEmailRouter` —
// `main.dart` calls `tryHandle` before falling through to the
// monolithic dispatcher (mounting is a follow-up; the dispatcher is
// shipped independently per the V1.E lane prompt).
//
// Tenant isolation: the dispatcher walks one operator at a time, so
// the operator-leading index on `vendor_lifecycle_notification`
// stays engaged. The route does not require a per-tenant context;
// the dispatcher binds tenant context inside its repository seams.
//
// Idempotency posture (CLAUDE.md / "Proxy & API Conventions"):
//   * Every proxy write is idempotent. Clients carry an
//     `Idempotency-Key` header; the proxy stores keys in
//     `proxy_requests` (UNIQUE).
//   * The route refuses a write without an `Idempotency-Key` so
//     misbehaving callers cannot fan out duplicate emails on retry.
//
// Banned items posture: no `package:postgres` import (idempotency +
// authorisation seams keep this file backend-agnostic).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../log.dart';
import 'vendor_lifecycle_notification_dispatcher.dart';

/// Locked path prefix. Trailing path segment is the vendor id and
/// the route extracts it; the prefix is anchored so partial matches
/// (e.g. an unrelated `/v1/admin/vendors/abc/sync` route) do not
/// trip this handler.
const String adminVendorLifecyclePromotionPathPrefix =
    '/v1/admin/vendors/';

/// Trailing path suffix that disambiguates the lifecycle-promotion
/// route from any other future `/v1/admin/vendors/:vendor_id/*`
/// surface. Lifted from the slice prompt verbatim.
const String adminVendorLifecyclePromotionPathSuffix =
    '/lifecycle-promotion-notification';

/// Permission key required to call the route. Matches the
/// `kFfPlatformAdminWriteRoles` gate — only F&F super_admins may
/// promote a vendor lifecycle. The string is the literal Postgres
/// role name so the auth gate can run a single SQL membership check.
const String adminVendorLifecyclePromotionPermissionKey =
    'platform.vendor_lifecycle.promote';

/// Idempotency seam. Production binds this to the
/// `AdminRequestIdempotencyStore` backed by the `proxy_requests`
/// UNIQUE index; tests pass an in-memory map.
abstract class VendorLifecyclePromotionIdempotencyStore {
  /// Returns the cached response for an already-seen
  /// `Idempotency-Key`, or `null` for a fresh key. Production reads
  /// this through the existing `proxy_requests` UNIQUE row scoped to
  /// the route key.
  Future<Map<String, Object?>?> peek({required String idempotencyKey});

  /// Records the result of a freshly-handled call so a retried POST
  /// short-circuits to the cached response.
  Future<void> remember({
    required String idempotencyKey,
    required Map<String, Object?> response,
  });
}

/// Authorisation seam. Production binds this to the existing
/// platform-admin role gate (the same gate used by the email-
/// rotation route in `admin_email_routes.dart`); tests pin a fixed
/// principal.
typedef VendorLifecyclePromotionAuthorizer = Future<bool> Function(
  HttpRequest request,
);

/// Pluggable router. The marked region in main.dart mounts this
/// before delegating to the monolithic `routeRequest`.
class VendorLifecyclePromotionRouter {
  VendorLifecyclePromotionRouter({
    required VendorLifecycleNotificationDispatcher dispatcher,
    required VendorLifecyclePromotionAuthorizer authorizer,
    required VendorLifecyclePromotionIdempotencyStore idempotencyStore,
    DateTime Function()? now,
  })  : _dispatcher = dispatcher,
        _authorizer = authorizer,
        _idempotencyStore = idempotencyStore,
        _now = now ?? DateTime.now;

  final VendorLifecycleNotificationDispatcher _dispatcher;
  final VendorLifecyclePromotionAuthorizer _authorizer;
  final VendorLifecyclePromotionIdempotencyStore _idempotencyStore;
  final DateTime Function() _now;

  /// Returns `true` when the request matched the route and was fully
  /// handled. Caller (main.dart marked region) must skip the rest of
  /// the dispatcher in that case.
  Future<bool> tryHandle(HttpRequest request) async {
    if (request.method != 'POST') return false;
    final vendorId = _extractVendorId(request.uri.path);
    if (vendorId == null) return false;

    final response = request.response;

    // Idempotency-Key gate.
    final idempotencyKey =
        request.headers.value('Idempotency-Key')?.trim();
    if (idempotencyKey == null || idempotencyKey.isEmpty) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'idempotency_key_required',
        'message':
            'Idempotency-Key header is required for vendor lifecycle '
            'promotion notification fan-out',
      });
      return true;
    }

    // RBAC gate. The authorizer returns false on missing role; the
    // route returns 403 without leaking which permission was missing.
    final authorized = await _authorizer(request);
    if (!authorized) {
      _writeJson(response, 403, <String, Object?>{
        'error': 'permission_denied',
        'message':
            'caller is not authorised to promote vendor lifecycle',
      });
      return true;
    }

    // Idempotency replay short-circuit.
    final cached =
        await _idempotencyStore.peek(idempotencyKey: idempotencyKey);
    if (cached != null) {
      _writeJson(response, 200, cached);
      return true;
    }

    // Body parse.
    final bodyBytes = await _readBody(request);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (bodyBytes.isNotEmpty) {
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bodyBytes));
      } catch (_) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'invalid_json_body',
          'message': 'request body must be valid JSON or empty',
        });
        return true;
      }
      if (decoded is Map) {
        parsed = decoded.cast<String, Object?>();
      }
    }

    final newLifecycleState =
        (parsed['new_lifecycle_state'] as String?)?.trim();
    if (newLifecycleState == null || newLifecycleState.isEmpty) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'new_lifecycle_state_required',
        'message':
            'new_lifecycle_state body field is required '
            '(e.g. "productionCredentialed")',
      });
      return true;
    }

    try {
      final outcome = await _dispatcher.dispatchForVendor(
        vendorId: vendorId,
        newLifecycleState: newLifecycleState,
      );
      final body = <String, Object?>{
        ...outcome.toJson(),
        'dispatched_at': _now().toUtc().toIso8601String(),
      };
      await _idempotencyStore.remember(
        idempotencyKey: idempotencyKey,
        response: body,
      );
      _writeJson(response, 200, body);
    } catch (error, stack) {
      // P0 fix (2026-05-09 webhook signature triage Section 4 — leak
      // site #8): no internal exception details (DB / SendGrid / fan-
      // out repo error text) in the response body.
      final errorId = _generateErrorId();
      log(
        LogSeverity.error,
        'lifecycle_promotion_unhandled_error',
        fields: <String, Object?>{
          'error_id': errorId,
          'vendor_id': vendorId,
          'error': error.toString(),
          'stack_first_frame': _firstStackFrame(stack),
        },
      );
      _writeJson(response, 500, <String, Object?>{
        'error': 'lifecycle_promotion_unhandled_error',
        'error_id': errorId,
        'message': 'internal_server_error',
      });
    }
    return true;
  }

  /// Extracts the vendor id segment from a path matching
  /// `/v1/admin/vendors/<vendor_id>/lifecycle-promotion-notification`.
  /// Returns `null` for any other shape so the caller can fall
  /// through to the next route in the chain.
  String? _extractVendorId(String path) {
    if (!path.startsWith(adminVendorLifecyclePromotionPathPrefix)) {
      return null;
    }
    if (!path.endsWith(adminVendorLifecyclePromotionPathSuffix)) {
      return null;
    }
    final trimmed = path.substring(
      adminVendorLifecyclePromotionPathPrefix.length,
      path.length - adminVendorLifecyclePromotionPathSuffix.length,
    );
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('/')) return null;
    if (trimmed.length > 64) return null;
    if (trimmed != trimmed.trim()) return null;
    return trimmed;
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _writeJson(HttpResponse response, int status, Object? body) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    response.close();
  }

  /// P0 fix (2026-05-09 webhook signature triage): per-failure
  /// correlation id surfaced in the response body. The full exception
  /// text + stack stays in the structured log keyed on this id.
  static final Random _errorIdRandom = Random.secure();

  static String _generateErrorId() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _errorIdRandom.nextInt(256);
    }
    final hex = StringBuffer();
    for (final b in bytes) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }

  static String _firstStackFrame(StackTrace stack) {
    final s = stack.toString();
    final newline = s.indexOf('\n');
    return newline < 0 ? s : s.substring(0, newline);
  }
}
