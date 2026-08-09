import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../routes/barrio_preview_role.dart';
import '../widgets/barrio_destination_scaffold.dart';

/// Coming-soon destination screen for the Preston Lee Model.
///
/// Premium photo-backed scaffold with warm amber accent bloom.
/// Audience tags and access intent banners were removed for consistency —
/// no other learning screen shows them. Phase 9 will add real role gating
/// systematically across all screens.
class PrestonLeeModelComingSoonScreen extends StatelessWidget {
  final BarrioPreviewRole previewRole;

  const PrestonLeeModelComingSoonScreen({
    super.key,
    this.previewRole = BarrioPreviewRole.admin,
  });

  static const _accent = BarrioColors.accentPreston;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: 'Preston Lee Model',
        accentColor: _accent,
      ),
      body: _PrestonPremiumBackground(
        accent: _accent,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Icon + title block
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _accent.withValues(alpha: 0.10),
                        border: Border.all(
                          color: _accent.withValues(alpha: 0.35),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _accent.withValues(alpha: 0.20),
                            blurRadius: 14,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.lightbulb_outline,
                          color: _accent, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Preston Lee Model',
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              color: BarrioColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Coming Soon',
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 13,
                              color: BarrioColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Divider
                Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      _accent.withValues(alpha: 0.4),
                      _accent.withValues(alpha: 0.0),
                    ]),
                  ),
                ),

                const SizedBox(height: 24),

                // Body
                Text(
                  'The Preston Lee Model is not ready yet.\n\n'
                  'We are still putting it together and will add it here as '
                  'soon as it is ready.',
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 14,
                    height: 1.75,
                    color: BarrioColors.textSecondary,
                  ),
                ),

              ],
            ),
          ),
        ),
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// Premium photo-backed background — same layering as home screen
// ---------------------------------------------------------------------------

class _PrestonPremiumBackground extends StatelessWidget {
  final Color accent;
  final Widget child;

  const _PrestonPremiumBackground({
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: Full-bleed photo. Decoded at screen width (perf audit
        // A1), not the source resolution.
        Positioned.fill(
          child: Image.asset(
            'assets/internal/barrio/preston_lee_bg.jpg',
            fit: BoxFit.cover,
            alignment: const Alignment(0.0, -0.3),
            cacheWidth:
                barrioCacheWidth(context, MediaQuery.sizeOf(context).width),
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: BarrioColors.shellDeep,
            ),
          ),
        ),

        // Layer 2: Cream veil for text legibility (light shell color)
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.15, 0.35, 0.65, 0.85, 1.0],
                  colors: [
                    BarrioColors.shellDeep.withValues(alpha: 0.95),
                    BarrioColors.shellDeep.withValues(alpha: 0.88),
                    BarrioColors.shellDeep.withValues(alpha: 0.78),
                    BarrioColors.shellDeep.withValues(alpha: 0.82),
                    BarrioColors.shellDeep.withValues(alpha: 0.90),
                    BarrioColors.shellDeep.withValues(alpha: 0.96),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Layers 3 + 4: the shared violet accent bloom (top-right) and
        // complementary navy bloom, from BarrioPremiumBackground.
        Positioned.fill(
          child: BarrioPremiumBackground(
            accentColor: accent,
            accentOpacity: 0.16,
            bloomAlignment: const Alignment(0.75, -0.85),
          ),
        ),

        // Layer 5: Edge vignette
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.1,
                  colors: [
                    Colors.transparent,
                    BarrioColors.shellDeep.withValues(alpha: 0.35),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Content
        child,
      ],
    );
  }
}
