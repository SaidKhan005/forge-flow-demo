// GAP A4 — shared org-unit depth-cap rule.
//
// The database caps the org-unit hierarchy at six levels:
//
//   db/migrations/202604280002_phase_9_0sigma_c_org_units.sql:115
//     constraint org_units_depth_check check (nlevel(path) <= 6)
//
// The proxy repository mirrors that cap in Dart so a malformed insert
// is rejected before the round-trip:
//
//   lib/infrastructure/persistence/postgres/repositories/
//     org_units_repository.dart:92  static const int maxDepth = 6;
//     org_units_repository.dart:241 if (parentDepth >= maxDepth) ...
//
// Until now the Flutter create dialogs (operator-web Hierarchy screen
// and the F&F admin Roles/Hierarchy/Sessions screen) never saw that
// rule, so an operator could try to add a seventh level and only learn
// it was rejected after a server round-trip with an unfriendly error.
//
// This helper is the single Flutter-free home for the rule so both
// dialogs and their tests pin one cap and one piece of copy. The
// boundary it enforces is identical to the proxy guard: a parent at
// depth 6 (the maximum) cannot take a child; a parent at depth 5 can
// (the child lands at depth 6, still inside the cap).
//
// Locations are NOT part of the org-unit chain — they attach to an
// org-unit via `parent_org_unit_id` and do not count toward the six
// levels. Only `org_units` rows count: the corp root is level 1.
//
// Pure Dart: no Flutter import, no `package:postgres` import, no I/O.

/// The deepest org-unit level Forge & Flow allows. Mirrors the
/// database `CHECK (nlevel(path) <= 6)` and
/// `OrgUnitsRepository.maxDepth`. The corp root is level 1; locations
/// are not in the chain and do not count.
const int kOrgUnitMaxDepth = 6;

/// Operator-facing copy shown when a create is blocked because the
/// parent is already at the deepest allowed level. Plain English, no
/// error codes — reads as guidance, per the UX writing standard.
const String kOrgUnitDepthCapMessage =
    "You've reached the deepest level we allow (6 levels under your "
    'business). You can\'t add a group under this one. Add the new '
    'group higher up, or move things around first.';

/// The rule itself. Stateless; every method is a pure function so the
/// dialogs, the proxy-side guard mirror, and the tests all agree on
/// one boundary.
class OrgUnitDepthRule {
  const OrgUnitDepthRule._();

  /// The locked maximum depth (alias of [kOrgUnitMaxDepth] so callers
  /// can reach it through the rule type without a second import).
  static const int maxDepth = kOrgUnitMaxDepth;

  /// The locked operator-facing copy (alias of
  /// [kOrgUnitDepthCapMessage]).
  static const String depthCapMessage = kOrgUnitDepthCapMessage;

  /// True iff a child may be added under a parent at [parentDepth].
  ///
  /// Mirrors the proxy guard exactly:
  /// `org_units_repository.dart:241 if (parentDepth >= maxDepth)`.
  /// A parent at depth 5 → allowed (child lands at 6). A parent at
  /// depth 6 → blocked. `parentDepth <= 0` is treated as "no real
  /// parent yet" and allowed (root creation is a separate path that
  /// the create dialogs never reach — the dialogs always have a
  /// concrete parent — but guarding here keeps the function total).
  static bool canAddChild(int parentDepth) => parentDepth < maxDepth;

  /// Depth implied by an ltree materialized path. `"a.b.c"` → 3,
  /// `"demo_bistro"` → 1, `""` → 0. Matches Postgres `nlevel(path)`:
  /// each dot-separated label is one level, the root path is a single
  /// label (level 1), and an empty/blank path is level 0.
  static int depthFromPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return 0;
    // ltree labels are dot-separated. Collapse any accidental empty
    // segments (e.g. a stray leading/trailing dot) so the count never
    // over-reports the real level.
    return trimmed
        .split('.')
        .where((segment) => segment.trim().isNotEmpty)
        .length;
  }

  /// Depth of [startId] computed by walking the in-memory parent
  /// links via [parentOf] (which returns the parent id of a given id,
  /// or `null` at the root). Cycle-guarded: if the chain revisits an
  /// id (corrupt data) the walk stops and returns the depth counted so
  /// far rather than looping forever.
  ///
  /// Used by the admin surface, whose node model carries no ltree
  /// `path` — only parent pointers. The root counts as level 1, each
  /// step up adds one, matching [depthFromPath] for a well-formed
  /// tree.
  static int depthFromChain(
    String startId,
    String? Function(String id) parentOf,
  ) {
    final seen = <String>{};
    var depth = 0;
    String? cursor = startId;
    while (cursor != null && seen.add(cursor)) {
      depth += 1;
      cursor = parentOf(cursor);
    }
    return depth;
  }
}
