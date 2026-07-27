// The two-sided flashcard for `BarrioFlashcardReviewScreen` (operator
// rec #5, 2026-07-23). Front: the term (plus its source picture when
// the unit has one, or a teal monogram medallion of the term's first
// letter when the abstract-vocabulary card has no picture). Back: the
// VERBATIM definition body, unchanged, scrollable, with the literal
// source caption when present.
//
// Tap anywhere on the card to flip (simple perspective Y-rotation;
// `MediaQuery.disableAnimations` makes the flip instant). The widget
// owns its own flip state, so the review screen resets a card to its
// front simply by giving each appearance a fresh Key.
//
// Style: the manuals' premium light-glass recipe (near-white surface,
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
    return AnimatedBuilder(
      animation: _flip,
      builder: (context, _) {
          final showFront = _flip.value < 0.5;
          // Accessibility (rec #12): the whole card is one flip button
          // whose label names the action the tap performs; the visible
          // face content merges in after it (Semantics sits OUTSIDE
          // the GestureDetector so the tap action lands on the labeled
          // node, same pattern as the bookmark toggle).
          final flipLabel = showFront ? 'Show definition' : 'Show term';
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
          return Semantics(
            button: true,
            label: flipLabel,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(_flip.value * math.pi),
                child: face,
              ),
            ),
          );
      },
    );
  }
}

/// Shared light-glass card shell (the manuals' premium recipe restated
/// with `BarrioColors`: near-opaque white, accent border, soft glow).
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

/// Front face: the REPEAT chip (when recycled), the term, and a
/// "Tap to flip" hint. When the unit has a picture it sits above the
/// term; when it has none (an abstract-vocabulary card such as "86" or
/// "in the weeds", which cannot be photographed) a decorative teal
/// monogram medallion of the term's first letter stands in its place,
/// so a picture-less card reads as intentional, not broken.
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
                ] else ...[
                  // No source picture (abstract-vocabulary card): a
                  // branded monogram medallion stands in so the card
                  // reads as intentional, not a broken missing photo.
                  // Decorative only: the card's flip-button label
                  // already carries the semantics (rec #12).
                  ExcludeSemantics(child: _Monogram(term: card.term)),
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
          // Excluded from semantics: the card's flip-button label
          // already says what a tap does (rec #12).
          ExcludeSemantics(
            child: Text(
              'Tap to flip',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 11.5,
                color: BarrioColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _picture(String imagePath) {
    // Screen-reader label (rec #12): the literal source caption when
    // present, else 'Photo: <term>'. Never an invented description.
    return Semantics(
      image: true,
      label: card.imageCaption ?? 'Photo: ${card.term}',
      child: ClipRRect(
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
      ),
    );
  }
}

/// Decorative teal monogram medallion shown on the front of a
/// picture-less card: a soft teal disc carrying the term's first
/// character. Purely branding, so it is wrapped in `ExcludeSemantics`
/// by its caller (the flip-button label carries the meaning, rec #12).
class _Monogram extends StatelessWidget {
  final String term;

  const _Monogram({required this.term});

  @override
  Widget build(BuildContext context) {
    // Safe first-character pick: never crash on an empty term, and use
    // grapheme clusters so a multi-byte first character stays whole. A
    // leading digit (e.g. "86" to "8") is intentionally fine.
    final trimmed = term.trim();
    final mono =
        trimmed.isEmpty ? '•' : trimmed.characters.first.toUpperCase();
    return Container(
      width: 76,
      height: 76,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: BarrioColors.tealDeep.withValues(alpha: 0.10),
        border: Border.all(
          color: BarrioColors.tealDeep.withValues(alpha: 0.35),
        ),
      ),
      child: Text(
        mono,
        style: GoogleFonts.playfairDisplay(
          fontSize: 34,
          fontWeight: FontWeight.w700,
          color: BarrioColors.tealDeep,
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
