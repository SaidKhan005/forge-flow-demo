// Editorial Shelf home redesign (2026-07-11 Barrio Home Redesign V1).
// Plan: docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md
//
// Replaces the orbit-bubble hub COMPOSITION on the Barrio home screen.
// The `BarrioBubbleHub` widget itself stays on disk per the plan's
// reversal doctrine (hide-only, never delete); the home screen simply
// stops composing it.
//
// Layout (single vertical scroll, no horizontal scrolling, no tabs):
//   1. Caller-provided leading widgets (brand header, gated El Podio).
//   2. Forge & Flow hero card (the one product-category destination).
//   3. Four fixed-order category sections, each a 2-column 4:5 card
//      grid built by filtering on `BarrioDestination.category`.
//   4. 40px footer padding.
//
// Motion: a single one-time entrance (staggered fade + slide per
// element, ~280ms each). `MediaQuery.disableAnimations` skips the
// entrance entirely. No looping/ambient animation lives here.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../content/training/training_docs.dart';
import '../../routes/barrio_destination_visibility_resolver.dart';
import '../../routes/barrio_destinations.dart';
import '../../routes/barrio_preview_role.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_hero_card.dart';
import 'barrio_home_topic_card.dart';

/// One category shelf: operator-facing title + section accent +
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
const List<_ShelfSection> _kShelfSections = <_ShelfSection>[
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
    'Running the Numbers',
    BarrioCategory.numbersAndLabor,
    BarrioColors.accentJimTaylor,
  ),
  _ShelfSection(
    'Company & Compliance',
    BarrioCategory.companyAndCompliance,
    BarrioColors.accentHandbook,
  ),
];

/// The Editorial Shelf home composition.
///
/// Mirrors the retired hub's contract: destinations in, taps out via
/// [onDestinationTap] (the home screen wires `BarrioRouteMap.navigateTo`),
/// with B18 visibility resolved through [visibilityResolver] when the
/// production permission runtime is present, else the [previewRole]
/// tier. Not-visible destinations render at 0.38 opacity and are
/// non-interactive, exactly like the hub.
class BarrioHomeShelf extends StatefulWidget {
  final List<BarrioDestination> destinations;
  final ValueChanged<BarrioDestination> onDestinationTap;
  final BarrioPreviewRole previewRole;

  /// B18: production hook for the live permission system. When
  /// non-null, the resolver overrides the legacy
  /// `previewRole.isIntendedFor(dest)` decision per destination.
  final BarrioDestinationVisibilityResolver? visibilityResolver;

  /// Widgets rendered above the hero (brand header, gated El Podio
  /// pill). They scroll with the shelf and are not entrance-staggered
  /// here (the header owns its own one-shot entrance).
  final List<Widget> leading;

  const BarrioHomeShelf({
    super.key,
    required this.destinations,
    required this.onDestinationTap,
    this.previewRole = BarrioPreviewRole.admin,
    this.visibilityResolver,
    this.leading = const <Widget>[],
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
    final visible =
        widget.destinations.where((d) => d.showOnHomeHub).toList();
    final slivers = <Widget>[
      for (final leading in widget.leading)
        SliverToBoxAdapter(child: leading),
      ..._heroSlivers(visible),
    ];
    var slot = 1;
    for (final section in _kShelfSections) {
      final dests =
          visible.where((d) => d.category == section.category).toList();
      if (dests.isEmpty) continue;
      slivers.add(
        SliverToBoxAdapter(
          child: _reveal(
            slot,
            _SectionHeader(section: section, count: dests.length),
          ),
        ),
      );
      slivers.add(_sectionGrid(section, dests, slot));
      slot++;
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 40)));
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: BarrioHomeHeroCard(
              destination: hero,
              dimmed: !_isDestVisible(hero) && !hero.comingSoon,
              onTap: () => widget.onDestinationTap(hero),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _sectionGrid(
    _ShelfSection section,
    List<BarrioDestination> dests,
    int slot,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 4 / 5,
        children: [
          for (final dest in dests)
            _reveal(
              slot,
              BarrioHomeTopicCard(
                destination: dest,
                dimmed: !_isDestVisible(dest) && !dest.comingSoon,
                sectionCount: kBarrioTrainingDocs[dest.id]?.chapters.length,
                onTap: () => widget.onDestinationTap(dest),
              ),
            ),
        ],
      ),
    );
  }
}

/// Section header: accent tick + Playfair title + right-aligned honest
/// topic count. ~32px above, ~12px below.
class _SectionHeader extends StatelessWidget {
  final _ShelfSection section;
  final int count;

  const _SectionHeader({required this.section, required this.count});

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
          Text(
            count == 1 ? '1 topic' : '$count topics',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 12,
              color: BarrioColors.textMuted,
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
