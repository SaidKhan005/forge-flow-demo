import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../../state/auth_session_notifier.dart';
import '../barrio_surface_flags.dart';
import '../content/training/training_docs.dart';
import '../routes/barrio_destination_visibility_resolver.dart';
import '../routes/barrio_destinations.dart';
import '../routes/barrio_preview_role.dart';
import '../routes/barrio_route_map.dart';
import '../../../state/permission_context.dart';
import '../search/barrio_training_search.dart';
import '../services/barrio_bookmarks_service.dart';
import '../services/barrio_reading_progress_service.dart';
import '../services/barrio_refresher_scheduler.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_text_size_sheet.dart';
import '../widgets/home/barrio_home_search.dart';
import '../widgets/home/barrio_home_shelf.dart';
import 'el_podio_screen.dart';

/// The Barrio Legado internal shell home screen.
///
/// One-scroll round-bubble composition (2026-07-11 operator decision,
/// revising the Editorial Shelf of Barrio Home Redesign V1, plan:
/// docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md).
/// A calm, static backdrop (a dark vertical gradient plus one soft teal
/// glow, 2026-07-26 operator request for a simpler, quieter background
/// in place of the busy photo + breathing scrim + blooms + vignette +
/// falling leaves) sits fixed behind a single vertical scroll of brand
/// header, the Forge & Flow center bubble, and four category sections of
/// round glass bubbles (recipes mirrored from the parked orbit hub,
/// which stays on disk byte-identical; reversal doctrine: hide-only,
/// never delete). The only looping motion left on home is the center
/// bubble's own rotating dual-color arc + glow pulse, gated by the
/// [TickerMode] below; `MediaQuery.disableAnimations` freezes it,
/// holding the resting frame.
class BarrioHomeScreen extends StatefulWidget {
  const BarrioHomeScreen({super.key});

  @override
  State<BarrioHomeScreen> createState() => _BarrioHomeScreenState();
}

class _BarrioHomeScreenState extends State<BarrioHomeScreen>
    with WidgetsBindingObserver {
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

  // Battery: while another screen is pushed on top of home (reading a
  // manual), the covered home must not keep running its looping
  // effects. `ModalRoute.of` in `didChangeDependencies` registers a
  // dependency on the route's status, so this flips on push/pop above
  // and re-gates the TickerMode subtree (which pauses the center
  // bubble's arc + glow pulse).
  bool _routeIsCurrent = true;

  // Wave B (training search): trimmed, debounced query from the glass
  // search field. While it meets the minimum length, the shelf shows
  // the results sliver instead of the center bubble + sections.
  String _searchQuery = '';

  // "The app remembers you" (2026-07-22): local reading memory that
  // drives the Continue Reading card and the honest per-manual
  // progress rows. Loaded on mount and reloaded every time home
  // becomes the current route again (returning from a manual), so the
  // shelf always shows what was just read. Null until the first load
  // completes: the shelf renders no card and no progress rows, which
  // is also the honest fresh-install state.
  BarrioReadingSnapshot? _readingSnapshot;

  // Saved cards (rec #8, 2026-07-23): drives the shelf's Saved
  // section. Reloaded on the same cadence as the reading memory.
  List<BarrioBookmark> _bookmarks = const <BarrioBookmark>[];

  // Spaced refresher (rec #11): the refresh-due manuals, longest
  // overdue first, derived from real recorded timestamps with
  // DateTime.now() read exactly once per reload (no timers, no
  // notifications). Empty = no card, which is also the honest
  // fresh-install state (nothing finished, never due).
  List<String> _refresherDue = const <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reloadReadingProgress();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_motionDecided) {
      // One-shot accessibility decision: with disableAnimations the
      // TickerMode below stays disabled, so the center bubble's arc and
      // glow pulse hold their resting frame.
      _motionDecided = true;
      _reduceMotion = MediaQuery.of(context).disableAnimations;
    }
    // Route currency is deliberately NOT behind the one-shot guard:
    // pushing a manual on top of home (and popping back) must keep
    // updating state after the first motion decision. No setState
    // needed: a dependency change already schedules a rebuild for
    // this element before didChangeDependencies runs.
    final wasCurrent = _routeIsCurrent;
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeIsCurrent && !wasCurrent) {
      // Back on top after reading a manual: refresh the reading memory
      // so Continue Reading and the progress rows reflect it.
      _reloadReadingProgress();
    }
  }

  /// Loads the local reading memory and saved cards off the
  /// preferences store. Fire and forget: every service degrades to an
  /// empty snapshot when the store is unavailable, and the mounted
  /// guards cover late arrival.
  void _reloadReadingProgress() {
    BarrioReadingProgressService.loadSnapshot(kBarrioTrainingDocs.keys)
        .then((snapshot) {
      if (mounted) setState(() => _readingSnapshot = snapshot);
    });
    BarrioBookmarksService.getAll().then((bookmarks) {
      if (mounted) setState(() => _bookmarks = bookmarks);
    });
    BarrioReadingProgressService.loadRefresherStates(kBarrioTrainingDocs.keys)
        .then((states) {
      if (!mounted) return;
      setState(() {
        _refresherDue =
            BarrioRefresherScheduler.dueDocIds(states, DateTime.now());
      });
    });
  }

  /// Removes a saved card, then reloads so the Saved section reflects
  /// the store truthfully.
  void _removeBookmark(BarrioBookmark bookmark) {
    BarrioBookmarksService.remove(
      bookmark.docId,
      bookmark.chapterIndex,
      bookmark.unitInChapter,
    ).then((_) {
      if (mounted) _reloadReadingProgress();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final shouldAnimate = state == AppLifecycleState.resumed;
    if (shouldAnimate == _animationsEnabled) return;

    // Foreground/background toggles the TickerMode gate below, which
    // pauses or resumes the center bubble's arc + glow pulse.
    _animationsEnabled = shouldAnimate;

    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  /// Opens the text-size stepper sheet (accessibility pass, rec #12).
  void _openTextSizeSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const BarrioTextSizeSheet(),
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
      initialUnitInChapter: result.unitIndex,
      // Highlight the searched words on the opened card (2026-07-11
      // operator request).
      highlightQuery: _searchQuery,
    );
  }

  @override
  Widget build(BuildContext context) {
    final homeDestinations = barrioDestinations
        .where((d) => d.showOnHomeHub)
        .toList();

    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      body: Stack(
        children: [
          const _BarrioHomeBackdrop(),
          // TickerMode gates the center logo bubble's own looping motion
          // (rotating arc + glow pulse): it pauses while the app is
          // backgrounded OR while another screen is pushed on top of
          // home, and stays frozen entirely under
          // MediaQuery.disableAnimations.
          SafeArea(
            child: TickerMode(
              enabled: _animationsEnabled && _routeIsCurrent && !_reduceMotion,
              child: _buildShelf(homeDestinations),
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
          readingProgress: _readingSnapshot,
          bookmarks: _bookmarks,
          refresherDueDocIds: _refresherDue,
          // Saved rows and Continue Reading deep-link to the exact
          // card via the same navigation params the search results use.
          onBookmarkOpen: (dest, chapter, unit) =>
              _openManualAt(innerCtx, role, dest, chapter, unit),
          onBookmarkRemove: _removeBookmark,
          onContinueReading: (dest, chapter, unit) =>
              _openManualAt(innerCtx, role, dest, chapter, unit),
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
          leading: _shelfLeading(innerCtx, role),
        );
      },
    );
  }

  /// Deep-links into a manual at an exact saved/remembered card.
  void _openManualAt(
    BuildContext ctx,
    BarrioPreviewRole role,
    BarrioDestination dest,
    int chapterIndex,
    int unitInChapter,
  ) {
    BarrioRouteMap.navigateTo(
      ctx,
      dest,
      previewRole: role,
      initialChapterIndex: chapterIndex,
      initialUnitInChapter: unitInChapter,
    );
  }

  /// The widgets above the shelf body: brand header, the glass training
  /// search, and the flag-gated El Podio pill.
  List<Widget> _shelfLeading(BuildContext innerCtx, BarrioPreviewRole role) {
    return [
      RepaintBoundary(
        child: _BarrioHeader(
          previewRole: role,
          onRoleChanged: (r) => setState(() => _previewRoleOverride = r),
          onTextSizeTap: _openTextSizeSheet,
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
    ];
  }
}

// ---------------------------------------------------------------------------
// Backdrop: a calm, static two-layer background (2026-07-26 operator
// request for a simpler, quieter background that still looks nice, in
// place of the busy photo + breathing scrim + blooms + vignette). A warm
// cream vertical gradient, lightest at the top for header legibility,
// easing to a faint mint down the scroll, with one soft teal glow behind
// the brand anchor. Pointer-transparent and isolated in a RepaintBoundary
// so the scrolling content never repaints it. Nothing here animates.
// ---------------------------------------------------------------------------

class _BarrioHomeBackdrop extends StatelessWidget {
  const _BarrioHomeBackdrop();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: RepaintBoundary(
        child: Stack(
          children: [
            // Base vertical gradient: warm cream at the top so the brand
            // wordmark stays legible, easing to a faint mint green.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFFCF8EF),
                      Color(0xFFF3F6EE),
                      Color(0xFFE9F3EC),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),

            // One soft teal glow behind the brand anchor, kept very
            // low-alpha so it reads as quiet depth rather than noise.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0.0, -0.5),
                    radius: 0.9,
                    colors: [Color(0x142E9B8F), Colors.transparent],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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

  /// Opens the text-size stepper sheet (accessibility pass, rec #12).
  final VoidCallback onTextSizeTap;

  const _BarrioHeader({
    required this.previewRole,
    required this.onRoleChanged,
    required this.onTextSizeTap,
  });

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
          child: Stack(
            children: [
              // Quiet 'Aa' entry to the text-size stepper (rec #12):
              // top-right of the header, clear of the centered wordmark.
              Positioned(
                top: 0,
                right: 0,
                child: _TextSizeButton(onTap: widget.onTextSizeTap),
              ),
              Column(
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
                // Subtle lift on the cream ground (was a heavy dark
                // drop-shadow tuned for the old navy backdrop).
                Shadow(
                  color: Color(0x14000000),
                  blurRadius: 12,
                  offset: Offset(0, 2),
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
              // Deeper icon-leaf teal so the wordmark stays legible on
              // cream (bright tealWarm is a fill/accent, not text).
              color: BarrioColors.tealDeep,
              height: 1.0,
              shadows: const [
                Shadow(
                  color: Color(0x142E9B8F),
                  blurRadius: 18,
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

/// Quiet 'Aa' text-size entry (accessibility pass, rec #12): a small
/// glass chip in the header's top-right corner opening the stepper
/// sheet. 44x44 hit target via padding around the compact chip.
class _TextSizeButton extends StatelessWidget {
  final VoidCallback onTap;

  const _TextSizeButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Text size',
      child: GestureDetector(
        key: const ValueKey<String>('barrio_text_size_button'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          // Grows the tap target to at least 44x44 around the chip.
          padding: const EdgeInsets.all(8),
          child: ExcludeSemantics(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x0D16243B),
                borderRadius: BorderRadius.circular(BarrioRadii.chip),
                border: Border.all(color: BarrioColors.hairline),
              ),
              child: Text(
                'Aa',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: BarrioColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
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
                  color: isActive ? null : const Color(0x1416243B),
                  borderRadius: BorderRadius.circular(BarrioRadii.chip),
                  border: Border.all(
                    color: isActive
                        ? BarrioColors.tealDeep.withValues(alpha: 0.6)
                        : const Color(0x2A16243B),
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
                    // Navy reads on the bright teal active fill; slate on cream.
                    color: isActive
                        ? BarrioColors.textPrimary
                        : BarrioColors.textSecondary,
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
              color: BarrioColors.trophyGold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(BarrioRadii.card),
              border: Border.all(
                color: BarrioColors.trophyGold.withValues(alpha: 0.45),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: BarrioColors.trophyGold.withValues(alpha: 0.15),
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
                  color: BarrioColors.trophyGold,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Text(
                  'EL PODIO',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    color: BarrioColors.trophyGold,
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
