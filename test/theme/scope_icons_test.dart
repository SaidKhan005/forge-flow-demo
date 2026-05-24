import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/theme/scope_icons.dart';

void main() {
  group('scopeIcon', () {
    test('business -> apartment_outlined', () {
      expect(
        scopeIcon(kind: ScopeEntityKind.business),
        Icons.apartment_outlined,
      );
    });

    test('location -> place_outlined', () {
      expect(
        scopeIcon(kind: ScopeEntityKind.location),
        Icons.place_outlined,
      );
    });

    test('org unit (no unit type) -> account_tree_outlined', () {
      expect(
        scopeIcon(kind: ScopeEntityKind.orgUnit),
        Icons.account_tree_outlined,
      );
    });

    test('org unit sub-types map to their canonical glyphs', () {
      expect(
        scopeIcon(kind: ScopeEntityKind.orgUnit, unitType: 'brand'),
        Icons.sell_outlined,
      );
      expect(
        scopeIcon(kind: ScopeEntityKind.orgUnit, unitType: 'region'),
        Icons.public,
      );
      expect(
        scopeIcon(kind: ScopeEntityKind.orgUnit, unitType: 'district'),
        Icons.map_outlined,
      );
      expect(
        scopeIcon(kind: ScopeEntityKind.orgUnit, unitType: 'location_group'),
        Icons.layers_outlined,
      );
    });

    test('org unit unknown / null unit type falls back to generic glyph', () {
      expect(
        scopeIcon(kind: ScopeEntityKind.orgUnit, unitType: 'mystery'),
        Icons.account_tree_outlined,
      );
      expect(
        scopeIcon(kind: ScopeEntityKind.orgUnit, unitType: null),
        Icons.account_tree_outlined,
      );
    });

    test('unitType is ignored for business and location kinds', () {
      expect(
        scopeIcon(kind: ScopeEntityKind.business, unitType: 'brand'),
        Icons.apartment_outlined,
      );
      expect(
        scopeIcon(kind: ScopeEntityKind.location, unitType: 'region'),
        Icons.place_outlined,
      );
    });
  });

  group('scopeIconForUnitType', () {
    test('corp root renders as the Business tier', () {
      expect(scopeIconForUnitType('corp'), Icons.apartment_outlined);
    });

    test('brand / region / district / location_group map canonically', () {
      expect(scopeIconForUnitType('brand'), Icons.sell_outlined);
      expect(scopeIconForUnitType('region'), Icons.public);
      expect(scopeIconForUnitType('district'), Icons.map_outlined);
      expect(scopeIconForUnitType('location_group'), Icons.layers_outlined);
    });

    test('unknown / null falls back to the generic org-unit glyph', () {
      expect(scopeIconForUnitType('mystery'), Icons.account_tree_outlined);
      expect(scopeIconForUnitType(null), Icons.account_tree_outlined);
    });
  });

  group('scopeIconForScopeType', () {
    test('operator -> business glyph', () {
      expect(scopeIconForScopeType('operator'), Icons.apartment_outlined);
    });

    test('org_unit -> generic org-unit glyph', () {
      expect(scopeIconForScopeType('org_unit'), Icons.account_tree_outlined);
    });

    test('location -> location glyph', () {
      expect(scopeIconForScopeType('location'), Icons.place_outlined);
    });

    test('unrecognised scope type falls back to the generic org-unit glyph', () {
      expect(scopeIconForScopeType('mystery'), Icons.account_tree_outlined);
    });
  });
}
