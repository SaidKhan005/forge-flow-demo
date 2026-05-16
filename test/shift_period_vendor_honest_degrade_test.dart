// Defects 2 & 3 — per-period (Variance) Shift labor must honest-degrade
// per the SAME per-(operator, location, category) vendor connection
// signal the whole-day path (Defect 1) and the DemoModeBanner use, and
// the unavailable copy must distinguish "vendor not connected" from
// "this service period hasn't started yet today".
//
// These pin the in-scope, caller-side behavior via the
// `@visibleForTesting` projection probe — no formula / read-model gate
// change, no kDemoMode reader fork.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/metric_provenance.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/services/integration/shift_vendor_source_resolver.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';

/// In-period bucket with positive covers, sales AND labor minutes so the
/// EXISTING value gate (`bucket.totalMinutes > 0`, `bucket.covers > 0`)
/// is satisfied — isolating the per-location connection check as the
/// only variable.
ServicePeriodAccumulator _fullBucket() => const ServicePeriodAccumulator(
      servicePeriodId: 'lunch',
      covers: 120,
      sales: 4800,
      checks: 60,
      fohMinutes: 600,
      bohMinutes: 480,
      fohWageDollars: 180,
      bohWageDollars: 152,
    );

/// Empty bucket — no covers, no punches (pre-service / not started).
ServicePeriodAccumulator _emptyBucket() =>
    const ServicePeriodAccumulator(servicePeriodId: 'lunch');

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

void main() {
  group('Defect 2 — per-period labor honest-degrades per location', () {
    test('Downtown (Labor connected) → labor actuals render live', () {
      final p = debugShiftPeriodProvenance(
        bucket: _fullBucket(),
        tc: _tcWithBand,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.downtownRestaurantId),
      );
      expect(p.cplhState, MetricState.live);
      expect(p.splhState, MetricState.live);
      expect(p.blendedWageState, MetricState.live);
      expect(p.laborActualPctPresent, isTrue);
      // OPZ scored, not the not-connected pending state.
      expect(p.opzLabel, isNot('LABOR NOT CONNECTED'));
      // POS / covers / sales path unchanged (value-based gate).
      expect(p.coversState, MetricState.live);
      expect(p.ppaState, MetricState.live);
    });

    test('Riverside (all connected/live) → labor actuals render live', () {
      final p = debugShiftPeriodProvenance(
        bucket: _fullBucket(),
        tc: _tcWithBand,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.riversideRestaurantId),
      );
      expect(p.cplhState, MetricState.live);
      expect(p.splhState, MetricState.live);
      expect(p.blendedWageState, MetricState.live);
      expect(p.laborActualPctPresent, isTrue);
    });

    test('North Loop (Labor disconnected) → labor honest-degraded, '
        'covers/sales untouched', () {
      final p = debugShiftPeriodProvenance(
        bucket: _fullBucket(),
        tc: _tcWithBand,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.northLoopRestaurantId),
      );
      expect(p.cplhState, MetricState.unavailable);
      expect(p.splhState, MetricState.unavailable);
      expect(p.blendedWageState, MetricState.unavailable);
      expect(p.laborActualPctPresent, isFalse);
      expect(p.opzLabel, 'LABOR NOT CONNECTED');
      // North Loop POS IS connected and the bucket has covers — the
      // value-based POS/covers/sales path must be unchanged.
      expect(p.coversState, MetricState.live);
      expect(p.ppaState, MetricState.live);
    });

    test('Harbour (none connected) → labor honest-degraded', () {
      final p = debugShiftPeriodProvenance(
        bucket: _fullBucket(),
        tc: _tcWithBand,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.harbourRestaurantId),
      );
      expect(p.cplhState, MetricState.unavailable);
      expect(p.splhState, MetricState.unavailable);
      expect(p.blendedWageState, MetricState.unavailable);
      expect(p.laborActualPctPresent, isFalse);
      expect(p.opzLabel, 'LABOR NOT CONNECTED');
      // Covers gate stays value-based (prompt: keep POS/covers/sales
      // unchanged) — the bucket has covers, so covers still render.
      expect(p.coversState, MetricState.live);
    });
  });

  group('Defect 3 — pre-service vs not-connected messaging', () {
    test('POS connected + pre-service → "hasn\'t started yet", '
        'NOT "Connect a POS vendor"', () {
      final p = debugShiftPeriodProvenance(
        bucket: _emptyBucket(),
        tc: DaypartTargetContext.none,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.downtownRestaurantId),
        periodNotStartedYet: true,
      );
      expect(p.coversState, MetricState.unavailable);
      expect(p.posUnavailableCopy, contains("hasn't started yet"));
      expect(p.posUnavailableCopy, isNot(contains('Connect a POS vendor')));
    });

    test('Labor connected + pre-service → labor copy is the pre-service '
        'state too', () {
      final p = debugShiftPeriodProvenance(
        bucket: _emptyBucket(),
        tc: DaypartTargetContext.none,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.downtownRestaurantId),
        periodNotStartedYet: true,
      );
      expect(p.laborUnavailableCopy, contains("hasn't started yet"));
      expect(
          p.laborUnavailableCopy, isNot(contains('Connect a labor vendor')));
    });

    test('Genuinely not connected + pre-service → still "Connect a vendor" '
        '(never mislabeled as not-started)', () {
      final p = debugShiftPeriodProvenance(
        bucket: _emptyBucket(),
        tc: DaypartTargetContext.none,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.harbourRestaurantId),
        periodNotStartedYet: true,
      );
      expect(p.posUnavailableCopy, 'Connect a POS vendor to see covers.');
      expect(p.laborUnavailableCopy,
          'Connect a labor vendor to see blended wage.');
      expect(p.posUnavailableCopy, isNot(contains("hasn't started")));
    });

    test('POS connected, NOT pre-service, no covers → existing honest-zero '
        'copy unchanged', () {
      final p = debugShiftPeriodProvenance(
        bucket: _emptyBucket(),
        tc: DaypartTargetContext.none,
        vendorSource: ShiftVendorSourceResolver.forLocation(
            DemoScope.downtownRestaurantId),
        // periodNotStartedYet defaults false (period over / genuine zero).
      );
      expect(p.posUnavailableCopy, 'Connect a POS vendor to see covers.');
    });
  });
}
