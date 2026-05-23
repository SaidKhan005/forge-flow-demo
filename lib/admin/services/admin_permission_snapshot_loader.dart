// UX-parity Slice E0 — admin-console permission-snapshot loader.
//
// Brings the admin console in line with operator-web's capability-key
// model: after a live (non-demo) admin sign-in the auth source
// hydrates `AdminAuthSession.permissions` best-effort from the SAME
// Phase 9 proxy route operator-web uses (`/v1/auth/permissions/snapshot`).
// No new admin-only route, no parallel permission catalog entry
// (CLAUDE.md HP #11 + R-2).
//
// FAIL-SAFE CONTRACT (binding — the slice's whole invariant rests on
// this): [load] NEVER throws and NEVER blocks sign-in. Any failure —
// no token, network error, timeout, non-200, malformed body, scope
// mismatch — resolves to an EMPTY set. An empty set makes the
// key-first editing gates in `admin_routes.dart` (`_adminCanEdit`)
// fall back to the role check, which is byte-identical to the
// pre-slice behaviour. Sign-in proceeds regardless.
//
// WEB-SAFETY CONTRACT (R3 — make-or-break): this loader funnels every
// request through [sendAdminHttpRequest], the admin console's existing
// `package:http`-based chokepoint. It does NOT import `dart:io` and is
// NOT the `dart:io`-backed `DartIoProxyPermissionSnapshotHttpClient`
// from `lib/services/auth/proxy_permission_snapshot_loader.dart`
// (which would break the admin web build). Nothing reachable from
// `lib/main_admin.dart` may import `dart:io`.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'admin_http_timeout.dart';

/// Bearer source the loader attaches to the snapshot GET. Production
/// binds this to the admin Firebase ID-token stream (the same
/// `_firebaseIdTokenProvider` the sibling admin gateways use); tests
/// pin a synthetic value. May return null/blank when the user is
/// signed out — the loader then resolves to an empty set (fail-safe).
typedef AdminPermissionSnapshotBearerProvider = Future<String?> Function();

/// Loads the proxy-resolved permission-key set for an admin session.
/// Implementations MUST be fail-safe: [load] returns an empty set
/// rather than throwing on any error so a snapshot blip can never
/// block admin sign-in.
abstract class AdminPermissionSnapshotLoader {
  /// Returns the `allow`-effect permission keys the proxy resolved for
  /// the verified caller. Returns an empty set on ANY failure. Never
  /// throws.
  Future<Set<String>> load();
}

/// Production HTTP implementation. Constructor shape + bearer source +
/// timeout mirror `HttpAdminSessionsGateway`; the transport funnels
/// through [sendAdminHttpRequest] so the admin 401-refresh-retry and
/// MFA-freshness-redirect interception apply uniformly and the path
/// stays web-safe (no `dart:io`).
class HttpAdminPermissionSnapshotLoader implements AdminPermissionSnapshotLoader {
  HttpAdminPermissionSnapshotLoader({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri baseUri;
  final AdminPermissionSnapshotBearerProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Same Phase 9 route operator-web's `ProxyPermissionContextLoader`
  /// hits (`proxy_permission_snapshot_loader.dart` `snapshotPath`). The
  /// string is part of the wire contract; the proxy endpoint tests pin
  /// both sides.
  static const String snapshotPath = '/v1/auth/permissions/snapshot';

  @override
  Future<Set<String>> load() async {
    try {
      final token = await bearerTokenProvider();
      if (token == null || token.trim().isEmpty) {
        // Signed out / no live token — nothing to hydrate. Fall back
        // to the role check.
        return const <String>{};
      }
      final uri = baseUri.resolve(snapshotPath);
      final request = http.Request('GET', uri)
        ..headers['authorization'] = 'Bearer ${token.trim()}'
        ..headers['accept'] = 'application/json'
        // GET is idempotent; the proxy ignores the header on reads but
        // the admin chokepoint shape carries one for uniformity.
        ..headers['Idempotency-Key'] = _readOnlyIdempotencyKey();
      final http.Response response;
      try {
        response = await sendAdminHttpRequest(
          _httpClient,
          request,
          timeout: _timeout,
        );
      } on AdminHttpTimeoutException {
        // Timeout is a fail-safe no-op: sign-in must not wait on the
        // snapshot. Role fallback.
        return const <String>{};
      }
      if (response.statusCode != 200) {
        return const <String>{};
      }
      final raw = utf8.decode(response.bodyBytes);
      if (raw.isEmpty) return const <String>{};
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return const <String>{};
      }
      return parseAllowedPermissions(decoded);
    } catch (_) {
      // Defense-in-depth: ANY unexpected error resolves to empty so
      // the slice's byte-identical-when-empty invariant holds and
      // sign-in is never blocked.
      return const <String>{};
    }
  }

  /// Extracts the `allow`-effect permission keys from a decoded
  /// snapshot body. Mirrors the `permissions` map shape parsed by
  /// `ProxyPermissionContextLoader.load`
  /// (`{permissions: {<key>: 'allow' | 'deny'}}`): only `'allow'`
  /// entries are surfaced; `'deny'` (and anything else) is dropped. A
  /// missing / malformed map yields an empty set. Returns an
  /// unmodifiable set.
  @visibleForTesting
  static Set<String> parseAllowedPermissions(Object? decoded) {
    if (decoded is! Map) return const <String>{};
    final permissions = decoded['permissions'];
    if (permissions is! Map) return const <String>{};
    final allowed = <String>{};
    permissions.forEach((key, value) {
      if (key is String && value == 'allow') {
        allowed.add(key);
      }
    });
    return Set<String>.unmodifiable(allowed);
  }

  static final math.Random _readOnlyRandom = math.Random.secure();
  static String _readOnlyIdempotencyKey() {
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final r = _readOnlyRandom.nextInt(1 << 32).toRadixString(36);
    return 'admin-permission-snapshot-$ts-$r';
  }
}
