// Plans & limits Phase 5b — operator-web "Your plan" surface.
//
// A simple, read-only plan-awareness screen that matches the rest of
// the operator-web console (same OperatorWebScreenBody / Header /
// Panel / Banner widgets, same theme). It shows, in plain English:
//
//   * the operator's current plan name + a one-line description + the
//     headline price line;
//   * if the operator is on a Pilot free preview, how many days are
//     left before it ends;
//   * what the plan includes, in plain language (the AI advisor plus
//     whichever features the plan layers on);
//   * an upgrade intent — a plain "Talk to us about upgrading" button
//     that opens contact guidance. Forge & Flow never changes a plan
//     on the operator's behalf, so this is an intent, not an action.
//
// Display-only. This screen does NOT gate any feature on or off (that
// is the deferred Phase 5d). It reads the current plan key and the
// trial fields off [OperatorWebSession] and the per-plan feature list
// off the client-side pricing constants
// ([kPricingPlanPresentations] / [kFeatureSlugCatalog] /
// [buildDefaultFeatureEntitlements]); it makes no proxy call of its
// own and adds no new endpoint.
//
// Honest unknown state (Metric Honesty Doctrine): when the session
// does not carry a recognized tier yet (the live source projects the
// tier in a small gated follow-up), the screen renders an honest "we
// could not load your plan yet" panel rather than a phantom plan.
//
// UX writing standard: every label / explainer reads as if training
// the operator. Plain English, no jargon, no em dash.

import 'package:flutter/material.dart';

import '../../admin/models/pricing_tier_admin_models.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

/// "Your plan" screen for the operator-web console.
class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key, required this.session, this.nowUtc});

  final OperatorWebSession session;

  /// Optional UTC clock seam. Production uses [DateTime.now]; widget
  /// tests pin this so the free-preview countdown is deterministic.
  final DateTime Function()? nowUtc;

  /// Resolved plan presentation for the session's tier, or null when
  /// the tier is missing / unrecognized (honest unknown state).
  PricingPlanPresentation? get _plan {
    final tier = session.subscriptionTier?.trim();
    if (tier == null || tier.isEmpty) return null;
    return findPricingPlanPresentation(tier);
  }

  /// Whole days left in the Pilot free preview, or null when the
  /// operator is not on a trial / the expiry is missing or already
  /// passed. Rounds up so the final partial day still reads as a day
  /// left rather than "0 days left" while access is still live.
  int? get _trialDaysLeft {
    if (!session.trialMode) return null;
    final expires = session.trialExpiresAt;
    if (expires == null) return null;
    final now = (nowUtc ?? DateTime.now)().toUtc();
    final remaining = expires.toUtc().difference(now);
    if (remaining.inSeconds <= 0) return null;
    return remaining.inHours ~/ 24 + (remaining.inHours % 24 == 0 ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return OperatorWebScreenBody(
      scrollKey: const Key('operator_web_plan_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const OperatorWebScreenHeader(
            icon: Icons.workspace_premium_outlined,
            title: 'Your plan',
            subtitle: 'See the plan your business is on and what it includes.',
          ),
          const SizedBox(height: 18),
          if (plan == null)
            const _PlanUnknownPanel()
          else ...<Widget>[
            _CurrentPlanPanel(
              plan: plan,
              trialDaysLeft: _trialDaysLeft,
              onTrial: session.trialMode,
            ),
            const SizedBox(height: 14),
            _IncludedPanel(tierKey: plan.tierKey),
            const SizedBox(height: 14),
            _UpgradePanel(plan: plan),
          ],
        ],
      ),
    );
  }
}

/// Honest unknown state: the session has no recognized tier yet. We do
/// not invent a plan; we tell the operator plainly and point them at
/// support. (Metric Honesty Doctrine: no phantom values.)
class _PlanUnknownPanel extends StatelessWidget {
  const _PlanUnknownPanel();

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('operator_web_plan_unknown'),
      title: 'Your plan',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                '—',
                key: const Key('operator_web_plan_name'),
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'We could not load your plan just yet. Refresh the page in a '
            'moment. If it still does not show, reach out to Forge & Flow '
            'and we will confirm the plan your business is on.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Current plan: name, one-line description, headline price line, and
/// (when on a Pilot free preview) the days-left countdown.
class _CurrentPlanPanel extends StatelessWidget {
  const _CurrentPlanPanel({
    required this.plan,
    required this.trialDaysLeft,
    required this.onTrial,
  });

  final PricingPlanPresentation plan;
  final int? trialDaysLeft;
  final bool onTrial;

  @override
  Widget build(BuildContext context) {
    final template = findPricingTierTemplate(plan.tierKey);
    final planName = template?.displayName ?? _titleCase(plan.tierKey);
    return OperatorWebPanel(
      key: const Key('operator_web_plan_current'),
      title: 'Your plan',
      tone: OperatorWebPanelTone.highlight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            planName,
            key: const Key('operator_web_plan_name'),
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            plan.priceLine,
            key: const Key('operator_web_plan_price_line'),
            style: AppTextStyles.mono14(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 10),
          Text(
            _planSummary(plan),
            style: AppTextStyles.body14(color: AppColors.textSecondary),
          ),
          if (onTrial) ...<Widget>[
            const SizedBox(height: 14),
            _TrialCountdownBanner(daysLeft: trialDaysLeft),
          ],
        ],
      ),
    );
  }

  /// Plain-English one-liner for the plan. Pilot reads as a free
  /// preview; paid plans read as "the full product plus AI".
  static String _planSummary(PricingPlanPresentation plan) {
    if (plan.tierKey == 'pilot') {
      return 'A free preview of Forge & Flow on sample data, including the '
          'AI advisor. Connect your real sales and labor data to go live.';
    }
    return 'The full Forge & Flow product plus the AI advisor. '
        '${plan.includes}';
  }

  static String _titleCase(String key) {
    if (key.isEmpty) return key;
    return key[0].toUpperCase() + key.substring(1);
  }
}

/// Free-preview countdown. Warning tone so it reads as a gentle "this
/// ends soon" nudge, never an error. Honest empty state when the
/// days-left value is unknown.
class _TrialCountdownBanner extends StatelessWidget {
  const _TrialCountdownBanner({required this.daysLeft});

  final int? daysLeft;

  @override
  Widget build(BuildContext context) {
    final days = daysLeft;
    final message = days == null
        ? 'You are on a free preview. We could not work out how many days '
              'are left just yet. Connect your data whenever you are ready '
              'to go live.'
        : 'You have $days ${days == 1 ? 'day' : 'days'} left in your free '
              'preview. Connect your sales and labor data to keep going '
              'after it ends.';
    return OperatorWebBanner(
      key: const Key('operator_web_plan_trial_banner'),
      icon: Icons.timelapse_outlined,
      tone: OperatorWebBannerTone.warning,
      title: 'Free preview',
      message: message,
    );
  }
}

/// What the plan includes, in plain language: the AI advisor plus the
/// features the plan layers on. Reads the per-tier matrix from the
/// client-side entitlement defaults so this stays in step with the
/// admin Plans & limits screen without a proxy call.
class _IncludedPanel extends StatelessWidget {
  const _IncludedPanel({required this.tierKey});

  final String tierKey;

  @override
  Widget build(BuildContext context) {
    final features = _includedFeatureNames(tierKey);
    return OperatorWebPanel(
      key: const Key('operator_web_plan_included'),
      title: "What's included",
      subtitle: 'Everything your plan gives your team today.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (features.isEmpty)
            Text(
              'We could not list the included features just yet. Reach out '
              'to Forge & Flow and we will walk you through what your plan '
              'covers.',
              key: const Key('operator_web_plan_included_empty'),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            )
          else
            for (final name in features)
              Padding(
                key: Key(
                  'operator_web_plan_feature_'
                  '${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}',
                ),
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.check_circle_outline,
                        size: 18,
                        color: AppColors.positive,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        name,
                        style: AppTextStyles.body14(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  /// Plain-English names of every feature the [tierKey] includes, in
  /// the catalog display order. Built from the same cumulative-ladder
  /// defaults the admin matrix seeds from, so the operator sees the
  /// honest per-plan set rather than a hand-maintained copy.
  static List<String> _includedFeatureNames(String tierKey) {
    final normalized = tierKey.trim().toLowerCase();
    final enabledSlugs = <String>{
      for (final entry in buildDefaultFeatureEntitlements())
        if (entry.tierKey == normalized && entry.enabled) entry.featureSlug,
    };
    return <String>[
      for (final slug in kFeatureSlugOrder)
        if (enabledSlugs.contains(slug)) featureSlugDisplayName(slug),
    ];
  }
}

/// Upgrade intent. Forge & Flow never changes a plan on the operator's
/// behalf, so this is a plain "talk to us" CTA that opens contact
/// guidance, not a self-serve plan switch. Hidden for the top plan
/// (Enterprise) where there is nothing above to move to.
class _UpgradePanel extends StatelessWidget {
  const _UpgradePanel({required this.plan});

  final PricingPlanPresentation plan;

  bool get _isTopPlan => plan.tierKey == 'enterprise';

  @override
  Widget build(BuildContext context) {
    if (_isTopPlan) {
      return OperatorWebBanner(
        key: const Key('operator_web_plan_upgrade_top'),
        icon: Icons.verified_outlined,
        title: 'You are on our top plan',
        message:
            'Enterprise includes everything Forge & Flow offers. Reach out '
            'any time if your needs change.',
      );
    }
    return OperatorWebBanner(
      key: const Key('operator_web_plan_upgrade'),
      icon: Icons.upgrade_outlined,
      title: 'Want more from Forge & Flow?',
      message:
          'Higher plans add more for your team. We will talk it through and '
          'set up the change for you. Forge & Flow never switches your plan '
          'on its own.',
      action: FilledButton(
        key: const Key('operator_web_plan_upgrade_cta'),
        onPressed: () => _showUpgradeDialog(context),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.sunset,
          foregroundColor: AppColors.backgroundSurface,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: const Text('Talk to us about upgrading'),
      ),
    );
  }

  Future<void> _showUpgradeDialog(BuildContext context) {
    return showOperatorWebDialog<void>(
      context: context,
      title: 'Talk to us about upgrading',
      icon: Icons.upgrade_outlined,
      child: Text(
        'Email hello@forgeandflow.com or message your Forge & Flow contact '
        'and let them know you would like to upgrade. We will walk you '
        'through the plans and set up the change for you. Your plan does '
        'not change until you confirm it with us.',
        style: AppTextStyles.body13(color: AppColors.textPrimary),
      ),
      actions: <Widget>[
        FilledButton(
          key: const Key('operator_web_plan_upgrade_dialog_close'),
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}
