// Slice L_A1 — Inheritance Tree primitive value class.
//
// Immutable tree node consumed by the shared [InheritanceTree] widget
// (`lib/widgets/inheritance_tree.dart`) and emitted by the hierarchy
// traversal methods on `OrgUnitsRepository`. The shape mirrors the
// Business → Org Unit → Location chain that lives in Postgres as the
// `org_units` ltree hierarchy with `locations` rooted at a parent
// org_unit:
//
//   Business root (org_units row, parent_id IS NULL, unit_type = 'corp')
//     └── Org Unit (org_units rows, parent_id set, unit_type in
//         {region, district, location_group})
//             └── Location (locations row attached via
//                 `parent_org_unit_id`)
//
// L_A2 will cache the descendant-location set per (operator_id,
// scope_id); L_A1's value class is the read-side shape that the cache
// will project into.
//
// Pure value: no I/O, no Flutter import, no `package:postgres` import.
// Consumers (B8 audit filter, B6 benchmark inheritance, C-6 operator-web
// hierarchy screens) attach their own effective-value semantics via the
// widget's `annotationBuilder` callback — the node itself stays
// effective-value-blind.

import 'package:meta/meta.dart';

/// What kind of node this is in the hierarchy. `business` is the root
/// (corp org_unit); `orgUnit` is any intermediate region / district /
/// location_group; `location` is a leaf restaurant location.
///
/// The enum mirrors the Postgres `scope_type` vocabulary used elsewhere
/// in the codebase (`operator_wide` / `org_unit` / `location` on
/// `user_roles` and `auth_invites`) but renames `operator_wide` to
/// `business` to match the operator-facing IA copy. See the Hard
/// Promise #11 hierarchy contract.
enum InheritanceTreeScopeKind {
  /// Operator-wide root. Lives in `org_units` with `parent_id IS NULL`
  /// and `unit_type = 'corp'`. Mapped to operator-facing copy
  /// "Business".
  business,

  /// Intermediate hierarchy node. Lives in `org_units` with `parent_id`
  /// set and `unit_type` in {region, district, location_group}.
  orgUnit,

  /// Leaf restaurant location. Lives in `public.locations` and attaches
  /// to an org_unit via `parent_org_unit_id` / `org_unit_path`.
  location,
}

/// One node in an inheritance tree. Immutable; build new instances via
/// [copyWith] rather than mutating in place.
///
/// The `metadata` slot is an open map so consumers can stash their own
/// fields (e.g. an `org_unit_path` ltree string for L_A2's cache key,
/// or an `is_suspended` flag for the consumer's annotation builder)
/// without forcing a breaking change to this value class. Keep the map
/// shallow and serialisable so future widget/DTO crossings stay clean.
@immutable
class InheritanceTreeNode {
  /// Construct a node. `children` defaults to const-empty so leaf nodes
  /// do not need to pass anything.
  const InheritanceTreeNode({
    required this.scopeKind,
    required this.scopeId,
    required this.displayName,
    this.parentScopeId,
    this.depth = 0,
    this.children = const <InheritanceTreeNode>[],
    this.metadata = const <String, Object?>{},
  });

  /// What kind of scope this row represents.
  final InheritanceTreeScopeKind scopeKind;

  /// Stable identifier for this scope. For `business` and `orgUnit`
  /// this is `org_units.id`; for `location` this is
  /// `locations.location_id`. UUID-shaped in production.
  final String scopeId;

  /// Operator-facing label for the row. The widget renders this as
  /// the primary text on each row.
  final String displayName;

  /// Identifier of this node's parent in the tree, if any. `null` only
  /// on the business root.
  final String? parentScopeId;

  /// 0 for the root, +1 for each level beneath. Used by the widget for
  /// indentation; callers do not have to populate this themselves —
  /// repository methods that assemble the tree set it.
  final int depth;

  /// Direct descendants in stable display order (parent assembles
  /// children sorted alphabetically by `displayName` so the rendered
  /// tree is reproducible across runs, matching the existing scope
  /// selector in `lib/operator_web/widgets/org_unit_tree_view.dart`).
  final List<InheritanceTreeNode> children;

  /// Open metadata slot for future fields. Consumers and the L_A2
  /// cache projector can stash `org_unit_path`, `is_suspended`, etc.
  /// without breaking the value class shape.
  final Map<String, Object?> metadata;

  /// Whether this node has any direct descendants. Cheaper than
  /// `children.isNotEmpty` for callers that just need the boolean.
  bool get hasChildren => children.isNotEmpty;

  /// Returns a copy with the named fields replaced. Pass `null` for
  /// `parentScopeId` explicitly to set it null (we cannot distinguish
  /// "leave alone" from "set null" without sentinel values, so
  /// callers that need that distinction should construct fresh).
  InheritanceTreeNode copyWith({
    InheritanceTreeScopeKind? scopeKind,
    String? scopeId,
    String? displayName,
    String? parentScopeId,
    int? depth,
    List<InheritanceTreeNode>? children,
    Map<String, Object?>? metadata,
  }) {
    return InheritanceTreeNode(
      scopeKind: scopeKind ?? this.scopeKind,
      scopeId: scopeId ?? this.scopeId,
      displayName: displayName ?? this.displayName,
      parentScopeId: parentScopeId ?? this.parentScopeId,
      depth: depth ?? this.depth,
      children: children ?? this.children,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is InheritanceTreeNode &&
            other.scopeKind == scopeKind &&
            other.scopeId == scopeId &&
            other.displayName == displayName &&
            other.parentScopeId == parentScopeId &&
            other.depth == depth &&
            _listEquals(other.children, children) &&
            _mapEquals(other.metadata, metadata));
  }

  @override
  int get hashCode {
    return Object.hash(
      scopeKind,
      scopeId,
      displayName,
      parentScopeId,
      depth,
      Object.hashAll(children),
      _mapHashCode(metadata),
    );
  }

  @override
  String toString() {
    return 'InheritanceTreeNode(${scopeKind.name}, $scopeId, '
        '"$displayName", depth=$depth, children=${children.length})';
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || b[key] != a[key]) return false;
    }
    return true;
  }

  static int _mapHashCode<K, V>(Map<K, V> m) {
    var h = 0;
    for (final entry in m.entries) {
      h ^= Object.hash(entry.key, entry.value);
    }
    return h;
  }
}
