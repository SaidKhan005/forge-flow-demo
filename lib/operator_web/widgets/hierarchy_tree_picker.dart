// Wave 2 RP-10 — Inline hierarchy-tree picker for invite + grant dialogs.
//
// HP #11 wants location / scope assignment in invite dialogs to mirror
// the org hierarchy, not a flat alphabetical dropdown. H-3 shipped a
// popover-shaped tree picker (`HierarchyMapPicker`) for the top bar;
// this widget is the inline, dialog-embedded sibling that callers mount
// directly inside a Column without an overlay wrapper.
//
// Behaviour:
//   * Single-node hierarchies auto-select on first build and collapse
//     to a confirmation row (no expand/collapse chrome). The dialog
//     then renders the picker as "Working at <name>" and the operator
//     never sees an interactive tree.
//   * Multi-node hierarchies render a scrollable tree inside a
//     fixed-height container so very tall hierarchies do not push the
//     submit button below the fold.
//   * Plain-English label + helper copy mirror the H-3 picker. No
//     `location_id` / engineering jargon surfaces.
//   * The picker stays a pure controlled component — selection state
//     lives in the parent dialog so a re-open after Cancel can rewire
//     the same `selectedId` and the operator sees their last pick.
//
// The widget reuses the H-3 `HierarchyMapTreeBody` for tree rendering
// so visual + interaction parity with the top-bar picker is automatic.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'hierarchy_map_picker.dart';

/// Inline hierarchy picker for invite + grant dialogs.
///
/// Renders a label, helper copy, and either the tree body (multi-node
/// hierarchies) or a confirmation row (single-node hierarchies). The
/// surrounding dialog owns the selection state and forwards it via
/// [selectedId] + [onSelected].
class HierarchyTreePicker extends StatefulWidget {
  const HierarchyTreePicker({
    super.key,
    required this.keyPrefix,
    required this.nodes,
    required this.selectedId,
    required this.onSelected,
    this.label = 'Choose where this person will work',
    this.helper =
        'Pick the location, region, or whole business. Higher levels '
        'include everything beneath.',
    this.allowNonLocationSelection = true,
    this.maxHeight = 240,
    this.errorText,
  });

  /// Stamped onto every internal widget key so multiple pickers on the
  /// same dialog do not collide (`keyPrefix + '_tree'`, `_node_<id>`).
  final String keyPrefix;

  /// Flat list of hierarchy nodes. Tree shape derived from
  /// [HierarchyMapNode.parentId]. Pass the same shape the H-3 top-bar
  /// picker consumes so visual parity is automatic.
  final List<HierarchyMapNode> nodes;

  /// Currently selected node id. The picker highlights the matching
  /// row + renders the confirmation row in single-node mode.
  final String? selectedId;

  /// Fired when the operator picks a row. Single-node mode fires this
  /// once during the first build so the dialog can pre-fill the form
  /// without an extra tap.
  final ValueChanged<HierarchyMapNode> onSelected;

  /// Label rendered above the tree. Title Case, plain English.
  final String label;

  /// Helper line rendered under the label. Keeps inheritance plain so
  /// operators understand selecting a region grants access to every
  /// location beneath it.
  final String helper;

  /// When `true`, tapping a business / orgUnit node also fires
  /// [onSelected]. When `false`, those rows toggle the branch only and
  /// the operator must drill to a location leaf before the dialog can
  /// submit. Invite dialogs pass `true` (the form accepts all three
  /// scopes per the 9.UX.4 wiring); grant dialogs may pass `false`.
  final bool allowNonLocationSelection;

  /// Cap on the tree's rendered height. Multi-node hierarchies scroll
  /// inside this height so the dialog's submit row stays visible.
  final double maxHeight;

  /// Optional plain-English validation message rendered under the
  /// picker. Pass `null` to skip; the dialog typically populates this
  /// on submit attempts that fail because of a missing scope pick.
  final String? errorText;

  @override
  State<HierarchyTreePicker> createState() => _HierarchyTreePickerState();
}

class _HierarchyTreePickerState extends State<HierarchyTreePicker> {
  @override
  void initState() {
    super.initState();
    _maybeAutoSelectSingleNode();
  }

  @override
  void didUpdateWidget(covariant HierarchyTreePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes != widget.nodes) {
      _maybeAutoSelectSingleNode();
    }
  }

  /// When the operator has exactly one location and no prior pick,
  /// auto-select the lone leaf on first build so the dialog can submit
  /// without an extra tap. The call is wrapped in
  /// `addPostFrameCallback` so the parent setState does not run during
  /// the picker's own build. The auto-select skips when the caller
  /// already passed a non-null [selectedId] — the parent dialog's
  /// pre-pick (e.g. an `initialScope` defaulting to operator-wide) is
  /// authoritative and must not be overwritten.
  void _maybeAutoSelectSingleNode() {
    if (widget.selectedId != null) return;
    final leaves = _locationLeaves();
    // Mirror the single-location collapse rule from build(): only
    // auto-select when the hierarchy is truly one node total. A
    // dataset containing a business / org-unit root alongside a lone
    // location still presents a real choice the operator must make.
    if (widget.nodes.length != 1 || leaves.length != 1) return;
    final leaf = leaves.single;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.selectedId != null) return;
      widget.onSelected(leaf);
    });
  }

  /// Returns the location leaves in the hierarchy. Used for the
  /// single-location collapse rule.
  List<HierarchyMapNode> _locationLeaves() {
    return widget.nodes
        .where((n) => n.kind == HierarchyMapNodeKind.location)
        .toList(growable: false);
  }

  HierarchyMapNode? get _selectedNode {
    final id = widget.selectedId;
    if (id == null) return null;
    for (final node in widget.nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final leaves = _locationLeaves();
    // Collapse to the confirmation row only when the picker has
    // exactly one node total and it is a location leaf. Hierarchies
    // that include a business / org-unit root alongside a single
    // location must keep the tree visible so the operator can pick
    // the broader scope. The single-row collapse is a UX nicety for
    // operators with truly one place to work, not a shortcut for
    // every dataset that happens to contain one location.
    final isSingleLocation =
        widget.nodes.length == 1 && leaves.length == 1;

    return Column(
      key: Key('${widget.keyPrefix}_root'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.label,
          key: Key('${widget.keyPrefix}_label'),
          style: AppTextStyles.body13(color: AppColors.textPrimary)
              .copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          widget.helper,
          key: Key('${widget.keyPrefix}_helper'),
          style: AppTextStyles.body12(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        if (widget.nodes.isEmpty)
          _EmptyState(
            key: Key('${widget.keyPrefix}_empty'),
            label: 'No locations available yet. Ask your admin to add one.',
          )
        else if (isSingleLocation)
          _SingleLocationRow(
            key: Key('${widget.keyPrefix}_single'),
            node: _selectedNode ?? leaves.single,
          )
        else
          Container(
            key: Key('${widget.keyPrefix}_tree_container'),
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.errorText == null
                    ? AppColors.borderSubtle
                    : AppColors.negative.withValues(alpha: 0.55),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: HierarchyMapTreeBody(
              key: Key('${widget.keyPrefix}_tree'),
              keyPrefix: widget.keyPrefix,
              nodes: widget.nodes,
              selectedId: widget.selectedId,
              onNodeTap: widget.onSelected,
              allowNonLocationSelection: widget.allowNonLocationSelection,
              maxHeight: widget.maxHeight,
            ),
          ),
        if (widget.errorText != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            widget.errorText!,
            key: Key('${widget.keyPrefix}_error'),
            style: AppTextStyles.body12(color: AppColors.negative),
          ),
        ],
      ],
    );
  }
}

/// Confirmation row rendered when the operator has exactly one
/// location. Mirrors a read-only "Working at Downtown" line so the
/// operator sees what the invite will land on without an interactive
/// tree they cannot use anyway.
class _SingleLocationRow extends StatelessWidget {
  const _SingleLocationRow({super.key, required this.node});

  final HierarchyMapNode node;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.sunset.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.place_outlined,
            size: 16,
            color: AppColors.sunsetDark,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Working at ${node.label}',
                  style: AppTextStyles.body13(color: AppColors.textPrimary)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                if (node.helper.isNotEmpty)
                  Text(
                    node.helper,
                    style: AppTextStyles.body12(color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
          const Icon(
            Icons.check_circle,
            size: 16,
            color: AppColors.sunsetDark,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.5),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: AppTextStyles.body13(color: AppColors.textMuted),
      ),
    );
  }
}

/// Helper for callers: project a flat list of locations (+ optional
/// org-units + a business root) into the [HierarchyMapNode] shape the
/// picker consumes. Centralised here so invite dialogs do not each
/// re-implement the same plumbing.
List<HierarchyMapNode> buildInviteHierarchyNodes({
  required String businessId,
  required String businessLabel,
  required List<({String orgUnitId, String name, String? parentOrgUnitId})>
      orgUnits,
  required List<({String locationId, String name, String? orgUnitId})> locations,
}) {
  final nodes = <HierarchyMapNode>[
    HierarchyMapNode(
      id: 'business:$businessId',
      label: businessLabel,
      helper: 'Whole business',
      kind: HierarchyMapNodeKind.business,
      inheritanceBreadcrumb:
          'Granting at this level covers every region and location.',
    ),
    for (final unit in orgUnits)
      HierarchyMapNode(
        id: 'org_unit:${unit.orgUnitId}',
        label: unit.name,
        helper: 'Region or group',
        kind: HierarchyMapNodeKind.orgUnit,
        parentId: unit.parentOrgUnitId == null
            ? 'business:$businessId'
            : 'org_unit:${unit.parentOrgUnitId}',
        inheritanceBreadcrumb:
            'Locations under this region inherit access granted here.',
      ),
    for (final loc in locations)
      HierarchyMapNode(
        id: 'location:${loc.locationId}',
        label: loc.name,
        helper: 'Location',
        kind: HierarchyMapNodeKind.location,
        parentId: loc.orgUnitId == null
            ? 'business:$businessId'
            : 'org_unit:${loc.orgUnitId}',
      ),
  ];
  return nodes;
}
