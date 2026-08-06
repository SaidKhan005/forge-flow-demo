// Chapter-end quick-check quiz card (2026-07-23 operator-approved
// rec #4b).
//
// Renders one BarrioQuizQuestion from the #1479 operator-reviewable
// bank as a tap-to-answer checkpoint card inside the training reader's
// deck. Same premium light-glass card family as HandbookLessonCard.
//
// Honesty rules (Metric Honesty Doctrine):
//   * The card records nothing itself. The screen holds the pick for
//     THIS SESSION only; no scores, streaks, or mastery claims.
//   * A quiz card is never a "read" content card and never gates
//     progress: the normal page-turn gestures and chevrons keep
//     working, so the reader can page past without answering.
//
// Reveal behavior: the first tap locks the card. The correct option
// highlights in calm green, a wrong pick is marked distinctly but not
// punishingly, and the whyLine appears below in plain English. Locked
// option rows absorb further taps so a re-tap never turns the page by
// accident (the edge tap zones stay live everywhere else on the card).
//
// Display shuffle (operator bug 2026-08-01, "all quick check answers
// are the first ones"): the bank stays operator-reviewable with the
// correct option authored first, so this card shuffles the DISPLAY
// order instead. The permutation is derived from the question id via a
// stable FNV-1a hash seeding a Fisher-Yates shuffle: the same question
// always renders in the same order (the card is stable when the reader
// pages away and back), but the correct answer's position varies from
// question to question. Everything the card reports outward, that is
// [selectedIndex] in and [onOptionSelected] out, stays in ORIGINAL
// [BarrioQuizQuestion.options] index space; only the on-screen row
// order and the A/B/C/D letters follow display position.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../content/quiz/barrio_quiz_models.dart';
import 'barrio_chapter_icons.dart';
import 'barrio_destination_scaffold.dart';

/// Amber accent shared with the handbook card family's CHECK badge.
const Color _kQuizAccent = BarrioColors.warning;

/// Calm confirmation green shared with the card family's correct state.
const Color _kCorrectGreen = BarrioColors.success;

/// Soft wrong-pick red (lower alphas than the handbook decision cards:
/// marked clearly, never punishingly).
const Color _kWrongRed = BarrioColors.error;

/// One tap-to-answer quick-check card. Stateless: the owning screen
/// holds the session's first pick so the reveal survives paging away
/// and back within the session.
class BarrioQuizCheckpointCard extends StatelessWidget {
  final BarrioQuizQuestion question;

  /// The reader's first pick this session, or null while unanswered.
  /// Non-null locks the card and reveals the answer.
  final int? selectedIndex;

  /// Called exactly once, with the first tapped option. Never called
  /// again after reveal (options lock).
  final ValueChanged<int> onOptionSelected;

  const BarrioQuizCheckpointCard({
    super.key,
    required this.question,
    required this.selectedIndex,
    required this.onOptionSelected,
  });

  bool get _revealed => selectedIndex != null;

  /// The deterministic display order for [question]'s options, as a
  /// permutation of original indices into [BarrioQuizQuestion.options].
  ///
  /// Seeded from the question id via [_stableSeed] (never
  /// String.hashCode, which is not stable across runs), so the same
  /// question always shuffles the same way: rebuilds, paging away and
  /// back, and app restarts all show one order. Public so tests can
  /// assert the shuffle without pumping every card.
  static List<int> displayOrderFor(BarrioQuizQuestion question) {
    final order =
        List<int>.generate(question.options.length, (i) => i);
    final rng = Random(_stableSeed(question.id));
    // Fisher-Yates, walking down from the last slot.
    for (var i = order.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final swapped = order[i];
      order[i] = order[j];
      order[j] = swapped;
    }
    return order;
  }

  /// FNV-1a (32-bit) over the string's code units: a stable hash that
  /// gives the same seed on every run and platform.
  static int _stableSeed(String id) {
    var hash = 0x811C9DC5;
    for (final unit in id.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  void _handleTap(int index) {
    if (_revealed) return;
    if (index == question.correctIndex) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
    onOptionSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    // Chapter wayfinding icon (recs 2+5): ties the checkpoint back to
    // the chapter it quizzes. Null for fixture docs outside the routed
    // corpus: render nothing rather than a bogus glyph.
    final chapterIcon =
        barrioChapterIconOrManual(question.docId, question.chapterId);
    // Deterministic display shuffle (see header): displayOrder[pos] is
    // the ORIGINAL option index shown at display position pos. Keys,
    // taps, and the picked/correct checks stay in original index
    // space; only the row order and letters follow display position.
    final displayOrder = displayOrderFor(question);
    return _QuizGlassShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _QuickCheckBadge(),
              if (chapterIcon != null) ...[
                const Spacer(),
                Icon(
                  chapterIcon,
                  size: 16,
                  color: _kQuizAccent.withValues(alpha: 0.75),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Text(
            question.prompt,
            style: GoogleFonts.playfairDisplay(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: BarrioColors.textPrimary,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          for (var pos = 0; pos < displayOrder.length; pos++)
            _QuizOptionRow(
              // Keyed by ORIGINAL option index, wherever the row lands
              // on screen, so callers address options in bank space.
              key: ValueKey<String>(
                  'quiz_option_${question.id}_${displayOrder[pos]}'),
              label: question.options[displayOrder[pos]],
              letter: String.fromCharCode(0x41 + pos),
              isCorrect: displayOrder[pos] == question.correctIndex,
              isPicked: selectedIndex == displayOrder[pos],
              revealed: _revealed,
              onTap: () => _handleTap(displayOrder[pos]),
            ),
          if (_revealed) ...[
            const SizedBox(height: 6),
            _WhyLine(
              key: ValueKey<String>('quiz_why_${question.id}'),
              text: question.whyLine,
            ),
          ] else ...[
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Tap an answer to check yourself.',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  letterSpacing: 0.3,
                  color: _kQuizAccent.withValues(alpha: 0.45),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The premium light-glass shell shared with the lesson card family:
/// white glass fill, amber border and glow, specular highlight, and
/// accent bottom tint, around a padded [child]. The decorations are
/// IgnorePointer'd so only real content ever claims a tap.
class _QuizGlassShell extends StatelessWidget {
  final Widget child;

  const _QuizGlassShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BarrioColors.glassFill,
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        border: Border.all(color: _kQuizAccent.withValues(alpha: 0.35)),
        // Neutral lift, no colored glow — consistent with the other cards.
        boxShadow: barrioSoftShadow(),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Specular highlight, matching the lesson card family.
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
          // Accent bottom tint.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      _kQuizAccent.withValues(alpha: 0.05),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// The QUICK CHECK mono badge, mirroring the lesson card type badge.
class _QuickCheckBadge extends StatelessWidget {
  const _QuickCheckBadge();

  @override
  Widget build(BuildContext context) {
    // Solid amber chip with a luminance-picked label so it stays legible on
    // the white card (was a pale-tint badge tuned for the dark shell). The
    // ink is derived from _kQuizAccent rather than hardcoded to the dark
    // side, so re-tinting the quiz accent can never strand the label at
    // near-black on near-black.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _kQuizAccent,
        borderRadius: BorderRadius.circular(BarrioRadii.chip),
        boxShadow: [
          BoxShadow(
            color: _kQuizAccent.withValues(alpha: 0.28),
            blurRadius: 5,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        'QUICK CHECK',
        style: GoogleFonts.ibmPlexMono(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: barrioOnAccent(_kQuizAccent),
        ),
      ),
    );
  }
}

/// One tappable answer row. Before reveal every row is neutral glass;
/// after reveal the correct row goes calm green, the wrong pick gets a
/// soft red mark, and the rest dim. Locked rows keep an opaque no-op
/// tap target so a re-tap never falls through to the page-turn zones.
class _QuizOptionRow extends StatelessWidget {
  final String label;
  final String letter;
  final bool isCorrect;
  final bool isPicked;
  final bool revealed;
  final VoidCallback onTap;

  const _QuizOptionRow({
    super.key,
    required this.label,
    required this.letter,
    required this.isCorrect,
    required this.isPicked,
    required this.revealed,
    required this.onTap,
  });

  /// Merged screen-reader label (rec #12): letter + option text, with
  /// the honest state appended after reveal.
  String get _semanticsLabel {
    var built = '$letter: $label';
    if (!revealed) return built;
    if (isCorrect) {
      built = isPicked
          ? '$built, your pick, correct answer'
          : '$built, correct answer';
    } else if (isPicked) {
      built = '$built, your pick, not correct';
    }
    return built;
  }

  @override
  Widget build(BuildContext context) {
    final showCorrect = revealed && isCorrect;
    final showWrong = revealed && isPicked && !isCorrect;

    Color borderColor;
    Color bgColor;
    if (showCorrect) {
      borderColor = _kCorrectGreen.withValues(alpha: 0.55);
      bgColor = _kCorrectGreen.withValues(alpha: 0.10);
    } else if (showWrong) {
      borderColor = _kWrongRed.withValues(alpha: 0.40);
      bgColor = _kWrongRed.withValues(alpha: 0.07);
    } else {
      borderColor = BarrioColors.hairline;
      bgColor = const Color(0x0A16243B);
    }
    final labelColor = revealed && !isCorrect && !isPicked
        ? BarrioColors.textSecondary.withValues(alpha: 0.6)
        : BarrioColors.textPrimary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: isPicked,
        label: _semanticsLabel,
        child: GestureDetector(
          // Locked rows absorb taps (no-op) instead of passing them to
          // the carousel's edge tap zones: re-reading an answer must
          // never turn the page by accident.
          onTap: revealed ? _noop : onTap,
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(BarrioRadii.chip),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Text(
                  letter,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: BarrioColors.tealDeep,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 13,
                      color: labelColor,
                    ),
                  ),
                ),
                if (showCorrect)
                  const Icon(
                    Icons.check_circle,
                    size: 18,
                    color: _kCorrectGreen,
                  ),
                if (showWrong)
                  Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: _kWrongRed.withValues(alpha: 0.8),
                  ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }

  static void _noop() {}
}

/// The plain-English answer explanation, shown only after reveal.
class _WhyLine extends StatelessWidget {
  final String text;

  const _WhyLine({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _kCorrectGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(BarrioRadii.chip),
        border: Border.all(color: _kCorrectGreen.withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        style: GoogleFonts.ibmPlexSans(
          fontSize: 12.5,
          height: 1.55,
          color: BarrioColors.textSecondary,
        ),
      ),
    );
  }
}
