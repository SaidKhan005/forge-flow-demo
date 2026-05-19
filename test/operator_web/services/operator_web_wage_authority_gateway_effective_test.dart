// GAP B2 — gateway projection: listEffective resolves HP #11
// inheritance over the demo gateway store, and the upsert round-trips
// the scope the editor saved at.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_wage_authority_gateway.dart';
import 'package:forge_and_flow/services/wage/wage_role_row_scope_resolver.dart';

void main() {
  final ts = DateTime.utc(2026, 5, 16);

  WageRoleRowRecord rec({
    required String id,
    required String scopeType,
    String? orgUnitId,
    required String locationId,
    String roleName = 'Server',
    String laborBucket = 'foh',
    required double hourlyRate,
  }) => WageRoleRowRecord(
    wageRoleRowId: id,
    operatorId: 'op-a',
    locationId: locationId,
    restaurantId: 'rest-a',
    roleName: roleName,
    laborBucket: laborBucket,
    hourlyRate: hourlyRate,
    weightedHours: 40,
    source: WageRoleRowSource.adminSeed,
    isActive: true,
    effectiveAt: ts,
    metadata: const <String, Object?>{},
    createdAt: ts,
    updatedAt: ts,
    scopeType: scopeType,
    orgUnitId: orgUnitId,
  );

  group('listEffective projection', () {
    test('location with no own row inherits the Business rate', () async {
      final gateway = OperatorWebDemoWageAuthorityGateway(
        initial: <WageRoleRowRecord>[
          rec(
            id: 'biz-server',
            scopeType: 'operator_wide',
            locationId: 'loc-harbour',
            hourlyRate: 16.50,
          ),
        ],
      );

      final effective = await gateway.listEffective(
        operatorId: 'op-a',
        locationId: 'loc-harbour',
        ancestorOrgUnitIdsNearestFirst: const <String>[],
      );

      expect(effective, hasLength(1));
      expect(effective.single.resolved.hourlyRate, 16.50);
      expect(effective.single.isInherited, isTrue);
      expect(
        effective.single.resolved.sourceScopeType,
        WageRoleRowScopeType.operatorWide,
      );
    });

    test('location override beats the Business default', () async {
      final gateway = OperatorWebDemoWageAuthorityGateway(
        initial: <WageRoleRowRecord>[
          rec(
            id: 'biz-server',
            scopeType: 'operator_wide',
            locationId: 'loc-downtown',
            hourlyRate: 16.50,
          ),
          rec(
            id: 'riverside-server',
            scopeType: 'location',
            locationId: 'loc-riverside',
            hourlyRate: 17.50,
          ),
        ],
      );

      final effective = await gateway.listEffective(
        operatorId: 'op-a',
        locationId: 'loc-riverside',
        ancestorOrgUnitIdsNearestFirst: const <String>[],
      );

      // Riverside sees its own override (17.50) AND the inherited
      // Business row is shadowed for the same (role, bucket) key.
      expect(effective, hasLength(1));
      expect(effective.single.resolved.hourlyRate, 17.50);
      expect(effective.single.isInherited, isFalse);
      expect(
        effective.single.resolved.sourceScopeType,
        WageRoleRowScopeType.location,
      );
    });

    test('org-unit ancestor supplies the value when nearer than '
        'Business', () async {
      final gateway = OperatorWebDemoWageAuthorityGateway(
        initial: <WageRoleRowRecord>[
          rec(
            id: 'biz-server',
            scopeType: 'operator_wide',
            locationId: 'loc-a',
            hourlyRate: 16.50,
          ),
          rec(
            id: 'region-server',
            scopeType: 'org_unit',
            orgUnitId: 'ou-east',
            locationId: 'loc-a',
            hourlyRate: 18.00,
          ),
        ],
      );

      final effective = await gateway.listEffective(
        operatorId: 'op-a',
        locationId: 'loc-a',
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-east'],
      );

      expect(effective, hasLength(1));
      expect(effective.single.resolved.hourlyRate, 18.00);
      expect(effective.single.isInherited, isTrue);
      expect(
        effective.single.resolved.sourceScopeType,
        WageRoleRowScopeType.orgUnit,
      );
    });
  });

  group('upsert round-trips scope', () {
    test('saving at Business scope reads back operator_wide', () async {
      final gateway = OperatorWebDemoWageAuthorityGateway(
        initial: const <WageRoleRowRecord>[],
        now: () => ts,
      );

      final saved = await gateway.upsert(
        request: const WageRoleRowUpsert(
          restaurantId: 'rest-a',
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 16.50,
          weightedHours: 40,
          scopeType: 'operator_wide',
        ),
        idempotencyKey: 'k1',
      );

      expect(saved.scopeType, 'operator_wide');
      expect(saved.orgUnitId, isNull);
    });

    test('upsert toJson carries scope_type + org_unit_id', () {
      const req = WageRoleRowUpsert(
        restaurantId: 'rest-a',
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 18,
        weightedHours: 40,
        scopeType: 'org_unit',
        orgUnitId: 'ou-east',
      );
      final json = req.toJson();
      expect(json['scope_type'], 'org_unit');
      expect(json['org_unit_id'], 'ou-east');
    });

    test('default scope is location (no regression for legacy '
        'callers)', () {
      const req = WageRoleRowUpsert(
        restaurantId: 'rest-a',
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 18,
        weightedHours: 40,
      );
      expect(req.toJson()['scope_type'], 'location');
      expect(req.toJson().containsKey('org_unit_id'), isFalse);
    });
  });

  group('WageRoleRowRecord scope round-trip', () {
    test('fromRow defaults to location when scope columns absent', () {
      final r = WageRoleRowRecord.fromRow(<String, Object?>{
        'wage_role_row_id': 'r1',
        'operator_id': 'op-a',
        'location_id': 'loc-a',
        'restaurant_id': 'rest-a',
        'role_name': 'Server',
        'labor_bucket': 'foh',
        'hourly_rate': 18.0,
        'weighted_hours': 40.0,
        'source': 'operator_manual',
        'is_active': true,
        'effective_at': ts,
        'created_at': ts,
        'updated_at': ts,
      });
      expect(r.scopeType, 'location');
      expect(r.orgUnitId, isNull);
      expect(r.inheritedFromScopeId, isNull);
    });

    test('toJson + fromRow preserve scope columns', () {
      final r = rec(
        id: 'r1',
        scopeType: 'org_unit',
        orgUnitId: 'ou-east',
        locationId: 'loc-a',
        hourlyRate: 18,
      );
      final json = r.toJson();
      expect(json['scope_type'], 'org_unit');
      expect(json['org_unit_id'], 'ou-east');
    });
  });
}
