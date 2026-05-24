// Forge & Flow advisor proxy — admin routing helpers (part of advisor_proxy.dart).
//
// chore(advisor-proxy): pure size refactor. This part file holds admin
// path-predicate helpers, CORS method constants, and admin route handler
// functions (_routeIntegrationsAdmin, _routeDataAccuracyAdmin,
// _routeVendorApplicabilityAdmin, _routePricingAdmin), mechanically
// lifted out of `advisor_proxy.dart` so the monolith stays under the
// `kAdvisorProxyMaxLines` bleed-stop ceiling enforced by
// `tool/advisor_proxy_size_lint.dart`. It is a Dart `part` of the
// `advisor_proxy.dart` library: it shares that library's imports and
// private scope verbatim, so the move is behavior byte-identical —
// routing, request/response shapes, status codes, error handling,
// idempotency, RLS, auth, and SQL are all unchanged. No symbol was
// renamed; every helper reference resolves through the shared library
// scope exactly as before.

part of 'advisor_proxy.dart';
void _writeNotFound(HttpResponse response, HttpRequest request) {
  _writeJson(response, 404, <String, Object?>{
    'error': 'not found',
    'method': request.method,
    'path': request.uri.path,
  });
}

bool _callerHasAnyRole(ProxyJwtClaims actor, Set<String> allowed) {
  return actor.roles.any(allowed.contains);
}

bool _isAdminPricingPath(String path) {
  if (path == adminPricingOperatorsPath ||
      path.startsWith(adminPricingOperatorsPrefix)) {
    return true;
  }
  if (path == adminPricingUsageCapsPath) return true;
  return false;
}

bool _isAdminDataAccuracyPath(String path) {
  if (path == adminDataAccuracyRowsPath) return true;
  if (path == adminDataAccuracyAuditHistoryPath) return true;
  if (path.startsWith(adminDataAccuracySettingsPrefix)) return true;
  if (path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix)) {
    return true;
  }
  if (path == adminDataAccuracyScopedSettingsPath) return true;
  if (path == adminPollingPricingTierDefinitionsPath ||
      path.startsWith(adminPollingPricingTierDefinitionsPrefix)) {
    return true;
  }
  if (path == adminPollingPricingAssignmentsPath ||
      path.startsWith(adminPollingPricingAssignmentsPrefix)) {
    return true;
  }
  if (path == adminPollingPricingScopedAssignmentsPath) return true;
  if (path == adminPollingPricingMarginPath ||
      path == adminPollingPricingMarginExportPath) {
    return true;
  }
  if (path == adminPollingPricingChangeRequestsPath ||
      path.startsWith(adminPollingPricingChangeRequestsPrefix)) {
    return true;
  }
  return false;
}

bool _isAdminVendorApplicabilityPath(String path) {
  return path == adminVendorApplicabilityPath;
}

bool _isAdminIntegrationsPath(String path) {
  return path == adminIntegrationsListPath ||
      path == adminIntegrationsRotateAnthropicPath ||
      path == adminIntegrationsRotateVoyagePath ||
      path == adminIntegrationsRotateAzureDbPath ||
      path == adminIntegrationsRotateGeminiPath ||
      path == adminIntegrationsRotateSendgridPath ||
      path == adminIntegrationsStatusPath;
}

bool _isAuthCorsPath(String path) {
  return path.startsWith('/v1/auth/') ||
      path.startsWith('/v1/operator/') ||
      path.startsWith('/v1/operators/') ||
      path.startsWith('/v1/admin/auth/') ||
      BusinessScopeRouter.match(path, 'GET') != null ||
      AuditChainAnchorsRouter.match(path, 'GET') != null;
}

bool _isAdminIntegrationsOperation(String path, String method) {
  if (method == 'GET' &&
      (path == adminIntegrationsListPath ||
          path == adminIntegrationsStatusPath)) {
    return true;
  }
  if (method == 'POST' &&
      (path == adminIntegrationsRotateAnthropicPath ||
          path == adminIntegrationsRotateVoyagePath ||
          path == adminIntegrationsRotateAzureDbPath ||
          path == adminIntegrationsRotateGeminiPath ||
          path == adminIntegrationsRotateSendgridPath)) {
    return true;
  }
  return false;
}

Future<void> _routeIntegrationsAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required IntegrationAdminProxyGateway gateway,
  required String actorUserId,
  required String actorLogId,
  required Map<String, Object?> body,
  String idempotencyKey = '',
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  // [actorLogId] is the original verified Firebase UID (the value the
  // resolver looked up). It is embedded in the admin reason string
  // alongside the resolved Postgres user UUID so the audit trail
  // captures both identifiers without relying on a join.
  final reasonPrefix = 'admin.integrations.$method:$actorLogId';

  if (method == 'GET' && path == adminIntegrationsListPath) {
    final params = request.uri.queryParameters;
    final bundle = await gateway.listBundle(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
      operatorId: _nonBlankString(params['operator_id']),
      locationId: _nonBlankString(params['location_id']),
      locationIds: _commaSeparatedQueryList(params['location_ids']),
    );
    _writeJson(response, 200, bundle);
    return;
  }

  if (method == 'GET' && path == adminIntegrationsStatusPath) {
    final params = request.uri.queryParameters;
    final bundle = await gateway.listBundle(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:status',
      operatorId: _nonBlankString(params['operator_id']),
      locationId: _nonBlankString(params['location_id']),
      locationIds: _commaSeparatedQueryList(params['location_ids']),
    );
    _writeJson(response, 200, <String, Object?>{
      'vendor_connectors': bundle['vendor_connectors'],
      'fx_rate_source': bundle['fx_rate_source'],
      'email_provider': bundle['email_provider'],
    });
    return;
  }

  if (method == 'POST') {
    final keyKind = _integrationKeyKindForRoute(path);
    if (keyKind == null) {
      _writeNotFound(response, request);
      return;
    }
    final plaintext = _requireBodyString(body, 'plaintext_value');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.integrations.rotate_$keyKind',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.rotateProviderKey(
          actorUserId: actorUserId,
          keyKind: keyKind,
          plaintextValue: plaintext,
          adminReason: '$reasonPrefix:rotate:$keyKind',
        );
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

String? _integrationKeyKindForRoute(String path) {
  if (path == adminIntegrationsRotateAnthropicPath) return 'anthropic';
  if (path == adminIntegrationsRotateVoyagePath) return 'voyage';
  if (path == adminIntegrationsRotateAzureDbPath) return 'azure_db';
  if (path == adminIntegrationsRotateGeminiPath) return 'gemini';
  if (path == adminIntegrationsRotateSendgridPath) return 'sendgrid';
  return null;
}

bool _isAdminPricingOperation(String path, String method) {
  if (method == 'GET' && path == adminPricingOperatorsPath) return true;
  if (method == 'PATCH' && path.startsWith(adminPricingOperatorsPrefix)) {
    return true;
  }
  if (method == 'POST' && path.startsWith(adminPricingOperatorsPrefix)) {
    // /apply-template suffix
    return true;
  }
  if (method == 'PUT' && path == adminPricingUsageCapsPath) return true;
  return false;
}

bool _isAdminDataAccuracyOperation(String path, String method) {
  if (method == 'GET' &&
      (path == adminDataAccuracyRowsPath ||
          path == adminDataAccuracyAuditHistoryPath ||
          path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix) ||
          path == adminPollingPricingTierDefinitionsPath ||
          path == adminPollingPricingAssignmentsPath ||
          path == adminPollingPricingMarginPath ||
          path == adminPollingPricingChangeRequestsPath)) {
    return true;
  }
  if (method == 'PATCH' &&
      (path.startsWith(adminDataAccuracySettingsPrefix) ||
          path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix) ||
          path.startsWith(adminPollingPricingTierDefinitionsPrefix) ||
          path.startsWith(adminPollingPricingChangeRequestsPrefix))) {
    return true;
  }
  if (method == 'PUT' &&
      path.startsWith(adminPollingPricingAssignmentsPrefix)) {
    return true;
  }
  if (method == 'PUT' &&
      (path == adminDataAccuracyScopedSettingsPath ||
          path == adminPollingPricingScopedAssignmentsPath)) {
    return true;
  }
  if (method == 'POST' && path == adminPollingPricingMarginExportPath) {
    return true;
  }
  return false;
}

bool _isAdminVendorApplicabilityOperation(String path, String method) {
  return path == adminVendorApplicabilityPath &&
      (method == 'GET' || method == 'POST' || method == 'PATCH');
}

Future<void> _routeDataAccuracyAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required DataAccuracyAdminProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
  String idempotencyKey = '',
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.data_accuracy.$method:$actorUserId';
  final params = request.uri.queryParameters;

  if (method == 'GET' && path == adminDataAccuracyRowsPath) {
    final rows = await gateway.listDataAccuracyRows(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:rows',
    );
    _writeJson(response, 200, <String, Object?>{'rows': rows});
    return;
  }

  if (method == 'GET' && path == adminDataAccuracyAuditHistoryPath) {
    final events = await gateway.listAuditHistory(
      actorUserId: actorUserId,
      operatorId: _nonBlankString(params['operator_id']),
      locationId: _nonBlankString(params['location_id']),
      adminReason: '$reasonPrefix:audit_history',
    );
    _writeJson(response, 200, <String, Object?>{'events': events});
    return;
  }

  if (method == 'GET' &&
      path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix)) {
    final pair = _pathPairSuffix(
      path,
      adminDataAccuracyServicePeriodSettingsPrefix,
    );
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final rows = await gateway.listDataAccuracyServicePeriodRows(
      actorUserId: actorUserId,
      operatorId: pair.operatorId,
      locationId: pair.locationId,
      adminReason:
          '$reasonPrefix:service_period_settings:${pair.operatorId}:${pair.locationId}',
    );
    _writeJson(response, 200, <String, Object?>{
      'data_accuracy_service_period_settings': rows,
    });
    return;
  }

  if (method == 'PATCH' &&
      path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix)) {
    final pair = _pathPairSuffix(
      path,
      adminDataAccuracyServicePeriodSettingsPrefix,
    );
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final servicePeriodKey = _requireBodyString(body, 'service_period_key');
    final clearServicePeriod = _optionalBodyBool(body, 'clear');
    if (clearServicePeriod) {
      final reasonNote = _requireBodyString(body, 'reason_note');
      await _runAdminIdempotent(
        response: response,
        store: idempotencyStore,
        idempotencyKey: idempotencyKey,
        requestType: 'admin.data_accuracy.service_period_clear',
        actorUserId: actorUserId,
        requestBody: body,
        compute: () async {
          final result = await gateway.clearDataAccuracyServicePeriod(
            actorUserId: actorUserId,
            operatorId: pair.operatorId,
            locationId: pair.locationId,
            servicePeriodKey: servicePeriodKey,
            reasonNote: reasonNote,
            adminReason:
                '$reasonPrefix:service_period_clear:${pair.operatorId}:${pair.locationId}:$servicePeriodKey',
          );
          return (statusCode: 200, payload: result);
        },
      );
      return;
    }
    final coversSource = _requireBodyString(body, 'covers_source');
    final wageSource = _requireBodyString(body, 'wage_source');
    final effectiveAtBusinessDate = _requireBodyString(
      body,
      'effective_at_business_date',
    );
    final reasonNote = _requireBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.data_accuracy.service_period_override',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.overrideDataAccuracyServicePeriod(
          actorUserId: actorUserId,
          operatorId: pair.operatorId,
          locationId: pair.locationId,
          servicePeriodKey: servicePeriodKey,
          coversSource: coversSource,
          wageSource: wageSource,
          effectiveAtBusinessDate: effectiveAtBusinessDate,
          reasonNote: reasonNote,
          adminReason:
              '$reasonPrefix:service_period_settings:${pair.operatorId}:${pair.locationId}:$servicePeriodKey',
        );
        return (statusCode: 200, payload: <String, Object?>{'data': row});
      },
    );
    return;
  }

  if (method == 'PATCH' && path.startsWith(adminDataAccuracySettingsPrefix)) {
    final pair = _pathPairSuffix(path, adminDataAccuracySettingsPrefix);
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    if (_rejectLegacyCoversSourceWriteKeys(response, body)) return;
    final coversPerServicePeriod = _optionalBodyStringMap(
      body,
      'covers_source_per_service_period',
    );
    final wageSource = _optionalBodyString(body, 'wage_source');
    final walkInHandlingMode = _optionalBodyString(
      body,
      'walk_in_handling_mode',
    );
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.data_accuracy.override',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.overrideDataAccuracy(
          actorUserId: actorUserId,
          operatorId: pair.operatorId,
          locationId: pair.locationId,
          coversSourcePerServicePeriod: coversPerServicePeriod,
          wageSource: wageSource,
          walkInHandlingMode: walkInHandlingMode,
          reasonNote: reasonNote,
          adminReason:
              '$reasonPrefix:settings:${pair.operatorId}:${pair.locationId}',
        );
        if (row == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator_location',
              'message': 'operator/location pair not found',
            },
          );
        }
        return (statusCode: 200, payload: <String, Object?>{'row': row});
      },
    );
    return;
  }

  if (method == 'PUT' && path == adminDataAccuracyScopedSettingsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final scopeType = _requireBodyString(body, 'scope_type');
    final orgUnitId = _optionalBodyString(body, 'org_unit_id');
    final locationId = _optionalBodyString(body, 'location_id');
    if (_rejectLegacyCoversSourceWriteKeys(response, body)) return;
    final coversPerServicePeriod = _optionalBodyStringMap(
      body,
      'covers_source_per_service_period',
    );
    final clearCoversPerServicePeriod = _optionalBodyStringList(
      body,
      'clear_covers_source_per_service_period',
    );
    final clearWageSource = _optionalBodyBool(body, 'clear_wage_source');
    final clearWalkInHandlingMode = _optionalBodyBool(
      body,
      'clear_walk_in_handling_mode',
    );
    final wageSource = _optionalBodyString(body, 'wage_source');
    final walkInHandlingMode = _optionalBodyString(
      body,
      'walk_in_handling_mode',
    );
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.data_accuracy.scope_override',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.overrideDataAccuracyScope(
          actorUserId: actorUserId,
          operatorId: operatorId,
          scopeType: scopeType,
          orgUnitId: orgUnitId,
          locationId: locationId,
          coversSourcePerServicePeriod: coversPerServicePeriod,
          clearCoversSourcePerServicePeriod: clearCoversPerServicePeriod,
          clearWageSource: clearWageSource,
          clearWalkInHandlingMode: clearWalkInHandlingMode,
          wageSource: wageSource,
          walkInHandlingMode: walkInHandlingMode,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:scoped_settings:$operatorId:$scopeType',
        );
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingTierDefinitionsPath) {
    final definitions = await gateway.listTierDefinitions(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:tier_definitions',
    );
    _writeJson(response, 200, <String, Object?>{'definitions': definitions});
    return;
  }

  if (method == 'PATCH' &&
      path.startsWith(adminPollingPricingTierDefinitionsPrefix)) {
    final tierKey = _pathSuffix(path, adminPollingPricingTierDefinitionsPrefix);
    if (tierKey == null) {
      _writeNotFound(response, request);
      return;
    }
    final cadence = _optionalBodyPositiveIntMap(
      body,
      'polling_cadence_per_vendor_seconds',
    );
    final descriptionMd = _optionalBodyString(body, 'description_md');
    final price = _optionalBodyNonNegativeInt(
      body,
      'default_monthly_price_cents',
    );
    final cost = _optionalBodyNonNegativeInt(
      body,
      'vendor_api_cost_estimate_cents_monthly',
    );
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.update_tier_definition',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final definition = await gateway.updateTierDefinition(
          actorUserId: actorUserId,
          tierKey: tierKey,
          descriptionMd: descriptionMd,
          pollingCadencePerVendorSeconds: cadence,
          defaultMonthlyPriceCents: price,
          vendorApiCostEstimateCentsMonthly: cost,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:tier_definition:$tierKey',
        );
        return (
          statusCode: 200,
          payload: <String, Object?>{'definition': definition},
        );
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingAssignmentsPath) {
    final assignments = await gateway.listTierAssignments(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:tier_assignments',
    );
    _writeJson(response, 200, <String, Object?>{'assignments': assignments});
    return;
  }

  if (method == 'PUT' &&
      path.startsWith(adminPollingPricingAssignmentsPrefix)) {
    final pair = _pathPairSuffix(path, adminPollingPricingAssignmentsPrefix);
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final tierKey = _requireBodyString(body, 'tier_key');
    final cadence = _optionalBodyPositiveIntMap(
      body,
      'custom_cadence_per_vendor_seconds',
    );
    final price = _optionalBodyNonNegativeInt(
      body,
      'monthly_price_cents_override',
    );
    final cost = _optionalBodyNonNegativeInt(
      body,
      'vendor_api_cost_estimate_cents_monthly_override',
    );
    final adminNotes = _optionalBodyString(body, 'admin_notes');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.assign_tier',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final assignment = await gateway.assignTier(
          actorUserId: actorUserId,
          operatorId: pair.operatorId,
          locationId: pair.locationId,
          tierKey: tierKey,
          customCadencePerVendorSeconds: cadence,
          monthlyPriceCentsOverride: price,
          vendorApiCostEstimateCentsMonthlyOverride: cost,
          adminNotes: adminNotes,
          reasonNote: reasonNote,
          adminReason:
              '$reasonPrefix:assignment:${pair.operatorId}:${pair.locationId}',
        );
        if (assignment == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator_location',
              'message': 'operator/location pair not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'assignment': assignment},
        );
      },
    );
    return;
  }

  if (method == 'PUT' && path == adminPollingPricingScopedAssignmentsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final scopeType = _requireBodyString(body, 'scope_type');
    final orgUnitId = _optionalBodyString(body, 'org_unit_id');
    final locationId = _optionalBodyString(body, 'location_id');
    final tierKey = _requireBodyString(body, 'tier_key');
    final cadence = _optionalBodyPositiveIntMap(
      body,
      'custom_cadence_per_vendor_seconds',
    );
    final price = _optionalBodyNonNegativeInt(
      body,
      'monthly_price_cents_override',
    );
    final cost = _optionalBodyNonNegativeInt(
      body,
      'vendor_api_cost_estimate_cents_monthly_override',
    );
    final adminNotes = _optionalBodyString(body, 'admin_notes');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.scope_assign_tier',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.assignTierScope(
          actorUserId: actorUserId,
          operatorId: operatorId,
          scopeType: scopeType,
          orgUnitId: orgUnitId,
          locationId: locationId,
          tierKey: tierKey,
          customCadencePerVendorSeconds: cadence,
          monthlyPriceCentsOverride: price,
          vendorApiCostEstimateCentsMonthlyOverride: cost,
          adminNotes: adminNotes,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:scope_assignment:$operatorId:$scopeType',
        );
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingMarginPath) {
    final rollup = await gateway.summarizeMargin(
      actorUserId: actorUserId,
      tierKey: _nonBlankString(params['tier_key']),
      adminReason: '$reasonPrefix:margin',
    );
    _writeJson(response, 200, <String, Object?>{'rollup': rollup});
    return;
  }

  if (method == 'POST' && path == adminPollingPricingMarginExportPath) {
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.export_margin_csv',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final csv = await gateway.exportMarginRollupCsv(
          actorUserId: actorUserId,
          adminReason: '$reasonPrefix:margin_export_csv',
        );
        return (statusCode: 200, payload: <String, Object?>{'csv': csv});
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingChangeRequestsPath) {
    final requests = await gateway.listTierChangeRequests(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:change_requests',
    );
    _writeJson(response, 200, <String, Object?>{'requests': requests});
    return;
  }

  if (method == 'PATCH' &&
      path.startsWith(adminPollingPricingChangeRequestsPrefix)) {
    final requestId = _pathSuffix(
      path,
      adminPollingPricingChangeRequestsPrefix,
    );
    if (requestId == null) {
      _writeNotFound(response, request);
      return;
    }
    final status = _requireBodyString(body, 'status');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.resolve_change_request',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final resolved = await gateway.resolveTierChangeRequest(
          actorUserId: actorUserId,
          requestId: requestId,
          status: status,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:change_request:$requestId',
        );
        if (resolved == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_change_request',
              'message': 'tier change request not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'request': resolved},
        );
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

Future<void> _routeVendorApplicabilityAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required VendorApplicabilityProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
  required String idempotencyKey,
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  if (path != adminVendorApplicabilityPath) {
    _writeNotFound(response, request);
    return;
  }
  final method = request.method;
  final reasonPrefix = 'admin.vendor_applicability.$method:$actorUserId';
  final params = request.uri.queryParameters;

  if (method == 'GET') {
    final rows = await gateway.listAdmin(
      actorUserId: actorUserId,
      operatorId: _nonBlankString(params['operator_id']),
      settingKind: _nonBlankString(params['setting_kind']),
      settingKey: _nonBlankString(params['setting_key']),
      vendorSlug: _nonBlankString(params['vendor_slug']),
      currentOnly: _optionalQueryBool(
        params['current_only'],
        defaultValue: true,
      ),
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'rows': rows});
    return;
  }

  if (method == 'POST') {
    final settingKind = _requireBodyString(body, 'setting_kind');
    final settingKey = _requireBodyString(body, 'setting_key');
    final vendorSlug = _requireBodyString(body, 'vendor_slug');
    final enabled = _requireBodyBool(body, 'enabled');
    final metadata = _optionalBodyObject(body, 'metadata');
    final operatorId = _optionalBodyString(body, 'operator_id');
    final effectiveFrom = _optionalBodyDateTime(body, 'effective_from');
    final adminReason = _requireBodyString(body, 'admin_reason');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.vendor_applicability.upsert',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.upsert(
          actorUserId: actorUserId,
          operatorId: operatorId,
          settingKind: settingKind,
          settingKey: settingKey,
          vendorSlug: vendorSlug,
          enabled: enabled,
          metadata: metadata,
          effectiveFrom: effectiveFrom,
          reasonNote: reasonNote,
          adminReason: adminReason,
        );
        return (statusCode: 200, payload: <String, Object?>{'row': row});
      },
    );
    return;
  }

  if (method == 'PATCH') {
    final action = _optionalBodyString(body, 'action') ?? 'end';
    if (action != 'end') {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'invalid_action',
        message: 'PATCH action must be "end"',
      );
    }
    final settingKind = _requireBodyString(body, 'setting_kind');
    final settingKey = _requireBodyString(body, 'setting_key');
    final vendorSlug = _requireBodyString(body, 'vendor_slug');
    final operatorId = _optionalBodyString(body, 'operator_id');
    final effectiveUntil = _optionalBodyDateTime(body, 'effective_until');
    final adminReason = _requireBodyString(body, 'admin_reason');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.vendor_applicability.end',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.end(
          actorUserId: actorUserId,
          operatorId: operatorId,
          settingKind: settingKind,
          settingKey: settingKey,
          vendorSlug: vendorSlug,
          effectiveUntil: effectiveUntil,
          reasonNote: reasonNote,
          adminReason: adminReason,
        );
        if (row == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_vendor_applicability',
              'message': 'current vendor applicability row not found',
            },
          );
        }
        return (statusCode: 200, payload: <String, Object?>{'row': row});
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

Future<void> _routePricingAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required PricingTierAdminProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
  String idempotencyKey = '',
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.pricing.$method:$actorUserId';

  if (method == 'GET' && path == adminPricingOperatorsPath) {
    final operators = await gateway.listOperatorsWithCaps(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'operators': operators});
    return;
  }

  if (method == 'PATCH' && path.startsWith(adminPricingOperatorsPrefix)) {
    final tail = _pathSuffix(path, adminPricingOperatorsPrefix);
    if (tail == null || tail.contains('/')) {
      _writeNotFound(response, request);
      return;
    }
    final operatorId = tail;
    final subscriptionTier = _requireBodyString(body, 'subscription_tier');
    if (!kProxyPricingTierTemplateKeys.contains(subscriptionTier)) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_subscription_tier',
        message:
            'subscription_tier must be one of: '
            '${kProxyPricingTierTemplateKeys.join(', ')}',
      );
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.update_operator_tier',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final updated = await gateway.updateOperatorTier(
          actorUserId: actorUserId,
          operatorId: operatorId,
          subscriptionTier: subscriptionTier,
          adminReason: '$reasonPrefix:tier:$operatorId',
        );
        if (updated == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator',
              'message': 'operator not found',
            },
          );
        }
        return (statusCode: 200, payload: updated);
      },
    );
    return;
  }

  if (method == 'POST' && path.startsWith(adminPricingOperatorsPrefix)) {
    final tail = path.substring(adminPricingOperatorsPrefix.length);
    if (tail.isEmpty) {
      _writeNotFound(response, request);
      return;
    }
    final parts = tail.split('/');
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) {
      _writeNotFound(response, request);
      return;
    }
    final operatorId = Uri.decodeComponent(parts[0]);
    final action = Uri.decodeComponent(parts[1]);
    if (action != 'apply-template') {
      _writeNotFound(response, request);
      return;
    }
    final tierKey = _requireBodyString(body, 'tier_key');
    if (!kProxyPricingTierTemplateKeys.contains(tierKey)) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'unknown_tier_template',
        message: 'tier_key "$tierKey" is not a known pricing template',
      );
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.apply_template',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.applyTierTemplate(
          actorUserId: actorUserId,
          operatorId: operatorId,
          tierKey: tierKey,
          adminReason: '$reasonPrefix:apply_template:$operatorId:$tierKey',
        );
        if (result == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator',
              'message': 'operator not found',
            },
          );
        }
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  if (method == 'PUT' && path == adminPricingUsageCapsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final locationId = _requireBodyString(body, 'location_id');
    final usageClass = _requireBodyString(body, 'usage_class');
    final monthlyCap = _requireBodyMoney(body, 'monthly_cap_usd');
    final perInvocation = _requireBodyMoney(body, 'per_invocation_cap_usd');
    final staffId = _optionalBodyString(body, 'staff_id');
    final workflowId = _optionalBodyString(body, 'workflow_id');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.upsert_usage_cap',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final cap = await gateway.upsertUsageCap(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId,
          usageClass: usageClass,
          monthlyCapUsd: monthlyCap,
          perInvocationCapUsd: perInvocation,
          staffId: staffId,
          workflowId: workflowId,
          adminReason:
              '$reasonPrefix:usage_caps:$operatorId:$locationId:$usageClass',
        );
        return (statusCode: 200, payload: <String, Object?>{'cap': cap});
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

bool _isAdminCorpusPath(String path) {
  if (path == adminCorpusVersionsPath ||
      path.startsWith(adminCorpusVersionsPrefix)) {
    return true;
  }
  if (path == adminCorpusUploadPath) return true;
  if (path == adminCorpusPreviewDiffPath) return true;
  if (path == adminCorpusCommitPath) return true;
  if (path == adminCorpusRollbackPath) return true;
  // Phase 11A.3b â€” graph-candidate review + AGE rebuild stub share
  // the corpus admin CORS preflight (Idempotency-Key allow-listed,
  // GET/POST methods admitted) so the browser preflight succeeds
  // for the new routes too.
  if (_isGraphCandidatesPath(path)) return true;
  if (path == adminAgeRebuildPath) return true;
  return false;
}

bool _isGraphCandidatesPath(String path) =>
    path == adminCorpusGraphCandidatesPath ||
    path == adminCorpusGraphCandidatesCommitPath;

bool _isGraphCandidatesOperation(String path, String method) {
  if (method == 'GET' && path == adminCorpusGraphCandidatesPath) return true;
  if (method == 'POST' && path == adminCorpusGraphCandidatesCommitPath) {
    return true;
  }
  return false;
}

bool _isAgeRebuildOperation(String path, String method) =>
    method == 'POST' && path == adminAgeRebuildPath;

bool _isAdminCorpusOperation(String path, String method) {
  if (method == 'GET' && path == adminCorpusVersionsPath) return true;
  if (method == 'GET' && path.startsWith(adminCorpusVersionsPrefix)) {
    return true;
  }
  if (method == 'POST' && path == adminCorpusUploadPath) return true;
  if (method == 'POST' && path == adminCorpusPreviewDiffPath) return true;
  if (method == 'POST' && path == adminCorpusCommitPath) return true;
  if (method == 'POST' && path == adminCorpusRollbackPath) return true;
  return false;
}

double _requireBodyMoney(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is num) {
    final value = raw.toDouble();
    if (value < 0 || value.isNaN || value.isInfinite) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a finite number >= 0',
      );
    }
    return value;
  }
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed == null || parsed < 0 || parsed.isNaN || parsed.isInfinite) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a finite number >= 0',
      );
    }
    return parsed;
  }
  throw _AdminInputError(
    statusCode: 400,
    code: 'missing_$field',
    message: '$field is required',
  );
}
