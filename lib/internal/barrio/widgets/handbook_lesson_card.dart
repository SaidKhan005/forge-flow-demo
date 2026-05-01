import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_celebration_overlay.dart';
import 'barrio_destination_scaffold.dart';
import '../content/company_handbook_content.dart';

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

  const HandbookLessonCard({
    super.key,
    required this.unit,
    this.onCompleted,
    this.isCarouselMode = false,
    this.cardPosition,
    this.onRequestAdvance,
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
                Text(
                  unit.body,
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
                Text(
                  unit.body,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    height: 1.8,
                    color: BarrioColors.textSecondary,
                  ),
                ),
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
