// Editorial Shelf home redesign (2026-07-11 Barrio Home Redesign V1).
// Plan: docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md
//
// One training topic card in a 2-column category grid (4:5 aspect).
// Anatomy top to bottom: accent-tinted glass icon panel (~55%), 3px
// accent strip, destination label (Playfair, max 2 lines), and an
// honest metadata line ('<n> sections' from the verbatim training
// registry). Coming-soon destinations render flat dark glass at ~45%
// opacity with a 'COMING SOON' tag but KEEP their tap-through behavior.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/barrio_destinations.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_destination_visuals.dart';

/// A single destination card on the home shelf.
///
/// B18 dimming semantics match the retired bubble hub: when [dimmed] is
/// true (visibility resolver says not-visible) the card renders at 0.38
/// opacity and is fully non-interactive. Coming-soon cards render at
/// 0.45 opacity and stay tappable (they navigate to their placeholder
/// screen, same as the hub did).
class BarrioHomeTopicCard extends StatelessWidget {
  final BarrioDestination destination;
  final bool dimmed;
  final VoidCallback onTap;

  /// Honest chapter count from the verbatim training registry; null for
  /// destinations without a registry entry (e.g. coming-soon cards,
  /// which show the 'COMING SOON' tag instead).
  final int? sectionCount;

  const BarrioHomeTopicCard({
    super.key,
    required this.destination,
    required this.dimmed,
    required this.onTap,
    required this.sectionCount,
  });

  @override
  Widget build(BuildContext context) {
    Widget card = _glassBody();
    if (dimmed) {
      return Opacity(opacity: 0.38, child: card);
    }
    if (destination.comingSoon) {
      card = Opacity(opacity: 0.45, child: card);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: card,
    );
  }

  Widget _glassBody() {
    final accent = barrioHomeAccentFor(destination.id);
    final comingSoon = destination.comingSoon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(BarrioRadii.card),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0x30000000),
            borderRadius: BorderRadius.circular(BarrioRadii.card),
            border: Border.all(color: const Color(0x22FFFFFF), width: 1.0),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 55, child: _iconPanel(accent, comingSoon)),
              Container(
                height: 3,
                color: comingSoon ? const Color(0x26FFFFFF) : accent,
              ),
              Expanded(flex: 45, child: _infoArea()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconPanel(Color accent, bool comingSoon) {
    return Container(
      decoration: BoxDecoration(
        // Coming soon: flat dark glass, no accent tint.
        color: comingSoon ? const Color(0x1F000000) : null,
        gradient: comingSoon
            ? null
            : RadialGradient(
                center: const Alignment(0.0, 0.55),
                radius: 1.25,
                colors: [
                  accent.withValues(alpha: 0.34),
                  accent.withValues(alpha: 0.10),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
      ),
      child: Center(
        child: Icon(
          barrioHomeIconFor(destination.id),
          size: 34,
          color: comingSoon ? BarrioColors.textMuted : accent,
        ),
      ),
    );
  }

  Widget _infoArea() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              destination.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.playfairDisplay(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                height: 1.2,
                color: BarrioColors.textPrimary,
              ),
            ),
          ),
          _metaLine(),
        ],
      ),
    );
  }

  Widget _metaLine() {
    if (destination.comingSoon) {
      return Text(
        'COMING SOON',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: BarrioColors.gold,
        ),
      );
    }
    final count = sectionCount;
    if (count == null) {
      return const SizedBox.shrink();
    }
    return Text(
      count == 1 ? '1 section' : '$count sections',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.ibmPlexMono(
        fontSize: 11,
        color: BarrioColors.textMuted,
      ),
    );
  }
}
