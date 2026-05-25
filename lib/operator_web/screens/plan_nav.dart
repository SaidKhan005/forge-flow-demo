// Plans & limits Phase 5b — "Your plan" nav wiring, kept out of the
// router so `operator_web_router.dart` does not grow past its frozen
// size ceiling (the size lint's prescribed fix: decompose into a
// helper rather than inflate the router). The router references the
// constant, the nav item, and the body builder below.

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../widgets/web_app_shell.dart';
import 'plan_screen.dart';

/// Stable nav id for the display-only "Your plan" surface. Tests and
/// deep links key off this. No feature gating (deferred Phase 5d).
const String kOperatorWebNavPlan = 'plan';

/// Side-rail nav item for "Your plan". Same shape as every other
/// operator-web nav item; lives here so the router stays lean.
const OperatorWebNavItem kOperatorWebPlanNavItem = OperatorWebNavItem(
  id: kOperatorWebNavPlan,
  title: 'Your plan',
  icon: Icons.workspace_premium_outlined,
  group: 'Plan & billing',
);

/// Builds the "Your plan" route body. Web-only: [PlanScreen] reads the
/// tier + trial fields off the session and the per-plan feature list
/// off the client-side pricing constants, so there is no gateway and
/// no `_liveSurfaceMissingGateway` guard applies. The [nowUtc] clock
/// seam threads through so the free-preview countdown is deterministic
/// in tests.
Widget operatorWebPlanScreenBody({
  required OperatorWebSession session,
  DateTime Function()? nowUtc,
}) {
  return PlanScreen(session: session, nowUtc: nowUtc);
}
