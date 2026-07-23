// The two-sided flashcard for `BarrioFlashcardReviewScreen` (operator
// rec #5, 2026-07-23). Front: the term (plus its source picture when
// the unit has one). Back: the VERBATIM definition body, unchanged,
// scrollable, with the literal source caption when present.
//
// Tap anywhere on the card to flip (simple perspective Y-rotation;
// `MediaQuery.disableAnimations` makes the flip instant). The widget
// owns its own flip state, so the review screen resets a card to its
// front simply by giving each appearance a fresh Key.
//
// Style: the manuals' premium dark-glass recipe (deep navy surface,
// accent border + soft glow) restated locally with `BarrioColors`
// constants; the manual-owned rendering widgets are not imported.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/barrio_flashcard_deck.dart';
import 'barrio_destination_scaffold.dart';

class BarrioFlashcardCard extends StatefulWidget {
  final BarrioFlashcard card;
  final Color accent;

  /// True when this appearance is a recycled "See it again" pass; the
  /// front carries an honest REPEAT chip.
  final bool isRepeat;

  const BarrioFlashcardCard({
    super.key,
    required this.card,
    required this.accent,
    this.isRepeat = false,
  });

  @override
  State<BarrioFlashcardCard> createState() => _BarrioFlashcardCardState();
}

class _BarrioFlashcardCardState extends State<BarrioFlashcardCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  bool _motionDecided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionDecided) return;
    _motionDecided = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Accessibility: flips land instantly.
      _flip.duration = Duration.zero;
    }
  }

  @override
  void dispose() {
    _flip.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_flip.value < 0.5) {
      _flip.forward();
    } else {
      _flip.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: AnimatedBuilder(
        animation: _flip,
        builder: (context, _) {
          final showFront = _flip.value < 0.5;
          // Back content is pre-mirrored so the Y-rotation past 90
          // degrees reads it the right way around.
          final face = showFront
              ? _FlashcardFront(
                  card: widget.card,
                  accent: widget.accent,
                  isRepeat: widget.isRepeat,
                )
              : Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.rotationY(math.pi),
                  child: _FlashcardBack(
                    card: widget.card,
                    accent: widget.accent,
                  ),
                );
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY(_flip.value * math.pi),
            child: face,
          );
        },
      ),
    );
  }
}

/// Shared dark-glass card shell (the manuals' premium recipe restated
/// with `BarrioColors`: near-opaque navy, accent border, soft glow).
class _FlashcardShell extends StatelessWidget {
  final Color accent;
  final Widget child;

  const _FlashcardShell({required this.accent, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: BarrioColors.shellMid.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.14),
            blurRadius: 24,
          ),
        ],
      ),
      child: child,
    );
  }
}

class _FlashcardFront extends StatelessWidget {
  final BarrioFlashcard card;
  final Color accent;
  final bool isRepeat;

  const _FlashcardFront({
    required this.card,
    required this.accent,
    required this.isRepeat,
  });

  @override
  Widget build(BuildContext context) {
    final imagePath = card.imageAssetPath;
    return _FlashcardShell(
      accent: accent,
      child: Column(
        children: [
          if (isRepeat)
            Align(
              alignment: Alignment.topLeft,
              child: _RepeatChip(accent: accent),
            ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (imagePath != null) ...[
                  Flexible(child: _picture(imagePath)),
                  const SizedBox(height: 18),
                ],
                Text(
                  card.term,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: BarrioColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Tap to flip',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 11.5,
              color: BarrioColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _picture(String imagePath) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.asset(
        imagePath,
        fit: BoxFit.contain,
        // Test environments load no real asset bytes: fall back to a
        // quiet icon instead of throwing (same pattern as the home
        // bubble visuals).
        errorBuilder: (_, __, ___) => Icon(
          Icons.image_outlined,
          size: 56,
          color: accent.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _FlashcardBack extends StatelessWidget {
  final BarrioFlashcard card;
  final Color accent;

  const _FlashcardBack({required this.card, required this.accent});

  @override
  Widget build(BuildContext context) {
    final caption = card.imageCaption;
    return _FlashcardShell(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            card.term,
            style: GoogleFonts.playfairDisplay(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The definition, word for word from the manual.
                  Text(
                    card.body,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 14.5,
                      height: 1.7,
                      color: BarrioColors.textSecondary,
                    ),
                  ),
                  if (caption != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      caption,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: BarrioColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RepeatChip extends StatelessWidget {
  final Color accent;

  const _RepeatChip({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Text(
        'REPEAT',
        style: GoogleFonts.ibmPlexMono(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: accent,
        ),
      ),
    );
  }
}
