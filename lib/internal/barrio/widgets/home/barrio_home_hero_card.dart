// Editorial Shelf home redesign (2026-07-11 Barrio Home Redesign V1).
// Plan: docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md
//
// The Forge & Flow product hero: full width minus the 20px shelf
// margins, 16:9, 24px corner radius, and the strongest glass treatment
// on the page (in-card BackdropFilter blur + 1px light rim + the
// Forge & Flow accent glow). The entire card is one tap target for the
// `forge_and_flow` destination.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/barrio_destinations.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_destination_visuals.dart';

/// The primary product entry card at the top of the home shelf.
///
/// B18 dimming semantics match the retired bubble hub: when [dimmed] is
/// true (visibility resolver says not-visible) the card renders at 0.38
/// opacity and is fully non-interactive.
class BarrioHomeHeroCard extends StatelessWidget {
  final BarrioDestination destination;
  final bool dimmed;
  final VoidCallback onTap;

  const BarrioHomeHeroCard({
    super.key,
    required this.destination,
    required this.dimmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = AspectRatio(aspectRatio: 16 / 9, child: _glassBody());
    if (dimmed) {
      return Opacity(opacity: 0.38, child: card);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: card,
    );
  }

  Widget _glassBody() {
    const accent = kBarrioHomeForgeAccent;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: dimmed
            ? null
            : [
                BoxShadow(
                  color: accent.withValues(alpha: 0.38),
                  blurRadius: 36,
                  spreadRadius: -6,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: accent.withValues(alpha: 0.16),
                  blurRadius: 64,
                  spreadRadius: 2,
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0x33FFFFFF), width: 1.0),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: 0.32),
                  const Color(0x46000000),
                  accent.withValues(alpha: 0.14),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: _content(),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'OPERATIONS',
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: BarrioColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          destination.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.playfairDisplay(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          destination.description,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 13,
            color: BarrioColors.textSecondary,
          ),
        ),
        const Spacer(),
        _openDashboardPill(),
      ],
    );
  }

  Widget _openDashboardPill() {
    const accent = kBarrioHomeForgeAccent;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [accent, accent.withValues(alpha: 0.78)],
        ),
        border: Border.all(color: const Color(0x40FFFFFF), width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Open dashboard',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(
            Icons.arrow_forward_rounded,
            size: 18,
            color: Colors.white,
          ),
        ],
      ),
    );
  }
}
