// Phase 9 live-closeout B19 - Proxy admin permission guard.
//
// Server-side permission gate the proxy invokes BEFORE running any
// `/v1/admin/*` handler. Wraps:
//
//   1. The Phase 9.6 `PermissionResolver` (deny wins, default deny,
//      time-bound grants, location scope).
//   2. The Phase 9.6 `PermissionCache` so each request consults
//      Postgres at most once per user / role-version / op / loc.
//   3. MFA freshness — sensitive permission keys (those flagged
//      `requires_mfa = true` in `permission_keys`) refuse when the
//      session's `auth_time` is past the locked 5-minute window.
//   4. Optional reCAPTCHA decision from B16 — when the route is
//      reCAPTCHA-protected the guard refuses on `reject` and emits
//      a `challenge_required` outcome on `challenge`.
//
// The guard is the only seam the proxy admin handlers depend on for
// permission decisions. Tests inject fakes; production wires a
// concrete impl that reads `user_roles` + `role_permissions` via
// the tenant-scoped repositories.

import '../../auth/permission_effect.dart';

/// Per-request context the guard needs. The proxy resolves these
/// from the verified JWT + the request's path/headers.
class ProxyAdminGuardContext {
  const ProxyAdminGuardContext({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.lastFreshAuthAt,
    required this.requestedPermissionKey,
    this.requestedAt,
    this.recaptchaOutcome,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final DateTime lastFreshAuthAt;
  final String requestedPermissionKey;
  final DateTime? requestedAt;

  /// Optional decision from a reCAPTCHA-protected route. Routes
  /// that are NOT reCAPTCHA-protected pass null. The guard uses
  /// `null` as "n/a" rather than an implicit pass.
  final ProxyAdminGuardRecaptcha? recaptchaOutcome;
}

/// Outcome of a reCAPTCHA verification step the proxy runs before
/// invoking the guard. Only `RecaptchaV3Decision`-style values matter
/// here; the guard does not run the verification itself.
enum ProxyAdminGuardRecaptcha {
  accept,
  challenge,
  reject,
}

/// Decision the guard returns. Sealed so the proxy can pattern-match
/// in the route handler.
sealed class ProxyAdminGuardDecision {
  const ProxyAdminGuardDecision();
}

class ProxyAdminAllowed extends ProxyAdminGuardDecision {
  const ProxyAdminAllowed();
}

class ProxyAdminDeniedDefault extends ProxyAdminGuardDecision {
  const ProxyAdminDeniedDefault();
}

class ProxyAdminDeniedExplicit extends ProxyAdminGuardDecision {
  const ProxyAdminDeniedExplicit({required this.matchedRoleId});
  final String matchedRoleId;
}

class ProxyAdminMfaStaleAuth extends ProxyAdminGuardDecision {
  const ProxyAdminMfaStaleAuth({required this.refreshAfter});
  final DateTime refreshAfter;
}

class ProxyAdminChallengeRequired extends ProxyAdminGuardDecision {
  const ProxyAdminChallengeRequired();
}

class ProxyAdminRejected extends ProxyAdminGuardDecision {
  const ProxyAdminRejected({required this.reasonCode});
  final String reasonCode;
}

/// What every concrete permission guard implements.
abstract class ProxyAdminPermissionGuard {
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  );
}

/// Hard-fail-closed default. Refuses every admin request when the
/// real guard is not bound — production must wire the real binding
/// before exposing `/v1/admin/*` routes.
class ScaffoldFailingProxyAdminPermissionGuard
    implements ProxyAdminPermissionGuard {
  const ScaffoldFailingProxyAdminPermissionGuard();

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    throw StateError(
      'B19 scaffold: real ProxyAdminPermissionGuard is not wired — '
      'bind the production guard (over UserRolesRepository + '
      'RolePermissionsRepository + PermissionCache) in the proxy '
      'bootstrap before exposing /v1/admin/* routes.',
    );
  }
}

/// In-memory guard for tests + dev. The caller seeds the resolved
/// permission per (userId, permissionKey, locationId) and the
/// `requires_mfa` flag per permission key. The guard then folds in
/// MFA freshness + reCAPTCHA outcomes uniformly.
class InMemoryProxyAdminPermissionGuard
    implements ProxyAdminPermissionGuard {
  InMemoryProxyAdminPermissionGuard({
    required this.permissionEffects,
    Set<String>? requiresMfaKeys,
    Set<String>? recaptchaProtectedKeys,
    Duration freshnessWindow = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : requiresMfaKeys = requiresMfaKeys ?? const <String>{},
       recaptchaProtectedKeys = recaptchaProtectedKeys ?? const <String>{},
       _freshnessWindow = freshnessWindow,
       _now = now ?? DateTime.now;

  /// Map of `(userId, permissionKey)` → resolved effect (deny wins
  /// is up to the seeder). Tests precompute these; production reads
  /// via the resolver + cache.
  final Map<String, PermissionEffect> permissionEffects;

  /// Permission keys flagged `requires_mfa = true` in
  /// `permission_keys`. The guard refuses with [ProxyAdminMfaStaleAuth]
  /// when the session is past the freshness window.
  final Set<String> requiresMfaKeys;

  /// Permission keys that route through a reCAPTCHA-protected
  /// endpoint. The guard refuses on a missing or rejected outcome.
  final Set<String> recaptchaProtectedKeys;

  final Duration _freshnessWindow;
  final DateTime Function() _now;

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    final now = context.requestedAt ?? _now();

    if (recaptchaProtectedKeys.contains(context.requestedPermissionKey)) {
      final r = context.recaptchaOutcome;
      if (r == null || r == ProxyAdminGuardRecaptcha.reject) {
        return const ProxyAdminRejected(reasonCode: 'recaptcha_rejected');
      }
      if (r == ProxyAdminGuardRecaptcha.challenge) {
        return const ProxyAdminChallengeRequired();
      }
    }

    if (requiresMfaKeys.contains(context.requestedPermissionKey)) {
      if (now.difference(context.lastFreshAuthAt) > _freshnessWindow) {
        return ProxyAdminMfaStaleAuth(
          refreshAfter: context.lastFreshAuthAt.add(_freshnessWindow),
        );
      }
    }

    final key = '${context.actorUserId}|${context.requestedPermissionKey}';
    final effect = permissionEffects[key];
    if (effect == null) return const ProxyAdminDeniedDefault();
    if (effect == PermissionEffect.deny) {
      return const ProxyAdminDeniedExplicit(matchedRoleId: 'in-memory-fake');
    }
    return const ProxyAdminAllowed();
  }
}
