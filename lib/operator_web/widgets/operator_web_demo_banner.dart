// G19 — Operator Web Console demo indicator.
//
// Operator-web has no per-(operator, location, category) runtime
// `demo_mode_state` surface like mobile (that path is driven by vendor
// connections + `DemoModeFlipPolicy`, which the web console does not
// host). The web console's "demo" condition is the fixture-driven
// auth source: `DemoOperatorWebAuthSource` substitutes in-memory
// `Demo*Gateway()` fixtures for every team/roles/sessions/audit/
// security/timing surface. When that source is active the data on
// screen is legitimately fixture data — but nothing told the operator,
// so a walkthrough viewer could mistake the fixtures for their real
// business (audit finding G19; mobile has `DemoModeBanner`, web had
// nothing).
//
// This is the operator-web parity of mobile's `DemoModeBanner`: a
// slim, persistent, unobtrusive strip mounted once in the app shell
// (NOT per screen). It is driven by an explicit `isDemoSource` flag
// the router computes from the auth source TYPE
// (`source is DemoOperatorWebAuthSource`) — NOT a `kDemoMode`
// reader-side branch and NOT a build-time flag. A live source
// (`FirebaseOperatorWebAuthSource` or any future live source) never
// renders this banner; when present the data is always real.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Slim demo indicator for the operator-web shell. Renders a single
/// persistent strip when the fixture-driven demo auth source is
/// active; collapses to a zero-height [SizedBox.shrink] for any live
/// source so production operators never see it.
class OperatorWebDemoBanner extends StatelessWidget {
  const OperatorWebDemoBanner({super.key, required this.isDemoSource});

  /// True only when the router's auth source is the fixture-driven
  /// [DemoOperatorWebAuthSource] (or a test subclass). The router owns
  /// the demo-vs-live discrimination so this widget stays a pure
  /// render of the flag.
  final bool isDemoSource;

  @override
  Widget build(BuildContext context) {
    if (!isDemoSource) {
      return const SizedBox.shrink();
    }
    return Material(
      key: const Key('operator_web_demo_banner'),
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.sunsetDark.withValues(alpha: 0.10),
          border: Border(
            bottom: BorderSide(
              color: AppColors.sunsetDark.withValues(alpha: 0.45),
              width: 1,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: const <Widget>[
            Icon(
              Icons.science_outlined,
              color: AppColors.sunsetDark,
              size: 18,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Demo data. This is a sample walkthrough, not your real '
                'business. Sign in with your live account to manage real '
                'data.',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
