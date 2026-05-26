// Advisor Chat screen — Slice D2 (operator-web).
//
// This screen is the operator-facing surface for the advisor answer
// endpoint. The endpoint and its client gateway (`AdvisorAnswerGateway`)
// already exist from Slice D1; this slice builds the UI that lets an
// operator ask a question, read the answer, and continue the conversation.
//
// Design target: docs/_mockups/advisor_chat_preview.html (v2, approved).
//
// HP #6 (recommend, never command): NO execute / apply / "do it for me"
// affordance exists anywhere in this screen. The reassurance line "The
// advisor suggests. You decide and act." is always visible. Answers are
// displayed as recommendations the operator acts on themselves.
//
// HP #7 (keys stay server-side): this screen NEVER logs the bearer token
// or any secret. The gateway handles auth; the screen only sees the typed
// [AdvisorAnswerStatus] and the [AdvisorAnswerResult] payload.
//
// HP #2 (demo mode): the screen uses the gateway from the provider seam.
// [AdvisorAnswerGatewayDemo] is the demo implementation; the screen has NO
// kDemoMode branch. Both code paths share the same UI.
//
// UX no-em-dash law: no U+2014 in any operator-facing string in this file.

import 'package:flutter/material.dart';

import '../../services/advisor/advisor_answer_gateway.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';

// ── Colour aliases (same palette as the v2 preview) ─────────────────────────
// The preview uses peacock (#0E8080) for the advisor badge/avatar and
// sunset (#C9772F / #9A5C2A) for the user bubble. We reuse the existing
// AppColors tokens which match those values.

/// The advisor chat screen for the operator-web console.
///
/// Accepts an [AdvisorAnswerGateway] directly so the router resolves the
/// live vs demo implementation via the provider seam and hands it in.
/// Tests pass a [_FakeAdvisorAnswerGateway] without touching the auth source.
class AdvisorChatScreen extends StatefulWidget {
  const AdvisorChatScreen({
    super.key,
    required this.session,
    required this.gateway,
  });

  final OperatorWebSession session;

  /// Resolved gateway (live or demo). The screen does NOT know or care
  /// which implementation this is (HP #2 parity).
  final AdvisorAnswerGateway gateway;

  @override
  State<AdvisorChatScreen> createState() => _AdvisorChatScreenState();
}

// ── Turn model ────────────────────────────────────────────────────────────────

/// A single turn in the conversation thread.
sealed class _ChatTurn {}

/// A question the operator typed.
class _UserTurn extends _ChatTurn {
  _UserTurn(this.question);
  final String question;
}

/// A successful advisor recommendation.
class _AdvisorTurn extends _ChatTurn {
  _AdvisorTurn(this.result);
  final AdvisorAnswerResult result;
}

/// A fail-closed error from the gateway (typed, calm copy).
class _ErrorTurn extends _ChatTurn {
  _ErrorTurn(this.status);
  final AdvisorAnswerStatus status;
}

// ── Fail-closed state flavours (rendered INSTEAD of the thread) ───────────────

/// States that replace the entire chat UI (not just a turn error).
enum _ScreenStatus {
  /// Normal interactive chat.
  chat,

  /// Advisor is not switched on / not configured.
  off,

  /// Monthly usage cap reached.
  cap,
}

// ── State ─────────────────────────────────────────────────────────────────────

class _AdvisorChatScreenState extends State<AdvisorChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  final List<_ChatTurn> _turns = <_ChatTurn>[];
  String? _conversationId;
  bool _loading = false;
  _ScreenStatus _screenStatus = _ScreenStatus.chat;

  static const List<String> _exampleChips = <String>[
    'Why was labor over target on Saturday?',
    'How does this week compare to my plan?',
    'What is driving my cost per labor hour?',
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _submit(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || _loading) return;
    _controller.clear();
    setState(() {
      _turns.add(_UserTurn(trimmed));
      _loading = true;
    });
    _scrollToBottom();
    try {
      final result = await widget.gateway.ask(
        question: trimmed,
        conversationId: _conversationId,
      );
      if (!mounted) return;
      setState(() {
        _conversationId = result.conversationId;
        _turns.add(_AdvisorTurn(result));
        _loading = false;
      });
    } on AdvisorAnswerException catch (e) {
      if (!mounted) return;
      // Fail-closed states that replace the whole screen body.
      if (e.status == AdvisorAnswerStatus.notSwitchedOn) {
        // Not switched on replaces the whole chat with a friendly off-state.
        setState(() {
          _turns.add(_ErrorTurn(e.status));
          _loading = false;
          _screenStatus = _ScreenStatus.off;
        });
        return;
      }
      if (e.status == AdvisorAnswerStatus.notConfigured) {
        // Not configured: show as an inline error turn rather than the off-state
        // screen, because the gateway message ("being set up") is more accurate
        // than the off-state title ("isn't switched on yet").
        setState(() {
          _turns.add(_ErrorTurn(e.status));
          _loading = false;
        });
        return;
      }
      if (e.status == AdvisorAnswerStatus.usageCapReached) {
        setState(() {
          _turns.add(_ErrorTurn(e.status));
          _loading = false;
          _screenStatus = _ScreenStatus.cap;
        });
        return;
      }
      // serverError / networkError: inline error turn, chat stays alive.
      setState(() {
        _turns.add(_ErrorTurn(e.status));
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _turns.add(_ErrorTurn(AdvisorAnswerStatus.serverError));
        _loading = false;
      });
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Fail-closed full-screen states (off / cap) bypass the chat UI.
    if (_screenStatus == _ScreenStatus.off) {
      return _FullScreenState(
        icon: Icons.lock_outline,
        title: "The advisor isn't switched on yet",
        body:
            'Once your team enables it, you can ask questions here. '
            'Nothing is sent anywhere until it is on.',
        isWarning: false,
      );
    }
    if (_screenStatus == _ScreenStatus.cap) {
      return _FullScreenState(
        icon: Icons.access_time_outlined,
        title: 'You have used this month\'s advisor questions',
        body:
            'The limit resets next month. '
            'An admin can raise it sooner if you need more.',
        isWarning: true,
      );
    }

    return OperatorWebScreenBody(
      scrollKey: const Key('operator_web_advisor_chat_screen'),
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ── Header ──────────────────────────────────────────────────────
            _ScreenHeader(),
            const SizedBox(height: 24),

            // ── Chat card (thread + composer) ────────────────────────────────
            _ChatCard(
              turns: _turns,
              loading: _loading,
              scrollController: _scrollController,
              exampleChips: _exampleChips,
              onChipTap: (chip) {
                _controller.text = chip;
                _inputFocus.requestFocus();
              },
              composerController: _controller,
              composerFocus: _inputFocus,
              onSubmit: _submit,
            ),

            // ── Reassurance line (HP #6 — always visible) ───────────────────
            const SizedBox(height: 16),
            const _ReassuranceLine(),
          ],
        ),
      ),
    );
  }
}

// ── Header widget ─────────────────────────────────────────────────────────────

class _ScreenHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Hero icon — peacock-tinted rounded square (matches preview .head .hero)
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color(0xFFE3F0F0), // peacock-bg
                Color(0xFFD6EBEB),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x0D2A2723),
                blurRadius: 2,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: const Icon(
            Icons.chat_bubble_outline,
            size: 27,
            color: AppColors.peacockDark,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Ask the advisor',
                style: AppTextStyles.display28(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 5),
              Text(
                'Ask about your labor, sales, or targets in plain language. '
                'It explains what it sees and suggests what to look at.',
                style: AppTextStyles.body15(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        // "Suggestions only" badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFFE3F0F0),
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Text(
            'Suggestions only',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: AppColors.peacockDark,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Chat card ─────────────────────────────────────────────────────────────────

class _ChatCard extends StatelessWidget {
  const _ChatCard({
    required this.turns,
    required this.loading,
    required this.scrollController,
    required this.exampleChips,
    required this.onChipTap,
    required this.composerController,
    required this.composerFocus,
    required this.onSubmit,
  });

  final List<_ChatTurn> turns;
  final bool loading;
  final ScrollController scrollController;
  final List<String> exampleChips;
  final ValueChanged<String> onChipTap;
  final TextEditingController composerController;
  final FocusNode composerFocus;
  final Future<void> Function(String) onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x0A2A2723),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x0D2A2723),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: <Widget>[
          // Thread
          _Thread(
            key: const Key('advisor_chat_thread'),
            turns: turns,
            loading: loading,
            scrollController: scrollController,
            exampleChips: exampleChips,
            onChipTap: onChipTap,
          ),
          // Composer
          _Composer(
            key: const Key('advisor_chat_composer'),
            controller: composerController,
            focusNode: composerFocus,
            onSubmit: onSubmit,
            disabled: loading,
          ),
        ],
      ),
    );
  }
}

// ── Thread ────────────────────────────────────────────────────────────────────

class _Thread extends StatelessWidget {
  const _Thread({
    super.key,
    required this.turns,
    required this.loading,
    required this.scrollController,
    required this.exampleChips,
    required this.onChipTap,
  });

  final List<_ChatTurn> turns;
  final bool loading;
  final ScrollController scrollController;
  final List<String> exampleChips;
  final ValueChanged<String> onChipTap;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 240, maxHeight: 520),
      child: ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 26),
        children: <Widget>[
          // Greeting + example chips (empty state intro)
          _AdvisorRow(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _AdvisorBody(
                  text:
                      'Hi. Ask me anything about your labor, sales, or targets. '
                      'I will explain what I see and suggest what you could '
                      'consider.',
                ),
                if (turns.isEmpty) ...<Widget>[
                  const SizedBox(height: 14),
                  _ExampleChips(chips: exampleChips, onTap: onChipTap),
                ],
              ],
            ),
          ),
          // Prior turns
          for (final turn in turns) ...<Widget>[
            const SizedBox(height: 24),
            _buildTurn(turn),
          ],
          // In-flight typing indicator
          if (loading) ...<Widget>[
            const SizedBox(height: 24),
            _AdvisorRow(child: const _TypingIndicator()),
          ],
        ],
      ),
    );
  }

  Widget _buildTurn(_ChatTurn turn) {
    return switch (turn) {
      _UserTurn(question: final q) => _UserBubbleRow(question: q),
      _AdvisorTurn(result: final r) => _AdvisorRow(
        child: _AdvisorAnswer(result: r),
      ),
      _ErrorTurn(status: final s) => _AdvisorRow(
        child: _ErrorMessage(status: s),
      ),
    };
  }
}

// ── Row wrappers (avatar + content) ──────────────────────────────────────────

class _AdvisorRow extends StatelessWidget {
  const _AdvisorRow({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Advisor avatar
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFFE3F0F0),
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Icon(
            Icons.chat_bubble_outline,
            size: 15,
            color: AppColors.peacockDark,
          ),
        ),
        const SizedBox(width: 12),
        Flexible(child: child),
      ],
    );
  }
}

class _UserBubbleRow extends StatelessWidget {
  const _UserBubbleRow({required this.question});
  final String question;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Flexible(
            child: Container(
              key: const Key('advisor_chat_user_bubble'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.sunset,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x0D2A2723),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                question,
                style: const TextStyle(
                  fontSize: 15,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // User avatar
          Container(
            width: 32,
            height: 32,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF6E7D8), // sunset-soft
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.person_outline,
              size: 15,
              color: AppColors.sunsetDark,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Advisor answer content ────────────────────────────────────────────────────

class _AdvisorBody extends StatelessWidget {
  const _AdvisorBody({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTextStyles.body15(color: AppColors.textPrimary),
    );
  }
}

class _AdvisorAnswer extends StatelessWidget {
  const _AdvisorAnswer({required this.result});
  final AdvisorAnswerResult result;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // "ADVISOR" label (uppercase, peacock)
        const Text(
          'ADVISOR',
          key: Key('advisor_chat_advisor_label'),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: AppColors.peacockDark,
          ),
        ),
        const SizedBox(height: 7),
        // Serif lead
        Text(
          'Here is what I would consider',
          style: AppTextStyles.display16(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 9),
        // Answer body
        Text(
          result.answer,
          style: AppTextStyles.body15(color: AppColors.textPrimary),
        ),
        // Citations (collapsible)
        if (result.citations.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          _CitationsSection(citations: result.citations),
        ],
      ],
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.status});
  final AdvisorAnswerStatus status;

  @override
  Widget build(BuildContext context) {
    final exception = AdvisorAnswerException(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F4),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.7),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        exception.message,
        style: AppTextStyles.body14(color: AppColors.textSecondary),
      ),
    );
  }
}

// ── Citations ─────────────────────────────────────────────────────────────────

class _CitationsSection extends StatefulWidget {
  const _CitationsSection({required this.citations});
  final List<AdvisorCitation> citations;

  @override
  State<_CitationsSection> createState() => _CitationsSectionState();
}

class _CitationsSectionState extends State<_CitationsSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Toggle row
        GestureDetector(
          onTap: () => setState(() => _open = !_open),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.link,
                size: 15,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 7),
              Text(
                'Where this comes from',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sunsetDark,
                ),
              ),
              const SizedBox(width: 7),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(
                  Icons.expand_more,
                  size: 15,
                  color: AppColors.sunsetDark,
                ),
              ),
            ],
          ),
        ),
        // Citation list
        if (_open) ...<Widget>[
          const SizedBox(height: 6),
          Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Color(0xFFEDE6DC), width: 1),
              ),
            ),
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: <Widget>[
                for (final citation in widget.citations)
                  _CitationRow(citation: citation),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _CitationRow extends StatelessWidget {
  const _CitationRow({required this.citation});
  final AdvisorCitation citation;

  IconData _iconForTool(String toolName) {
    if (toolName.contains('target') || toolName.contains('cycle')) {
      return Icons.flag_outlined;
    }
    if (toolName.contains('plan') || toolName.contains('snapshot')) {
      return Icons.check_box_outlined;
    }
    if (toolName.contains('shift') || toolName.contains('variance')) {
      return Icons.bar_chart;
    }
    return Icons.insert_link_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final title = citation.title ?? citation.sourceId;
    final snippet = citation.snippet;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: const Color(0xFFF4ECE3),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              _iconForTool(citation.toolName),
              size: 15,
              color: AppColors.peacockDark,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: AppTextStyles.body14(color: AppColors.textSecondary),
                ),
                if (snippet != null)
                  Text(
                    snippet,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF938A7E),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Example chips ─────────────────────────────────────────────────────────────

class _ExampleChips extends StatelessWidget {
  const _ExampleChips({required this.chips, required this.onTap});
  final List<String> chips;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: <Widget>[
        for (final chip in chips)
          _ExampleChip(
            key: Key('advisor_example_chip_${chip.hashCode}'),
            label: chip,
            onTap: () => onTap(chip),
          ),
      ],
    );
  }
}

class _ExampleChip extends StatefulWidget {
  const _ExampleChip({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_ExampleChip> createState() => _ExampleChipState();
}

class _ExampleChipState extends State<_ExampleChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF6E7D8), // sunset-soft
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _hovered ? AppColors.sunset : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppColors.sunsetDark,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Typing indicator ──────────────────────────────────────────────────────────

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _TypingDot(controller: _controller, delay: 0.0),
        const SizedBox(width: 5),
        _TypingDot(controller: _controller, delay: 0.15),
        const SizedBox(width: 5),
        _TypingDot(controller: _controller, delay: 0.30),
        const SizedBox(width: 10),
        Text(
          'Looking at your numbers',
          key: const Key('advisor_chat_loading_indicator'),
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFF938A7E),
          ),
        ),
      ],
    );
  }
}

class _TypingDot extends StatelessWidget {
  const _TypingDot({required this.controller, required this.delay});
  final AnimationController controller;
  final double delay;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = (controller.value - delay).clamp(0.0, 1.0);
        // Blink: 0..0.4 fade in, 0.4..1 fade out (repeat)
        final opacity = t < 0.4 ? t / 0.4 : 1.0 - (t - 0.4) / 0.6;
        return Opacity(
          opacity: opacity.clamp(0.25, 1.0),
          child: Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: Color(0xFF938A7E),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

// ── Composer ──────────────────────────────────────────────────────────────────

class _Composer extends StatefulWidget {
  const _Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.disabled,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function(String) onSubmit;
  final bool disabled;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _focused = false;

  void _handleSubmit() {
    final text = widget.controller.text;
    if (text.trim().isEmpty || widget.disabled) return;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFEDE6DC), width: 1),
        ),
        color: AppColors.backgroundSurface,
      ),
      child: Row(
        children: <Widget>[
          // Pill input
          Expanded(
            child: Focus(
              onFocusChange: (focused) => setState(() => _focused = focused),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: AppColors.backgroundDeep,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: _focused
                      ? <BoxShadow>[
                          BoxShadow(
                            color: AppColors.sunset.withValues(alpha: 0.15),
                            blurRadius: 0,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.chat_bubble_outline,
                      size: 15,
                      color: Color(0xFF938A7E),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: const Key('advisor_chat_input'),
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        enabled: !widget.disabled,
                        style: AppTextStyles.body15(
                          color: AppColors.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Ask about labor, sales, or targets...',
                          hintStyle: TextStyle(
                            color: Color(0xFF938A7E),
                            fontSize: 15,
                          ),
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onSubmitted: (_) => _handleSubmit(),
                        textInputAction: TextInputAction.send,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Round send button
          SizedBox(
            width: 46,
            height: 46,
            child: _SendButton(
              onPressed: widget.disabled ? null : _handleSubmit,
            ),
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: enabled
                ? (_hovered ? AppColors.sunsetDark : AppColors.sunset)
                : AppColors.borderSubtle,
            shape: BoxShape.circle,
            boxShadow: enabled
                ? const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x0D2A2723),
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.send,
            key: const Key('advisor_chat_send_button'),
            size: 20,
            color: enabled ? Colors.white : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

// ── Reassurance line (HP #6 — always visible) ─────────────────────────────────

class _ReassuranceLine extends StatelessWidget {
  const _ReassuranceLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const <Widget>[
        Icon(Icons.verified_user_outlined, size: 15, color: Color(0xFF938A7E)),
        SizedBox(width: 8),
        Text(
          'The advisor suggests. You decide and act.',
          key: Key('advisor_chat_reassurance_line'),
          style: TextStyle(fontSize: 12.5, color: Color(0xFF938A7E)),
        ),
      ],
    );
  }
}

// ── Full-screen fail-closed states ────────────────────────────────────────────

class _FullScreenState extends StatelessWidget {
  const _FullScreenState({
    required this.icon,
    required this.title,
    required this.body,
    required this.isWarning,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final iconBg = isWarning ? const Color(0xFFF6EFD9) : AppColors.backgroundMid;
    final iconColor = isWarning ? const Color(0xFF9A7400) : AppColors.textMuted;

    return OperatorWebScreenBody(
      scrollKey: const Key('operator_web_advisor_chat_state_screen'),
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _ScreenHeader(),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              decoration: BoxDecoration(
                color: AppColors.backgroundSurface,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x0D2A2723),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconBg,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon, size: 22, color: iconColor),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: AppTextStyles.body15(
                            color: AppColors.textPrimary,
                          ).copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          body,
                          style: AppTextStyles.body13(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _ReassuranceLine(),
          ],
        ),
      ),
    );
  }
}
