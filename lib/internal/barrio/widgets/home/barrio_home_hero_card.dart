// Editorial Shelf home redesign (2026-07-11 Barrio Home Redesign V1).
// Plan: docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md
//
// The Forge & Flow product hero: full width minus the 20px shelf
// margins, 16:9, and the strongest glass treatment on the page. The
// entire card is one tap target for the `forge_and_flow` destination.
//
// Premium pass (2026-08-05, premium+performance Wave 2). The card was
// styled for a dark theme and shipped on a cream page:
//   * three literal `BorderRadius.circular(24)` (the bottom-sheet rung)
//     are now [BarrioRadii.card], the rung every other card sits on;
//   * a double coloured glow (36px @ 0.38 plus 64px @ 0.16 in the F&F
//     accent) is now the one house [barrioSoftShadow] - the same neon
//     halo the 2026-07-27 pass removed everywhere else;
//   * the `0x33FFFFFF` white rim is now a muted accent hairline, the
//     same treatment [BarrioHomeOrbitBubble] uses;
//   * the `0x46000000` black gradient stop, which composited to a muddy
//     grey over the cream page and fought the navy body text, is now a
//     low-alpha navy tint.
//
// This is the ONE surface on the home hub that keeps its BackdropFilter
// (see the GPU-diet note in barrio_home_bubble.dart). It is the only
// genuinely translucent glass left: the fill is a gradient topping out
// at 32% alpha, well under the ~85% cutoff at which a blur is simply
// painted over, so the frost really does read here. It is also the
// deliberate hero differentiator, the one place the effect earns its
// saveLayer.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/barrio_destinations.dart';
import '../barrio_destination_scaffold.dart';
import 'barrio_home_destination_visuals.dart';

/// The primary product entry card at the top of the home shelf.
///
/// Currently hide-only: the 2026-07-11 operator revision swapped the
/// rectangular hero/topic cards for the round bubbles, so
/// `BarrioHomeShelf` no longer composes this (see that file's header).
/// It stays on disk, exported, and correct, so restoring it does not
/// re-import a dark-theme card onto the cream page.
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
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        // ONE soft navy lift from the shared token. No coloured glow,
        // no stacked shadows: the same language as every other card.
        boxShadow: dimmed
            ? null
            : barrioSoftShadow(y: 10, blur: 28, opacity: 0.12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        // The one kept blur on the home hub: this fill is genuinely
        // translucent (see the file header), so the frost is visible.
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(BarrioRadii.card),
              border: Border.all(
                // A single muted accent hairline, matching the orbit
                // bubbles (was a 20%-alpha white rim, a dark-theme
                // idiom that read as haze on the cream page).
                color: accent.withValues(alpha: 0.38),
                width: 1.0,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: 0.32),
                  // Was Color(0x46000000): 27%-alpha black over cream
                  // composited to a muddy grey and fought the navy body
                  // text. A low-alpha navy tint cools the mid-stop
                  // instead of dirtying it.
                  BarrioColors.navy.withValues(alpha: 0.12),
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
        // Half of the 48 height: a true stadium pill, not a card corner,
        // so this one stays off the [BarrioRadii] card ladder.
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
