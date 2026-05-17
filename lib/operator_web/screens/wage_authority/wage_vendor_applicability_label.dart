// Wave 2 S-1 — Plain-English vendor applicability label for a wage row.
//
// Origin: debug.md:198-220 (OW-13a + OW-13b). Each role row on the Wage
// Authority screen needs a label that tells the operator which labor
// vendor will receive the rate when it syncs. Six Wave B vendors carry
// labor data:
//
//   ADP, 7shifts, Agendrix, Humanity, QuickBooks Time, Push Operations
//
// Per `lib/services/integration/labor_wage_source_class.dart` only a
// subset can consume per-position rates today:
//
//   * `humanity` + `agendrix` — `perPositionWithRates` (1:1 mapping
//     to `wage_role_rows`; this is the model truth path).
//   * `seven_shifts` + `quickbooks_time` — `perEmployeeWithRates`
//     (vendor exposes per-employee rates on a different endpoint;
//     wage-row sync is best-effort metadata for the operator to
//     reconcile, not a binding rate write).
//   * `adp` + `push_operations` — `hoursOnly` (vendor exposes no
//     wage data at V1; wage-row sync is admin reference only).
//
// The label here surfaces that truth to the operator without leaking
// engineering jargon. UX writing standard (no `vendorId`-style codes
// in copy, no scope_id, no inheritance plumbing terms).
//
// Pure-Dart, no Flutter machinery — easy to unit-test.

library;

import '../../../integrations/labor/adp_labor_adapter.dart'
    show kAdpVendorId;
import '../../../integrations/labor/agendrix_labor_adapter.dart'
    show agendrixVendorId;
import '../../../integrations/labor/humanity_labor_adapter.dart'
    show kHumanityVendorId;
import '../../../integrations/labor/push_operations_labor_adapter.dart'
    show pushOperationsVendorId;
import '../../../integrations/labor/quickbooks_time_labor_adapter.dart'
    show kQuickBooksTimeVendorId;
import '../../../integrations/labor/seven_shifts_labor_adapter.dart'
    show kSevenShiftsVendorId;

/// Plain-English display name for each labor vendor. The wage-row
/// table stores opaque vendor ids (`'adp'`, `'seven_shifts'`, …); the
/// screen renders the friendly name.
const Map<String, String> _kLaborVendorDisplayNames = <String, String>{
  kAdpVendorId: 'ADP',
  kSevenShiftsVendorId: '7shifts',
  agendrixVendorId: 'Agendrix',
  kHumanityVendorId: 'Humanity',
  kQuickBooksTimeVendorId: 'QuickBooks Time',
  pushOperationsVendorId: 'Push Operations',
};

/// Vendor applicability tone — drives whether the row's label reads as
/// a binding sync ("Will sync to Humanity"), an advisory note
/// ("7shifts uses per-employee rates"), or a manual-only fallback.
enum WageVendorApplicabilityTone {
  /// Vendor consumes per-position wage rows. Editing the rate here
  /// will push to the vendor on the next sync.
  perPositionSync,

  /// Vendor stores rates per employee, not per position. The wage row
  /// is operator-side reference only.
  perEmployeeAdvisory,

  /// Vendor exposes hours but no wage data. The wage row is operator-
  /// side reference only.
  hoursOnlyAdvisory,

  /// No labor vendor connected at this location, or the row has no
  /// vendor mapping yet. The wage row stays manual.
  manualOnly,
}

/// Compose a plain-English label for one wage row.
///
/// The widget calls this with the row's `vendor_id`, optional
/// `vendor_role_id`, and optional `job_code`. The return is one
/// readable sentence that obeys the UX writing standard — no engineer
/// strings like `kHumanityVendorId` or `vendor_id=humanity` ever
/// surface.
class WageVendorApplicabilityLabel {
  const WageVendorApplicabilityLabel({
    required this.tone,
    required this.text,
  });

  final WageVendorApplicabilityTone tone;
  final String text;
}

/// Build the label text + tone for one wage row.
WageVendorApplicabilityLabel buildWageVendorApplicabilityLabel({
  required String? vendorId,
  String? vendorRoleId,
  String? jobCode,
  Set<String> connectedLaborVendorIds = const <String>{},
}) {
  final trimmedVendorId = vendorId?.trim();
  if (trimmedVendorId == null || trimmedVendorId.isEmpty) {
    // No vendor mapping on the row → manual only.
    return _manualOnlyLabel(
      connectedLaborVendorIds: connectedLaborVendorIds,
    );
  }
  final display = _kLaborVendorDisplayNames[trimmedVendorId];
  if (display == null) {
    // Row references an unknown vendor (e.g. seeded admin data carrying
    // a vendor that has not been onboarded). Don't render a confusing
    // raw id — fall through to manual-only with a soft note.
    return const WageVendorApplicabilityLabel(
      tone: WageVendorApplicabilityTone.manualOnly,
      text: 'Manual only: this row is not tied to a connected labor '
          'vendor at this location yet.',
    );
  }
  final roleHint = _composeRoleHint(
    vendorRoleId: vendorRoleId,
    jobCode: jobCode,
  );
  switch (trimmedVendorId) {
    case kHumanityVendorId:
    case agendrixVendorId:
      return WageVendorApplicabilityLabel(
        tone: WageVendorApplicabilityTone.perPositionSync,
        text: roleHint == null
            ? 'Will sync to $display on the next labor refresh.'
            : 'Will sync to $display as "$roleHint" on the next labor '
                'refresh.',
      );
    case kSevenShiftsVendorId:
    case kQuickBooksTimeVendorId:
      return WageVendorApplicabilityLabel(
        tone: WageVendorApplicabilityTone.perEmployeeAdvisory,
        text: roleHint == null
            ? '$display stores rates per employee. This rate stays on '
                'Forge & Flow as your reference; we do not overwrite '
                '$display.'
            : '$display stores rates per employee. This rate stays on '
                'Forge & Flow as your reference for "$roleHint"; we do '
                'not overwrite $display.',
      );
    case kAdpVendorId:
    case pushOperationsVendorId:
      return WageVendorApplicabilityLabel(
        tone: WageVendorApplicabilityTone.hoursOnlyAdvisory,
        text: roleHint == null
            ? '$display sends us hours, not rates. This rate stays on '
                'Forge & Flow so we can value the hours $display reports.'
            : '$display sends us hours, not rates. This rate stays on '
                'Forge & Flow for "$roleHint" so we can value the hours '
                '$display reports.',
      );
    default:
      return WageVendorApplicabilityLabel(
        tone: WageVendorApplicabilityTone.manualOnly,
        text: 'Linked to $display. Forge & Flow keeps this row as your '
            'reference rate.',
      );
  }
}

WageVendorApplicabilityLabel _manualOnlyLabel({
  required Set<String> connectedLaborVendorIds,
}) {
  if (connectedLaborVendorIds.isEmpty) {
    return const WageVendorApplicabilityLabel(
      tone: WageVendorApplicabilityTone.manualOnly,
      text: 'Manual only: no labor vendor connected at this location.',
    );
  }
  final names = connectedLaborVendorIds
      .map((id) => _kLaborVendorDisplayNames[id] ?? id)
      .toList()
    ..sort();
  final friendlyList = names.length == 1
      ? names.single
      : names.length == 2
          ? '${names.first} and ${names.last}'
          : '${names.take(names.length - 1).join(', ')}, and ${names.last}';
  return WageVendorApplicabilityLabel(
    tone: WageVendorApplicabilityTone.manualOnly,
    text: 'Manual only: pick a vendor role for this row to sync with '
        '$friendlyList.',
  );
}

String? _composeRoleHint({String? vendorRoleId, String? jobCode}) {
  final vendorRole = vendorRoleId?.trim();
  final job = jobCode?.trim();
  if (vendorRole != null && vendorRole.isNotEmpty) return vendorRole;
  if (job != null && job.isNotEmpty) return job;
  return null;
}
