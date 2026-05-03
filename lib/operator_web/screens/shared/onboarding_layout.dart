// Phase 11W.0 — Shared layout for the operator-web onboarding screens.
//
// All four onboarding screens (welcome, password, MFA, T&Cs) share
// the same chrome — centered card on a brand-gradient backdrop, brand
// mark + step pill at the top, optional error banner, slot for the
// per-screen body. Lifting the chrome here keeps each screen file
// scoped to copy + form state and guarantees the visual rhythm
// matches across steps.

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// Shared chrome for the onboarding click path. Each screen wraps its
/// content in [OnboardingLayout] and supplies the per-screen title,
/// subtitle, step label, optional error message, and the body widget
/// (the form / explainer / button column the screen owns).
class OnboardingLayout extends StatelessWidget {
  const OnboardingLayout({
    super.key,
    required this.stepLabel,
    required this.title,
    required this.subtitle,
    required this.child,
    this.errorMessage,
  });

  /// Step pill copy (e.g. "Step 2 of 4 — Password").
  final String stepLabel;

  /// Display title for the screen.
  final String title;

  /// 1-2 sentence "what this screen is" intro.
  final String subtitle;

  /// Body slot — the per-screen form / explainer column.
  final Widget child;

  /// Optional remediation message rendered above the body.
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.backgroundDeep,
              AppColors.backgroundMid,
              AppColors.shimmer,
            ],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _OnboardingBrandMark(),
                    const SizedBox(height: 24),
                    _StepPill(
                      key: const Key('operator_web_step_pill'),
                      label: stepLabel,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: AppTextStyles.display28(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (errorMessage != null) ...[
                      _ErrorBanner(message: errorMessage!),
                      const SizedBox(height: 14),
                    ],
                    _OnboardingCard(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OnboardingBrandMark extends StatelessWidget {
  const _OnboardingBrandMark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.sunset.withValues(alpha: 0.18),
                blurRadius: 22,
                spreadRadius: 1,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/forge_flow_splash_icon.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Forge & Flow',
          textAlign: TextAlign.center,
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          'Operator Web Console',
          textAlign: TextAlign.center,
          style: AppTextStyles.mono8(color: AppColors.sunsetDark),
        ),
      ],
    );
  }
}

class _StepPill extends StatelessWidget {
  const _StepPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.peacock.withValues(alpha: 0.12),
          border: Border.all(
            color: AppColors.peacock.withValues(alpha: 0.45),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: AppTextStyles.mono8(color: AppColors.peacockDark),
        ),
      ),
    );
  }
}

class _OnboardingCard extends StatelessWidget {
  const _OnboardingCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      key: const Key('operator_web_onboarding_card'),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundSurface, AppColors.cardGlow],
          ),
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          boxShadow: [
            BoxShadow(
              color: AppColors.textPrimary.withValues(alpha: 0.04),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: child,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_onboarding_error_banner'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
  }
}
