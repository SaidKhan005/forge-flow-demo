// Quiz refresher screen (spaced "Quick refresher" shelf, operator-
// approved rec #11). A simple paged run through ONE manual's quiz-bank
// questions in sequence, reusing the #1483 checkpoint card widget
// unchanged. Entry point: the home shelf's Quick refresher card.
//
// Honesty rules (Metric Honesty Doctrine):
//   * Session-only picks: nothing about answers is persisted, and no
//     mastery is claimed. Completion records exactly one fact upstream
//     (lastRefreshedAt, via [onCompleted]).
//   * No gating: the reader can move past a question without
//     answering, same as the in-reader checkpoint cards. The end state
//     reports honest counts of what actually happened.
//   * Plain English, no em dashes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../content/quiz/barrio_quiz_models.dart';
import '../widgets/barrio_destination_scaffold.dart';
import '../widgets/barrio_quiz_checkpoint_card.dart';
import '../widgets/barrio_streak_tracker.dart';

class BarrioQuizRefresherScreen extends StatefulWidget {
  /// The manual's full quiz bank; questions run in bank (chapter
  /// reading) order.
  final BarrioQuizBank bank;

  /// Operator-facing title (the shelf passes the destination label).
  final String title;

  final Color accent;

  /// Fires exactly once, when the reader reaches the end of the run
  /// (the shelf wires the lastRefreshedAt recording here). Null makes
  /// completion record nothing.
  final VoidCallback? onCompleted;

  const BarrioQuizRefresherScreen({
    super.key,
    required this.bank,
    required this.title,
    this.accent = BarrioColors.tealWarm,
    this.onCompleted,
  });

  @override
  State<BarrioQuizRefresherScreen> createState() =>
      _BarrioQuizRefresherScreenState();
}

class _BarrioQuizRefresherScreenState extends State<BarrioQuizRefresherScreen> {
  int _index = 0;

  /// This session's first pick per question id. Session-only.
  final Map<String, int> _picks = <String, int>{};

  bool _finished = false;
  bool _completionNotified = false;

  @override
  void initState() {
    super.initState();
    // Honest streak (rec #10): opening a refresher is learning
    // activity too, same as the flashcard review screen. Idempotent
    // per day; fire and forget.
    BarrioStreakService.recordActivity();
  }

  List<BarrioQuizQuestion> get _questions => widget.bank.questions;

  void _advance() {
    HapticFeedback.selectionClick();
    if (_index + 1 < _questions.length) {
      setState(() => _index++);
      return;
    }
    setState(() => _finished = true);
    if (!_completionNotified) {
      _completionNotified = true;
      widget.onCompleted?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: widget.title,
        accentColor: widget.accent,
      ),
      body: BarrioPremiumBackground(
        accentColor: widget.accent,
        child: SafeArea(
          child: _finished ? _buildFinished() : _buildRunning(),
        ),
      ),
    );
  }

  Widget _buildRunning() {
    final question = _questions[_index];
    final answered = _picks.containsKey(question.id);
    final isLast = _index + 1 >= _questions.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              Text(
                'Question ${_index + 1} of ${_questions.length}',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: BarrioColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: BarrioQuizCheckpointCard(
              key: ValueKey<String>('refresher_${question.id}'),
              question: question,
              selectedIndex: _picks[question.id],
              onOptionSelected: (picked) =>
                  setState(() => _picks[question.id] = picked),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: _AdvanceButton(
            key: const Key('barrio_refresher_advance'),
            label: isLast ? 'Finish' : 'Next question',
            accent: widget.accent,
            // Quiet outline until the question is answered, filled
            // after: a nudge to answer, never a gate.
            filled: answered,
            onTap: _advance,
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
              Icons.refresh_rounded,
              size: 44,
              color: widget.accent.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 14),
            Text(
              'Refresher done.',
              textAlign: TextAlign.center,
              style: GoogleFonts.playfairDisplay(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: BarrioColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _honestCounts(),
              textAlign: TextAlign.center,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 13,
                height: 1.5,
                color: BarrioColors.textSecondary,
              ),
            ),
            const SizedBox(height: 22),
            _AdvanceButton(
              key: const Key('barrio_refresher_exit'),
              label: 'Exit',
              accent: widget.accent,
              filled: true,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ),
    );
  }

  /// Honest end counts: what actually happened this session, nothing
  /// more. The first-tap-correct clause appears only when at least one
  /// question was answered (no phantom zeroes).
  String _honestCounts() {
    final total = _questions.length;
    final answered = _picks.length;
    var correct = 0;
    for (final question in _questions) {
      if (_picks[question.id] == question.correctIndex) correct++;
    }
    final base = 'You answered $answered of $total.';
    if (answered == 0) return base;
    return '$base $correct correct on the first tap.';
  }
}

/// Full-width action button: quiet outline or filled accent, same
/// recipe as the flashcard review buttons.
class _AdvanceButton extends StatelessWidget {
  final String label;
  final Color accent;
  final bool filled;
  final VoidCallback onTap;

  const _AdvanceButton({
    super.key,
    required this.label,
    required this.accent,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Light theme: solid accent primary with a luminance-picked label;
    // quiet accent-outline secondary with a slate label.
    final onAccent = barrioOnAccent(accent);
    // Accessibility (rec #12): a proper button role; the visible text
    // merges in as the label.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: filled ? accent : Colors.transparent,
              borderRadius: BorderRadius.circular(BarrioRadii.card),
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
