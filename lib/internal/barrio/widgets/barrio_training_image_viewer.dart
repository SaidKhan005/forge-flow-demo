import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'barrio_destination_scaffold.dart';

/// One picture in the full-screen viewer.
///
/// Credits are per picture, never shared across a slide group: each
/// photograph carries its own literal source caption
/// (`Photo: <creator>, <licence>`), so paging swaps the caption with the
/// picture. A caption is null only when the source gave none.
class BarrioTrainingImageSlide {
  final String assetPath;
  final String? caption;

  const BarrioTrainingImageSlide({required this.assetPath, this.caption});
}

/// Full-screen viewer for training content pictures.
///
/// Warm cream backdrop, pinch-zoom via [InteractiveViewer], a close
/// button in a soft circular chip, and the current picture's literal
/// source caption on a cream pill. No looping animation. Opened by
/// tapping an inline picture in a training lesson card.
///
/// Slide paging (T10, 2026-08-02): a card whose picture holder carries
/// more than one photograph opens the viewer with the whole slide list
/// and the slide that was on screen, and the reader swipes between them.
/// A real [PageView] is safe HERE and nowhere else: this is a separate
/// route, so none of the reading deck's page-turn recognizers are in the
/// arena. Paging locks while the picture on screen is zoomed in, so a
/// pinch pan never fights the swipe.
///
/// Degrade rule: a one-picture open renders exactly what it always has.
/// The pager holds a single page (nothing to swipe to), the caption pill
/// is the same pill, and the screen-reader label stays the bare caption
/// with no position tail.
class BarrioTrainingImageViewer extends StatefulWidget {
  /// The pictures to page between, in reading order. Never empty.
  final List<BarrioTrainingImageSlide> slides;

  /// The slide to open on. Opening from slide k lands on slide k.
  final int initialIndex;

  const BarrioTrainingImageViewer({
    super.key,
    required this.slides,
    this.initialIndex = 0,
  });

  /// Pushes the viewer as a full-screen route.
  static Future<void> open(
    BuildContext context, {
    required List<BarrioTrainingImageSlide> slides,
    int initialIndex = 0,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => BarrioTrainingImageViewer(
          slides: slides,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  @override
  State<BarrioTrainingImageViewer> createState() =>
      _BarrioTrainingImageViewerState();
}

class _BarrioTrainingImageViewerState extends State<BarrioTrainingImageViewer> {
  late final PageController _pageController;
  late int _index;

  /// True while the picture on screen is zoomed past its fitted size.
  /// Reported by the slide itself; locks paging so a pinch pan stays a
  /// pan.
  bool _zoomed = false;

  bool get _isSlideshow => widget.slides.length > 1;

  @override
  void initState() {
    super.initState();
    // Defensive clamp: an out-of-range initialIndex lands on the nearest
    // real slide instead of throwing mid-route.
    _index = widget.slides.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.slides.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleZoomChanged(bool zoomed) {
    if (!mounted || zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  @override
  Widget build(BuildContext context) {
    final caption =
        widget.slides.isEmpty ? null : widget.slides[_index].caption;
    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildPager()),
            if (caption != null || _isSlideshow)
              Positioned(
                left: 20,
                right: 20,
                bottom: 16,
                child: Center(child: _buildFooter(caption)),
              ),
            Positioned(top: 8, right: 8, child: _buildCloseChip(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildPager() {
    return PageView.builder(
      controller: _pageController,
      // One physics personality with the reading deck: clamp, no bounce.
      // Locked outright while the picture on screen is zoomed in.
      physics: _zoomed
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      itemCount: widget.slides.length,
      onPageChanged: (page) => setState(() {
        _index = page;
        // A page that scrolls away is rebuilt at rest, so the lock must
        // not survive the turn.
        _zoomed = false;
      }),
      itemBuilder: (context, index) => _ViewerSlide(
        slide: widget.slides[index],
        position:
            _isSlideshow ? '${index + 1} of ${widget.slides.length}' : null,
        onZoomChanged: _handleZoomChanged,
      ),
    );
  }

  /// The bottom chrome: the slide position (slideshows only) above the
  /// current picture's literal source caption on its cream pill. A lone
  /// captioned picture renders the pill and nothing else, exactly as it
  /// always has.
  Widget _buildFooter(String? caption) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isSlideshow) ...[
          // Excluded from semantics: the picture's own label already
          // ends in 'Photo K of N', so position must not read twice.
          ExcludeSemantics(
            child: Text(
              '${_index + 1} of ${widget.slides.length}',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: BarrioColors.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (caption != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: BarrioColors.shellMid.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              caption,
              textAlign: TextAlign.center,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 12,
                color: BarrioColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCloseChip(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: BarrioColors.shellMid.withValues(alpha: 0.82),
        border: Border.all(color: const Color(0x2216243B)),
      ),
      child: IconButton(
        tooltip: 'Close',
        icon: const Icon(Icons.close_rounded),
        color: BarrioColors.textPrimary,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

/// One zoomable page of the viewer.
///
/// Owns its own [TransformationController] so each picture's zoom state
/// is its own, and reports the zoomed/at-rest flip to the pager. Pan is
/// enabled ONLY once the picture is zoomed in: at rest a horizontal drag
/// belongs to the pager, so a swipe between pictures is never swallowed
/// by the [InteractiveViewer]'s own recognizer.
class _ViewerSlide extends StatefulWidget {
  final BarrioTrainingImageSlide slide;

  /// Plain-English position ('2 of 3') appended to the screen-reader
  /// label when the viewer holds more than one picture. Null for a lone
  /// picture, which keeps the label it has always had.
  final String? position;

  final ValueChanged<bool> onZoomChanged;

  const _ViewerSlide({
    required this.slide,
    required this.position,
    required this.onZoomChanged,
  });

  @override
  State<_ViewerSlide> createState() => _ViewerSlideState();
}

class _ViewerSlideState extends State<_ViewerSlide> {
  final TransformationController _transform = TransformationController();
  bool _zoomed = false;

  /// Scale slack so floating-point drift at the fitted size never reads
  /// as "zoomed in".
  static const double _zoomEpsilon = 1.01;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_syncZoom);
  }

  @override
  void dispose() {
    _transform.removeListener(_syncZoom);
    _transform.dispose();
    super.dispose();
  }

  void _syncZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > _zoomEpsilon;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  /// Accessibility (rec #12): the literal caption when present, else
  /// 'Photo'. Never invented. A slideshow appends the plain-English
  /// position, mirroring the reading deck's 'Card X of Y'.
  String get _semanticLabel {
    final base = widget.slide.caption ?? 'Photo';
    final position = widget.position;
    if (position == null) return base;
    final stem = base.endsWith('.')
        ? base.substring(0, base.length - 1)
        : base;
    return '$stem. Photo $position';
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transform,
      maxScale: 5,
      panEnabled: _zoomed,
      child: Center(
        child: Image.asset(
          widget.slide.assetPath,
          semanticLabel: _semanticLabel,
          errorBuilder: (context, error, stackTrace) => const Icon(
            Icons.image_not_supported_outlined,
            size: 48,
            color: BarrioColors.textMuted,
          ),
        ),
      ),
    );
  }
}
