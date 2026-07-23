// Flashcard review mode for the glossary manuals (operator-approved
// rec #5, 2026-07-23). Retrieval practice with zero content authoring:
// each glossary unit becomes a card (term front, verbatim definition
// back), shuffled per session, with "Got it" / "See it again" recycling.
//
// Session-only by design: nothing about mastery is persisted. "Got it"
// is the reader's claim, not an app metric (Metric Honesty). The
// header counter and the finish line report only what actually
// happened in this session.
//
// Entry points: the quiet REVIEW pills on the home shelf (per-manual
// under-bubble metadata zone + the Food & Drink section header for the
// combined deck), which push this screen directly.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/barrio_flashcard_deck.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_flashcard_card.dart';
import '../widgets/barrio_streak_tracker.dart';

class BarrioFlashcardReviewScreen extends StatefulWidget {
  final BarrioFlashcardDeck deck;
  final Color accent;

  /// Fixed RNG seed for deterministic shuffles (tests). Null uses a
  /// time-based seed, so every real session gets a fresh order.
  final int? shuffleSeed;

  const BarrioFlashcardReviewScreen({
    super.key,
    required this.deck,
    this.accent = BarrioColors.tealWarm,
    this.shuffleSeed,
  });

  @override
  State<BarrioFlashcardReviewScreen> createState() =>
      _BarrioFlashcardReviewScreenState();
}

class _BarrioFlashcardReviewScreenState
    extends State<BarrioFlashcardReviewScreen> {
  late final Random _rng =
      Random(widget.shuffleSeed ?? DateTime.now().millisecondsSinceEpoch);
  late BarrioFlashcardSession _session;

  /// Bumped on every card advance and reshuffle: keys each card
  /// appearance so a recycled card always starts front-side up.
  int _appearance = 0;

  @override
  void initState() {
    super.initState();
    _session = _newSession();
    // Honest streak (rec #10): opening a review deck is learning
    // activity too. Idempotent per day; fire and forget.
    BarrioStreakService.recordActivity();
  }

  BarrioFlashcardSession _newSession() {
    return BarrioFlashcardSession(
      shuffleBarrioFlashcards(widget.deck.cards, _rng),
    );
  }

  void _markGotIt() {
    HapticFeedback.selectionClick();
    setState(() {
      _session.markGotIt();
      _appearance++;
    });
  }

  void _markSeeAgain() {
    HapticFeedback.selectionClick();
    setState(() {
      _session.markSeeAgain();
      _appearance++;
    });
  }

  void _reshuffle() {
    HapticFeedback.lightImpact();
    setState(() {
      _session = _newSession();
      _appearance++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: widget.deck.title,
        accentColor: widget.accent,
      ),
      body: BarrioPremiumBackground(
        accentColor: widget.accent,
        child: SafeArea(
          child: _session.isFinished ? _buildFinished() : _buildReviewing(),
        ),
      ),
    );
  }

  Widget _buildReviewing() {
    final card = _session.current!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: _buildCounterRow(),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: BarrioFlashcardCard(
              key: ValueKey<int>(_appearance),
              card: card,
              accent: widget.accent,
              isRepeat: _session.currentIsRepeat,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Row(
            children: [
              Expanded(
                child: _ReviewButton(
                  label: 'See it again',
                  accent: widget.accent,
                  filled: false,
                  onTap: _markSeeAgain,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ReviewButton(
                  label: 'Got it',
                  accent: widget.accent,
                  filled: true,
                  onTap: _markGotIt,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Honest deck header: distinct cards shown so far out of the deck
  /// total, plus how many recycled cards are still waiting (only when
  /// there are any; no phantom zeroes).
  Widget _buildCounterRow() {
    final queued = _session.queuedRepeatCount;
    return Row(
      children: [
        Text(
          'Card ${_session.introducedCount} of ${_session.totalCards}',
          style: GoogleFonts.ibmPlexMono(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: BarrioColors.textSecondary,
          ),
        ),
        const Spacer(),
        if (queued > 0)
          Text(
            '$queued queued to repeat',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 11.5,
              color: BarrioColors.textMuted,
            ),
          ),
      ],
    );
  }

  Widget _buildFinished() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.style_rounded,
              size: 44,
              color: widget.accent.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 14),
            Text(
              _finishedLine(),
              textAlign: TextAlign.center,
              style: GoogleFonts.playfairDisplay(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: BarrioColors.textPrimary,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: _ReviewButton(
                    label: 'Shuffle again',
                    accent: widget.accent,
                    filled: true,
                    onTap: _reshuffle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ReviewButton(
                    label: 'Exit',
                    accent: widget.accent,
                    filled: false,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Honest end state: deck size always; the repeat count only when at
  /// least one card was recycled (no phantom zeroes).
  String _finishedLine() {
    final n = _session.totalCards;
    final m = _session.repeatedCardCount;
    final cardsWord = n == 1 ? 'card' : 'cards';
    if (m == 0) return 'Deck finished: $n $cardsWord.';
    return 'Deck finished: $n $cardsWord, $m repeated.';
  }
}

/// Shared button recipe for the review actions: filled accent for the
/// primary action, quiet outline for the secondary.
class _ReviewButton extends StatelessWidget {
  final String label;
  final Color accent;
  final bool filled;
  final VoidCallback onTap;

  const _ReviewButton({
    required this.label,
    required this.accent,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: filled
              ? accent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accent.withValues(alpha: filled ? 0.55 : 0.40),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 14,
              fontWeight: filled ? FontWeight.w700 : FontWeight.w600,
              color: filled ? accent : BarrioColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
