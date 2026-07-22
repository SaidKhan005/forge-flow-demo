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
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../content/training/barrio_training_doc.dart';
import '../../content/training/training_docs.dart';
import '../../routes/barrio_destination_visibility_resolver.dart';
import '../../routes/barrio_destinations.dart';
import '../../routes/barrio_preview_role.dart';
import '../../services/barrio_reading_progress_service.dart';
import '../../services/barrio_reading_time.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_bubble.dart';
import 'barrio_home_destination_visuals.dart';

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

/// Quiet metadata zone under each bubble ("the app remembers you",
/// 2026-07-22): reading time, and honest read progress when at least
/// one card has been read. Sits below the 150px bubble zone so the
/// glow halos keep their full breathing room.
const double _kBubbleMetaHeight = 40.0;

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

  /// Local reading memory ("the app remembers you", 2026-07-22):
  /// drives the Continue Reading card and the honest per-manual
  /// progress rows. Null (the default) renders neither, so existing
  /// call sites and fresh installs look exactly like before.
  final BarrioReadingSnapshot? readingProgress;

  /// Tap handler for the Continue Reading card: deep-links into the
  /// manual at the remembered position. When null the card does not
  /// render (there is nowhere for it to go).
  final void Function(
    BarrioDestination destination,
    int chapterIndex,
    int unitInChapter,
  )? onContinueReading;

  const BarrioHomeShelf({
    super.key,
    required this.destinations,
    required this.onDestinationTap,
    this.previewRole = BarrioPreviewRole.admin,
    this.visibilityResolver,
    this.leading = const <Widget>[],
    this.bodyOverride,
    this.readingProgress,
    this.onContinueReading,
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
    final slivers = <Widget>[
      ..._continueReadingSlivers(visible),
      ..._heroSlivers(visible),
    ];
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

  /// The Continue Reading card at the top of the shelf ("the app
  /// remembers you", 2026-07-22). Renders ONLY when: something has
  /// actually been read (position + at least one read card recorded),
  /// the manual still exists on the shelf, a tap handler is wired, and
  /// the manual passes the same B18 visibility resolution as the
  /// bubbles (resolver first, preview-role fallback): a hidden manual
  /// never appears here.
  List<Widget> _continueReadingSlivers(List<BarrioDestination> visible) {
    final progress = widget.readingProgress;
    final onTap = widget.onContinueReading;
    final docId = progress?.lastDocId;
    final position = progress?.lastPosition;
    if (progress == null || onTap == null || docId == null ||
        position == null) {
      return const <Widget>[];
    }
    // No card unless at least one card of that manual was read.
    if (!(progress.readUnitIds[docId]?.isNotEmpty ?? false)) {
      return const <Widget>[];
    }
    final doc = kBarrioTrainingDocs[docId];
    if (doc == null || doc.chapters.isEmpty) return const <Widget>[];
    BarrioDestination? dest;
    for (final d in visible) {
      if (d.id == docId) {
        dest = d;
        break;
      }
    }
    if (dest == null || !_isDestVisible(dest)) return const <Widget>[];
    final chapterIndex =
        position.chapterIndex.clamp(0, doc.chapters.length - 1);
    final destination = dest;
    return <Widget>[
      SliverToBoxAdapter(
        child: _reveal(
          0,
          _ContinueReadingCard(
            destination: destination,
            chapterIndex: chapterIndex,
            chapterTitle: doc.chapters[chapterIndex].title,
            onTap: () {
              HapticFeedback.lightImpact();
              onTap(destination, chapterIndex, position.unitInChapter);
            },
          ),
        ),
      ),
    ];
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
  /// The bubble zone keeps its fixed 150px height so the glow halos
  /// never clip; a quiet metadata zone (reading time + honest read
  /// progress) sits below each bubble. Only the row scrolls
  /// horizontally, never the page.
  Widget _sectionBubbles(List<BarrioDestination> dests, int slot) {
    return SliverToBoxAdapter(
      child: _reveal(
        slot,
        SizedBox(
          height: _kSectionRowHeight + _kBubbleMetaHeight,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: dests.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final dest = dests[i];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: _kSectionRowHeight,
                    child: Center(
                      child: BarrioHomeOrbitBubble(
                        destination: dest,
                        diameter: _kBubbleDiameter,
                        dimmed: !_isDestVisible(dest) && !dest.comingSoon,
                        onTap: () => widget.onDestinationTap(dest),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _kBubbleDiameter + 8,
                    height: _kBubbleMetaHeight,
                    child: _bubbleMeta(dest),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Quiet under-bubble metadata for manuals: the reading-time estimate
  /// always, plus 'N of M cards read' + a thin progress bar ONLY once
  /// at least one card has been read (Metric Honesty: untouched manuals
  /// show no progress row at all; no phantom zeroes). Non-manual
  /// destinations render nothing here.
  Widget _bubbleMeta(BarrioDestination dest) {
    final doc = kBarrioTrainingDocs[dest.id];
    if (doc == null) return const SizedBox.shrink();
    final readIds = widget.readingProgress?.readUnitIds[dest.id];
    var readCount = 0;
    final totalCards = _cardCountOf(doc);
    if (readIds != null && readIds.isNotEmpty) {
      for (final chapter in doc.chapters) {
        for (final unit in chapter.units) {
          if (readIds.contains(unit.id)) readCount++;
        }
      }
    }
    return _BubbleMeta(
      minutes: BarrioReadingTime.docMinutes(doc),
      readCount: readCount,
      totalCards: totalCards,
      accent: barrioHomeAccentFor(dest.id),
    );
  }

  static int _cardCountOf(BarrioTrainingDoc doc) {
    var count = 0;
    for (final chapter in doc.chapters) {
      count += chapter.units.length;
    }
    return count;
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

/// The Continue Reading card: near-opaque dark card (same legibility
/// recipe as the search result rows, which sit over the same photo),
/// accent icon chip, and the honest position line
/// ('Pick up at Section N: Title').
class _ContinueReadingCard extends StatelessWidget {
  final BarrioDestination destination;
  final int chapterIndex;
  final String chapterTitle;
  final VoidCallback onTap;

  const _ContinueReadingCard({
    required this.destination,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = barrioHomeAccentFor(destination.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: BarrioColors.shellMid.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: 0.40)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: accent.withValues(alpha: 0.40)),
                ),
                child: Center(
                  child: barrioHomeIconWidgetFor(
                    context,
                    destination.id,
                    22,
                    accent,
                    false,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CONTINUE READING',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        color: accent.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      destination.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: BarrioColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Pick up at Section ${chapterIndex + 1}: $chapterTitle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 12,
                        color: BarrioColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: accent.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quiet under-bubble metadata: 'about N min' always; the read line +
/// thin bar only when [readCount] is at least 1 (no phantom zeroes).
class _BubbleMeta extends StatelessWidget {
  final int minutes;
  final int readCount;
  final int totalCards;
  final Color accent;

  const _BubbleMeta({
    required this.minutes,
    required this.readCount,
    required this.totalCards,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          BarrioReadingTime.label(minutes),
          maxLines: 1,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 9.5,
            color: BarrioColors.textMuted.withValues(alpha: 0.85),
          ),
        ),
        if (readCount >= 1 && totalCards > 0) ...[
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$readCount of $totalCards cards read',
              maxLines: 1,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 9.5,
                color: BarrioColors.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (readCount / totalCards).clamp(0.0, 1.0),
                minHeight: 2.5,
                backgroundColor: BarrioColors.shellSurface,
                valueColor: AlwaysStoppedAnimation(
                  accent.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ],
      ],
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
