import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_celebration_overlay.dart';
import 'barrio_destination_scaffold.dart';

/// Generic option model for interactive learning cards.
class LearningOption {
  final String label;
  final bool isCorrect;
  final String feedback;
  const LearningOption({
    required this.label,
    required this.isCorrect,
    required this.feedback,
  });
}

final _whitespaceRegExp = RegExp(r'\s+');

/// Premium light glassmorphism learning card.
///
/// Supports three modes based on [badgeLabel]:
/// - GUIDE / CONCEPT = read-only explainer
/// - SCENARIO / DECIDE = interactive decision
/// - CHECK = checkpoint/quiz interaction
///
/// Features: expand/collapse, reading time, correct-answer sparkle,
/// haptic feedback, staggered option reveal.
///
/// Shared by Interview Playbook and Jim Taylor surfaces.
class LearningSurfaceCard extends StatefulWidget {
  final String title;
  final String body;
  final String badgeLabel;
  final Color badgeColor;
  final List<LearningOption> options;
  final VoidCallback? onCompleted;
  final bool isCarouselMode;
  final String? cardPosition;
  final VoidCallback? onRequestAdvance;

  const LearningSurfaceCard({
    super.key,
    required this.title,
    required this.body,
    required this.badgeLabel,
    required this.badgeColor,
    this.options = const [],
    this.onCompleted,
    this.isCarouselMode = false,
    this.cardPosition,
    this.onRequestAdvance,
  });

  @override
  State<LearningSurfaceCard> createState() => _LearningSurfaceCardState();
}

class _LearningSurfaceCardState extends State<LearningSurfaceCard>
    with SingleTickerProviderStateMixin {
  int? _selected;
  bool _expanded = false;
  bool _showSparkle = false;
  bool _isPressed = false;

  /// Estimate reading time based on word count (200 wpm average).
  String get _readingTime {
    final words = widget.body.split(_whitespaceRegExp).length +
        widget.options.fold<int>(0, (sum, o) => sum + o.label.split(_whitespaceRegExp).length);
    final minutes = (words / 200).ceil().clamp(1, 99);
    return '~$minutes min';
  }

  bool get _isReadOnly => widget.options.isEmpty;

  @override
  Widget build(BuildContext context) {
    final carousel = widget.isCarouselMode;

    return GestureDetector(
      onTapDown: !_isReadOnly && !_expanded
          ? (_) {
              HapticFeedback.lightImpact();
              setState(() => _isPressed = true);
            }
          : null,
      onTapUp: !_isReadOnly && !_expanded
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
            color: BarrioColors.glassFill, // premium white glass fill
            borderRadius: BorderRadius.circular(BarrioRadii.card),
            border: Border.all(
              color: widget.badgeColor.withValues(alpha: 0.35),
            ),
            // One neutral navy lift, no colored glow — identical to the twin
            // [HandbookLessonCard] so the two cards share a shadow language
            // (and one shadow pass instead of two).
            boxShadow: barrioSoftShadow(
              y: _isPressed ? 4 : 10,
              blur: _isPressed ? 14 : 24,
              opacity: _isPressed ? 0.14 : 0.10,
            ),
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
                          widget.badgeColor.withValues(alpha: 0.05),
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
              // Badge + title + reading time
              Row(
                children: [
                  _PremiumBadge(
                    label: widget.badgeLabel,
                    color: widget.badgeColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: BarrioColors.textPrimary,
                      ),
                    ),
                  ),
                  if (!_isReadOnly && !carousel) ...[
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

              // Collapsed preview: first line only for interactive cards (list mode)
              if (!_isReadOnly && !_expanded && !carousel) ...[
                const SizedBox(height: 10),
                Text(
                  widget.body,
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
                      color: widget.badgeColor.withValues(alpha: 0.45),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Tap to expand',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        color: widget.badgeColor.withValues(alpha: 0.45),
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ],

              // Carousel mode: show full body + "Tap to begin" for interactive cards
              if (carousel && !_isReadOnly && !_expanded) ...[
                const SizedBox(height: 14),
                Text(
                  widget.body,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    height: 1.8,
                    color: BarrioColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.touch_app_rounded,
                      size: 16,
                      color: widget.badgeColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Tap to begin',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: widget.badgeColor.withValues(alpha: 0.5),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ],

              // Expanded body (always for read-only; when expanded for interactive in any mode)
              if (_isReadOnly || _expanded) ...[
                const SizedBox(height: 14),
                Text(
                  widget.body,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    height: 1.8,
                    color: BarrioColors.textSecondary,
                  ),
                ),
              ],

              // Interactive options (only when expanded)
              if (widget.options.isNotEmpty && _expanded) ...[
                const SizedBox(height: 16),
                ...List.generate(widget.options.length, (i) {
                  final opt = widget.options[i];
                  final isSelected = _selected == i;
                  final isRevealed = _selected != null;
                  final showCorrect = isRevealed && opt.isCorrect;
                  final showWrong = isSelected && !opt.isCorrect;

                  Color border, bg;
                  if (showCorrect) {
                    border = BarrioColors.success.withValues(alpha: 0.55);
                    bg = BarrioColors.success.withValues(alpha: 0.10);
                  } else if (showWrong) {
                    border = BarrioColors.error.withValues(alpha: 0.55);
                    bg = BarrioColors.error.withValues(alpha: 0.10);
                  } else {
                    border = const Color(0x2216243B);
                    bg = const Color(0x0A16243B);
                  }

                  return _StaggeredOption(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: _selected == null ? () => _select(i) : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: bg,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Text(
                                  String.fromCharCode(0x41 + i),
                                  style: GoogleFonts.ibmPlexMono(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    // Slate stays legible on the white card
                                    // for any per-card badge accent.
                                    color: BarrioColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    opt.label,
                                    style: GoogleFonts.ibmPlexSans(
                                      fontSize: 13,
                                      color: BarrioColors.textPrimary,
                                    ),
                                  ),
                                ),
                                if (showCorrect) ...[
                                  if (_showSparkle)
                                    CorrectAnswerSparkle(
                                      accentColor: BarrioColors.success,
                                      onComplete: () {
                                        if (mounted) {
                                          setState(() => _showSparkle = false);
                                        }
                                      },
                                    ),
                                  const Icon(Icons.check_circle,
                                      size: 18, color: BarrioColors.success),
                                ],
                                if (showWrong)
                                  const Icon(Icons.cancel,
                                      size: 18, color: BarrioColors.error),
                              ]),
                              if (isSelected) ...[
                                const SizedBox(height: 8),
                                Text(
                                  opt.feedback,
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
                    ),
                  );
                }),
              ],

              // Read-only hint
              if (_isReadOnly) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: widget.badgeColor.withValues(alpha: 0.35),
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

  void _select(int i) {
    setState(() {
      _selected = i;
      if (widget.options[i].isCorrect) _showSparkle = true;
    });
    if (widget.options[i].isCorrect) {
      HapticFeedback.mediumImpact();
      widget.onCompleted?.call();
      widget.onRequestAdvance?.call();
    } else {
      HapticFeedback.lightImpact();
    }
  }
}

/// Premium badge with subtle gradient depth.
class _PremiumBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _PremiumBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    // Solid accent chip with a luminance-picked foreground so the label
    // stays legible on the white card (the old pale-tint-on-dark badge
    // relied on bright accent text against a dark surface).
    final onColor = barrioOnAccent(color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.28),
            blurRadius: 5,
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
          color: onColor,
        ),
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

// ---------------------------------------------------------------------------
// Generic section/module rail — shared by Playbook and Jim Taylor screens
// ---------------------------------------------------------------------------

/// Constant icon lookup for section/module rail icons.
/// Maps each known iconCodePoint to its tree-shake-friendly Icons constant
/// so that release builds can eliminate unused glyphs from MaterialIcons.
const _sectionIcons = <int, IconData>{
  // Interview Playbook sections
  0xf06be: Icons.handshake,
  0xe2b9: Icons.format_list_numbered,
  0xe28e: Icons.flag,
  0xe0c8: Icons.badge,
  // Jim Taylor modules
  0xe2c9: Icons.foundation,
  0xf0547: Icons.percent,
  0xe59f: Icons.show_chart,
  0xe5e0: Icons.speed,
};

/// Horizontal section selector with per-destination accent color.
class LearningSectionRail extends StatelessWidget {
  final List<String> titles;
  final List<int> iconCodePoints;
  final int activeIndex;
  final Color activeAccent;
  final Set<int> completedIndices;
  final ValueChanged<int> onTap;

  const LearningSectionRail({
    super.key,
    required this.titles,
    required this.iconCodePoints,
    required this.activeIndex,
    required this.completedIndices,
    required this.onTap,
    this.activeAccent = BarrioColors.tealWarm,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: titles.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final isActive = i == activeIndex;
          final isComplete = completedIndices.contains(i);

          return GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isActive
                    ? activeAccent.withValues(alpha: 0.15)
                    : const Color(0x0A16243B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isActive
                      ? activeAccent.withValues(alpha: 0.50)
                      : const Color(0x2216243B),
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: activeAccent.withValues(alpha: 0.20),
                          blurRadius: 10,
                          spreadRadius: 0,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _sectionIcons[iconCodePoints[i]] ??
                            Icons.circle_outlined,
                        size: 16,
                        color: isActive ? activeAccent : BarrioColors.textMuted,
                      ),
                      if (isComplete) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.check_circle,
                            size: 12, color: BarrioColors.success),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    titles[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 12,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive
                          ? BarrioColors.textPrimary
                          : BarrioColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
