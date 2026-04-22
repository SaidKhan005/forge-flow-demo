import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

/// Swipeable teaching-card carousel for the Variance > Learn tab.
///
/// Forked from Barrio's `LearningCarousel`:
///
/// - Same `viewportFraction: 0.88` PageView so adjacent cards peek from
///   the edges.
/// - Same per-card transform: 3D Y-rotation (`rotateY`), scale, and
///   opacity driven by distance-from-active-page.
/// - Same entrance fade+slide on first build.
/// - Same CustomPaint "worm dot" position indicator that stretches
///   between dots during swipe.
///
/// Differences from the Barrio original:
///
/// - No `completedIndices` set — Variance Learn has no mastery tracking.
/// - No `requestAdvance` auto-advance timer — read-only cards don't
///   trigger "correct answer" auto-swipes.
/// - Position label uses `AppTextStyles.mono11` instead of
///   `GoogleFonts.ibmPlexMono`, and worm dots use `AppColors.sunset`
///   as the default accent — so the carousel matches the rest of the
///   Forge & Flow surfaces.
///
/// `cardBuilder` is expected to return a Forge & Flow-styled card
/// widget (e.g. `LearnTeachingCard`).
class LearnCarousel extends StatefulWidget {
  final int cardCount;
  final IndexedWidgetBuilder cardBuilder;
  final Color accent;
  final ValueChanged<int>? onPageChanged;

  const LearnCarousel({
    super.key,
    required this.cardCount,
    required this.cardBuilder,
    this.accent = AppColors.sunset,
    this.onPageChanged,
  });

  @override
  State<LearnCarousel> createState() => _LearnCarouselState();
}

class _LearnCarouselState extends State<LearnCarousel>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;

  late final AnimationController _entranceCtrl;
  late final Animation<double> _entranceFade;
  late final Animation<Offset> _entranceSlide;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.88);

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
  void didUpdateWidget(covariant LearnCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the chapter changes (key is swapped by the caller), reset to
    // the first card and re-play the entrance animation so the fresh
    // chapter reads as a new surface.
    if (oldWidget.key != widget.key) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      _entranceCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _entranceCtrl.dispose();
    super.dispose();
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
                        opacity =
                            (1.0 - distance * 0.4).clamp(0.5, 1.0);
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
                          horizontal: 4, vertical: 8),
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
              pageController: _pageController,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _CarouselPositionIndicator extends StatelessWidget {
  final int count;
  final Color accent;
  final PageController pageController;

  const _CarouselPositionIndicator({
    required this.count,
    required this.accent,
    required this.pageController,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pageController,
      builder: (context, _) {
        final page = pageController.hasClients &&
                pageController.position.haveDimensions
            ? (pageController.page ?? 0.0)
            : 0.0;
        final currentPage = page.round();

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                '${currentPage + 1} of $count',
                style: AppTextStyles.mono11(
                    color: accent.withValues(alpha: 0.7)),
              ),
            ),
            CustomPaint(
              size: Size(count * 12.0, 6),
              painter: _WormDotPainter(
                page: page,
                count: count,
                accent: accent,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _WormDotPainter extends CustomPainter {
  final double page;
  final int count;
  final Color accent;

  static const _dotSpacing = 12.0;
  static const _dotWidth = 6.0;
  static const _dotHeight = 3.0;
  static const _dotRadius = 1.5;

  _WormDotPainter({
    required this.page,
    required this.count,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;

    // Inactive dots
    for (var i = 0; i < count; i++) {
      final cx = i * _dotSpacing + _dotWidth / 2;
      final paint = Paint()
        ..color = AppColors.borderStrong.withValues(alpha: 0.5)
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

    // Worm (active indicator) — leading edge arrives first, trailing
    // catches up, creating the stretching pill effect.
    final currentIndex = page.floor().clamp(0, count - 1);
    final nextIndex = (currentIndex + 1).clamp(0, count - 1);
    final t = (page - currentIndex).clamp(0.0, 1.0);

    final currentCx = currentIndex * _dotSpacing + _dotWidth / 2;
    final nextCx = nextIndex * _dotSpacing + _dotWidth / 2;

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
        Rect.fromLTRB(
            left, cy - _dotHeight / 2, right, cy + _dotHeight / 2),
        const Radius.circular(_dotRadius),
      ),
      wormPaint,
    );
  }

  @override
  bool shouldRepaint(_WormDotPainter old) =>
      old.page != page ||
      old.count != count ||
      old.accent != accent;
}
