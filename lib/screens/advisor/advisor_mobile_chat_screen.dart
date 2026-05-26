// Advisor Chat screen -- Slice D2 (mobile).
//
// Mobile-narrow adaptation of the operator-web advisor chat screen
// (lib/operator_web/screens/advisor_chat_screen.dart). Shares the same
// AdvisorAnswerGateway and honor the same Hard Promises:
//
// HP #6 (recommend, never command): NO execute / apply / "do it for me"
// affordance exists anywhere in this screen. The reassurance line
// "The advisor suggests. You decide and act." is always visible.
//
// HP #7 (keys stay server-side): this screen NEVER logs the bearer token
// or any secret. The gateway handles auth; the screen only sees the typed
// AdvisorAnswerStatus and the AdvisorAnswerResult payload.
//
// HP #2 (demo mode): the screen uses the gateway passed in by the nav
// wiring. No kDemoMode branch exists here. Demo and live share one code
// path.
//
// UX no-em-dash law: no U+2014 in any operator-facing string in this file.
// The standalone dash-only sentinel glyph is exempt where used as a value
// placeholder elsewhere, but this file uses none.

import 'package:flutter/material.dart';

import '../../services/advisor/advisor_answer_gateway.dart';
import '../../theme/app_theme.dart';

// ---- Turn model ---------------------------------------------------------------

/// A single turn in the conversation thread.
sealed class _ChatTurn {}

class _UserTurn extends _ChatTurn {
  _UserTurn(this.question);
  final String question;
}

class _AdvisorTurn extends _ChatTurn {
  _AdvisorTurn(this.result);
  final AdvisorAnswerResult result;
}

class _ErrorTurn extends _ChatTurn {
  _ErrorTurn(this.status);
  final AdvisorAnswerStatus status;
}

// ---- Fail-closed screen states -----------------------------------------------

enum _ScreenStatus { chat, off, cap }

// ---- Main screen widget ------------------------------------------------------

/// Mobile advisor chat screen.
///
/// Accepts an [AdvisorAnswerGateway] so the nav wiring can resolve the
/// live vs demo implementation via the provider seam and hand it in.
/// Widget tests pass a fake gateway directly.
class AdvisorMobileChatScreen extends StatefulWidget {
  const AdvisorMobileChatScreen({
    super.key,
    required this.gateway,
  });

  final AdvisorAnswerGateway gateway;

  @override
  State<AdvisorMobileChatScreen> createState() =>
      _AdvisorMobileChatScreenState();
}

class _AdvisorMobileChatScreenState
    extends State<AdvisorMobileChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  final List<_ChatTurn> _turns = <_ChatTurn>[];
  String? _conversationId;
  bool _loading = false;
  _ScreenStatus _screenStatus = _ScreenStatus.chat;

  // Narrower set of example chips to fit mobile widths comfortably.
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
      if (e.status == AdvisorAnswerStatus.notSwitchedOn) {
        setState(() {
          _turns.add(_ErrorTurn(e.status));
          _loading = false;
          _screenStatus = _ScreenStatus.off;
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
      // notConfigured / serverError / networkError: inline error, chat stays.
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
    // Fail-closed full-screen states bypass the chat UI.
    if (_screenStatus == _ScreenStatus.off) {
      return _MobileFullScreenState(
        icon: Icons.lock_outline,
        title: "The advisor isn't switched on yet",
        body:
            'Once your team enables it, you can ask questions here. '
            'Nothing is sent anywhere until it is on.',
        isWarning: false,
      );
    }
    if (_screenStatus == _ScreenStatus.cap) {
      return _MobileFullScreenState(
        icon: Icons.access_time_outlined,
        title: 'You have used this month\'s advisor questions',
        body:
            'The limit resets next month. '
            'An admin can raise it sooner if you need more.',
        isWarning: true,
      );
    }

    return Column(
      children: <Widget>[
        // Header
        _MobileHeader(),
        // Thread (scrollable, fills available space)
        Expanded(
          child: _MobileThread(
            key: const Key('advisor_mobile_chat_thread'),
            turns: _turns,
            loading: _loading,
            scrollController: _scrollController,
            exampleChips: _exampleChips,
            onChipTap: (chip) {
              _controller.text = chip;
              _inputFocus.requestFocus();
            },
          ),
        ),
        // Reassurance line (HP #6 -- always visible)
        const _MobileReassuranceLine(),
        // Composer
        _MobileComposer(
          key: const Key('advisor_mobile_chat_composer'),
          controller: _controller,
          focusNode: _inputFocus,
          onSubmit: _submit,
          disabled: _loading,
        ),
      ],
    );
  }
}

// ---- Header ------------------------------------------------------------------

class _MobileHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border(
          bottom: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xFFE3F0F0),
                  Color(0xFFD6EBEB),
                ],
              ),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(
              Icons.chat_bubble_outline,
              size: 18,
              color: AppColors.peacockDark,
            ),
          ),
          const SizedBox(width: 12),
          // The Expanded column absorbs all remaining width so the badge
          // does not push out of the Row on narrow phones.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Ask the advisor',
                        style: AppTextStyles.body15Bold(
                          color: AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // "Suggestions only" badge -- HP #6 framing always
                    // visible. Sits inside the Expanded column so it
                    // cannot overflow the outer Row.
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3F0F0),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Suggestions only',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.peacockDark,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Ask about labor, sales, or targets in plain language.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Thread ------------------------------------------------------------------

class _MobileThread extends StatelessWidget {
  const _MobileThread({
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
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
      children: <Widget>[
        // Greeting + example chips (empty state)
        _MobileAdvisorRow(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _MobileAdvisorBody(
                text:
                    'Hi. Ask me anything about your labor, sales, or targets. '
                    'I will explain what I see and suggest what you could '
                    'consider.',
              ),
              if (turns.isEmpty) ...<Widget>[
                const SizedBox(height: 12),
                _MobileExampleChips(chips: exampleChips, onTap: onChipTap),
              ],
            ],
          ),
        ),
        for (final turn in turns) ...<Widget>[
          const SizedBox(height: 18),
          _buildTurn(turn),
        ],
        if (loading) ...<Widget>[
          const SizedBox(height: 18),
          _MobileAdvisorRow(child: const _MobileTypingIndicator()),
        ],
      ],
    );
  }

  Widget _buildTurn(_ChatTurn turn) {
    return switch (turn) {
      _UserTurn(question: final q) => _MobileUserBubbleRow(question: q),
      _AdvisorTurn(result: final r) =>
        _MobileAdvisorRow(child: _MobileAdvisorAnswer(result: r)),
      _ErrorTurn(status: final s) =>
        _MobileAdvisorRow(child: _MobileErrorMessage(status: s)),
    };
  }
}

// ---- Row wrappers ------------------------------------------------------------

class _MobileAdvisorRow extends StatelessWidget {
  const _MobileAdvisorRow({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFFE3F0F0),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.chat_bubble_outline,
            size: 13,
            color: AppColors.peacockDark,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(child: child),
      ],
    );
  }
}

class _MobileUserBubbleRow extends StatelessWidget {
  const _MobileUserBubbleRow({required this.question});
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
              key: const Key('advisor_mobile_chat_user_bubble'),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: AppColors.sunset,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(3),
                ),
              ),
              child: Text(
                question,
                style: const TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF6E7D8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.person_outline,
              size: 13,
              color: AppColors.sunsetDark,
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Advisor answer content --------------------------------------------------

class _MobileAdvisorBody extends StatelessWidget {
  const _MobileAdvisorBody({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTextStyles.body14(color: AppColors.textPrimary),
    );
  }
}

class _MobileAdvisorAnswer extends StatelessWidget {
  const _MobileAdvisorAnswer({required this.result});
  final AdvisorAnswerResult result;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // "ADVISOR" label -- uppercase, peacock (mirrors web version).
        const Text(
          'ADVISOR',
          key: Key('advisor_mobile_chat_advisor_label'),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: AppColors.peacockDark,
          ),
        ),
        const SizedBox(height: 5),
        // Serif lead line.
        Text(
          'Here is what I would consider',
          style: AppTextStyles.display16(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 8),
        // Answer body text.
        Text(
          result.answer,
          style: AppTextStyles.body14(color: AppColors.textPrimary),
        ),
        // Citations section (collapsible).
        if (result.citations.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          _MobileCitationsSection(citations: result.citations),
        ],
      ],
    );
  }
}

class _MobileErrorMessage extends StatelessWidget {
  const _MobileErrorMessage({required this.status});
  final AdvisorAnswerStatus status;

  @override
  Widget build(BuildContext context) {
    final exception = AdvisorAnswerException(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F4),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.7),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        exception.message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
    );
  }
}

// ---- Citations ---------------------------------------------------------------

class _MobileCitationsSection extends StatefulWidget {
  const _MobileCitationsSection({required this.citations});
  final List<AdvisorCitation> citations;

  @override
  State<_MobileCitationsSection> createState() =>
      _MobileCitationsSectionState();
}

class _MobileCitationsSectionState extends State<_MobileCitationsSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GestureDetector(
          onTap: () => setState(() => _open = !_open),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.link, size: 13, color: AppColors.sunsetDark),
              const SizedBox(width: 6),
              const Text(
                'Where this comes from',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sunsetDark,
                ),
              ),
              const SizedBox(width: 5),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 150),
                child: const Icon(
                  Icons.expand_more,
                  size: 13,
                  color: AppColors.sunsetDark,
                ),
              ),
            ],
          ),
        ),
        if (_open) ...<Widget>[
          const SizedBox(height: 6),
          Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Color(0xFFEDE6DC), width: 1),
              ),
            ),
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              children: <Widget>[
                for (final citation in widget.citations)
                  _MobileCitationRow(citation: citation),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _MobileCitationRow extends StatelessWidget {
  const _MobileCitationRow({required this.citation});
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: const Color(0xFFF4ECE3),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              _iconForTool(citation.toolName),
              size: 13,
              color: AppColors.peacockDark,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: AppTextStyles.body13(
                    color: AppColors.textSecondary,
                  ),
                ),
                if (snippet != null)
                  Text(
                    snippet,
                    style: const TextStyle(
                      fontSize: 11,
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

// ---- Example chips -----------------------------------------------------------

class _MobileExampleChips extends StatelessWidget {
  const _MobileExampleChips({required this.chips, required this.onTap});
  final List<String> chips;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: <Widget>[
        for (final chip in chips)
          _MobileExampleChip(
            key: Key('advisor_mobile_example_chip_${chip.hashCode}'),
            label: chip,
            onTap: () => onTap(chip),
          ),
      ],
    );
  }
}

class _MobileExampleChip extends StatelessWidget {
  const _MobileExampleChip({
    super.key,
    required this.label,
    required this.onTap,
  });
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFF6E7D8),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            color: AppColors.sunsetDark,
          ),
        ),
      ),
    );
  }
}

// ---- Typing indicator --------------------------------------------------------

class _MobileTypingIndicator extends StatefulWidget {
  const _MobileTypingIndicator();

  @override
  State<_MobileTypingIndicator> createState() => _MobileTypingIndicatorState();
}

class _MobileTypingIndicatorState extends State<_MobileTypingIndicator>
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
        _MobileTypingDot(controller: _controller, delay: 0.0),
        const SizedBox(width: 4),
        _MobileTypingDot(controller: _controller, delay: 0.15),
        const SizedBox(width: 4),
        _MobileTypingDot(controller: _controller, delay: 0.30),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'Looking at your numbers',
            key: const Key('advisor_mobile_chat_loading_indicator'),
            style: const TextStyle(fontSize: 13, color: Color(0xFF938A7E)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MobileTypingDot extends StatelessWidget {
  const _MobileTypingDot({
    required this.controller,
    required this.delay,
  });
  final AnimationController controller;
  final double delay;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final t = (controller.value - delay).clamp(0.0, 1.0);
        final opacity = t < 0.4 ? t / 0.4 : 1.0 - (t - 0.4) / 0.6;
        return Opacity(
          opacity: opacity.clamp(0.25, 1.0),
          child: Container(
            width: 6,
            height: 6,
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

// ---- Composer ----------------------------------------------------------------

class _MobileComposer extends StatefulWidget {
  const _MobileComposer({
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
  State<_MobileComposer> createState() => _MobileComposerState();
}

class _MobileComposerState extends State<_MobileComposer> {
  void _handleSubmit() {
    final text = widget.controller.text;
    if (text.trim().isEmpty || widget.disabled) return;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 10,
        bottom: 10 + MediaQuery.of(context).viewPadding.bottom,
      ),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border(
          top: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.8),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.backgroundMid,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppColors.borderSubtle.withValues(alpha: 0.6),
                  width: 1,
                ),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.chat_bubble_outline,
                    size: 14,
                    color: Color(0xFF938A7E),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('advisor_mobile_chat_input'),
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      enabled: !widget.disabled,
                      style: AppTextStyles.body14(
                        color: AppColors.textPrimary,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Ask about labor, sales, or targets...',
                        hintStyle: TextStyle(
                          color: Color(0xFF938A7E),
                          fontSize: 14,
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
          const SizedBox(width: 10),
          SizedBox(
            width: 42,
            height: 42,
            child: GestureDetector(
              onTap: widget.disabled ? null : _handleSubmit,
              child: Container(
                decoration: BoxDecoration(
                  color: widget.disabled
                      ? AppColors.borderSubtle
                      : AppColors.sunset,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.send,
                  key: const Key('advisor_mobile_chat_send_button'),
                  size: 18,
                  color: widget.disabled ? AppColors.textMuted : Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Reassurance line (HP #6) ------------------------------------------------

class _MobileReassuranceLine extends StatelessWidget {
  const _MobileReassuranceLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.backgroundDeep,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const <Widget>[
          Icon(
            Icons.verified_user_outlined,
            size: 12,
            color: Color(0xFF938A7E),
          ),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'The advisor suggests. You decide and act.',
              key: Key('advisor_mobile_chat_reassurance_line'),
              style: TextStyle(fontSize: 11.5, color: Color(0xFF938A7E)),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Full-screen fail-closed states ------------------------------------------

class _MobileFullScreenState extends StatelessWidget {
  const _MobileFullScreenState({
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
    final iconBg =
        isWarning ? const Color(0xFFF6EFD9) : AppColors.backgroundMid;
    final iconColor =
        isWarning ? const Color(0xFF9A7400) : AppColors.textMuted;

    return Column(
      children: <Widget>[
        _MobileHeader(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            child: Column(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.borderSubtle.withValues(alpha: 0.6),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: iconBg,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, size: 20, color: iconColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              title,
                              style: AppTextStyles.body14(
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
                const _MobileReassuranceLine(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
