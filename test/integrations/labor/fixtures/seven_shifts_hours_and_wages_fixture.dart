// Phase 8.spine-bridge.7S.upgrade — fixtures for the
// `/v2/company/{company_id}/reports/hours_and_wages` endpoint.
//
// Source documentation:
// <https://developers.7shifts.com/reference/get_reports-hours-and-wages>
//
// The Hours & Wages report exposes per-(employee, shift) wage totals
// (`total_pay`, `regular_pay`, `overtime_pay`). Lane
// `8.spine-bridge.7S.upgrade` consumes the endpoint alongside
// `/time_punches` so 7shifts qualifies as
// `LaborWageSourceClass.perEmployeeWithDollars` per
// `docs/contracts/integration_spine_architecture_contract.md`
// 2026-05-05 falsehood corrections #7. Adapter merges by
// `(employee_id, shift_id)`; merge tests live in
// `test/integrations/labor/seven_shifts_labor_adapter_test.dart`
// group "Hours & Wages report".

import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';

/// Two time-punches that mirror the report-fixture's
/// (employee_id, shift_id) tuples — the merge test asserts the
/// canonical facts emerge with `actual_labor_dollars` populated.
const List<Map<String, Object?>> sevenShiftsTimePunchesWithShiftIds =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 712301,
    'user_id': 99001,
    // 7shifts links each time_punch to a planned shift via shift_id.
    'shift_id': 887701,
    'role': <String, Object?>{'id': 401, 'name': 'Server'},
    'clocked_in': '2026-05-03T18:00:00Z',
    'clocked_out': '2026-05-03T23:30:00Z',
    'approved': true,
    'modified': '2026-05-03T23:35:00Z',
  },
  <String, Object?>{
    'id': 712302,
    'user_id': 99002,
    'shift_id': 887702,
    'role': <String, Object?>{'id': 402, 'name': 'Bartender'},
    'clocked_in': '2026-05-03T17:00:00Z',
    'clocked_out': '2026-05-03T22:30:00Z',
    'approved': true,
    'modified': '2026-05-03T22:35:00Z',
  },
];

/// Hours & Wages report rows matching
/// [sevenShiftsTimePunchesWithShiftIds] by (employee_id, shift_id).
/// Report row 1 covers regular + overtime; row 2 is regular only.
const List<SevenShiftsHoursAndWagesRow>
    sevenShiftsHoursAndWagesReportRows = <SevenShiftsHoursAndWagesRow>[
  SevenShiftsHoursAndWagesRow(
    employeeId: '99001',
    shiftId: '887701',
    totalPay: 137.50,
    regularPay: 110.00,
    overtimePay: 27.50,
  ),
  SevenShiftsHoursAndWagesRow(
    employeeId: '99002',
    shiftId: '887702',
    totalPay: 96.25,
    regularPay: 96.25,
    overtimePay: 0,
  ),
];

/// Canonical-fact-shaped expectations for
/// [sevenShiftsTimePunchesWithShiftIds] + [sevenShiftsHoursAndWagesReportRows]
/// after the merge. Test A asserts each canonical fact dict carries
/// these wage values and provenance.
const Map<String, num> sevenShiftsExpectedTotalPayByVendorEntityId =
    <String, num>{
  '712301': 137.50,
  '712302': 96.25,
};
