import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_action_controls.dart';
import 'per_vendor_cadence_editor.dart';

class TierDefinitionEditResult {
  const TierDefinitionEditResult({
    required this.descriptionMd,
    required this.pollingCadencePerVendorSeconds,
    required this.defaultMonthlyPriceCents,
    required this.vendorApiCostEstimateCentsMonthly,
    required this.reasonNote,
  });

  final String descriptionMd;
  final Map<String, int> pollingCadencePerVendorSeconds;
  final int defaultMonthlyPriceCents;
  final int vendorApiCostEstimateCentsMonthly;
  final String reasonNote;
}

class TierDefinitionEditDialog extends StatefulWidget {
  const TierDefinitionEditDialog({super.key, required this.initial});

  final TierDefinition initial;

  static Future<TierDefinitionEditResult?> show(
    BuildContext context,
    TierDefinition initial,
  ) => showDialog<TierDefinitionEditResult>(
    context: context,
    builder: (_) => TierDefinitionEditDialog(initial: initial),
  );

  @override
  State<TierDefinitionEditDialog> createState() =>
      _TierDefinitionEditDialogState();
}

class _TierDefinitionEditDialogState extends State<TierDefinitionEditDialog> {
  late final TextEditingController _description;
  late final TextEditingController _priceDollars;
  late final TextEditingController _costDollars;
  late final TextEditingController _reason;
  late Map<String, int> _cadence;

  String? _priceError;
  String? _costError;
  String? _reasonError;
  String? _cadenceError;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.initial.descriptionMd);
    _priceDollars = TextEditingController(
      text: (widget.initial.defaultMonthlyPriceCents / 100).toStringAsFixed(2),
    );
    _costDollars = TextEditingController(
      text: (widget.initial.vendorApiCostEstimateCentsMonthly / 100)
          .toStringAsFixed(2),
    );
    _reason = TextEditingController();
    _cadence = Map<String, int>.from(
      widget.initial.pollingCadencePerVendorSeconds,
    );
  }

  @override
  void dispose() {
    _description.dispose();
    _priceDollars.dispose();
    _costDollars.dispose();
    _reason.dispose();
    super.dispose();
  }

  int? _parseDollarsToCents(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final dollars = double.tryParse(trimmed);
    if (dollars == null || dollars < 0) return null;
    return (dollars * 100).round();
  }

  void _onSubmit() {
    final priceCents = _parseDollarsToCents(_priceDollars.text);
    final costCents = _parseDollarsToCents(_costDollars.text);
    final reason = _reason.text.trim();
    // Contract: standard / premium tiers ship with cadence presets
    // baked in code. Letting an admin save those tiers with an empty
    // cadence map would silently turn off polling for every operator
    // assigned to that tier. Custom is allowed empty (admin sets per
    // assignment).
    final cadenceEmptyForBakedTier =
        widget.initial.tierKey != PollingTierKey.custom && _cadence.isEmpty;

    setState(() {
      _priceError = priceCents == null ? 'Enter a price in dollars' : null;
      _costError = costCents == null ? 'Enter a cost in dollars' : null;
      _reasonError = reason.isEmpty ? 'Reason is required' : null;
      _cadenceError = cadenceEmptyForBakedTier
          ? 'Regular / premium tiers require at least one vendor cadence.'
          : null;
    });

    if (priceCents == null ||
        costCents == null ||
        reason.isEmpty ||
        cadenceEmptyForBakedTier) {
      return;
    }

    Navigator.of(context).pop(
      TierDefinitionEditResult(
        descriptionMd: _description.text,
        pollingCadencePerVendorSeconds: _cadence,
        defaultMonthlyPriceCents: priceCents,
        vendorApiCostEstimateCentsMonthly: costCents,
        reasonNote: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_tier_definition_dialog'),
      title: 'Edit ${_tierLabel(widget.initial.tierKey)} tier',
      icon: Icons.tune_outlined,
      maxWidth: 640,
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_tier_definition_dialog_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_tier_definition_dialog_submit'),
          label: 'Save changes',
          onPressed: _onSubmit,
          role: AdminActionRole.primary,
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Description',
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const Key('admin_tier_definition_dialog_description'),
              controller: _description,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Default tier price (USD/month/location)',
                        style: AppTextStyles.uiLabel(
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        key: const Key('admin_tier_definition_dialog_price'),
                        controller: _priceDollars,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: InputDecoration(
                          prefixText: '\$ ',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          errorText: _priceError,
                        ),
                        style: AppTextStyles.mono14(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Vendor API cost basis (USD/month/location)',
                        style: AppTextStyles.uiLabel(
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        key: const Key('admin_tier_definition_dialog_cost'),
                        controller: _costDollars,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: InputDecoration(
                          prefixText: '\$ ',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          errorText: _costError,
                        ),
                        style: AppTextStyles.mono14(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            PerVendorCadenceEditor(
              initialCadence: _cadence,
              onChanged: (next) => setState(() {
                _cadence = next;
                if (_cadenceError != null) _cadenceError = null;
              }),
            ),
            if (_cadenceError != null) ...[
              const SizedBox(height: 6),
              Text(
                _cadenceError!,
                style: AppTextStyles.body12(color: AppColors.negative),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Reason note (audit log)',
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const Key('admin_tier_definition_dialog_reason'),
              controller: _reason,
              maxLines: 2,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _reasonError,
                hintText: 'Why this change?',
              ),
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

String _tierLabel(PollingTierKey tier) {
  switch (tier) {
    case PollingTierKey.standard:
      return 'Regular';
    case PollingTierKey.premium:
      return 'Premium';
    case PollingTierKey.custom:
      return 'Custom';
  }
}
