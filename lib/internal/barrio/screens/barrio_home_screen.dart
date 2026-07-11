import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../../state/auth_session_notifier.dart';
import '../barrio_surface_flags.dart';
import '../routes/barrio_destination_visibility_resolver.dart';
import '../routes/barrio_destinations.dart';
import '../routes/barrio_preview_role.dart';
import '../routes/barrio_route_map.dart';
import '../../../state/permission_context.dart';
import '../search/barrio_training_search.dart';
import '../widgets/barrio_ambient_leaves.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/home/barrio_home_search.dart';
import '../widgets/home/barrio_home_shelf.dart';
import 'el_podio_screen.dart';

/// The Barrio Legado internal shell home screen.
///
/// One-scroll round-bubble composition (2026-07-11 operator decision,
/// revising the Editorial Shelf of Barrio Home Redesign V1, plan:
/// docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md):
/// full-bleed photo background with gradient scrim + colour blooms +
/// vignette sits fixed behind a single vertical scroll of brand header,
/// the Forge & Flow center bubble, and four category sections of round
/// glass bubbles (recipes mirrored from the parked orbit hub, which
/// stays on disk byte-identical; reversal doctrine: hide-only, never
/// delete). The operator decision explicitly restores the premium
/// ambient effects the shelf removed: the falling leaves, the rotating
/// dual-color center arc, and the scrim colour-breathing loop, which
/// overrides the redesign plan's "no looping/ambient animation" rule.
/// `MediaQuery.disableAnimations` keeps everything static.
class BarrioHomeScreen extends StatefulWidget {
  const BarrioHomeScreen({super.key});

  @override
  State<BarrioHomeScreen> createState() => _BarrioHomeScreenState();
}

class _BarrioHomeScreenState extends State<BarrioHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Phase 9.3: when an auth session is live, the preview role is
  // derived from `BarrioPreviewRole.fromAuthRoles(session.roles)`.
  // This local override is used in two cases:
  //
  //   1. Dev / preview mode (no AuthSessionNotifier in the tree).
  //   2. The role chips below — preserved as a dev-only override so
  //      design and learning surfaces keep their preview tooling.
  //
  // Real permission gating (allow / deny across catalog keys) lands
  // in 9.7. 9.3 only wires the read direction so authenticated
  // sessions feed the existing preview surface.
  BarrioPreviewRole? _previewRoleOverride;
  bool _animationsEnabled = true;
  bool _motionDecided = false;
  bool _reduceMotion = false;

  // Wave B (training search): trimmed, debounced query from the glass
  // search field. While it meets the minimum length, the shelf shows
  // the results sliver instead of the center bubble + sections.
  String _searchQuery = '';

  // Colour-temperature scrim breathing: 12s loop shifting the bottom
  // gradient between warm golden (#1A0A00) and cool midnight (#0A0A1A).
  // Restored from the pre-shelf home (c712461b) per the operator's
  // 2026-07-11 home-revision decision.
  late final AnimationController _scrimCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionDecided) return;
    _motionDecided = true;
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (!_reduceMotion) {
      // Accessibility: with disableAnimations the loop never starts, so
      // the scrim holds its resting warm-golden bottom stop.
      _scrimCtrl.repeat(reverse: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final shouldAnimate = state == AppLifecycleState.resumed;
    if (shouldAnimate == _animationsEnabled) return;

    if (shouldAnimate && !_reduceMotion) {
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

  BarrioPreviewRole _resolvePreviewRole(BuildContext context) {
    // BSP.2: while the preview switcher is hidden, the preview-role
    // fallback is pinned to Admin. The override / session-role mapping
    // below stays in place (unexecuted) so flipping
    // kBarrioShowRolePreviewChips restores it verbatim. Production
    // permission gating via PermissionContext (B18, wired in build)
    // is independent of this and still wins when present.
    if (!kBarrioShowRolePreviewChips) return BarrioPreviewRole.admin;
    final override = _previewRoleOverride;
    if (override != null) return override;
    AuthSessionNotifier? notifier;
    try {
      notifier = Provider.of<AuthSessionNotifier>(context, listen: true);
    } on ProviderNotFoundException {
      notifier = null;
    }
    if (notifier == null) {
      return BarrioPreviewRole.admin;
    }
    final session = notifier.session;
    if (session == null) {
      return BarrioPreviewRole.admin;
    }
    return BarrioPreviewRole.fromAuthRoles(session.roles);
  }

  void _openElPodio(BuildContext context) {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ElPodioScreen()),
    );
  }

  void _onSearchQueryChanged(String raw) {
    final trimmed = raw.trim();
    if (trimmed == _searchQuery) return;
    setState(() => _searchQuery = trimmed);
  }

  void _openSearchResult(
    BuildContext context,
    BarrioTrainingSearchResult result,
    BarrioDestination destination,
    BarrioPreviewRole role,
  ) {
    // Dismiss the keyboard before navigating to the matched section.
    FocusManager.instance.primaryFocus?.unfocus();
    HapticFeedback.lightImpact();
    BarrioRouteMap.navigateTo(
      context,
      destination,
      previewRole: role,
      initialChapterIndex: result.chapterIndex,
    );
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
          _BarrioHomeBackdrop(scrimColour: _scrimColour),
          // Ambient falling leaves overlay the scrolling content
          // (IgnorePointer inside the widget keeps taps passing
          // through), restored from the pre-shelf composition
          // (c712461b). TickerMode pauses all looping motion while the
          // app is backgrounded, and keeps it frozen entirely under
          // MediaQuery.disableAnimations.
          SafeArea(
            child: TickerMode(
              enabled: _animationsEnabled && !_reduceMotion,
              child: BarrioAmbientLeaves(
                child: _buildShelf(homeDestinations),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShelf(List<BarrioDestination> homeDestinations) {
    return Builder(
      builder: (innerCtx) {
        final role = _resolvePreviewRole(innerCtx);
        // B18: when a PermissionContext is wired by production
        // bootstrap, prefer the permission-runtime resolver over the
        // preview-role tier; otherwise leave null so the chip-driven
        // preview-role still works in dev / demo.
        PermissionContext? permissionContext;
        try {
          permissionContext = Provider.of<PermissionContext>(
            innerCtx,
            listen: true,
          );
        } on ProviderNotFoundException {
          permissionContext = null;
        }
        final resolver = permissionContext != null
            ? PermissionContextBarrioVisibilityResolver(
                context: permissionContext,
              )
            : null;
        // Wave B: an active query swaps the shelf body for the results
        // sliver; the same resolver-first / preview-role visibility the
        // bubbles use filters the results (B18).
        final searchActive =
            _searchQuery.length >= BarrioTrainingSearch.kMinQueryLength;
        return BarrioHomeShelf(
          destinations: homeDestinations,
          previewRole: role,
          visibilityResolver: resolver,
          onDestinationTap: (dest) => BarrioRouteMap.navigateTo(
            innerCtx,
            dest,
            previewRole: role,
          ),
          bodyOverride: searchActive
              ? BarrioHomeSearchResults(
                  query: _searchQuery,
                  previewRole: role,
                  visibilityResolver: resolver,
                  onResultTap: (result, destination) => _openSearchResult(
                    innerCtx,
                    result,
                    destination,
                    role,
                  ),
                )
              : null,
          leading: [
            RepaintBoundary(
              child: _BarrioHeader(
                previewRole: role,
                onRoleChanged: (r) =>
                    setState(() => _previewRoleOverride = r),
              ),
            ),
            // Wave B: glass training search under the brand header,
            // above the Forge & Flow center bubble.
            RepaintBoundary(
              child: BarrioHomeSearchField(
                onQueryChanged: _onSearchQueryChanged,
              ),
            ),
            // BSP.2: El Podio entry hidden while kBarrioShowElPodioEntry
            // is false. The widget, screen, and route stay in the tree;
            // flipping the flag restores the pill verbatim.
            if (kBarrioShowElPodioEntry)
              RepaintBoundary(
                child: _ElPodioButton(onTap: () => _openElPodio(innerCtx)),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Backdrop: full-bleed photo, then the colour-breathing gradient scrim,
// then colour blooms and vignette. All layers are pointer-transparent.
// The scrim's bottom stop breathes warm-to-cool on the 12s loop
// (restored from c712461b); the blooms and vignette stay static.
// ---------------------------------------------------------------------------

class _BarrioHomeBackdrop extends StatelessWidget {
  final Animation<Color?> scrimColour;

  const _BarrioHomeBackdrop({required this.scrimColour});

  static const List<Widget> _staticOverlayLayers = [
    // 3 — Teal bloom — top-centre brand anchor
    Positioned.fill(
      child: RepaintBoundary(
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
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
          child: DecoratedBox(
            decoration: BoxDecoration(
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
          child: DecoratedBox(
            decoration: BoxDecoration(
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
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1 — Full-bleed photo
        const Positioned.fill(
          child: RepaintBoundary(
            child: _ViewportAssetFill(
              assetPath: 'assets/internal/barrio/home_bg.png',
            ),
          ),
        ),

        // 2: editorial gradient scrim with colour-temperature breathing.
        //    Dark at top (header legibility), transparent in the bubble
        //    area (photo breathes), animated warm-to-cool at the bottom.
        Positioned.fill(
          child: RepaintBoundary(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: scrimColour,
                builder: (context, _) {
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0xF0070D1A), // 94%: header zone
                          const Color(0xBB070D1A), // 73%: below header
                          const Color(0x44070D1A), // 27%: photo shows
                          const Color(0x66070D1A), // 40%: below bubbles
                          scrimColour.value!, // animated warm-to-cool
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

        ..._staticOverlayLayers,
      ],
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
// Header: plain centered wordmark + gold rule, no card background
// (2026-07-11 operator request: text only, centered; the dark top stop
// of the scrim keeps it legible over the photo). The flag-gated role
// PREVIEW row stays wired beneath it for BSP.2 reversal.
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
  bool _entranceDecided = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    final curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart);
    _barrioSpacing = Tween<double>(begin: 6.0, end: 2.0).animate(curve);
    _legadoSpacing = Tween<double>(begin: 6.0, end: 1.0).animate(curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceDecided) return;
    _entranceDecided = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Accessibility: skip the one-shot wordmark entrance entirely.
      _ctrl.value = 1.0;
    } else {
      _ctrl.forward();
    }
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _wordmark(),
              const SizedBox(height: 6),
              const _GoldRule(),

              // BSP.2: role PREVIEW switcher hidden while
              // kBarrioShowRolePreviewChips is false; the spacing
              // above it goes with it so the header keeps no empty
              // gap. Flipping the flag restores the row verbatim.
              if (kBarrioShowRolePreviewChips) ...[
                const SizedBox(height: 14),

                // Role preview row
                _RolePreviewRow(
                  current: widget.previewRole,
                  onChanged: widget.onRoleChanged,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // Wordmark — letterSpacing collapses from 6.0 to resting values on entry
  Widget _wordmark() {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: 'Barrio ',
            style: GoogleFonts.playfairDisplay(
              fontSize: 28,
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
              fontSize: 28,
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
    );
  }
}

/// Refined gold rule — longer, thinner, double-line. Centered under the
/// wordmark, so both lines fade out symmetrically at their edges.
class _GoldRule extends StatelessWidget {
  const _GoldRule();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 88,
          height: 1.0,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                BarrioColors.gold.withValues(alpha: 0.0),
                BarrioColors.gold,
                BarrioColors.gold.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.5, 1.0],
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
                BarrioColors.gold.withValues(alpha: 0.0),
                BarrioColors.gold.withValues(alpha: 0.5),
                BarrioColors.gold.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
    );
  }
}

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
