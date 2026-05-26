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

/// Builds the Advisor chat route body. Resolves the gateway from the auth
/// source when it mixes in [AdvisorAnswerGatewayProvider]; otherwise falls
/// back to [AdvisorAnswerGatewayDemo] (demo walkthrough and any
/// live source that has not yet wired the mixin). The screen does not
/// know or care which implementation is used (HP #2 demo parity).
Widget operatorWebAdvisorChatBody({
  required OperatorWebSession session,
  required OperatorWebAuthSource source,
  AdvisorAnswerGateway? routerOwnedDemoGateway,
}) {
  final gateway = _resolveGateway(source, routerOwnedDemoGateway);
  return AdvisorChatScreen(
    key: const Key('operator_web_advisor_chat_screen'),
    session: session,
    gateway: gateway,
  );
}

AdvisorAnswerGateway _resolveGateway(
  OperatorWebAuthSource source,
  AdvisorAnswerGateway? routerOwned,
) {
  if (source is AdvisorAnswerGatewayProvider) {
    return (source as AdvisorAnswerGatewayProvider).advisorAnswerGateway;
  }
  return routerOwned ?? AdvisorAnswerGatewayDemo();
}
