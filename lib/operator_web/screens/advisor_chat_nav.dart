// Advisor chat nav wiring — Slice D2 (operator-web).
//
// Mirrors the plan_nav.dart decomposition pattern: the router references
// the constant, the nav item, and the body builder from here so
// operator_web_router.dart does not grow past its frozen size ceiling.
//
// HP #6: the nav label ("Advisor") does NOT say "commands" or "do it".
// The screen itself carries the "Suggestions only" badge + the reassurance
// line "The advisor suggests. You decide and act." to keep the framing
// consistent at every level.

import 'package:flutter/material.dart';

import '../../services/advisor/advisor_answer_gateway.dart';
import '../auth/operator_web_auth_source.dart';
import '../widgets/web_app_shell.dart';
import 'advisor_chat_screen.dart';

/// Stable nav id for the advisor chat surface. Tests and deep links key
/// off this.
const String kOperatorWebNavAdvisor = 'advisor';

/// Side-rail nav item for "Advisor". Lives here so the router stays lean.
const OperatorWebNavItem kOperatorWebAdvisorNavItem = OperatorWebNavItem(
  id: kOperatorWebNavAdvisor,
  title: 'Advisor',
  icon: Icons.chat_bubble_outline,
  group: 'Operations',
);

// Module-level demo gateway cache: created once per nav file load, shared
// across builds so the conversation state persists within a session even
// when the router rebuilds (same lifetime as the router's own fields).
AdvisorAnswerGatewayDemo? _demoGateway;

/// Builds the Advisor chat route body. Resolves the gateway from the auth
/// source when it mixes in [AdvisorAnswerGatewayProvider]; otherwise falls
/// back to the module-level [AdvisorAnswerGatewayDemo] so the demo
/// walkthrough and any unmixed live source work without a live proxy.
/// HP #2: the screen does not know or care which implementation is used.
Widget operatorWebAdvisorChatBody({
  required OperatorWebSession session,
  required OperatorWebAuthSource source,
}) {
  final AdvisorAnswerGateway gateway;
  if (source is AdvisorAnswerGatewayProvider) {
    gateway =
        (source as AdvisorAnswerGatewayProvider).advisorAnswerGateway;
  } else {
    gateway = _demoGateway ??= AdvisorAnswerGatewayDemo();
  }
  return AdvisorChatScreen(
    key: const Key('operator_web_advisor_chat_screen'),
    session: session,
    gateway: gateway,
  );
}
