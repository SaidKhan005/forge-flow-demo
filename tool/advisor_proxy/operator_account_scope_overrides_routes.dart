// Brand/account scope: operator org-unit account override routes.
//
// Routes:
//   GET   /v1/operator/account-overrides/org-unit/<org_unit_id>
//   PATCH /v1/operator/account-overrides/org-unit/<org_unit_id>
//
// These routes let Operator Web save account contact, currency, locale, and
// timezone at Brand/Region/District/Location group scopes. Business name and
// logo remain Business-only; location overrides keep their existing sibling
// route.

import 'operator_location_account_overrides_routes.dart'
    show
        LocationAccountOverridesFieldSet,
        LocationAccountOverridesSourcesRecord,
        ValidatedLocationAccountOverridesPatch,
        decodeLocationAccountOverridesPatchBody,
        isLocationAccountOverridesUuid;

const String operatorAccountScopeOverridesOrgUnitPathPrefix =
    '/v1/operator/account-overrides/org-unit/';

bool isOperatorAccountScopeOverridesPath(String path) {
  if (!path.startsWith(operatorAccountScopeOverridesOrgUnitPathPrefix)) {
    return false;
  }
  final suffix = path.substring(
    operatorAccountScopeOverridesOrgUnitPathPrefix.length,
  );
  if (suffix.isEmpty) return false;
  if (suffix.contains('/')) return false;
  return true;
}

String? operatorAccountScopeOverridesOrgUnitIdOf(String path) {
  if (!isOperatorAccountScopeOverridesPath(path)) return null;
  return Uri.decodeComponent(
    path.substring(operatorAccountScopeOverridesOrgUnitPathPrefix.length),
  );
}

class AccountScopeOverridesRecord {
  const AccountScopeOverridesRecord({
    required this.operatorId,
    required this.scopeType,
    required this.scopeId,
    required this.effective,
    required this.override,
    required this.businessDefault,
    this.sources = const LocationAccountOverridesSourcesRecord(),
    required this.updatedAt,
  });

  final String operatorId;
  final String scopeType;
  final String scopeId;
  final LocationAccountOverridesFieldSet effective;
  final LocationAccountOverridesFieldSet override;
  final LocationAccountOverridesFieldSet businessDefault;
  final LocationAccountOverridesSourcesRecord sources;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'operatorId': operatorId,
    'scopeType': scopeType,
    'scopeId': scopeId,
    'effective': effective.toJson(),
    'override': override.toJson(),
    'businessDefault': businessDefault.toJson(),
    'sources': sources.toJson(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class AccountScopeOverridesDecode {
  const AccountScopeOverridesDecode.success(this.patch)
    : status = 200,
      body = null;
  const AccountScopeOverridesDecode.failure({
    required this.status,
    required this.body,
  }) : patch = null;

  final int status;
  final Map<String, Object?>? body;
  final ValidatedLocationAccountOverridesPatch? patch;

  bool get ok => patch != null;
}

AccountScopeOverridesDecode decodeAccountScopeOverridesPatchBody(
  Map<String, Object?> body,
) {
  if (body.containsKey('businessDayRolloverHour')) {
    return const AccountScopeOverridesDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'unsupported_account_scope_field',
        'message':
            'businessDayRolloverHour is edited in Business Timing, not Account.',
      },
    );
  }
  const allowed = <String>{
    'ianaTimezone',
    'localeCode',
    'currencyCode',
    'contactEmail',
    'contactPhone',
  };
  for (final key in body.keys) {
    if (allowed.contains(key)) continue;
    return AccountScopeOverridesDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'unsupported_account_scope_field',
        'message': '$key is not editable at a hierarchy account scope.',
        'field': key,
      },
    );
  }
  final decoded = decodeLocationAccountOverridesPatchBody(body);
  if (!decoded.ok) {
    final failureBody = decoded.body ?? const <String, Object?>{};
    if (failureBody['error'] == 'no_fields_to_update') {
      return const AccountScopeOverridesDecode.failure(
        status: 400,
        body: <String, Object?>{
          'error': 'no_fields_to_update',
          'message':
              'request body must include at least one editable field '
              '(ianaTimezone, localeCode, currencyCode, contactEmail, contactPhone).',
        },
      );
    }
    return AccountScopeOverridesDecode.failure(
      status: decoded.status,
      body: failureBody,
    );
  }
  return AccountScopeOverridesDecode.success(decoded.patch!);
}

enum AccountScopeOverridesOutcomeKind { ok, scopeNotFound }

class AccountScopeOverridesOutcome {
  const AccountScopeOverridesOutcome.ok(this.record)
    : kind = AccountScopeOverridesOutcomeKind.ok;
  const AccountScopeOverridesOutcome.scopeNotFound()
    : kind = AccountScopeOverridesOutcomeKind.scopeNotFound,
      record = null;

  final AccountScopeOverridesOutcomeKind kind;
  final AccountScopeOverridesRecord? record;
}

abstract class AccountScopeOverridesWriteGateway {
  Future<AccountScopeOverridesOutcome> loadOverrides({
    required String operatorId,
    required String actorUserId,
    required String orgUnitId,
    required String adminReason,
  });

  Future<AccountScopeOverridesOutcome> patchOverrides({
    required String operatorId,
    required String actorUserId,
    required String orgUnitId,
    required ValidatedLocationAccountOverridesPatch patch,
    required String adminReason,
  });
}

class OperatorAccountScopeOverridesHandler {
  OperatorAccountScopeOverridesHandler({
    required AccountScopeOverridesWriteGateway gateway,
  }) : _gateway = gateway;

  final AccountScopeOverridesWriteGateway _gateway;

  Future<({int statusCode, Map<String, Object?> body})> handleGet({
    required String operatorId,
    required String actorUserId,
    required String orgUnitId,
  }) async {
    if (!isLocationAccountOverridesUuid(orgUnitId)) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'invalid_org_unit_id',
          'message': 'org_unit_id path segment must be a lowercase UUID.',
        },
      );
    }
    final adminReason = 'operator.account_scope_overrides.load:$actorUserId';
    try {
      final outcome = await _gateway.loadOverrides(
        operatorId: operatorId,
        actorUserId: actorUserId,
        orgUnitId: orgUnitId,
        adminReason: adminReason,
      );
      return _writeOutcome(outcome);
    } on Exception catch (error) {
      return (
        statusCode: 503,
        body: <String, Object?>{
          'error': 'operator_account_scope_overrides_unavailable',
          'message':
              'hierarchy account overrides are unavailable; please retry.',
          'detail': error.toString(),
        },
      );
    }
  }

  Future<({int statusCode, Map<String, Object?> body})> handlePatch({
    required String operatorId,
    required String actorUserId,
    required String orgUnitId,
    required Map<String, Object?> body,
  }) async {
    if (!isLocationAccountOverridesUuid(orgUnitId)) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'invalid_org_unit_id',
          'message': 'org_unit_id path segment must be a lowercase UUID.',
        },
      );
    }
    final decode = decodeAccountScopeOverridesPatchBody(body);
    if (!decode.ok) {
      return (statusCode: decode.status, body: decode.body!);
    }
    final adminReason = 'operator.account_scope_overrides.patch:$actorUserId';
    try {
      final outcome = await _gateway.patchOverrides(
        operatorId: operatorId,
        actorUserId: actorUserId,
        orgUnitId: orgUnitId,
        patch: decode.patch!,
        adminReason: adminReason,
      );
      return _writeOutcome(outcome);
    } on Exception catch (error) {
      return (
        statusCode: 503,
        body: <String, Object?>{
          'error': 'operator_account_scope_overrides_unavailable',
          'message':
              'hierarchy account overrides are unavailable; please retry.',
          'detail': error.toString(),
        },
      );
    }
  }

  ({int statusCode, Map<String, Object?> body}) _writeOutcome(
    AccountScopeOverridesOutcome outcome,
  ) {
    switch (outcome.kind) {
      case AccountScopeOverridesOutcomeKind.ok:
        return (statusCode: 200, body: outcome.record!.toJson());
      case AccountScopeOverridesOutcomeKind.scopeNotFound:
        return (
          statusCode: 404,
          body: const <String, Object?>{
            'error': 'org_unit_not_found',
            'message': 'The requested hierarchy scope was not found.',
          },
        );
    }
  }
}
