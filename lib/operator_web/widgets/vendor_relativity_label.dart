// Phase 8 spine-bridge Lane .B — Vendor relativity label.
//
// Renders the per-card "this setting applies when..." copy that names
// which connected vendors the setting affects.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Vendor relativity rules" + "Wage source resolution" sections.
//
// The label is dynamic: it reads the operator's currently-connected
// POS / labor / reservation vendor from the supplied
// [VendorConnectionsBundle] and substitutes the vendor's display
// name into the copy. With Toast (POS) connected, the covers card
// reads "Toast exposes covers directly..." With Square connected,
// "Square does not expose covers directly..."
//
// Wage class lookup goes through Lane .2's
// `lib/services/integration/labor_wage_source_class.dart` — the
// 2026-05-05-binding sidecar — so this widget never disagrees with
// the aggregator on what wage path a connected labor vendor takes.
// Per the 2026-05-05 corrections, no Wave B vendor currently
// qualifies as `perEmployeeWithDollars`; QBT/7shifts run at
// `perEmployeeWithRates` (rate × duration), Humanity/Agendrix at
// `perPositionWithRates`, ADP/Push at `hoursOnly`.
//
// Covers exposure + poll-only-ness live as small const sets in this
// file because there is no central capability registry yet. Keep them
// in sync with each vendor's `api_consumed.md` reference doc.

import 'package:flutter/material.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../services/integration/labor_wage_source_class.dart';
import '../../theme/app_theme.dart';

enum VendorRelativitySetting { covers, wage, polling }

/// Widget rendering the vendor-relativity copy for a single setting
/// card. Reads the connected POS / labor / reservation rows off
/// [bundle] and produces dynamic English copy.
class VendorRelativityLabel extends StatelessWidget {
  const VendorRelativityLabel({
    super.key,
    required this.setting,
    required this.bundle,
  });

  final VendorRelativitySetting setting;

  /// Latest VendorConnectionsBundle. Null while the gateway is still
  /// loading — renders a generic fallback that doesn't name vendors.
  final VendorConnectionsBundle? bundle;

  @override
  Widget build(BuildContext context) {
    final lines = _composeLines(setting, bundle);
    return Container(
      key: Key('vendor_relativity_label_${setting.name}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Note:',
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < lines.length; i++) ...[
            Text(
              lines[i],
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
            if (i != lines.length - 1) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

/// Public so the screen-level UX audit test can scan the same copy
/// the widget renders (no separate fixture to drift).
List<String> composeVendorRelativityLines(
  VendorRelativitySetting setting,
  VendorConnectionsBundle? bundle,
) =>
    _composeLines(setting, bundle);

List<String> _composeLines(
  VendorRelativitySetting setting,
  VendorConnectionsBundle? bundle,
) {
  switch (setting) {
    case VendorRelativitySetting.covers:
      return _composeCoversLines(bundle);
    case VendorRelativitySetting.wage:
      return _composeWageLines(bundle);
    case VendorRelativitySetting.polling:
      return _composePollingLines(bundle);
  }
}

// ─── Covers ────────────────────────────────────────────────────────

/// POS vendor IDs whose adapters declare `coversFieldExposed = false`.
/// Anchored to each vendor's `api_consumed.md`; matches the contract's
/// "Vendor relativity rules" row for `Covers source = manual`.
const Set<String> kPosVendorsWithoutCovers = <String>{'square', 'clover'};

/// Whether a connected POS vendor exposes covers as a first-class
/// field. Returns `true` for unknown vendor ids (assume exposed) so a
/// new POS adapter doesn't accidentally trigger walk-in / historical-
/// seed cards on the operator's screen before the lookup is updated.
bool posVendorExposesCovers(String vendorId) =>
    !kPosVendorsWithoutCovers.contains(vendorId);

List<String> _composeCoversLines(VendorConnectionsBundle? bundle) {
  final pos = bundle?.posConnection;
  if (pos == null) {
    return <String>[
      'This setting applies when your POS does not expose covers as a first-class field.',
      'POS systems that do not expose covers at V1: Square, Clover.',
    ];
  }
  final coversNotExposed = kPosVendorsWithoutCovers.contains(pos.vendorId);
  if (!coversNotExposed) {
    return <String>[
      '${pos.displayName} exposes covers directly. This setting only kicks in if you switch to a POS that does not (Square, Clover).',
      'You can still pick "manual" for a daypart to type your own numbers; F&F will use those instead of what ${pos.displayName} reports.',
    ];
  }
  return <String>[
    '${pos.displayName} does not expose covers as a first-class field. Pick a covers source per daypart so F&F knows where to read covers from.',
    'POS systems that do not expose covers at V1: Square, Clover.',
  ];
}

// ─── Wage ──────────────────────────────────────────────────────────

List<String> _composeWageLines(VendorConnectionsBundle? bundle) {
  final labor = bundle?.laborConnection;
  if (labor == null) {
    return <String>[
      'This setting applies when your labor vendor does not expose per-shift dollars.',
      'Scheduling systems that do not expose dollars at V1: QuickBooks Time, 7shifts, Humanity, Agendrix, ADP Workforce Now, Push Operations.',
    ];
  }
  final wageClass = laborWageSourceClassFor(labor.vendorId);
  if (wageClass == null) {
    return <String>[
      'Your labor vendor (${labor.displayName}) is connected. This setting controls how F&F resolves labor dollars when the vendor does not expose them directly.',
      'Scheduling systems that do not expose dollars at V1: QuickBooks Time, 7shifts, Humanity, Agendrix, ADP Workforce Now, Push Operations.',
    ];
  }
  switch (wageClass) {
    case LaborWageSourceClass.perEmployeeWithDollars:
      return <String>[
        '${labor.displayName} reports per-employee labor dollars. F&F uses those directly when you choose "Use vendor".',
        'Switch to "Use my manual wage mix" if you want F&F to ignore vendor dollars and use the wage editor mix instead.',
      ];
    case LaborWageSourceClass.perEmployeeWithRates:
      return <String>[
        '${labor.displayName} reports per-employee hourly rates, not per-shift dollars. When you choose "Use vendor", F&F multiplies each punch\'s duration by the employee\'s rate.',
        'Switch to "Use my manual wage mix" if your vendor rates are out of date and you would rather F&F use your wage editor mix.',
      ];
    case LaborWageSourceClass.perPositionWithRates:
      return <String>[
        '${labor.displayName} reports per-position pay rates, not per-employee dollars. F&F multiplies those by scheduled hours when you choose "Use vendor".',
        'This is what the wage model needs. Your wage editor\'s role rows reflect what your scheduler reports.',
      ];
    case LaborWageSourceClass.hoursOnly:
      return <String>[
        '${labor.displayName} does not expose dollars or rates. F&F substitutes target wage × hours from your TargetCycle when you choose "Use vendor".',
        'Switch to "Use my manual wage mix" to use your wage editor mix instead. Usually more accurate when you have not set targets yet.',
      ];
  }
}

// ─── Polling ───────────────────────────────────────────────────────

/// Vendor IDs whose adapters declare `webhookSupport == pollOnly`.
/// Anchored to the contract's "Transport-bounded live-ness" row +
/// each vendor's `api_consumed.md`.
const Set<String> _kPollOnlyVendors = <String>{
  'oracle_micros_simphony',
  'quickbooks_time',
  'humanity',
  'agendrix',
  'push_operations',
};

List<String> _composePollingLines(VendorConnectionsBundle? bundle) {
  // Polling cadence applies only to poll-only vendors. Webhook
  // vendors update in real time. We name the connected vendor when
  // it falls in either group, and we name the poll-only roster up
  // front so the operator understands the boundary.
  final pos = bundle?.posConnection;
  final labor = bundle?.laborConnection;
  final pollOnlyConnected = <String>[
    if (pos != null && _kPollOnlyVendors.contains(pos.vendorId))
      pos.displayName,
    if (labor != null && _kPollOnlyVendors.contains(labor.vendorId))
      labor.displayName,
  ];
  final webhookConnected = <String>[
    if (pos != null && !_kPollOnlyVendors.contains(pos.vendorId))
      pos.displayName,
    if (labor != null && !_kPollOnlyVendors.contains(labor.vendorId))
      labor.displayName,
  ];

  if (pollOnlyConnected.isEmpty && webhookConnected.isEmpty) {
    return <String>[
      'Some vendors push new data to Forge & Flow the moment it happens. Others only respond when we ask. Your tier controls how often we ask the ones that do not push.',
      'Vendors that need to be asked: Oracle MICROS Simphony, QuickBooks Time, Humanity, Agendrix, Push Operations.',
    ];
  }
  final lines = <String>[];
  if (pollOnlyConnected.isNotEmpty) {
    lines.add(
      'Forge & Flow checks ${pollOnlyConnected.join(' and ')} for new data on a regular schedule. Your tier sets how often.',
    );
  }
  if (webhookConnected.isNotEmpty) {
    lines.add(
      '${webhookConnected.join(' and ')} push updates to Forge & Flow in real time, so your tier does not change how fast they refresh.',
    );
  }
  lines.add(
    'Forge & Flow manages the schedule at the tier level. Tap "Request faster data freshness" below if you need a different cadence.',
  );
  return lines;
}
