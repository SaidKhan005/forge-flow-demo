// Barrio home revision (2026-07-11, operator decision): one-scroll
// round-bubble layout. Keeps the Editorial Shelf's single-vertical-
// scroll organization (Barrio Home Redesign V1, plan:
// docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md)
// but composes the parked orbit hub's round glass bubbles instead of
// the rectangular hero/topic cards (which stay on disk, hide-only).
//
// Layout (single vertical scroll, no horizontal scrolling, no tabs):
//   1. Caller-provided leading widgets (brand header, gated El Podio).
//   2. Forge & Flow as the hub's center bubble (160px, centered, with
//      the rotating arc + glow pulse + 'Dashboard' label).
//   3. Four fixed-order category sections, each rendering its
//      destinations as round hub-style bubbles, 3 per row with the last
//      partial row centered, built by filtering on
//      `BarrioDestination.category`.
//   4. 40px footer padding.
//
// Motion: a single one-time entrance (staggered fade + slide) plus the
// bubbles' own looping glow/arc effects (operator decision overriding
// the redesign plan's motion rule). `MediaQuery.disableAnimations`
// skips the entrance and freezes the bubble loops.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/barrio_destination_visibility_resolver.dart';
import '../../routes/barrio_destinations.dart';
import '../../routes/barrio_preview_role.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_bubble.dart';

/// One category section: operator-facing title + section accent +
/// category filter. Section membership is driven by the
/// `BarrioDestination.category` field, never by hardcoded id lists.
class _ShelfSection {
  final String title;
  final BarrioCategory category;
  final Color accent;

  const _ShelfSection(this.title, this.category, this.accent);
}

/// Fixed section order with the operator-facing titles and section
/// accents from the redesign plan's category model.
/// 2026-07-11 operator revision: Company & Compliance leads, and the
/// numbers section's display title is 'A Deeper Dive' (the
/// BarrioCategory.numbersAndLabor identifier is unchanged).
const List<_ShelfSection> _kShelfSections = <_ShelfSection>[
  _ShelfSection(
    'Company & Compliance',
    BarrioCategory.companyAndCompliance,
    BarrioColors.accentHandbook,
  ),
  _ShelfSection(
    'Service & Hospitality',
    BarrioCategory.serviceHospitality,
    BarrioColors.accentPlaybook,
  ),
  _ShelfSection(
    'Food & Drink',
    BarrioCategory.foodAndDrink,
    BarrioColors.gold,
  ),
  _ShelfSection(
    'A Deeper Dive',
    BarrioCategory.numbersAndLabor,
    BarrioColors.accentJimTaylor,
  ),
];

/// Center-bubble diameter (the hub's primary node was 150; the operator
/// spec allows 150-170 for the scrolling composition).
const double _kCenterBubbleDiameter = 160.0;

/// Section bubble diameter and swipe-row height (glow halos need the
/// extra vertical room so they never clip against the row bounds).
const double _kBubbleDiameter = 100.0;
const double _kSectionRowHeight = 150.0;

/// The one-scroll round-bubble home composition.
///
/// Mirrors the retired hub's contract: destinations in, taps out via
/// [onDestinationTap] (the home screen wires `BarrioRouteMap.navigateTo`),
/// with B18 visibility resolved through [visibilityResolver] when the
/// production permission runtime is present, else the [previewRole]
/// tier. Not-visible destinations render at 0.38 opacity and are
/// non-interactive, exactly like the hub (center bubble included).
class BarrioHomeShelf extends StatefulWidget {
  final List<BarrioDestination> destinations;
  final ValueChanged<BarrioDestination> onDestinationTap;
  final BarrioPreviewRole previewRole;

  /// B18: production hook for the live permission system. When
  /// non-null, the resolver overrides the legacy
  /// `previewRole.isIntendedFor(dest)` decision per destination.
  final BarrioDestinationVisibilityResolver? visibilityResolver;

  /// Widgets rendered above the center bubble (brand header, gated El
  /// Podio pill). They scroll with the shelf and are not
  /// entrance-staggered here (the header owns its own one-shot entrance).
  final List<Widget> leading;

  /// Wave B (training search): when non-null, this single sliver
  /// replaces the center bubble + category sections while a query is
  /// active. The [leading] widgets and footer padding stay, and the
  /// shelf state (entrance controller) is preserved, so clearing the
  /// override brings the sections back exactly as before with no
  /// entrance replay. Default null keeps the shelf unchanged.
  final Widget? bodyOverride;

  const BarrioHomeShelf({
    super.key,
    required this.destinations,
    required this.onDestinationTap,
    this.previewRole = BarrioPreviewRole.admin,
    this.visibilityResolver,
    this.leading = const <Widget>[],
    this.bodyOverride,
  });

  @override
  State<BarrioHomeShelf> createState() => _BarrioHomeShelfState();
}

class _BarrioHomeShelfState extends State<BarrioHomeShelf>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool _entranceDecided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceDecided) return;
    _entranceDecided = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Accessibility: skip the entrance entirely.
      _entrance.value = 1.0;
    } else {
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  bool _isDestVisible(BarrioDestination dest) {
    final resolver = widget.visibilityResolver;
    if (resolver != null) return resolver.isVisible(dest);
    return widget.previewRole.isIntendedFor(dest);
  }

  Widget _reveal(int slot, Widget child) {
    return _EntranceReveal(entrance: _entrance, slot: slot, child: child);
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(slivers: _buildSlivers());
  }

  List<Widget> _buildSlivers() {
    final slivers = <Widget>[
      for (final leading in widget.leading)
        SliverToBoxAdapter(child: leading),
    ];
    final override = widget.bodyOverride;
    if (override != null) {
      // Wave B: an active search replaces the center bubble + sections.
      slivers.add(override);
    } else {
      slivers.addAll(_shelfBodySlivers());
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 40)));
    return slivers;
  }

  List<Widget> _shelfBodySlivers() {
    final visible =
        widget.destinations.where((d) => d.showOnHomeHub).toList();
    final slivers = <Widget>[..._heroSlivers(visible)];
    var slot = 1;
    for (final section in _kShelfSections) {
      final dests =
          visible.where((d) => d.category == section.category).toList();
      if (dests.isEmpty) continue;
      slivers.add(
        SliverToBoxAdapter(
          child: _reveal(slot, _SectionHeader(section: section)),
        ),
      );
      slivers.add(_sectionBubbles(dests, slot));
      slot++;
    }
    return slivers;
  }

  List<Widget> _heroSlivers(List<BarrioDestination> visible) {
    final products =
        visible.where((d) => d.category == BarrioCategory.product).toList();
    if (products.isEmpty) return const <Widget>[];
    final hero = products.first;
    return <Widget>[
      SliverToBoxAdapter(
        child: _reveal(
          0,
          Padding(
            // Extra top room so the rotating arcs + glow halo have space
            // to breathe below the header.
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 8),
            child: Center(
              child: BarrioHomeCenterBubble(
                destination: hero,
                diameter: _kCenterBubbleDiameter,
                dimmed: !_isDestVisible(hero) && !hero.comingSoon,
                onTap: () => widget.onDestinationTap(hero),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// One section body: a single horizontal swipe row of bubbles
  /// (2026-07-11 operator decision: sections scroll left and right).
  /// Fixed row height leaves room above and below the 100px bubbles so
  /// their glow halos never clip; only the row scrolls horizontally,
  /// never the page.
  Widget _sectionBubbles(List<BarrioDestination> dests, int slot) {
    return SliverToBoxAdapter(
      child: _reveal(
        slot,
        SizedBox(
          height: _kSectionRowHeight,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: dests.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final dest = dests[i];
              return Center(
                child: BarrioHomeOrbitBubble(
                  destination: dest,
                  diameter: _kBubbleDiameter,
                  dimmed: !_isDestVisible(dest) && !dest.comingSoon,
                  onTap: () => widget.onDestinationTap(dest),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Section header: accent tick + Playfair title. ~32px above, ~12px
/// below. (The topic count was removed 2026-07-11 by operator request.)
class _SectionHeader extends StatelessWidget {
  final _ShelfSection section;

  const _SectionHeader({required this.section});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: section.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              section.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.playfairDisplay(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: BarrioColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One-time staggered entrance: fade + 14px upward slide over ~280ms,
/// offset ~117ms per slot. Once the parent controller completes (or is
/// jumped to 1.0 for `disableAnimations`), lazily-built slivers render
/// fully settled with no further rebuilds.
class _EntranceReveal extends StatelessWidget {
  final Animation<double> entrance;
  final int slot;
  final Widget child;

  const _EntranceReveal({
    required this.entrance,
    required this.slot,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final start = (slot * 0.13).clamp(0.0, 0.69);
    final end = (start + 0.31).clamp(0.0, 1.0);
    final curved = CurvedAnimation(
      parent: entrance,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, inner) => Transform.translate(
          offset: Offset(0, 14 * (1 - curved.value)),
          child: inner,
        ),
        child: child,
      ),
    );
  }
}
