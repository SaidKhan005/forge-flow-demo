import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Premium horizontal PageView carousel for learning content.
///
/// Replaces linear ListView scroll with a depth-stacked card swiper.
/// Adjacent cards peek from edges (viewportFraction 0.88), scale down,
/// tilt in 3D perspective, and dim — giving spatial context and a
/// premium Masterclass-like feel.
///
/// Features:
/// - 3D perspective tilt on non-active cards (Matrix4 rotateY)
/// - Depth transforms (scale + opacity)
/// - Breathing accent glow on the active card
/// - Worm dot indicator with smooth stretching pill
/// - Auto-advance timer after correct answers
/// - Entrance animation on chapter/section change
class LearningCarousel extends StatefulWidget {
  final int cardCount;
  final IndexedWidgetBuilder cardBuilder;
  final Color accent;
  final Set<int> completedIndices;
  final ValueChanged<int>? onPageChanged;

  /// Page the carousel opens on. Only read when the State mounts, so
  /// callers that need a programmatic jump re-mount with a new [key]
  /// (the training screen's chapter-rail taps do exactly that).
  final int initialPage;

  const LearningCarousel({
    super.key,
    required this.cardCount,
    required this.cardBuilder,
    required this.accent,
    this.completedIndices = const {},
    this.onPageChanged,
    this.initialPage = 0,
  });

  @override
  State<LearningCarousel> createState() => LearningCarouselState();
}

class LearningCarouselState extends State<LearningCarousel>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  int _currentPage = 0;
  Timer? _autoAdvanceTimer;

  // Entrance animation
  late final AnimationController _entranceCtrl;
  late final Animation<double> _entranceFade;
  late final Animation<Offset> _entranceSlide;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _pageController = PageController(
      viewportFraction: 0.88,
      initialPage: widget.initialPage,
    );

    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
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
  void didUpdateWidget(covariant LearningCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.key != widget.key) {
      _currentPage = 0;
      _cancelAutoAdvance();
      _entranceCtrl.forward(from: 0);
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

  void _cancelAutoAdvance() {
    _autoAdvanceTimer?.cancel();
    _autoAdvanceTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _entranceFade,
      child: SlideTransition(
        position: _entranceSlide,
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                physics: const BouncingScrollPhysics(),
                itemCount: widget.cardCount,
                onPageChanged: (page) {
                  _cancelAutoAdvance();
                  setState(() => _currentPage = page);
                  widget.onPageChanged?.call(page);
                },
                itemBuilder: (context, index) {
                  return AnimatedBuilder(
                    animation: _pageController,
                    builder: (context, child) {
                      double scale = 1.0;
                      double opacity = 1.0;
                      double rotationY = 0.0;

                      if (_pageController.position.haveDimensions) {
                        final page = _pageController.page ?? 0.0;
                        final distance = (page - index).abs();
                        final delta = page - index;
                        scale = (1.0 - distance * 0.08).clamp(0.88, 1.0);
                        opacity = (1.0 - distance * 0.4).clamp(0.5, 1.0);
                        // 3D perspective tilt — adjacent cards rotate toward center
                        rotationY = -delta.clamp(-1.0, 1.0) * 0.07;
                      }

                      return Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.001)
                          ..rotateY(rotationY),
                        child: Transform.scale(
                          scale: scale,
                          child: Opacity(
                            opacity: opacity,
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: widget.cardBuilder(context, index),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            _CarouselPositionIndicator(
              count: widget.cardCount,
              accent: widget.accent,
              completedIndices: widget.completedIndices,
              pageController: _pageController,
              fallbackPage: _currentPage,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Smooth worm dot indicator below the carousel.
///
/// Uses [CustomPainter] for a continuously interpolating "worm" pill
/// that stretches between positions during swipe. The leading edge
/// reaches the next dot before the trailing edge leaves, creating
/// an organic stretch effect.
class _CarouselPositionIndicator extends StatelessWidget {
  final int count;
  final Color accent;
  final Set<int> completedIndices;
  final PageController pageController;

  /// Page shown before the controller has laid out (it does not notify
  /// on its initial layout). The carousel passes its tracked current
  /// page so a non-zero initialPage (deep link or resume) reads
  /// correctly from the first frame instead of a stale '1 of N'.
  final int fallbackPage;

  const _CarouselPositionIndicator({
    required this.count,
    required this.accent,
    required this.completedIndices,
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

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Card position label
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '${currentPage + 1} of $count',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                  color: accent.withValues(alpha: 0.6),
                ),
              ),
            ),
            // Worm dots. Whole-document swiping can put dozens of cards
            // in one carousel, so the dot strip scales down instead of
            // overflowing the row on phone widths.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: CustomPaint(
                  size: Size(count * 12.0, 6),
                  painter: _WormDotPainter(
                    page: page,
                    count: count,
                    accent: accent,
                    completedIndices: completedIndices,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// CustomPainter for the worm dot indicator.
///
/// Draws inactive dots for all positions, then overlays a stretching
/// "worm" pill that interpolates between the current and next dot.
class _WormDotPainter extends CustomPainter {
  final double page;
  final int count;
  final Color accent;
  final Set<int> completedIndices;

  static const _dotSpacing = 12.0;
  static const _dotWidth = 6.0;
  static const _dotHeight = 3.0;
  static const _dotRadius = 1.5;

  _WormDotPainter({
    required this.page,
    required this.count,
    required this.accent,
    required this.completedIndices,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;

    // Draw inactive dots
    for (var i = 0; i < count; i++) {
      final cx = i * _dotSpacing + _dotWidth / 2;
      final isCompleted = completedIndices.contains(i);

      final paint = Paint()
        ..color = isCompleted
            ? accent.withValues(alpha: 0.35)
            : const Color(0x30FFFFFF)
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx, cy),
            width: _dotWidth,
            height: _dotHeight,
          ),
          const Radius.circular(_dotRadius),
        ),
        paint,
      );
    }

    // Draw the worm (active indicator)
    final currentIndex = page.floor().clamp(0, count - 1);
    final nextIndex = (currentIndex + 1).clamp(0, count - 1);
    final t = (page - currentIndex).clamp(0.0, 1.0);

    final currentCx = currentIndex * _dotSpacing + _dotWidth / 2;
    final nextCx = nextIndex * _dotSpacing + _dotWidth / 2;

    // Leading edge arrives first (easeIn), trailing catches up (easeOut)
    final leadingT = Curves.easeIn.transform(t);
    final trailingT = Curves.easeOut.transform(t);

    final left = ui.lerpDouble(currentCx - _dotWidth / 2,
        nextCx - _dotWidth / 2, trailingT)!;
    final right = ui.lerpDouble(currentCx + _dotWidth / 2,
        nextCx + _dotWidth / 2, leadingT)!;

    final wormPaint = Paint()
      ..color = accent
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(left, cy - _dotHeight / 2, right, cy + _dotHeight / 2),
        const Radius.circular(_dotRadius),
      ),
      wormPaint,
    );
  }

  @override
  bool shouldRepaint(_WormDotPainter old) =>
      old.page != page || old.count != count;
}
