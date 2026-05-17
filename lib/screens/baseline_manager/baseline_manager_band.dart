// Choose Star Shifts R3: Lean / Balanced / Generous band control.
//
// The band is pure UI sugar. Picking a band DERIVES a draft selection:
// for every operator-configured service period (resolved `defs`, never a
// hardcoded daypart list) it keeps the top-N strongest candidate shifts
// for that period by CPLH, where N grows Lean -> Balanced -> Generous.
//
// The band ONLY produces a `Set<String>` of recordKeys that the screen
// assigns to its draft set. It never persists, never adds a strictness
// column, never introduces a second pooling formula, and never touches
// the target write path. Commit still flows through the unchanged
// `BaselineManagerService.saveSelection`. The operator can hand-tweak
// the calendar / sheet afterwards exactly as before.

import 'package:flutter/material.dart';

import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../models/baseline_candidate_shift.dart';
import '../../theme/app_theme.dart';

/// The three selectable bands. The only thing that differs between tiers
/// is how many of each period's strongest shifts get kept.
enum StarBand {
  lean,
  balanced,
  generous;

  /// How many of each configured period's strongest shifts (by CPLH) to
  /// keep. Lean keeps the fewest, Generous the most. Nothing here assumes
  /// a fixed period count: N is per configured period, applied across
  /// however many periods the operator has.
  int get nPerPeriod {
    switch (this) {
      case StarBand.lean:
        return 2;
      case StarBand.balanced:
        return 4;
      case StarBand.generous:
        return 6;
    }
  }

  /// Plain-English chip label (no dashes anywhere).
  String get label {
    switch (this) {
      case StarBand.lean:
        return 'Lean';
      case StarBand.balanced:
        return 'Balanced';
      case StarBand.generous:
        return 'Generous';
    }
  }

  /// Plain-English one-line explanation shown under the band row.
  String get helperText {
    switch (this) {
      case StarBand.lean:
        return 'Lean keeps only the strongest few shifts in each service '
            'period. Tightest target.';
      case StarBand.balanced:
        return 'Balanced keeps a moderate set of strong shifts in each '
            'service period.';
      case StarBand.generous:
        return 'Generous keeps a wider set of strong shifts in each '
            'service period. Most forgiving target.';
    }
  }
}

/// Derives the band selection: per operator-configured period (iterating
/// the resolved [defs], never a hardcoded daypart list), keep the top
/// [StarBand.nPerPeriod] candidate shifts for that period ranked by CPLH
/// (strongest = highest CPLH first; ties broken by recordKey for a stable
/// deterministic result). Returns ONLY the chosen recordKeys; the caller
/// assigns these to the draft set. No persistence, no second pooling
/// formula, no write-path contact.
Set<String> deriveBandSelection(
  List<BaselineCandidateShift> candidates,
  List<ServicePeriodDefinition> defs,
  StarBand band,
) {
  // Group candidates by their service period (daypart id). A candidate
  // whose period is not in the configured defs is still grouped by its
  // own id so it is never silently dropped from consideration.
  final byPeriod = <String, List<BaselineCandidateShift>>{};
  for (final c in candidates) {
    byPeriod.putIfAbsent(c.daypart, () => []).add(c);
  }

  // Iterate periods in the operator-configured order, then any extra
  // period present in data but absent from the config (kept visible so
  // nothing is silently lost), exactly mirroring the day-sheet rule.
  final orderedIds =
      ServicePeriodDefinitionResolver.ordered(defs).map((d) => d.id).toList();
  final periodIds = <String>[
    ...orderedIds.where(byPeriod.containsKey),
    ...byPeriod.keys.where((k) => !orderedIds.contains(k)),
  ];

  final keys = <String>{};
  final n = band.nPerPeriod;
  for (final periodId in periodIds) {
    final list = [...byPeriod[periodId]!];
    // Strongest first: highest CPLH wins; stable tie-break on recordKey.
    list.sort((a, b) {
      final cmp = b.cplh.compareTo(a.cplh);
      return cmp != 0 ? cmp : a.recordKey.compareTo(b.recordKey);
    });
    for (final c in list.take(n)) {
      keys.add(c.recordKey);
    }
  }
  return keys;
}

/// R10: derives the draft from a PER-PERIOD band map. For every
/// operator-configured period (iterating the resolved [defs], never a
/// hardcoded daypart list) it keeps that period's strongest N candidate
/// shifts by CPLH, where N comes from THAT period's own band tier in
/// [bandByPeriod]. Periods absent from the map (defensive) fall back to
/// [fallbackBand]. Candidate periods absent from the configured defs are
/// still ranked under their own id so nothing is silently dropped, again
/// using [fallbackBand]. Returns ONLY the chosen recordKeys; the caller
/// assigns these to the draft set. Same record-key Set shape as
/// [deriveBandSelection]. No persistence, no second pooling formula, no
/// write-path contact: each period's keep count is exactly the existing
/// per-tier N applied to that period's own shifts.
Set<String> derivePerPeriodBandSelection(
  List<BaselineCandidateShift> candidates,
  List<ServicePeriodDefinition> defs,
  Map<String, StarBand> bandByPeriod, {
  StarBand fallbackBand = StarBand.balanced,
}) {
  final byPeriod = <String, List<BaselineCandidateShift>>{};
  for (final c in candidates) {
    byPeriod.putIfAbsent(c.daypart, () => []).add(c);
  }

  final orderedIds =
      ServicePeriodDefinitionResolver.ordered(defs).map((d) => d.id).toList();
  final periodIds = <String>[
    ...orderedIds.where(byPeriod.containsKey),
    ...byPeriod.keys.where((k) => !orderedIds.contains(k)),
  ];

  final keys = <String>{};
  for (final periodId in periodIds) {
    final band = bandByPeriod[periodId] ?? fallbackBand;
    final list = [...byPeriod[periodId]!];
    // Strongest first: highest CPLH wins; stable tie-break on recordKey.
    list.sort((a, b) {
      final cmp = b.cplh.compareTo(a.cplh);
      return cmp != 0 ? cmp : a.recordKey.compareTo(b.recordKey);
    });
    for (final c in list.take(band.nPerPeriod)) {
      keys.add(c.recordKey);
    }
  }
  return keys;
}

/// Three-option band selector. Selecting a band asks the screen to
/// replace its draft set with [deriveBandSelection]'s output. No band is
/// pre-selected: the band is an optional starting point, not state the
/// screen has to track or persist.
class BaselineManagerBandSelector extends StatelessWidget {
  /// The currently highlighted band, or null when the operator has not
  /// applied one (or has since hand-tweaked the selection).
  final StarBand? selectedBand;

  /// Called with the chosen band. The screen derives the selection.
  final ValueChanged<StarBand> onBandSelected;

  const BaselineManagerBandSelector({
    super.key,
    required this.selectedBand,
    required this.onBandSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'STAR SHIFT SELECTION',
            style: AppTextStyles.mono7(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              for (final band in StarBand.values) ...[
                Expanded(
                  child: _BandChip(
                    key: ValueKey<String>('band_${band.name}'),
                    label: band.label,
                    selected: selectedBand == band,
                    onTap: () => onBandSelected(band),
                  ),
                ),
                if (band != StarBand.values.last)
                  const SizedBox(width: AppSpacing.sm),
              ],
            ],
          ),
          if (selectedBand != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              selectedBand!.helperText,
              style: AppTextStyles.mono7(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _BandChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BandChip({
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
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.18)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppColors.sunset : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: AppRadius.smallR,
        ),
        alignment: Alignment.center,
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
