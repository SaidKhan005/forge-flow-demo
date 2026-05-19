// Phase 8 spine-bridge Lane .B — Walk-in handling card.
//
// Renders only when the parent decides it is needed (POS does NOT
// expose covers AND a reservation system is connected). The card
// itself does not gate; the parent decides whether to instantiate it.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Walk-in handling card" section.
//
// Three modes:
//   * Reservations only            — every guest counted as a reservation.
//   * Walk-ins added to reservations — operator types a daily walk-in
//                                      count; total = reservations + walk-ins.
//   * Walk-ins tracked separately  — F&F charts the two streams apart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../theme/app_theme.dart';

enum WalkInHandlingMode {
  reservationsOnly,
  walkInsAddedToReservations,
  walkInsTrackedSeparately,
}

class WalkInHandlingCard extends StatefulWidget {
  const WalkInHandlingCard({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.businessDateIso,
    required this.dailyWalkInCount,
    required this.onDailyWalkInCountChanged,
    this.source,
  });

  final WalkInHandlingMode mode;
  final ValueChanged<WalkInHandlingMode> onModeChanged;

  /// ISO `YYYY-MM-DD` business date the walk-in count applies to.
  final String businessDateIso;

  /// Current walk-in count for [businessDateIso]. `null` when unset.
  final int? dailyWalkInCount;

  /// Called on submit. `null` when the operator clears the field.
  final void Function(int?) onDailyWalkInCountChanged;

  final DataAccuracySettingSource? source;

  @override
  State<WalkInHandlingCard> createState() => _WalkInHandlingCardState();
}

class _WalkInHandlingCardState extends State<WalkInHandlingCard> {
  late final TextEditingController _walkInController;

  @override
  void initState() {
    super.initState();
    _walkInController = TextEditingController(
      text: widget.dailyWalkInCount?.toString() ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant WalkInHandlingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.dailyWalkInCount?.toString() ?? '';
    if (_walkInController.text != next) {
      _walkInController.text = next;
      _walkInController.selection = TextSelection.fromPosition(
        TextPosition(offset: _walkInController.text.length),
      );
    }
  }

  @override
  void dispose() {
    _walkInController.dispose();
    super.dispose();
  }

  void _commitWalkIn(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      widget.onDailyWalkInCountChanged(null);
      return;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 0) return;
    widget.onDailyWalkInCountChanged(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final sourceLabel = widget.source?.operatorFacingLabel;
    return Container(
      key: const Key('data_accuracy_walk_in_handling_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.groups_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Walk-ins handling',
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
            "Your reservation system tracks reservations, but your POS "
            "doesn't track covers. Tell F&F how to handle walk-in guests "
            'so per-cover metrics stay honest.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          _RadioRow(
            rowKey: const Key('walk_in_handling_radio_reservations_only'),
            selected: widget.mode == WalkInHandlingMode.reservationsOnly,
            label: 'Use reservations only',
            body:
                'F&F treats every guest as a reservation. Use this if '
                "walk-ins are rare or you don't track them separately.",
            onTap: () =>
                widget.onModeChanged(WalkInHandlingMode.reservationsOnly),
          ),
          const SizedBox(height: 10),
          _RadioRow(
            rowKey: const Key('walk_in_handling_radio_added'),
            selected:
                widget.mode == WalkInHandlingMode.walkInsAddedToReservations,
            label: 'Add walk-ins to reservations',
            body:
                'F&F asks you to type a daily walk-in count. Total covers '
                '= reservations + walk-ins for that day. Best when '
                'walk-in volume varies day to day.',
            onTap: () => widget.onModeChanged(
              WalkInHandlingMode.walkInsAddedToReservations,
            ),
          ),
          const SizedBox(height: 10),
          _RadioRow(
            rowKey: const Key('walk_in_handling_radio_separate'),
            selected:
                widget.mode == WalkInHandlingMode.walkInsTrackedSeparately,
            label: 'Track walk-ins separately',
            body:
                'F&F charts reservations and walk-ins on different lines '
                'so you can see the mix. Best when walk-in business is a '
                'distinct segment of your operation.',
            onTap: () => widget.onModeChanged(
              WalkInHandlingMode.walkInsTrackedSeparately,
            ),
          ),
          if (sourceLabel != null) ...[
            const SizedBox(height: 10),
            Text(
              'Source: $sourceLabel',
              key: const Key('walk_in_handling_source_label'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
          if (widget.mode == WalkInHandlingMode.walkInsAddedToReservations) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: AppColors.cardGlow,
                border: Border.all(color: AppColors.borderSubtle, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      'Walk-ins on ${widget.businessDateIso}',
                      style: AppTextStyles.body14(color: AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 140,
                    child: TextField(
                      key: const Key('walk_in_handling_daily_count_field'),
                      controller: _walkInController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: false,
                        signed: false,
                      ),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onSubmitted: _commitWalkIn,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'e.g. 12',
                        border: OutlineInputBorder(),
                      ),
                      style: AppTextStyles.body14(color: AppColors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.rowKey,
    required this.selected,
    required this.label,
    required this.body,
    required this.onTap,
  });

  final Key rowKey;
  final bool selected;
  final String label;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: rowKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.10)
              : AppColors.backgroundSurface,
          border: Border.all(
            color: selected
                ? AppColors.sunset.withValues(alpha: 0.55)
                : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? AppColors.sunsetDark : AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.body14(color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: AppTextStyles.body13(color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
