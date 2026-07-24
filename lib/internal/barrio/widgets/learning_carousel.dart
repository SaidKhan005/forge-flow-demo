import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

/// Premium horizontal PageView carousel for learning content.
///
/// Learning-screen v2 gesture ownership (2026-07-23, operator-approved
/// Direction 1 "tap turns the page, drag scrolls the card"):
///
/// - Every vertical or diagonal drag ALWAYS scrolls the card being
///   read. The pager only claims drags that are clearly horizontal
///   (see [_StronglyHorizontalDragRecognizer]), so a slanted reading
///   flick can never turn the page by accident.
/// - Page turns come from generous invisible tap zones on the left and
///   right edges of the card area (e-reader style) plus small visible
///   back/next chevrons in the side gutters. Taps on inline images and
///   interactive card content still win (child-first gesture arena).
/// - One physics personality on both axes: the pager and the card
///   scroll both clamp (no mixed bounce/clamp feel).
/// - Cards that overflow LOOK scrollable: a thin scrollbar plus a
///   bottom fade cue that disappears at the end of the card.
/// - Scroll offsets survive paging away and back (PageStorageKey per
///   card) and [moveToPage] jumps without remounting, so chapter-rail
///   taps no longer wipe state or replay the entrance animation.
///
/// Retained premium feel: glass cards, entrance fade+slide (once per
/// screen open), subtle neighbor scale, auto-advance after correct
/// answers on interactive decks.
class LearningCarousel extends StatefulWidget {
  final int cardCount;
  final IndexedWidgetBuilder cardBuilder;
  final Color accent;
  final ValueChanged<int>? onPageChanged;

  /// Page the carousel opens on. Read when the State mounts. For a
  /// programmatic jump after mount, call [LearningCarouselState.moveToPage]
  /// (the training screen's chapter rail and resume restore do); legacy
  /// per-chapter callers may still re-mount with a new [key].
  final int initialPage;

  const LearningCarousel({
    super.key,
    required this.cardCount,
    required this.cardBuilder,
    required this.accent,
    this.onPageChanged,
    this.initialPage = 0,
  });

  @override
  State<LearningCarousel> createState() => LearningCarouselState();
}

class LearningCarouselState extends State<LearningCarousel>
    with SingleTickerProviderStateMixin {
  /// Near-full-width pages: the wider text measure replaces the old
  /// 0.88 neighbor peek as the paging affordance now that chevrons and
  /// tap zones exist.
  static const double _viewportFraction = 0.96;

  /// Fraction of the card area on each edge that acts as an invisible
  /// page-turn tap zone (left = back, right = next).
  static const double _edgeTapZoneFraction = 0.22;

  late final PageController _pageController;
  int _currentPage = 0;
  Timer? _autoAdvanceTimer;
  Drag? _pagerDrag;

  // Entrance animation (runs once per screen open; moveToPage jumps do
  // not replay it).
  late final AnimationController _entranceCtrl;
  late final Animation<double> _entranceFade;
  late final Animation<Offset> _entranceSlide;
  bool _entranceDecided = false;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _pageController = PageController(
      viewportFraction: _viewportFraction,
      initialPage: widget.initialPage,
    );

    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _entranceFade = CurvedAnimation(
      parent: _entranceCtrl,
      curve: Curves.easeOutCubic,
    );
    _entranceSlide = Tween<Offset>(
      begin: const Offset(0.05, 0),
      end: Offset.zero,
    ).animate(_entranceFade);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceDecided) return;
    _entranceDecided = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Accessibility (rec #12): reduce motion skips the entrance
      // fade + slide; the deck lands settled on the first frame.
      _entranceCtrl.value = 1.0;
    } else {
      _entranceCtrl.forward();
    }
  }

  @override
  void dispose() {
    _autoAdvanceTimer?.cancel();
    _pageController.dispose();
    _entranceCtrl.dispose();
    super.dispose();
  }

  /// Called by card widgets after a correct answer to trigger auto-advance.
  void requestAdvance() {
    _cancelAutoAdvance();
    _autoAdvanceTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      if (_currentPage < widget.cardCount - 1) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOutCubic,
        );
      }
    });
  }

  /// Programmatic page move (chapter-rail taps, resume restore). Near
  /// targets animate so the reader keeps context; far targets jump
  /// instantly so dozens of intermediate cards never flash by. No
  /// remount: every card's scroll offset and the entrance animation
  /// survive, and [LearningCarousel.onPageChanged] fires exactly as it
  /// does for swipes and tap-zone turns.
  void moveToPage(int page) {
    _cancelAutoAdvance();
    if (widget.cardCount == 0 || !_pageController.hasClients) return;
    final target = page.clamp(0, widget.cardCount - 1);
    if ((target - _currentPage).abs() <= 3) {
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _pageController.jumpToPage(target);
    }
  }

  void _cancelAutoAdvance() {
    _autoAdvanceTimer?.cancel();
    _autoAdvanceTimer = null;
  }

  /// Animated single-page turn from the tap zones and chevrons.
  void _turnPage(int delta) {
    _cancelAutoAdvance();
    final target = _currentPage + delta;
    if (target < 0 || target >= widget.cardCount) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _handleCardAreaTap(double dx, double width) {
    if (width <= 0) return;
    if (dx < width * _edgeTapZoneFraction) {
      _turnPage(-1);
    } else if (dx > width * (1 - _edgeTapZoneFraction)) {
      _turnPage(1);
    }
  }

  // The pager owns no built-in drag ([_ExternalDragOnlyPhysics]); the
  // strongly horizontal recognizer drives the scroll position directly
  // so page snapping and fling targeting behave exactly like a native
  // PageView drag.
  void _startPagerDrag(DragStartDetails details) {
    _cancelAutoAdvance();
    if (!_pageController.hasClients) return;
    _pagerDrag = _pageController.position.drag(details, () {
      _pagerDrag = null;
    });
  }

  void _updatePagerDrag(DragUpdateDetails details) {
    _pagerDrag?.update(details);
  }

  void _endPagerDrag(DragEndDetails details) {
    final drag = _pagerDrag;
    _pagerDrag = null;
    drag?.end(details);
  }

  void _cancelPagerDrag() {
    final drag = _pagerDrag;
    _pagerDrag = null;
    drag?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _entranceFade,
      child: SlideTransition(
        position: _entranceSlide,
        child: Column(
          children: [
            Expanded(child: _buildPager(context)),
            const SizedBox(height: 6),
            _CarouselPositionIndicator(
              count: widget.cardCount,
              accent: widget.accent,
              pageController: _pageController,
              fallbackPage: _currentPage,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildPager(BuildContext context) {
    return Stack(
      children: [
        RawGestureDetector(
          gestures: <Type, GestureRecognizerFactory>{
            _StronglyHorizontalDragRecognizer:
                GestureRecognizerFactoryWithHandlers<
                    _StronglyHorizontalDragRecognizer>(
              () => _StronglyHorizontalDragRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onStart = _startPagerDrag
                ..onUpdate = _updatePagerDrag
                ..onEnd = _endPagerDrag
                ..onCancel = _cancelPagerDrag,
            ),
          },
          child: PageView.builder(
            controller: _pageController,
            physics: const _ExternalDragOnlyPhysics(),
            itemCount: widget.cardCount,
            onPageChanged: (page) {
              _cancelAutoAdvance();
              setState(() => _currentPage = page);
              widget.onPageChanged?.call(page);
            },
            itemBuilder: _buildPageItem,
          ),
        ),
        // Small visible page-turn chevrons in the side gutters (over
        // the card's padding strip, never over content or image taps).
        if (_currentPage > 0)
          _EdgeChevron(alignLeft: true, onTap: () => _turnPage(-1)),
        if (_currentPage < widget.cardCount - 1)
          _EdgeChevron(alignLeft: false, onTap: () => _turnPage(1)),
      ],
    );
  }

  Widget _buildPageItem(BuildContext context, int index) {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, child) {
        // Subtle neighbor scale only. The old 3D tilt and opacity dim
        // were ornamental layers that cost legibility (learning-screen
        // v2 chrome diet).
        var scale = 1.0;
        if (_pageController.position.haveDimensions) {
          final distance = ((_pageController.page ?? 0.0) - index).abs();
          scale = (1.0 - distance * 0.03).clamp(0.94, 1.0);
        }
        return Transform.scale(scale: scale, child: child);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Invisible edge tap zones. deferToChild keeps image taps
            // and interactive-card taps winning inside their bounds.
            return GestureDetector(
              onTapUp: (details) => _handleCardAreaTap(
                details.localPosition.dx,
                constraints.maxWidth,
              ),
              // Accessibility (rec #12): the card page area announces
              // its deck position before the card content is read.
              child: Semantics(
                container: true,
                label: 'Card ${index + 1} of ${widget.cardCount}',
                child: _CardScrollView(
                  index: index,
                  child: widget.cardBuilder(context, index),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The vertical scroll view around one card: PageStorage-keyed offset,
/// a thin scrollbar, and a bottom fade cue while more content remains
/// below the fold. Cards that fit show neither.
class _CardScrollView extends StatefulWidget {
  final int index;
  final Widget child;

  const _CardScrollView({required this.index, required this.child});

  @override
  State<_CardScrollView> createState() => _CardScrollViewState();
}

class _CardScrollViewState extends State<_CardScrollView> {
  final ScrollController _scrollController = ScrollController();
  bool _overflows = false;
  bool _moreBelow = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _syncMetrics(ScrollMetrics metrics) {
    final overflows = metrics.maxScrollExtent > 0;
    final moreBelow = overflows && metrics.extentAfter > 8;
    if (overflows == _overflows && moreBelow == _moreBelow) return;
    void apply() {
      if (!mounted) return;
      setState(() {
        _overflows = overflows;
        _moreBelow = moreBelow;
      });
    }

    // ScrollMetricsNotification arrives via microtask and scroll
    // updates via gesture/animation callbacks, so setState is safe;
    // guard the layout phase anyway.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        _syncMetrics(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _syncMetrics(notification.metrics);
          return false;
        },
        child: Stack(
          children: [
            RawScrollbar(
              controller: _scrollController,
              thumbVisibility: _overflows,
              thickness: 3,
              radius: const Radius.circular(1.5),
              thumbColor: Colors.white.withValues(alpha: 0.25),
              child: SingleChildScrollView(
                key: PageStorageKey<String>(
                    'learning_card_scroll_${widget.index}'),
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                child: widget.child,
              ),
            ),
            // "More below" fade cue; disappears at the end of the card.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 46,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  key: ValueKey<String>(
                      'learning_overflow_cue_${widget.index}'),
                  opacity: _moreBelow ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x00101418),
                          Color(0xCC101418),
                        ],
                      ),
                    ),
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

/// One small always-visible page-turn chevron in a side gutter. The
/// full-height strip is tappable (translucent, so drags starting on it
/// still reach the pager and the card scroll).
class _EdgeChevron extends StatelessWidget {
  final bool alignLeft;
  final VoidCallback onTap;

  const _EdgeChevron({required this.alignLeft, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: alignLeft ? 0 : null,
      right: alignLeft ? null : 0,
      top: 0,
      bottom: 0,
      width: 30,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: Center(
          child: Semantics(
            button: true,
            label: alignLeft ? 'Previous card' : 'Next card',
            child: Icon(
              alignLeft
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              size: 22,
              color: Colors.white.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// Position label below the carousel: the single card-granularity
/// signal ("X of N"). The old worm-dot strip rendered 187 dots at under
/// a pixel each on big decks and duplicated three other position
/// indicators, so it was removed (learning-screen v2 chrome diet).
class _CarouselPositionIndicator extends StatelessWidget {
  final int count;
  final Color accent;
  final PageController pageController;

  /// Page shown before the controller has laid out (it does not notify
  /// on its initial layout). The carousel passes its tracked current
  /// page so a non-zero initialPage (deep link or resume) reads
  /// correctly from the first frame instead of a stale '1 of N'.
  final int fallbackPage;

  const _CarouselPositionIndicator({
    required this.count,
    required this.accent,
    required this.pageController,
    this.fallbackPage = 0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pageController,
      builder: (context, _) {
        final page = pageController.hasClients &&
                pageController.position.haveDimensions
            ? (pageController.page ?? fallbackPage.toDouble())
            : fallbackPage.toDouble();
        final currentPage = page.round();

        return Text(
          '${currentPage + 1} of $count',
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
            color: accent.withValues(alpha: 0.6),
          ),
        );
      },
    );
  }
}

/// Claims a drag for the pager only when the pointer's travel is
/// clearly horizontal (|dx| more than twice |dy|, about 27 degrees off
/// the horizontal axis). Vertical and diagonal drags are left for the
/// card's own scroll view, so reading a long card never turns the page
/// by accident. This replaces the old gesture-arena race between the
/// PageView and the per-card SingleChildScrollView.
class _StronglyHorizontalDragRecognizer
    extends HorizontalDragGestureRecognizer {
  _StronglyHorizontalDragRecognizer({super.debugOwner});

  static const double _slopeRatio = 2.0;

  double _totalDx = 0;
  double _totalDy = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // Every new gesture starts with a pointer down: reset the travel
    // totals so a previous gesture's slope never leaks into this one.
    _totalDx = 0;
    _totalDy = 0;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _totalDx += event.localDelta.dx;
      _totalDy += event.localDelta.dy;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    if (!super.hasSufficientGlobalDistanceToAccept(
        pointerDeviceKind, deviceTouchSlop)) {
      return false;
    }
    return _totalDx.abs() > _slopeRatio * _totalDy.abs();
  }
}

/// Keeps the PageView's built-in drag recognizers off; page turns are
/// driven externally (tap zones, chevrons, moveToPage, and the
/// strongly horizontal recognizer feeding the scroll position
/// directly). Extends [ClampingScrollPhysics] so both axes share one
/// physics personality and drags stop hard at the first and last card.
class _ExternalDragOnlyPhysics extends ClampingScrollPhysics {
  const _ExternalDragOnlyPhysics({super.parent});

  @override
  _ExternalDragOnlyPhysics applyTo(ScrollPhysics? ancestor) =>
      _ExternalDragOnlyPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false;
}
