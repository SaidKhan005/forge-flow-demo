// UX-parity slice V2 — adapter from the admin hierarchy scope intent to the
// shared operator-web `HierarchyScopeNotice`.
//
// Background: the admin console used to render a degraded free-text
// `AdminHierarchyScopeNotice` (a single `message` string + icon). The
// operator-web `HierarchyScopeNotice` renders the real Hard Promise #11
// triple — selected scope (level pill + name), inherited source, effective
// value — plus an optional backend-only explainer. The admin screens already
// cross-import operator-web widgets, so they now reuse that same notice.
//
// This file holds the single mapping the admin screens need: the admin
// `AdminHierarchyScopeType` (business / org unit / location) onto the
// operator widget's `HierarchyScopeLevel`. Admin org units are a generic
// mid-tier grouping, so they render as the operator widget's "Location
// group" level. Keeping the map in one place stops six screens from each
// re-deriving it.

import 'package:forge_and_flow/operator_web/widgets/hierarchy_scope_notice.dart';

import '../admin_route_handoff.dart';

/// Maps the admin scope type onto the shared operator-web scope level used by
/// `HierarchyScopeNotice`. Business and location map one to one; an admin org
/// unit renders as the operator widget's "Location group" tier (its closest
/// plain-English match — admin org units are a generic grouping above
/// locations).
HierarchyScopeLevel adminScopeLevel(AdminHierarchyScopeType scopeType) {
  switch (scopeType) {
    case AdminHierarchyScopeType.business:
      return HierarchyScopeLevel.business;
    case AdminHierarchyScopeType.orgUnit:
      return HierarchyScopeLevel.group;
    case AdminHierarchyScopeType.location:
      return HierarchyScopeLevel.location;
  }
}
