// Phase 8 spine-bridge Lane .B — Covers source per-daypart toggle.
//
// Three states per daypart (lunch / dinner / late_night):
//
//   * vendor   — read covers from POS (default).
//   * forecast — substitute the F&F-computed forecast covers value.
//   * manual   — operator types the number per business date.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Covers source card" + "Covers source resolution" sections.
//
// When the operator picks `manual` for a daypart, the parent screen
// is responsible for rendering the manual-entry sub-card; this
// widget only owns the per-daypart 3-way picker plus the dynamic
// vendor relativity label.

import 'package:flutter/material.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../theme/app_theme.dart';
import 'vendor_relativity_label.dart';

class CoversSourceToggle extends StatelessWidget {
  const CoversSourceToggle({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.bundle,
  });

  final DataAccuracySettings settings;
  final void Function(Daypart daypart, CoversSource source) onChanged;
  final VendorConnectionsBundle? bundle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('data_accuracy_covers_source_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.restaurant_menu_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Where covers come from, per daypart',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Covers (number of guests served) drive the per-cover '
            'metrics on your dashboard. Pick where Forge & Flow should read '
            'covers from for each daypart. Different dayparts can use '
            'different sources - for example, vendor at lunch and manual at '
            'dinner.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          for (final daypart in Daypart.values) ...[
            _DaypartRow(
              daypart: daypart,
              source: settings.coversSourceFor(daypart),
              onChanged: (source) => onChanged(daypart, source),
            ),
            if (daypart != Daypart.values.last) const SizedBox(height: 10),
          ],
          const SizedBox(height: 14),
          VendorRelativityLabel(
            setting: VendorRelativitySetting.covers,
            bundle: bundle,
          ),
        ],
      ),
    );
  }
}

class _DaypartRow extends StatelessWidget {
  const _DaypartRow({
    required this.daypart,
    required this.source,
    required this.onChanged,
  });

  final Daypart daypart;
  final CoversSource source;
  final ValueChanged<CoversSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('covers_source_daypart_${daypart.wire}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              _daypartLabel(daypart),
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final option in CoversSource.values)
                  _ChoiceChip(
                    chipKey: Key(
                      'covers_source_chip_${daypart.wire}_${option.wire}',
                    ),
                    label: _sourceLabel(option),
                    selected: option == source,
                    onTap: () => onChanged(option),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _daypartLabel(Daypart d) {
    switch (d) {
      case Daypart.lunch:
        return 'Lunch';
      case Daypart.dinner:
        return 'Dinner';
      case Daypart.lateNight:
        return 'Late night';
    }
  }

  String _sourceLabel(CoversSource s) {
    switch (s) {
      case CoversSource.vendor:
        return 'Vendor';
      case CoversSource.forecast:
        return 'Forecast';
      case CoversSource.manual:
        return 'Manual';
    }
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.chipKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: chipKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.14)
              : AppColors.backgroundSurface,
          border: Border.all(
            color: selected ? AppColors.sunsetDark : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: AppTextStyles.mono14(
            color: selected ? AppColors.sunsetDark : AppColors.textSecondary,
            weight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
