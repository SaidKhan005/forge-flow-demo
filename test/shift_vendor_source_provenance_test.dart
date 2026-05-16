// Fix: Shift dashboard labor tiles honestly reflect per-location
// vendor connection.
//
// Defect: every demo location's CPLH / SPLH / BLENDED WAGE tiles
// rendered "connect a labor vendor" because the two whole-day
// `buildWholeDay(...)` call sites omitted `laborSourceVendorId`, so
// the EXISTING read-model gate always saw `null`.
//
// These tests pin the caller-only fix: feeding the per-location
// connection state (resolved off the same `DemoVendorIntegrationState
// Fixture` the banner uses) makes the UNCHANGED gate degrade honestly
// per location, matching the locked operator decision:
//   * Downtown  (POS+Labor connected)            → labor live
//   * North Loop (POS connected, Labor off)      → labor unavailable
//   * Riverside  (all connected/live)            → labor live
//   * Harbour    (none connected)                → labor unavailable
// POS provenance is unaffected by the fix.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/metric_provenance.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/services/integration/shift_vendor_source_resolver.dart';

ActiveTargetProfile _profile() => const ActiveTargetProfile(
      targetProfileId: 'test_active',
      restaurantId: 'demo_restaurant_001',
      sourceType: 'system_baseline',
      targetCPLH: 5.0,
      targetSPLH: 200.0,
      targetPPA: 40.0,
      fohWage: 18.0,
      bohWage: 19.0,
      opzFloorCPLH: 4.0,
      opzCeilingCPLH: 6.0,
      theoreticalFohLaborPct: 12.0,
      theoreticalBohLaborPct: 14.0,
      theoreticalLaborPct: 26.0,
      builtAt: '2026-03-27T19:42:00',
    );

/// A closed whole-day snapshot with positive FOH/BOH hours, covers,
/// sales and blended wage so the read-model gate's *value* guards
/// (`actualFohHours > 0`, etc.) are all satisfied — isolating the
/// vendor-id gate as the only variable under test.
OpenShiftSnapshot _snapshot(String restaurantId) => OpenShiftSnapshot(
      restaurantId: restaurantId,
      weekId: '2026-W13',
      dayLabel: 'Fri',
      daypart: 'dinner',
      status: 'closed',
      businessDate: '2026-03-27',
      forecastCovers: 200,
      currentCovers: 180,
      scheduledFohHours: 30,
      scheduledBohHours: 28,
      currentPPA: 41.00,
      currentCPLH: 6.0,
      currentSPLH: 205.0,
      blendedWage: 18.74,
      updatedAt: '2026-03-27T19:42:00',
    );

ShiftDashboardReadModel _buildFor(String restaurantId) {
  final vendorSource = ShiftVendorSourceResolver.forLocation(restaurantId);
  return ShiftDashboardReadModel.buildWholeDay(
    snapshots: [_snapshot(restaurantId)],
    profile: _profile(),
    forecastCovers: 200,
    forecastSales: 8000,
    planFohHours: 30,
    planBohHours: 28,
    posSourceVendorId: vendorSource.posSourceVendorId,
    laborSourceVendorId: vendorSource.laborSourceVendorId,
  );
}

void main() {
  group('ShiftVendorSourceResolver — per-location connection state', () {
    test('Downtown: POS + Labor connected → both vendor ids resolved', () {
      final src =
          ShiftVendorSourceResolver.forLocation(DemoScope.downtownRestaurantId);
      expect(src.posSourceVendorId, 'toast');
      expect(src.laborSourceVendorId, 'humanity');
    });

    test('North Loop: POS connected, Labor disconnected → labor id null', () {
      final src =
          ShiftVendorSourceResolver.forLocation(DemoScope.northLoopRestaurantId);
      expect(src.posSourceVendorId, 'toast');
      expect(src.laborSourceVendorId, isNull);
    });

    test('Riverside: all connected (flipped live) → both vendor ids', () {
      final src =
          ShiftVendorSourceResolver.forLocation(DemoScope.riversideRestaurantId);
      expect(src.posSourceVendorId, 'toast');
      expect(src.laborSourceVendorId, 'humanity');
    });

    test('Harbour: none connected → both vendor ids null', () {
      final src =
          ShiftVendorSourceResolver.forLocation(DemoScope.harbourRestaurantId);
      expect(src.posSourceVendorId, isNull);
      expect(src.laborSourceVendorId, isNull);
    });

    test('unknown (production) location → ShiftVendorSource.none', () {
      final src = ShiftVendorSourceResolver.forLocation('op-42/loc-real-7f3a');
      expect(src.posSourceVendorId, isNull);
      expect(src.laborSourceVendorId, isNull);
    });
  });

  group('whole-day read model labor provenance — honest per location', () {
    test('Downtown → CPLH/SPLH/blended-wage are live, not unavailable', () {
      final rm = _buildFor(DemoScope.downtownRestaurantId);
      expect(rm.cplhProvenance.state, MetricState.live);
      expect(rm.splhProvenance.state, MetricState.live);
      expect(rm.blendedWageProvenance.state, MetricState.live);
      // Real seeded values flow through, not phantom zeros.
      expect(rm.cplhProvenance.value, greaterThan(0));
      expect(rm.blendedWageProvenance.value, greaterThan(0));
    });

    test('Riverside → CPLH/SPLH/blended-wage are live', () {
      final rm = _buildFor(DemoScope.riversideRestaurantId);
      expect(rm.cplhProvenance.state, MetricState.live);
      expect(rm.splhProvenance.state, MetricState.live);
      expect(rm.blendedWageProvenance.state, MetricState.live);
    });

    test('North Loop → labor provenance stays unavailable (Labor off)', () {
      final rm = _buildFor(DemoScope.northLoopRestaurantId);
      expect(rm.cplhProvenance.state, MetricState.unavailable);
      expect(rm.splhProvenance.state, MetricState.unavailable);
      expect(rm.blendedWageProvenance.state, MetricState.unavailable);
    });

    test('Harbour → labor provenance stays unavailable (none connected)', () {
      final rm = _buildFor(DemoScope.harbourRestaurantId);
      expect(rm.cplhProvenance.state, MetricState.unavailable);
      expect(rm.splhProvenance.state, MetricState.unavailable);
      expect(rm.blendedWageProvenance.state, MetricState.unavailable);
    });

    test('POS provenance unaffected — covers/sales live wherever data exists',
        () {
      // North Loop POS is connected; Downtown POS connected. The fix
      // must not regress POS provenance for any location.
      for (final id in <String>[
        DemoScope.downtownRestaurantId,
        DemoScope.northLoopRestaurantId,
        DemoScope.riversideRestaurantId,
      ]) {
        final rm = _buildFor(id);
        expect(rm.coversProvenance.state, MetricState.live,
            reason: 'covers should be live for $id');
        expect(rm.salesProvenance.state, MetricState.live,
            reason: 'sales should be live for $id');
      }
    });

    test(
        'gate is caller-only: omitting laborSourceVendorId still '
        'suppresses labor even with positive labor values', () {
      // Proves the read-model gate body is UNCHANGED — it remains a
      // vendor-id gate. Same positive snapshot, no vendor id → the
      // gate still degrades to unavailable. The fix only feeds the
      // gate; it does not collapse it to a value-based guard.
      final rm = ShiftDashboardReadModel.buildWholeDay(
        snapshots: [_snapshot(DemoScope.downtownRestaurantId)],
        profile: _profile(),
        forecastCovers: 200,
        forecastSales: 8000,
        planFohHours: 30,
        planBohHours: 28,
        // posSourceVendorId / laborSourceVendorId intentionally omitted
      );
      expect(rm.cplhProvenance.state, MetricState.unavailable);
      expect(rm.splhProvenance.state, MetricState.unavailable);
      expect(rm.blendedWageProvenance.state, MetricState.unavailable);
    });
  });
}
