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
import 'vendor_relativity_label.dart';

class WageSourceToggle extends StatelessWidget {
  const WageSourceToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.bundle,
    this.vendorApplicabilityBound = false,
    this.vendorApplicabilityLoading = false,
    this.vendorApplicabilityError,
    this.applicableWageVendorSlugs = const <String>[],
  });

  final WageSource value;
  final ValueChanged<WageSource> onChanged;
  final VendorConnectionsBundle? bundle;
  final bool vendorApplicabilityBound;
  final bool vendorApplicabilityLoading;
  final String? vendorApplicabilityError;
  final List<String> applicableWageVendorSlugs;

  @override
  Widget build(BuildContext context) {
    final vendorSelectable =
        !vendorApplicabilityBound || applicableWageVendorSlugs.isNotEmpty;
    return _DataAccuracyCard(
      cardKey: const Key('data_accuracy_wage_source_card'),
      icon: Icons.payments_outlined,
      title: 'How labor dollars are calculated',
      headerExplainer:
          'Labor dollars on your dashboard are calculated one of two ways. '
          'Either Forge & Flow reads them straight from your scheduling '
          'system, or it multiplies the wage rates you set in Settings by '
          'the hours your staff actually worked. Pick the path that '
          'matches the system you trust today — you can switch back '
          'any time without losing past numbers.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RadioRow(
            rowKey: const Key('wage_source_radio_vendor'),
            selected: value == WageSource.vendor,
            enabled: vendorSelectable,
            label:
                'Use labor vendor\'s reported wages and dollars when available',
            body: _vendorCopy(vendorSelectable),
            onTap: () => onChanged(WageSource.vendor),
          ),
          const SizedBox(height: 10),
          _RadioRow(
            rowKey: const Key('wage_source_radio_manual_mix'),
            selected: value == WageSource.manualMix,
            label:
                'Use my manual wage mix from Settings (the same rates the wage generator uses)',
            body:
                'Always use the wage editor mix you set up in Forge & Flow. '
                'Forge & Flow multiplies your role-by-role rates by actual '
                'hours, ignoring whatever the scheduling system reports. '
                'Pick this if your scheduling system\'s rates are out of date '
                'or if you have not yet built confidence in them.',
            onTap: () => onChanged(WageSource.manualMix),
          ),
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
    if (vendorApplicabilityBound && !vendorSelectable) {
      return 'No current wage vendor is enabled for this location yet. Use the manual mix until F&F enables one.';
    }
    final suffix = vendorApplicabilityBound
        ? ' Current wage vendors: ${_slugList(applicableWageVendorSlugs)}.'
        : '';
    return 'Read labor dollars from your scheduling system when it reports them. '
        'Forge & Flow falls back to target wage x hours when the system does not '
        'expose dollars (we will tell you when that happens on the dashboard).'
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
    required this.icon,
    required this.title,
    required this.headerExplainer,
    required this.child,
  });

  final Key cardKey;
  final IconData icon;
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
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.sunsetDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
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
            headerExplainer,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
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
                  Text(
                    label,
                    style: AppTextStyles.body14(
                      color: enabled
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: AppTextStyles.body13(
                      color: enabled
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
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
