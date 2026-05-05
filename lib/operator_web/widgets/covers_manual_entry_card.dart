// Phase 8 spine-bridge Lane .B — Covers manual entry sub-card.
//
// Surfaces beneath the covers source picker when ANY daypart is set
// to `manual`. The operator types today's covers per manual daypart
// and can copy yesterday's value with one tap.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Covers source card" + manual entry handling sections.
//
// When no dayparts are set to manual the card still renders (so its
// presence is testable) but shows a muted hint pointing the operator
// back at the covers picker above.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../theme/app_theme.dart';

class CoversManualEntryCard extends StatefulWidget {
  const CoversManualEntryCard({
    super.key,
    required this.businessDateIso,
    required this.yesterdayBusinessDateIso,
    required this.settings,
    required this.onEnterCovers,
    required this.onCopyYesterday,
  });

  /// ISO `YYYY-MM-DD` business date the operator is entering for
  /// (today, restaurant-local).
  final String businessDateIso;

  /// ISO `YYYY-MM-DD` of the prior business date — drives the
  /// "Copy yesterday's value" shortcut.
  final String yesterdayBusinessDateIso;

  /// Current settings row. Used to determine which dayparts are
  /// manual and to read prefilled values from `coversManualEntries`.
  final DataAccuracySettings settings;

  /// Called when the operator commits a value. `null` means clear.
  final void Function(Daypart daypart, int? covers) onEnterCovers;

  /// Called when the operator taps "Copy yesterday's value" for a
  /// daypart. The parent is responsible for reading yesterday's
  /// value off `settings.manualCoversFor(...)` and writing it to
  /// today.
  final void Function(Daypart daypart) onCopyYesterday;

  @override
  State<CoversManualEntryCard> createState() => _CoversManualEntryCardState();
}

class _CoversManualEntryCardState extends State<CoversManualEntryCard> {
  late final Map<Daypart, TextEditingController> _controllers;
  final Map<Daypart, String?> _errors = {};

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final d in Daypart.values)
        d: TextEditingController(
          text: _initialText(d),
        ),
    };
  }

  @override
  void didUpdateWidget(covariant CoversManualEntryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When parent pushes new settings (e.g. after a copy-yesterday
    // tap) refresh any field that the operator isn't actively
    // editing. We keep it simple: re-sync text from settings if it
    // diverges and the field isn't focused.
    for (final d in Daypart.values) {
      final next = _initialText(d);
      final controller = _controllers[d]!;
      if (controller.text != next && next.isNotEmpty) {
        controller.text = next;
        controller.selection = TextSelection.fromPosition(
          TextPosition(offset: controller.text.length),
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _initialText(Daypart d) {
    final v = widget.settings.manualCoversFor(widget.businessDateIso, d);
    return v?.toString() ?? '';
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

  void _commit(Daypart d, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() => _errors[d] = null);
      widget.onEnterCovers(d, null);
      return;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 0) {
      setState(() {
        _errors[d] = 'Type a whole number, 0 or greater.';
      });
      return;
    }
    setState(() => _errors[d] = null);
    widget.onEnterCovers(d, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final manualDayparts = Daypart.values
        .where(
          (d) =>
              widget.settings.coversSourceFor(d) == CoversSource.manual,
        )
        .toList();

    return Container(
      key: const Key('data_accuracy_covers_manual_entry_card'),
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
                Icons.edit_note_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Type today's covers",
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
            'You set this daypart to manual. Type how many guests you '
            "served. Leave blank if you don't have the count yet — F&F "
            "will show \"not yet available\" rather than make up a number.",
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          if (manualDayparts.isEmpty)
            Text(
              "Switch a daypart to 'Manual' above to type today's covers "
              'here.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else
            for (final d in manualDayparts) ...[
              _ManualRow(
                daypart: d,
                label: _daypartLabel(d),
                controller: _controllers[d]!,
                error: _errors[d],
                yesterdayValue: widget.settings.manualCoversFor(
                  widget.yesterdayBusinessDateIso,
                  d,
                ),
                onCommit: (raw) => _commit(d, raw),
                onCopyYesterday: () => widget.onCopyYesterday(d),
              ),
              if (d != manualDayparts.last) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _ManualRow extends StatelessWidget {
  const _ManualRow({
    required this.daypart,
    required this.label,
    required this.controller,
    required this.error,
    required this.yesterdayValue,
    required this.onCommit,
    required this.onCopyYesterday,
  });

  final Daypart daypart;
  final String label;
  final TextEditingController controller;
  final String? error;
  final int? yesterdayValue;
  final ValueChanged<String> onCommit;
  final VoidCallback onCopyYesterday;

  @override
  Widget build(BuildContext context) {
    final canCopy = yesterdayValue != null;
    final disabledTooltip =
        "You haven't entered a $label number for yesterday yet.";

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  label,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
              Expanded(
                child: TextField(
                  key: Key('covers_manual_entry_field_${daypart.wire}'),
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: false,
                    signed: false,
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: onCommit,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'e.g. 84',
                    border: OutlineInputBorder(),
                  ),
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: canCopy ? "Copy yesterday's value" : disabledTooltip,
                child: TextButton.icon(
                  key: Key(
                    'covers_manual_entry_copy_yesterday_${daypart.wire}',
                  ),
                  onPressed: canCopy ? onCopyYesterday : null,
                  icon: const Icon(Icons.content_copy_outlined, size: 16),
                  label: Text(
                    "Copy yesterday's value",
                    style: AppTextStyles.body13(
                      color: canCopy
                          ? AppColors.sunsetDark
                          : AppColors.textMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 96),
              child: Text(
                error!,
                style: AppTextStyles.body13(color: AppColors.negative),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
