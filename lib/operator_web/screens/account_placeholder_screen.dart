// Phase 11W.0 — Account placeholder screen.
//
// Mounted at `/account`. The full account form lands in `11W.7`. The
// placeholder follows the UX writing standard's "empty states explain
// context and suggest the next step" rule — operators who land here
// at V1 see a brief explainer + a pointer to mobile Settings, not a
// blank screen.

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../../theme/app_theme.dart';

/// Placeholder for the V1 Account screen. Lights up in `11W.7`.
class AccountPlaceholderScreen extends StatelessWidget {
  const AccountPlaceholderScreen({super.key, required this.session});

  final OperatorWebSession session;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('operator_web_account_placeholder'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.business_outlined,
                    size: 22,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Account and business setup',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Welcome, ${session.displayName}. Your operator account '
                'for ${session.businessName} is ready.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 18),
              _ContextCallout(
                heading: 'Account management is coming soon',
                body:
                    'The web-based account screen — for editing business '
                    'name, brand color, currency, business-day rollover, '
                    'and per-location time zones — lands in slice 11W.7. '
                    'In the meantime, please use the operator mobile app '
                    'under Settings → Account for those edits. Mobile '
                    'Settings stays as the lightweight access point even '
                    'after the web equivalent ships.',
              ),
              const SizedBox(height: 14),
              _NextActionCallout(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextCallout extends StatelessWidget {
  const _ContextCallout({required this.heading, required this.body});

  final String heading;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 6),
          Text(body, style: AppTextStyles.body13(color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

class _NextActionCallout extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.06),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What you can do here today',
            style: AppTextStyles.mono11(color: AppColors.peacockDark),
          ),
          const SizedBox(height: 6),
          Text(
            'Open the Vendor connections page from the side nav. '
            'Connecting your POS, reservation, and scheduling systems is '
            'how Forge & Flow starts pulling live data for your '
            'locations. The Vendor connections widget itself lights up '
            'as Phase 8 vendor adapters ship.',
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}
