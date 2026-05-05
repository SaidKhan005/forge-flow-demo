// Phase 8 spine-bridge Lane .B — Vendor relativity label.
//
// Renders the per-card "this setting applies when..." copy that names
// which connected vendors the setting affects, plus the V1 list of
// vendors that REQUIRE it (vendor doesn't expose that field).
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Vendor relativity rules" section.
//
// The label is dynamic: it reads the operator's currently-connected
// POS / labor / reservation vendor from the supplied
// [VendorConnectionsBundle] and substitutes the vendor's display
// name into the copy. With Toast (POS) connected, the covers card
// reads "Toast exposes covers directly..." With Square connected,
// "Square does not expose covers directly..."
//
// Static per-vendor facts live in this file as a const lookup —
// `coversFieldExposed`, `wageClass`, polling-only-ness — sourced from
// each vendor's `api_consumed.md` reference doc + the contract's
// vendor relativity table. There is no live registry in the codebase
// today, so this lookup is the seam; it's a single edit when a new
// vendor lands.

import 'package:flutter/material.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
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
            'How this applies to your setup',
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

List<String> _composeCoversLines(VendorConnectionsBundle? bundle) {
  final pos = bundle?.posConnection;
  if (pos == null) {
    return <String>[
      'This setting applies when your POS does not expose covers as a first-class field.',
      'POS systems that do not expose covers at V1: Square, Clover.',
    ];
  }
  final fact = _kVendorFacts[pos.vendorId];
  if (fact == null) {
    return <String>[
      'Your POS (${pos.displayName}) is connected. This setting only matters when your POS does not expose covers.',
      'POS systems that do not expose covers at V1: Square, Clover.',
    ];
  }
  if (fact.coversFieldExposed) {
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

List<String> _composeWageLines(VendorConnectionsBundle? bundle) {
  final labor = bundle?.laborConnection;
  if (labor == null) {
    return <String>[
      'This setting applies when your scheduling system does not expose per-shift dollars.',
      'Scheduling systems that do not expose dollars at V1: QuickBooks Time, Humanity, Agendrix.',
    ];
  }
  final fact = _kVendorFacts[labor.vendorId];
  if (fact == null) {
    return <String>[
      'Your scheduling system (${labor.displayName}) is connected.',
      'Scheduling systems that do not expose dollars at V1: QuickBooks Time, Humanity, Agendrix.',
    ];
  }
  switch (fact.wageClass) {
    case _WageClass.perEmployeeWithDollars:
      return <String>[
        '${labor.displayName} reports per-employee labor dollars. F&F uses those directly when you choose "Use vendor".',
        'Switch to "Use my manual mix" if you want F&F to ignore vendor dollars and use the wage editor mix instead.',
      ];
    case _WageClass.perPositionWithRates:
      return <String>[
        '${labor.displayName} reports per-position pay rates, not per-employee dollars. F&F multiplies those by scheduled hours when you choose "Use vendor".',
        'This is what the wage model needs — your wage editor\'s role rows reflect what your scheduler reports.',
      ];
    case _WageClass.hoursOnly:
      return <String>[
        '${labor.displayName} does not expose dollars or rates. F&F substitutes target wage × hours from your TargetCycle when you choose "Use vendor".',
        'Switch to "Use my manual mix" to use your wage editor mix instead — usually more accurate when you have not set targets yet.',
      ];
  }
}

List<String> _composePollingLines(VendorConnectionsBundle? bundle) {
  // Polling cadence applies only to poll-only vendors. Webhook
  // vendors update in real time. We name the connected vendor when
  // it falls in either group, and we name the poll-only roster up
  // front so the operator understands the boundary.
  final pos = bundle?.posConnection;
  final labor = bundle?.laborConnection;
  final pollOnlyConnected = <String>[
    if (pos != null && _kVendorFacts[pos.vendorId]?.pollOnly == true)
      pos.displayName,
    if (labor != null && _kVendorFacts[labor.vendorId]?.pollOnly == true)
      labor.displayName,
  ];
  final webhookConnected = <String>[
    if (pos != null && _kVendorFacts[pos.vendorId]?.pollOnly == false)
      pos.displayName,
    if (labor != null && _kVendorFacts[labor.vendorId]?.pollOnly == false)
      labor.displayName,
  ];

  if (pollOnlyConnected.isEmpty && webhookConnected.isEmpty) {
    return <String>[
      'Polling cadence applies to vendors that do not push real-time webhooks (currently: Oracle MICROS Simphony, QuickBooks Time, Humanity, Agendrix, Push Operations).',
      'Your webhook vendors update in real time regardless of this setting.',
    ];
  }
  final lines = <String>[];
  if (pollOnlyConnected.isNotEmpty) {
    lines.add(
      'Polling cadence applies to ${pollOnlyConnected.join(' and ')} — F&F asks them for new data on a schedule.',
    );
  }
  if (webhookConnected.isNotEmpty) {
    lines.add(
      '${webhookConnected.join(' and ')} push updates in real time, so polling cadence does not affect them.',
    );
  }
  lines.add(
    'F&F controls cadence at the tier level. Use "Request tier change" below if you need a different cadence.',
  );
  return lines;
}

// ─── Static vendor facts (V1 lookup) ────────────────────────────────
//
// Not a substitute for capability profiles — when a runtime registry
// lands (Wave D), this table retires. For V1 the shape mirrors the
// contract's "Vendor relativity rules" table verbatim. New vendors
// added here must match each vendor's `api_consumed.md` reference doc.

enum _WageClass { perEmployeeWithDollars, perPositionWithRates, hoursOnly }

class _VendorFacts {
  const _VendorFacts({
    required this.coversFieldExposed,
    required this.wageClass,
    required this.pollOnly,
  });

  final bool coversFieldExposed;
  final _WageClass wageClass;
  final bool pollOnly;
}

const Map<String, _VendorFacts> _kVendorFacts = <String, _VendorFacts>{
  // POS — covers exposure varies; not relevant for wage class.
  'toast': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'square': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'clover': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'lightspeed_lsk': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'revel': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'aloha_ncr_voyix': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'oracle_micros_simphony': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: true,
  ),

  // Labor — wage class lookup matters; covers exposure does not.
  '7shifts': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.perEmployeeWithDollars,
    pollOnly: false,
  ),
  'quickbooks_time': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.perEmployeeWithDollars,
    pollOnly: true,
  ),
  'adp_workforce_now': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.perEmployeeWithDollars,
    pollOnly: false,
  ),
  'humanity': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.perPositionWithRates,
    pollOnly: true,
  ),
  'agendrix': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.perPositionWithRates,
    pollOnly: true,
  ),
  'push_operations': _VendorFacts(
    coversFieldExposed: false,
    wageClass: _WageClass.perEmployeeWithDollars,
    pollOnly: true,
  ),

  // Reservations — neither covers-relevant nor wage-relevant; included
  // for completeness.
  'libro': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'opentable': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'sevenrooms': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
  'tock': _VendorFacts(
    coversFieldExposed: true,
    wageClass: _WageClass.hoursOnly,
    pollOnly: false,
  ),
};
