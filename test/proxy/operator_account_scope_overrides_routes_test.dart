import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/operator_routes.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _orgUnitId = '22222222-2222-2222-2222-222222222222';
const String _actorUserId = '33333333-3333-3333-3333-333333333333';

void main() {
  group('operator account scope overrides route helpers', () {
    test('matches one org-unit segment and extracts id', () {
      final path = '/v1/operator/account-overrides/org-unit/$_orgUnitId';
      expect(isOperatorAccountScopeOverridesPath(path), isTrue);
      expect(operatorAccountScopeOverridesOrgUnitIdOf(path), _orgUnitId);
      expect(isOperatorAccountScopeOverridesPath('$path/extra'), isFalse);
    });

    test('decode rejects fields owned by other surfaces', () {
      final businessName = decodeAccountScopeOverridesPatchBody(
        const <String, Object?>{'businessName': 'Nope'},
      );
      expect(businessName.ok, isFalse);
      expect(
        businessName.body?['error'],
        equals('unsupported_account_scope_field'),
      );

      final rollover = decodeAccountScopeOverridesPatchBody(
        const <String, Object?>{'businessDayRolloverHour': 4},
      );
      expect(rollover.ok, isFalse);
      expect(
        rollover.body?['error'],
        equals('unsupported_account_scope_field'),
      );
    });

    test('decode accepts scoped account fields and null clears', () {
      final decoded = decodeAccountScopeOverridesPatchBody(
        const <String, Object?>{
          'ianaTimezone': 'Europe/London',
          'currencyCode': 'GBP',
          'contactPhone': null,
        },
      );
      expect(decoded.ok, isTrue);
      expect(decoded.patch?.ianaTimezone, equals('Europe/London'));
      expect(decoded.patch?.currencyCode, equals('GBP'));
      expect(decoded.patch?.clearContactPhone, isTrue);
    });
  });

  group('OperatorAccountScopeOverridesHandler', () {
    test('GET returns the effective triple from the gateway', () async {
      final gateway = _ScopeGateway();
      final handler = OperatorAccountScopeOverridesHandler(gateway: gateway);

      final result = await handler.handleGet(
        operatorId: _operatorId,
        actorUserId: _actorUserId,
        orgUnitId: _orgUnitId,
      );

      expect(result.statusCode, equals(200));
      expect(result.body['scopeType'], equals('org_unit'));
      expect(result.body['scopeId'], equals(_orgUnitId));
      expect(gateway.loadCalls, equals(1));
    });

    test('PATCH validates id and returns scoped write result', () async {
      final gateway = _ScopeGateway();
      final handler = OperatorAccountScopeOverridesHandler(gateway: gateway);

      final result = await handler.handlePatch(
        operatorId: _operatorId,
        actorUserId: _actorUserId,
        orgUnitId: _orgUnitId,
        body: const <String, Object?>{
          'ianaTimezone': 'Europe/London',
          'currencyCode': 'GBP',
        },
      );

      expect(result.statusCode, equals(200));
      expect(gateway.patchCalls, equals(1));
      expect(gateway.lastPatch?.ianaTimezone, equals('Europe/London'));
      expect(gateway.lastPatch?.currencyCode, equals('GBP'));
    });

    test('PATCH returns 404 when scope is missing', () async {
      final handler = OperatorAccountScopeOverridesHandler(
        gateway: _ScopeGateway(
          outcome: const AccountScopeOverridesOutcome.scopeNotFound(),
        ),
      );

      final result = await handler.handlePatch(
        operatorId: _operatorId,
        actorUserId: _actorUserId,
        orgUnitId: _orgUnitId,
        body: const <String, Object?>{'currencyCode': 'GBP'},
      );

      expect(result.statusCode, equals(404));
      expect(result.body['error'], equals('org_unit_not_found'));
    });
  });
}

class _ScopeGateway implements AccountScopeOverridesWriteGateway {
  _ScopeGateway({this.outcome});

  final AccountScopeOverridesOutcome? outcome;
  int loadCalls = 0;
  int patchCalls = 0;
  ValidatedLocationAccountOverridesPatch? lastPatch;

  @override
  Future<AccountScopeOverridesOutcome> loadOverrides({
    required String operatorId,
    required String actorUserId,
    required String orgUnitId,
    required String adminReason,
  }) async {
    loadCalls += 1;
    return outcome ?? AccountScopeOverridesOutcome.ok(_record(operatorId));
  }

  @override
  Future<AccountScopeOverridesOutcome> patchOverrides({
    required String operatorId,
    required String actorUserId,
    required String orgUnitId,
    required ValidatedLocationAccountOverridesPatch patch,
    required String adminReason,
  }) async {
    patchCalls += 1;
    lastPatch = patch;
    return outcome ??
        AccountScopeOverridesOutcome.ok(
          AccountScopeOverridesRecord(
            operatorId: operatorId,
            scopeType: 'org_unit',
            scopeId: orgUnitId,
            effective: LocationAccountOverridesFieldSet(
              ianaTimezone: patch.ianaTimezone ?? 'America/Toronto',
              localeCode: patch.localeCode ?? 'en-CA',
              currencyCode: patch.currencyCode ?? 'CAD',
            ),
            override: LocationAccountOverridesFieldSet(
              ianaTimezone: patch.ianaTimezone,
              localeCode: patch.localeCode,
              currencyCode: patch.currencyCode,
            ),
            businessDefault: const LocationAccountOverridesFieldSet(
              ianaTimezone: 'America/Toronto',
              localeCode: 'en-CA',
              currencyCode: 'CAD',
            ),
            updatedAt: DateTime.utc(2026, 5, 20, 12),
          ),
        );
  }

  AccountScopeOverridesRecord _record(String operatorId) {
    return AccountScopeOverridesRecord(
      operatorId: operatorId,
      scopeType: 'org_unit',
      scopeId: _orgUnitId,
      effective: const LocationAccountOverridesFieldSet(
        ianaTimezone: 'America/Toronto',
        localeCode: 'en-CA',
        currencyCode: 'CAD',
      ),
      override: const LocationAccountOverridesFieldSet(),
      businessDefault: const LocationAccountOverridesFieldSet(
        localeCode: 'en-CA',
        currencyCode: 'CAD',
      ),
      updatedAt: DateTime.utc(2026, 5, 20, 12),
    );
  }
}
