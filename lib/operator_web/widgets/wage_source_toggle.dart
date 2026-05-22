// Phase 8 spine-bridge Lane .B — Wage source toggle card.
//
// Surfaces the existing wage adjuster (currently in mobile Settings)
// on web. Operator picks between:
//
//   * "Use vendor"        — labor vendor's reported wages and dollars
//                           when available. Default.
//   * "Use my manual mix" — operator's manual wage mix from the wage
//                           editor (the same rates the wage generator
//                           uses).
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Wage source card" + "Wage source resolution" sections.
//
// The card surfaces the active vendor wage class via the vendor
// relativity label so the operator understands what changes when
// they flip the toggle. The label reads off the connected labor
// vendor; if no labor vendor is connected, a generic explainer
// renders.

import 'package:flutter/material.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../theme/app_theme.dart';
import 'data_accuracy_applicability.dart';
import 'operator_web_info_button.dart';
import 'operator_web_section_heading.dart';
import 'vendor_relativity_label.dart';

class WageSourceToggle extends StatelessWidget {
  const WageSourceToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.bundle,
    this.source,
    this.vendorApplicabilityBound = false,
    this.vendorApplicabilityLoading = false,
    this.vendorApplicabilityError,
    this.applicableWageVendorSlugs = const <String>[],
  });

  final WageSource value;
  final ValueChanged<WageSource> onChanged;
  final VendorConnectionsBundle? bundle;
  final DataAccuracySettingSource? source;
  final bool vendorApplicabilityBound;
  final bool vendorApplicabilityLoading;
  final String? vendorApplicabilityError;
  final List<String> applicableWageVendorSlugs;

  @override
  Widget build(BuildContext context) {
    final sourceLabel = source?.operatorFacingLabel;
    final vendorSelectable = wageVendorOptionSelectable(
      bundle: bundle,
      vendorApplicabilityBound: vendorApplicabilityBound,
      applicableWageVendorSlugs: applicableWageVendorSlugs,
    );
    final effectiveValue = effectiveWageSource(
      configured: value,
      bundle: bundle,
      vendorApplicabilityBound: vendorApplicabilityBound,
      applicableWageVendorSlugs: applicableWageVendorSlugs,
    );
    return _DataAccuracyCard(
      cardKey: const Key('data_accuracy_wage_source_card'),
      title: 'How labor dollars are calculated',
      headerExplainer:
          'Labor dollars come from either the labor integration or the '
          'manual wage mix. If a vendor sends dollars, Forge & Flow uses '
          'them. If it sends rates, Forge & Flow calculates dollars from '
          'rates and time. Manual mix uses the wage-role rows you maintain '
          'in Settings.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RadioRow(
            rowKey: const Key('wage_source_radio_vendor'),
            selected: effectiveValue == WageSource.vendor,
            enabled: vendorSelectable,
            label:
                'Use labor vendor\'s reported wages and dollars when available',
            body: _vendorCopy(vendorSelectable),
            onTap: () => onChanged(WageSource.vendor),
          ),
          const SizedBox(height: 10),
          _RadioRow(
            rowKey: const Key('wage_source_radio_manual_mix'),
            selected: effectiveValue == WageSource.manualMix,
            label:
                'Use my manual wage mix from Settings (the same rates the wage generator uses)',
            body:
                'Use the wage-role rows you maintain in Forge & Flow. This '
                'is the manual fallback when the vendor does not provide '
                'usable labor dollars, or when you want one operator-owned '
                'wage model across the location.',
            onTap: () => onChanged(WageSource.manualMix),
          ),
          if (sourceLabel != null) ...[
            const SizedBox(height: 10),
            Text(
              'Source: $sourceLabel',
              key: const Key('wage_source_source_label'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 14),
          if (vendorApplicabilityBound) ...[
            _VendorApplicabilityStatus(
              loading: vendorApplicabilityLoading,
              error: vendorApplicabilityError,
              slugs: applicableWageVendorSlugs,
            ),
            const SizedBox(height: 14),
          ],
          VendorRelativityLabel(
            setting: VendorRelativitySetting.wage,
            bundle: bundle,
          ),
        ],
      ),
    );
  }

  String _vendorCopy(bool vendorSelectable) {
    if (!wageVendorOptionApplies(bundle)) {
      return 'Connect a labor vendor before using vendor-reported wages. Manual mix stays available.';
    }
    if (vendorApplicabilityBound && !vendorSelectable) {
      return 'No current wage vendor is enabled for this location yet. Use manual mix until this vendor is ready.';
    }
    final suffix = vendorApplicabilityBound
        ? ' Current wage vendors: ${_slugList(applicableWageVendorSlugs)}.'
        : '';
    return 'Use the labor integration when it can supply the wage path. '
        'Forge & Flow uses vendor dollars directly, calculates from vendor '
        'rates when needed, or uses target wage x hours for hours-only vendors.'
        '$suffix';
  }
}

// ─── Shared chrome ──────────────────────────────────────────────────
//
// _DataAccuracyCard / _RadioRow / _DataAccuracyChoiceChip are shared
// across the Lane .B widget set. Defining them once per file keeps
// each widget file self-contained (no cross-imports between sibling
// widget files) and lets the bundle ship cleanly even if a future
// slice retires one card without touching the others.

class _DataAccuracyCard extends StatelessWidget {
  const _DataAccuracyCard({
    required this.cardKey,
    required this.title,
    required this.headerExplainer,
    required this.child,
  });

  final Key cardKey;
  final String title;
  final String headerExplainer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: cardKey,
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
            title: title,
            trailing: OperatorWebInfoButton(
              title: title,
              tooltip: title,
              body: Text(
                headerExplainer,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.rowKey,
    required this.selected,
    this.enabled = true,
    required this.label,
    required this.body,
    required this.onTap,
  });

  final Key rowKey;
  final bool selected;
  final bool enabled;
  final String label;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: rowKey,
      onTap: enabled ? onTap : null,
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
              color: !enabled
                  ? AppColors.textMuted.withValues(alpha: 0.55)
                  : selected
                  ? AppColors.sunsetDark
                  : AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: AppTextStyles.body14(
                            color: enabled
                                ? AppColors.textPrimary
                                : AppColors.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OperatorWebInfoButton(
                        title: label,
                        tooltip: label,
                        body: Text(
                          body,
                          style: AppTextStyles.body13(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
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

class _VendorApplicabilityStatus extends StatelessWidget {
  const _VendorApplicabilityStatus({
    required this.loading,
    required this.error,
    required this.slugs,
  });

  final bool loading;
  final String? error;
  final List<String> slugs;

  @override
  Widget build(BuildContext context) {
    final isError = error != null;
    final message = loading
        ? 'Checking wage vendor options...'
        : isError
        ? error!
        : slugs.isEmpty
        ? 'No enabled wage vendor is current. Manual mix stays available.'
        : 'Enabled wage vendors: ${_slugList(slugs)}';
    return Container(
      key: const Key('wage_source_vendor_applicability_status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isError ? AppColors.warningBadgeBg : AppColors.cardGlow,
        border: Border.all(
          color: isError ? AppColors.warning : AppColors.borderSubtle,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.sunsetDark,
              ),
            )
          else
            Icon(
              isError ? Icons.warning_amber_rounded : Icons.fact_check_outlined,
              size: 16,
              color: isError ? AppColors.warning : AppColors.textSecondary,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(
                color: isError ? AppColors.warning : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _slugList(List<String> slugs) {
  final unique = slugs.toSet().toList()..sort();
  if (unique.isEmpty) return 'none';
  return unique.join(', ');
}
