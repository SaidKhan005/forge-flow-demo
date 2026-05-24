// Wave 2 H-3 — Hierarchy-map picker for the operator-web + admin top bars.
//
// The slice replaces the flat-list `DropdownButton` location selector
// with a tree-shaped popover that mirrors the org hierarchy (Business →
// Region → Brand → Location) so operators can navigate by structure,
// not by alphabetical name. HP #11 alignment:
//
//   * Plain-English labels. No `location_id=…`, no `scope_id=…`.
//   * Selected scope is highlighted in the trigger button + inside the
//     popover tree so the operator always sees what they are managing.
//   * Inheritance breadcrumb shows beside non-Location nodes ("All
//     locations inherit business-wide settings"). The trigger button
//     itself shows the scope-kind helper ("Region" / "Location" / "All
//     locations") under the selected label so the operator never has to
//     open the picker to remember which level they are managing.
//   * Branches the actor lacks access to render disabled with a tooltip
//     so the operator never sees a silent omission. The current data
//     layer (`WebTeamHierarchyGateway`) projects only the actor's
//     visible scopes, so the disabled-branch rendering is wired but
//     only triggers when a future gateway projects forbidden branches
//     alongside the visible ones. This widget is forward-compatible so
//     the future surface lights up without re-shaping the picker.
//
// The widget is intentionally generic on its node shape (`HierarchyMapNode`)
// so the operator-web shell and the admin console can share the same
// picker even though their scope models live in different files
// (`OperatorWebManagementScopeOption` vs `AdminHierarchyScopeIntent`).
// Each console maps its own scope catalog to `HierarchyMapNode` once at
// the call site.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';

/// One node in the hierarchy tree the picker renders.
///
/// Nodes form a parent / child graph keyed by [id]; the picker derives
/// the tree shape from [parentId]. Pass a flat list — the picker walks
/// the structure internally so callers do not pre-shape the data.
@immutable
class HierarchyMapNode {
  const HierarchyMapNode({
    required this.id,
    required this.label,
    required this.helper,
    required this.kind,
    this.parentId,
    this.disabled = false,
    this.disabledReason,
    this.inheritanceBreadcrumb,
    this.statusChips = const <String>[],
  });

  /// Stable identifier the caller maps back to its scope catalog.
  /// Doubles as the test-key suffix the picker stamps on each row.
  final String id;

  /// Plain-English label shown on the trigger + inside the tree
  /// (e.g. "Pizza Express — Toronto downtown", "East Region").
  final String label;

  /// Short scope-kind helper rendered under the label
  /// (e.g. "Business-wide" / "Region" / "Location"). Helps the operator
  /// distinguish two same-named rows at different levels.
  final String helper;

  /// Hierarchy kind the node represents. The picker maps this to the
  /// icon + selection rules: only [HierarchyMapNodeKind.location] (and
  /// optionally [HierarchyMapNodeKind.business] / `orgUnit` when
  /// `allowNonLocationSelection` is set) close the popover when tapped.
  final HierarchyMapNodeKind kind;

  /// `null` for roots (business / top-level org unit). Children point
  /// to their parent's [id]; the picker groups + renders accordingly.
  final String? parentId;

  /// When `true`, the row renders disabled + non-tappable. Use for
  /// branches the actor lacks access to so the operator sees them
  /// explicitly instead of a silent omission (HP #11).
  final bool disabled;

  /// Tooltip explaining why the row is disabled. Rendered as a tooltip
  /// over the disabled row + as the helper line for the screen reader.
  /// Pass plain English ("You don't have access to this region — ask
  /// your admin"); no engineering jargon.
  final String? disabledReason;

  /// Plain-English inheritance breadcrumb shown when the row is
  /// non-location and is selected (e.g. "Inherits business-wide
  /// defaults" / "Locations under East Region inherit region timing").
  /// Optional — pass `null` to skip the breadcrumb row.
  final String? inheritanceBreadcrumb;

  /// Optional plain-English status chips rendered under the label
  /// (e.g. "Set at this scope" / "Inherited from business" /
  /// "Effective: Business default"). Empty list skips chip rendering.
  /// Callers should keep the labels short — long chips truncate.
  final List<String> statusChips;
}

/// Hierarchy kind a node represents.
enum HierarchyMapNodeKind { business, orgUnit, location }

/// Reusable hierarchy-map picker. Renders a trigger button with the
/// current selection summary; tapping the trigger opens a popover with
/// a search field + hierarchical tree.
class HierarchyMapPicker extends StatefulWidget {
  const HierarchyMapPicker({
    super.key,
    required this.keyPrefix,
    required this.nodes,
    required this.selectedId,
    required this.onSelected,
    this.loading = false,
    this.error,
    this.triggerLabelPrefix = 'Managing',
    this.allowNonLocationSelection = true,
    this.popoverWidth = 320,
    this.popoverMaxHeight = 420,
    this.popoverOffsetY = 44,
    this.largeTrigger = false,
    this.triggerKey,
    this.nodeKeyResolver,
  });

  /// Stamped onto every internal widget key so two pickers on the same
  /// screen do not collide (`keyPrefix + '_trigger'`, `_search_field`,
  /// `_node_<id>`).
  final String keyPrefix;

  /// Flat list of nodes. Tree shape derived from [HierarchyMapNode.parentId].
  final List<HierarchyMapNode> nodes;

  /// Currently selected node id. The picker highlights the matching
  /// row + renders its label in the trigger button.
  final String? selectedId;

  /// Fired when the operator picks a row. The picker closes the popover
  /// automatically for [HierarchyMapNodeKind.location] selections
  /// (and for non-location selections when [allowNonLocationSelection]
  /// is `true`); otherwise the popover stays open so the operator can
  /// drill further into a region / brand they tapped to expand.
  final ValueChanged<HierarchyMapNode> onSelected;

  /// When `true`, the trigger renders a quiet loading indicator and the
  /// popover (if open) shows a "Loading hierarchy" placeholder. The
  /// caller pre-populates [nodes] with whatever it has cached so the
  /// operator sees something while the fresh fetch runs.
  final bool loading;

  /// Plain-English error message when the hierarchy fetch failed.
  /// Rendered inside the trigger tooltip + at the top of the popover.
  /// Pass `null` to skip the error chrome.
  final String? error;

  /// Verb shown before the selected label in the trigger button — the
  /// operator-web header uses "Managing"; the admin console may pass
  /// "Scope" for the scope-prompt analogue.
  final String triggerLabelPrefix;

  /// When `true`, tapping a business / orgUnit node closes the popover
  /// and fires [onSelected] with that node. When `false`, those taps
  /// only expand / collapse the branch and the popover stays open until
  /// a Location is picked. Operator-web sets `true` (the screens that
  /// need a location forward to a "Choose a location" surface); admin
  /// scope screens pass `true` because their scope model accepts all
  /// three kinds.
  final bool allowNonLocationSelection;

  /// Popover width in logical pixels. Defaults to 320 — wide enough for
  /// a two-line row + chevron.
  final double popoverWidth;

  /// Popover height cap. The tree scrolls inside this height.
  final double popoverMaxHeight;

  /// Vertical offset from the trigger to the popover. The compact
  /// header picker uses 44px; Operator Web's larger scope banner uses
  /// a taller offset so the popover starts below the full tile.
  final double popoverOffsetY;

  /// Renders the trigger as a larger scope banner. Defaults to false
  /// so existing compact admin/operator uses keep their footprint.
  final bool largeTrigger;

  /// Optional override for the trigger-button widget key. Defaults to
  /// `<keyPrefix>_trigger`; callers pass this when an existing test
  /// surface (e.g. `operator_web_management_scope_picker`) needs to keep
  /// pointing at the new trigger after the H-3 refactor.
  final Key? triggerKey;

  /// Optional resolver that returns a custom widget key for a given
  /// node id. The picker stamps the returned key on the node row's
  /// InkWell (so existing tests that tap a legacy key still work).
  /// Return `null` to fall back to the default
  /// `<keyPrefix>_node_<id>` key.
  final Key? Function(String nodeId)? nodeKeyResolver;

  @override
  State<HierarchyMapPicker> createState() => _HierarchyMapPickerState();
}

class _HierarchyMapPickerState extends State<HierarchyMapPicker> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _collapsed = <String>{};

  @override
  void dispose() {
    // Remove the overlay entry directly (skip the setState in `_close`
    // because the widget is already being unmounted). Wrapping the
    // remove in a try / catch protects against the overlay being torn
    // down ahead of the picker during test teardown.
    final entry = _overlayEntry;
    _overlayEntry = null;
    if (entry != null) {
      try {
        entry.remove();
      } catch (_) {
        // Overlay already gone — nothing to clean up.
      }
    }
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HierarchyMapPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the node list changes while the popover is open, rebuild the
    // overlay so the operator sees the latest tree.
    if (_overlayEntry != null && oldWidget.nodes != widget.nodes) {
      _overlayEntry!.markNeedsBuild();
    }
  }

  HierarchyMapNode? get _selectedNode {
    final id = widget.selectedId;
    if (id == null) return null;
    for (final node in widget.nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  void _toggleOverlay() {
    if (_overlayEntry == null) {
      _open();
    } else {
      _close();
    }
  }

  void _open() {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _searchController.text = '';
    _searchQuery = '';
    final entry = OverlayEntry(builder: _buildOverlay);
    _overlayEntry = entry;
    overlay.insert(entry);
    setState(() {});
  }

  void _close() {
    final entry = _overlayEntry;
    if (entry == null) return;
    _overlayEntry = null;
    entry.remove();
    if (mounted) setState(() {});
  }

  void _handleNodeTap(HierarchyMapNode node) {
    if (node.disabled) return;
    final closes =
        node.kind == HierarchyMapNodeKind.location ||
        widget.allowNonLocationSelection;
    widget.onSelected(node);
    if (closes) {
      _close();
    } else {
      // Non-location tap with allowNonLocationSelection=false toggles
      // the branch instead of selecting it.
      setState(() {
        if (!_collapsed.add(node.id)) {
          _collapsed.remove(node.id);
        }
      });
      _overlayEntry?.markNeedsBuild();
    }
  }

  void _toggleBranch(String id) {
    setState(() {
      if (!_collapsed.add(id)) {
        _collapsed.remove(id);
      }
    });
    _overlayEntry?.markNeedsBuild();
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    return Stack(
      children: <Widget>[
        // Dismissal scrim — taps outside the popover close it.
        Positioned.fill(
          child: GestureDetector(
            key: Key('${widget.keyPrefix}_dismiss_scrim'),
            behavior: HitTestBehavior.opaque,
            onTap: _close,
            child: const SizedBox.shrink(),
          ),
        ),
        Positioned(
          width: widget.popoverWidth,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: Offset(0, widget.popoverOffsetY),
            child: Material(
              key: Key('${widget.keyPrefix}_popover'),
              color: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(maxHeight: widget.popoverMaxHeight),
                decoration: BoxDecoration(
                  color: AppColors.backgroundSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: AppColors.textPrimary.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: _PopoverBody(
                  keyPrefix: widget.keyPrefix,
                  nodes: widget.nodes,
                  selectedId: widget.selectedId,
                  searchController: _searchController,
                  searchQuery: _searchQuery,
                  onSearchChanged: (value) {
                    setState(() => _searchQuery = value);
                    _overlayEntry?.markNeedsBuild();
                  },
                  collapsed: _collapsed,
                  onToggleBranch: _toggleBranch,
                  onNodeTap: _handleNodeTap,
                  loading: widget.loading,
                  error: widget.error,
                  nodeKeyResolver: widget.nodeKeyResolver,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedNode;
    final selectedLabel = selected?.label ?? 'Choose scope';
    final selectedHelper = selected?.helper ?? '';
    final isOpen = _overlayEntry != null;
    final borderColor = widget.error == null
        ? (isOpen
              ? AppColors.sunsetDark.withValues(alpha: 0.62)
              : AppColors.borderSubtle)
        : AppColors.negative.withValues(alpha: 0.55);
    final tooltipMessage = widget.error == null
        ? 'Choose the business, group, or location you are managing. '
              'The picker mirrors your org hierarchy so you can navigate '
              'by structure.'
        : '${widget.error} Showing the safest available context.';
    final triggerRadius = widget.largeTrigger ? 8.0 : 6.0;
    final triggerPadding = widget.largeTrigger
        ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 4);
    final triggerMinHeight = widget.largeTrigger ? 68.0 : 42.0;
    final iconSize = widget.largeTrigger ? 20.0 : 16.0;
    return CompositedTransformTarget(
      link: _layerLink,
      child: Tooltip(
        message: tooltipMessage,
        waitDuration: const Duration(milliseconds: 600),
        child: Material(
          key: Key('${widget.keyPrefix}_trigger_container'),
          color: AppColors.backgroundSurface.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(triggerRadius),
          child: InkWell(
            key: widget.triggerKey ?? Key('${widget.keyPrefix}_trigger'),
            borderRadius: BorderRadius.circular(triggerRadius),
            onTap: widget.loading && widget.nodes.isEmpty
                ? null
                : _toggleOverlay,
            child: Container(
              constraints: BoxConstraints(minHeight: triggerMinHeight),
              padding: triggerPadding,
              decoration: BoxDecoration(
                border: Border.all(color: borderColor, width: 1),
                borderRadius: BorderRadius.circular(triggerRadius),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    _iconForKind(selected?.kind),
                    size: iconSize,
                    color: AppColors.sunsetDark,
                  ),
                  SizedBox(width: widget.largeTrigger ? 12 : 8),
                  if (!widget.largeTrigger) ...<Widget>[
                    Text(
                      widget.triggerLabelPrefix,
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (widget.largeTrigger) ...<Widget>[
                          Text(
                            widget.triggerLabelPrefix,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: AppTextStyles.mono8(
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 2),
                        ],
                        Text(
                          selectedLabel,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: widget.largeTrigger
                              ? AppTextStyles.display16(
                                  color: AppColors.textPrimary,
                                )
                              : AppTextStyles.body13(
                                  color: AppColors.textPrimary,
                                ),
                        ),
                        if (selectedHelper.isNotEmpty)
                          Text(
                            selectedHelper,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: widget.largeTrigger
                                ? AppTextStyles.body12(
                                    color: AppColors.textSecondary,
                                  )
                                : AppTextStyles.mono8(
                                    color: AppColors.textMuted,
                                  ),
                          ),
                      ],
                    ),
                  ),
                  if (widget.loading)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.sunsetDark,
                        ),
                      ),
                    )
                  else
                    Icon(
                      isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static IconData _iconForKind(HierarchyMapNodeKind? kind) =>
      _hierarchyMapScopeIcon(kind);
}

/// Canonical glyph for a [HierarchyMapNodeKind]. A null kind falls back
/// to the generic org-unit glyph. Routes through the single source of
/// truth at lib/theme/scope_icons.dart so this picker stays in lockstep
/// with every other hierarchy surface.
IconData _hierarchyMapScopeIcon(HierarchyMapNodeKind? kind) {
  switch (kind) {
    case HierarchyMapNodeKind.business:
      return scopeIcon(kind: ScopeEntityKind.business);
    case HierarchyMapNodeKind.location:
      return scopeIcon(kind: ScopeEntityKind.location);
    case HierarchyMapNodeKind.orgUnit:
    case null:
      return scopeIcon(kind: ScopeEntityKind.orgUnit);
  }
}

/// Tree body used inside the popover. Exposed publicly so callers
/// (the admin scope-prompt at `lib/admin/widgets/admin_hierarchy_scope_prompt.dart`)
/// can embed the tree inline without a popover wrapper when the
/// hierarchy is the screen's primary surface.
class HierarchyMapTreeBody extends StatefulWidget {
  const HierarchyMapTreeBody({
    super.key,
    required this.keyPrefix,
    required this.nodes,
    required this.selectedId,
    required this.onNodeTap,
    this.allowNonLocationSelection = true,
    this.loading = false,
    this.error,
    this.maxHeight = 360,
    this.nodeKeyResolver,
  });

  final String keyPrefix;
  final List<HierarchyMapNode> nodes;
  final String? selectedId;
  final ValueChanged<HierarchyMapNode> onNodeTap;
  final bool allowNonLocationSelection;
  final bool loading;
  final String? error;
  final double maxHeight;
  final Key? Function(String nodeId)? nodeKeyResolver;

  @override
  State<HierarchyMapTreeBody> createState() => _HierarchyMapTreeBodyState();
}

class _HierarchyMapTreeBodyState extends State<HierarchyMapTreeBody> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _collapsed = <String>{};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleBranch(String id) {
    setState(() {
      if (!_collapsed.add(id)) {
        _collapsed.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: _PopoverBody(
        keyPrefix: widget.keyPrefix,
        nodes: widget.nodes,
        selectedId: widget.selectedId,
        searchController: _searchController,
        searchQuery: _searchQuery,
        onSearchChanged: (value) => setState(() => _searchQuery = value),
        collapsed: _collapsed,
        onToggleBranch: _toggleBranch,
        onNodeTap: (node) {
          if (node.disabled) return;
          final closes =
              node.kind == HierarchyMapNodeKind.location ||
              widget.allowNonLocationSelection;
          widget.onNodeTap(node);
          if (!closes) _toggleBranch(node.id);
        },
        loading: widget.loading,
        error: widget.error,
        nodeKeyResolver: widget.nodeKeyResolver,
      ),
    );
  }
}

class _PopoverBody extends StatelessWidget {
  const _PopoverBody({
    required this.keyPrefix,
    required this.nodes,
    required this.selectedId,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.collapsed,
    required this.onToggleBranch,
    required this.onNodeTap,
    required this.loading,
    required this.error,
    required this.nodeKeyResolver,
  });

  final String keyPrefix;
  final List<HierarchyMapNode> nodes;
  final String? selectedId;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final Set<String> collapsed;
  final ValueChanged<String> onToggleBranch;
  final ValueChanged<HierarchyMapNode> onNodeTap;
  final bool loading;
  final String? error;
  final Key? Function(String nodeId)? nodeKeyResolver;

  @override
  Widget build(BuildContext context) {
    final query = searchQuery.trim().toLowerCase();
    final visibleByMatch = _resolveVisible(nodes, query);
    final byParent = <String?, List<HierarchyMapNode>>{};
    for (final node in nodes) {
      byParent.putIfAbsent(node.parentId, () => <HierarchyMapNode>[]).add(node);
    }
    for (final entry in byParent.entries) {
      entry.value.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
    }
    final roots = byParent[null] ?? const <HierarchyMapNode>[];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (error != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                error!,
                style: AppTextStyles.body12(color: AppColors.negative),
                key: Key('${keyPrefix}_error'),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              key: Key('${keyPrefix}_search_field'),
              controller: searchController,
              onChanged: onSearchChanged,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                hintText: 'Search by name',
                hintStyle: AppTextStyles.body13(color: AppColors.textMuted),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.borderSubtle,
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.borderSubtle,
                    width: 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.sunsetDark,
                    width: 1,
                  ),
                ),
              ),
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
          Flexible(
            child: nodes.isEmpty
                ? _EmptyState(
                    key: Key('${keyPrefix}_empty'),
                    label: loading
                        ? 'Loading hierarchy…'
                        : 'No hierarchy available yet.',
                  )
                : visibleByMatch.isEmpty
                ? _EmptyState(
                    key: Key('${keyPrefix}_no_match'),
                    label: 'No matches for "$searchQuery".',
                  )
                : SingleChildScrollView(
                    key: Key('${keyPrefix}_scroll'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final root in roots)
                          if (visibleByMatch.contains(root.id))
                            _NodeRow(
                              keyPrefix: keyPrefix,
                              node: root,
                              depth: 0,
                              selectedId: selectedId,
                              byParent: byParent,
                              visible: visibleByMatch,
                              collapsed: collapsed,
                              query: query,
                              onToggleBranch: onToggleBranch,
                              onNodeTap: onNodeTap,
                              nodeKeyResolver: nodeKeyResolver,
                            ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Returns the set of node ids that should render given [query].
  /// A node renders if its label matches the query OR any descendant
  /// matches (so ancestors stay visible as breadcrumbs). When the query
  /// is empty every node renders.
  static Set<String> _resolveVisible(
    List<HierarchyMapNode> nodes,
    String query,
  ) {
    if (query.isEmpty) {
      return nodes.map((n) => n.id).toSet();
    }
    final matches = <String>{};
    final childrenByParent = <String, List<String>>{};
    final byId = <String, HierarchyMapNode>{};
    for (final node in nodes) {
      byId[node.id] = node;
      final parent = node.parentId;
      if (parent != null) {
        childrenByParent.putIfAbsent(parent, () => <String>[]).add(node.id);
      }
    }
    for (final node in nodes) {
      if (node.label.toLowerCase().contains(query)) {
        matches.add(node.id);
        // Pull ancestors in so the operator sees the path.
        var parentId = node.parentId;
        while (parentId != null && matches.add(parentId)) {
          parentId = byId[parentId]?.parentId;
        }
        // Pull descendants in so the operator can drill into the
        // matched branch.
        final queue = <String>[node.id];
        while (queue.isNotEmpty) {
          final next = queue.removeLast();
          final children = childrenByParent[next] ?? const <String>[];
          for (final child in children) {
            if (matches.add(child)) queue.add(child);
          }
        }
      }
    }
    return matches;
  }
}

class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.keyPrefix,
    required this.node,
    required this.depth,
    required this.selectedId,
    required this.byParent,
    required this.visible,
    required this.collapsed,
    required this.query,
    required this.onToggleBranch,
    required this.onNodeTap,
    required this.nodeKeyResolver,
  });

  final String keyPrefix;
  final HierarchyMapNode node;
  final int depth;
  final String? selectedId;
  final Map<String?, List<HierarchyMapNode>> byParent;
  final Set<String> visible;
  final Set<String> collapsed;
  final String query;
  final ValueChanged<String> onToggleBranch;
  final ValueChanged<HierarchyMapNode> onNodeTap;
  final Key? Function(String nodeId)? nodeKeyResolver;

  @override
  Widget build(BuildContext context) {
    final children = (byParent[node.id] ?? const <HierarchyMapNode>[])
        .where((child) => visible.contains(child.id))
        .toList(growable: false);
    final hasChildren = children.isNotEmpty;
    final isCollapsed = collapsed.contains(node.id) && query.isEmpty;
    final isSelected = node.id == selectedId;
    final disabled = node.disabled;
    final indent = depth * 14.0;
    final rowKey =
        nodeKeyResolver?.call(node.id) ??
        Key('${keyPrefix}_node_${_nodeKeySegment(node.id)}');
    final highlightColor = isSelected
        ? AppColors.sunset.withValues(alpha: 0.12)
        : Colors.transparent;
    final foreground = disabled
        ? AppColors.textMuted
        : (isSelected ? AppColors.textPrimary : AppColors.textSecondary);

    final rowChild = Padding(
      padding: EdgeInsets.only(left: indent, top: depth == 0 ? 0 : 2),
      child: Material(
        color: highlightColor,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: rowKey,
          borderRadius: BorderRadius.circular(6),
          onTap: disabled ? null : () => onNodeTap(node),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isSelected
                    ? AppColors.sunset.withValues(alpha: 0.55)
                    : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              children: <Widget>[
                IconButton(
                  key: Key(
                    '${keyPrefix}_node_${_nodeKeySegment(node.id)}_toggle',
                  ),
                  icon: Icon(
                    hasChildren
                        ? (isCollapsed
                              ? Icons.chevron_right
                              : Icons.expand_more)
                        : Icons.remove,
                    size: 16,
                    color: hasChildren
                        ? AppColors.sunsetDark
                        : AppColors.borderSubtle,
                  ),
                  tooltip: hasChildren
                      ? (isCollapsed ? 'Expand' : 'Collapse')
                      : 'No children',
                  onPressed: hasChildren ? () => onToggleBranch(node.id) : null,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 22,
                    minHeight: 22,
                  ),
                ),
                Icon(
                  _iconForKind(node.kind),
                  size: 16,
                  color: isSelected
                      ? AppColors.sunsetDark
                      : (disabled
                            ? AppColors.textMuted
                            : AppColors.textSecondary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        node.label,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: AppTextStyles.body13(color: foreground).copyWith(
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      Text(
                        node.helper,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: AppTextStyles.mono8(color: AppColors.textMuted),
                      ),
                      if (node.statusChips.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: <Widget>[
                              for (final chip in node.statusChips)
                                _NodeStatusChip(label: chip),
                            ],
                          ),
                        ),
                      if (isSelected && node.inheritanceBreadcrumb != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            node.inheritanceBreadcrumb!,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                            style: AppTextStyles.body12(
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (isSelected)
                  const Icon(
                    Icons.check_circle,
                    size: 14,
                    color: AppColors.sunsetDark,
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final wrappedRow = disabled
        ? Tooltip(
            message:
                node.disabledReason ??
                'You do not have access to this branch. Ask your admin '
                    'if you need it.',
            child: rowChild,
          )
        : rowChild;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        wrappedRow,
        if (hasChildren && !isCollapsed)
          for (final child in children)
            _NodeRow(
              keyPrefix: keyPrefix,
              node: child,
              depth: depth + 1,
              selectedId: selectedId,
              byParent: byParent,
              visible: visible,
              collapsed: collapsed,
              query: query,
              onToggleBranch: onToggleBranch,
              onNodeTap: onNodeTap,
              nodeKeyResolver: nodeKeyResolver,
            ),
      ],
    );
  }

  static IconData _iconForKind(HierarchyMapNodeKind kind) =>
      _hierarchyMapScopeIcon(kind);
}

class _NodeStatusChip extends StatelessWidget {
  const _NodeStatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.82),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: AppTextStyles.chipLabel(color: AppColors.textSecondary),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 24, 14, 24),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: AppTextStyles.body13(color: AppColors.textMuted),
      ),
    );
  }
}

String _nodeKeySegment(String id) => id
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');
