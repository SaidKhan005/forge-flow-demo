// Advisor mobile chat nav wiring -- Slice D2 (mobile).
//
// Provides the bottom-nav index constant, icon/label used by the shell's
// BottomNavigationBar, and the gateway-resolved body builder so
// forge_flow_app.dart stays lean.
//
// HP #6: the nav label ("Advisor") does NOT imply commands. The screen
// itself carries the "Suggestions only" badge and the reassurance line
// "The advisor suggests. You decide and act."
//
// HP #2: no kDemoMode branch. The gateway seam (live vs demo) is resolved
// here and passed into AdvisorMobileChatScreen. The screen has one code
// path for both.

import 'package:flutter/material.dart';

import '../../services/advisor/advisor_answer_gateway.dart';
import 'advisor_mobile_chat_screen.dart';

/// The bottom-nav index for the Advisor tab.
const int kAdvisorMobileNavIndex = 4;

/// The BottomNavigationBarItem for the Advisor tab.
const BottomNavigationBarItem kAdvisorMobileNavItem = BottomNavigationBarItem(
  icon: Icon(Icons.chat_bubble_outline, size: 22),
  label: 'Advisor',
);

// Module-level demo gateway cache: one instance per session so the
// conversation state persists across rebuilds in the same session.
// HP #2: this is the writer-side provider seam, not a kDemoMode reader branch.
AdvisorAnswerGatewayDemo? _mobileDemoGateway;

/// Returns the AdvisorAnswerGateway to use for the mobile screen.
///
/// When the [source] object mixes in [AdvisorAnswerGatewayProvider], the
/// live gateway is used. Otherwise falls back to the module-level demo
/// gateway so the demo walkthrough works without a proxy.
///
/// HP #2: this decision is at the provider seam, not inside the screen.
AdvisorAnswerGateway resolveAdvisorMobileGateway(Object? source) {
  if (source is AdvisorAnswerGatewayProvider) {
    return source.advisorAnswerGateway;
  }
  return _mobileDemoGateway ??= AdvisorAnswerGatewayDemo();
}

/// Builds the Advisor tab body. The caller resolves the gateway from the auth
/// source and passes it here. The screen gets a stable key so the IndexedStack
/// preserves its state across tab switches.
Widget buildAdvisorMobileChatTab({required AdvisorAnswerGateway gateway}) {
  return AdvisorMobileChatScreen(
    key: const Key('advisor_mobile_chat_screen'),
    gateway: gateway,
  );
}
