// Phase 8.0 (V1 lean cut 2) — MetricProvenance value-object tests.
//
// Asserts the contract pairing rules per
// `docs/contracts/metric_card_honesty_contract.md`:
//   * unavailable ⟺ value == null AND provenance == 'none'
//   * live  ⟹ provenance names a vendor (not 'none')
//   * partial / fallback similarly require provenance != 'none'

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/metric_provenance.dart';

void main() {
  group('MetricProvenance', () {
    test('unavailable has null value + provenance "none"', () {
      const m = MetricProvenance.unavailable();
      expect(m.value, isNull);
      expect(m.state, MetricState.unavailable);
      expect(m.provenance, provenanceNone);
      expect(m.rendersNumber, isFalse);
      expect(m.isDegraded, isTrue);
    });

    test('live carries a numeric value + non-none provenance', () {
      const m = MetricProvenance.live(value: 42, provenance: 'vendor_test');
      expect(m.value, 42);
      expect(m.state, MetricState.live);
      expect(m.provenance, 'vendor_test');
      expect(m.rendersNumber, isTrue);
      expect(m.isDegraded, isFalse);
    });

    test('partial carries provenance + value; isDegraded true', () {
      const m = MetricProvenance.partial(
        value: 4.5,
        provenance: 'vendor_test_partial_sync',
      );
      expect(m.state, MetricState.partial);
      expect(m.rendersNumber, isTrue);
      expect(m.isDegraded, isTrue);
    });

    test('fallback carries provenance + value; isDegraded true', () {
      const m = MetricProvenance.fallback(
        value: 24.0,
        provenance: 'vendor_test_with_forecast_covers',
      );
      expect(m.state, MetricState.fallback);
      expect(m.rendersNumber, isTrue);
      expect(m.isDegraded, isTrue);
    });

    test('equality + hashCode round-trip', () {
      const a = MetricProvenance.live(value: 12, provenance: 'vendor_x');
      const b = MetricProvenance.live(value: 12, provenance: 'vendor_x');
      const c = MetricProvenance.live(value: 13, provenance: 'vendor_x');
      expect(a == b, isTrue);
      expect(a.hashCode == b.hashCode, isTrue);
      expect(a == c, isFalse);
    });

    test('toString includes state, provenance, and value for debugging', () {
      const m = MetricProvenance.live(value: 7, provenance: 'vendor_y');
      final s = m.toString();
      expect(s, contains('live'));
      expect(s, contains('vendor_y'));
      expect(s, contains('7'));
    });
  });
}
