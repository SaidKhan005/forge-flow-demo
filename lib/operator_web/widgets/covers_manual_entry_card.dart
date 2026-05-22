// Phase 8 spine-bridge Lane .B — Covers manual entry sub-card.
//
// Surfaces beneath the covers source picker when ANY service period is
// set to `manual`. The operator types today's covers per manual period
// and can copy yesterday's value with one tap.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Covers source card" + manual entry handling sections.
//
// Per-Daypart V1 Slice R5 (Gap 27/36): the hardcoded 3-daypart
// `Daypart.values` iteration is replaced by the operator-configured
// service periods (resolver-ordered by the screen). An operator with
// any number of periods gets one manual-entry row per period set to
// manual.
//
// When no periods are set to manual the card still renders (so its
// presence is testable) but shows a muted hint pointing the operator
// back at the covers picker above.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/service_period_definition.dart';
import '../../theme/app_theme.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';

class CoversManualEntryCard extends StatefulWidget {
  const CoversManualEntryCard({
    super.key,
    required this.businessDateIso,
    required this.yesterdayBusinessDateIso,
    required this.settings,
    required this.servicePeriods,
    required this.onEnterCovers,
    required this.onCopyYesterday,
  });

  /// ISO `YYYY-MM-DD` business date the operator is entering for
  /// (today, restaurant-local).
  final String businessDateIso;

  /// ISO `YYYY-MM-DD` of the prior business date — drives the
  /// "Copy yesterday's value" shortcut.
  final String yesterdayBusinessDateIso;

  /// Current settings row. Used to determine which periods are manual
  /// and to read prefilled values from `coversManualEntries`.
  final DataAccuracySettings settings;

  /// Operator-configured service periods, resolver-ordered by the
  /// screen. Only the periods whose covers source is `manual` render a
  /// manual-entry row; never a hardcoded daypart list.
  final List<ServicePeriodDefinition> servicePeriods;

  /// Called when the operator commits a value. `null` means clear.
  final void Function(String servicePeriodId, int? covers) onEnterCovers;

  /// Called when the operator taps "Copy yesterday's value" for a
  /// period. The parent is responsible for reading yesterday's value
  /// off `settings.manualCoversFor(...)` and writing it to today.
  final void Function(String servicePeriodId) onCopyYesterday;

  @override
  State<CoversManualEntryCard> createState() => _CoversManualEntryCardState();
}

class _CoversManualEntryCardState extends State<CoversManualEntryCard> {
  late Map<String, TextEditingController> _controllers;
  final Map<String, String?> _errors = {};

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final p in widget.servicePeriods)
        p.id: TextEditingController(text: _initialText(p.id)),
    };
  }

  @override
  void didUpdateWidget(covariant CoversManualEntryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reconcile controllers when the operator's configured period set
    // changes (e.g. they add a new period under Business timing) or
    // the parent pushes new settings (e.g. after a copy-yesterday tap).
    final nextIds = widget.servicePeriods.map((p) => p.id).toSet();
    for (final removed
        in _controllers.keys.where((k) => !nextIds.contains(k)).toList()) {
      _controllers.remove(removed)?.dispose();
    }
    for (final p in widget.servicePeriods) {
      final controller = _controllers.putIfAbsent(
        p.id,
        () => TextEditingController(text: _initialText(p.id)),
      );
      final next = _initialText(p.id);
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

  String _initialText(String servicePeriodId) {
    final v = widget.settings.manualCoversFor(
      widget.businessDateIso,
      servicePeriodId,
    );
    return v?.toString() ?? '';
  }

  void _commit(String servicePeriodId, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() => _errors[servicePeriodId] = null);
      widget.onEnterCovers(servicePeriodId, null);
      return;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 0) {
      setState(() {
        _errors[servicePeriodId] = 'Type a whole number, 0 or greater.';
      });
      return;
    }
    setState(() => _errors[servicePeriodId] = null);
    widget.onEnterCovers(servicePeriodId, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final manualPeriods = widget.servicePeriods
        .where(
          (p) => widget.settings.coversSourceFor(p.id) == CoversSource.manual,
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
          OperatorWebSectionHeading(
            title: "Type today's covers",
            trailing: OperatorWebInfoButton(
              title: "Type today's covers",
              tooltip: "Type today's covers",
              body: Text(
                'You set this service period to manual. Type how many guests '
                "you served. Leave blank if you don't have the count yet. The "
                'app dashboard will show "not yet available" rather than make '
                'up a number.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (manualPeriods.isEmpty)
            Text(
              "Switch a service period to 'Manual' above to type today's "
              'covers here.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else
            for (final p in manualPeriods) ...[
              _ManualRow(
                servicePeriodId: p.id,
                label: p.label,
                controller: _controllers[p.id]!,
                error: _errors[p.id],
                yesterdayValue: widget.settings.manualCoversFor(
                  widget.yesterdayBusinessDateIso,
                  p.id,
                ),
                onCommit: (raw) => _commit(p.id, raw),
                onCopyYesterday: () => widget.onCopyYesterday(p.id),
              ),
              if (p != manualPeriods.last) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _ManualRow extends StatelessWidget {
  const _ManualRow({
    required this.servicePeriodId,
    required this.label,
    required this.controller,
    required this.error,
    required this.yesterdayValue,
    required this.onCommit,
    required this.onCopyYesterday,
  });

  final String servicePeriodId;
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
                  key: Key('covers_manual_entry_field_$servicePeriodId'),
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
                    'covers_manual_entry_copy_yesterday_$servicePeriodId',
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
