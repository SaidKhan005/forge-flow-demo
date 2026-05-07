// Mobile core business scope proxy routes.
//
// Canonical route:
//   GET /v1/users/:user_id/business_scopes
//
// Compatibility route for the earlier Doc 1 dispatch wording:
//   GET /v1/operators/:operator_id/business_scopes

const String businessScopesUsersPrefix = '/v1/users/';
const String businessScopesOperatorsPrefix = '/v1/operators/';
const String businessScopesResource = 'business_scopes';

class BusinessScopeRouter {
  const BusinessScopeRouter({required BusinessScopeProxyGateway gateway})
    : _gateway = gateway;

  final BusinessScopeProxyGateway _gateway;

  static BusinessScopeRouteMatch? match(String path, String method) {
    if (method != 'GET') return null;
    if (path.startsWith(businessScopesUsersPrefix)) {
      final tail = path.substring(businessScopesUsersPrefix.length);
      final parts = tail.split('/');
      if (parts.length == 2 && parts[1] == businessScopesResource) {
        return BusinessScopeRouteMatch(userId: Uri.decodeComponent(parts[0]));
      }
    }
    if (path.startsWith(businessScopesOperatorsPrefix)) {
      final tail = path.substring(businessScopesOperatorsPrefix.length);
      final parts = tail.split('/');
      if (parts.length == 2 && parts[1] == businessScopesResource) {
        return BusinessScopeRouteMatch(
          operatorId: Uri.decodeComponent(parts[0]),
        );
      }
    }
    return null;
  }

  Future<BusinessScopeRouteResult> handle({
    required BusinessScopeRouteMatch match,
    required String actorUserId,
    required List<String> actorRoles,
    required String? actorOperatorId,
    required String? actorLocationId,
  }) async {
    final pathUserId = match.userId;
    if (pathUserId != null && pathUserId != actorUserId) {
      return const BusinessScopeRouteResult(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'permission_denied',
          'message': 'requested user does not match caller',
        },
      );
    }
    final pathOperatorId = match.operatorId;
    final actorHasGlobalRead = _hasGlobalBusinessScopeReadRole(actorRoles);
    if (pathUserId != null && actorHasGlobalRead) {
      final rows = await _gateway.listAllLocationScopesForAdmin(
        adminUserId: actorUserId,
      );
      return BusinessScopeRouteResult(
        statusCode: 200,
        body: <String, Object?>{
          'user_id': actorUserId,
          'scopes': <Map<String, Object?>>[
            for (final row in rows) row.toJson(),
          ],
        },
      );
    }

    final scopedOperatorId = _nonBlank(actorOperatorId);
    final scopedLocationId = _nonBlank(actorLocationId);
    if (scopedOperatorId == null || scopedLocationId == null) {
      return const BusinessScopeRouteResult(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'permission_denied',
          'message': 'verified token is missing operator or location scope',
        },
      );
    }
    if (pathOperatorId != null && pathOperatorId != scopedOperatorId) {
      return const BusinessScopeRouteResult(
        statusCode: 403,
        body: <String, Object?>{
          'error': 'permission_denied',
          'message': 'requested operator does not match caller scope',
        },
      );
    }
    final rows = await _gateway.listAccessibleScopes(
      userId: actorUserId,
      operatorId: scopedOperatorId,
      locationId: scopedLocationId,
    );
    return BusinessScopeRouteResult(
      statusCode: 200,
      body: <String, Object?>{
        'user_id': actorUserId,
        'operator_id': scopedOperatorId,
        'scopes': <Map<String, Object?>>[for (final row in rows) row.toJson()],
      },
    );
  }
}

abstract class BusinessScopeProxyGateway {
  Future<List<BusinessScopeProxyRow>> listAccessibleScopes({
    required String userId,
    required String operatorId,
    required String locationId,
  });

  Future<List<BusinessScopeProxyRow>> listAllLocationScopesForAdmin({
    required String adminUserId,
  });

  Future<bool> canAccessLocation({
    required String userId,
    required String operatorId,
    required String locationId,
  });
}

class BusinessScopeRouteMatch {
  const BusinessScopeRouteMatch({this.userId, this.operatorId});

  final String? userId;
  final String? operatorId;
}

class BusinessScopeRouteResult {
  const BusinessScopeRouteResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

class BusinessScopeProxyRow {
  const BusinessScopeProxyRow({
    required this.scopeId,
    required this.scopeType,
    required this.operatorId,
    required this.label,
    this.locationId,
    this.parentScopeId,
    this.businessTimezone,
    this.sortPath,
  });

  final String scopeId;
  final String scopeType;
  final String operatorId;
  final String? locationId;
  final String? parentScopeId;
  final String label;
  final String? businessTimezone;
  final String? sortPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'scope_id': scopeId,
    'scope_type': scopeType,
    'operator_id': operatorId,
    'location_id': locationId,
    'parent_scope_id': parentScopeId,
    'label': label,
    'business_timezone': businessTimezone,
    'sort_path': sortPath,
  };
}

bool _hasGlobalBusinessScopeReadRole(List<String> roles) {
  return roles.contains('super_admin') || roles.contains('ff_support');
}

String? _nonBlank(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
