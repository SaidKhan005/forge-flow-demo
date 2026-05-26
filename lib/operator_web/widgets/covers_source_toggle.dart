// Phase 8 spine-bridge Lane .B — Covers source per-service-period
// toggle.
//
// Three states per service period:
//
//   * vendor   — read covers from POS (default).
//   * forecast — substitute the F&F-computed forecast covers value.
//   * manual   — operator types the number per business date.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Covers source card" + "Covers source resolution" sections.
//
// Per-Daypart V1 Slice R5 (Gap 27/36): the hardcoded 3-daypart
// `Daypart.values` iteration is replaced by the operator-configured
// service periods (resolver-ordered via
// `ServicePeriodDefinitionResolver.ordered`). An operator with any
// number of periods (e.g. breakfast/lunch/dinner/late_night) gets one
// row per period.
//
// When the operator picks `manual` for a period, the parent screen is
// responsible for rendering the manual-entry sub-card; this widget
// only owns the per-period 3-way picker plus the dynamic vendor
// relativity label.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/service_period_definition.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../theme/app_theme.dart';
import 'data_accuracy_applicability.dart';
import 'data_accuracy_explainer_card.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';
import 'vendor_relativity_label.dart';

class CoversSourceToggle extends StatelessWidget {
  const CoversSourceToggle({
    super.key,
    required this.settings,
    required this.servicePeriods,
    required this.onChanged,
    required this.bundle,
    this.applicableCoversVendorSlugs = const <String>[],
    this.vendorApplicabilityBound = false,
    this.businessDateIso,
    this.yesterdayBusinessDateIso,
    this.onEnterManualCovers,
    this.onCopyYesterday,
  });

  final DataAccuracySettings settings;

  /// Operator-configured service periods, resolver-ordered by the
  /// screen (`ServicePeriodDefinitionResolver.ordered`). One picker row
  /// renders per period; never a hardcoded daypart list.
  final List<ServicePeriodDefinition> servicePeriods;

  final void Function(String servicePeriodId, CoversSource source) onChanged;
  final VendorConnectionsBundle? bundle;

  /// Admin allow-list of vendor slugs cleared for the `covers` setting
  /// kind (enabled + current rows), read by the screen from
  /// `/v1/operator/vendor-applicability?setting_kind=covers`. Mirrors
  /// the wage card's `applicableWageVendorSlugs`. Empty when no
  /// applicability gateway is wired.
  final Iterable<String> applicableCoversVendorSlugs;

  /// Whether the admin allow-list is enforced (true only when the
  /// applicability gateway is wired). When false, the vendor-backed
  /// covers chips fall back to the capability check alone. Mirrors the
  /// wage card's `vendorApplicabilityBound`.
  final bool vendorApplicabilityBound;

  /// Today's business date (`YYYY-MM-DD`, restaurant-local) for the
  /// inline manual-entry rows. When null the inline manual entry is not
  /// rendered (the widget falls back to the picker-only layout for tests
  /// that do not exercise manual entry).
  final String? businessDateIso;

  /// Prior business date (`YYYY-MM-DD`), drives the inline "Copy
  /// yesterday" shortcut.
  final String? yesterdayBusinessDateIso;

  /// Called when the operator commits an inline manual covers value for
  /// a period. `null` means clear. Wired by the screen to the same
  /// manual-covers save/clear handler the standalone card used.
  final void Function(String servicePeriodId, int? covers)? onEnterManualCovers;

  /// Called when the operator taps the inline "Copy yesterday" shortcut.
  final void Function(String servicePeriodId)? onCopyYesterday;

  bool get _inlineManualEnabled =>
      businessDateIso != null && onEnterManualCovers != null;

  @override
  Widget build(BuildContext context) {
    // The inline manual-entry container carries the
    // `data_accuracy_covers_manual_entry_card` key (relocated from the
    // old separate "Type today's covers" card). It is attached to the
    // FIRST manual period only, so the screen tests' single-card
    // findsOneWidget / findsNothing expectations hold regardless of how
    // many periods are manual.
    String? firstManualPeriodId;
    if (_inlineManualEnabled) {
      for (final period in servicePeriods) {
        if (effectiveCoversSource(settings.coversSourceFor(period.id), bundle) ==
            CoversSource.manual) {
          firstManualPeriodId = period.id;
          break;
        }
      }
    }
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
          OperatorWebPlainSectionHeading(
            title: 'Where covers come from',
            trailing: OperatorWebInfoButton(
              title: 'Where covers come from',
              tooltip: 'Where covers come from',
              body: const DataAccuracyCoversModeInfo(),
            ),
          ),
          const SizedBox(height: 14),
          if (servicePeriods.isEmpty)
            Text(
              'No service periods are configured yet. Set up your service '
              'periods under Business timing and they will appear here.',
              key: const Key('covers_source_no_periods'),
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else
            for (final period in servicePeriods) ...[
              _PeriodRow(
                period: period,
                source: effectiveCoversSourceHonoringApplicability(
                  configured: settings.coversSourceFor(period.id),
                  bundle: bundle,
                  vendorApplicabilityBound: vendorApplicabilityBound,
                  applicableCoversVendorSlugs: applicableCoversVendorSlugs,
                ),
                sourceMetadata: settings.coversSourceSourceFor(period.id),
                bundle: bundle,
                applicableCoversVendorSlugs: applicableCoversVendorSlugs,
                vendorApplicabilityBound: vendorApplicabilityBound,
                onChanged: (source) => onChanged(period.id, source),
                // Inline manual entry, rendered directly under this
                // period's chip row when the period is manual.
                manualEntry: _inlineManualEnabled
                    ? _PeriodManualEntry(
                        manualCardKey: period.id == firstManualPeriodId
                            ? const Key('data_accuracy_covers_manual_entry_card')
                            : null,
                        todayValue: settings.manualCoversFor(
                          businessDateIso!,
                          period.id,
                        ),
                        yesterdayValue: yesterdayBusinessDateIso == null
                            ? null
                            : settings.manualCoversFor(
                                yesterdayBusinessDateIso!,
                                period.id,
                              ),
                        onCommit: (value) =>
                            onEnterManualCovers!(period.id, value),
                        onCopyYesterday: onCopyYesterday == null
                            ? null
                            : () => onCopyYesterday!(period.id),
                      )
                    : null,
              ),
              if (period != servicePeriods.last) const SizedBox(height: 10),
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

/// Inline manual-entry payload for a single period's row. Built by
/// [CoversSourceToggle] and rendered by [_PeriodRow] under the chip row
/// only when the period's effective source is manual.
class _PeriodManualEntry {
  const _PeriodManualEntry({
    required this.manualCardKey,
    required this.todayValue,
    required this.yesterdayValue,
    required this.onCommit,
    required this.onCopyYesterday,
  });

  /// Non-null only for the first manual period, so the relocated
  /// `data_accuracy_covers_manual_entry_card` key appears exactly once.
  final Key? manualCardKey;
  final int? todayValue;
  final int? yesterdayValue;
  final void Function(int? covers) onCommit;
  final VoidCallback? onCopyYesterday;
}

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({
    required this.period,
    required this.source,
    required this.sourceMetadata,
    required this.bundle,
    required this.applicableCoversVendorSlugs,
    required this.vendorApplicabilityBound,
    required this.onChanged,
    this.manualEntry,
  });

  final ServicePeriodDefinition period;
  final CoversSource source;
  final DataAccuracySettingSource? sourceMetadata;
  final VendorConnectionsBundle? bundle;
  final Iterable<String> applicableCoversVendorSlugs;
  final bool vendorApplicabilityBound;
  final ValueChanged<CoversSource> onChanged;

  /// Inline manual entry shown directly under this period's chip row
  /// when its effective source is manual. Null when manual entry is not
  /// wired (picker-only layout).
  final _PeriodManualEntry? manualEntry;

  @override
  Widget build(BuildContext context) {
    final sourceLabel = sourceMetadata?.operatorFacingLabel;
    return Container(
      key: Key('covers_source_daypart_${period.id}'),
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
                  period.label,
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
                          'covers_source_chip_${period.id}_${option.wire}',
                        ),
                        label: _sourceLabel(option),
                        selected: option == source,
                        enabled: coversSourceOptionSelectable(
                          source: option,
                          bundle: bundle,
                          vendorApplicabilityBound: vendorApplicabilityBound,
                          applicableCoversVendorSlugs:
                              applicableCoversVendorSlugs,
                        ),
                        disabledReason:
                            coversSourceDisabledReasonWithApplicability(
                              source: option,
                              bundle: bundle,
                              vendorApplicabilityBound:
                                  vendorApplicabilityBound,
                              applicableCoversVendorSlugs:
                                  applicableCoversVendorSlugs,
                            ),
                        onTap: () => onChanged(option),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (!coversSourceOptionSelectable(
            source: source,
            bundle: bundle,
            vendorApplicabilityBound: vendorApplicabilityBound,
            applicableCoversVendorSlugs: applicableCoversVendorSlugs,
          )) ...[
            const SizedBox(height: 6),
            Text(
              coversSourceDisabledReasonWithApplicability(
                    source: source,
                    bundle: bundle,
                    vendorApplicabilityBound: vendorApplicabilityBound,
                    applicableCoversVendorSlugs: applicableCoversVendorSlugs,
                  ) ??
                  'This source does not apply to the current integrations.',
              key: Key('covers_source_disabled_reason_${period.id}'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
          if (sourceLabel != null) ...[
            const SizedBox(height: 6),
            Text(
              'Source: $sourceLabel',
              key: Key('covers_source_source_${period.id}'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
          if (manualEntry != null && source == CoversSource.manual) ...[
            const SizedBox(height: 12),
            _InlineManualRow(
              servicePeriodId: period.id,
              cardKey: manualEntry!.manualCardKey,
              todayValue: manualEntry!.todayValue,
              yesterdayValue: manualEntry!.yesterdayValue,
              onCommit: manualEntry!.onCommit,
              onCopyYesterday: manualEntry!.onCopyYesterday,
            ),
          ],
        ],
      ),
    );
  }

  String _sourceLabel(CoversSource s) {
    switch (s) {
      case CoversSource.vendor:
        return 'Vendor';
      case CoversSource.forecast:
        return 'Forecast';
      case CoversSource.manual:
        return 'Manual';
      case CoversSource.reservationPlusWalkin:
        return 'Reservations + walk-ins';
    }
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.chipKey,
    required this.label,
    required this.selected,
    required this.enabled,
    this.disabledReason,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool selected;
  final bool enabled;
  final String? disabledReason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chip = InkWell(
      key: chipKey,
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(999),
      child: Opacity(
        opacity: enabled ? 1 : 0.58,
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
              color: !enabled
                  ? AppColors.textMuted
                  : selected
                  ? AppColors.sunsetDark
                  : AppColors.textSecondary,
              weight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
    if (enabled || disabledReason == null) return chip;
    return Tooltip(message: disabledReason!, child: chip);
  }
}

/// Inline manual-entry row rendered directly under a period's chip row
/// when that period is manual (matches the mockup's `.manualrow`). Owns
/// the `covers_manual_entry_field_<period>` text field key and the
/// `covers_manual_entry_copy_yesterday_<period>` copy-shortcut key, so
/// the screen + widget tests that drive manual covers through these keys
/// keep working with the value flowing to the same save/clear handler.
class _InlineManualRow extends StatefulWidget {
  const _InlineManualRow({
    required this.servicePeriodId,
    required this.cardKey,
    required this.todayValue,
    required this.yesterdayValue,
    required this.onCommit,
    required this.onCopyYesterday,
  });

  final String servicePeriodId;
  final Key? cardKey;
  final int? todayValue;
  final int? yesterdayValue;
  final void Function(int? covers) onCommit;
  final VoidCallback? onCopyYesterday;

  @override
  State<_InlineManualRow> createState() => _InlineManualRowState();
}

class _InlineManualRowState extends State<_InlineManualRow> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.todayValue?.toString() ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _InlineManualRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.todayValue?.toString() ?? '';
    if (_controller.text != next && next.isNotEmpty) {
      _controller.text = next;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() => _error = null);
      widget.onCommit(null);
      return;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 0) {
      setState(() => _error = 'Type a whole number, 0 or greater.');
      return;
    }
    setState(() => _error = null);
    widget.onCommit(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final canCopy = widget.yesterdayValue != null && widget.onCopyYesterday != null;
    return Container(
      key: widget.cardKey,
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
              const Icon(
                Icons.edit_outlined,
                size: 16,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Text(
                "Today's guest count",
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 110,
                child: TextField(
                  key: Key(
                    'covers_manual_entry_field_${widget.servicePeriodId}',
                  ),
                  controller: _controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: false,
                    signed: false,
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: _commit,
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
                message: canCopy
                    ? "Copy yesterday's value"
                    : "You haven't entered a number for yesterday yet.",
                child: TextButton.icon(
                  key: Key(
                    'covers_manual_entry_copy_yesterday_'
                    '${widget.servicePeriodId}',
                  ),
                  onPressed: canCopy ? widget.onCopyYesterday : null,
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
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ],
        ],
      ),
    );
  }
}
