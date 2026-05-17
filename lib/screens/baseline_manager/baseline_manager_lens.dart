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
      chips.add(const SizedBox(width: AppSpacing.sm));
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.18)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppColors.sunset : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: AppRadius.pillR,
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

/// R10: scope label rendered as a plain SECTION HEADER for the summary
/// table beneath it, e.g. "Dinner targets" or "Whole day targets". It is
/// NOT interactive (the lens bar above is the control): no border, no
/// chip/pill background, no tap handler, no button affordance. The
/// uppercase mono caption styling matches the other section headers on
/// this screen (e.g. STAR SHIFT SELECTION). The label text still comes
/// from the resolved operator defs (or the whole-day sentinel), never a
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
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '$scopeLabel targets'.toUpperCase(),
          style: AppTextStyles.mono7(color: AppColors.textMuted),
        ),
      ),
    );
  }
}
