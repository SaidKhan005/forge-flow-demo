// Phase 8 framework — Admin actor resolver bridge.
//
// `Phase80IntegrationRoutesBindingsHolder.actorResolver`
// (`tool/advisor_proxy/admin_integrations_routes.dart`) expects a
// `Future<AdminActorContext?> Function(HttpRequest)` closure. The
// existing `productionBindings.integrationAdminActorResolver` returns a
// Postgres user UUID — wrong shape for the bindings holder. This file
// supplies the missing bridge: read the `Authorization: Bearer <token>`
// header, verify via the existing JWT verifier, look up the local
// Postgres user UUID via the existing `IntegrationAdminActorResolver`,
// and assemble a [AdminActorContext]. Returns null on every failure so
// the route handler can 401 cleanly.
//
// CLAUDE.md alignment:
//   * Hard Promise #4 — every operator/location pair carried in the
//     resolved context flows from the verified JWT claims, never from
//     untrusted request data.
//   * Hard Promise #7 — JWT verification + user lookup live server-side
//     under Cloud Run; the closure is consumed by the proxy router only.
//
// Why this file lives in `lib/` rather than `tool/advisor_proxy/`:
//   * The prompt placed the bridge in `lib/integrations/_common/` so
//     adapter-side scaffolding (the 17 vendor bridges) can live next to
//     the same package.
//   * The convention "no `lib/` file imports `tool/`" still holds; this
//     bridge therefore declares **lib-side abstractions** that mirror
//     the tool-side `ProxyJwtVerifier`, `IntegrationAdminActorResolver`,
//     and `AdminActorContext` shapes. The proxy bootstrap wraps the
//     tool-side instances in these abstractions when it wires the
//     `actorResolver` closure into `Phase80IntegrationRoutesBindingsHolder`.
//
// The lib-side abstractions defined here:
//   * [AdminActorContext]                — same fields as the tool type.
//   * [AdminActorJwtVerifier]            — same shape as `ProxyJwtVerifier`.
//   * [AdminActorJwtClaims]              — same shape as `ProxyJwtClaims`.
//   * [AdminActorUserResolver]           — same shape as
//                                           `IntegrationAdminActorResolver`.

import 'dart:io';

/// Authenticated context resolved from the inbound JWT. Mirrors the
/// `AdminActorContext` shape declared in
/// `tool/advisor_proxy/admin_integrations_routes.dart` so the bootstrap
/// can pass either type into the bindings holder by adapting through
/// this seam.
class AdminActorContext {
  const AdminActorContext({
    required this.operatorId,
    required this.locationId,
    required this.userId,
  });

  final String operatorId;
  final String locationId;
  final String userId;
}

/// Verified-claims subset relevant to the admin-actor closure. Mirrors
/// `ProxyJwtClaims` from `tool/advisor_proxy/advisor_proxy.dart`. The
/// bootstrap adapts the tool-side type to this minimal lib-side shape.
class AdminActorJwtClaims {
  const AdminActorJwtClaims({
    required this.firebaseUid,
    required this.operatorId,
    required this.locationId,
  });

  /// Firebase UID extracted from the verified token. The Postgres user
  /// lookup keys off this. Null when the token authenticated but did
  /// not carry a Firebase identity.
  final String? firebaseUid;

  /// Operator UUID extracted from the verified token's custom claims.
  /// Null when the token authenticated but is not yet operator-scoped.
  final String? operatorId;

  /// Location UUID extracted from the verified token's custom claims.
  /// Null when multi-location operators have not selected a location.
  final String? locationId;
}

/// Lib-side mirror of `ProxyJwtVerifier`. Implementations verify the
/// raw bearer token (without the `Bearer ` prefix) and return verified
/// claims, or throw on any failure.
abstract class AdminActorJwtVerifier {
  Future<AdminActorJwtClaims> verify(String bearerToken);
}

/// Lib-side mirror of `IntegrationAdminActorResolver`. The production
/// implementation reads `users` (admin pool / system scope) by Firebase
/// UID and returns the active user UUID — or null when no `users` row
/// matches.
abstract class AdminActorUserResolver {
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  });
}

/// Reason string the lookup resolver records for audit attribution.
/// All admin actor lookups originating from this bridge use the same
/// reason so triage queries can isolate the integrations dispatcher.
const String kAdminActorIntegrationsReason =
    'admin_integrations_actor_lookup';

const String _kAuthorizationHeader = 'authorization';
const String _kBearerPrefix = 'Bearer ';

/// Resolve the [AdminActorContext] for [request]. Returns null on every
/// failure (missing header, invalid JWT, missing operator/location
/// claim, no resolved Postgres user UUID) so the calling route can
/// surface a clean 401 / 403 without leaking the underlying reason.
///
/// Production wires:
///   * [jwtVerifier] = adapter over the proxy's `CompositeProxyJwtVerifier`
///     (Firebase + service-principal verifiers).
///   * [lookupResolver] = adapter over
///     `RepositoryIntegrationAdminActorResolver`.
Future<AdminActorContext?> resolveAdminActorFromHttpRequest(
  HttpRequest request, {
  required AdminActorJwtVerifier jwtVerifier,
  required AdminActorUserResolver lookupResolver,
}) async {
  final header = _readAuthorizationHeader(request);
  if (header == null) return null;
  if (!header.startsWith(_kBearerPrefix)) return null;
  final bearer = header.substring(_kBearerPrefix.length).trim();
  if (bearer.isEmpty) return null;

  final AdminActorJwtClaims claims;
  try {
    claims = await jwtVerifier.verify(bearer);
  } catch (_) {
    return null;
  }

  final firebaseUid = claims.firebaseUid;
  if (firebaseUid == null || firebaseUid.isEmpty) return null;
  final operatorId = claims.operatorId;
  if (operatorId == null || operatorId.isEmpty) return null;
  final locationId = claims.locationId;
  if (locationId == null || locationId.isEmpty) return null;

  final userId = await lookupResolver.resolveActorUserId(
    firebaseUid: firebaseUid,
    adminReason: kAdminActorIntegrationsReason,
  );
  if (userId == null || userId.isEmpty) return null;

  return AdminActorContext(
    operatorId: operatorId,
    locationId: locationId,
    userId: userId,
  );
}

String? _readAuthorizationHeader(HttpRequest request) {
  // `HttpRequest.headers.value` returns the first matching header
  // value. Header names in `dart:io` are lower-cased.
  return request.headers.value(_kAuthorizationHeader);
}
