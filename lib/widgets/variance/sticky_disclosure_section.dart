// Variance Coaching V2 — shared sticky disclosure section.
//
// Promoted verbatim from the previously PRIVATE
// `_StickyDisclosureSection` in
// lib/screens/variance/variance_this_week_tab.dart (GAP 2 / GAP 3 +
// drift fix E). Moved to a shared public widget so the Variance "This
// Week" tab AND the History "open a past week" detail screen render the
// SAME single-source disclosure and cannot drift apart again. Behaviour,
// layout, the `InkWell` toggle structure, the pinned
// `StickyDisclosureHeaderDelegate`, the optional pinned
// `StickyColumnHeaderDelegate`, and the trailing 24px spacer are all
// byte-identical to the original private widget.

import 'package:flutter/material.dart';

import '../sticky_section_delegate.dart';

/// GAP 2 / GAP 3 + drift fix (E) — a default-collapsed disclosure
/// section whose SINGLE header IS the section title + the expand
/// toggle (mockup `<summary>Week to date vs plan ›</summary>`). It
/// emits a [SliverMainAxisGroup] so it drops straight into a flat
/// sliver list.
///
/// There is exactly ONE title element: the pinned
/// [StickyDisclosureHeaderDelegate]. While collapsed it still behaves
/// like a pinned section header you can expand; the separate duplicate
/// pinned `StickySectionDelegate` title (and the old inner `summary`
/// row) are gone — no repetition.
///
/// The wrapped child (`_WtdTable` / `DollarImpactCard` /
/// `_GroupedSummaryTable`) is byte-preserved — this widget only
/// shows/hides it; it never alters the content, the numbers, or their
/// sentiment. When [showColumnHeader] is true (a variance table) the
/// TARGET/ACTUAL/VAR [StickyColumnHeaderDelegate] pins directly under
/// the title while expanded, exactly as before.
class StickyDisclosureSection extends StatefulWidget {
  final String title;
  final Widget child;
  final bool showColumnHeader;
  const StickyDisclosureSection({
    super.key,
    required this.title,
    required this.child,
    this.showColumnHeader = false,
  });

  @override
  State<StickyDisclosureSection> createState() =>
      _StickyDisclosureSectionState();
}

class _StickyDisclosureSectionState extends State<StickyDisclosureSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: [
        // The ONE title element: pinned while collapsed (reads as a
        // sticky section header), and is itself the expand toggle.
        SliverPersistentHeader(
          pinned: true,
          delegate: StickyDisclosureHeaderDelegate(
            label: widget.title,
            expanded: _expanded,
            onTap: () => setState(() => _expanded = !_expanded),
          ),
        ),
        // TARGET/ACTUAL/VAR column header pins under the title while
        // the table is expanded (unchanged behaviour).
        if (_expanded && widget.showColumnHeader)
          const SliverPersistentHeader(
            pinned: true,
            delegate: StickyColumnHeaderDelegate(),
          ),
        // Default collapsed: the byte-preserved child is only built
        // when expanded.
        if (_expanded) SliverToBoxAdapter(child: widget.child),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}
