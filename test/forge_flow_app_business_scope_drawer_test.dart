import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/forge_flow_app.dart';

void main() {
  group('filterBusinessScopeLocationsForDrawer', () {
    const scopes = <BusinessScope>[
      BusinessScope(
        scopeId: 'op-1',
        scopeType: 'operator',
        operatorId: 'op-1',
        label: 'Acme',
      ),
      BusinessScope(
        scopeId: 'loc-1',
        scopeType: 'location',
        operatorId: 'op-1',
        locationId: 'loc-1',
        label: 'Downtown',
        sortPath: 'Acme / East / Downtown',
      ),
      BusinessScope(
        scopeId: 'loc-2',
        scopeType: 'location',
        operatorId: 'op-2',
        locationId: 'loc-2',
        label: 'Beta - Uptown',
        sortPath: 'Beta / Uptown',
      ),
    ];

    test('keeps only selectable locations', () {
      final filtered = filterBusinessScopeLocationsForDrawer(scopes, '');

      expect(filtered.map((scope) => scope.scopeId), <String>[
        'loc-1',
        'loc-2',
      ]);
    });

    test('searches business/location labels and path text', () {
      final byBusiness = filterBusinessScopeLocationsForDrawer(scopes, 'beta');
      final byPath = filterBusinessScopeLocationsForDrawer(scopes, 'east');

      expect(byBusiness.single.scopeId, 'loc-2');
      expect(byPath.single.scopeId, 'loc-1');
    });
  });
}
