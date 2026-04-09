import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../routes/barrio_destinations.dart';
import '../routes/barrio_preview_role.dart';
import '../routes/barrio_route_map.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_bubble_hub.dart';
import 'el_podio_screen.dart';
import '../widgets/barrio_ambient_leaves.dart';

/// The Barrio Legado internal shell home screen.
///
/// Editorial-grade layered background: full-bleed photo → gradient scrim
/// (dark header / transparent hub / dark footer) → colour blooms → vignette.
/// Glassmorphism header card floats above the photo with frosted blur.
class BarrioHomeScreen extends StatefulWidget {
  const BarrioHomeScreen({super.key});

  @override
  State<BarrioHomeScreen> createState() => _BarrioHomeScreenState();
}

class _BarrioHomeScreenState extends State<BarrioHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  BarrioPreviewRole _previewRole = BarrioPreviewRole.admin;
  bool _animationsEnabled = true;

  // Colour-temperature scrim breathing — 12s loop shifting the bottom
  // gradient between warm golden (#1A0A00) and cool midnight (#0A0A1A).
  late final AnimationController _scrimCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  )..repeat(reverse: true);

  late final Animation<Color?> _scrimColour = ColorTween(
    begin: const Color(0xCC1A0A00), // warm golden
    end: const Color(0xCC0A0A1A), // cool midnight
  ).animate(CurvedAnimation(parent: _scrimCtrl, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final shouldAnimate = state == AppLifecycleState.resumed;
    if (shouldAnimate == _animationsEnabled) return;

    if (shouldAnimate) {
      _scrimCtrl.repeat(reverse: true);
    } else {
      _scrimCtrl.stop(canceled: false);
    }

    if (!mounted) return;
    setState(() => _animationsEnabled = shouldAnimate);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrimCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final homeDestinations = barrioDestinations
        .where((d) => d.showOnHomeHub)
        .toList();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1 — Full-bleed photo
          Positioned.fill(
            child: RepaintBoundary(
              child: _ViewportAssetFill(
                assetPath: 'assets/internal/barrio/home_bg.png',
              ),
            ),
          ),

          // 2 — Editorial gradient scrim with colour-temperature breathing:
          //     dark at top (header legibility) → transparent in hub area
          //     (photo breathes) → animated warm↔cool at bottom.
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _scrimColour,
                  builder: (context, _) {
                    return Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0xF0070D1A), // 94% — header zone
                            const Color(0xBB070D1A), // 73% — below header
                            const Color(0x44070D1A), // 27% — hub: photo shows
                            const Color(0x66070D1A), // 40% — below hub
                            _scrimColour.value!, // animated warm↔cool
                          ],
                          stops: const [0.0, 0.20, 0.52, 0.75, 1.0],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // 3 — Teal bloom — top-centre brand anchor
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0.0, -0.55),
                      radius: 0.85,
                      colors: [Color(0x4040CFCF), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4 — Gold warmth bloom — bottom-right hospitality accent
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(1.0, 1.1),
                      radius: 0.75,
                      colors: [Color(0x2ADFAA40), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 5 — Edge vignette — cinematic corner darkness
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.2,
                      colors: [Colors.transparent, Color(0x88000000)],
                      stops: [0.55, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 6 — Content
          SafeArea(
            child: TickerMode(
              enabled: _animationsEnabled,
              child: BarrioAmbientLeaves(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RepaintBoundary(
                      child: _BarrioHeader(
                        previewRole: _previewRole,
                        onRoleChanged: (r) => setState(() => _previewRole = r),
                      ),
                    ),
                    RepaintBoundary(
                      child: _ElPodioButton(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ElPodioScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: RepaintBoundary(
                          child: BarrioBubbleHub(
                            destinations: homeDestinations,
                            previewRole: _previewRole,
                            onDestinationTap: (dest) =>
                                BarrioRouteMap.navigateTo(
                                  context,
                                  dest,
                                  previewRole: _previewRole,
                                ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewportAssetFill extends StatelessWidget {
  final String assetPath;

  const _ViewportAssetFill({required this.assetPath});

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheWidth = constraints.maxWidth.isFinite
            ? (constraints.maxWidth * dpr).round()
            : null;
        final cacheHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight * dpr).round()
            : null;

        return Image.asset(
          assetPath,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth != null && cacheWidth > 0 ? cacheWidth : null,
          cacheHeight: cacheHeight != null && cacheHeight > 0
              ? cacheHeight
              : null,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Header — frosted glass card with wordmark + role preview
// ---------------------------------------------------------------------------

class _BarrioHeader extends StatefulWidget {
  final BarrioPreviewRole previewRole;
  final ValueChanged<BarrioPreviewRole> onRoleChanged;

  const _BarrioHeader({required this.previewRole, required this.onRoleChanged});

  @override
  State<_BarrioHeader> createState() => _BarrioHeaderState();
}

class _BarrioHeaderState extends State<_BarrioHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _barrioSpacing; // 6.0 → 2.0
  late final Animation<double> _legadoSpacing; // 6.0 → 1.0

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
    final curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart);
    _barrioSpacing = Tween<double>(begin: 6.0, end: 2.0).animate(curve);
    _legadoSpacing = Tween<double>(begin: 6.0, end: 1.0).animate(curve);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0x18FFFFFF),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0x28FFFFFF),
                    width: 1.0,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Wordmark — letterSpacing collapses from 6.0 to resting values on entry
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Barrio ',
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 36,
                              fontWeight: FontWeight.w700,
                              letterSpacing: _barrioSpacing.value,
                              color: BarrioColors.textPrimary,
                              height: 1.0,
                              shadows: const [
                                Shadow(
                                  color: Color(0x60000000),
                                  blurRadius: 16,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                          ),
                          TextSpan(
                            text: 'Legado',
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 36,
                              fontWeight: FontWeight.w300,
                              fontStyle: FontStyle.italic,
                              letterSpacing: _legadoSpacing.value,
                              color: BarrioColors.tealWarm,
                              height: 1.0,
                              shadows: const [
                                Shadow(
                                  color: Color(0x504FC3C3),
                                  blurRadius: 20,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Refined gold rule — longer, thinner, double-line
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 88,
                          height: 1.0,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                BarrioColors.gold,
                                BarrioColors.gold.withValues(alpha: 0.0),
                              ],
                              stops: const [0.0, 1.0],
                            ),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Container(
                          width: 44,
                          height: 0.5,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                BarrioColors.gold.withValues(alpha: 0.5),
                                BarrioColors.gold.withValues(alpha: 0.0),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // Role preview row
                    _RolePreviewRow(
                      current: widget.previewRole,
                      onChanged: widget.onRoleChanged,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Film grain — static analog texture layer
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

class _RolePreviewRow extends StatelessWidget {
  final BarrioPreviewRole current;
  final ValueChanged<BarrioPreviewRole> onChanged;

  const _RolePreviewRow({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Gold accent dot + PREVIEW label
        Row(
          children: [
            Container(
              width: 4,
              height: 4,
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BarrioColors.gold.withValues(alpha: 0.85),
              ),
            ),
            Text(
              'PREVIEW',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.0,
                color: BarrioColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Role chips — Wrap prevents overflow on any screen width
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: BarrioPreviewRole.values.map((role) {
            final isActive = role == current;
            return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onChanged(role);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  gradient: isActive
                      ? LinearGradient(
                          colors: [
                            BarrioColors.tealWarm,
                            BarrioColors.tealWarm.withValues(alpha: 0.75),
                          ],
                        )
                      : null,
                  color: isActive ? null : const Color(0x18FFFFFF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isActive
                        ? BarrioColors.tealWarm.withValues(alpha: 0.6)
                        : const Color(0x30FFFFFF),
                    width: 1.0,
                  ),
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: BarrioColors.tealWarm.withValues(
                              alpha: 0.45,
                            ),
                            blurRadius: 12,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  role.label,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: 0.4,
                    color: isActive ? Colors.white : BarrioColors.textSecondary,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// El Podio button — frosted glass pill for home screen
// ---------------------------------------------------------------------------

class _ElPodioButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ElPodioButton({required this.onTap});

  @override
  State<_ElPodioButton> createState() => _ElPodioButtonState();
}

class _ElPodioButtonState extends State<_ElPodioButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutBack,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFD4AF37).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFFD4AF37).withValues(alpha: 0.45),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFD4AF37).withValues(alpha: 0.15),
                  blurRadius: 16,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.emoji_events,
                  color: Color(0xFFD4AF37),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Text(
                  'EL PODIO',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    color: const Color(0xFFD4AF37),
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
