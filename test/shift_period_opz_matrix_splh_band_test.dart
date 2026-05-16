// Per-Daypart V1 regression — the OPZ tile's CPLH x SPLH matrix must
// highlight its active cell in the per-period (daypart) lens, not only
// on the whole-day view.
//
// Bug: `_ShiftSectionViewData.fromPeriod` built `_OpzBandData` WITHOUT a
// `splhState`, so `OpzMatrixGrid` received `splh: null` and rendered all
// nine cells dim for every daypart even when the kitchen had punched in.
// Whole-day already passed `rm.splhState`, so only the daypart lens was
// broken — exactly the operator report.
//
// These pin the caller-side wiring via the `@visibleForTesting`
// projection probe. The SPLH axis of the cross-axis matrix is the BOH
// productivity metric (sales per BOH labor hour) per Jim Taylor deep
// dive ch. 6/7, so the band is computed off `bucket.bohSplh` vs the
// locked `tc.targetSPLH` through the same canonical classifier the
// whole-day read model uses — the two surfaces stay 1:1.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/services/integration/shift_vendor_source_resolver.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';

// Locked per-daypart context: targetCPLH 5.0, OPZ [4.0, 6.0],
// targetSPLH $200 (BOH-axis).
const DaypartTargetContext _tcWithBand = DaypartTargetContext(
  source: 'open_profile',
  targetCPLH: 5.0,
  targetSPLH: 200.0,
  targetPPA: 40.0,
  opzFloorCPLH: 4.0,
  opzCeilingCPLH: 6.0,
  theoreticalLaborPct: 26.0,
  forecastSales: 5000.0,
  requiredFohHours: 10.0,
  requiredBohHours: 8.0,
);

/// Bucket builder. fohMinutes/bohMinutes fixed at 600/480 (10h FOH /
/// 8h BOH, total 18h) so:
///   cplh    = covers * 60 / 1080
///   bohSplh = sales  * 60 / 480
ServicePeriodAccumulator _bucket({
  required int covers,
  required double sales,
  int bohMinutes = 480,
}) =>
    ServicePeriodAccumulator(
      servicePeriodId: 'dinner',
      covers: covers,
      sales: sales,
      checks: covers ~/ 2,
      fohMinutes: 600,
      bohMinutes: bohMinutes,
      fohWageDollars: 180,
      bohWageDollars: 152,
    );

ShiftPeriodProvenanceProbe _probe(ServicePeriodAccumulator b) =>
    debugShiftPeriodProvenance(
      bucket: b,
      tc: _tcWithBand,
      // Downtown — Labor IS connected (mirrors the honest-degrade suite),
      // so the OPZ band is scored, not the not-connected pending state.
      vendorSource: ShiftVendorSourceResolver.forLocation(
          DemoScope.downtownRestaurantId),
    );

void main() {
  group('Per-period OPZ matrix highlights its active cell (the bug)', () {
    test('CPLH above + SPLH above → matrix band "above" (was null)', () {
      // covers 120 → cplh = 120*60/1080 = 6.67  (> ceiling 6.0 → ABOVE)
      // sales 4800 → bohSplh = 4800*60/480 = 600 (> 1.05*200 → above)
      final p = _probe(_bucket(covers: 120, sales: 4800));
      expect(p.opzLabel, 'ABOVE OPZ');
      expect(p.opzMatrixSplhState, 'above',
          reason: 'daypart matrix must highlight a cell, not render dim');
    });

    test('CPLH in OPZ + SPLH on target → matrix band "on"', () {
      // covers 90  → cplh = 90*60/1080 = 5.0  (in [4,6] → IN OPZ)
      // sales 1600 → bohSplh = 1600*60/480 = 200 (== target → on)
      final p = _probe(_bucket(covers: 90, sales: 1600));
      expect(p.opzLabel, 'IN OPZ');
      expect(p.opzMatrixSplhState, 'on');
    });

    test('CPLH below floor + SPLH below target → matrix band "below" '
        '(the orange UNDER x LOW cell from the operator screenshot)', () {
      // covers 30  → cplh = 30*60/1080 = 1.67 (< floor 4.0 → BELOW)
      // sales 1200 → bohSplh = 1200*60/480 = 150 (< 0.95*200 → below)
      final p = _probe(_bucket(covers: 30, sales: 1200));
      expect(p.opzLabel, 'BELOW OPZ');
      expect(p.opzMatrixSplhState, 'below');
    });
  });

  group('Honest-dim cases are preserved (no phantom highlight)', () {
    test('No BOH punches but FOH present → band scored, matrix SPLH null',
        () {
      // bohMinutes 0 → no BOH labor → SPLH axis honestly absent even
      // though CPLH is scored off FOH minutes.
      final p = _probe(_bucket(covers: 60, sales: 2400, bohMinutes: 0));
      expect(p.opzLabel, isNot('LABOR NOT CONNECTED'));
      expect(p.opzMatrixSplhState, isNull,
          reason: 'no BOH punches → matrix renders dim, never a phantom '
              'cell off a zero SPLH');
    });

    test('Labor vendor not connected → pending band, matrix SPLH null', () {
      final p = debugShiftPeriodProvenance(
        bucket: _bucket(covers: 120, sales: 4800),
        tc: _tcWithBand,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.harbourRestaurantId),
      );
      expect(p.opzLabel, 'LABOR NOT CONNECTED');
      expect(p.opzMatrixSplhState, isNull);
    });
  });

  group('Canonical classifier stays consistent across surfaces', () {
    test('computeSplhState honors the +/- 5% tolerance + honest nulls',
        () {
      String? band(double actual, double target, {bool boh = true}) =>
          ShiftDashboardReadModel.computeSplhState(
            hasBohLabor: boh,
            actualSplh: actual,
            targetSplh: target,
          );
      expect(band(200, 200), 'on');
      expect(band(209, 200), 'on'); // +4.5% inside tolerance
      expect(band(211, 200), 'above'); // +5.5% over tolerance
      expect(band(191, 200), 'on'); // -4.5% inside tolerance
      expect(band(189, 200), 'below'); // -5.5% under tolerance
      expect(band(600, 200, boh: false), isNull); // no BOH labor
      expect(band(600, 0), isNull); // no locked target
    });
  });

  group('Daypart OPZ sub-label speaks the SAME cross-axis sentence as '
      'whole-day (true 1:1)', () {
    test('CPLH below + SPLH above → the Jim Taylor ch. 7 cross-axis '
        'coaching sentence, not the single-axis line', () {
      // covers 36  → cplh = 36*60/1080 = 2.0  (< floor 4.0 → BELOW)
      // sales 2400 → bohSplh = 2400*60/480 = 300 (> 1.05*200 → above)
      final p = _probe(_bucket(covers: 36, sales: 2400));
      expect(p.opzMatrixSplhState, 'above');
      expect(
        p.opzSubLabel,
        'Below OPZ floor. Team executed. Volume problem, not staffing. '
        'Fix the forecast.',
      );
      // And it is exactly what the whole-day resolver would emit.
      expect(
        p.opzSubLabel,
        ShiftDashboardReadModel.computeOpzSubLabel('below', 'above'),
      );
    });

    test('CPLH in OPZ + SPLH above → "kitchen running strong" cross-axis '
        'sentence', () {
      // covers 90 → cplh 5.0 (IN); sales 2400 → bohSplh 300 (above)
      final p = _probe(_bucket(covers: 90, sales: 2400));
      expect(
        p.opzSubLabel,
        ShiftDashboardReadModel.computeOpzSubLabel('in', 'above'),
      );
      expect(p.opzSubLabel, contains('Kitchen running strong'));
    });

    test('No band (no BOH punches) → single-axis fallback, byte-identical '
        'to the prior per-period copy (no regression)', () {
      final p = _probe(_bucket(covers: 30, sales: 1200, bohMinutes: 0));
      expect(p.opzMatrixSplhState, isNull);
      expect(
        p.opzSubLabel,
        'Productivity is below the OPZ floor. Too many labor hours for '
        'the volume.',
      );
      expect(
        p.opzSubLabel,
        ShiftDashboardReadModel.computeOpzSubLabel('below', null),
      );
    });
  });
}
