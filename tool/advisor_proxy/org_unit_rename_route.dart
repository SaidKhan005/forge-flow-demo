// GAP A1 — org-unit RENAME route (operator self-service + F&F admin).
//
// Authority: merged PR #833 deferred section + the parity contract
// `docs/contracts/team_roles_hierarchy_console_parity_contract.md`
// § Hierarchy "Rename semantics (GAP A1)".
//
// Route shape
// -----------
//   PATCH /v1/auth/team/org-units/:id/name        (operator self-service)
//   PATCH /v1/admin/auth/org-units/:id/name        (F&F admin)
//
// Both canonicalize to the same admin-prefixed suffix in the proxy
// dispatcher; the RAW request path tells them apart. The corp root IS
// renameable (it is the operator-facing Business label) behind the
// same `team.roles.assign` write key as create/move. Rename changes
// ONLY the `org_units.name` display column — no ltree path touch, so
// there is no descendant rewrite.
//
// Body:
//   { "name": "<required>", "admin_reason": "<required on admin path>" }
//
// `admin_reason` is forbidden-by-omission on self-service (the gateway
// receives null and the audit row lands `actor_kind=team_member`),
// REQUIRED on the F&F admin path (rejected with 400 before any write so
// the `actor_kind=forge_admin` row always carries a reason per the
// parity contract § Audit-row shape).
//
// Why a sibling file (not the monolith)
// -------------------------------------
// `tool/advisor_proxy/advisor_proxy.dart` sits at the
// `kAdvisorProxyMaxLines` bleed-stop ceiling (CLAUDE.md "R-2 ceiling-
// raise rule"; raising it needs explicit operator approval). This file
// keeps the rename validation + gateway dispatch entirely outside the
// monolith; the dispatcher hooks one thin if-block that resolves scope,
// checks the `team.roles.assign` gate, reads the Idempotency-Key, and
// hands the parsed body to [OrgUnitRenameRouter.handleRequest].

import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

import 'proxy_idempotency_cache.dart'
    show CachedProxyResponse, ProxyAuthIdempotencyCache;

/// Validates + dispatches an org-unit rename. Pure of `dart:io`; the
/// monolith owns the socket, scope resolution, permission gate, and
/// idempotency cache.
class OrgUnitRenameRouter {
  const OrgUnitRenameRouter({
    required this.authOperationsGateway,
    required this.orgUnitToJson,
  });

  final AuthOperationsGateway authOperationsGateway;

  /// Mirrors the monolith's `_teamOrgUnitToJson` so the wire shape
  /// stays identical to the `/parent` move route's `org_unit` envelope.
  final Map<String, Object?> Function(TeamOrgUnitEntry entry) orgUnitToJson;

  /// Extract the org-unit id from a canonicalized
  /// `<adminOrgUnitPrefix>:id/name` rename path. Mirrors the monolith's
  /// `_orgUnitIdFromParentPath` exactly (the `/parent` move route),
  /// swapping the trailing segment. Returns null on any shape mismatch.
  static String? orgUnitIdFromNamePath(String path, String adminOrgUnitPrefix) {
    if (!path.startsWith(adminOrgUnitPrefix)) return null;
    final rest = path.substring(adminOrgUnitPrefix.length);
    final parts = rest.split('/');
    if (parts.length != 2 || parts[0].isEmpty || parts[1] != 'name') {
      return null;
    }
    return Uri.decodeComponent(parts[0]);
  }

  /// Idempotent dispatch. [targetOrgUnitId] is parsed from the
  /// canonical path by the caller. [isSelfService] is true iff the RAW
  /// request path was the `/v1/auth/team/...` self-service form
  /// (admin_reason forbidden); false for the `/v1/admin/auth/...` F&F
  /// admin form (admin_reason REQUIRED, rejected with 400 before any
  /// write). [scopeUserId]/[operatorId]/[locationId] come from the
  /// verified bearer-token scope (operator_id clamped on self-service).
  /// [cache] + [idempotencyKey] give the proxy_requests UNIQUE replay
  /// (a re-submit returns the original 2xx; no second mutation).
  Future<CachedProxyResponse> dispatch({
    required String? targetOrgUnitId,
    required bool isSelfService,
    required String scopeUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
    required String? Function(Object? raw) nonBlankString,
    required ProxyAuthIdempotencyCache cache,
    required String idempotencyKey,
    required String route,
  }) {
    return cache.runOrReplay(
      route: route,
      key: idempotencyKey,
      compute: () async {
        final name = nonBlankString(body['name']);
        final adminReason = nonBlankString(body['admin_reason']) ??
            nonBlankString(body['adminReason']);
        if (targetOrgUnitId == null || name == null) {
          return CachedProxyResponse(statusCode: 400, body: <String, Object?>{
            'error': 'missing_org_unit_rename_fields',
            'message': 'org unit id in path and name body are required',
          });
        }
        if (!isSelfService && adminReason == null) {
          return CachedProxyResponse(statusCode: 400, body: <String, Object?>{
            'error': 'missing_org_unit_rename_fields',
            'message': 'admin_reason is required on the admin rename path',
          });
        }
        try {
          final renamed = await authOperationsGateway.renameOrgUnit(
            TeamOrgUnitRenameCommand(
              actorUserId: scopeUserId,
              operatorId: operatorId,
              locationId: locationId,
              orgUnitId: targetOrgUnitId,
              name: name,
              adminReason: isSelfService ? null : adminReason,
            ),
          );
          return CachedProxyResponse(statusCode: 200, body: <String, Object?>{
            'ok': true,
            'org_unit': orgUnitToJson(renamed.orgUnit),
          });
        } on AuthOperationRejected catch (rejected) {
          return CachedProxyResponse(
              statusCode: rejected.statusCode,
              body: <String, Object?>{
                'error': rejected.code,
                'message': rejected.message,
              });
        }
      },
    );
  }
}
