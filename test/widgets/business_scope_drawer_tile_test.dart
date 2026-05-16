// Mobile-FU-business-scope-drawer-seed — widget tests for the
// active-scope highlight in the mobile business-scope drawer.
//
// Scope: the rendering rules for `BusinessScopeDrawerTile` (extracted
// from `_buildBusinessScopeDrawer` in `lib/forge_flow_app.dart` so the
// active-row treatment can be exercised in isolation).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/business_scope.dart';
import 'package:forge_and_flow/forge_flow_app.dart';

void main() {
  group('BusinessScopeDrawerTile', () {
    const activeScope = BusinessScope(
      scopeId: 'demo_restaurant_001',
      scopeType: 'location',
      operatorId: 'demo-operator',
      locationId: 'demo_restaurant_001',
      label: 'Barrio Legado',
      businessTimezone: 'America/St_Johns',
    );

    const otherScope = BusinessScope(
      scopeId: 'loc-2',
      scopeType: 'location',
      operatorId: 'demo-operator',
      locationId: 'loc-2',
      label: 'Harbour',
      businessTimezone: 'America/St_Johns',
    );

    Future<void> pumpTile(
      WidgetTester tester, {
      required BusinessScope scope,
      required bool selected,
      VoidCallback? onTap,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BusinessScopeDrawerTile(
              scope: scope,
              selected: selected,
              onTap: onTap ?? () {},
            ),
          ),
        ),
      );
    }

    testWidgets(
      'renders the active scope as the selected row with check_circle',
      (tester) async {
        await pumpTile(tester, scope: activeScope, selected: true);

        // The active row carries the deterministic anchor key, plus a
        // ListTile.selected=true and the trailing check_circle.
        final activeFinder = find.byKey(
          const Key('business_scope_drawer_tile_active'),
        );
        expect(activeFinder, findsOneWidget);
        final tile = tester.widget<ListTile>(activeFinder);
        expect(tile.selected, isTrue);
        expect(
          find.byKey(BusinessScopeDrawerTile.activeCheckIconKey),
          findsOneWidget,
        );
        expect(
          find.byKey(BusinessScopeDrawerTile.activeLeadingIconKey),
          findsOneWidget,
        );
        expect(find.text('Barrio Legado'), findsOneWidget);
      },
    );

    testWidgets('non-active rows hide the trailing check icon', (tester) async {
      await pumpTile(tester, scope: otherScope, selected: false);

      final tileFinder = find.byKey(
        const Key('business_scope_drawer_tile_location:loc-2'),
      );
      expect(tileFinder, findsOneWidget);
      final tile = tester.widget<ListTile>(tileFinder);
      expect(tile.selected, isFalse);
      expect(
        find.byKey(BusinessScopeDrawerTile.activeCheckIconKey),
        findsNothing,
      );
      expect(
        find.byKey(BusinessScopeDrawerTile.activeLeadingIconKey),
        findsNothing,
      );
    });

    testWidgets('onTap fires when the row is tapped', (tester) async {
      var taps = 0;
      await pumpTile(
        tester,
        scope: otherScope,
        selected: false,
        onTap: () => taps += 1,
      );

      await tester.tap(
        find.byKey(const Key('business_scope_drawer_tile_location:loc-2')),
      );
      expect(taps, 1);
    });

    test('iconFor maps each scope type to the canonical glyph', () {
      expect(
        BusinessScopeDrawerTile.iconFor(activeScope),
        Icons.storefront_outlined,
      );
      expect(
        BusinessScopeDrawerTile.iconFor(
          const BusinessScope(
            scopeId: 'op-1',
            scopeType: 'operator',
            operatorId: 'op-1',
            label: 'Acme',
          ),
        ),
        Icons.business_outlined,
      );
      expect(
        BusinessScopeDrawerTile.iconFor(
          const BusinessScope(
            scopeId: 'org-1',
            scopeType: 'org_unit',
            operatorId: 'op-1',
            label: 'Region',
          ),
        ),
        Icons.account_tree_outlined,
      );
    });

    test('subtitleFor prefers sortPath when distinct from label', () {
      expect(
        BusinessScopeDrawerTile.subtitleFor(
          const BusinessScope(
            scopeId: 'loc-1',
            scopeType: 'location',
            operatorId: 'op-1',
            locationId: 'loc-1',
            label: 'Downtown',
            sortPath: 'Acme / East / Downtown',
          ),
        ),
        'Acme / East / Downtown',
      );
      expect(BusinessScopeDrawerTile.subtitleFor(activeScope), 'Location');
    });
  });
}
