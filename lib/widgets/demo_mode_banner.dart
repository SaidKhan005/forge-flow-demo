import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/integration/integration_adapter_common.dart';
import '../state/demo_mode_state_notifier.dart';
import '../theme/app_theme.dart';

/// Mobile app shell demo indicator.
///
/// The banner reads runtime `demo_mode_state` rows through
/// [DemoModeStateNotifier]. It does not branch on build flavor: when no
/// provider, no active scope, or no demo rows exist, the widget remains mounted
/// but collapses to zero height. Integration harnesses assert the mount so the
/// shell keeps the demo-state seam wired.
class DemoModeBanner extends StatelessWidget {
  const DemoModeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    DemoModeStateNotifier? notifier;
    try {
      notifier = context.watch<DemoModeStateNotifier?>();
    } on ProviderNotFoundException {
      notifier = null;
    }

    final snapshot = notifier?.snapshot;
    if (snapshot == null || !snapshot.hasDemoCategories) {
      return const SizedBox.shrink();
    }

    final categories = snapshot.demoCategories.map(_categoryLabel).join(', ');
    return Material(
      key: const Key('demo_mode_banner'),
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
          children: <Widget>[
            const Icon(
              Icons.science_outlined,
              color: AppColors.sunsetDark,
              size: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                categories.isEmpty
                    ? 'Demo data is active for this location.'
                    : 'Demo data is active for $categories.',
                style: const TextStyle(
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

  static String _categoryLabel(IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return 'POS';
      case IntegrationCategory.labor:
        return 'labor';
      case IntegrationCategory.reservation:
        return 'reservations';
    }
  }
}
