// Canonical hierarchy-scope icons — THE single source of truth.
//
// Every operator-facing surface that renders a hierarchy-scope entity
// (Business -> Org unit -> Location, plus the org-unit sub-types
// brand / region / district / location group) MUST resolve its glyph
// through this helper. Do NOT hardcode scope glyphs in widgets; route
// them here so the icon set stays identical across the shared tree,
// operator-web, and mobile.
//
// Operator-approved canonical mapping (do not change without operator
// sign-off):
//   business              -> Icons.apartment_outlined
//   org unit (generic)    -> Icons.account_tree_outlined
//   brand                 -> Icons.sell_outlined
//   region                -> Icons.public
//   district              -> Icons.map_outlined
//   location group        -> Icons.layers_outlined
//   location              -> Icons.place_outlined
//
// The admin console keeps its own scope-icon resolver for now; a later
// lane migrates it onto this helper.

import 'package:flutter/material.dart';

/// Hierarchy-scope entity kinds shared across every surface.
///
/// This intentionally mirrors the three structural tiers of the
/// hierarchy (Business root -> intermediate org units -> leaf
/// locations). The org-unit sub-type (brand / region / district /
/// location group) is carried separately via `unitType` because the
/// same `orgUnit` kind renders a different glyph per sub-type.
enum ScopeEntityKind { business, orgUnit, location }

/// Canonical glyph for a hierarchy-scope entity.
///
/// [kind] selects the structural tier. For [ScopeEntityKind.orgUnit],
/// pass the raw `unit_type` string ([unitType]) to pick the sub-type
/// glyph; an unknown or null unit type falls back to the generic
/// org-unit icon ([Icons.account_tree_outlined]). [unitType] is ignored
/// for `business` and `location`.
IconData scopeIcon({required ScopeEntityKind kind, String? unitType}) {
  switch (kind) {
    case ScopeEntityKind.business:
      return Icons.apartment_outlined;
    case ScopeEntityKind.location:
      return Icons.place_outlined;
    case ScopeEntityKind.orgUnit:
      return _orgUnitIcon(unitType);
  }
}

/// Canonical glyph keyed purely off a raw `unit_type` string.
///
/// Surfaces that only have the `unit_type` column (and treat the
/// operator-wide `'corp'` root as the Business tier) use this. `'corp'`
/// resolves to the Business glyph; the brand / region / district /
/// location-group sub-types resolve to their canonical glyphs; anything
/// else (including null) falls back to the generic org-unit icon.
IconData scopeIconForUnitType(String? unitType) {
  if (unitType == 'corp') {
    return scopeIcon(kind: ScopeEntityKind.business);
  }
  return scopeIcon(kind: ScopeEntityKind.orgUnit, unitType: unitType);
}

/// Canonical glyph keyed off the [scope_type] string carried by
/// `BusinessScope` rows.
///
/// `BusinessScope` names the root tier `'operator'` (not `'corp'`).
/// `'operator'` -> Business glyph, `'org_unit'` -> generic org-unit
/// glyph, `'location'` -> location glyph. Any unrecognised value falls
/// back to the generic org-unit icon so a row always renders something.
IconData scopeIconForScopeType(String scopeType) {
  switch (scopeType) {
    case 'operator':
      return scopeIcon(kind: ScopeEntityKind.business);
    case 'location':
      return scopeIcon(kind: ScopeEntityKind.location);
    case 'org_unit':
    default:
      return scopeIcon(kind: ScopeEntityKind.orgUnit);
  }
}

IconData _orgUnitIcon(String? unitType) {
  switch (unitType) {
    case 'brand':
      return Icons.sell_outlined;
    case 'region':
      return Icons.public;
    case 'district':
      return Icons.map_outlined;
    case 'location_group':
      return Icons.layers_outlined;
    default:
      return Icons.account_tree_outlined;
  }
}
