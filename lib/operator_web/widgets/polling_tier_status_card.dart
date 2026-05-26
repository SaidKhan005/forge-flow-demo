// Phase 8 spine-bridge Lane .B — Polling tier status card.
//
// DISPLAY-ONLY. Renders the operator's currently-assigned polling
// tier name + tier price + a per-vendor cadence list (poll-only
// vendors only — webhook vendors absent). Operators DO NOT pick
// cadences here; the card surfaces a "Request tier change" button
// that opens a support-ticket flow (mock dialog when no real route
// is wired).
//
// Authority:
//   docs/contracts/data_accuracy_settings_contract.md
//   "Polling cadence — F&F-controlled tier model" section.
//
// Per the contract (REVERSAL 2026-05-05): F&F controls polling
// cadence per (operator, location) via tier assignment. Operators
// see tier names + tier prices, NOT vendor per-call costs. The
// earlier cadence-picker + cost-projection UI is forbidden on
// operator-facing surfaces. Any future surface that gives operators
// a direct cadence picker violates this contract.

import 'package:flutter/material.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../theme/app_theme.dart';
import 'data_accuracy_applicability.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';
import 'vendor_relativity_label.dart';

/// Tier label keys. The display string + monthly price label come
/// off [PollingTierStatus.tierDisplayLabel] / .monthlyPriceLabel so
/// the F&F admin surface (Lane .C) can override them per
/// (operator, location).
enum PollingTierLabel { standard, premium, custom }

/// Display payload for the polling tier status card. The screen
/// builds this off [PollingTierStatus] read from the gateway; null
/// means "still loading".
class PollingTierStatus {
  const PollingTierStatus({
    required this.tier,
    required this.tierDisplayLabel,
    required this.monthlyPriceLabel,
    required this.perVendorCadenceSeconds,
  });

  /// Stable tier key.
  final PollingTierLabel tier;

  /// Operator-facing tier name. Examples: "Standard", "Premium",
  /// "Custom".
  final String tierDisplayLabel;

  /// Operator-facing monthly price label. Examples:
  /// "$25/month", "Bundled with subscription".
  final String monthlyPriceLabel;

  /// Resolved cadence per poll-only vendor, seconds. Example:
  /// `{'oracle_micros_simphony': 300, 'quickbooks_time': 300}`.
  /// Webhook vendors are NEVER in this map (they ignore polling
  /// cadence per the contract's transport-bounded live-ness rule).
  final Map<String, int> perVendorCadenceSeconds;
}

/// Display-only polling tier card on the Operator Web Console Data
/// Accuracy tab. Shows the current tier + monthly price label + a
/// per-vendor cadence list. The only interactive element is the
/// "Request tier change" button; tapping it calls
/// [onRequestTierChange] which is wired by the screen to
/// [showPollingTierChangeRequestDialog] (or a real ticket flow when
/// one is wired).
class PollingTierStatusCard extends StatelessWidget {
  const PollingTierStatusCard({
    super.key,
    required this.status,
    required this.bundle,
    required this.onRequestTierChange,
    this.appliesToConnectedVendors = true,
    this.actionLabel = 'Request faster data freshness',
    this.actionDescription =
        'Request a change when poll-only vendors need fresher '
        'data than this tier provides.',
    this.actionIcon = Icons.bolt_outlined,
    this.actionEnabled = true,
    this.actionAvailableWhenNotApplicable = false,
  });

  /// Current tier status. Null while loading — renders a placeholder.
  final PollingTierStatus? status;

  /// Latest VendorConnectionsBundle (for the relativity label).
  final VendorConnectionsBundle? bundle;

  /// Tapped on "Request tier change". Wired by the screen.
  final VoidCallback onRequestTierChange;

  /// False when the selected location has no poll-only vendors. In that
  /// state there is nothing for an operator to change on this surface.
  final bool appliesToConnectedVendors;
  final String actionLabel;
  final String actionDescription;
  final IconData actionIcon;
  final bool actionEnabled;
  final bool actionAvailableWhenNotApplicable;

  @override
  Widget build(BuildContext context) {
    return _DataAccuracyCard(
      cardKey: const Key('data_accuracy_polling_tier_status_card'),
      title: 'Data freshness tier',
      headerExplainer:
          'Applies only to vendors that do not push live updates. Forge & '
          'Flow checks them on the schedule set by this location\'s tier.',
      child: !appliesToConnectedVendors
          ? _FreshnessDoesNotApplyBlock(
              bundle: bundle,
              actionLabel: actionLabel,
              actionIcon: actionIcon,
              onRequestTierChange:
                  actionEnabled && actionAvailableWhenNotApplicable
                  ? onRequestTierChange
                  : null,
            )
          : status == null
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: Text('Loading your tier...')),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TierStatusBlock(status: status!),
                const SizedBox(height: 14),
                _PerVendorCadenceList(
                  perVendorCadenceSeconds: status!.perVendorCadenceSeconds,
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('polling_tier_request_change_button'),
                    onPressed: actionEnabled ? onRequestTierChange : null,
                    icon: Icon(actionIcon, size: 16),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sunsetDark,
                      foregroundColor: AppColors.backgroundSurface,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    label: Text(actionLabel),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  actionDescription,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                const SizedBox(height: 14),
                VendorRelativityLabel(
                  setting: VendorRelativitySetting.polling,
                  bundle: bundle,
                ),
              ],
            ),
    );
  }
}

class _FreshnessDoesNotApplyBlock extends StatelessWidget {
  const _FreshnessDoesNotApplyBlock({
    required this.bundle,
    required this.actionLabel,
    required this.actionIcon,
    this.onRequestTierChange,
  });

  final VendorConnectionsBundle? bundle;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback? onRequestTierChange;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('polling_tier_not_applicable_notice'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.shimmer,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.lock_clock_outlined,
                size: 18,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  dataFreshnessNotApplicableCopy(bundle),
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('polling_tier_request_change_button'),
            onPressed: onRequestTierChange,
            icon: Icon(actionIcon, size: 16),
            label: Text(actionLabel),
          ),
        ),
      ],
    );
  }
}

class _TierStatusBlock extends StatelessWidget {
  const _TierStatusBlock({required this.status});

  final PollingTierStatus status;

  @override
  Widget build(BuildContext context) {
    // A clean header row (no tinted panel) so the tier reads as the card's
    // headline status instead of one more nested box.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          key: const Key('polling_tier_status_pill'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.peacock,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            status.tierDisplayLabel,
            style: AppTextStyles.chipLabel(color: AppColors.backgroundSurface),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current tier',
                style: AppTextStyles.uiLabel(color: AppColors.sunsetDark),
              ),
              const SizedBox(height: 2),
              Text(
                status.monthlyPriceLabel,
                style: AppTextStyles.body14(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PerVendorCadenceList extends StatelessWidget {
  const _PerVendorCadenceList({required this.perVendorCadenceSeconds});

  final Map<String, int> perVendorCadenceSeconds;

  @override
  Widget build(BuildContext context) {
    if (perVendorCadenceSeconds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Every connected vendor pushes updates to Forge & Flow when they '
          'happen, so there is no schedule to set here.',
          style: AppTextStyles.body13(color: AppColors.textMuted),
        ),
      );
    }
    final entries = perVendorCadenceSeconds.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'How often we check each vendor',
          style: AppTextStyles.uiLabel(color: AppColors.sunsetDark),
        ),
        const SizedBox(height: 8),
        // One light grouped list with hairline separators, instead of a
        // separate bordered tile per vendor (less nesting on the card).
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, color: AppColors.borderSubtle),
                _VendorCadenceRow(
                  vendorId: entries[i].key,
                  cadenceSeconds: entries[i].value,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _VendorCadenceRow extends StatelessWidget {
  const _VendorCadenceRow({
    required this.vendorId,
    required this.cadenceSeconds,
  });

  final String vendorId;
  final int cadenceSeconds;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('polling_tier_vendor_row_$vendorId'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              friendlyVendorDisplayName(vendorId),
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
          Text(
            friendlyCadenceLabel(cadenceSeconds),
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Maps a stable vendor id to the operator-facing display name. The
/// 5 poll-only vendors per the contract live here; webhook vendors
/// are intentionally absent because the cadence list never carries
/// them.
String friendlyVendorDisplayName(String vendorId) {
  switch (vendorId) {
    case 'oracle_micros_simphony':
      return 'Oracle MICROS Simphony';
    case 'quickbooks_time':
      return 'QuickBooks Time';
    case 'humanity':
      return 'Humanity';
    case 'agendrix':
      return 'Agendrix';
    case 'push_operations':
      return 'Push Operations';
    default:
      return vendorId;
  }
}

/// Formats a cadence in seconds as plain English.
///
///   <60s         "${s} seconds"
///   60-3599s     "${m} minute(s)"
///   >=3600s      "${h} hour(s)"
String friendlyCadenceLabel(int cadenceSeconds) {
  if (cadenceSeconds < 60) {
    return '$cadenceSeconds seconds';
  }
  if (cadenceSeconds < 3600) {
    final minutes = cadenceSeconds ~/ 60;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }
  final hours = cadenceSeconds ~/ 3600;
  return hours == 1 ? '1 hour' : '$hours hours';
}

// ─── Default ticket-flow dialog ─────────────────────────────────────
//
// The Lane .C F&F Ops Console will eventually carry a real ticket
// flow surface ("Card 4: Tier change requests" in the contract).
// Until that lands, the operator-facing surface opens this plain
// dialog. The screen wires `onRequestTierChange` to call
// `showPollingTierChangeRequestDialog(context)` and surface a
// transient toast with the typed reason. Routing the result into
// the real ticket table is a Lane .C follow-up.

/// Opens the tier-change-request dialog and resolves to the trimmed
/// reason text on submit, or `null` on cancel.
Future<String?> showPollingTierChangeRequestDialog(BuildContext context) {
  return showDialog<String?>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) {
      return const _PollingTierChangeRequestDialog();
    },
  );
}

class _PollingTierChangeRequestDialog extends StatefulWidget {
  const _PollingTierChangeRequestDialog();

  @override
  State<_PollingTierChangeRequestDialog> createState() =>
      _PollingTierChangeRequestDialogState();
}

class _PollingTierChangeRequestDialogState
    extends State<_PollingTierChangeRequestDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit => _controller.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('polling_tier_change_request_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Request a different tier',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Tell us what you would like to change and why. The F&F '
              'team will email you back within one business day.',
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('polling_tier_change_request_reason_field'),
              controller: _controller,
              maxLines: 5,
              minLines: 3,
              decoration: InputDecoration(
                hintText:
                    'For example: We are pushing to under-a-minute service '
                    'awareness during dinner rush. Would Premium fit?',
                hintStyle: AppTextStyles.body13(color: AppColors.textMuted),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.borderSubtle),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppColors.sunsetDark,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('polling_tier_change_request_cancel'),
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(
            'Cancel',
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ),
        FilledButton(
          key: const Key('polling_tier_change_request_submit'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunsetDark,
            foregroundColor: AppColors.backgroundSurface,
            disabledBackgroundColor: AppColors.borderSubtle,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          ),
          onPressed: _canSubmit
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}

// ─── Shared chrome ──────────────────────────────────────────────────
//
// _DataAccuracyCard is duplicated across the Lane .B widget set so
// each widget file is self-contained (no cross-imports between
// sibling widget files in this lane).

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
