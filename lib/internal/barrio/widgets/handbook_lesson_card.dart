import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_celebration_overlay.dart';
import 'barrio_destination_scaffold.dart';
import 'barrio_training_image_viewer.dart';
import '../content/company_handbook_content.dart';
import '../search/barrio_training_search.dart';

final _whitespaceRegExp = RegExp(r'\s+');

/// Renders a single [HandbookUnit] as a premium dark glassmorphism card.
///
/// Features: expand/collapse for interactive cards, reading time estimate,
/// correct-answer sparkle, haptic feedback, premium badge depth.
///
/// Explainer units show body text (always expanded). Decision and checkpoint
/// units show interactive options with feedback revealed after selection.
class HandbookLessonCard extends StatefulWidget {
  final HandbookUnit unit;
  final VoidCallback? onCompleted;
  final bool isCarouselMode;
  final String? cardPosition;
  final VoidCallback? onRequestAdvance;

  /// Search deep-link highlighting (2026-07-11 operator request): folded
  /// query words to mark inside the body text. Matching is
  /// case- and diacritic-insensitive via the search service's
  /// length-preserving fold, so span offsets apply to the original
  /// text directly. Empty = no highlighting (the default everywhere
  /// outside a search deep link).
  final List<String> highlightTerms;

  const HandbookLessonCard({
    super.key,
    required this.unit,
    this.onCompleted,
    this.isCarouselMode = false,
    this.cardPosition,
    this.onRequestAdvance,
    this.highlightTerms = const [],
  });

  @override
  State<HandbookLessonCard> createState() => _HandbookLessonCardState();
}

class _HandbookLessonCardState extends State<HandbookLessonCard> {
  int? _selectedIndex;
  bool _expanded = false;
  bool _showSparkle = false;
  bool _isPressed = false;

  Color get _borderColor {
    switch (widget.unit.type) {
      case HandbookUnitType.explainer:
        return const Color(0x22FFFFFF);
      case HandbookUnitType.decision:
        return const Color(0xFF2ECC71).withValues(alpha: 0.22);
      case HandbookUnitType.checkpoint:
        return const Color(0xFFF39C12).withValues(alpha: 0.22);
    }
  }

  bool get _isInteractive => widget.unit.type != HandbookUnitType.explainer;

  String get _readingTime {
    final words = widget.unit.body.split(_whitespaceRegExp).length +
        widget.unit.options.fold<int>(
            0, (sum, o) => sum + o.label.split(_whitespaceRegExp).length);
    final minutes = (words / 200).ceil().clamp(1, 99);
    return '~$minutes min';
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.unit;

    final carousel = widget.isCarouselMode;

    return GestureDetector(
      onTapDown: _isInteractive && !_expanded
          ? (_) {
              HapticFeedback.lightImpact();
              setState(() => _isPressed = true);
            }
          : null,
      onTapUp: _isInteractive && !_expanded
          ? (_) {
              setState(() {
                _isPressed = false;
                _expanded = true;
              });
            }
          : null,
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutBack,
        child: Container(
          margin: carousel ? EdgeInsets.zero : const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF), // premium glass fill
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _borderColor),
            boxShadow: [
              // Inner accent glow
              BoxShadow(
                color: _badgeColor.withValues(alpha: _isPressed ? 0.22 : 0.10),
                blurRadius: _isPressed ? 12 : 20,
                spreadRadius: -4,
              ),
              // Outer ambient shadow
              BoxShadow(
                color: const Color(0x44000000),
                blurRadius: _isPressed ? 14 : 28,
                spreadRadius: _isPressed ? -6 : -2,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Specular highlight — overhead light catch
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.7, -0.8),
                        radius: 0.8,
                        colors: [
                          Colors.white.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Accent bottom tint
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          _badgeColor.withValues(alpha: 0.05),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Content
              Padding(
                padding: const EdgeInsets.all(20),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _TypeBadge(type: unit.type, badgeHint: unit.badgeHint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      unit.title,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: BarrioColors.textPrimary,
                      ),
                    ),
                  ),
                  if (_isInteractive && !carousel) ...[
                    const SizedBox(width: 8),
                    Text(
                      _readingTime,
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        color: BarrioColors.textMuted.withValues(alpha: 0.7),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ],
              ),

              // Collapsed preview for interactive cards (list mode only)
              if (_isInteractive && !_expanded && !carousel) ...[
                const SizedBox(height: 10),
                Text(
                  unit.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    height: 1.8,
                    color: BarrioColors.textSecondary.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: _badgeColor.withValues(alpha: 0.45),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Tap to expand',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        color: _badgeColor.withValues(alpha: 0.45),
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ],

              // Carousel mode: show full body + "Tap to begin" for interactive cards
              if (carousel && _isInteractive && !_expanded) ...[
                const SizedBox(height: 14),
                _UnitBody(unit: unit, highlightTerms: widget.highlightTerms),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.touch_app_rounded,
                      size: 16,
                      color: _badgeColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Tap to begin',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _badgeColor.withValues(alpha: 0.5),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ],

              // Full body (always shown for explainers; list mode: shown when expanded;
              // carousel mode: shown when expanded since pre-expand body is in the carousel block above)
              if (!_isInteractive || _expanded) ...[
                const SizedBox(height: 14),
                _UnitBody(unit: unit, highlightTerms: widget.highlightTerms),
              ],

              if (_isInteractive && _expanded && unit.options.isNotEmpty) ...[
                const SizedBox(height: 16),
                ...List.generate(unit.options.length, (i) {
                  return _StaggeredOption(
                    index: i,
                    child: _OptionTile(
                      option: unit.options[i],
                      index: i,
                      selectedIndex: _selectedIndex,
                      showSparkle: _showSparkle && unit.options[i].isCorrect,
                      onSparkleComplete: () {
                        if (mounted) setState(() => _showSparkle = false);
                      },
                      onTap: _selectedIndex == null
                          ? () => _selectOption(i)
                          : null,
                    ),
                  );
                }),
              ],
              if (!_isInteractive) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: BarrioColors.tealWarm.withValues(alpha: 0.35),
                  ),
                ),
              ],
                  ],
                ),
              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color get _badgeColor {
    return switch (widget.unit.type) {
      HandbookUnitType.explainer  => BarrioColors.tealWarm,
      HandbookUnitType.decision   => const Color(0xFF2ECC71),
      HandbookUnitType.checkpoint => const Color(0xFFF39C12),
    };
  }

  void _selectOption(int index) {
    setState(() {
      _selectedIndex = index;
      if (widget.unit.options[index].isCorrect) _showSparkle = true;
    });
    if (widget.unit.options[index].isCorrect) {
      HapticFeedback.mediumImpact();
      widget.onCompleted?.call();
      widget.onRequestAdvance?.call();
    } else {
      HapticFeedback.lightImpact();
    }
  }
}

class _TypeBadge extends StatelessWidget {
  final HandbookUnitType type;
  final String? badgeHint;
  const _TypeBadge({required this.type, this.badgeHint});

  @override
  Widget build(BuildContext context) {
    final (defaultLabel, color) = switch (type) {
      HandbookUnitType.explainer  => ('LEARN',  BarrioColors.tealWarm),
      HandbookUnitType.decision   => ('DECIDE', const Color(0xFF2ECC71)),
      HandbookUnitType.checkpoint => ('CHECK',  const Color(0xFFF39C12)),
    };
    final label = badgeHint ?? defaultLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: color,
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final HandbookOption option;
  final int index;
  final int? selectedIndex;
  final bool showSparkle;
  final VoidCallback? onSparkleComplete;
  final VoidCallback? onTap;

  const _OptionTile({
    required this.option,
    required this.index,
    required this.selectedIndex,
    this.showSparkle = false,
    this.onSparkleComplete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selectedIndex == index;
    final isRevealed = selectedIndex != null;
    final showCorrect = isRevealed && option.isCorrect;
    final showWrong = isSelected && !option.isCorrect;

    Color borderColor;
    Color bgColor;
    if (showCorrect) {
      borderColor = const Color(0xFF2ECC71).withValues(alpha: 0.55);
      bgColor = const Color(0xFF2ECC71).withValues(alpha: 0.10);
    } else if (showWrong) {
      borderColor = const Color(0xFFE74C3C).withValues(alpha: 0.55);
      bgColor = const Color(0xFFE74C3C).withValues(alpha: 0.10);
    } else {
      borderColor = const Color(0x1AFFFFFF);
      bgColor = const Color(0x08FFFFFF);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    String.fromCharCode(0x41 + index),
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: BarrioColors.tealWarm,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      option.label,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        color: BarrioColors.textPrimary,
                      ),
                    ),
                  ),
                  if (showCorrect) ...[
                    if (showSparkle)
                      CorrectAnswerSparkle(
                        accentColor: const Color(0xFF2ECC71),
                        onComplete: onSparkleComplete,
                      ),
                    const Icon(Icons.check_circle,
                        size: 18, color: Color(0xFF2ECC71)),
                  ],
                  if (showWrong)
                    const Icon(Icons.cancel, size: 18, color: Color(0xFFE74C3C)),
                ],
              ),
              if (isSelected) ...[
                const SizedBox(height: 8),
                Text(
                  option.feedback,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12,
                    height: 1.55,
                    fontStyle: FontStyle.italic,
                    color: BarrioColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Full unit body. Units without images render the exact single-Text path
/// the card always used (zero visual diff). Units with images split the
/// body on blank-line paragraphs and insert each image after its
/// [HandbookUnitImage.afterParagraph] index (-1 = before the first
/// paragraph); paragraph runs between images stay joined so their text
/// renders identically to the no-image path.
class _UnitBody extends StatelessWidget {
  final HandbookUnit unit;
  final List<String> highlightTerms;
  const _UnitBody({required this.unit, this.highlightTerms = const []});

  @override
  Widget build(BuildContext context) {
    final style = GoogleFonts.ibmPlexSans(
      fontSize: 13,
      height: 1.8,
      color: BarrioColors.textSecondary,
    );
    if (unit.images.isEmpty) {
      return _bodyText(unit.body, style);
    }

    final paragraphs = unit.body.split('\n\n');
    final byBoundary = <int, List<HandbookUnitImage>>{};
    for (final image in unit.images) {
      final boundary = image.afterParagraph.clamp(-1, paragraphs.length - 1);
      byBoundary.putIfAbsent(boundary, () => []).add(image);
    }

    final children = <Widget>[];
    for (final image in byBoundary[-1] ?? const <HandbookUnitImage>[]) {
      children.add(_UnitImage(image: image));
    }
    var runStart = 0;
    for (var p = 0; p < paragraphs.length; p++) {
      final imagesAfter = byBoundary[p];
      if (imagesAfter == null) continue;
      children.add(
        _bodyText(paragraphs.sublist(runStart, p + 1).join('\n\n'), style),
      );
      children.addAll(imagesAfter.map((image) => _UnitImage(image: image)));
      runStart = p + 1;
    }
    if (runStart < paragraphs.length) {
      children.add(
        _bodyText(paragraphs.sublist(runStart).join('\n\n'), style),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// Plain body text, or highlighted runs when search deep-link terms
  /// are present. The search fold is length-preserving per code unit,
  /// so fold-space match offsets index the original string directly.
  Widget _bodyText(String text, TextStyle style) {
    if (highlightTerms.isEmpty) {
      return Text(text, style: style);
    }
    final ranges =
        _mergeRanges(_rawMatchRanges(BarrioTrainingSearch.fold(text)));
    if (ranges.isEmpty) {
      return Text(text, style: style);
    }
    return Text.rich(
      TextSpan(style: style, children: _highlightSpans(text, ranges, style)),
    );
  }

  /// All [start, end) fold-space match ranges of every term, unsorted.
  List<List<int>> _rawMatchRanges(String folded) {
    final ranges = <List<int>>[];
    for (final term in highlightTerms) {
      if (term.isEmpty) continue;
      var idx = folded.indexOf(term);
      while (idx >= 0) {
        ranges.add([idx, idx + term.length]);
        idx = folded.indexOf(term, idx + term.length);
      }
    }
    return ranges;
  }

  /// Sorts ranges and merges overlaps so span runs never intersect.
  List<List<int>> _mergeRanges(List<List<int>> ranges) {
    if (ranges.isEmpty) return ranges;
    ranges.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<int>>[ranges.first];
    for (final r in ranges.skip(1)) {
      if (r[0] > merged.last[1]) {
        merged.add(r);
      } else if (r[1] > merged.last[1]) {
        merged.last[1] = r[1];
      }
    }
    return merged;
  }

  List<TextSpan> _highlightSpans(
    String text,
    List<List<int>> merged,
    TextStyle style,
  ) {
    final mark = style.copyWith(
      color: BarrioColors.textPrimary,
      fontWeight: FontWeight.w700,
      backgroundColor: BarrioColors.tealWarm.withValues(alpha: 0.28),
    );
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final r in merged) {
      if (r[0] > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, r[0])));
      }
      spans.add(TextSpan(text: text.substring(r[0], r[1]), style: mark));
      cursor = r[1];
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }
}

/// One content picture inside a unit body: rounded corners, full card
/// width, tap to open the full-screen viewer. The [Image.asset]
/// errorBuilder keeps widget tests (no bundled assets) from throwing.
class _UnitImage extends StatelessWidget {
  final HandbookUnitImage image;
  const _UnitImage({required this.image});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => BarrioTrainingImageViewer.open(
              context,
              assetPath: image.assetPath,
              caption: image.caption,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                image.assetPath,
                width: double.infinity,
                fit: BoxFit.fitWidth,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: double.infinity,
                  height: 120,
                  color: const Color(0x14FFFFFF),
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 28,
                    color: BarrioColors.textMuted.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
          if (image.caption != null) ...[
            const SizedBox(height: 6),
            Text(
              image.caption!,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: BarrioColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Staggered option animation for premium reveal.
class _StaggeredOption extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredOption({required this.index, required this.child});

  @override
  State<_StaggeredOption> createState() => _StaggeredOptionState();
}

class _StaggeredOptionState extends State<_StaggeredOption>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.15),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: 100 * widget.index), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
