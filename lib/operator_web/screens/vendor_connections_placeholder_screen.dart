// Phase 11W.0 — Vendor Connections placeholder screen.
//
// Mounted at `/locations/:location_id/vendor-connections`. The actual
// Vendor Connections widget tree (built by Phase 8 `8.0`) mounts here
// in slice `11W.8`. The placeholder follows the UX writing standard's
// "empty states explain context and suggest the next step" rule —
// operators who land here before Phase 8 see a brief explainer and a
// note about what will appear once the framework lands.

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../../theme/app_theme.dart';

/// Placeholder for the V1 Vendor Connections page. Lights up in
/// `11W.8` once Phase 8 `8.0` ships the shared widget tree.
class VendorConnectionsPlaceholderScreen extends StatelessWidget {
  const VendorConnectionsPlaceholderScreen({
    super.key,
    required this.session,
    required this.locationId,
  });

  final OperatorWebSession session;
  final String locationId;

  @override
  Widget build(BuildContext context) {
    final locationLabel = locationId == session.primaryLocationId
        ? '${session.primaryLocationName} (primary location)'
        : 'location $locationId';
    return Center(
      key: const Key('operator_web_vendor_connections_placeholder'),
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
                    Icons.cable_outlined,
                    size: 22,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Vendor connections',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Configuring connections for $locationLabel.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),
              _ContextCallout(
                heading: 'Vendor connections will appear here soon',
                body:
                    'The vendor connections widget — for connecting your '
                    'POS, reservation, and scheduling systems — lands in '
                    'slice 11W.8 once the Phase 8 framework (slice 8.0) '
                    'ships. Each new vendor card will appear here '
                    'automatically as Forge & Flow rolls out new '
                    'integrations.',
              ),
              const SizedBox(height: 14),
              _ContextCallout(
                heading: 'What you can expect',
                body:
                    'When live, this page shows one card per category — '
                    'POS, Reservation, Scheduling — with a Connect button '
                    'on each. Connecting a vendor takes you through the '
                    'vendor\'s own sign-in screen, then runs a 60-day '
                    'backfill so historical data is available right away. '
                    'Demo data on your operator app stays in place until '
                    'each category is connected.',
              ),
              const SizedBox(height: 14),
              _ContextCallout(
                heading: 'Need help right now?',
                body:
                    'Forge & Flow support can configure connections on '
                    'your behalf during onboarding. Reach out to your F&F '
                    'point of contact and they will set things up from '
                    'the F&F admin console while the self-serve flow is '
                    'being finished.',
              ),
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
