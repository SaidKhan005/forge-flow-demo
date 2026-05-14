// Wave 2 H-2 — Visual hierarchy tree for operator-web identity pages.
//
// Wave 2 ledger row H-2 (`docs/_indices/WAVE_2_LEDGER.md`) replaces the
// text-only inheritance labels on the operator-web identity surfaces
// (`business_setup_screen.dart`, `business_timing_editor_screen.dart`)
// with a small visual tree that shows the Business → Region/Org Unit
// → Location chain, highlights the scope the operator is currently
// editing, and marks any inheritance source on the path.
//
// The companion `HierarchyScopeNotice` card
// (`lib/operator_web/widgets/hierarchy_scope_notice.dart`) stays on
// every screen — it remains the operator's accessible, plain-text
// explanation of the scope/inherited-from/effective triple required
// by Hard Promise #11 (`CLAUDE.md`). This widget renders an
// additional VIEW of the same data, never a replacement.
//
// Why a new widget rather than reusing `lib/widgets/inheritance_tree.
// dart`: that widget is consumed by surfaces (B6, B8, C-6) that
// already have a fully-assembled `InheritanceTreeNode` graph emitted
// by `OrgUnitsRepository`. The two identity pages do not have access
// to that data layer yet — they read from `BusinessTimingGateway`,
// whose `BusinessTimingBundle.inheritanceChain` is a flat list of
// `BusinessTimingScopeSummary` rows. Building a tiny purpose-built
// widget keeps H-2 additive (no plumbing through the org-units
// repository, no new gateway calls) and aligns with the scope item
// #5 doctrine in the H-2 brief ("render the tree as best-effort with
// what IS available, and emit a TODO citing the gap").
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every label, status, and copy line reads as training. Plain
// English. No engineering jargon (no `scope_kind=brand`, no
// `inherited_from=null`).

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Hierarchy level a node represents in the tree visualization. Mirrors
/// the `HierarchyScopeLevel` enum used by `HierarchyScopeNotice` so the
/// two widgets stay aligned in copy and shape.
///
/// `business` and `location` are the two anchors that always render.
/// `region` and `brand` light up as intermediate levels when the
/// underlying data exposes them; today the timing bundle exposes an
/// "Org unit / Region" placeholder we can render as a region rung.
enum HierarchyTreeLevel {
  business,
  region,
  brand,
  location,
}

extension on HierarchyTreeLevel {
  String get label {
    switch (this) {
      case HierarchyTreeLevel.business:
        return 'Business';
      case HierarchyTreeLevel.region:
        return 'Region';
      case HierarchyTreeLevel.brand:
        return 'Brand';
      case HierarchyTreeLevel.location:
        return 'Location';
    }
  }

  IconData get icon {
    switch (this) {
      case HierarchyTreeLevel.business:
        return Icons.apartment;
      case HierarchyTreeLevel.region:
        return Icons.public;
      case HierarchyTreeLevel.brand:
        return Icons.local_offer_outlined;
      case HierarchyTreeLevel.location:
        return Icons.storefront_outlined;
    }
  }
}

/// One node in the visual tree. Immutable; the screen passes a list of
/// nodes top-down (root first, leaf last) to [HierarchyTreeVisualization].
@immutable
class HierarchyTreeNodeView {
  const HierarchyTreeNodeView({
    required this.level,
    required this.name,
    this.isCurrentScope = false,
    this.inheritsFromHere = false,
    this.subtitle,
  });

  /// What level of the hierarchy this node sits at.
  final HierarchyTreeLevel level;

  /// Operator-facing display name. Renders verbatim, so callers pass
  /// the resolved business / region / location name — no UUIDs, no
  /// internal scope identifiers.
  final String name;

  /// Whether this is the scope the operator is currently editing on
  /// the host screen. Exactly one node in the chain should set this
  /// to true; the widget highlights the row and renders a "Currently
  /// editing" annotation.
  final bool isCurrentScope;

  /// Whether the host screen's effective value is *inherited from*
  /// this node. The widget marks the edge below this node with a
  /// dashed connector and an "inherits" badge so the operator can
  /// trace where the value actually came from.
  final bool inheritsFromHere;

  /// Optional one-line subtitle below the name (e.g. "Operator
  /// default" / "No override set"). Plain English; no jargon.
  final String? subtitle;
}

/// Visual tree showing the hierarchy chain for an operator-web
/// identity surface. Renders nodes top-down with connector lines, a
/// highlight on the current scope, and an inheritance source badge
/// where applicable.
///
/// The widget is intentionally non-interactive — it does not change
/// the scope, it only explains the chain visually. Pair it with
/// `HierarchyScopeNotice` for the textual triple (HP #11).
class HierarchyTreeVisualization extends StatelessWidget {
  const HierarchyTreeVisualization({
    super.key,
    required this.keyName,
    required this.nodes,
    this.headline,
    this.dataGapExplainer,
  });

  /// Key prefix the widget stamps on its root + each node so screen
  /// tests can find rows without colliding with sibling notices.
  final String keyName;

  /// Top-down list of nodes: root (business) first, leaf (location)
  /// last. Intermediate rungs (region, brand) appear in between when
  /// the host screen has data for them.
  final List<HierarchyTreeNodeView> nodes;

  /// Optional override for the headline row. Defaults to "Hierarchy".
  final String? headline;

  /// When the underlying data layer cannot expose every rung yet,
  /// pass a plain-English explainer. The widget renders it in a
  /// subdued note below the tree so the gap is visible to the
  /// operator rather than silently hidden. See HP #11 final clause
  /// ("or document why the capability is backend-only / gated /
  /// incomplete").
  final String? dataGapExplainer;

  @override
  Widget build(BuildContext context) {
    final gap = dataGapExplainer;
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.account_tree_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  headline ?? 'Hierarchy',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              _CurrentlyEditingPill(
                keyName: '${keyName}_currently_editing_pill',
                nodes: nodes,
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (int i = 0; i < nodes.length; i++)
            _TreeNodeAndConnector(
              keyName: '${keyName}_node_${nodes[i].level.name}',
              node: nodes[i],
              isLast: i == nodes.length - 1,
              parentInherits: i > 0 && nodes[i - 1].inheritsFromHere,
            ),
          if (gap != null) ...<Widget>[
            const SizedBox(height: 10),
            _DataGapNote(
              keyName: '${keyName}_data_gap',
              message: gap,
            ),
          ],
        ],
      ),
    );
  }
}

/// Renders the "Currently editing: Brand — Pizza Express" pill in the
/// header. Reads the node list to find the highlighted scope.
class _CurrentlyEditingPill extends StatelessWidget {
  const _CurrentlyEditingPill({
    required this.keyName,
    required this.nodes,
  });

  final String keyName;
  final List<HierarchyTreeNodeView> nodes;

  @override
  Widget build(BuildContext context) {
    HierarchyTreeNodeView? current;
    for (final node in nodes) {
      if (node.isCurrentScope) {
        current = node;
        break;
      }
    }
    if (current == null) {
      return const SizedBox.shrink();
    }
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.sunsetDark.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.sunsetDark.withValues(alpha: 0.42),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Editing ${current.level.label} — ${current.name}',
        style: AppTextStyles.mono8(color: AppColors.sunsetDark),
      ),
    );
  }
}

class _TreeNodeAndConnector extends StatelessWidget {
  const _TreeNodeAndConnector({
    required this.keyName,
    required this.node,
    required this.isLast,
    required this.parentInherits,
  });

  final String keyName;
  final HierarchyTreeNodeView node;
  final bool isLast;
  final bool parentInherits;

  @override
  Widget build(BuildContext context) {
    final isCurrent = node.isCurrentScope;
    return Column(
      key: Key(keyName),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          key: Key('${keyName}_row'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: isCurrent
                ? AppColors.sunsetDark.withValues(alpha: 0.08)
                : Colors.transparent,
            border: Border.all(
              color: isCurrent
                  ? AppColors.sunsetDark.withValues(alpha: 0.45)
                  : AppColors.borderSubtle.withValues(alpha: 0.55),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Icon(
                node.level.icon,
                size: 18,
                color: isCurrent ? AppColors.sunsetDark : AppColors.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${node.level.label} — ${node.name}',
                      style: AppTextStyles.body14(
                        color: isCurrent
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    if (node.subtitle != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        node.subtitle!,
                        style: AppTextStyles.body13(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (node.inheritsFromHere) ...<Widget>[
                const SizedBox(width: 8),
                _InheritsBadge(
                  keyName: '${keyName}_inherits_badge',
                ),
              ],
              if (isCurrent) ...<Widget>[
                const SizedBox(width: 8),
                _CurrentBadge(
                  keyName: '${keyName}_current_badge',
                ),
              ],
            ],
          ),
        ),
        if (!isLast)
          _ConnectorLine(
            keyName: '${keyName}_connector',
            isInheritEdge: parentInherits,
          ),
      ],
    );
  }
}

/// Vertical connector between two tree rows. Solid line by default;
/// dashed when the row above marks `inheritsFromHere` so the operator
/// can read the inheritance path visually.
class _ConnectorLine extends StatelessWidget {
  const _ConnectorLine({
    required this.keyName,
    required this.isInheritEdge,
  });

  final String keyName;
  final bool isInheritEdge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key(keyName),
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 16),
      child: CustomPaint(
        size: const Size(2, 16),
        painter: _ConnectorPainter(
          color: isInheritEdge
              ? AppColors.peacockDark.withValues(alpha: 0.55)
              : AppColors.borderSubtle,
          isDashed: isInheritEdge,
        ),
      ),
    );
  }
}

class _ConnectorPainter extends CustomPainter {
  const _ConnectorPainter({required this.color, required this.isDashed});

  final Color color;
  final bool isDashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final x = size.width / 2;
    if (!isDashed) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      return;
    }
    const dashLength = 3.0;
    const dashGap = 3.0;
    var y = 0.0;
    while (y < size.height) {
      final next = (y + dashLength).clamp(0.0, size.height);
      canvas.drawLine(Offset(x, y), Offset(x, next), paint);
      y = next + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectorPainter old) =>
      old.color != color || old.isDashed != isDashed;
}

class _CurrentBadge extends StatelessWidget {
  const _CurrentBadge({required this.keyName});

  final String keyName;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.sunsetDark,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'You are here',
        style: AppTextStyles.mono8(color: AppColors.backgroundSurface),
      ),
    );
  }
}

class _InheritsBadge extends StatelessWidget {
  const _InheritsBadge({required this.keyName});

  final String keyName;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.peacockDark.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.peacockDark.withValues(alpha: 0.42),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Inherits from here',
        style: AppTextStyles.mono8(color: AppColors.peacockDark),
      ),
    );
  }
}

class _DataGapNote extends StatelessWidget {
  const _DataGapNote({
    required this.keyName,
    required this.message,
  });

  final String keyName;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(
          color: AppColors.borderSubtle,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.info_outline,
            size: 14,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
