// Choose Star Shifts R1: service-period lens bar.
//
// Horizontal lens selector that re-scopes both the hero calendar and
// the summary/preview region together. Options are "Whole day" plus
// one entry per operator-configured service period, in the operator's
// configured order with the operator's configured labels. Nothing here
// assumes a fixed daypart count: every period entry derives from the
// resolved `defs` passed by the screen, so a 4+ period operator renders
// correctly.

import 'package:flutter/material.dart';

import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../theme/app_theme.dart';

/// Sentinel lens id meaning "no period filter, show the cover-weighted
/// whole-day rollup". Kept distinct from any service-period id.
const String kWholeDayLensId = '__whole_day__';

/// Plain-English label for the whole-day lens.
const String kWholeDayLensLabel = 'Whole day';

class BaselineManagerLensBar extends StatelessWidget {
  /// Operator-configured service-period definitions (already resolved by
  /// the screen from the persisted timing config, with the demo-defs
  /// fallback applied upstream).
  final List<ServicePeriodDefinition> defs;

  /// Currently selected lens id ([kWholeDayLensId] or a period id).
  final String selectedLensId;

  /// Called with the newly selected lens id.
  final ValueChanged<String> onLensSelected;

  const BaselineManagerLensBar({
    super.key,
    required this.defs,
    required this.selectedLensId,
    required this.onLensSelected,
  });

  @override
  Widget build(BuildContext context) {
    // Ordered period entries derive entirely from the operator config.
    final ordered = ServicePeriodDefinitionResolver.ordered(defs);

    final chips = <Widget>[
      _LensChip(
        key: const ValueKey<String>('lens_$kWholeDayLensId'),
        label: kWholeDayLensLabel,
        selected: selectedLensId == kWholeDayLensId,
        onTap: () => onLensSelected(kWholeDayLensId),
      ),
    ];

    for (final d in ordered) {
      chips.add(const SizedBox(width: 8));
      chips.add(
        _LensChip(
          key: ValueKey<String>('lens_${d.id}'),
          label: d.label,
          selected: selectedLensId == d.id,
          onTap: () => onLensSelected(d.id),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: chips),
      ),
    );
  }
}

class _LensChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LensChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.18)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppColors.sunset : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label.toUpperCase(),
          style: AppTextStyles.mono8(
            color: selected ? AppColors.sunset : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Small scope tag shown above the summary/preview region, e.g.
/// "Dinner targets" or "Whole day targets". The label comes from the
/// resolved operator defs (or the whole-day sentinel), never a
/// hardcoded daypart name.
class BaselineManagerScopeTag extends StatelessWidget {
  final List<ServicePeriodDefinition> defs;
  final String selectedLensId;

  const BaselineManagerScopeTag({
    super.key,
    required this.defs,
    required this.selectedLensId,
  });

  @override
  Widget build(BuildContext context) {
    final scopeLabel = selectedLensId == kWholeDayLensId
        ? kWholeDayLensLabel
        : ServicePeriodDefinitionResolver.labelForId(defs, selectedLensId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.backgroundMid,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '$scopeLabel targets',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}
