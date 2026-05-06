// Phase 11W.3 - Location card.
//
// Reusable summary card for one location in the org-tree view. The
// hierarchy screen renders this as a leaf under each org-unit. The
// move dialog reuses the same card to summarise the location being
// moved. Pure-presentation; no controllers, no gateway access.

import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../theme/app_theme.dart';

/// Summary card for one [TeamOrgLocationEntry]. The optional Move
/// trailing button is wired only when [onMove] is supplied; read-only
/// audiences pass null so the affordance stays hidden per the parity
/// contract § Hierarchy Read-only audiences rule.
class LocationCard extends StatelessWidget {
  const LocationCard({
    super.key,
    required this.location,
    this.onMove,
    this.busy = false,
  });

  final TeamOrgLocationEntry location;
  final VoidCallback? onMove;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('operator_web_location_card_${location.locationId}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const Icon(
            Icons.place_outlined,
            size: 18,
            color: AppColors.sunsetDark,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  location.label,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  location.orgUnitPath,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onMove != null)
            TextButton(
              key: Key(
                'operator_web_location_card_move_${location.locationId}',
              ),
              onPressed: busy ? null : onMove,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.sunsetDark,
              ),
              child: const Text('Move'),
            )
          else if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.sunsetDark,
              ),
            ),
        ],
      ),
    );
  }
}
