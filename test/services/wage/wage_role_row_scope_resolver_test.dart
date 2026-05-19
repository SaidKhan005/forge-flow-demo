import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/wage/wage_role_row_scope_resolver.dart';

void main() {
  const resolver = WageRoleRowScopeResolver();
  const operatorId = 'op-a';
  final t0 = DateTime.utc(2026, 5, 16, 10);

  WageRoleRowScopeCandidate row({
    required String id,
    required WageRoleRowScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    double hourlyRate = 18.0,
    double weightedHours = 40.0,
    String roleName = 'Server',
    String laborBucket = 'foh',
    DateTime? effectiveAt,
    bool isActive = true,
  }) {
    return WageRoleRowScopeCandidate(
      wageRoleRowId: id,
      operatorId: operatorId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: locationId,
      roleName: roleName,
      laborBucket: laborBucket,
      hourlyRate: hourlyRate,
      weightedHours: weightedHours,
      effectiveAt: effectiveAt ?? t0,
      isActive: isActive,
      sourceLabel: id,
    );
  }

  group('WageRoleRowScopeResolver', () {
    test('location override beats org-unit and Business values', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near', 'ou-root'],
        locationId: 'loc-a',
        candidates: <WageRoleRowScopeCandidate>[
          row(
            id: 'business',
            scopeType: WageRoleRowScopeType.operatorWide,
            hourlyRate: 16.50,
          ),
          row(
            id: 'ou-near',
            scopeType: WageRoleRowScopeType.orgUnit,
            orgUnitId: 'ou-near',
            hourlyRate: 17.00,
          ),
          row(
            id: 'loc-a',
            scopeType: WageRoleRowScopeType.location,
            locationId: 'loc-a',
            hourlyRate: 19.25,
          ),
        ],
      );

      expect(resolved.wageRoleRowId, 'loc-a');
      expect(resolved.hourlyRate, 19.25);
      expect(resolved.sourceScopeType, WageRoleRowScopeType.location);
      expect(resolved.inherited, isFalse);
    });

    test('nearest configured org-unit wins over farther ancestor', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near', 'ou-root'],
        locationId: 'loc-a',
        candidates: <WageRoleRowScopeCandidate>[
          row(
            id: 'ou-root',
            scopeType: WageRoleRowScopeType.orgUnit,
            orgUnitId: 'ou-root',
            hourlyRate: 18.0,
          ),
          row(
            id: 'ou-near',
            scopeType: WageRoleRowScopeType.orgUnit,
            orgUnitId: 'ou-near',
            hourlyRate: 17.25,
          ),
        ],
      );

      expect(resolved.wageRoleRowId, 'ou-near');
      expect(resolved.hourlyRate, 17.25);
      expect(resolved.sourceScopeType, WageRoleRowScopeType.orgUnit);
      expect(resolved.inherited, isTrue);
    });

    test('Business (operator-wide) used when no lower scope configured', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near'],
        locationId: 'loc-a',
        candidates: <WageRoleRowScopeCandidate>[
          row(
            id: 'business',
            scopeType: WageRoleRowScopeType.operatorWide,
            hourlyRate: 16.50,
          ),
        ],
      );

      expect(resolved.wageRoleRowId, 'business');
      expect(resolved.hourlyRate, 16.50);
      expect(resolved.sourceScopeType, WageRoleRowScopeType.operatorWide);
      expect(resolved.inherited, isTrue);
      expect(resolved.sourceLabel, 'business');
    });

    test('empty ancestor list — Business still resolves (boundary)', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>[],
        locationId: 'loc-a',
        candidates: <WageRoleRowScopeCandidate>[
          row(
            id: 'ou-orphan',
            scopeType: WageRoleRowScopeType.orgUnit,
            orgUnitId: 'ou-orphan',
            hourlyRate: 99.0,
          ),
          row(
            id: 'business',
            scopeType: WageRoleRowScopeType.operatorWide,
            hourlyRate: 16.50,
          ),
        ],
      );

      // No ancestors → the org-unit row is unreachable; falls through
      // to Business.
      expect(resolved.wageRoleRowId, 'business');
      expect(resolved.hourlyRate, 16.50);
      expect(resolved.sourceScopeType, WageRoleRowScopeType.operatorWide);
    });

    test('no candidates at all → fallback (boundary)', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>[],
        locationId: 'loc-a',
        candidates: const <WageRoleRowScopeCandidate>[],
        fallbackHourlyRate: 12.0,
      );

      expect(resolved.wageRoleRowId, isNull);
      expect(resolved.hourlyRate, 12.0);
      expect(resolved.sourceScopeType, WageRoleRowScopeType.fallback);
      expect(resolved.sourceLabel, 'No wage set');
      expect(resolved.inherited, isFalse);
    });

    test('null locationId skips the location tier', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near'],
        locationId: null,
        candidates: <WageRoleRowScopeCandidate>[
          row(
            id: 'loc-a',
            scopeType: WageRoleRowScopeType.location,
            locationId: 'loc-a',
            hourlyRate: 19.25,
          ),
          row(
            id: 'ou-near',
            scopeType: WageRoleRowScopeType.orgUnit,
            orgUnitId: 'ou-near',
            hourlyRate: 17.25,
          ),
        ],
      );

      expect(resolved.wageRoleRowId, 'ou-near');
      expect(resolved.sourceScopeType, WageRoleRowScopeType.orgUnit);
    });

    test('inactive + wrong-role rows are ignored before fallback', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>['ou-near'],
        locationId: 'loc-a',
        candidates: <WageRoleRowScopeCandidate>[
          row(
            id: 'inactive-loc',
            scopeType: WageRoleRowScopeType.location,
            locationId: 'loc-a',
            hourlyRate: 1.0,
            isActive: false,
          ),
          row(
            id: 'wrong-role',
            scopeType: WageRoleRowScopeType.location,
            locationId: 'loc-a',
            roleName: 'Bartender',
            hourlyRate: 2.0,
          ),
          row(
            id: 'wrong-bucket',
            scopeType: WageRoleRowScopeType.location,
            locationId: 'loc-a',
            laborBucket: 'boh',
            hourlyRate: 3.0,
          ),
        ],
        fallbackHourlyRate: 15.0,
      );

      expect(resolved.wageRoleRowId, isNull);
      expect(resolved.hourlyRate, 15.0);
      expect(resolved.sourceScopeType, WageRoleRowScopeType.fallback);
    });

    test('latest effectiveAt wins among same-scope rows', () {
      final resolved = resolver.resolve(
        roleName: 'Server',
        laborBucket: 'foh',
        operatorId: operatorId,
        ancestorOrgUnitIdsNearestFirst: const <String>[],
        locationId: 'loc-a',
        candidates: <WageRoleRowScopeCandidate>[
          row(
            id: 'older',
            scopeType: WageRoleRowScopeType.location,
            locationId: 'loc-a',
            hourlyRate: 18.0,
            effectiveAt: DateTime.utc(2026, 5, 10),
          ),
          row(
            id: 'newer',
            scopeType: WageRoleRowScopeType.location,
            locationId: 'loc-a',
            hourlyRate: 20.0,
            effectiveAt: DateTime.utc(2026, 5, 16),
          ),
        ],
      );

      expect(resolved.wageRoleRowId, 'newer');
      expect(resolved.hourlyRate, 20.0);
    });
  });
}
