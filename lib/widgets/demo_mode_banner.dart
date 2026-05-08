// 8.demo-mode-banner — Runtime per-(operator, location, category)
// demo-mode banner.
//
// Architecture promise (`lib/services/integration/demo_mode_state.dart`
// header lines 12-15): the operator-app banner reads runtime state
// from the `demo_mode_state` surface, NOT from a build-time flag.
// Once an operator's first vendor connection backfills successfully,
// `DemoModeFlipPolicy.evaluateFlip` flips the row to `is_demo = false`
// and the banner clears without a redeploy.
//
// This widget is the read-side complement: it watches
// [DemoModeStateNotifier] and renders one row per category that is
// still `is_demo = true` (POS, Labor, Reservation). When every
// category flips, the widget collapses to a zero-height
// `SizedBox.shrink`.
//
// HP #2 (CLAUDE.md): no `kDemoMode` reader-side branch lives here.
// The banner is driven entirely by per-(O, L, C) runtime state.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/integration/integration_adapter_common.dart';
import '../state/demo_mode_state_notifier.dart';
import '../theme/app_theme.dart';

/// Slim banner stack that surfaces categories still in demo mode for
/// the active (operator, location). Renders nothing when no scope is
/// active or every category has flipped to live.
class DemoModeBanner extends StatelessWidget {
  const DemoModeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    DemoModeStateNotifier? notifier;
    try {
      notifier = context.watch<DemoModeStateNotifier>();
    } on ProviderNotFoundException {
      notifier = null;
    }
    if (notifier == null) {
      return const SizedBox.shrink();
    }
    final snapshot = notifier.snapshot;
    if (!snapshot.hasDemoCategories) {
      return const SizedBox.shrink();
    }
    final categories = snapshot.demoCategories;
    return Material(
      key: const Key('demo_mode_banner'),
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final category in categories)
            _DemoCategoryRow(
              key: Key('demo_mode_banner_${_categoryKey(category)}'),
              category: category,
            ),
        ],
      ),
    );
  }
}

/// One row inside the banner stack. Includes a leading info icon, a
/// per-category copy line, and a hint that the row clears once the
/// operator's first vendor backfill commits.
class _DemoCategoryRow extends StatelessWidget {
  const _DemoCategoryRow({super.key, required this.category});

  final IntegrationCategory category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
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
        children: <Widget>[
          const Icon(
            Icons.science_outlined,
            color: AppColors.sunsetDark,
            size: 18,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _copyFor(category),
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _copyFor(IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return 'Demo POS data — connect a POS to go live.';
      case IntegrationCategory.labor:
        return 'Demo labor data — connect a labor system to go live.';
      case IntegrationCategory.reservation:
        return 'Demo reservation data — connect a reservation system '
            'to go live.';
    }
  }
}

String _categoryKey(IntegrationCategory category) {
  switch (category) {
    case IntegrationCategory.pos:
      return 'pos';
    case IntegrationCategory.labor:
      return 'labor';
    case IntegrationCategory.reservation:
      return 'reservation';
  }
}
