// Slice L_A1 — Inheritance Tree shared widget.
//
// VISUALIZATION (not a selector). Renders the Business → Org Unit →
// Location hierarchy with a per-node annotation slot. Consumers
// (B8 audit log filter, B6 benchmark override, C-6 operator-web
// hierarchy screens, future region rollups) plug their own
// effective-value labels via [annotationBuilder] — the widget itself
// stays effective-value-blind.
//
// Distinguishes itself from `lib/operator_web/widgets/org_unit_tree_view.dart`
// (a scope SELECTOR with mutate affordances tied to the Members /
// Hierarchy gateway). This file is the read-side visualization that
// any role-gated screen can mount; the existing selector remains
// untouched per the L_A1 spec ("Codex's scope pane is the selector;
// this is the visualization").
//
// Shared location (`lib/widgets/`): both `lib/admin/` and
// `lib/operator_web/` import from here; placing it in either of those
// directories would force the other to reach across the layer
// boundary.
//
// Style mirrors the existing scope selector for visual posture (icon
// + label + expand/collapse) so the two surfaces feel like the same
// product. No animation, no drag, no mutate buttons — the widget is a
// pure read-side tree.

import 'package:flutter/material.dart';

import '../domain/models/inheritance_tree_node.dart';
import '../theme/scope_icons.dart';
import '../theme/app_theme.dart';

/// Builds a widget rendered to the right of the node's label. Use this
/// slot to attach effective-value annotations (e.g. catalog version
/// for B2.2, benchmark value for B6, audit-scope filter for B8). The
/// widget passes the full [InheritanceTreeNode] so the builder can
/// dispatch on `scopeKind`, read metadata, etc.
typedef InheritanceTreeAnnotationBuilder =
    Widget Function(BuildContext context, InheritanceTreeNode node);

/// Called when a node row is tapped. Null means the tree renders
/// read-only (no tap region).
typedef InheritanceTreeNodeTapped = void Function(InheritanceTreeNode node);

/// Shared Inheritance Tree visualization. Pass a fully-assembled
/// [rootNode] (e.g. from
/// `OrgUnitsRepository.getOrgUnitTreeForOperator`) and a
/// caller-supplied [annotationBuilder]; the widget renders the tree
/// with consistent depth indentation, icons per scope kind, and
/// expand/collapse on org-unit rows.
///
/// The widget itself never decides what an "effective value" means —
/// that semantics lives in the [annotationBuilder] the consumer
/// provides. Likewise, no permission gating: callers are responsible
/// for showing/hiding the surface based on their feature's role gate.
class InheritanceTree extends StatefulWidget {
  const InheritanceTree({
    super.key,
    required this.rootNode,
    required this.annotationBuilder,
    this.onNodeTap,
    this.initiallyCollapsedScopeIds = const <String>{},
    this.emptyMessage,
    this.indentWidth = 18,
    this.rowGap = 6,
  });

  /// Top of the tree. When `rootNode.children.isEmpty` the widget
  /// renders the empty-state notice instead of the tree body.
  final InheritanceTreeNode rootNode;

  /// Per-node annotation builder. Required so callers explicitly opt
  /// in to whatever effective-value semantics they want to display.
  /// Return `const SizedBox.shrink()` to omit the annotation on a
  /// given row.
  final InheritanceTreeAnnotationBuilder annotationBuilder;

  /// Optional tap handler. Null = read-only tree.
  final InheritanceTreeNodeTapped? onNodeTap;

  /// Scope ids that start collapsed when the widget first mounts.
  /// Useful for very deep trees where the consumer prefers a compact
  /// initial view; default expands everything.
  final Set<String> initiallyCollapsedScopeIds;

  /// Override copy for the empty-state notice. Defaults to plain
  /// English per `project_ux_writing_standard.md`.
  final String? emptyMessage;

  /// Horizontal offset per tree depth level.
  final double indentWidth;

  /// Vertical space between tree rows.
  final double rowGap;

  @override
  State<InheritanceTree> createState() => _InheritanceTreeState();
}

class _InheritanceTreeState extends State<InheritanceTree> {
  late final Set<String> _collapsed = <String>{
    ...widget.initiallyCollapsedScopeIds,
  };

  @override
  Widget build(BuildContext context) {
    if (!widget.rootNode.hasChildren &&
        widget.rootNode.scopeKind == InheritanceTreeScopeKind.business) {
      // Empty business with no descendants — show the empty state.
      return _emptyState(context);
    }
    return Column(
      key: const Key('inheritance_tree'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _InheritanceTreeNodeRow(
          node: widget.rootNode,
          collapsed: _collapsed,
          onToggleCollapsed: _toggleCollapsed,
          annotationBuilder: widget.annotationBuilder,
          onNodeTap: widget.onNodeTap,
          indentWidth: widget.indentWidth,
          rowGap: widget.rowGap,
        ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    return Container(
      key: const Key('inheritance_tree_empty'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        widget.emptyMessage ??
            'No org units or locations yet. Add your first location '
                'to populate the inheritance tree.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      ),
    );
  }

  void _toggleCollapsed(String scopeId) {
    setState(() {
      if (!_collapsed.add(scopeId)) {
        _collapsed.remove(scopeId);
      }
    });
  }
}

class _InheritanceTreeNodeRow extends StatelessWidget {
  const _InheritanceTreeNodeRow({
    required this.node,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.annotationBuilder,
    required this.onNodeTap,
    required this.indentWidth,
    required this.rowGap,
  });

  final InheritanceTreeNode node;
  final Set<String> collapsed;
  final ValueChanged<String> onToggleCollapsed;
  final InheritanceTreeAnnotationBuilder annotationBuilder;
  final InheritanceTreeNodeTapped? onNodeTap;
  final double indentWidth;
  final double rowGap;

  @override
  Widget build(BuildContext context) {
    final isCollapsed = collapsed.contains(node.scopeId);
    final indent = node.depth * indentWidth;
    final tap = onNodeTap;
    final row = Padding(
      padding: EdgeInsets.only(left: indent, top: node.depth == 0 ? 0 : rowGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _ToggleIcon(
            node: node,
            isCollapsed: isCollapsed,
            onToggleCollapsed: onToggleCollapsed,
          ),
          Icon(
            _iconFor(node.scopeKind, node.metadata),
            size: 18,
            color: AppColors.sunsetDark,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  node.displayName,
                  style: AppTextStyles.body13(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  _scopeKindLabel(node),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Caller-supplied annotation. Consumers (B8/B6/C-6) plug
          // their effective-value widget here — the tree stays blind.
          Builder(
            key: Key('inheritance_tree_annotation_${node.scopeId}'),
            builder: (innerContext) => annotationBuilder(innerContext, node),
          ),
        ],
      ),
    );
    final tappableRow = tap == null
        ? row
        : InkWell(
            key: Key('inheritance_tree_tap_${node.scopeId}'),
            onTap: () => tap(node),
            child: row,
          );
    return Column(
      key: Key('inheritance_tree_node_${node.scopeId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        tappableRow,
        if (!isCollapsed)
          ...node.children.map(
            (child) => _InheritanceTreeNodeRow(
              node: child,
              collapsed: collapsed,
              onToggleCollapsed: onToggleCollapsed,
              annotationBuilder: annotationBuilder,
              onNodeTap: onNodeTap,
              indentWidth: indentWidth,
              rowGap: rowGap,
            ),
          ),
      ],
    );
  }

  static IconData _iconFor(
    InheritanceTreeScopeKind kind,
    Map<String, Object?> metadata,
  ) {
    // Canonical hierarchy-scope glyphs live in lib/theme/scope_icons.dart.
    final unitType = metadata['unit_type'];
    return scopeIcon(
      kind: switch (kind) {
        InheritanceTreeScopeKind.business => ScopeEntityKind.business,
        InheritanceTreeScopeKind.orgUnit => ScopeEntityKind.orgUnit,
        InheritanceTreeScopeKind.location => ScopeEntityKind.location,
      },
      unitType: unitType is String ? unitType : null,
    );
  }

  static String _scopeKindLabel(InheritanceTreeNode node) {
    switch (node.scopeKind) {
      case InheritanceTreeScopeKind.business:
        return 'Business';
      case InheritanceTreeScopeKind.orgUnit:
        final unitType = node.metadata['unit_type'];
        return switch (unitType) {
          'brand' => 'Brand',
          'region' => 'Region',
          'district' => 'District',
          'location_group' => 'Location group',
          _ => 'Org unit',
        };
      case InheritanceTreeScopeKind.location:
        return 'Location';
    }
  }
}

/// Expand/collapse toggle for org-unit / business rows. Locations are
/// leaves so the toggle renders as a non-interactive spacer to keep
/// every row's horizontal layout consistent.
class _ToggleIcon extends StatelessWidget {
  const _ToggleIcon({
    required this.node,
    required this.isCollapsed,
    required this.onToggleCollapsed,
  });

  final InheritanceTreeNode node;
  final bool isCollapsed;
  final ValueChanged<String> onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    if (!node.hasChildren) {
      // Leaf — render a placeholder with the same footprint so
      // children align with rows that DO have a toggle.
      return const SizedBox(width: 28, height: 28);
    }
    return IconButton(
      key: Key('inheritance_tree_toggle_${node.scopeId}'),
      icon: Icon(
        isCollapsed ? Icons.chevron_right : Icons.expand_more,
        size: 18,
        color: AppColors.sunsetDark,
      ),
      tooltip: isCollapsed ? 'Expand' : 'Collapse',
      onPressed: () => onToggleCollapsed(node.scopeId),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }
}
