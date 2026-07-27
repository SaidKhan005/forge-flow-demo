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

  /// Fires ONCE per screen visit, the first time the whole deck is
  /// finished (spaced refresher, rec #11: the shelf wires the
  /// lastRefreshedAt recording here). Reshuffle-and-finish-again in
  /// the same visit deliberately does not re-fire, so one sitting
  /// never skips a spacing stage. Null (the default, used by the
  /// REVIEW pills) keeps the screen exactly as before: session-only,
  /// nothing recorded.
  final VoidCallback? onDeckFinished;

  const BarrioFlashcardReviewScreen({
    super.key,
    required this.deck,
    this.accent = BarrioColors.tealWarm,
    this.shuffleSeed,
    this.onDeckFinished,
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

  /// Whether [BarrioFlashcardReviewScreen.onDeckFinished] already
  /// fired this visit (once per screen instance, never per reshuffle).
  bool _finishNotified = false;

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
    if (_session.isFinished && !_finishNotified) {
      _finishNotified = true;
      widget.onDeckFinished?.call();
    }
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
  /// there are any; no phantom zeroes). Both texts sit in Flexible
  /// slots so large text scales wrap instead of overflowing the row
  /// (accessibility pass, rec #12).
  Widget _buildCounterRow() {
    final queued = _session.queuedRepeatCount;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(
          child: Text(
            'Card ${_session.introducedCount} of ${_session.totalCards}',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: BarrioColors.textSecondary,
            ),
          ),
        ),
        if (queued > 0) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              '$queued queued to repeat',
              textAlign: TextAlign.right,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 11.5,
                color: BarrioColors.textMuted,
              ),
            ),
          ),
        ] else
          const Spacer(),
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
    // Light theme: the primary action is a solid accent fill with a
    // luminance-picked label (legible on any manual accent); the
    // secondary stays a quiet accent-outline with a slate label.
    final onAccent =
        ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : const Color(0xFF10151F);
    // Accessibility (rec #12): a proper button role; the visible text
    // merges in as the label.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: filled ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: filled
                  ? null
                  : Border.all(color: accent.withValues(alpha: 0.40)),
            ),
            child: Center(
              child: Text(
                label,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 14,
                  fontWeight: filled ? FontWeight.w700 : FontWeight.w600,
                  color: filled ? onAccent : BarrioColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
